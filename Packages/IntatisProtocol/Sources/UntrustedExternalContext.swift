import Foundation

/// Provider-neutral origin classification for user-selected external data.
/// None of these values conveys message-role or instruction authority.
public enum UntrustedExternalContextSource:
    String, Codable, Equatable, Hashable, Sendable
{
    case mcpUserSelectedPrompt =
        "mcp_user_selected_prompt"
    case mcpExplicitServerInstructions =
        "mcp_explicit_server_instructions"
    case mcpResource = "mcp_resource"
}

public enum UntrustedExternalContextTrust:
    String, Codable, Equatable, Hashable, Sendable
{
    case externalUntrusted = "external_untrusted"
}

public struct UntrustedExternalContextProvenance:
    Codable, Equatable, Sendable
{
    public enum Kind:
        String, Codable, Equatable, Hashable, Sendable
    {
        case mcp
    }

    public let kind: Kind
    public let mcp: MCPContentProvenance?

    public init(mcp: MCPContentProvenance) {
        kind = .mcp
        self.mcp = mcp
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case mcp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self)
        let kind = try container.decode(
            Kind.self,
            forKey: .kind)
        let mcp = try container.decodeIfPresent(
            MCPContentProvenance.self,
            forKey: .mcp)
        guard kind == .mcp, mcp != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .mcp,
                in: container,
                debugDescription:
                    "MCP external context provenance is incomplete")
        }
        self.kind = kind
        self.mcp = mcp
    }
}

/// External data frozen into exactly one durable user submission.
///
/// This provider-neutral type deliberately cannot represent system/developer
/// roles. ContextBuilder is the sole model-facing projection and emits it as a
/// separate quoted user-role block.
public struct UntrustedExternalContext:
    Codable, Equatable, Sendable
{
    public let source: UntrustedExternalContextSource
    public let trust: UntrustedExternalContextTrust
    public let text: String?
    public let structured: JSONValue?
    public let provenance:
        UntrustedExternalContextProvenance

    public init(
        source: UntrustedExternalContextSource,
        text: String? = nil,
        structured: JSONValue? = nil,
        provenance:
            UntrustedExternalContextProvenance
    ) {
        self.source = source
        trust = .externalUntrusted
        self.text = text
        self.structured = structured
        self.provenance = provenance
    }
}
