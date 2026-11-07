import SwiftUI

// MARK: - 标题栏的录音按钮

/// 标题右侧的录音按钮：空闲时是次要按钮，录音中变成红色计时胶囊，点一下停止。
struct RecordButton: View {
    @ObservedObject var store: TimeNoteStore
    @State private var isHovered = false

    var body: some View {
        Group {
            if let session = store.recordingSession {
                recordingPill(session)
            } else if store.isFinishingRecording {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在保存录音…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
            } else {
                idleButton
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.recordingSession?.recordingID)
    }

    private var idleButton: some View {
        Button {
            store.startRecording()
        } label: {
            HStack(spacing: 7) {
                if store.isStartingRecording {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .fill(Theme.recording)
                        .frame(width: 9, height: 9)
                }
                Text("录音")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? Theme.surfaceMuted : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(store.isStartingRecording)
        .help("开始录音，并在本机实时转成文字（⇧⌘R）")
        .accessibilityLabel("开始录音")
    }

    private func recordingPill(_ session: RecordingSession) -> some View {
        let isOtherProject = session.projectID != store.selectedProjectID
        return Button {
            store.stopRecording()
        } label: {
            HStack(spacing: 8) {
                PulsingDot()
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(DurationFormats.string(from: context.date.timeIntervalSince(session.startedAt)))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
                LevelMeter(live: store.live)
                    .frame(width: 26, height: 12)
                if isOtherProject {
                    Text(session.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.22)))
            }
            .foregroundStyle(Color.white)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.recordingFill)
                    .brightness(isHovered ? 0.04 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isOtherProject ? "正在为其他项目录音，点击停止（⇧⌘R）" : "正在录音，点击停止（⇧⌘R）")
        .accessibilityLabel("停止录音")
    }
}

private struct PulsingDot: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// 五格电平
struct LevelMeter: View {
    @ObservedObject var live: LiveAudioState
    var color: Color = .white

    var body: some View {
        let level = live.level
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                Capsule()
                    .fill(color.opacity(level > threshold ? 1 : 0.3))
                    .frame(width: 3, height: 4 + CGFloat(index) * 2)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - 右侧录音面板

struct RecordingPanel: View {
    @ObservedObject var store: TimeNoteStore
    @State private var renamingRecording: Recording?
    @State private var renameDraft = ""
    @State private var deletingRecording: Recording?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let session = store.recordingSession, session.projectID == store.selectedProjectID {
                LiveRecordingCard(store: store, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if let session = store.recordingSession {
                otherProjectBanner(session)
            }

            if store.recordings.isEmpty {
                emptyState
            } else {
                recordingList
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if let recording = store.selectedRecording {
                    TranscriptView(store: store, live: store.live, recording: recording)
                } else {
                    Spacer()
                }
            }
        }
        .background(Theme.canvas)
        .onAppear {
            store.refreshInputDevices()
        }
        .alert("重命名录音", isPresented: Binding(
            get: { renamingRecording != nil },
            set: { if $0 == false { renamingRecording = nil } }
        )) {
            TextField("录音名称", text: $renameDraft)
            Button("取消", role: .cancel) {
                renamingRecording = nil
            }
            Button("确定") {
                if let recording = renamingRecording {
                    store.renameRecording(id: recording.id, title: renameDraft)
                }
                renamingRecording = nil
            }
        }
        .confirmationDialog(
            "删除录音「\(deletingRecording?.title ?? "")」？",
            isPresented: Binding(
                get: { deletingRecording != nil },
                set: { if $0 == false { deletingRecording = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除录音和文字", role: .destructive) {
                if let recording = deletingRecording {
                    store.deleteRecording(id: recording.id)
                }
                deletingRecording = nil
            }
            Button("取消", role: .cancel) {
                deletingRecording = nil
            }
        } message: {
            Text("录音文件和转写的文字都会删除，无法撤销。场记不受影响。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("录音")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if store.recordings.isEmpty == false {
                Text("\(store.recordings.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            settingsMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var settingsMenu: some View {
        Menu {
            Section("输入设备") {
                Picker("输入设备", selection: Binding(
                    get: { store.selectedInputDeviceUID ?? "" },
                    set: { store.selectedInputDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("系统默认").tag("")
                    ForEach(store.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("转写语言") {
                Picker("转写语言", selection: $store.transcriptLocaleIdentifier) {
                    ForEach(TranscriptLanguage.all) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.isRecording)
        .help(store.isRecording ? "录音中不能更改设置" : "输入设备：\(store.selectedInputDeviceName)")
        .onTapGesture {
            store.refreshInputDevices()
        }
    }

    private func otherProjectBanner(_ session: RecordingSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.recording).frame(width: 7, height: 7)
            Text("正在为其他项目录音（\(session.title)）")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("停止") {
                store.stopRecording()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.recordingSession?.projectID != store.selectedProjectID {
                Image(systemName: "waveform")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("还没有录音")
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                Text("录音时说的话会实时转成文字。\n录音期间记的场记，之后点一下就能从那一刻回放。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textTertiary)
                Button {
                    store.startRecording()
                } label: {
                    Label("开始录音", systemImage: "record.circle")
                }
                .controlSize(.large)
                .disabled(store.isRecording || store.isStartingRecording)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.recordings) { recording in
                    RecordingRow(
                        recording: recording,
                        isSelected: store.selectedRecordingID == recording.id,
                        isLive: store.recordingSession?.recordingID == recording.id
                    )
                    .onTapGesture {
                        store.selectRecording(id: recording.id)
                    }
                    .contextMenu {
                        Button("重命名…") {
                            renameDraft = recording.title
                            renamingRecording = recording
                        }
                        Button("复制全部文字") {
                            store.copyTranscript(of: recording)
                        }
                        Button("重新转写") {
                            store.transcribeRecording(recording)
                        }
                        .disabled(recording.status == .recording || store.isTranscribing(recording))
                        Button("在访达中显示") {
                            store.revealRecording(recording)
                        }
                        .disabled(recording.status == .recording)
                        Divider()
                        Button("删除录音…", role: .destructive) {
                            deletingRecording = recording
                        }
                        .disabled(store.recordingSession?.recordingID == recording.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: min(CGFloat(store.recordings.count) * 50 + 8, 190))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LiveRecordingCard: View {
    @ObservedObject var store: TimeNoteStore
    let session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Theme.recording).frame(width: 8, height: 8)
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(DurationFormats.string(from: context.date.timeIntervalSince(session.startedAt)))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.recording)
                }
                LevelMeter(live: store.live, color: Theme.recording)
                    .frame(width: 26, height: 12)
                Spacer()
                Button {
                    store.stopRecording()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .controlSize(.small)
            }
            HStack(spacing: 5) {
                transcriptStateIcon
                Text(transcriptStateText)
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.recording.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.recording.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var transcriptStateIcon: some View {
        switch session.transcriptState {
        case .preparing, .downloading:
            ProgressView().controlSize(.mini)
        case .live:
            Image(systemName: "text.bubble")
        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
        }
    }

    private var transcriptStateText: String {
        switch session.transcriptState {
        case .preparing:
            return "正在准备本机转写…"
        case .downloading(let fraction):
            return "首次使用，正在下载语音模型 \(Int(fraction * 100))%（录音不受影响）"
        case .live:
            return "实时转写中 · 文字只保存在这台 Mac 上"
        case .unavailable(let message):
            return "转写不可用，只录音：\(message)"
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isSelected: Bool
    let isLive: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLive ? "record.circle" : "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isLive ? Theme.recording : Theme.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small + 1, style: .continuous)
                        .fill(isLive ? Theme.recording.opacity(0.12) : Theme.accentSoft)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if recording.status == .interrupted {
                Text("已中断")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.surfaceMuted))
                    .help("录音时应用意外退出，已恢复到中断前的内容")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium - 2, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : (isHovered ? Theme.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var subtitle: String {
        let day = TimeFormats.relativeDayLabel(for: recording.startedAt) ?? TimeFormats.shortDateString(from: recording.startedAt)
        let start = "\(day) \(TimeFormats.clockString(from: recording.startedAt))"
        if isLive {
            return "\(start) · 录音中"
        }
        return "\(start) · \(DurationFormats.string(from: recording.duration))"
    }
}

// MARK: - 转写文字 + 播放

private struct TranscriptView: View {
    @ObservedObject var store: TimeNoteStore
    @ObservedObject var live: LiveAudioState
    let recording: Recording

    private var isLive: Bool { store.recordingSession?.recordingID == recording.id }
    private static let liveAnchorID = "timenote-transcript-live"

    var body: some View {
        VStack(spacing: 0) {
            if isLive == false {
                PlayerBar(store: store, live: live, recording: recording)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if store.isTranscribing(recording) && store.selectedRecordingSegments.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在把录音转成文字…")
                                    .font(.callout)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                        } else if store.selectedRecordingSegments.isEmpty && liveText.isEmpty {
                            VStack(spacing: 12) {
                                Text(emptyText)
                                    .font(.callout)
                                    .foregroundStyle(Theme.textTertiary)
                                if isLive == false {
                                    Button {
                                        store.transcribeRecording(recording)
                                    } label: {
                                        Label("转写这段录音", systemImage: "text.bubble")
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                        }
                        ForEach(store.selectedRecordingSegments) { segment in
                            SegmentRow(
                                segment: segment,
                                clockText: TimeFormats.clockString(from: recording.startedAt.addingTimeInterval(segment.start)),
                                isPlaying: isPlaying(segment),
                                isHighlighted: store.highlightedSegmentID == segment.id,
                                canPlay: isLive == false,
                                onPlay: { store.play(recording, from: segment.start) },
                                onInsert: { store.insertTranscriptAsEntry(segment) }
                            )
                            .id(segment.id)
                        }
                        if liveText.isEmpty == false {
                            Text(liveText)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .italic()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        Color.clear.frame(height: 1).id(Self.liveAnchorID)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
                .onChange(of: store.selectedRecordingSegments.count) { _, _ in
                    if isLive {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.liveAnchorID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: liveText) { _, _ in
                    if isLive {
                        proxy.scrollTo(Self.liveAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: store.highlightedSegmentID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onAppear {
                    if let highlighted = store.highlightedSegmentID {
                        proxy.scrollTo(highlighted, anchor: .center)
                    } else if isLive {
                        proxy.scrollTo(Self.liveAnchorID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var liveText: String {
        isLive ? live.volatileText : ""
    }

    private var emptyText: String {
        if isLive {
            return "说话后，文字会出现在这里"
        }
        return "这段录音没有转写文字"
    }

    private func isPlaying(_ segment: TranscriptSegment) -> Bool {
        guard let playback = store.playback, playback.recordingID == recording.id else { return false }
        return live.playbackTime >= segment.start && live.playbackTime < max(segment.end, segment.start + 0.5)
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let clockText: String
    let isPlaying: Bool
    let isHighlighted: Bool
    let canPlay: Bool
    let onPlay: () -> Void
    let onInsert: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onPlay) {
                Text(clockText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(canPlay == false)
            .help(canPlay ? "从这里播放" : "录音结束后可以回放")

            Text(segment.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onInsert) {
                Image(systemName: "text.badge.plus")
            }
            .buttonStyle(HoverIconButtonStyle())
            .opacity(isHovered ? 1 : 0)
            .help("插入为场记（时间为这句话说出的时刻）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small + 2, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("从这里播放", action: onPlay)
                .disabled(canPlay == false)
            Button("插入为场记", action: onInsert)
        }
    }

    private var background: Color {
        if isHighlighted { return Theme.accentSoft }
        if isPlaying { return Theme.accent.opacity(0.08) }
        if isHovered { return Theme.hover }
        return .clear
    }
}

private struct PlayerBar: View {
    @ObservedObject var store: TimeNoteStore
    @ObservedObject var live: LiveAudioState
    let recording: Recording
    @State private var scrubbing: Double?

    private var state: PlaybackState? {
        guard let playback = store.playback, playback.recordingID == recording.id else { return nil }
        return playback
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    store.skipPlayback(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .buttonStyle(HoverIconButtonStyle())
                .disabled(state == nil)
                .help("后退 10 秒")

                Button {
                    store.togglePlayback(for: recording)
                } label: {
                    Image(systemName: state?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [.option])
                .help(state?.isPlaying == true ? "暂停（⌥空格）" : "播放（⌥空格）")

                Button {
                    store.skipPlayback(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .buttonStyle(HoverIconButtonStyle())
                .disabled(state == nil)
                .help("前进 10 秒")

                Spacer()
                Text("\(DurationFormats.string(from: displayedTime)) / \(DurationFormats.string(from: totalDuration))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { scrubbing ?? displayedTime },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(totalDuration, 0.1)
            ) { editing in
                if editing == false, let target = scrubbing {
                    if state == nil {
                        store.play(recording, from: target)
                    } else {
                        store.seekPlayback(to: target)
                    }
                    scrubbing = nil
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var displayedTime: TimeInterval {
        state == nil ? 0 : live.playbackTime
    }

    private var totalDuration: TimeInterval {
        state?.duration ?? recording.duration
    }
}
