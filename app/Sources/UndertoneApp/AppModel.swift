import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI

struct PermissionSnapshot: Equatable {
    let microphoneGranted: Bool
    let microphoneUndetermined: Bool
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let screenRecordingGranted: Bool

    var dictationReady: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    static func current() -> Self {
        let microphone = AVAudioApplication.shared.recordPermission
        return Self(
            microphoneGranted: microphone == .granted,
            microphoneUndetermined: microphone == .undetermined,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }
}

@MainActor
final class AppModel: ObservableObject {
    let engine: EngineClient
    let recorder = AudioRecorder()
    let meetings: MeetingModel
    let inserter = InsertionController()
    let hotkey = HotkeyMonitor()
    let editWatcher: EditWatcher

    @Published var pillState: PillState = .idle
    @Published var slowerOnBattery = false
    @Published var commandMode = false
    @Published var cleanupLevel = "medium"
    @Published var statusText = "Engine unavailable"
    /// A transient note shown in place of the normal "working" label, used
    /// while waiting out a still-held fn key before insertion.
    @Published var workingNote: String?
    @Published var engineStatusText = "Engine unavailable"
    @Published var engineReady = false
    @Published var appPage: AppPage = .home
    private var mainWindow: NSWindow?
    @Published var soundsEnabled = true
    @Published var streamInsert = true
    @Published var keepWarm = true
    @Published var whisperMode = false
    @Published var pillPersistent = true
    @Published var pillEdge: PillEdge = .bottom
    @Published var pillOffset: Double = 0.5
    @Published var lastRow: HistoryRow?
    @Published var detectedMeeting: DetectedMeeting?
    /// The Obsidian vault Quick note writes its daily note into. Empty means
    /// no vault is chosen and notes stay in `~/.undertone/quicknotes`.
    @Published var obsidianVaultPath: String?
    /// Whether the meeting nudge may appear at all. Settings owns this.
    @Published var detectCallsEnabled = MeetingDetectionSettings.isEnabled()
    /// How much of the nudge card's 20 s is left, 1 down to 0. Hovering the
    /// card pauses the count.
    @Published private(set) var nudgeFraction: Double = 1
    @Published var configError: String?
    @Published var learnedSuggestions: [LearnedSuggestion] = []
    @Published var learnFromCorrections = false
    @Published private(set) var pendingLearningActionID: Int?
    @Published private(set) var pendingLearningTerm: String?
    @Published private(set) var permissionSnapshot = PermissionSnapshot.current()
    @Published var permissionRequestMessage: String?
    @Published private(set) var shortcutTapActive = false
    @Published private(set) var lastShortcutSeen: ShortcutSighting?
    /// Whether the hold key has latched into lock mode. Drives the lock
    /// glyph on the pill.
    @Published private(set) var dictationLocked = false
    let previewMode: Bool
    private var target: TargetSnapshot?
    // The target captured before an Undertone window takes focus. It remains
    // separate from the target of the most recent insertion for history actions.
    private var externalTarget: TargetSnapshot?
    private var lastInsertTarget: TargetSnapshot?
    private var lastInsertedText: String?
    private var lastInsertedRawText: String?
    private var lastInsertedRowID: Int?
    private var statusTask: Task<Void, Never>?
    private var pillResetTask: Task<Void, Never>?
    private var inputMonitoringUnavailable = false
    private var accessibilityUnavailable = false
    private var insertionInFlight = false
    private var learningUndoInFlight = false
    private var meetingsObservation: AnyCancellable?
    private var meetingStateObservation: AnyCancellable?
    private var detectionObservation: AnyCancellable?
    private var nudgeTask: Task<Void, Never>?
    private var deferredMeetingNudge: DetectedMeeting?
    private var nudgeHovered = false
    private var meetingElapsedTask: Task<Void, Never>?
    /// Set by the app delegate, which owns the Quick note panel.
    var onQuickNoteToggle: (() -> Void)?
    private var watchdogTask: Task<Void, Never>?
    private var workingTask: Task<Void, Never>?
    private var lockEscapeMonitors: [Any] = []
    private var powerMonitor: PowerStateMonitor?
    private var meetingDetector: MeetingAppDetector?
    private var streamInsertSession: StreamInsertSession?
    /// Same subsystem and category as the detector, so one log stream shows
    /// the detection and the dock's reaction to it side by side.
    nonisolated private static let log = Logger(subsystem: "com.undertone.app", category: "meeting")
    /// Matches the engine's default `min_speech_seconds` gate.
    private static let minimumRecordedSeconds = 0.4
    private static let workingTimeout: Duration = .seconds(25)
    /// Longest time to wait for a physically held fn/F13 key to release
    /// before inserting anyway. macOS drops keystrokes typed while fn is
    /// still down, so lock-mode dictations must wait this out first.
    private static let holdKeyReleaseTimeout: Duration = .milliseconds(1500)
    /// Extra settle time after the hold key releases (or the wait times
    /// out) before insertion, so the modifier state has finished changing.
    private static let holdKeyReleaseSettleDelay: Duration = .milliseconds(60)
    /// How long the wait must run before the pill shows a note explaining
    /// why insertion has not happened yet.
    private static let holdKeyReleaseNoteDelay: Duration = .milliseconds(300)

    private final class StreamInsertSession {
        let target: TargetSnapshot
        var committed = ""
        var firstKeystroke: UInt64?
        var lastKeystroke: UInt64?
        var failure: InsertOutcome?
        var holdAwaited = false

        init(target: TargetSnapshot) {
            self.target = target
        }
    }

    init(socketPath: String? = nil, previewMode: Bool = false) {
        let configured = socketPath ?? ProcessInfo.processInfo.environment["UNDERTONE_SOCKET"]
        engine = EngineClient(path: configured ?? NSString(string: "~/.undertone/engine.sock").expandingTildeInPath)
        self.previewMode = previewMode
        editWatcher = EditWatcher(inserter: inserter)
        meetings = MeetingModel(engine: EngineClient(path: configured ?? NSString(string: "~/.undertone/engine.sock").expandingTildeInPath),
                                previewMode: previewMode)
        meetingsObservation = meetings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        meetings.canStartMeeting = { [weak self] in
            guard let self else { return false }
            switch self.pillState {
            case .listening, .working: return false
            default: return true
            }
        }
        if previewMode {
            slowerOnBattery = PreviewFixtures.slowerOnBattery
            detectedMeeting = PreviewFixtures.detectedMeeting
            pillState = .working
        }
    }

    nonisolated static func hasCommandSelection(_ selectedText: String?) -> Bool {
        guard let selectedText else { return false }
        return !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func hasEditableCommandSelection(
        _ selectedText: String?, selectedRange: CFRange?, axSettable: Bool
    ) -> Bool {
        guard axSettable, let selectedRange, selectedRange.location >= 0, selectedRange.length > 0 else { return false }
        return hasCommandSelection(selectedText)
    }

    nonisolated static func commandSelectionWithinLimit(_ selectedText: String) -> Bool {
        selectedText.utf8.count <= 1_048_576
    }

    nonisolated static func commandInstructionWithinLimit(_ instruction: String) -> Bool {
        instruction.utf8.count <= 4_096
    }

    nonisolated static func canShowLearningNotice(for state: PillState) -> Bool {
        switch state {
        case .idle, .notice:
            return true
        case .listening, .working, .inserted, .guarded, .error, .recording, .meetingDetected:
            return false
        }
    }

    nonisolated static func learningNotice(for term: String) -> String {
        "Learned \(term) · Undo"
    }

    nonisolated static func isLearningNotice(_ state: PillState, term: String) -> Bool {
        guard case .notice(let message) = state else { return false }
        return message == learningNotice(for: term)
    }

    nonisolated static func shouldDeferMeetingNudge(for state: PillState, pendingLearningTerm: String?) -> Bool {
        guard let pendingLearningTerm else { return false }
        return isLearningNotice(state, term: pendingLearningTerm)
    }

    nonisolated static func preservesDeferredMeetingNudge(_ state: PillState) -> Bool {
        guard case .notice(let message) = state else { return false }
        return message.hasPrefix("Undid learning ")
    }

    nonisolated static func shouldShowDeferredMeetingNudge(
        current: DetectedMeeting?, deferred: DetectedMeeting?, enabled: Bool,
        persistent: Bool, ignored: Bool, busy: Bool, pillIsIdle: Bool
    ) -> Bool {
        guard let current, let deferred, current == deferred else { return false }
        return shouldShowNudge(enabled: enabled, persistent: persistent, ignored: ignored,
                               busy: busy, pillIsIdle: pillIsIdle)
    }

    nonisolated static func canBeginLearningUndo(actionID: Int?, inFlight: Bool) -> Bool {
        actionID != nil && !inFlight
    }

    nonisolated static func commandSidecarPayload(selectedText: String, instruction: String) -> [String: String] {
        ["kind": "command", "raw_text": selectedText, "instruction_text": instruction]
    }

    func start() {
        recorder.levelHandler = { [weak self] level in
            guard let self, case .listening = self.pillState else { return }
            self.pillState = .listening(level: level)
        }
        recorder.errorHandler = { [weak self] error in
            guard let self else { return }
            _ = self.recorder.stop()
            self.commandMode = false
            self.showTransientError("Recording failed: \(error.localizedDescription)")
        }
        hotkey.onStart = { [weak self] in self?.beginDictation() }
        hotkey.onStop = { [weak self] in self?.endDictation() }
        hotkey.onLockChange = { [weak self] locked in self?.dictationLocked = locked }
        installLockEscapeMonitors()
        hotkey.onDiagnosticsChange = { [weak self] tapActive, lastSeen in
            self?.shortcutTapActive = tapActive
            self?.lastShortcutSeen = lastSeen
        }
        hotkey.onShortcut = { [weak self] key in
            switch key {
            case "v": self?.insertLast()
            case "z": self?.insertLast(raw: true)
            case "c": self?.copyLast()
            case "m":
                self?.showApp(.meetings)
                self?.meetings.start()
            default: break
            }
        }
        hotkey.onOptionShortcut = { [weak self] key in
            switch key {
            case "m": self?.toggleMeetingCapture()
            case "s": self?.toggleQuickNote()
            default: break
            }
        }
        detectionObservation = $detectedMeeting.sink { [weak self] detected in
            MainActor.assumeIsolated { self?.detectionChanged(detected) }
        }
        meetingStateObservation = meetings.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.meetingStateChanged(state) }
        }
        refreshPermissionsAndHotkey()
        if accessibilityUnavailable { statusText = "Accessibility permission required" }
        else if inputMonitoringUnavailable { statusText = "Input Monitoring permission required" }
        Task { await refreshStatus() }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        Task {
            guard let response = try? await engine.request(op: "config.get"), let config = response.config else { return }
            if case .string(let value) = config["cleanup_level"] { cleanupLevel = value }
            if case .bool(let value) = config["sounds"] { soundsEnabled = value }
            if case .bool(let value) = config["stream_insert"] { streamInsert = value }
            if case .bool(let value) = config["whisper_mode"] { whisperMode = value }
            learnFromCorrections = CorrectionLearningSetting.value(from: config)
            if case .bool(let value) = config["pill_persistent"] { pillPersistent = value }
            if case .string(let value) = config["pill_edge"], let edge = PillEdge(rawValue: value) { pillEdge = edge }
            if case .number(let value) = config["pill_offset"] { pillOffset = value }
            if case .string(let value) = config["obsidian_vault_path"] { obsidianVaultPath = value }
        }
        Task { await refreshLearnedSuggestions() }
        Task { await meetings.loadSessions() }
        startPowerMonitor()
        startMeetingDetector()
    }

    func refreshPermissions() {
        refreshPermissionsAndHotkey()
        if permissionSnapshot.microphoneGranted {
            permissionRequestMessage = nil
        }
        guard !previewMode else { return }
        Task { await refreshStatus() }
    }

    /// Diagnostic label for the tap location, shown next to the "Global
    /// shortcuts" status line in Settings.
    var hotkeyTapLevel: String { hotkey.tapLevel }

    /// Copies the in-memory ring buffer of recent hotkey tap log lines to
    /// the clipboard. An explicit user action, so it is exempt from the
    /// no-clipboard-for-dictation rule.
    func copyHotkeyTapLog() {
        guard !previewMode else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hotkey.tapLogText, forType: .string)
    }

    func requestMicrophonePermission() {
        guard !previewMode else { return }
        permissionRequestMessage = nil
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.permissionRequestMessage = granted
                    ? "Microphone permission granted."
                    : "Microphone permission was not granted."
                self.refreshPermissions()
            }
        }
    }

    func stop() {
        statusTask?.cancel()
        statusTask = nil
        pillResetTask?.cancel()
        pillResetTask = nil
        nudgeTask?.cancel()
        nudgeTask = nil
        deferredMeetingNudge = nil
        meetingElapsedTask?.cancel()
        meetingElapsedTask = nil
        powerMonitor?.stop()
        powerMonitor = nil
        meetingDetector?.stop()
        meetingDetector = nil
        removeLockEscapeMonitors()
        hotkey.stop()
        editWatcher.cancel()
        _ = recorder.stop()
    }

    /// Escape ends a locked recording and proceeds to transcription, the
    /// same as a single tap of the hold key while locked. A local monitor
    /// catches Escape inside the app; a global monitor catches it while
    /// another app is frontmost, since the pill panel never becomes key.
    /// Mirrors `DraggablePillPanel`'s drag-cancel Escape monitors.
    private func installLockEscapeMonitors() {
        guard lockEscapeMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self, self.hotkey.isLocked else { return false }
                self.hotkey.stopByEscape()
                return true
            }
            return consumed ? nil : event
        }) {
            lockEscapeMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.hotkey.isLocked else { return }
                self.hotkey.stopByEscape()
            }
        }) {
            lockEscapeMonitors.append(global)
        }
    }

    private func removeLockEscapeMonitors() {
        for monitor in lockEscapeMonitors { NSEvent.removeMonitor(monitor) }
        lockEscapeMonitors = []
    }

    func beginDictation() {
        guard !meetings.state.isRecording else {
            showTransientError("Stop meeting capture before dictating")
            return
        }
        switch pillState {
        case .idle, .inserted, .guarded, .error, .notice, .meetingDetected:
            break
        case .listening, .working, .recording:
            return
        }
        clearPendingLearning()
        cancelNudge()
        editWatcher.cancel()
        pillResetTask?.cancel()
        pillResetTask = nil
        workingNote = nil
        target = inserter.snapshot()
        let hasSelectionText = Self.hasCommandSelection(target?.selectedText)
        let hasSelectionRange = (target?.selectedRange?.length ?? 0) > 0
        if hasSelectionText || hasSelectionRange {
            guard let target,
                  Self.hasEditableCommandSelection(target.selectedText,
                                                   selectedRange: target.selectedRange,
                                                   axSettable: inserter.canReplaceSelection(target)) else {
                self.target = nil
                commandMode = false
                showTransientError("Selected text cannot be edited via Accessibility")
                return
            }
            guard Self.commandSelectionWithinLimit(target.selectedText ?? "") else {
                self.target = nil
                commandMode = false
                showTransientError("Selected text exceeds the 1 MiB UTF-8 limit")
                return
            }
            commandMode = true
        } else {
            commandMode = false
        }
        recorder.whisperMode = whisperMode
        do {
            _ = try recorder.start()
            pillState = .listening(level: 0)
            if soundsEnabled { NSSound(named: "Tink")?.play() }
        } catch {
            commandMode = false
            showTransientError("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    func endDictation() {
        guard case .listening = pillState else { return }
        guard let path = recorder.stop(), let target else {
            commandMode = false
            showTransientError("Recording failed, no audio retained")
            return
        }
        guard recorder.lastRecordedSeconds >= Self.minimumRecordedSeconds else {
            commandMode = false
            self.target = nil
            statusText = "No speech detected"
            pillState = .idle
            return
        }
        pillState = .working
        let task = Task { await self.process(audioPath: path, target: target) }
        startWatchdog(for: task)
    }

    private func startWatchdog(for task: Task<Void, Never>) {
        workingTask = task
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.workingTimeout) } catch { return }
            guard let self, case .working = self.pillState else { return }
            task.cancel()
            self.commandMode = false
            self.showTransientError("Cleanup took too long")
        }
    }

    /// Waits for a physically held fn/F13 key to release before insertion.
    /// A lock-mode stop tap fires on the key-down; the key can still be
    /// physically down while transcription and cleanup run, and macOS drops
    /// keystrokes typed while it is. No-op if the key is already up (the
    /// ordinary hold-and-release path, where the release itself is what
    /// triggered `endDictation`). Always returns, even if the key never
    /// releases; a second dictation cannot start while this runs because
    /// `pillState` is `.working` for its whole duration, which blocks
    /// `beginDictation`.
    private func awaitHoldKeyRelease() async {
        guard hotkey.holdKeyIsDown else { return }
        let noteTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdKeyReleaseNoteDelay)
            guard !Task.isCancelled else { return }
            self?.workingNote = "Release fn to insert"
        }
        await HoldKeyReleaseWaiter.wait(timeout: Self.holdKeyReleaseTimeout) { [weak hotkey] signal in
            hotkey?.onHoldKeyReleased = signal
        }
        hotkey.onHoldKeyReleased = nil
        noteTask.cancel()
        workingNote = nil
        try? await Task.sleep(for: Self.holdKeyReleaseSettleDelay)
    }

    private func consumeStreamChunk(_ chunk: String) async {
        guard let session = streamInsertSession else { return }
        if session.failure != nil { return }
        if !session.holdAwaited {
            await awaitHoldKeyRelease()
            session.holdAwaited = true
            workingNote = "Inserting"
        }
        guard !Task.isCancelled else { return }
        let outcome = inserter.appendStreamed(chunk, target: session.target)
        switch outcome {
        case .inserted:
            if session.firstKeystroke == nil {
                session.firstKeystroke = DispatchTime.now().uptimeNanoseconds
            }
            session.lastKeystroke = DispatchTime.now().uptimeNanoseconds
            session.committed += chunk
        case .failed:
            session.failure = outcome
        }
    }

    func refreshStatus() async {
        refreshPermissionsAndHotkey()
        do {
            let response = try await engine.request(op: "status")
            if let error = response.error { setEngineStatus(error.message) }
            else if response.whisper == "error" || response.cleanup == "error" {
                setEngineStatus(response.errorMessage ?? "Engine error")
            } else if response.whisper == "warm" && response.cleanup == "warm" {
                setEngineStatus("Whisper and \(response.model ?? "cleanup") warm · ready")
            } else { setEngineStatus("Engine loading…") }
        } catch { setEngineStatus("Engine unavailable") }
    }

    private func process(audioPath: URL, target: TargetSnapshot) async {
        defer {
            watchdogTask?.cancel()
            watchdogTask = nil
            workingTask = nil
            streamInsertSession = nil
        }
        do {
            let commandMode = Self.hasCommandSelection(target.selectedText)
            let selectedText = target.selectedText ?? ""
            let context = AXContextReader.context(for: target)
            let harvestedTerms = commandMode ? [] : AXContextReader.harvestedTerms(for: target)
            let knownTerms: Set<String> = commandMode
                ? []
                : Set((try? await engine.request(op: "dictionary.list"))?.terms?.map { $0.lowercased() } ?? [])
            let transcript = try await engine.request(op: "transcribe", fields: [
                "audio_path": .string(audioPath.path), "vocab_extra": .array(harvestedTerms.map(JSONValue.string))
            ])
            let raw = transcript.raw ?? ""
            guard transcript.noSpeech != true, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "No speech detected"
                self.commandMode = false
                pillState = .idle
                return
            }
            // Retain the raw transcript beside the audio before any history or
            // cleanup request. This covers a history socket failure without
            // printing or otherwise exposing transcript content.
            if commandMode {
                try? retainRawTranscript(kind: "command", rawText: selectedText, instructionText: raw, alongside: audioPath)
                guard Self.commandInstructionWithinLimit(raw) else {
                    self.commandMode = false
                    showTransientError("Command instruction exceeds the 4 KiB UTF-8 limit")
                    return
                }
            } else {
                try? retainRawTranscript(kind: "dictation", rawText: raw, instructionText: nil, alongside: audioPath)
            }
            let app = target.bundleID ?? "unknown"
            let sttMS = transcript.sttMS ?? 0
            let audioSeconds = audioSeconds(audioPath)
            let historyRaw = commandMode ? selectedText : raw
            let recorded = try await engine.request(op: "history.record", fields: [
                "kind": .string(commandMode ? "command" : "dictation"),
                "raw_text": .string(historyRaw), "instruction_text": commandMode ? .string(raw) : .null,
                "clean_text": .string(""),
                "stt_ms": .number(sttMS), "llm_ms": .number(0),
                "insert_ms": .number(0), "total_ms": .number(sttMS),
                "insert_mode": .string("skipped"), "audio_seconds": .number(audioSeconds),
                "app_bundle_id": .string(app), "guard_fired": .bool(false),
                "model": .null, "audio_path": .string(audioPath.path)
            ])
            guard let rowID = recorded.rowID else {
                throw EngineClientError.protocolViolation("history.record did not return row_id")
            }
            let result: EngineResponse
            let usedStreamInsert = !commandMode && streamInsert
            if commandMode {
                result = try await engine.request(op: "command", fields: [
                    "selected": .string(selectedText), "instruction": .string(raw)
                ])
            } else if usedStreamInsert {
                let session = StreamInsertSession(target: target)
                streamInsertSession = session
                let cleanFields: [String: JSONValue] = [
                    "raw": .string(raw), "level": .string(cleanupLevel), "app": .string(app),
                    "context": .object(["before": .string(context.before), "after": .string(context.after), "selected": .string(context.selected)])
                ]
                result = try await engine.requestStream(op: "clean.stream", fields: cleanFields) { chunk in
                    await self.consumeStreamChunk(chunk)
                }
            } else {
                result = try await engine.request(op: "clean", fields: [
                    "raw": .string(raw), "level": .string(cleanupLevel), "app": .string(app),
                    "context": .object(["before": .string(context.before), "after": .string(context.after), "selected": .string(context.selected)])
                ])
            }
            let text = commandMode
                ? (result.rewrite ?? "")
                : ([result.clean, result.cleanText]
                    .compactMap { $0 }
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "")
            let guardFired = commandMode ? false : (result.guardFired ?? false)
            let streamCutShort = result.streamTruncated == true || result.streamInterrupted == true
            let keptRaw = !commandMode && guardFired
                && (result.model == nil || result.model?.isEmpty == true || streamCutShort)
            let llmMS = result.llmMS ?? 0
            _ = try await engine.request(op: "history.complete", fields: [
                "row_id": .number(Double(rowID)), "clean_text": .string(text),
                "model": result.model.map(JSONValue.string) ?? .null,
                "guard_fired": .bool(guardFired), "llm_ms": .number(llmMS)
            ])
            if let latest = try? await engine.request(op: "history.last") {
                lastRow = latest.row
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.commandMode = false
                workingNote = nil
                showTransientError("Cleanup returned no text; original retained")
                return
            }
            let outcome: InsertOutcome
            let insertMS: Double
            let chunksSent = result.chunksSent ?? 0
            if commandMode || !usedStreamInsert || chunksSent == 0 {
                await awaitHoldKeyRelease()
                let insertStart = DispatchTime.now().uptimeNanoseconds
                outcome = inserter.insert(text, target: target, axOnly: commandMode)
                insertMS = Double(DispatchTime.now().uptimeNanoseconds &- insertStart) / 1_000_000
            } else {
                let session = streamInsertSession ?? StreamInsertSession(target: target)
                if session.failure == nil {
                    if let rest = StreamInsertion.remainder(clean: text, committed: session.committed) {
                        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Task.isCancelled {
                            let remOutcome = inserter.appendStreamed(rest, target: target)
                            if case .inserted = remOutcome {
                                if session.firstKeystroke == nil {
                                    session.firstKeystroke = DispatchTime.now().uptimeNanoseconds
                                }
                                session.lastKeystroke = DispatchTime.now().uptimeNanoseconds
                                session.committed += rest
                            } else {
                                session.failure = remOutcome
                            }
                        }
                    } else {
                        InsertionController.logStreamPrefixMismatch(bundleID: target.bundleID)
                    }
                }
                if let failure = session.failure {
                    outcome = failure
                } else if !session.committed.isEmpty {
                    outcome = .inserted(.type)
                } else {
                    outcome = .failed(.emptyText)
                }
                if let first = session.firstKeystroke, let last = session.lastKeystroke {
                    insertMS = Double(last &- first) / 1_000_000
                } else {
                    insertMS = 0
                }
                workingNote = nil
            }
            let total = sttMS + llmMS + insertMS
            if !outcome.isFailure {
                lastInsertTarget = target
                lastInsertedText = text
                lastInsertedRawText = commandMode ? selectedText : raw
                lastInsertedRowID = rowID
                if !commandMode, let receipt = InsertionReceipt.make(rowID: rowID, produced: text, target: target) {
                    editWatcher.start(receipt: receipt, knownTerms: knownTerms) { [weak self] candidate, edited in
                        self?.handleEdit(candidate: candidate, editedText: edited, receipt: receipt)
                    }
                }
            }
            var historyUpdateFailed = false
            do {
                _ = try await engine.request(op: "history.update", fields: [
                    "row_id": .number(Double(rowID)),
                    "insert_mode": .string(outcome.historyValue),
                    "insert_ms": .number(insertMS),
                    "total_ms": .number(total),
                ])
            } catch {
                historyUpdateFailed = true
            }
            self.commandMode = false
            if let latest = try? await engine.request(op: "history.last") { lastRow = latest.row }
            if case .failed(let reason) = outcome {
                statusText = historyUpdateFailed
                    ? "Insertion failed, history update unknown"
                    : Self.failureMessage(reason)
                showTransientError(statusText)
            } else if historyUpdateFailed {
                statusText = "Inserted, history update unknown"
                showTransientState(keptRaw ? .guarded(totalMS: total) : .inserted(totalMS: total))
            } else {
                showTransientState(keptRaw ? .guarded(totalMS: total) : .inserted(totalMS: total))
            }
            if soundsEnabled, !outcome.isFailure { NSSound(named: "Pop")?.play() }
        } catch is CancellationError {
            // The watchdog already reported the timeout and reset the pill.
        } catch {
            commandMode = false
            showTransientError(error.localizedDescription, duration: .milliseconds(2200))
        }
    }

    private func handleEdit(candidate: LearningCandidate, editedText: String, receipt: InsertionReceipt) {
        let rowID = receipt.rowID
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await engine.request(op: "history.update", fields: [
                    "row_id": .number(Double(rowID)), "edited_text": .string(editedText)
                ])
                guard candidate.reason != "already_known" else { return }
                guard learnFromCorrections else {
                    try await proposeEdit(candidate: candidate, rowID: rowID, appBundleID: receipt.appBundleID)
                    return
                }
                guard Self.canShowLearningNotice(for: pillState) else {
                    try await proposeEdit(candidate: candidate, rowID: rowID, appBundleID: receipt.appBundleID)
                    return
                }
                let response = try await engine.request(op: "learning.auto_learn", fields: [
                    "produced": .string(candidate.produced),
                    "replacement": .string(candidate.replacement), "row_id": .number(Double(rowID)),
                    "app_bundle_id": .string(receipt.appBundleID)
                ])
                if response.status == "learned", let actionID = response.learningActionID {
                    let term = response.term ?? candidate.replacement
                    guard Self.canShowLearningNotice(for: pillState) else {
                        _ = try? await engine.request(op: "learning.undo", fields: ["action_id": .number(Double(actionID))])
                        try await proposeEdit(candidate: candidate, rowID: rowID, appBundleID: receipt.appBundleID)
                        return
                    }
                    pendingLearningActionID = actionID
                    pendingLearningTerm = term
                    showTransientState(.notice(Self.learningNotice(for: term)))
                } else if response.status == "already_known" {
                    return
                } else if response.status == "disabled" {
                    try await proposeEdit(candidate: candidate, rowID: rowID, appBundleID: receipt.appBundleID)
                }
            } catch {
                statusText = "Learning unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func proposeEdit(candidate: LearningCandidate, rowID: Int, appBundleID: String) async throws {
        let response = try await engine.request(op: "learned.propose", fields: [
            "produced": .string(candidate.produced), "replacement": .string(candidate.replacement),
            "row_id": .number(Double(rowID)), "app_bundle_id": .string(appBundleID)
        ])
        if let suggestion = response.suggestion,
           !learnedSuggestions.contains(where: { $0.id == suggestion.id }) {
            learnedSuggestions.insert(suggestion, at: 0)
        }
    }

    private func clearPendingLearning() {
        pendingLearningActionID = nil
        pendingLearningTerm = nil
    }

    private func clearDeferredMeetingNudge() {
        deferredMeetingNudge = nil
    }

    func undoPendingLearning() {
        guard Self.canBeginLearningUndo(actionID: pendingLearningActionID, inFlight: learningUndoInFlight),
              let actionID = pendingLearningActionID else { return }
        guard !previewMode else {
            pendingLearningActionID = nil
            pendingLearningTerm = nil
            return
        }
        learningUndoInFlight = true
        let term = pendingLearningTerm ?? "term"
        Task { [weak self] in
            guard let self else { return }
            defer { learningUndoInFlight = false }
            do {
                _ = try await engine.request(op: "learning.undo", fields: ["action_id": .number(Double(actionID))])
                guard pendingLearningActionID == actionID else { return }
                pendingLearningActionID = nil
                pendingLearningTerm = nil
                showNotice("Undid learning \(term)", hold: FlowBarMetrics.transientHold)
            } catch {
                statusText = "Learning unavailable: \(error.localizedDescription)"
            }
        }
    }

    func refreshLearnedSuggestions() async {
        if previewMode {
            learnedSuggestions = PreviewFixtures.suggestions
            return
        }
        do {
            let response = try await engine.request(op: "learned.list")
            learnedSuggestions = response.suggestions ?? []
        } catch { statusText = "Learning unavailable: \(error.localizedDescription)" }
    }

    func decideSuggestion(_ suggestion: LearnedSuggestion, action: String) {
        guard ["learned.add", "learned.ignore", "learned.never_ask"].contains(action) else { return }
        guard !previewMode else {
            learnedSuggestions.removeAll { $0.id == suggestion.id }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await engine.request(op: action, fields: ["suggestion_id": .number(Double(suggestion.id))])
                learnedSuggestions.removeAll { $0.id == suggestion.id }
            } catch { statusText = "Learning unavailable: \(error.localizedDescription)" }
        }
    }

    func insertLast(raw: Bool = false) {
        // The chord can fire while Undertone's own window is frontmost. Never
        // insert into a stale background target in that case; do nothing.
        guard inserter.snapshot().bundleID != Bundle.main.bundleIdentifier else { return }
        guard beginInsertAction() else { return }
        editWatcher.cancel()
        let capturedTarget = captureExternalTarget()
        if raw {
            guard let priorText = lastInsertedText,
                  let priorTarget = lastInsertTarget,
                  let replacement = lastInsertedRawText else {
                insertionInFlight = false
                showTransientError("Undo unavailable, no captured insertion target")
                return
            }
            Task { [weak self] in
                guard let self else { return }
                defer { self.insertionInFlight = false }
                if let bundleID = priorTarget.bundleID,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    app.activate(options: [])
                }
                try? await Task.sleep(for: .milliseconds(120))
                let outcome = self.inserter.replaceLastInsertion(priorText, with: replacement, target: priorTarget)
                if case .inserted = outcome {
                    self.lastInsertedText = replacement
                } else if case .failed(let reason) = outcome {
                    self.showTransientError(Self.failureMessage(reason))
                }
            }
            return
        }
        Task {
            defer { insertionInFlight = false }
            do {
                let response = try await engine.request(op: "history.last")
                guard let row = response.row, let text = row.preferredText else { return }
                guard let capturedTarget else {
                    showTransientError("No external insertion target")
                    return
                }
                if let bundleID = capturedTarget.bundleID,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    app.activate(options: [])
                }
                try? await Task.sleep(for: .milliseconds(120))
                let outcome = insertHistoryText(text, target: capturedTarget)
                if case .inserted = outcome {
                    lastInsertedText = text
                    lastInsertedRawText = row.rawText
                    lastInsertedRowID = row.id
                } else if case .failed(let reason) = outcome {
                    showTransientError(Self.failureMessage(reason))
                }
            } catch { showTransientError(error.localizedDescription) }
        }
    }

    func insert(row: HistoryRow, raw: Bool = false) {
        guard let text = raw ? row.rawText : row.preferredText else { return }
        guard beginInsertAction() else { return }
        editWatcher.cancel()
        guard let selectedTarget = externalTarget ?? captureExternalTarget() else {
            insertionInFlight = false
            showTransientError("No external insertion target")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.insertionInFlight = false }
            if let bundleID = selectedTarget.bundleID,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [])
            }
            try? await Task.sleep(for: .milliseconds(120))
            let outcome = self.insertHistoryText(text, target: selectedTarget)
            if case .inserted = outcome {
                self.lastInsertedText = text
                self.lastInsertedRawText = row.rawText
                self.lastInsertedRowID = row.id
            } else if case .failed(let reason) = outcome {
                self.showTransientError(Self.failureMessage(reason))
            }
        }
    }

    private func insertHistoryText(_ text: String, target: TargetSnapshot) -> InsertOutcome {
        let result = inserter.insert(text, target: target)
        if !result.isFailure { lastInsertTarget = target }
        return result
    }

    /// Plain-language reason for the transient pill and the accessibility
    /// permission prompt it can otherwise mask.
    nonisolated static func failureMessage(_ reason: InsertFailure) -> String {
        switch reason {
        case .emptyText: return "Insertion failed: nothing to insert"
        case .notTrusted: return "Accessibility permission required"
        case .appChanged: return "Insertion failed: app changed"
        case .elementChanged: return "Insertion failed: element changed"
        case .axRejected: return "Insertion failed: Accessibility rejected"
        case .typeFailed: return "Insertion failed: typing failed"
        }
    }

    func copyLast() {
        Task {
            do {
                let response = try await engine.request(op: "history.last")
                guard let text = response.row?.preferredText else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch { statusText = error.localizedDescription }
        }
    }

    func showApp(_ page: AppPage? = nil) {
        if let page { appPage = page }
        if !previewMode { externalTarget = captureExternalTarget() }
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Undertone"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("UndertoneMainWindow")
            window.contentView = NSHostingView(rootView: NativeAppView().environmentObject(self))
            window.center()
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissions()
    }

    func openWindow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) {
        if !previewMode { externalTarget = captureExternalTarget() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: previewMode ? 1200 : 850, height: previewMode ? 900 : 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content().environmentObject(self))
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    /// Starts meeting capture named after the detected call, used by a click
    /// on the dock's New note control. Drags do not call this. The pid goes
    /// through so the detector watches the process that is actually on the
    /// call, which is what auto-stop keys off.
    func recordDetectedMeeting() {
        guard !meetings.state.isBusy else { return }
        meetings.start(title: detectedMeeting?.suggestedTitle, callPID: detectedMeeting?.pid)
    }

    /// The level the dictation capsule is drawing right now.
    var listeningLevel: Double {
        guard case .listening(let level) = pillState else { return 0 }
        return level
    }

    /// What the New note control does on the next click: stop what is
    /// running, resume what auto-stop just ended, or start something new.
    var newNoteAction: FlowBarDock.NewNoteAction {
        FlowBarDock.newNoteAction(
            isRecording: meetings.state.isRecording,
            autoStoppedAt: meetings.lastAutoStop?.at,
            now: Date()
        )
    }

    // MARK: - Dock actions

    /// A click on Dictate is one tap of the hold key in lock mode: it starts
    /// dictation and leaves it running until the next click, Escape, or a tap
    /// of the hold key.
    func toggleDictationFromDock() {
        guard !previewMode else { return }
        hotkey.toggleByClick()
    }

    /// New note and Opt+M both land here. Right after an auto-stop the same
    /// control resumes that call instead of opening a blank meeting, which is
    /// the whole point of remembering it.
    func toggleMeetingCapture() {
        guard !previewMode else { return }
        switch newNoteAction {
        case .stop:
            meetings.stop()
        case .resume:
            cancelNudge()
            meetings.resumeLast()
        case .start:
            guard !meetings.state.isBusy else { return }
            cancelNudge()
            recordDetectedMeeting()
        }
    }

    /// Quick note and Opt+S both land here.
    func toggleQuickNote() {
        onQuickNoteToggle?()
    }

    /// Start note on the nudge card: capture named for the platform and the
    /// window that raised it.
    func startDetectedMeeting(_ detected: DetectedMeeting) {
        cancelNudge()
        guard !previewMode, !meetings.state.isBusy else { return }
        meetings.start(title: FlowBarDock.startNoteTitle(for: detected), callPID: detected.pid)
    }

    /// Ignore on the nudge card. `MeetingModel` owns the memory, so the card
    /// and the meeting screen cannot disagree about what was dismissed.
    func ignoreDetectedMeeting() {
        if let detected = detectedMeeting { meetings.ignore(detected) }
        cancelNudge()
    }

    /// Hovering the card pauses its countdown so a reachable mouse does not
    /// let the nudge time out underneath it.
    func setNudgeHovered(_ hovered: Bool) {
        nudgeHovered = hovered
    }

    /// Turns the nudge on or off wholesale. Settings writes the same key the
    /// detector reads.
    func setDetectCallsEnabled(_ enabled: Bool) {
        detectCallsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: MeetingDetectionSettings.detectCallsKey)
        if !enabled { cancelNudge() }
    }

    // MARK: - Meeting nudge

    /// Every reason the card stays down, in one place so the rule can be read
    /// and tested without a detector, a screen, or an engine.
    nonisolated static func shouldShowNudge(
        enabled: Bool, persistent: Bool, ignored: Bool, busy: Bool, pillIsIdle: Bool
    ) -> Bool {
        enabled && persistent && !ignored && !busy && pillIsIdle
    }

    private func detectionChanged(_ detected: DetectedMeeting?) {
        guard let detected else {
            meetings.clearIgnored()
            deferredMeetingNudge = nil
            cancelNudge()
            return
        }
        guard Self.shouldShowNudge(
            enabled: detectCallsEnabled,
            persistent: pillPersistent,
            ignored: meetings.isIgnored(detected),
            busy: meetings.state.isBusy,
            pillIsIdle: true
        ) else {
            deferredMeetingNudge = nil
            return
        }
        guard pillState == .idle else {
            if Self.shouldDeferMeetingNudge(for: pillState, pendingLearningTerm: pendingLearningTerm) {
                deferredMeetingNudge = detected
            }
            return
        }
        showNudge(detected)
    }

    private func showNudge(_ detected: DetectedMeeting) {
        clearPendingLearning()
        clearDeferredMeetingNudge()
        nudgeTask?.cancel()
        nudgeHovered = false
        nudgeFraction = 1
        Self.log.info("""
        nudge platform=\(detected.platform.rawValue, privacy: .public) \
        source=\(detected.source.rawValue, privacy: .public)
        """)
        pillState = .meetingDetected(detected)
        let total = FlowBarMetrics.nudgeAutoDismiss
        nudgeTask = Task { [weak self] in
            var remaining = total
            let step = 0.1
            while remaining > 0 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, case .meetingDetected = self.pillState else { return }
                if !self.nudgeHovered { remaining -= step }
                self.nudgeFraction = max(0, remaining / total)
            }
            guard let self, case .meetingDetected = self.pillState else { return }
            self.pillState = .idle
            self.nudgeTask = nil
        }
    }

    private func cancelNudge() {
        nudgeTask?.cancel()
        nudgeTask = nil
        clearDeferredMeetingNudge()
        nudgeHovered = false
        nudgeFraction = 1
        if case .meetingDetected = pillState { pillState = .idle }
    }

    // MARK: - Auto-stop

    /// The tracked call let go of the microphone for longer than the grace
    /// interval. Mute does not get here: Zoom and Teams keep the input open
    /// while muted, so the detector never sees a release.
    private func callEnded(_ meeting: DetectedMeeting) {
        // The call is over, so a dismissed card for it is spent too.
        meetings.clearIgnored()
        guard meetings.state.isRecording else { return }
        Self.log.info("""
        auto-stop platform=\(meeting.platform.rawValue, privacy: .public) \
        pid=\(meeting.pid ?? -1, privacy: .public)
        """)
        meetings.autoStop(reason: "\(meeting.platform.displayName) released the microphone")
        showNotice("Meeting ended", hold: FlowBarMetrics.meetingEndedHold)
    }

    // MARK: - Recording clock

    private func meetingStateChanged(_ state: MeetingModel.State) {
        guard state == .recording else {
            meetingElapsedTask?.cancel()
            meetingElapsedTask = nil
            if case .recording = pillState { pillState = .idle }
            return
        }
        cancelNudge()
        clearPendingLearning()
        clearDeferredMeetingNudge()
        meetingElapsedTask?.cancel()
        meetingElapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.meetings.state == .recording else { return }
                let started = self.meetings.recordingStartedAt ?? Date()
                self.pillState = .recording(elapsed: Date().timeIntervalSince(started))
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    // MARK: - Quick note

    /// Commits a Quick note. Returns a message when it could not be saved,
    /// and nil when it landed.
    @discardableResult
    func commitQuickNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recordingSessionID = meetings.state.isRecording ? meetings.currentSession?.sessionID : nil
        let destination = QuickNoteRouter.destination(
            recordingSessionID: recordingSessionID,
            vaultPath: obsidianVaultPath,
            date: Date(),
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
        guard !previewMode else {
            showQuickNoteReceipt()
            return nil
        }
        switch destination {
        case .meetingNotes:
            // The engine owns meeting notes, so append through the model that
            // already debounces and retries those saves.
            meetings.updateNotes(QuickNoteRouter.appended(existing: meetings.currentSession?.notes,
                                                          addition: trimmed))
            meetings.flushEdits()
        case .dailyNote(let path), .localFallback(let path):
            do {
                try QuickNoteRouter.appendToFile(trimmed, path: path)
            } catch {
                return "Quick note not saved: \(error.localizedDescription)"
            }
        }
        showQuickNoteReceipt()
        return nil
    }

    private func showQuickNoteReceipt() {
        showNotice("Saved", hold: FlowBarMetrics.savedHold)
    }

    /// A short receipt on the dock. It never interrupts dictation or a live
    /// capture: those states own the dock while they run.
    private func showNotice(_ message: String, hold: Duration) {
        let nextState = PillState.notice(message)
        switch pillState {
        case .idle, .notice:
            break
        case .listening, .working, .inserted, .guarded, .error, .recording, .meetingDetected:
            return
        }
        clearPendingLearning()
        if !Self.preservesDeferredMeetingNudge(nextState) { clearDeferredMeetingNudge() }
        pillState = nextState
        schedulePillReset(from: nextState, after: hold)
    }

    /// Persists a new pill dock position, applied immediately for the panel
    /// and written through to the engine config.
    func setPillDock(edge: PillEdge, offset: Double) {
        pillEdge = edge
        pillOffset = offset
        guard !previewMode else { return }
        updateConfig("pill_edge", .string(edge.rawValue))
        updateConfig("pill_offset", .number(offset))
    }

    func resetPillPosition() {
        setPillDock(edge: pillEdge, offset: 0.5)
    }

    func updateConfig(_ key: String, _ value: JSONValue) {
        configError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await engine.request(op: "config.update", fields: ["config": .object([key: value])])
            } catch {
                configError = error.localizedDescription
                statusText = "Settings error: \(error.localizedDescription)"
            }
        }
    }

    private func captureExternalTarget() -> TargetSnapshot? {
        let snapshot = inserter.snapshot()
        if snapshot.bundleID != Bundle.main.bundleIdentifier {
            // A frontmost external app with no focused element is not a valid
            // insertion target. Clear the old target so a later action cannot
            // inject into a previous application.
            externalTarget = snapshot.element == nil ? nil : snapshot
        }
        return externalTarget
    }

    private func beginInsertAction() -> Bool {
        switch pillState {
        case .listening:
            statusText = "Finish dictation before inserting"
            return false
        case .working:
            statusText = "Please wait for dictation to finish"
            return false
        default:
            break
        }
        guard !insertionInFlight else {
            statusText = "Insertion already in progress"
            return false
        }
        insertionInFlight = true
        return true
    }

    private func showTransientError(_ message: String) {
        showTransientError(message, duration: FlowBarMetrics.transientHold)
    }

    private func showTransientError(_ message: String, duration: Duration) {
        clearPendingLearning()
        clearDeferredMeetingNudge()
        pillState = .error(message)
        schedulePillReset(from: .error(message), after: duration)
    }

    /// Inserted is a receipt, not a warning, so it leaves twice as fast as
    /// Kept raw and Error do.
    private func showTransientState(_ state: PillState) {
        let preservesLearning = if case .notice = state,
                                    let term = pendingLearningTerm {
            Self.isLearningNotice(state, term: term)
        } else { false }
        if !preservesLearning {
            clearPendingLearning()
            clearDeferredMeetingNudge()
        }
        pillState = state
        schedulePillReset(from: state, after: FlowBarMetrics.transientHold(for: state))
    }

    private func schedulePillReset(from expected: PillState, after duration: Duration) {
        pillResetTask?.cancel()
        pillResetTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.pillState == expected else { return }
            let deferredMeeting = self.deferredMeetingNudge
            self.pillState = .idle
            if case .notice = expected {
                self.pendingLearningActionID = nil
                self.pendingLearningTerm = nil
            }
            self.pillResetTask = nil
            guard let deferredMeeting,
                  Self.shouldShowDeferredMeetingNudge(
                current: self.detectedMeeting,
                deferred: deferredMeeting,
                enabled: self.detectCallsEnabled,
                persistent: self.pillPersistent,
                ignored: self.meetings.isIgnored(self.detectedMeeting),
                busy: self.meetings.state.isBusy,
                pillIsIdle: self.pillState == .idle
            ) else {
                self.deferredMeetingNudge = nil
                return
            }
            self.showNudge(deferredMeeting)
        }
    }

    private func retainRawTranscript(kind: String, rawText: String, instructionText: String?, alongside audioURL: URL) throws {
        let sidecarURL = audioURL.appendingPathExtension("json")
        var payload: [String: String]
        if kind == "command", let instructionText {
            payload = Self.commandSidecarPayload(selectedText: rawText, instruction: instructionText)
        } else {
            payload = ["kind": "dictation", "raw_text": rawText]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: sidecarURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecarURL.path)
    }

    private func setEngineStatus(_ message: String) {
        engineStatusText = message
        engineReady = message.hasSuffix("· ready")
        let permissionMessage = accessibilityUnavailable ? "Accessibility permission required · \(message)" : message
        statusText = inputMonitoringUnavailable
            ? "Input Monitoring permission required · \(permissionMessage)"
            : permissionMessage
    }

    private func startPowerMonitor() {
        guard !previewMode else {
            slowerOnBattery = PreviewFixtures.slowerOnBattery
            return
        }
        let monitor = PowerStateMonitor()
        monitor.onChange = { [weak self] slower in
            self?.slowerOnBattery = slower
        }
        monitor.start()
        slowerOnBattery = monitor.slowerOnBattery
        powerMonitor = monitor
    }

    private func startMeetingDetector() {
        guard !previewMode else {
            detectedMeeting = PreviewFixtures.detectedMeeting
            return
        }
        let detector = MeetingAppDetector()
        detector.onChange = { [weak self] detected in
            self?.detectedMeeting = detected
        }
        detector.onCallEnded = { [weak self] meeting in
            self?.callEnded(meeting)
        }
        detector.start()
        detectedMeeting = detector.detected
        meetingDetector = detector
    }

    private func refreshPermissionsAndHotkey() {
        accessibilityUnavailable = !AXIsProcessTrusted()
        inputMonitoringUnavailable = !CGPreflightListenEventAccess()
        permissionSnapshot = .current()
        guard !previewMode else { return }
        guard !accessibilityUnavailable, !inputMonitoringUnavailable else {
            hotkey.stop()
            return
        }
        guard !hotkey.isRunning else { return }
        _ = hotkey.start()
    }

    private func audioSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
