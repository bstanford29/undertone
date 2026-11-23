import AppKit
import SwiftUI

/// One commit on GitHub's main that the checkout does not have yet.
struct UpdateChange: Codable, Equatable, Sendable, Identifiable {
    let commit: String
    let time: Double?
    let title: String

    var id: String { commit }
}

/// The engine's answer to `update.check`: how the checkout compares with
/// GitHub's main. Changes nothing on disk except the fetch.
struct UpdateCheck: Codable, Equatable, Sendable {
    /// `current`, `ready`, `blocked`, or `error`.
    let state: String
    let message: String?
    let changes: [UpdateChange]?
    let behind: Int?
    let head: String?
    /// The commit of GitHub's main this check saw. Update installs exactly this.
    let remote: String?
    let appChanged: Bool?
    let checkedAt: Double?

    enum CodingKeys: String, CodingKey {
        case state, message, changes, behind, head, remote
        case appChanged = "app_changed", checkedAt = "checked_at"
    }

    static func failure(_ message: String) -> UpdateCheck {
        UpdateCheck(state: "error", message: message, changes: nil, behind: nil, head: nil, remote: nil,
                    appChanged: nil, checkedAt: Date().timeIntervalSince1970)
    }
}

/// The last update or Go back, from `update.status`, `update.apply`, or `update.undo`.
struct UpdateRun: Codable, Equatable, Sendable {
    /// `idle`, `running`, `done`, `failed`, or `blocked`.
    let state: String
    let runID: String?
    let action: String?
    let message: String?
    let startedAt: Double?
    let finishedAt: Double?
    let canUndo: Bool?
    let logPath: String?

    enum CodingKeys: String, CodingKey {
        case state, action, message
        case runID = "run_id", startedAt = "started_at", finishedAt = "finished_at"
        case canUndo = "can_undo", logPath = "log_path"
    }

    static func failure(_ message: String) -> UpdateRun {
        UpdateRun(state: "failed", runID: nil, action: nil, message: message, startedAt: nil,
                  finishedAt: Date().timeIntervalSince1970, canUndo: nil, logPath: nil)
    }
}

/// What the Updates tab shows. A pure function of the model, so tests pin each state.
struct UpdateDisplay: Equatable {
    enum Action: Equatable { case check, install, finish, none }
    enum Tone: Equatable { case neutral, good, working, problem }

    let headline: String
    let detail: String?
    let action: Action
    let tone: Tone

    /// - Parameters:
    ///   - busy: what is in progress right now (dictation, a meeting, a quick note), or nil.
    ///   - finishing: the step the app is on while it finishes an update, or nil.
    ///   - pending: the checkout or the app bundle on disk is newer than what is running.
    ///   - finishProblem: why the last attempt to finish failed, with how to recover.
    static func make(check: UpdateCheck?, run: UpdateRun?, checking: Bool, busy: String?,
                     finishing: String? = nil, pending: Bool = false,
                     finishProblem: String? = nil) -> UpdateDisplay {
        if let run, run.state == "running" {
            return UpdateDisplay(headline: run.action == "undo" ? "Going back…" : "Updating…",
                                 detail: run.message, action: .none, tone: .working)
        }
        if let finishing {
            return UpdateDisplay(headline: "Finishing the update", detail: finishing, action: .none, tone: .working)
        }
        if checking {
            return UpdateDisplay(headline: "Checking GitHub…", detail: nil, action: .none, tone: .working)
        }
        if let finishProblem {
            return UpdateDisplay(headline: "Update not finished", detail: finishProblem,
                                 action: busy == nil && pending ? .finish : .check, tone: .problem)
        }
        let runTime = run?.finishedAt ?? run?.startedAt ?? 0
        if pending {
            return UpdateDisplay(headline: "Update installed",
                                 detail: busy.map { "It finishes when this ends: \($0)" }
                                    ?? "Restart the engine and reopen Undertone to use it.",
                                 action: busy == nil ? .finish : .none, tone: .neutral)
        }
        if let run, runTime >= (check?.checkedAt ?? 0) {
            switch run.state {
            case "failed", "blocked":
                return UpdateDisplay(headline: run.action == "undo" ? "Could not go back" : "Update did not finish",
                                     detail: run.message, action: .check, tone: .problem)
            case "done":
                return UpdateDisplay(headline: run.message ?? "Updated.", detail: nil, action: .check, tone: .good)
            default:
                break
            }
        }
        guard let check else {
            return UpdateDisplay(headline: "Not checked yet", detail: "Undertone checks only when you ask.",
                                 action: .check, tone: .neutral)
        }
        switch check.state {
        case "ready":
            let note = check.appChanged == true ? "The app is rebuilt, which takes a few minutes."
                : "Only the engine changes. This takes seconds."
            return UpdateDisplay(headline: check.message ?? "An update is ready.",
                                 detail: busy.map { "Update can start when this ends: \($0)" } ?? note,
                                 action: busy == nil ? .install : .none, tone: .neutral)
        case "current":
            return UpdateDisplay(headline: "Undertone is up to date.", detail: nil, action: .check, tone: .good)
        default:
            return UpdateDisplay(headline: "Can't update right now", detail: check.message, action: .check, tone: .problem)
        }
    }
}

/// Talks to the engine's `update.*` requests. The engine changes files in a
/// separate process and never restarts anything. This model finishes the
/// update: once nothing is in progress, it restarts the engine, waits until
/// the engine runs the new commit, and reopens the app if it was replaced.
@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var check: UpdateCheck?
    @Published private(set) var run: UpdateRun?
    @Published private(set) var checking = false
    /// The commit the running engine started from, from its last answer.
    @Published private(set) var engineCommit: String?
    @Published private(set) var finishing: String?
    /// Why the last attempt to finish failed, with the Terminal recovery command.
    @Published private(set) var finishProblem: String?
    /// The checkout has engine or package changes the running engine has not loaded.
    @Published private(set) var engineStale = false
    /// The commit stamped into this app's bundle on disk, read fresh. It differs
    /// from `appCommit` once an update replaced the bundle this process runs from.
    @Published private(set) var bundleCommitOnDisk: String?
    /// The checkout the engine runs from, for the Terminal recovery command.
    @Published private(set) var checkoutPath: String?
    /// What is in progress right now (dictation, a meeting, a quick note), or nil.
    var busyReason: (() -> String?)?

    private let engine: EngineClient
    private let previewMode: Bool
    private var poller: Task<Void, Never>?
    /// The run this app started. Only that run finishes on its own.
    private var acceptedRunID: String?

    init(engine: EngineClient, previewMode: Bool) {
        self.engine = engine
        self.previewMode = previewMode
        if previewMode {
            check = PreviewFixtures.updateCheck
            run = PreviewFixtures.updateRun
            engineCommit = PreviewFixtures.updateEngineCommit
            engineStale = PreviewFixtures.updateState == "installed"
            bundleCommitOnDisk = PreviewFixtures.updateAppCommit
        }
    }

    /// Waiting for a dictation, meeting, or quick note to end before finishing.
    private var waitingForIdle = false

    /// True while the engine restarts or the app reopens. New dictation,
    /// meetings, and quick notes wait for that, so nothing is cut off. While
    /// the update only waits for something to end, everything still works.
    var isFinishing: Bool { finishing != nil && !waitingForIdle }

    var display: UpdateDisplay {
        .make(check: check, run: run, checking: checking, busy: busyReason?(), finishing: finishing,
              pending: pending, finishProblem: finishProblem)
    }

    /// The commit this app was built from, stamped into Info.plist by build_app.sh.
    var appCommit: String? {
        previewMode ? PreviewFixtures.updateAppCommit
            : Bundle.main.object(forInfoDictionaryKey: "UndertoneBuildCommit") as? String
    }

    var canUndo: Bool { run?.canUndo == true && run?.state != "running" && finishing == nil }

    private var needsEngineRestart: Bool { engineStale }

    private var needsReopen: Bool {
        guard let disk = bundleCommitOnDisk, let running = appCommit else { return false }
        return disk != running
    }

    /// An update is on disk, but the engine or this app still runs older code.
    /// Worked out from what is running, not from the last run, so a later
    /// "up to date" run or a Terminal update cannot hide it.
    var pending: Bool { needsEngineRestart || needsReopen }

    /// Takes the live state from any `update.*` answer.
    private func adopt(_ response: EngineResponse) {
        engineCommit = response.engineCommit
        engineStale = response.engineStale ?? false
        if let checkout = response.checkout { checkoutPath = checkout }
        bundleCommitOnDisk = Self.readBundleCommit()
    }

    /// Reads Info.plist from disk, not the copy loaded at launch.
    private static func readBundleCommit() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["UndertoneBuildCommit"] as? String
    }

    /// Reads the last run, so an update still running, or one that failed or
    /// still needs finishing, shows when Settings opens.
    func loadStatus() async {
        guard !previewMode, let response = try? await engine.request(op: "update.status") else { return }
        adopt(response)
        guard let latest = response.updateRun else { return }
        run = latest
        if latest.state == "running" { poll() }
    }

    func checkNow() async {
        guard !previewMode, !checking, finishing == nil, run?.state != "running" else { return }
        checking = true
        finishProblem = nil
        defer { checking = false }
        do {
            let response = try await engine.request(op: "update.check", fields: appPathField)
            check = response.update ?? .failure("The engine sent no update details.")
            adopt(response)
            if let latest = response.updateRun { run = latest }
        } catch {
            check = .failure("The engine did not answer. Is it running?")
        }
    }

    func install() async {
        guard !previewMode, display.action == .install, let remote = check?.remote else { return }
        var fields = appPathField
        fields["expect"] = .string(remote)
        await start(op: "update.apply", fields: fields)
    }

    func undo() async {
        guard !previewMode, busyReason?() == nil, canUndo else { return }
        await start(op: "update.undo", fields: [:])
    }

    func showLog() {
        guard !previewMode, let path = run?.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The running app's own bundle, so check and apply look at the same app.
    private var appPathField: [String: JSONValue] {
        ["app_path": .string(Bundle.main.bundleURL.standardizedFileURL.path)]
    }

    private func start(op: String, fields: [String: JSONValue]) async {
        do {
            let response = try await engine.request(op: op, fields: fields)
            adopt(response)
            guard let latest = response.updateRun else { return }
            run = latest
            if latest.state == "running" {
                acceptedRunID = latest.runID
                poll()
            }
        } catch {
            // The reply was lost, not necessarily the request: read what happened.
            await loadStatus()
            if run?.state == "running" {
                acceptedRunID = run?.runID
            } else {
                run = .failure("The engine did not answer. Check again in a moment.")
            }
        }
    }

    /// Polls once a second while a run is going.
    private func poll() {
        poller?.cancel()
        poller = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard let response = try? await self.engine.request(op: "update.status"),
                      let latest = response.updateRun else {
                    misses += 1
                    if misses >= 60 {
                        self.run = .failure("Lost contact with the engine during the update. The log has the details.")
                        return
                    }
                    continue
                }
                misses = 0
                self.adopt(response)
                self.run = latest
                guard latest.state != "running" else { continue }
                if latest.state == "done", latest.runID != nil, latest.runID == self.acceptedRunID {
                    self.acceptedRunID = nil
                    await self.finish()
                }
                return
            }
        }
    }

    /// Restarts the engine and reopens the app once nothing is in progress.
    /// Runs on its own after an update this app started; otherwise from the
    /// "Finish update" button.
    func finish() async {
        guard !previewMode, finishing == nil, pending else { return }
        finishProblem = nil
        await waitUntilIdle()
        if needsEngineRestart {
            finishing = "Restarting the engine."
            let restarted = await EngineRestarter.restart()
            var answered = false
            var waited = 0
            while restarted, waited < 60 {
                try? await Task.sleep(for: .seconds(1))
                waited += 1
                if let response = try? await engine.request(op: "update.status") {
                    adopt(response)
                    answered = true
                    if !needsEngineRestart { break }
                }
            }
            if needsEngineRestart || !answered {
                finishing = nil
                let folder = checkoutPath ?? "the Undertone folder"
                finishProblem = "The engine did not come back on the new version. To go back, run `.venv/bin/undertone update --undo` in Terminal in \(folder), then use Restart in Settings → Privacy."
                return
            }
        }
        if needsReopen {
            // Checked again here: something may have started during the restart.
            await waitUntilIdle()
            finishing = "Reopening Undertone."
            Self.reopen(at: Bundle.main.bundleURL.path)
            return
        }
        finishing = nil
    }

    /// Returns on the main actor with nothing in progress. The caller's next
    /// step starts before any new capture can, because nothing awaits between.
    private func waitUntilIdle() async {
        while let reason = busyReason?() {
            waitingForIdle = true
            finishing = "It finishes when this ends: \(reason)"
            try? await Task.sleep(for: .seconds(1))
        }
        waitingForIdle = false
        finishing = finishing ?? "Finishing."
    }

    /// Waits for this process to exit, then opens the new app at the same path.
    private static func reopen(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(getpid()), path]
        do { try process.run() } catch { return }
        NSApp.terminate(nil)
    }
}

// MARK: - Settings tab

struct UpdatesSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let updates = model.updates
        let display = updates.display
        SettingsPage {
            Section("Version") {
                LabeledContent {
                    Text(Self.short(updates.appCommit)).font(.system(.body, design: .monospaced))
                } label: {
                    SettingLabel(title: "This app", detail: "The commit it was built from.")
                }
                LabeledContent {
                    Text(Self.short(updates.engineCommit)).font(.system(.body, design: .monospaced))
                } label: {
                    SettingLabel(title: "Engine", detail: "The commit the engine started from.")
                }
            }
            Section {
                HStack(alignment: .top, spacing: 10) {
                    statusIcon(display.tone)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.headline).font(.body.weight(.medium))
                        if let detail = display.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
                if display.action == .install, let changes = updates.check?.changes, !changes.isEmpty {
                    ForEach(changes) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(change.commit).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Text(change.title).font(.callout)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Check for updates") { Task { await updates.checkNow() } }
                        .disabled(display.tone == .working)
                    if display.action == .install {
                        Button("Update now") { Task { await updates.install() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if display.action == .finish {
                        Button("Finish update") { Task { await updates.finish() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    if display.tone == .problem, updates.run?.logPath != nil {
                        Button("Show log") { updates.showLog() }
                    }
                }
                if updates.canUndo {
                    LabeledContent {
                        Button("Go back") { Task { await updates.undo() } }
                    } label: {
                        SettingLabel(title: "Previous version",
                                     detail: "Puts back the app and engine from before the last update.")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Undertone updates from its git checkout on GitHub's main. A check fetches from GitHub and sends no audio, transcripts, or settings. The engine restarts and the app reopens only when no dictation, meeting, or quick note is in progress.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await updates.loadStatus() }
    }

    nonisolated static func short(_ commit: String?) -> String {
        guard let commit, !commit.isEmpty else { return "unknown" }
        return String(commit.prefix(7))
    }

    @ViewBuilder
    private func statusIcon(_ tone: UpdateDisplay.Tone) -> some View {
        switch tone {
        case .working:
            ProgressView().controlSize(.small)
        case .good:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .neutral:
            Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
        }
    }
}
