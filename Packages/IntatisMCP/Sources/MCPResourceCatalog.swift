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

public struct MCPRawResourceAnnotations:
    Codable, Equatable, Hashable, Sendable {
    public let audience: [String]
    public let priority: Double?
    public let lastModified: String?

    public init(
        audience: [String] = [],
        priority: Double? = nil,
        lastModified: String? = nil
    ) {
        self.audience = Array(Set(audience)).sorted()
        self.priority = priority
        self.lastModified = lastModified
    }
}

public struct MCPRawCatalogIcon:
    Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let mimeType: String?
    public let sizes: [String]
    public let theme: String?

    public init(
        source: String,
        mimeType: String? = nil,
        sizes: [String] = [],
        theme: String? = nil
    ) {
        self.source = source
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }
}

public enum MCPResourceCatalogLimits {
    public static let maximumNameBytes = 4 * 1_024
    public static let maximumDescriptionBytes = 64 * 1_024
    public static let maximumURIBytes = 16 * 1_024
    public static let maximumIcons = 32
    public static let maximumIconSourceBytes = 16 * 1_024
    public static let maximumPromptArguments = 256
}

public enum MCPResourceCatalogError:
    Error, Equatable, LocalizedError, Sendable {
    case invalidName
    case invalidURI(String)
    case invalidSize
    case invalidAnnotation
    case itemTooLarge(String)
    case tooManyPages(maximum: Int)
    case tooManyItems(kind: String, maximum: Int)
    case pageTooLarge(kind: String, actual: Int, maximum: Int)
    case catalogTooLarge(actual: Int, maximum: Int)
    case invalidCursor
    case cursorCycle(String)
    case duplicateItem(kind: String, identity: String)
    case fingerprintMismatch(String)
    case completeSnapshotMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "MCP catalog item has an invalid name"
        case .invalidURI(let uri):
            return "MCP catalog contains an invalid or unsafe URI: \(uri.prefix(128))"
        case .invalidSize:
            return "MCP resource contains an invalid size"
        case .invalidAnnotation:
            return "MCP resource contains an invalid annotation"
        case .itemTooLarge(let identity):
            return "MCP catalog item '\(identity)' exceeds a bounded metadata limit"
        case .tooManyPages(let maximum):
            return "MCP catalog discovery exceeded \(maximum) pages"
        case .tooManyItems(let kind, let maximum):
            return "MCP \(kind) discovery exceeded \(maximum) items"
        case .pageTooLarge(let kind, let actual, let maximum):
            return "MCP \(kind) page contains \(actual) items; maximum is \(maximum)"
        case .catalogTooLarge(let actual, let maximum):
            return "MCP catalog is \(actual) bytes; maximum is \(maximum)"
        case .invalidCursor:
            return "MCP catalog returned an invalid opaque cursor"
        case .cursorCycle:
            return "MCP catalog repeated an opaque cursor"
        case .duplicateItem(let kind, let identity):
            return "MCP \(kind) discovery returned duplicate '\(identity)'"
        case .fingerprintMismatch(let identity):
            return "MCP catalog item '\(identity)' failed fingerprint validation"
        case .completeSnapshotMismatch(let reason):
            return "complete MCP catalog snapshot is inconsistent: \(reason)"
        }
    }
}

public struct MCPRawResourceRecord:
    Codable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let uri: String
    public let summary: String?
    public let mimeType: String?
    public let size: Int?
    public let annotations: MCPRawResourceAnnotations?
    public let icons: [MCPRawCatalogIcon]
    public let identityFingerprint: String

    public init(
        name: String,
        uri: String,
        title: String? = nil,
        summary: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: MCPRawResourceAnnotations? = nil,
        icons: [MCPRawCatalogIcon] = []
    ) throws {
        try MCPRawCatalogValidation.validateName(name)
        try MCPRawCatalogValidation.validateURI(uri)
        try MCPRawCatalogValidation.validateMetadata(
            identity: uri,
            title: title,
            summary: summary,
            mimeType: mimeType,
            icons: icons)
        guard size.map({ $0 >= 0 }) ?? true else {
            throw MCPResourceCatalogError.invalidSize
        }
        try MCPRawCatalogValidation.validateAnnotations(annotations)
        self.name = name
        self.title = title
        self.uri = uri
        self.summary = summary
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self.icons = icons
        identityFingerprint = try MCPRawCatalogHash.hash(
            ResourceIdentity(
                name: name,
                title: title,
                uri: uri,
                summary: summary,
                mimeType: mimeType,
                size: size,
                annotations: annotations,
                icons: icons))
    }

    public func validated() throws -> Self {
        let rebuilt = try Self(
            name: name,
            uri: uri,
            title: title,
            summary: summary,
            mimeType: mimeType,
            size: size,
            annotations: annotations,
            icons: icons)
        guard rebuilt == self else {
            throw MCPResourceCatalogError.fingerprintMismatch(uri)
        }
        return rebuilt
    }

    public func modelJSON(serverAlias: String) -> JSONValue {
        var fields: [String: JSONValue] = [
            "server": .string(serverAlias),
            "name": .string(name),
            "uri": .string(uri),
        ]
        if let title { fields["title"] = .string(title) }
        if let summary { fields["description"] = .string(summary) }
        if let mimeType { fields["mimeType"] = .string(mimeType) }
        if let size { fields["size"] = .number(Double(size)) }
        if let annotations {
            fields["annotations"] = annotations.json
        }
        if !icons.isEmpty {
            fields["icons"] = .array(icons.map(\.json))
        }
        return .object(fields)
    }

    private struct ResourceIdentity: Encodable {
        let name: String
        let title: String?
        let uri: String
        let summary: String?
        let mimeType: String?
        let size: Int?
        let annotations: MCPRawResourceAnnotations?
        let icons: [MCPRawCatalogIcon]
    }
}

public struct MCPRawResourceTemplateRecord:
    Codable, Equatable, Sendable {
    public let uriTemplate: String
    public let name: String
    public let title: String?
    public let summary: String?
    public let mimeType: String?
    public let annotations: MCPRawResourceAnnotations?
    public let icons: [MCPRawCatalogIcon]
    public let identityFingerprint: String

    public init(
        uriTemplate: String,
        name: String,
        title: String? = nil,
        summary: String? = nil,
        mimeType: String? = nil,
        annotations: MCPRawResourceAnnotations? = nil,
        icons: [MCPRawCatalogIcon] = []
    ) throws {
        try MCPRawCatalogValidation.validateName(name)
        try MCPRawCatalogValidation.validateURITemplate(uriTemplate)
        try MCPRawCatalogValidation.validateMetadata(
            identity: uriTemplate,
            title: title,
            summary: summary,
            mimeType: mimeType,
            icons: icons)
        try MCPRawCatalogValidation.validateAnnotations(annotations)
        self.uriTemplate = uriTemplate
        self.name = name
        self.title = title
        self.summary = summary
        self.mimeType = mimeType
        self.annotations = annotations
        self.icons = icons
        identityFingerprint = try MCPRawCatalogHash.hash(
            TemplateIdentity(
                uriTemplate: uriTemplate,
                name: name,
                title: title,
                summary: summary,
                mimeType: mimeType,
                annotations: annotations,
                icons: icons))
    }

    public func validated() throws -> Self {
        let rebuilt = try Self(
            uriTemplate: uriTemplate,
            name: name,
            title: title,
            summary: summary,
            mimeType: mimeType,
            annotations: annotations,
            icons: icons)
        guard rebuilt == self else {
            throw MCPResourceCatalogError.fingerprintMismatch(uriTemplate)
        }
        return rebuilt
    }

    public func modelJSON(serverAlias: String) -> JSONValue {
        var fields: [String: JSONValue] = [
            "server": .string(serverAlias),
            "uriTemplate": .string(uriTemplate),
            "name": .string(name),
        ]
        if let title { fields["title"] = .string(title) }
        if let summary { fields["description"] = .string(summary) }
        if let mimeType { fields["mimeType"] = .string(mimeType) }
        if let annotations {
            fields["annotations"] = annotations.json
        }
        if !icons.isEmpty {
            fields["icons"] = .array(icons.map(\.json))
        }
        return .object(fields)
    }

    private struct TemplateIdentity: Encodable {
        let uriTemplate: String
        let name: String
        let title: String?
        let summary: String?
        let mimeType: String?
        let annotations: MCPRawResourceAnnotations?
        let icons: [MCPRawCatalogIcon]
    }
}

public struct MCPRawPromptArgument:
    Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let title: String?
    public let summary: String?
    public let required: Bool

    public init(
        name: String,
        title: String? = nil,
        summary: String? = nil,
        required: Bool = false
    ) throws {
        try MCPRawCatalogValidation.validateName(name)
        guard (title?.utf8.count ?? 0)
                <= MCPResourceCatalogLimits.maximumNameBytes,
              (summary?.utf8.count ?? 0)
                <= MCPResourceCatalogLimits.maximumDescriptionBytes else {
            throw MCPResourceCatalogError.itemTooLarge(name)
        }
        self.name = name
        self.title = title
        self.summary = summary
        self.required = required
    }
}

public struct MCPRawPromptRecord:
    Codable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let summary: String?
    public let arguments: [MCPRawPromptArgument]
    public let icons: [MCPRawCatalogIcon]
    public let identityFingerprint: String

    public init(
        name: String,
        title: String? = nil,
        summary: String? = nil,
        arguments: [MCPRawPromptArgument] = [],
        icons: [MCPRawCatalogIcon] = []
    ) throws {
        try MCPRawCatalogValidation.validateName(name)
        try MCPRawCatalogValidation.validateMetadata(
            identity: name,
            title: title,
            summary: summary,
            mimeType: nil,
            icons: icons)
        guard arguments.count
                <= MCPResourceCatalogLimits.maximumPromptArguments,
              Set(arguments.map(\.name)).count == arguments.count else {
            throw MCPResourceCatalogError.itemTooLarge(name)
        }
        self.name = name
        self.title = title
        self.summary = summary
        self.arguments = arguments.sorted { $0.name < $1.name }
        self.icons = icons
        identityFingerprint = try MCPRawCatalogHash.hash(
            PromptIdentity(
                name: name,
                title: title,
                summary: summary,
                arguments: self.arguments,
                icons: icons))
    }

    public func validated() throws -> Self {
        let rebuilt = try Self(
            name: name,
            title: title,
            summary: summary,
            arguments: arguments,
            icons: icons)
        guard rebuilt == self else {
            throw MCPResourceCatalogError.fingerprintMismatch(name)
        }
        return rebuilt
    }

    private struct PromptIdentity: Encodable {
        let name: String
        let title: String?
        let summary: String?
        let arguments: [MCPRawPromptArgument]
        let icons: [MCPRawCatalogIcon]
    }
}

public struct MCPResourceListPage: Equatable, Sendable {
    public let resources: [MCPRawResourceRecord]
    public let nextCursor: String?

    public init(
        resources: [MCPRawResourceRecord],
        nextCursor: String? = nil
    ) {
        self.resources = resources
        self.nextCursor = nextCursor
    }
}

public struct MCPResourceTemplateListPage: Equatable, Sendable {
    public let templates: [MCPRawResourceTemplateRecord]
    public let nextCursor: String?

    public init(
        templates: [MCPRawResourceTemplateRecord],
        nextCursor: String? = nil
    ) {
        self.templates = templates
        self.nextCursor = nextCursor
    }
}

public struct MCPPromptListPage: Equatable, Sendable {
    public let prompts: [MCPRawPromptRecord]
    public let nextCursor: String?

    public init(
        prompts: [MCPRawPromptRecord],
        nextCursor: String? = nil
    ) {
        self.prompts = prompts
        self.nextCursor = nextCursor
    }
}

public struct MCPFullCatalogDiscoveryLimits: Equatable, Sendable {
    public let maximumPagesPerCategory: Int
    public let maximumItemsPerCategory: Int
    public let maximumItemsPerPage: Int
    public let maximumCatalogBytes: Int
    public let maximumCursorBytes: Int

    public init(
        maximumPagesPerCategory: Int = 1_024,
        maximumItemsPerCategory: Int = 10_000,
        maximumItemsPerPage: Int = 1_000,
        maximumCatalogBytes: Int = 64 * 1_024 * 1_024,
        maximumCursorBytes: Int = 4_096
    ) {
        self.maximumPagesPerCategory = maximumPagesPerCategory
        self.maximumItemsPerCategory = maximumItemsPerCategory
        self.maximumItemsPerPage = maximumItemsPerPage
        self.maximumCatalogBytes = maximumCatalogBytes
        self.maximumCursorBytes = maximumCursorBytes
    }
}

/// Builds every negotiated catalog category in private staging and creates one
/// immutable raw revision only after all categories have completed.
public enum MCPFullCatalogDiscovery {
    public typealias ToolLoader =
        @Sendable (String?) async throws -> MCPToolListPage
    public typealias ResourceLoader =
        @Sendable (String?) async throws -> MCPResourceListPage
    public typealias TemplateLoader =
        @Sendable (String?) async throws -> MCPResourceTemplateListPage
    public typealias PromptLoader =
        @Sendable (String?) async throws -> MCPPromptListPage

    public static func discover(
        capabilities: MCPNegotiatedCapabilitySet,
        revision: MCPRawCatalogRevision = .init(
            rawValue: IDGen.random(prefix: "mcpcatalog")),
        limits: MCPFullCatalogDiscoveryLimits = .init(),
        listToolsPage: @escaping ToolLoader,
        listResourcesPage: @escaping ResourceLoader,
        listResourceTemplatesPage: @escaping TemplateLoader,
        listPromptsPage: @escaping PromptLoader
    ) async throws -> MCPCompleteCatalogSnapshot {
        let capabilitySet = capabilities.capabilities

        async let toolResult: MCPCompleteCatalogSnapshot =
            capabilitySet.contains(.tools)
            ? MCPToolCatalogDiscovery.discover(
                revision: revision,
                loadPage: listToolsPage)
            : emptyToolSnapshot(revision: revision)
        async let resourcesResult: [MCPRawResourceRecord] =
            capabilitySet.contains(.resources)
            ? discoverResources(limits: limits, loadPage: listResourcesPage)
            : []
        async let templatesResult: [MCPRawResourceTemplateRecord] =
            capabilitySet.contains(.resources)
            ? discoverTemplates(
                limits: limits,
                loadPage: listResourceTemplatesPage)
            : []
        async let promptsResult: [MCPRawPromptRecord] =
            capabilitySet.contains(.prompts)
            ? discoverPrompts(limits: limits, loadPage: listPromptsPage)
            : []

        let (toolSnapshot, resources, templates, prompts) =
            try await (
                toolResult,
                resourcesResult,
                templatesResult,
                promptsResult)

        let tools = toolSnapshot.tools
        let material = FullCatalogMaterial(
            tools: tools,
            resources: resources,
            resourceTemplates: templates,
            prompts: prompts)
        let encoded = try MCPRawCatalogHash.encoded(material)
        guard encoded.count <= limits.maximumCatalogBytes else {
            throw MCPResourceCatalogError.catalogTooLarge(
                actual: encoded.count,
                maximum: limits.maximumCatalogBytes)
        }

        var items = toolSnapshot.items
        items.append(contentsOf: resources.map {
            MCPPublishedCatalogItem(
                kind: .resource,
                remoteName: $0.uri,
                identityFingerprint: $0.identityFingerprint)
        })
        items.append(contentsOf: templates.map {
            MCPPublishedCatalogItem(
                kind: .resourceTemplate,
                remoteName: $0.uriTemplate,
                identityFingerprint: $0.identityFingerprint)
        })
        items.append(contentsOf: prompts.map {
            MCPPublishedCatalogItem(
                kind: .prompt,
                remoteName: $0.name,
                identityFingerprint: $0.identityFingerprint)
        })
        return try MCPCompleteCatalogSnapshot(
            revision: revision,
            catalogFingerprint: MCPRawCatalogHash.sha256(encoded),
            items: items,
            tools: tools,
            resources: resources,
            resourceTemplates: templates,
            prompts: prompts)
    }

    public static func discoverResources(
        limits: MCPFullCatalogDiscoveryLimits = .init(),
        loadPage: @escaping ResourceLoader
    ) async throws -> [MCPRawResourceRecord] {
        try await discoverPages(
            kind: "resources",
            limits: limits,
            load: loadPage,
            values: \.resources,
            cursor: \.nextCursor,
            identity: \.uri,
            validate: { try $0.validated() })
    }

    public static func discoverTemplates(
        limits: MCPFullCatalogDiscoveryLimits = .init(),
        loadPage: @escaping TemplateLoader
    ) async throws -> [MCPRawResourceTemplateRecord] {
        try await discoverPages(
            kind: "resource_templates",
            limits: limits,
            load: loadPage,
            values: \.templates,
            cursor: \.nextCursor,
            identity: \.uriTemplate,
            validate: { try $0.validated() })
    }

    public static func discoverPrompts(
        limits: MCPFullCatalogDiscoveryLimits = .init(),
        loadPage: @escaping PromptLoader
    ) async throws -> [MCPRawPromptRecord] {
        try await discoverPages(
            kind: "prompts",
            limits: limits,
            load: loadPage,
            values: \.prompts,
            cursor: \.nextCursor,
            identity: \.name,
            validate: { try $0.validated() })
    }

    private static func emptyToolSnapshot(
        revision: MCPRawCatalogRevision
    ) throws -> MCPCompleteCatalogSnapshot {
        try MCPCompleteCatalogSnapshot(
            revision: revision,
            catalogFingerprint: MCPRawCatalogHash.sha256(Data()),
            items: [])
    }

    private static func discoverPages<Page, Item>(
        kind: String,
        limits: MCPFullCatalogDiscoveryLimits,
        load: @escaping @Sendable (String?) async throws -> Page,
        values: KeyPath<Page, [Item]>,
        cursor: KeyPath<Page, String?>,
        identity: KeyPath<Item, String>,
        validate: (Item) throws -> Item
    ) async throws -> [Item] {
        var next: String?
        var seenCursors: Set<String> = []
        var seenItems: Set<String> = []
        var result: [Item] = []
        var pageCount = 0

        repeat {
            pageCount += 1
            guard pageCount <= limits.maximumPagesPerCategory else {
                throw MCPResourceCatalogError.tooManyPages(
                    maximum: limits.maximumPagesPerCategory)
            }
            let page = try await load(next)
            let pageValues = page[keyPath: values]
            guard pageValues.count <= limits.maximumItemsPerPage else {
                throw MCPResourceCatalogError.pageTooLarge(
                    kind: kind,
                    actual: pageValues.count,
                    maximum: limits.maximumItemsPerPage)
            }
            for value in pageValues {
                let validated = try validate(value)
                let key = validated[keyPath: identity]
                guard seenItems.insert(key).inserted else {
                    throw MCPResourceCatalogError.duplicateItem(
                        kind: kind,
                        identity: key)
                }
                result.append(validated)
            }
            guard result.count <= limits.maximumItemsPerCategory else {
                throw MCPResourceCatalogError.tooManyItems(
                    kind: kind,
                    maximum: limits.maximumItemsPerCategory)
            }

            next = page[keyPath: cursor]
            if let next {
                guard !next.isEmpty,
                      next.utf8.count <= limits.maximumCursorBytes,
                      !next.contains("\0"),
                      !next.contains(where: \.isNewline) else {
                    throw MCPResourceCatalogError.invalidCursor
                }
                guard seenCursors.insert(next).inserted else {
                    throw MCPResourceCatalogError.cursorCycle(next)
                }
            }
        } while next != nil

        return result.sorted {
            $0[keyPath: identity] < $1[keyPath: identity]
        }
    }

    private struct FullCatalogMaterial: Encodable {
        let tools: [MCPRawToolRecord]
        let resources: [MCPRawResourceRecord]
        let resourceTemplates: [MCPRawResourceTemplateRecord]
        let prompts: [MCPRawPromptRecord]
    }
}

enum MCPRawCatalogHash {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func hash<T: Encodable>(_ value: T) throws -> String {
        sha256(try encoded(value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum MCPRawCatalogValidation {
    static func validateName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= MCPResourceCatalogLimits.maximumNameBytes,
              !name.contains("\0"),
              !name.contains(where: \.isNewline) else {
            throw MCPResourceCatalogError.invalidName
        }
    }

    static func validateURI(_ uri: String) throws {
        guard uri.utf8.count
                <= MCPResourceCatalogLimits.maximumURIBytes,
              !uri.contains("\0"),
              !uri.contains(where: \.isNewline),
              let components = URLComponents(string: uri),
              let scheme = components.scheme,
              !scheme.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw MCPResourceCatalogError.invalidURI(uri)
        }
    }

    static func validateURITemplate(_ value: String) throws {
        guard value.utf8.count
                <= MCPResourceCatalogLimits.maximumURIBytes,
              !value.contains("\0"),
              !value.contains(where: \.isNewline),
              let schemeEnd = value.firstIndex(of: ":"),
              schemeEnd != value.startIndex else {
            throw MCPResourceCatalogError.invalidURI(value)
        }
        let scheme = value[..<schemeEnd]
        guard scheme.first?.isLetter == true,
              scheme.allSatisfy({
                  $0.isLetter || $0.isNumber
                      || $0 == "+" || $0 == "-" || $0 == "."
              }) else {
            throw MCPResourceCatalogError.invalidURI(value)
        }
    }

    static func validateMetadata(
        identity: String,
        title: String?,
        summary: String?,
        mimeType: String?,
        icons: [MCPRawCatalogIcon]
    ) throws {
        guard (title?.utf8.count ?? 0)
                <= MCPResourceCatalogLimits.maximumNameBytes,
              (summary?.utf8.count ?? 0)
                <= MCPResourceCatalogLimits.maximumDescriptionBytes,
              (mimeType?.utf8.count ?? 0) <= 256,
              icons.count <= MCPResourceCatalogLimits.maximumIcons,
              icons.allSatisfy({
                  !$0.source.isEmpty
                      && $0.source.utf8.count
                          <= MCPResourceCatalogLimits.maximumIconSourceBytes
                      && ($0.mimeType?.utf8.count ?? 0) <= 256
                      && $0.sizes.count <= 64
                      && ($0.theme?.utf8.count ?? 0) <= 32
              }) else {
            throw MCPResourceCatalogError.itemTooLarge(identity)
        }
    }

    static func validateAnnotations(
        _ annotations: MCPRawResourceAnnotations?
    ) throws {
        guard let annotations else { return }
        guard annotations.audience.allSatisfy({
            $0 == "user" || $0 == "assistant"
        }),
        annotations.priority.map({
            $0.isFinite && (0...1).contains($0)
        }) ?? true,
        (annotations.lastModified?.utf8.count ?? 0) <= 128 else {
            throw MCPResourceCatalogError.invalidAnnotation
        }
    }
}

private extension MCPRawResourceAnnotations {
    var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        if !audience.isEmpty {
            fields["audience"] = .array(audience.map(JSONValue.string))
        }
        if let priority {
            fields["priority"] = .number(priority)
        }
        if let lastModified {
            fields["lastModified"] = .string(lastModified)
        }
        return .object(fields)
    }
}

private extension MCPRawCatalogIcon {
    var json: JSONValue {
        var fields: [String: JSONValue] = ["src": .string(source)]
        if let mimeType { fields["mimeType"] = .string(mimeType) }
        if !sizes.isEmpty {
            fields["sizes"] = .array(sizes.map(JSONValue.string))
        }
        if let theme { fields["theme"] = .string(theme) }
        return .object(fields)
    }
}
