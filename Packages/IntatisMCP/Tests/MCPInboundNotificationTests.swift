import Foundation
import IntatisProtocol
import Logging
import MCP
import XCTest
@testable import IntatisMCP

final class MCPInboundNotificationTests: XCTestCase {
    func testBrokerSanitizesBoundsDeduplicatesAndFencesProgress()
        async throws
    {
        let sink = InboundNotificationRecorder()
        let redactor = MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            "fixture-exact-secret")
        let broker = MCPInboundNotificationBroker(
            authority: notificationAuthority(
                profile: .standardExtended),
            policy: MCPInboundNotificationPolicy(
                minimumLoggingLevel: .info,
                maximumLogDataBytes: 128,
                maximumLogsPerMinute: 4,
                maximumProgressNotificationsPerMinute: 8,
                maximumProgressNotificationsPerRequestPerMinute: 4,
                duplicateWindowSeconds: 60),
            sanitizer: redactor,
            sink: sink)

        await broker.receiveLog(.init(
            level: .debug,
            data: .string("below threshold")))
        await broker.receiveLog(.init(
            level: .info,
            logger: "fixture-exact-secret.logger",
            data: .object([
                "message": .string(
                    "server echoed fixture-exact-secret"),
                "binary": .data(
                    mimeType: "application/octet-stream",
                    Data(repeating: 0x41, count: 32)),
            ])))
        await broker.receiveLog(.init(
            level: .info,
            logger: "fixture-exact-secret.logger",
            data: .object([
                "message": .string(
                    "server echoed fixture-exact-secret"),
                "binary": .data(
                    mimeType: "application/octet-stream",
                    Data(repeating: 0x41, count: 32)),
            ])))

        let requestID = ID.string("raw-request-id")
        let token = try await broker.registerRequest(
            requestID: requestID,
            method: "tools/call")
        await broker.receiveProgress(.init(
            progressToken: .string("unknown-token"),
            progress: 1,
            total: 10))
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 10,
            total: 100,
            message:
                "working with fixture-exact-secret"))
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 10,
            total: 100,
            message:
                "working with fixture-exact-secret"))
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 9,
            total: 100))
        await broker.finishRequest(
            progressToken: token,
            phase: .succeeded)
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 20,
            total: 100))

        let events = await sink.values()
        let logs: [MCPInboundLogRecord] =
            events.compactMap { event
                -> MCPInboundLogRecord? in
            guard case .log(let record) = event else {
                return nil
            }
            return record
        }
        XCTAssertEqual(logs.count, 1)
        XCTAssertFalse(
            (logs[0].logger ?? "")
                .contains("fixture-exact-secret"))
        XCTAssertFalse(
            logs[0].dataSummary
                .contains("fixture-exact-secret"))
        XCTAssertLessThanOrEqual(
            logs[0].dataSummary.utf8.count,
            128)
        XCTAssertTrue(
            logs[0].dataSummary.contains("[binary 32 bytes"))

        let progress: [MCPInboundProgressRecord] =
            events.compactMap { event
                -> MCPInboundProgressRecord? in
            guard case .progress(let record) = event else {
                return nil
            }
            return record
        }
        XCTAssertEqual(
            progress.map(\.phase),
            [.reported, .succeeded])
        XCTAssertTrue(progress[0].isDurableMilestone)
        XCTAssertFalse(
            (progress[0].message ?? "")
                .contains("fixture-exact-secret"))
        XCTAssertNotEqual(
            progress[0].correlation.requestIDFingerprint,
            "raw-request-id")
        XCTAssertNotEqual(
            progress[0].correlation.progressTokenFingerprint,
            String(describing: token))

        let snapshot = await broker.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 0)
        XCTAssertEqual(
            snapshot.droppedCounts[
                .belowConfiguredLogLevel],
            1)
        XCTAssertEqual(
            snapshot.droppedCounts[.duplicate],
            2)
        XCTAssertEqual(
            snapshot.droppedCounts[
                .unknownProgressToken],
            1)
        XCTAssertEqual(
            snapshot.droppedCounts[
                .nonMonotonicProgress],
            1)
        XCTAssertEqual(
            snapshot.droppedCounts[
                .lateProgressToken],
            1)
    }

    func testRemoteCancellationRequiresExactActiveRequest()
        async throws
    {
        let sink = InboundNotificationRecorder()
        let redactor = MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            "remote-cancel-secret")
        let broker = MCPInboundNotificationBroker(
            authority: notificationAuthority(
                profile: .codexCompat),
            sanitizer: redactor,
            sink: sink)
        let requestID = ID.string("request-1")
        let token = try await broker.registerRequest(
            requestID: requestID,
            method: "ping")
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 1,
            total: 2))
        await broker.receiveCancellation(.init(
            requestId: .string("unknown"),
            reason: "ignore"))
        await broker.receiveCancellation(.init(
            requestId: requestID,
            reason:
                "remote-cancel-secret stopped"))
        await broker.receiveCancellation(.init(
            requestId: requestID,
            reason: "late"))

        let events = await sink.values()
        let cancellations:
            [MCPInboundCancellationRecord] =
            events.compactMap { event
                -> MCPInboundCancellationRecord? in
            guard case .cancelled(let record) =
                    event else {
                return nil
            }
            return record
        }
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertFalse(
            (cancellations[0].reason ?? "")
                .contains("remote-cancel-secret"))
        let terminal: [MCPInboundProgressRecord] =
            events.compactMap { event
                -> MCPInboundProgressRecord? in
            guard case .progress(let record) = event,
                  record.phase == .cancelled else {
                return nil
            }
            return record
        }
        XCTAssertEqual(terminal.count, 1)
        let snapshot = await broker.snapshot()
        XCTAssertEqual(
            snapshot.droppedCounts[.unknownRequestID],
            1)
        XCTAssertEqual(
            snapshot.droppedCounts[.lateRequestID],
            1)
    }

    func testBrokerRateLimitsDistinctLogsAndProgress()
        async throws
    {
        let sink = InboundNotificationRecorder()
        let broker = MCPInboundNotificationBroker(
            authority: notificationAuthority(
                profile: .codexCompat),
            policy: MCPInboundNotificationPolicy(
                maximumLogsPerMinute: 1,
                maximumProgressNotificationsPerMinute: 1,
                maximumProgressNotificationsPerRequestPerMinute: 1,
                duplicateWindowSeconds: 0),
            sink: sink)
        await broker.receiveLog(.init(
            level: .info,
            data: .string("first")))
        await broker.receiveLog(.init(
            level: .info,
            data: .string("second")))
        let token = try await broker.registerRequest(
            requestID: .string("rate-request"),
            method: "tools/call")
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 1,
            total: 10))
        await broker.receiveProgress(.init(
            progressToken: token,
            progress: 2,
            total: 10))

        let snapshot = await broker.snapshot()
        XCTAssertEqual(
            snapshot.droppedCounts[.rateLimited],
            2)
        let recorded = await sink.values()
        let logs: [MCPInboundLogRecord] =
            recorded.compactMap { event
                -> MCPInboundLogRecord? in
                guard case .log(let record) =
                        event else {
                    return nil
                }
                return record
            }
        let progress:
            [MCPInboundProgressRecord] =
            recorded.compactMap { event
                -> MCPInboundProgressRecord? in
                guard case .progress(let record) =
                        event else {
                    return nil
                }
                return record
            }
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(
            progress.filter {
                $0.phase == .reported
            }.count,
            1)
    }

    func testShippingStorePersistsOnlyExtendedMilestones()
        async throws
    {
        let events = InboundBrokerEventRecorder()
        let store = MCPProductionInboundNotificationStore(
            events: events)
        let codex = notificationCorrelation(
            profile: .codexCompat,
            request: "codex")
        let extended = notificationCorrelation(
            profile: .standardExtended,
            request: "extended")

        await store.receiveMCPInboundNotification(
            .progress(.init(
                correlation: codex,
                progress: 25,
                total: 100,
                message: "codex live only",
                phase: .reported,
                isDurableMilestone: true)))
        await store.receiveMCPInboundNotification(
            .progress(.init(
                correlation: extended,
                progress: 30,
                total: 100,
                message: "high frequency",
                phase: .reported,
                isDurableMilestone: false)))
        await store.receiveMCPInboundNotification(
            .progress(.init(
                correlation: extended,
                progress: 50,
                total: 100,
                message: "halfway",
                phase: .reported,
                isDurableMilestone: true)))
        await store.receiveMCPInboundNotification(
            .log(.init(
                authority: extended.authority,
                level: .warning,
                logger: "fixture",
                dataSummary: "\"safe\"")))

        let recorded = await events.values()
        XCTAssertEqual(recorded.count, 1)
        guard case .mcpRequestProgress(let payload) =
                recorded[0] else {
            return XCTFail(
                "expected one durable progress event")
        }
        XCTAssertEqual(
            payload.requestIDFingerprint,
            extended.requestIDFingerprint)
        XCTAssertEqual(payload.progress, 50)
        XCTAssertEqual(payload.total, 100)
        XCTAssertEqual(payload.phase, .reported)
        XCTAssertEqual(
            payload.diagnostic?.summary,
            "halfway")

        let diagnostics =
            await store.inboundDiagnosticsSnapshot()
        XCTAssertEqual(
            diagnostics.map(\.code),
            [
                "mcp_request_progress",
                "mcp_request_progress",
                "mcp_server_log_warning",
            ])
        let active =
            await store.activeInboundProgressSnapshot()
        XCTAssertEqual(active.count, 2)
    }

    func testSessionNegotiatesLoggingTracksProgressAndRemoteCancellation()
        async throws
    {
        let transport = NotificationSessionTransport()
        let sink = InboundNotificationRecorder()
        let redactor = MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            "wire-exact-secret")
        let authorityFingerprint =
            String(repeating: "a", count: 64)
        let session = MCPClientSession(
            configuration: MCPClientSessionConfiguration(
                server: notificationServer(),
                generation: notificationGeneration(),
                profile: .codexCompat,
                startupTimeoutMilliseconds: 1_000,
                callTimeoutMilliseconds: 1_000,
                clientVersion: "test",
                callbackAuthorityFingerprint:
                    authorityFingerprint,
                outputSanitizer: redactor,
                inboundNotificationSink: sink,
                inboundNotificationPolicy: .init(
                    minimumLoggingLevel: .warning)),
            transport: transport)

        _ = try await session.start()
        try await session.ping(timeoutMilliseconds: 500)
        do {
            try await session.ping(
                timeoutMilliseconds: 500)
            XCTFail("expected exact remote cancellation")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .requestCancelled(method: "ping"))
        }

        let methods = await transport.methods()
        XCTAssertEqual(
            methods,
            [
                "initialize",
                "notifications/initialized",
                "logging/setLevel",
                "ping",
                "ping",
            ])
        let configuredLogLevel =
            await transport.configuredLogLevel()
        XCTAssertEqual(configuredLogLevel, "warning")
        let tokens = await transport.progressTokens()
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(Set(tokens).count, 3)

        let recorded = await sink.values()
        let logs: [MCPInboundLogRecord] =
            recorded.compactMap { event
                -> MCPInboundLogRecord? in
                guard case .log(let value) = event else {
                    return nil
                }
                return value
            }
        let log = try XCTUnwrap(logs.first)
        XCTAssertFalse(
            log.dataSummary.contains(
                "wire-exact-secret"))
        let progress: [MCPInboundProgressRecord] =
            recorded.compactMap { event
                -> MCPInboundProgressRecord? in
            guard case .progress(let value) = event else {
                return nil
            }
            return value
        }
        let containsSucceededProgress =
            progress.contains { record in
                record.phase == .succeeded
                    && record.progress == 50
                    && record.total == 100
            }
        XCTAssertTrue(containsSucceededProgress)
        let containsCancelledProgress =
            progress.contains { record in
                record.phase == .cancelled
                    && record.progress == 1
                    && record.total == 10
            }
        XCTAssertTrue(containsCancelledProgress)
        let cancellations:
            [MCPInboundCancellationRecord] =
            recorded.compactMap { event
                -> MCPInboundCancellationRecord? in
            guard case .cancelled(let value) =
                    event else {
                return nil
            }
            return value
        }
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertFalse(
            (cancellations[0].reason ?? "")
                .contains("wire-exact-secret"))
        await session.shutdown()
    }

    func testSessionRejectsNotificationSinkWithoutExactAuthority()
        async
    {
        let transport = NotificationSessionTransport()
        let session = MCPClientSession(
            configuration: MCPClientSessionConfiguration(
                server: notificationServer(),
                generation: notificationGeneration(),
                profile: .codexCompat,
                clientVersion: "test",
                inboundNotificationSink:
                    InboundNotificationRecorder()),
            transport: transport)

        do {
            _ = try await session.start()
            XCTFail(
                "notification publication must require exact authority")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .missingCallbackAuthorityFingerprint)
        }
        let methods = await transport.methods()
        XCTAssertTrue(methods.isEmpty)
    }
}

private actor InboundNotificationRecorder:
    MCPInboundNotificationSink
{
    private var recorded:
        [MCPInboundNotificationEvent] = []

    func receiveMCPInboundNotification(
        _ notification: MCPInboundNotificationEvent
    ) async {
        recorded.append(notification)
    }

    func values() -> [MCPInboundNotificationEvent] {
        recorded
    }
}

private actor InboundBrokerEventRecorder:
    MCPBrokerEventSink
{
    private var recorded: [Event] = []

    func appendMCPBrokerEvent(
        _ event: Event
    ) async throws {
        recorded.append(event)
    }

    func appendMCPBrokerEvents(
        _ events: [Event]
    ) async throws {
        recorded.append(contentsOf: events)
    }

    func values() -> [Event] {
        recorded
    }
}

private actor NotificationSessionTransport: Transport {
    nonisolated let logger = Logger(
        label: "intatis.mcp.tests.inbound-notifications")

    private let stream:
        AsyncThrowingStream<Data, Error>
    private let continuation:
        AsyncThrowingStream<Data, Error>.Continuation
    private var sentMethods: [String] = []
    private var tokens: [String] = []
    private var logLevel: String?
    private var pingCount = 0

    init() {
        var continuation:
            AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream {
            continuation = $0
        }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func send(_ data: Data) async throws {
        guard let object = try JSONSerialization
                .jsonObject(with: data)
                as? [String: Any],
              let method = object["method"] as? String else {
            return
        }
        sentMethods.append(method)
        let parameters =
            object["params"] as? [String: Any]
        if let token = (
            parameters?["_meta"] as? [String: Any]
        )?["progressToken"] as? String {
            tokens.append(token)
        }
        switch method {
        case "initialize":
            try yieldResponse(
                id: object["id"],
                result: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [
                        "logging": [:],
                    ],
                    "serverInfo": [
                        "name": "notification-fixture",
                        "version": "1.0",
                    ],
                ])
        case "logging/setLevel":
            logLevel = parameters?["level"] as? String
            try yieldNotification(
                method: "notifications/message",
                params: [
                    "level": "warning",
                    "logger": "fixture",
                    "data":
                        "wire-exact-secret was echoed",
                ])
            try yieldResponse(
                id: object["id"],
                result: [:])
        case "ping":
            pingCount += 1
            let token = try progressToken(
                in: parameters)
            if pingCount == 1 {
                try yieldNotification(
                    method: "notifications/progress",
                    params: [
                        "progressToken": token,
                        "progress": 50,
                        "total": 100,
                        "message": "halfway",
                    ])
                try yieldResponse(
                    id: object["id"],
                    result: [:])
            } else {
                try yieldNotification(
                    method: "notifications/progress",
                    params: [
                        "progressToken": token,
                        "progress": 1,
                        "total": 10,
                    ])
                try yieldNotification(
                    method: "notifications/cancelled",
                    params: [
                        "requestId":
                            object["id"] ?? NSNull(),
                        "reason":
                            "wire-exact-secret cancelled",
                    ])
            }
        default:
            break
        }
    }

    func methods() -> [String] {
        sentMethods
    }

    func progressTokens() -> [String] {
        tokens
    }

    func configuredLogLevel() -> String? {
        logLevel
    }

    private func progressToken(
        in parameters: [String: Any]?
    ) throws -> String {
        guard let token = (
            parameters?["_meta"] as? [String: Any]
        )?["progressToken"] as? String else {
            throw NotificationFixtureError
                .missingProgressToken
        }
        return token
    }

    private func yieldResponse(
        id: Any?,
        result: [String: Any]
    ) throws {
        continuation.yield(
            try JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": id ?? NSNull(),
                    "result": result,
                ]))
    }

    private func yieldNotification(
        method: String,
        params: [String: Any]
    ) throws {
        continuation.yield(
            try JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "method": method,
                    "params": params,
                ]))
    }
}

private enum NotificationFixtureError: Error {
    case missingProgressToken
}

private func notificationServer() -> MCPServerReference {
    MCPServerReference(
        serverID: MCPServerID(
            rawValue: "notification-server"),
        serverRevision: MCPServerRevision(
            rawValue: "notification-revision"))
}

private func notificationGeneration()
    -> MCPConnectionGeneration
{
    MCPConnectionGeneration(
        rawValue: "notification-generation")
}

private func notificationAuthority(
    profile: MCPProtocolProfile
) -> MCPCallbackAuthorityContext {
    MCPCallbackAuthorityContext(
        server: notificationServer(),
        connectionGeneration:
            notificationGeneration(),
        authorityFingerprint:
            String(repeating: "a", count: 64),
        profile: profile)
}

private func notificationCorrelation(
    profile: MCPProtocolProfile,
    request: String
) -> MCPInboundRequestCorrelation {
    MCPInboundRequestCorrelation(
        authority: notificationAuthority(
            profile: profile),
        requestIDFingerprint:
            "request-\(request)",
        progressTokenFingerprint:
            "token-\(request)",
        method: "tools/call")
}
