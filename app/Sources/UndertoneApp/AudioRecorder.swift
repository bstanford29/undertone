import AVFoundation
import AVFAudio
import Foundation

final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var recordingFailed = false
    private(set) var currentURL: URL?
    private var framesWritten: UInt64 = 0
    private var recordingSampleRate: Double = 0
    /// Frames written / sample rate for the most recently stopped recording.
    private(set) var lastRecordedSeconds: Double = 0
    var levelHandler: ((Double) -> Void)?
    var errorHandler: ((Error) -> Void)?
    var whisperMode = false

    func start() throws -> URL {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw RecorderError.microphonePermission }
        let directory = URL(fileURLWithPath: NSString(string: "~/.undertone/audio").expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        do { file = try AVAudioFile(forWriting: url, settings: format.settings) }
        catch { currentURL = nil; throw error }
        recordingFailed = false
        framesWritten = 0
        recordingSampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            if let self, self.whisperMode { Self.applyGain(to: buffer, multiplier: 1.8) }
            do { try self?.file?.write(from: buffer) }
            catch {
                guard let self, !self.recordingFailed else { return }
                self.recordingFailed = true
                DispatchQueue.main.async { self.errorHandler?(error) }
                return
            }
            self?.framesWritten += UInt64(buffer.frameLength)
            let rms = Self.rms(buffer)
            DispatchQueue.main.async { self?.levelHandler?(rms) }
        }
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); file = nil; currentURL = nil; throw error }
        currentURL = url
        return url
    }

    func stop() -> URL? {
        guard currentURL != nil else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        lastRecordedSeconds = recordingSampleRate > 0 ? Double(framesWritten) / recordingSampleRate : 0
        let result = recordingFailed ? nil : currentURL
        currentURL = nil
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

enum RecorderError: LocalizedError {
    case microphonePermission
    var errorDescription: String? { "Microphone permission is required" }
}
