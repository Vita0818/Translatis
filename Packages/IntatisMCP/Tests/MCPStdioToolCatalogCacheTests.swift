import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisMCP

final class MCPStdioToolCatalogCacheTests: XCTestCase {
    func testOnlyExactStdioIdentityCanFormACacheKey() {
        let stdio = cacheIdentity(server: "stdio", transport: .stdio)
        let http = cacheIdentity(
            server: "http",
            transport: .streamableHTTP)

        XCTAssertNotNil(cacheKey(stdio))
        XCTAssertNil(MCPStdioToolCatalogCacheKey(
            identity: http,
            profile: .codexCompat,
            maximumProtocolVersion:
                MCPProtocolProfile.codexCompat.defaultMaximumVersion))
    }

    func testHitIsBoundedByThirtyMinuteTTLAndSanitizesHints()
        async throws {
        let cache = MCPStdioToolCatalogCache()
        let key = try XCTUnwrap(cacheKey(cacheIdentity(
            server: "ttl")))
        let pendingFetch = await cache.beginFetch(for: key)
        let fetch = try XCTUnwrap(pendingFetch)
        let now = Date(timeIntervalSince1970: 10_000)
        let tool = try cacheTool(
            "calendar",
            annotations: MCPRawToolAnnotations(
                title: "Remote title",
                readOnlyHint: true),
            icons: [
                MCPRawToolIcon(
                    source: "https://example.test/icon.png"),
            ])

        let published = try await cache.publish(
            [tool],
            for: fetch,
            now: now)
        XCTAssertTrue(published)
        let lookedUp = await cache.lookup(
            key,
            now: now.addingTimeInterval(1_799.999))
        let hit = try XCTUnwrap(lookedUp)
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit[0].remoteName, "calendar")
        XCTAssertEqual(hit[0].annotations, .init())
        XCTAssertEqual(hit[0].icons, tool.icons)
        let boundaryHit = await cache.lookup(
            key,
            now: now.addingTimeInterval(1_800))
        XCTAssertNotNil(boundaryHit)
        let expired = await cache.lookup(
            key,
            now: now.addingTimeInterval(1_800.001))
        XCTAssertNil(expired)
    }

    func testCapacityIsExactlyThirtyTwoAndUsesLRU()
        async throws {
        let cache = MCPStdioToolCatalogCache()
        let now = Date(timeIntervalSince1970: 20_000)
        var keys: [MCPStdioToolCatalogCacheKey] = []

        for index in 0..<32 {
            let key = try XCTUnwrap(cacheKey(cacheIdentity(
                server: "server-\(index)")))
            keys.append(key)
            let pendingFetch = await cache.beginFetch(for: key)
            let fetch = try XCTUnwrap(pendingFetch)
            let published = try await cache.publish(
                [cacheTool("tool-\(index)")],
                for: fetch,
                now: now)
            XCTAssertTrue(published)
        }
        let initialCount = await cache.entryCount()
        XCTAssertEqual(initialCount, 32)

        // Refresh entry zero so entry one becomes least recently used.
        let refreshedZero = await cache.lookup(keys[0], now: now)
        XCTAssertNotNil(refreshedZero)
        let thirtyThird = try XCTUnwrap(cacheKey(cacheIdentity(
            server: "server-32")))
        let pendingFetch = await cache.beginFetch(for: thirtyThird)
        let fetch = try XCTUnwrap(pendingFetch)
        let publishedThirtyThird = try await cache.publish(
            [cacheTool("tool-32")],
            for: fetch,
            now: now)
        XCTAssertTrue(publishedThirtyThird)

        let finalCount = await cache.entryCount()
        let retainedZero = await cache.lookup(keys[0], now: now)
        let evictedOne = await cache.lookup(keys[1], now: now)
        let retainedThirtyThird = await cache.lookup(
            thirtyThird,
            now: now)
        XCTAssertEqual(finalCount, 32)
        XCTAssertNotNil(retainedZero)
        XCTAssertNil(evictedOne)
        XCTAssertNotNil(retainedThirtyThird)
    }

    func testOlderFetchCannotOverwriteNewerGeneration()
        async throws {
        let cache = MCPStdioToolCatalogCache()
        let key = try XCTUnwrap(cacheKey(cacheIdentity(
            server: "racing")))
        let pendingOlder = await cache.beginFetch(for: key)
        let older = try XCTUnwrap(pendingOlder)
        let pendingNewer = await cache.beginFetch(for: key)
        let newer = try XCTUnwrap(pendingNewer)

        let publishedNewer = try await cache.publish(
            [cacheTool("newer")],
            for: newer)
        let publishedOlder = try await cache.publish(
            [cacheTool("older")],
            for: older)
        XCTAssertTrue(publishedNewer)
        XCTAssertFalse(publishedOlder)
        let cachedNames = await cache.lookup(key)?.map(\.remoteName)
        XCTAssertEqual(cachedNames, ["newer"])
    }

    func testOlderFetchMayPublishUntilANewerGenerationIsAccepted()
        async throws {
        let cache = MCPStdioToolCatalogCache()
        let key = try XCTUnwrap(cacheKey(cacheIdentity(
            server: "accepted-generation")))
        let pendingOlder = await cache.beginFetch(for: key)
        let older = try XCTUnwrap(pendingOlder)
        let pendingNewer = await cache.beginFetch(for: key)
        let newer = try XCTUnwrap(pendingNewer)

        let publishedOlder = try await cache.publish(
            [cacheTool("older")],
            for: older)
        let olderNames = await cache.lookup(key)?.map(\.remoteName)
        let publishedNewer = try await cache.publish(
            [cacheTool("newer")],
            for: newer)
        let newerNames = await cache.lookup(key)?.map(\.remoteName)

        XCTAssertTrue(publishedOlder)
        XCTAssertEqual(olderNames, ["older"])
        XCTAssertTrue(publishedNewer)
        XCTAssertEqual(newerNames, ["newer"])
    }

    func testRevisionAuthorityProfileAndDisableBoundaries()
        async throws {
        let cache = MCPStdioToolCatalogCache()
        let firstIdentity = cacheIdentity(server: "isolation")
        let first = try XCTUnwrap(cacheKey(firstIdentity))
        let differentRevision = try XCTUnwrap(cacheKey(cacheIdentity(
            server: "isolation",
            revision: "revision-2")))
        let differentAuthority = try XCTUnwrap(cacheKey(cacheIdentity(
            server: "isolation",
            agent: "other-agent")))
        let pendingFetch = await cache.beginFetch(for: first)
        let fetch = try XCTUnwrap(pendingFetch)
        let published = try await cache.publish(
            [cacheTool("only-first")],
            for: fetch)
        XCTAssertTrue(published)

        let firstHit = await cache.lookup(first)
        let revisionMiss = await cache.lookup(differentRevision)
        let authorityMiss = await cache.lookup(differentAuthority)
        XCTAssertNotNil(firstHit)
        XCTAssertNil(revisionMiss)
        XCTAssertNil(authorityMiss)

        await cache.disableAndClear()
        let disabledCount = await cache.entryCount()
        let disabledLookup = await cache.lookup(first)
        let disabledFetch = await cache.beginFetch(for: first)
        XCTAssertEqual(disabledCount, 0)
        XCTAssertNil(disabledLookup)
        XCTAssertNil(disabledFetch)
    }
}

private func cacheTool(
    _ name: String,
    annotations: MCPRawToolAnnotations = .init(),
    icons: [MCPRawToolIcon] = []
) throws -> MCPRawToolRecord {
    try MCPRawToolRecord(
        remoteName: name,
        summary: "Tool \(name)",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]),
        annotations: annotations,
        icons: icons)
}

private func cacheKey(
    _ identity: MCPConnectionReuseIdentity
) -> MCPStdioToolCatalogCacheKey? {
    MCPStdioToolCatalogCacheKey(
        identity: identity,
        profile: .codexCompat,
        maximumProtocolVersion:
            MCPProtocolProfile.codexCompat.defaultMaximumVersion)
}

private func cacheIdentity(
    server serverID: String,
    revision: String = "revision-1",
    agent: String = "agent",
    transport: MCPTransportKind = .stdio
) -> MCPConnectionReuseIdentity {
    let server = MCPServerReference(
        serverID: MCPServerID(rawValue: serverID),
        serverRevision: MCPServerRevision(rawValue: revision))
    let environment = MCPEnvironmentReference(
        rawValue: "environment")
    let launch = transport == .stdio ? "launch" : nil
    let authority = MCPConnectionAuthority(
        server: server,
        transport: transport,
        protocolProfile: .codexCompat,
        sessionID: SessionID(rawValue: "session"),
        agentID: AgentID(rawValue: agent),
        attachmentID: MCPAttachmentID(
            rawValue: "attachment-\(agent)"),
        capabilityLeaseID: CapabilityLeaseID(
            rawValue: "capability-\(agent)"),
        capabilityTaskID: nil,
        workspaceLeaseID: WorkspaceLeaseID(
            rawValue: "workspace"),
        workspaceRootIdentityFingerprint: "root",
        workspaceLeasePolicyFingerprint:
            String(repeating: "a", count: 64),
        attachmentPolicyRevision: MCPPolicyRevision(
            rawValue: "attachment-policy"),
        environmentReference: environment,
        launchArtifactFingerprint: launch,
        rootsPolicyRevision: MCPPolicyRevision(
            rawValue: "roots-policy"),
        networkPolicyRevision: MCPPolicyRevision(
            rawValue: "network-policy"),
        sandboxProfileRevision: MCPPolicyRevision(
            rawValue: "sandbox-policy"),
        sandboxPolicyFingerprint:
            String(repeating: "b", count: 64),
        hostPlatform: "test",
        fingerprint:
            "\(serverID)|\(revision)|\(agent)|\(transport.rawValue)")
    return MCPConnectionReuseIdentity(
        server: server,
        transport: transport,
        transportConfigurationFingerprint:
            "transport|\(serverID)|\(revision)|\(transport.rawValue)",
        authority: authority,
        oauthAccountReference: nil,
        environmentReference: environment,
        launchArtifactFingerprint: launch,
        runtimeIdentityFingerprint: "runtime|\(agent)")
}
