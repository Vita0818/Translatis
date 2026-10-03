#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol
import MCP

public enum MCPToolTaskSupport:
    String, Codable, Equatable, Hashable, Sendable {
    case required
    case optional
    case forbidden
}

public struct MCPRawToolAnnotations:
    Codable, Equatable, Hashable, Sendable {
    public let title: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

public struct MCPRawToolIcon:
    Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let mimeType: String?
    public let sizes: [String]?
    public let theme: String?

    public init(
        source: String,
        mimeType: String? = nil,
        sizes: [String]? = nil,
        theme: String? = nil
    ) {
        self.source = source
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }
}

/// Complete SDK-independent record retained in the immutable raw catalog.
///
/// `_meta` is deliberately excluded from model and permission surfaces. The
/// validated input schema is the only schema advertised as function
/// parameters; output schema and annotations remain execution metadata.
public struct MCPRawToolRecord: Codable, Equatable, Sendable {
    public let remoteName: String
    public let title: String?
    public let summary: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let annotations: MCPRawToolAnnotations
    public let icons: [MCPRawToolIcon]
    public let taskSupport: MCPToolTaskSupport?
    public let inputSchemaHash: String
    public let outputSchemaHash: String?
    public let identityFingerprint: String

    public init(
        remoteName: String,
        title: String? = nil,
        summary: String = "",
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        annotations: MCPRawToolAnnotations = .init(),
        icons: [MCPRawToolIcon] = [],
        taskSupport: MCPToolTaskSupport? = nil
    ) throws {
        try MCPConfigurationValidation.validateRemoteName(remoteName)
        guard summary.utf8.count <= MCPToolCatalogLimits.maximumDescriptionBytes,
              (title?.utf8.count ?? 0)
                <= MCPToolCatalogLimits.maximumTitleBytes,
              icons.count <= MCPToolCatalogLimits.maximumIconsPerTool else {
            throw MCPToolCatalogError.itemTooLarge(remoteName)
        }
        try MCPJSONSchema.validateSchema(
            inputSchema,
            rootMustBeObject: true)
        if let outputSchema {
            try MCPJSONSchema.validateSchema(
                outputSchema,
                rootMustBeObject: true)
        }
        for icon in icons {
            guard icon.source.utf8.count
                    <= MCPToolCatalogLimits.maximumIconSourceBytes,
                  (icon.mimeType?.utf8.count ?? 0) <= 256,
                  (icon.sizes?.count ?? 0) <= 64,
                  (icon.theme?.utf8.count ?? 0) <= 32 else {
                throw MCPToolCatalogError.itemTooLarge(remoteName)
            }
        }

        self.remoteName = remoteName
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.icons = icons
        self.taskSupport = taskSupport
        inputSchemaHash = try MCPJSONSchema.hash(inputSchema)
        outputSchemaHash = try outputSchema.map(MCPJSONSchema.hash)
        identityFingerprint = try Self.identityFingerprint(
            remoteName: remoteName,
            title: title,
            summary: summary,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            annotations: annotations,
            icons: icons,
            taskSupport: taskSupport)
    }

    public func validated() throws -> MCPRawToolRecord {
        let rebuilt = try MCPRawToolRecord(
            remoteName: remoteName,
            title: title,
            summary: summary,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            annotations: annotations,
            icons: icons,
            taskSupport: taskSupport)
        guard rebuilt == self else {
            throw MCPToolCatalogError.recordFingerprintMismatch(remoteName)
        }
        return rebuilt
    }

    private struct IdentityMaterial: Encodable {
        let remoteName: String
        let title: String?
        let summary: String
        let inputSchema: JSONValue
        let outputSchema: JSONValue?
        let annotations: MCPRawToolAnnotations
        let icons: [MCPRawToolIcon]
        let taskSupport: MCPToolTaskSupport?
    }

    private static func identityFingerprint(
        remoteName: String,
        title: String?,
        summary: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue?,
        annotations: MCPRawToolAnnotations,
        icons: [MCPRawToolIcon],
        taskSupport: MCPToolTaskSupport?
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(IdentityMaterial(
            remoteName: remoteName,
            title: title,
            summary: summary,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            annotations: annotations,
            icons: icons,
            taskSupport: taskSupport))
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct MCPToolListPage: Equatable, Sendable {
    public let tools: [MCPRawToolRecord]
    public let nextCursor: String?

    public init(
        tools: [MCPRawToolRecord],
        nextCursor: String? = nil
    ) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

public struct MCPToolCatalogDiscoveryLimits: Equatable, Sendable {
    public let maximumPages: Int
    public let maximumTools: Int
    public let maximumToolsPerPage: Int
    public let maximumCatalogBytes: Int
    public let maximumCursorBytes: Int

    public init(
        maximumPages: Int = 1_024,
        maximumTools: Int = 10_000,
        maximumToolsPerPage: Int = 1_000,
        maximumCatalogBytes: Int = 32 * 1_024 * 1_024,
        maximumCursorBytes: Int = 4_096
    ) {
        self.maximumPages = maximumPages
        self.maximumTools = maximumTools
        self.maximumToolsPerPage = maximumToolsPerPage
        self.maximumCatalogBytes = maximumCatalogBytes
        self.maximumCursorBytes = maximumCursorBytes
    }
}

public enum MCPToolCatalogError:
    Error, Equatable, LocalizedError, Sendable {
    case tooManyPages(maximum: Int)
    case tooManyTools(maximum: Int)
    case pageTooLarge(actual: Int, maximum: Int)
    case catalogTooLarge(actual: Int, maximum: Int)
    case invalidCursor
    case cursorCycle(String)
    case duplicateTool(String)
    case itemTooLarge(String)
    case recordFingerprintMismatch(String)
    case completeSnapshotMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .tooManyPages(let maximum):
            return "tools/list exceeded \(maximum) pages"
        case .tooManyTools(let maximum):
            return "tools/list exceeded \(maximum) tools"
        case .pageTooLarge(let actual, let maximum):
            return "tools/list page contains \(actual) tools; maximum is \(maximum)"
        case .catalogTooLarge(let actual, let maximum):
            return "tools/list catalog is \(actual) bytes; maximum is \(maximum)"
        case .invalidCursor:
            return "tools/list returned an invalid opaque cursor"
        case .cursorCycle:
            return "tools/list repeated an opaque cursor"
        case .duplicateTool(let name):
            return "tools/list returned duplicate tool '\(name)'"
        case .itemTooLarge(let name):
            return "tools/list item '\(name)' exceeds a bounded metadata limit"
        case .recordFingerprintMismatch(let name):
            return "tools/list item '\(name)' failed fingerprint validation"
        case .completeSnapshotMismatch(let reason):
            return "complete MCP catalog snapshot is inconsistent: \(reason)"
        }
    }
}

public enum MCPToolCatalogLimits {
    public static let maximumDescriptionBytes = 64 * 1_024
    public static let maximumTitleBytes = 4 * 1_024
    public static let maximumIconsPerTool = 32
    public static let maximumIconSourceBytes = 16 * 1_024
}

/// Fetches every tools/list page into private staging and publishes only after
/// all records, cursors, hashes, limits and duplicates have passed.
public enum MCPToolCatalogDiscovery {
    public typealias PageLoader =
        @Sendable (_ cursor: String?) async throws -> MCPToolListPage

    public static func discover(
        revision: MCPRawCatalogRevision = MCPRawCatalogRevision(
            rawValue: IDGen.random(prefix: "mcpcatalog")),
        limits: MCPToolCatalogDiscoveryLimits = .init(),
        loadPage: PageLoader
    ) async throws -> MCPCompleteCatalogSnapshot {
        var staged: [MCPRawToolRecord] = []
        var seenNames: Set<String> = []
        var seenCursors: Set<String> = []
        var cursor: String?
        var pageCount = 0
        var totalBytes = 0

        while true {
            pageCount += 1
            guard pageCount <= limits.maximumPages else {
                throw MCPToolCatalogError.tooManyPages(
                    maximum: limits.maximumPages)
            }
            let page = try await loadPage(cursor)
            guard page.tools.count <= limits.maximumToolsPerPage else {
                throw MCPToolCatalogError.pageTooLarge(
                    actual: page.tools.count,
                    maximum: limits.maximumToolsPerPage)
            }
            for supplied in page.tools {
                let tool = try supplied.validated()
                guard seenNames.insert(tool.remoteName).inserted else {
                    throw MCPToolCatalogError.duplicateTool(tool.remoteName)
                }
                totalBytes += try encodedSize(tool)
                guard totalBytes <= limits.maximumCatalogBytes else {
                    throw MCPToolCatalogError.catalogTooLarge(
                        actual: totalBytes,
                        maximum: limits.maximumCatalogBytes)
                }
                staged.append(tool)
                guard staged.count <= limits.maximumTools else {
                    throw MCPToolCatalogError.tooManyTools(
                        maximum: limits.maximumTools)
                }
            }

            guard let next = page.nextCursor else { break }
            guard !next.isEmpty,
                  next.utf8.count <= limits.maximumCursorBytes,
                  !next.contains("\0"),
                  !next.contains(where: \.isNewline) else {
                throw MCPToolCatalogError.invalidCursor
            }
            guard seenCursors.insert(next).inserted else {
                throw MCPToolCatalogError.cursorCycle(next)
            }
            cursor = next
        }

        let ordered = staged.sorted {
            if $0.remoteName != $1.remoteName {
                return $0.remoteName < $1.remoteName
            }
            return $0.identityFingerprint < $1.identityFingerprint
        }
        let catalogFingerprint = try fingerprint(ordered)
        let items = ordered.map {
            MCPPublishedCatalogItem(
                kind: .tool,
                remoteName: $0.remoteName,
                identityFingerprint: $0.identityFingerprint,
                schemaHash: $0.inputSchemaHash)
        }
        return try MCPCompleteCatalogSnapshot(
            revision: revision,
            catalogFingerprint: catalogFingerprint,
            items: items,
            tools: ordered)
    }

    private static func encodedSize<T: Encodable>(_ value: T) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value).count
    }

    private static func fingerprint(
        _ tools: [MCPRawToolRecord]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(tools)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Pinned SDK bridge

public extension MCPRawToolRecord {
    init(sdkTool: MCP.Tool) throws {
        try self.init(
            sdkTool: sdkTool,
            sanitizer:
                MCPConservativeToolResultSanitizer())
    }

    init(
        sdkTool: MCP.Tool,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws {
        let remoteName =
            try MCPOutputSanitization
                .requireUnchangedIdentifier(
                    sdkTool.name,
                    using: sanitizer)
        let rawInput =
            try MCPJSONValueBridge.fromSDK(
                sdkTool.inputSchema)
        let input =
            try MCPOutputSanitization
                .sanitizeJSON(
                    rawInput,
                    using: sanitizer)
        let output = try sdkTool.outputSchema.map {
            try MCPOutputSanitization
                .sanitizeJSON(
                    MCPJSONValueBridge.fromSDK($0),
                    using: sanitizer)
        }
        let taskSupport = sdkTool.execution?.taskSupport.map {
            MCPToolTaskSupport(rawValue: $0.rawValue)!
        }
        try self.init(
            remoteName: remoteName,
            title: try sdkTool.title.map(
                sanitizer.sanitizeMCPText),
            summary: try sanitizer
                .sanitizeMCPText(
                    sdkTool.description ?? ""),
            inputSchema: input,
            outputSchema: output,
            annotations: MCPRawToolAnnotations(
                title: try sdkTool.annotations.title.map(
                    sanitizer.sanitizeMCPText),
                readOnlyHint: sdkTool.annotations.readOnlyHint,
                destructiveHint: sdkTool.annotations.destructiveHint,
                idempotentHint: sdkTool.annotations.idempotentHint,
                openWorldHint: sdkTool.annotations.openWorldHint),
            icons: try (sdkTool.icons ?? []).map {
                let source =
                    try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            $0.src,
                            using: sanitizer)
                return MCPRawToolIcon(
                    source: source,
                    mimeType: $0.mimeType,
                    sizes: $0.sizes,
                    theme: $0.theme?.rawValue)
            },
            taskSupport: taskSupport)
    }
}

enum MCPJSONValueBridge {
    static func fromSDK(_ value: MCP.Value) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func toSDK(_ value: JSONValue) throws -> MCP.Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCP.Value.self, from: data)
    }
}
