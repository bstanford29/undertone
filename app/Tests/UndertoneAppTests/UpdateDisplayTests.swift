import XCTest
@testable import UndertoneApp

/// What the Updates tab shows in each state, and that the engine's answers decode.
final class UpdateDisplayTests: XCTestCase {
    private func check(_ state: String, appChanged: Bool = false, at time: Double = 100) -> UpdateCheck {
        UpdateCheck(state: state, message: state == "ready" ? "2 new changes ready to install." : "The checkout is on branch work.",
                    changes: [], behind: state == "ready" ? 2 : 0, head: "abc1234", remote: "def5678",
                    appChanged: appChanged, checkedAt: time)
    }

    private func run(_ state: String, action: String = "update", finished: Double? = 200) -> UpdateRun {
        UpdateRun(state: state, runID: "r1", action: action, message: "Step or result.", startedAt: 150,
                  finishedAt: finished, canUndo: state == "done", logPath: "/tmp/update.log")
    }

    func testEngineResponseDecodesBothUpdatePayloads() throws {
        let json = """
        {"id": 7, "update": {"state": "ready", "message": "1 new change ready to install.", "behind": 1,
          "changes": [{"commit": "abc1234", "time": 1700000000, "title": "Fix a thing"}],
          "head": "0123456789", "app_commit": null, "app_changed": true, "engine_changed": false,
          "checked_at": 1700000100, "ahead": 0, "remote": "abc1234"},
         "update_run": {"state": "done", "action": "update", "run_id": "abc", "pid": 42, "new": "def5678",
          "restart_engine": true, "relaunch": true, "app_commit": "def5678",
          "message": "Updated to def5678.", "started_at": 1700000200, "can_undo": true, "log_path": "/x/update.log"},
         "engine_commit": "abc1234", "engine_stale": true, "checkout": "/Users/example/undertone"}
        """
        let response = try JSONDecoder().decode(EngineResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.update?.state, "ready")
        XCTAssertEqual(response.update?.changes?.first?.title, "Fix a thing")
        XCTAssertEqual(response.update?.appChanged, true)
        XCTAssertEqual(response.update?.remote, "abc1234")
        XCTAssertEqual(response.updateRun?.runID, "abc")
        XCTAssertEqual(response.updateRun?.canUndo, true)
        XCTAssertEqual(response.engineCommit, "abc1234")
        XCTAssertEqual(response.engineStale, true)
        XCTAssertEqual(response.checkout, "/Users/example/undertone")
    }

    func testReadyOffersInstallUnlessSomethingIsInProgress() {
        let ready = UpdateDisplay.make(check: check("ready", appChanged: true), run: nil, checking: false, busy: nil)
        XCTAssertEqual(ready.action, .install)
        XCTAssertEqual(ready.headline, "2 new changes ready to install.")
        XCTAssertEqual(ready.detail, "The app is rebuilt, which takes a few minutes.")

        let busy = UpdateDisplay.make(check: check("ready"), run: nil, checking: false, busy: "A dictation is in progress.")
        XCTAssertEqual(busy.action, .none)
        XCTAssertEqual(busy.detail, "Update can start when this ends: A dictation is in progress.")
    }

    func testRunningAndCheckingOfferNothing() {
        let running = UpdateDisplay.make(check: check("ready"), run: run("running", finished: nil), checking: false, busy: nil)
        XCTAssertEqual(running.action, .none)
        XCTAssertEqual(running.tone, .working)
        XCTAssertEqual(running.headline, "Updating…")
        XCTAssertEqual(UpdateDisplay.make(check: nil, run: run("running", action: "undo", finished: nil),
                                          checking: false, busy: nil).headline, "Going back…")
        XCTAssertEqual(UpdateDisplay.make(check: nil, run: nil, checking: true, busy: nil).tone, .working)
    }

    func testANewerRunResultWinsOverAnOlderCheck() {
        let failed = UpdateDisplay.make(check: check("ready", at: 100), run: run("failed", finished: 200), checking: false, busy: nil)
        XCTAssertEqual(failed.tone, .problem)
        XCTAssertEqual(failed.headline, "Update did not finish")

        let newerCheck = UpdateDisplay.make(check: check("ready", at: 300), run: run("failed", finished: 200), checking: false, busy: nil)
        XCTAssertEqual(newerCheck.action, .install)

        let done = UpdateDisplay.make(check: nil, run: run("done"), checking: false, busy: nil)
        XCTAssertEqual(done.tone, .good)
        XCTAssertEqual(done.headline, "Step or result.")
    }

    func testAnInstalledUpdateFinishesOnlyWhenNothingIsInProgress() {
        let idle = UpdateDisplay.make(check: nil, run: run("done"), checking: false, busy: nil, pending: true)
        XCTAssertEqual(idle.headline, "Update installed")
        XCTAssertEqual(idle.action, .finish)

        let busy = UpdateDisplay.make(check: nil, run: run("done"), checking: false,
                                      busy: "Meeting notes are recording.", pending: true)
        XCTAssertEqual(busy.action, .none)
        XCTAssertEqual(busy.detail, "It finishes when this ends: Meeting notes are recording.")

        let finishing = UpdateDisplay.make(check: nil, run: run("done"), checking: false, busy: nil,
                                           finishing: "Restarting the engine.", pending: true)
        XCTAssertEqual(finishing.tone, .working)
        XCTAssertEqual(finishing.action, .none)
    }

    func testAnUpdateStillToFinishShowsWhateverTheLastRunWas() {
        let afterUpToDate = UpdateDisplay.make(check: check("current", at: 300), run: run("done", finished: 310),
                                               checking: false, busy: nil, pending: true)
        XCTAssertEqual(afterUpToDate.action, .finish)
    }

    func testAFailedFinishShowsItsRecoveryCommandAheadOfPending() {
        let shown = UpdateDisplay.make(check: nil, run: run("done"), checking: false, busy: nil, pending: true,
                                       finishProblem: "Run `.venv/bin/undertone update --undo` in Terminal.")
        XCTAssertEqual(shown.tone, .problem)
        XCTAssertEqual(shown.detail, "Run `.venv/bin/undertone update --undo` in Terminal.")
        XCTAssertEqual(shown.action, .finish, "Finish update stays available to try again")
    }

    func testBlockedAndCurrentStates() {
        let blocked = UpdateDisplay.make(check: check("blocked"), run: nil, checking: false, busy: nil)
        XCTAssertEqual(blocked.tone, .problem)
        XCTAssertEqual(blocked.detail, "The checkout is on branch work.")
        XCTAssertEqual(blocked.action, .check)
        XCTAssertEqual(UpdateDisplay.make(check: check("current"), run: nil, checking: false, busy: nil).tone, .good)
        XCTAssertEqual(UpdateDisplay.make(check: nil, run: nil, checking: false, busy: nil).headline, "Not checked yet")
    }

    func testVersionTextIsTheShortCommit() {
        XCTAssertEqual(UpdatesSettingsTab.short("0123456789abcdef"), "0123456")
        XCTAssertEqual(UpdatesSettingsTab.short(nil), "unknown")
    }
}
