import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import os

struct TargetSnapshot {
    let bundleID: String?
    let element: AXUIElement?
    let value: String?
    let selectedText: String?
    let selectedRange: CFRange?
}

enum InsertStrategy: String { case ax, type }

/// Why an insertion attempt did not land. Written into history as
/// `"failed:<rawValue>"` so the failure mode is visible after the fact.
enum InsertFailure: String {
    case emptyText, notTrusted, appChanged, elementChanged, axRejected, typeFailed, prefixMismatch
    case partialInsertion, cancelled, deliveryBusy, unsupportedCharacters
}

enum InsertOutcome: Equatable {
    case inserted(InsertStrategy)
    case failed(InsertFailure)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The string written into the history row's `insert_mode` column.
    var historyValue: String {
        switch self {
        case .inserted(let strategy): return strategy.rawValue
        case .failed(let reason): return "failed:\(reason.rawValue)"
        }
    }
}

/// The routing decision for a plain-dictation insertion once the frontmost
/// bundle id is confirmed to still match the captured target. Selection and
/// range drift never block this path; only the app and, when it matters for
/// AX trust, the focused element do.
enum DictationInsertRoute: Equatable {
    case appChanged
    case elementChanged
    case type
    case axAttempt
}

enum StreamInsertion {
    /// A failed live request may replay only when no part of its text landed.
    static func canUseOneShotFallback(committed: String, failure: InsertOutcome?) -> Bool {
        committed.isEmpty && failure != .failed(.partialInsertion)
    }

    /// A later pre-post failure is still partial when an earlier chunk landed.
    static func failure(_ outcome: InsertOutcome, committed: String) -> InsertOutcome {
        guard outcome.isFailure, !committed.isEmpty else { return outcome }
        return .failed(.partialInsertion)
    }

    /// Viewers cannot confirm that an early prefix reached the remote field.
    static func enabled(requested: Bool, bundleID: String?) -> Bool {
        requested && !RemoteDesktopTyping.isRemoteDesktopViewer(bundleID: bundleID)
    }

    /// Remainder of `clean` after `committed`, or nil when `committed` is not a prefix.
    static func remainder(clean: String, committed: String) -> String? {
        guard clean.hasPrefix(committed) else { return nil }
        return String(clean[committed.endIndex...])
    }
}

final class InsertionController {
    @MainActor private var deliveryInFlight = false
    /// Apps confirmed to report a trustworthy AX success for plain dictation,
    /// so it is worth trying `kAXSelectedText` before falling back to typed
    /// keystrokes. Empty by default: Messages and every Electron app tried so
    /// far (Codex, Claude Desktop) return an AX success whose value the
    /// read-back cannot distinguish from a real insertion (a "hollow"
    /// success), so typed keystrokes are the default route for every app.
    /// The mechanism stays in place so a specific app can opt back into
    /// AX-first without redesigning the routing table.
    static let axFirstBundleIDs: Set<String> = []

    private static let logger = Logger(subsystem: "com.undertone.app", category: "hotkey")
    private static let insertLogger = Logger(subsystem: "com.undertone.app", category: "insert")
    /// How long to wait after posting a synthetic fn key-up before typing,
    /// so the modifier state change has settled. See
    /// `clearStuckFnFlagIfNeeded`.
    private static let fnClearSettleDelay: TimeInterval = 0.03
    /// Give the target time to consume each event, including modifier changes.
    private static let keystrokeInterval: Duration = .milliseconds(3)

    private static func allowsTypingFallback(for error: AXError) -> Bool {
        error == .attributeUnsupported || error == .notImplemented
    }

    /// Whether the session's modifier state still reports fn held. Pure and
    /// testable on its own; the impure part (reading and clearing the real
    /// session state) lives in `clearStuckFnFlagIfNeeded`.
    static func needsFnClear(sessionFlags: CGEventFlags) -> Bool {
        sessionFlags.contains(.maskSecondaryFn)
    }

    static func shouldAXFirst(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return axFirstBundleIDs.contains(bundleID)
    }

    func snapshot() -> TargetSnapshot {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let element = focusedElement()
        return TargetSnapshot(bundleID: bundleID, element: element, value: value(of: element), selectedText: selectedText(element), selectedRange: selectedRange(element))
    }

    /// Plain dictation rejects a known different field in the same app. Selected text
    /// and range can legitimately move between key-down and insertion
    /// (autocomplete, cursor drift) and must not block insertion. Typed
    /// keystrokes are the default route for every app, because AX success
    /// cannot be told apart from a hollow AX success (an `.success` result
    /// whose value never actually changes, first seen in Electron apps and
    /// then in Messages) without a read-back the app may not support.
    /// `axFirst` opts a specific, confirmed-trustworthy app back into trying
    /// `kAXSelectedText` first, and even then only when the exact focused
    /// element captured at key-down is still focused now. Command
    /// replacement keeps the strict contract: same element, same selected
    /// text, same selected range; see `isValidTarget(_:axOnly:)`.
    static func dictationInsertRoute(
        bundleMatches: Bool, axFirst: Bool, snapshotHasElement: Bool, currentElementMatches: Bool,
        currentHasElement: Bool = true
    ) -> DictationInsertRoute {
        guard bundleMatches else { return .appChanged }
        if snapshotHasElement, currentHasElement, !currentElementMatches { return .elementChanged }
        if axFirst, snapshotHasElement, currentElementMatches { return .axAttempt }
        return .type
    }

    /// An AX setter that returns `.success` is not proof of an actual
    /// insertion in every app; some AX trees (Electron apps and Messages)
    /// report success with no visible effect. Confirm by reading the value
    /// back; when the value cannot be read at all, do not trust the success,
    /// since an unreadable value is exactly the shape of a hollow success.
    static func isConfirmedAXInsertion(text: String, readableValue: String?) -> Bool {
        guard let readableValue else { return false }
        return readableValue.contains(text)
    }

    @MainActor func insert(_ text: String, target: TargetSnapshot, axOnly: Bool = false) async -> InsertOutcome {
        let bundleDescription = target.bundleID ?? "nil"
        let textLength = text.count
        // One diagnostic line per call, never the text itself: the target
        // app, the route taken, the AX result code when AX was attempted,
        // whether read-back confirmed it, and the final outcome. This is
        // what makes a future hollow-success report in a new app
        // diagnosable from Console instead of guesswork.
        func logAndReturn(route: String, axResult: AXError?, confirmed: Bool?, _ outcome: InsertOutcome) -> InsertOutcome {
            let axResultDescription = axResult.map { "\($0)" } ?? "n/a"
            let confirmedDescription = confirmed.map { $0 ? "true" : "false" } ?? "n/a"
            Self.insertLogger.info("""
                insert: bundle=\(bundleDescription, privacy: .public) route=\(route, privacy: .public) \
                axResult=\(axResultDescription, privacy: .public) confirmed=\(confirmedDescription, privacy: .public) \
                outcome=\(outcome.historyValue, privacy: .public) length=\(textLength, privacy: .public)
                """)
            return outcome
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return logAndReturn(route: axOnly ? "axOnly" : "dictation", axResult: nil, confirmed: nil, .failed(.emptyText))
        }
        guard !deliveryInFlight else {
            return logAndReturn(route: "busy", axResult: nil, confirmed: nil, .failed(.deliveryBusy))
        }
        guard AXIsProcessTrusted() else {
            return logAndReturn(route: axOnly ? "axOnly" : "dictation", axResult: nil, confirmed: nil, .failed(.notTrusted))
        }
        guard !Task.isCancelled else {
            return logAndReturn(route: "cancelled", axResult: nil, confirmed: nil, .failed(.cancelled))
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let bundleMatches = frontmostBundleID == target.bundleID && frontmostBundleID != Bundle.main.bundleIdentifier
        if axOnly {
            // Command replacement retains its strict AX-only selection contract.
            guard bundleMatches else {
                return logAndReturn(route: "axOnly", axResult: nil, confirmed: nil, .failed(.appChanged))
            }
            guard let current = focusedElement(), let expected = target.element, CFEqual(current, expected) else {
                return logAndReturn(route: "axOnly", axResult: nil, confirmed: nil, .failed(.elementChanged))
            }
            guard selectedText(current) == target.selectedText, rangesEqual(selectedRange(current), target.selectedRange) else {
                return logAndReturn(route: "axOnly", axResult: nil, confirmed: nil, .failed(.elementChanged))
            }
            let axResult = setSelectedText(text, element: target.element)
            let outcome: InsertOutcome = axResult == .success ? .inserted(.ax) : .failed(.axRejected)
            return logAndReturn(route: "axOnly", axResult: axResult, confirmed: nil, outcome)
        }
        // Unknown AX identity permits typing; a known different field does not.
        let currentElement = focusedElement()
        let currentElementMatches = target.element.map { expected in
            currentElement.map { CFEqual($0, expected) } ?? false
        } ?? false
        let route = Self.dictationInsertRoute(
            bundleMatches: bundleMatches,
            axFirst: Self.shouldAXFirst(bundleID: target.bundleID),
            snapshotHasElement: target.element != nil,
            currentElementMatches: currentElementMatches, currentHasElement: currentElement != nil
        )
        switch route {
        case .appChanged:
            return logAndReturn(route: "appChanged", axResult: nil, confirmed: nil, .failed(.appChanged))
        case .elementChanged:
            return logAndReturn(route: "elementChanged", axResult: nil, confirmed: nil, .failed(.elementChanged))
        case .type:
            let outcome = await typeText(text, target: target)
            return logAndReturn(route: "type", axResult: nil, confirmed: nil, outcome)
        case .axAttempt:
            let axResult = setSelectedText(text, element: target.element)
            let confirmed = axResult == .success
                && Self.isConfirmedAXInsertion(text: text, readableValue: value(of: target.element))
            if confirmed {
                return logAndReturn(route: "axAttempt", axResult: axResult, confirmed: true, .inserted(.ax))
            }
            // Any AX error, or a hollow success, falls back to typed keystrokes.
            let outcome = await typeText(text, target: target)
            return logAndReturn(route: "axAttempt", axResult: axResult, confirmed: false, outcome)
        }
    }

    @MainActor func appendStreamed(_ text: String, target: TargetSnapshot) async -> InsertOutcome {
        let bundleDescription = target.bundleID ?? "nil"
        let textLength = text.count
        func logAndReturn(_ outcome: InsertOutcome) -> InsertOutcome {
            Self.insertLogger.info("""
                insert: bundle=\(bundleDescription, privacy: .public) route=stream \
                axResult=n/a confirmed=n/a \
                outcome=\(outcome.historyValue, privacy: .public) length=\(textLength, privacy: .public)
                """)
            return outcome
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return logAndReturn(.failed(.emptyText))
        }
        guard AXIsProcessTrusted() else {
            return logAndReturn(.failed(.notTrusted))
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let bundleMatches = frontmostBundleID == target.bundleID && frontmostBundleID != Bundle.main.bundleIdentifier
        guard bundleMatches else {
            return logAndReturn(.failed(.appChanged))
        }
        if let expected = target.element, let current = focusedElement(), !CFEqual(expected, current) {
            return logAndReturn(.failed(.elementChanged))
        }
        let outcome = await typeText(text, target: target)
        return logAndReturn(outcome)
    }

    static func logStreamPrefixMismatch(bundleID: String?) {
        let bundleDescription = bundleID ?? "nil"
        insertLogger.info("insert: bundle=\(bundleDescription, privacy: .public) route=stream prefix_mismatch")
    }

    func canReplaceSelection(_ target: TargetSnapshot) -> Bool {
        guard let element = target.element,
              let range = target.selectedRange,
              range.location >= 0, range.length > 0,
              let selected = target.selectedText,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    @MainActor func replaceLastInsertion(_ inserted: String, with replacement: String, target: TargetSnapshot) async -> InsertOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard !deliveryInFlight else { return .failed(.deliveryBusy) }
        guard AXIsProcessTrusted() else { return .failed(.notTrusted) }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID else { return .failed(.appChanged) }
        guard isSameElement(target) else { return .failed(.elementChanged) }
        guard let element = target.element, let value = value(of: element) else { return .failed(.elementChanged) }
        guard let originalRange = target.selectedRange,
              let currentRange = selectedRange(element),
              let replacementRange = Self.exactReplacementRange(inserted: inserted, value: value,
                                                                originalRange: originalRange, currentRange: currentRange) else { return .failed(.elementChanged) }
        var range = replacementRange
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else { return .failed(.elementChanged) }
        // A successful setter may be asynchronous in the target application. Confirm
        // the exact range before writing, so a stale or ignored selection cannot be
        // replaced in an unrelated location.
        guard let readBack = selectedRange(element), rangesEqual(readBack, replacementRange) else { return .failed(.elementChanged) }
        let axResult = setSelectedText(replacement, element: element)
        if axResult == .success { return .inserted(.ax) }
        if Self.allowsTypingFallback(for: axResult) { return await typeText(replacement, target: target) }
        return .failed(.axRejected)
    }

    /// Read only the focused field in the expected process. Do not collect
    /// selected text, clipboard data, or values from another app while paused.
    @MainActor func correctionSnapshot(in bundleID: String) -> TargetSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        defer { _ = AXUIElementSetMessagingTimeout(element, 0) }
        var subrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleResult == .success || subroleResult == .attributeUnsupported || subroleResult == .noValue,
              (subrole as? String) != kAXSecureTextFieldSubrole else { return nil }
        guard let currentValue = value(of: element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return TargetSnapshot(bundleID: bundleID, element: element, value: currentValue,
                              selectedText: nil, selectedRange: nil)
    }

    static func exactReplacementRange(inserted: String, value: String, originalRange: CFRange, currentRange: CFRange) -> CFRange? {
        let insertedUnits = Array(inserted.utf16)
        let valueUnits = Array(value.utf16)
        guard !insertedUnits.isEmpty,
              originalRange.location >= 0,
              originalRange.length >= 0,
              originalRange.location + insertedUnits.count <= valueUnits.count,
              currentRange.length == 0,
              currentRange.location == originalRange.location + insertedUnits.count else { return nil }
        let end = originalRange.location + insertedUnits.count
        guard Array(valueUnits[originalRange.location..<end]) == insertedUnits else { return nil }
        return CFRange(location: originalRange.location, length: insertedUnits.count)
    }

    static func utf16Chunks(_ text: String, maximumUnits: Int = 20) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard maximumUnits > 0 else { return [] }
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maximumUnits, units.count)
            if end < units.count, end > start, units[end - 1] >= 0xD800, units[end - 1] <= 0xDBFF {
                end -= 1
            }
            if end == start { end = min(start + maximumUnits, units.count) }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    private func isSameElement(_ target: TargetSnapshot) -> Bool {
        guard let current = focusedElement(), let expected = target.element else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID && CFEqual(current, expected)
    }

    private func value(of element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        return value as? String
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selectedText(_ element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        return value as? String
    }

    private func selectedRange(_ element: AXUIElement?) -> CFRange? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private func rangesEqual(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (.some(a), .some(b)): return a.location == b.location && a.length == b.length
        default: return false
        }
    }

    private func setSelectedText(_ text: String, element: AXUIElement?) -> AXError {
        guard let element else { return .invalidUIElement }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }

    /// Belt-and-braces guard against a fn key the OS still believes is held
    /// down going into a keystroke-based insertion. `HotkeyMonitor` no
    /// longer swallows fn `flagsChanged` at its event tap (see that type's
    /// `shouldConsumeAtTap` doc comment): dropping that event at the tap
    /// does not retract fn from the system's own modifier tracking, so a
    /// lock-mode stop tap could still leave fn reading as held right into
    /// typing, turning the first typed letter into a globe+key system
    /// shortcut. If the session's own state still reports fn down, post a
    /// synthetic fn key-up at HID level and give it a moment to settle
    /// before typing. A no-op when fn state is already clear, which is true
    /// the overwhelming majority of the time.
    private func clearStuckFnFlagIfNeeded() {
        let sessionFlags = CGEventSource.flagsState(.combinedSessionState)
        guard Self.needsFnClear(sessionFlags: sessionFlags) else { return }
        Self.logger.info("typeUnicode: clearing a stuck fn flag before typing")
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let fnUp = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: false) else { return }
        fnUp.flags.remove(.maskSecondaryFn)
        fnUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Self.fnClearSettleDelay)
    }

    /// Types `text` with the keystroke method that suits the target app.
    /// Remote-desktop viewers get real key presses; every other app gets
    /// Unicode string events. See `RemoteDesktopTyping`.
    @MainActor private func typeText(_ text: String, target: TargetSnapshot) async -> InsertOutcome {
        switch RemoteDesktopTyping.keystrokeMethod(bundleID: target.bundleID) {
        case .unicodeChunks: return await typeUnicode(text, target: target)
        case .layoutKeys: return await typeLayoutKeys(text, target: target)
        }
    }

    @MainActor private func typeUnicode(_ text: String, target: TargetSnapshot) async -> InsertOutcome {
        clearStuckFnFlagIfNeeded()
        let chunks = Self.utf16Chunks(text)
        Self.insertLogger.info("typeUnicode: posting \(chunks.count, privacy: .public) chunks")
        guard let source = CGEventSource(stateID: .privateState) else { return .failed(.typeFailed) }
        var events: [(down: CGEvent, up: CGEvent)] = []
        events.reserveCapacity(chunks.count)


        // Allocate every event before posting any of them. If event creation fails,
        // the caller can report failure without leaving a partially typed string.
        for chunk in chunks {
            guard let pair = Self.unicodeKeyEvents(chunk, source: source) else { return .failed(.typeFailed) }
            events.append(pair)
        }


        return await postKeyGroups(events.map { [$0.down, $0.up] }, target: target)
    }

    /// Types `text` into a remote-desktop viewer as one real key press per
    /// character, with Shift and Option pressed as their own keys. The
    /// viewer forwards these to the remote computer the same way it
    /// forwards physical typing. Reject unsupported characters before typing
    /// any part of the message; the complete text remains in History.
    /// The log line is at notice level so it persists for later diagnosis.
    @MainActor private func typeLayoutKeys(_ text: String, target: TargetSnapshot) async -> InsertOutcome {
        let keyMap = RemoteDesktopTyping.currentLayoutKeyMap()
        let steps = RemoteDesktopTyping.steps(for: text, keyMap: keyMap)
        let unicodeSteps = steps.filter { if case .unicode = $0 { return true } else { return false } }.count
        let bundleDescription = target.bundleID ?? "nil"
        Self.insertLogger.notice("""
            typeLayoutKeys: bundle=\(bundleDescription, privacy: .public) \
            keys=\(steps.count - unicodeSteps, privacy: .public) unicode=\(unicodeSteps, privacy: .public) \
            layoutKeys=\(keyMap.count, privacy: .public)
            """)
        guard RemoteDesktopTyping.canDeliver(steps) else { return .failed(.unsupportedCharacters) }
        clearStuckFnFlagIfNeeded()
        guard let source = CGEventSource(stateID: .privateState) else { return .failed(.typeFailed) }
        var groups: [[CGEvent]] = []
        groups.reserveCapacity(steps.count)

        // Allocate every event before posting any of them, as typeUnicode does.
        for step in steps {
            switch step {
            case .key(let stroke):
                var events: [CGEvent] = []
                for press in RemoteDesktopTyping.keyPresses(for: stroke) {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: press.keyCode,
                                              keyDown: press.keyDown) else { return .failed(.typeFailed) }
                    event.flags = press.flags
                    events.append(event)
                }
                groups.append(events)
            case .unicode(let units):
                guard let pair = Self.unicodeKeyEvents(units, source: source) else { return .failed(.typeFailed) }
                groups.append([pair.down, pair.up])
            }
        }

        return await postKeyGroups(groups, target: target)
    }

    @MainActor private func postKeyGroups(_ groups: [[CGEvent]], target: TargetSnapshot) async -> InsertOutcome {
        await postKeyGroups(groups, interval: Self.keystrokeInterval, isCurrent: {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID
        }, post: { $0.post(tap: .cghidEventTap) })
    }

    /// A group is one complete stroke, including its modifier releases. Finish
    /// that stroke before stopping, so cancellation cannot leave Shift held.
    @MainActor func postKeyGroups<Event>(
        _ groups: [[Event]], interval: Duration, isCurrent: () -> Bool,
        post: (Event) -> Void,
        pause: (Duration) async -> Void = InsertionController.waitForKeyEvent
    ) async -> InsertOutcome {
        guard !deliveryInFlight else { return .failed(.deliveryBusy) }
        guard !groups.isEmpty else { return .failed(.emptyText) }
        deliveryInFlight = true
        defer { deliveryInFlight = false }
        var posted = false
        for (groupIndex, group) in groups.enumerated() {
            guard !Task.isCancelled else { return .failed(posted ? .partialInsertion : .cancelled) }
            guard isCurrent() else { return .failed(posted ? .partialInsertion : .appChanged) }
            for (eventIndex, event) in group.enumerated() {
                post(event)
                posted = true
                if groupIndex < groups.count - 1 || eventIndex < group.count - 1 {
                    await pause(interval)
                }
            }
        }
        return .inserted(.type)
    }

    /// A cancellation must not collapse the key-up/modifier-release gaps.
    nonisolated static func waitForKeyEvent(_ delay: Duration) async {
        let parts = delay.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    /// A key-down and key-up pair on key code 0 that carries `units` as its
    /// Unicode string, with no modifier flags.
    private static func unicodeKeyEvents(_ units: [UInt16], source: CGEventSource) -> (down: CGEvent, up: CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        down.flags = []; up.flags = []
        units.withUnsafeBufferPointer { pointer in
            down.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
        }
        return (down: down, up: up)
    }
}
