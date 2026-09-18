import AppKit
import CoreAudio
import Foundation
import os

/// One process that Core Audio currently knows about, with the two running
/// flags the HAL publishes. `bundleID` is nil for processes that have no
/// bundle, such as a command line tool.
struct MicOwner: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool

    init(pid: pid_t, bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Watches which process holds the microphone.
///
/// The query is the public HAL process object list (macOS 14.2+), so it needs
/// no new permission and raises no prompt. Two things drive a new sample:
///
/// 1. A property listener on the default input device's
///    `kAudioDevicePropertyDeviceIsRunningSomewhere`. Per process
///    `kAudioProcessPropertyIsRunningInput` listeners register but never fire
///    on macOS 26, so the device flag is the trigger and the per process flags
///    are read inside the callback.
/// 2. A 2 s poll, gated on a known call app being in the running app list.
///    That covers systems where the device listener misbehaves.
///
/// Samples are published at most once every 250 ms, and only when the owner
/// list actually changed.
@MainActor
final class MicOwnerWatcher {
    /// Shortest gap between two published samples.
    static let debounceInterval: TimeInterval = 0.25
    /// Fallback poll period while a known call app is running.
    static let pollInterval: TimeInterval = 2

    var onChange: (([MicOwner]) -> Void)?
    private(set) var owners: [MicOwner] = []

    private let ownPID: pid_t
    private var started = false
    private var pollTimer: Timer?
    private var lastPublishedAt = Date.distantPast
    private var pendingSample: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listeningDevice = AudioObjectID(kAudioObjectUnknown)
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private static let log = Logger(subsystem: "com.undertone.app", category: "meeting")

    init(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
    }

    deinit {
        // Listener removal needs the main actor; stop() is called by owners.
    }

    // MARK: Lifecycle

    func start() {
        guard !started, Self.isSupported else { return }
        started = true
        addDefaultDeviceListener()
        addDeviceListener(for: Self.defaultInputDevice())
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pollTick() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        sampleNow()
    }

    func stop() {
        guard started else { return }
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        pendingSample?.cancel()
        pendingSample = nil
        removeDeviceListener()
        removeDefaultDeviceListener()
        guard !owners.isEmpty else { return }
        owners = []
        onChange?([])
    }

    /// Reads the owner list right now and publishes it if it changed. Skips
    /// the debounce, so callers that need a fresh answer can ask for one.
    func refreshNow() {
        sampleNow()
    }

    // MARK: Selection (pure)

    /// The processes that could be a call: input is running, the process is
    /// not us, the bundle is not a system daemon, and the bundle maps to a
    /// native call app or to a browser that can host one.
    ///
    /// Native apps sort before browsers, then by pid, so repeated reads of the
    /// same machine state give the same answer.
    nonisolated static func callCandidates(owners: [MicOwner], ownPID: pid_t) -> [MicOwner] {
        owners
            .filter { owner in
                guard owner.isRunningInput, owner.pid != ownPID else { return false }
                guard let bundleID = owner.bundleID, !bundleID.isEmpty else { return false }
                guard !MeetingPlatform.ignoredMicOwnerBundleIDs.contains(bundleID) else { return false }
                return MeetingPlatform.nativeBundleIDs[bundleID] != nil
                    || MeetingPlatform.browserBundleIDs.contains(bundleID)
            }
            .sorted { first, second in
                let firstNative = MeetingPlatform.nativeBundleIDs[first.bundleID ?? ""] != nil
                let secondNative = MeetingPlatform.nativeBundleIDs[second.bundleID ?? ""] != nil
                if firstNative != secondNative { return firstNative }
                return first.pid < second.pid
            }
    }

    /// The single best call candidate, or nil when nothing on the machine
    /// holding the mic looks like a call.
    nonisolated static func callOwner(owners: [MicOwner], ownPID: pid_t) -> MicOwner? {
        callCandidates(owners: owners, ownPID: ownPID).first
    }

    /// True when at least one running app could host a call. The poll only
    /// touches Core Audio when this is true.
    nonisolated static func knownCallAppIsRunning(bundleIDs: [String]) -> Bool {
        bundleIDs.contains { bundleID in
            MeetingPlatform.nativeBundleIDs[bundleID] != nil
                || MeetingPlatform.browserBundleIDs.contains(bundleID)
        }
    }

    static func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    // MARK: Core Audio query

    /// True when this system publishes the process object list.
    nonisolated static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// One pass over the Core Audio process objects. Our own process is left
    /// out, so no caller has to remember to filter it.
    nonisolated static func readOwners(excluding ownPID: pid_t) -> [MicOwner] {
        guard isSupported else { return [] }
        var result: [MicOwner] = []
        for object in processObjectIDs() {
            guard let pid = processPID(object), pid != ownPID else { continue }
            result.append(MicOwner(
                pid: pid,
                bundleID: processBundleID(object),
                isRunningInput: processFlag(object, selector: kAudioProcessPropertyIsRunningInput),
                isRunningOutput: processFlag(object, selector: kAudioProcessPropertyIsRunningOutput)
            ))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    nonisolated static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    nonisolated static func processPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, value > 0 else {
            return nil
        }
        return value
    }

    nonisolated static func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let bundleID = value as String
        return bundleID.isEmpty ? nil : bundleID
    }

    nonisolated static func processFlag(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    nonisolated static func defaultInputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return device
    }

    // MARK: Sampling

    private func pollTick() {
        guard started else { return }
        guard Self.knownCallAppIsRunning(bundleIDs: Self.runningBundleIDs()) else { return }
        scheduleSample()
    }

    /// Publishes at most once every `debounceInterval`. A burst of Core Audio
    /// callbacks collapses into one trailing sample.
    private func scheduleSample() {
        let elapsed = Date().timeIntervalSince(lastPublishedAt)
        guard elapsed < Self.debounceInterval else {
            sampleNow()
            return
        }
        guard pendingSample == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSample = nil
                self.sampleNow()
            }
        }
        pendingSample = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.debounceInterval - elapsed), execute: item)
    }

    private func sampleNow() {
        lastPublishedAt = Date()
        let next = Self.readOwners(excluding: ownPID)
        guard next != owners else { return }
        owners = next
        onChange?(next)
    }

    // MARK: Listeners

    private func addDeviceListener(for device: AudioObjectID) {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleSample() }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        guard status == noErr else {
            Self.log.error("mic owner device listener failed status=\(status, privacy: .public)")
            return
        }
        deviceListener = block
        listeningDevice = device
    }

    private func removeDeviceListener() {
        guard let block = deviceListener, listeningDevice != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(listeningDevice, &address, DispatchQueue.main, block)
        deviceListener = nil
        listeningDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func addDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    self.removeDeviceListener()
                    self.addDeviceListener(for: Self.defaultInputDevice())
                    self.scheduleSample()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                         &address, DispatchQueue.main, block)
        guard status == noErr else {
            Self.log.error("default input listener failed status=\(status, privacy: .public)")
            return
        }
        defaultDeviceListener = block
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, DispatchQueue.main, block)
        defaultDeviceListener = nil
    }
}
