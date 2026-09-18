import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct EngineError: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct LearnedSuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let produced: String
    let replacement: String
    let rowID: Int?
    let appBundleID: String?
    let createdAt: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, produced, replacement, rowID = "row_id", appBundleID = "app_bundle_id"
        case createdAt = "created_at", reason
    }
}

struct HistoryRow: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    var rowID: Int?
    var ts: Double?
    var appBundleID: String?
    var rawText: String?
    var cleanText: String?
    var editedText: String?
    var sttMS: Double?
    var llmMS: Double?
    var insertMS: Double?
    var totalMS: Double?
    var insertMode: String?
    var audioSeconds: Double?
    var guardFired: Bool?
    var model: String?
    var audioPath: String?
    var kind: String?
    var instructionText: String?
    var preferredText: String? {
        [cleanText, rawText].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    enum CodingKeys: String, CodingKey {
        case id, rowID = "row_id", ts
        case appBundleID = "app_bundle_id", rawText = "raw_text", cleanText = "clean_text"
        case editedText = "edited_text", sttMS = "stt_ms", llmMS = "llm_ms", insertMS = "insert_ms"
        case totalMS = "total_ms", insertMode = "insert_mode", audioSeconds = "audio_seconds"
        case guardFired = "guard_fired", model, audioPath = "audio_path", kind, instructionText = "instruction_text"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? c.decode(Int.self, forKey: .rowID)
        rowID = try c.decodeIfPresent(Int.self, forKey: .rowID)
        ts = try c.decodeIfPresent(Double.self, forKey: .ts)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText); cleanText = try c.decodeIfPresent(String.self, forKey: .cleanText)
        editedText = try c.decodeIfPresent(String.self, forKey: .editedText)
        sttMS = try c.decodeIfPresent(Double.self, forKey: .sttMS); llmMS = try c.decodeIfPresent(Double.self, forKey: .llmMS)
        insertMS = try c.decodeIfPresent(Double.self, forKey: .insertMS); totalMS = try c.decodeIfPresent(Double.self, forKey: .totalMS)
        insertMode = try c.decodeIfPresent(String.self, forKey: .insertMode); audioSeconds = try c.decodeIfPresent(Double.self, forKey: .audioSeconds)
        guardFired = try Self.decodeBoolOrInteger(c, forKey: .guardFired); model = try c.decodeIfPresent(String.self, forKey: .model)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        instructionText = try c.decodeIfPresent(String.self, forKey: .instructionText)
    }

    private static func decodeBoolOrInteger(
        _ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Bool? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        let value = try container.decode(Int.self, forKey: key)
        guard value == 0 || value == 1 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                   debugDescription: "Expected a boolean or 0/1 integer")
        }
        return value == 1
    }
}

struct MeetingChunkRecord: Codable, Identifiable, Equatable, Sendable {
    let seq: Int
    let offsetS: Double
    let durationS: Double
    let speaker: MeetingSpeaker
    let status: String
    let text: String?
    let sttMS: Double?
    let errorCode: String?
    let retainedPath: String?
    let sourcePath: String?
    let voiceActivity: Bool?

    var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case seq, offsetS = "offset_s", durationS = "duration_s", speaker, status, text
        case sttMS = "stt_ms", errorCode = "error_code", retainedPath = "retained_path"
        case sourcePath = "source_path", voiceActivity = "voice_activity"
    }

    init(seq: Int, offsetS: Double, durationS: Double, speaker: MeetingSpeaker,
         status: String, text: String?, sttMS: Double?, errorCode: String?,
         retainedPath: String?, sourcePath: String? = nil, voiceActivity: Bool? = nil) {
        self.seq = seq
        self.offsetS = offsetS
        self.durationS = durationS
        self.speaker = speaker
        self.status = status
        self.text = text
        self.sttMS = sttMS
        self.errorCode = errorCode
        self.retainedPath = retainedPath
        self.sourcePath = sourcePath
        self.voiceActivity = voiceActivity
    }
}

struct MeetingSession: Codable, Identifiable, Equatable, Sendable {
    let sessionID: String
    var title: String
    let startedAt: Double
    let endedAt: Double?
    let status: String
    var summary: String?
    let notePath: String?
    let transcriptPath: String?
    let chunkCount: Int
    let chunks: [MeetingChunkRecord]?
    /// Fields an older engine does not send. Each one decodes as absent.
    var notes: String?
    var titleSource: String?
    var summaryEdited: Bool?
    var updatedAt: Double?
    var searchText: String?

    var id: String { sessionID }

    init(sessionID: String, title: String, startedAt: Double, endedAt: Double? = nil,
         status: String, summary: String? = nil, notePath: String? = nil,
         transcriptPath: String? = nil, chunkCount: Int = 0, chunks: [MeetingChunkRecord]? = nil,
         notes: String? = nil, titleSource: String? = nil, summaryEdited: Bool? = nil,
         updatedAt: Double? = nil, searchText: String? = nil) {
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.summary = summary
        self.notePath = notePath
        self.transcriptPath = transcriptPath
        self.chunkCount = chunkCount
        self.chunks = chunks
        self.notes = notes
        self.titleSource = titleSource
        self.summaryEdited = summaryEdited
        self.updatedAt = updatedAt
        self.searchText = searchText
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", title, startedAt = "started_at", endedAt = "ended_at"
        case status, summary, notePath = "note_path", transcriptPath = "transcript_path"
        case chunkCount = "chunk_count", chunks, notes, titleSource = "title_source"
        case summaryEdited = "summary_edited", updatedAt = "updated_at", searchText = "search_text"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        endedAt = try c.decodeIfPresent(Double.self, forKey: .endedAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        notePath = try c.decodeIfPresent(String.self, forKey: .notePath)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        chunkCount = try c.decodeIfPresent(Int.self, forKey: .chunkCount) ?? 0
        chunks = try c.decodeIfPresent([MeetingChunkRecord].self, forKey: .chunks)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        titleSource = try c.decodeIfPresent(String.self, forKey: .titleSource)
        summaryEdited = try Self.decodeBoolOrInteger(c, forKey: .summaryEdited)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText)
    }

    /// SQLite stores the edited flag as 0 or 1; a newer engine sends a boolean.
    private static func decodeBoolOrInteger(
        _ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Bool? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        return try container.decode(Int.self, forKey: key) != 0
    }
}

struct EngineResponse: Codable, Equatable, Sendable {
    let id: Int
    let raw: String?
    let clean: String?
    let cleanText: String?
    let rewrite: String?
    let sttMS: Double?
    let llmMS: Double?
    let model: String?
    let whisper: String?
    let cleanup: String?
    let errorMessage: String?
    let guardFired: Bool?
    let rowID: Int?
    let row: HistoryRow?
    let rows: [HistoryRow]?
    let terms: [String]?
    let replacements: [String: String]?
    let config: [String: JSONValue]?
    let suggestions: [LearnedSuggestion]?
    let suggestion: LearnedSuggestion?
    let session: MeetingSession?
    let sessions: [MeetingSession]?
    let sessionID: String?
    let title: String?
    let startedAt: Double?
    let endedAt: Double?
    let summary: String?
    let notePath: String?
    let transcriptPath: String?
    let chunkCount: Int?
    let chunks: [MeetingChunkRecord]?
    let status: String?
    let text: String?
    let errorCode: String?
    let nextOffset: Int?
    let error: EngineError?
    let noSpeech: Bool?
    let reason: String?
    let chunk: String?
    let seq: Int?
    let done: Bool?
    let chunksSent: Int?
    let streamTruncated: Bool?
    let streamInterrupted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, raw, clean, cleanText = "clean_text", rewrite, sttMS = "stt_ms", llmMS = "llm_ms", model, whisper, cleanup
        case errorMessage = "error_message"
        case guardFired = "guard_fired", rowID = "row_id", row, rows, terms, replacements, config, suggestions, suggestion
        case session, sessions, sessionID = "session_id", title, startedAt = "started_at", endedAt = "ended_at"
        case summary, notePath = "note_path", transcriptPath = "transcript_path", chunkCount = "chunk_count", chunks
        case status, text, errorCode = "error_code", nextOffset = "next_offset", error
        case noSpeech = "no_speech", reason
        case chunk, seq, done, chunksSent = "chunks_sent"
        case streamTruncated = "stream_truncated", streamInterrupted = "stream_interrupted"
    }
}

struct AppContext: Codable, Equatable {
    var before: String = ""
    var after: String = ""
    var selected: String = ""
}

/// Every state the edge dock can settle into. Hover is deliberately absent:
/// it belongs to the view, not the model. `schedulePillReset` compares these
/// values, so each case stays cheap to compare.
enum PillState: Equatable, Sendable {
    case idle
    case listening(level: Double)
    case working
    case inserted(totalMS: Double)
    case guarded(totalMS: Double)
    case error(String)
    /// Meeting capture is running, with the seconds since it started.
    case recording(elapsed: TimeInterval)
    /// A call app took the microphone and the nudge card is offering capture.
    case meetingDetected(DetectedMeeting)
    /// A short receipt: "Saved" after a Quick note, "Meeting ended" after
    /// auto-stop. One case rather than one per message.
    case notice(String)
}
