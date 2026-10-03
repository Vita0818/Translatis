import Foundation
import IntatisMCP
import IntatisProtocol
import Logging
import MCP
import XCTest

final class MCPProtocolLifecycleTests: XCTestCase {
    func testBothProfilesRequestTheirConfiguredHighestCommonVersion() throws {
        let codex = try MCPProtocolNegotiationPolicy.request(
            profile: .codexCompat,
            configuredMaximum: .v2025_06_18)
        XCTAssertEqual(codex.requestedVersion, .v2025_06_18)
        XCTAssertEqual(
            codex.allowedVersions,
            ["2024-11-05", "2025-03-26", "2025-06-18"])

        let extended = try MCPProtocolNegotiationPolicy.request(
            profile: .standardExtended,
            configuredMaximum: .v2025_11_25)
        XCTAssertEqual(extended.requestedVersion, .v2025_11_25)
        XCTAssertEqual(extended.allowedVersions, Version.supported)
    }

    func testProfileCeilingRejectsExtendedVersionForCodexCompatibility() {
        XCTAssertThrowsError(
            try MCPProtocolNegotiationPolicy.request(
                profile: .codexCompat,
                configuredMaximum: .v2025_11_25)
        ) { error in
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .unsupportedConfiguredProtocolVersion("2025-11-25"))
        }
    }

    func testCancellationActionsAreDisjointByRequestKind() {
        XCTAssertEqual(
            MCPOutboundCancellationPolicy.action(for: .initialize),
            .retireConnectionGeneration)
        XCTAssertEqual(
            MCPOutboundCancellationPolicy.action(for: .ordinary),
            .sendCancelledNotification)
        XCTAssertEqual(
            MCPOutboundCancellationPolicy.action(
                for: .taskAugmented(remoteTaskID: "remote-1")),
            .sendTasksCancel(remoteTaskID: "remote-1"))
        XCTAssertEqual(
            MCPOutboundCancellationPolicy.action(
                for: .taskAugmented(remoteTaskID: nil)),
            .retireTaskGenerationWithoutRemoteTaskID)
    }

    func testToolsOnlyServerInitializesWithoutUnrelatedOptionalCapabilities() async throws {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-06-18",
            serverCapabilities: ["tools": ["listChanged": true]])
        let session = MCPClientSession(
            configuration: configuration(
                profile: .codexCompat,
                required: [.tools]),
            transport: transport)

        let handshake = try await session.start()
        XCTAssertEqual(
            handshake.negotiatedVersion.value,
            .v2025_06_18)
        XCTAssertTrue(
            handshake.capabilities.capabilities.contains(.tools))
        XCTAssertFalse(
            handshake.capabilities.capabilities.contains(.resources))
        XCTAssertTrue(handshake.capabilities.toolsListChanged)
        let initializeMethods = await transport.sentMethods()
        XCTAssertEqual(
            initializeMethods,
            ["initialize", "notifications/initialized"])

        try await session.ping(timeoutMilliseconds: 500)
        let methodsAfterPing = await transport.sentMethods()
        XCTAssertEqual(
            methodsAfterPing,
            ["initialize", "notifications/initialized", "ping"])
        await session.shutdown()
        let didDisconnect = await transport.didDisconnect()
        XCTAssertTrue(didDisconnect)
    }

    func testStandardExtendedSessionActuallyNegotiates2025_11_25() async throws {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-11-25",
            serverCapabilities: ["tools": [:]])
        let session = MCPClientSession(
            configuration: configuration(profile: .standardExtended),
            transport: transport)

        let handshake = try await session.start()
        XCTAssertEqual(
            handshake.negotiatedVersion.value,
            .v2025_11_25)
        let methods = await transport.sentMethods()
        XCTAssertEqual(
            methods,
            ["initialize", "notifications/initialized"])
        await session.shutdown()
    }

    func testLazyTransportForwardsNegotiatedVersionBeforeInitialized()
        async throws
    {
        let concrete = ScriptedMCPTransport(
            selectedVersion: "2025-06-18",
            serverCapabilities: ["tools": [:]],
            requiresNegotiatedVersionBeforeInitialized:
                true)
        let lazy = MCPLazyClientTransport(
            label:
                "intatis.mcp.tests.lazy-negotiated-version"
        ) {
            concrete
        }
        let session = MCPClientSession(
            configuration: configuration(
                profile: .codexCompat),
            transport: lazy)

        let handshake = try await session.start()
        XCTAssertEqual(
            handshake.negotiatedVersion.value,
            .v2025_06_18)
        let negotiatedVersion =
            await concrete.negotiatedVersion()
        let methods =
            await concrete.sentMethods()
        XCTAssertEqual(
            negotiatedVersion,
            "2025-06-18")
        XCTAssertEqual(
            methods,
            [
                "initialize",
                "notifications/initialized",
            ])
        await session.shutdown()
    }

    func testServerSelectedVersionOutsideProfileRetiresBeforePublication() async {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-11-25",
            serverCapabilities: ["tools": [:]])
        let session = MCPClientSession(
            configuration: configuration(profile: .codexCompat),
            transport: transport)
        do {
            _ = try await session.start()
            XCTFail("expected protocol ceiling rejection")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .serverSelectedProtocolVersionOutsideProfile(
                    selected: "2025-11-25",
                    requested: "2025-06-18",
                    profile: "codex-compat"))
        }
        let handshake = await session.handshake()
        let didDisconnect = await transport.didDisconnect()
        let methods = await transport.sentMethods()
        XCTAssertNil(handshake)
        XCTAssertTrue(didDisconnect)
        XCTAssertFalse(methods.contains("notifications/initialized"))
    }

    func testMissingRequiredCapabilityRejectsBeforeInitializedNotification() async {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-06-18",
            serverCapabilities: ["tools": [:]])
        let session = MCPClientSession(
            configuration: configuration(
                profile: .codexCompat,
                required: [.resources]),
            transport: transport)
        do {
            _ = try await session.start()
            XCTFail("expected required-capability failure")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .missingRequiredCapabilities(["resources"]))
        }
        let methods = await transport.sentMethods()
        let handshake = await session.handshake()
        XCTAssertEqual(methods, ["initialize"])
        XCTAssertNil(handshake)
    }

    func testInitializeTimeoutRetiresWithoutCancelledNotification() async {
        let transport = ScriptedMCPTransport(
            selectedVersion: nil,
            serverCapabilities: [:])
        let session = MCPClientSession(
            configuration: configuration(
                profile: .codexCompat,
                startupTimeoutMilliseconds: 100),
            transport: transport)
        do {
            _ = try await session.start()
            XCTFail("expected initialize timeout")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .initializeTimedOut(milliseconds: 100))
        }
        let methods = await transport.sentMethods()
        XCTAssertEqual(methods, ["initialize"])
        XCTAssertFalse(methods.contains("notifications/cancelled"))
        let didDisconnect = await transport.didDisconnect()
        XCTAssertTrue(didDisconnect)
    }

    func testCallerCancellationDuringInitializeRetiresWithoutCancelledNotification() async {
        let transport = ScriptedMCPTransport(
            selectedVersion: nil,
            serverCapabilities: [:])
        let session = MCPClientSession(
            configuration: configuration(
                profile: .codexCompat,
                startupTimeoutMilliseconds: 2_000),
            transport: transport)

        let start = Task {
            try await session.start()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        start.cancel()

        do {
            _ = try await start.value
            XCTFail("expected initialize cancellation")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .initializeCancelled)
        }
        let methods = await transport.sentMethods()
        XCTAssertEqual(methods, ["initialize"])
        XCTAssertFalse(methods.contains("notifications/cancelled"))
        let didDisconnect = await transport.didDisconnect()
        XCTAssertTrue(didDisconnect)
    }

    func testOrdinaryTimeoutSendsExactCancelledNotification() async throws {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-06-18",
            serverCapabilities: ["tools": [:]],
            respondsToPing: false)
        let session = MCPClientSession(
            configuration: configuration(profile: .codexCompat),
            transport: transport)
        _ = try await session.start()

        do {
            try await session.ping(timeoutMilliseconds: 100)
            XCTFail("expected ping timeout")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .requestTimedOut(method: "ping", milliseconds: 100))
        }
        let records = await transport.sentRecords()
        let pingID = records.first(where: { $0.method == "ping" })?.id
        let cancelled = records.first(where: {
            $0.method == "notifications/cancelled"
        })
        XCTAssertNotNil(pingID)
        XCTAssertEqual(cancelled?.cancelledRequestID, pingID)
        await session.shutdown()
    }

    func testCallerCancellationDuringOrdinaryRequestSendsExactCancelledNotification() async throws {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-06-18",
            serverCapabilities: ["tools": [:]],
            respondsToPing: false)
        let session = MCPClientSession(
            configuration: configuration(profile: .codexCompat),
            transport: transport)
        _ = try await session.start()

        let ping = Task {
            try await session.ping(timeoutMilliseconds: 2_000)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        ping.cancel()

        do {
            try await ping.value
            XCTFail("expected ping cancellation")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .requestCancelled(method: "ping"))
        }
        let records = await transport.sentRecords()
        let pingID = records.first(where: { $0.method == "ping" })?.id
        let cancelled = records.first(where: {
            $0.method == "notifications/cancelled"
        })
        XCTAssertNotNil(pingID)
        XCTAssertEqual(cancelled?.cancelledRequestID, pingID)
        await session.shutdown()
    }

    func testExternalJSONRPCErrorsAreExactlyRedactedAtSessionBoundary()
        async throws {
        let authorization =
            "opaque-authorization-value"
        let sessionIdentifier =
            "opaque-session-identifier"
        let redactor =
            MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            authorization)
        redactor.registerMCPSecretRedactionValue(
            sessionIdentifier)
        let malicious =
            "echo \(authorization) and \(sessionIdentifier)"

        let initializeTransport =
            ScriptedMCPTransport(
                selectedVersion: "2025-06-18",
                serverCapabilities:
                    ["tools": [:]],
                errorMessagesByMethod: [
                    "initialize": malicious,
                ])
        let initializeSession =
            MCPClientSession(
                configuration:
                    configuration(
                        profile: .codexCompat,
                        outputSanitizer:
                            redactor),
                transport:
                    initializeTransport)
        do {
            _ = try await initializeSession
                .start()
            XCTFail(
                "malicious initialize error must fail")
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
                -32_050)
            XCTAssertFalse(
                error.localizedDescription
                    .contains(authorization))
            XCTAssertFalse(
                error.localizedDescription
                    .contains(sessionIdentifier))
            XCTAssertTrue(
                error.localizedDescription
                    .contains("[REDACTED]"))
        }
        if case .failed(let reason) =
                await initializeSession.state() {
            XCTAssertFalse(
                reason.contains(authorization))
            XCTAssertFalse(
                reason.contains(
                    sessionIdentifier))
        } else {
            XCTFail(
                "initialize failure must be retained safely")
        }

        let catalogTransport =
            ScriptedMCPTransport(
                selectedVersion: "2025-06-18",
                serverCapabilities: [
                    "tools": [:],
                    "resources": [:],
                    "prompts": [:],
                ],
                errorMessagesByMethod: [
                    "tools/list": malicious,
                    "resources/list": malicious,
                    "prompts/list": malicious,
                ])
        let catalogSession =
            MCPClientSession(
                configuration:
                    configuration(
                        profile: .codexCompat,
                        outputSanitizer:
                            redactor),
                transport:
                    catalogTransport)
        _ = try await catalogSession.start()
        let connection =
            MCPClientSessionConnectionClient(
                session: catalogSession)
        let operations:
            [() async throws -> Void] = [
                {
                    _ = try await connection
                        .listToolsPage(
                            cursor: nil)
                },
                {
                    _ = try await connection
                        .listResourcesPage(
                            cursor: nil)
                },
                {
                    _ = try await connection
                        .listPromptsPage(
                            cursor: nil)
                },
            ]
        for operation in operations {
            do {
                try await operation()
                XCTFail(
                    "malicious catalog error must fail")
            } catch let error
                as MCPSanitizedExternalError {
                XCTAssertEqual(
                    error.jsonRPCCode,
                    -32_050)
                XCTAssertFalse(
                    error.localizedDescription
                        .contains(authorization))
                XCTAssertFalse(
                    error.localizedDescription
                        .contains(
                            sessionIdentifier))
            }
        }
        await catalogSession.shutdown()
    }

    func testResourceCatalogRejectsSensitiveMIMEAtSessionBoundary()
        async throws {
        let sensitiveMIME =
            "mcp-session-sensitive-mime-value"
        let redactor =
            MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            sensitiveMIME)
        let transport =
            ScriptedMCPTransport(
                selectedVersion:
                    "2025-06-18",
                serverCapabilities: [
                    "resources": [:],
                ],
                resultsByMethod: [
                    "resources/list": [
                        "resources": [
                            [
                                "name":
                                    "safe-resource",
                                "uri":
                                    "test://resource",
                                "mimeType":
                                    sensitiveMIME,
                            ],
                        ],
                    ],
                    "resources/templates/list": [
                        "resourceTemplates": [
                            [
                                "name":
                                    "safe-template",
                                "uriTemplate":
                                    "test://resource/{id}",
                                "mimeType":
                                    sensitiveMIME,
                            ],
                        ],
                    ],
                ])
        let session =
            MCPClientSession(
                configuration:
                    configuration(
                        profile:
                            .codexCompat,
                        required:
                            [.resources],
                        outputSanitizer:
                            redactor),
                transport: transport)
        _ = try await session.start()
        let connection =
            MCPClientSessionConnectionClient(
                session: session)
        let operations:
            [() async throws -> Void] = [
                {
                    _ = try await connection
                        .listResourcesPage(
                            cursor: nil)
                },
                {
                    _ = try await connection
                        .listResourceTemplatesPage(
                            cursor: nil)
                },
            ]
        for operation in operations {
            do {
                try await operation()
                XCTFail(
                    "sensitive MIME must not enter a resource catalog")
            } catch {
                XCTAssertEqual(
                    error as?
                        MCPOutputSecurityError,
                    .sensitiveStructuralIdentifier)
                XCTAssertFalse(
                    error.localizedDescription
                        .contains(
                            sensitiveMIME))
            }
        }
        await session.shutdown()
    }

    func testTaskAugmentedCallReturnsExactCreateTaskWithoutOrdinaryCancellation() async throws {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-11-25",
            serverCapabilities: [
                "tools": [:],
                "tasks": [
                    "requests": [
                        "tools": ["call": [:]],
                    ],
                ],
            ],
            respondsToTaskCall: true)
        let session = MCPClientSession(
            configuration: configuration(profile: .standardExtended),
            transport: transport)
        _ = try await session.start()

        let result = try await session.performTaskAugmented(
            CallTool.request(.init(
                name: "slow_fixture",
                arguments: [:],
                task: .init(ttl: 5_000))),
            timeoutMilliseconds: 500)
        XCTAssertEqual(result.task?.taskId, "remote-task-1")
        XCTAssertEqual(result.task?.status, .working)
        let records = await transport.sentRecords()
        XCTAssertEqual(
            records.first(where: { $0.method == "tools/call" })?
                .taskTTL,
            5_000)
        XCTAssertFalse(
            records.contains {
                $0.method == "notifications/cancelled"
            })
        await session.shutdown()
    }

    func testUnmappedTaskTimeoutRetiresGenerationWithoutFabricatedCancel() async throws {
        let transport = ScriptedMCPTransport(
            selectedVersion: "2025-11-25",
            serverCapabilities: ["tools": [:]],
            respondsToTaskCall: false)
        let session = MCPClientSession(
            configuration: configuration(profile: .standardExtended),
            transport: transport)
        _ = try await session.start()

        do {
            _ = try await session.performTaskAugmented(
                CallTool.request(.init(
                    name: "uncertain_fixture",
                    task: .init(ttl: 1_000))),
                timeoutMilliseconds: 100)
            XCTFail("expected task creation timeout")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .taskCreationTimedOut(
                    method: "tools/call",
                    milliseconds: 100))
        }
        let methods = await transport.sentMethods()
        XCTAssertFalse(methods.contains("notifications/cancelled"))
        XCTAssertFalse(methods.contains("tasks/cancel"))
        let disconnected = await transport.didDisconnect()
        XCTAssertTrue(disconnected)
        if case .failed = await session.state() {
            // Expected exact-generation retirement.
        } else {
            XCTFail("retired task generation must not remain ready")
        }
    }

    private func configuration(
        profile: MCPProtocolProfile,
        required: Set<MCPGrantedCapability> = [],
        startupTimeoutMilliseconds: Int = 1_000,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer()
    ) -> MCPClientSessionConfiguration {
        MCPClientSessionConfiguration(
            server: MCPServerReference(
                serverID: MCPServerID(rawValue: "server_fixture"),
                serverRevision: MCPServerRevision(
                    rawValue: "mcpsrvrev_fixture")),
            generation: MCPConnectionGeneration(
                rawValue: "mcpcnx_fixture"),
            profile: profile,
            requiredCapabilities: required,
            startupTimeoutMilliseconds: startupTimeoutMilliseconds,
            callTimeoutMilliseconds: 1_000,
            clientVersion: "test",
            outputSanitizer:
                outputSanitizer)
    }
}

private struct ScriptedMCPRecord: Sendable {
    let method: String
    let id: String?
    let cancelledRequestID: String?
    let taskTTL: Int?
}

private actor ScriptedMCPTransport:
    NegotiatedProtocolVersionTransport
{
    nonisolated let logger = Logger(label: "intatis.mcp.tests.scripted")

    private let selectedVersion: String?
    private let serverCapabilities: [String: AnySendableJSON]
    private let respondsToPing: Bool
    private let respondsToTaskCall: Bool
    private let requiresNegotiatedVersionBeforeInitialized:
        Bool
    private let errorMessagesByMethod:
        [String: String]
    private let resultsByMethod:
        [String: AnySendableJSON]
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var records: [ScriptedMCPRecord] = []
    private var disconnected = false
    private var appliedNegotiatedVersion: String?

    init(
        selectedVersion: String?,
        serverCapabilities: [String: Any],
        respondsToPing: Bool = true,
        respondsToTaskCall: Bool = false,
        requiresNegotiatedVersionBeforeInitialized:
            Bool = false,
        errorMessagesByMethod:
            [String: String] = [:],
        resultsByMethod:
            [String: Any] = [:]
    ) {
        self.selectedVersion = selectedVersion
        self.serverCapabilities = serverCapabilities.mapValues(
            AnySendableJSON.init)
        self.respondsToPing = respondsToPing
        self.respondsToTaskCall = respondsToTaskCall
        self.requiresNegotiatedVersionBeforeInitialized =
            requiresNegotiatedVersionBeforeInitialized
        self.errorMessagesByMethod =
            errorMessagesByMethod
        self.resultsByMethod =
            resultsByMethod.mapValues(
                AnySendableJSON.init)
        var continuation:
            AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream {
            continuation = $0
        }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        disconnected = true
        continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func updateNegotiatedProtocolVersion(
        _ value: String
    ) throws {
        appliedNegotiatedVersion = value
    }

    func send(_ data: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(
            with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return
        }
        let id = Self.idString(object["id"])
        let params = object["params"] as? [String: Any]
        let cancelledID = Self.idString(params?["requestId"])
        let taskTTL = (params?["task"] as? [String: Any])?["ttl"]
            as? Int
        if requiresNegotiatedVersionBeforeInitialized,
           method == "notifications/initialized",
           appliedNegotiatedVersion != selectedVersion
        {
            throw ScriptedMCPTransportError
                .negotiatedVersionNotForwarded
        }
        records.append(
            ScriptedMCPRecord(
                method: method,
                id: id,
                cancelledRequestID: cancelledID,
                taskTTL: taskTTL))

        if let message =
                errorMessagesByMethod[method] {
            try yieldError(
                id: object["id"],
                message: message)
        } else if method == "initialize",
                  let selectedVersion {
            let capabilities = serverCapabilities.mapValues(\.value)
            try yieldResponse(
                id: object["id"],
                result: [
                    "protocolVersion": selectedVersion,
                    "capabilities": capabilities,
                    "serverInfo": [
                        "name": "fixture",
                        "version": "1.0",
                    ],
                    "instructions": "external fixture instructions",
                ])
        } else if method == "ping", respondsToPing {
            try yieldResponse(id: object["id"], result: [:])
        } else if let result =
                resultsByMethod[method]?
                    .value as?
                    [String: Any] {
            try yieldResponse(
                id: object["id"],
                result: result)
        } else if method == "tools/call", respondsToTaskCall {
            try yieldResponse(
                id: object["id"],
                result: [
                    "task": [
                        "taskId": "remote-task-1",
                        "status": "working",
                        "createdAt": "2026-07-26T00:00:00Z",
                        "lastUpdatedAt": "2026-07-26T00:00:00Z",
                        "ttl": 5_000,
                        "pollInterval": 250,
                    ],
                ])
        }
    }

    func sentMethods() -> [String] {
        records.map(\.method)
    }

    func sentRecords() -> [ScriptedMCPRecord] {
        records
    }

    func didDisconnect() -> Bool {
        disconnected
    }

    func negotiatedVersion() -> String? {
        appliedNegotiatedVersion
    }

    private func yieldResponse(id: Any?, result: [String: Any]) throws {
        let value: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ]
        continuation.yield(
            try JSONSerialization.data(withJSONObject: value))
    }

    private func yieldError(
        id: Any?,
        message: String
    ) throws {
        let value: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": -32_050,
                "message": message,
            ],
        ]
        continuation.yield(
            try JSONSerialization
                .data(withJSONObject: value))
    }

    private static func idString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

private enum ScriptedMCPTransportError: Error {
    case negotiatedVersionNotForwarded
}

/// Test-only wrapper that lets an actor retain JSON fixture values without
/// claiming Foundation's heterogeneous containers are Sendable.
private struct AnySendableJSON: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}
