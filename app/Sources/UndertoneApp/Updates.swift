import AppKit
import SwiftUI

/// One commit waiting on GitHub's main.
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
    let appCommit: String?
    let appChanged: Bool?
    let checkedAt: Double?

    enum CodingKeys: String, CodingKey {
        case state, message, changes, behind, head
        case appCommit = "app_commit", appChanged = "app_changed", checkedAt = "checked_at"
    }

    static func failure(_ message: String) -> UpdateCheck {
        UpdateCheck(state: "error", message: message, changes: nil, behind: nil, head: nil,
                    appCommit: nil, appChanged: nil, checkedAt: Date().timeIntervalSince1970)
    }
}

/// The last update or undo, from `update.status`, `update.apply`, or `update.undo`.
struct UpdateRun: Codable, Equatable, Sendable {
    /// `idle`, `running`, `done`, `failed`, or `blocked`.
    let state: String
    let action: String?
    let message: String?
    let startedAt: Double?
    let finishedAt: Double?
    let relaunch: Bool?
    let appPath: String?
    let canUndo: Bool?
    let logPath: String?

    enum CodingKeys: String, CodingKey {
        case state, action, message, relaunch
        case startedAt = "started_at", finishedAt = "finished_at", appPath = "app_path"
        case canUndo = "can_undo", logPath = "log_path"
    }

    static func failure(_ message: String) -> UpdateRun {
        UpdateRun(state: "failed", action: nil, message: message, startedAt: nil,
                  finishedAt: Date().timeIntervalSince1970, relaunch: nil, appPath: nil, canUndo: nil, logPath: nil)
    }
}

/// What the Updates tab shows. A pure function of the model, so tests pin each state.
struct UpdateDisplay: Equatable {
    enum Action: Equatable { case check, install, none }
    enum Tone: Equatable { case neutral, good, working, problem }

    let headline: String
    let detail: String?
    let action: Action
    let tone: Tone

    static func make(check: UpdateCheck?, run: UpdateRun?, checking: Bool, busy: String?) -> UpdateDisplay {
        if let run, run.state == "running" {
            return UpdateDisplay(headline: run.action == "undo" ? "Going back…" : "Updating…",
                                 detail: run.message, action: .none, tone: .working)
        }
        if checking {
            return UpdateDisplay(headline: "Checking GitHub…", detail: nil, action: .none, tone: .working)
        }
        let runTime = run?.finishedAt ?? run?.startedAt ?? 0
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
            let note = check.appChanged == true ? "The app is rebuilt, which takes a few minutes." : "Only the engine changes. This takes seconds."
            return UpdateDisplay(headline: check.message ?? "An update is ready.", detail: busy ?? note,
                                 action: busy == nil ? .install : .none, tone: .neutral)
        case "current":
            return UpdateDisplay(headline: "Undertone is up to date.", detail: nil, action: .check, tone: .good)
        default:
            return UpdateDisplay(headline: "Can't update right now", detail: check.message, action: .check, tone: .problem)
        }
    }
}

/// Talks to the engine's `update.*` requests. The engine does the work in a
/// separate process; this polls its status and reopens the app when the app
/// itself was replaced.
@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var check: UpdateCheck?
    @Published private(set) var run: UpdateRun?
    @Published private(set) var checking = false
    /// Why an update must wait right now (dictation, a meeting, an open quick
    /// note), or nil when it can start.
    var busyReason: (() -> String?)?

    private let engine: EngineClient
    private let previewMode: Bool
    private var poller: Task<Void, Never>?
    /// Only a run this app started may close and reopen it.
    private var startedHere = false

    init(engine: EngineClient, previewMode: Bool) {
        self.engine = engine
        self.previewMode = previewMode
        if previewMode {
            check = PreviewFixtures.updateCheck
            run = PreviewFixtures.updateRun
        }
    }

    var display: UpdateDisplay {
        .make(check: check, run: run, checking: checking, busy: busyReason?())
    }

    /// The commit this app was built from, stamped into Info.plist by build_app.sh.
    var appCommit: String? {
        previewMode ? PreviewFixtures.updateAppCommit
            : Bundle.main.object(forInfoDictionaryKey: "UndertoneBuildCommit") as? String
    }

    var canUndo: Bool { run?.canUndo == true && run?.state != "running" }

    /// Reads the last run, so an update still running, or one that failed
    /// earlier, shows when Settings opens.
    func loadStatus() async {
        guard !previewMode, let response = try? await engine.request(op: "update.status"),
              let latest = response.updateRun else { return }
        run = latest
        if latest.state == "running" { poll() }
    }

    func checkNow() async {
        guard !previewMode, !checking, run?.state != "running" else { return }
        checking = true
        defer { checking = false }
        do {
            let response = try await engine.request(op: "update.check")
            check = response.update ?? .failure("The engine sent no update details.")
            if let latest = response.updateRun { run = latest }
        } catch {
            check = .failure("The engine did not answer. Is it running?")
        }
    }

    func install() async {
        guard !previewMode, busyReason?() == nil, display.action == .install else { return }
        await start(op: "update.apply", fields: ["app_path": .string(Bundle.main.bundlePath)])
    }

    func undo() async {
        guard !previewMode, busyReason?() == nil, canUndo else { return }
        await start(op: "update.undo", fields: [:])
    }

    func showLog() {
        guard !previewMode, let path = run?.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func start(op: String, fields: [String: JSONValue]) async {
        do {
            let response = try await engine.request(op: op, fields: fields)
            guard let latest = response.updateRun else { return }
            run = latest
            if latest.state == "running" {
                startedHere = true
                poll()
            }
        } catch {
            run = .failure("The engine did not answer. Nothing changed.")
        }
    }

    /// Polls once a second. The engine restarts near the end of an update, so
    /// missed answers are expected for a while.
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
                    if misses >= 120 {
                        self.run = .failure("Lost contact with the engine during the update. The log has the details.")
                        return
                    }
                    continue
                }
                misses = 0
                self.run = latest
                if latest.state != "running" {
                    self.finished(latest)
                    return
                }
            }
        }
    }

    private func finished(_ latest: UpdateRun) {
        guard startedHere else { return }
        startedHere = false
        guard latest.state == "done" else { return }
        check = nil
        if latest.relaunch == true, let path = latest.appPath {
            Self.reopen(at: path)
        }
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
                    Text(Self.short(updates.check?.head)).font(.system(.body, design: .monospaced))
                } label: {
                    SettingLabel(title: "Engine", detail: "The commit the engine runs, known after a check.")
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
                        .disabled(display.action == .none && display.tone == .working)
                    if display.action == .install {
                        Button("Update now") { Task { await updates.install() } }
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
                Text("Undertone updates from its git checkout on GitHub's main. A check fetches from GitHub and sends no audio, transcripts, or settings. It waits while you dictate or record a meeting.")
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
