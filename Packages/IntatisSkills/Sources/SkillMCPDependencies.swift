import Foundation
import IntatisCore
import IntatisPermission
import IntatisTools

/// The only MCP dependency transport metadata retained by Intatis.
///
/// Transport configuration is validated while freezing the Skill, but raw
/// URLs and commands are never exposed through this value.
public enum SkillMCPDependencyTransport:
    String, Equatable, Sendable {
    case unspecified
    case streamableHTTP = "streamable_http"
    case stdio
}

/// Safe, frozen projection of one `dependencies.tools` MCP record from
/// `agents/openai.yaml`.
public struct SkillMCPDependency: Equatable, Sendable {
    /// Exact MCP server ID declared by the Skill metadata.
    public let identifier: String
    public let transport: SkillMCPDependencyTransport
    /// Opaque canonical fingerprint derived only from transport + URL/command.
    /// Runtime preflight matches this fingerprint together with `identifier`
    /// against one host-attested, request-owned MCP tool view.
    public let locatorFingerprint: String
    /// Digest of every validated allowlisted field, including transport
    /// locator metadata. It makes snapshot identity sensitive to metadata
    /// edits without exposing a URL, command, or description.
    public let metadataFingerprint: String

    public init(
        identifier: String,
        transport: SkillMCPDependencyTransport,
        locatorFingerprint: String,
        metadataFingerprint: String
    ) {
        self.identifier = identifier
        self.transport = transport
        self.locatorFingerprint = locatorFingerprint
        self.metadataFingerprint = metadataFingerprint
    }
}

public enum SkillMCPDependencyMetadataState:
    String, Equatable, Sendable {
    case absent
    case valid
    case invalid
}

/// Typed, disclosure-safe failure produced before any Skill body or resource
/// is returned.
public enum SkillActivationPreflightError:
    Error, Equatable, LocalizedError, Sendable {
    case invalidDependencyMetadata(skillID: String)
    case mcpHostUnavailable(skillID: String, requiredCount: Int)
    case missingMCPDependencies(skillID: String, missingCount: Int)

    public var code: String {
        switch self {
        case .invalidDependencyMetadata:
            return "skill_mcp_dependency_metadata_invalid"
        case .mcpHostUnavailable:
            return "skill_mcp_host_unavailable"
        case .missingMCPDependencies:
            return "skill_mcp_dependency_missing"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidDependencyMetadata:
            return "Skill activation was rejected because its frozen MCP dependency metadata is invalid; no Skill content was returned."
        case .mcpHostUnavailable(_, let requiredCount):
            return "Skill activation requires \(requiredCount) MCP dependency record(s), but this request has no exact MCP host snapshot; no Skill content was returned."
        case .missingMCPDependencies(_, let missingCount):
            return "Skill activation is missing \(missingCount) dependency record(s) from this request's exact MCP tool snapshot; no Skill content was returned."
        }
    }
}

enum SkillMCPMetadataBounds {
    static let maximumFileBytes = 16 * 1_024
    static let maximumLines = 256
    static let maximumDependencies = 16
    static let maximumIdentifierCharacters = 128
    static let maximumDescriptionCharacters = 256
    static let maximumTransportCharacters = 32
    static let maximumCommandCharacters = 256
    static let maximumURLCharacters = 1_024
}

struct ParsedSkillMCPMetadata: Equatable, Sendable {
    var dependencies: [SkillMCPDependency]
}

enum SkillMCPMetadataParser {
    private struct RawDependency {
        var fields: [String: String] = [:]
    }

    private static let allowedTopLevel =
        Set(["interface", "dependencies", "policy"])
    private static let allowedDependencyFields =
        Set([
            "type", "value", "description", "transport", "command",
            "url",
        ])

    static func parse(_ contents: String) throws
        -> ParsedSkillMCPMetadata {
        guard contents.utf8.count
                <= SkillMCPMetadataBounds.maximumFileBytes else {
            throw IntatisError.decoding(
                "Skill MCP metadata exceeds the frozen file-size limit")
        }
        guard !SecretScanner.containsSecret(contents) else {
            throw IntatisError.permissionDenied(
                "Skill MCP metadata contains secret-like material")
        }
        let lines = contents.split(
            separator: "\n",
            omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\r", with: "") }
        guard lines.count <= SkillMCPMetadataBounds.maximumLines else {
            throw IntatisError.decoding(
                "Skill MCP metadata exceeds the frozen line limit")
        }
        guard !lines.contains(where: { $0.contains("\t") }) else {
            throw IntatisError.decoding(
                "Skill MCP metadata must use spaces for indentation")
        }
        let secretKeys = [
            "token", "secret", "password", "authorization",
            "api_key", "apikey", "bearer", "cookie",
        ]
        guard !lines.contains(where: { line in
            let key = line.trimmingCharacters(
                in: .whitespaces)
                .split(separator: ":", maxSplits: 1)
                .first?
                .lowercased()
            return key.map(secretKeys.contains) ?? false
        }) else {
            throw IntatisError.permissionDenied(
                "Skill MCP metadata contains a forbidden secret field")
        }

        var topLevelSeen: Set<String> = []
        var section: String?
        var dependenciesToolsSeen = false
        var acceptsToolItems = false
        var current: RawDependency?
        var records: [RawDependency] = []

        func finishCurrent(
            _ current: inout RawDependency?,
            records: inout [RawDependency]
        ) throws {
            guard let value = current else { return }
            guard records.count
                    < SkillMCPMetadataBounds.maximumDependencies else {
                throw IntatisError.decoding(
                    "Skill MCP metadata exceeds the dependency-record limit")
            }
            records.append(value)
            current = nil
        }

        for rawLine in lines {
            let indentation = leadingSpaces(rawLine)
            let trimmed = rawLine.trimmingCharacters(
                in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            guard !trimmed.hasPrefix("---"),
                  trimmed != "...",
                  !containsUnsupportedYAMLToken(trimmed) else {
                throw IntatisError.decoding(
                    "Skill MCP metadata uses unsupported YAML syntax")
            }

            if indentation == 0 {
                try finishCurrent(
                    &current,
                    records: &records)
                let pair = try mappingPair(trimmed)
                guard pair.value.isEmpty,
                      allowedTopLevel.contains(pair.key) else {
                    throw IntatisError.decoding(
                        "Skill MCP metadata has an unknown top-level field")
                }
                guard topLevelSeen.insert(pair.key).inserted else {
                    throw IntatisError.decoding(
                        "Skill MCP metadata has a duplicate top-level field")
                }
                section = pair.key
                acceptsToolItems = false
                continue
            }

            guard let section else {
                throw IntatisError.decoding(
                    "Skill MCP metadata begins with nested content")
            }
            // Codex-compatible interface/policy blocks are intentionally not
            // consumed by this dependency-only phase. They remain bounded and
            // secret-scanned above; only their recognized top-level names are
            // accepted.
            guard section == "dependencies" else {
                continue
            }

            if indentation == 2 {
                try finishCurrent(
                    &current,
                    records: &records)
                let pair = try mappingPair(trimmed)
                guard pair.key == "tools",
                      !dependenciesToolsSeen else {
                    throw IntatisError.decoding(
                        "Skill MCP dependencies contain an unknown or duplicate field")
                }
                dependenciesToolsSeen = true
                if pair.value == "[]" {
                    acceptsToolItems = false
                } else {
                    guard pair.value.isEmpty else {
                        throw IntatisError.decoding(
                            "Skill MCP dependency tools must be a block sequence")
                    }
                    acceptsToolItems = true
                }
                continue
            }

            guard acceptsToolItems else {
                throw IntatisError.decoding(
                    "Skill MCP dependency record appears outside dependencies.tools")
            }
            if indentation == 4, trimmed.hasPrefix("-") {
                try finishCurrent(
                    &current,
                    records: &records)
                let remainder = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                guard !remainder.isEmpty else {
                    throw IntatisError.decoding(
                        "Skill MCP dependency record cannot be empty")
                }
                current = RawDependency()
                try insertField(
                    remainder,
                    into: &current!.fields)
                continue
            }
            if indentation == 6, current != nil {
                try insertField(
                    trimmed,
                    into: &current!.fields)
                continue
            }
            throw IntatisError.decoding(
                "Skill MCP dependency indentation or sequence shape is invalid")
        }
        try finishCurrent(
            &current,
            records: &records)

        var seenIdentifiers: Set<String> = []
        var seenLocators: Set<String> = []
        let dependencies = try records.map { record in
            let dependency = try resolve(record)
            guard seenIdentifiers.insert(
                dependency.identifier).inserted else {
                throw IntatisError.decoding(
                    "Skill MCP dependency identifier is duplicated")
            }
            guard seenLocators.insert(
                dependency.locatorFingerprint).inserted else {
                throw IntatisError.decoding(
                    "Skill MCP dependency locator is duplicated")
            }
            return dependency
        }
        return ParsedSkillMCPMetadata(
            dependencies: dependencies)
    }

    private static func resolve(
        _ record: RawDependency
    ) throws -> SkillMCPDependency {
        guard record.fields["type"] == "mcp" else {
            throw IntatisError.decoding(
                "Skill dependency type must be mcp")
        }
        let identifier = try validatedIdentifier(
            required(record, "value"))
        let description = record.fields["description"]
        if let description {
            try validateScalar(
                description,
                field: "description",
                maximum:
                    SkillMCPMetadataBounds
                        .maximumDescriptionCharacters)
        }

        let rawTransport = try required(
            record,
            "transport")
        try validateScalar(
            rawTransport,
            field: "transport",
            maximum:
                SkillMCPMetadataBounds
                    .maximumTransportCharacters)
        guard let transport =
                SkillMCPDependencyTransport(
                    rawValue: rawTransport),
              transport != .unspecified else {
            throw IntatisError.decoding(
                "Skill MCP dependency transport is unsupported")
        }

        let command = record.fields["command"]
        let url = record.fields["url"]
        guard command == nil || url == nil else {
            throw IntatisError.decoding(
                "Skill MCP dependency cannot declare both command and url")
        }
        let locatorFingerprint: String
        switch transport {
        case .stdio:
            guard let command else {
                throw IntatisError.decoding(
                    "stdio Skill MCP dependency is missing command")
            }
            try validateCommand(command)
            locatorFingerprint =
                try MCPDependencyLocatorFingerprint.stdio(
                    command)
            guard url == nil else {
                throw IntatisError.decoding(
                    "stdio Skill MCP dependency cannot declare url")
            }
        case .streamableHTTP:
            guard let url else {
                throw IntatisError.decoding(
                    "streamable_http Skill MCP dependency is missing url")
            }
            try validateURL(url)
            locatorFingerprint =
                try MCPDependencyLocatorFingerprint
                    .streamableHTTP(url)
            guard command == nil else {
                throw IntatisError.decoding(
                    "streamable_http Skill MCP dependency cannot declare command")
            }
        case .unspecified:
            throw IntatisError.decoding(
                "Skill MCP dependency transport is required")
        }

        let fingerprint =
            ToolRegistry.authorizationDigest(
                SkillSnapshot.framed([
                    IntatisHostApplication.identity.temporaryPrefix(
                        "skill-mcp-dependency-v1"),
                    "mcp",
                    identifier,
                    description ?? "",
                    transport.rawValue,
                    command ?? "",
                    url ?? "",
                ]))
        return SkillMCPDependency(
            identifier: identifier,
            transport: transport,
            locatorFingerprint: locatorFingerprint,
            metadataFingerprint: fingerprint)
    }

    private static func insertField(
        _ text: String,
        into fields: inout [String: String]
    ) throws {
        let pair = try mappingPair(text)
        guard allowedDependencyFields.contains(pair.key) else {
            throw IntatisError.decoding(
                "Skill MCP dependency has an unknown field")
        }
        guard fields[pair.key] == nil else {
            throw IntatisError.decoding(
                "Skill MCP dependency has a duplicate field")
        }
        let value = try decodedScalar(pair.value)
        guard !value.isEmpty else {
            throw IntatisError.decoding(
                "Skill MCP dependency field is empty")
        }
        fields[pair.key] = value
    }

    private static func required(
        _ record: RawDependency,
        _ key: String
    ) throws -> String {
        guard let value = record.fields[key] else {
            throw IntatisError.decoding(
                "Skill MCP dependency is missing a required field")
        }
        return value
    }

    private static func validatedIdentifier(
        _ value: String
    ) throws -> String {
        try validateScalar(
            value,
            field: "identifier",
            maximum:
                SkillMCPMetadataBounds
                    .maximumIdentifierCharacters)
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard value.unicodeScalars.allSatisfy({
            allowed.contains($0)
        }) else {
            throw IntatisError.decoding(
                "Skill MCP dependency identifier contains unsupported characters")
        }
        return value
    }

    private static func validateCommand(
        _ value: String
    ) throws {
        try validateScalar(
            value,
            field: "command",
            maximum:
                SkillMCPMetadataBounds
                    .maximumCommandCharacters)
        guard value.hasPrefix("/"),
              URL(fileURLWithPath: value)
                .standardizedFileURL.path == value,
              !value.contains(where: { $0.isWhitespace }),
              !value.contains(where: {
                  ";&|<>$`=".contains($0)
              }) else {
            throw IntatisError.decoding(
                "Skill MCP dependency command must be one canonical absolute executable path")
        }
    }

    private static func validateURL(
        _ value: String
    ) throws {
        try validateScalar(
            value,
            field: "url",
            maximum:
                SkillMCPMetadataBounds.maximumURLCharacters)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw IntatisError.decoding(
                "Skill MCP dependency URL must be credential-free HTTPS without query or fragment")
        }
    }

    private static func validateScalar(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        guard !value.isEmpty,
              value.count <= maximum,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !SecretScanner.containsSecret(value) else {
            throw IntatisError.decoding(
                "Skill MCP dependency \(field) is empty, overlong, unsafe, or secret-like")
        }
    }

    private static func mappingPair(
        _ text: String
    ) throws -> (key: String, value: String) {
        guard let separator = text.firstIndex(of: ":") else {
            throw IntatisError.decoding(
                "Skill MCP metadata mapping entry is malformed")
        }
        let key = String(text[..<separator])
            .trimmingCharacters(in: .whitespaces)
        let value = String(text[
            text.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        let keyCharacters = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyz_")
        guard !key.isEmpty,
              key.unicodeScalars.allSatisfy({
                  keyCharacters.contains($0)
              }) else {
            throw IntatisError.decoding(
                "Skill MCP metadata key is invalid")
        }
        return (key, value)
    }

    private static func decodedScalar(
        _ raw: String
    ) throws -> String {
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("\"") {
            guard raw.hasSuffix("\""),
                  let data = raw.data(using: .utf8),
                  let value = try? JSONDecoder().decode(
                    String.self,
                    from: data) else {
                throw IntatisError.decoding(
                    "Skill MCP metadata has an invalid quoted scalar")
            }
            return value
        }
        if raw.hasPrefix("'") {
            guard raw.hasSuffix("'") else {
                throw IntatisError.decoding(
                    "Skill MCP metadata has an invalid quoted scalar")
            }
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        guard !raw.contains("#"),
              !raw.hasPrefix("["),
              !raw.hasPrefix("{"),
              !raw.hasPrefix("|"),
              !raw.hasPrefix(">"),
              !raw.hasPrefix("&"),
              !raw.hasPrefix("*"),
              !raw.hasPrefix("!"),
              raw != "~",
              raw.lowercased() != "null" else {
            throw IntatisError.decoding(
                "Skill MCP metadata scalar uses unsupported YAML syntax")
        }
        return raw
    }

    private static func leadingSpaces(_ value: String) -> Int {
        value.prefix(while: { $0 == " " }).count
    }

    private static func containsUnsupportedYAMLToken(
        _ value: String
    ) -> Bool {
        value.hasPrefix("&")
            || value.hasPrefix("*")
            || value.hasPrefix("!")
            || value.contains(" <<:")
    }
}
