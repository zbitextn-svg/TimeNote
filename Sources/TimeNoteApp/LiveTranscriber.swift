import AVFoundation
import Foundation
import Speech

/// 接收录音音频的转写端（与具体系统版本的实现解耦）
protocol TranscriptSink: AnyObject, Sendable {
    func feed(_ buffer: AVAudioPCMBuffer)
    /// 停止输入并等最后一句定稿
    func finish() async
    func cancel() async
}

enum TranscriptEvent: Sendable {
    /// 当前还在变化的文字（会被下一次结果替换）
    case volatile(String)
    /// 定稿的一句，时间相对录音开始（毫秒）
    case final(text: String, startMs: Int64, endMs: Int64)
    case failed(String)
}

/// 本机实时转写（macOS 26 的 SpeechAnalyzer / SpeechTranscriber）。
///
/// 录音线程通过 `feed` 送入音频；识别结果通过 `onEvent` 回调：
/// 未定稿的文字（volatile）随时替换，定稿的句子带上在录音中的起止时间。
@available(macOS 26.0, *)
final class LiveTranscriber: TranscriptSink, @unchecked Sendable {
    typealias Event = TranscriptEvent

    enum PreparationError: LocalizedError {
        case unsupportedLocale(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let name):
                return "这台 Mac 不支持「\(name)」的本机转写。"
            case .unavailable(let message):
                return "转写不可用：\(message)"
            }
        }
    }

    private let locale: Locale
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    let analyzerFormat: AVAudioFormat
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?

    private init(locale: Locale, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.locale = locale
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    /// 选出与偏好语言等价的、这台 Mac 支持的转写语言
    static func supportedLocale(for preferred: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
    }

    /// 准备好可用的转写模块：检查语言、预留语言、必要时下载语音模型（`onDownloadProgress` 报告 0…1）
    private static func makeModule(
        locale preferred: Locale,
        reportsVolatileResults: Bool,
        onDownloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (SpeechTranscriber, Locale) {
        guard SpeechTranscriber.isAvailable else {
            throw PreparationError.unavailable("这台 Mac 不支持本机语音转写")
        }
        guard let locale = await supportedLocale(for: preferred) else {
            throw PreparationError.unsupportedLocale(preferred.localizedString(forIdentifier: preferred.identifier) ?? preferred.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // fastResults：牺牲一点准确度换更快出字，实时转写更跟手
            reportingOptions: reportsVolatileResults ? [.volatileResults, .fastResults] : [],
            attributeOptions: [.audioTimeRange]
        )

        // 语言要先「预留」，否则模型状态一直是 supported（未安装），也无法开始识别。
        // 实测：预留之后已下载过的模型立即变为 installed。
        try await reserveIfNeeded(locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // 用 Task 轮询进度，而不是 KVO：KVO 回调在系统的任意线程上，
            // 从那里切到主线程的 Task 会触发执行器检查崩溃（见录音电平的说明）
            let progress = request.progress
            let poller = Task {
                while Task.isCancelled == false {
                    onDownloadProgress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
        }
        return (transcriber, locale)
    }

    /// 准备实时转写器
    static func prepare(
        locale preferred: Locale,
        onDownloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> LiveTranscriber {
        let (transcriber, locale) = try await makeModule(
            locale: preferred,
            reportsVolatileResults: true,
            onDownloadProgress: onDownloadProgress
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw PreparationError.unavailable("没有可用的音频格式")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // 预先加载模型，开始送音频后能更快出字
        try await analyzer.prepareToAnalyze(in: format)
        return LiveTranscriber(locale: locale, transcriber: transcriber, analyzer: analyzer, format: format)
    }

    private static func reserveIfNeeded(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) == false else { return }
        // 最多能预留的语言数量有限，满了就先释放最早的一个
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            await AssetInventory.release(reservedLocale: oldest)
        }
        try await AssetInventory.reserve(locale: locale)
    }

    /// 转写一个已保存的录音文件（录音时没来得及实时转写，或用户手动补转写）。
    /// 每定稿一句就回调一次，时间相对文件开头（毫秒）。
    static func transcribeFile(
        at url: URL,
        locale preferred: Locale,
        onDownloadProgress: @escaping @Sendable (Double) -> Void,
        onSegment: @escaping @Sendable (_ text: String, _ startMs: Int64, _ endMs: Int64) -> Void
    ) async throws {
        let (transcriber, _) = try await makeModule(
            locale: preferred,
            reportsVolatileResults: false,
            onDownloadProgress: onDownloadProgress
        )
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task.detached { () throws -> Void in
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { continue }
                let startMs = LiveTranscriber.milliseconds(result.range.start)
                onSegment(text, startMs, max(startMs, LiveTranscriber.milliseconds(result.range.end)))
            }
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await results.value
    }

    func start(onEvent: @escaping @Sendable (Event) -> Void) async throws {
        let transcriber = self.transcriber
        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        let range = result.range
                        let startMs = Self.milliseconds(range.start)
                        let endMs = Self.milliseconds(range.end)
                        onEvent(.volatile(""))
                        if text.isEmpty == false {
                            onEvent(.final(text: text, startMs: startMs, endMs: max(startMs, endMs)))
                        }
                    } else {
                        onEvent(.volatile(text))
                    }
                }
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
        try await analyzer.start(inputSequence: inputStream)
    }

    /// 送入一段单声道 Float32 音频（任意采样率），内部转换为识别所需的格式
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { return }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        let feeder = OneShotBuffer(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            feeder.next(status)
        }
        guard error == nil, output.frameLength > 0 else { return }
        inputContinuation.yield(AnalyzerInput(buffer: output))
    }

    /// 停止输入，等识别器处理完已送入的音频（最后一句会定稿）
    func finish() async {
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        _ = await resultsTask?.value
    }

    func cancel() async {
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    private static func milliseconds(_ time: CMTime) -> Int64 {
        guard time.isValid, time.isNumeric else { return 0 }
        return Int64((CMTimeGetSeconds(time) * 1000).rounded())
    }
}
