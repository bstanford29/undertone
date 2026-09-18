import XCTest
@testable import UndertoneApp

final class MeetingRecorderTests: XCTestCase {
    func testVADDistinguishesSilenceAndVoice() {
        XCTAssertFalse(MeetingAudioMath.isVoiceActivity([Float](repeating: 0, count: 100)))
        XCTAssertTrue(MeetingAudioMath.isVoiceActivity([0.2, -0.2, 0.1, -0.1]))
    }

    func testLevelMetricUsesOnlyCapturedSamples() {
        let values = MeetingAudioMath.metrics([0.5, -0.5, 0.5, -0.5])
        XCTAssertEqual(values.rms, 0.5, accuracy: 0.0001)
        XCTAssertEqual(values.peak, 0.5, accuracy: 0.0001)
        XCTAssertEqual(MeetingAudioMath.metrics([]).rms, 0)
        XCTAssertEqual(MeetingAudioMath.metrics([]).peak, 0)
    }

    func testConcurrentStopCallsShareSafeIdleTeardown() async {
        let recorder = MeetingRecorder(outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        async let first = recorder.stop()
        async let second = recorder.stop()
        let (firstChunks, secondChunks) = await (first, second)
        XCTAssertEqual(firstChunks, [])
        XCTAssertEqual(secondChunks, [])
    }

    func testMonoDownmixPreservesFrameCount() {
        XCTAssertEqual(MeetingAudioMath.mono([1, -1, 0.5, 0.5], channels: 2), [0, 0.5])
        XCTAssertEqual(MeetingAudioMath.mono([1, 2], channels: 1), [1, 2])
    }

    func testResampleAdjustsFrameCountAndKeepsEndpoints() {
        let converted = MeetingAudioMath.resample([0, 1, 0], fromRate: 3, toRate: 6)
        XCTAssertEqual(converted.count, 6)
        XCTAssertEqual(converted.first, 0)
        XCTAssertEqual(converted.last, 0)
    }

    func testChunkBoundariesIncludeFinalFlush() {
        XCTAssertEqual(MeetingAudioMath.boundaries(totalFrames: 25, sampleRate: 10, chunkSeconds: 2), [
            MeetingChunkBoundary(offset: 0, duration: 2),
            MeetingChunkBoundary(offset: 2, duration: 0.5),
        ])
        XCTAssertEqual(MeetingAudioMath.boundaries(totalFrames: 0, sampleRate: 10, chunkSeconds: 2), [])
    }

    func testChunkEncodingMatchesMeetingEngineFields() throws {
        let chunk = MeetingChunk(sequence: 3, speaker: .others,
                                 path: URL(fileURLWithPath: "/tmp/chunk.wav"),
                                 offset: 20, duration: 10)
        let data = try JSONEncoder().encode(chunk)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["seq"] as? Int, 3)
        XCTAssertEqual(object["speaker"] as? String, "others")
        XCTAssertEqual(object["audio_path"] as? String, "/tmp/chunk.wav")
        XCTAssertEqual(object["offset_s"] as? Int, 20)
        XCTAssertEqual(object["duration_s"] as? Int, 10)
        XCTAssertEqual(object["voice_activity"] as? Bool, true)
        XCTAssertNil(object["sequence"])
        XCTAssertNil(object["path"])
    }

    func testPendingManifestRoundTripsRetainedChunk() throws {
        let chunk = MeetingChunk(sequence: 4, speaker: .me,
                                 path: URL(fileURLWithPath: "/tmp/meeting-4.wav"),
                                 offset: 40, duration: 10, voiceActivity: false)
        let manifest = MeetingPendingManifest(sessionID: "session_1234", title: "Planning",
                                              startedAt: 1_725_000_000, chunks: [chunk])
        let data = try JSONEncoder().encode(manifest)
        let restored = try JSONDecoder().decode(MeetingPendingManifest.self, from: data)
        XCTAssertEqual(restored, manifest)
        XCTAssertFalse(restored.chunks[0].voiceActivity)
    }

    func testMeetingEngineResponseDecodesNestedSessionAndChunk() throws {
        let data = #"{"id":7,"session":{"session_id":"session_1234","title":"Planning","started_at":1725000000,"status":"recording","chunk_count":1,"chunks":[{"seq":0,"source_path":"/tmp/source.wav","retained_path":"/tmp/retained.wav","offset_s":0,"duration_s":10,"speaker":"others","voice_activity":false,"status":"complete","text":"Ready."}]}}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(EngineResponse.self, from: data)
        XCTAssertEqual(response.session?.sessionID, "session_1234")
        XCTAssertEqual(response.session?.chunks?.first?.speaker, .others)
        XCTAssertEqual(response.session?.chunks?.first?.text, "Ready.")
        XCTAssertEqual(response.session?.chunks?.first?.sourcePath, "/tmp/source.wav")
        XCTAssertEqual(response.session?.chunks?.first?.retainedPath, "/tmp/retained.wav")
        XCTAssertEqual(response.session?.chunks?.first?.voiceActivity, false)
    }

    func testMeetingLifecyclePolicyProtectsActiveAndPendingOperations() {
        XCTAssertFalse(MeetingModel.State.summarizing.isRecording)
        XCTAssertTrue(MeetingModel.State.summarizing.isBusy)
        XCTAssertFalse(MeetingLifecyclePolicy.shouldRetryChunk(status: "complete"))
        XCTAssertFalse(MeetingLifecyclePolicy.shouldRetryChunk(status: "silence"))
        XCTAssertTrue(MeetingLifecyclePolicy.shouldRetryChunk(status: "error"))
        XCTAssertTrue(MeetingLifecyclePolicy.canLoadSession(isCapturing: false, pendingCount: 0,
                                                            uploadInFlight: false))
        XCTAssertFalse(MeetingLifecyclePolicy.canLoadSession(isCapturing: true, pendingCount: 0,
                                                             uploadInFlight: false))
        XCTAssertFalse(MeetingLifecyclePolicy.canLoadSession(isCapturing: false, pendingCount: 1,
                                                             uploadInFlight: false))
        XCTAssertFalse(MeetingLifecyclePolicy.canLoadSession(isCapturing: false, pendingCount: 0,
                                                             uploadInFlight: true))
        XCTAssertTrue(MeetingLifecyclePolicy.canExport(isCapturing: false, pendingCount: 0,
                                                       uploadInFlight: false, exportInFlight: false))
        XCTAssertFalse(MeetingLifecyclePolicy.canExport(isCapturing: true, pendingCount: 0,
                                                        uploadInFlight: false, exportInFlight: false))
        XCTAssertFalse(MeetingLifecyclePolicy.canExport(isCapturing: false, pendingCount: 1,
                                                        uploadInFlight: false, exportInFlight: false))
        XCTAssertFalse(MeetingLifecyclePolicy.canExport(isCapturing: false, pendingCount: 0,
                                                        uploadInFlight: false, exportInFlight: true))
    }
}
