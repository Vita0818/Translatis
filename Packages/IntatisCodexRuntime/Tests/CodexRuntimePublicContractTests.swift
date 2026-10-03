import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisCodexRuntime

/// Compiles from the same public imports available to a downstream SwiftPM
/// consumer. Do not add `@testable`: this suite is the v1 source contract.
final class CodexRuntimePublicContractTests: XCTestCase {
    func testV1ContractIdentityMatchesThePublishedProductAndRuntime() throws {
        XCTAssertEqual(
            CodexRuntimeHostContract.publicAPIMajorVersion,
            1)
        XCTAssertEqual(CodexRuntimeHostContract.packageName, "Intatis")
        XCTAssertEqual(
            CodexRuntimeHostContract.productName,
            "IntatisCodexRuntime")
        XCTAssertEqual(
            CodexRuntimeHostContract.moduleName,
            "IntatisCodexRuntime")
        XCTAssertEqual(
            CodexRuntimeHostContract.pinnedRuntimeVersion,
            CodexRuntimeExecutable.pinnedVersion)
        XCTAssertEqual(
            CodexRuntimeHostContract.pinnedRuntimeDerivationID,
            CodexRuntimeExecutable.pinnedDerivationID)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        XCTAssertTrue(manifest.contains(
            #".library(name: "IntatisCodexRuntime", targets: ["IntatisCodexRuntime"])"#))
    }

    func testV1MinimalExternalHostConstructionUsesOnlyPublicAPI() {
        let route = ResponsesRuntimeRoute(
            endpointID: "consumer-fixture",
            model: ModelID(rawValue: "consumer-model"),
            baseURL: URL(string: "https://example.invalid/v1")!,
            bearerToken: "fixture-token")
        let tools = CodexRuntimeDynamicTools(
            toolsetID: "consumer.fixture.v1",
            specs: [
                CodexRuntimeDynamicToolSpec(
                    name: "consumer_probe",
                    description: "Return a bounded consumer fixture result.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "additionalProperties": .bool(false),
                    ])),
            ],
            handler: { call in
                .text("handled \(call.tool)")
            })
        let configuration = CodexRuntimeConfiguration(
            sessionID: SessionID(rawValue: "sess_consumer_fixture"),
            mode: .code,
            workspaceURL: URL(fileURLWithPath: "/tmp/consumer-workspace"),
            runtimeRootURL: URL(fileURLWithPath: "/tmp/consumer-runtime"),
            route: route,
            executableOverride: URL(fileURLWithPath: "/tmp/codex"),
            dynamicTools: tools,
            requestUserInputHandler: { request in
                let questionID = request.questions.first?.id
                    ?? "consumer_choice"
                return CodexRuntimeUserInputResponse(answers: [
                    questionID: ["Continue (Recommended)"],
                ])
            })
        let session = CodexAppServerSession(configuration: configuration)

        XCTAssertFalse(configuration.description.contains("fixture-token"))
        XCTAssertNotNil(session)
    }

    func testV1LifecycleAndApprovalSignaturesRemainSourceCompatible() {
        let events: @Sendable (
            CodexAppServerSession
        ) async -> AsyncStream<CodexRuntimeEvent> = { session in
            await session.events()
        }
        let start: @Sendable (
            CodexAppServerSession
        ) async throws -> CodexRuntimeIdentity = { session in
            try await session.start()
        }
        let runTurn: @Sendable (
            CodexAppServerSession,
            String,
            [URL]
        ) async throws -> CodexRuntimeTurnResult = { session, text, images in
            try await session.runTurn(
                text: text,
                localImageURLs: images)
        }
        let startTurn: @Sendable (
            CodexAppServerSession,
            String,
            [URL]
        ) async throws -> String = { session, text, images in
            try await session.startTurn(
                text: text,
                localImageURLs: images)
        }
        let waitForTurn: @Sendable (
            CodexAppServerSession,
            String
        ) async throws -> CodexRuntimeTurnResult = { session, turnID in
            try await session.waitForTurn(turnID)
        }
        let interrupt: @Sendable (
            CodexAppServerSession
        ) async throws -> Void = { session in
            try await session.interruptCurrentTurn()
        }
        let interruptTurn: @Sendable (
            CodexAppServerSession,
            String
        ) async throws -> Void = { session, turnID in
            try await session.interruptTurn(turnID: turnID)
        }
        let resolveApproval: @Sendable (
            CodexAppServerSession,
            CodexRuntimeRequestID,
            CodexRuntimeApprovalDecision
        ) async throws -> Void = { session, requestID, decision in
            try await session.resolveApproval(
                requestID: requestID,
                decision: decision)
        }
        let shutdown: @Sendable (
            CodexAppServerSession
        ) async -> Void = { session in
            await session.shutdown()
        }
        let approvalProjection: @Sendable (
            CodexRuntimeApprovalRequest
        ) -> (CodexRuntimeRequestID, CodexRuntimeApprovalKind, String) = {
            request in
            (request.requestID, request.kind, request.summary)
        }
        let usageProjection: @Sendable (
            CodexRuntimeResponsesUsage
        ) -> (String, Int, Int) = { usage in
            (usage.turnID, usage.inputTokens, usage.totalTokens)
        }
        let errorProjection: @Sendable (CodexRuntimeError) -> String = {
            $0.localizedDescription
        }
        let contentItem = CodexRuntimeDynamicToolContentItem.inputText(
            "consumer fixture")

        _ = (
            events,
            start,
            startTurn,
            runTurn,
            waitForTurn,
            interrupt,
            interruptTurn,
            resolveApproval,
            shutdown,
            approvalProjection,
            usageProjection,
            errorProjection,
            contentItem)
    }
}
