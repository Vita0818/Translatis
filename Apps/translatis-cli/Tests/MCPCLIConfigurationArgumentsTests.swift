import Foundation
import IntatisMCP
import IntatisProtocol
import XCTest
@testable import TranslatisCLI

final class MCPCLIConfigurationArgumentsTests:
    XCTestCase
{
    func testCompleteHTTPOAuthPinConfigurationRoundTrips()
        async throws
    {
        let context = testContext()
        let pin = String(repeating: "a", count: 64)
        let args = try parsed([
            "--alias", "remote",
            "--name", "Remote MCP",
            "--url",
            "https://api.example.com/mcp",
            "--header", "X-Client=translatis",
            "--oauth-resource",
            "https://api.example.com/audience",
            "--oauth-client-id", "client-public",
            "--oauth-scope", "mcp.read",
            "--oauth-scope", "mcp.write",
            "--redirect-policy", "deny",
            "--tool-approval",
            "delete_issue=prompt",
            "--tool-approval",
            "write_issue=writes",
            "--proxy-policy",
            "system-configured",
            "--tls-spki-pin", pin,
            "--profile", "standard-extended",
            "--maximum-protocol-version",
            "2025-11-25",
            "--required-capability", "tools",
            "--required-capability", "tasks",
            "--required", "--parallel",
            "--startup-timeout-ms", "12000",
            "--call-timeout-ms", "34000",
            "--shutdown-timeout-ms", "6000",
            "--allow-tool", "read_issue",
            "--deny-tool", "delete_issue",
            "--allow-resource", "issue",
            "--deny-resource", "private_issue",
            "--allow-prompt", "triage",
            "--deny-prompt", "admin",
            "--allow-completion", "labels",
            "--deny-completion", "secrets",
        ])
        let built =
            try await buildMCPCLIConfiguration(
                context: context,
                arguments: args,
                existing: nil,
                serverID:
                    MCPServerID(
                        rawValue: "remote"),
                displayName: "Remote MCP",
                sourceLabel: "cli-test")
        let configuration =
            built.configuration

        XCTAssertTrue(configuration.required)
        XCTAssertTrue(
            configuration.parallelCalls)
        XCTAssertEqual(
            configuration.requiredCapabilities,
            [.tasks, .tools])
        XCTAssertEqual(
            configuration.timeouts,
            try MCPServerTimeouts(
                startupMilliseconds: 12_000,
                callMilliseconds: 34_000,
                shutdownMilliseconds: 6_000))
        XCTAssertEqual(
            configuration.filters.tools,
            MCPNameFilter(
                allowList: ["read_issue"],
                denyList: ["delete_issue"]))
        XCTAssertEqual(
            configuration.filters.resources,
            MCPNameFilter(
                allowList: ["issue"],
                denyList: ["private_issue"]))
        XCTAssertEqual(
            configuration.filters.prompts,
            MCPNameFilter(
                allowList: ["triage"],
                denyList: ["admin"]))
        XCTAssertEqual(
            configuration.filters.completions,
            MCPNameFilter(
                allowList: ["labels"],
                denyList: ["secrets"]))
        XCTAssertEqual(
            configuration.approvalPolicy
                .toolOverrides,
            [
                "delete_issue": .prompt,
                "write_issue": .writes,
            ])

        guard case .streamableHTTP(let http) =
                configuration.transport else {
            return XCTFail(
                "Expected HTTP transport")
        }
        XCTAssertEqual(
            http.endpoint,
            "https://api.example.com/mcp")
        XCTAssertEqual(
            http.headers["X-Client"],
            .literal("translatis"))
        XCTAssertEqual(
            http.redirectPolicy,
            .deny)
        XCTAssertEqual(
            http.proxyPolicy,
            .systemConfigured)
        XCTAssertEqual(
            http.tlsPolicy,
            .pinnedPublicKeySHA256([pin]))
        XCTAssertEqual(
            http.oauth?.canonicalResource,
            "https://api.example.com/audience")
        XCTAssertEqual(
            http.oauth?.clientID,
            "client-public")
        XCTAssertEqual(
            http.oauth?.scopes,
            ["mcp.read", "mcp.write"])

        let encoded =
            try JSONEncoder().encode(
                configuration)
        let decoded =
            try JSONDecoder().decode(
                MCPServerConfiguration.self,
                from: encoded)
        XCTAssertEqual(decoded, configuration)
    }

    func testStdioExactOriginsAndHelpersAreSeparateAndRoundTrip()
        async throws
    {
        let executable =
            try XCTUnwrap(
                firstExistingPath([
                    "/usr/bin/env",
                    "/bin/echo",
                ]))
        let helper =
            try XCTUnwrap(
                firstExistingPath([
                    "/usr/bin/true",
                    "/bin/true",
                ]))
        let context = testContext()
        let args = try parsed([
            "--alias", "local",
            "--command", executable,
            "--arg", "node",
            "--cwd", "/tmp",
            "--env", "MODE=development",
            "--helper", helper,
            "--network-origin",
            "https://registry.example.com",
            "--network-origin",
            "https://api.example.com:443",
            "--serial",
        ])
        let built =
            try await buildMCPCLIConfiguration(
                context: context,
                arguments: args,
                existing: nil,
                serverID:
                    MCPServerID(
                        rawValue: "local"),
                displayName: "Local MCP",
                sourceLabel: "cli-test")
        guard case .stdio(let stdio) =
                built.configuration.transport else {
            return XCTFail(
                "Expected stdio transport")
        }

        XCTAssertFalse(
            stdio.launchArtifact.files.contains {
                $0.role == .helper
            })
        XCTAssertEqual(
            stdio.helperArtifacts.count,
            1)
        XCTAssertEqual(
            stdio.helperArtifacts
                .flatMap(\.files)
                .map(\.role),
            [.helper])
        XCTAssertEqual(
            stdio.environment["MODE"],
            .literal("development"))
        XCTAssertEqual(
            stdio.networkPolicy,
            .exactOrigins([
                "https://api.example.com",
                "https://registry.example.com",
            ]))

        let data = try JSONEncoder().encode(
            built.configuration)
        XCTAssertEqual(
            try JSONDecoder().decode(
                MCPServerConfiguration.self,
                from: data),
            built.configuration)
    }

    func testSecureHeaderEnvironmentOAuthAndBearerInputsBecomeEncryptedReferences()
        async throws
    {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-config-secrets-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }
        let context = MCPCLIContext(
            root: root)
        let secretStore =
            await context.secretStore
        try await secretStore
            .initialize(
                passphrase:
                    Data(
                        "test-only-passphrase-value"
                            .utf8))
        let reader:
            MCPCLIConfigurationSecretReader = {
                prompt,
                readsStandardInput in
                if readsStandardInput {
                    return Data(
                        "bearer-from-stdin".utf8)
                }
                if prompt.contains(
                    "OAuth") {
                    return Data(
                        "oauth-client-secret".utf8)
                }
                if prompt.contains(
                    "HTTP header") {
                    return Data(
                        "header-secret".utf8)
                }
                if prompt.contains(
                    "environment variable") {
                    return Data(
                        "environment-secret".utf8)
                }
                return Data(
                    "replacement-bearer".utf8)
            }
        let remote =
            try await buildMCPCLIConfiguration(
                context: context,
                arguments:
                    try parsed([
                        "--alias", "remote",
                        "--url",
                        "https://api.example.com/mcp",
                        "--bearer-stdin",
                        "--secret-header",
                        "Authorization",
                        "--oauth-resource",
                        "https://api.example.com/audience",
                        "--oauth-client-secret",
                    ]),
                existing: nil,
                serverID:
                    MCPServerID(
                        rawValue: "remote"),
                displayName: "Remote",
                sourceLabel: "cli-test",
                secretReader: reader)
                .configuration
        guard case .streamableHTTP(let http) =
                remote.transport,
              let bearer =
                http.bearerTokenReference,
              case .secret(let header) =
                http.headers[
                    "Authorization"],
              let oauthSecret =
                http.oauth?
                    .clientSecretReference else {
            return XCTFail(
                "Expected secret references")
        }
        let resolvedBearer =
            try await secretStore
                .resolve(bearer)
        let resolvedHeader =
            try await secretStore
                .resolve(header)
        let resolvedOAuth =
            try await secretStore
                .resolve(oauthSecret)
        XCTAssertEqual(
            resolvedBearer,
            Data("bearer-from-stdin".utf8))
        XCTAssertEqual(
            resolvedHeader,
            Data("header-secret".utf8))
        XCTAssertEqual(
            resolvedOAuth,
            Data("oauth-client-secret".utf8))

        let local =
            try await buildMCPCLIConfiguration(
                context: context,
                arguments:
                    try parsed([
                        "--alias", "local",
                        "--command",
                        try XCTUnwrap(
                            firstExistingPath([
                                "/usr/bin/env",
                                "/bin/echo",
                            ])),
                        "--secret-env",
                        "API_TOKEN",
                    ]),
                existing: nil,
                serverID:
                    MCPServerID(
                        rawValue: "local"),
                displayName: "Local",
                sourceLabel: "cli-test",
                secretReader: reader)
                .configuration
        guard case .stdio(let stdio) =
                local.transport,
              case .secret(let environment) =
                stdio.environment[
                    "API_TOKEN"] else {
            return XCTFail(
                "Expected an environment secret reference")
        }
        let resolvedEnvironment =
            try await secretStore
                .resolve(environment)
        XCTAssertEqual(
            resolvedEnvironment,
            Data("environment-secret".utf8))

        let encoded =
            String(
                decoding:
                    try JSONEncoder().encode([
                        remote, local,
                    ]),
                as: UTF8.self)
        for plaintext in [
            "bearer-from-stdin",
            "header-secret",
            "oauth-client-secret",
            "environment-secret",
        ] {
            XCTAssertFalse(
                encoded.contains(plaintext))
        }

        let replaced =
            try await buildMCPCLIConfiguration(
                context: context,
                arguments:
                    try parsed([
                        "--server", "remote",
                        "--bearer-secret",
                    ]),
                existing: remote,
                serverID:
                    remote.serverID,
                displayName:
                    remote.displayName,
                sourceLabel: "cli-edit",
                secretReader: reader)
                .configuration
        guard case .streamableHTTP(
                let replacementHTTP) =
                replaced.transport,
              let replacement =
                replacementHTTP
                    .bearerTokenReference else {
            return XCTFail(
                "Expected replacement bearer reference")
        }
        XCTAssertNotEqual(replacement, bearer)
        let resolvedReplacement =
            try await secretStore
                .resolve(replacement)
        let retainedOldBearer =
            try await secretStore
                .resolve(bearer)
        XCTAssertEqual(
            resolvedReplacement,
            Data("replacement-bearer".utf8))
        XCTAssertEqual(
            retainedOldBearer,
            Data("bearer-from-stdin".utf8),
            "immutable older revisions must retain their referenced credential")
    }

    func testEditEndpointPreservesCredentialsHeadersOAuthPinsAndPolicy()
        async throws
    {
        let bearer =
            try secretReference("bearer")
        let clientSecret =
            try secretReference(
                "oauth-client")
        let headerSecret =
            try secretReference(
                "header-secret")
        let pin = String(
            repeating: "b",
            count: 64)
        let old =
            try MCPServerConfiguration(
                serverID:
                    MCPServerID(
                        rawValue: "remote"),
                displayName: "Remote",
                required: true,
                requiredCapabilities:
                    [.tools],
                protocolProfile:
                    .standardExtended,
                maximumProtocolVersion:
                    .v2025_11_25,
                approvalPolicy:
                    MCPApprovalPolicy(
                        serverDefault:
                            .writes,
                        toolOverrides: [
                            "delete": .prompt,
                        ]),
                parallelCalls: true,
                timeouts:
                    MCPServerTimeouts(
                        startupMilliseconds:
                            15_000,
                        callMilliseconds:
                            45_000,
                        shutdownMilliseconds:
                            7_000),
                filters:
                    MCPServerFilters(
                        tools:
                            MCPNameFilter(
                                allowList:
                                    ["read"],
                                denyList:
                                    ["delete"])),
                transport:
                    .streamableHTTP(
                        try MCPHTTPServerConfiguration(
                            endpoint:
                                "https://api.example.com/old",
                            headers: [
                                "X-Public":
                                    .literal("client"),
                                "X-Private":
                                    .secret(
                                        headerSecret),
                            ],
                            bearerTokenReference:
                                bearer,
                            oauth:
                                MCPOAuthConfiguration(
                                    enabled: true,
                                    canonicalResource:
                                        "https://api.example.com/audience",
                                    clientID:
                                        "client",
                                    clientSecretReference:
                                        clientSecret,
                                    scopes: [
                                        "mcp.read",
                                    ]),
                            redirectPolicy:
                                .deny,
                            proxyPolicy:
                                .systemConfigured,
                            tlsPolicy:
                                .pinnedPublicKeySHA256(
                                    [pin]))),
                environmentReference:
                    MCPEnvironmentReference(
                        rawValue:
                            "mcpenv_preserve"),
                provenance:
                    MCPConfigurationProvenance(
                        sourceKind:
                            .intatisUser,
                        sourceLabel:
                            "original"))
        let args = try parsed([
            "--server", "remote",
            "--url",
            "https://api.example.com/new",
        ])
        let edited =
            try await buildMCPCLIConfiguration(
                context: testContext(),
                arguments: args,
                existing: old,
                serverID: old.serverID,
                displayName:
                    old.displayName,
                sourceLabel: "cli-edit")
                .configuration

        guard case .streamableHTTP(let http) =
                edited.transport else {
            return XCTFail(
                "Expected HTTP transport")
        }
        XCTAssertEqual(
            http.endpoint,
            "https://api.example.com/new")
        XCTAssertEqual(http.headers,
            try XCTUnwrap({
                if case .streamableHTTP(
                    let value) = old.transport {
                    return value.headers
                }
                return nil
            }()))
        XCTAssertEqual(
            http.bearerTokenReference,
            bearer)
        XCTAssertEqual(
            http.oauth?
                .clientSecretReference,
            clientSecret)
        XCTAssertEqual(
            http.oauth?.scopes,
            ["mcp.read"])
        XCTAssertEqual(
            http.tlsPolicy,
            .pinnedPublicKeySHA256([pin]))
        XCTAssertEqual(
            edited.requiredCapabilities,
            old.requiredCapabilities)
        XCTAssertEqual(
            edited.approvalPolicy,
            old.approvalPolicy)
        XCTAssertEqual(
            edited.parallelCalls,
            old.parallelCalls)
        XCTAssertEqual(
            edited.timeouts,
            old.timeouts)
        XCTAssertEqual(
            edited.filters,
            old.filters)
        XCTAssertEqual(
            edited.environmentReference,
            old.environmentReference)

        let cleared =
            try await buildMCPCLIConfiguration(
                context: testContext(),
                arguments:
                    try parsed([
                        "--server", "remote",
                        "--clear-bearer",
                        "--disable-oauth",
                        "--system-trust",
                        "--clear-tool-approvals",
                    ]),
                existing: old,
                serverID: old.serverID,
                displayName:
                    old.displayName,
                sourceLabel: "cli-edit")
                .configuration
        guard case .streamableHTTP(
                let clearedHTTP) =
                cleared.transport else {
            return XCTFail(
                "Expected HTTP transport")
        }
        XCTAssertNil(
            clearedHTTP
                .bearerTokenReference)
        XCTAssertNil(clearedHTTP.oauth)
        XCTAssertEqual(
            clearedHTTP.tlsPolicy,
            .systemTrust)
        XCTAssertTrue(
            cleared.approvalPolicy
                .toolOverrides.isEmpty)

        let removedOverride =
            try await buildMCPCLIConfiguration(
                context: testContext(),
                arguments:
                    try parsed([
                        "--server", "remote",
                        "--remove-tool-approval",
                        "delete",
                    ]),
                existing: old,
                serverID: old.serverID,
                displayName:
                    old.displayName,
                sourceLabel: "cli-edit")
                .configuration
        XCTAssertTrue(
            removedOverride.approvalPolicy
                .toolOverrides.isEmpty)
    }

    func testAttachmentApprovalUpdatePreservesUnspecifiedAndSupportsSerial()
        throws
    {
        let revision = MCPPolicyRevision(
            rawValue: "mcppolicy_old")
        let old = MCPAttachmentPolicy(
            revision: revision,
            required: true,
            approvalMode: .writes,
            parallelCalls: true,
            filter: MCPCatalogFilter(
                revision: revision,
                tools:
                    MCPNameFilter(
                        allowList: ["read"],
                        denyList: ["delete"])))

        let preserved =
            try updatedMCPCLIAttachmentPolicy(
                parsed([
                    "set", "--session", "s",
                    "--server", "remote",
                    "--optional",
                ]),
                existing: old)
        XCTAssertFalse(preserved.required)
        XCTAssertEqual(
            preserved.approvalMode,
            .writes)
        XCTAssertTrue(
            preserved.parallelCalls)
        XCTAssertEqual(
            preserved.filter.tools,
            old.filter.tools)

        let serial =
            try updatedMCPCLIAttachmentPolicy(
                parsed([
                    "set", "--session", "s",
                    "--server", "remote",
                    "--serial",
                    "--approval", "approve",
                ]),
                existing: old)
        XCTAssertFalse(
            serial.parallelCalls)
        XCTAssertEqual(
            serial.approvalMode,
            .approve)

        XCTAssertThrowsError(
            try updatedMCPCLIAttachmentPolicy(
                parsed([
                    "set", "--session", "s",
                    "--server", "remote",
                    "--parallel", "--serial",
                ]),
                existing: old))
        XCTAssertThrowsError(
            try updatedMCPCLIAttachmentPolicy(
                parsed([
                    "set", "--session", "s",
                    "--server", "remote",
                    "--unknown", "value",
                ]),
                existing: old))
    }

    func testSecretLikeArgvUnknownOptionsAndStdinConflictsFailClosed()
        async throws
    {
        let secret = "sk-never-print-this"
        let literalArgs = try parsed([
            "--alias", "remote",
            "--url",
            "https://api.example.com/mcp",
            "--header",
            "X-Value=\(secret)",
        ])
        do {
            _ = try await
                buildMCPCLIConfiguration(
                    context: testContext(),
                    arguments:
                        literalArgs,
                    existing: nil,
                    serverID:
                        MCPServerID(
                            rawValue:
                                "remote"),
                    displayName: "Remote",
                    sourceLabel: "cli-test")
            XCTFail(
                "Secret-like literal must fail")
        } catch {
            XCTAssertFalse(
                error.localizedDescription
                    .contains(secret))
        }

        let plaintextOption =
            "--client-secret=\(secret)"
        XCTAssertThrowsError(
            try parsed([
                "--alias", "remote",
                "--url",
                "https://api.example.com/mcp",
                plaintextOption,
            ])
        ) { error in
            XCTAssertEqual(
                error as? MCPCLIError,
                .plaintextSecretArgument(
                    "client-secret"))
            XCTAssertFalse(
                error.localizedDescription
                    .contains(secret))
        }

        let unknown = try parsed([
            "--alias", "remote",
            "--url",
            "https://api.example.com/mcp",
            "--unknown-field", "value",
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await
                buildMCPCLIConfiguration(
                    context: self.testContext(),
                    arguments: unknown,
                    existing: nil,
                    serverID:
                        MCPServerID(
                            rawValue:
                                "remote"),
                    displayName: "Remote",
                    sourceLabel: "cli-test")
        }

        let duplicateToolApproval =
            try parsed([
                "--alias", "remote",
                "--url",
                "https://api.example.com/mcp",
                "--tool-approval",
                "read=auto",
                "--tool-approval",
                "read=prompt",
            ])
        await XCTAssertThrowsErrorAsync {
            _ = try await
                buildMCPCLIConfiguration(
                    context: self.testContext(),
                    arguments:
                        duplicateToolApproval,
                    existing: nil,
                    serverID:
                        MCPServerID(
                            rawValue:
                                "remote"),
                    displayName: "Remote",
                    sourceLabel: "cli-test")
        }

        let conflictingStdin =
            try parsed([
                "--alias", "remote",
                "--url",
                "https://api.example.com/mcp",
                "--bearer-stdin",
                "--oauth-resource",
                "https://api.example.com/audience",
                "--oauth-client-secret-stdin",
            ])
        await XCTAssertThrowsErrorAsync {
            _ = try await
                buildMCPCLIConfiguration(
                    context: self.testContext(),
                    arguments:
                        conflictingStdin,
                    existing: nil,
                    serverID:
                        MCPServerID(
                            rawValue:
                                "remote"),
                    displayName: "Remote",
                    sourceLabel: "cli-test")
        }
    }

    private func testContext()
        -> MCPCLIContext {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-config-\(UUID().uuidString)",
                isDirectory: true)
        return MCPCLIContext(root: root)
    }

    private func parsed(
        _ values: [String]
    ) throws -> MCPCLIParsedArguments {
        try MCPCLIParsedArguments(
            values[...])
    }

    private func secretReference(
        _ identifier: String
    ) throws -> MCPSecretReference {
        try MCPSecretReference(
            storageClass: .hostOwned,
            identifier:
                "test-\(identifier)")
    }

    private func firstExistingPath(
        _ values: [String]
    ) -> String? {
        values.first {
            FileManager.default
                .isExecutableFile(
                    atPath: $0)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ operation:
        () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail(
            "Expected operation to throw",
            file: file,
            line: line)
    } catch {
        // Expected.
    }
}
