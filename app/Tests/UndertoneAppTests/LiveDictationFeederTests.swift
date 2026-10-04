import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import UndertoneApp

private final class LiveChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A stand-in engine on a Unix socket that answers the live dictation ops,
/// one request per connection the way the real server is used, and records
/// what it was sent.
private final class FakeLiveEngine: @unchecked Sendable {
    let path: String
    private let server: Int32
    private let lock = NSLock()
    private var opsSeen: [String] = []
    private var seqsSeen: [Int] = []
    private var samples = 0
    private var finishPath: String?
    private var sessions = 0

    init() throws {
        path = "/tmp/undertone-live-\(UUID().uuidString).sock"
        server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw EngineClientError.system("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(server, 16) == 0 else { throw EngineClientError.system("bind") }
        DispatchQueue.global().async { [self] in self.serve() }
    }

    func close() {
        shutdown(server, SHUT_RDWR)
        Darwin.close(server)
        unlink(path)
    }

    var ops: [String] { lock.lock(); defer { lock.unlock() }; return opsSeen }
    var seqs: [Int] { lock.lock(); defer { lock.unlock() }; return seqsSeen }
    var samplesReceived: Int { lock.lock(); defer { lock.unlock() }; return samples }
    var finishAudioPath: String? { lock.lock(); defer { lock.unlock() }; return finishPath }

    private func serve() {
        while true {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async { [self] in self.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        var request = Data()
        var byte: UInt8 = 0
        while Darwin.read(client, &byte, 1) == 1 {
            if byte == 10 { break }
            request.append(byte)
        }
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let op = object["op"] as? String else { return }
        let id = object["id"] as? Int ?? 0
        lock.lock()
        opsSeen.append(op)
        var lines: [String]
        switch op {
        case "dictation.start":
            sessions += 1
            lines = ["{\"id\":\(id),\"session_id\":\"live-\(sessions)\",\"backend\":\"fake\",\"model\":\"fake\",\"level\":\"medium\"}"]
        case "dictation.audio":
            let seq = object["seq"] as? Int ?? -1
            seqsSeen.append(seq)
            if let pcm = object["pcm16"] as? String, let data = Data(base64Encoded: pcm) { samples += data.count / 2 }
            lines = ["{\"id\":\(id),\"seq\":\(seq),\"received_seconds\":0,\"committed_seconds\":0,\"units\":0,\"units_cleaned\":0}"]
        case "dictation.finish":
            finishPath = object["audio_path"] as? String
            lines = [
                "{\"id\":\(id),\"seq\":0,\"chunk\":\"Hello world. \"}",
                "{\"id\":\(id),\"done\":true,\"raw\":\"hello world and more\",\"clean\":\"Hello world. And more.\","
                    + "\"chunks_sent\":1,\"guard_fired\":false,\"llm_ms\":5,\"stt_ms\":3,\"no_speech\":false,"
                    + "\"live_units\":2,\"live_fallback\":null,\"live_release_ms\":40}",
            ]
        case "dictation.cancel":
            lines = ["{\"id\":\(id),\"cancelled\":true}"]
        default:
            lines = ["{\"id\":\(id),\"error\":{\"code\":\"bad_request\",\"message\":\"unknown op\"}}"]
        }
        lock.unlock()
        var payload = Data()
        for line in lines {
            payload.append(contentsOf: line.utf8)
            payload.append(10)
        }
        payload.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress { _ = Darwin.write(client, base, buffer.count) }
        }
    }
}

final class LiveDictationFeederTests: XCTestCase {
    func testStreamingResamplerMatchesTheWholeSignalResample() {
        for fromRate in [48_000.0, 44_100.0] {
            let toRate = LiveDictationFeeder.sampleRate
            let total = Int(fromRate)
            let signal = (0..<total).map { Float(sin(Double($0) * 2 * .pi * 440 / fromRate)) }
            let whole = MeetingAudioMath.resample(signal, fromRate: fromRate, toRate: toRate)
            var resampler = StreamingResampler(fromRate: fromRate, toRate: toRate)
            var streamed: [Float] = []
            var start = 0
            while start < total {
                let end = min(total, start + 1024)
                streamed.append(contentsOf: resampler.process(Array(signal[start..<end])))
                start = end
            }
            XCTAssertLessThanOrEqual(abs(streamed.count - whole.count), 1, "count at \(fromRate)")
            var largest: Float = 0
            for index in 0..<min(streamed.count, whole.count) {
                largest = max(largest, abs(streamed[index] - whole[index]))
            }
            XCTAssertLessThan(largest, 0.002, "drift at \(fromRate)")
        }
    }

    func testStreamingResamplerPassesTheEngineRateThrough() {
        var resampler = StreamingResampler(fromRate: 16_000, toRate: 16_000)
        XCTAssertTrue(resampler.isIdentity)
        XCTAssertEqual(resampler.process([0.1, 0.2, 0.3]), [0.1, 0.2, 0.3])
        XCTAssertEqual(resampler.process([]), [])
    }

    func testFrameAssemblerEmitsFixedFramesAndFlushesTheRest() {
        var assembler = LiveFrameAssembler(frameSamples: 4)
        XCTAssertEqual(assembler.append([1, 2, 3]), [])
        XCTAssertEqual(assembler.append([4, 5, 6, 7, 8, 9]), [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(assembler.flush(), [9])
        XCTAssertNil(assembler.flush())
    }

    func testPCM16Base64IsLittleEndianAndClamped() throws {
        let encoded = LivePCM16.base64([0, 1, -1, 0.5, 2, -2])
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let values: [Int16] = stride(from: 0, to: data.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
        }
        XCTAssertEqual(values, [0, 32767, -32767, 16384, 32767, -32767])
    }

    func testMonoMixdownAveragesChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<4 {
            channels[0][index] = Float(index)
            channels[1][index] = Float(index) + 1
        }
        XCTAssertEqual(AudioRecorder.mono(buffer), [0.5, 1.5, 2.5, 3.5])
    }

    func testFeederSendsFramesInOrderAndFinishesWithTheCommittedChunkFirst() async throws {
        let fake = try FakeLiveEngine()
        defer { fake.close() }
        let feeder = LiveDictationFeeder(engine: EngineClient(path: fake.path))
        let frame = [Float](repeating: 0.25, count: LiveDictationFeeder.frameSamples)
        // Audio can arrive before the session is open; it must wait its turn.
        feeder.push(frame)
        await feeder.begin(fields: ["level": .string("medium")])
        for _ in 0..<3 { feeder.push(frame) }
        let collector = LiveChunkCollector()
        let response = try await feeder.finish(audioPath: URL(fileURLWithPath: "/tmp/undertone-live-test.wav")) { chunk in
            collector.append(chunk)
        }
        XCTAssertEqual(collector.values, ["Hello world. "])
        XCTAssertEqual(response.done, true)
        XCTAssertEqual(response.clean, "Hello world. And more.")
        XCTAssertEqual(response.chunksSent, 1)
        XCTAssertEqual(response.liveUnits, 2)
        XCTAssertNil(response.liveFallback)
        XCTAssertEqual(response.liveReleaseMS, 40)
        XCTAssertEqual(fake.seqs, [0, 1, 2, 3])
        XCTAssertEqual(fake.samplesReceived, 4 * LiveDictationFeeder.frameSamples)
        XCTAssertEqual(fake.ops.first, "dictation.start")
        XCTAssertEqual(fake.ops.last, "dictation.finish")
        XCTAssertEqual(fake.finishAudioPath, "/tmp/undertone-live-test.wav")
        let sent = await feeder.framesSent
        XCTAssertEqual(sent, 4)
    }

    func testFeederCancelTellsTheEngineAndSendsNothingMore() async throws {
        let fake = try FakeLiveEngine()
        defer { fake.close() }
        let feeder = LiveDictationFeeder(engine: EngineClient(path: fake.path))
        await feeder.begin(fields: [:])
        feeder.push([0.1, 0.2])
        await feeder.cancel()
        feeder.push([0.3])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.ops.first, "dictation.start")
        XCTAssertEqual(fake.ops.last, "dictation.cancel")
        XCTAssertLessThanOrEqual(fake.seqs.count, 1)
    }

    func testFeederFinishThrowsWhenTheSessionNeverOpened() async {
        let missing = "/tmp/undertone-live-missing-\(UUID().uuidString).sock"
        let feeder = LiveDictationFeeder(engine: EngineClient(path: missing))
        await feeder.begin(fields: [:])
        feeder.push([0, 0, 0])
        do {
            _ = try await feeder.finish(audioPath: URL(fileURLWithPath: "/tmp/x.wav")) { _ in }
            XCTFail("finish must throw when dictation.start failed")
        } catch {
            XCTAssertNotNil(error as? EngineClientError)
        }
    }

    func testEngineResponseDecodesLiveFields() throws {
        let data = try XCTUnwrap(#"{"id":2,"done":true,"clean":"Hi.","live_units":3,"live_fallback":"seq_gap","live_release_ms":123.5}"#.data(using: .utf8))
        let response = try JSONDecoder().decode(EngineResponse.self, from: data)
        XCTAssertEqual(response.liveUnits, 3)
        XCTAssertEqual(response.liveFallback, "seq_gap")
        XCTAssertEqual(response.liveReleaseMS, 123.5)
        let older = try XCTUnwrap(#"{"id":3,"clean":"Hi."}"#.data(using: .utf8))
        let legacy = try JSONDecoder().decode(EngineResponse.self, from: older)
        XCTAssertNil(legacy.liveUnits)
        XCTAssertNil(legacy.liveFallback)
    }
}
