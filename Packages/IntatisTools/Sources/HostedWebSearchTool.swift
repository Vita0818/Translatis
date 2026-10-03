import Foundation
import IntatisCore
import IntatisProtocol

/// Provider-backed search seam. The Tools target owns only the model-facing
/// contract; AgentKernel binds it to one exact provider/model route.
public protocol HostedWebSearchToolService: Sendable {
    func search(query: String) async throws -> ToolObservation
}

/// A narrow agent tool for provider-hosted web search. This is deliberately
/// independent from `browser_search`, `web_fetch`, and MCP search tools.
public struct HostedWebSearchTool: Tool {
    private let service: any HostedWebSearchToolService

    public init(service: any HostedWebSearchToolService) {
        self.service = service
    }

    public static let descriptor = ToolDescriptor(
        name: "hosted_web_search",
        description: "Search the web using the current model provider's hosted search capability and return its answer with provider-supplied sources. This does not open or control a browser.",
        sideEffect: .network,
        parameters: Schema.object([
            "query": Schema.boundedString(
                minLength: 1,
                maxLength: 8_000),
        ], required: ["query"]),
        strict: true)

    public static let canonicalPermission: String? =
        "network.search"

    struct Args: Decodable {
        let query: String
    }

    public func validateArguments(_ args: ToolArgs) throws {
        let query = try normalizedQuery(args)
        guard query.count <= 8_000 else {
            throw IntatisError.decoding(
                "hosted web-search query exceeds 8000 characters")
        }
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func permissionIntent(
        _ args: ToolArgs,
        workspaceRoot: URL
    ) -> PermissionIntent {
        let queryLength = (try? normalizedQuery(args).count) ?? 0
        return PermissionIntent(
            action: "network.search",
            resources: [
                PermissionResource(
                    kind: .tool,
                    value: Self.descriptor.name),
            ],
            metadata: [
                "tool": .string(Self.descriptor.name),
                "query_characters": .number(Double(queryLength)),
            ],
            dataEffects: [.network],
            risks: [.networkAccess, .modelCost],
            replayPolicy: .doNotReplay)
    }

    public func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        try await service.search(query: normalizedQuery(args))
    }

    private func normalizedQuery(_ args: ToolArgs) throws -> String {
        let value = try args.decode(Args.self).query
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw IntatisError.decoding(
                "hosted web-search query must not be blank")
        }
        return value
    }
}
