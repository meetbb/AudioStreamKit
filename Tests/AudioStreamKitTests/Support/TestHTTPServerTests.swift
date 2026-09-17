//
//  TestHTTPServerTests.swift
//  AudioStreamKitTests
//

import XCTest

// Smoke tests for the test harness itself, not for AudioStreamKit — verifies TestHTTPServer's
// range/revalidation/failure-injection behavior is trustworthy before other tests build on it.
final class TestHTTPServerTests: XCTestCase {

    private func makeServer(body: Data, etag: String? = nil, lastModified: String? = nil) async throws -> (TestHTTPServer, URL) {
        let server = TestHTTPServer()
        try await server.start()
        await server.setResource(
            .init(body: body, etag: etag, lastModified: lastModified),
            at: "/track.mp3"
        )
        let port = await server.port
        let url = URL(string: "http://127.0.0.1:\(port)/track.mp3")!
        return (server, url)
    }

    func testFullGETReturnsWholeBody() async throws {
        let body = Data("0123456789".utf8)
        let (server, url) = try await makeServer(body: body)
        defer { Task { await server.stop() } }

        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, body)
    }

    func testRangeRequestReturnsPartialContent() async throws {
        let body = Data("0123456789".utf8)
        let (server, url) = try await makeServer(body: body)
        defer { Task { await server.stop() } }

        var request = URLRequest(url: url)
        request.setValue("bytes=2-4", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, Data("234".utf8))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 2-4/10")
    }

    func testConditionalRequestWithMatchingETagReturns304() async throws {
        let body = Data("0123456789".utf8)
        let (server, url) = try await makeServer(body: body, etag: "abc123")
        defer { Task { await server.stop() } }

        var request = URLRequest(url: url)
        request.setValue("abc123", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 304)
    }

    func testForcedStatusBehaviorAppliesOnceThenResets() async throws {
        let body = Data("0123456789".utf8)
        let (server, url) = try await makeServer(body: body)
        defer { Task { await server.stop() } }

        await server.setBehavior(.status(500))
        let (_, firstResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((firstResponse as! HTTPURLResponse).statusCode, 500)

        let (_, secondResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((secondResponse as! HTTPURLResponse).statusCode, 200)
    }

    func testUnknownPathReturns404() async throws {
        let (server, url) = try await makeServer(body: Data())
        defer { Task { await server.stop() } }

        let missing = url.deletingLastPathComponent().appendingPathComponent("missing.mp3")
        let (_, response) = try await URLSession.shared.data(from: missing)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 404)
    }
}
