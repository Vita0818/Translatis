import Foundation
@testable import IntatisMCP
import IntatisProtocol
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MCPStreamableHTTPTests: XCTestCase {
    override func tearDown() {
        MCPMockURLProtocol.reset()
        super.tearDown()
    }

    func testPOSTJSONSessionProtocolHeaderAndNoCookies() async throws {
        let recorder = MCPRequestRecorder()
        let redactor = MCPResolvedSecretRedactor()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                return .response(status: 405)
            }
            let posts = recorder.requests.filter {
                $0.httpMethod == "POST"
            }
            if posts.count == 1 {
                return .response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "opaque-session",
                        "Set-Cookie": "ambient=forbidden",
                    ],
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            }
            return .response(
                status: 202,
                headers: ["Content-Type": "application/json"])
        }

        let transport = try makeTransport(
            secretRedactionRegistrar:
                redactor)
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        try await transport.updateNegotiatedProtocolVersion(
            "2025-11-25")
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
                .utf8))

        let posts = recorder.requests.filter {
            $0.httpMethod == "POST"
        }
        XCTAssertEqual(posts.count, 2)
        XCTAssertNil(
            posts[0].value(
                forHTTPHeaderField: "MCP-Protocol-Version"))
        XCTAssertEqual(
            posts[1].value(
                forHTTPHeaderField: "MCP-Protocol-Version"),
            "2025-11-25")
        XCTAssertEqual(
            posts[1].value(
                forHTTPHeaderField: "MCP-Session-Id"),
            "opaque-session")
        XCTAssertNil(posts[1].value(forHTTPHeaderField: "Cookie"))
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.hasSession)
        let sanitized =
            try redactor.sanitizeMCPText(
                "session=opaque-session")
        XCTAssertFalse(
            sanitized.contains(
                "opaque-session"))
        await transport.disconnect()
    }

    func testSSEErrorCannotRaceSessionIdentifierExactRegistration()
        async throws
    {
        let sessionIdentifier =
            "opaque-sse-session-identifier"
        let redactor = MCPResolvedSecretRedactor()
        let registrationFence =
            MCPSecretRegistrationFence(
                expected: sessionIdentifier,
                redactor: redactor)
        MCPMockURLProtocol.setHandler {
            request in
            guard request.httpMethod == "POST" else {
                return .response(status: 405)
            }
            let requestObject =
                try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with:
                            try mcpHTTPBody(
                                request))
                        as? [String: Any])
            let requestID =
                try XCTUnwrap(
                    requestObject["id"])
            let responseData =
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": requestID,
                        "error": [
                            "code": -32_091,
                            "message":
                                "server echoed \(sessionIdentifier)",
                        ],
                    ],
                    options: [.sortedKeys])
            var frame = Data("data: ".utf8)
            frame.append(responseData)
            frame.append(Data("\n\n".utf8))
            return .responseAfterRegistration(
                status: 200,
                headers: [
                    "Content-Type":
                        "text/event-stream",
                    "MCP-Session-Id":
                        sessionIdentifier,
                ],
                chunks: [frame],
                waitForRegistration: {
                    registrationFence
                        .waitForExpectedRegistration()
                })
        }

        let generation =
            MCPConnectionGeneration(
                rawValue:
                    "mcpcnx_sse_session_redaction")
        let transport = try makeTransport(
            generation: generation,
            secretRedactionRegistrar:
                registrationFence)
        let session = MCPClientSession(
            configuration:
                MCPClientSessionConfiguration(
                    server:
                        MCPServerReference(
                            serverID:
                                MCPServerID(
                                    rawValue:
                                        "sse-session-redaction"),
                            serverRevision:
                                MCPServerRevision(
                                    rawValue:
                                        "mcprev_sse_session_redaction")),
                    generation: generation,
                    profile: .standardExtended,
                    startupTimeoutMilliseconds:
                        3_000,
                    callTimeoutMilliseconds:
                        1_000,
                    clientVersion: "test",
                    outputSanitizer: redactor),
            transport: transport)

        do {
            _ = try await session.start()
            XCTFail(
                "malicious SSE initialize response must fail")
        } catch let error
            as MCPSanitizedExternalError {
            XCTAssertEqual(
                error.operation,
                "initialize")
            XCTAssertEqual(
                error.category,
                .jsonRPC)
            XCTAssertEqual(
                error.jsonRPCCode,
                -32_091)
            XCTAssertFalse(
                error.localizedDescription
                    .contains(sessionIdentifier))
            XCTAssertTrue(
                error.localizedDescription
                    .contains("[REDACTED]"))
        } catch {
            await session.shutdown()
            throw error
        }
        XCTAssertTrue(
            registrationFence
                .didRegisterExpectedValue)
        await session.shutdown()
    }

    func testPOSTSSEHasPerStreamDeduplication() async throws {
        MCPMockURLProtocol.setHandler { request in
            if request.httpMethod == "GET" {
                return .response(status: 405)
            }
            return .response(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [
                    Data("id: 1\ndata: {\"one\":1}\n\n".utf8),
                    Data("id: 1\ndata: {\"one\":1}\n\n".utf8),
                    Data("id: 2\ndata: {\"two\":2}\n\n".utf8),
                ])
        }
        let transport = try makeTransport()
        try await transport.connect()
        let stream = await transport.receive()
        let collector = Task {
            var values: [String] = []
            for try await data in stream {
                values.append(String(decoding: data, as: UTF8.self))
                if values.count == 2 { break }
            }
            return values
        }
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        let values = try await collector.value
        XCTAssertEqual(values, ["{\"one\":1}", "{\"two\":2}"])
        await transport.disconnect()
    }

    func testGETResumeUsesOnlyGETStreamLastEventID() async throws {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            switch request.httpMethod {
            case "POST":
                return .response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "resume-session",
                    ],
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            case "GET":
                let getCount = recorder.requests.filter {
                    $0.httpMethod == "GET"
                }.count
                if getCount == 1 {
                    return .response(
                        status: 200,
                        headers: ["Content-Type": "text/event-stream"],
                        body: Data(
                            "id: get-event-1\nretry: 10\ndata: {\"method\":\"notifications/progress\"}\n\n"
                                .utf8))
                }
                return .response(status: 405)
            default:
                return .response(status: 405)
            }
        }

        let limits = MCPHTTPTransportLimits(
            minimumRetryMilliseconds: 10,
            maximumRetryMilliseconds: 20)
        let transport = try makeTransport(limits: limits)
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        try await transport.updateNegotiatedProtocolVersion(
            "2025-11-25")

        try await eventually {
            recorder.requests.filter { $0.httpMethod == "GET" }.count >= 2
        }
        let gets = recorder.requests.filter { $0.httpMethod == "GET" }
        XCTAssertNil(
            gets[0].value(forHTTPHeaderField: "Last-Event-ID"))
        XCTAssertEqual(
            gets[1].value(forHTTPHeaderField: "Last-Event-ID"),
            "get-event-1")
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.getStreamSupport, .unsupported)
        await transport.disconnect()
    }

    func testPOSTSSEDisconnectResumesByGETWithoutReplayingPOST()
        async throws
    {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                if request.value(
                    forHTTPHeaderField: "Last-Event-ID") == "post-1"
                {
                    return .response(
                        status: 200,
                        headers: ["Content-Type": "text/event-stream"],
                        body: Data(
                            "id: post-2\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n\n"
                                .utf8))
                }
                return .response(status: 405)
            }
            let postCount = recorder.requests.filter {
                $0.httpMethod == "POST"
            }.count
            if postCount == 1 {
                return .response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "post-resume-session",
                    ],
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            }
            return .responseThenFailure(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [
                    Data(
                        "id: post-1\nretry: 10\ndata: {\"method\":\"notifications/progress\"}\n\n"
                            .utf8)
                ],
                error: URLError(.networkConnectionLost))
        }
        let transport = try makeTransport(
            limits: MCPHTTPTransportLimits(
                minimumRetryMilliseconds: 10,
                maximumRetryMilliseconds: 20))
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        try await transport.updateNegotiatedProtocolVersion(
            "2025-11-25")
        try await eventually {
            let snapshot = recorder.requests
            return snapshot.contains {
                $0.httpMethod == "GET"
                    && $0.value(
                        forHTTPHeaderField: "Last-Event-ID") == nil
            }
        }
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write"}}"#
                    .utf8))
        } catch {
            let trace = recorder.requests.map {
                "\($0.httpMethod ?? "?") last=\($0.value(forHTTPHeaderField: "Last-Event-ID") ?? "-")"
            }.joined(separator: ", ")
            XCTFail("unexpected send failure \(error); requests: \(trace)")
            throw error
        }

        let requests = recorder.requests
        XCTAssertEqual(
            requests.filter { $0.httpMethod == "POST" }.count,
            2,
            "the original tools/call POST must not be replayed")
        let resumed = requests.filter {
            $0.httpMethod == "GET"
                && $0.value(
                    forHTTPHeaderField: "Last-Event-ID") == "post-1"
        }
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(
            resumed[0].value(
                forHTTPHeaderField: "MCP-Session-Id"),
            "post-resume-session")
        await transport.disconnect()
    }

    func testGracefullyClosedPOSTSSERespectsRetryAndResumesExactResponse()
        async throws
    {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                if request.value(
                    forHTTPHeaderField: "Last-Event-ID") == "graceful-1"
                {
                    return .response(
                        status: 200,
                        headers: ["Content-Type": "text/event-stream"],
                        body: Data(
                            "id: graceful-2\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[]}}\n\n"
                                .utf8))
                }
                return .response(status: 405)
            }
            let postCount = recorder.requests.filter {
                $0.httpMethod == "POST"
            }.count
            if postCount == 1 {
                return .response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "graceful-session",
                    ],
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            }
            return .response(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    "id: graceful-1\nretry: 50\ndata: \n\n".utf8))
        }
        let transport = try makeTransport(
            limits: MCPHTTPTransportLimits(
                minimumRetryMilliseconds: 50,
                maximumRetryMilliseconds: 50))
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        try await transport.updateNegotiatedProtocolVersion(
            "2025-11-25")

        let start = DispatchTime.now().uptimeNanoseconds
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"long"}}"#
                .utf8))
        let elapsedMilliseconds =
            (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 45)
        XCTAssertEqual(
            recorder.requests.filter { $0.httpMethod == "POST" }.count,
            2,
            "graceful SSE recovery must never replay tools/call")
        let resumed = recorder.requests.filter {
            $0.httpMethod == "GET"
                && $0.value(
                    forHTTPHeaderField: "Last-Event-ID")
                    == "graceful-1"
        }
        XCTAssertEqual(resumed.count, 1)
        await transport.disconnect()
    }

    func testSession404RetiresGenerationWithoutToolReplay() async throws {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            if request.httpMethod == "GET" {
                return .response(status: 405)
            }
            let postCount = recorder.requests.filter {
                $0.httpMethod == "POST"
            }.count
            if postCount == 1 {
                return .response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "expiring",
                    ],
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            }
            return .response(status: 404)
        }

        let generation = MCPConnectionGeneration(
            rawValue: "mcpcnx_test_404")
        let transport = try makeTransport(generation: generation)
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        try await transport.updateNegotiatedProtocolVersion(
            "2025-11-25")

        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"charge"}}"#
                    .utf8))
            XCTFail("Expected uncertain session expiry")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(
                error,
                .sessionExpiredAfterUncertainExecution(
                    generation: generation,
                    method: "tools/call"))
        }
        XCTAssertEqual(
            recorder.requests.filter { $0.httpMethod == "POST" }.count,
            2,
            "sent tools/call must never be replayed")
        let retiredSnapshot = await transport.snapshot()
        XCTAssertTrue(retiredSnapshot.retired)
        await transport.disconnect()
    }

    func testNetworkFailureAfterToolDispatchIsUncertainAndNotRetried()
        async throws
    {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            return .failure(URLError(.networkConnectionLost))
        }
        let transport = try makeTransport()
        try await transport.connect()
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"write"}}"#
                    .utf8))
            XCTFail("Expected uncertain result")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(
                error,
                .executionUncertain(method: "tools/call"))
        }
        XCTAssertEqual(recorder.requests.count, 1)
        await transport.disconnect()
    }

    func testAuthorizationChallengeNeverReplaysDispatchedToolCall()
        async throws
    {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            return .response(
                status: 403,
                headers: [
                    "WWW-Authenticate":
                        #"Bearer error="insufficient_scope", scope="write:item", resource_metadata="https://mcp.example.test/prm""#
                ])
        }
        let transport = try makeTransport()
        try await transport.connect()
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"charge"}}"#
                    .utf8))
            XCTFail("Expected explicit authorization challenge")
        } catch let error as MCPHTTPTransportError {
            guard case .authenticationRequired(let challenge) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(challenge.requiredScopes, ["write:item"])
            XCTAssertEqual(
                challenge.resourceMetadataURL?.absoluteString,
                "https://mcp.example.test/prm")
            XCTAssertTrue(challenge.sideEffectsUncertain)
        }
        XCTAssertEqual(recorder.requests.count, 1)
        await transport.disconnect()
    }

    func testDELETEUsesSessionAnd405StillClosesLocally() async throws {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            switch request.httpMethod {
            case "POST":
                return .response(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "delete-session",
                    ],
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            case "DELETE", "GET":
                return .response(status: 405)
            default:
                return .response(status: 400)
            }
        }
        let transport = try makeTransport()
        try await transport.connect()
        try await transport.send(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
                .utf8))
        try await transport.updateNegotiatedProtocolVersion(
            "2025-11-25")
        await transport.disconnect()

        let deletes = recorder.requests.filter {
            $0.httpMethod == "DELETE"
        }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(
            deletes[0].value(
                forHTTPHeaderField: "MCP-Session-Id"),
            "delete-session")
        let snapshot = await transport.snapshot()
        XCTAssertFalse(snapshot.connected)
        XCTAssertTrue(snapshot.retired)
    }

    func testBodyAndFrameCapsFailClosed() async throws {
        MCPMockURLProtocol.setHandler { _ in
            .response(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(repeating: 0x61, count: 2_048))
        }
        let limits = MCPHTTPTransportLimits(
            maximumResponseBodyBytes: 1_024)
        let transport = try makeTransport(limits: limits)
        try await transport.connect()
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTFail("Expected response cap")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(error, .responseBodyTooLarge)
        }
        await transport.disconnect()

        MCPMockURLProtocol.setHandler { _ in
            .response(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    ("data: " + String(repeating: "a", count: 2_048))
                        .utf8))
        }
        let frameLimits = MCPHTTPTransportLimits(
            maximumSSEFrameBytes: 1_024)
        let frameTransport = try makeTransport(limits: frameLimits)
        try await frameTransport.connect()
        do {
            try await frameTransport.send(Data(
                #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTFail("Expected frame cap")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(error, .sseFrameTooLarge)
        }
        await frameTransport.disconnect()
    }

    func testDNSRebindingFenceRejectsAddressChange() async throws {
        let resolver = MCPSequenceDNSResolver([
            ["203.0.113.10"],
            ["203.0.113.11"],
        ])
        let fence = try MCPHTTPEgressFence(
            endpoint: URL(string: "https://mcp.example.test/mcp")!,
            canonicalOrigin: "https://mcp.example.test",
            resolver: resolver,
            authorizer: MCPAllowAllEgress())
        try await fence.authorizeRequest()
        do {
            try await fence.authorizeRequest()
            XCTFail("Expected rebinding rejection")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(
                error,
                .resolvedAddressSetChanged)
        }
    }

    func testDirectConfigurationHasNoCookieOrProxyStores() {
        let configuration = MCPStreamableHTTPTransport
            .makeSessionConfiguration(proxyPolicy: .direct)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(
            configuration.connectionProxyDictionary?.count,
            0)
    }

    func testFoundationNetworkingDirectModeRejectsAmbientProxyVariables()
        throws
    {
        for key in [
            "http_proxy",
            "HTTP_PROXY",
            "Https_Proxy",
            "ALL_PROXY",
            "no_proxy",
            "NO_PROXY",
        ] {
            XCTAssertThrowsError(
                try MCPStreamableHTTPTransport
                    .validateAmbientProxyEnvironment(
                        [key: ""],
                        proxyPolicy: .direct,
                        foundationNetworkingBacked:
                            true)
            ) { error in
                XCTAssertEqual(
                    error as? MCPHTTPTransportError,
                    .ambientProxyDenied)
            }
        }
        XCTAssertNoThrow(
            try MCPStreamableHTTPTransport
                .validateAmbientProxyEnvironment(
                    ["HTTPS_PROXY": "http://proxy.invalid"],
                    proxyPolicy: .systemConfigured,
                    foundationNetworkingBacked: true))
        XCTAssertNoThrow(
            try MCPStreamableHTTPTransport
                .validateAmbientProxyEnvironment(
                    ["HTTPS_PROXY": "http://proxy.invalid"],
                    proxyPolicy: .direct,
                    foundationNetworkingBacked:
                        false))
        XCTAssertNoThrow(
            try MCPStreamableHTTPTransport
                .validateAmbientProxyEnvironment(
                    [:],
                    proxyPolicy: .direct,
                    foundationNetworkingBacked: true))
    }

    func testSystemConfiguredProxyDoesNotClaimLocalTargetDNSBinding()
        async throws
    {
        let configuration = try MCPHTTPServerConfiguration(
            endpoint: "https://proxy-resolved.example.test/mcp",
            proxyPolicy: .systemConfigured)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MCPMockURLProtocol.self]
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(
                rawValue: "mcpcnx_proxy_delegation"),
            resolver: MCPFailingDNSResolver(),
            egressAuthorizer: MCPAllowAllEgress(),
            testingSessionConfiguration: session)
        try await transport.connect()
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.connected)
        await transport.disconnect()
    }

    func testCrossOriginRedirectIsDeniedBeforeCredentialLeak()
        async throws
    {
        let recorder = MCPRequestRecorder()
        MCPMockURLProtocol.setHandler { request in
            recorder.append(request)
            return .redirect(
                URL(string: "https://attacker.example/mcp")!)
        }
        let transport = try makeTransport()
        try await transport.connect()
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTFail("Expected redirect denial")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(error, .redirectDenied)
        }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(
            recorder.requests[0].url?.host,
            "mcp.example.test")
        await transport.disconnect()
    }

    func testDevelopmentHTTPCrossOriginRedirectIsDenied()
        async throws
    {
        MCPMockURLProtocol.setHandler { _ in
            .redirect(URL(string: "https://attacker.example/mcp")!)
        }
        let configuration = try MCPHTTPServerConfiguration(
            endpoint: "http://localhost/mcp",
            allowInsecureLoopbackDevelopmentHTTP: true)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MCPMockURLProtocol.self]
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: .init(
                rawValue: "mcpcnx_http_loopback_redirect"),
            resolver: MCPLoopbackDNSResolver(),
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true),
            testingSessionConfiguration: session)
        try await transport.connect()
        do {
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
            XCTFail("Expected redirect denial")
        } catch let error as MCPHTTPTransportError {
            XCTAssertEqual(error, .redirectDenied)
        }
        await transport.disconnect()
    }

    private func makeTransport(
        generation: MCPConnectionGeneration = .init(
            rawValue: "mcpcnx_http_test"),
        limits: MCPHTTPTransportLimits = .production,
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)? = nil
    ) throws -> MCPStreamableHTTPTransport {
        let configuration = try MCPHTTPServerConfiguration(
            endpoint: "https://mcp.example.test/mcp")
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MCPMockURLProtocol.self]
        return try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: generation,
            secretRedactionRegistrar:
                secretRedactionRegistrar,
            limits: limits,
            resolver: MCPFixedDNSResolver(),
            egressAuthorizer: MCPAllowAllEgress(),
            testingSessionConfiguration: session)
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Condition did not become true")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private func mcpHTTPBody(
    _ request: URLRequest
) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw URLError(.cannotDecodeContentData)
    }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](
        repeating: 0,
        count: 4_096)
    while true {
        let count = stream.read(
            &buffer,
            maxLength: buffer.count)
        if count > 0 {
            result.append(
                buffer,
                count: count)
        } else if count == 0 {
            return result
        } else {
            throw stream.streamError
                ?? URLError(
                    .cannotDecodeContentData)
        }
    }
}

private struct MCPFixedDNSResolver: MCPDNSResolving {
    func addresses(
        for _: String,
        port _: Int
    ) async throws -> Set<String> {
        ["203.0.113.10"]
    }
}

private struct MCPLoopbackDNSResolver: MCPDNSResolving {
    func addresses(
        for _: String,
        port _: Int
    ) async throws -> Set<String> {
        ["127.0.0.1"]
    }
}

private struct MCPFailingDNSResolver: MCPDNSResolving {
    func addresses(
        for _: String,
        port _: Int
    ) async throws -> Set<String> {
        throw MCPHTTPTransportError.dnsResolutionFailed
    }
}

private actor MCPSequenceDNSResolver: MCPDNSResolving {
    private var values: [Set<String>]

    init(_ values: [Set<String>]) {
        self.values = values
    }

    func addresses(
        for _: String,
        port _: Int
    ) async throws -> Set<String> {
        guard !values.isEmpty else {
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private struct MCPAllowAllEgress: MCPHTTPEgressAuthorizing {
    func authorize(
        canonicalOrigin _: String,
        resolvedAddresses _: Set<String>
    ) throws {}
}

private final class MCPRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class MCPSecretRegistrationFence:
    MCPSecretRedactionRegistering,
    @unchecked Sendable
{
    let redactor: MCPResolvedSecretRedactor

    private let expected: Data
    private let condition = NSCondition()
    private var registered = false

    init(
        expected: String,
        redactor: MCPResolvedSecretRedactor
    ) {
        self.expected = Data(expected.utf8)
        self.redactor = redactor
    }

    func registerMCPSecretRedactionValue(
        _ value: Data
    ) {
        redactor.registerMCPSecretRedactionValue(
            value)
        guard value == expected else { return }
        condition.lock()
        registered = true
        condition.broadcast()
        condition.unlock()
    }

    func clearMCPSecretRedactionValues() {
        redactor.clearMCPSecretRedactionValues()
        condition.lock()
        registered = false
        condition.unlock()
    }

    func waitForExpectedRegistration(
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(
            timeout)
        condition.lock()
        defer { condition.unlock() }
        while !registered {
            guard condition.wait(until: deadline)
            else { return registered }
        }
        return true
    }

    var didRegisterExpectedValue: Bool {
        condition.lock()
        defer { condition.unlock() }
        return registered
    }
}

private enum MCPMockReply {
    case response(
        status: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        chunks: [Data] = [])
    case responseAfterRegistration(
        status: Int,
        headers: [String: String],
        chunks: [Data],
        waitForRegistration: @Sendable () -> Bool)
    case responseThenFailure(
        status: Int,
        headers: [String: String],
        chunks: [Data],
        error: Error)
    case redirect(URL)
    case failure(Error)
}

private final class MCPMockURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler:
        ((URLRequest) throws -> MCPMockReply)?

    static func setHandler(
        _ value: @escaping (URLRequest) throws -> MCPMockReply
    ) {
        lock.lock()
        handler = value
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
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
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            switch try handler(request) {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .redirect(let target):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Location": target.absoluteString
                    ])!
                var redirected = request
                redirected.url = target
                client?.urlProtocol(
                    self,
                    wasRedirectedTo: redirected,
                    redirectResponse: response)
            case .responseThenFailure(
                let status,
                let headers,
                let chunks,
                let error):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers)!
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed)
                for chunk in chunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
                // Let URLSession deliver the partial body to its data
                // delegate before terminating the same stream.
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .milliseconds(10)
                ) { [self] in
                    client?.urlProtocol(
                        self,
                        didFailWithError: error)
                }
            case .response(
                let status,
                let headers,
                let body,
                let chunks):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers)!
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed)
                for chunk in chunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
                if !body.isEmpty {
                    client?.urlProtocol(self, didLoad: body)
                }
                client?.urlProtocolDidFinishLoading(self)
            case .responseAfterRegistration(
                let status,
                let headers,
                let chunks,
                let waitForRegistration):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers)!
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed)
                DispatchQueue.global().async {
                    [self] in
                    guard waitForRegistration() else {
                        client?.urlProtocol(
                            self,
                            didFailWithError:
                                URLError(.timedOut))
                        return
                    }
                    for chunk in chunks {
                        client?.urlProtocol(
                            self,
                            didLoad: chunk)
                    }
                    client?.urlProtocolDidFinishLoading(
                        self)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
