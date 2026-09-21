import Foundation
import Darwin

private struct EngineEnvelope: Decodable {
    let error: EngineError?
}

actor EngineClient {
    private let path: String
    private var nextID = 1

    init(path: String = NSString(string: "~/.undertone/engine.sock").expandingTildeInPath) { self.path = path }

    func request(op: String, fields: [String: JSONValue] = [:]) throws -> EngineResponse {
        var payload = fields
        payload["op"] = .string(op)
        let requestID = nextID
        payload["id"] = .number(Double(requestID))
        nextID += 1
        let data = try JSONEncoder().encode(payload)
        let fd = try connect()
        defer { Darwin.close(fd) }
        var readBuffer = Data()
        var line = data
        line.append(10)
        try writeAll(fd, line)
        let responseData = try readLine(fd, buffer: &readBuffer)
        let response = try decodeResponse(responseData, requestID: requestID)
        return response
    }

    func requestStream(
        op: String,
        fields: [String: JSONValue] = [:],
        onChunk: @Sendable (String) async -> Void
    ) async throws -> EngineResponse {
        var payload = fields
        payload["op"] = .string(op)
        let requestID = nextID
        payload["id"] = .number(Double(requestID))
        nextID += 1
        let data = try JSONEncoder().encode(payload)
        let fd = try connect()
        defer { Darwin.close(fd) }
        var readBuffer = Data()
        var line = data
        line.append(10)
        try writeAll(fd, line)
        while true {
            let responseData = try readLine(fd, buffer: &readBuffer)
            let response = try decodeResponse(responseData, requestID: requestID)
            if let chunk = response.chunk {
                await onChunk(chunk)
            }
            if response.done == true { return response }
        }
    }

    private func decodeResponse(_ data: Data, requestID: Int) throws -> EngineResponse {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(EngineEnvelope.self, from: data)
        if let error = envelope.error {
            if error.code == "busy" { throw EngineClientError.system("engine is busy") }
            throw EngineClientError.remote(error.code, error.message)
        }
        let response = try decoder.decode(EngineResponse.self, from: data)
        guard response.id == requestID else {
            throw EngineClientError.protocolViolation("response id \(response.id) did not match request \(requestID)")
        }
        return response
    }

    /// Saves an edited title, notes, or summary. Only the given fields change.
    func meetingUpdate(sessionID: String, title: String? = nil,
                       notes: String? = nil, summary: String? = nil) throws -> EngineResponse {
        var fields: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let title { fields["title"] = .string(title) }
        if let notes { fields["notes"] = .string(notes) }
        if let summary { fields["summary"] = .string(summary) }
        return try request(op: "meeting.update", fields: fields)
    }

    /// Asks the engine to write the summary again for a finished meeting.
    func meetingSummarize(sessionID: String) throws -> EngineResponse {
        try request(op: "meeting.summarize", fields: ["session_id": .string(sessionID)])
    }

    /// Each NDJSON request gets one fresh connection. The local server may
    /// close an idle connection after 30 seconds, and keeping a descriptor
    /// across requests can leave the next request writing to a stale socket.
    /// There is deliberately no automatic retry: an uncertain mutating request
    /// must never replay.
    private func connect() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineClientError.system("socket: \(String(cString: strerror(errno)))") }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw EngineClientError.system("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno)); Darwin.close(fd)
            throw EngineClientError.system("connect: \(message)")
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw EngineClientError.system("write: \(String(cString: strerror(errno)))") }
                offset += count
            }
        }
    }

    private func readLine(_ fd: Int32, buffer: inout Data) throws -> Data {
        while true {
            if let index = buffer.firstIndex(of: 10) {
                let result = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                return Data(result)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw EngineClientError.system("engine closed the socket") }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 8 * 1024 * 1024 else { throw EngineClientError.system("engine response exceeds 8 MB") }
        }
    }
}

enum EngineClientError: LocalizedError {
    case system(String)
    case remote(String, String)
    case protocolViolation(String)

    var isRetryableRecoveryFailure: Bool {
        switch self {
        case .system:
            return true
        case .remote(let code, _):
            return code == "engine_error"
        case .protocolViolation:
            return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .system(let message): return message
        case .remote(let code, let message): return "\(code): \(message)"
        case .protocolViolation(let message): return message
        }
    }
}
