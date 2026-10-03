import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisTools

final class MCPDynamicToolRegistryTests: XCTestCase {
    func testStructuredObservationIsAdditiveAndEquatable() {
        let legacy = ToolObservation(text: "legacy")
        XCTAssertNil(legacy.structuredResult)
        XCTAssertEqual(
            legacy,
            ToolObservation(
                text: "legacy",
                truncated: false,
                diff: nil,
                changedFiles: nil))

        let structuredResult = MCPStructuredToolResult(
            content: [
                MCPContentBlock(
                    kind: .text,
                    text: "structured text",
                    mimeType: "text/plain",
                    byteCount: 15,
                    truncated: false),
                MCPContentBlock(
                    kind: .artifactReference,
                    artifactID: ArtifactID(rawValue: "art-test"),
                    mimeType: "image/png",
                    byteCount: 42,
                    sha256: String(repeating: "a", count: 64)),
            ],
            structuredContent: .object(["ok": .bool(true)]),
            outputSchemaHash: String(repeating: "b", count: 64),
            totalByteCount: 57)
        let first = ToolObservation(
            text: "legacy projection",
            structuredResult: structuredResult)
        let second = ToolObservation(
            text: "legacy projection",
            structuredResult: structuredResult)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.structuredResult, structuredResult)
    }

    func testInstanceDescriptorsDriveCatalogAuthorizationFingerprintAndExecution() async throws {
        let alphaDescriptor = descriptor(
            name: "mcp_alpha",
            description: "Alpha dynamic tool",
            property: "query")
        let betaDescriptor = descriptor(
            name: "mcp_beta",
            description: "Beta dynamic tool",
            property: "path")
        let registry = ToolRegistry(
            registrations: [
                ToolRegistration(
                    descriptor: alphaDescriptor,
                    tool: DynamicExecutor(result: "alpha-result")),
                ToolRegistration(
                    descriptor: betaDescriptor,
                    tool: DynamicExecutor(result: "beta-result")),
            ],
            registryVersion: "test.dynamic.v1")

        let descriptors = Dictionary(
            uniqueKeysWithValues: registry.descriptors().map { ($0.name, $0) })
        XCTAssertEqual(descriptors["mcp_alpha"]?.description, "Alpha dynamic tool")
        XCTAssertEqual(descriptors["mcp_alpha"]?.parameters, alphaDescriptor.parameters)
        XCTAssertEqual(descriptors["mcp_beta"]?.description, "Beta dynamic tool")
        XCTAssertEqual(descriptors["mcp_beta"]?.parameters, betaDescriptor.parameters)
        XCTAssertNil(descriptors[DynamicExecutor.descriptor.name])

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let context = ToolContext(workspaceRoot: workspace)
        let alphaRegistration = try XCTUnwrap(
            registry.registration(named: "mcp_alpha"))
        let betaRegistration = try XCTUnwrap(
            registry.registration(named: "mcp_beta"))
        let alphaArguments = ToolArgs(raw: #"{"query":"one"}"#)
        let betaArguments = ToolArgs(raw: #"{"path":"two"}"#)
        let alphaIntent = alphaRegistration.permissionIntent(
            alphaArguments,
            workspaceRoot: workspace)
        let betaIntent = betaRegistration.permissionIntent(
            betaArguments,
            workspaceRoot: workspace)

        XCTAssertEqual(alphaIntent.metadata["tool"], .string("mcp_alpha"))
        XCTAssertEqual(betaIntent.metadata["tool"], .string("mcp_beta"))
        XCTAssertEqual(
            alphaRegistration.permissionActionPreview(alphaArguments)?.kind,
            "mcp_alpha")
        XCTAssertEqual(
            betaRegistration.permissionActionPreview(betaArguments)?.kind,
            "mcp_beta")

        let alphaAuthorization = try registry.resolveAuthorization(
            toolName: "mcp_alpha",
            intent: alphaIntent,
            risksNetwork: false,
            normalizedArguments: alphaArguments.raw,
            capabilityLease: nil,
            workspaceLease: nil)
        let betaAuthorization = try registry.resolveAuthorization(
            toolName: "mcp_beta",
            intent: betaIntent,
            risksNetwork: false,
            normalizedArguments: betaArguments.raw,
            capabilityLease: nil,
            workspaceLease: nil)

        XCTAssertEqual(alphaAuthorization.toolName, "mcp_alpha")
        XCTAssertEqual(betaAuthorization.toolName, "mcp_beta")
        XCTAssertNotEqual(
            alphaAuthorization.descriptorFingerprint,
            betaAuthorization.descriptorFingerprint)

        try registry.validateAuthorizationSnapshot(
            alphaAuthorization,
            toolName: "mcp_alpha",
            normalizedArguments: alphaArguments.raw,
            intent: alphaAuthorization.intent,
            risksNetwork: false)
        XCTAssertThrowsError(
            try registry.validateAuthorizationSnapshot(
                alphaAuthorization,
                toolName: "mcp_beta",
                normalizedArguments: alphaArguments.raw,
                intent: alphaAuthorization.intent,
                risksNetwork: false))

        let alphaObservation = try await alphaRegistration.execute(
            ToolArgs(raw: "{}"),
            in: context)
        let betaObservation = try await betaRegistration.execute(
            ToolArgs(raw: "{}"),
            in: context)
        XCTAssertEqual(alphaObservation.text, "alpha-result")
        XCTAssertEqual(betaObservation.text, "beta-result")
    }

    func testDynamicRegistryUpdateRequiresAndUsesReplacementVersion() {
        let base = ToolRegistry(
            [StaticCompatibilityTool()],
            registryVersion: "test.registry.v1")
        let dynamic = ToolRegistration(
            descriptor: descriptor(
                name: "mcp_dynamic",
                description: "Dynamic",
                property: "value"),
            tool: DynamicExecutor(result: "dynamic-result"))

        let updated = base.adding(
            registrations: [dynamic],
            registryVersion: "test.registry.v2")

        XCTAssertEqual(base.registryVersion, "test.registry.v1")
        XCTAssertNil(base.registration(named: "mcp_dynamic"))
        XCTAssertEqual(updated.registryVersion, "test.registry.v2")
        XCTAssertEqual(
            updated.registration(named: "mcp_dynamic")?.descriptor.name,
            "mcp_dynamic")

        let rebuilt = base
            .rebuilding(registryVersion: "test.registry.v3")
            .adding(registrations: [dynamic])
            .build()
        XCTAssertEqual(rebuilt.registryVersion, "test.registry.v3")
        XCTAssertNotNil(rebuilt.registration(named: "mcp_dynamic"))

        let legacy = base.adding([AnotherStaticCompatibilityTool()])
        XCTAssertEqual(legacy.registryVersion, "test.registry.v1")
        XCTAssertNotNil(legacy.registration(named: "another_static"))
    }

    func testStaticToolRegistrationCompatibilityUsesStaticDescriptor() async throws {
        let registration = ToolRegistration(tool: StaticCompatibilityTool())
        XCTAssertEqual(registration.descriptor.name, "static_compatibility")
        XCTAssertEqual(
            registration.descriptor.parameters,
            StaticCompatibilityTool.descriptor.parameters)

        let registry = ToolRegistry(
            [StaticCompatibilityTool()],
            registryVersion: "test.static.v1")
        XCTAssertEqual(registry.descriptors().map(\.name), ["static_compatibility"])

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let arguments = ToolArgs(raw: #"{"query":"static"}"#)
        let intent = registration.permissionIntent(
            arguments,
            workspaceRoot: workspace)
        XCTAssertEqual(intent.action, "static.custom.action")
        XCTAssertEqual(
            registration.permissionActionPreview(arguments)?.kind,
            "static-custom-preview")
        let authorization = try registry.resolveAuthorization(
            toolName: "static_compatibility",
            intent: intent,
            risksNetwork: false,
            normalizedArguments: arguments.raw,
            capabilityLease: nil,
            workspaceLease: nil)
        XCTAssertEqual(authorization.canonicalPermission, "static.permission")

        let observation = try await XCTUnwrap(
            registry.registration(named: "static_compatibility"))
            .execute(
                ToolArgs(raw: "{}"),
                in: ToolContext(workspaceRoot: workspace))
        XCTAssertEqual(observation, ToolObservation(text: "static-result"))
    }

    private func descriptor(name: String,
                            description: String,
                            property: String) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            sideEffect: .readOnly,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    property: .object(["type": .string("string")]),
                ]),
                "required": .array([.string(property)]),
                "additionalProperties": .bool(false),
            ]))
    }
}

private struct DynamicExecutor: Tool {
    static let descriptor = ToolDescriptor(
        name: "dynamic_executor_static_fallback",
        description: "This descriptor must never represent a dynamic registration.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ]))

    let result: String

    func execute(_ args: ToolArgs,
                 in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: result)
    }
}

private struct StaticCompatibilityTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "static_compatibility",
        description: "Static compatibility tool",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ]))
    static let canonicalPermission: String? = "static.permission"

    func permissionIntent(_ args: ToolArgs,
                          workspaceRoot: URL) -> PermissionIntent {
        var intent = PermissionIntent.derived(
            toolName: Self.descriptor.name,
            sideEffect: Self.descriptor.sideEffect,
            touchedPaths: [],
            risksNetwork: false)
        intent.action = "static.custom.action"
        return intent
    }

    func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        PermissionActionPreview(
            kind: "static-custom-preview",
            fields: ["query": "static"])
    }

    func execute(_ args: ToolArgs,
                 in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: "static-result")
    }
}

private struct AnotherStaticCompatibilityTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "another_static",
        description: "Another static tool",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ]))

    func execute(_ args: ToolArgs,
                 in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: "another-static-result")
    }
}
