import Foundation
import XCTest
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import IntatisAgentKernel

private final class SessionRenameScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let proposedName: String
    private var requestIndex = 0
    private var captured: [AgentRequest] = []

    init(proposedName: String = "Focused implementation") {
        self.proposedName = proposedName
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        let index = requestIndex
        requestIndex += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if index == 0 {
                let arguments = String(decoding: try! JSONEncoder().encode([
                    "name": self.proposedName,
                ]), as: UTF8.self)
                continuation.yield(.toolCalls([ToolCall(
                    id: "rename-call",
                    name: "rename_session",
                    arguments: arguments)]))
                continuation.yield(.done(finishReason: "tool_calls"))
            } else {
                continuation.yield(.textDelta("Renamed."))
                continuation.yield(.done(finishReason: "stop"))
            }
            continuation.finish()
        }
    }
}

final class SessionRenameAgentLoopTests: XCTestCase {
    func testRenameSessionUsesDurableExecutionIdentityWithoutManualPermissionRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "code_agent_rename")
        let log = try EventLog(
            session: session,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let provider = SessionRenameScriptedProvider()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: .standard(),
            engine: PermissionEngine(),
            responder: FixedResponder(.deny),
            agent: Agent(
                name: AgentID(rawValue: "Coder"),
                workspaceRoot: root,
                model: ModelID(rawValue: "test"),
                profile: .reviewed),
            allowsShell: false,
            sessionNaming: EventLogSessionNamingService(log: log, kind: .code))

        let response = try await loop.send("Give this session a useful name.")
        XCTAssertEqual(response, "Renamed.")

        let events = try await log.replayChecked()
        let prepared = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionPreparedPayload? in
            if case .toolExecutionPrepared(let payload) = envelope.event,
               payload.tool == "rename_session" { return payload }
            return nil
        }.first)
        let rename = try XCTUnwrap(events.compactMap { envelope -> SessionSettingsUpdatedPayload? in
            if case .sessionSettingsUpdated(let payload) = envelope.event,
               payload.changeKind == .renamed { return payload }
            return nil
        }.first)
        XCTAssertEqual(rename.displayName, "Focused implementation")
        XCTAssertEqual(rename.displayNameSource, .modelTool)
        XCTAssertEqual(rename.renameOperationID, prepared.executionID)

        let durableCall = try XCTUnwrap(events.compactMap { envelope -> ToolCallPayload? in
            if case .toolCall(let payload) = envelope.event,
               payload.name == "rename_session" { return payload }
            return nil
        }.first)
        XCTAssertEqual(durableCall.argsRedacted, true)
        XCTAssertFalse(durableCall.args.contains("Focused implementation"))
        XCTAssertFalse(events.contains {
            if case .permissionRequest = $0.event { return true }
            return false
        })

        let settlement = try XCTUnwrap(events.compactMap { envelope -> ToolExecutionSettledPayload? in
            if case .toolExecutionSettled(let payload) = envelope.event,
               payload.executionID == prepared.executionID { return payload }
            return nil
        }.first)
        XCTAssertEqual(settlement.outcome, .succeeded)
        XCTAssertEqual(settlement.effectDisposition, .committed)

        let projection = try await SessionProjectionStore.rebuild(from: log)
        XCTAssertEqual(projection.kind, .code)
        XCTAssertEqual(projection.displayName, "Focused implementation")
        XCTAssertEqual(provider.requests.first?.tools.contains { $0.name == "rename_session" }, true)
    }

    func testSecretLikeRenameIsDeniedBeforeAuthorizationOrExecutionIsPersisted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-agent-secret-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl")
        let log = try EventLog(
            session: SessionID(rawValue: "code_secret_rename"),
            fileURL: logURL)
        let secret = "token=ghp_abcdef123456"
        let loop = AgentLoop(
            log: log,
            provider: SessionRenameScriptedProvider(proposedName: secret),
            registry: .standard(),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: AgentID(rawValue: "Coder"),
                workspaceRoot: root,
                model: ModelID(rawValue: "test"),
                profile: .reviewed),
            allowsShell: false,
            sessionNaming: EventLogSessionNamingService(log: log, kind: .code))

        _ = try await loop.send("Choose an appropriate session name.")
        let events = try await log.replayChecked()
        XCTAssertFalse(events.contains {
            if case .sessionSettingsUpdated = $0.event { return true }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .toolExecutionPrepared = $0.event { return true }
            return false
        })
        let denial = try XCTUnwrap(events.compactMap { envelope -> PermissionResolvedPayload? in
            if case .permissionResolved(let payload) = envelope.event,
               payload.tool == "rename_session" { return payload }
            return nil
        }.first)
        XCTAssertNotNil(denial.turnID)
        XCTAssertEqual(denial.toolCallID, "rename-call")
        XCTAssertEqual(denial.decision, .deny)
        XCTAssertNil(denial.authorization)
        let durableBytes = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(durableBytes.contains(secret))
    }
}
