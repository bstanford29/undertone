import AVFoundation
import AVFAudio
import Foundation
import os

/// Records one dictation to a WAV file.
///
/// Each recording gets a fresh `AVAudioEngine`. An engine reused across
/// recordings can keep the input format it read before the default
/// microphone changed (AirPods connecting, the lid closing, a dock), and
/// `installTap` then raises an Objective-C exception that Swift cannot catch,
/// so the app quits.
final class AudioRecorder: @unchecked Sendable {
    /// Engine starts allowed within one recording after the first, counting
    /// retries, before the recorder stops following the input and keeps what
    /// it has. A Bluetooth headset can change format more than once, and
    /// report no input for a moment, while it switches profiles.
    static let maxInputRestarts = 8
    /// Wait before trying again when the new input has no format yet.
    static let inputRetryDelay = 0.25

    private static let log = Logger(subsystem: "com.undertone.app", category: "recorder")

    // Main-queue state.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    /// Bumped for every engine started, so a late change notice from an
    /// engine that is already gone cannot restart the current one.
    private var engineGeneration: UInt64 = 0
    /// Bumped for every recording, so a queued retry or a converter failure
    /// from an earlier recording cannot touch the current one.
    private var recordingID: UInt64 = 0
    private var inputRestarts = 0
    private var inputGivenUp = false
    private(set) var currentURL: URL?
    private var recordingSampleRate: Double = 0
    /// Frames written / sample rate for the most recently stopped recording.
    private(set) var lastRecordedSeconds: Double = 0
    var levelHandler: ((Double) -> Void)?
    var errorHandler: ((Error) -> Void)?
    /// Called on the main queue when the microphone changed mid-recording
    /// and no input could take over. Capture has stopped; the audio from
    /// before the change stays in the file and `stop()` still returns it.
    var inputLostHandler: (() -> Void)?
    var whisperMode = false

    // Tap-thread state, guarded by `writeLock`.
    private let writeLock = NSLock()
    private var file: AVAudioFile?
    private var recordingFailed = false
    private var framesWritten: UInt64 = 0
    /// Set while a replacement microphone delivers a format other than the
    /// file's.
    private var converter: InputConverter?
    /// The replacement microphone's format cannot be converted to the file's.
    private var conversionFailed = false

    /// Receives mono samples at `LiveDictationFeeder.sampleRate` in frames of
    /// `LiveDictationFeeder.frameSamples`, on the audio thread, while a
    /// recording runs. Set it before `start()`. `stop()` flushes the last
    /// partial frame through it and then clears it.
    var sampleHandler: (@Sendable ([Float]) -> Void)? {
        get { liveLock.lock(); defer { liveLock.unlock() }; return liveHandler }
        set { liveLock.lock(); liveHandler = newValue; liveLock.unlock() }
    }
    private let liveLock = NSLock()
    private var liveHandler: (@Sendable ([Float]) -> Void)?
    private var liveResampler: StreamingResampler?
    private var liveFrames = LiveFrameAssembler(frameSamples: LiveDictationFeeder.frameSamples)

    /// A format a recording can be opened with. With no input device, or
    /// mid-switch, the input reports 0 Hz or 0 channels, and tapping that
    /// raises an exception.
    static func isUsableInput(sampleRate: Double, channels: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channels > 0
    }

    func start() throws -> URL {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw RecorderError.microphonePermission }
        let directory = URL(fileURLWithPath: NSString(string: "~/.undertone/audio").expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let audioEngine = AVAudioEngine()
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        guard Self.isUsableInput(sampleRate: format.sampleRate, channels: format.channelCount) else {
            throw RecorderError.noInputDevice
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let newFile = try AVAudioFile(forWriting: url, settings: format.settings)
        writeLock.lock()
        file = newFile
        recordingFailed = false
        framesWritten = 0
        converter = nil
        conversionFailed = false
        writeLock.unlock()
        recordingSampleRate = newFile.processingFormat.sampleRate
        recordingID &+= 1
        inputRestarts = 0
        inputGivenUp = false
        liveLock.lock()
        liveResampler = liveHandler == nil
            ? nil
            : StreamingResampler(fromRate: recordingSampleRate, toRate: LiveDictationFeeder.sampleRate)
        liveFrames = LiveFrameAssembler(frameSamples: LiveDictationFeeder.frameSamples)
        liveLock.unlock()
        do { try run(audioEngine) }
        catch {
            writeLock.lock(); file = nil; writeLock.unlock()
            throw error
        }
        currentURL = url
        return url
    }

    func stop() -> URL? {
        guard currentURL != nil else { return nil }
        stopEngine()
        writeLock.lock()
        file = nil
        converter = nil
        let failed = recordingFailed
        let frames = framesWritten
        writeLock.unlock()
        flushLiveSamples()
        lastRecordedSeconds = recordingSampleRate > 0 ? Double(frames) / recordingSampleRate : 0
        let result = failed ? nil : currentURL
        currentURL = nil
        return result
    }

    /// Taps the engine's input and starts it. The tap asks for no format, so
    /// it takes the bus's format at install time rather than one read a
    /// moment earlier; `receive` converts anything that differs from the file.
    private func run(_ audioEngine: AVAudioEngine) throws {
        let input = audioEngine.inputNode
        let recording = recordingID
        try Self.installTap(on: input) { [weak self] buffer, _ in
            self?.receive(buffer, recording: recording)
        }
        engineGeneration &+= 1
        let generation = engineGeneration
        // Posted on an engine thread. Calling back into the engine from
        // there can deadlock, so the restart runs on the main queue.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.inputChanged(generation: generation) }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw error
        }
        engine = audioEngine
        configurationObserver = observer
    }

    /// On macOS 27 and later, a format that is no longer valid when the tap
    /// installs (the input switched after the check) throws a Swift error.
    /// Earlier systems raise an Objective-C exception instead, so the check
    /// before each start remains the only guard there.
    private static func installTap(on input: AVAudioInputNode, block: @escaping AVAudioNodeTapBlock) throws {
        if #available(macOS 27, *) {
            try input.__installTap(onBus: 0, bufferSize: 1024, format: nil, error: (), block: block)
        } else {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: block)
        }
    }

    private func stopEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// The engine stops itself when the input's sample rate or channel count
    /// changes. Start a fresh engine on whatever input is now the default and
    /// keep writing to the same file.
    private func inputChanged(generation: UInt64) {
        guard currentURL != nil, engine != nil, generation == engineGeneration else { return }
        stopEngine()
        restartInput(recording: recordingID)
    }

    /// Starts a fresh engine on the current default input. An input with no
    /// format yet, or one that fails to start, gets another try shortly; a
    /// headset switching profiles can report no input for a moment. Every
    /// try counts toward `maxInputRestarts`, and past it the recorder keeps
    /// what it has.
    private func restartInput(recording: UInt64) {
        guard recording == recordingID, currentURL != nil, engine == nil, !inputGivenUp else { return }
        inputRestarts += 1
        guard inputRestarts <= Self.maxInputRestarts else {
            inputLost(RecorderError.inputUnstable, recording: recording)
            return
        }
        let replacement = AVAudioEngine()
        let format = replacement.inputNode.outputFormat(forBus: 0)
        Self.log.notice("input changed mid-recording: \(Int(format.sampleRate), privacy: .public) Hz \(format.channelCount, privacy: .public) ch, attempt \(self.inputRestarts, privacy: .public)")
        do {
            guard Self.isUsableInput(sampleRate: format.sampleRate, channels: format.channelCount) else {
                throw RecorderError.noInputDevice
            }
            try run(replacement)
        } catch {
            Self.log.notice("input not ready, retrying: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputRetryDelay) { [weak self] in
                self?.restartInput(recording: recording)
            }
        }
    }

    /// Stops following the input for this recording, keeps the file, and
    /// tells the owner once.
    private func inputLost(_ error: Error, recording: UInt64) {
        guard recording == recordingID, currentURL != nil, !inputGivenUp else { return }
        inputGivenUp = true
        stopEngine()
        Self.log.error("input lost mid-recording: \(error.localizedDescription, privacy: .public)")
        inputLostHandler?()
    }

    /// Runs on the tap thread for every buffer the input delivers.
    private func receive(_ tapBuffer: AVAudioPCMBuffer, recording: UInt64) {
        writeLock.lock()
        guard let file, !recordingFailed, !conversionFailed else {
            writeLock.unlock()
            return
        }
        let buffer: AVAudioPCMBuffer
        if tapBuffer.format == file.processingFormat {
            buffer = tapBuffer
        } else {
            if converter?.inputFormat != tapBuffer.format {
                converter = InputConverter(from: tapBuffer.format, to: file.processingFormat)
            }
            let converted: AVAudioPCMBuffer?
            do {
                guard let converter else { throw RecorderError.unsupportedFormat }
                converted = try converter.convert(tapBuffer)
            } catch {
                // Without a working converter every later buffer would be
                // dropped in silence. Stop and finish with what was recorded.
                conversionFailed = true
                let from = tapBuffer.format.description
                let to = file.processingFormat.description
                writeLock.unlock()
                Self.log.error("cannot convert \(from, privacy: .public) to \(to, privacy: .public): \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.inputLost(RecorderError.unsupportedFormat, recording: recording)
                }
                return
            }
            guard let converted else {
                writeLock.unlock()
                return
            }
            buffer = converted
        }
        if whisperMode { Self.applyGain(to: buffer, multiplier: 1.8) }
        do {
            try file.write(from: buffer)
            framesWritten += UInt64(buffer.frameLength)
        } catch {
            recordingFailed = true
            writeLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.errorHandler?(error) }
            return
        }
        writeLock.unlock()
        forwardLiveSamples(buffer)
        let rms = Self.rms(buffer)
        DispatchQueue.main.async { [weak self] in self?.levelHandler?(rms) }
    }

    /// Resamples the tap buffer to the engine rate and hands over every full
    /// frame. Runs on the audio thread, so it holds the lock only around the
    /// resampler state and calls the handler outside it.
    private func forwardLiveSamples(_ buffer: AVAudioPCMBuffer) {
        liveLock.lock()
        guard let handler = liveHandler, var resampler = liveResampler, let mono = Self.mono(buffer) else {
            liveLock.unlock()
            return
        }
        let converted = resampler.process(mono)
        liveResampler = resampler
        let frames = liveFrames.append(converted)
        liveLock.unlock()
        for frame in frames { handler(frame) }
    }

    private func flushLiveSamples() {
        liveLock.lock()
        let handler = liveHandler
        let rest = liveResampler == nil ? nil : liveFrames.flush()
        liveResampler = nil
        liveHandler = nil
        liveLock.unlock()
        if let handler, let rest { handler(rest) }
    }

    /// The buffer mixed down to one channel. Nil for non-float formats.
    static func mono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var result = [Float](repeating: 0, count: frames)
        if buffer.format.isInterleaved {
            let data = channels[0]
            for index in 0..<frames {
                var total: Float = 0
                for channel in 0..<channelCount { total += data[index * channelCount + channel] }
                result[index] = total / Float(channelCount)
            }
        } else {
            for channel in 0..<channelCount {
                let data = channels[channel]
                for index in 0..<frames { result[index] += data[index] }
            }
            let scale = 1 / Float(channelCount)
            for index in 0..<frames { result[index] *= scale }
        }
        return result
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum = Float.zero
        for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
        return min(1, Double(sqrt(sum / Float(buffer.frameLength)) * 4))
    }

    private static func applyGain(to buffer: AVAudioPCMBuffer, multiplier: Float) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<Int(buffer.frameLength) {
                channels[channel][index] = max(-1, min(1, channels[channel][index] * multiplier))
            }
        }
    }
}

/// Converts tap buffers from a replacement microphone into the format the
/// recording file was opened with, so one file holds the whole dictation.
/// It keeps its sample-rate state between buffers, so the joins stay
/// continuous. Extra channels are mixed down, not dropped.
final class InputConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        converter.downmix = true
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    struct ConversionFailed: Error {}

    /// The buffer in `outputFormat`, or nil when there is nothing to write
    /// yet: an empty buffer, or the first call after a rate change while the
    /// converter fills its filter. Throws when the conversion fails, so the
    /// caller can stop instead of dropping audio in silence.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard inputFormat.sampleRate > 0 else { throw ConversionFailed() }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionFailed()
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { throw error ?? ConversionFailed() }
        return output.frameLength > 0 ? output : nil
    }
}

enum RecorderError: LocalizedError {
    case microphonePermission
    case noInputDevice
    case inputUnstable
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "Microphone permission is required"
        case .noInputDevice: "no input device found"
        case .inputUnstable: "the input kept changing"
        case .unsupportedFormat: "the new input's format cannot be converted"
        }
    }
}
