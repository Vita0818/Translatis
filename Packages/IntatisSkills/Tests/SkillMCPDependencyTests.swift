import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools
import XCTest
@testable import IntatisSkills

final class SkillMCPDependencyTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
    }

    func testValidMetadataIsFrozenMachineOnlyAndRequiresExactConnectionIdentity()
        async throws
    {
        let workspace = try makeWorkspace("valid")
        let skillDirectory = try makeSkill(
            workspace: workspace,
            folder: "docs",
            name: "docs",
            body: "DEPENDENT_SKILL_BODY",
            metadata: httpMetadata(
                value: "docs-server",
                url: "https://mcp.example.test/v1"),
            resources: [
                "references/guide.md": "FROZEN_RESOURCE_BODY",
            ])

        let snapshot = try await load(workspace)
        let skill = try XCTUnwrap(snapshot.skills.first)
        XCTAssertEqual(
            skill.mcpDependencyMetadataState,
            .valid)
        XCTAssertEqual(
            skill.mcpDependencies.map(\.identifier),
            ["docs-server"])
        XCTAssertFalse(
            skill.resourcePaths.contains(
                "agents/openai.yaml"))
        XCTAssertFalse(
            snapshot.digest.contains(
                "mcp.example.test"))

        let unavailable = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $docs.",
                mcpAvailability: .unavailable))
        XCTAssertTrue(unavailable.contains(
            "skill_mcp_host_unavailable"))
        XCTAssertFalse(unavailable.contains(
            "DEPENDENT_SKILL_BODY"))
        XCTAssertFalse(unavailable.contains(
            "docs-server"))
        XCTAssertFalse(unavailable.contains(
            "mcp.example.test"))

        // A tool name or display-like alias is not a server identity.
        let wrongServer = try httpAvailability(
            serverID: "other-server",
            url: "https://mcp.example.test/v1",
            servers: ["other-server"],
            tools: ["docs-server"])
        let missing = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $docs.",
                mcpAvailability: wrongServer))
        XCTAssertTrue(missing.contains(
            "skill_mcp_dependency_missing"))
        XCTAssertFalse(missing.contains(
            "DEPENDENT_SKILL_BODY"))

        let changedEndpoint = try httpAvailability(
            serverID: "docs-server",
            url: "https://mcp.example.test/v2")
        let locatorMismatch = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $docs.",
                mcpAvailability: changedEndpoint))
        XCTAssertTrue(locatorMismatch.contains(
            "skill_mcp_dependency_missing"))
        XCTAssertFalse(locatorMismatch.contains(
            "DEPENDENT_SKILL_BODY"))

        let exact = try httpAvailability(
            serverID: "docs-server",
            url: "https://mcp.example.test/v1")
        let activated = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $docs.",
                mcpAvailability: exact))
        XCTAssertTrue(activated.contains(
            "DEPENDENT_SKILL_BODY"))
        XCTAssertFalse(activated.contains(
            "mcp.example.test"))

        XCTAssertThrowsError(
            try snapshot.resourcePrompt(
                skillID: skill.id,
                path: "agents/openai.yaml",
                mcpAvailability: exact))

        // Mutating the live package cannot alter the frozen snapshot.
        try Data("MUTATED_METADATA".utf8).write(
            to: skillDirectory
                .appendingPathComponent(
                    "agents/openai.yaml"),
            options: .atomic)
        let stillFrozen = try snapshot.activationPrompt(
            skillID: skill.id,
            mcpAvailability: exact)
        XCTAssertTrue(stillFrozen.contains(
            "DEPENDENT_SKILL_BODY"))
        XCTAssertFalse(stillFrozen.contains(
            "MUTATED_METADATA"))
    }

    func testOnlySelectedSkillsRunDependencyPreflight()
        async throws
    {
        let workspace = try makeWorkspace("selected-only")
        _ = try makeSkill(
            workspace: workspace,
            folder: "plain",
            name: "plain",
            body: "PLAIN_BODY")
        _ = try makeSkill(
            workspace: workspace,
            folder: "dependent",
            name: "dependent",
            body: "DEPENDENT_BODY",
            metadata: httpMetadata(
                value: "selected-server",
                url: "https://selected.example.test/mcp"))
        _ = try makeSkill(
            workspace: workspace,
            folder: "invalid",
            name: "invalid",
            body: "INVALID_BODY",
            metadata: """
            dependencies:
              tools:
                - type: mcp
                  value: invalid-server
                  transport: streamable_http
                  url: https://invalid.example.test/mcp
                  unexpected: rejected
            """)

        let snapshot = try await load(workspace)
        let plain = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $plain.",
                mcpAvailability: .unavailable))
        XCTAssertTrue(plain.contains("PLAIN_BODY"))
        XCTAssertFalse(
            snapshot
                .explicitActivationRequiresMCPAvailability(
                    in: "Use $plain."))

        XCTAssertTrue(
            snapshot
                .explicitActivationRequiresMCPAvailability(
                    in: "Use $dependent."))
        let dependencyRejected = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $dependent.",
                mcpAvailability: .unavailable))
        XCTAssertTrue(dependencyRejected.contains(
            "skill_mcp_host_unavailable"))
        XCTAssertFalse(dependencyRejected.contains(
            "DEPENDENT_BODY"))

        let invalidRejected = try XCTUnwrap(
            snapshot.explicitActivationPrompt(
                in: "Use $invalid.",
                mcpAvailability: .unavailable))
        XCTAssertTrue(invalidRejected.contains(
            "skill_mcp_dependency_metadata_invalid"))
        XCTAssertFalse(invalidRejected.contains(
            "INVALID_BODY"))
        XCTAssertFalse(invalidRejected.contains(
            "unexpected"))
    }

    func testStdioUsesExactServerIDWithoutRawCommandPathGuessing()
        async throws
    {
        let workspace = try makeWorkspace("stdio")
        let skillDirectory = try makeSkill(
            workspace: workspace,
            folder: "github",
            name: "github",
            body: "STDIO_BODY",
            metadata: stdioMetadata(
                value: "github-server",
                command: "/usr/local/bin/gh-mcp"))

        let first = try await load(workspace)
        let availability = try stdioAvailability(
            serverID: "github-server",
            command: "/usr/local/bin/gh-mcp")
        let activated = try XCTUnwrap(
            first.explicitActivationPrompt(
                in: "$github",
                mcpAvailability: availability))
        XCTAssertTrue(activated.contains("STDIO_BODY"))

        // The metadata command is deliberately not accepted as a server ID.
        let commandOnly = try stdioAvailability(
            serverID: "/usr/local/bin/gh-mcp",
            command: "/usr/local/bin/gh-mcp")
        let rejected = try XCTUnwrap(
            first.explicitActivationPrompt(
                in: "$github",
                mcpAvailability: commandOnly))
        XCTAssertTrue(rejected.contains(
            "skill_mcp_dependency_missing"))
        XCTAssertFalse(rejected.contains("STDIO_BODY"))

        let firstDigest = first.digest
        let firstFingerprint = try XCTUnwrap(
            first.skills.first?
                .mcpDependencies.first?
                .locatorFingerprint)
        try Data(stdioMetadata(
            value: "github-server",
            command: "/usr/local/bin/gh-mcp-v2").utf8).write(
                to: skillDirectory
                    .appendingPathComponent(
                        "agents/openai.yaml"),
                options: .atomic)
        let second = try await load(workspace)
        XCTAssertNotEqual(firstDigest, second.digest)
        XCTAssertNotEqual(
            firstFingerprint,
            second.skills.first?
                .mcpDependencies.first?
                .locatorFingerprint)
        let staleConnection = try XCTUnwrap(
            second.explicitActivationPrompt(
                in: "$github",
                mcpAvailability: availability))
        XCTAssertTrue(staleConnection.contains(
            "skill_mcp_dependency_missing"))
        XCTAssertFalse(staleConnection.contains(
            "STDIO_BODY"))
        XCTAssertTrue(
            try XCTUnwrap(
                second.explicitActivationPrompt(
                    in: "$github",
                    mcpAvailability:
                        try stdioAvailability(
                            serverID: "github-server",
                            command:
                                "/usr/local/bin/gh-mcp-v2")))
                .contains("STDIO_BODY"))
    }

    func testActivateAndResourceToolsPreflightBeforeDisclosure()
        async throws
    {
        let workspace = try makeWorkspace("tools")
        _ = try makeSkill(
            workspace: workspace,
            folder: "tool",
            name: "tool",
            body: "TOOL_SKILL_BODY",
            metadata: httpMetadata(
                value: "tool-server",
                url: "https://tool.example.test/mcp"),
            resources: [
                "reference.md": "TOOL_RESOURCE_BODY",
            ])
        let snapshot = try await load(workspace)
        let skill = try XCTUnwrap(snapshot.skills.first)
        let registry = snapshot.augmenting(
            ToolRegistry(
                [],
                registryVersion: "mcp-skill-tests"))
        let activate = try XCTUnwrap(
            registry.registration(
                named: "activate_skill"))
        let read = try XCTUnwrap(
            registry.registration(
                named: "read_skill_resource"))

        do {
            _ = try await activate.execute(
                ToolArgs(raw: try arguments([
                    "skill_id": skill.id,
                ])),
                in: ToolContext(
                    workspaceRoot: workspace,
                    mcpAvailability: .unavailable))
            XCTFail("dependent Skill activation should reject")
        } catch let error
            as ToolExecutionRejectedWithoutSideEffect
        {
            XCTAssertEqual(
                error.code,
                "skill_mcp_host_unavailable")
            XCTAssertFalse(error.message.contains(
                "TOOL_SKILL_BODY"))
            XCTAssertFalse(error.message.contains(
                "tool.example.test"))
        }

        do {
            _ = try await read.execute(
                ToolArgs(raw: try arguments([
                    "skill_id": skill.id,
                    "path": "reference.md",
                ])),
                in: ToolContext(
                    workspaceRoot: workspace,
                    mcpAvailability:
                        try httpAvailability(
                            serverID: "wrong-server",
                            url:
                                "https://tool.example.test/mcp")))
            XCTFail("dependent Skill resource should reject")
        } catch let error
            as ToolExecutionRejectedWithoutSideEffect
        {
            XCTAssertEqual(
                error.code,
                "skill_mcp_dependency_missing")
            XCTAssertFalse(error.message.contains(
                "TOOL_RESOURCE_BODY"))
        }

        let exactContext = ToolContext(
            workspaceRoot: workspace,
            mcpAvailability:
                try httpAvailability(
                    serverID: "tool-server",
                    url:
                        "https://tool.example.test/mcp"))
        let activation = try await activate.execute(
            ToolArgs(raw: try arguments([
                "skill_id": skill.id,
            ])),
            in: exactContext)
        XCTAssertTrue(activation.text.contains(
            "TOOL_SKILL_BODY"))
        let resource = try await read.execute(
            ToolArgs(raw: try arguments([
                "skill_id": skill.id,
                "path": "reference.md",
            ])),
            in: exactContext)
        XCTAssertTrue(resource.text.contains(
            "TOOL_RESOURCE_BODY"))
    }

    func testInvalidMetadataShapesFailClosedWithoutDroppingUnrelatedSkill()
        async throws
    {
        let workspace = try makeWorkspace("invalid")
        _ = try makeSkill(
            workspace: workspace,
            folder: "duplicate",
            name: "duplicate",
            body: "DUPLICATE_BODY",
            metadata: """
            dependencies:
              tools:
                - type: mcp
                  type: mcp
                  value: duplicate-server
                  transport: stdio
                  command: duplicate-mcp
            """)
        _ = try makeSkill(
            workspace: workspace,
            folder: "secret",
            name: "secret",
            body: "SECRET_BODY",
            metadata: """
            dependencies:
              tools:
                - type: mcp
                  value: secret-server
                  transport: streamable_http
                  url: https://secret.example.test/mcp
                  token: SHOULD_NOT_APPEAR
            """)
        _ = try makeSkill(
            workspace: workspace,
            folder: "relative",
            name: "relative",
            body: "RELATIVE_BODY",
            metadata: stdioMetadata(
                value: "relative-server",
                command: "relative-mcp"))
        let invalidUTF8Directory = try makeSkill(
            workspace: workspace,
            folder: "utf8",
            name: "utf8",
            body: "UTF8_BODY")
        try makeMetadataDirectory(
            invalidUTF8Directory)
        try Data([0xff, 0xfe, 0xfd]).write(
            to: invalidUTF8Directory
                .appendingPathComponent(
                    "agents/openai.yaml"))
        _ = try makeSkill(
            workspace: workspace,
            folder: "plain",
            name: "plain",
            body: "SAFE_PLAIN_BODY")

        let snapshot = try await load(workspace)
        XCTAssertEqual(snapshot.skills.count, 5)
        for name in [
            "duplicate", "secret", "relative", "utf8",
        ] {
            let skill = try XCTUnwrap(
                snapshot.skills.first {
                    $0.name == name
                })
            XCTAssertEqual(
                skill.mcpDependencyMetadataState,
                .invalid)
            let prompt = try XCTUnwrap(
                snapshot.explicitActivationPrompt(
                    in: "$\(name)",
                    mcpAvailability: .unavailable))
            XCTAssertTrue(prompt.contains(
                "skill_mcp_dependency_metadata_invalid"))
            XCTAssertFalse(prompt.contains(
                "\(name.uppercased())_BODY"))
        }
        XCTAssertTrue(
            try XCTUnwrap(
                snapshot.explicitActivationPrompt(
                    in: "$plain",
                    mcpAvailability: .unavailable))
                .contains("SAFE_PLAIN_BODY"))
        let diagnostics = snapshot.diagnostics
            .map(\.message)
            .joined(separator: "\n")
        XCTAssertFalse(diagnostics.contains(
            "SHOULD_NOT_APPEAR"))
        XCTAssertFalse(diagnostics.contains(
            "secret.example.test"))
    }

    func testSymlinkAndOversizedMetadataAreInvalidAndNeverResources()
        async throws
    {
        let workspace = try makeWorkspace("unsafe-files")
        let outside = workspace
            .appendingPathComponent("outside.yaml")
        try Data(httpMetadata(
            value: "outside-server",
            url: "https://outside.example.test/mcp").utf8)
            .write(to: outside)
        let linked = try makeSkill(
            workspace: workspace,
            folder: "linked",
            name: "linked",
            body: "LINKED_BODY")
        try makeMetadataDirectory(linked)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent(
                "agents/openai.yaml"),
            withDestinationURL: outside)

        let oversized = try makeSkill(
            workspace: workspace,
            folder: "oversized",
            name: "oversized",
            body: "OVERSIZED_BODY")
        try makeMetadataDirectory(oversized)
        try Data(repeating: 0x61, count: 17 * 1_024)
            .write(
                to: oversized.appendingPathComponent(
                    "agents/openai.yaml"))

        let snapshot = try await load(workspace)
        XCTAssertEqual(snapshot.skills.count, 2)
        for skill in snapshot.skills {
            XCTAssertEqual(
                skill.mcpDependencyMetadataState,
                .invalid)
            XCTAssertFalse(
                skill.resourcePaths.contains(
                    "agents/openai.yaml"))
            let rejected = try XCTUnwrap(
                snapshot.explicitActivationPrompt(
                    in: "$\(skill.name)",
                    mcpAvailability: .unavailable))
            XCTAssertTrue(rejected.contains(
                "skill_mcp_dependency_metadata_invalid"))
            XCTAssertFalse(rejected.contains(
                "outside.example.test"))
        }
    }

    func testMixedCaseMachineMetadataIsParsedButNeverFrozenAsResource()
        async throws
    {
        let workspace = try makeWorkspace(
            "mixed-case-metadata")
        let skillDirectory = try makeSkill(
            workspace: workspace,
            folder: "mixed",
            name: "mixed",
            body: "MIXED_CASE_BODY")
        let agents = skillDirectory
            .appendingPathComponent(
                "Agents",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: agents,
            withIntermediateDirectories: true)
        let rawURL =
            "https://mixed-case.example.test/mcp"
        try Data(httpMetadata(
            value: "mixed-server",
            url: rawURL).utf8).write(
                to: agents.appendingPathComponent(
                    "OpenAI.yaml"),
                options: .atomic)

        let snapshot = try await load(workspace)
        let skill = try XCTUnwrap(
            snapshot.skills.first)
        XCTAssertEqual(
            skill.mcpDependencyMetadataState,
            .valid)
        XCTAssertFalse(
            skill.resourcePaths.contains {
                $0.lowercased()
                    == "agents/openai.yaml"
            })
        let availability = try httpAvailability(
            serverID: "mixed-server",
            url: rawURL)
        XCTAssertTrue(
            try snapshot.activationPrompt(
                skillID: skill.id,
                mcpAvailability: availability)
                .contains("MIXED_CASE_BODY"))
        XCTAssertThrowsError(
            try snapshot.resourcePrompt(
                skillID: skill.id,
                path: "Agents/OpenAI.yaml",
                mcpAvailability: availability))

        let registry = snapshot.augmenting(
            ToolRegistry([]))
        let read = try XCTUnwrap(
            registry.registration(
                named: "read_skill_resource"))
        await XCTAssertThrowsErrorAsync {
            _ = try await read.execute(
                ToolArgs(raw: try self.arguments([
                    "skill_id": skill.id,
                    "path": "Agents/OpenAI.yaml",
                ])),
                in: ToolContext(
                    workspaceRoot: workspace,
                    mcpAvailability:
                        availability))
        }
    }

    func testAvailabilitySnapshotsAreValueIsolatedAcrossAgentContexts()
        async throws
    {
        let workspace = try makeWorkspace("isolation")
        _ = try makeSkill(
            workspace: workspace,
            folder: "isolated",
            name: "isolated",
            body: "ISOLATED_BODY",
            metadata: httpMetadata(
                value: "parent-server",
                url: "https://isolated.example.test/mcp"))
        let snapshot = try await load(workspace)
        let registry = snapshot.augmenting(
            ToolRegistry([]))
        let skill = try XCTUnwrap(snapshot.skills.first)
        let registration = try XCTUnwrap(
            registry.registration(
                named: "activate_skill"))
        let args = ToolArgs(raw: try arguments([
            "skill_id": skill.id,
        ]))
        let parentContext = ToolContext(
            workspaceRoot: workspace,
            mcpAvailability:
                try httpAvailability(
                    serverID: "parent-server",
                    url:
                        "https://isolated.example.test/mcp"))
        let childContext = ToolContext(
            workspaceRoot: workspace,
            mcpAvailability:
                try httpAvailability(
                    serverID: "child-server",
                    url:
                        "https://isolated.example.test/mcp"))

        let parent = try await registration.execute(
            args,
            in: parentContext)
        XCTAssertTrue(parent.text.contains(
            "ISOLATED_BODY"))
        do {
            _ = try await registration.execute(
                args,
                in: childContext)
            XCTFail("child snapshot must not inherit parent availability")
        } catch let error
            as ToolExecutionRejectedWithoutSideEffect
        {
            XCTAssertEqual(
                error.code,
                "skill_mcp_dependency_missing")
        }
        XCTAssertEqual(
            parentContext.mcpAvailability
                .serverIdentifiers,
            ["parent-server"])
        XCTAssertEqual(
            childContext.mcpAvailability
                .serverIdentifiers,
            ["child-server"])
    }

    func testAvailabilityFactoryRejectsUnpairedOrMalformedDependencyAssertions()
        throws
    {
        let validFingerprint =
            try MCPDependencyLocatorFingerprint
                .streamableHTTP(
                    "https://assertion.example.test/mcp")
        XCTAssertThrowsError(
            try MCPToolAvailabilitySnapshot.frozen(
                snapshotID: "unpaired-assertion",
                serverIdentifiers: ["visible-server"],
                toolIdentifiers: [],
                dependencyIdentities: [
                    MCPServerDependencyIdentity(
                        serverID: "different-server",
                        transportLocatorFingerprint:
                            validFingerprint),
                ]))
        XCTAssertThrowsError(
            try MCPToolAvailabilitySnapshot.frozen(
                snapshotID: "malformed-assertion",
                serverIdentifiers: ["visible-server"],
                toolIdentifiers: [],
                dependencyIdentities: [
                    MCPServerDependencyIdentity(
                        serverID: "visible-server",
                        transportLocatorFingerprint:
                            "mcplocator_not-a-digest"),
                ]))
        let largeToolView =
            try MCPToolAvailabilitySnapshot.frozen(
                snapshotID: "large-tool-view",
                serverIdentifiers: ["visible-server"],
                toolIdentifiers:
                    (0..<2_049).map {
                        "mcp__visible__tool_\($0)"
                    })
        XCTAssertEqual(
            largeToolView.toolIdentifiers.count,
            2_049)
    }

    // MARK: - Fixtures

    private func makeWorkspace(
        _ name: String
    ) throws -> URL {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "intatis-skill-mcp-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default
            .createDirectory(
                at: root,
                withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    @discardableResult
    private func makeSkill(
        workspace: URL,
        folder: String,
        name: String,
        body: String,
        metadata: String? = nil,
        resources: [String: String] = [:]
    ) throws -> URL {
        let directory = workspace
            .appendingPathComponent(
                ".agents/skills/\(folder)",
                isDirectory: true)
        try FileManager.default
            .createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        let skill = """
        ---
        name: \(name)
        description: MCP dependency test Skill \(name).
        ---
        \(body)
        """
        try Data(skill.utf8).write(
            to: directory
                .appendingPathComponent("SKILL.md"),
            options: .atomic)
        if let metadata {
            try makeMetadataDirectory(directory)
            try Data(metadata.utf8).write(
                to: directory
                    .appendingPathComponent(
                        "agents/openai.yaml"),
                options: .atomic)
        }
        for (path, value) in resources {
            let target = directory
                .appendingPathComponent(path)
            try FileManager.default
                .createDirectory(
                    at: target
                        .deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            try Data(value.utf8).write(
                to: target,
                options: .atomic)
        }
        return directory
    }

    private func makeMetadataDirectory(
        _ skillDirectory: URL
    ) throws {
        try FileManager.default
            .createDirectory(
                at: skillDirectory
                    .appendingPathComponent(
                        "agents",
                        isDirectory: true),
                withIntermediateDirectories: true)
    }

    private func load(
        _ workspace: URL
    ) async throws -> SkillSnapshot {
        try await SkillCatalogService.shared
            .snapshot(
                configuration:
                    SkillDiscoveryConfiguration(
                        workspaceRoot: workspace,
                        access: .workspaceOnly))
    }

    private func availability(
        servers: [String],
        tools: [String] = [],
        dependencies:
            [MCPServerDependencyIdentity] = []
    ) throws -> MCPToolAvailabilitySnapshot {
        try MCPToolAvailabilitySnapshot.frozen(
            snapshotID:
                "snapshot-\(UUID().uuidString)",
            serverIdentifiers: servers,
            toolIdentifiers: tools,
            dependencyIdentities:
                dependencies)
    }

    private func httpAvailability(
        serverID: String,
        url: String,
        servers: [String]? = nil,
        tools: [String] = []
    ) throws -> MCPToolAvailabilitySnapshot {
        try availability(
            servers: servers ?? [serverID],
            tools: tools,
            dependencies: [
                MCPServerDependencyIdentity(
                    serverID: serverID,
                    transportLocatorFingerprint:
                        try MCPDependencyLocatorFingerprint
                            .streamableHTTP(url)),
            ])
    }

    private func stdioAvailability(
        serverID: String,
        command: String
    ) throws -> MCPToolAvailabilitySnapshot {
        try availability(
            servers: [serverID],
            dependencies: [
                MCPServerDependencyIdentity(
                    serverID: serverID,
                    transportLocatorFingerprint:
                        try MCPDependencyLocatorFingerprint
                            .stdio(command)),
            ])
    }

    private func arguments(
        _ object: [String: String]
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return try XCTUnwrap(
            String(
                data: data,
                encoding: .utf8))
    }

    private func httpMetadata(
        value: String,
        url: String
    ) -> String {
        """
        interface:
          display_name: "Dependency test"
        dependencies:
          tools:
            - type: mcp
              value: \(value)
              description: Required request-owned MCP server.
              transport: streamable_http
              url: \(url)
        policy:
          allow_implicit_invocation: true
        """
    }

    private func stdioMetadata(
        value: String,
        command: String
    ) -> String {
        """
        dependencies:
          tools:
            - type: mcp
              value: \(value)
              description: Required request-owned MCP server.
              transport: stdio
              command: \(command)
        """
    }

    private func XCTAssertThrowsErrorAsync(
        _ operation: () async throws -> Void,
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
}
