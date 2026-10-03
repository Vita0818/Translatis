import Foundation
import IntatisCore

public enum MCPContentSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case tool
    case resource
    case resourceTemplate = "resource_template"
    case prompt
    case sampling
    case elicitation
    case task
}

/// Exact server/binding identity carried with MCP-derived content. It contains
/// no transport headers, environment values, OAuth material, or server wire
/// payload.
public struct MCPContentProvenance: Codable, Equatable, Hashable, Sendable {
    public let sourceKind: MCPContentSourceKind
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let rawCatalogRevision: MCPRawCatalogRevision
    public let agentCatalogViewRevision: MCPAgentCatalogViewRevision
    public let bindingID: MCPBindingID
    public let protocolProfile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion
    public let negotiatedProtocolVersion: MCPNegotiatedProtocolVersion
    public let remoteName: String?
    public let resourceURI: String?
    public let schemaHash: String?
    public let accountReference: MCPAccountReference?
    public let environmentReference: MCPEnvironmentReference

    public init(sourceKind: MCPContentSourceKind,
                server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                rawCatalogRevision: MCPRawCatalogRevision,
                agentCatalogViewRevision: MCPAgentCatalogViewRevision,
                bindingID: MCPBindingID,
                protocolProfile: MCPProtocolProfile,
                maximumProtocolVersion: MCPProtocolVersion? = nil,
                negotiatedProtocolVersion: MCPNegotiatedProtocolVersion,
                remoteName: String? = nil,
                resourceURI: String? = nil,
                schemaHash: String? = nil,
                accountReference: MCPAccountReference? = nil,
                environmentReference: MCPEnvironmentReference) {
        self.sourceKind = sourceKind
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.rawCatalogRevision = rawCatalogRevision
        self.agentCatalogViewRevision = agentCatalogViewRevision
        self.bindingID = bindingID
        self.protocolProfile = protocolProfile
        self.maximumProtocolVersion = maximumProtocolVersion ?? protocolProfile.defaultMaximumVersion
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
        self.remoteName = remoteName
        self.resourceURI = resourceURI
        self.schemaHash = schemaHash
        self.accountReference = accountReference
        self.environmentReference = environmentReference
    }
}

public enum MCPContentBlockKind: String, Codable, Equatable, Hashable, Sendable {
    case text
    case structuredJSON = "structured_json"
    case imageReference = "image_reference"
    case audioReference = "audio_reference"
    case resourceLink = "resource_link"
    case embeddedResourceReference = "embedded_resource_reference"
    case artifactReference = "artifact_reference"
}

/// One bounded content block from an MCP result. Binary media and embedded
/// resources are represented by URI/Artifact references rather than inline
/// bytes. A runtime must apply size, MIME, hash, and SecretScanner policy before
/// constructing a durable value.
public struct MCPContentBlock: Codable, Equatable, Sendable {
    public let kind: MCPContentBlockKind
    public let text: String?
    public let structuredJSON: JSONValue?
    public let artifactID: ArtifactID?
    public let uri: String?
    public let mimeType: String?
    public let byteCount: Int?
    public let sha256: String?
    public let truncated: Bool
    public let provenance: MCPContentProvenance?

    public init(kind: MCPContentBlockKind,
                text: String? = nil,
                structuredJSON: JSONValue? = nil,
                artifactID: ArtifactID? = nil,
                uri: String? = nil,
                mimeType: String? = nil,
                byteCount: Int? = nil,
                sha256: String? = nil,
                truncated: Bool = false,
                provenance: MCPContentProvenance? = nil) {
        self.kind = kind
        self.text = text
        self.structuredJSON = structuredJSON
        self.artifactID = artifactID
        self.uri = uri
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.truncated = truncated
        self.provenance = provenance
    }
}

/// Additive typed MCP result stored beside the existing text observation.
/// `structuredContent` is validated against `outputSchemaHash` by the runtime;
/// the protocol layer deliberately stays SDK-independent.
public enum MCPToolResultType: String, Codable, Equatable, Sendable {
    case complete
}

public struct MCPStructuredToolResult: Codable, Equatable, Sendable {
    /// MCP 2026-07-28 complete-result discriminator. Legacy durable events
    /// decode a missing discriminator as `.complete` because this pre-task
    /// Intatis value never represented streaming/incomplete tool results.
    public let resultType: MCPToolResultType
    public let content: [MCPContentBlock]
    public let structuredContent: JSONValue?
    public let outputSchemaHash: String?
    public let isError: Bool
    public let totalByteCount: Int?
    public let truncated: Bool

    public init(resultType: MCPToolResultType = .complete,
                content: [MCPContentBlock],
                structuredContent: JSONValue? = nil,
                outputSchemaHash: String? = nil,
                isError: Bool = false,
                totalByteCount: Int? = nil,
                truncated: Bool = false) {
        self.resultType = resultType
        self.content = content
        self.structuredContent = structuredContent
        self.outputSchemaHash = outputSchemaHash
        self.isError = isError
        self.totalByteCount = totalByteCount
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case resultType, content, structuredContent, outputSchemaHash
        case isError, totalByteCount, truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resultType = try container.decodeIfPresent(
            MCPToolResultType.self,
            forKey: .resultType) ?? .complete
        content = try container.decode([MCPContentBlock].self, forKey: .content)
        structuredContent = try container.decodeIfPresent(
            JSONValue.self,
            forKey: .structuredContent)
        outputSchemaHash = try container.decodeIfPresent(
            String.self,
            forKey: .outputSchemaHash)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        totalByteCount = try container.decodeIfPresent(Int.self, forKey: .totalByteCount)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resultType, forKey: .resultType)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(structuredContent, forKey: .structuredContent)
        try container.encodeIfPresent(outputSchemaHash, forKey: .outputSchemaHash)
        try container.encode(isError, forKey: .isError)
        try container.encodeIfPresent(totalByteCount, forKey: .totalByteCount)
        try container.encode(truncated, forKey: .truncated)
    }
}
