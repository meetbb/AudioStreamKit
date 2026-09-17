//
//  TestHTTPServer.swift
//  AudioStreamKitTests
//

import Foundation
import Network

/// Hand-rolled loopback HTTP/1.1 server for exercising `MediaSource`'s real network path
/// (range requests, revalidation, retry) in tests without a third-party dependency or a real
/// remote asset. Test-only — not part of the `AudioStreamKit` library target.
///
/// Understands just enough HTTP/1.1 to serve our own client's traffic: `GET`/`HEAD`, `Range`,
/// `If-None-Match`/`If-Modified-Since`. Every response closes the connection immediately
/// rather than supporting keep-alive/pipelining, since `MediaSource` issues one request per
/// connection via `URLSession.data(for:)`.
actor TestHTTPServer {

    struct Resource {
        var body: Data
        var mimeType: String = "audio/mpeg"
        var etag: String?
        var lastModified: String?
    }

    /// A one-shot override applied to the next request only, then reset to `.normal`. Lets a
    /// test deterministically trigger a stall/retry or a hard failure instead of depending on
    /// real network flakiness.
    enum Behavior {
        case normal
        case delay(TimeInterval)
        case status(Int)
        case dropConnection
    }

    private var listener: NWListener?
    private var resources: [String: Resource] = [:]
    private var behavior: Behavior = .normal
    private var behaviorIsSticky = false
    private(set) var requestCount = 0

    private(set) var port: UInt16 = 0

    init() {}

    /// Binds an ephemeral loopback port and starts accepting connections. `port` is valid once
    /// this returns.
    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { await self?.handle(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }

        guard let boundPort = listener.port else {
            throw TestHTTPServerError.noPortAssigned
        }
        port = boundPort.rawValue
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func setResource(_ resource: Resource, at path: String) {
        resources[path] = resource
    }

    /// Applies to the very next request this server handles, then resets to `.normal` —
    /// unless `sticky` is `true`, in which case it keeps applying to every request until
    /// explicitly changed. Sticky is for simulating an origin that's down across an entire
    /// retry loop; one-shot is for a single transient hiccup a retry should recover from.
    func setBehavior(_ behavior: Behavior, sticky: Bool = false) {
        self.behavior = behavior
        self.behaviorIsSticky = sticky
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) async {
        requestCount += 1
        let currentBehavior = behavior
        if !behaviorIsSticky {
            behavior = .normal
        }

        if case .dropConnection = currentBehavior {
            connection.cancel()
            return
        }
        if case .delay(let seconds) = currentBehavior {
            try? await Task.sleep(for: .seconds(seconds))
        }

        guard let request = await readRequest(from: connection) else {
            connection.cancel()
            return
        }

        if case .status(let code) = currentBehavior {
            await send(HTTPResponseBuilder.build(status: code, headers: [:], body: nil), on: connection)
            connection.cancel()
            return
        }

        await respond(to: request, on: connection)
        connection.cancel()
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        guard let resource = resources[request.path] else {
            await send(HTTPResponseBuilder.build(status: 404, headers: [:], body: nil), on: connection)
            return
        }

        if request.headers["Range"] == nil,
           notModified(request: request, resource: resource) {
            await send(HTTPResponseBuilder.build(status: 304, headers: [:], body: nil), on: connection)
            return
        }

        var headers: [String: String] = [
            "Accept-Ranges": "bytes",
            "Content-Type": resource.mimeType
        ]
        if let etag = resource.etag { headers["ETag"] = etag }
        if let lastModified = resource.lastModified { headers["Last-Modified"] = lastModified }

        let includeBody = request.method == "GET"

        if let rangeHeader = request.headers["Range"], let range = parseRange(rangeHeader, totalLength: resource.body.count) {
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(resource.body.count)"
            headers["Content-Length"] = "\(range.count)"
            let slice = resource.body.subdata(in: range)
            await send(HTTPResponseBuilder.build(status: 206, headers: headers, body: includeBody ? slice : nil), on: connection)
            return
        }

        headers["Content-Length"] = "\(resource.body.count)"
        await send(HTTPResponseBuilder.build(status: 200, headers: headers, body: includeBody ? resource.body : nil), on: connection)
    }

    private func notModified(request: HTTPRequest, resource: Resource) -> Bool {
        if let inm = request.headers["If-None-Match"], let etag = resource.etag {
            return inm == etag
        }
        if let ims = request.headers["If-Modified-Since"], let lastModified = resource.lastModified {
            return ims == lastModified
        }
        return false
    }

    private func parseRange(_ header: String, totalLength: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int(parts[0]) else { return nil }
        let upperExclusive: Int
        if let upper = Int(parts[1]) {
            upperExclusive = min(upper + 1, totalLength)
        } else {
            upperExclusive = totalLength
        }
        guard lower >= 0, lower < upperExclusive else { return nil }
        return lower..<upperExclusive
    }

    // MARK: - Raw socket I/O

    private func readRequest(from connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.range(of: terminator) {
                return HTTPRequest.parse(buffer[..<range.lowerBound])
            }
            guard let chunk = await receive(connection), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if buffer.count > 16_384 { return nil }
        }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

enum TestHTTPServerError: Error {
    case noPortAssigned
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    static func parse(_ headerData: Data) -> HTTPRequest? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers)
    }
}

private enum HTTPResponseBuilder {
    static func build(status: Int, headers: [String: String], body: Data?) -> Data {
        var response = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        if body == nil, headers["Content-Length"] == nil {
            response += "Content-Length: 0\r\n"
        }
        response += "Connection: close\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
