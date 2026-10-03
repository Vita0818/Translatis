import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisTools

private actor RecordingSessionNamingService: SessionNamingService {
    struct Call: Equatable {
        let name: String
        let operationID: String
    }

    private let result: SessionRenameResult
    private var recordedCalls: [Call] = []

    init(result: SessionRenameResult) {
        self.result = result
    }

    func renameCurrentSession(to name: String,
                              operationID: String) async throws -> SessionRenameResult {
        recordedCalls.append(Call(name: name, operationID: operationID))
        return result
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

final class SessionNamingToolTests: XCTestCase {
    func testDescriptorUsesClosedBoundedNameSchemaAndStandardRegistryIncludesTool() throws {
        let descriptor = RenameSessionTool.descriptor
        XCTAssertEqual(descriptor.name, "rename_session")
        XCTAssertEqual(descriptor.sideEffect, .write)
        XCTAssertNotNil(ToolRegistry.standard().tool(named: "rename_session"))

        let data = try JSONEncoder().encode(descriptor.parameters)
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["name"])

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["name"])
        let name = try XCTUnwrap(properties["name"] as? [String: Any])
        XCTAssertEqual(name["type"] as? String, "string")
        XCTAssertEqual(name["minLength"] as? Int, 1)
        XCTAssertEqual(name["maxLength"] as? Int, 120)
    }

    func testPermissionIntentTargetsCurrentSessionAndPreviewOnlyRevealsCharacterCount() throws {
        let proposedName = "Secret roadmap"
        let args = ToolArgs(raw: #"{"name":"Secret roadmap"}"#)
        let tool = RenameSessionTool()

        XCTAssertEqual(RenameSessionTool.canonicalPermission, "session.rename")
        let intent = tool.permissionIntent(
            args,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(intent.action, "session.rename")
        XCTAssertEqual(
            intent.resources,
            [PermissionResource(kind: .tool, value: "current_session")])
        XCTAssertEqual(intent.dataEffects, [.none])
        XCTAssertEqual(intent.controlEffects, [])
        XCTAssertEqual(intent.risks, [.controlPlaneMutation])
        XCTAssertEqual(intent.replayPolicy, .doNotReplay)

        let preview = try XCTUnwrap(tool.permissionActionPreview(args))
        XCTAssertEqual(preview.kind, "rename_session")
        XCTAssertEqual(preview.fields, ["nameCharacterCount": String(proposedName.count)])
        XCTAssertFalse(preview.fields.values.contains { $0.contains(proposedName) })

        let authorizationIdentity = tool.authorizationArgumentIdentity(args)
        XCTAssertEqual(
            authorizationIdentity,
            "current-session-name:characters=\(proposedName.count)")
        XCTAssertFalse(authorizationIdentity.contains(proposedName))
    }

    func testMissingSessionNamingServiceRejectsWithoutSideEffect() async throws {
        let context = ToolContext(
            workspaceRoot: URL(fileURLWithPath: "/workspace"),
            executionID: "execution-1")

        do {
            _ = try await RenameSessionTool().execute(
                ToolArgs(raw: #"{"name":"New name"}"#),
                in: context)
            XCTFail("expected a typed no-side-effect rejection")
        } catch let error as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(error.code, "session_naming_unavailable")
        }
    }

    func testMissingExecutionIDRejectsBeforeCallingService() async throws {
        let expected = SessionRenameResult(
            previousName: "Old",
            name: "New",
            currentName: "New",
            revision: 2,
            changed: true)
        let service = RecordingSessionNamingService(result: expected)
        let context = ToolContext(
            workspaceRoot: URL(fileURLWithPath: "/workspace"),
            sessionNaming: service)

        do {
            _ = try await RenameSessionTool().execute(
                ToolArgs(raw: #"{"name":"New"}"#),
                in: context)
            XCTFail("expected a typed no-side-effect rejection")
        } catch let error as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(error.code, "missing_execution_id")
        }
        let calls = await service.calls()
        XCTAssertEqual(calls, [])
    }

    func testExecuteForwardsExecutionIDAndReturnsServiceResult() async throws {
        let expected = SessionRenameResult(
            previousName: "Old name",
            name: "Requested name",
            currentName: "Requested name",
            revision: 7,
            changed: true)
        let service = RecordingSessionNamingService(result: expected)
        let context = ToolContext(
            workspaceRoot: URL(fileURLWithPath: "/workspace"),
            sessionNaming: service,
            executionID: "execution-42")

        let observation = try await RenameSessionTool().execute(
            ToolArgs(raw: #"{"name":"Requested name"}"#),
            in: context)

        let calls = await service.calls()
        XCTAssertEqual(
            calls,
            [.init(name: "Requested name", operationID: "execution-42")])
        let returned = try JSONDecoder().decode(
            SessionRenameResult.self,
            from: Data(observation.text.utf8))
        XCTAssertEqual(returned, expected)
    }
}
