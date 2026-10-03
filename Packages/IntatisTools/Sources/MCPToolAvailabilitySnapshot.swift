import Foundation
import IntatisCore

/// One non-disclosing dependency identity attested by the host from the exact,
/// request-owned agent-visible MCP tool view.
public struct MCPServerDependencyIdentity:
    Hashable, Sendable {
    public let serverID: String
    public let transportLocatorFingerprint: String

    public init(
        serverID: String,
        transportLocatorFingerprint: String
    ) {
        self.serverID = serverID
        self.transportLocatorFingerprint =
            transportLocatorFingerprint
    }
}

/// Exact, request-owned MCP identifiers visible to one provider request.
///
/// This value contains only host-approved exact server IDs and model-visible
/// qualified tool names. It deliberately contains no
/// endpoint, command, credential, header, query, or connection configuration.
/// An unavailable host is distinct from a frozen-but-empty MCP view so callers
/// cannot infer availability from process-global state.
public struct MCPToolAvailabilitySnapshot:
    Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case unavailable
        case frozen
    }

    public let state: State
    public let snapshotID: String
    /// Exact `MCPServerID.rawValue` values contributing tools to this request.
    /// Display aliases are deliberately excluded because Skill dependency
    /// metadata uses a stable server identity, not a presentation name.
    public let serverIdentifiers: Set<String>
    public let toolIdentifiers: Set<String>
    /// Paired server/transport identities. Keeping these paired prevents a
    /// server ID from one connection and a locator from another connection
    /// from jointly satisfying one dependency.
    public let dependencyIdentities:
        Set<MCPServerDependencyIdentity>

    private init(
        state: State,
        snapshotID: String,
        serverIdentifiers: Set<String>,
        toolIdentifiers: Set<String>,
        dependencyIdentities:
            Set<MCPServerDependencyIdentity> = []
    ) {
        self.state = state
        self.snapshotID = snapshotID
        self.serverIdentifiers = serverIdentifiers
        self.toolIdentifiers = toolIdentifiers
        self.dependencyIdentities =
            dependencyIdentities
    }

    public static let unavailable =
        MCPToolAvailabilitySnapshot(
            state: .unavailable,
            snapshotID: "mcp-availability-unavailable",
            serverIdentifiers: [],
            toolIdentifiers: [],
            dependencyIdentities: [])

    /// Builds the only positive host assertion accepted by Skill dependency
    /// preflight. The caller must derive these identifiers from the exact
    /// request-owned MCP catalog view, never from config or a live global
    /// registry. This value validates shape and pairing; it is not
    /// self-authenticating proof of a network connection.
    public static func frozen(
        snapshotID: String,
        serverIdentifiers: some Sequence<String>,
        toolIdentifiers: some Sequence<String>,
        dependencyIdentities:
            some Sequence<MCPServerDependencyIdentity> = []
    ) throws -> MCPToolAvailabilitySnapshot {
        let boundedSnapshotID = try validated(
            snapshotID,
            field: "snapshot ID",
            maximumCharacters: 256)
        let servers = try validatedIdentifiers(
            serverIdentifiers,
            field: "server identifiers",
            maximumCount: 2_048)
        let tools = try validatedIdentifiers(
            toolIdentifiers,
            field: "tool identifiers",
            maximumCount: 10_000)
        var validatedDependencies:
            Set<MCPServerDependencyIdentity> = []
        var dependencyCount = 0
        for identity in dependencyIdentities {
            dependencyCount += 1
            guard dependencyCount <= 2_048 else {
                throw MCPToolAvailabilitySnapshotError
                    .tooManyIdentifiers(
                        field: "dependency identities",
                        maximum: 2_048)
            }
            let serverID = try validated(
                identity.serverID,
                field: "dependency server ID",
                maximumCharacters: 128)
            let fingerprint = try validated(
                identity.transportLocatorFingerprint,
                field: "dependency locator fingerprint",
                maximumCharacters: 128)
            let fingerprintPrefix = "mcplocator_"
            let digest = fingerprint.dropFirst(
                fingerprintPrefix.count)
            guard fingerprint.hasPrefix(
                    fingerprintPrefix),
                  digest.count == 64,
                  digest.allSatisfy({
                      ("0"..."9").contains(
                          String($0))
                          || ("a"..."f").contains(
                              String($0))
                  }),
                  servers.contains(serverID) else {
                throw MCPToolAvailabilitySnapshotError
                    .invalidIdentifier(
                        field:
                            "dependency locator fingerprint")
            }
            validatedDependencies.insert(
                MCPServerDependencyIdentity(
                    serverID: serverID,
                    transportLocatorFingerprint:
                        fingerprint))
        }
        return MCPToolAvailabilitySnapshot(
            state: .frozen,
            snapshotID: boundedSnapshotID,
            serverIdentifiers: servers,
            toolIdentifiers: tools,
            dependencyIdentities:
                validatedDependencies)
    }

    public func containsExactServerID(_ identifier: String) -> Bool {
        state == .frozen
            && serverIdentifiers.contains(identifier)
    }

    public func containsDependency(
        serverID: String,
        transportLocatorFingerprint: String
    ) -> Bool {
        state == .frozen
            && dependencyIdentities.contains(
                MCPServerDependencyIdentity(
                    serverID: serverID,
                    transportLocatorFingerprint:
                        transportLocatorFingerprint))
    }

    private static func validatedIdentifiers(
        _ identifiers: some Sequence<String>,
        field: String,
        maximumCount: Int
    ) throws -> Set<String> {
        var result: Set<String> = []
        var inputCount = 0
        for raw in identifiers {
            inputCount += 1
            guard inputCount <= maximumCount else {
                throw MCPToolAvailabilitySnapshotError
                    .tooManyIdentifiers(
                        field: field,
                        maximum: maximumCount)
            }
            let value = try validated(
                raw,
                field: field,
                maximumCharacters: 256)
            result.insert(value)
        }
        return result
    }

    private static func validated(
        _ raw: String,
        field: String,
        maximumCharacters: Int
    ) throws -> String {
        let value = raw.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MCPToolAvailabilitySnapshotError
                .invalidIdentifier(field: field)
        }
        guard value.count <= maximumCharacters,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MCPToolAvailabilitySnapshotError
                .invalidIdentifier(field: field)
        }
        return value
    }
}

/// Non-disclosing canonicalization shared by frozen Skill metadata and the
/// exact request-owned MCP connection generation.
public enum MCPDependencyLocatorFingerprint {
    public static func streamableHTTP(
        _ rawURL: String
    ) throws -> String {
        let canonical = try canonicalHTTPSURL(rawURL)
        return key(
            transport: "streamable_http",
            locator: canonical)
    }

    public static func stdio(
        _ rawCommand: String
    ) throws -> String {
        let command = rawCommand.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              command.utf8.count <= 1_024,
              command.hasPrefix("/"),
              !command.contains("\0"),
              !command.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MCPToolAvailabilitySnapshotError
                .invalidDependencyLocator
        }
        let standardized = URL(
            fileURLWithPath: command)
            .standardizedFileURL.path
        guard standardized == command else {
            throw MCPToolAvailabilitySnapshotError
                .invalidDependencyLocator
        }
        return key(
            transport: "stdio",
            locator: command)
    }

    private static func canonicalHTTPSURL(
        _ rawValue: String
    ) throws -> String {
        guard rawValue.utf8.count <= 8 * 1_024,
              var components = URLComponents(
                string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw MCPToolAvailabilitySnapshotError
                .invalidDependencyLocator
        }
        let normalizedHost = host.lowercased()
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "[]"))
        components.scheme = "https"
        components.host = normalizedHost.contains(":")
            ? "[\(normalizedHost)]"
            : normalizedHost
        if components.port == 443 {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        guard let decodedPath =
                components.percentEncodedPath
                    .removingPercentEncoding,
              !decodedPath.split(
                separator: "/",
                omittingEmptySubsequences: false)
                .contains(where: {
                    $0 == "." || $0 == ".."
                }),
              let canonical = components.string else {
            throw MCPToolAvailabilitySnapshotError
                .invalidDependencyLocator
        }
        return canonical
    }

    private static func key(
        transport: String,
        locator: String
    ) -> String {
        let framed = [
            IntatisHostApplication.identity.temporaryPrefix(
                "skill-mcp-locator-v1"),
            transport,
            locator,
        ].map {
            "\($0.utf8.count):\($0)"
        }.joined()
        return "mcplocator_"
            + ToolRegistry.authorizationDigest(
                framed)
    }
}

public enum MCPToolAvailabilitySnapshotError:
    Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier(field: String)
    case tooManyIdentifiers(field: String, maximum: Int)
    case invalidDependencyLocator

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let field):
            return "MCP \(field) is empty, overlong, or contains control characters"
        case .tooManyIdentifiers(let field, let maximum):
            return "MCP \(field) exceeds the frozen \(maximum)-entry limit"
        case .invalidDependencyLocator:
            return "MCP dependency locator is invalid or unsafe"
        }
    }
}
