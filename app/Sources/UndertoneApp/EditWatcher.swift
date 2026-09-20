import Foundation
import AppKit
import ApplicationServices

struct InsertionReceipt {
    let rowID: Int
    let target: TargetSnapshot
    let produced: String
    let expectedValue: String
    let insertedRange: CFRange
    let appBundleID: String

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

    func start(receipt: InsertionReceipt, knownTerms: Set<String>, onCandidate: @escaping (LearningCandidate, String) -> Void) {
        cancel()
        if let element = receipt.target.element {
            _ = AXUIElementSetMessagingTimeout(element, 0.25)
        }
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + self.duration
            var stableEdit: String?
            var stableSince = ContinuousClock.now
            while !Task.isCancelled && ContinuousClock.now < deadline {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled, self.inserter.isCurrentTarget(receipt.target) else { return }
                guard let value = self.inserter.currentValue(of: receipt.target),
                      let edited = Self.isolatedEditedSpan(expected: receipt.expectedValue, current: value, range: receipt.insertedRange) else { return }
                guard edited != receipt.produced else {
                    stableEdit = nil
                    continue
                }
                if edited != stableEdit { stableEdit = edited; stableSince = .now; continue }
                guard ContinuousClock.now - stableSince >= .seconds(1) else { continue }
                if let candidate = Self.candidate(produced: receipt.produced, replacement: edited, knownTerms: knownTerms) {
                    if candidate.reason == "unknown" {
                        let misspelling = NSSpellChecker.shared.checkSpelling(of: candidate.replacement, startingAt: 0)
                        guard misspelling.location != NSNotFound else { return }
                    }
                    onCandidate(candidate, edited)
                    return
                }
                // A term already in the dictionary is still an accepted edit
                // for history, but it must not create a suggestion or learning
                // action. Keep the public candidate classifier's old nil
                // result for callers that only want new vocabulary.
                if let knownCandidate = Self.candidate(produced: receipt.produced, replacement: edited, knownTerms: []) {
                    let known = knownTerms.contains(knownCandidate.replacement.lowercased())
                    if known {
                        onCandidate(
                            LearningCandidate(produced: knownCandidate.produced,
                                              replacement: knownCandidate.replacement,
                                              reason: "already_known"),
                            edited
                        )
                        return
                    }
                }
            }
        }
    }

    nonisolated static func isolatedEditedSpan(expected: String, current: String, range: CFRange) -> String? {
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
}
