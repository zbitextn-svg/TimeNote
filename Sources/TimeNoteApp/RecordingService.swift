import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum RecordingError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case engineFailed(String)
    case fileFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "没有麦克风权限。请到「系统设置 → 隐私与安全性 → 麦克风」中允许 TimeNote，然后再试一次。"
        case .noInputDevice:
            return "这台 Mac 现在没有可用的麦克风（例如 Mac Studio、Mac mini 本身不带麦克风）。请连接 USB 话筒、带麦克风的耳机或声卡，然后再点「录音」。"
        case .engineFailed(let message):
            return "无法开始录音：\(message)"
        case .fileFailed(let message):
            return "录音文件处理失败：\(message)"
        }
    }
}

// MARK: - 输入设备

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputDevices {
    /// 系统里所有带输入通道的设备（内建麦克风、USB 话筒、声卡等）
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else {
            return nil
        }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - 采集

/// 麦克风采集：一路写入录音文件（CAF/PCM，异常退出也能恢复），一路转成转写需要的格式交给回调。
///
/// 音频回调在系统的音频线程上执行，内部状态用锁保护。
final class AudioCapture: @unchecked Sendable {
    /// 采集到的一段音频（已转为单声道）。在音频线程上调用，回调里不要切换到主线程或创建 Task。
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var monoConverter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var writeError: String?
    private var currentLevel: Float = 0

    private(set) var sampleRate: Double = 48_000

    /// 已写入的时长（秒）
    var recordedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / sampleRate
    }

    /// 最近一段音频的音量（0…1），由界面定时读取
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    var lastWriteError: String? {
        lock.lock()
        defer { lock.unlock() }
        return writeError
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// 开始采集并写入 `fileURL`（.caf）。`deviceID` 为 nil 时使用系统默认输入。
    func start(fileURL: URL, deviceID: AudioDeviceID?, onBuffer: @escaping BufferHandler) throws {
        // 先确认有输入设备：没有麦克风时 AVAudioEngine 安装 tap 会抛出 Objective-C 异常，
        // Swift 无法捕获，应用会直接崩溃
        let available = AudioInputDevices.all()
        if let deviceID {
            guard available.contains(where: { $0.id == deviceID }) else { throw RecordingError.noInputDevice }
        } else {
            guard let defaultID = AudioInputDevices.defaultInputID(),
                  available.contains(where: { $0.id == defaultID })
            else { throw RecordingError.noInputDevice }
        }

        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw RecordingError.engineFailed("无法切换到所选的输入设备（\(status)）")
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.noInputDevice
        }
        // AAC 最高 48 kHz；高采样率的声卡统一转到 48 kHz
        let rate = min(inputFormat.sampleRate, 48_000)
        guard
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: mono)
        else {
            throw RecordingError.engineFailed("不支持的输入格式 \(inputFormat)")
        }
        converter.downmix = true

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let audioFile: AVAudioFile
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw RecordingError.fileFailed(error.localizedDescription)
        }

        lock.lock()
        file = audioFile
        monoConverter = converter
        monoFormat = mono
        framesWritten = 0
        writeError = nil
        sampleRate = rate
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, onBuffer: onBuffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            closeFile()
            throw RecordingError.engineFailed(error.localizedDescription)
        }
    }

    /// 停止采集并关闭文件，返回录到的时长（秒）
    @discardableResult
    func stop() -> TimeInterval {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let duration = recordedDuration
        closeFile()
        return duration
    }

    private func closeFile() {
        lock.lock()
        // 关闭时写回文件头（数据长度等）；macOS 15 以前由释放对象时自动完成
        if #available(macOS 15.0, *) {
            file?.close()
        }
        file = nil
        monoConverter = nil
        lock.unlock()
    }

    private func process(_ buffer: AVAudioPCMBuffer, onBuffer: BufferHandler) {
        lock.lock()
        guard let converter = monoConverter, let monoFormat, let file else {
            lock.unlock()
            return
        }
        let ratio = monoFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else {
            lock.unlock()
            return
        }
        let feeder = OneShotBuffer(buffer)
        var conversionError: NSError?
        converter.convert(to: mono, error: &conversionError) { _, status in
            feeder.next(status)
        }
        if mono.frameLength > 0 {
            do {
                try file.write(from: mono)
                framesWritten += AVAudioFramePosition(mono.frameLength)
            } catch {
                writeError = error.localizedDescription
            }
            currentLevel = Self.level(of: mono)
        }
        lock.unlock()

        guard mono.frameLength > 0 else { return }
        onBuffer(mono)
    }

    /// 均方根音量，映射到 0…1（约 -50 dB 到 0 dB）
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
    }
}

/// AVAudioConverter 的输入回调：每次转换只提供一次同一个缓冲区
final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer {
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = .noDataNow
        return nil
    }
}

// MARK: - 文件整理

enum RecordingFiles {
    /// 把 CAF/PCM 录音压缩成 AAC（.m4a），成功后删除 CAF。返回 m4a 的时长（秒）。
    static func compressToM4A(source: URL, destination: URL) throws -> TimeInterval {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            // 应用异常退出时 CAF 文件头里的数据长度可能没写回，修复后再读
            try repairCAFDataChunk(at: source)
            input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        var totalFrames: AVAudioFramePosition = 0
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw RecordingError.fileFailed("无法分配缓冲区")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                totalFrames += AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw RecordingError.fileFailed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: source)
        return Double(totalFrames) / format.sampleRate
    }

    /// CAF 的 data 块长度写成 -1（表示一直到文件末尾），用于恢复意外中断的录音
    static func repairCAFDataChunk(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 8 // 'caff' + version + flags
        while offset + 12 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 12), header.count == 12 else { break }
            let type = String(decoding: header.prefix(4), as: UTF8.self)
            let size = header.dropFirst(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if type == "data" {
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: Data(repeating: 0xFF, count: 8))
                return
            }
            if size == UInt64.max { break }
            offset += 12 + size
        }
        throw RecordingError.fileFailed("录音文件已损坏，无法恢复")
    }

    static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
