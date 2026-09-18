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
    case emptyText, notTrusted, appChanged, elementChanged, axRejected, typeFailed
}

enum InsertOutcome {
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
    case type
    case axAttempt
}

enum StreamInsertion {
    /// Remainder of `clean` after `committed`, or nil when `committed` is not a prefix.
    static func remainder(clean: String, committed: String) -> String? {
        guard clean.hasPrefix(committed) else { return nil }
        return String(clean[committed.endIndex...])
    }
}

final class InsertionController {
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

    /// Plain dictation only requires the frontmost app to match. Selected text
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
        bundleMatches: Bool, axFirst: Bool, snapshotHasElement: Bool, currentElementMatches: Bool
    ) -> DictationInsertRoute {
        guard bundleMatches else { return .appChanged }
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

    func insert(_ text: String, target: TargetSnapshot, axOnly: Bool = false) -> InsertOutcome {
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
        guard AXIsProcessTrusted() else {
            return logAndReturn(route: axOnly ? "axOnly" : "dictation", axResult: nil, confirmed: nil, .failed(.notTrusted))
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
        // Universal dictation strategy: the app must still be frontmost, but a
        // changed or unreadable focused element only routes to typed
        // keystrokes instead of blocking insertion outright.
        let currentElement = focusedElement()
        let currentElementMatches = target.element.map { expected in
            currentElement.map { CFEqual($0, expected) } ?? false
        } ?? false
        let route = Self.dictationInsertRoute(
            bundleMatches: bundleMatches,
            axFirst: Self.shouldAXFirst(bundleID: target.bundleID),
            snapshotHasElement: target.element != nil,
            currentElementMatches: currentElementMatches
        )
        switch route {
        case .appChanged:
            return logAndReturn(route: "appChanged", axResult: nil, confirmed: nil, .failed(.appChanged))
        case .type:
            let outcome: InsertOutcome = typeUnicode(text) ? .inserted(.type) : .failed(.typeFailed)
            return logAndReturn(route: "type", axResult: nil, confirmed: nil, outcome)
        case .axAttempt:
            let axResult = setSelectedText(text, element: target.element)
            let confirmed = axResult == .success
                && Self.isConfirmedAXInsertion(text: text, readableValue: value(of: target.element))
            if confirmed {
                return logAndReturn(route: "axAttempt", axResult: axResult, confirmed: true, .inserted(.ax))
            }
            // Any AX error, or a hollow success, falls back to typed keystrokes.
            let outcome: InsertOutcome = typeUnicode(text) ? .inserted(.type) : .failed(.typeFailed)
            return logAndReturn(route: "axAttempt", axResult: axResult, confirmed: false, outcome)
        }
    }

    func appendStreamed(_ text: String, target: TargetSnapshot) -> InsertOutcome {
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
        let outcome: InsertOutcome = typeUnicode(text) ? .inserted(.type) : .failed(.typeFailed)
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

    func replaceLastInsertion(_ inserted: String, with replacement: String, target: TargetSnapshot) -> InsertOutcome {
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
        if Self.allowsTypingFallback(for: axResult), typeUnicode(replacement) { return .inserted(.type) }
        return .failed(.axRejected)
    }

    func currentValue(of target: TargetSnapshot) -> String? {
        guard isSameElement(target) else { return nil }
        return value(of: target.element)
    }

    func isCurrentTarget(_ target: TargetSnapshot) -> Bool {
        isSameElement(target)
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

    private func typeUnicode(_ text: String) -> Bool {
        clearStuckFnFlagIfNeeded()
        let chunks = Self.utf16Chunks(text)
        Self.insertLogger.info("typeUnicode: posting \(chunks.count, privacy: .public) chunks")
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var events: [(down: CGEvent, up: CGEvent)] = []
        events.reserveCapacity(chunks.count)


        // Allocate every event before posting any of them. If event creation fails,
        // the caller can report failure without leaving a partially typed string.
        for chunk in chunks {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []; up.flags = []
            chunk.withUnsafeBufferPointer { pointer in
                down.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
            }
            events.append((down: down, up: up))
        }


        for event in events {
            event.down.post(tap: .cghidEventTap)
            event.up.post(tap: .cghidEventTap)
        }
        return true
    }
}
