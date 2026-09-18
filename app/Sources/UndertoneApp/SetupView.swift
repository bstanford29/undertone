import AppKit
import SwiftUI

@MainActor
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showTroubleshooting = false
    @State private var globeKeyValue: Int? = GlobeKeySetting.current()
    @State private var globeKeyHasStoredPreviousValue = UserDefaults.standard.object(
        forKey: GlobeKeySetting.previousValueDefaultsKey
    ) != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Set up Undertone")
                        .font(.title2.bold())
                    Text(model.permissionSnapshot.dictationReady
                         ? "Required dictation permissions are enabled."
                         : "Grant the permissions below to enable local dictation.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.refreshPermissions() }
            }

            GroupBox("Dictation") {
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(
                        title: "Microphone",
                        detail: "Keeps your recordings on this Mac.",
                        granted: model.permissionSnapshot.microphoneGranted,
                        actionTitle: microphoneActionTitle,
                        action: microphoneAction
                    )
                    Divider()
                    permissionRow(
                        title: "Accessibility",
                        detail: "Reads the focused text field and inserts without using the clipboard.",
                        granted: model.permissionSnapshot.accessibilityGranted,
                        actionTitle: "Open Settings",
                        action: { openPrivacyPane("Privacy_Accessibility") }
                    )
                    Divider()
                    permissionRow(
                        title: "Input Monitoring",
                        detail: "Listens for the fn or F13 hold key.",
                        granted: model.permissionSnapshot.inputMonitoringGranted,
                        actionTitle: "Open Settings",
                        action: { openPrivacyPane("Privacy_ListenEvent") }
                    )
                    Divider()
                    globeKeyCard
                }
                .padding(.top, 4)
            }

            GroupBox("Meeting notes (optional)") {
                if #available(macOS 14.4, *) {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("System audio").font(.headline)
                            Text("Audio-only access is checked when you start a meeting. macOS may ask you to allow it once. No screen or video is captured.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Meetings") { model.showApp(.meetings) }
                    }
                } else {
                    permissionRow(
                        title: "Screen Recording",
                        detail: "Required by older macOS versions to capture meeting audio. No video is saved.",
                        granted: model.permissionSnapshot.screenRecordingGranted,
                        actionTitle: "Open Settings",
                        action: { openPrivacyPane("Privacy_ScreenCapture") }
                    )
                }
            }

            GroupBox("Engine") {
                HStack {
                    Image(systemName: engineIsReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(engineIsReady ? .green : .orange)
                    Text(model.engineStatusText)
                    Spacer()
                }
            }

            GroupBox("Global shortcuts") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: model.shortcutTapActive ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.shortcutTapActive ? .green : .orange)
                        Text(shortcutDiagnosticsText)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(HotkeyMonitor.chordRoster, id: \.chord) { entry in
                            HStack(spacing: 8) {
                                Text(entry.chord)
                                    .font(.caption.monospaced())
                                    .frame(width: 44, alignment: .leading)
                                Text(entry.action)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Copy tap log") { model.copyHotkeyTapLog() }
                            .buttonStyle(.link)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Permission troubleshooting") { showTroubleshooting.toggle() }
                if showTroubleshooting {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If a switch is already on but access is missing, remove the old Undertone entry with the minus button in System Settings, then add Undertone from your Applications folder. Turning the old switch off and on may retain its previous signature.")
                    Text("If access still appears missing after a change, quit and reopen Undertone. On older macOS versions, Screen Recording may require a new launch.")
                    Text("Running copy: \(Bundle.main.bundleURL.path)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Build: \(Bundle.main.object(forInfoDictionaryKey: "UndertoneBuildCommit") as? String ?? "Development")")
                        .font(.caption.monospaced())
                    Button("Quit Undertone") { if !model.previewMode { NSApp.terminate(nil) } }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                }
            }

            Text("Hold fn or F13 to dictate. If another dictation tool is using fn, use F13 or stop that tool so both do not start at once.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = model.permissionRequestMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            model.refreshPermissions()
            refreshGlobeKeyState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshGlobeKeyState()
        }
    }

    /// Card for macOS's "Press globe key to" preference. A bare fn tap runs
    /// a system action (commonly the Emoji & Symbols picker) unless this is
    /// set to "Do Nothing", which would otherwise steal every fn-hold
    /// dictation. Collapses to a single confirmation line once it reads 0.
    @ViewBuilder
    private var globeKeyCard: some View {
        if globeKeyValue == 0 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Globe key: Do Nothing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Globe key opens the emoji picker")
                    .font(.body.weight(.semibold))
                Text("A bare tap of fn runs a system action; Undertone needs it set to Do Nothing so fn works as the hold-to-talk key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Set to Do Nothing") { setGlobeKeyDoNothing() }
                    if globeKeyHasStoredPreviousValue {
                        Button("Revert") { revertGlobeKey() }
                    }
                    Button("Open Keyboard Settings") { openKeyboardSettings() }
                        .buttonStyle(.link)
                    Spacer()
                }
            }
        }
    }

    private func refreshGlobeKeyState() {
        globeKeyValue = GlobeKeySetting.current()
        globeKeyHasStoredPreviousValue = UserDefaults.standard.object(
            forKey: GlobeKeySetting.previousValueDefaultsKey
        ) != nil
    }

    private func setGlobeKeyDoNothing() {
        guard !model.previewMode else { return }
        GlobeKeySetting.setDoNothing()
        refreshGlobeKeyState()
    }

    private func revertGlobeKey() {
        guard !model.previewMode else { return }
        GlobeKeySetting.revert()
        refreshGlobeKeyState()
    }

    private func openKeyboardSettings() {
        guard !model.previewMode else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var engineIsReady: Bool {
        model.engineReady
    }

    private var shortcutDiagnosticsText: String {
        let status = model.shortcutTapActive ? "active" : "inactive"
        let level = " (\(model.hotkeyTapLevel))"
        guard let lastSeen = model.lastShortcutSeen else {
            return "Global shortcuts: \(status)\(level) · no chord seen yet"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "Global shortcuts: \(status)\(level) · last seen: \(lastSeen.chordName) at \(formatter.string(from: lastSeen.date))"
    }

    private var microphoneActionTitle: String {
        if model.permissionSnapshot.microphoneGranted { return "Granted" }
        if model.permissionSnapshot.microphoneUndetermined { return "Allow Microphone" }
        return "Open Settings"
    }

    private var microphoneAction: () -> Void {
        if model.permissionSnapshot.microphoneGranted { return {} }
        if model.permissionSnapshot.microphoneUndetermined {
            return { model.requestMicrophonePermission() }
        }
        return { openPrivacyPane("Privacy_Microphone") }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "Granted" : actionTitle, action: action)
                .disabled(granted)
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard !model.previewMode else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
