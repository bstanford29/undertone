import XCTest
import ApplicationServices
@testable import UndertoneApp

@MainActor
private final class ScriptedCorrectionFields: CorrectionFieldReading {
    let initialAnchor: CorrectionFieldAnchor?
    let retired: Bool
    let observations: [CorrectionFieldObservation?]
    private var index = 0

    init(anchor: CorrectionFieldAnchor?, retired: Bool = false, observations: [CorrectionFieldObservation?]) {
        self.initialAnchor = anchor
        self.retired = retired
        self.observations = observations
    }

    func correctionAnchor(for target: TargetSnapshot) -> CorrectionFieldAnchor? { initialAnchor }
    func correctionReferenceIsRetired(_ target: TargetSnapshot) -> Bool { retired }
    func correctionObservation(in appBundleID: String) -> CorrectionFieldObservation? {
        guard !observations.isEmpty else { return nil }
        let observation = observations[min(index, observations.count - 1)]
        index += 1
        return observation
    }
}

@MainActor
final class CorrectionWatcherTests: XCTestCase {
    private let oldElement = AXUIElementCreateApplication(101)
    private let newElement = AXUIElementCreateApplication(102)
    private let window = AXUIElementCreateApplication(201)
    private let otherWindow = AXUIElementCreateApplication(202)

    private func anchor(y: CGFloat = 40, identifier: String? = nil, otherWindow: Bool = false) -> CorrectionFieldAnchor {
        CorrectionFieldAnchor(window: otherWindow ? self.otherWindow : window, role: kAXTextAreaRole,
                              identifier: identifier, frame: CGRect(x: 20, y: y, width: 400, height: 60))
    }

    private func original(value: String = "", location: Int = 0) -> TargetSnapshot {
        TargetSnapshot(bundleID: "fixture.app", element: oldElement, value: value,
                       selectedText: "", selectedRange: CFRange(location: location, length: 0))
    }

    private func field(_ value: String, newElement: Bool = false,
                       anchor: CorrectionFieldAnchor? = nil, bundle: String = "fixture.app") -> CorrectionFieldObservation {
        CorrectionFieldObservation(
            target: TargetSnapshot(bundleID: bundle, element: newElement ? self.newElement : oldElement,
                                   value: value, selectedText: nil, selectedRange: nil),
            anchor: anchor ?? self.anchor())
    }

    private func run(_ observations: [CorrectionFieldObservation?], target: TargetSnapshot? = nil,
                     produced: String = "Nora", initialAnchor: CorrectionFieldAnchor? = nil,
                     retired: Bool = false, noAnchor: Bool = false,
                     wait: Duration = .milliseconds(280)) async -> [LearningCandidate] {
        let reader = ScriptedCorrectionFields(anchor: noAnchor ? nil : initialAnchor ?? anchor(),
                                              retired: retired, observations: observations)
        let watcher = EditWatcher(inserter: reader, interval: .milliseconds(3),
                                  duration: .milliseconds(200), stability: .milliseconds(2))
        var candidates: [LearningCandidate] = []
        watcher.start(rowID: 1, produced: produced, target: target ?? original(), knownTerms: []) { candidate, _, _ in
            candidates.append(candidate)
        }
        try? await Task.sleep(for: wait)
        watcher.cancel()
        return candidates
    }

    func testLearnsWhenEditorReplacesItsAXElementDuringTheCorrection() async {
        let result = await run([field("Please call Nora"), field("Please call Zelvoriax", newElement: true)],
                               produced: "Please call Nora")
        XCTAssertEqual(result, [LearningCandidate(produced: "Nora", replacement: "Zelvoriax", reason: "capitalized")])
    }

    func testPausesWhileCopyingAndResumesInTheSameLogicalEditor() async {
        let result = await run([
            field("Please call Nora"), nil, field("Source", newElement: true, anchor: anchor(y: 300)), nil,
            field("Please call Zelvoriax", newElement: true)
        ], produced: "Please call Nora")
        XCTAssertEqual(result.first?.replacement, "Zelvoriax")
        XCTAssertEqual(result.count, 1)
    }

    func testRebindSurvivesDeletingAWordBeforeTypingItsReplacement() async {
        let result = await run([field("Please call Nora"), field("Please call", newElement: true),
                                field("Please call Zelvoriax")], produced: "Please call Nora")
        XCTAssertEqual(result.first?.replacement, "Zelvoriax")
    }

    func testSamePositionUnrelatedSingleWordDraftDoesNotLearn() async {
        let result = await run([field("Okay"), field("Thanks", newElement: true)], produced: "Okay")
        XCTAssertTrue(result.isEmpty)
    }

    func testOneWordDictationCanRebindWhileUnchangedThenLearn() async {
        let result = await run([field("Nora"), field("Nora", newElement: true), field("Zelvoriax", newElement: true)])
        XCTAssertEqual(result.first?.replacement, "Zelvoriax")
    }

    func testConversationContextChangesRejectEvenAtTheSamePosition() async {
        for key in ["placeholder", "description", "windowTitle"] {
            var changed = anchor()
            switch key {
            case "placeholder": changed.placeholder = "Message other conversation"
            case "description": changed.description = "Other conversation"
            default: changed.windowTitle = "Other conversation"
            }
            let result = await run([field("Please call Nora"),
                                    field("Please call Zelvoriax", newElement: true, anchor: changed)],
                                   produced: "Please call Nora")
            XCTAssertTrue(result.isEmpty, key)
        }
    }

    func testReusedPhysicalReferenceCannotIgnoreChangedConversationMetadata() async {
        var changed = anchor()
        changed.windowTitle = "Other conversation"
        let result = await run([field("Nora"), field("Zelvoriax", anchor: changed)])
        XCTAssertTrue(result.isEmpty)
    }

    func testNeverRebindsToAnotherFieldEvenWhenItContainsTheSameOutput() async {
        let other = anchor(y: 300)
        let result = await run([field("Nora", newElement: true, anchor: other),
                                field("Zelvoriax", newElement: true, anchor: other)])
        XCTAssertTrue(result.isEmpty)
    }

    func testNeverRebindsAcrossWindowsOrApps() async {
        let result = await run([
            field("Nora"), field("Zelvoriax", newElement: true, anchor: anchor(otherWindow: true)),
            field("Zelvoriax", newElement: true, bundle: "other.app")
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testRetiredInitialReferenceRequiresExactUneditedReadback() async {
        let accepted = await run([field("Nora", newElement: true), field("Zelvoriax", newElement: true)],
                                 retired: true, noAnchor: true)
        XCTAssertEqual(accepted.first?.replacement, "Zelvoriax")
        let rejected = await run([field("Zelvoriax", newElement: true)], retired: true, noAnchor: true)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testLiveUnanchoredReferenceCannotAdoptAnotherField() async {
        let result = await run([field("Nora", newElement: true), field("Zelvoriax", newElement: true)], noAnchor: true)
        XCTAssertTrue(result.isEmpty)
    }

    func testMissingSnapshotRecoversOnlyAfterExactOriginalAppReadback() async {
        let missing = TargetSnapshot(bundleID: "fixture.app", element: nil, value: nil, selectedText: nil, selectedRange: nil)
        let accepted = await run([nil, field("Nora", newElement: true), field("Zelvoriax", newElement: true)],
                                 target: missing, noAnchor: true)
        XCTAssertEqual(accepted.first?.replacement, "Zelvoriax")
        let alreadyEdited = await run([field("Zelvoriax", newElement: true)], target: missing, noAnchor: true)
        XCTAssertTrue(alreadyEdited.isEmpty)
        let unknownApp = TargetSnapshot(bundleID: nil, element: nil, value: nil, selectedText: nil, selectedRange: nil)
        let unknown = await run([field("Nora", newElement: true), field("Zelvoriax", newElement: true)],
                                target: unknownApp, noAnchor: true)
        XCTAssertTrue(unknown.isEmpty)
    }

    func testClearingComposerStopsBeforeAnUnrelatedNextMessage() async {
        let result = await run([field("Nora"), field("", newElement: true), field("Zelvoriax", newElement: true)])
        XCTAssertTrue(result.isEmpty)
    }

    func testReturningToPreInsertionPlaceholderAlsoEndsWatching() async {
        let result = await run([field("Nora"), field("Message", newElement: true), field("Zelvoriax", newElement: true)],
                               target: original(value: "Message"))
        XCTAssertTrue(result.isEmpty)
    }

    func testReboundEditorStillRejectsChangesOutsideDictatedSpan() async {
        let result = await run([field("beforeNora after"), field("changedZelvoriax after", newElement: true),
                                field("beforeZelvoriax after", newElement: true)],
                               target: original(value: "before after", location: 6))
        XCTAssertTrue(result.isEmpty)
    }

    func testAnchorRequiresWindowRoleAndPositionAndRejectsDuplicateIDsElsewhere() {
        XCTAssertTrue(anchor().matches(anchor()))
        XCTAssertFalse(anchor().matches(anchor(y: 300)))
        XCTAssertFalse(anchor().matches(anchor(otherWindow: true)))
        XCTAssertFalse(anchor(identifier: "composer").matches(anchor(identifier: "search")))
        XCTAssertFalse(anchor(identifier: "composer").matches(anchor(y: 300, identifier: "composer")))
        let grown = CorrectionFieldAnchor(window: window, role: kAXTextAreaRole, identifier: nil,
                                          frame: CGRect(x: 20, y: 10, width: 400, height: 90))
        XCTAssertTrue(anchor().matches(grown))
        let noGeometry = CorrectionFieldAnchor(window: window, role: kAXTextAreaRole, identifier: nil, frame: nil)
        XCTAssertFalse(noGeometry.matches(noGeometry))
    }

    func testPausedWatchDoesNotExtendItsDeadline() async {
        let observations = [field("Nora")] + Array<CorrectionFieldObservation?>(repeating: nil, count: 90)
            + [field("Zelvoriax", newElement: true)]
        // A broken extended deadline would reach the late edit around 280ms.
        // Keep the harness alive well beyond that point so it cannot hide it.
        let result = await run(observations, wait: .milliseconds(650))
        XCTAssertTrue(result.isEmpty)
    }

    func testStartingAnotherDictationCancelsThePreviousWatch() async {
        let reader = ScriptedCorrectionFields(anchor: anchor(), observations: [field("Noah"), field("Zelvoriax")])
        let watcher = EditWatcher(inserter: reader, interval: .milliseconds(3),
                                  duration: .milliseconds(200), stability: .milliseconds(2))
        var rows: [Int] = []
        watcher.start(rowID: 1, produced: "Nora", target: original(), knownTerms: []) { _, _, receipt in rows.append(receipt.rowID) }
        watcher.start(rowID: 2, produced: "Noah", target: original(), knownTerms: []) { _, _, receipt in rows.append(receipt.rowID) }
        try? await Task.sleep(for: .milliseconds(280))
        watcher.cancel()
        XCTAssertEqual(rows, [2])
    }
}
