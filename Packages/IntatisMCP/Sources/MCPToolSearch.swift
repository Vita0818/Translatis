// The deferred-tool wire shape, searchable MCP metadata fields, and
// tool_search history behavior are derived from OpenAI Codex commit
// 61a44880a85d2fd0d8770908dea5733495e571c8. Intatis adapts them to its Swift
// MCP client, catalog revisions, grants, PermissionEngine, and EventLog.
// Provenance and Apache-2.0 notice: ThirdPartyNotices/MCPToolSearch.md.

import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

public enum MCPToolSearchConstants {
    public static let toolName = "tool_search"
    public static let defaultLimit = 8
    public static let maximumLimit = 1_000

    public static let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "Search query for deferred tools."),
            ]),
            "limit": .object([
                "type": .string("number"),
                "description": .string(
                    "Maximum number of tools to return. Defaults to 8."),
            ]),
        ]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])

    public static func description(
        sources: [MCPToolSearchSource]
    ) -> String {
        let deduplicated = Dictionary(
            sources.map { ($0.name, $0.description) },
            uniquingKeysWith: { current, candidate in
                current ?? candidate
            })
        let sourceLines: String
        if deduplicated.isEmpty {
            sourceLines = "None currently enabled."
        } else {
            sourceLines = deduplicated.keys.sorted().map { name in
                if let description = deduplicated[name] ?? nil {
                    return "- \(name): \(description)"
                }
                return "- \(name)"
            }.joined(separator: "\n")
        }
        return """
        # Tool discovery

        Searches over deferred tool metadata with BM25 and exposes matching tools for the next model call.

        You have access to tools from the following sources:
        \(sourceLines)
        Some of the tools may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search` instead of `list_mcp_resources` or `list_mcp_resource_templates`.
        """
    }
}

public struct MCPToolSearchSource:
    Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Provider-neutral equivalent of Codex's deferred Responses API function.
///
/// `routingName` remains the exact flat ToolRegistry key. `name` is the
/// callable child name when the spec is placed in a namespace.
public struct MCPDeferredFunctionSpec:
    Codable, Equatable, Sendable {
    public let name: String
    public let routingName: String
    public let description: String
    public let parameters: JSONValue
    public let strict: Bool
    public let deferLoading: Bool
    public let outputSchema: JSONValue?
    public let supportsParallelCalls: Bool
    public let server: MCPServerReference
    public let rawCatalogRevision: MCPRawCatalogRevision
    public let agentCatalogViewRevision: MCPAgentCatalogViewRevision
    public let schemaHash: String

    public init(entry: MCPToolBindingEntry) {
        name = entry.qualifiedName.toolAlias
        routingName = entry.qualifiedName.value
        description = entry.remoteTool.summary
        parameters = entry.remoteTool.inputSchema
        strict = false
        deferLoading = true
        // Codex strips output_schema from tool_search results. Intatis keeps
        // the real output schema on the exact execution registration.
        outputSchema = nil
        supportsParallelCalls = entry.policy.supportsParallelCalls
        server = entry.authorization.server
        rawCatalogRevision = entry.authorization.rawCatalogRevision
        agentCatalogViewRevision =
            entry.authorization.agentCatalogViewRevision
        schemaHash = entry.authorization.schemaHash
    }
}

public struct MCPDeferredNamespaceSpec:
    Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let tools: [MCPDeferredFunctionSpec]

    public init(
        name: String,
        description: String? = nil,
        tools: [MCPDeferredFunctionSpec]
    ) {
        self.name = name
        self.description = description?.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty == false
            ? description!
            : "Tools in the \(name) namespace."
        self.tools = tools
    }
}

public enum MCPDeferredToolSpec:
    Codable, Equatable, Sendable {
    case function(MCPDeferredFunctionSpec)
    case namespace(MCPDeferredNamespaceSpec)

    /// Exact Responses tool definition placed inside
    /// `tool_search_output.tools`. These definitions are history items; callers
    /// must not append them to the next request's top-level `tools` array.
    public var responsesJSON: JSONValue {
        switch self {
        case .function(let function):
            return Self.functionJSON(function)
        case .namespace(let namespace):
            return .object([
                "type": .string("namespace"),
                "name": .string(namespace.name),
                "description": .string(namespace.description),
                "tools": .array(
                    namespace.tools.map(Self.functionJSON)),
            ])
        }
    }

    private static func functionJSON(
        _ function: MCPDeferredFunctionSpec
    ) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(function.name),
            "description": .string(function.description),
            "strict": .bool(function.strict),
            "defer_loading": .bool(function.deferLoading),
            "parameters": function.parameters,
        ])
    }
}

public struct MCPToolSearchMatch:
    Codable, Equatable, Sendable {
    public let server: MCPServerReference
    public let qualifiedName: String
    public let remoteToolName: String
    public let summary: String
    public let schemaHash: String
    public let schemaPropertyNames: [String]
    public let rawCatalogRevision: MCPRawCatalogRevision
    public let agentCatalogViewRevision: MCPAgentCatalogViewRevision
    public let score: Double
}

public struct MCPToolSearchResult:
    Codable, Equatable, Sendable {
    public let catalogFingerprint: String
    public let matches: [MCPToolSearchMatch]
    public let loadableTools: [MCPDeferredToolSpec]
}

public enum MCPToolSearchError:
    Error, Equatable, LocalizedError, Sendable {
    case emptyQuery
    case invalidLimit
    case staleCatalog(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "query must not be empty"
        case .invalidLimit:
            return "limit must be greater than zero"
        case .staleCatalog(let expected, let actual):
            return "tool_search catalog is stale; expected \(expected), current \(actual)"
        }
    }
}

private struct MCPToolSearchArguments: Decodable, Sendable {
    let query: String
    let limit: Int?
}

private struct MCPToolSearchIndexEntry: Sendable {
    let binding: MCPToolBindingEntry
    let searchText: String
}

/// Immutable, grant-scoped BM25 index. No server-global catalog enters this
/// value: the input is already the exact Agent catalog view.
public struct MCPToolSearchIndex: Sendable {
    public let catalogFingerprint: String
    private let entries: [MCPToolSearchIndexEntry]
    private let bm25: MCPBM25Index

    public init(view: MCPAgentToolCatalogView) {
        catalogFingerprint = view.stableFingerprint
        entries = view.entries.map {
            MCPToolSearchIndexEntry(
                binding: $0,
                searchText: Self.searchText(for: $0))
        }
        bm25 = MCPBM25Index(documents: entries.map(\.searchText))
    }

    public func search(
        query untrimmedQuery: String,
        limit requestedLimit: Int? = nil,
        namespaceTools: Bool = true
    ) throws -> MCPToolSearchResult {
        let query = untrimmedQuery.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw MCPToolSearchError.emptyQuery
        }
        let limit = requestedLimit ?? MCPToolSearchConstants.defaultLimit
        guard limit > 0 else {
            throw MCPToolSearchError.invalidLimit
        }
        let boundedLimit = min(limit, MCPToolSearchConstants.maximumLimit)
        let ranked = bm25.search(query: query, limit: boundedLimit)
        let selected = ranked.compactMap { ranked -> (
            MCPToolSearchIndexEntry, Double)? in
            guard entries.indices.contains(ranked.index) else { return nil }
            return (entries[ranked.index], ranked.score)
        }
        let matches = selected.map { entry, score in
            MCPToolSearchMatch(
                server: entry.binding.authorization.server,
                qualifiedName: entry.binding.qualifiedName.value,
                remoteToolName: entry.binding.remoteTool.remoteName,
                summary: entry.binding.remoteTool.summary,
                schemaHash: entry.binding.authorization.schemaHash,
                schemaPropertyNames: Self.propertyNames(
                    entry.binding.remoteTool.inputSchema),
                rawCatalogRevision:
                    entry.binding.authorization.rawCatalogRevision,
                agentCatalogViewRevision:
                    entry.binding.authorization.agentCatalogViewRevision,
                score: score)
        }
        let functions = selected.map {
            ($0.0.binding, MCPDeferredFunctionSpec(entry: $0.0.binding))
        }
        let loadableTools = Self.loadableTools(
            functions,
            namespaceTools: namespaceTools)
        return MCPToolSearchResult(
            catalogFingerprint: catalogFingerprint,
            matches: matches,
            loadableTools: loadableTools)
    }

    public func loadableTools(
        qualifiedNames: [String],
        namespaceTools: Bool
    ) -> [MCPDeferredToolSpec] {
        let entryByName = Dictionary(
            entries.map { ($0.binding.qualifiedName.value, $0.binding) },
            uniquingKeysWith: { current, _ in current })
        let selected = qualifiedNames.compactMap { name -> (
            MCPToolBindingEntry, MCPDeferredFunctionSpec)? in
            guard let binding = entryByName[name] else { return nil }
            return (binding, MCPDeferredFunctionSpec(entry: binding))
        }
        return Self.loadableTools(
            selected,
            namespaceTools: namespaceTools)
    }

    private static func loadableTools(
        _ functions: [(
            MCPToolBindingEntry,
            MCPDeferredFunctionSpec
        )],
        namespaceTools: Bool
    ) -> [MCPDeferredToolSpec] {
        guard namespaceTools else {
            return functions.map { .function($0.1) }
        }
        var namespaceOrder: [String] = []
        var toolsByNamespace: [String: [MCPDeferredFunctionSpec]] = [:]
        for (entry, function) in functions {
            let namespace = entry.qualifiedName.namespace
            if toolsByNamespace[namespace] == nil {
                namespaceOrder.append(namespace)
                toolsByNamespace[namespace] = []
            }
            toolsByNamespace[namespace, default: []].append(function)
        }
        return namespaceOrder.map { namespace in
            .namespace(MCPDeferredNamespaceSpec(
                name: namespace,
                tools: toolsByNamespace[namespace] ?? []))
        }
    }

    static func searchText(
        for entry: MCPToolBindingEntry
    ) -> String {
        var parts = [
            entry.qualifiedName.value,
            entry.qualifiedName.toolAlias,
            entry.remoteTool.remoteName,
            entry.policy.serverAlias,
        ]
        if let title = entry.remoteTool.title?.trimmingCharacters(
            in: .whitespacesAndNewlines),
           !title.isEmpty {
            parts.append(title)
        }
        let summary = entry.remoteTool.summary.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            parts.append(summary)
        }
        parts.append(contentsOf: Self.propertyNames(
            entry.remoteTool.inputSchema))
        return parts.joined(separator: " ")
    }

    private static func propertyNames(
        _ schema: JSONValue
    ) -> [String] {
        guard case .object(let object) = schema,
              case .object(let properties)? = object["properties"] else {
            return []
        }
        return properties.keys.sorted()
    }
}

/// Session-owned mutable load state. Replacing the Agent view atomically
/// clears every loaded spec, and old search registrations fail on the exact
/// catalog fingerprint instead of searching the replacement index.
public actor MCPToolSearchCatalogState {
    private var index: MCPToolSearchIndex
    private var loadedQualifiedNames: [String] = []

    public init(view: MCPAgentToolCatalogView) {
        index = MCPToolSearchIndex(view: view)
    }

    func replace(with view: MCPAgentToolCatalogView) {
        index = MCPToolSearchIndex(view: view)
        loadedQualifiedNames.removeAll(keepingCapacity: false)
    }

    func search(
        expectedCatalogFingerprint: String,
        query: String,
        limit: Int?,
        namespaceTools: Bool = true
    ) throws -> MCPToolSearchResult {
        let result = try previewSearch(
            expectedCatalogFingerprint:
                expectedCatalogFingerprint,
            query: query,
            limit: limit,
            namespaceTools: namespaceTools)
        recordLoaded(
            result.matches.map(\.qualifiedName))
        return result
    }

    /// Produces an immutable search result without widening the loaded-tool
    /// state. The executable tool uses this form so encoding and all output
    /// budgets succeed before the result becomes callable.
    fileprivate func previewSearch(
        expectedCatalogFingerprint: String,
        query: String,
        limit: Int?,
        namespaceTools: Bool = true
    ) throws -> MCPToolSearchResult {
        try validate(expectedCatalogFingerprint)
        return try index.search(
            query: query,
            limit: limit,
            namespaceTools: namespaceTools)
    }

    fileprivate func commitLoadedTools(
        expectedCatalogFingerprint: String,
        qualifiedNames: [String]
    ) throws {
        try validate(expectedCatalogFingerprint)
        recordLoaded(qualifiedNames)
    }

    func loadedTools(
        expectedCatalogFingerprint: String,
        namespaceTools: Bool = true
    ) throws -> [MCPDeferredToolSpec] {
        try validate(expectedCatalogFingerprint)
        return index.loadableTools(
            qualifiedNames: loadedQualifiedNames,
            namespaceTools: namespaceTools)
    }

    func currentCatalogFingerprint() -> String {
        index.catalogFingerprint
    }

    private func validate(_ expected: String) throws {
        guard expected == index.catalogFingerprint else {
            throw MCPToolSearchError.staleCatalog(
                expected: expected,
                actual: index.catalogFingerprint)
        }
    }

    private func recordLoaded(
        _ qualifiedNames: [String]
    ) {
        for name in qualifiedNames
        where !loadedQualifiedNames.contains(name) {
            loadedQualifiedNames.append(name)
        }
    }
}

public struct MCPToolSearchExposure: Sendable {
    public let registry: ToolRegistry
    public let searchDescriptor: ToolDescriptor
    let state: MCPToolSearchCatalogState
    public let catalogFingerprint: String

    public func loadedTools(
        namespaceTools: Bool = true
    ) async throws -> [MCPDeferredToolSpec] {
        try await state.loadedTools(
            expectedCatalogFingerprint: catalogFingerprint,
            namespaceTools: namespaceTools)
    }
}

private struct MCPToolSearchTool: Tool, Sendable {
    static let descriptor = ToolDescriptor(
        name: MCPToolSearchConstants.toolName,
        description: MCPToolSearchConstants.description(sources: []),
        sideEffect: .readOnly,
        parameters: MCPToolSearchConstants.parameters,
        modelSpecKind: .toolSearch,
        supportsParallelCalls: true)

    let state: MCPToolSearchCatalogState
    let expectedCatalogFingerprint: String
    let namespaceTools: Bool
    let resultConverter: MCPToolResultConverter

    func permissionIntent(
        _ args: ToolArgs,
        descriptor: ToolDescriptor,
        workspaceRoot _: URL
    ) -> PermissionIntent {
        PermissionIntent(
            action: "tool.discovery.search",
            resources: [
                PermissionResource(kind: .tool, value: descriptor.name),
            ],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    func execute(
        _ args: ToolArgs,
        in _: ToolContext
    ) async throws -> ToolObservation {
        let decoded: MCPToolSearchArguments
        do {
            decoded = try Self.decode(args)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "tool_search_invalid_arguments",
                message: error.localizedDescription)
        }
        let result: MCPToolSearchResult
        do {
            result = try await state.previewSearch(
                expectedCatalogFingerprint:
                    expectedCatalogFingerprint,
                query: decoded.query,
                limit: decoded.limit,
                namespaceTools: namespaceTools)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "tool_search_failed",
                message: error.localizedDescription)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "tool_search_encoding_failed",
                message: "tool_search result is not UTF-8")
        }
        let toolSearchOutput = ModelToolSearchOutput(
            tools: result.loadableTools.map(\.responsesJSON))
        let nativeData = try encoder.encode(
            toolSearchOutput)
        guard data.count <= Int.max - nativeData.count else {
            throw MCPToolExecutionError
                .resultTooLarge(
                    maximum:
                        resultConverter
                            .limits
                            .maximumTotalBytes)
        }
        try resultConverter
            .reserveCanonicalOutputBytes(
                data.count + nativeData.count)
        try await state.commitLoadedTools(
            expectedCatalogFingerprint:
                expectedCatalogFingerprint,
            qualifiedNames:
                result.matches.map(\.qualifiedName))
        return ToolObservation(
            text: text,
            toolSearchOutput: toolSearchOutput)
    }

    static func validateArguments(_ args: ToolArgs) throws {
        _ = try decode(args)
    }

    private static func decode(
        _ args: ToolArgs
    ) throws -> MCPToolSearchArguments {
        let decoded = try args.decode(MCPToolSearchArguments.self)
        let query = decoded.query.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw MCPToolSearchError.emptyQuery
        }
        if let limit = decoded.limit, limit <= 0 {
            throw MCPToolSearchError.invalidLimit
        }
        return MCPToolSearchArguments(
            query: query,
            limit: decoded.limit)
    }
}

public extension MCPToolRegistryBuilder {
    static func buildSearchable(
        base: ToolRegistry,
        view: MCPAgentToolCatalogView,
        resultConverter: MCPToolResultConverter,
        namespaceTools: Bool = true,
        executionPreflight:
            @escaping @Sendable (
                MCPToolBindingEntry
            ) async throws -> Void = { _ in }
    ) -> MCPToolSearchExposure {
        let state = MCPToolSearchCatalogState(view: view)
        let sources = view.entries.map {
            MCPToolSearchSource(name: $0.policy.serverAlias)
        }
        let searchDescriptor = ToolDescriptor(
            name: MCPToolSearchConstants.toolName,
            description: MCPToolSearchConstants.description(
                sources: sources),
            sideEffect: .readOnly,
            parameters: MCPToolSearchConstants.parameters,
            modelSpecKind: .toolSearch,
            strict: nil,
            deferLoading: nil,
            outputSchema: nil,
            supportsParallelCalls: true)
        let searchTool = MCPToolSearchTool(
            state: state,
            expectedCatalogFingerprint: view.stableFingerprint,
            namespaceTools: namespaceTools,
            resultConverter: resultConverter)
        let deferredRegistry = build(
            base: base,
            view: view,
            resultConverter: resultConverter,
            deferLoading: true,
            executionPreflight: executionPreflight)
        let version = IntatisHostApplication.identity
            .namespacedIdentifier("mcp.registry.search.v1.") + stableHash([
            deferredRegistry.registryVersion,
            view.stableFingerprint,
            namespaceTools ? "namespace" : "function",
        ])
        let registry = deferredRegistry.adding(
            registrations: [
                ToolRegistration(
                    descriptor: searchDescriptor,
                    tool: searchTool,
                    canonicalPermission: "tool.discovery.search",
                    argumentValidator: { args in
                        try MCPToolSearchTool.validateArguments(args)
                    }),
            ],
            registryVersion: version)
        return MCPToolSearchExposure(
            registry: registry,
            searchDescriptor: searchDescriptor,
            state: state,
            catalogFingerprint: view.stableFingerprint)
    }
}
