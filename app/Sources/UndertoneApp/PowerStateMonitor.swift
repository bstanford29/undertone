import Foundation
import IOKit
import IOKit.ps

/// Watches AC vs battery and Low Power Mode. Cleanup is slower in either case,
/// so the pill and menu can say so without polling or shelling out to `pmset`.
@MainActor
final class PowerStateMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var slowerOnBattery = false

    private var runLoopSource: CFRunLoopSource?
    private var powerStateObserver: NSObjectProtocol?
    private var started = false

    nonisolated static func isSlower(onBattery: Bool, lowPowerMode: Bool) -> Bool {
        onBattery || lowPowerMode
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let created = IOPSNotificationCreateRunLoopSource(Self.powerSourceChanged, context) {
            let source = created.takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refresh()
                }
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
    }

    func refresh() {
        let next = Self.isSlower(onBattery: Self.isOnBattery(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard next != slowerOnBattery else { return }
        slowerOnBattery = next
        onChange?(next)
    }

    /// IOKit delivers this on an arbitrary thread. Hop to the main actor
    /// through the queue that owns AppKit, then refresh.
    private static let powerSourceChanged: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let unmanaged = Unmanaged<PowerStateMonitor>.fromOpaque(context)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                unmanaged.takeUnretainedValue().refresh()
            }
        }
    }

    nonisolated private static func isOnBattery() -> Bool {
        guard let created = IOPSCopyPowerSourcesInfo() else { return false }
        let blob = created.takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == (kIOPMBatteryPowerKey as String)
    }
}
