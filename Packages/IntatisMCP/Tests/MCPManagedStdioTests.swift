import Foundation
import IntatisCore
import IntatisMCP
@testable import IntatisMCPStdio
import IntatisProtocol
import MCP
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class MCPManagedStdioTests: XCTestCase {
    func testStrictConnectParserRequiresExactAuthorityAndUniqueCredential()
        throws
    {
        let authorization = "Basic dGVzdDp0b2tlbg=="
        let expected = Array(authorization.utf8)
        let valid = Data(
            (
                "CONNECT example.com:443 HTTP/1.1\r\n"
                    + "Host: example.com:443\r\n"
                    + "Proxy-Connection: Keep-Alive\r\n"
                    + "Proxy-Authorization: \(authorization)\r\n"
                    + "\r\n"
            ).utf8)
        XCTAssertEqual(
            valid.suffix(4),
            Data([13, 10, 13, 10]))
        XCTAssertNoThrow(
            try MCPStdioConnectRequestParser.parseAuthority(
                "example.com:443"))
        XCTAssertEqual(
            try MCPStdioConnectRequestParser.parse(
                valid,
                expectedProxyAuthorization: expected),
            try MCPStdioCanonicalNetworkOrigin(
                "https://example.com"))

        let invalidRequests = [
            valid.replacingUTF8(
                "Proxy-Authorization: \(authorization)\r\n",
                with: ""),
            valid.replacingUTF8(
                authorization,
                with: "Basic d3Jvbmc="),
            valid.replacingUTF8(
                "Proxy-Authorization: \(authorization)\r\n",
                with:
                    "Proxy-Authorization: \(authorization)\r\nProxy-Authorization: \(authorization)\r\n"),
            valid.replacingUTF8(
                "CONNECT example.com:443",
                with: "GET example.com:443"),
            valid.replacingUTF8(
                "\r\n\r\n",
                with: "\r\nContent-Length: 0\r\n\r\n"),
            valid + Data("body".utf8),
            valid.replacingUTF8(
                "Host: example.com:443",
                with: "Host: other.example:443"),
        ]
        for request in invalidRequests {
            XCTAssertThrowsError(
                try MCPStdioConnectRequestParser.parse(
                    request,
                    expectedProxyAuthorization: expected))
        }
        XCTAssertTrue(
            MCPStdioConnectRequestParser.constantTimeEqual(
                expected,
                expected))
        XCTAssertFalse(
            MCPStdioConnectRequestParser.constantTimeEqual(
                expected,
                Array("Basic different".utf8)))
    }

    func testStrictConnectParserCanonicalizesIPv6Authority() throws {
        let authorization = "Basic dGVzdDp0b2tlbg=="
        let request = Data(
            (
                "CONNECT [::1]:8443 HTTP/1.1\r\n"
                    + "Host: [::1]:8443\r\n"
                    + "Proxy-Authorization: \(authorization)\r\n"
                    + "\r\n"
            ).utf8)
        XCTAssertEqual(
            try MCPStdioConnectRequestParser.parse(
                request,
                expectedProxyAuthorization:
                    Array(authorization.utf8)),
            try MCPStdioCanonicalNetworkOrigin(
                "https://[::1]:8443"))
    }

    func testGatewayCredentialIsHighEntropyGenerationLocalMaterial() {
        let credentials = Set(
            (0..<64).map { _ in
                MCPStdioExactNetworkGateway.makeCredential()
            })
        XCTAssertEqual(credentials.count, 64)
        for credential in credentials {
            XCTAssertEqual(credential.utf8.count, 43)
            XCTAssertTrue(
                credential.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics
                        .union(
                            CharacterSet(
                                charactersIn: "-_"))
                        .contains($0)
                })
        }
    }

    func testLaunchTicketRegistersOnlyResolvedSecretEnvironmentValues()
        async throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(
            for: material.request)
        let redactor = MCPResolvedSecretRedactor()

        ticket.registerResolvedSecretEnvironmentValues(
            with: redactor)

        let sanitized = try redactor.sanitizeMCPText(
            "token=\(fixture.secret) protocol=2025-06-18 port=\(fixture.networkProbePort)")
        XCTAssertFalse(sanitized.contains(fixture.secret))
        XCTAssertTrue(sanitized.contains("protocol=2025-06-18"))
        XCTAssertTrue(
            sanitized.contains(
                "port=\(fixture.networkProbePort)"))
        XCTAssertGreaterThan(
            redactor.registeredValueCount,
            0)
    }

    #if os(macOS)
    func testExactSeatbeltGatewayRuleHasExplicitImportedProfileExclusion() {
        let rule = MCPStdioSandboxCompiler
            .exactSeatbeltGatewayRule(port: 43_219)
        XCTAssertTrue(rule.contains("(deny network-inbound)"))
        XCTAssertTrue(rule.contains("(deny network-outbound"))
        XCTAssertTrue(rule.contains("(require-not"))
        XCTAssertTrue(
            rule.contains(
                #"(remote tcp "127.0.0.1:43219")"#))
        XCTAssertTrue(rule.contains("(allow network-outbound"))
        XCTAssertFalse(rule.contains("(allow network*)"))
        XCTAssertFalse(rule.contains("*:43219"))
        XCTAssertFalse(rule.contains("127.0.0.2"))
        XCTAssertFalse(rule.contains("remote udp"))
    }

    func testExactGatewayFreezesIPv4AndIPv6AndRequiresCredential()
        throws
    {
        let listener: LocalTCPListener
        do {
            listener = try LocalTCPListener()
        } catch {
            throw XCTSkip(
                "the outer test host blocks loopback listeners")
        }
        defer { listener.stop() }
        let gateway: MCPStdioExactNetworkGateway
        do {
            gateway = try MCPStdioExactNetworkGateway(origins: [
                "https://127.0.0.1:\(listener.port)",
                "https://[::1]:\(listener.port)",
            ])
        } catch {
            throw XCTSkip(
                "the outer test host blocks the exact gateway listener")
        }
        defer { gateway.stop() }

        XCTAssertEqual(gateway.endpoints.count, 2)
        let families = Set(
            gateway.endpoints.flatMap(\.addresses).map(\.family))
        XCTAssertTrue(families.contains(AF_INET))
        XCTAssertTrue(families.contains(AF_INET6))
        XCTAssertTrue(gateway.proxyURL.hasPrefix("http://intatis:"))
        XCTAssertFalse(gateway.proxyURL.contains("https://127.0.0.1"))
        let redactor = MCPResolvedSecretRedactor()
        gateway.registerDiagnosticRedactionValues(
            with: redactor)
        let sanitizedProxy = try redactor.sanitizeMCPText(
            "proxy=\(gateway.proxyURL)")
        XCTAssertFalse(
            sanitizedProxy.contains(gateway.proxyURL))
        for redaction in gateway.diagnosticRedactionValues {
            XCTAssertFalse(
                try redactor.sanitizeMCPText(
                    "value=\(redaction)")
                    .contains(redaction))
        }

        let missing = try sendConnectRequest(
            gatewayPort: gateway.port,
            targetAuthority: "127.0.0.1:\(listener.port)",
            authorization: nil)
        XCTAssertTrue(missing.contains("400 Bad Request"))
        for redaction in gateway.diagnosticRedactionValues {
            XCTAssertFalse(missing.contains(redaction))
        }

        let wrong = try sendConnectRequest(
            gatewayPort: gateway.port,
            targetAuthority: "127.0.0.1:\(listener.port)",
            authorization: "Basic d3Jvbmc=")
        XCTAssertTrue(wrong.contains("400 Bad Request"))
        for redaction in gateway.diagnosticRedactionValues {
            XCTAssertFalse(wrong.contains(redaction))
        }

        let correct = try XCTUnwrap(
            gateway.diagnosticRedactionValues.first(where: {
                $0.hasPrefix("Basic ")
            }))
        let accepted = try sendConnectRequest(
            gatewayPort: gateway.port,
            targetAuthority: "127.0.0.1:\(listener.port)",
            authorization: correct)
        XCTAssertTrue(
            accepted.contains("200 Connection Established"))
        for redaction in gateway.diagnosticRedactionValues {
            XCTAssertFalse(accepted.contains(redaction))
        }
        let deadline = Date().addingTimeInterval(1)
        while !listener.acceptedConnection(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(listener.hasAcceptedConnection)
        gateway.stop()
        XCTAssertThrowsError(
            try sendConnectRequest(
                gatewayPort: gateway.port,
                targetAuthority:
                    "127.0.0.1:\(listener.port)",
                authorization: correct))
    }
    #endif

    func testPreparedSaveRejectsArtifactReplacedAfterSuccessfulTest()
        async throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let catalogURL =
            fixture.rootURL.appendingPathComponent(
                "catalog.json")
        let store = MCPServerCatalogStore(
            fileURL: catalogURL,
            precommitVerifier:
                MCPStdioPreparedDefinitionPrecommitVerifier())
        let service = MCPManagementService(
            catalogStore: store,
            testJournal:
                MCPCatalogOperationJournalStore(
                    fileURL:
                        fixture.rootURL.appendingPathComponent(
                            "test-journal.json")),
            hostProfile: .macCLI,
            catalogPublicationSink: { _ in },
            testExecutor: {
                try successfulPreparedTest($0)
            })
        let prepared = try await service.prepare(
            alias: "replace-after-test",
            configuration:
                try preparedStdioConfiguration(
                    fixture: fixture,
                    serverID:
                        MCPServerID(
                            rawValue:
                                "mcpserver_replace_after_test")))
        let result = try await service.test(
            prepared,
            authorization:
                preparedStdioTestAuthorization())
        XCTAssertEqual(result.terminal, .succeeded)

        try Data("\n# replaced after Test\n".utf8)
            .appendAtomically(to: fixture.scriptURL)

        do {
            _ = try await service.savePrepared(
                prepared,
                proof: prepared.accept(result))
            XCTFail("changed launch closure unexpectedly saved")
        } catch let error as MCPManagedPipeError {
            XCTAssertEqual(
                error,
                .launchArtifactChanged("beforeSave"))
        }
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.generation, 0)
        XCTAssertTrue(reloaded.definitions.isEmpty)
        XCTAssertTrue(reloaded.heads.isEmpty)
    }

    func testPreparedBatchPrecommitVerificationIsAtomic()
        async throws
    {
        let firstFixture = try StdioFixture(mode: .normal)
        let secondFixture = try StdioFixture(mode: .normal)
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let store = MCPServerCatalogStore(
            fileURL:
                firstFixture.rootURL.appendingPathComponent(
                    "catalog.json"),
            precommitVerifier:
                MCPStdioPreparedDefinitionPrecommitVerifier())
        let service = MCPManagementService(
            catalogStore: store,
            testJournal:
                MCPCatalogOperationJournalStore(
                    fileURL:
                        firstFixture.rootURL.appendingPathComponent(
                            "test-journal.json")),
            hostProfile: .macCLI,
            catalogPublicationSink: { _ in },
            testExecutor: {
                try successfulPreparedTest($0)
            })
        let prepared = try await service.prepareBatch([
            (
                alias: "batch-one",
                configuration:
                    try preparedStdioConfiguration(
                        fixture: firstFixture,
                        serverID:
                            MCPServerID(
                                rawValue:
                                    "mcpserver_precommit_batch_one"))
            ),
            (
                alias: "batch-two",
                configuration:
                    try preparedStdioConfiguration(
                        fixture: secondFixture,
                        serverID:
                            MCPServerID(
                                rawValue:
                                    "mcpserver_precommit_batch_two"))
            ),
        ])
        var saveItems: [MCPPreparedCatalogSaveItem] = []
        for item in prepared {
            let result = try await service.test(
                item,
                authorization:
                    preparedStdioTestAuthorization())
            XCTAssertEqual(result.terminal, .succeeded)
            saveItems.append(
                MCPPreparedCatalogSaveItem(
                    prepared: item,
                    proof: try item.accept(result)))
        }

        try Data("\n# second batch item replaced\n".utf8)
            .appendAtomically(to: secondFixture.scriptURL)
        do {
            _ = try await store.savePreparedBatch(
                saveItems,
                importMarker: nil)
            XCTFail("partially changed batch unexpectedly saved")
        } catch let error as MCPManagedPipeError {
            XCTAssertEqual(
                error,
                .launchArtifactChanged("beforeSave"))
        }
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.generation, 0)
        XCTAssertTrue(reloaded.definitions.isEmpty)
        XCTAssertTrue(reloaded.heads.isEmpty)
    }

    func testLaunchArtifactIdentityUsesSameCaptureAtTestSaveAndLaunch() throws {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }

        let identity = try fixture.captureIdentity()
        try MCPLaunchArtifactIdentityVerifier.verifyBeforeSave(identity)
        try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(identity)
        XCTAssertEqual(
            identity.files.map(\.role),
            [.executable, .interpreter, .script])
        XCTAssertEqual(identity.fingerprint.count, 64)
    }

    func testLaunchArtifactReplacementFailsClosed() throws {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let identity = try fixture.captureIdentity()

        try Data("\n# replaced\n".utf8).appendAtomically(
            to: fixture.scriptURL)
        XCTAssertThrowsError(
            try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(identity)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .launchArtifactChanged("beforeLaunch"))
        }
    }

    func testStableSymlinkRevalidatesAndSymlinkSwapFailsClosed() throws {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let linkURL = fixture.rootURL.appendingPathComponent("entrypoint")
        let replacementURL =
            fixture.rootURL.appendingPathComponent("replacement.sh")
        try FileManager.default.copyItem(
            at: fixture.scriptURL,
            to: replacementURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: fixture.scriptURL)
        let identity =
            try MCPLaunchArtifactIdentityVerifier.captureForTest([
                MCPLaunchArtifactInput(
                    role: .executable,
                    path: "/bin/bash"),
                MCPLaunchArtifactInput(
                    role: .interpreter,
                    path: "/bin/bash"),
                MCPLaunchArtifactInput(
                    role: .script,
                    path: linkURL.path),
            ])

        try MCPLaunchArtifactIdentityVerifier.verifyBeforeSave(identity)
        let script = try XCTUnwrap(
            identity.files.first(where: { $0.role == .script }))
        XCTAssertEqual(script.canonicalPath, fixture.scriptURL.path)
        XCTAssertEqual(script.resolvedSymlinkPath, linkURL.path)

        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: replacementURL)
        XCTAssertThrowsError(
            try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(identity)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .launchArtifactChanged("beforeLaunch"))
        }
    }

    func testHelperArtifactReplacementFailsClosed() throws {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let helperURL = fixture.rootURL.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: helperURL,
            options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path)
        let identity =
            try MCPLaunchArtifactIdentityVerifier.captureHelperForTest([
                MCPLaunchArtifactInput(
                    role: .helper,
                    path: helperURL.path),
            ])

        try Data("\n# replaced\n".utf8).appendAtomically(to: helperURL)
        XCTAssertThrowsError(
            try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(identity)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .launchArtifactChanged("beforeLaunch"))
        }
    }

    func testTicketCannotBeMintedWithMismatchedAdmissionProof() async throws {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let material = try fixture.material()
        let issuer = MCPStdioLaunchTicketIssuer { request in
            MCPStdioHostAuthorization(
                decisionID: "decision",
                operationID: request.operationID,
                authorityFingerprint: String(repeating: "f", count: 64),
                launchArtifactFingerprint:
                    request.configuration.launchArtifact.fingerprint,
                workspaceLeaseID: request.workspaceLease.id,
                expiresAt: Date().addingTimeInterval(30),
                resolvedEnvironment: fixture.environment)
        }
        do {
            _ = try await issuer.issue(for: material.request)
            XCTFail("expected exact authority mismatch")
        } catch {
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .authorizationBindingMismatch)
        }
    }

    func testLinuxReadOnlyMasksHideFilesDirectoriesAndMixedCaseNames()
        throws {
        let root = try makeLinuxMaskWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = root.appendingPathComponent(".NeTrC")
        let directory = root.appendingPathComponent(
            ".SsH",
            isDirectory: true)
        try Data("credential".utf8).write(to: credential)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        try Data("private".utf8).write(
            to: directory.appendingPathComponent("id_ed25519"))

        let masks = try MCPStdioSandboxCompiler
            .linuxReadOnlyMasks(
                lease: try linuxMaskLease(root: root),
                workspace: root)

        XCTAssertEqual(
            masks,
            [
                MCPStdioLinuxReadOnlyMask(
                    targetPath: credential.path,
                    kind: .file),
                MCPStdioLinuxReadOnlyMask(
                    targetPath: directory.path,
                    kind: .directory),
            ].sorted {
                let lhs = $0.targetPath.split(separator: "/").count
                let rhs = $1.targetPath.split(separator: "/").count
                return lhs == rhs
                    ? $0.targetPath < $1.targetPath
                    : lhs < rhs
            })
        XCTAssertFalse(
            masks.contains {
                $0.targetPath.hasSuffix("/id_ed25519")
            },
            "a denied directory is one stable mask and descendants are skipped")
    }

    func testLinuxReadOnlyMaskScanRejectsSymlinkHardlinkAndSpecialFile()
        throws {
        for hostile in ["symlink", "hardlink", "special"] {
            let root = try makeLinuxMaskWorkspace()
            defer { try? FileManager.default.removeItem(at: root) }
            let ordinary = root.appendingPathComponent("ordinary")
            try Data("value".utf8).write(to: ordinary)
            switch hostile {
            case "symlink":
                try FileManager.default.createSymbolicLink(
                    at: root.appendingPathComponent("link"),
                    withDestinationURL: ordinary)
            case "hardlink":
                try FileManager.default.linkItem(
                    at: ordinary,
                    to: root.appendingPathComponent("alias"))
            default:
                let fifo = root.appendingPathComponent("pipe")
                #if canImport(Darwin)
                XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
                #elseif canImport(Glibc)
                XCTAssertEqual(Glibc.mkfifo(fifo.path, 0o600), 0)
                #elseif canImport(Musl)
                XCTAssertEqual(Musl.mkfifo(fifo.path, 0o600), 0)
                #endif
            }
            XCTAssertThrowsError(
                try MCPStdioSandboxCompiler
                    .linuxReadOnlyMasks(
                        lease: try linuxMaskLease(root: root),
                        workspace: root)
            ) { error in
                XCTAssertEqual(
                    error as? MCPManagedPipeError,
                    .workspacePolicyUnsupported,
                    hostile)
            }
        }
    }

    func testIsolatedTestWorkspaceUsesConfiguredWorkingDirectoryFirst()
        throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let configured = fixture.rootURL.appendingPathComponent(
            "configured",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: configured,
            withIntermediateDirectories: false)
        let configuration = try isolatedWorkspaceConfiguration(
            artifact: fixture.captureIdentity(),
            workingDirectory: configured.path)

        let selection = try XCTUnwrap(
            MCPIsolatedTestWorkspace.selection(
                for: configuration))
        let lease = try XCTUnwrap(
            MCPIsolatedTestWorkspace.lease(
                for: configuration))

        XCTAssertEqual(
            selection.source,
            .configuredWorkingDirectory)
        XCTAssertEqual(
            selection.rootPath,
            configured.resolvingSymlinksInPath()
                .standardizedFileURL.path)
        XCTAssertEqual(lease.rootPath, selection.rootPath)
        XCTAssertEqual(
            lease.rootIdentity,
            selection.rootIdentity)
        XCTAssertTrue(
            lease.id.rawValue.contains(
                String(
                    selection.bindingFingerprint
                        .prefix(24))))
    }

    func testIsolatedTestWorkspaceUsesOneExactScriptParent()
        throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let configuration = try isolatedWorkspaceConfiguration(
            artifact: fixture.captureIdentity())

        let selection = try XCTUnwrap(
            MCPIsolatedTestWorkspace.selection(
                for: configuration))

        XCTAssertEqual(
            selection.source,
            .launchComponentParent)
        XCTAssertEqual(
            selection.rootPath,
            fixture.rootURL.resolvingSymlinksInPath()
                .standardizedFileURL.path)
    }

    func testIsolatedTestWorkspaceRejectsAmbiguousComponentRoots()
        throws
    {
        let first = try StdioFixture(mode: .normal)
        let second = try StdioFixture(mode: .normal)
        defer {
            first.remove()
            second.remove()
        }
        let artifact =
            try MCPLaunchArtifactIdentityVerifier.captureForTest([
                MCPLaunchArtifactInput(
                    role: .executable,
                    path: "/bin/bash"),
                MCPLaunchArtifactInput(
                    role: .interpreter,
                    path: "/bin/bash"),
                MCPLaunchArtifactInput(
                    role: .script,
                    path: first.scriptURL.path),
                MCPLaunchArtifactInput(
                    role: .packageEntrypoint,
                    path: second.scriptURL.path),
            ])
        let configuration = try isolatedWorkspaceConfiguration(
            artifact: artifact)

        XCTAssertThrowsError(
            try MCPIsolatedTestWorkspace.selection(
                for: configuration)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .ambiguousTestWorkspaceRoot)
        }
    }

    func testIsolatedTestWorkspaceFallsBackToNativeExecutableParent()
        throws
    {
        let artifact =
            try MCPLaunchArtifactIdentityVerifier.captureForTest([
                MCPLaunchArtifactInput(
                    role: .executable,
                    path: "/bin/sh"),
            ])
        let configuration = try isolatedWorkspaceConfiguration(
            artifact: artifact)

        let selection = try XCTUnwrap(
            MCPIsolatedTestWorkspace.selection(
                for: configuration))
        let executable = try XCTUnwrap(
            artifact.files.first {
                $0.role == .executable
            })

        XCTAssertEqual(
            selection.source,
            .nativeExecutableParent)
        XCTAssertEqual(
            selection.rootPath,
            URL(fileURLWithPath: executable.canonicalPath)
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL.path)
    }

    func testPythonFixtureUsesDerivedRootForRelativeImport()
        throws
    {
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/python3")
        else {
            throw XCTSkip(
                "the exact /usr/bin/python3 fixture runtime is unavailable")
        }
        try runRelativeImportFixture(
            executable: "/usr/bin/python3",
            mainName: "main.py",
            dependencyName: "fixture_dependency.py",
            dependencySource:
                "VALUE = \"relative-import-ok\"\n",
            mainSource:
                "from fixture_dependency import VALUE\nprint(VALUE, end=\"\")\n")
    }

    func testNodeFixtureUsesDerivedRootForRelativeImport()
        throws
    {
        let candidates = [
            "/usr/bin/node",
            "/opt/homebrew/bin/node",
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(
                atPath: $0)
        }) else {
            throw XCTSkip(
                "an exact node fixture runtime is unavailable")
        }
        try runRelativeImportFixture(
            executable: executable,
            mainName: "main.js",
            dependencyName: "fixture-dependency.js",
            dependencySource:
                "module.exports = \"relative-import-ok\";\n",
            mainSource:
                "process.stdout.write(require(\"./fixture-dependency.js\"));\n")
    }

    func testConfiguredWorkingDirectoryOutsideSessionLeaseFailsClosed()
        async throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-mcp-outside-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        let material = try fixture.material(
            workingDirectoryOverride: outside.path)
        let ticket = try await fixture.ticket(
            for: material.request)

        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler.compile(
                ticket: ticket)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .workingDirectoryOutsideLease)
        }
    }

    func testLinuxReadOnlyMaskScanIsBoundedAndRequiresMandatoryFloor()
        throws {
        let root = try makeLinuxMaskWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(
            to: root.appendingPathComponent("one"))
        try Data().write(
            to: root.appendingPathComponent("two"))

        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler
                .linuxReadOnlyMasks(
                    lease: try linuxMaskLease(root: root),
                    workspace: root,
                    maximumEntries: 1)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .workspacePolicyUnsupported)
        }
        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler
                .linuxReadOnlyMasks(
                    lease: try linuxMaskLease(
                        root: root,
                        deniedPatterns: []),
                    workspace: root)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .workspacePolicyUnsupported)
        }
    }

    func testLinuxReadOnlyMaskScanRejectsReadWriteLeaseAndMissingBubblewrap()
        throws {
        let root = try makeLinuxMaskWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler
                .linuxReadOnlyMasks(
                    lease: try linuxMaskLease(
                        root: root,
                        access: .readWrite),
                    workspace: root)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .workspacePolicyUnsupported)
        }
        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler.resolveLinuxBubblewrap(
                candidates: [])
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .sandboxUnavailable)
        }
    }

    func testLinuxStdioSupportRequiresBubblewrapAndExecutionGuard() {
        XCTAssertTrue(
            MCPStdioExecutionGuard.linuxRequirementsSatisfied(
                bubblewrapAvailable: true,
                executionGuardAvailable: true))
        XCTAssertFalse(
            MCPStdioExecutionGuard.linuxRequirementsSatisfied(
                bubblewrapAvailable: false,
                executionGuardAvailable: true))
        XCTAssertFalse(
            MCPStdioExecutionGuard.linuxRequirementsSatisfied(
                bubblewrapAvailable: true,
                executionGuardAvailable: false))
        XCTAssertFalse(
            MCPStdioExecutionGuard.linuxRequirementsSatisfied(
                bubblewrapAvailable: false,
                executionGuardAvailable: false))
    }

    func testPrimaryInterpreterCannotAlsoBeAllowListedAsHelper()
        async throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let primary = try fixture.captureIdentity()
        let aliasedHelper =
            try MCPLaunchArtifactIdentityVerifier
                .captureHelperForTest([
                    MCPLaunchArtifactInput(
                        role: .helper,
                        path: "/bin/bash"),
                ])
        let configuration = try MCPStdioServerConfiguration(
            launchArtifact: primary,
            arguments: [
                fixture.scriptURL.path,
                StdioFixture.Mode.normal.rawValue,
            ],
            workingDirectory: fixture.rootURL.path,
            helperArtifacts: [aliasedHelper])
        let material = try fixture.material(
            configurationOverride: configuration)
        let ticket = try await fixture.ticket(
            for: material.request)

        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler.compile(
                ticket: ticket)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .invalidLaunchArtifact)
        }
    }

    #if os(Linux)
    func testLinuxProductionLeaseIsDistinctReadOnlyAuthority()
        throws {
        let root = try makeLinuxMaskWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentLease = try linuxMaskLease(
            root: root,
            access: .readWrite,
            deniedPatterns: [])

        let mcpLease = try MCPProductionStdioWorkspaceLease
            .derive(from: agentLease)

        XCTAssertEqual(agentLease.access, .readWrite)
        XCTAssertEqual(mcpLease.access, .readOnly)
        XCTAssertNotEqual(mcpLease.id, agentLease.id)
        XCTAssertEqual(
            mcpLease.allowedPathRules,
            [PathRule(pattern: ".")])
        XCTAssertTrue(
            Set(mcpLease.deniedPatterns.map {
                $0.lowercased()
            }).isSuperset(
                of: WorkspaceLease
                    .mandatoryTerminalDeniedPatterns
                    .map { $0.lowercased() }))
    }

    func testLinuxDefaultForkAndSameInterpreterReexecAreDeniedByGuard()
        async throws
    {
        try requireLinuxStdioGuard()
        for mode in [
            StdioFixture.Mode.normal,
            .sameInterpreterReexec,
        ] {
            let fixture = try StdioFixture(mode: mode)
            defer { fixture.remove() }
            try await runLinuxHandshakeFixture(fixture)
        }
    }

    func testLinuxExactHelperExecIsAllowedEndToEnd()
        async throws
    {
        try requireLinuxStdioGuard()
        let fixture = try StdioFixture(mode: .exactHelper)
        defer { fixture.remove() }
        try await runLinuxHandshakeFixture(fixture)
    }

    func testLinuxExactNetworkUsesCredentialedGatewayWithoutArgvSecret()
        async throws
    {
        try requireLinuxStdioGuard()
        let listener: LocalTCPListener
        do {
            listener = try LocalTCPListener()
        } catch {
            throw XCTSkip(
                "the Linux test host blocks loopback listeners")
        }
        defer { listener.stop() }
        let fixture = try StdioFixture(
            mode: .exactNetworkProxy,
            networkProbePort: listener.port)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(
            for: material.request)

        let plan = try MCPStdioSandboxCompiler.compile(
            ticket: ticket)
        let gateway = try XCTUnwrap(plan.networkGateway)
        for secret in gateway.diagnosticRedactionValues {
            XCTAssertFalse(
                plan.wrapperArguments.contains(where: {
                    $0.contains(secret)
                }))
        }
        XCTAssertFalse(plan.wrapperArguments.contains("--clearenv"))
        XCTAssertFalse(plan.wrapperArguments.contains("--setenv"))
        XCTAssertTrue(plan.wrapperArguments.contains("--share-net"))
        XCTAssertFalse(plan.wrapperArguments.contains("--unshare-net"))
        gateway.stop()
        try? FileManager.default.removeItem(
            at: plan.runtimeDirectory)

        try await runLinuxHandshakeFixture(fixture)
        let deadline = Date().addingTimeInterval(1)
        while !listener.acceptedConnection(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(listener.hasAcceptedConnection)
    }

    func testLinuxDirectUDPAndAlternateLoopbackBypassesRetireGeneration()
        async throws
    {
        try requireLinuxStdioGuard()
        let listener: LocalTCPListener
        do {
            listener = try LocalTCPListener()
        } catch {
            throw XCTSkip(
                "the Linux test host blocks loopback listeners")
        }
        defer { listener.stop() }
        for mode in [
            StdioFixture.Mode.exactNetworkDirectBypass,
            .exactNetworkUDPBypass,
            .exactNetworkAlternateLoopbackBypass,
        ] {
            let fixture = try StdioFixture(
                mode: mode,
                networkProbePort: listener.port)
            defer { fixture.remove() }
            try await assertLinuxNetworkViolation(fixture)
        }
        XCTAssertFalse(listener.acceptedConnection())
    }

    func testLinuxUnlistedExecIsStoppedBeforeNewImageRuns()
        async throws
    {
        try requireLinuxStdioGuard()
        let fixture = try StdioFixture(mode: .unlistedHelper)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(
            for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 750))
        let session = MCPClientSession(
            configuration:
                MCPClientSessionConfiguration(
                    server: material.server,
                    generation: material.generation,
                    profile: .codexCompat,
                    requiredCapabilities: [.tools],
                    startupTimeoutMilliseconds: 2_000,
                    callTimeoutMilliseconds: 1_000,
                    clientVersion:
                        "stdio-linux-unlisted-exec-test"),
            transport: process)
        do {
            _ = try await session.start()
            XCTFail("unlisted executable entered user code")
        } catch {
            for _ in 0..<100 {
                let diagnostics =
                    await process.diagnostics()
                if diagnostics.terminalError != nil {
                    break
                }
                try? await Task.sleep(
                    nanoseconds: 5_000_000)
            }
            let diagnostics = await process.diagnostics()
            XCTAssertEqual(
                diagnostics.terminalError,
                MCPManagedPipeError
                    .descendantExecutionPolicyViolation
                    .errorDescription)
        }
        await session.shutdown()
        let running = await process.isRunning()
        XCTAssertFalse(running)
    }

    private func requireLinuxStdioGuard() throws {
        guard (try? MCPStdioSandboxCompiler
                .resolveLinuxBubblewrap()) != nil else {
            throw XCTSkip("bubblewrap is unavailable")
        }
        guard MCPStdioExecutionGuard
                .linuxKernelGuardAvailable() else {
            throw XCTSkip(
                "ptrace/seccomp execution guard is unavailable")
        }
    }

    private func runLinuxHandshakeFixture(
        _ fixture: StdioFixture
    ) async throws {
        let material = try fixture.material()
        let ticket = try await fixture.ticket(
            for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 750))
        let session = MCPClientSession(
            configuration:
                MCPClientSessionConfiguration(
                    server: material.server,
                    generation: material.generation,
                    profile: .codexCompat,
                    requiredCapabilities: [.tools],
                    startupTimeoutMilliseconds: 2_000,
                    callTimeoutMilliseconds: 1_000,
                    clientVersion:
                        "stdio-linux-guard-e2e-test"),
            transport: process)
        do {
            _ = try await session.start()
            try await session.ping(
                timeoutMilliseconds: 500)
            await session.shutdown()
        } catch {
            let diagnostics = await process.diagnostics()
            await session.shutdown()
            throw StdioFixtureExecutionError(
                mode: fixture.mode.rawValue,
                underlying: error,
                diagnostics: diagnostics)
        }
    }

    private func assertLinuxNetworkViolation(
        _ fixture: StdioFixture
    ) async throws {
        let material = try fixture.material()
        let ticket = try await fixture.ticket(
            for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 750))
        let session = MCPClientSession(
            configuration:
                MCPClientSessionConfiguration(
                    server: material.server,
                    generation: material.generation,
                    profile: .codexCompat,
                    requiredCapabilities: [.tools],
                    startupTimeoutMilliseconds: 2_000,
                    callTimeoutMilliseconds: 1_000,
                    clientVersion:
                        "stdio-linux-network-guard-e2e-test"),
            transport: process)
        do {
            _ = try await session.start()
            XCTFail("network bypass did not retire generation")
        } catch {
            for _ in 0..<100 {
                let diagnostics = await process.diagnostics()
                if diagnostics.terminalError != nil {
                    break
                }
                try? await Task.sleep(
                    nanoseconds: 5_000_000)
            }
            let diagnostics = await process.diagnostics()
            XCTAssertEqual(
                diagnostics.terminalError,
                MCPManagedPipeError
                    .exactNetworkPolicyViolation
                    .errorDescription)
        }
        await session.shutdown()
        XCTAssertFalse(await process.isRunning())
    }
    #endif

    #if os(macOS)
    func testDeniedNetworkAndSensitivePathsAreCompiledIntoSeatbeltProfile() async throws {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let plan = try MCPStdioSandboxCompiler.compile(ticket: ticket)
        defer { try? FileManager.default.removeItem(at: plan.runtimeDirectory) }

        XCTAssertEqual(plan.wrapperExecutable, "/usr/bin/sandbox-exec")
        let profile = try XCTUnwrap(
            plan.wrapperArguments.dropFirst().first)
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("file-map-executable"))
        XCTAssertTrue(profile.contains("process-exec"))
        XCTAssertTrue(
            profile.contains(
                #"(process-path "/usr/bin/sandbox-exec")"#))
        XCTAssertTrue(profile.contains("(deny process-fork)"))
        XCTAssertFalse(profile.contains("(allow process-fork)"))
        XCTAssertFalse(profile.contains("(allow network*)"))
        XCTAssertFalse(profile.contains("/dev/tty"))
        XCTAssertFalse(profile.contains(fixture.secret))
        let scriptPath = fixture.scriptURL.path
        let sandboxScriptPath = ["/var", "/tmp", "/etc"].contains {
            scriptPath == $0 || scriptPath.hasPrefix($0 + "/")
        } ? "/private\(scriptPath)" : scriptPath
        XCTAssertTrue(
            profile.contains(
                "(deny file-write* (literal \"\(sandboxScriptPath)\"))"))
    }

    func testHelperAuthorityFailsClosedWhenSeatbeltCannotProvePreExecCleanup()
        async throws
    {
        let fixture = try StdioFixture(
            mode: .helperAndNetworkAllowed,
            networkProbePort: 42_431)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        XCTAssertThrowsError(
            try MCPStdioSandboxCompiler.compile(ticket: ticket)
        ) { error in
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .descendantExecutionGuardUnavailable)
        }
    }

    func testRemoteExactNetworkOriginUsesOnlyAuthenticatedLoopbackGateway()
        async throws
    {
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let material = try fixture.material(
            networkPolicyOverride: .exactOrigins([
                "https://127.0.0.1:443",
            ]))
        let ticket = try await fixture.ticket(for: material.request)
        let plan: MCPStdioSandboxPlan
        do {
            plan = try MCPStdioSandboxCompiler.compile(ticket: ticket)
        } catch MCPManagedPipeError.exactNetworkPolicyUnavailable {
            throw XCTSkip(
                "the outer test host blocks the exact loopback gateway")
        }
        defer {
            plan.networkGateway?.stop()
            try? FileManager.default.removeItem(
                at: plan.runtimeDirectory)
        }
        let gateway = try XCTUnwrap(plan.networkGateway)
        let profile = try XCTUnwrap(
            plan.wrapperArguments.dropFirst().first)
        XCTAssertTrue(
            profile.contains(
                #"127.0.0.1:\#(gateway.port)"#))
        XCTAssertTrue(profile.contains("(deny network-inbound)"))
        XCTAssertTrue(profile.contains("(deny network-outbound"))
        XCTAssertTrue(profile.contains("(require-not"))
        XCTAssertTrue(profile.contains("(remote tcp"))
        XCTAssertFalse(profile.contains("example.com"))
        XCTAssertFalse(profile.contains("(allow network*)"))
        XCTAssertFalse(profile.contains(#"remote udp"#))
        XCTAssertFalse(profile.contains(#"127.0.0.2"#))
        for name in [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy",
        ] {
            XCTAssertEqual(
                plan.environment[name],
                gateway.proxyURL)
        }
        XCTAssertEqual(plan.environment["NO_PROXY"], "")
        XCTAssertEqual(plan.environment["no_proxy"], "")
    }

    func testRealFixtureInitializePingDiagnosticsAndShutdown() async throws {
        let listener: LocalTCPListener
        do {
            listener = try LocalTCPListener()
        } catch {
            throw XCTSkip(
                "the outer test host blocks the loopback fixture listener")
        }
        defer { listener.stop() }
        let fixture = try StdioFixture(
            mode: .normal,
            networkProbePort: listener.port)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                maximumFrameBytes: 16 * 1_024,
                terminationGraceMilliseconds: 200,
                killDrainMilliseconds: 1_000))
        let session = MCPClientSession(
            configuration: MCPClientSessionConfiguration(
                server: material.server,
                generation: material.generation,
                profile: .codexCompat,
                requiredCapabilities: [.tools],
                startupTimeoutMilliseconds: 2_000,
                callTimeoutMilliseconds: 1_000,
                clientVersion: "stdio-e2e-test"),
            transport: process)

        do {
            let handshake = try await session.start()
            XCTAssertEqual(
                handshake.negotiatedVersion.value,
                .v2025_06_18)
            XCTAssertTrue(
                handshake.capabilities.capabilities.contains(.tools))
            try await session.ping(timeoutMilliseconds: 500)

            let diagnostics = await process.diagnostics()
            XCTAssertGreaterThan(diagnostics.totalBytes, 0)
            XCTAssertFalse(
                diagnostics.entries.joined(separator: "\n")
                    .contains(fixture.secret))
            XCTAssertTrue(
                diagnostics.entries.joined(separator: "\n")
                    .contains("[REDACTED]"))
            XCTAssertFalse(listener.acceptedConnection())

            await session.shutdown()
            let running = await process.isRunning()
            XCTAssertFalse(running)
        } catch {
            let diagnostics = await process.diagnostics()
            await session.shutdown()
            if diagnostics.entries.contains(where: {
                $0.contains("sandbox_apply")
            }) {
                throw XCTSkip(
                    "the outer test host blocks nested Seatbelt: \(diagnostics.entries)")
            }
            throw StdioFixtureExecutionError(
                mode: fixture.mode.rawValue,
                underlying: error,
                diagnostics: diagnostics)
        }
    }

    func testDefaultForkAndUnlistedExecAreDeniedEndToEnd()
        async throws
    {
        let deniedListener: LocalTCPListener
        let allowedListener: LocalTCPListener
        do {
            deniedListener = try LocalTCPListener()
            allowedListener = try LocalTCPListener()
        } catch {
            throw XCTSkip(
                "the outer test host blocks the loopback fixture listener")
        }
        defer {
            deniedListener.stop()
            allowedListener.stop()
        }

        let denied = try StdioFixture(
            mode: .normal,
            networkProbePort: deniedListener.port)
        defer { denied.remove() }
        try await runHandshakeFixture(denied)
        XCTAssertFalse(deniedListener.acceptedConnection())

        let unsupportedHelper = try StdioFixture(
            mode: .helperAndNetworkAllowed,
            networkProbePort: allowedListener.port)
        defer { unsupportedHelper.remove() }
        let helperMaterial = try unsupportedHelper.material()
        let helperTicket = try await unsupportedHelper.ticket(
            for: helperMaterial.request)
        do {
            _ = try await ManagedPipeProcess.launch(
                ticket: helperTicket)
            XCTFail("unprovable helper authority launched")
        } catch {
            XCTAssertEqual(
                error as? MCPManagedPipeError,
                .descendantExecutionGuardUnavailable)
        }
        XCTAssertFalse(allowedListener.acceptedConnection())
    }

    func testSameInterpreterSecondExecIsDeniedBeforeNewImageRuns()
        async throws
    {
        let fixture = try StdioFixture(
            mode: .sameInterpreterReexec)
        defer { fixture.remove() }
        try await runHandshakeFixture(fixture)
    }

    func testActiveSetSIDAttemptCannotEscapeExactProcessOwnership()
        async throws
    {
        let ruby = "/usr/bin/ruby"
        guard FileManager.default.isExecutableFile(
            atPath: ruby) else {
            throw XCTSkip("the setsid fixture runtime is unavailable")
        }
        let fixture = try StdioFixture(mode: .normal)
        defer { fixture.remove() }
        let script = fixture.rootURL.appendingPathComponent(
            "setsid-fixture.rb")
        try Data(
            """
            outcome = begin
              Process.setsid
              "escaped"
            rescue SystemCallError
              "denied"
            end
            STDOUT.write("{\\"jsonrpc\\":\\"2.0\\",\\"method\\":\\"guard/setsid-#{outcome}\\"}\\n")
            STDOUT.flush
            sleep 30
            """.utf8
        ).write(to: script, options: .atomic)
        let identity =
            try MCPLaunchArtifactIdentityVerifier
                .captureForTest([
                    MCPLaunchArtifactInput(
                        role: .executable,
                        path: ruby),
                    MCPLaunchArtifactInput(
                        role: .interpreter,
                        path: ruby),
                    MCPLaunchArtifactInput(
                        role: .script,
                        path: script.path),
                ])
        let configuration = try MCPStdioServerConfiguration(
            launchArtifact: identity,
            arguments: ["--disable-gems", script.path],
            workingDirectory: fixture.rootURL.path)
        let material = try fixture.material(
            configurationOverride: configuration)
        let ticket = try await fixture.ticket(
            for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 750))
        do {
            try await process.connect()
            let stream = await process.receive()
            let frame = try await firstFrame(
                from: stream,
                timeoutMilliseconds: 2_000)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: frame) as? [String: Any])
            XCTAssertEqual(
                object["method"] as? String,
                "guard/setsid-denied")
        } catch {
            let diagnostics = await process.diagnostics()
            await process.disconnect()
            if diagnostics.entries.contains(where: {
                $0.contains("sandbox_apply")
            }) {
                throw XCTSkip("outer host blocks nested Seatbelt")
            }
            throw StdioFixtureExecutionError(
                mode: "setsid",
                underlying: error,
                diagnostics: diagnostics)
        }
        await process.disconnect()
        let running = await process.isRunning()
        XCTAssertFalse(running)
    }

    func testStubbornProcessIsKilledAndFullyReapedWithinBound() async throws {
        let fixture = try StdioFixture(mode: .stubborn)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                terminationGraceMilliseconds: 75,
                killDrainMilliseconds: 750))
        try await process.connect()

        let startedAt = Date()
        await process.disconnect()
        let elapsed = Date().timeIntervalSince(startedAt)
        let running = await process.isRunning()
        XCTAssertFalse(running)
        XCTAssertLessThan(elapsed, 2)
    }

    func testInboundQueueOverflowRetiresGeneration() async throws {
        let fixture = try StdioFixture(mode: .queueOverflow)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                maximumQueuedFrames: 1,
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 500))
        try await process.connect()
        try await process.send(Self.initializeFrame)
        let diagnostics = await waitForTerminalDiagnostics(process)
        if diagnostics.entries.contains(where: {
            $0.contains("sandbox_apply")
        }) {
            await process.disconnect()
            throw XCTSkip("outer host blocks nested Seatbelt")
        }
        XCTAssertEqual(
            diagnostics.terminalError,
            MCPManagedPipeError.frameQueueOverflow.errorDescription,
            "diagnostics=\(diagnostics)")
        let automaticallyReaped = await waitUntilStopped(process)
        XCTAssertTrue(automaticallyReaped)
        await process.disconnect()
        let running = await process.isRunning()
        XCTAssertFalse(running)
    }

    func testHostileOversizeFrameRetiresGeneration() async throws {
        try await assertHostileFixture(
            mode: .oversize,
            expected: .inboundFrameTooLarge)
    }

    func testPartialFrameAtEOFRetiresGeneration() async throws {
        try await assertHostileFixture(
            mode: .partialEOF,
            expected: .partialFrameAtEOF)
    }

    func testMalformedFrameRetiresGeneration() async throws {
        try await assertHostileFixture(
            mode: .malformed,
            expected: .inboundFrameInvalid)
    }

    func testStderrFloodIsBoundedAndRetiresGeneration() async throws {
        let fixture = try StdioFixture(mode: .stderrFlood)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                maximumFrameBytes: 4 * 1_024,
                maximumStderrRetainedBytes: 1_024,
                maximumStderrTotalBytes: 8 * 1_024,
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 500))
        do {
            try await process.connect()
            try await process.send(Self.initializeFrame)
            let stream = await process.receive()
            var iterator = stream.makeAsyncIterator()
            while try await iterator.next() != nil {}
            let diagnostics = await process.diagnostics()
            if diagnostics.entries.contains(where: {
                $0.contains("sandbox_apply")
            }) {
                await process.disconnect()
                throw XCTSkip("outer host blocks nested Seatbelt")
            }
            XCTAssertEqual(
                diagnostics.terminalError,
                MCPManagedPipeError.stderrLimitExceeded.errorDescription)
            XCTAssertTrue(diagnostics.truncated)
        } catch {
            let diagnostics = await process.diagnostics()
            if diagnostics.entries.contains(where: {
                $0.contains("sandbox_apply")
            }) {
                await process.disconnect()
                throw XCTSkip("outer host blocks nested Seatbelt")
            }
            XCTAssertLessThanOrEqual(
                diagnostics.entries.joined(separator: "\n").utf8.count,
                1_024 + 512)
            XCTAssertTrue(diagnostics.truncated)
            XCTAssertEqual(
                diagnostics.terminalError,
                MCPManagedPipeError.stderrLimitExceeded.errorDescription)
        }
        await process.disconnect()
    }

    private func assertHostileFixture(
        mode: StdioFixture.Mode,
        expected: MCPManagedPipeError
    ) async throws {
        let fixture = try StdioFixture(mode: mode)
        defer { fixture.remove() }
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                maximumFrameBytes: 1_024,
                maximumQueuedFrames: 2,
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 500))
        do {
            try await process.connect()
            let stream = await process.receive()
            var iterator = stream.makeAsyncIterator()
            try await process.send(Self.initializeFrame)
            let value = try await iterator.next()
            let diagnostics = await process.diagnostics()
            if value == nil,
               diagnostics.entries.contains(where: {
                   $0.contains("sandbox_apply")
               }) {
                await process.disconnect()
                throw XCTSkip(
                    "outer host blocks nested Seatbelt: \(diagnostics.entries)")
            }
            if diagnostics.terminalError
                == expected.errorDescription {
                // A transport consumer may observe terminal nil after the
                // continuation was already terminated. The typed terminal
                // snapshot remains the generation's single source of truth.
            } else {
                XCTFail(
                    "expected \(expected), value=\(String(describing: value)), diagnostics=\(diagnostics)")
            }
        } catch {
            let diagnostics = await process.diagnostics()
            if diagnostics.entries.contains(where: {
                $0.contains("sandbox_apply")
            }) {
                await process.disconnect()
                throw XCTSkip("outer host blocks nested Seatbelt")
            }
            XCTAssertEqual(error as? MCPManagedPipeError, expected)
        }
        await process.disconnect()
        let running = await process.isRunning()
        XCTAssertFalse(running)
    }

    private func runHandshakeFixture(
        _ fixture: StdioFixture
    ) async throws {
        let material = try fixture.material()
        let ticket = try await fixture.ticket(for: material.request)
        let process = try await ManagedPipeProcess.launch(
            ticket: ticket,
            limits: MCPManagedPipeLimits(
                terminationGraceMilliseconds: 100,
                killDrainMilliseconds: 750))
        let session = MCPClientSession(
            configuration: MCPClientSessionConfiguration(
                server: material.server,
                generation: material.generation,
                profile: .codexCompat,
                requiredCapabilities: [.tools],
                startupTimeoutMilliseconds: 2_000,
                callTimeoutMilliseconds: 1_000,
                clientVersion: "stdio-policy-e2e-test"),
            transport: process)
        do {
            _ = try await session.start()
            try await session.ping(timeoutMilliseconds: 500)
            await session.shutdown()
        } catch {
            let diagnostics = await process.diagnostics()
            await session.shutdown()
            if diagnostics.entries.contains(where: {
                $0.contains("sandbox_apply")
            }) {
                throw XCTSkip(
                    "the outer test host blocks nested Seatbelt: \(diagnostics.entries)")
            }
            throw StdioFixtureExecutionError(
                mode: fixture.mode.rawValue,
                underlying: error,
                diagnostics: diagnostics)
        }
    }

    private func firstFrame(
        from stream: AsyncThrowingStream<Data, Error>,
        timeoutMilliseconds: Int
    ) async throws -> Data {
        try await withThrowingTaskGroup(
            of: Data.self
        ) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let frame = try await iterator.next()
                else {
                    throw MCPManagedPipeError.transportClosed
                }
                return frame
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds:
                        UInt64(timeoutMilliseconds)
                        * 1_000_000)
                throw MCPManagedPipeError.writeTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next()
            else {
                throw MCPManagedPipeError.transportClosed
            }
            return result
        }
    }

    private func waitUntilStopped(
        _ process: ManagedPipeProcess
    ) async -> Bool {
        for _ in 0..<100 {
            if !(await process.isRunning()) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return !(await process.isRunning())
    }

    private func waitForTerminalDiagnostics(
        _ process: ManagedPipeProcess
    ) async -> MCPStdioDiagnosticsSnapshot {
        for _ in 0..<200 {
            let diagnostics = await process.diagnostics()
            if diagnostics.terminalError != nil
                || diagnostics.entries.contains(where: {
                    $0.contains("sandbox_apply")
                }) {
                return diagnostics
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await process.diagnostics()
    }
    #endif

    private func makeLinuxMaskWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-mcp-linux-mask-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return root
    }

    private func linuxMaskLease(
        root: URL,
        access: WorkspaceAccess = .readOnly,
        deniedPatterns: [String] =
            WorkspaceLease.defaultDeniedPatterns
    ) throws -> WorkspaceLease {
        WorkspaceLease(
            id: WorkspaceLeaseID(
                rawValue: "wlease_linux_mask"),
            workspaceID: WorkspaceID(
                rawValue: "workspace_linux_mask"),
            rootPath: root.path,
            rootIdentity: try XCTUnwrap(
                WorkspaceRootIdentity.capture(
                    rootPath: root.path)),
            access: access,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: deniedPatterns)
    }

    func testCrashReconciliationNeverSignalsHistoricalPID() {
        XCTAssertFalse(
            MCPStdioCrashReconciliationPolicy
                .maySignalHistoricalProcessIdentifier)
    }

    private static let initializeFrame = Data(
        #"{"jsonrpc":"2.0","id":"fixture-request","method":"initialize","params":{}}"#
            .utf8)
}

private func preparedStdioConfiguration(
    fixture: StdioFixture,
    serverID: MCPServerID
) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
        serverID: serverID,
        displayName: serverID.rawValue,
        approvalPolicy:
            MCPApprovalPolicy(serverDefault: .prompt),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .stdio(
            try MCPStdioServerConfiguration(
                launchArtifact:
                    fixture.captureIdentity(),
                arguments: [
                    fixture.scriptURL.path,
                    StdioFixture.Mode.normal.rawValue,
                ],
                workingDirectory:
                    fixture.rootURL.path)),
        environmentReference:
            MCPEnvironmentReference(
                rawValue: "mcpenv_precommit_test"),
        provenance:
            MCPConfigurationProvenance(
                sourceKind: .intatisUser,
            sourceLabel: "precommit-test"))
}

private func isolatedWorkspaceConfiguration(
    artifact: LaunchArtifactIdentity,
    workingDirectory: String? = nil
) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
        serverID: MCPServerID(
            rawValue:
                "mcpserver_isolated_workspace_fixture"),
        displayName: "Isolated workspace fixture",
        approvalPolicy:
            MCPApprovalPolicy(serverDefault: .prompt),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .stdio(
            try MCPStdioServerConfiguration(
                launchArtifact: artifact,
                workingDirectory: workingDirectory)),
        environmentReference:
            MCPEnvironmentReference(
                rawValue:
                    "mcpenv_isolated_workspace_fixture"),
        provenance:
            MCPConfigurationProvenance(
                sourceKind: .intatisUser,
                sourceLabel:
                    "isolated-workspace-fixture"))
}

private func runRelativeImportFixture(
    executable: String,
    mainName: String,
    dependencyName: String,
    dependencySource: String,
    mainSource: String
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "intatis-mcp-relative-import-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let main = root.appendingPathComponent(mainName)
    try Data(dependencySource.utf8).write(
        to: root.appendingPathComponent(dependencyName),
        options: .atomic)
    try Data(mainSource.utf8).write(
        to: main,
        options: .atomic)
    let artifact =
        try MCPLaunchArtifactIdentityVerifier.captureForTest([
            MCPLaunchArtifactInput(
                role: .executable,
                path: executable),
            MCPLaunchArtifactInput(
                role: .interpreter,
                path: executable),
            MCPLaunchArtifactInput(
                role: .script,
                path: main.path),
        ])
    let configuration = try isolatedWorkspaceConfiguration(
        artifact: artifact)
    let selection = try XCTUnwrap(
        MCPIsolatedTestWorkspace.selection(
            for: configuration))
    XCTAssertEqual(
        selection.source,
        .launchComponentParent)
    XCTAssertEqual(
        selection.rootPath,
        root.resolvingSymlinksInPath()
            .standardizedFileURL.path)

    let process = Process()
    process.executableURL =
        URL(fileURLWithPath: executable)
    process.arguments = [main.path]
    process.currentDirectoryURL =
        URL(fileURLWithPath: selection.rootPath)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data =
        output.fileHandleForReading.readDataToEndOfFile()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(
        String(data: data, encoding: .utf8),
        "relative-import-ok")
}

private func successfulPreparedTest(
    _ prepared: MCPPreparedServerConfiguration
) throws -> MCPConfigurationTestResult {
    try MCPConfigurationTestResult(
        challenge: prepared.staging.challenge,
        terminal: .succeeded,
        testedIdentityFingerprint:
            prepared.staging
                .expectedTestedIdentityFingerprint,
        sanitizedReasonCode: "ok")
}

private func preparedStdioTestAuthorization()
    throws -> MCPConfigurationTestAuthorization
{
    try MCPConfigurationTestAuthorization(
        directUserAction: true,
        callerFingerprint:
            String(repeating: "b", count: 64))
}

private struct StdioFixture {
    enum Mode: String {
        case normal
        case helperAndNetworkAllowed = "helper-network-allowed"
        case exactHelper = "exact-helper"
        case unlistedHelper = "unlisted-helper"
        case sameInterpreterReexec = "same-interpreter-reexec"
        case stubborn
        case queueOverflow = "queue-overflow"
        case oversize
        case partialEOF = "partial-eof"
        case malformed
        case stderrFlood = "stderr-flood"
        case exactNetworkProxy = "exact-network-proxy"
        case exactNetworkDirectBypass =
            "exact-network-direct-bypass"
        case exactNetworkUDPBypass =
            "exact-network-udp-bypass"
        case exactNetworkAlternateLoopbackBypass =
            "exact-network-alternate-loopback-bypass"
    }

    struct Material {
        let server: MCPServerReference
        let generation: MCPConnectionGeneration
        let request: MCPStdioLaunchRequest
    }

    let rootURL: URL
    let scriptURL: URL
    let mode: Mode
    let secret = "fixture-secret-value-never-log"
    let networkProbePort: UInt16

    var environment: [String: String] {
        [
            "FIXTURE_TOKEN": secret,
            "FIXTURE_PROTOCOL": "2025-06-18",
            "FIXTURE_PORT": String(networkProbePort),
        ]
    }

    init(mode: Mode, networkProbePort: UInt16 = 9) throws {
        self.mode = mode
        self.networkProbePort = networkProbePort
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-mcp-fixture-\(UUID().uuidString)",
                isDirectory: true)
        self.scriptURL = rootURL.appendingPathComponent("fixture.sh")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data(Self.script.utf8).write(
            to: scriptURL,
            options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: scriptURL.path)
        try Data("do-not-read\n".utf8).write(
            to: rootURL.appendingPathComponent(".env"),
            options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func captureIdentity(
        includesUnlistedExecutable: Bool = false
    ) throws -> LaunchArtifactIdentity {
        var inputs = [
            MCPLaunchArtifactInput(
                role: .executable,
                path: "/bin/bash"),
            MCPLaunchArtifactInput(
                role: .interpreter,
                path: "/bin/bash"),
            MCPLaunchArtifactInput(
                role: .script,
                path: scriptURL.path),
        ]
        if includesUnlistedExecutable {
            inputs.append(
                MCPLaunchArtifactInput(
                    role: .packageEntrypoint,
                    path: "/usr/bin/false"))
        }
        return try MCPLaunchArtifactIdentityVerifier
            .captureForTest(inputs)
    }

    func material(
        networkPolicyOverride: MCPStdioNetworkPolicy? = nil,
        workingDirectoryOverride: String? = nil,
        configurationOverride:
            MCPStdioServerConfiguration? = nil
    ) throws -> Material {
        let identity = try captureIdentity(
            includesUnlistedExecutable:
                mode == .unlistedHelper)
        let helperArtifacts: [LaunchArtifactIdentity]
        let networkPolicy: MCPStdioNetworkPolicy
        if [
            .helperAndNetworkAllowed,
            .exactHelper,
            .unlistedHelper,
        ].contains(mode) {
            helperArtifacts = [
                try MCPLaunchArtifactIdentityVerifier.captureHelperForTest([
                    MCPLaunchArtifactInput(
                        role: .helper,
                        path: "/usr/bin/true"),
                ]),
            ]
            networkPolicy =
                mode == .helperAndNetworkAllowed
                    ? .exactOrigins([
                        "https://localhost:\(networkProbePort)",
                    ])
                    : .denied
        } else if [
            .exactNetworkProxy,
            .exactNetworkDirectBypass,
            .exactNetworkUDPBypass,
            .exactNetworkAlternateLoopbackBypass,
        ].contains(mode) {
            helperArtifacts = []
            networkPolicy = .exactOrigins([
                "https://127.0.0.1:\(networkProbePort)",
            ])
        } else {
            helperArtifacts = []
            networkPolicy = .denied
        }
        let tokenReference = try MCPSecretReference(
            storageClass: .hostOwned,
            identifier: "fixture_token")
        let configuration =
            try configurationOverride
                ?? MCPStdioServerConfiguration(
                    launchArtifact: identity,
                    arguments: [scriptURL.path, mode.rawValue],
                    workingDirectory:
                        workingDirectoryOverride ?? rootURL.path,
                    environment: [
                        "FIXTURE_TOKEN": .secret(tokenReference),
                        "FIXTURE_PROTOCOL":
                            .literal("2025-06-18"),
                        "FIXTURE_PORT":
                            .literal(String(networkProbePort)),
                    ],
                    helperArtifacts: helperArtifacts,
                    networkPolicy:
                        networkPolicyOverride ?? networkPolicy)
        let rootIdentity = try XCTUnwrap(
            WorkspaceRootIdentity.capture(rootPath: rootURL.path))
        let workspaceLease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "wslease_mcp_fixture"),
            workspaceID: WorkspaceID(rawValue: "workspace_mcp_fixture"),
            rootPath: rootURL.path,
            rootIdentity: rootIdentity,
            access:
                {
                    #if os(Linux)
                    return .readOnly
                    #else
                    return .readWrite
                    #endif
                }(),
            allowedPathRules: [PathRule(pattern: ".")])
        let server = MCPServerReference(
            serverID: MCPServerID(rawValue: "mcp_fixture"),
            serverRevision: MCPServerRevision(
                rawValue: "mcpsrvrev_fixture"))
        let generation = MCPConnectionGeneration(
            rawValue: "mcpcnx_fixture")
        let authority = MCPConnectionAuthority(
            server: server,
            transport: .stdio,
            protocolProfile: .codexCompat,
            sessionID: SessionID(rawValue: "session_mcp_fixture"),
            agentID: AgentID(rawValue: "main"),
            attachmentID: MCPAttachmentID(
                rawValue: "mcpattach_fixture"),
            capabilityLeaseID: CapabilityLeaseID(
                rawValue: "caplease_mcp_fixture"),
            capabilityTaskID: workspaceLease.taskID,
            workspaceLeaseID: workspaceLease.id,
            workspaceRootIdentityFingerprint:
                String(repeating: "1", count: 64),
            workspaceLeasePolicyFingerprint:
                MCPConnectionIdentityBuilder
                    .workspaceLeasePolicyFingerprint(
                        workspaceLease),
            attachmentPolicyRevision: MCPPolicyRevision(
                rawValue: "mcppol_attach"),
            environmentReference: MCPEnvironmentReference(
                rawValue: "mcpenv_fixture"),
            launchArtifactFingerprint:
                configuration.launchArtifact.fingerprint,
            rootsPolicyRevision: MCPPolicyRevision(
                rawValue: "mcppol_roots"),
            networkPolicyRevision: MCPPolicyRevision(
                rawValue: "mcppol_network"),
            sandboxProfileRevision: MCPPolicyRevision(
                rawValue: "mcppol_sandbox"),
            sandboxPolicyFingerprint:
                String(repeating: "3", count: 64),
            hostPlatform: "macOS",
            fingerprint: String(repeating: "2", count: 64))
        let request = try MCPStdioLaunchRequest(
            operationID: MCPControlOperationID(
                rawValue: "mcpop_fixture"),
            purpose: .isolatedTest,
            authority: authority,
            configuration: configuration,
            workspaceLease: workspaceLease)
        return Material(
            server: server,
            generation: generation,
            request: request)
    }

    func ticket(
        for request: MCPStdioLaunchRequest
    ) async throws -> MCPAuthorizedStdioLaunchTicket {
        let environment = self.environment
        let issuer = MCPStdioLaunchTicketIssuer { request in
            let requestedNames =
                Set(request.configuration.environment.keys)
                    .union(
                        request.configuration
                            .inheritedEnvironmentReferences.keys)
            let resolved = environment.filter {
                requestedNames.contains($0.key)
            }
            return MCPStdioHostAuthorization(
                decisionID: "fixture-control-plane-allow",
                operationID: request.operationID,
                authorityFingerprint: request.authority.fingerprint,
                launchArtifactFingerprint:
                    request.configuration.launchArtifact.fingerprint,
                workspaceLeaseID: request.workspaceLease.id,
                expiresAt: Date().addingTimeInterval(30),
                resolvedEnvironment: resolved)
        }
        return try await issuer.issue(for: request)
    }

    private static let script = #"""
    #!/bin/bash
    set -u
    shopt -s execfail
    mode="${1:-normal}"

    if [ "$mode" = same-interpreter-reexec ]; then
      exec /bin/bash "$0" reexec-succeeded
      printf '%s\n' 'same interpreter re-exec denied' >&2
    elif [ "$mode" = reexec-succeeded ]; then
      printf '%s\n' 'same interpreter re-exec unexpectedly succeeded' >&2
      exit 78
    fi

    if [ "${SSH_AUTH_SOCK+x}" = x ]; then
      printf '%s\n' 'unexpected inherited environment' >&2
      exit 71
    fi
    if IFS= read -r hidden 2>/dev/null < "$PWD/.env"; then
      printf '%s\n' 'sensitive path was readable' >&2
      exit 72
    fi
    if : 2>/dev/null >>"$0"; then
      printf '%s\n' 'launch artifact was writable' >&2
      exit 73
    fi
    if [ "$mode" = helper-network-allowed ] ||
       [ "$mode" = exact-helper ] ||
       [ "$mode" = unlisted-helper ]; then
      if ! /usr/bin/true 2>/dev/null; then
        printf '%s\n' 'listed helper was not executable' >&2
        exit 75
      fi
    else
      # macOS intentionally denies process-fork. Probe the independent
      # process-exec boundary without asking Bash to fork and retry EPERM.
      # A forbidden direct exec must return to this fixture; an unexpected
      # allow replaces the fixture and therefore cannot complete MCP startup.
      exec /usr/bin/true
    fi
    if [ "$mode" = unlisted-helper ]; then
      /usr/bin/false
      printf '%s\n' 'unlisted helper exec returned to server' >&2
      exit 79
    fi

    base64_ascii() {
      local input="$1"
      local table='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
      local output=''
      local first second third first_value second_value third_value
      local first_index second_index third_index fourth_index padding
      while [ -n "$input" ]; do
        first="${input:0:1}"
        input="${input:1}"
        printf -v first_value '%d' "'$first"
        second_value=0
        third_value=0
        padding=2
        if [ -n "$input" ]; then
          second="${input:0:1}"
          input="${input:1}"
          printf -v second_value '%d' "'$second"
          padding=1
        fi
        if [ -n "$input" ]; then
          third="${input:0:1}"
          input="${input:1}"
          printf -v third_value '%d' "'$third"
          padding=0
        fi
        first_index=$((first_value >> 2))
        second_index=$(((first_value & 3) << 4 | second_value >> 4))
        third_index=$(((second_value & 15) << 2 | third_value >> 6))
        fourth_index=$((third_value & 63))
        output="${output}${table:first_index:1}${table:second_index:1}"
        if [ "$padding" -eq 2 ]; then
          output="${output}=="
        elif [ "$padding" -eq 1 ]; then
          output="${output}${table:third_index:1}="
        else
          output="${output}${table:third_index:1}${table:fourth_index:1}"
        fi
      done
      BASE64_ASCII_RESULT="$output"
    }

    case "$mode" in
      exact-network-proxy)
        proxy="${HTTPS_PROXY#http://}"
        proxy_credentials="${proxy%@*}"
        proxy_endpoint="${proxy#*@}"
        proxy_host="${proxy_endpoint%:*}"
        proxy_port="${proxy_endpoint##*:}"
        base64_ascii "$proxy_credentials"
        if ! exec 9<>"/dev/tcp/${proxy_host}/${proxy_port}"; then
          printf '%s\n' 'exact gateway was unreachable' >&2
          exit 80
        fi
        printf 'CONNECT 127.0.0.1:%s HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nProxy-Authorization: Basic %s\r\n\r\n' \
          "$FIXTURE_PORT" "$FIXTURE_PORT" "$BASE64_ASCII_RESULT" >&9
        IFS= read -r proxy_status <&9
        exec 9<&-
        exec 9>&-
        case "$proxy_status" in
          'HTTP/1.1 200 '*) ;;
          *)
            printf '%s\n' 'exact gateway rejected valid credential' >&2
            exit 81
            ;;
        esac
        ;;
      exact-network-direct-bypass)
        : >"/dev/tcp/127.0.0.1/${FIXTURE_PORT}" 2>/dev/null || :
        printf '%s\n' 'direct bypass returned without generation retirement' >&2
        exit 82
        ;;
      exact-network-udp-bypass)
        : >"/dev/udp/127.0.0.1/${FIXTURE_PORT}" 2>/dev/null || :
        printf '%s\n' 'UDP bypass returned without generation retirement' >&2
        exit 83
        ;;
      exact-network-alternate-loopback-bypass)
        proxy="${HTTPS_PROXY#http://}"
        proxy_endpoint="${proxy#*@}"
        proxy_port="${proxy_endpoint##*:}"
        : >"/dev/tcp/127.0.0.2/${proxy_port}" 2>/dev/null || :
        printf '%s\n' 'alternate loopback bypass returned without generation retirement' >&2
        exit 84
        ;;
      *)
        if : >"/dev/tcp/127.0.0.1/${FIXTURE_PORT}" 2>/dev/null; then
          if [ "$mode" != helper-network-allowed ]; then
            printf '%s\n' 'network was reachable' >&2
            exit 76
          fi
        elif [ "$mode" = helper-network-allowed ]; then
          printf '%s\n' 'listed network endpoint was unreachable' >&2
          exit 77
        fi
        ;;
    esac
    printf 'token=%s\n' "$FIXTURE_TOKEN" >&2

    if [ "$mode" = stubborn ]; then
      trap '' TERM
    fi
    while IFS= read -r line; do
      case "$mode" in
        oversize)
          i=0
          while [ "$i" -lt 4096 ]; do
            printf x
            i=$((i + 1))
          done
          exit 0
          ;;
        partial-eof)
          printf '%s' '{"jsonrpc":"2.0"'
          exit 0
          ;;
        malformed)
          printf '%s\n' 'not-json'
          exit 0
          ;;
        stderr-flood)
          i=0
          while [ "$i" -lt 200000 ]; do
            printf x >&2
            i=$((i + 1))
          done
          exit 0
          ;;
        queue-overflow)
          printf '%s\n' '{"jsonrpc":"2.0","method":"fixture/one"}'
          printf '%s\n' '{"jsonrpc":"2.0","method":"fixture/two"}'
          printf '%s\n' '{"jsonrpc":"2.0","method":"fixture/three"}'
          while :; do :; done
          ;;
      esac

      case "$line" in
        *'"method":"initialize"'*)
          rest="${line#*\"id\":\"}"
          request_id="\"${rest%%\"*}\""
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"%s","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"fixture","version":"1.0"}}}\n' "$request_id" "$FIXTURE_PROTOCOL"
          ;;
        *'"method":"ping"'*)
          rest="${line#*\"id\":\"}"
          request_id="\"${rest%%\"*}\""
          printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$request_id"
          ;;
        *'"method":"notifications/initialized"'*)
          ;;
      esac
    done
    if [ "$mode" = stubborn ]; then
      while :; do :; done
    fi
    """#
}

#if os(macOS)
private func sendConnectRequest(
    gatewayPort: UInt16,
    targetAuthority: String,
    authorization: String?
) throws -> String {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw MCPManagedPipeError.pipeSetupFailed
    }
    defer { Darwin.close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = gatewayPort.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        throw MCPManagedPipeError.pipeSetupFailed
    }
    var request =
        "CONNECT \(targetAuthority) HTTP/1.1\r\n"
        + "Host: \(targetAuthority)\r\n"
    if let authorization {
        request += "Proxy-Authorization: \(authorization)\r\n"
    }
    request += "\r\n"
    let bytes = Array(request.utf8)
    let written = bytes.withUnsafeBytes {
        Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard written == bytes.count else {
        throw MCPManagedPipeError.pipeSetupFailed
    }
    var response = [UInt8](repeating: 0, count: 4 * 1_024)
    let count = response.withUnsafeMutableBytes {
        Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard count > 0 else {
        throw MCPManagedPipeError.pipeSetupFailed
    }
    return String(decoding: response.prefix(count), as: UTF8.self)
}
#endif

#if os(macOS) || os(Linux)
private final class LocalTCPListener {
    private var descriptor: Int32 = -1
    private(set) var port: UInt16 = 0
    private(set) var hasAcceptedConnection = false

    init() throws {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #elseif canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = Int32(SOCK_STREAM)
        #endif
        let socketDescriptor = socket(AF_INET, streamType, 0)
        guard socketDescriptor >= 0 else {
            throw MCPManagedPipeError.pipeSetupFailed
        }
        var reuse: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0,
              listen(socketDescriptor, 4) == 0 else {
            close(socketDescriptor)
            throw MCPManagedPipeError.pipeSetupFailed
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketDescriptor)
            throw MCPManagedPipeError.pipeSetupFailed
        }
        descriptor = socketDescriptor
        port = UInt16(bigEndian: bound.sin_port)
        let flags = fcntl(socketDescriptor, F_GETFL)
        _ = fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    func acceptedConnection() -> Bool {
        let accepted = accept(descriptor, nil, nil)
        if accepted >= 0 {
            close(accepted)
            hasAcceptedConnection = true
            return true
        }
        return hasAcceptedConnection
    }

    func stop() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit {
        stop()
    }
}
#endif

private extension Data {
    func replacingUTF8(
        _ target: String,
        with replacement: String
    ) -> Data {
        Data(
            String(decoding: self, as: UTF8.self)
                .replacingOccurrences(
                    of: target,
                    with: replacement).utf8)
    }

    func appendAtomically(to url: URL) throws {
        let existing = try Data(contentsOf: url)
        var combined = existing
        combined.append(self)
        try combined.write(to: url, options: .atomic)
    }
}

private struct StdioFixtureExecutionError: LocalizedError {
    let mode: String
    let underlying: Error
    let diagnostics: MCPStdioDiagnosticsSnapshot

    var errorDescription: String? {
        "stdio fixture \(mode) failed: \(underlying.localizedDescription); diagnostics=\(diagnostics)"
    }
}
