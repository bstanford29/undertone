import AppKit
import Foundation
import SwiftUI

struct MeetingPendingManifest: Codable, Equatable, Sendable {
    let sessionID: String
    let title: String
    let startedAt: Double
    var chunks: [MeetingChunk]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", title, startedAt = "started_at", chunks
    }
}

/// One block of a structured meeting summary, ready to render.
enum MeetingSummaryBlock: Equatable, Sendable, Identifiable {
    case heading(String)
    case bullet(String)
    case paragraph(String)

    var id: String {
        switch self {
        case .heading(let text): return "h:\(text)"
        case .bullet(let text): return "b:\(text)"
        case .paragraph(let text): return "p:\(text)"
        }
    }
}

enum MeetingSummaryMarkdown {
    /// Reads the small Markdown subset the summarizer writes: "## " headings,
    /// "- " or "* " bullets, and plain lines. Anything else stays a paragraph,
    /// so an older unstructured summary still reads correctly.
    static func blocks(_ text: String) -> [MeetingSummaryBlock] {
        var blocks: [MeetingSummaryBlock] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let heading = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                blocks.append(.heading(String(trimmed[heading.upperBound...])))
            } else if let bullet = trimmed.range(of: #"^([-*•]|\d+\.)\s+"#, options: .regularExpression) {
                blocks.append(.bullet(String(trimmed[bullet.upperBound...])))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        return blocks
    }
}

enum MeetingLifecyclePolicy {
    static func shouldRetryChunk(status: String) -> Bool {
        status != "complete" && status != "silence"
    }

    static func canLoadSession(isCapturing: Bool, pendingCount: Int, uploadInFlight: Bool) -> Bool {
        !isCapturing && pendingCount == 0 && !uploadInFlight
    }

    static func canExport(isCapturing: Bool, pendingCount: Int,
                          uploadInFlight: Bool, exportInFlight: Bool) -> Bool {
        !isCapturing && pendingCount == 0 && !uploadInFlight && !exportInFlight
    }
}

private final class MeetingChunkInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [MeetingChunk] = []

    func append(_ chunk: MeetingChunk) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(chunk)
    }

    func drain() -> [MeetingChunk] {
        lock.lock(); defer { lock.unlock() }
        let result = chunks
        chunks.removeAll(keepingCapacity: true)
        return result
    }
}

@MainActor
final class MeetingModel: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case recording
        case stopping
        case summarizing
        case error(String)

        var isRecording: Bool { self == .recording || self == .starting || self == .stopping }
        var isBusy: Bool { isRecording || self == .summarizing }
    }

    let engine: EngineClient
    let recorder: MeetingRecorder
    let previewMode: Bool
    @Published private(set) var state: State = .idle
    @Published private(set) var currentSession: MeetingSession?
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var transcript: [MeetingChunkRecord] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var systemAudioLevel = 0.0
    @Published var errorMessage: String?
    @Published var searchQuery = ""
    /// The call auto-stop ended, kept so the dock can offer Resume.
    @Published private(set) var lastAutoStop: AutoStop?
    /// A detection the user dismissed. It stays hidden until the detected
    /// value changes, which means a new call or a new platform.
    @Published private(set) var ignoredDetection: DetectedMeeting?
    /// The process holding the microphone for the meeting being recorded, so
    /// the detector watches the right one for release.
    private(set) var activeCallPID: pid_t?
    var canStartMeeting: (() -> Bool)?

    /// What auto-stop ended, and why.
    struct AutoStop: Equatable, Sendable {
        let title: String
        let at: Date
        let reason: String
    }

    /// Typing pauses this long before the edit is saved.
    static let saveDebounceMilliseconds = 600

    private var saveTask: Task<Void, Never>?
    private var pendingSessionID: String?
    private var pendingNotes: String?
    private var pendingSummary: String?

    private let inbox = MeetingChunkInbox()
    private let manifestURL: URL
    private var pending: [Int: MeetingChunk] = [:]
    private var pollTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var activeLoadToken: UUID?

    var hasPendingRecovery: Bool { !pending.isEmpty }
    var canLoadSession: Bool {
        MeetingLifecyclePolicy.canLoadSession(isCapturing: state.isBusy,
                                               pendingCount: pending.count,
                                               uploadInFlight: uploadTask != nil || exportTask != nil)
    }
    var canExportCurrent: Bool {
        MeetingLifecyclePolicy.canExport(isCapturing: state.isBusy,
                                         pendingCount: pending.count,
                                         uploadInFlight: uploadTask != nil,
                                         exportInFlight: exportTask != nil)
    }

    init(engine: EngineClient, previewMode: Bool = false, recorder: MeetingRecorder = MeetingRecorder()) {
        self.engine = engine
        self.previewMode = previewMode
        self.recorder = recorder
        let root = URL(fileURLWithPath: NSString(string: "~/.undertone/meetings").expandingTildeInPath,
                       isDirectory: true)
        self.manifestURL = root.appendingPathComponent("pending.json")
        recorder.onChunk = { [weak self] chunk in self?.inbox.append(chunk) }
        recorder.onLevels = { [weak self] speaker, level in
            Task { @MainActor [weak self] in
                self?.receiveAudioLevel(speaker, level: level)
            }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor in self?.handleRecorderError(error) }
        }
        if !previewMode { loadManifest() }
    }

    deinit {
        pollTask?.cancel()
    }

    func start(title: String? = nil, callPID: pid_t? = nil) {
        guard !previewMode else { errorMessage = "Preview mode does not start capture."; return }
        guard canStartMeeting?() ?? true else {
            errorMessage = "Stop dictation before starting meeting capture."
            return
        }
        guard pending.isEmpty else {
            errorMessage = "Retry or export the pending meeting before starting another."
            return
        }
        guard state == .idle || { if case .error = state { return true }; return false }() else { return }
        guard MeetingRecorder.permissionStatus() == .ready else {
            errorMessage = MeetingRecorderError.permissions(MeetingRecorder.permissionStatus()).localizedDescription
            return
        }
        activeLoadToken = nil
        activeCallPID = callPID
        state = .starting
        errorMessage = nil
        recordingStartedAt = nil
        microphoneLevel = 0
        systemAudioLevel = 0
        Task { [weak self] in
            guard let self else { return }
            do {
                var fields: [String: JSONValue] = [:]
                if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fields["title"] = .string(title)
                }
                let response = try await engine.request(op: "meeting.start", fields: fields)
                guard let session = self.session(from: response) else {
                    throw EngineClientError.protocolViolation("meeting.start returned no session")
                }
                currentSession = session
                pending.removeAll()
                transcript.removeAll()
                persistManifest()
                try await recorder.start()
                recordingStartedAt = Date()
                state = .recording
                startPolling()
            } catch {
                _ = await recorder.stop()
                drainInbox()
                startUploadIfNeeded()
                await uploadTask?.value
                if pending.isEmpty {
                    state = .error(error.localizedDescription)
                    errorMessage = error.localizedDescription
                } else {
                    let message = "Meeting start failed; \(pending.count) audio chunk(s) retained for retry."
                    state = .error(message)
                    errorMessage = message
                }
                recordingStartedAt = nil
                microphoneLevel = 0
                systemAudioLevel = 0
                activeCallPID = nil
            }
        }
    }

    /// Stops capture the way End does, then remembers the title so the dock
    /// can offer Resume. The detector calls this when the call app has let go
    /// of the microphone for longer than the grace interval.
    func autoStop(reason: String) {
        guard state == .recording else { return }
        lastAutoStop = AutoStop(title: currentSession?.title ?? "Meeting", at: Date(), reason: reason)
        stop()
    }

    /// Preview only: arms the Resume offer with no capture behind it, so the
    /// dock's Resume label can be inspected without a live call.
    func previewAutoStop(title: String = "Zoom · Process flows review") {
        guard previewMode else { return }
        lastAutoStop = AutoStop(title: title, at: Date(), reason: "preview")
    }

    /// Starts a new session under the title of the call that auto-stopped.
    func resumeLast() {
        guard let last = lastAutoStop else { return }
        lastAutoStop = nil
        start(title: last.title)
    }

    /// Hides the card for this exact detection. A different call, or the same
    /// app on a different meeting, produces a different value and shows again.
    func ignore(_ detection: DetectedMeeting) {
        ignoredDetection = detection
    }

    func isIgnored(_ detection: DetectedMeeting?) -> Bool {
        guard let detection, let ignoredDetection else { return false }
        return detection == ignoredDetection
    }

    func clearIgnored() {
        ignoredDetection = nil
    }

    func stop() {
        guard state == .recording else { return }
        state = .stopping
        activeCallPID = nil
        microphoneLevel = 0
        systemAudioLevel = 0
        pollTask?.cancel(); pollTask = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await recorder.stop()
            drainInbox()
            startUploadIfNeeded()
            await uploadTask?.value
            guard pending.isEmpty else {
                let message = "Some meeting chunks are still pending. Retry before ending."
                state = .error(message); errorMessage = message
                return
            }
            guard let sessionID = currentSession?.sessionID else {
                state = .error("Meeting session is missing")
                return
            }
            state = .summarizing
            do {
                let response = try await engine.request(op: "meeting.end", fields: ["session_id": .string(sessionID)])
                if let session = self.session(from: response) { currentSession = session }
                clearManifest()
                state = .idle
                recordingStartedAt = nil
                microphoneLevel = 0
                systemAudioLevel = 0
                await loadSessions()
            } catch {
                state = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadSessions() async {
        guard !previewMode else { sessions = PreviewFixtures.meetingSessions; return }
        do {
            let response = try await engine.request(op: "meeting.list", fields: ["limit": .number(100)])
            sessions = response.sessions ?? []
        } catch { errorMessage = error.localizedDescription }
    }

    func load(_ session: MeetingSession) async {
        guard !previewMode else {
            currentSession = session
            transcript = session.chunks ?? PreviewFixtures.meetingTranscript
            return
        }
        guard canLoadSession else {
            errorMessage = hasPendingRecovery
                ? "Retry or export pending meeting audio before opening another session."
                : "Finish meeting capture before opening another session."
            return
        }
        let loadToken = UUID()
        activeLoadToken = loadToken
        defer {
            if activeLoadToken == loadToken { activeLoadToken = nil }
        }
        do {
            var offset = 0
            var pages = 0
            var loadedSession = session
            var chunks: [MeetingChunkRecord] = []
            repeat {
                let response = try await engine.request(op: "meeting.get", fields: [
                    "session_id": .string(session.sessionID),
                    "offset": .number(Double(offset)),
                    "limit": .number(100),
                ])
                guard activeLoadToken == loadToken, canLoadSession else { return }
                if let pageSession = response.session {
                    loadedSession = pageSession
                    chunks.append(contentsOf: pageSession.chunks ?? [])
                }
                pages += 1
                guard let nextOffset = response.nextOffset, nextOffset > offset, pages < 1000 else { break }
                offset = nextOffset
            } while true
            guard activeLoadToken == loadToken, canLoadSession else { return }
            currentSession = MeetingSession(sessionID: loadedSession.sessionID, title: loadedSession.title,
                                            startedAt: loadedSession.startedAt, endedAt: loadedSession.endedAt,
                                            status: loadedSession.status, summary: loadedSession.summary,
                                            notePath: loadedSession.notePath, transcriptPath: loadedSession.transcriptPath,
                                            chunkCount: loadedSession.chunkCount, chunks: chunks,
                                            notes: loadedSession.notes, titleSource: loadedSession.titleSource,
                                            summaryEdited: loadedSession.summaryEdited,
                                            updatedAt: loadedSession.updatedAt,
                                            searchText: loadedSession.searchText ?? session.searchText)
            transcript = chunks
            pending = Dictionary(uniqueKeysWithValues: chunks.compactMap { row in
                guard MeetingLifecyclePolicy.shouldRetryChunk(status: row.status),
                      let path = row.sourcePath ?? row.retainedPath else { return nil }
                return (row.seq, MeetingChunk(sequence: row.seq, speaker: row.speaker,
                                              path: URL(fileURLWithPath: path), offset: row.offsetS,
                                              duration: row.durationS,
                                              voiceActivity: row.voiceActivity ?? true))
            })
            pendingCount = pending.count
            if !pending.isEmpty { persistManifest() }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Editing

    /// The meetings the search box leaves visible, recording one first.
    var filteredSessions: [MeetingSession] {
        sessions
            .filter { MeetingModel.matches(session: $0, query: searchQuery) }
            .sorted { first, second in
                let firstLive = first.status == "recording", secondLive = second.status == "recording"
                if firstLive != secondLive { return firstLive }
                return first.startedAt > second.startedAt
            }
    }

    /// Case-insensitive contains over the engine's search field, with a local
    /// fallback for an older engine that does not send one.
    static func matches(session: MeetingSession, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return haystack(for: session).contains(needle)
    }

    static func haystack(for session: MeetingSession) -> String {
        if let text = session.searchText, !text.isEmpty { return text.lowercased() }
        return [session.title, session.summary ?? "", session.notes ?? ""]
            .joined(separator: " ")
            .lowercased()
    }

    /// Skips a save that would write back what the engine already stores.
    static func shouldSave(draft: String, stored: String?) -> Bool {
        draft != (stored ?? "")
    }

    func updateTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = currentSession,
              MeetingModel.shouldSave(draft: trimmed, stored: session.title) else { return }
        save(sessionID: session.sessionID, title: trimmed, notes: nil, summary: nil)
    }

    func updateNotes(_ notes: String) {
        guard let session = currentSession,
              MeetingModel.shouldSave(draft: notes, stored: session.notes) else { return }
        pendingNotes = notes
        scheduleSave(for: session.sessionID)
    }

    func updateSummary(_ summary: String) {
        guard let session = currentSession,
              MeetingModel.shouldSave(draft: summary, stored: session.summary) else { return }
        pendingSummary = summary
        scheduleSave(for: session.sessionID)
    }

    /// Writes any waiting edit at once. The view calls this when it disappears.
    func flushEdits() {
        saveTask?.cancel()
        saveTask = nil
        guard let sessionID = pendingSessionID, pendingNotes != nil || pendingSummary != nil else { return }
        let notes = pendingNotes, summary = pendingSummary
        pendingNotes = nil; pendingSummary = nil; pendingSessionID = nil
        save(sessionID: sessionID, title: nil, notes: notes, summary: summary)
    }

    func regenerateSummary() {
        guard let session = currentSession else { return }
        guard !previewMode else { errorMessage = "Preview mode does not summarize."; return }
        guard !state.isBusy else {
            errorMessage = "Finish meeting capture before summarizing again."
            return
        }
        flushEdits()
        state = .summarizing
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await engine.meetingSummarize(sessionID: session.sessionID)
                if let updated = response.session { apply(updated) }
                state = .idle
                await loadSessions()
            } catch {
                state = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleSave(for sessionID: String) {
        pendingSessionID = sessionID
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(MeetingModel.saveDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.flushEdits()
        }
    }

    private func save(sessionID: String, title: String?, notes: String?, summary: String?) {
        guard !previewMode else {
            applyLocalEdit(sessionID: sessionID, title: title, notes: notes, summary: summary)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await engine.meetingUpdate(sessionID: sessionID, title: title,
                                                              notes: notes, summary: summary)
                if let updated = response.session { apply(updated) }
            } catch {
                errorMessage = "Meeting edit not saved: \(error.localizedDescription)"
            }
        }
    }

    /// Preview mode keeps edits in memory so the screen can be tried without
    /// an engine. Nothing is written to disk.
    private func applyLocalEdit(sessionID: String, title: String?, notes: String?, summary: String?) {
        let known = currentSession?.sessionID == sessionID
            ? currentSession
            : sessions.first { $0.sessionID == sessionID }
        guard var session = known else { return }
        if let title { session.title = title; session.titleSource = "user" }
        if let notes { session.notes = notes }
        if let summary { session.summary = summary; session.summaryEdited = true }
        session.searchText = nil
        apply(session)
    }

    private func apply(_ session: MeetingSession) {
        if currentSession?.sessionID == session.sessionID { currentSession = session }
        guard let index = sessions.firstIndex(where: { $0.sessionID == session.sessionID }) else { return }
        var row = session
        // meeting.get and meeting.update do not send a search field; rebuild it
        // so the list keeps filtering on the text that is now on screen.
        row.searchText = MeetingModel.haystack(for: session)
        sessions[index] = row
    }

    func retryFailed() {
        guard !previewMode else { errorMessage = "Preview mode does not retry audio."; return }
        guard !state.isBusy else {
            errorMessage = "Finish the active meeting operation before retrying."
            return
        }
        drainInbox()
        startUploadIfNeeded()
    }

    func exportCurrent() {
        guard !previewMode else { errorMessage = "Preview mode does not export notes."; return }
        guard canExportCurrent else {
            errorMessage = "Stop capture and finish pending audio before exporting."
            return
        }
        guard let sessionID = currentSession?.sessionID else { return }
        let exportSessionID = sessionID
        state = .summarizing
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }
            do {
                guard self.state == .summarizing,
                      self.currentSession?.sessionID == exportSessionID,
                      self.pending.isEmpty else { return }
                let response = try await engine.request(op: "meeting.end", fields: ["session_id": .string(exportSessionID)])
                guard self.currentSession?.sessionID == exportSessionID, self.pending.isEmpty else {
                    self.errorMessage = "Export finished without clearing pending audio."
                    return
                }
                currentSession = session(from: response) ?? currentSession
                clearManifest()
                await loadSessions()
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectPendingIfNeeded() {
        guard currentSession != nil else { return }
        pendingCount = pending.count
    }

    /// Called by the recorder's audio-level callback on the main actor. The
    /// recorder owns RMS calculation; the model only bounds values for UI.
    func receiveAudioLevel(_ speaker: MeetingSpeaker, level: Double) {
        guard state.isBusy else { return }
        let value = level.isFinite ? min(1, max(0, level)) : 0
        switch speaker {
        case .me: microphoneLevel = value
        case .others: systemAudioLevel = value
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                drainInbox()
                startUploadIfNeeded()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func drainInbox() {
        for chunk in inbox.drain() {
            guard pending[chunk.sequence] == nil,
                  !transcript.contains(where: { $0.seq == chunk.sequence }) else { continue }
            pending[chunk.sequence] = chunk
            transcript.append(MeetingChunkRecord(seq: chunk.sequence, offsetS: chunk.offset,
                                                 durationS: chunk.duration, speaker: chunk.speaker,
                                                 status: "pending", text: nil, sttMS: nil,
                                                 errorCode: nil, retainedPath: chunk.path.path,
                                                 sourcePath: chunk.path.path,
                                                 voiceActivity: chunk.voiceActivity))
        }
        pendingCount = pending.count
        persistManifest()
    }

    private func startUploadIfNeeded() {
        guard uploadTask == nil, !pending.isEmpty else { return }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.drainAndUpload()
            self.uploadTask = nil
        }
    }

    private func drainAndUpload() async {
        guard currentSession != nil else { return }
        drainInbox()
        while let sequence = pending.keys.min(), let chunk = pending[sequence] {
            do {
                let response = try await engine.request(op: "meeting.chunk", fields: [
                    "session_id": .string(currentSession!.sessionID),
                    "seq": .number(Double(chunk.sequence)),
                    "audio_path": .string(chunk.path.path),
                    "speaker": .string(chunk.speaker.rawValue),
                    "offset_s": .number(chunk.offset),
                    "duration_s": .number(chunk.duration),
                    "voice_activity": .bool(chunk.voiceActivity),
                ])
                updateTranscript(sequence: sequence, response: response)
                guard response.status == "complete" || response.status == "silence" else {
                    errorMessage = "Meeting chunk \(sequence) retained; transcription failed. Retry to try again."
                    persistManifest()
                    return
                }
                pending.removeValue(forKey: sequence)
                pendingCount = pending.count
                persistManifest()
            } catch {
                errorMessage = "Meeting chunk \(sequence) pending: \(error.localizedDescription)"
                return
            }
        }
    }

    private func updateTranscript(sequence: Int, response: EngineResponse) {
        guard let index = transcript.firstIndex(where: { $0.seq == sequence }) else { return }
        let prior = transcript[index]
        transcript[index] = MeetingChunkRecord(seq: prior.seq, offsetS: prior.offsetS,
                                               durationS: prior.durationS, speaker: prior.speaker,
                                               status: response.status ?? "complete", text: response.text,
                                               sttMS: response.sttMS, errorCode: response.errorCode,
                                               retainedPath: prior.retainedPath,
                                               sourcePath: prior.sourcePath,
                                               voiceActivity: prior.voiceActivity)
    }

    private func session(from response: EngineResponse) -> MeetingSession? {
        if let session = response.session { return session }
        guard let sessionID = response.sessionID else { return nil }
        return MeetingSession(sessionID: sessionID, title: response.title ?? "Meeting",
                              startedAt: response.startedAt ?? Date().timeIntervalSince1970,
                              endedAt: response.endedAt, status: response.status ?? "recording",
                              summary: response.summary, notePath: response.notePath,
                              transcriptPath: response.transcriptPath, chunkCount: response.chunkCount ?? 0,
                              chunks: response.chunks)
    }

    private func handleRecorderError(_ error: MeetingRecorderError) {
        errorMessage = error.localizedDescription
        if state == .recording {
            state = .stopping
            pollTask?.cancel()
            pollTask = nil
            Task { [weak self] in
                guard let self else { return }
                _ = await self.recorder.stop()
                self.drainInbox()
                self.startUploadIfNeeded()
                await self.uploadTask?.value
                self.microphoneLevel = 0
                self.systemAudioLevel = 0
                self.activeCallPID = nil
                if self.pending.isEmpty {
                    self.state = .error(error.localizedDescription)
                } else {
                    self.state = .error("Capture failed; \(self.pending.count) audio chunk(s) retained for retry.")
                }
                self.errorMessage = self.state == .error(error.localizedDescription)
                    ? error.localizedDescription
                    : "Capture failed; audio retained for retry."
            }
        }
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(MeetingPendingManifest.self, from: data) else { return }
        currentSession = MeetingSession(sessionID: manifest.sessionID, title: manifest.title,
                                        startedAt: manifest.startedAt, status: "recording",
                                        chunkCount: manifest.chunks.count)
        pending = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.sequence, $0) })
        pendingCount = pending.count
        state = .error("Pending meeting audio needs retry")
        errorMessage = "Pending meeting audio needs retry before export."
    }

    private func persistManifest() {
        guard let session = currentSession, !pending.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: manifestURL.deletingLastPathComponent().path)
            let manifest = MeetingPendingManifest(sessionID: session.sessionID, title: session.title,
                                                  startedAt: session.startedAt,
                                                  chunks: pending.values.sorted { $0.sequence < $1.sequence })
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch { errorMessage = "Could not save pending meeting manifest: \(error.localizedDescription)" }
    }

    private func clearManifest() {
        guard pending.isEmpty else { return }
        pending.removeAll()
        pendingCount = 0
        try? FileManager.default.removeItem(at: manifestURL)
    }
}
