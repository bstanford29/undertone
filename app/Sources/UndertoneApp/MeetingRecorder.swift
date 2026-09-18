import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum MeetingSpeaker: String, Codable, Sendable {
    case me
    case others
}

struct MeetingChunk: Codable, Equatable, Sendable {
    let sequence: Int
    let speaker: MeetingSpeaker
    let path: URL
    let offset: Double
    let duration: Double
    let voiceActivity: Bool

    // Match the engine's meeting.chunk request names so the callback can be
    // forwarded without leaking a second protocol model into the UI layer.
    enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case speaker
        case path = "audio_path"
        case offset = "offset_s"
        case duration = "duration_s"
        case voiceActivity = "voice_activity"
    }

    init(sequence: Int, speaker: MeetingSpeaker, path: URL, offset: Double, duration: Double,
         voiceActivity: Bool = true) {
        self.sequence = sequence
        self.speaker = speaker
        self.path = path
        self.offset = offset
        self.duration = duration
        self.voiceActivity = voiceActivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        speaker = try container.decode(MeetingSpeaker.self, forKey: .speaker)
        let pathString = try container.decode(String.self, forKey: .path)
        path = URL(fileURLWithPath: pathString)
        offset = try container.decode(Double.self, forKey: .offset)
        duration = try container.decode(Double.self, forKey: .duration)
        voiceActivity = try container.decodeIfPresent(Bool.self, forKey: .voiceActivity) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(path.path, forKey: .path)
        try container.encode(offset, forKey: .offset)
        try container.encode(duration, forKey: .duration)
        try container.encode(voiceActivity, forKey: .voiceActivity)
    }
}

struct MeetingChunkBoundary: Equatable, Sendable {
    let offset: Double
    let duration: Double
}

enum MeetingPermissionStatus: Equatable, Sendable {
    case ready
    case microphoneRequired
    case screenRecordingRequired
    case microphoneAndScreenRecordingRequired
}

enum MeetingRecorderError: LocalizedError, Equatable {
    case permissions(MeetingPermissionStatus)
    case alreadyRunning
    case stoppedDuringStart
    case noDisplay
    case captureFailed(String)
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .permissions(let status): return "Meeting capture requires \(status.permissionDescription)"
        case .alreadyRunning: return "Meeting capture is already running"
        case .stoppedDuringStart: return "Meeting capture stopped before it finished starting"
        case .noDisplay: return "No display is available for system audio capture"
        case .captureFailed(let message): return "Meeting capture failed: \(message)"
        case .audioFormatUnavailable: return "Meeting audio format is unavailable"
        }
    }
}

private extension MeetingPermissionStatus {
    var permissionDescription: String {
        switch self {
        case .ready: return "no additional permissions"
        case .microphoneRequired: return "Microphone permission"
        case .screenRecordingRequired: return "Screen Recording permission"
        case .microphoneAndScreenRecordingRequired: return "Microphone and Screen Recording permissions"
        }
    }
}

struct MeetingAudioMath {
    static let defaultSampleRate = 48_000.0
    static let defaultChunkSeconds = 10.0
    static let defaultVADThreshold = 0.01

    static func metrics(_ samples: [Float]) -> (rms: Double, peak: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        var sum = 0.0
        var peak = 0.0
        for sample in samples {
            let value = abs(Double(sample))
            sum += value * value
            peak = max(peak, value)
        }
        return (sqrt(sum / Double(samples.count)), peak)
    }

    static func isVoiceActivity(_ samples: [Float], threshold: Double = defaultVADThreshold) -> Bool {
        let values = metrics(samples)
        return values.rms >= threshold || values.peak >= threshold * 4
    }

    static func mono(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return samples }
        let frameCount = samples.count / channels
        return (0..<frameCount).map { frame in
            let start = frame * channels
            return samples[start..<(start + channels)].reduce(0, +) / Float(channels)
        }
    }

    /// Linear resampling keeps chunk duration metadata tied to the output
    /// sample rate even when Core Audio opens the microphone at 44.1 kHz.
    static func resample(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard !samples.isEmpty, fromRate > 0, toRate > 0 else { return [] }
        guard abs(fromRate - toRate) > 0.5 else { return samples }
        let count = max(1, Int((Double(samples.count) * toRate / fromRate).rounded()))
        return (0..<count).map { index in
            let sourcePosition = Double(index) * fromRate / toRate
            let lower = min(samples.count - 1, Int(sourcePosition.rounded(.down)))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }

    static func boundaries(totalFrames: Int, sampleRate: Double = defaultSampleRate,
                           chunkSeconds: Double = defaultChunkSeconds) -> [MeetingChunkBoundary] {
        guard totalFrames > 0, sampleRate > 0, chunkSeconds > 0 else { return [] }
        let capacity = max(1, Int(sampleRate * chunkSeconds))
        var result: [MeetingChunkBoundary] = []
        var start = 0
        while start < totalFrames {
            let length = min(capacity, totalFrames - start)
            result.append(MeetingChunkBoundary(offset: Double(start) / sampleRate,
                                               duration: Double(length) / sampleRate))
            start += length
        }
        return result
    }
}

private final class MeetingChunkAssembler {
    let speaker: MeetingSpeaker
    let directory: URL
    let sampleRate: Double
    let chunkSeconds: Double
    let vadThreshold: Double
    private var samples: [Float] = []
    private var capturedFrames = 0
    private var pendingOffset: Double?

    init(speaker: MeetingSpeaker, directory: URL, sampleRate: Double,
         chunkSeconds: Double, vadThreshold: Double) {
        self.speaker = speaker
        self.directory = directory
        self.sampleRate = sampleRate
        self.chunkSeconds = chunkSeconds
        self.vadThreshold = vadThreshold
        samples.reserveCapacity(max(1, Int(sampleRate * chunkSeconds)))
    }

    func append(_ monoSamples: [Float], offset: Double,
                emit: (MeetingSpeaker, [Float], Double, Double, Bool) -> Void) {
        guard !monoSamples.isEmpty else { return }
        if samples.isEmpty {
            pendingOffset = max(offset, Double(capturedFrames) / sampleRate)
        }
        samples.append(contentsOf: monoSamples)
        let capacity = max(1, Int(sampleRate * chunkSeconds))
        while samples.count >= capacity {
            let chunk = Array(samples.prefix(capacity))
            samples.removeFirst(capacity)
            let chunkOffset = pendingOffset ?? Double(capturedFrames) / sampleRate
            capturedFrames += chunk.count
            let hasVoice = MeetingAudioMath.isVoiceActivity(chunk, threshold: vadThreshold)
            let duration = Double(chunk.count) / sampleRate
            emit(speaker, chunk, chunkOffset, duration, hasVoice)
            pendingOffset = samples.isEmpty ? nil : chunkOffset + duration
        }
    }

    func flush(emit: (MeetingSpeaker, [Float], Double, Double, Bool) -> Void) {
        guard !samples.isEmpty else { return }
        let chunk = samples
        samples.removeAll(keepingCapacity: true)
        let offset = pendingOffset ?? Double(capturedFrames) / sampleRate
        capturedFrames += chunk.count
        let hasVoice = MeetingAudioMath.isVoiceActivity(chunk, threshold: vadThreshold)
        emit(speaker, chunk, offset, Double(chunk.count) / sampleRate, hasVoice)
        pendingOffset = nil
    }
}

private final class MeetingStreamOutput: NSObject, SCStreamOutput {
    weak var owner: MeetingRecorder?

    init(owner: MeetingRecorder) { self.owner = owner }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        owner?.receiveSystemAudio(sampleBuffer)
    }
}

private final class MeetingStreamDelegate: NSObject, SCStreamDelegate {
    weak var owner: MeetingRecorder?

    init(owner: MeetingRecorder) { self.owner = owner }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.receiveCaptureError(error)
    }
}

final class MeetingRecorder: NSObject, @unchecked Sendable {
    typealias ChunkHandler = @Sendable (MeetingChunk) -> Void
    typealias ErrorHandler = @Sendable (MeetingRecorderError) -> Void

    let outputDirectory: URL
    var onChunk: ChunkHandler?
    var onError: ErrorHandler?
    /// Called with the measured RMS for each speaker at most 20 times/sec.
    /// Values are normalized to the Float PCM range and never synthesized.
    var onLevels: (@Sendable (MeetingSpeaker, Double) -> Void)?
    private let sampleRate: Double
    private let chunkSeconds: Double
    private let vadThreshold: Double
    private let audioQueue = DispatchQueue(label: "com.undertone.meeting-audio")
    private let pendingLock = NSLock()
    private let stopLock = NSLock()
    private let maxPendingAudioBlocks = 64
    private var pendingAudioBlocks = 0
    private var overloadReported = false
    private var stopTask: Task<[MeetingChunk], Never>?
    private enum Lifecycle { case idle, starting, running, stopping }
    private var stream: SCStream?
    private var streamOutput: MeetingStreamOutput?
    private var streamDelegate: MeetingStreamDelegate?
    private var systemTapObject: AnyObject?
    private var micEngine: AVAudioEngine?
    private var lifecycle = Lifecycle.idle
    private var running = false
    private var nextSequence = 0
    private var activeOutputDirectory: URL?
    private var captureStartUptime: TimeInterval = 0
    private var meAssembler: MeetingChunkAssembler?
    private var othersAssembler: MeetingChunkAssembler?
    private var lastLevelAt: [MeetingSpeaker: TimeInterval] = [:]

    init(outputDirectory: URL? = nil, sampleRate: Double = MeetingAudioMath.defaultSampleRate,
         chunkSeconds: Double = MeetingAudioMath.defaultChunkSeconds,
         vadThreshold: Double = MeetingAudioMath.defaultVADThreshold,
         onChunk: ChunkHandler? = nil, onError: ErrorHandler? = nil,
         onLevels: (@Sendable (MeetingSpeaker, Double) -> Void)? = nil) {
        self.outputDirectory = outputDirectory ?? URL(fileURLWithPath: NSString(string: "~/.undertone/meetings").expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.sampleRate = sampleRate
        self.chunkSeconds = chunkSeconds
        self.vadThreshold = vadThreshold
        self.onChunk = onChunk
        self.onError = onError
        self.onLevels = onLevels
    }

    static func permissionStatus() -> MeetingPermissionStatus {
        let microphone = AVAudioApplication.shared.recordPermission == .granted
        if #available(macOS 14.4, *) {
            // Core Audio has no public preflight API for this grant. Starting
            // the process tap is the authoritative check on modern macOS.
            return microphone ? .ready : .microphoneRequired
        }
        let screen = CGPreflightScreenCaptureAccess()
        switch (microphone, screen) {
        case (true, true): return .ready
        case (false, true): return .microphoneRequired
        case (true, false): return .screenRecordingRequired
        case (false, false): return .microphoneAndScreenRecordingRequired
        }
    }

    func start() async throws {
        let status = Self.permissionStatus()
        guard status == .ready else { throw MeetingRecorderError.permissions(status) }
        let runDirectory = outputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputDirectory.path)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runDirectory.path)
        let claimed = audioQueue.sync { () -> Bool in
            guard lifecycle == .idle else { return false }
            lifecycle = .starting
            running = true
            nextSequence = 0
            pendingLock.lock()
            pendingAudioBlocks = 0
            overloadReported = false
            pendingLock.unlock()
            lastLevelAt.removeAll(keepingCapacity: true)
            activeOutputDirectory = runDirectory
            captureStartUptime = ProcessInfo.processInfo.systemUptime
            meAssembler = MeetingChunkAssembler(speaker: .me, directory: runDirectory, sampleRate: sampleRate, chunkSeconds: chunkSeconds, vadThreshold: vadThreshold)
            othersAssembler = MeetingChunkAssembler(speaker: .others, directory: runDirectory, sampleRate: sampleRate, chunkSeconds: chunkSeconds, vadThreshold: vadThreshold)
            return true
        }
        guard claimed else { throw MeetingRecorderError.alreadyRunning }
        var pendingStream: SCStream?
        var pendingStreamOutput: MeetingStreamOutput?
        var pendingStreamDelegate: MeetingStreamDelegate?
        var pendingSystemTap: AnyObject?
        var pendingMic: AVAudioEngine?
        var micTapInstalled = false
        do {
            let mic = AVAudioEngine()
            pendingMic = mic
            let input = mic.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingRecorderError.audioFormatUnavailable }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let samples = Self.samples(from: buffer) else { return }
                let mono = MeetingAudioMath.mono(samples, channels: Int(format.channelCount))
                let converted = MeetingAudioMath.resample(mono, fromRate: format.sampleRate, toRate: self.sampleRate)
                self.receiveMicrophone(converted, channels: 1)
            }
            micTapInstalled = true
            try mic.start()
            if #available(macOS 14.4, *) {
                let tap = CoreAudioSystemTap()
                tap.onBuffer = { [weak self] buffer in
                    self?.receiveSystemAudio(buffer)
                }
                try tap.start()
                pendingSystemTap = tap
            } else {
                let shareable = try await shareableContent()
                guard let display = shareable.displays.first else { throw MeetingRecorderError.noDisplay }
                let ownApplications = shareable.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = Int(sampleRate)
                configuration.channelCount = 2
                configuration.width = 2
                configuration.height = 2
                let delegate = MeetingStreamDelegate(owner: self)
                let output = MeetingStreamOutput(owner: self)
                let systemStream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
                try systemStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
                pendingStream = systemStream
                pendingStreamOutput = output
                pendingStreamDelegate = delegate
                try await startCapture(systemStream)
            }
            let attached = audioQueue.sync { () -> Bool in
                guard lifecycle == .starting else { return false }
                stream = pendingStream
                streamOutput = pendingStreamOutput
                streamDelegate = pendingStreamDelegate
                if #available(macOS 14.4, *) {
                    systemTapObject = pendingSystemTap
                }
                micEngine = mic
                lifecycle = .running
                return true
            }
            guard attached else { throw MeetingRecorderError.stoppedDuringStart }
        } catch {
            if let pendingStream { await stopCapture(pendingStream) }
            if #available(macOS 14.4, *) { (pendingSystemTap as? CoreAudioSystemTap)?.stop() }
            if let pendingMic {
                if micTapInstalled { pendingMic.inputNode.removeTap(onBus: 0) }
                pendingMic.stop()
            }
            await stop()
            if let recorderError = error as? MeetingRecorderError { throw recorderError }
            if #available(macOS 14.4, *), let tapError = error as? CoreAudioSystemTapError {
                throw MeetingRecorderError.captureFailed(tapError.diagnosticDescription)
            }
            throw MeetingRecorderError.captureFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func stop() async -> [MeetingChunk] {
        await stopTaskForCurrentCall().value
    }

    private func stopTaskForCurrentCall() -> Task<[MeetingChunk], Never> {
        stopLock.lock()
        defer { stopLock.unlock() }
        if let existing = stopTask {
            return existing
        }
        let task = Task { [weak self] () -> [MeetingChunk] in
            guard let self else { return [] }
            let result = await self.performStop()
            self.clearStopTask()
            return result
        }
        stopTask = task
        return task
    }

    private func clearStopTask() {
        stopLock.lock()
        stopTask = nil
        stopLock.unlock()
    }

    private func performStop() async -> [MeetingChunk] {
        let resources = audioQueue.sync { () -> (SCStream?, AVAudioEngine?, AnyObject?) in
            guard lifecycle == .running || lifecycle == .starting else { return (nil, nil, nil) }
            lifecycle = .stopping
            let value = (stream, micEngine, systemTapObject)
            stream = nil; streamOutput = nil; streamDelegate = nil; micEngine = nil
            systemTapObject = nil
            return value
        }
        if let systemStream = resources.0 { await stopCapture(systemStream) }
        if #available(macOS 14.4, *) { (resources.2 as? CoreAudioSystemTap)?.stop() }
        if let mic = resources.1 {
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
        }
        return audioQueue.sync {
            // The barrier drains sample callbacks already queued before the
            // capture resources were detached. Mark inactive only afterwards
            // so the final frames are retained and flushed below.
            running = false
            lifecycle = .idle
            var result: [MeetingChunk] = []
            meAssembler?.flush { [weak self] speaker, samples, offset, duration, hasVoice in
                if let self, let chunk = self.writeChunk(speaker: speaker, samples: samples, offset: offset, duration: duration, voiceActivity: hasVoice) {
                    result.append(chunk)
                    self.onChunk?(chunk)
                }
            }
            othersAssembler?.flush { [weak self] speaker, samples, offset, duration, hasVoice in
                if let self, let chunk = self.writeChunk(speaker: speaker, samples: samples, offset: offset, duration: duration, voiceActivity: hasVoice) {
                    result.append(chunk)
                    self.onChunk?(chunk)
                }
            }
            meAssembler = nil; othersAssembler = nil
            activeOutputDirectory = nil
            lastLevelAt.removeAll(keepingCapacity: true)
            pendingLock.lock()
            pendingAudioBlocks = 0
            overloadReported = false
            pendingLock.unlock()
            return result
        }
    }

    fileprivate func receiveSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let payload = Self.samples(from: sampleBuffer) else { return }
        let samples = MeetingAudioMath.resample(payload.samples, fromRate: payload.sampleRate, toRate: sampleRate)
        let offset = max(0, ProcessInfo.processInfo.systemUptime - captureStartUptime)
        enqueue(samples: samples, channels: 1, speaker: .others, offset: offset)
    }

    @available(macOS 14.4, *)
    fileprivate func receiveSystemAudio(_ buffer: AVAudioPCMBuffer) {
        guard let payload = Self.samples(from: buffer) else { return }
        let mono = MeetingAudioMath.mono(payload, channels: Int(buffer.format.channelCount))
        let samples = MeetingAudioMath.resample(mono, fromRate: buffer.format.sampleRate, toRate: sampleRate)
        let offset = max(0, ProcessInfo.processInfo.systemUptime - captureStartUptime)
        enqueue(samples: samples, channels: 1, speaker: .others, offset: offset)
    }

    fileprivate func receiveMicrophone(_ samples: [Float], channels: Int) {
        let offset = max(0, ProcessInfo.processInfo.systemUptime - captureStartUptime)
        enqueue(samples: samples, channels: channels, speaker: .me, offset: offset)
    }

    private func enqueue(samples: [Float], channels: Int, speaker: MeetingSpeaker, offset: Double) {
        guard !samples.isEmpty else { return }
        pendingLock.lock()
        let accepted = pendingAudioBlocks < maxPendingAudioBlocks
        if accepted { pendingAudioBlocks += 1 }
        let reportOverload = !accepted && !overloadReported
        if reportOverload { overloadReported = true }
        pendingLock.unlock()
        guard accepted else {
            // A realtime producer must never silently discard audio. Stop and
            // flush the retained prefix, while making the overload explicit.
            if reportOverload {
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.stop()
                    self.onError?(.captureFailed("Audio processing backlog exceeded its limit"))
                }
            }
            return
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock()
                self.pendingAudioBlocks = max(0, self.pendingAudioBlocks - 1)
                self.pendingLock.unlock()
            }
            self.append(samples, channels: channels, speaker: speaker, offset: offset)
        }
    }

    fileprivate func receiveCaptureError(_ error: Error) {
        Task { [weak self] in
            guard let self else { return }
            let shouldStop = self.audioQueue.sync { self.lifecycle == .running }
            guard shouldStop else { return }
            _ = await self.stop()
            self.onError?(.captureFailed(error.localizedDescription))
        }
    }

    private func append(_ samples: [Float], channels: Int, speaker: MeetingSpeaker, offset: Double) {
        guard running else { return }
        let mono = MeetingAudioMath.mono(samples, channels: channels)
        reportLevel(speaker: speaker, samples: mono)
        let assembler = speaker == .me ? meAssembler : othersAssembler
        assembler?.append(mono, offset: offset) { [weak self] speaker, values, offset, duration, hasVoice in
            guard let self, let chunk = self.writeChunk(speaker: speaker, samples: values, offset: offset, duration: duration, voiceActivity: hasVoice) else { return }
            self.onChunk?(chunk)
        }
    }

    private func reportLevel(speaker: MeetingSpeaker, samples: [Float]) {
        guard let onLevels else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastLevelAt[speaker] ?? -.greatestFiniteMagnitude) >= 0.05 else { return }
        lastLevelAt[speaker] = now
        let rms = min(1, max(0, MeetingAudioMath.metrics(samples).rms))
        onLevels(speaker, rms)
    }

    private func writeChunk(speaker: MeetingSpeaker, samples: [Float], offset: Double, duration: Double,
                            voiceActivity: Bool) -> MeetingChunk? {
        let sequence = nextSequence
        let directory = activeOutputDirectory ?? outputDirectory
        let path = directory.appendingPathComponent(String(format: "chunk-%06d-%@.wav", sequence, speaker.rawValue))
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
            let file = try AVAudioFile(forWriting: path, settings: format.settings)
            try file.write(from: buffer)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            nextSequence += 1
            return MeetingChunk(sequence: sequence, speaker: speaker, path: path, offset: offset,
                                duration: duration, voiceActivity: voiceActivity)
        } catch {
            onError?(.captureFailed("Could not write \(speaker.rawValue) audio chunk"))
            return nil
        }
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0 else { return nil }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        var result: [Float] = []
        result.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount { result.append(channels[channel][frame]) }
        }
        return result
    }

    private static func samples(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        var listSize = 0
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &listSize,
                                                                       bufferListOut: nil, bufferListSize: 0,
                                                                       blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                       flags: 0, blockBufferOut: &blockBuffer) == noErr,
              listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
                                                                       bufferListOut: list, bufferListSize: listSize,
                                                                       blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                       flags: 0, blockBufferOut: &blockBuffer) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerSample = max(1, Int(asbd.mBitsPerChannel / 8))
        let interleaved = buffers.count == 1 && buffers[0].mNumberChannels > 1
        var result: [Float] = []
        if interleaved {
            let count = Int(buffers[0].mDataByteSize) / bytesPerSample
            result.reserveCapacity(count)
            guard let rawData = buffers[0].mData else { return nil }
            let data = rawData.assumingMemoryBound(to: UInt8.self)
            for index in stride(from: 0, to: count, by: channels) {
                var total: Float = 0
                for channel in 0..<channels {
                    total += Self.decodePCM(data.advanced(by: (index + channel) * bytesPerSample), asbd: asbd)
                }
                result.append(total / Float(channels))
            }
        } else {
            let count = buffers.reduce(0) { max($0, Int($1.mDataByteSize) / bytesPerSample) }
            result.reserveCapacity(count)
            for frame in 0..<count {
                var total: Float = 0
                var present = 0
                for audioBuffer in buffers {
                    let samples = Int(audioBuffer.mDataByteSize) / bytesPerSample
                    guard frame < samples, let data = audioBuffer.mData else { continue }
                    total += Self.decodePCM(data.assumingMemoryBound(to: UInt8.self).advanced(by: frame * bytesPerSample), asbd: asbd)
                    present += 1
                }
                if present > 0 { result.append(total / Float(present)) }
            }
        }
        guard asbd.mSampleRate > 0 else { return nil }
        return (result, asbd.mSampleRate)
    }

    private static func decodePCM(_ pointer: UnsafePointer<UInt8>, asbd: AudioStreamBasicDescription) -> Float {
        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            return pointer.withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
        }
        if asbd.mBitsPerChannel <= 16 {
            let value = pointer.withMemoryRebound(to: Int16.self, capacity: 1) { $0.pointee }
            return Float(value) / Float(Int16.max)
        }
        let value = pointer.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        return Float(value) / Float(Int32.max)
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func stopCapture(_ stream: SCStream) async {
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in continuation.resume() }
        }
    }
}
