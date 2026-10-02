import Foundation
import AppKit
import ApplicationServices
import os

struct InsertionReceipt {
    let rowID: Int
    let target: TargetSnapshot
    let produced: String
    let expectedValue: String
    let insertedRange: CFRange
    let appBundleID: String

    /// Some editors expose stale or placeholder AX text before insertion.
    /// Re-anchor only when the first observed field is exactly our output.
    /// A substring match or an already edited field is not sufficient proof.
    func confirmedWholeFieldBaseline(current: String) -> InsertionReceipt? {
        guard !produced.isEmpty, current == produced, current != expectedValue else { return nil }
        return InsertionReceipt(
            rowID: rowID, target: target, produced: produced,
            expectedValue: current,
            insertedRange: CFRange(location: 0, length: current.utf16.count),
            appBundleID: appBundleID
        )
    }

    /// Recover a missing pre-insertion snapshot only from exact whole-field
    /// readback in the original app. Preserve element identity when known.
    static func confirmedAfterInsertion(
        rowID: Int, produced: String, original: TargetSnapshot, observed: TargetSnapshot
    ) -> InsertionReceipt? {
        guard let bundleID = original.bundleID, !bundleID.isEmpty,
              observed.bundleID == bundleID, let element = observed.element,
              !produced.isEmpty, observed.value == produced else { return nil }
        if let originalElement = original.element, !CFEqual(originalElement, element) { return nil }
        return InsertionReceipt(
            rowID: rowID, target: observed, produced: produced, expectedValue: produced,
            insertedRange: CFRange(location: 0, length: produced.utf16.count), appBundleID: bundleID
        )
    }

    static func make(rowID: Int, produced: String, target: TargetSnapshot) -> InsertionReceipt? {
        guard let before = target.value, let selected = target.selectedRange,
              selected.location >= 0, selected.length >= 0 else { return nil }
        let units = Array(before.utf16)
        guard selected.location + selected.length <= units.count else { return nil }
        let replacement = Array(produced.utf16)
        var expected = Array(units[..<selected.location])
        expected.append(contentsOf: replacement)
        expected.append(contentsOf: units[(selected.location + selected.length)...])
        return InsertionReceipt(
            rowID: rowID,
            target: target,
            produced: produced,
            expectedValue: String(decoding: expected, as: UTF16.self),
            insertedRange: CFRange(location: selected.location, length: replacement.count),
            appBundleID: target.bundleID ?? "unknown"
        )
    }
}

struct LearningCandidate: Equatable, Sendable {
    let produced: String
    let replacement: String
    let reason: String
}

@MainActor
final class EditWatcher {
    private static let logger = Logger(subsystem: "com.undertone.app", category: "correction")

    static func logUnavailable(rowID: Int, target: TargetSnapshot) {
        logger.notice("correction: row=\(rowID, privacy: .public) unavailable element=\(target.element != nil, privacy: .public) value=\(target.value != nil, privacy: .public) range=\(target.selectedRange != nil, privacy: .public)")
    }

    private func log(_ reason: String, rowID: Int) {
        Self.logger.notice("correction: row=\(rowID, privacy: .public) event=\(reason, privacy: .public)")
    }

    /// Diagnose the AX boundary without retaining field or transcript text.
    private func logBoundaryMismatch(receipt: InsertionReceipt, current: String) {
        let expected = Array(receipt.expectedValue.utf16)
        let actual = Array(current.utf16)
        let start = receipt.insertedRange.location
        let end = start + receipt.insertedRange.length
        guard start >= 0, end >= start, end <= expected.count else { return }
        let prefix = Array(expected[..<start])
        let suffix = Array(expected[end...])
        let prefixMatches = Array(actual.prefix(prefix.count)) == prefix
        let suffixMatches = Array(actual.suffix(suffix.count)) == suffix
        let prefixBlank = String(decoding: prefix, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let suffixBlank = String(decoding: suffix, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let producedPresent = !receipt.produced.isEmpty && current.contains(receipt.produced)
        Self.logger.notice("correction boundary: row=\(receipt.rowID, privacy: .public) before_units=\(receipt.target.value?.utf16.count ?? -1, privacy: .public) expected_units=\(expected.count, privacy: .public) current_units=\(actual.count, privacy: .public) start=\(start, privacy: .public) inserted_units=\(receipt.insertedRange.length, privacy: .public) prefix_matches=\(prefixMatches, privacy: .public) suffix_matches=\(suffixMatches, privacy: .public) prefix_blank=\(prefixBlank, privacy: .public) suffix_blank=\(suffixBlank, privacy: .public) produced_present=\(producedPresent, privacy: .public)")
    }

    private let inserter: InsertionController
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let duration: Duration

    init(inserter: InsertionController, interval: Duration = .milliseconds(500), duration: Duration = .seconds(20)) {
        self.inserter = inserter
        self.interval = interval
        self.duration = duration
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(
        rowID: Int, produced: String, target: TargetSnapshot, knownTerms: Set<String>,
        onCandidate: @escaping (LearningCandidate, String, InsertionReceipt) -> Void
    ) {
        cancel()
        let initialReceipt = target.element == nil ? nil : InsertionReceipt.make(rowID: rowID, produced: produced, target: target)
        if let element = target.element {
            _ = AXUIElementSetMessagingTimeout(element, 0.25)
        }
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + self.duration
            let receipt: InsertionReceipt
            if let initialReceipt {
                receipt = initialReceipt
            } else {
                Self.logUnavailable(rowID: rowID, target: target)
                // One delayed read lets the typed events reach the app. Never
                // keep searching for another field after a failed recovery.
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
                let observed = self.inserter.snapshot()
                guard let confirmed = InsertionReceipt.confirmedAfterInsertion(
                    rowID: rowID, produced: produced, original: target, observed: observed
                ) else {
                    Self.logUnavailable(rowID: rowID, target: observed)
                    self.log("snapshot_recovery_rejected", rowID: rowID)
                    return
                }
                receipt = confirmed
                if let element = receipt.target.element {
                    _ = AXUIElementSetMessagingTimeout(element, 0.25)
                }
                self.log("snapshot_recovered", rowID: rowID)
            }
            self.log("watch_started", rowID: rowID)
            var baseline = receipt
            var isFirstObservation = true
            var stableEdit: String?
            var stableSince = ContinuousClock.now
            while !Task.isCancelled && ContinuousClock.now < deadline {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { return }
                guard self.inserter.isCurrentTarget(receipt.target) else {
                    self.log("target_changed", rowID: receipt.rowID)
                    return
                }
                guard let value = self.inserter.currentValue(of: receipt.target) else {
                    self.log("value_unavailable", rowID: receipt.rowID)
                    return
                }
                if isFirstObservation {
                    isFirstObservation = false
                    if let confirmed = receipt.confirmedWholeFieldBaseline(current: value) {
                        baseline = confirmed
                        self.log("whole_field_baseline_confirmed", rowID: receipt.rowID)
                    }
                }
                guard let edited = Self.isolatedEditedSpan(expected: baseline.expectedValue, current: value, range: baseline.insertedRange) else {
                    if value.isEmpty {
                        self.log("field_cleared", rowID: receipt.rowID)
                    } else {
                        self.log("outside_inserted_span", rowID: receipt.rowID)
                        self.logBoundaryMismatch(receipt: baseline, current: value)
                    }
                    return
                }
                guard edited != receipt.produced else {
                    stableEdit = nil
                    continue
                }
                if edited != stableEdit { stableEdit = edited; stableSince = .now; continue }
                guard ContinuousClock.now - stableSince >= .seconds(1) else { continue }
                if let candidate = Self.candidate(produced: receipt.produced, replacement: edited, knownTerms: knownTerms) {
                    if candidate.reason == "unknown" {
                        let misspelling = NSSpellChecker.shared.checkSpelling(of: candidate.replacement, startingAt: 0)
                        guard misspelling.location != NSNotFound else {
                            self.log("spelled_correctly", rowID: receipt.rowID)
                            return
                        }
                    }
                    self.log("candidate_accepted", rowID: receipt.rowID)
                    onCandidate(candidate, edited, receipt)
                    return
                }
                // A term already in the dictionary is still an accepted edit
                // for history, but it must not create a suggestion or learning
                // action. Keep the public candidate classifier's old nil
                // result for callers that only want new vocabulary.
                if let knownCandidate = Self.alreadyKnownCandidate(
                    produced: receipt.produced, replacement: edited, knownTerms: knownTerms
                ) {
                    self.log("already_known", rowID: receipt.rowID)
                    onCandidate(knownCandidate, edited, receipt)
                    return
                }
            }
            if !Task.isCancelled { self.log("watch_expired", rowID: receipt.rowID) }
        }
    }

    nonisolated static func isolatedEditedSpan(expected: String, current: String, range: CFRange) -> String? {
        // A sent or cleared composer ends this dictation's observation window.
        guard !current.isEmpty else { return nil }
        let expectedUnits = Array(expected.utf16)
        let currentUnits = Array(current.utf16)
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= expectedUnits.count,
              currentUnits.count >= expectedUnits.count - range.length else { return nil }
        let prefix = Array(expectedUnits[..<range.location])
        let suffix = Array(expectedUnits[(range.location + range.length)...])
        guard Array(currentUnits.prefix(prefix.count)) == prefix,
              Array(currentUnits.suffix(suffix.count)) == suffix else { return nil }
        let start = prefix.count
        let end = currentUnits.count - suffix.count
        guard end >= start else { return nil }
        return String(decoding: currentUnits[start..<end], as: UTF16.self)
    }

    nonisolated static func candidate(produced: String, replacement: String, knownTerms: Set<String>) -> LearningCandidate? {
        let oldWords = produced.split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = replacement.split(whereSeparator: \.isWhitespace).map(String.init)
        let oldClean = oldWords.map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
        let newClean = newWords.map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
        guard oldClean.count == newClean.count else { return nil }
        let changed = zip(oldClean, newClean).enumerated().filter { _, pair in
            pair.0.caseInsensitiveCompare(pair.1) != .orderedSame
        }
        guard changed.count == 1 else { return nil }
        for (_, pair) in changed {
            let oldWord = pair.0
            let clean = pair.1
            guard let first = clean.first, clean.count > 1 else { continue }
            let known = knownTerms.contains(clean.lowercased())
            guard !known else { continue }
            return LearningCandidate(produced: oldWord, replacement: clean, reason: first.isUppercase ? "capitalized" : "unknown")
        }
        return nil
    }

    nonisolated static func alreadyKnownCandidate(
        produced: String, replacement: String, knownTerms: Set<String>
    ) -> LearningCandidate? {
        guard let candidate = candidate(produced: produced, replacement: replacement, knownTerms: []) else {
            return nil
        }
        guard knownTerms.contains(candidate.replacement.lowercased()) else { return nil }
        return LearningCandidate(produced: candidate.produced,
                                 replacement: candidate.replacement,
                                 reason: "already_known")
    }
}
