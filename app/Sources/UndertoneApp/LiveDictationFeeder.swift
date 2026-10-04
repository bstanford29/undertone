import Foundation
import os

/// Linear resampler that keeps its place between calls, so audio handed over
/// one tap buffer at a time comes out as a single continuous stream at the
/// engine's rate. `MeetingAudioMath.resample` restarts at every buffer, which
/// is fine for meeting chunks written to files but drifts by a fraction of a
/// sample per call when the pieces are joined back together.
struct StreamingResampler {
    let fromRate: Double
    let toRate: Double
    /// The last input sample of the previous call, for interpolation across
    /// the buffer boundary.
    private var carry: Float?
    /// Where the next output sample sits, in source samples measured from the
    /// first sample of the next input; -1 is `carry`.
    private var position: Double = 0

    init(fromRate: Double, toRate: Double) {
        self.fromRate = fromRate
        self.toRate = toRate
    }

    var isIdentity: Bool { abs(fromRate - toRate) <= 0.5 }

    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty, fromRate > 0, toRate > 0 else { return [] }
        if isIdentity { return input }
        let step = fromRate / toRate
        let count = input.count
        let previous = carry
        var output: [Float] = []
        output.reserveCapacity(Int(Double(count) / step) + 2)
        var cursor = position
        while cursor <= Double(count - 1) {
            let lower = Int(cursor.rounded(.down))
            let fraction = Float(cursor - Double(lower))
            let upper = min(count - 1, lower + 1)
            let a = lower < 0 ? (previous ?? input[0]) : input[lower]
            let b = input[upper]
            output.append(a + (b - a) * fraction)
            cursor += step
        }
        position = cursor - Double(count)
        carry = input[count - 1]
        return output
    }
}

/// Collects samples at the engine rate and hands them over in frames of one
/// fixed size, so the socket sees a steady half second of audio at a time.
struct LiveFrameAssembler {
    let frameSamples: Int
    private var pending: [Float] = []

    init(frameSamples: Int) {
        self.frameSamples = max(1, frameSamples)
    }

    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        while pending.count >= frameSamples {
            frames.append(Array(pending[0..<frameSamples]))
            pending.removeFirst(frameSamples)
        }
        return frames
    }

    /// Whatever is left after the last full frame, or nil when nothing is.
    mutating func flush() -> [Float]? {
        guard !pending.isEmpty else { return nil }
        let rest = pending
        pending.removeAll()
        return rest
    }
}

enum LivePCM16 {
    /// Little-endian signed 16-bit samples, clamped, as base64 for the socket.
    static func base64(_ samples: [Float]) -> String {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}

/// Frames waiting for the socket. The audio thread appends; the feeder actor
/// pops. A plain lock keeps the audio callback free of actor hops.
final class LiveFrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[Float]] = []

    func append(_ frame: [Float]) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func popFirst() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    func removeAll() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }
}

/// Streams the recording to the engine while the key is held and finishes the
/// session at release. Audio arrives from the audio thread through `push`,
/// which only queues; the actor drains the queue one frame at a time so the
/// sequence numbers reach the engine in order. Any failure is remembered and
/// surfaces from `finish`, where the caller falls back to the one-shot path.
actor LiveDictationFeeder {
    static let sampleRate = 16_000.0
    /// Half a second at the engine rate.
    static let frameSamples = 8_000
    nonisolated private static let log = Logger(subsystem: "com.undertone.app", category: "live")

    private let engine: EngineClient
    private let queue = LiveFrameQueue()
    private var sessionID: String?
    private var startTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var draining = false
    private var finished = false
    private var failure: Error?
    private var nextSeq = 0
    private(set) var framesSent = 0

    init(engine: EngineClient) {
        self.engine = engine
    }

    /// Opens the engine session. Frames pushed before it opens wait in order.
    func begin(fields: [String: JSONValue]) {
        guard startTask == nil, !finished else { return }
        startTask = Task { await self.open(fields: fields) }
    }

    private func open(fields: [String: JSONValue]) async {
        do {
            let response = try await engine.request(op: "dictation.start", fields: fields)
            guard let id = response.sessionID, !id.isEmpty else {
                throw EngineClientError.protocolViolation("dictation.start did not return session_id")
            }
            sessionID = id
            drainIfNeeded()
        } catch {
            Self.log.notice("live dictation did not start: \(error.localizedDescription, privacy: .public)")
            failure = error
            queue.removeAll()
        }
    }

    /// Called from the audio thread with one frame; queues and returns at once.
    nonisolated func push(_ samples: [Float]) {
        queue.append(samples)
        Task { await self.drainIfNeeded() }
    }

    private func drainIfNeeded() {
        guard !draining, !finished, failure == nil, sessionID != nil else { return }
        draining = true
        drainTask = Task { await self.drain() }
    }

    private func drain() async {
        await sendQueued()
        draining = false
    }

    private func sendQueued() async {
        guard let sessionID else { return }
        while failure == nil, let frame = queue.popFirst() {
            let seq = nextSeq
            nextSeq += 1
            do {
                _ = try await engine.request(op: "dictation.audio", fields: [
                    "session_id": .string(sessionID),
                    "seq": .number(Double(seq)),
                    "pcm16": .string(LivePCM16.base64(frame)),
                ])
                framesSent += 1
            } catch {
                Self.log.error("live audio frame \(seq) failed: \(error.localizedDescription, privacy: .public)")
                failure = error
                queue.removeAll()
            }
        }
    }

    /// Sends what is still queued, then finishes the session. `onChunk`
    /// receives the committed clean text before the final response arrives.
    func finish(audioPath: URL, onChunk: @Sendable (String) async -> Void) async throws -> EngineResponse {
        await startTask?.value
        finished = true
        while draining { await drainTask?.value }
        await sendQueued()
        if let failure { throw failure }
        guard let sessionID else { throw EngineClientError.system("live dictation did not start") }
        return try await engine.requestStream(op: "dictation.finish", fields: [
            "session_id": .string(sessionID),
            "audio_path": .string(audioPath.path),
        ], onChunk: onChunk)
    }

    /// Drops the session. The engine forgets it; retained audio stays with the app.
    func cancel() async {
        finished = true
        queue.removeAll()
        await startTask?.value
        while draining { await drainTask?.value }
        guard let sessionID else { return }
        _ = try? await engine.request(op: "dictation.cancel", fields: ["session_id": .string(sessionID)])
    }
}
