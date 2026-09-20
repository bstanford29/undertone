import SwiftUI
import AVFoundation
import AppKit

enum PreviewAppearance: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    var nsAppearance: NSAppearance.Name {
        self == .light ? .aqua : .darkAqua
    }

    @MainActor static func initial() -> PreviewAppearance {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--appearance"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let value = PreviewAppearance(rawValue: ProcessInfo.processInfo.arguments[index + 1].capitalized) {
            return value
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
/// The dock states the preview can be pinned to, so a screenshot run does not
/// depend on hovering anything.
enum PreviewDockState: String, CaseIterable, Identifiable {
    case idle
    case hover
    case resume
    case listening
    case working
    case holdkey
    case inserted
    case guarded
    case error
    case saved
    case recording
    case meetingEnded
    case meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .hover: return "Hover"
        case .resume: return "Resume"
        case .listening: return "Dictating"
        case .working: return "Working"
        case .holdkey: return "Release fn"
        case .inserted: return "Inserted"
        case .guarded: return "Kept raw"
        case .error: return "Error"
        case .saved: return "Saved"
        case .recording: return "Recording"
        case .meetingEnded: return "Meeting ended"
        case .meeting: return "Meeting detected"
        }
    }

    /// `--pill-state recording` opens the Pill tab on one state. "record" is
    /// kept as an alias for the flag the older capture script used.
    static func initial() -> PreviewDockState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--pill-state"),
              arguments.indices.contains(index + 1) else { return nil }
        let raw = arguments[index + 1].lowercased()
        if raw == "record" { return .recording }
        if raw == "meetingdetected" { return .meeting }
        if raw == "meetingended" { return .meetingEnded }
        return PreviewDockState(rawValue: raw)
    }
}

/// Fixed backdrops so the light and dark captures are repeatable whichever
/// desktop picture the Mac happens to have.
struct FlowBarPreviewStage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chrome: FlowBarChrome
    let dark: Bool

    private static let deskSize = CGSize(width: 620, height: 380)

    private var alignment: Alignment {
        switch model.pillEdge {
        case .right: return .trailing
        case .left: return .leading
        case .bottom: return .bottom
        case .top: return .top
        }
    }

    var body: some View {
        let state = FlowBarState.viewState(model: model, hovered: chrome.hovered, open: chrome.open)
        let size = FlowBarDock.panelSize(for: state, edge: model.pillEdge)
        ZStack(alignment: alignment) {
            wall
            FlowBarDockView(chrome: chrome)
                .environmentObject(model)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: Self.deskSize.width, height: Self.deskSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var wall: some View {
        RadialGradient(
            colors: dark
                ? [Color(red: 0.157, green: 0.192, blue: 0.235), Color(red: 0.078, green: 0.102, blue: 0.129)]
                : [Color(red: 0.980, green: 0.984, blue: 0.988), Color(red: 0.875, green: 0.894, blue: 0.914)],
            center: UnitPoint(x: 0.62, y: -0.12), startRadius: 40, endRadius: 620
        )
    }
}

enum PreviewScreen: String, CaseIterable, Identifiable {
    case pill = "Pill"
    case history = "History"
    case dictionary = "Dictionary"
    case meetings = "Meetings"
    case settings = "Settings"
    case setup = "Setup"
    case app = "App"
    var id: String { rawValue }

    /// `--screen meetings` opens straight to one screen, so a screenshot run
    /// does not depend on clicking the picker.
    static func initial() -> PreviewScreen {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--screen"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return .pill }
        return PreviewScreen(rawValue: ProcessInfo.processInfo.arguments[index + 1].capitalized) ?? .pill
    }
}

@MainActor
struct PreviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var screen: PreviewScreen = PreviewScreen.initial()
    @State private var appearance = PreviewAppearance.initial()
    @State private var speechDemo = false

    /// `--edge left` stands the pill on end for a vertical-dock capture.
    @MainActor static func initialEdge() -> PillEdge? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--edge"),
              arguments.indices.contains(index + 1) else { return nil }
        return PillEdge(rawValue: arguments[index + 1].lowercased())
    }

    @StateObject private var dockChrome = FlowBarChrome()
    @State private var dockState: PreviewDockState = PreviewDockState.initial() ?? .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Undertone preview").font(.title2.bold())
                Spacer()
                Text("Synthetic fixtures · no engine calls").font(.caption).foregroundStyle(.secondary)
                Button("Quit") { NSApp.terminate(nil) }
            }
            HStack {
                Text("Appearance").foregroundStyle(.secondary)
                Picker("Appearance", selection: $appearance) {
                    ForEach(PreviewAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Picker("Preview", selection: $screen) {
                ForEach(PreviewScreen.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Group {
                switch screen {
                case .pill:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Flow Bar states").font(.headline)
                        Picker("State", selection: $dockState) {
                            ForEach(PreviewDockState.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        HStack {
                            Text("Edge").foregroundStyle(.secondary)
                            Picker("Edge", selection: $model.pillEdge) {
                                Text("Bottom").tag(PillEdge.bottom)
                                Text("Top").tag(PillEdge.top)
                                Text("Left").tag(PillEdge.left)
                                Text("Right").tag(PillEdge.right)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 280)
                            Toggle("Command mode", isOn: $model.commandMode)
                            Button(speechDemo ? "Stop demo" : "Speech demo") { speechDemo.toggle() }
                        }
                        FlowBarPreviewStage(chrome: dockChrome, dark: appearance == .dark)
                            .environmentObject(model)
                        HStack {
                            Button("Open History window") { model.openWindow("History Preview") { HistoryView() } }
                            Button("Open Meetings window") { model.openWindow("Meetings Preview") { MeetingView() } }
                            Button("Open Settings window") { model.openWindow("Settings Preview") { SettingsView() } }
                        }
                        .task(id: speechDemo) {
                            guard speechDemo else { return }
                            var tick = 0.0
                            while !Task.isCancelled {
                                let level = 0.02 + (0.42 * (0.5 + 0.5 * sin(tick)))
                                model.pillState = .listening(level: level)
                                tick += 0.34
                                try? await Task.sleep(for: .milliseconds(20))
                            }
                        }
                    }
                    .onChange(of: dockState) { _, value in applyDockState(value) }
                case .history:
                    HistoryView()
                case .dictionary:
                    DictionaryView()
                case .meetings:
                    VStack(alignment: .leading, spacing: 12) {
                        MeetingView()
                        Text("Floating meeting indicator preview").font(.caption).foregroundStyle(.secondary)
                        MeetingRecordingPanelView()
                    }
                case .settings:
                    SettingsView()
                case .setup:
                    SetupView()
                case .app:
                    NativeAppView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(minWidth: 850, minHeight: 600)
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            applyAppearance()
            applyCLIPillOptions()
        }
        .onChange(of: appearance) { _, _ in applyAppearance() }
        .onChange(of: model.appPage) { _, _ in screen = .app }
        .onChange(of: screen) { _, newScreen in
            if newScreen != .pill { speechDemo = false }
        }
    }

    private func applyAppearance() {
        // This changes only Undertone's process appearance, never System Settings.
        NSApp.appearance = NSAppearance(named: appearance.nsAppearance)
    }

    private func applyCLIPillOptions() {
        if let edge = Self.initialEdge() { model.pillEdge = edge }
        applyDockState(dockState)
    }

    /// Pins the dock to one state, with no pointer and no engine behind it.
    private func applyDockState(_ state: PreviewDockState) {
        speechDemo = false
        model.commandMode = false
        model.workingNote = nil
        dockChrome.open = false
        dockChrome.hovered = nil
        switch state {
        case .idle:
            model.pillState = .idle
        case .hover:
            model.pillState = .idle
            dockChrome.open = true
            dockChrome.hovered = .dictate
        case .resume:
            // Arms the offer auto-stop would leave behind, then hovers the
            // control that carries it.
            model.meetings.previewAutoStop()
            model.pillState = .idle
            dockChrome.open = true
            dockChrome.hovered = .newNote
        case .listening:
            model.pillState = .listening(level: 0.7)
        case .working:
            model.pillState = .working
        case .holdkey:
            model.workingNote = "Release fn to insert"
            model.pillState = .working
        case .inserted:
            model.pillState = .inserted(totalMS: 742)
        case .guarded:
            model.pillState = .guarded(totalMS: 957)
        case .error:
            model.pillState = .error("Insertion failed: app changed")
        case .saved:
            model.pillState = .notice("Saved")
        case .recording:
            model.pillState = .recording(elapsed: PreviewFixtures.recordingElapsed)
        case .meetingEnded:
            model.pillState = .notice("Meeting ended")
        case .meeting:
            model.pillState = .meetingDetected(Self.initialDetectedMeeting())
        }
    }

    /// `--platform teams` picks which call the nudge card names.
    @MainActor static func initialDetectedMeeting() -> DetectedMeeting {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--platform"),
              arguments.indices.contains(index + 1) else { return PreviewFixtures.detectedMeeting }
        return PreviewFixtures.detectedMeeting(named: arguments[index + 1].lowercased())
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var level = "medium"
    @State private var vaultPath = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Check microphone, keyboard, and screen capture access.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Permissions") { model.appPage = .permissions }
                }
            }
            Section("General") {
                Picker("Cleanup", selection: $level) {
                    Text("None").tag("none")
                    Text("Light").tag("light")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                Toggle("Tick on start and insert", isOn: $model.soundsEnabled)
                    .onChange(of: model.soundsEnabled) { _, value in
                        guard !model.previewMode else { return }
                        model.updateConfig("sounds", .bool(value))
                    }
                Toggle("Type text as it is cleaned", isOn: $model.streamInsert)
                    .onChange(of: model.streamInsert) { _, value in
                        guard !model.previewMode else { return }
                        model.updateConfig("stream_insert", .bool(value))
                    }
                Toggle("Whisper mode", isOn: $model.whisperMode)
                    .onChange(of: model.whisperMode) { _, value in
                        guard !model.previewMode else { return }
                        model.updateConfig("whisper_mode", .bool(value))
                    }
                Toggle("Learn from my corrections", isOn: $model.learnFromCorrections)
                    .onChange(of: model.learnFromCorrections) { _, value in
                        guard !model.previewMode else { return }
                        model.updateConfig(CorrectionLearningSetting.key, .bool(value))
                    }
                LabeledContent("Hold key", value: "fn / F13")
            }
            Section("Models") {
                LabeledContent("Speech", value: "whisper-large-v3-turbo")
                LabeledContent("Cleanup", value: "qwen3.5 · fast")
                Text("High uses gemma4:31b").foregroundStyle(.secondary)
            }
            Section("Tone by app") {
                LabeledContent("Codex, Claude, Ghostty", value: "Neutral")
                LabeledContent("Messages", value: "Casual")
                LabeledContent("Mail", value: "Formal")
            }
            Section("Pill") {
                Picker("Edge", selection: $model.pillEdge) {
                    Text("Bottom").tag(PillEdge.bottom)
                    Text("Top").tag(PillEdge.top)
                    Text("Left").tag(PillEdge.left)
                    Text("Right").tag(PillEdge.right)
                }
                .onChange(of: model.pillEdge) { _, value in
                    guard !model.previewMode else { return }
                    model.setPillDock(edge: value, offset: model.pillOffset)
                }
                Toggle("Keep pill on screen when idle", isOn: $model.pillPersistent)
                    .onChange(of: model.pillPersistent) { _, value in
                        guard !model.previewMode else { return }
                        model.updateConfig("pill_persistent", .bool(value))
                    }
                Toggle("Detect calls automatically", isOn: $model.detectCallsEnabled)
                    .onChange(of: model.detectCallsEnabled) { _, value in
                        model.setDetectCallsEnabled(value)
                    }
                Text("When a call app takes the microphone, the dock offers to start meeting notes. Turn this off and it stays quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Opt+M meeting notes · Opt+S quick note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset position") { model.resetPillPosition() }
            }
            Section("Meeting notes") {
                HStack {
                    Text(vaultPath.isEmpty ? "No Obsidian vault selected" : vaultPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose vault…") { chooseVault() }
                        .disabled(model.previewMode)
                }
                Text("Choose a vault explicitly before exporting meeting summaries. Undertone never guesses this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = model.configError ?? errorMessage {
                Text(message).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if model.previewMode {
                if case .string(let value) = PreviewFixtures.config["cleanup_level"] { level = value }
                if case .bool(let value) = PreviewFixtures.config["sounds"] { model.soundsEnabled = value }
                if case .bool(let value) = PreviewFixtures.config["stream_insert"] { model.streamInsert = value }
                if case .bool(let value) = PreviewFixtures.config["whisper_mode"] { model.whisperMode = value }
                model.learnFromCorrections = CorrectionLearningSetting.value(from: PreviewFixtures.config)
                if case .string(let value) = PreviewFixtures.config["obsidian_vault_path"] { vaultPath = value }
                return
            }
            Task { await loadConfig() }
        }
        .onChange(of: level) { _, value in
            model.cleanupLevel = value
            guard !model.previewMode else { return }
            model.updateConfig("cleanup_level", .string(value))
        }
    }

    private func loadConfig() async {
        do {
            let response = try await model.engine.request(op: "config.get")
            guard let config = response.config else { return }
            if case .string(let value) = config["cleanup_level"] { level = value; model.cleanupLevel = value }
            if case .bool(let value) = config["sounds"] { model.soundsEnabled = value }
            if case .bool(let value) = config["stream_insert"] { model.streamInsert = value }
            if case .bool(let value) = config["whisper_mode"] { model.whisperMode = value }
            model.learnFromCorrections = CorrectionLearningSetting.value(from: config)
            if case .string(let value) = config["obsidian_vault_path"] { vaultPath = value }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultPath = url.path
        model.updateConfig("obsidian_vault_path", .string(url.path))
    }
}

enum HistoryDateFilter: String, CaseIterable, Identifiable {
    case all = "All time"
    case today = "Today"
    case week = "Last 7 days"
    var id: String { rawValue }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rows: [HistoryRow] = []
    @State private var selectedID: Int?
    @State private var query = ""
    @State private var appFilter = "All apps"
    @State private var dateFilter: HistoryDateFilter = .all
    @State private var errorMessage: String?

    private var apps: [String] {
        ["All apps"] + Array(Set(rows.compactMap(\.appBundleID))).sorted()
    }

    var visibleRows: [HistoryRow] {
        rows.filter { row in
            let matchesApp = appFilter == "All apps" || row.appBundleID == appFilter
            let matchesQuery = query.isEmpty || [row.rawText, row.cleanText, row.editedText]
                .compactMap { $0?.localizedCaseInsensitiveContains(query) }
                .contains(true)
            let matchesDate: Bool
            if dateFilter == .all {
                matchesDate = true
            } else {
                let age = Date().timeIntervalSince1970 - (row.ts ?? 0)
                matchesDate = age >= 0 && age <= (dateFilter == .today ? 86_400 : 7 * 86_400)
            }
            return matchesApp && matchesQuery && matchesDate
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        VStack(spacing: 10) {
            TextField("Search history", text: $query)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Picker("App", selection: $appFilter) {
                    ForEach(apps, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Picker("Date", selection: $dateFilter) {
                    ForEach(HistoryDateFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            List(visibleRows, selection: $selectedID) { row in
                HistoryRowCell(row: row).tag(row.id)
            }
            .overlay {
                if visibleRows.isEmpty {
                    ContentUnavailableView("No dictations", systemImage: "waveform", description: Text("Try another search or filter."))
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var detailContent: some View {
        if let row = visibleRows.first(where: { $0.id == selectedID }) {
            HistoryDetail(row: row, onDelete: { await delete(row) })
        } else {
            ContentUnavailableView("Select a dictation", systemImage: "waveform")
        }
    }

    var body: some View {
        Group {
            if model.previewMode {
                // NavigationSplitView's sidebar draws with a vibrant
                // material that renders solid black when the preview
                // window is captured offscreen with cacheDisplay, so
                // preview mode lays the two panes out with a plain HStack
                // instead. Production keeps the real NavigationSplitView.
                HStack(spacing: 0) {
                    sidebarContent
                        .frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
                    Divider()
                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NavigationSplitView {
                    sidebarContent
                        .navigationTitle("History")
                        .navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 360)
                } detail: {
                    detailContent
                }
            }
        }
        .task { await load() }
        .onChange(of: query) { _, _ in Task { await load() } }
        .onChange(of: appFilter) { _, _ in Task { await load() } }
        .onChange(of: dateFilter) { _, _ in Task { await load() } }
        .alert("History error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        if model.previewMode {
            rows = PreviewFixtures.rows
            if selectedID == nil { selectedID = rows.first?.id }
            return
        }
        var fields: [String: JSONValue] = [
            "limit": .number(100),
            "query": .string(query),
        ]
        if appFilter != "All apps" { fields["app"] = .string(appFilter) }
        if let bounds = dateBounds {
            fields["after"] = .number(bounds.lowerBound)
            fields["before"] = .number(bounds.upperBound)
        }
        do {
            let response = try await model.engine.request(op: "history.list", fields: fields)
            rows = response.rows ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var dateBounds: ClosedRange<Double>? {
        guard dateFilter != .all else { return nil }
        let now = Date().timeIntervalSince1970
        let duration = dateFilter == .today ? 86_400.0 : 7 * 86_400.0
        return (now - duration)...now
    }

    private func delete(_ row: HistoryRow) async {
        if model.previewMode {
            rows.removeAll { $0.id == row.id }
            selectedID = nil
            return
        }
        do {
            _ = try await model.engine.request(op: "history.delete", fields: ["row_id": .number(Double(row.id))])
            rows.removeAll { $0.id == row.id }
            selectedID = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HistoryRowCell: View {
    let row: HistoryRow
    var body: some View {
        HStack(spacing: 10) {
            Text(String((row.appBundleID ?? "?").prefix(1)).uppercased())
                .font(.caption.bold())
                .frame(width: 26, height: 26)
                .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.preferredText ?? "(empty)").lineLimit(2)
                Text("\(Int(row.audioSeconds ?? 0)) s · \(Int(row.totalMS ?? 0)) ms · \(row.appBundleID ?? "Unknown")\(row.guardFired == true && (row.model == nil || row.model?.isEmpty == true) ? " · raw kept" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(relativeDate(row.ts)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func relativeDate(_ timestamp: Double?) -> String {
        guard let timestamp else { return "" }
        return RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
}

struct HistoryDetail: View {
    @EnvironmentObject private var model: AppModel
    let row: HistoryRow
    let onDelete: () async -> Void
    @State private var tab = 1
    @State private var player: AVAudioPlayer?
    @State private var dictionaryTerm = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("View", selection: $tab) {
                Text("Raw").tag(0)
                Text("Cleaned").tag(1)
                Text("Diff").tag(2)
            }
            .pickerStyle(.segmented)
            ScrollView {
                if tab == 2 {
                    WordDiffView(raw: row.rawText ?? "", cleaned: row.preferredText ?? "")
                } else {
                    Text(tab == 0 ? row.rawText ?? "" : row.preferredText ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .font(.body)
                }
            }
            if let path = row.audioPath {
                HStack {
                    Button {
                        do {
                            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                            player?.play()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Label("Play audio", systemImage: "play.fill")
                    }
                    Text("\(Int(row.audioSeconds ?? 0)) s").foregroundStyle(.secondary)
                }
            }
            Text("STT \(Int(row.sttMS ?? 0)) ms · LLM \(Int(row.llmMS ?? 0)) ms · Insert \(Int(row.insertMS ?? 0)) ms · \(row.model ?? "unknown") · \(row.insertMode ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionControls }
                VStack(alignment: .leading, spacing: 8) { actionControls }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 500, alignment: .topLeading)
    }

    @ViewBuilder
    private var actionControls: some View {
        Button("Insert again") {
            if model.previewMode { errorMessage = "Preview mode does not insert text." }
            else { model.insert(row: row, raw: false) }
        }.buttonStyle(.borderedProminent)
        Button("Copy cleaned") { copy(row.preferredText ?? "") }
        Button("Copy raw") { copy(row.rawText ?? "") }
        TextField("Add term", text: $dictionaryTerm)
            .frame(minWidth: 120, idealWidth: 150)
        Button("Add") { addTerm() }.disabled(dictionaryTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Delete row (audio retained)", role: .destructive) { Task { await onDelete() } }
    }

    private func copy(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func addTerm() {
        let term = dictionaryTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard !model.previewMode else {
            errorMessage = "Preview mode does not write dictionary changes."
            return
        }
        Task {
            do {
                _ = try await model.engine.request(op: "dictionary.add", fields: ["term": .string(term)])
                dictionaryTerm = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct WordDiffView: View {
    let raw: String
    let cleaned: String

    private var rawWords: [String] { raw.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var cleanedWords: [String] { cleaned.split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        let difference: CollectionDifference<String> = cleanedWords.difference(from: rawWords)
        let removed = Set(difference.compactMap { change -> String? in
            if case let .remove(_, element, _) = change { return element }
            return nil
        })
        let inserted = Set(difference.compactMap { change -> String? in
            if case let .insert(_, element, _) = change { return element }
            return nil
        })
        VStack(alignment: .leading, spacing: 10) {
            Text("Removed words").font(.caption.bold()).foregroundStyle(.secondary)
            Text(attributed(rawWords, marked: removed, color: .red, strike: true))
            Text("Retained and added words").font(.caption.bold()).foregroundStyle(.secondary)
            Text(attributed(cleanedWords, marked: inserted, color: .green, strike: false))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func attributed(_ words: [String], marked: Set<String>, color: Color, strike: Bool) -> AttributedString {
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString(word + (index == words.count - 1 ? "" : " "))
            if marked.contains(word) {
                part.foregroundColor = color
                if strike { part.strikethroughStyle = .single }
            }
            result.append(part)
        }
        return result
    }
}

struct DictionaryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var terms: [String] = []
    @State private var replacements: [String: String] = [:]
    @State private var newTerm = ""
    @State private var replacementPhrase = ""
    @State private var replacementText = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Terms · \(terms.count)") {
                ForEach(terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        if !model.previewMode {
                            Button(role: .destructive) { removeTerm(term) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Add term", text: $newTerm)
                    Button("Add") { addTerm() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Replacements · \(replacements.count)") {
                ForEach(replacements.keys.sorted(), id: \.self) { phrase in
                    HStack {
                        Text(phrase)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(replacements[phrase] ?? "").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Spoken phrase", text: $replacementPhrase)
                    TextField("Stored text", text: $replacementText)
                    Button("Save") { saveReplacement() }
                        .disabled(replacementPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Learned inbox · \(model.learnedSuggestions.count)") {
                if model.learnedSuggestions.isEmpty {
                    Text("No pending suggestions").foregroundStyle(.secondary)
                }
                ForEach(model.learnedSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("You changed \"\(suggestion.produced)\" to \"\(suggestion.replacement)\"")
                        HStack {
                            Button("Add") { model.decideSuggestion(suggestion, action: "learned.add") }
                                .buttonStyle(.borderedProminent)
                            Button("Ignore") { model.decideSuggestion(suggestion, action: "learned.ignore") }
                            Button("Never ask") { model.decideSuggestion(suggestion, action: "learned.never_ask") }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("Terms feed local Whisper and cleanup vocabulary. Replacements run after cleanup as plain text substitution.")
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await load()
            await model.refreshLearnedSuggestions()
        }
    }

    private func load() async {
        if model.previewMode {
            terms = PreviewFixtures.terms
            replacements = PreviewFixtures.replacements
            return
        }
        do {
            let response = try await model.engine.request(op: "dictionary.list")
            terms = response.terms ?? []
            replacements = response.replacements ?? [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !model.previewMode else {
            if model.previewMode { errorMessage = "Preview mode does not write dictionary changes." }
            return
        }
        Task {
            do {
                let response = try await model.engine.request(op: "dictionary.add", fields: ["term": .string(term)])
                terms = response.terms ?? terms
                newTerm = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeTerm(_ term: String) {
        Task {
            do {
                let response = try await model.engine.request(op: "dictionary.remove", fields: ["term": .string(term)])
                terms = response.terms ?? terms.filter { $0 != term }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveReplacement() {
        let phrase = replacementPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !model.previewMode else {
            if model.previewMode { errorMessage = "Preview mode does not write dictionary changes." }
            return
        }
        Task {
            do {
                let response = try await model.engine.request(op: "dictionary.replace", fields: [
                    "phrase": .string(phrase),
                    "replacement": .string(replacementText),
                ])
                replacements = response.replacements ?? replacements
                replacementPhrase = ""
                replacementText = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
