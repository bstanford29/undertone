import AppKit
import SwiftUI

/// The four tabs of the Settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case cleanup = "Cleanup"
    case pill = "Pill and Meetings"
    case privacy = "Privacy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dictation: return "mic"
        case .cleanup: return "text.badge.plus"
        case .pill: return "capsule"
        case .privacy: return "lock.shield"
        }
    }

    /// `--settings-tab cleanup` opens the preview on one tab.
    static func initial() -> SettingsTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--settings-tab"),
              arguments.indices.contains(index + 1) else { return .dictation }
        let raw = arguments[index + 1].lowercased()
        return allCases.first { $0.rawValue.lowercased().hasPrefix(raw) } ?? .dictation
    }
}

/// The Settings window, opened with ⌘,. The real window uses the system's
/// toolbar tabs. Preview mode draws the same tabs in the content instead,
/// because an offscreen capture of the window does not include its toolbar.
@MainActor
struct SettingsWindowView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: SettingsTab
    @State private var loaded = false

    init(tab: SettingsTab = .dictation) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        Group {
            if model.previewMode {
                VStack(spacing: 0) {
                    previewTabBar
                    Divider()
                    page(tab)
                }
            } else {
                TabView(selection: $tab) {
                    ForEach(SettingsTab.allCases) { tab in
                        page(tab)
                            .tabItem { Label(tab.rawValue, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
            }
        }
        .frame(width: 680, height: 720)
        .task {
            guard !loaded else { return }
            loaded = true
            await model.loadSettings()
        }
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .dictation: DictationSettingsTab()
        case .cleanup: CleanupSettingsTab()
        case .pill: PillSettingsTab()
        case .privacy: PrivacySettingsTab()
        }
    }

    private var previewTabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 17))
                        Text(item.rawValue).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(item == tab ? Color.accentColor : Color.secondary)
                    .background(item == tab ? Color.primary.opacity(0.07) : .clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Shared pieces

/// The strip at the top of every tab: the engine, each model warm or cold,
/// and how many permissions are granted.
struct SettingsStatusStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let health = model.engineHealth
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { items(health) }
            VStack(alignment: .leading, spacing: 6) { items(health) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func items(_ health: EngineHealth) -> some View {
        led(health.reachable ? (health.warm ? .ok : .loading) : .off,
            health.reachable ? (health.warm ? "Engine ready" : "Engine loading") : "Engine not running")
        led(state(health.whisper), "whisper \(health.whisper)")
        led(state(health.cleanup), "\(EngineHealth.shortName(health.model) ?? "cleanup") \(health.cleanup)")
        let high = EngineHealth.shortName(health.highModel) ?? "High model"
        led(health.high == "warm" ? .ok : .off,
            health.high == "warm" ? "\(high) warm" : "\(high) loads on first High")
        Spacer(minLength: 0)
        let granted = model.permissionSnapshot.grantedCount
        led(granted == 3 ? .ok : .warn, "Permissions \(granted) of 3")
    }

    enum LED { case ok, loading, off, warn }

    private func state(_ value: String) -> LED {
        switch value {
        case "warm": return .ok
        case "error": return .warn
        default: return model.engineHealth.reachable ? .loading : .off
        }
    }

    @ViewBuilder
    private func led(_ state: LED, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color(state))
                .frame(width: 7, height: 7)
            Text(text).lineLimit(1).fixedSize()
        }
    }

    private func color(_ state: LED) -> Color {
        switch state {
        case .ok: return .green
        case .loading: return .orange
        case .off: return Color.secondary.opacity(0.5)
        case .warn: return .orange
        }
    }
}

/// A row whose value Undertone does not let you change, with a lock glyph so
/// it does not read as a broken control.
struct LockedValue: View {
    let value: String

    var body: some View {
        Label(value, systemImage: "lock.fill")
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(value), fixed")
    }
}

/// A two-line label: the setting, then one plain sentence about it.
struct SettingLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A form that starts with the status strip, in the grouped style.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            Section { SettingsStatusStrip() }
            content()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

struct DictationSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var microphone = AudioInputDevices.defaultInputName()

    var body: some View {
        SettingsPage {
            Section("Talk") {
                LabeledContent {
                    LockedValue(value: "fn (Globe) or F13")
                } label: {
                    SettingLabel(title: "Hold to dictate",
                                 detail: "Undertone listens for both keys. Choosing another key is not built yet.")
                }
                Toggle(isOn: Binding(get: { model.doubleTapLock }, set: { model.setDoubleTapLock($0) })) {
                    SettingLabel(title: "Double-tap to lock",
                                 detail: "Talk hands-free. Tap the key again, or press Escape, to finish.")
                }
                LabeledContent {
                    Button("Sound Settings…") { model.runFlowMenu(.openSoundSettings) }
                        .disabled(model.previewMode)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingLabel(title: "Microphone",
                                     detail: "\(microphoneName). Undertone uses the macOS input; change it in Sound settings.")
                        InputLevelBar(level: model.listeningLevel)
                    }
                }
                Toggle(isOn: $model.whisperMode) {
                    SettingLabel(title: "Whisper mode", detail: "Boosts quiet speech for shared rooms and late nights.")
                }
                .onChange(of: model.whisperMode) { _, value in model.saveSetting("whisper_mode", .bool(value)) }
            }
            Section("Insert") {
                Toggle(isOn: $model.streamInsert) {
                    SettingLabel(title: "Type text as it is cleaned",
                                 detail: "Words appear while cleanup streams instead of all at once.")
                }
                .onChange(of: model.streamInsert) { _, value in model.saveSetting("stream_insert", .bool(value)) }
                Toggle("Tick on start and insert", isOn: $model.soundsEnabled)
                    .onChange(of: model.soundsEnabled) { _, value in model.saveSetting("sounds", .bool(value)) }
                LabeledContent {
                    LockedValue(value: "Keystrokes")
                } label: {
                    SettingLabel(title: "How text gets in",
                                 detail: "Undertone types keystrokes. It never uses the clipboard to dictate.")
                }
            }
            Section("Shortcuts") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    ForEach(Self.shortcuts.indices.filter { $0.isMultiple(of: 2) }, id: \.self) { index in
                        GridRow {
                            shortcutCell(Self.shortcuts[index])
                            if index + 1 < Self.shortcuts.count { shortcutCell(Self.shortcuts[index + 1]) }
                        }
                    }
                }
                Text("Shortcuts are fixed for now.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { microphone = AudioInputDevices.defaultInputName() }
    }

    private var microphoneName: String {
        if model.previewMode { return "MacBook Pro Microphone" }
        return microphone ?? "No input device"
    }

    static let shortcuts: [(String, String)] = [
        ("Dictate", "hold fn"), ("Lock dictation", "fn fn"),
        ("Meeting notes", "⌥M"), ("Quick note", "⌥S"),
        ("Insert last again", "⌥⇧V"), ("Undo AI edit", "⌥⇧Z"),
        ("Copy last transcript", "⌥⇧C"), ("History", "⌥⇧H"),
    ]

    @ViewBuilder
    private func shortcutCell(_ item: (String, String)) -> some View {
        HStack {
            Text(item.0)
            Spacer(minLength: 12)
            Text(item.1)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The live input level. It moves while you dictate; Settings never opens the
/// microphone on its own.
struct InputLevelBar: View {
    let level: Double

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color(red: 0.06, green: 0.71, blue: 0.86))
                    .frame(width: 160 * MeterScale.visual(level))
            }
            .frame(width: 160, height: 4)
            .animation(.easeOut(duration: 0.12), value: level)
            Text(level > 0 ? "Input level" : "Input level, moves while you dictate")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
    }
}

// MARK: - Cleanup

struct CleanupLevelInfo: Identifiable {
    let id: String
    let name: String
    let what: String
    let speed: String
    let model: String
}

struct CleanupSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    /// Apps added this session. They keep their row after Neutral removes
    /// their entry, so a choice never makes a row vanish under the pointer.
    @State private var extraApps: [String] = []

    private var levels: [CleanupLevelInfo] {
        let medium = EngineHealth.shortName(model.engineHealth.model) ?? "qwen3.5"
        let high = EngineHealth.shortName(model.engineHealth.highModel) ?? "gemma4:31b"
        return [
            CleanupLevelInfo(id: "none", name: "None", what: "Exactly what speech-to-text heard.",
                             speed: "instant", model: "no model"),
            CleanupLevelInfo(id: "light", name: "Light", what: "Drops fillers, fixes punctuation.",
                             speed: "instant", model: "rules only"),
            CleanupLevelInfo(id: "medium", name: "Medium", what: "Reads like you wrote it. Keeps every sentence.",
                             speed: "0.6 to 1.1 s", model: medium),
            CleanupLevelInfo(id: "high", name: "High", what: "Best polish for long messages.",
                             speed: "1.5 to 3.4 s", model: high),
        ]
    }

    var body: some View {
        SettingsPage {
            Section("Level") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(levels) { level in levelCard(level) }
                }
                lastDictationPreview
            }
            Section {
                ForEach(toneApps, id: \.self) { bundleID in toneRow(bundleID) }
                HStack {
                    Text("Everything else uses Neutral.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add app…") { addApp() }.disabled(model.previewMode)
                }
            } header: {
                Text("Tone by app")
            }
            Section("Always on") {
                LabeledContent {
                    LockedValue(value: "On")
                } label: {
                    SettingLabel(title: "Never drop content",
                                 detail: "If cleanup returns under 60% of your words, Undertone retries, then types what you said.")
                }
                LabeledContent {
                    LockedValue(value: "On")
                } label: {
                    SettingLabel(title: "Questions stay yours",
                                 detail: "A question you dictate is typed as a question, never answered.")
                }
            }
        }
    }

    @ViewBuilder
    private func levelCard(_ level: CleanupLevelInfo) -> some View {
        let selected = model.cleanupLevel == level.id
        Button { model.setCleanupLevel(level.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(level.name).font(.body.weight(.semibold))
                Text(level.what).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 30, alignment: .topLeading)
                Text(level.speed).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(level.model).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The last History row: what you said and what Undertone typed. Only
    /// that one level ran, so the preview names it instead of guessing what
    /// the other levels would have made.
    @ViewBuilder
    private var lastDictationPreview: some View {
        if let row = model.lastRow, let raw = row.rawText, !raw.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your last dictation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(previewCaption(row)).font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("You said").font(.caption).foregroundStyle(.secondary)
                        Text(raw).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Undertone typed").font(.caption).foregroundStyle(.secondary)
                        Text(row.preferredText ?? raw).fontWeight(.medium).textSelection(.enabled)
                    }
                }
            }
        } else {
            Text("Dictate once to see your own words here, before and after cleanup.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func previewCaption(_ row: HistoryRow) -> String {
        let app = row.appBundleID.map(ToneCatalog.fallbackName(for:)) ?? "Unknown app"
        let tone = ToneCatalog.tone(for: row.appBundleID, variants: model.appPromptVariants).rawValue
        let cleaned = row.model.map { "cleaned by \($0)" } ?? (row.guardFired == true ? "kept raw" : "not cleaned")
        return "\(app) · \(tone) · \(cleaned)"
    }

    private var toneApps: [String] {
        var apps = model.appPromptVariants.keys.sorted { appName($0) < appName($1) }
        for app in extraApps where !apps.contains(app) { apps.append(app) }
        return apps
    }

    private func appName(_ bundleID: String) -> String {
        model.previewMode ? ToneCatalog.fallbackName(for: bundleID)
            : (ToneCatalog.appName(for: bundleID) ?? bundleID)
    }

    @ViewBuilder
    private func toneRow(_ bundleID: String) -> some View {
        let tone = ToneCatalog.tone(for: bundleID, variants: model.appPromptVariants)
        Picker(selection: Binding(
            get: { tone },
            set: { newTone in
                if !extraApps.contains(bundleID) { extraApps.append(bundleID) }
                model.setTone(newTone, for: bundleID)
            }
        )) {
            ForEach(ToneCatalog.Tone.allCases.filter { $0 != .custom || tone == .custom }) { option in
                Text(option.rawValue).tag(option)
            }
        } label: {
            SettingLabel(title: appName(bundleID),
                         detail: tone == .custom ? "Custom style text from config.yaml" : nil)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if !extraApps.contains(bundleID) { extraApps.append(bundleID) }
    }
}

// MARK: - Pill and Meetings

struct PillSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPage {
            Section("Position") {
                Picker(selection: Binding(
                    get: { model.pillEdge },
                    set: { model.setPillDock(edge: $0, offset: model.pillOffset) }
                )) {
                    Text("Bottom").tag(PillEdge.bottom)
                    Text("Top").tag(PillEdge.top)
                    Text("Left").tag(PillEdge.left)
                    Text("Right").tag(PillEdge.right)
                } label: {
                    SettingLabel(title: "Docked to", detail: "Drag the pill anywhere along an edge too.")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $model.pillPersistent) {
                    SettingLabel(title: "Show nub at rest",
                                 detail: "Off, the pill appears only while you talk or a meeting records.")
                }
                .onChange(of: model.pillPersistent) { _, value in model.saveSetting("pill_persistent", .bool(value)) }
                if model.pillHidden {
                    LabeledContent("Hidden for an hour") {
                        Button("Show now") { model.showPillNow() }
                    }
                }
                LabeledContent("Position along the edge") {
                    Button("Reset to center") { model.resetPillPosition() }
                }
            }
            Section("Meetings") {
                Toggle(isOn: Binding(get: { model.detectCallsEnabled }, set: { model.setDetectCallsEnabled($0) })) {
                    SettingLabel(title: "Offer notes when a call starts",
                                 detail: "When a call app takes the microphone, the pill asks once. No bot joins.")
                }
                LabeledContent {
                    HStack {
                        Text(vaultText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button("Choose…") { chooseVault() }.disabled(model.previewMode)
                    }
                } label: {
                    SettingLabel(title: "Obsidian vault",
                                 detail: "Meeting summaries and Quick notes go here. Undertone never guesses this folder.")
                }
            }
        }
    }

    private var vaultText: String {
        guard let path = model.obsidianVaultPath, !path.isEmpty else { return "No vault selected" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.obsidianVaultPath = url.path
        model.saveSetting("obsidian_vault_path", .string(url.path))
    }
}

// MARK: - Privacy

struct PrivacySettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var restartMessage: String?

    var body: some View {
        let permissions = model.permissionSnapshot
        SettingsPage {
            Section {
                permissionRow("Microphone", detail: "Hear you while the key is held.",
                              granted: permissions.microphoneGranted, pane: "Privacy_Microphone")
                permissionRow("Accessibility", detail: "Type into the focused app and read the caret.",
                              granted: permissions.accessibilityGranted, pane: "Privacy_Accessibility")
                permissionRow("Input Monitoring", detail: "Notice the hold key from any app.",
                              granted: permissions.inputMonitoringGranted, pane: "Privacy_ListenEvent")
                systemAudioRow(permissions)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Undertone only reports these. Change them in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Stays on this Mac") {
                LabeledContent {
                    Button("Show in Finder") { showDataFolder() }.disabled(model.previewMode)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio, transcripts, and history")
                        Text("~/.undertone/history.sqlite").font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    LockedValue(value: "Local only")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cleanup models")
                        Text("Ollama at localhost:11434").font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    LockedValue(value: "Never")
                } label: {
                    SettingLabel(title: "Clipboard",
                                 detail: "Untouched while dictating. Copy last transcript writes it only when you ask.")
                }
                LabeledContent {
                    LockedValue(value: "Always")
                } label: {
                    SettingLabel(title: "History is kept",
                                 detail: "Nothing is deleted automatically. Delete rows yourself in History.")
                }
            }
            Section("Engine") {
                LabeledContent {
                    HStack(spacing: 10) {
                        Label(model.engineHealth.reachable ? "Running" : "Not running",
                              systemImage: model.engineHealth.reachable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(model.engineHealth.reachable ? Color.green : Color.secondary)
                        Button("Restart") { restartEngine() }.disabled(model.previewMode)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background engine")
                        Text("com.undertone.engine · ~/.undertone/engine.sock")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        if let restartMessage {
                            Text(restartMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent {
                    Text(keepWarmText).font(.system(.body, design: .monospaced))
                } label: {
                    SettingLabel(title: "Keep models warm for",
                                 detail: "Set by ollama_keep_alive in config.yaml. Longer is faster after a break, but holds memory.")
                }
            }
        }
    }

    private var keepWarmText: String {
        Self.keepWarmText(model.engineHealth.keepAlive)
    }

    /// "60m" reads as "60 min"; anything else is shown as the engine wrote it.
    static func keepWarmText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        if raw.hasSuffix("m"), let minutes = Int(raw.dropLast()) { return "\(minutes) min" }
        if raw.hasSuffix("h"), let hours = Int(raw.dropLast()) { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return raw
    }

    @ViewBuilder
    private func permissionRow(_ title: String, detail: String, granted: Bool, pane: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(granted ? "Allowed" : "Not allowed")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                if !granted {
                    Button("Open System Settings") { openPrivacyPane(pane) }
                }
            }
        } label: {
            SettingLabel(title: title, detail: detail)
        }
    }

    @ViewBuilder
    private func systemAudioRow(_ permissions: PermissionSnapshot) -> some View {
        if #available(macOS 14.4, *) {
            LabeledContent {
                Text("Asked when a meeting starts").foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "System Audio Recording",
                             detail: "Only for meeting notes: hear the other people on the call.")
            }
        } else {
            permissionRow("Screen Recording", detail: "Older macOS needs this to hear call audio. No video is saved.",
                          granted: permissions.screenRecordingGranted, pane: "Privacy_ScreenCapture")
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard !model.previewMode,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showDataFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".undertone")
        NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent("history.sqlite")])
    }

    /// Restarts Undertone's own launchd agent. It touches nothing else.
    private func restartEngine() {
        restartMessage = "Restarting…"
        Task {
            let ok = await EngineRestarter.restart()
            restartMessage = ok ? "Restarted. Models warm up again in the background." : "Restart failed. Is the engine installed as com.undertone.engine?"
            await model.refreshStatus()
        }
    }
}

/// Runs `launchctl kickstart -k` on the engine's own agent.
enum EngineRestarter {
    static let label = "com.undertone.engine"

    static func restart() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
