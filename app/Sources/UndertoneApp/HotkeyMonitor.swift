import AppKit
import CoreGraphics
import Foundation
import ApplicationServices
import os

struct HotkeyStateMachine {
    enum PressAction: Equatable { case start, stop, none }
    enum ReleaseAction: Equatable { case stopImmediately, stopAfterDelay, none }

    private(set) var locked = false
    private var lastDown: TimeInterval?
    private var pressStartedAt: TimeInterval?
    private var awaitingDelayedStop = false
    private var suppressNextRelease = false
    let doubleTapWindow: TimeInterval = 0.35

    mutating func press(at now: TimeInterval) -> PressAction {
        awaitingDelayedStop = false
        if locked {
            // Any press while locked is a deliberate tap to stop, no matter
            // how long ago the lock formed. `lastDown` is cleared so a
            // second press inside the double-tap window right after does
            // not read as the second tap of a new lock.
            locked = false
            suppressNextRelease = true
            lastDown = nil
            return .stop
        }
        let isDoubleTap = lastDown.map { now - $0 < doubleTapWindow } ?? false
        lastDown = now
        if isDoubleTap {
            locked = true
            return .none
        }
        pressStartedAt = now
        return .start
    }

    mutating func release(at now: TimeInterval) -> ReleaseAction {
        if suppressNextRelease {
            suppressNextRelease = false
            return .none
        }
        guard !locked else { return .none }
        guard let started = pressStartedAt else { return .none }
        pressStartedAt = nil
        if now - started >= doubleTapWindow {
            lastDown = nil
            return .stopImmediately
        }
        awaitingDelayedStop = true
        return .stopAfterDelay
    }

    mutating func delayedStop() -> Bool {
        guard awaitingDelayedStop, !locked else { return false }
        awaitingDelayedStop = false
        lastDown = nil
        return true
    }

    /// Stops a locked recording from a source other than the hold key, for
    /// example Escape. Clears `lastDown` so a hold-key press within the
    /// double-tap window right after does not read as the second tap of a
    /// new lock.
    mutating func stopIfLocked() -> Bool {
        guard locked else { return false }
        locked = false
        lastDown = nil
        pressStartedAt = nil
        awaitingDelayedStop = false
        return true
    }

    /// A click on the dock's Dictate control. It behaves as one tap of the
    /// hold key in lock mode: the first click latches recording on, the next
    /// one stops it.
    mutating func clickToggle() -> PressAction {
        pendingReset()
        if locked {
            locked = false
            return .stop
        }
        locked = true
        return .start
    }

    private mutating func pendingReset() {
        lastDown = nil
        pressStartedAt = nil
        awaitingDelayedStop = false
        suppressNextRelease = false
    }

    mutating func reset() {
        locked = false
        pendingReset()
    }
}

/// A chord seen by the global shortcut tap, kept for on-screen diagnostics.
struct ShortcutSighting: Equatable {
    let chordName: String
    let date: Date
}

final class HotkeyMonitor: @unchecked Sendable {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onShortcut: ((Character) -> Void)?
    /// The Option-only chords: ⌥M for meeting notes, ⌥S for Quick note.
    var onOptionShortcut: ((Character) -> Void)?
    /// Fired on the main thread whenever lock mode engages or disengages.
    var onLockChange: ((Bool) -> Void)?
    /// Fired on the main thread whenever `tapActive` or `lastShortcutSeen` changes.
    var onDiagnosticsChange: ((Bool, ShortcutSighting?) -> Void)?
    /// Fired on the main thread on the physical up transition of the hold
    /// key (fn `flagsChanged` up, or F13 `keyUp`), regardless of lock state.
    var onHoldKeyReleased: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed = false
    private var state = HotkeyStateMachine()
    private var pendingRelease: DispatchWorkItem?
    private var consumedKeys = Set<Int64>()
    private(set) var isRunning = false
    /// Diagnostic label for the tap location the running tap was created
    /// at. Always "session" (`.cgSessionEventTap`), shown in Settings next
    /// to the shortcut status line.
    private(set) var tapLevel = "session"
    private static let logger = Logger(subsystem: "com.undertone.app", category: "hotkey")
    private static let tapLogRingLimit = 50
    private var tapLogLines: [String] = []
    /// The in-memory ring buffer of the last `tapLogRingLimit` tap log
    /// lines, newest last, for the Settings "Copy tap log" action.
    var tapLogText: String { tapLogLines.joined(separator: "\n") }
    /// Raw `CGEventType` value for `NX_SYSDEFINED` (media/aux keys, and
    /// reportedly the globe/fn key's default action). Not represented as a
    /// named `CGEventType` case in the public CoreGraphics headers. Kept in
    /// the tap's mask for diagnostic logging only; these events are never
    /// swallowed.
    static let systemDefinedEventType: UInt32 = 14
    private(set) var tapActive = false {
        didSet {
            guard tapActive != oldValue else { return }
            onDiagnosticsChange?(tapActive, lastShortcutSeen)
        }
    }
    private(set) var lastShortcutSeen: ShortcutSighting? {
        didSet { onDiagnosticsChange?(tapActive, lastShortcutSeen) }
    }
    /// Whether the hold key is currently latched into lock mode.
    var isLocked: Bool { state.locked }
    /// Whether the physical hold key (fn or F13) is currently held down,
    /// independent of `HotkeyStateMachine` state. True from the down
    /// transition until the matching up transition.
    private(set) var holdKeyIsDown = false

    /// The tap's C callback. Captures nothing: all state comes through
    /// `refcon`, so this is safe to hand to `CGEvent.tapCreate` as a C
    /// function pointer. Never swallows an fn `flagsChanged` or a
    /// systemDefined event: see `shouldConsumeAtTap`'s doc comment for why.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.tapActive = false
            if let tap = monitor.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                monitor.tapActive = CGEvent.tapIsEnabled(tap: tap)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type.rawValue == HotkeyMonitor.systemDefinedEventType {
            // Diagnostics only: decode what we can and always pass through.
            let nsEvent = NSEvent(cgEvent: event)
            let subtype = nsEvent?.subtype.rawValue
            let data1 = nsEvent?.data1
            monitor.logTapEvent(typeRaw: type.rawValue, keyCode: keyCode, flagsRaw: flags.rawValue,
                                subtype: subtype, data1: data1, consumed: false)
            return Unmanaged.passUnretained(event)
        }

        if monitor.consumeShortcutFromTap(type: type, keyCode: keyCode, flags: flags,
                                          autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            return nil
        }
        let consumeAtTap = HotkeyMonitor.shouldConsumeAtTap(type: type, keyCode: keyCode)
        if type == .flagsChanged && keyCode == 63 {
            monitor.logTapEvent(typeRaw: type.rawValue, keyCode: keyCode, flagsRaw: flags.rawValue,
                                subtype: nil, data1: nil, consumed: consumeAtTap)
        }
        // Accessibility and audio work can block for a noticeable interval;
        // keep the event-tap callback limited to consume/pass decisions.
        DispatchQueue.main.async { [weak monitor] in monitor?.handle(type: type, keyCode: keyCode, flags: flags) }
        return consumeAtTap ? nil : Unmanaged.passUnretained(event)
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else {
            tapActive = false
            return false
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << HotkeyMonitor.systemDefinedEventType)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: HotkeyMonitor.tapCallback, userInfo: context)
        tapLevel = "session"
        guard let tap else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
            return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        tapActive = CGEvent.tapIsEnabled(tap: tap)
        return true
    }

    func stop() {
        pendingRelease?.cancel(); pendingRelease = nil
        state.reset()
        consumedKeys.removeAll()
        pressed = false
        holdKeyIsDown = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil; tap = nil
        isRunning = false
        tapActive = false
    }

    /// The chord's option+shift key must be down and command/control must be up.
    /// Caps lock (`maskAlphaShift`), the numeric pad flag, the non-coalesced
    /// flag, and a held `fn` (`maskSecondaryFn`) never block a match: they can
    /// be set alongside a genuine option-shift chord and are not part of it.
    static func shortcut(for keyCode: Int64, flags: CGEventFlags, autorepeat: Bool) -> Character? {
        guard flags.contains(.maskAlternate), flags.contains(.maskShift),
              !flags.contains(.maskCommand), !flags.contains(.maskControl), !autorepeat else { return nil }
        switch keyCode {
        case 9: return "v"
        case 6: return "z"
        case 8: return "c"
        case 46: return "m"
        default: return nil
        }
    }

    /// Option alone, with no other modifier. ⌥M starts or stops meeting
    /// notes; ⌥S opens or closes the Quick note panel. Shift must be up, or
    /// the existing ⌥⇧M chord would match both.
    static func optionShortcut(for keyCode: Int64, flags: CGEventFlags, autorepeat: Bool) -> Character? {
        guard flags.contains(.maskAlternate), !flags.contains(.maskShift),
              !flags.contains(.maskCommand), !flags.contains(.maskControl), !autorepeat else { return nil }
        switch keyCode {
        case 46: return "m"
        case 1: return "s"
        default: return nil
        }
    }

    /// Every global chord Undertone claims, for the Permissions list. One
    /// source, so the screen cannot drift from the tap.
    static let chordRoster: [(chord: String, action: String)] = [
        ("⌥⇧V", "Insert last transcript again"),
        ("⌥⇧Z", "Undo AI edit, keep raw"),
        ("⌥⇧C", "Copy last transcript"),
        ("⌥⇧M", "Open Meetings"),
        ("⌥M", "Start or stop meeting notes"),
        ("⌥S", "Quick note"),
    ]

    private static func chordName(for character: Character) -> String {
        "⌥⇧\(String(character).uppercased())"
    }

    private static func optionChordName(for character: Character) -> String {
        "⌥\(String(character).uppercased())"
    }

    /// Whether the tap must swallow this event. Always false.
    ///
    /// This used to swallow fn `flagsChanged` (key code 63, both directions)
    /// so macOS would never see a bare fn tap and run its own default action
    /// (typically the Emoji & Symbols picker). That did not work: dropping
    /// the event at the tap removes it from the stream this process's own
    /// callback chain sees, but it does not retract fn from the system's own
    /// modifier tracking. A lock-mode stop tap still leaves the OS believing
    /// fn is held right up until, or past, the point Undertone starts typing
    /// the dictated text. The very next letter then reads as globe+key (for
    /// example globe+E opens Emoji & Symbols), and the rest of the dictation
    /// lands in its search field, exactly the failure this was meant to
    /// prevent. `InsertionController` now clears a stuck fn flag itself
    /// right before typing, which is where a fix for this actually belongs.
    static func shouldConsumeAtTap(type: CGEventType, keyCode: Int64) -> Bool {
        false
    }

    /// Appends a line to the in-memory tap log (capped at
    /// `tapLogRingLimit`) and emits it through `os.Logger`. Called only from
    /// the tap callback, which runs on the main run loop, so no locking is
    /// needed around `tapLogLines`.
    fileprivate func logTapEvent(typeRaw: UInt32, keyCode: Int64, flagsRaw: UInt64,
                                  subtype: Int16?, data1: Int?, consumed: Bool) {
        let subtypeText = subtype.map(String.init) ?? "-"
        let data1Text = data1.map(String.init) ?? "-"
        let line = "type=\(typeRaw) keyCode=\(keyCode) flags=0x\(String(flagsRaw, radix: 16)) " +
            "subtype=\(subtypeText) data1=\(data1Text) consumed=\(consumed)"
        Self.logger.info("\(line, privacy: .public)")
        tapLogLines.append(line)
        if tapLogLines.count > Self.tapLogRingLimit {
            tapLogLines.removeFirst(tapLogLines.count - Self.tapLogRingLimit)
        }
    }

    func consumeShortcut(type: CGEventType, keyCode: Int64, flags: CGEventFlags, autorepeat: Bool) -> Bool {
        consumeShortcut(type: type, keyCode: keyCode, flags: flags, autorepeat: autorepeat, dispatch: false)
    }

    private func consumeShortcutFromTap(type: CGEventType, keyCode: Int64, flags: CGEventFlags, autorepeat: Bool) -> Bool {
        consumeShortcut(type: type, keyCode: keyCode, flags: flags, autorepeat: autorepeat, dispatch: true)
    }

    private func consumeShortcut(type: CGEventType, keyCode: Int64, flags: CGEventFlags, autorepeat: Bool, dispatch: Bool) -> Bool {
        if type == .keyUp { return consumedKeys.remove(keyCode) != nil }
        guard type == .keyDown else { return false }
        if consumedKeys.contains(keyCode) { return true }
        // An autorepeat without a consumed initial keyDown belongs to the
        // foreground app. Passing it through also prevents stealing its keyUp.
        guard !autorepeat else { return false }
        if let shortcut = Self.shortcut(for: keyCode, flags: flags, autorepeat: false) {
            consumedKeys.insert(keyCode)
            lastShortcutSeen = ShortcutSighting(chordName: Self.chordName(for: shortcut), date: Date())
            if dispatch {
                DispatchQueue.main.async { [weak self] in self?.onShortcut?(shortcut) }
            } else {
                onShortcut?(shortcut)
            }
            return true
        }
        guard let option = Self.optionShortcut(for: keyCode, flags: flags, autorepeat: false) else { return false }
        consumedKeys.insert(keyCode)
        lastShortcutSeen = ShortcutSighting(chordName: Self.optionChordName(for: option), date: Date())
        if dispatch {
            DispatchQueue.main.async { [weak self] in self?.onOptionShortcut?(option) }
        } else {
            onOptionShortcut?(option)
        }
        return true
    }

    /// Starts or stops a locked dictation from a click on the dock. Mirrors
    /// `stopByEscape`, which is the other non-keyboard way in.
    func toggleByClick() {
        pendingRelease?.cancel(); pendingRelease = nil
        let wasLocked = state.locked
        let action = state.clickToggle()
        notifyLockChange(from: wasLocked)
        switch action {
        case .start: onStart?()
        case .stop: onStop?()
        case .none: break
        }
    }

    // Marked internal, not private, so tests can drive it directly without a
    // real CGEventTap.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        // F13 is the reliable prototype key. Key code 63 covers the physical fn key on supported Macs.
        guard keyCode == 105 || keyCode == 63 else { return }
        if keyCode == 63 && type == .flagsChanged {
            let fnDown = flags.contains(.maskSecondaryFn)
            guard fnDown != pressed else { return }
            pressed = fnDown
            setHoldKeyDown(fnDown)
            if fnDown { press() } else { release() }
        } else if type == .keyDown {
            if pressed { return }
            pressed = true
            setHoldKeyDown(true)
            press()
        } else if type == .keyUp {
            pressed = false
            setHoldKeyDown(false)
            release()
        }
    }

    /// Updates `holdKeyIsDown` and, on the down-to-up transition, fires
    /// `onHoldKeyReleased`. This tracks the physical key state independent of
    /// the lock state machine so a lock-mode stop tap can be told apart from
    /// an actual key-up.
    private func setHoldKeyDown(_ down: Bool) {
        guard holdKeyIsDown != down else { return }
        holdKeyIsDown = down
        if !down { onHoldKeyReleased?() }
    }

    private func press() {
        pendingRelease?.cancel(); pendingRelease = nil
        let wasLocked = state.locked
        let action = state.press(at: monotonicNow())
        notifyLockChange(from: wasLocked)
        switch action {
        case .start: onStart?()
        case .stop: onStop?()
        case .none: break
        }
    }

    private func release() {
        let wasLocked = state.locked
        let action = state.release(at: monotonicNow())
        notifyLockChange(from: wasLocked)
        switch action {
        case .stopImmediately:
            onStop?()
        case .stopAfterDelay:
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state.delayedStop() else { return }
                self.onStop?()
            }
            pendingRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + state.doubleTapWindow, execute: work)
        case .none: break
        }
    }

    /// Stops a locked recording from a source other than the hold key, such
    /// as the Escape key. No-op when lock mode is not engaged.
    func stopByEscape() {
        pendingRelease?.cancel(); pendingRelease = nil
        let wasLocked = state.locked
        guard state.stopIfLocked() else { return }
        notifyLockChange(from: wasLocked)
        onStop?()
    }

    private func notifyLockChange(from previous: Bool) {
        guard state.locked != previous else { return }
        onLockChange?(state.locked)
    }

    private func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
