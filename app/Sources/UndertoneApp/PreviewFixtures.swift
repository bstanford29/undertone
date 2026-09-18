import Foundation

enum PreviewFixtures {
    private static let now = Date().timeIntervalSince1970

    static let rows: [HistoryRow] = [
        HistoryRow(
            id: 312, ts: now - 4 * 60, appBundleID: "com.openai.codex",
            rawText: "Um so hey can you uh send me the the report by Tuesday no wait Wednesday",
            cleanText: "Hey, can you send me the report by Wednesday?",
            editedText: nil, sttMS: 174, llmMS: 783, insertMS: 30, totalMS: 957,
            insertMode: "ax", audioSeconds: 15, guardFired: false, model: "qwen3.5 · medium", audioPath: nil
        ),
        HistoryRow(
            id: 311, ts: now - 2 * 60 * 60, appBundleID: "com.anthropic.claudefordesktop",
            rawText: "One of the best features I love about this thing is that it doesn't take over my clipboard",
            cleanText: "One of the best features I love about this thing is that it doesn't take over my clipboard.",
            editedText: nil, sttMS: 120, llmMS: 480, insertMS: 40, totalMS: 640,
            insertMode: "type", audioSeconds: 9, guardFired: false, model: "qwen3.5 · medium", audioPath: nil
        ),
        HistoryRow(
            id: 310, ts: now - 5 * 60 * 60, appBundleID: "com.openai.codex",
            rawText: "Okay can you tell me what you fixed because I just see a lot here right now",
            cleanText: "Okay, can you tell me what you fixed, because I just see a lot here right now?",
            editedText: nil, sttMS: 100, llmMS: 210, insertMS: 39, totalMS: 349,
            insertMode: "ax", audioSeconds: 4, guardFired: false, model: "qwen3.5 · medium", audioPath: nil
        ),
        HistoryRow(
            id: 309, ts: now - 1 * 86_400, appBundleID: "com.mitchellh.ghostty",
            rawText: "git commit dash m tidy the release notes",
            cleanText: "git commit -m tidy the release notes",
            editedText: nil, sttMS: 0, llmMS: 0, insertMS: 0, totalMS: 0,
            insertMode: "skipped", audioSeconds: 3, guardFired: true, model: nil, audioPath: nil
        ),
        HistoryRow(
            id: 308, ts: now - 2 * 86_400, appBundleID: "com.apple.MobileSMS",
            rawText: "Tell Jordan the pickup is at three not four",
            cleanText: "Tell Jordan the pickup is at three, not four.",
            editedText: nil, sttMS: 100, llmMS: 270, insertMS: 40, totalMS: 410,
            insertMode: "ax", audioSeconds: 3, guardFired: false, model: "qwen3.5 · medium", audioPath: nil
        ),
    ]

    static let terms = ["Northwind", "Obsidian", "Ollama", "Whisper"]
    static let commandSelection = "The original paragraph selected in Mail stays available while Command Mode rewrites it."
    static let commandInstruction = "Make this shorter"
    static let commandRewrite = "Command Mode keeps the selected meaning while shortening it."
    static let replacements = [
        "btw": "by the way",
        "gh": "GitHub",
        "otw": "on the way",
        "my work email": "avery@…",
        "sign off": "Thanks, Avery",
    ]

    static let suggestions = [
        LearnedSuggestion(id: 1, produced: "Quinn", replacement: "Qwen", rowID: 312,
                          appBundleID: "com.openai.codex", createdAt: now - 90, reason: "capitalized")
    ]

    static let meetingTranscript = [
        MeetingChunkRecord(seq: 0, offsetS: 0, durationS: 10, speaker: .others,
                           status: "complete", text: "We can make the changes at the end once the latest version is confirmed.",
                           sttMS: 172, errorCode: nil, retainedPath: nil),
        MeetingChunkRecord(seq: 1, offsetS: 10, durationS: 10, speaker: .me,
                           status: "complete", text: "Agreed. Let us send the v4 before the next call.",
                           sttMS: 166, errorCode: nil, retainedPath: nil),
        MeetingChunkRecord(seq: 2, offsetS: 20, durationS: 10, speaker: .others,
                           status: "pending", text: nil, sttMS: nil, errorCode: nil, retainedPath: nil),
    ]

    static let meetingSummary = """
    ## Key points
    - The v4 sprint plan is confirmed and replaces the v3 diagram.
    - Northwind needs the roadmap before the next review.
    - Two fields in the intake form are still unnamed.

    ## Decisions
    - Send v4 before the next call instead of waiting for sign off.
    - Keep the old diagram available for one more week.

    ## Action items
    - Avery sends v4 to Priya on Tuesday.
    - Priya confirms the roadmap.
    """

    static let meetingNotes = """
    Ask about the onboarding checklist. My own wording stays exactly as typed.
    Follow up with Priya on Tuesday.
    """

    static let meetingSessions = [
        MeetingSession(sessionID: "preview-quarterly", title: "Quarterly planning",
                       startedAt: now - 3 * 86_400, endedAt: now - 3 * 86_400 + 2_400,
                       status: "ended", summary: meetingSummary,
                       notePath: "~/Documents/Obsidian/Meetings/2026-09-12 Quarterly planning.md",
                       chunkCount: 8, chunks: meetingTranscript,
                       notes: meetingNotes, titleSource: "auto", summaryEdited: false,
                       updatedAt: now - 3 * 86_400 + 2_500,
                       searchText: (["quarterly planning", meetingSummary, meetingNotes]
                                    .joined(separator: " ")).lowercased()),
        MeetingSession(sessionID: "preview-sprint-plan", title: "Sprint plan review",
                       startedAt: now - 12 * 60, status: "recording", chunkCount: meetingTranscript.count,
                       chunks: meetingTranscript,
                       notes: "Live notes go here while the meeting runs.",
                       titleSource: "user", summaryEdited: false, updatedAt: now - 60,
                       searchText: "sprint plan review live notes go here while the meeting runs."),
        MeetingSession(sessionID: "preview-northwind-intake", title: "Northwind onboarding walkthrough",
                       startedAt: now - 6 * 86_400, endedAt: now - 6 * 86_400 + 1_500,
                       status: "ended",
                       summary: """
                       ## Key points
                       - The intake queue is two weeks behind.

                       ## Decisions
                       - None noted.

                       ## Action items
                       - Jordan drafts the new intake checklist.
                       """,
                       chunkCount: 5, notes: "", titleSource: "auto", summaryEdited: false,
                       updatedAt: now - 6 * 86_400 + 1_600,
                       searchText: "northwind onboarding walkthrough the intake queue is two weeks behind jordan drafts the new intake checklist"),
        MeetingSession(sessionID: "preview-vendor-renewal", title: "Vendor renewal review",
                       startedAt: now - 11 * 86_400, endedAt: now - 11 * 86_400 + 900,
                       status: "needs_vault",
                       summary: """
                       ## Key points
                       - The vendor portal needs a new login.

                       ## Decisions
                       - Renew the license this month.

                       ## Action items
                       - None noted.
                       """,
                       chunkCount: 3, notes: "The old login is retired. Ask the vendor.",
                       titleSource: "user", summaryEdited: true, updatedAt: now - 11 * 86_400 + 1_000,
                       searchText: "vendor renewal review the vendor portal needs a new login renew the license this month the old login is retired ask the vendor"),
    ]

    static let config: [String: JSONValue] = [
        "cleanup_level": .string("medium"),
        "sounds": .bool(true),
        "stream_insert": .bool(true),
        "whisper_mode": .bool(false),
    ]

    /// Preview screenshots always show the slower-on-battery warning so the
    /// light and dark captures are repeatable whether the Mac is plugged in.
    static let slowerOnBattery = true

    /// Zoom holds the microphone, so the dock can show the nudge card.
    static let detectedMeeting = detectedZoom

    /// The fixtures carry what the detector would have filled in: the
    /// platform it settled on, the mic owner signal, and the pid it tracks.
    static let detectedZoom = DetectedMeeting(
        appName: "Zoom", suggestedTitle: "Sprint plan review", bundleID: "us.zoom.xos",
        platform: .zoom, source: .micOwner, pid: 4821
    )

    static let detectedTeams = DetectedMeeting(
        appName: "Microsoft Teams", suggestedTitle: "Northwind intake sync", bundleID: "com.microsoft.teams2",
        platform: .teams, source: .micOwner, pid: 4822
    )

    /// A browser call: Chrome holds the mic and a Meet tab is open.
    static let detectedMeetInChrome = DetectedMeeting(
        appName: "Chrome", suggestedTitle: "Meet - abc-defg-hij", bundleID: "com.google.Chrome",
        platform: .meet, source: .micOwner, pid: 4823, browserName: "Chrome"
    )

    static let detectedFaceTime = DetectedMeeting(
        appName: "FaceTime", suggestedTitle: "FaceTime call", bundleID: "com.apple.FaceTime",
        platform: .facetime, source: .micOwner, pid: 4824
    )

    static func detectedMeeting(named name: String) -> DetectedMeeting {
        switch name {
        case "teams": return detectedTeams
        case "meet", "chrome": return detectedMeetInChrome
        case "facetime": return detectedFaceTime
        default: return detectedZoom
        }
    }

    /// 12 minutes and 4 seconds, the timer reading in the mockup.
    static let recordingElapsed: TimeInterval = 12 * 60 + 4
}

extension HistoryRow {
    init(
        id: Int, ts: Double, appBundleID: String?, rawText: String?, cleanText: String?,
        editedText: String?, sttMS: Double?, llmMS: Double?, insertMS: Double?, totalMS: Double?,
        insertMode: String?, audioSeconds: Double?, guardFired: Bool?, model: String?, audioPath: String?
    ) {
        self.id = id
        self.rowID = id
        self.ts = ts
        self.appBundleID = appBundleID
        self.rawText = rawText
        self.cleanText = cleanText
        self.editedText = editedText
        self.sttMS = sttMS
        self.llmMS = llmMS
        self.insertMS = insertMS
        self.totalMS = totalMS
        self.insertMode = insertMode
        self.audioSeconds = audioSeconds
        self.guardFired = guardFired
        self.model = model
        self.audioPath = audioPath
        self.kind = nil
        self.instructionText = nil
    }
}
