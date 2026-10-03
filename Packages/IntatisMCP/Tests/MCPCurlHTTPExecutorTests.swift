#if canImport(IntatisCurlTransport)
import Foundation
import IntatisProtocol
import XCTest
@testable import IntatisMCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class MCPCurlHTTPExecutorTests: XCTestCase {
    func testResolveEntriesSortEveryAuthorizedAddressAndBracketIPv6()
        throws
    {
        let entries = try MCPCurlHTTPExecutor.resolveEntries(
            host: "mcp.example.test",
            port: 443,
            addresses: [
                "2001:db8::2",
                "192.0.2.20",
                "192.0.2.10",
            ],
            proxyPolicy: .direct)
        XCTAssertEqual(
            entries,
            [
                "mcp.example.test:443:192.0.2.10,192.0.2.20,[2001:db8::2]"
            ])
        XCTAssertTrue(try MCPCurlHTTPExecutor.resolveEntries(
            host: "mcp.example.test",
            port: 443,
            addresses: ["192.0.2.10"],
            proxyPolicy: .systemConfigured).isEmpty)
    }

    func testSPKIHexPinsConvertToLibcurlStandardBase64Form()
        throws
    {
        let zeroDigest = String(repeating: "00", count: 32)
        let oneDigest = String(repeating: "01", count: 32)
        let rendered = try MCPCurlHTTPExecutor
            .curlPublicKeyPins(
                .pinnedPublicKeySHA256([
                    zeroDigest,
                    oneDigest,
                ]))
        XCTAssertEqual(
            rendered,
            [
                "sha256//\(Data(repeating: 0, count: 32).base64EncodedString())",
                "sha256//\(Data(repeating: 1, count: 32).base64EncodedString())",
            ].joined(separator: ";"))
    }

    func testProductionHTTPBindsLocalhostToAuthorizedSocketAndPreservesHost()
        async throws
    {
        let responseBody =
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}"#
        let server = try makeFixture(
            bindAddress: "127.0.0.1",
            responses: [
                MCPBoundHTTPFixture.response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                    ],
                    body: Data(responseBody.utf8)),
            ])
        server.start()
        let endpoint =
            "http://localhost:\(server.port)/mcp"
        let configuration = try MCPHTTPServerConfiguration(
            endpoint: endpoint,
            allowInsecureLoopbackDevelopmentHTTP: true,
            redirectPolicy: .deny)
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(rawValue: "curl_bound_http"),
            resolver: MCPFixedCurlDNSResolver(
                addresses: ["127.0.0.1"]),
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        await transport.disconnect()
        try await server.waitUntilFinished()

        let requests = server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(
            requests[0].contains(
                "Host: localhost:\(server.port)"))
    }

    func testSameOriginRedirectRepeatsDNSAuthorizationAndSocketBinding()
        async throws
    {
        let responseBody =
            #"{"jsonrpc":"2.0","id":2,"result":{}}"#
        let server = try makeFixture(
            bindAddress: "127.0.0.1",
            responses: [
                MCPBoundHTTPFixture.response(
                    status: 307,
                    headers: ["Location": "/second"],
                    body: Data()),
                MCPBoundHTTPFixture.response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                    ],
                    body: Data(responseBody.utf8)),
            ])
        server.start()
        let resolver = MCPCountingCurlDNSResolver(
            addresses: ["127.0.0.1"])
        let configuration = try MCPHTTPServerConfiguration(
            endpoint:
                "http://localhost:\(server.port)/first",
            allowInsecureLoopbackDevelopmentHTTP: true,
            redirectPolicy: .sameOriginOnly)
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(rawValue: "curl_redirect"),
            resolver: resolver,
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
                .utf8))
        await transport.disconnect()
        try await server.waitUntilFinished()

        let requests = server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].hasPrefix("POST /first "))
        XCTAssertTrue(requests[1].hasPrefix("POST /second "))
        let resolutionCount = await resolver.count()
        XCTAssertEqual(resolutionCount, 3)
    }

    func testOAuthCurlBindsUnresolvableHostAndPreservesOriginalHost()
        async throws
    {
        let server = try makeFixture(
            bindAddress: "127.0.0.1",
            responses: [
                MCPBoundHTTPFixture.response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                    ],
                    body: Data(#"{"ok":true}"#.utf8)),
            ])
        server.start()
        let url = URL(
            string:
                "http://mcp-does-not-resolve.invalid:\(server.port)/oauth")!
        let client = MCPURLSessionOAuthHTTPClient(
            resolver: MCPFixedCurlDNSResolver(
                addresses: ["127.0.0.1"]),
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        let response = try await client.send(
            URLRequest(url: url),
            allowedOrigin:
                "http://mcp-does-not-resolve.invalid:\(server.port)")
        XCTAssertEqual(response.statusCode, 200)
        try await server.waitUntilFinished()

        let requests = server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(
            requests[0].contains(
                "Host: mcp-does-not-resolve.invalid:\(server.port)"))
    }

    func testProductionSSEStopsExactCurlOperationAfterExpectedResponse()
        async throws
    {
        let event =
            #"id: response-3\ndata: {"jsonrpc":"2.0","id":3,"result":{}}\n\n"#
                .replacingOccurrences(
                    of: "\\n",
                    with: "\n")
        let rawResponse = Data(
            """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Connection: keep-alive\r
            \r
            \(event)
            """.utf8)
        let server = try makeFixture(
            bindAddress: "127.0.0.1",
            responses: [rawResponse],
            waitForClientCloseIndices: [0])
        server.start()
        let configuration = try MCPHTTPServerConfiguration(
            endpoint:
                "http://localhost:\(server.port)/sse",
            allowInsecureLoopbackDevelopmentHTTP: true,
            redirectPolicy: .deny)
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(rawValue: "curl_sse_stop"),
            requestTimeoutMilliseconds: 1_000,
            resolver: MCPFixedCurlDNSResolver(
                addresses: ["127.0.0.1"]),
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#
                .utf8))
        await transport.disconnect()
        try await server.waitUntilFinished()
        XCTAssertEqual(server.clientCloseCount(), 1)
    }

    func testProductionCurlCancellationClosesBlockedSSESocket()
        async throws
    {
        let rawResponse = Data(
            """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Connection: keep-alive\r
            \r
            """.utf8)
        let server = try makeFixture(
            bindAddress: "127.0.0.1",
            responses: [rawResponse],
            waitForClientCloseIndices: [0])
        server.start()
        let configuration = try MCPHTTPServerConfiguration(
            endpoint:
                "http://localhost:\(server.port)/cancel",
            allowInsecureLoopbackDevelopmentHTTP: true,
            redirectPolicy: .deny)
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(rawValue: "curl_cancel"),
            requestTimeoutMilliseconds: 2_000,
            resolver: MCPFixedCurlDNSResolver(
                addresses: ["127.0.0.1"]),
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        try await transport.connect()
        let send = Task {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#
                    .utf8))
        }
        try await waitUntil {
            server.requests().count == 1
        }
        send.cancel()
        do {
            try await send.value
            XCTFail("cancelled curl send should fail")
        } catch is CancellationError {
            // Expected exact operation cancellation.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        await transport.disconnect()
        try await server.waitUntilFinished()
        XCTAssertEqual(server.clientCloseCount(), 1)
    }

    func testProductionCurlTimeoutClosesBlockedResponse()
        async throws
    {
        let rawResponse = Data(
            """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Connection: keep-alive\r
            \r
            """.utf8)
        let server = try makeFixture(
            bindAddress: "127.0.0.1",
            responses: [rawResponse],
            waitForClientCloseIndices: [0])
        server.start()
        let configuration = try MCPHTTPServerConfiguration(
            endpoint:
                "http://localhost:\(server.port)/timeout",
            allowInsecureLoopbackDevelopmentHTTP: true,
            redirectPolicy: .deny)
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(rawValue: "curl_timeout"),
            requestTimeoutMilliseconds: 150,
            resolver: MCPFixedCurlDNSResolver(
                addresses: ["127.0.0.1"]),
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        try await transport.connect()
        let started = Date()
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#
                    .utf8))
            XCTFail("blocked curl response should time out")
        } catch {
            XCTAssertLessThan(
                Date().timeIntervalSince(started),
                2)
        }
        await transport.disconnect()
        try await server.waitUntilFinished()
        XCTAssertEqual(server.clientCloseCount(), 1)
    }

    func testOAuthDirectProxyTrapIsCaseInsensitiveAndSystemModeIsExplicit()
        throws
    {
        for key in [
            "HTTP_PROXY",
            "http_proxy",
            "Https_Proxy",
            "ALL_proxy",
            "No_PrOxY",
        ] {
            XCTAssertThrowsError(
                try MCPURLSessionOAuthHTTPClient
                    .validateAmbientProxyEnvironment(
                        [key: "http://proxy.invalid"],
                        proxyPolicy: .direct,
                        foundationNetworkingBacked: true)
            ) { error in
                XCTAssertEqual(
                    error as? MCPHTTPTransportError,
                    .ambientProxyDenied)
            }
        }
        XCTAssertNoThrow(
            try MCPURLSessionOAuthHTTPClient
                .validateAmbientProxyEnvironment(
                    ["HTTPS_PROXY": "http://proxy.invalid"],
                    proxyPolicy: .systemConfigured,
                    foundationNetworkingBacked: true))
    }

    func testOAuthURLSessionTestSeamCancelsChunkedBodyAtHardCap()
        async throws
    {
        let path = "/oauth-body-cap-\(UUID().uuidString)"
        MCPOAuthChunkURLProtocol.install(
            path: path,
            headers: ["Content-Type": "application/json"],
            chunks: [
                Data(repeating: 0x61, count: 800),
                Data(repeating: 0x62, count: 800),
                Data(repeating: 0x63, count: 800),
            ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            MCPOAuthChunkURLProtocol.self,
        ]
        let client = MCPURLSessionOAuthHTTPClient(
            resolver: MCPFixedCurlDNSResolver(
                // The URLProtocol seam prevents any socket use. Keep the
                // preflight address in a public range so this body-limit test
                // does not intentionally trip the production TEST-NET deny.
                addresses: ["93.184.216.34"]),
            testingSessionConfiguration: configuration,
            maximumBodyBytes: 1_024)
        let url = URL(
            string: "https://oauth.example.test\(path)")!
        do {
            _ = try await client.send(
                URLRequest(url: url),
                allowedOrigin:
                    "https://oauth.example.test:443")
            XCTFail("oversized OAuth body should fail")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .responseTooLarge)
        }
        try await waitUntil {
            MCPOAuthChunkURLProtocol.wasStopped(path: path)
        }
        XCTAssertLessThan(
            MCPOAuthChunkURLProtocol.deliveredChunks(path: path),
            3)
    }

    func testOAuthURLSessionTestSeamRejectsHeadersBeforeBody()
        async throws
    {
        let path = "/oauth-header-cap-\(UUID().uuidString)"
        MCPOAuthChunkURLProtocol.install(
            path: path,
            headers: [
                "Content-Type": "application/json",
                "X-Oversized": String(
                    repeating: "h",
                    count: 2_048),
            ],
            chunks: [Data(#"{"never":true}"#.utf8)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            MCPOAuthChunkURLProtocol.self,
        ]
        let client = MCPURLSessionOAuthHTTPClient(
            resolver: MCPFixedCurlDNSResolver(
                // The URLProtocol seam prevents any socket use. Keep the
                // preflight address in a public range so this header-limit
                // test exercises the response boundary, not TEST-NET policy.
                addresses: ["93.184.216.34"]),
            testingSessionConfiguration: configuration,
            maximumHeaderBytes: 1_024)
        let url = URL(
            string: "https://oauth.example.test\(path)")!
        do {
            _ = try await client.send(
                URLRequest(url: url),
                allowedOrigin:
                    "https://oauth.example.test:443")
            XCTFail("oversized OAuth headers should fail")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .responseTooLarge)
        }
        try await waitUntil {
            MCPOAuthChunkURLProtocol.wasStopped(path: path)
        }
        XCTAssertEqual(
            MCPOAuthChunkURLProtocol.deliveredChunks(path: path),
            0)
    }

    private func makeFixture(
        bindAddress: String,
        responses: [Data],
        waitForClientCloseIndices: Set<Int> = []
    ) throws -> MCPBoundHTTPFixture {
        do {
            return try MCPBoundHTTPFixture(
                bindAddress: bindAddress,
                responses: responses,
                waitForClientCloseIndices:
                    waitForClientCloseIndices)
        } catch MCPBoundHTTPFixtureError.bindFailed(let code)
            where code == EPERM {
            throw XCTSkip(
                "The test host sandbox denies loopback bind; run this E2E on a socket-capable macOS/Linux runner.")
        }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(
                nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true")
    }
}

private struct MCPFixedCurlDNSResolver: MCPDNSResolving {
    let addresses: Set<String>

    func addresses(
        for _: String,
        port _: Int
    ) async throws -> Set<String> {
        addresses
    }
}

private actor MCPCountingCurlDNSResolver: MCPDNSResolving {
    let addresses: Set<String>
    private var calls = 0

    init(addresses: Set<String>) {
        self.addresses = addresses
    }

    func addresses(
        for _: String,
        port _: Int
    ) -> Set<String> {
        calls += 1
        return addresses
    }

    func count() -> Int { calls }
}

private final class MCPBoundHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let responses: [Data]
    private let waitForClientCloseIndices: Set<Int>
    private var recordedRequests: [String] = []
    private var observedClientCloses = 0
    private var serverError: Error?
    private var task: Task<Void, Never>?
    let port: Int

    init(
        bindAddress: String,
        responses: [Data],
        waitForClientCloseIndices: Set<Int> = []
    ) throws {
        guard !responses.isEmpty else {
            throw MCPBoundHTTPFixtureError.invalidFixture
        }
        let descriptor = mcpTestSocket()
        guard descriptor >= 0 else {
            throw MCPBoundHTTPFixtureError.socketFailed
        }
        self.descriptor = descriptor
        self.responses = responses
        self.waitForClientCloseIndices =
            waitForClientCloseIndices
        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        guard inet_pton(
            AF_INET,
            bindAddress,
            &address.sin_addr) == 1 else {
            mcpTestClose(descriptor)
            throw MCPBoundHTTPFixtureError.invalidFixture
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0,
              listen(descriptor, 8) == 0 else {
            mcpTestClose(descriptor)
            throw MCPBoundHTTPFixtureError.bindFailed(
                errno)
        }
        var bound = sockaddr_in()
        var boundLength = socklen_t(
            MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(
            to: &bound
        ) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(
                    descriptor,
                    $0,
                    &boundLength)
            }
        }
        guard nameResult == 0 else {
            mcpTestClose(descriptor)
            throw MCPBoundHTTPFixtureError.bindFailed(
                errno)
        }
        port = Int(in_port_t(bigEndian: bound.sin_port))
    }

    deinit {
        task?.cancel()
        mcpTestClose(descriptor)
    }

    func start() {
        task = Task.detached { [self] in
            do {
                for (index, response) in responses.enumerated() {
                    let accepted = accept(
                        descriptor,
                        nil,
                        nil)
                    guard accepted >= 0 else {
                        throw MCPBoundHTTPFixtureError
                            .acceptFailed
                    }
                    defer { mcpTestClose(accepted) }
                    let request = try Self.readRequest(
                        descriptor: accepted)
                    lock.withLock {
                        recordedRequests.append(request)
                    }
                    try Self.writeAll(
                        response,
                        descriptor: accepted)
                    if waitForClientCloseIndices
                        .contains(index)
                    {
                        try Self.waitForClientClose(
                            descriptor: accepted)
                        lock.withLock {
                            observedClientCloses += 1
                        }
                    }
                }
            } catch {
                lock.withLock {
                    serverError = error
                }
            }
        }
    }

    func requests() -> [String] {
        lock.withLock { recordedRequests }
    }

    func clientCloseCount() -> Int {
        lock.withLock { observedClientCloses }
    }

    func waitUntilFinished() async throws {
        guard let task else {
            throw MCPBoundHTTPFixtureError.invalidFixture
        }
        await task.value
        if let error = lock.withLock({ serverError }) {
            throw error
        }
    }

    static func response(
        status: Int,
        headers: [String: String],
        body: Data
    ) -> Data {
        var lines = [
            "HTTP/1.1 \(status) \(reason(status))",
        ]
        for (name, value) in headers.sorted(
            by: { $0.key < $1.key })
        {
            lines.append("\(name): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 307: return "Temporary Redirect"
        default: return "Response"
        }
    }

    private static func readRequest(
        descriptor: Int32
    ) throws -> String {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        while data.count < 1_024 * 1_024 {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = recv(
                descriptor,
                &buffer,
                buffer.count,
                0)
            guard count > 0 else {
                throw MCPBoundHTTPFixtureError.readFailed
            }
            data.append(buffer, count: count)
            if headerEnd == nil,
               let range = data.range(
                of: Data("\r\n\r\n".utf8))
            {
                headerEnd = range
                let headerText = String(
                    decoding: data[..<range.upperBound],
                    as: UTF8.self)
                contentLength = headerText
                    .split(separator: "\n")
                    .first(where: {
                        $0.lowercased().hasPrefix(
                            "content-length:")
                    })
                    .flatMap {
                        Int($0.split(separator: ":",
                            maxSplits: 1)[1]
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines))
                    } ?? 0
            }
            if let headerEnd,
               data.count >= headerEnd.upperBound
                    + contentLength {
                return String(decoding: data, as: UTF8.self)
            }
        }
        throw MCPBoundHTTPFixtureError.readFailed
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = send(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset,
                    0)
                guard count > 0 else {
                    throw MCPBoundHTTPFixtureError
                        .writeFailed
                }
                offset += count
            }
        }
    }

    private static func waitForClientClose(
        descriptor: Int32
    ) throws {
        var byte: UInt8 = 0
        while true {
            let count = recv(
                descriptor,
                &byte,
                1,
                0)
            if count == 0 { return }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw MCPBoundHTTPFixtureError.readFailed
            }
        }
    }
}

private enum MCPBoundHTTPFixtureError: Error {
    case invalidFixture
    case socketFailed
    case bindFailed(Int32)
    case acceptFailed
    case readFailed
    case writeFailed
}

private final class MCPOAuthChunkURLProtocol:
    URLProtocol, @unchecked Sendable
{
    private struct Script {
        let headers: [String: String]
        let chunks: [Data]
    }

    private static let lock = NSLock()
    private static var scripts: [String: Script] = [:]
    private static var stopped: Set<String> = []
    private static var delivered: [String: Int] = [:]

    private let stateLock = NSLock()
    private var cancelled = false

    static func install(
        path: String,
        headers: [String: String],
        chunks: [Data]
    ) {
        lock.withLock {
            scripts[path] = Script(
                headers: headers,
                chunks: chunks)
            stopped.remove(path)
            delivered[path] = 0
        }
    }

    static func wasStopped(path: String) -> Bool {
        lock.withLock { stopped.contains(path) }
    }

    static func deliveredChunks(path: String) -> Int {
        lock.withLock { delivered[path] ?? 0 }
    }

    override class func canInit(
        with _: URLRequest
    ) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let script = Self.lock.withLock({
                  Self.scripts[url.path]
              }),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: script.headers) else {
            client?.urlProtocol(
                self,
                didFailWithError:
                    URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed)
        deliver(
            script.chunks,
            path: url.path,
            index: 0)
    }

    override func stopLoading() {
        stateLock.withLock {
            cancelled = true
        }
        if let path = request.url?.path {
            Self.lock.withLock {
                _ = Self.stopped.insert(path)
            }
        }
    }

    private func deliver(
        _ chunks: [Data],
        path: String,
        index: Int
    ) {
        DispatchQueue.global().asyncAfter(
            deadline: .now() + 0.02
        ) { [self] in
            guard !stateLock.withLock({
                cancelled
            }) else {
                return
            }
            guard index < chunks.count else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            Self.lock.withLock {
                Self.delivered[path, default: 0] += 1
            }
            client?.urlProtocol(
                self,
                didLoad: chunks[index])
            deliver(
                chunks,
                path: path,
                index: index + 1)
        }
    }
}

private func mcpTestSocket() -> Int32 {
    #if canImport(Darwin)
    return Darwin.socket(AF_INET, SOCK_STREAM, 0)
    #elseif canImport(Glibc)
    return Glibc.socket(
        AF_INET,
        Int32(SOCK_STREAM.rawValue),
        0)
    #endif
}

private func mcpTestClose(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #elseif canImport(Glibc)
    _ = Glibc.close(descriptor)
    #endif
}
#endif
