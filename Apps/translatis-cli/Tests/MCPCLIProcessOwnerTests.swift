import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCodexRuntime
import IntatisCore
import IntatisMCP
import IntatisProtocol
import XCTest
@testable import TranslatisCLI

final class MCPCLIProcessOwnerTests:
    XCTestCase
{
    func testNativeCodexGrantEntryPersistsOnlyRootCompleteNonExpiringAuthority()
        async throws
    {
        let fixture: MCPCLILoopbackFixture
        do {
            fixture = try MCPCLILoopbackFixture()
        } catch MCPCLILoopbackFixtureError
                    .loopbackBindPermissionDenied {
            throw XCTSkip(
                "This test runner forbids binding a real 127.0.0.1 listener.")
        }
        defer { fixture.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-native-grant-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let context = MCPCLIContext(
            root: root.appendingPathComponent(
                "mcp-config",
                isDirectory: true))
        let sessionID = SessionID(
            rawValue: "cli_native_grant")
        let interactive = try await makeMCPCLIInteractiveCodeSession(
            context: context,
            workspace: workspace,
            sessionID: sessionID,
            agentID: AgentID(rawValue: "Coder"))
        try await context.bindInteractiveSessionLog(
            interactive.log,
            nativeCodexRootAgentID: interactive.agentID)

        do {
            try await runMCPCommand([
                "add",
                "--alias", "native",
                "--url", fixture.endpoint,
                "--profile", "codex-compat",
                "--allow-insecure-loopback-development-http",
                "--yes",
            ][...], context: context)
            try await runMCPCommand([
                "attach",
                "--session", sessionID.rawValue,
                "--server", "native",
                "--agent", interactive.agentID.rawValue,
            ][...], context: context)

            do {
                try await runMCPCommand([
                    "grant",
                    "--session", sessionID.rawValue,
                    "--server", "native",
                    "--agent", interactive.agentID.rawValue,
                    "--capabilities", "tools",
                ][...], context: context)
                XCTFail("A partial native Codex grant must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(
                    "partial capability grant"))
            }
            do {
                try await runMCPCommand([
                    "grant",
                    "--session", sessionID.rawValue,
                    "--server", "native",
                    "--agent", "child",
                ][...], context: context)
                XCTFail("A child native Codex grant must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(
                    "session-root Agent"))
            }
            do {
                try await runMCPCommand([
                    "status",
                    "--session", sessionID.rawValue,
                    "--agent", "child",
                ][...], context: context)
                XCTFail("A child native Codex live action must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(
                    "session-root Agent"))
            }
            do {
                try await runMCPCommand([
                    "grant",
                    "--session", sessionID.rawValue,
                    "--server", "native",
                    "--agent", interactive.agentID.rawValue,
                    "--ttl-seconds", "60",
                ][...], context: context)
                XCTFail("An expiring native Codex grant must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(
                    "cannot use --ttl-seconds"))
            }

            try await runMCPCommand([
                "grant",
                "--session", sessionID.rawValue,
                "--server", "native",
                "--agent", interactive.agentID.rawValue,
            ][...], context: context)
            let state = try await MCPDurableSessionState.load(
                from: interactive.log)
            let grant = try XCTUnwrap(state.grants.values.first)
            XCTAssertEqual(state.grants.count, 1)
            XCTAssertEqual(
                Set(grant.capabilities),
                CodexRuntimeMCPProjector
                    .requiredNativeSurfaceCapabilities)
            XCTAssertEqual(grant.agentID, interactive.agentID)
            XCTAssertNil(grant.taskID)
            XCTAssertNil(grant.expiresAt)
        } catch {
            await interactive.shutdown(
                reason: "native Codex grant entry test failed")
            throw error
        }
        await interactive.shutdown(
            reason: "native Codex grant entry test completed")
    }

    func testShippingCodeHostWithoutAttachmentIsCompletelyInert()
        async throws
    {
        let fixture = try Self.makeHostFixture(
            name: "no-attachment")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root)
        }
        let host = MCPCLIInteractiveCodeHost(
            log: fixture.log,
            workspace: fixture.workspace)

        let activation =
            try await host.activationIfAttached()
        let isActivated =
            await host.isActivated()
        let initialEvents =
            try await fixture.log.replayChecked()

        XCTAssertNil(activation)
        XCTAssertFalse(isActivated)
        XCTAssertTrue(
            initialEvents.isEmpty,
            "shipping CLI Code must not append MCP or lease state when no durable attachment exists")

        await host.shutdown(
            reason:
                "no-attachment shipping host test completed")
        let finalEvents =
            try await fixture.log.replayChecked()
        XCTAssertTrue(
            finalEvents.isEmpty)
    }

    func testFirstExplicitMCPActionPromotesTheExistingShippingCodeLog()
        async throws
    {
        let fixture = try Self.makeHostFixture(
            name: "explicit-activation")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root)
        }
        let context = MCPCLIContext(
            root: fixture.root.appendingPathComponent(
                "mcp-config",
                isDirectory: true))
        let host = MCPCLIInteractiveCodeHost(
            log: fixture.log,
            workspace: fixture.workspace,
            context: context)

        let activation = try await host.activate()
        do {
            let isActivated =
                await host.isActivated()
            XCTAssertTrue(isActivated)
            XCTAssertEqual(
                activation.session.sessionID,
                fixture.sessionID)
            let rebound = try await context.sessionLog(
                fixture.sessionID.rawValue)
            XCTAssertEqual(
                ObjectIdentifier(rebound),
                ObjectIdentifier(fixture.log),
                "interactive /mcp commands must mutate the same EventLog already owned by Code")

            let events =
                try await fixture.log.replayChecked()
            XCTAssertEqual(events.count, 2)
            XCTAssertTrue(events.contains {
                if case .workspaceLeaseGranted =
                    $0.event { return true }
                return false
            })
            XCTAssertTrue(events.contains {
                if case .capabilityLeaseCreated =
                    $0.event { return true }
                return false
            })
        } catch {
            await host.shutdown(
                reason:
                    "explicit activation shipping host test failed")
            throw error
        }

        await host.shutdown(
            reason:
                "explicit activation shipping host test completed")
        let retained =
            await context.retainedRuntime(
                sessionID: fixture.sessionID)
        XCTAssertNil(
            retained)
    }

    func testDurableAttachmentActivatesShippingCodeOwnerBeforeDispatch()
        async throws
    {
        let fixture = try Self.makeHostFixture(
            name: "durable-attachment")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root)
        }
        let revision = MCPPolicyRevision(
            rawValue: "mcppol_cli_host")
        _ = try await fixture.log.append(
            .mcpServerAttached(.init(
                attachment: MCPServerAttachment(
                    server: MCPServerReference(
                        serverID: MCPServerID(
                            rawValue:
                                "shipping-cli-host"),
                        serverRevision:
                            MCPServerRevision(
                                rawValue:
                                    "mcprev_shipping_cli_host")),
                    policy: MCPAttachmentPolicy(
                        revision: revision,
                        filter: MCPCatalogFilter(
                            revision: revision)),
                    source: .user))))
        let context = MCPCLIContext(
            root: fixture.root.appendingPathComponent(
                "mcp-config",
                isDirectory: true))
        let host = MCPCLIInteractiveCodeHost(
            log: fixture.log,
            workspace: fixture.workspace,
            context: context)

        let activation =
            try await host.activationIfAttached()
        let isActivated =
            await host.isActivated()
        let events =
            try await fixture.log.replayChecked()
        XCTAssertNotNil(activation)
        XCTAssertTrue(isActivated)
        XCTAssertEqual(
            events.count,
            3,
            "the pre-existing attachment plus the exact runtime leases must share one log")

        await host.shutdown(
            reason:
                "durable-attachment shipping host test completed")
    }

    func testShippingCoworkHostWithoutAttachmentIsCompletelyInert()
        async throws
    {
        let fixture = try Self.makeHostFixture(
            name: "cowork-no-attachment")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root)
        }
        let contextRoot = fixture.root
            .appendingPathComponent(
                "mcp-config",
                isDirectory: true)
        let context = MCPCLIContext(
            root: contextRoot)
        let host = MCPCLIInteractiveCoworkHost(
            log: fixture.log,
            workspace: fixture.workspace,
            context: context)
        let artifactRoot = Self.artifactRoot(
            contextRoot: contextRoot,
            sessionID: fixture.sessionID)

        let activation =
            try await host.activationIfAttached()
        let isActivated =
            await host.isActivated()
        let retained =
            await context.retainedRuntime(
                sessionID: fixture.sessionID)
        let events =
            try await fixture.log.replayChecked()

        XCTAssertNil(activation)
        XCTAssertFalse(isActivated)
        XCTAssertNil(retained)
        XCTAssertTrue(
            events.isEmpty,
            "shipping CLI Cowork must not append MCP state when no durable attachment exists")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifactRoot.path),
            "an inert Cowork MCP host must not create its ArtifactStore")

        await host.shutdown(
            reason:
                "no-attachment Cowork host test completed")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: artifactRoot.path))
    }

    func testFirstExplicitMCPActionActivatesCoworkWithoutAddingLeaseEvents()
        async throws
    {
        let fixture = try Self.makeHostFixture(
            name: "cowork-explicit-activation")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root)
        }
        let contextRoot = fixture.root
            .appendingPathComponent(
                "mcp-config",
                isDirectory: true)
        let context = MCPCLIContext(
            root: contextRoot)
        let host = MCPCLIInteractiveCoworkHost(
            log: fixture.log,
            workspace: fixture.workspace,
            context: context)

        let activation = try await host.activate()
        do {
            let isActivated =
                await host.isActivated()
            let events =
                try await fixture.log.replayChecked()
            XCTAssertTrue(isActivated)
            XCTAssertEqual(
                activation.owner.runtime.sessionID,
                fixture.sessionID)
            let rebound = try await context.sessionLog(
                fixture.sessionID.rawValue)
            XCTAssertEqual(
                ObjectIdentifier(rebound),
                ObjectIdentifier(fixture.log),
                "interactive Cowork /mcp commands must mutate the Cowork-owned EventLog")
            XCTAssertTrue(
                events.isEmpty,
                "Cowork activation must reuse its existing durable leases instead of appending Code leases")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: Self.artifactRoot(
                        contextRoot: contextRoot,
                        sessionID:
                            fixture.sessionID).path))
        } catch {
            await host.shutdown(
                reason:
                    "explicit Cowork activation test failed")
            throw error
        }

        await host.shutdown(
            reason:
                "explicit Cowork activation test completed")
        let retained =
            await context.retainedRuntime(
                sessionID: fixture.sessionID)
        XCTAssertNil(retained)
    }

    func testDurableAttachmentActivatesShippingCoworkOwnerBeforeDispatch()
        async throws
    {
        let fixture = try Self.makeHostFixture(
            name: "cowork-durable-attachment")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root)
        }
        _ = try await fixture.log.append(
            Self.testAttachmentEvent())
        let context = MCPCLIContext(
            root: fixture.root.appendingPathComponent(
                "mcp-config",
                isDirectory: true))
        let host = MCPCLIInteractiveCoworkHost(
            log: fixture.log,
            workspace: fixture.workspace,
            context: context)

        let activation =
            try await host.activationIfAttached()
        let isActivated =
            await host.isActivated()
        let events =
            try await fixture.log.replayChecked()
        XCTAssertNotNil(activation)
        XCTAssertTrue(isActivated)
        XCTAssertEqual(
            events.count,
            1,
            "Cowork activation must preserve the pre-existing attachment without adding Code leases")

        await host.shutdown(
            reason:
                "durable-attachment Cowork host test completed")
    }

    func testShippingCodeStartupWithoutMCPAddsNoMCPStdout()
        throws
    {
        let executable =
            try Self.shippingCLIExecutable()
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-shipping-stdout-\(UUID().uuidString)",
                isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let configURL = root.appendingPathComponent(
            "translatis.json")
        let codexRuntime = root.appendingPathComponent(
            "translatis-codex")
        let codexScript = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            case "$line" in
              *skills/extraRoots/set*)
                echo '{"id":2,"result":{}}'
                ;;
              *) exit 41 ;;
            esac
          elif [ "$count" = "3" ]; then
            case "$line" in
              *thread/start*)
                echo '{"id":3,"result":{"thread":{"id":"thread-cli-no-mcp","turns":[],"createdAt":0,"updatedAt":0,"status":{"type":"idle"}}}}'
                ;;
              *) exit 42 ;;
            esac
          fi
        done
        """
        try Data(codexScript.utf8).write(to: codexRuntime)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: codexRuntime.path)
        let config: [String: Any] = [
            "model": "test/cli-no-mcp-model",
            "enabled_providers": ["test"],
            "provider": [
                "test": [
                    "name": "CLI no-MCP test",
                    "options": [
                        "baseURL":
                            "https://example.invalid/v1",
                        "apiKey":
                            "{env:TRANSLATIS_API_KEY}",
                    ],
                    "models": [
                        "cli-no-mcp-model": [
                            "name":
                                "CLI no-MCP model",
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys])
            .write(to: configURL, options: .atomic)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = executable
        process.arguments = [
            "code", workspace.path,
        ]
        var environment =
            ProcessInfo.processInfo.environment
        environment["TRANSLATIS_CONFIG"] =
            configURL.path
        environment["TRANSLATIS_API_KEY"] =
            "shipping-cli-test-key"
        environment["TRANSLATIS_MODEL"] =
            "test/cli-no-mcp-model"
        environment["TRANSLATIS_MODE"] = "code"
        environment["TRANSLATIS_USAGE"] = "0"
        environment["TRANSLATIS_CODEX_RUNTIME"] =
            codexRuntime.path
        // Keep the shipping-process smoke's deterministic Codex session home
        // inside this fixture. The fixture defer removes it, so a test run
        // cannot leave empty runtime directories in the user's real
        // Application Support tree.
        environment["CFFIXED_USER_HOME"] = root.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        try input.fileHandleForWriting.write(
            contentsOf: Data("/exit\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = String(
            decoding:
                output.fileHandleForReading
                    .readDataToEndOfFile(),
            as: UTF8.self)
        let stderr = String(
            decoding:
                errorOutput.fileHandleForReading
                    .readDataToEndOfFile(),
            as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(stdout.contains("Translatis"))
        XCTAssertTrue(stdout.contains("cli-no-mcp-model"))
        XCTAssertTrue(stdout.contains("code"))
        XCTAssertFalse(stdout.contains("Code session "))
        XCTAssertFalse(stdout.contains("owns its MCP runtime"))
        XCTAssertFalse(stdout.contains("prior MCP attachments"))
        XCTAssertEqual(stderr, "")
    }

    func testRealLoopbackConnectStatusRefreshDisconnectUsesOneRetainedOwner()
        async throws
    {
        let fixture: MCPCLILoopbackFixture
        do {
            fixture = try MCPCLILoopbackFixture()
        } catch MCPCLILoopbackFixtureError
                    .loopbackBindPermissionDenied {
            throw XCTSkip(
                "This test runner forbids binding a real 127.0.0.1 listener.")
        }
        defer { fixture.stop() }

        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-mcp-owner-\(UUID().uuidString)",
                isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let context = MCPCLIContext(root: root)
        let sessionID = SessionID(
            rawValue: "cli_owner_e2e")
        let interactive =
            try await makeMCPCLIInteractiveCodeSession(
                context: context,
                workspace: workspace,
                sessionID: sessionID)
        var stage = "add"

        do {
            try await runMCPCommand([
                "add",
                "--alias", "loopback",
                "--url", fixture.endpoint,
                "--allow-insecure-loopback-development-http",
                "--yes",
            ][...], context: context)
            stage = "attach"
            try await runMCPCommand([
                "attach",
                "--session", sessionID.rawValue,
                "--server", "loopback",
                "--agent",
                interactive.agentID.rawValue,
            ][...], context: context)
            stage = "grant"
            try await runMCPCommand([
                "grant",
                "--session", sessionID.rawValue,
                "--server", "loopback",
                "--agent",
                interactive.agentID.rawValue,
                "--capabilities", "tools",
            ][...], context: context)

            stage = "connect"
            try await runMCPCommand([
                "connect",
                "--session", sessionID.rawValue,
                "--agent",
                interactive.agentID.rawValue,
                "--server", "loopback",
                "--yes",
            ][...], context: context)
            stage = "connected-status"
            try await runMCPCommand([
                "status",
                "--session", sessionID.rawValue,
                "--agent",
                interactive.agentID.rawValue,
                "--json",
            ][...], context: context)

            let connected =
                await interactive.owner.runtime
                    .liveConnectionSnapshots()
            XCTAssertEqual(connected.count, 1)
            let firstGeneration = try XCTUnwrap(
                connected.first?.bindingIdentity
                    .connectionGeneration)
            let firstCatalog = try XCTUnwrap(
                connected.first?.bindingIdentity
                    .rawCatalogRevision)

            try await runMCPCommand([
                "refresh",
                "--session", sessionID.rawValue,
                "--agent",
                interactive.agentID.rawValue,
                "--server", "loopback",
            ][...], context: context)
            try await runMCPCommand([
                "status",
                "--session", sessionID.rawValue,
                "--agent",
                interactive.agentID.rawValue,
                "--json",
            ][...], context: context)

            let refreshed =
                await interactive.owner.runtime
                    .liveConnectionSnapshots()
            XCTAssertEqual(refreshed.count, 1)
            XCTAssertEqual(
                refreshed.first?.bindingIdentity
                    .connectionGeneration,
                firstGeneration,
                "view-only refresh must retain the exact live connection generation")
            XCTAssertNotEqual(
                refreshed.first?.bindingIdentity
                    .rawCatalogRevision,
                firstCatalog,
                "refresh must atomically publish a new complete raw catalog")

            stage = "disconnect"
            try await runMCPCommand([
                "disconnect",
                "--session", sessionID.rawValue,
                "--agent",
                interactive.agentID.rawValue,
                "--server", "loopback",
            ][...], context: context)
            try await runMCPCommand([
                "status",
                "--session", sessionID.rawValue,
                "--agent",
                interactive.agentID.rawValue,
                "--json",
            ][...], context: context)
            let disconnected =
                await interactive.owner.runtime
                    .liveConnectionSnapshots()
            XCTAssertTrue(disconnected.isEmpty)

            let methods = try fixture.methods()
            XCTAssertGreaterThanOrEqual(
                methods.filter {
                    $0 == "initialize"
                }.count,
                2,
                "isolated Test and retained Connect must use distinct real generations")
            XCTAssertGreaterThanOrEqual(
                methods.filter {
                    $0 == "tools/list"
                }.count,
                3,
                "Test, Connect, and Refresh must each perform real discovery")
            XCTAssertTrue(methods.contains("DELETE"))
        } catch {
            let methods =
                (try? fixture.methods())
                ?? ["<fixture stats unavailable>"]
            XCTFail(
                "CLI MCP lifecycle failed during \(stage); taskCancelled=\(Task.isCancelled); methods=\(methods); error=\(String(reflecting: error))")
            await interactive.shutdown(
                reason:
                    "CLI MCP owner E2E failed")
            throw error
        }

        await interactive.shutdown(
            reason:
                "CLI MCP owner E2E completed")
        let retainedOwnerCount =
            await MCPCLIProcessRuntimeOwners.shared
                .retainedOwnerCount()
        XCTAssertEqual(
            retainedOwnerCount,
            0)
    }

    func testInteractiveTokenizerAndExactOwnerConfinement()
        throws
    {
        XCTAssertEqual(
            try MCPCLICommandLineTokenizer.tokenize(
                #"attach --server "issue tracker" --required"#),
            [
                "attach", "--server",
                "issue tracker", "--required",
            ])
        XCTAssertThrowsError(
            try MCPCLICommandLineTokenizer.tokenize(
                #"connect --server "unfinished"#))
    }

    func testRequiredStartupFailureMapsToNonzeroCLIExit()
        throws
    {
        let failure = MCPRequiredStartupFailure(
            invocationID:
                MCPInvocationID(
                    rawValue: "mcpinvoke_cli_required"),
            failures: [
                MCPServerStartupFailure(
                    server: MCPServerReference(
                        serverID: MCPServerID(
                            rawValue: "required"),
                        serverRevision:
                            MCPServerRevision(
                                rawValue:
                                    "mcprev_required")),
                    attachmentID:
                        MCPAttachmentID(
                            rawValue:
                                "mcpattach_required"),
                    required: true,
                    code: "startup_failed",
                    diagnostic:
                        MCPDiagnosticSummary(
                            code: "startup_failed",
                            summary:
                                "Required server startup failed.")),
            ])

        XCTAssertEqual(
            mcpCLIExitCode(for: failure),
            failure.cliExitCode)
        XCTAssertEqual(failure.cliExitCode, 1)
        XCTAssertTrue(
            failure.providerDispatchMustRemainZero)
    }

    private struct HostFixture {
        let root: URL
        let workspace: URL
        let sessionID: SessionID
        let log: EventLog
    }

    private static func makeHostFixture(
        name: String
    ) throws -> HostFixture {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-host-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let sessionID = SessionID(
            rawValue:
                "cli_host_\(name.replacingOccurrences(of: "-", with: "_"))")
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent(
                "events.jsonl"))
        return HostFixture(
            root: root,
            workspace: workspace,
            sessionID: sessionID,
            log: log)
    }

    private static func artifactRoot(
        contextRoot: URL,
        sessionID: SessionID
    ) -> URL {
        contextRoot
            .appendingPathComponent(
                "sessions",
                isDirectory: true)
            .appendingPathComponent(
                sessionID.rawValue,
                isDirectory: true)
            .appendingPathComponent(
                "artifacts",
                isDirectory: true)
    }

    private static func testAttachmentEvent()
        -> Event
    {
        let revision = MCPPolicyRevision(
            rawValue:
                "mcppol_cli_cowork_host")
        return .mcpServerAttached(.init(
            attachment: MCPServerAttachment(
                server: MCPServerReference(
                    serverID: MCPServerID(
                        rawValue:
                            "shipping-cli-cowork-host"),
                    serverRevision:
                        MCPServerRevision(
                            rawValue:
                                "mcprev_shipping_cli_cowork_host")),
                policy: MCPAttachmentPolicy(
                    revision: revision,
                    filter: MCPCatalogFilter(
                        revision: revision)),
                source: .user)))
    }

    private static func shippingCLIExecutable()
        throws -> URL
    {
        let seeds = [
            URL(
                fileURLWithPath:
                    CommandLine.arguments[0])
                .deletingLastPathComponent(),
            Bundle.main.bundleURL,
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent(),
        ]
        for seed in seeds {
            var directory = seed
            for _ in 0..<10 {
                let candidates = [
                    directory.appendingPathComponent(
                        "translatis"),
                    directory
                        .appendingPathComponent(
                            ".build",
                            isDirectory: true)
                        .appendingPathComponent(
                            "debug",
                            isDirectory: true)
                        .appendingPathComponent(
                            "translatis"),
                ]
                if let candidate =
                        candidates.first(where: {
                            FileManager.default
                                .isExecutableFile(
                                    atPath: $0.path)
                        }) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }
        throw XCTSkip(
            "The built shipping translatis executable is unavailable.")
    }
}

private enum MCPCLILoopbackFixtureError:
    Error, LocalizedError
{
    case loopbackBindPermissionDenied
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case .loopbackBindPermissionDenied:
            return "The test runner denied a real loopback listener."
        case .processExited(let diagnostic):
            return "The real MCP loopback fixture exited before publishing its port: \(diagnostic)"
        }
    }
}

private final class MCPCLILoopbackFixture {
    let endpoint: String
    private let process: Process
    private let output: Pipe
    private let errorOutput: Pipe
    private let statsURL: URL

    init() throws {
        statsURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-mcp-stats-\(UUID().uuidString).log")
        guard let script = Bundle.module.url(
            forResource:
                "mcp-cli-lifecycle-server",
            withExtension: "mjs",
            subdirectory: "Fixtures")
        else {
            throw IntatisError.io(
                "The bundled MCP loopback fixture is unavailable.")
        }
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL =
            URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path, statsURL.path,
        ]
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        self.process = process
        self.output = output
        self.errorOutput = errorOutput

        var line = Data()
        while true {
            guard let byte = try output.fileHandleForReading
                .read(upToCount: 1),
                !byte.isEmpty else {
                process.waitUntilExit()
                let errorData = try errorOutput
                    .fileHandleForReading
                    .readToEnd() ?? Data()
                let diagnostic = String(
                    decoding: errorData,
                    as: UTF8.self)
                if diagnostic.contains(
                    "listen EPERM: operation not permitted 127.0.0.1") {
                    throw MCPCLILoopbackFixtureError
                        .loopbackBindPermissionDenied
                }
                throw MCPCLILoopbackFixtureError
                    .processExited(
                        diagnostic
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines))
            }
            if byte[0] == 0x0A { break }
            line.append(byte)
            guard line.count <= 16 else {
                throw IntatisError.io(
                    "The MCP loopback fixture returned an invalid port.")
            }
        }
        guard let value = String(
                data: line,
                encoding: .utf8),
              let port = Int(value),
              (1...65_535).contains(port)
        else {
            throw IntatisError.io(
                "The MCP loopback fixture returned an invalid port.")
        }
        endpoint =
            "http://127.0.0.1:\(port)/mcp"
    }

    func methods() throws -> [String] {
        let data = try Data(contentsOf: statsURL)
        return String(
            decoding: data,
            as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}
