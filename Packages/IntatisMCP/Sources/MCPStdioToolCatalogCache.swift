// The stdio-only 32-entry/30-minute LRU and accepted-generation publication
// rules are derived from OpenAI Codex commit
// 61a44880a85d2fd0d8770908dea5733495e571c8. Intatis uses its stronger
// connection authority/revision/profile identity and never caches authority.
// Provenance and Apache-2.0 notice: ThirdPartyNotices/MCPToolSearch.md.

import Foundation
import IntatisProtocol

/// Exact process-memory key for Codex-compatible stdio tool-schema reuse.
///
/// `MCPConnectionReuseIdentity` retains server revision, transport config,
/// authority, environment, launch artifact, account, and runtime identity.
/// Profile and maximum version remain explicit so a future identity migration
/// cannot accidentally collapse distinct negotiation contracts.
public struct MCPStdioToolCatalogCacheKey:
    Equatable, Hashable, Sendable {
    public let identity: MCPConnectionReuseIdentity
    public let profile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion

    public init?(
        identity: MCPConnectionReuseIdentity,
        profile: MCPProtocolProfile,
        maximumProtocolVersion: MCPProtocolVersion
    ) {
        guard identity.transport == .stdio,
              identity.authority.transport == .stdio,
              identity.authority.protocolProfile == profile,
              identity.authority.maximumProtocolVersion
                == maximumProtocolVersion else {
            return nil
        }
        self.identity = identity
        self.profile = profile
        self.maximumProtocolVersion = maximumProtocolVersion
    }
}

public struct MCPStdioToolCatalogFetch:
    Equatable, Hashable, Sendable {
    public let key: MCPStdioToolCatalogCacheKey
    public let generation: UInt64

    fileprivate init(
        key: MCPStdioToolCatalogCacheKey,
        generation: UInt64
    ) {
        self.key = key
        self.generation = generation
    }
}

/// Process-scoped stdio tool-schema LRU matching Codex's 32-entry,
/// 30-minute boundary.
///
/// A cache hit contains definitions only. It does not contain a connection,
/// grant, binding, route, revocation generation, or execution authority.
/// Callers must initialize a live connection first and must still pass the
/// ordinary binding/revalidation path before any tool call.
public actor MCPStdioToolCatalogCache {
    public static let maximumEntries = 32
    public static let timeToLive: TimeInterval = 30 * 60
    public static let shared = MCPStdioToolCatalogCache()

    private struct Entry: Sendable {
        var tools: [MCPRawToolRecord]
        var expiresAt: Date
        var lastAccess: UInt64
    }

    private let capacity: Int
    private let ttl: TimeInterval
    private var entries: [MCPStdioToolCatalogCacheKey: Entry] = [:]
    private var lastAcceptedGeneration:
        [MCPStdioToolCatalogCacheKey: UInt64] = [:]
    private var logicalClock: UInt64 = 0
    private var generationClock: UInt64 = 0
    private var enabled = true

    public init(
        capacity: Int = MCPStdioToolCatalogCache.maximumEntries,
        ttl: TimeInterval = MCPStdioToolCatalogCache.timeToLive
    ) {
        self.capacity = max(
            1,
            min(capacity, Self.maximumEntries))
        self.ttl = max(0.001, ttl)
    }

    public func lookup(
        _ key: MCPStdioToolCatalogCacheKey,
        now: Date = Date()
    ) -> [MCPRawToolRecord]? {
        guard enabled, var entry = entries[key] else {
            return nil
        }
        guard now <= entry.expiresAt else {
            entries.removeValue(forKey: key)
            return nil
        }
        logicalClock &+= 1
        entry.lastAccess = logicalClock
        entries[key] = entry
        return entry.tools
    }

    /// Starts one schema fetch generation. Publication compares the ticket
    /// with the newest generation already accepted for this key.
    public func beginFetch(
        for key: MCPStdioToolCatalogCacheKey
    ) -> MCPStdioToolCatalogFetch? {
        guard enabled else { return nil }
        generationClock &+= 1
        return MCPStdioToolCatalogFetch(
            key: key,
            generation: generationClock)
    }

    /// Returns false when the fetch was superseded or caching was disabled.
    @discardableResult
    public func publish(
        _ tools: [MCPRawToolRecord],
        for fetch: MCPStdioToolCatalogFetch,
        now: Date = Date()
    ) throws -> Bool {
        guard enabled,
              fetch.generation
                > (lastAcceptedGeneration[fetch.key] ?? 0) else {
            return false
        }
        let sanitized = try tools.map(Self.sanitized)
        logicalClock &+= 1
        lastAcceptedGeneration[fetch.key] = fetch.generation
        entries[fetch.key] = Entry(
            tools: sanitized,
            expiresAt: now.addingTimeInterval(ttl),
            lastAccess: logicalClock)
        evictIfNeeded()
        return true
    }

    public func invalidate(
        _ key: MCPStdioToolCatalogCacheKey
    ) {
        entries.removeValue(forKey: key)
        lastAcceptedGeneration.removeValue(forKey: key)
    }

    public func disableAndClear() {
        enabled = false
        entries.removeAll(keepingCapacity: false)
        lastAcceptedGeneration.removeAll(keepingCapacity: false)
    }

    public func enable() {
        enabled = true
    }

    public func entryCount() -> Int {
        entries.count
    }

    private func evictIfNeeded() {
        while entries.count > capacity,
              let victim = entries.min(by: {
                  if $0.value.lastAccess != $1.value.lastAccess {
                      return $0.value.lastAccess
                          < $1.value.lastAccess
                  }
                  return Self.stableKey($0.key)
                      < Self.stableKey($1.key)
            })?.key {
            entries.removeValue(forKey: victim)
            lastAcceptedGeneration.removeValue(forKey: victim)
        }
    }

    /// Connection-owned hints and presentation assets do not survive schema
    /// reuse. The live connection remains authoritative for execution and
    /// later catalog notifications.
    private static func sanitized(
        _ tool: MCPRawToolRecord
    ) throws -> MCPRawToolRecord {
        try MCPRawToolRecord(
            remoteName: tool.remoteName,
            title: tool.title,
            summary: tool.summary,
            inputSchema: tool.inputSchema,
            outputSchema: tool.outputSchema,
            annotations: .init(),
            icons: tool.icons,
            taskSupport: tool.taskSupport)
    }

    private static func stableKey(
        _ key: MCPStdioToolCatalogCacheKey
    ) -> String {
        [
            key.identity.server.serverID.rawValue,
            key.identity.server.serverRevision.rawValue,
            key.identity.authority.fingerprint,
            key.profile.rawValue,
            key.maximumProtocolVersion.rawValue,
            key.identity.transportConfigurationFingerprint,
            key.identity.runtimeIdentityFingerprint,
        ].joined(separator: "\u{001F}")
    }
}

public struct MCPStdioToolCatalogCacheContext: Sendable {
    public let cache: MCPStdioToolCatalogCache
    public let key: MCPStdioToolCatalogCacheKey

    public init(
        cache: MCPStdioToolCatalogCache,
        key: MCPStdioToolCatalogCacheKey
    ) {
        self.cache = cache
        self.key = key
    }
}
