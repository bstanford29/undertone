import XCTest
import Darwin
import CoreGraphics
@testable import UndertoneApp

private final class StreamChunkCollector: @unchecked Sendable {
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

final class ProtocolTests: XCTestCase {
    func testPermissionSnapshotRequiresOnlyDictationPermissions() {
        let ready = PermissionSnapshot(microphoneGranted: true, microphoneUndetermined: false,
                                       accessibilityGranted: true, inputMonitoringGranted: true,
                                       screenRecordingGranted: false)
        XCTAssertTrue(ready.dictationReady)

        let missingMicrophone = PermissionSnapshot(microphoneGranted: false, microphoneUndetermined: true,
                                                   accessibilityGranted: true, inputMonitoringGranted: true,
                                                   screenRecordingGranted: true)
        XCTAssertFalse(missingMicrophone.dictationReady)

        let missingAccessibility = PermissionSnapshot(microphoneGranted: true, microphoneUndetermined: false,
                                                      accessibilityGranted: false, inputMonitoringGranted: true,
                                                      screenRecordingGranted: true)
        XCTAssertFalse(missingAccessibility.dictationReady)
    }

    func testJSONValueRoundTrip() throws {
        let value: [String: JSONValue] = ["op": .string("clean"), "id": .number(7), "guard": .bool(false)]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testHistoryRowDecodesDocumentedFields() throws {
        let data = #"{"id":4,"raw_text":"raw","clean_text":"clean","edited_text":"edited","guard_fired":true,"model":"qwen3.5:latest","audio_path":"/tmp/a.wav","insert_mode":"ax"}"#.data(using: .utf8)!
        let row = try JSONDecoder().decode(HistoryRow.self, from: data)
        XCTAssertEqual(row.id, 4); XCTAssertEqual(row.guardFired, true); XCTAssertEqual(row.editedText, "edited")
        XCTAssertEqual(row.audioPath, "/tmp/a.wav")
    }

    func testHistoryRowDecodesSQLiteIntegerGuardFlag() throws {
        let data = #"{"id":5,"guard_fired":1}"#.data(using: .utf8)!
        let guarded = try JSONDecoder().decode(HistoryRow.self, from: data)
        XCTAssertEqual(guarded.guardFired, true)
        let clearData = #"{"id":6,"guard_fired":0}"#.data(using: .utf8)!
        let clear = try JSONDecoder().decode(HistoryRow.self, from: clearData)
        XCTAssertEqual(clear.guardFired, false)
    }

    func testCommandSelectionClassification() {
        XCTAssertTrue(AppModel.hasCommandSelection("selected sentence"))
        XCTAssertFalse(AppModel.hasCommandSelection(" \n\t"))
        XCTAssertFalse(AppModel.hasCommandSelection(nil))
        XCTAssertTrue(AppModel.hasEditableCommandSelection("selected sentence",
                                                           selectedRange: CFRange(location: 4, length: 8),
                                                           axSettable: true))
        XCTAssertFalse(AppModel.hasEditableCommandSelection("selected sentence",
                                                            selectedRange: CFRange(location: 4, length: 0),
                                                            axSettable: true))
        XCTAssertFalse(AppModel.hasEditableCommandSelection("selected sentence",
                                                            selectedRange: CFRange(location: 4, length: 8),
                                                            axSettable: false))
    }

    func testCommandLimitsAreUTF8ByteLimits() {
        XCTAssertTrue(AppModel.commandSelectionWithinLimit(String(repeating: "é", count: 524_288)))
        XCTAssertFalse(AppModel.commandSelectionWithinLimit(String(repeating: "é", count: 524_289)))
        XCTAssertTrue(AppModel.commandInstructionWithinLimit(String(repeating: "é", count: 2_048)))
        XCTAssertFalse(AppModel.commandInstructionWithinLimit(String(repeating: "é", count: 2_049)))
    }

    func testCommandSidecarMatchesHistoryFields() {
        let payload = AppModel.commandSidecarPayload(selectedText: "selected passage", instruction: "make shorter")
        XCTAssertEqual(payload["kind"], "command")
        XCTAssertEqual(payload["raw_text"], "selected passage")
        XCTAssertEqual(payload["instruction_text"], "make shorter")
        XCTAssertNil(payload["selected_text"])
    }

    func testCommandResponseDecodesRewrite() throws {
        let data = #"{"id":7,"rewrite":"Shortened selection.","model":"gemma4:31b","llm_ms":123.5}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(EngineResponse.self, from: data)
        XCTAssertEqual(response.id, 7)
        XCTAssertEqual(response.rewrite, "Shortened selection.")
        XCTAssertEqual(response.model, "gemma4:31b")
        XCTAssertEqual(response.llmMS, 123.5)
    }

    func testHistoryRowDecodesCommandMetadata() throws {
        let data = #"{"id":8,"kind":"command","raw_text":"Selected paragraph.","instruction_text":"Make this shorter","clean_text":"Short paragraph."}"#.data(using: .utf8)!
        let row = try JSONDecoder().decode(HistoryRow.self, from: data)
        XCTAssertEqual(row.kind, "command")
        XCTAssertEqual(row.rawText, "Selected paragraph.")
        XCTAssertEqual(row.instructionText, "Make this shorter")
        XCTAssertEqual(row.cleanText, "Short paragraph.")
    }

    func testLearnedSuggestionDecodesSocketFields() throws {
        let data = #"{"id":7,"produced":"Quinn","replacement":"Qwen","row_id":312,"app_bundle_id":"com.openai.codex","created_at":100.5,"reason":"capitalized"}"#.data(using: .utf8)!
        let suggestion = try JSONDecoder().decode(LearnedSuggestion.self, from: data)
        XCTAssertEqual(suggestion.id, 7)
        XCTAssertEqual(suggestion.replacement, "Qwen")
        XCTAssertEqual(suggestion.rowID, 312)
        XCTAssertEqual(suggestion.reason, "capitalized")
    }

    func testCorrectionLearningSettingDefaultsOffAndReadsPersistedConfig() {
        XCTAssertFalse(CorrectionLearningSetting.value(from: [:]))
        XCTAssertTrue(CorrectionLearningSetting.value(from: [CorrectionLearningSetting.key: .bool(true)]))
        XCTAssertFalse(CorrectionLearningSetting.value(from: [CorrectionLearningSetting.key: .string("yes")]))
    }

    func testLearningActionResponseDecodesStatusAndUndoToken() throws {
        let data = #"{"id":9,"status":"learned","action_id":12,"term":"Velora","action_status":"active","client_token":"velora-token"}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(EngineResponse.self, from: data)
        XCTAssertEqual(response.status, "learned")
        XCTAssertEqual(response.learningActionID, 12)
        XCTAssertEqual(response.learningActionStatus, "active")
        XCTAssertEqual(response.learningClientToken, "velora-token")
        XCTAssertEqual(response.term, "Velora")
    }

    func testLearningReconciliationPolicyRequiresACompleteLearnedResponse() {
        let token = AppModel.learningClientToken()
        XCTAssertTrue(token.count <= 128)
        XCTAssertTrue(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        XCTAssertFalse(token.contains("Velora"))
        XCTAssertEqual(
            AppModel.learningReconciliationPolicy(
                status: "learned", actionStatus: "active", actionID: 12, term: "Velora"
            ),
            .active(actionID: 12, term: "Velora")
        )
        XCTAssertEqual(
            AppModel.learningReconciliationPolicy(
                status: "learned", actionStatus: "superseded", actionID: 12, term: "Velora"
            ),
            .receipt("Kept newer dictionary entry for Velora")
        )
        XCTAssertEqual(
            AppModel.learningReconciliationPolicy(
                status: "learned", actionStatus: "undone", actionID: 12, term: "Velora"
            ),
            .receipt("Learning for Velora was already undone")
        )
        XCTAssertEqual(
            AppModel.learningReconciliationPolicy(
                status: "not_found", actionStatus: nil, actionID: nil, term: nil
            ),
            .notFound
        )
        XCTAssertEqual(
            AppModel.learningReconciliationPolicy(
                status: "learned", actionStatus: "mystery", actionID: 12, term: "Velora"
            ),
            .clear
        )
        XCTAssertEqual(
            AppModel.learningReconciliationPolicy(
                status: "learned", actionStatus: nil, actionID: 12, term: "Velora"
            ),
            .clear
        )
    }

    func testEngineClientUnixSocketRoundTrip() async throws {
        let path = "/tmp/undertone-test-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        XCTAssertLessThan(pathBytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }, 0)
        XCTAssertEqual(listen(server, 1), 0)

        let ready = expectation(description: "fake engine response")
        DispatchQueue.global().async {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var request = Data()
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1 {
                request.append(byte)
                if byte == 10 { break }
            }
            var response = #"{"id":1,"raw":"socket ok"}"#.data(using: .utf8)!
            response.append(10)
            response.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress { _ = Darwin.write(client, base, buffer.count) }
            }
            ready.fulfill()
        }

        let client = EngineClient(path: path)
        let response = try await client.request(op: "status")
        XCTAssertEqual(response.id, 1)
        XCTAssertEqual(response.raw, "socket ok")
        await fulfillment(of: [ready], timeout: 2)
    }

    func testEngineResponseDecodesStreamFieldsAndOldFixtures() throws {
        let streamed = #"{"id":3,"chunk":"Hello ","seq":0,"done":false}"#.data(using: .utf8)!
        let chunkFrame = try JSONDecoder().decode(EngineResponse.self, from: streamed)
        XCTAssertEqual(chunkFrame.chunk, "Hello ")
        XCTAssertEqual(chunkFrame.seq, 0)
        XCTAssertEqual(chunkFrame.done, false)

        let final = #"{"id":3,"done":true,"clean":"Hello world.","model":"qwen3.5:latest","guard_fired":false,"llm_ms":12.5,"chunks_sent":2,"stream_truncated":true,"stream_interrupted":false}"#.data(using: .utf8)!
        let doneFrame = try JSONDecoder().decode(EngineResponse.self, from: final)
        XCTAssertEqual(doneFrame.done, true)
        XCTAssertEqual(doneFrame.clean, "Hello world.")
        XCTAssertEqual(doneFrame.chunksSent, 2)
        XCTAssertEqual(doneFrame.streamTruncated, true)
        XCTAssertEqual(doneFrame.streamInterrupted, false)

        let legacy = #"{"id":7,"rewrite":"Shortened selection.","model":"gemma4:31b","llm_ms":123.5}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(EngineResponse.self, from: legacy)
        XCTAssertEqual(old.id, 7)
        XCTAssertEqual(old.rewrite, "Shortened selection.")
        XCTAssertNil(old.chunk)
        XCTAssertNil(old.done)
        XCTAssertNil(old.chunksSent)
    }

    func testStreamInsertionRemainder() {
        XCTAssertEqual(StreamInsertion.remainder(clean: "Hello world.", committed: "Hello "), "world.")
        XCTAssertEqual(StreamInsertion.remainder(clean: "Hello world.", committed: "Hello world."), "")
        XCTAssertEqual(StreamInsertion.remainder(clean: "Hello world.", committed: ""), "Hello world.")
        XCTAssertNil(StreamInsertion.remainder(clean: "Hello world.", committed: "Goodbye"))
        XCTAssertNil(StreamInsertion.remainder(clean: "Hello", committed: "Hello world"))
    }

    func testRequestStreamDeliversChunksInOrderAndReturnsFinal() async throws {
        let path = "/tmp/undertone-stream-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }, 0)
        XCTAssertEqual(listen(server, 1), 0)

        let ready = expectation(description: "fake stream engine")
        DispatchQueue.global().async {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != 10 {}
            var payload = Data()
            for line in [
                #"{"id":1,"seq":0,"chunk":"Hello "}"#,
                #"{"id":1,"seq":1,"chunk":"world"}"#,
                #"{"id":1,"done":true,"clean":"Hello world.","chunks_sent":2,"guard_fired":false,"llm_ms":9}"#,
            ] {
                payload.append(contentsOf: line.utf8)
                payload.append(10)
            }
            payload.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress { _ = Darwin.write(client, base, buffer.count) }
            }
            ready.fulfill()
        }

        let client = EngineClient(path: path)
        let collector = StreamChunkCollector()
        let response = try await client.requestStream(op: "clean.stream") { chunk in
            collector.append(chunk)
        }
        XCTAssertEqual(collector.values, ["Hello ", "world"])
        XCTAssertEqual(response.done, true)
        XCTAssertEqual(response.clean, "Hello world.")
        XCTAssertEqual(response.chunksSent, 2)
        await fulfillment(of: [ready], timeout: 2)
    }

    func testRequestStreamThrowsOnIdMismatch() async throws {
        let path = "/tmp/undertone-stream-id-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }, 0)
        XCTAssertEqual(listen(server, 1), 0)

        let ready = expectation(description: "mismatched stream id")
        DispatchQueue.global().async {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != 10 {}
            var payload = #"{"id":99,"seq":0,"chunk":"nope"}"#.data(using: .utf8)!
            payload.append(10)
            payload.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress { _ = Darwin.write(client, base, buffer.count) }
            }
            ready.fulfill()
        }

        let client = EngineClient(path: path)
        do {
            _ = try await client.requestStream(op: "clean.stream") { _ in }
            XCTFail("id mismatch must throw")
        } catch EngineClientError.protocolViolation {
            // expected
        } catch {
            XCTFail("expected protocolViolation, got \(error)")
        }
        await fulfillment(of: [ready], timeout: 2)
    }

    func testEngineClientUsesFreshConnectionForEachRequest() async throws {
        let path = "/tmp/undertone-fresh-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }, 0)
        XCTAssertEqual(listen(server, 2), 0)

        let served = expectation(description: "two one-frame connections served")
        DispatchQueue.global().async {
            for id in 1...2 {
                let client = accept(server, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var byte: UInt8 = 0
                while Darwin.read(client, &byte, 1) == 1, byte != 10 {}
                var response = "{\"id\":\(id),\"raw\":\"socket \(id)\"}".data(using: .utf8)!
                response.append(10)
                response.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress { _ = Darwin.write(client, base, buffer.count) }
                }
            }
            served.fulfill()
        }

        let client = EngineClient(path: path)
        let first = try await client.request(op: "status")
        let second = try await client.request(op: "status")
        XCTAssertEqual(first.raw, "socket 1")
        XCTAssertEqual(second.raw, "socket 2")
        await fulfillment(of: [served], timeout: 2)
    }

    func testEngineClientDoesNotReplayMutationAfterUncertainResponse() async throws {
        let path = "/tmp/undertone-no-replay-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }, 0)
        XCTAssertEqual(listen(server, 2), 0)

        let closed = expectation(description: "mutation connection closed before response")
        DispatchQueue.global().async {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != 10 {}
            close(client)
            closed.fulfill()
        }

        let client = EngineClient(path: path)
        do {
            _ = try await client.request(op: "history.record", fields: ["raw_text": .string("one attempt")])
            XCTFail("an uncertain mutation must report failure")
        } catch {
            // The caller decides whether a failed mutation is safe to repeat.
        }
        await fulfillment(of: [closed], timeout: 2)

        var flags = fcntl(server, F_GETFL, 0)
        XCTAssertGreaterThanOrEqual(flags, 0)
        flags |= O_NONBLOCK
        XCTAssertEqual(fcntl(server, F_SETFL, flags), 0)
        usleep(100_000)
        let replay = accept(server, nil, nil)
        XCTAssertEqual(replay, -1, "the client must not automatically replay a mutation")
    }

    func testUTF16ChunksPreserveSurrogatePairs() {
        let samples = [
            String(repeating: "a", count: 19) + "😀" + "tail",
            "😀😃😄😁😆😅😂🤣☺️😊"
        ]
        for sample in samples {
            let chunks = InsertionController.utf16Chunks(sample)
            XCTAssertEqual(chunks.flatMap { $0 }, Array(sample.utf16))
            XCTAssertTrue(chunks.allSatisfy { chunk in
                Array(String(decoding: chunk, as: UTF16.self).utf16) == chunk
            })
            XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        }
    }

    func testNeedsFnClearReadsOnlyTheSecondaryFnBit() {
        XCTAssertTrue(InsertionController.needsFnClear(sessionFlags: [.maskSecondaryFn]))
        XCTAssertTrue(InsertionController.needsFnClear(sessionFlags: [.maskSecondaryFn, .maskShift]))
        XCTAssertFalse(InsertionController.needsFnClear(sessionFlags: []))
        XCTAssertFalse(InsertionController.needsFnClear(sessionFlags: [.maskShift, .maskAlternate]))
    }

    func testAXFirstAppsAreEmptyByDefault() {
        XCTAssertFalse(InsertionController.shouldAXFirst(bundleID: "com.apple.MobileSMS"))
        XCTAssertFalse(InsertionController.shouldAXFirst(bundleID: "com.openai.codex"))
        XCTAssertFalse(InsertionController.shouldAXFirst(bundleID: "com.anthropic.claudefordesktop"))
        XCTAssertFalse(InsertionController.shouldAXFirst(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(InsertionController.shouldAXFirst(bundleID: nil))
    }

    func testDictationInsertRouteDecisionTable() {
        // Different frontmost bundle (or Undertone's own): always appChanged,
        // regardless of axFirst or element state.
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: false, axFirst: false, snapshotHasElement: true, currentElementMatches: true
        ), .appChanged)
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: false, axFirst: true, snapshotHasElement: false, currentElementMatches: false
        ), .appChanged)

        // Same app, not axFirst (the default for every app): type regardless
        // of element state. This is the Messages/Electron fix: a hollow AX
        // success cannot be told apart from a real one by read-back, so
        // typed keystrokes are the default route everywhere.
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: true, axFirst: false, snapshotHasElement: true, currentElementMatches: true
        ), .type)
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: true, axFirst: false, snapshotHasElement: false, currentElementMatches: false
        ), .type)
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: true, axFirst: false, snapshotHasElement: true, currentElementMatches: false
        ), .type)

        // Same app, axFirst bundle, but no element captured at key-down (or a
        // different element is focused now): type, never fail.
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: true, axFirst: true, snapshotHasElement: false, currentElementMatches: false
        ), .type)
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: true, axFirst: true, snapshotHasElement: true, currentElementMatches: false
        ), .type)

        // Same app, axFirst bundle, same element still focused: attempt AX.
        XCTAssertEqual(InsertionController.dictationInsertRoute(
            bundleMatches: true, axFirst: true, snapshotHasElement: true, currentElementMatches: true
        ), .axAttempt)
    }

    func testInsertFailureRawValuesMatchHistoryFormat() {
        XCTAssertEqual(InsertFailure.emptyText.rawValue, "emptyText")
        XCTAssertEqual(InsertFailure.notTrusted.rawValue, "notTrusted")
        XCTAssertEqual(InsertFailure.appChanged.rawValue, "appChanged")
        XCTAssertEqual(InsertFailure.elementChanged.rawValue, "elementChanged")
        XCTAssertEqual(InsertFailure.axRejected.rawValue, "axRejected")
        XCTAssertEqual(InsertFailure.typeFailed.rawValue, "typeFailed")
        XCTAssertEqual(InsertOutcome.failed(.appChanged).historyValue, "failed:appChanged")
        XCTAssertEqual(InsertOutcome.inserted(.ax).historyValue, "ax")
        XCTAssertEqual(InsertOutcome.inserted(.type).historyValue, "type")
        XCTAssertTrue(InsertOutcome.failed(.elementChanged).isFailure)
        XCTAssertFalse(InsertOutcome.inserted(.type).isFailure)
    }

    func testFailureMessageNamesTheReasonInPlainWords() {
        XCTAssertEqual(AppModel.failureMessage(.notTrusted), "Accessibility permission required")
        XCTAssertEqual(AppModel.failureMessage(.appChanged), "Insertion failed: app changed")
        XCTAssertEqual(AppModel.failureMessage(.elementChanged), "Insertion failed: element changed")
        XCTAssertEqual(AppModel.failureMessage(.axRejected), "Insertion failed: Accessibility rejected")
        XCTAssertEqual(AppModel.failureMessage(.typeFailed), "Insertion failed: typing failed")
    }

    func testConfirmedAXInsertionRequiresReadbackMatch() {
        // Value readable: only a match counts as confirmed.
        XCTAssertTrue(InsertionController.isConfirmedAXInsertion(text: "hello", readableValue: "say hello now"))
        XCTAssertFalse(InsertionController.isConfirmedAXInsertion(text: "hello", readableValue: "unrelated"))
        // Value unreadable: never trust success. An unreadable value is
        // exactly the shape of a hollow AX success.
        XCTAssertFalse(InsertionController.isConfirmedAXInsertion(text: "hello", readableValue: nil))
    }

    func testUndoRangeRequiresOriginalCaretAndContent() {
        let inserted = "hello"
        let value = "xxhello yyhello"
        let original = CFRange(location: 2, length: 0)
        let expectedCaret = CFRange(location: 2 + inserted.utf16.count, length: 0)
        let exact = InsertionController.exactReplacementRange(inserted: inserted, value: value,
                                                              originalRange: original, currentRange: expectedCaret)
        XCTAssertEqual(exact?.location, 2)
        XCTAssertEqual(exact?.length, inserted.utf16.count)
        XCTAssertNil(InsertionController.exactReplacementRange(inserted: inserted, value: value,
                                                               originalRange: original,
                                                               currentRange: CFRange(location: 15, length: 0)))
        XCTAssertNil(InsertionController.exactReplacementRange(inserted: inserted, value: "xxHELLO yyhello",
                                                               originalRange: original, currentRange: expectedCaret))
    }

    func testHotkeyStateMachineTapLockAndLongHold() {
        var state = HotkeyStateMachine()
        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 0.1), .stopAfterDelay)
        XCTAssertTrue(state.delayedStop())

        state.reset()
        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 0.1), .stopAfterDelay)
        XCTAssertEqual(state.press(at: 0.2), .none)
        XCTAssertTrue(state.locked)
        XCTAssertEqual(state.release(at: 0.25), .none)
        XCTAssertFalse(state.delayedStop())
        XCTAssertEqual(state.press(at: 0.3), .stop)
        XCTAssertEqual(state.release(at: 0.31), .none)

        state.reset()
        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 1), .stopImmediately)
        XCTAssertFalse(state.delayedStop())
    }

    func testHotkeyStateMachineLockAndUnlockTransitions() {
        var state = HotkeyStateMachine()
        // Double-tap locks.
        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 0.05), .stopAfterDelay)
        XCTAssertEqual(state.press(at: 0.1), .none)
        XCTAssertTrue(state.locked)

        // A single press while locked stops, and its matching release is a no-op.
        XCTAssertEqual(state.press(at: 0.5), .stop)
        XCTAssertFalse(state.locked)
        XCTAssertEqual(state.release(at: 0.51), .none)

        // A press within the double-tap window right after a lock stop does
        // not read as the second tap of a new lock.
        XCTAssertEqual(state.press(at: 0.6), .start)
        XCTAssertFalse(state.locked)
    }

    func testHotkeyStateMachineEscapeStopsLockAndDoesNotRelock() {
        var state = HotkeyStateMachine()
        XCTAssertFalse(state.stopIfLocked())

        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 0.05), .stopAfterDelay)
        XCTAssertEqual(state.press(at: 0.1), .none)
        XCTAssertTrue(state.locked)

        // Escape stops the lock without going through the hold key.
        XCTAssertTrue(state.stopIfLocked())
        XCTAssertFalse(state.locked)
        // A second call is a no-op; nothing left latched.
        XCTAssertFalse(state.stopIfLocked())

        // A press within the double-tap window right after does not relock.
        XCTAssertEqual(state.press(at: 0.2), .start)
        XCTAssertFalse(state.locked)
        // Its release behaves like any ordinary short hold, not a suppressed
        // lock-stop release.
        XCTAssertEqual(state.release(at: 0.25), .stopAfterDelay)
    }

    func testShouldConsumeAtTapNeverSwallowsAnyEvent() {
        // fn flagsChanged (both directions) must pass through. Swallowing it
        // at the tap does not retract fn from the OS's own modifier
        // tracking, so a lock-mode stop tap could leave fn reading as held
        // into the next typed letter, turning it into a globe+key system
        // shortcut. See `shouldConsumeAtTap`'s doc comment.
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: .flagsChanged, keyCode: 63))
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: .flagsChanged, keyCode: 63))
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: .flagsChanged, keyCode: 105))
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: .keyDown, keyCode: 105))
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: .keyUp, keyCode: 105))
        // A keyDown for another key (e.g. Right Arrow) that happens to carry
        // maskSecondaryFn because fn is held passes through untouched.
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: .keyDown, keyCode: 124))
        // The systemDefined event type (raw value 14, NX_SYSDEFINED) used for
        // media/aux keys and the globe key's own default action must also
        // never be swallowed; the tap only logs it for diagnostics.
        let systemDefined = CGEventType(rawValue: HotkeyMonitor.systemDefinedEventType)!
        XCTAssertFalse(HotkeyMonitor.shouldConsumeAtTap(type: systemDefined, keyCode: 0))
    }

    func testAXContextIsBoundedAndHarvestsProperNouns() {
        let value = String(repeating: "x", count: 2_100) + " Northwind met Priya today"
        let target = TargetSnapshot(bundleID: "fixture.app", element: nil, value: value,
                                    selectedText: "", selectedRange: CFRange(location: 2_100, length: 0))
        let context = AXContextReader.context(for: target)
        XCTAssertLessThanOrEqual(context.before.utf16.count, 2_000)
        XCTAssertLessThanOrEqual(context.after.utf16.count, 2_000)
        XCTAssertEqual(AXContextReader.harvestedTerms(for: target), ["Northwind", "Priya"])
    }

    func testContextDoesNotSplitEmojiOrSendOversizedSelection() {
        let value = String(repeating: "🧭", count: 2_100)
        let target = TargetSnapshot(bundleID: "fixture", element: nil, value: value, selectedText: value, selectedRange: CFRange(location: 0, length: value.utf16.count))
        let context = AXContextReader.context(for: target, maximumUnits: 1_999)
        XCTAssertLessThanOrEqual(context.selected.utf16.count, 1_999)
        XCTAssertFalse(context.selected.contains("�"))
        XCTAssertNil(EditWatcher.candidate(produced: "Use Quinn today", replacement: "Please use Quinn today", knownTerms: []))
    }

    func testFallbackContextBoundsUTF16WithoutSplittingEmoji() {
        let selected = "a😀bc"
        let target = TargetSnapshot(bundleID: "fixture", element: nil, value: nil,
                                    selectedText: selected, selectedRange: nil)
        let context = AXContextReader.context(for: target, maximumUnits: 2)
        XCTAssertEqual(context.selected, "a")
        XCTAssertEqual(AXContextReader.context(for: target, maximumUnits: 0).selected, "")
    }

    func testEditWatcherAcceptsOnlyChangesInsideInsertedSpan() {
        let expected = "beforeQuinn after"
        let range = CFRange(location: 6, length: "Quinn".utf16.count)
        XCTAssertEqual(EditWatcher.isolatedEditedSpan(expected: expected, current: "beforeQwen after", range: range), "Qwen")
        XCTAssertNil(EditWatcher.isolatedEditedSpan(expected: expected, current: "changedQwen after", range: range))
        XCTAssertNil(EditWatcher.isolatedEditedSpan(expected: expected, current: "beforeQuinn changed", range: range))
    }

    func testLearningCandidateUsesCapitalizedOrUnknownReplacement() {
        let candidate = EditWatcher.candidate(produced: "Please use Quinn", replacement: "Please use Qwen", knownTerms: [])
        XCTAssertEqual(candidate, LearningCandidate(produced: "Quinn", replacement: "Qwen", reason: "capitalized"))
        XCTAssertNil(EditWatcher.candidate(produced: "Please use Quinn", replacement: "Please use Qwen", knownTerms: ["qwen"]))
        XCTAssertNil(EditWatcher.candidate(produced: "Quinn,", replacement: "Quinn", knownTerms: []))
        XCTAssertNil(EditWatcher.candidate(produced: "quinn", replacement: "Quinn", knownTerms: []))
        let punctuation = EditWatcher.candidate(produced: "Quinn", replacement: "Qwen,", knownTerms: [])
        XCTAssertEqual(punctuation?.replacement, "Qwen")
        XCTAssertEqual(EditWatcher.alreadyKnownCandidate(produced: "Quinn", replacement: "Qwen", knownTerms: ["qwen"]),
                       LearningCandidate(produced: "Quinn", replacement: "Qwen", reason: "already_known"))
    }

    func testCorrectionLearningNoticePolicyUsesExactSafeStatesAndCopy() {
        XCTAssertTrue(AppModel.canShowLearningNotice(for: .idle))
        XCTAssertTrue(AppModel.canShowLearningNotice(for: .notice("Saved")))
        XCTAssertFalse(AppModel.canShowLearningNotice(for: .meetingDetected(PreviewFixtures.detectedMeeting)))
        XCTAssertFalse(AppModel.canShowLearningNotice(for: .listening(level: 0.5)))
        XCTAssertFalse(AppModel.canShowLearningNotice(for: .working))
        XCTAssertFalse(AppModel.canShowLearningNotice(for: .recording(elapsed: 1)))
        XCTAssertFalse(AppModel.canShowLearningNotice(for: .error("busy")))
        let state = PillState.notice(AppModel.learningNotice(for: "Velora"))
        XCTAssertTrue(AppModel.isLearningNotice(state, term: "Velora"))
        XCTAssertFalse(AppModel.isLearningNotice(.notice("Saved"), term: "Velora"))
        XCTAssertFalse(AppModel.isLearningNotice(state, term: "Qwen"))
    }

    func testMeetingNudgeDefersLearningUndoAndConfirmationNotices() {
        let learningNotice = PillState.notice(AppModel.learningNotice(for: "Velora"))
        XCTAssertTrue(AppModel.shouldDeferMeetingNudge(for: learningNotice, pendingLearningTerm: "Velora"))
        XCTAssertFalse(AppModel.shouldDeferMeetingNudge(for: .notice("Saved"), pendingLearningTerm: "Velora"))
        XCTAssertFalse(AppModel.shouldDeferMeetingNudge(for: learningNotice, pendingLearningTerm: "Qwen"))
        XCTAssertFalse(AppModel.shouldDeferMeetingNudge(for: .idle, pendingLearningTerm: "Velora"))
        XCTAssertTrue(AppModel.shouldDeferMeetingNudge(
            for: .notice("Undid learning Velora"), pendingLearningTerm: nil
        ))
        XCTAssertTrue(AppModel.shouldDeferMeetingNudge(
            for: .notice("Velora was already removed"), pendingLearningTerm: nil
        ))
        XCTAssertFalse(AppModel.shouldDeferMeetingNudge(for: .notice("Saved"), pendingLearningTerm: nil))
        XCTAssertTrue(AppModel.preservesDeferredMeetingNudge(.notice("Undid learning Velora")))
        XCTAssertTrue(AppModel.preservesDeferredMeetingNudge(.notice("Kept newer dictionary entry for Velora")))
        XCTAssertTrue(AppModel.preservesDeferredMeetingNudge(.notice("Kept newer learning for Velora")))
        XCTAssertTrue(AppModel.preservesDeferredMeetingNudge(.notice("Learning for Velora was already undone")))
        XCTAssertTrue(AppModel.preservesDeferredMeetingNudge(.notice("Velora was already removed")))
        XCTAssertFalse(AppModel.preservesDeferredMeetingNudge(learningNotice))
        XCTAssertFalse(AppModel.preservesDeferredMeetingNudge(.notice("Saved")))
    }

    func testLearningUndoReceiptNamesEachSemanticStatusAndRejectsUnknown() {
        XCTAssertEqual(AppModel.learningUndoReceipt(status: "removed", term: "Velora"), "Undid learning Velora")
        XCTAssertEqual(AppModel.learningUndoReceipt(status: "superseded", term: "Velora"), "Kept newer dictionary entry for Velora")
        XCTAssertEqual(AppModel.learningUndoReceipt(status: "preserved", term: "Velora"), "Kept newer learning for Velora")
        XCTAssertEqual(AppModel.learningUndoReceipt(status: "undone", term: "Velora"), "Learning for Velora was already undone")
        XCTAssertEqual(AppModel.learningUndoReceipt(status: "absent", term: "Velora"), "Velora was already removed")
        XCTAssertNil(AppModel.learningUndoReceipt(status: nil, term: "Velora"))
        XCTAssertNil(AppModel.learningUndoReceipt(status: "unexpected", term: "Velora"))
    }

    func testDeferredMeetingNudgeRequiresTheSameCurrentDetectionAndEligibility() {
        let meeting = PreviewFixtures.detectedMeeting
        let otherMeeting = PreviewFixtures.detectedTeams
        XCTAssertTrue(AppModel.shouldShowDeferredMeetingNudge(
            current: meeting, deferred: meeting, enabled: true, persistent: true,
            ignored: false, busy: false, pillIsIdle: true))
        XCTAssertFalse(AppModel.shouldShowDeferredMeetingNudge(
            current: nil, deferred: meeting, enabled: true, persistent: true,
            ignored: false, busy: false, pillIsIdle: true))
        XCTAssertFalse(AppModel.shouldShowDeferredMeetingNudge(
            current: otherMeeting, deferred: meeting, enabled: true, persistent: true,
            ignored: false, busy: false, pillIsIdle: true))
        XCTAssertFalse(AppModel.shouldShowDeferredMeetingNudge(
            current: meeting, deferred: meeting, enabled: false, persistent: true,
            ignored: false, busy: false, pillIsIdle: true))
        XCTAssertFalse(AppModel.shouldShowDeferredMeetingNudge(
            current: meeting, deferred: meeting, enabled: true, persistent: true,
            ignored: true, busy: false, pillIsIdle: true))
        XCTAssertFalse(AppModel.shouldShowDeferredMeetingNudge(
            current: meeting, deferred: meeting, enabled: true, persistent: true,
            ignored: false, busy: true, pillIsIdle: true))
        XCTAssertFalse(AppModel.shouldShowDeferredMeetingNudge(
            current: meeting, deferred: meeting, enabled: true, persistent: true,
            ignored: false, busy: false, pillIsIdle: false))
    }

    func testLearningUndoCanBeginOnlyOnceWhileRequestIsInFlight() {
        XCTAssertTrue(AppModel.canBeginLearningUndo(actionID: 7, inFlight: false))
        XCTAssertFalse(AppModel.canBeginLearningUndo(actionID: 7, inFlight: true))
        XCTAssertFalse(AppModel.canBeginLearningUndo(actionID: nil, inFlight: false))
    }

    func testFailedBusyRollbackRetainsRecoverableUndoUntilSafe() {
        let learningNotice = PillState.notice(AppModel.learningNotice(for: "Velora"))
        XCTAssertFalse(AppModel.shouldKeepLearningActionAfterRollback(rollbackSucceeded: true))
        XCTAssertTrue(AppModel.shouldKeepLearningActionAfterRollback(rollbackSucceeded: false))
        XCTAssertTrue(AppModel.canShowLearningRecoveryNotice(for: .idle))
        XCTAssertFalse(AppModel.canShowLearningRecoveryNotice(for: .inserted(totalMS: 12)))
        XCTAssertFalse(AppModel.canShowLearningRecoveryNotice(for: .meetingDetected(PreviewFixtures.detectedMeeting)))
        XCTAssertTrue(AppModel.canSupersedeLearningRecovery(false))
        XCTAssertFalse(AppModel.canSupersedeLearningRecovery(true))
        XCTAssertTrue(AppModel.shouldKeepLearningRecoveryAfterReshowing(inFlight: true))
        XCTAssertFalse(AppModel.shouldKeepLearningRecoveryAfterReshowing(inFlight: false))
        XCTAssertTrue(AppModel.shouldPreserveLearningRecoveryWhileShowingNotice(
            state: learningNotice, nextState: .notice("Meeting ended"),
            actionID: 7, term: "Velora", recoveryPending: false))
        XCTAssertTrue(AppModel.shouldPreserveLearningRecoveryWhileShowingNotice(
            state: learningNotice, nextState: .notice("Saved"),
            actionID: 7, term: "Velora", recoveryPending: false))
        XCTAssertTrue(AppModel.shouldPreserveLearningRecoveryWhileShowingNotice(
            state: .idle, nextState: .notice("Saved"),
            actionID: nil, term: nil, recoveryPending: true))
        XCTAssertFalse(AppModel.shouldPreserveLearningRecoveryWhileShowingNotice(
            state: .notice("Saved"), nextState: .notice("Saved"),
            actionID: 7, term: "Velora", recoveryPending: false))
        XCTAssertFalse(AppModel.shouldPreserveLearningRecoveryWhileShowingNotice(
            state: learningNotice, nextState: .idle,
            actionID: 7, term: "Velora", recoveryPending: false))
        XCTAssertTrue(AppModel.shouldFallbackForPendingLearning(actionID: 7))
        XCTAssertFalse(AppModel.shouldFallbackForPendingLearning(actionID: nil))
        XCTAssertTrue(AppModel.shouldFallbackForPendingLearning(actionID: nil, unresolvedToken: "opaque-token"))
        XCTAssertFalse(AppModel.shouldFallbackForPendingLearning(actionID: nil, unresolvedToken: nil))
        XCTAssertTrue(AppModel.canBeginLearningReconciliation(tokenPresent: true, inFlight: false))
        XCTAssertFalse(AppModel.canBeginLearningReconciliation(tokenPresent: true, inFlight: true))
        XCTAssertFalse(AppModel.canBeginLearningReconciliation(tokenPresent: false, inFlight: false))
    }

    func testPersistedLearningFallbackIsBoundedAndRoundTrips() throws {
        let fallback = PersistedLearningFallback(
            produced: "Quinn", replacement: "Qwen", rowID: 7,
            appBundleID: "com.example.editor"
        )
        XCTAssertTrue(fallback.isValid)
        XCTAssertEqual(fallback.candidate, LearningCandidate(
            produced: "Quinn", replacement: "Qwen", reason: "recovered"
        ))
        let decoded = try JSONDecoder().decode(
            PersistedLearningFallback.self,
            from: JSONEncoder().encode(fallback)
        )
        XCTAssertEqual(decoded, fallback)
        let request = PersistedLearningRequest(token: "opaque-token", fallback: fallback)
        XCTAssertTrue(request.isValid)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PersistedLearningRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertFalse(PersistedLearningRequest(token: "bad token", fallback: fallback).isValid)
        XCTAssertFalse(PersistedLearningFallback(
            produced: "Quinn", replacement: "Qwen", rowID: 0,
            appBundleID: "com.example.editor"
        ).isValid)
        XCTAssertFalse(PersistedLearningFallback(
            produced: "Quinn", replacement: String(repeating: "x", count: 201), rowID: 7,
            appBundleID: "com.example.editor"
        ).isValid)
    }

    func testHarvestDropsOversizedUnicodeToken() {
        let oversized = String(repeating: "A", count: AXContextReader.maximumHarvestTokenScalars + 1)
        let target = TargetSnapshot(bundleID: "fixture", element: nil, value: oversized + " Northwind",
                                    selectedText: "", selectedRange: nil)
        XCTAssertEqual(AXContextReader.harvestedTerms(for: target), ["Northwind"])
    }

    func testShortcutsRequireOptionShiftAndIgnoreRepeats() {
        let exact: CGEventFlags = [.maskAlternate, .maskShift]
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 9, flags: exact, autorepeat: false), "v")
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 6, flags: exact, autorepeat: false), "z")
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 8, flags: exact, autorepeat: false), "c")
        XCTAssertNil(HotkeyMonitor.shortcut(for: 9, flags: [.maskAlternate], autorepeat: false))
        XCTAssertNil(HotkeyMonitor.shortcut(for: 9, flags: [.maskAlternate, .maskShift, .maskCommand], autorepeat: false))
        XCTAssertNil(HotkeyMonitor.shortcut(for: 9, flags: exact, autorepeat: true))
    }

    func testShortcutToleratesCapsLockNumericPadNonCoalescedAndFnBits() {
        let base: CGEventFlags = [.maskAlternate, .maskShift]
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 9, flags: base.union(.maskAlphaShift), autorepeat: false), "v")
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 9, flags: base.union(.maskNumericPad), autorepeat: false), "v")
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 9, flags: base.union(.maskNonCoalesced), autorepeat: false), "v")
        XCTAssertEqual(HotkeyMonitor.shortcut(for: 9, flags: base.union(.maskSecondaryFn), autorepeat: false), "v")
        XCTAssertEqual(
            HotkeyMonitor.shortcut(for: 9, flags: base.union([.maskAlphaShift, .maskNumericPad, .maskNonCoalesced, .maskSecondaryFn]), autorepeat: false),
            "v"
        )
        // The forbidden modifiers still block a match even alongside the ignored bits.
        XCTAssertNil(HotkeyMonitor.shortcut(for: 9, flags: base.union([.maskCommand, .maskAlphaShift]), autorepeat: false))
        XCTAssertNil(HotkeyMonitor.shortcut(for: 9, flags: base.union([.maskControl, .maskNonCoalesced]), autorepeat: false))
    }

    func testGlobalShortcutConsumesDownRepeatAndUp() {
        let monitor = HotkeyMonitor()
        var calls = 0
        monitor.onShortcut = { _ in calls += 1 }
        XCTAssertFalse(monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: [.maskAlternate, .maskShift], autorepeat: true))
        XCTAssertFalse(monitor.consumeShortcut(type: .keyUp, keyCode: 9, flags: [], autorepeat: false))
        XCTAssertTrue(monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: [.maskAlternate, .maskShift], autorepeat: false))
        XCTAssertTrue(monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: [.maskAlternate, .maskShift], autorepeat: true))
        XCTAssertTrue(monitor.consumeShortcut(type: .keyUp, keyCode: 9, flags: [], autorepeat: false))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: [], autorepeat: false))
    }

    func testGlobalShortcutWithCapsLockConsumesDownAndMatchingUp() {
        let monitor = HotkeyMonitor()
        var calls = 0
        monitor.onShortcut = { _ in calls += 1 }
        let flags: CGEventFlags = [.maskAlternate, .maskShift, .maskAlphaShift]
        XCTAssertTrue(monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: flags, autorepeat: false))
        XCTAssertTrue(monitor.consumeShortcut(type: .keyUp, keyCode: 9, flags: [.maskAlphaShift], autorepeat: false))
        XCTAssertEqual(calls, 1)
    }

    func testConsumeShortcutRecordsLastShortcutSeen() {
        let monitor = HotkeyMonitor()
        XCTAssertNil(monitor.lastShortcutSeen)
        let before = Date()
        XCTAssertTrue(monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: [.maskAlternate, .maskShift], autorepeat: false))
        guard let sighting = monitor.lastShortcutSeen else {
            return XCTFail("Expected a recorded shortcut sighting")
        }
        XCTAssertEqual(sighting.chordName, "⌥⇧V")
        XCTAssertGreaterThanOrEqual(sighting.date.timeIntervalSince1970, before.timeIntervalSince1970)
    }

    func testDiagnosticsChangeFiresWhenLastShortcutSeenUpdates() {
        let monitor = HotkeyMonitor()
        var diagnosticsCalls = 0
        monitor.onDiagnosticsChange = { _, _ in diagnosticsCalls += 1 }
        XCTAssertFalse(monitor.tapActive)
        monitor.stop()
        XCTAssertFalse(monitor.tapActive)
        _ = monitor.consumeShortcut(type: .keyDown, keyCode: 9, flags: [.maskAlternate, .maskShift], autorepeat: false)
        XCTAssertNotNil(monitor.lastShortcutSeen)
        XCTAssertEqual(diagnosticsCalls, 1)
    }

    func testHistoryFallsBackToRawAfterCleanupFailure() throws {
        let row = try JSONDecoder().decode(HistoryRow.self, from: Data(#"{"id":1,"clean_text":"","raw_text":"Retained words"}"#.utf8))
        XCTAssertEqual(row.preferredText, "Retained words")
    }

    // MARK: - holdKeyIsDown

    func testHoldKeyIsDownTracksFnFlagsChangedTransitions() {
        let monitor = HotkeyMonitor()
        var released = 0
        monitor.onHoldKeyReleased = { released += 1 }
        XCTAssertFalse(monitor.holdKeyIsDown)

        monitor.handle(type: .flagsChanged, keyCode: 63, flags: [.maskSecondaryFn])
        XCTAssertTrue(monitor.holdKeyIsDown)
        XCTAssertEqual(released, 0)

        monitor.handle(type: .flagsChanged, keyCode: 63, flags: [])
        XCTAssertFalse(monitor.holdKeyIsDown)
        XCTAssertEqual(released, 1)

        // A rapid double tap engages lock (the state machine's own
        // transitions are covered elsewhere); holdKeyIsDown must still track
        // every physical down/up pair regardless of the resulting lock
        // state or press/release action.
        monitor.handle(type: .flagsChanged, keyCode: 63, flags: [.maskSecondaryFn])
        XCTAssertTrue(monitor.holdKeyIsDown)
        monitor.handle(type: .flagsChanged, keyCode: 63, flags: [])
        XCTAssertFalse(monitor.holdKeyIsDown)
        XCTAssertEqual(released, 2)
        XCTAssertTrue(monitor.isLocked)

        // The lock-stop tap: fn goes down while locked (the state machine
        // reports .stop) and holdKeyIsDown must read true until the
        // matching up arrives, exactly like any other down/up pair.
        monitor.handle(type: .flagsChanged, keyCode: 63, flags: [.maskSecondaryFn])
        XCTAssertTrue(monitor.holdKeyIsDown)
        XCTAssertFalse(monitor.isLocked)
        monitor.handle(type: .flagsChanged, keyCode: 63, flags: [])
        XCTAssertFalse(monitor.holdKeyIsDown)
        XCTAssertEqual(released, 3)
    }

    func testHoldKeyIsDownTracksF13DownUpTransitions() {
        let monitor = HotkeyMonitor()
        var released = 0
        monitor.onHoldKeyReleased = { released += 1 }
        XCTAssertFalse(monitor.holdKeyIsDown)

        monitor.handle(type: .keyDown, keyCode: 105, flags: [])
        XCTAssertTrue(monitor.holdKeyIsDown)
        XCTAssertEqual(released, 0)

        // Autorepeat keyDowns while already pressed must not re-fire or
        // otherwise disturb the down state.
        monitor.handle(type: .keyDown, keyCode: 105, flags: [])
        XCTAssertTrue(monitor.holdKeyIsDown)

        monitor.handle(type: .keyUp, keyCode: 105, flags: [])
        XCTAssertFalse(monitor.holdKeyIsDown)
        XCTAssertEqual(released, 1)
    }

    func testHoldKeyIsDownResetsOnStop() {
        let monitor = HotkeyMonitor()
        monitor.handle(type: .keyDown, keyCode: 105, flags: [])
        XCTAssertTrue(monitor.holdKeyIsDown)
        monitor.stop()
        XCTAssertFalse(monitor.holdKeyIsDown)
    }

    // MARK: - HoldKeyReleaseWaiter

    func testHoldKeyReleaseWaiterCompletesEarlyWhenSignalFires() async {
        let start = DispatchTime.now()
        await HoldKeyReleaseWaiter.wait(
            timeout: .seconds(5),
            registerSignal: { signal in
                Task { signal() }
            },
            sleep: { duration in
                // A generous sleep the signal should beat by a wide margin.
                try? await Task.sleep(for: duration)
            }
        )
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(elapsedMS, 1_000)
    }

    func testHoldKeyReleaseWaiterCompletesAtTimeoutWithNoSignal() async {
        let start = DispatchTime.now()
        await HoldKeyReleaseWaiter.wait(
            timeout: .milliseconds(30),
            registerSignal: { _ in
                // No release ever arrives.
            },
            sleep: { duration in try? await Task.sleep(for: duration) }
        )
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        XCTAssertGreaterThanOrEqual(elapsedMS, 25)
    }

    func testHoldKeyReleaseWaiterResumesOnceWhenSignalAndTimeoutRace() async {
        // Both fire; the waiter must still resume exactly once (no hang,
        // no crash from a double continuation resume).
        await HoldKeyReleaseWaiter.wait(
            timeout: .milliseconds(1),
            registerSignal: { signal in
                Task {
                    try? await Task.sleep(for: .milliseconds(1))
                    signal()
                }
            },
            sleep: { duration in try? await Task.sleep(for: duration) }
        )
    }

}
