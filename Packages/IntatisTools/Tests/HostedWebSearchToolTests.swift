import Foundation
import XCTest
import IntatisProtocol
@testable import IntatisTools

private actor CapturingHostedWebSearchService:
    HostedWebSearchToolService
{
    private var queries: [String] = []

    func search(query: String) async throws -> ToolObservation {
        queries.append(query)
        return ToolObservation(text: "hosted result for \(query)")
    }

    func capturedQueries() -> [String] { queries }
}

final class HostedWebSearchToolTests: XCTestCase {
    func testDescriptorIsOneFieldStrictClosedNetworkSchema() throws {
        let descriptor = HostedWebSearchTool.descriptor

        XCTAssertEqual(descriptor.name, "hosted_web_search")
        XCTAssertEqual(descriptor.sideEffect, .network)
        XCTAssertEqual(descriptor.strict, true)
        guard case .object(let schema) = descriptor.parameters,
              case .object(let properties)? = schema["properties"],
              case .array(let required)? = schema["required"] else {
            return XCTFail("hosted search must expose a closed object schema")
        }
        XCTAssertEqual(Set(properties.keys), ["query"])
        XCTAssertEqual(required, [.string("query")])
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(
            HostedWebSearchTool.canonicalPermission,
            "network.search")
    }

    func testPermissionIntentDeclaresNetworkAndModelCost() throws {
        let service = CapturingHostedWebSearchService()
        let tool = HostedWebSearchTool(service: service)
        let args = ToolArgs(raw: #"{"query":"current Swift release"}"#)

        let intent = tool.permissionIntent(
            args,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))

        XCTAssertEqual(intent.action, "network.search")
        XCTAssertEqual(intent.dataEffects, [.network])
        XCTAssertEqual(intent.risks, [.networkAccess, .modelCost])
        XCTAssertEqual(intent.replayPolicy, .doNotReplay)
        XCTAssertEqual(
            intent.resources,
            [PermissionResource(
                kind: .tool,
                value: "hosted_web_search")])
        XCTAssertEqual(
            intent.metadata["query_characters"],
            .number(21))
    }

    func testExecutionTrimsQueryAndDelegatesToBoundService() async throws {
        let service = CapturingHostedWebSearchService()
        let tool = HostedWebSearchTool(service: service)

        let observation = try await tool.execute(
            ToolArgs(raw: #"{"query":"  latest model news  \n"}"#),
            in: ToolContext(
                workspaceRoot: URL(fileURLWithPath: "/tmp")))

        XCTAssertEqual(observation.text, "hosted result for latest model news")
        let capturedQueries = await service.capturedQueries()
        XCTAssertEqual(capturedQueries, ["latest model news"])
        XCTAssertThrowsError(try tool.validateArguments(
            ToolArgs(raw: #"{"query":"   "}"#)))

        let oversized = String(repeating: "q", count: 8_001)
        let encoded = try JSONEncoder().encode(["query": oversized])
        XCTAssertThrowsError(try tool.validateArguments(
            ToolArgs(raw: String(decoding: encoded, as: UTF8.self))))
    }

    func testStandardRegistryRequiresInjectedServiceAndExactCapability() {
        let ordinary = ToolRegistry.standard()
        XCTAssertNil(ordinary.tool(named: "hosted_web_search"))
        XCTAssertEqual(ordinary.registryVersion, "intatis.standard.v5")

        let service = CapturingHostedWebSearchService()
        let enabled = ToolRegistry.standard(hostedWebSearch: service)
        XCTAssertNotNil(enabled.tool(named: "hosted_web_search"))
        XCTAssertEqual(
            enabled.registration(named: "hosted_web_search")?
                .grantingCapabilities,
            [.hostedWebSearch])
        XCTAssertNotNil(enabled.tool(named: "browser_search"))
        XCTAssertNotNil(enabled.tool(named: "web_fetch"))
    }
}
