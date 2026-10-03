import Foundation
import XCTest
import IntatisProtocol
@testable import IntatisMCP

private actor MCPImportSinkProbe: MCPImportSecretSink {
    let sourceFingerprint: String
    private var storedCount = 0
    private var storedByteCounts: [Int] = []

    init(sourceFingerprint: String) {
        self.sourceFingerprint = sourceFingerprint
    }

    func storeImportedSecret(
        _ secret: Data,
        descriptor: MCPImportedSecretDescriptor
    ) async throws -> MCPSecretReference {
        storedCount += 1
        storedByteCounts.append(secret.count)
        return try MCPSecretReference(
            storageClass: .macOSKeychain,
            identifier: "mcpsecretref_\(storedCount)",
            sourceBindingFingerprint: descriptor.sourceFingerprint)
    }

    func snapshot() -> (Int, [Int]) {
        (storedCount, storedByteCounts)
    }
}

final class MCPImportTests: XCTestCase {
    func testMCPJSONPreviewStagesSecretsWithoutLaunchingOrPersistingThem() async throws {
        let plaintextSecret = "sk-import-secret-value"
        let source = Data(
            """
            {
              "version": 1,
              "mcpServers": {
                "local": {
                  "type": "stdio",
                  "command": "true",
                  "args": ["--version"],
                  "env": {
                    "NODE_ENV": "production",
                    "API_TOKEN": "\(plaintextSecret)"
                  },
                  "env_vars": ["HOME_PROXY"],
                  "approval_mode": "auto",
                  "tool_approval_modes": {"write": "prompt"},
                  "tools": {"allow": ["read", "write"], "deny": ["admin"]}
                }
              }
            }
            """.utf8)
        let result = try MCPConfigurationImporter.parse(
            data: source,
            format: .mcpJSON,
            sourceLabel: ".mcp.json")
        XCTAssertTrue(result.preview.canProceedToResolution)
        XCTAssertEqual(result.preview.proposals.count, 1)
        XCTAssertEqual(result.preview.secretDescriptors.count, 1)
        XCTAssertEqual(
            result.preview.proposals[0].provenance.sourceKind,
            .importedMCPJSON)

        let sink = MCPImportSinkProbe(
            sourceFingerprint: result.preview.sourceFingerprint)
        let references = try await result.secretStaging.migrate(to: sink)
        let sinkSnapshot = await sink.snapshot()
        XCTAssertEqual(sinkSnapshot.0, 1)
        XCTAssertEqual(sinkSnapshot.1, [plaintextSecret.utf8.count])
        XCTAssertEqual(references.count, 1)

        let configuration = try result.preview.proposals[0].makeConfiguration(
            resolution: MCPImportedServerResolution(
                launchArtifact: mcpImportArtifact(),
                secretReferences: references,
                environmentReference: MCPEnvironmentReference(
                    rawValue: "env_import")))
        let encoded = try JSONEncoder().encode(configuration)
        XCTAssertNil(String(data: encoded, encoding: .utf8)?
            .range(of: plaintextSecret))
        guard case .stdio(let stdio) = configuration.transport else {
            return XCTFail("expected stdio")
        }
        XCTAssertEqual(stdio.environment["NODE_ENV"], .literal("production"))
        guard case .secret = stdio.environment["API_TOKEN"] else {
            return XCTFail("secret was not referenceized")
        }
        XCTAssertEqual(
            stdio.inheritedEnvironmentReferences["HOME_PROXY"]?
                .storageClass,
            .environment)
    }

    func testClaudeJSONHTTPParserIsExplicitAndSecretSafe() async throws {
        let plaintextSecret = "Bearer imported-secret"
        let data = Data(
            """
            {
              "mcpServers": {
                "remote": {
                  "type": "http",
                  "url": "https://EXAMPLE.com:443/mcp",
                  "headers": {
                    "Accept": "application/json",
                    "Authorization": "\(plaintextSecret)"
                  },
                  "required": true,
                  "approval_mode": "writes"
                }
              }
            }
            """.utf8)
        let result = try MCPConfigurationImporter.parse(
            data: data,
            format: .claudeJSON,
            sourceLabel: ".claude.json")
        XCTAssertTrue(result.preview.canProceedToResolution)
        XCTAssertEqual(result.preview.format, .claudeJSON)
        XCTAssertEqual(
            result.preview.proposals[0].provenance.sourceKind,
            .importedClaudeJSON)
        let sink = MCPImportSinkProbe(
            sourceFingerprint: result.preview.sourceFingerprint)
        let references = try await result.secretStaging.migrate(to: sink)
        let configuration = try result.preview.proposals[0].makeConfiguration(
            resolution: MCPImportedServerResolution(
                secretReferences: references,
                environmentReference: MCPEnvironmentReference(
                    rawValue: "env_remote")))
        guard case .streamableHTTP(let http) = configuration.transport else {
            return XCTFail("expected HTTP")
        }
        XCTAssertEqual(http.endpoint, "https://example.com/mcp")
        XCTAssertEqual(http.headers["Accept"], .literal("application/json"))
        guard case .secret = http.headers["Authorization"] else {
            return XCTFail("authorization was not referenceized")
        }
        XCTAssertNil(String(
            data: try JSONEncoder().encode(configuration),
            encoding: .utf8)?.range(of: plaintextSecret))
    }

    func testImportedDevelopmentHTTPRequiresExplicitResolution()
        throws
    {
        func proposal(_ endpoint: String) throws
            -> MCPImportedServerProposal
        {
            let result = try MCPConfigurationImporter.parse(
                data: Data(
                    """
                    {
                      "mcpServers": {
                        "local": {
                          "type": "http",
                          "url": "\(endpoint)"
                        }
                      }
                    }
                    """.utf8),
                format: .claudeJSON,
                sourceLabel: ".claude.json")
            return try XCTUnwrap(result.preview.proposals.first)
        }

        let environment = MCPEnvironmentReference(
            rawValue: "env_import_http")
        let local = try proposal("http://localhost:8080/mcp")
        XCTAssertThrowsError(try local.makeConfiguration(
            resolution: MCPImportedServerResolution(
                environmentReference: environment)))
        let accepted = try local.makeConfiguration(
            resolution: MCPImportedServerResolution(
                environmentReference: environment,
                allowInsecureLoopbackDevelopmentHTTP: true))
        guard case .streamableHTTP(let http) = accepted.transport else {
            return XCTFail("expected HTTP")
        }
        XCTAssertEqual(http.endpoint, "http://localhost:8080/mcp")
        XCTAssertTrue(
            http.allowInsecureLoopbackDevelopmentHTTP)

        let remote = try MCPConfigurationImporter.parse(
            data: Data(
                """
                {
                  "mcpServers": {
                    "remote": {
                      "type": "http",
                      "url": "http://example.com/mcp"
                    }
                  }
                }
                """.utf8),
            format: .claudeJSON,
            sourceLabel: ".claude.json")
        XCTAssertFalse(
            remote.preview.canProceedToResolution)
        XCTAssertTrue(
            remote.preview.proposals.isEmpty)
    }

    func testUnknownAndPrivateFieldsAreVisibleBlockingIssues() throws {
        let data = Data(
            """
            {
              "unknownRoot": true,
              "mcpServers": {
                "server": {
                  "command": "/usr/bin/true",
                  "unknownServer": "do-not-trust",
                  "privatePlugin": {"enabled": true}
                }
              }
            }
            """.utf8)
        let result = try MCPConfigurationImporter.parse(
            data: data,
            format: .mcpJSON,
            sourceLabel: ".mcp.json")
        XCTAssertFalse(result.preview.canProceedToResolution)
        XCTAssertTrue(result.preview.issues.contains {
            $0.code == .unknownField && $0.path == "$.unknownRoot"
        })
        XCTAssertTrue(result.preview.issues.contains {
            $0.code == .unknownField
                && $0.path == "$.mcpServers.server.unknownServer"
        })
        XCTAssertTrue(result.preview.issues.contains {
            $0.code == .unsupportedPrivateSemantics
                && $0.path == "$.mcpServers.server.privatePlugin"
        })
        XCTAssertThrowsError(try MCPImportPlanner.plan(
            preview: result.preview,
            catalog: .empty))
    }

    func testLegacySSEAndAmbiguousTransportFailPreview() throws {
        let sse = Data(
            """
            {"mcpServers":{"server":{"type":"sse","url":"https://example.com"}}}
            """.utf8)
        let sseResult = try MCPConfigurationImporter.parse(
            data: sse,
            format: .claudeJSON,
            sourceLabel: ".claude.json")
        XCTAssertFalse(sseResult.preview.canProceedToResolution)
        XCTAssertTrue(sseResult.preview.issues.contains {
            $0.code == .unsupportedTransport
        })

        let ambiguous = Data(
            """
            {"mcpServers":{"server":{"command":"true","url":"https://example.com"}}}
            """.utf8)
        let ambiguousResult = try MCPConfigurationImporter.parse(
            data: ambiguous,
            format: .mcpJSON,
            sourceLabel: ".mcp.json")
        XCTAssertFalse(ambiguousResult.preview.canProceedToResolution)
        XCTAssertTrue(ambiguousResult.preview.issues.contains {
            $0.code == .invalidField
        })
    }

    func testConflictRequiresExplicitRenameReplaceOrSkip() async throws {
        let catalogRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-import-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: catalogRoot) }
        let store = MCPServerCatalogStore(
            fileURL: catalogRoot.appendingPathComponent("catalog.json"))
        let existingConfiguration = try mcpImportHTTPConfiguration(
            serverID: "mcpserver_existing")
        let existingStage = try MCPConfigurationStaging(
            configuration: existingConfiguration)
        let existingResult = try MCPConfigurationTestResult(
            challenge: existingStage.challenge,
            terminal: .succeeded,
            testedIdentityFingerprint:
                existingStage.expectedTestedIdentityFingerprint,
            sanitizedReasonCode: "ok")
        let existingProof = try existingStage.accept(existingResult)
        _ = try await store.save(
            alias: "remote",
            staging: existingStage,
            proof: existingProof,
            expectedGeneration: 0)
        let catalog = try await store.load()

        let imported = try MCPConfigurationImporter.parse(
            data: Data(
                """
                {"mcpServers":{"remote":{"type":"http","url":"https://other.example/mcp"}}}
                """.utf8),
            format: .mcpJSON,
            sourceLabel: ".mcp.json")
        let plan = try MCPImportPlanner.plan(
            preview: imported.preview,
            catalog: catalog)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertThrowsError(try plan.resolving([:], catalog: catalog))
        let conflict = try XCTUnwrap(plan.conflicts.first)
        let renamed = try plan.resolving(
            [conflict.proposalID: .rename("remote-imported")],
            catalog: catalog)
        XCTAssertEqual(renamed.map(\.alias), ["remote-imported"])
        let replaced = try plan.resolving(
            [conflict.proposalID: .replaceExisting(
                conflict.existingServerID)],
            catalog: catalog)
        XCTAssertEqual(replaced.map(\.serverID), [conflict.existingServerID])
        let skipped = try plan.resolving(
            [conflict.proposalID: .skip],
            catalog: catalog)
        XCTAssertTrue(skipped.isEmpty)
    }

    func testExplicitFileImportDoesNotModifySourceAndRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-import-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent(".mcp.json")
        let bytes = Data(
            #"{"mcpServers":{"server":{"command":"/usr/bin/true"}}}"#.utf8)
        try bytes.write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: sourceURL.path)
        let before = try FileManager.default.attributesOfItem(
            atPath: sourceURL.path)
        let result = try MCPConfigurationImporter.parseExplicitFile(
            at: sourceURL,
            format: .mcpJSON)
        let after = try FileManager.default.attributesOfItem(
            atPath: sourceURL.path)
        XCTAssertTrue(result.preview.canProceedToResolution)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        XCTAssertEqual(
            before[.systemFileNumber] as? NSNumber,
            after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(
            before[.posixPermissions] as? NSNumber,
            after[.posixPermissions] as? NSNumber)

        let symlink = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: sourceURL)
        XCTAssertThrowsError(try MCPConfigurationImporter.parseExplicitFile(
            at: symlink,
            format: .mcpJSON))
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testSanitizedExportContainsOnlyReferenceAndCanSaveAtomically() async throws {
        let plaintextSecret = "sk-export-must-not-appear"
        let imported = try MCPConfigurationImporter.parse(
            data: Data(
                """
                {"mcpServers":{"remote":{"type":"http","url":"https://example.com/mcp","headers":{"Authorization":"\(plaintextSecret)"}}}}
                """.utf8),
            format: .mcpJSON,
            sourceLabel: ".mcp.json")
        let sink = MCPImportSinkProbe(
            sourceFingerprint: imported.preview.sourceFingerprint)
        let refs = try await imported.secretStaging.migrate(to: sink)
        let proposal = try XCTUnwrap(imported.preview.proposals.first)
        let configuration = try proposal.makeConfiguration(
            resolution: MCPImportedServerResolution(
                secretReferences: refs,
                environmentReference: MCPEnvironmentReference(
                    rawValue: "env_export")))
        let stage = try MCPConfigurationStaging(configuration: configuration)
        let test = try MCPConfigurationTestResult(
            challenge: stage.challenge,
            terminal: .succeeded,
            testedIdentityFingerprint: stage.expectedTestedIdentityFingerprint,
            sanitizedReasonCode: "ok")
        let proof = try stage.accept(test)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = try imported.preview.importMarker()
        let saved = try await MCPServerCatalogStore(
            fileURL: root.appendingPathComponent("catalog.json")).saveBatch(
                [MCPCatalogSaveItem(
                    alias: proposal.alias,
                    staging: stage,
                    proof: proof)],
                importMarker: marker,
                expectedGeneration: 0)
        XCTAssertEqual(saved.catalog.importMarkers, [marker])
        let export = try MCPConfigurationExporter.sanitizedMCPJSON(
            catalog: saved.catalog)
        let text = try XCTUnwrap(String(data: export, encoding: .utf8))
        XCTAssertFalse(text.contains(plaintextSecret))
        XCTAssertTrue(text.contains("$intatisSecretRef"))
        XCTAssertTrue(text.contains("mcpsecretref_1"))
        let reimport = try MCPConfigurationImporter.parse(
            data: export,
            format: .mcpJSON,
            sourceLabel: "sanitized-export.mcp.json")
        XCTAssertTrue(reimport.preview.canProceedToResolution)
        XCTAssertTrue(reimport.preview.secretDescriptors.isEmpty)
    }

    func testDiscardedSecretStagingCannotMigrate() async throws {
        let imported = try MCPConfigurationImporter.parse(
            data: Data(
                #"{"mcpServers":{"remote":{"type":"http","url":"https://example.com","bearer_token":"sk-discard-me"}}}"#.utf8),
            format: .mcpJSON,
            sourceLabel: ".mcp.json")
        await imported.secretStaging.discard()
        let sink = MCPImportSinkProbe(
            sourceFingerprint: imported.preview.sourceFingerprint)
        do {
            _ = try await imported.secretStaging.migrate(to: sink)
            XCTFail("discarded secret unexpectedly migrated")
        } catch {
            XCTAssertEqual(
                error as? MCPImportError,
                .secretStagingUnavailable)
        }
    }
}

private func mcpImportArtifact() -> LaunchArtifactIdentity {
    LaunchArtifactIdentity(
        files: [
            MCPLaunchFileIdentity(
                role: .executable,
                canonicalPath: "/usr/bin/true",
                fileType: "regular",
                ownerID: 0,
                mode: 0o755,
                deviceID: 1,
                fileID: 2,
                byteCount: 1,
                sha256: String(repeating: "c", count: 64)),
        ],
        fingerprint: String(repeating: "c", count: 64))
}

private func mcpImportHTTPConfiguration(
    serverID: String
) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
        serverID: MCPServerID(rawValue: serverID),
        displayName: "Existing",
        approvalPolicy: MCPApprovalPolicy(),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .streamableHTTP(try MCPHTTPServerConfiguration(
            endpoint: "https://example.com/mcp")),
        environmentReference: MCPEnvironmentReference(rawValue: "env_existing"),
        provenance: MCPConfigurationProvenance(
            sourceKind: .intatisUser,
            sourceLabel: "settings"))
}
