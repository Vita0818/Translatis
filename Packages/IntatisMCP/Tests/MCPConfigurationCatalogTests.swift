import Foundation
import XCTest
import IntatisProtocol
@testable import IntatisMCP

private let mcpTestHashA = String(repeating: "a", count: 64)
private let mcpTestHashB = String(repeating: "b", count: 64)

private func mcpTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "intatis-mcp-catalog-tests-\(UUID().uuidString)",
        isDirectory: true)
}

private func mcpArtifact(
    path: String = "/usr/bin/true",
    fingerprint: String = mcpTestHashA
) -> LaunchArtifactIdentity {
    LaunchArtifactIdentity(
        files: [
            MCPLaunchFileIdentity(
                role: .executable,
                canonicalPath: path,
                fileType: "regular",
                ownerID: 0,
                mode: 0o755,
                deviceID: 1,
                fileID: 2,
                byteCount: 1,
                sha256: fingerprint),
        ],
        fingerprint: fingerprint)
}

private func mcpConfiguration(
    serverID: String = "mcpserver_test",
    displayName: String = "Test Server",
    endpoint: String = "https://EXAMPLE.com:443/mcp",
    mode: MCPApprovalMode = .auto,
    profile: MCPProtocolProfile = .codexCompat,
    maximum: MCPProtocolVersion? = nil,
    requiredCapabilities: [MCPGrantedCapability] = []
) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
        serverID: MCPServerID(rawValue: serverID),
        displayName: displayName,
        requiredCapabilities: requiredCapabilities,
        protocolProfile: profile,
        maximumProtocolVersion: maximum,
        approvalPolicy: MCPApprovalPolicy(
            serverDefault: mode,
            toolOverrides: ["mutate": .prompt]),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .streamableHTTP(try MCPHTTPServerConfiguration(
            endpoint: endpoint)),
        environmentReference: MCPEnvironmentReference(rawValue: "env_local"),
        provenance: MCPConfigurationProvenance(
            sourceKind: .intatisUser,
            sourceLabel: "settings"))
}

private func mcpStageAndProof(
    _ configuration: MCPServerConfiguration,
    completedAt: Date = Date()
) throws -> (MCPConfigurationStaging, MCPConfigurationTestProof) {
    let staging = try MCPConfigurationStaging(configuration: configuration)
    let result = try MCPConfigurationTestResult(
        challenge: staging.challenge,
        terminal: .succeeded,
        testedIdentityFingerprint: staging.expectedTestedIdentityFingerprint,
        completedAt: completedAt,
        sanitizedReasonCode: "ok")
    return (staging, try staging.accept(result))
}

final class MCPConfigurationTests: XCTestCase {
    func testCanonicalHTTPTransportAndProfileDefaults() throws {
        let configuration = try mcpConfiguration()
        guard case .streamableHTTP(let http) = configuration.transport else {
            return XCTFail("expected HTTP transport")
        }
        XCTAssertEqual(http.endpoint, "https://example.com/mcp")
        XCTAssertEqual(http.canonicalOrigin, "https://example.com")
        XCTAssertEqual(configuration.maximumProtocolVersion, .v2025_06_18)
        XCTAssertEqual(configuration.approvalPolicy.effectiveMode(for: "other"), .auto)
        XCTAssertEqual(configuration.approvalPolicy.effectiveMode(for: "mutate"), .prompt)
        XCTAssertEqual(
            try configuration.validatedCanonical().canonicalFingerprint,
            configuration.canonicalFingerprint)
    }

    func testEveryApprovalModeRoundTripsAndStrictMergeIsStable() throws {
        for mode in [
            MCPApprovalMode.auto, .prompt, .writes, .approve,
        ] {
            let policy = try MCPApprovalPolicy(serverDefault: mode)
            let decoded = try JSONDecoder().decode(
                MCPApprovalPolicy.self,
                from: JSONEncoder().encode(policy))
            XCTAssertEqual(decoded.serverDefault, mode)
        }
        XCTAssertEqual(
            MCPApprovalPolicy.mostRestrictive(.approve, .auto),
            .auto)
        XCTAssertEqual(
            MCPApprovalPolicy.mostRestrictive(.auto, .writes),
            .writes)
        XCTAssertEqual(
            MCPApprovalPolicy.mostRestrictive(.writes, .prompt),
            .prompt)
    }

    func testProtocolProfileRejectsExtendedCapabilityAboveCeiling() throws {
        XCTAssertThrowsError(try mcpConfiguration(
            profile: .codexCompat,
            requiredCapabilities: [.prompts]))
        XCTAssertThrowsError(try mcpConfiguration(
            profile: .codexCompat,
            maximum: .v2025_11_25))
        XCTAssertNoThrow(try mcpConfiguration(
            profile: .standardExtended,
            maximum: .v2025_11_25,
            requiredCapabilities: [.prompts, .tasks]))
        XCTAssertThrowsError(try mcpConfiguration(
            profile: .standardExtended,
            maximum: .v2025_06_18,
            requiredCapabilities: [.tasks]))
    }

    func testPlaintextSecretsAndUnsafeEndpointsFailClosed() throws {
        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "http://example.com/mcp"))
        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "https://user:pass@example.com/mcp"))
        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "https://example.com/mcp?token=value"))
        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "https://example.com/mcp",
            headers: ["Authorization": .literal("not-even-a-token")]))
        XCTAssertThrowsError(try MCPStdioServerConfiguration(
            launchArtifact: mcpArtifact(),
            environment: ["API_TOKEN": .literal("value")]))
    }

    func testDevelopmentHTTPRequiresExplicitExactLoopbackScope() throws {
        for (endpoint, canonical, origin) in [
            (
                "http://localhost:80/mcp",
                "http://localhost/mcp",
                "http://localhost"
            ),
            (
                "http://127.0.0.1:8080/mcp",
                "http://127.0.0.1:8080/mcp",
                "http://127.0.0.1:8080"
            ),
            (
                "http://[::1]:9090/mcp",
                "http://[::1]:9090/mcp",
                "http://[::1]:9090"
            ),
        ] {
            XCTAssertThrowsError(try MCPHTTPServerConfiguration(
                endpoint: endpoint))
            let value = try MCPHTTPServerConfiguration(
                endpoint: endpoint,
                allowInsecureLoopbackDevelopmentHTTP: true)
            XCTAssertEqual(value.endpoint, canonical)
            XCTAssertEqual(value.canonicalOrigin, origin)
            XCTAssertTrue(value.allowInsecureLoopbackDevelopmentHTTP)

            let decoded = try JSONDecoder().decode(
                MCPHTTPServerConfiguration.self,
                from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, value)
        }
    }

    func testDevelopmentHTTPFlagCannotBroadenHTTPSOrRemoteHTTP()
        throws
    {
        for endpoint in [
            "http://localhost.example/mcp",
            "http://127.0.0.2/mcp",
            "http://user@localhost/mcp",
            "https://example.com/mcp",
            "https://localhost/mcp",
        ] {
            XCTAssertThrowsError(try MCPHTTPServerConfiguration(
                endpoint: endpoint,
                allowInsecureLoopbackDevelopmentHTTP: true))
        }

        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "http://localhost/mcp",
            allowInsecureLoopbackDevelopmentHTTP: true,
            proxyPolicy: .systemConfigured))
        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "http://localhost/mcp",
            allowInsecureLoopbackDevelopmentHTTP: true,
            tlsPolicy: .pinnedPublicKeySHA256([mcpTestHashA])))
        let oauth = try MCPOAuthConfiguration(
            enabled: true,
            canonicalResource: "https://localhost/mcp")
        XCTAssertThrowsError(try MCPHTTPServerConfiguration(
            endpoint: "http://localhost/mcp",
            allowInsecureLoopbackDevelopmentHTTP: true,
            oauth: oauth))
    }

    func testLegacyHTTPConfigurationDecodeDefaultsDevelopmentFlagOff()
        throws
    {
        let value = try MCPHTTPServerConfiguration(
            endpoint: "https://example.com/mcp")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(value))
                as? [String: Any])
        object.removeValue(
            forKey: "allowInsecureLoopbackDevelopmentHTTP")
        let decoded = try JSONDecoder().decode(
            MCPHTTPServerConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(
            decoded.allowInsecureLoopbackDevelopmentHTTP)
        XCTAssertEqual(decoded.endpoint, value.endpoint)
    }

    func testSecretReferencesRemainOpaqueAndSourceBound() throws {
        let reference = try MCPSecretReference(
            storageClass: .macOSKeychain,
            identifier: "mcpsecretref_test",
            sourceBindingFingerprint: mcpTestHashA)
        let http = try MCPHTTPServerConfiguration(
            endpoint: "https://example.com/mcp",
            headers: ["Authorization": .secret(reference)])
        XCTAssertEqual(http.headers["Authorization"], .secret(reference))
        XCTAssertThrowsError(try MCPSecretReference(
            storageClass: .macOSKeychain,
            identifier: "sk-plain-secret",
            sourceBindingFingerprint: mcpTestHashA))
    }

    func testStagingRequiresExactSuccessfulUnexpiredTest() throws {
        let first = try MCPConfigurationStaging(
            configuration: mcpConfiguration())
        let second = try MCPConfigurationStaging(
            configuration: mcpConfiguration(displayName: "Changed"))
        let success = try MCPConfigurationTestResult(
            challenge: first.challenge,
            terminal: .succeeded,
            testedIdentityFingerprint: first.expectedTestedIdentityFingerprint,
            sanitizedReasonCode: "ok")
        let proof = try first.accept(success)
        XCTAssertNoThrow(try first.validate(proof: proof, at: Date()))
        XCTAssertThrowsError(try second.validate(proof: proof, at: Date()))

        let failed = try MCPConfigurationTestResult(
            challenge: first.challenge,
            terminal: .failed,
            testedIdentityFingerprint: first.expectedTestedIdentityFingerprint,
            sanitizedReasonCode: "failed")
        XCTAssertThrowsError(try first.accept(failed))

        let old = Date(timeIntervalSince1970: 100)
        let expiredResult = try MCPConfigurationTestResult(
            challenge: first.challenge,
            terminal: .succeeded,
            testedIdentityFingerprint: first.expectedTestedIdentityFingerprint,
            completedAt: old,
            sanitizedReasonCode: "ok")
        let expiredProof = try first.accept(expiredResult, proofLifetime: 1)
        XCTAssertThrowsError(try first.validate(
            proof: expiredProof,
            at: old.addingTimeInterval(2)))
    }
}

final class MCPServerCatalogStoreTests: XCTestCase {
    func testOwnerOnlyAtomicSaveLoadAndImmutableRevisionRetention() async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(
            MCPServerCatalogStore.fileName)
        let store = MCPServerCatalogStore(fileURL: fileURL)

        let (firstStage, firstProof) = try mcpStageAndProof(
            mcpConfiguration())
        let first = try await store.save(
            alias: "test",
            staging: firstStage,
            proof: firstProof,
            expectedGeneration: 0)
        XCTAssertEqual(first.catalog.generation, 1)
        XCTAssertEqual(first.catalog.definitions.count, 1)

        let (secondStage, secondProof) = try mcpStageAndProof(
            mcpConfiguration(displayName: "Changed"))
        let second = try await store.save(
            alias: "test",
            staging: secondStage,
            proof: secondProof,
            expectedGeneration: 1)
        XCTAssertEqual(second.catalog.generation, 2)
        XCTAssertEqual(second.catalog.definitions.count, 2)
        XCTAssertNotEqual(
            second.definitions[0].reference,
            first.definitions[0].reference)
        XCTAssertNotNil(second.catalog.definition(
            for: first.definitions[0].reference))

        let reloaded = try await MCPServerCatalogStore(
            fileURL: fileURL).load()
        XCTAssertEqual(reloaded, second.catalog)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path)
        XCTAssertEqual(
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o600)
        let lockAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(
                ".\(MCPServerCatalogStore.fileName).lock").path)
        XCTAssertEqual(
            ((lockAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o600)
    }

    func testConcurrentCASHasExactlyOneWinner() async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("catalog.json")
        let firstStore = MCPServerCatalogStore(fileURL: fileURL)
        let secondStore = MCPServerCatalogStore(fileURL: fileURL)
        let (firstStage, firstProof) = try mcpStageAndProof(
            mcpConfiguration(serverID: "mcpserver_one"))
        let (secondStage, secondProof) = try mcpStageAndProof(
            mcpConfiguration(serverID: "mcpserver_two"))

        let successes = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await firstStore.save(
                        alias: "one",
                        staging: firstStage,
                        proof: firstProof,
                        expectedGeneration: 0)
                    return true
                } catch { return false }
            }
            group.addTask {
                do {
                    _ = try await secondStore.save(
                        alias: "two",
                        staging: secondStage,
                        proof: secondProof,
                        expectedGeneration: 0)
                    return true
                } catch { return false }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(successes, 1)
        let reloaded = try await MCPServerCatalogStore(fileURL: fileURL).load()
        XCTAssertEqual(reloaded.generation, 1)
    }

    func testTestProofMismatchRollsBackWithoutChangingBytes() async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("catalog.json")
        let store = MCPServerCatalogStore(fileURL: fileURL)
        let (stage, proof) = try mcpStageAndProof(mcpConfiguration())
        _ = try await store.save(
            alias: "test",
            staging: stage,
            proof: proof,
            expectedGeneration: 0)
        let original = try Data(contentsOf: fileURL)

        let changed = try MCPConfigurationStaging(
            configuration: mcpConfiguration(displayName: "Changed"))
        do {
            _ = try await store.save(
                alias: "test",
                staging: changed,
                proof: proof,
                expectedGeneration: 1)
            XCTFail("mismatched proof unexpectedly saved")
        } catch {
            XCTAssertEqual(error as? MCPServerCatalogError, .testRequired)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testTombstoneBlocksConnectionAndPurgeRequiresZeroReferences() async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent("catalog.json"))
        let (stage, proof) = try mcpStageAndProof(mcpConfiguration())
        let saved = try await store.save(
            alias: "test",
            staging: stage,
            proof: proof,
            expectedGeneration: 0)
        let reference = try XCTUnwrap(saved.definitions.first?.reference)
        let tombstoned = try await store.tombstone(
            reference,
            reason: .userDelete,
            expectedGeneration: 1)
        XCTAssertTrue(tombstoned.isTombstoned(reference))
        XCTAssertThrowsError(try tombstoned.definitionForNewConnection(
            serverID: reference.serverID))

        let referenced = try MCPZeroReferenceProof(
            reference: reference,
            catalogGeneration: 2,
            durableReferenceCount: 1,
            liveReferenceCount: 0)
        do {
            _ = try await store.purge(
                reference,
                proof: referenced,
                expectedGeneration: 2)
            XCTFail("referenced revision unexpectedly purged")
        } catch {
            XCTAssertEqual(
                error as? MCPServerCatalogError,
                .revisionStillReferenced)
        }
        let zero = try MCPZeroReferenceProof(
            reference: reference,
            catalogGeneration: 2,
            durableReferenceCount: 0,
            liveReferenceCount: 0)
        let purged = try await store.purge(
            reference,
            proof: zero,
            expectedGeneration: 2)
        XCTAssertNil(purged.definition(for: reference))
        XCTAssertFalse(purged.isTombstoned(reference))
    }

    func testSymlinkHardlinkPermissionsCorruptionAndFutureSchemaFailClosed() async throws {
        try await assertUnsafeCatalogLeaf { root, catalog in
            let target = root.appendingPathComponent("target")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(
                at: catalog,
                withDestinationURL: target)
        }
        try await assertUnsafeCatalogLeaf { root, catalog in
            let target = root.appendingPathComponent("target")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: target.path)
            try FileManager.default.linkItem(at: target, to: catalog)
        }
        try await assertUnsafeCatalogLeaf { _, catalog in
            try Data("{}".utf8).write(to: catalog)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: catalog.path)
        }
        try await assertUnsafeCatalogLeaf { _, catalog in
            try Data("not-json".utf8).write(to: catalog)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: catalog.path)
        }

        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("catalog.json")
        let future: [String: Any] = [
            "schemaVersion": 99,
            "generation": 0,
            "definitions": [],
            "heads": [],
            "tombstones": [],
            "importMarkers": [],
            "contentDigest": mcpTestHashA,
        ]
        try JSONSerialization.data(
            withJSONObject: future,
            options: [.sortedKeys]).write(to: catalog)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: catalog.path)
        do {
            _ = try await MCPServerCatalogStore(fileURL: catalog).load()
            XCTFail("future catalog unexpectedly loaded")
        } catch {
            XCTAssertEqual(
                error as? MCPServerCatalogError,
                .unsupportedSchemaVersion)
        }
    }

    func testSymbolicLinkLockIsRejectedWithoutTouchingTarget() async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let protected = root.appendingPathComponent("protected")
        let protectedBytes = Data("unchanged".utf8)
        try protectedBytes.write(to: protected)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: protected.path)
        let catalog = root.appendingPathComponent("catalog.json")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".catalog.json.lock"),
            withDestinationURL: protected)
        let (stage, proof) = try mcpStageAndProof(mcpConfiguration())
        do {
            _ = try await MCPServerCatalogStore(fileURL: catalog).save(
                alias: "test",
                staging: stage,
                proof: proof,
                expectedGeneration: 0)
            XCTFail("symlink lock unexpectedly followed")
        } catch {
            XCTAssertEqual(error as? MCPServerCatalogError, .catalogIO)
        }
        XCTAssertEqual(try Data(contentsOf: protected), protectedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.path))
    }

    private func assertUnsafeCatalogLeaf(
        prepare: (URL, URL) throws -> Void
    ) async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("catalog.json")
        try prepare(root, catalog)
        do {
            _ = try await MCPServerCatalogStore(fileURL: catalog).load()
            XCTFail("unsafe catalog unexpectedly loaded")
        } catch {
            XCTAssertTrue(
                error as? MCPServerCatalogError == .catalogIO
                    || error as? MCPServerCatalogError == .catalogCorrupted)
        }
    }
}

final class MCPCatalogOperationJournalStoreTests: XCTestCase {
    func testGlobalTestJournalIsOwnerOnlyBoundedAndFirstTerminalCAS() async throws {
        let root = mcpTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(
            MCPCatalogOperationJournalStore.fileName)
        let store = MCPCatalogOperationJournalStore(fileURL: fileURL)
        let configuration = try mcpConfiguration()
        let staging = try MCPConfigurationStaging(configuration: configuration)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let record = try MCPGlobalTestOperationRecord(
            serverID: configuration.serverID,
            challenge: staging.challenge,
            startedAt: startedAt)
        let registered = try await store.register(
            record,
            expectedGeneration: 0)
        XCTAssertEqual(registered.generation, 1)
        XCTAssertEqual(registered.records.map(\.state), [.running])

        let result = try MCPConfigurationTestResult(
            challenge: staging.challenge,
            terminal: .succeeded,
            testedIdentityFingerprint: staging.expectedTestedIdentityFingerprint,
            completedAt: startedAt.addingTimeInterval(1),
            sanitizedReasonCode: "ok")
        let settled = try await store.settle(
            operationID: record.operationID,
            result: result,
            expectedGeneration: 1)
        XCTAssertEqual(settled.generation, 2)
        XCTAssertEqual(settled.records.map(\.state), [.succeeded])
        let duplicate = try await store.settle(
            operationID: record.operationID,
            result: result,
            expectedGeneration: 2)
        XCTAssertEqual(duplicate, settled)

        let conflict = try MCPConfigurationTestResult(
            challenge: staging.challenge,
            terminal: .failed,
            testedIdentityFingerprint: staging.expectedTestedIdentityFingerprint,
            completedAt: startedAt.addingTimeInterval(1),
            sanitizedReasonCode: "failed")
        do {
            _ = try await store.settle(
                operationID: record.operationID,
                result: conflict,
                expectedGeneration: 2)
            XCTFail("conflicting terminal unexpectedly replaced first terminal")
        } catch {
            XCTAssertEqual(
                error as? MCPGlobalTestJournalError,
                .conflictingSettlement)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path)
        XCTAssertEqual(
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777,
            0o600)
    }
}
