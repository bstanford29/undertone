import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Errors reported while constructing the macOS 14.4+ system-audio tap.
///
/// Core Audio exposes status codes rather than user-facing permission state.
/// Keep those codes private and let the recorder surface a stable capture
/// error to the UI.
@available(macOS 14.4, *)
enum CoreAudioSystemTapError: LocalizedError, Equatable {
    case alreadyRunning
    case processUnavailable(OSStatus)
    case audioFormatUnavailable
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "System audio capture is already running"
        case .processUnavailable: return "The current process could not be excluded from system audio capture"
        case .audioFormatUnavailable: return "The system audio format is unavailable"
        case .operationFailed: return "System audio capture could not be started"
        }
    }

    /// A bounded diagnostic retained for local error handling. It contains
    /// only the static operation name and Core Audio status, never audio or
    /// user content.
    var diagnosticDescription: String {
        switch self {
        case .alreadyRunning: return "system tap already running"
        case .processUnavailable(let status): return "translate process object (OSStatus \(status))"
        case .audioFormatUnavailable: return "system tap audio format unavailable"
        case .operationFailed(let operation, let status): return "\(operation) (OSStatus \(status))"
        }
    }
}

/// A private aggregate device backed by a Core Audio process tap.
///
/// AVAudioEngine owns the consumer callback and converts the aggregate's
/// native format into an AVAudioPCMBuffer. The tap is process-scoped so the
/// app's own microphone and UI sounds are excluded from the system stream.
@available(macOS 14.4, *)
final class CoreAudioSystemTap {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    var onBuffer: BufferHandler?

    private var engine: AVAudioEngine?
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var running = false

    deinit { stop() }

    func start() throws {
        guard !running else { throw CoreAudioSystemTapError.alreadyRunning }

        do {
            let tap = CATapDescription()
            let process = try currentProcessObjectID()
            tap.processes = [process]
            tap.isExclusive = true
            tap.isMixdown = true
            tap.isMono = false
            tap.isPrivate = true
            tap.muteBehavior = .unmuted

            var createdTap = kAudioObjectUnknown
            let tapStatus = AudioHardwareCreateProcessTap(tap, &createdTap)
            guard tapStatus == noErr else {
                throw CoreAudioSystemTapError.operationFailed(operation: "create process tap", status: tapStatus)
            }
            tapID = createdTap

            let uid = try tapUID(createdTap)
            let aggregateUID = "com.undertone.meeting.tap.\(UUID().uuidString)"
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Undertone Meeting Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            var createdAggregate = kAudioObjectUnknown
            let aggregateStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdAggregate)
            guard aggregateStatus == noErr else {
                throw CoreAudioSystemTapError.operationFailed(operation: "create aggregate device", status: aggregateStatus)
            }
            aggregateID = createdAggregate
            try setTapList(uid: uid, aggregate: createdAggregate)

            let audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            guard let audioUnit = input.audioUnit else {
                throw CoreAudioSystemTapError.audioFormatUnavailable
            }
            var device = createdAggregate
            let deviceStatus = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                                    kAudioUnitScope_Global, 0, &device,
                                                    UInt32(MemoryLayout<AudioObjectID>.size))
            guard deviceStatus == noErr else {
                throw CoreAudioSystemTapError.operationFailed(operation: "route aggregate input", status: deviceStatus)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CoreAudioSystemTapError.audioFormatUnavailable
            }
            // Retain the partially configured engine before installing the
            // tap so every failure path can remove it during stop().
            engine = audioEngine
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.onBuffer?(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            running = true
        } catch {
            stop()
            if let error = error as? CoreAudioSystemTapError { throw error }
            let status = (error as NSError).code
            throw CoreAudioSystemTapError.operationFailed(operation: "start audio engine", status: OSStatus(status))
        }
    }

    func stop() {
        if let audioEngine = engine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
        }
        engine = nil
        running = false

        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func currentProcessObjectID() throws -> AudioObjectID {
        var pid = getpid()
        var process = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &pid) { qualifier in
            withUnsafeMutablePointer(to: &process) { result in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                           UInt32(MemoryLayout<pid_t>.size), qualifier,
                                           &size, result)
            }
        }
        guard status == noErr, process != kAudioObjectUnknown else {
            throw CoreAudioSystemTapError.processUnavailable(status)
        }
        return process
    }

    private func tapUID(_ tap: AudioObjectID) throws -> String {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) { result in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, result)
        }
        guard status == noErr else {
            throw CoreAudioSystemTapError.operationFailed(operation: "read process tap UID", status: status)
        }
        return value as String
    }

    private func setTapList(uid: String, aggregate: AudioObjectID) throws {
        var list: CFArray = [uid as CFString] as CFArray
        let size = UInt32(MemoryLayout<CFArray>.stride)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &list) { value in
            AudioObjectSetPropertyData(aggregate, &address, 0, nil, size, value)
        }
        guard status == noErr else {
            throw CoreAudioSystemTapError.operationFailed(operation: "attach process tap", status: status)
        }
    }
}
