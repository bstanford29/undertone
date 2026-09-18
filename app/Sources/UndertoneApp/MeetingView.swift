import SwiftUI

struct MeetingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var startTitle = ""
    @State private var selectedSessionID: String?
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var summaryDraft = ""
    @State private var editingSummary = false
    @State private var confirmRegenerate = false
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool

    private var meetings: MeetingModel { model.meetings }

    /// The detail column edits the fully loaded session only. A list row holds
    /// shortened previews, so typing against one could truncate real text.
    private var detailSession: MeetingSession? {
        guard let current = meetings.currentSession else { return nil }
        guard let selected = selectedSessionID else { return current }
        return current.sessionID == selected ? current : nil
    }

    private var searchQuery: Binding<String> {
        Binding(get: { meetings.searchQuery }, set: { meetings.searchQuery = $0 })
    }

    private var selection: Binding<String?> {
        Binding(get: { selectedSessionID }, set: { open($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting notes").font(.title2.bold())
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }
            if let message = meetings.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            recordingStatusCard
            HStack(alignment: .top, spacing: 18) {
                sessionsPanel
                detailPanel
            }
        }
        .padding(22)
        // Keep the full header and action row visible in the 850x560 preview
        // window; both content panels already scroll independently.
        .frame(minWidth: 700, minHeight: 300)
        .background(searchShortcut)
        .task {
            await meetings.loadSessions()
            if selectedSessionID == nil, let current = meetings.currentSession {
                selectedSessionID = current.id
            } else if selectedSessionID == nil, meetings.canLoadSession,
                      !meetings.hasPendingRecovery, let first = meetings.sessions.first {
                selectedSessionID = first.id
                await meetings.load(first)
            }
            syncDrafts()
        }
        .onChange(of: detailSession?.id) { _, _ in syncDrafts() }
        .onChange(of: detailSession?.title) { _, title in
            if !titleFocused, let title { titleDraft = title }
        }
        .onChange(of: detailSession?.summary) { _, summary in
            if !editingSummary { summaryDraft = summary ?? "" }
        }
        .onDisappear { meetings.flushEdits() }
    }

    // MARK: Recording

    @ViewBuilder
    private var controls: some View {
        if meetings.state == .summarizing {
            Label("Finalizing meeting notes…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        } else if model.previewMode && meetings.currentSession?.status == "recording" {
            Label("Recording fixture", systemImage: "waveform")
                .foregroundStyle(.secondary)
        } else if meetings.state.isRecording {
            Button("End and summarize", role: .destructive) {
                if !model.previewMode { meetings.stop() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(model.previewMode || meetings.state != .recording)
        } else {
            HStack(spacing: 8) {
                TextField("Title (optional, auto-named when the meeting ends)", text: $startTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                Button("Start meeting notes") { meetings.start(title: startTitle) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.previewMode)
            }
        }
    }

    private var recordingStatusCard: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            HStack(spacing: 16) {
                Circle()
                    .fill(recordingStatusColor)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recordingStatusTitle)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(recordingStatusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let elapsed = recordingElapsedLabel(at: context.date) {
                            Text(elapsed)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 6) {
                    AudioLevelMeter(label: "Me", level: meetings.microphoneLevel, tint: .blue)
                    AudioLevelMeter(label: "Others", level: meetings.systemAudioLevel, tint: .cyan)
                }
                if meetings.state == .recording {
                    Button("End") { meetings.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.previewMode)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(recordingStatusColor.opacity(0.24))
            }
        }
    }

    // MARK: Meetings list

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search meetings", text: searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !meetings.searchQuery.isEmpty {
                    Button {
                        meetings.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if meetings.filteredSessions.isEmpty {
                Text(meetings.searchQuery.isEmpty
                     ? "No meetings yet. Start one above."
                     : "No meetings match that search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                List(selection: selection) {
                    ForEach(meetings.filteredSessions) { session in
                        sessionRow(session).tag(session.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .disabled(!meetings.canLoadSession)
            }
        }
        .frame(width: 292, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func sessionRow(_ session: MeetingSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .opacity(session.status == "recording" ? 1 : 0)
                .accessibilityHidden(session.status != "recording")
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(rowMeta(session))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(summaryPreview(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let session = detailSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    captionLine(session)
                    notesSection
                    summarySection(session)
                    transcriptSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if selectedSessionID != nil {
            placeholder("Opening meeting…", detail: "Loading the transcript and notes from this Mac.")
        } else {
            placeholder("No meeting selected",
                        detail: "Pick a meeting on the left, or start a new one.")
        }
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var titleField: some View {
        TextField("Meeting title", text: $titleDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .focused($titleFocused)
            .onSubmit { commitTitle() }
            .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(titleFocused ? 0.07 : 0.0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor.opacity(titleFocused ? 0.45 : 0))
            }
            .padding(.leading, -8)
    }

    private func captionLine(_ session: MeetingSession) -> some View {
        HStack(spacing: 7) {
            Text(startedLabel(session))
            Text("·")
            Text(durationLabel(session))
            Text("·")
            Label("Processed locally", systemImage: "lock.shield")
            Spacer(minLength: 8)
            detailActions(session)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func detailActions(_ session: MeetingSession) -> some View {
        HStack(spacing: 8) {
            if meetings.pendingCount > 0 {
                Button("Retry failed") { meetings.retryFailed() }
                    .disabled(model.previewMode || meetings.state.isBusy)
            }
            Button(session.status == "summary_failed" ? "Retry summary" : "Export to Obsidian") {
                meetings.exportCurrent()
            }
            .disabled(model.previewMode || !meetings.canExportCurrent || session.status == "ended")
        }
        .font(.caption)
    }

    private var notesSection: some View {
        section("Notes") {
            EmptyView()
        } content: {
            ZStack(alignment: .topLeading) {
                if notesDraft.isEmpty {
                    Text("Your notes. These are never rewritten.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notesDraft)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 92)
                    .onChange(of: notesDraft) { _, value in meetings.updateNotes(value) }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ session: MeetingSession) -> some View {
        section("Summary") {
            HStack(spacing: 8) {
                if session.summaryEdited == true && !editingSummary {
                    Text("Edited by you")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(editingSummary ? "Done" : "Edit") {
                    if editingSummary {
                        meetings.updateSummary(summaryDraft)
                        meetings.flushEdits()
                    } else {
                        summaryDraft = session.summary ?? ""
                    }
                    editingSummary.toggle()
                }
                .font(.caption)
                Button("Regenerate") {
                    if session.summaryEdited == true {
                        confirmRegenerate = true
                    } else {
                        editingSummary = false
                        meetings.regenerateSummary()
                    }
                }
                .font(.caption)
                .disabled(model.previewMode || meetings.state.isBusy)
            }
        } content: {
            if meetings.state == .summarizing {
                Label("Summarizing…", systemImage: "ellipsis.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if editingSummary {
                TextEditor(text: $summaryDraft)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .onChange(of: summaryDraft) { _, value in meetings.updateSummary(value) }
            } else {
                summaryBody(session.summary ?? "")
            }
        }
        .confirmationDialog("Replace the summary you edited?",
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                editingSummary = false
                meetings.regenerateSummary()
            }
            Button("Keep mine", role: .cancel) {}
        } message: {
            Text("Your edited summary is replaced by a new local summary. Your notes are untouched.")
        }
    }

    @ViewBuilder
    private func summaryBody(_ text: String) -> some View {
        let blocks = MeetingSummaryMarkdown.blocks(text)
        if blocks.isEmpty {
            Text("No summary yet. It is written when the meeting ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(blocks) { block in
                    switch block {
                    case .heading(let heading):
                        Text(heading)
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 4)
                    case .bullet(let bullet):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(bullet).font(.callout)
                        }
                        .padding(.leading, 2)
                    case .paragraph(let paragraph):
                        Text(paragraph).font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcriptSection: some View {
        section("Transcript") {
            if meetings.pendingCount > 0 {
                Text("\(meetings.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } content: {
            LazyVStack(alignment: .leading, spacing: 12) {
                if meetings.transcript.isEmpty {
                    Text("No transcript yet. Me and Others appear here every few seconds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(meetings.transcript.sorted {
                    $0.offsetS == $1.offsetS ? $0.seq < $1.seq : $0.offsetS < $1.offsetS
                }) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Text(line.speaker == .me ? "Me" : "Others")
                            .font(.caption.bold())
                            .foregroundStyle(line.speaker == .me ? .blue : .secondary)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.text ?? (line.status == "pending" ? "Transcribing…" : "Audio retained; transcription failed."))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(timestamp(line.offsetS)) · \(line.status)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Accessory: View, Content: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Command-F focuses the search field while this screen is showing.
    private var searchShortcut: some View {
        Button("Search meetings") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Actions

    private func open(_ sessionID: String?) {
        guard selectedSessionID != sessionID else { return }
        meetings.flushEdits()
        editingSummary = false
        selectedSessionID = sessionID
        guard let sessionID, let session = meetings.sessions.first(where: { $0.id == sessionID }) else { return }
        Task { await meetings.load(session) }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = detailSession else { return }
        guard !trimmed.isEmpty else {
            titleDraft = session.title
            return
        }
        titleDraft = trimmed
        meetings.updateTitle(trimmed)
    }

    private func syncDrafts() {
        guard let session = detailSession else { return }
        titleDraft = session.title
        notesDraft = session.notes ?? ""
        summaryDraft = session.summary ?? ""
        editingSummary = false
    }

    // MARK: Labels

    private var statusLabel: String {
        switch meetings.state {
        case .idle: return meetings.currentSession.map { meetingStatusLabel($0.status) } ?? "Ready"
        case .starting: return "Preparing capture…"
        case .recording: return "Recording locally · \(meetings.pendingCount) pending"
        case .stopping: return "Flushing audio and waiting for transcription…"
        case .summarizing: return "Writing meeting summary…"
        case .error(let message): return message
        }
    }

    private var recordingStatusTitle: String {
        switch meetings.state {
        case .starting: return "Preparing local capture"
        case .recording: return "Recording meeting"
        case .stopping: return "Flushing audio"
        case .summarizing: return "Writing meeting notes"
        case .error: return "Meeting needs attention"
        case .idle:
            return meetings.currentSession?.status == "recording" ? "Recording fixture" : "Ready to record"
        }
    }

    private var recordingStatusDetail: String {
        switch meetings.state {
        case .starting: return "Starting microphone and system audio…"
        case .recording: return "Me and Others are captured locally."
        case .stopping: return "Saving every retained audio chunk…"
        case .summarizing: return "The local transcript is being summarized."
        case .error: return meetings.errorMessage ?? "Review the Meetings page for recovery actions."
        case .idle:
            return meetings.currentSession?.status == "recording"
                ? "Preview data only. No microphone or engine calls."
                : "Start from this page or the menu bar."
        }
    }

    private var recordingStatusColor: Color {
        switch meetings.state {
        case .error: return .orange
        case .starting, .recording: return .red
        case .stopping, .summarizing: return .blue
        case .idle: return meetings.currentSession?.status == "recording" ? .red : .secondary
        }
    }

    private func recordingElapsedLabel(at date: Date) -> String? {
        switch meetings.state {
        case .starting: return "starting"
        case .stopping, .summarizing: return "finishing"
        case .recording:
            guard let started = meetings.recordingStartedAt else { return nil }
            let seconds = max(0, Int(date.timeIntervalSince(started)))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        case .idle where model.previewMode && meetings.currentSession?.status == "recording":
            guard let started = meetings.currentSession.map({ Date(timeIntervalSince1970: $0.startedAt) }) else { return nil }
            let seconds = max(0, Int(date.timeIntervalSince(started)))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        default: return nil
        }
    }

    private func rowMeta(_ session: MeetingSession) -> String {
        "\(startedLabel(session)) · \(durationLabel(session))"
    }

    private func startedLabel(_ session: MeetingSession) -> String {
        Date(timeIntervalSince1970: session.startedAt)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func durationLabel(_ session: MeetingSession) -> String {
        guard let endedAt = session.endedAt else {
            return session.status == "recording" ? "recording" : "not finished"
        }
        let minutes = Int((endedAt - session.startedAt) / 60)
        if minutes < 1 { return "under a minute" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func summaryPreview(_ session: MeetingSession) -> String {
        for block in MeetingSummaryMarkdown.blocks(session.summary ?? "") {
            switch block {
            case .bullet(let text), .paragraph(let text): return text
            case .heading: continue
            }
        }
        return session.status == "recording" ? "Recording now" : "No summary yet"
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func meetingStatusLabel(_ status: String) -> String {
        switch status {
        case "needs_vault": return "Saved locally"
        case "summary_failed": return "Summary needs retry"
        case "recording": return "Recording"
        case "ended": return "Ended"
        default: return status.capitalized
        }
    }
}
