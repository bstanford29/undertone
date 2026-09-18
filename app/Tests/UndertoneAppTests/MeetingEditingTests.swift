import XCTest
@testable import UndertoneApp

@MainActor
final class MeetingEditingTests: XCTestCase {
    private func session(title: String, summary: String? = nil,
                         notes: String? = nil, searchText: String? = nil) -> MeetingSession {
        MeetingSession(sessionID: "fixture-\(title)", title: title, startedAt: 0,
                       status: "ended", summary: summary, notes: notes, searchText: searchText)
    }

    func testSearchUsesTheEngineHaystackCaseInsensitively() {
        let row = session(title: "Quarterly planning", summary: "Owners assigned",
                          searchText: "quarterly planning owners assigned")
        XCTAssertTrue(MeetingModel.matches(session: row, query: "QUARTERLY"))
        XCTAssertTrue(MeetingModel.matches(session: row, query: "owners"))
        XCTAssertFalse(MeetingModel.matches(session: row, query: "northwind"))
    }

    func testEmptySearchKeepsEveryMeeting() {
        let row = session(title: "Quarterly planning", searchText: "quarterly planning")
        XCTAssertTrue(MeetingModel.matches(session: row, query: ""))
        XCTAssertTrue(MeetingModel.matches(session: row, query: "   "))
    }

    func testSearchFallsBackToTitleSummaryAndNotesWhenTheEngineSendsNoHaystack() {
        let row = session(title: "Process flows", summary: "Confirmed the V4 diagram",
                          notes: "Ask Priya about intake")
        XCTAssertTrue(MeetingModel.matches(session: row, query: "v4"))
        XCTAssertTrue(MeetingModel.matches(session: row, query: "priya"))
        XCTAssertTrue(MeetingModel.matches(session: row, query: "PROCESS"))
        XCTAssertFalse(MeetingModel.matches(session: row, query: "budget"))
    }

    func testSaveIsSkippedWhenTheDraftMatchesWhatIsStored() {
        XCTAssertFalse(MeetingModel.shouldSave(draft: "same", stored: "same"))
        XCTAssertFalse(MeetingModel.shouldSave(draft: "", stored: nil))
        XCTAssertTrue(MeetingModel.shouldSave(draft: "typed", stored: nil))
        XCTAssertTrue(MeetingModel.shouldSave(draft: "typed", stored: "other"))
    }

    func testSessionDecodesTheEditingFields() throws {
        let data = #"""
        {"session_id":"abc","title":"Quarterly planning","started_at":10.0,"ended_at":70.0,
         "status":"ended","summary":"## Key points","notes":"My notes","title_source":"auto",
         "summary_edited":1,"updated_at":99.5,"search_text":"quarterly planning my notes",
         "chunk_count":3}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: data)
        XCTAssertEqual(decoded.notes, "My notes")
        XCTAssertEqual(decoded.titleSource, "auto")
        XCTAssertEqual(decoded.summaryEdited, true)
        XCTAssertEqual(decoded.updatedAt, 99.5)
        XCTAssertEqual(decoded.searchText, "quarterly planning my notes")
        XCTAssertEqual(decoded.chunkCount, 3)
    }

    func testSessionFromAnOlderEngineStillDecodes() throws {
        let data = #"{"session_id":"abc","title":"Old meeting","started_at":10.0,"status":"ended"}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: data)
        XCTAssertEqual(decoded.title, "Old meeting")
        XCTAssertNil(decoded.notes)
        XCTAssertNil(decoded.titleSource)
        XCTAssertNil(decoded.summaryEdited)
        XCTAssertNil(decoded.updatedAt)
        XCTAssertNil(decoded.searchText)
    }

    func testSummaryMarkdownSplitsHeadingsAndBullets() {
        let blocks = MeetingSummaryMarkdown.blocks("""
        ## Key points
        - Sent the v4 diagram
        * Second point

        ## Decisions
        - None noted.
        Trailing sentence
        """)
        XCTAssertEqual(blocks, [
            .heading("Key points"),
            .bullet("Sent the v4 diagram"),
            .bullet("Second point"),
            .heading("Decisions"),
            .bullet("None noted."),
            .paragraph("Trailing sentence"),
        ])
    }

    func testUnstructuredSummaryStaysReadable() {
        XCTAssertEqual(MeetingSummaryMarkdown.blocks("One plain paragraph."),
                       [.paragraph("One plain paragraph.")])
        XCTAssertTrue(MeetingSummaryMarkdown.blocks("   \n  ").isEmpty)
    }
}
