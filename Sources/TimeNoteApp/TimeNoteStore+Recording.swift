import AppKit
import AVFoundation
import Foundation

/// 正在进行的录音
struct RecordingSession: Equatable {
    enum TranscriptState: Equatable {
        /// 正在准备转写（检查语言、加载模型）
        case preparing
        /// 首次使用，正在下载语音模型
        case downloading(Double)
        case live
        case unavailable(String)
    }

    let recordingID: String
    let projectID: String
    let startedAt: Date
    var title: String
    var segments: [TranscriptSegment] = []
    var transcriptState: TranscriptState = .preparing
}

struct PlaybackState: Equatable {
    let recordingID: String
    var isPlaying: Bool
    var duration: TimeInterval
}

/// 高频变化的状态（电平、未定稿文字、播放进度）单独发布，
/// 只让用到它们的小视图刷新，避免整个窗口每秒重绘十几次。
@MainActor
final class LiveAudioState: ObservableObject {
    @Published var level: Float = 0
    @Published var volatileText = ""
    @Published var playbackTime: TimeInterval = 0
}

/// 可选的转写语言
struct TranscriptLanguage: Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [TranscriptLanguage] = [
        TranscriptLanguage(id: "zh-CN", name: "普通话"),
        TranscriptLanguage(id: "zh-HK", name: "粤语"),
        TranscriptLanguage(id: "en-US", name: "English"),
    ]
}

/// 把采集到的音频交给转写器。转写器还没准备好时（例如首次下载语音模型）先缓存在内存里，
/// 准备好后一次性补送，这样开头几句也能转写，时间也能对上。
final class TranscriptFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: (any TranscriptSink)?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var isClosed = false
    /// 缓存上限（约 20 分钟单声道 48 kHz）
    private let maxPendingFrames: AVAudioFramePosition = 48_000 * 60 * 20
    /// 因缓存超限被丢弃、没有送去转写的开头时长（秒），用于修正句子时间
    private(set) var droppedSeconds: TimeInterval = 0

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isClosed == false else { return }
        if let transcriber {
            transcriber.feed(buffer)
            return
        }
        pending.append(buffer)
        pendingFrames += AVAudioFramePosition(buffer.frameLength)
        while pendingFrames > maxPendingFrames, let first = pending.first {
            pending.removeFirst()
            pendingFrames -= AVAudioFramePosition(first.frameLength)
            droppedSeconds += Double(first.frameLength) / first.format.sampleRate
        }
    }

    func attach(_ transcriber: any TranscriptSink) {
        lock.lock()
        defer { lock.unlock() }
        guard isClosed == false else { return }
        for buffer in pending {
            transcriber.feed(buffer)
        }
        pending.removeAll()
        pendingFrames = 0
        self.transcriber = transcriber
    }

    /// 停止接收音频，返回已接上的转写器（用于收尾）
    func close() -> (any TranscriptSink)? {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        pending.removeAll()
        return transcriber
    }
}

extension TimeNoteStore {
    // MARK: - 列表

    var isRecording: Bool { recordingSession != nil }

    var selectedRecording: Recording? {
        guard let selectedRecordingID else { return nil }
        return recordings.first(where: { $0.id == selectedRecordingID })
    }

    /// 当前项目的录音是否正在录制
    var isRecordingCurrentProject: Bool {
        recordingSession != nil && recordingSession?.projectID == selectedProjectID
    }

    func refreshRecordings() {
        guard let selectedProjectID else {
            recordings = []
            selectedRecordingSegments = []
            return
        }
        do {
            recordings = try database.fetchRecordings(projectID: selectedProjectID)
            if let selectedRecordingID, recordings.contains(where: { $0.id == selectedRecordingID }) == false {
                self.selectedRecordingID = nil
            }
            if selectedRecordingID == nil {
                selectedRecordingID = recordings.first?.id
            }
            reloadSelectedRecordingSegments()
        } catch {
            transientError = error.localizedDescription
        }
    }

    func selectRecording(id: String?) {
        guard selectedRecordingID != id else { return }
        selectedRecordingID = id
        reloadSelectedRecordingSegments()
    }

    func reloadSelectedRecordingSegments() {
        guard let selectedRecordingID else {
            selectedRecordingSegments = []
            return
        }
        if let session = recordingSession, session.recordingID == selectedRecordingID {
            selectedRecordingSegments = session.segments
            return
        }
        selectedRecordingSegments = (try? database.fetchTranscriptSegments(recordingID: selectedRecordingID)) ?? []
    }

    /// 某条场记对应的录音与位置（只在当前项目的录音里找）
    func recordingPosition(for entry: LogEntry) -> (recording: Recording, offset: TimeInterval)? {
        for recording in recordings {
            if let offset = recording.offset(of: entry.recordedAt) {
                return (recording, offset)
            }
        }
        return nil
    }

    // MARK: - 输入设备

    func refreshInputDevices() {
        inputDevices = AudioInputDevices.all()
        if let uid = selectedInputDeviceUID, inputDevices.contains(where: { $0.uid == uid }) == false {
            // 选过的设备已拔掉：回到系统默认
            selectedInputDeviceUID = nil
        }
    }

    var selectedInputDeviceName: String {
        if let uid = selectedInputDeviceUID, let device = inputDevices.first(where: { $0.uid == uid }) {
            return device.name
        }
        if let id = AudioInputDevices.defaultInputID(), let device = AudioInputDevices.all().first(where: { $0.id == id }) {
            return "系统默认（\(device.name)）"
        }
        return "系统默认"
    }

    // MARK: - 开始 / 停止

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard recordingSession == nil, isStartingRecording == false, isFinishingRecording == false else { return }
        guard let project = selectedProject else { return }
        // 先看有没有麦克风，没有就直接提示，不必弹出权限申请
        if AudioInputDevices.all().isEmpty {
            transientError = RecordingError.noInputDevice.localizedDescription
            return
        }
        isStartingRecording = true
        Task { @MainActor in
            defer { isStartingRecording = false }
            guard await AudioCapture.requestMicrophoneAccess() else {
                transientError = RecordingError.microphoneDenied.localizedDescription
                return
            }
            beginRecording(projectID: project.id)
        }
    }

    private func beginRecording(projectID: String) {
        refreshInputDevices()
        let recordingID = UUID().uuidString
        let relativePath = "attachments/\(projectID)/recordings/\(recordingID).caf"
        let existingCount = (try? database.fetchRecordings(projectID: projectID).count) ?? recordings.count
        let title = "录音 \(existingCount + 1)"
        let deviceID = selectedInputDeviceUID.flatMap { uid in inputDevices.first(where: { $0.uid == uid })?.id }

        let capture = AudioCapture()
        let feed = TranscriptFeed()
        let startedAt = Date()
        do {
            let fileURL = try attachmentService.attachmentURL(relativePath: relativePath)
            try database.insertRecording(
                id: recordingID,
                projectID: projectID,
                title: title,
                relativePath: relativePath,
                startedAt: startedAt,
                locale: transcriptLocaleIdentifier
            )
            do {
                // 音频线程上只做转写送料；电平由主线程定时读取（见 startLevelMeter）。
                // 不能在音频线程里创建 @MainActor 的 Task：实测会让主线程执行器检查崩溃。
                try capture.start(fileURL: fileURL, deviceID: deviceID) { buffer in
                    feed.feed(buffer)
                }
            } catch {
                try? database.deleteRecording(id: recordingID)
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        } catch {
            transientError = error.localizedDescription
            return
        }

        audioCapture = capture
        transcriptFeed = feed
        recordingSession = RecordingSession(recordingID: recordingID, projectID: projectID, startedAt: startedAt, title: title)
        if selectedProjectID == projectID {
            refreshRecordings()
            selectedRecordingID = recordingID
            selectedRecordingSegments = []
        }
        isRecordingPanelPresented = true
        startTranscription(recordingID: recordingID, projectID: projectID, feed: feed)
        startProgressUpdates(recordingID: recordingID, capture: capture)
        startLevelMeter(recordingID: recordingID, capture: capture)
    }

    /// 每 0.1 秒在主线程读取一次音量，驱动电平显示
    private func startLevelMeter(recordingID: String, capture: AudioCapture) {
        let task = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.recordingSession?.recordingID == recordingID else { return }
                let level = capture.level
                if abs(self.live.level - level) > 0.02 {
                    self.live.level = level
                }
            }
        }
        recordingTasks.append(task)
    }

    private func startTranscription(recordingID: String, projectID: String, feed: TranscriptFeed) {
        guard #available(macOS 26.0, *) else {
            recordingSession?.transcriptState = .unavailable("需要 macOS 26 或更高版本")
            return
        }
        let locale = Locale(identifier: transcriptLocaleIdentifier)
        // 这里的闭包都强引用 store：转写器在录音停止时就会结束，不会长期持有
        let task = Task { @MainActor in
            do {
                let transcriber = try await LiveTranscriber.prepare(locale: locale) { fraction in
                    Task { @MainActor in
                        guard self.recordingSession?.recordingID == recordingID else { return }
                        self.recordingSession?.transcriptState = .downloading(fraction)
                    }
                }
                guard recordingSession?.recordingID == recordingID else {
                    await transcriber.cancel()
                    return
                }
                // 先接上音频（送入的音频会在流里排队），再启动识别
                feed.attach(transcriber)
                recordingSession?.transcriptState = .live
                try await transcriber.start { event in
                    Task { @MainActor in
                        self.handleTranscriptEvent(event, recordingID: recordingID, projectID: projectID, feed: feed)
                    }
                }
            } catch {
                guard recordingSession?.recordingID == recordingID else { return }
                recordingSession?.transcriptState = .unavailable(error.localizedDescription)
            }
        }
        recordingTasks.append(task)
    }

    private func handleTranscriptEvent(_ event: TranscriptEvent, recordingID: String, projectID: String, feed: TranscriptFeed) {
        switch event {
        case .volatile(let text):
            guard recordingSession?.recordingID == recordingID else { return }
            live.volatileText = text
        case .final(let text, let startMs, let endMs):
            let offsetMs = Int64(feed.droppedSeconds * 1000)
            do {
                guard let segment = try database.insertTranscriptSegment(
                    recordingID: recordingID,
                    projectID: projectID,
                    startMs: startMs + offsetMs,
                    endMs: endMs + offsetMs,
                    text: text
                ) else { return }
                if recordingSession?.recordingID == recordingID {
                    recordingSession?.segments.append(segment)
                }
                if selectedRecordingID == recordingID {
                    selectedRecordingSegments.append(segment)
                }
            } catch {
                transientError = error.localizedDescription
            }
        case .failed(let message):
            guard recordingSession?.recordingID == recordingID else { return }
            recordingSession?.transcriptState = .unavailable(message)
        }
    }

    /// 每 5 秒把已录时长写进数据库，异常退出后也能知道录到了哪里
    private func startProgressUpdates(recordingID: String, capture: AudioCapture) {
        let task = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.recordingSession?.recordingID == recordingID else { return }
                try? self.database.updateRecordingProgress(id: recordingID, durationMs: Int64(capture.recordedDuration * 1000))
                if let message = capture.lastWriteError {
                    self.transientError = "录音写入出错：\(message)"
                }
            }
        }
        recordingTasks.append(task)
    }

    func stopRecording() {
        guard let session = recordingSession, let capture = audioCapture else { return }
        isFinishingRecording = true
        let duration = capture.stop()
        let transcriber = transcriptFeed?.close()
        for task in recordingTasks {
            task.cancel()
        }
        recordingTasks.removeAll()
        audioCapture = nil
        transcriptFeed = nil

        Task { @MainActor in
            // 等最后一句定稿
            if let transcriber {
                await transcriber.finish()
            }
            recordingSession = nil
            live.volatileText = ""
            live.level = 0
            await finalizeRecording(id: session.recordingID, durationHint: duration, status: .finished)
            isFinishingRecording = false
            if selectedProjectID == session.projectID {
                refreshRecordings()
                selectRecording(id: session.recordingID)
                reloadSelectedRecordingSegments()
            }
            showToast("录音已保存：\(session.title)（\(DurationFormats.string(from: duration))）", style: .success)

            // 录音时没来得及实时转写（模型还在准备、转写出错等），就对保存好的文件补转写
            let savedSegments = (try? database.fetchTranscriptSegments(recordingID: session.recordingID)) ?? []
            if savedSegments.isEmpty, let recording = try? database.fetchRecording(id: session.recordingID) {
                transcribeRecording(recording)
            }
        }
    }

    // MARK: - 对录音文件补转写

    func isTranscribing(_ recording: Recording) -> Bool {
        transcribingRecordingIDs.contains(recording.id)
    }

    /// 对已保存的录音文件做转写。已有的文字会被替换。
    func transcribeRecording(_ recording: Recording) {
        guard recording.status != .recording, transcribingRecordingIDs.contains(recording.id) == false else { return }
        guard #available(macOS 26.0, *) else {
            transientError = "录音转文字需要 macOS 26 或更高版本。"
            return
        }
        guard let url = try? attachmentService.attachmentURL(relativePath: recording.relativePath),
              FileManager.default.fileExists(atPath: url.path)
        else {
            transientError = "找不到录音文件，无法转写。"
            return
        }
        transcribingRecordingIDs.insert(recording.id)
        let locale = Locale(identifier: recording.locale.isEmpty ? transcriptLocaleIdentifier : recording.locale)
        let recordingID = recording.id
        let projectID = recording.projectID

        Task { @MainActor in
            defer { transcribingRecordingIDs.remove(recordingID) }
            // 先清掉旧的文字（如果有），再逐句写入
            if let old = try? database.fetchTranscriptSegments(recordingID: recordingID) {
                for segment in old {
                    try? database.updateTranscriptSegment(id: segment.id, text: "")
                }
            }
            if selectedRecordingID == recordingID {
                selectedRecordingSegments = []
            }
            do {
                try await LiveTranscriber.transcribeFile(
                    at: url,
                    locale: locale,
                    onDownloadProgress: { _ in }
                ) { text, startMs, endMs in
                    Task { @MainActor in
                        guard let segment = try? self.database.insertTranscriptSegment(
                            recordingID: recordingID,
                            projectID: projectID,
                            startMs: startMs,
                            endMs: endMs,
                            text: text
                        ) else { return }
                        if self.selectedRecordingID == recordingID {
                            self.selectedRecordingSegments.append(segment)
                        }
                    }
                }
                // 让最后几句的写入先完成，再按时间顺序重新载入
                try? await Task.sleep(for: .milliseconds(300))
                reloadSelectedRecordingSegments()
                let total = (try? database.fetchTranscriptSegments(recordingID: recordingID).count) ?? 0
                showToast(total == 0 ? "「\(recording.title)」里没有识别到说话内容" : "「\(recording.title)」已转写 \(total) 句", style: total == 0 ? .info : .success)
            } catch {
                transientError = "转写失败：\(error.localizedDescription)"
            }
        }
    }

    /// 应用退出时：立即关闭文件（转写来不及收尾），下次启动时整理
    func stopRecordingForTermination() {
        guard audioCapture != nil else { return }
        audioCapture?.stop()
        _ = transcriptFeed?.close()
        live.level = 0
        audioCapture = nil
        transcriptFeed = nil
    }

    /// 把 CAF 压缩成 m4a，并写入最终时长、大小与状态
    private func finalizeRecording(id: String, durationHint: TimeInterval, status: Recording.Status) async {
        guard let recording = try? database.fetchRecording(id: id) else { return }
        let sourceURL: URL
        do {
            sourceURL = try attachmentService.attachmentURL(relativePath: recording.relativePath)
        } catch {
            transientError = error.localizedDescription
            return
        }
        let m4aRelativePath = (recording.relativePath as NSString).deletingPathExtension + ".m4a"
        let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")

        var finalRelativePath = recording.relativePath
        var finalURL = sourceURL
        var duration = durationHint
        if sourceURL.pathExtension == "caf", FileManager.default.fileExists(atPath: sourceURL.path) {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<TimeInterval, Error> in
                Result { try RecordingFiles.compressToM4A(source: sourceURL, destination: destinationURL) }
            }.value
            switch result {
            case .success(let compressedDuration):
                finalRelativePath = m4aRelativePath
                finalURL = destinationURL
                duration = compressedDuration
            case .failure(let error):
                // 压缩失败时保留原始 CAF，仍然可以回放
                transientError = "录音已保存，但压缩为 m4a 失败：\(error.localizedDescription)"
            }
        } else if FileManager.default.fileExists(atPath: destinationURL.path) {
            // 上次压缩完成但还没来得及更新数据库
            finalRelativePath = m4aRelativePath
            finalURL = destinationURL
            if let file = try? AVAudioFile(forReading: destinationURL) {
                duration = Double(file.length) / file.processingFormat.sampleRate
            }
        }

        // 意外中断、几乎没有录到声音的录音，直接清理掉，不留下 00:00 的空记录
        if status == .interrupted, duration < 0.5 {
            try? database.deleteRecording(id: id)
            try? FileManager.default.removeItem(at: finalURL)
            if finalURL != sourceURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            return
        }

        do {
            try database.finishRecording(
                id: id,
                relativePath: finalRelativePath,
                durationMs: Int64((duration * 1000).rounded()),
                fileSize: RecordingFiles.fileSize(at: finalURL),
                status: status
            )
        } catch {
            transientError = error.localizedDescription
        }
    }

    /// 启动时整理上次没有正常结束的录音
    func recoverUnfinishedRecordings() {
        // 清理以前崩溃留下的空录音（00:00、没有文字）
        if let empty = try? database.fetchEmptyInterruptedRecordings() {
            for recording in empty {
                try? database.deleteRecording(id: recording.id)
                try? attachmentService.deleteAttachment(relativePath: recording.relativePath)
            }
            if empty.isEmpty == false {
                refreshRecordings()
            }
        }
        guard let unfinished = try? database.fetchUnfinishedRecordings(), unfinished.isEmpty == false else { return }
        Task { @MainActor in
            for recording in unfinished {
                await finalizeRecording(
                    id: recording.id,
                    durationHint: recording.duration,
                    status: .interrupted
                )
            }
            refreshRecordings()
            let recovered = unfinished.filter { recording in
                (try? database.fetchRecording(id: recording.id)) != nil
            }
            if recovered.isEmpty == false {
                let names = recovered.map(\.title).joined(separator: "、")
                showToast("已恢复上次意外中断的录音：\(names)", style: .info)
            }
        }
    }

    // MARK: - 管理

    func renameRecording(id: String, title: String) {
        performDatabaseUpdate {
            try database.renameRecording(id: id, title: title)
            if recordingSession?.recordingID == id {
                recordingSession?.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            refreshRecordings()
        }
    }

    func deleteRecording(id: String) {
        guard recordingSession?.recordingID != id else {
            transientError = "正在录制的录音不能删除，请先停止录音。"
            return
        }
        if playback?.recordingID == id {
            stopPlayback()
        }
        performDatabaseUpdate {
            guard let recording = try database.fetchRecording(id: id) else { return }
            try database.deleteRecording(id: id)
            try? attachmentService.deleteAttachment(relativePath: recording.relativePath)
            if selectedRecordingID == id {
                selectedRecordingID = nil
            }
            refreshRecordings()
        }
    }

    func revealRecording(_ recording: Recording) {
        guard let url = try? attachmentService.attachmentURL(relativePath: recording.relativePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 把一句转写插入主场记，时间为这句话说出的时刻
    func insertTranscriptAsEntry(_ segment: TranscriptSegment) {
        guard
            let recording = try? database.fetchRecording(id: segment.recordingID),
            let mainTab = try? database.fetchMainTab(projectID: recording.projectID)
        else { return }
        let recordedAt = recording.startedAt.addingTimeInterval(segment.start)
        performDatabaseUpdate {
            guard let entry = try database.insertLogEntry(
                projectID: recording.projectID,
                tabID: mainTab.id,
                recordedAt: recordedAt,
                noteText: segment.text
            ) else { return }
            if recording.projectID == selectedProjectID {
                refreshEntries()
                highlightEntry(entry.id)
            }
            refreshProjectStats()
            showToast("已插入场记 \(TimeFormats.clockString(from: recordedAt))", style: .success)
        }
    }

    func copyTranscript(of recording: Recording) {
        let segments = recording.id == recordingSession?.recordingID
            ? (recordingSession?.segments ?? [])
            : ((try? database.fetchTranscriptSegments(recordingID: recording.id)) ?? [])
        guard segments.isEmpty == false else {
            showToast("这段录音还没有文字", style: .info)
            return
        }
        let text = segments.map { segment in
            "\(TimeFormats.clockString(from: recording.startedAt.addingTimeInterval(segment.start))) \(segment.text)"
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("已复制「\(recording.title)」的文字", style: .success)
    }

    /// 从搜索结果跳到某句转写
    func revealTranscript(recordingID: String, offsetMs: Int64) {
        isRecordingPanelPresented = true
        refreshRecordings()
        selectRecording(id: recordingID)
        reloadSelectedRecordingSegments()
        if let segment = selectedRecordingSegments.first(where: { $0.startMs == offsetMs }) ?? selectedRecordingSegments.last(where: { $0.startMs <= offsetMs }) {
            highlightSegment(segment.id)
        }
        if let recording = selectedRecording, recording.status != .recording {
            preparePlayback(recording, at: TimeInterval(offsetMs) / 1000, autoplay: false)
        }
    }

    func highlightSegment(_ segmentID: String) {
        highlightedSegmentID = segmentID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if highlightedSegmentID == segmentID {
                highlightedSegmentID = nil
            }
        }
    }

    // MARK: - 回放

    /// 从场记对应的位置开始播放（提前 3 秒，方便听到上下文）
    func playEntry(_ entry: LogEntry) {
        guard let position = recordingPosition(for: entry) else { return }
        isRecordingPanelPresented = true
        selectRecording(id: position.recording.id)
        guard position.recording.status != .recording else {
            showToast("录音结束后就可以从这里回放", style: .info)
            return
        }
        let start = max(0, position.offset - 3)
        if let segment = selectedRecordingSegments.last(where: { $0.start <= position.offset }) {
            highlightSegment(segment.id)
        }
        preparePlayback(position.recording, at: start, autoplay: true)
    }

    func play(_ recording: Recording, from offset: TimeInterval) {
        guard recording.status != .recording else {
            showToast("录音结束后就可以回放", style: .info)
            return
        }
        preparePlayback(recording, at: offset, autoplay: true)
    }

    func togglePlayback(for recording: Recording) {
        if let playback, playback.recordingID == recording.id, let audioPlayer {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                self.playback?.isPlaying = false
            } else {
                audioPlayer.play()
                self.playback?.isPlaying = true
                startPlaybackTimer()
            }
            return
        }
        play(recording, from: 0)
    }

    func seekPlayback(to time: TimeInterval) {
        guard let audioPlayer else { return }
        audioPlayer.currentTime = max(0, min(time, audioPlayer.duration))
        live.playbackTime = audioPlayer.currentTime
    }

    func skipPlayback(by seconds: TimeInterval) {
        guard let audioPlayer else { return }
        seekPlayback(to: audioPlayer.currentTime + seconds)
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playback = nil
        live.playbackTime = 0
    }

    private func preparePlayback(_ recording: Recording, at offset: TimeInterval, autoplay: Bool) {
        do {
            if playback?.recordingID != recording.id || audioPlayer == nil {
                stopPlayback()
                let url = try attachmentService.attachmentURL(relativePath: recording.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    transientError = "找不到录音文件：\(url.lastPathComponent)"
                    return
                }
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                audioPlayer = player
                playback = PlaybackState(recordingID: recording.id, isPlaying: false, duration: player.duration)
            }
            guard let audioPlayer else { return }
            audioPlayer.currentTime = max(0, min(offset, audioPlayer.duration))
            live.playbackTime = audioPlayer.currentTime
            if autoplay {
                audioPlayer.play()
                playback?.isPlaying = true
                startPlaybackTimer()
            }
        } catch {
            transientError = "无法播放录音：\(error.localizedDescription)"
        }
    }

    private func startPlaybackTimer() {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.audioPlayer else { return }
                self.live.playbackTime = player.currentTime
                if player.isPlaying == false {
                    self.playback?.isPlaying = false
                    return
                }
            }
        }
    }
}
