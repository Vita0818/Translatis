import Foundation
import IntatisCore
import IntatisProtocol
import IntatisSkills

struct CodexRuntimeStorage: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let runtimeVersion: String
        let derivationID: String?
        let threadID: String
        let mode: CodexRuntimeMode
        let workspacePath: String
        /// Exact App Server dynamic-tool surface frozen when the thread was
        /// created. A missing or different value requires a new session;
        /// dynamic tools exist only on `thread/start` in the pinned protocol.
        let dynamicToolsetID: String?
        let materialized: Bool

        init(
            schemaVersion: Int,
            runtimeVersion: String,
            derivationID: String? =
                CodexRuntimeExecutable.pinnedDerivationID,
            threadID: String,
            mode: CodexRuntimeMode,
            workspacePath: String,
            dynamicToolsetID: String? = nil,
            materialized: Bool
        ) {
            self.schemaVersion = schemaVersion
            self.runtimeVersion = runtimeVersion
            self.derivationID = derivationID
            self.threadID = threadID
            self.mode = mode
            self.workspacePath = workspacePath
            self.dynamicToolsetID = dynamicToolsetID
            self.materialized = materialized
        }
    }

    let rootURL: URL
    let homeURL: URL
    let recordURL: URL
    let modelCatalogURL: URL
    let processLockURL: URL
    let childProfilesURL: URL
    let configURL: URL
    let skillsURL: URL
    let hostApplicationIdentity: IntatisHostApplicationIdentity

    init(
        rootURL: URL,
        hostApplicationIdentity: IntatisHostApplicationIdentity =
            IntatisHostApplication.identity
    ) {
        self.hostApplicationIdentity = hostApplicationIdentity
        self.rootURL = rootURL.standardizedFileURL
        self.homeURL = self.rootURL.appendingPathComponent(
            "codex-home",
            isDirectory: true)
        self.recordURL = self.rootURL.appendingPathComponent(
            "runtime.json")
        self.modelCatalogURL = self.rootURL.appendingPathComponent(
            "models.json")
        self.processLockURL = self.rootURL.appendingPathComponent(
            "runtime.lock")
        self.childProfilesURL = self.homeURL.appendingPathComponent(
            hostApplicationIdentity.fileNameStem + "-agent-profiles",
            isDirectory: true)
        self.configURL = self.homeURL.appendingPathComponent("config.toml")
        self.skillsURL = self.homeURL.appendingPathComponent(
            "skills",
            isDirectory: true)
    }

    func prepare() throws {
        try prepareOwnedDirectory(rootURL)
        try prepareOwnedDirectory(homeURL)
    }

    /// Materializes the existing product-bundled Cowork Skill into the
    /// isolated CODEX_HOME using Codex's official Skill discovery layout.
    /// Only the two audited UTF-8 resources are copied; no executable, secret,
    /// endpoint, credential, or session path is written into the Skill.
    func installCoworkSkill() throws {
        guard let bundledRoot = IntatisBundledSkills.discoveryRoots.first else {
            throw CodexRuntimeError.malformedProtocol(
                "the bundled Cowork orchestration Skill is unavailable")
        }
        let name = IntatisBundledSkills.coworkAgentOrchestrationName
        let source = bundledRoot.appendingPathComponent(
            name,
            isDirectory: true)
        let destination = skillsURL.appendingPathComponent(
            name,
            isDirectory: true)
        let sourceFiles: [(source: URL, destination: URL)] = [
            (
                source.appendingPathComponent("SKILL.md"),
                destination.appendingPathComponent("SKILL.md")),
            (
                source.appendingPathComponent("references", isDirectory: true)
                    .appendingPathComponent("model-routing.md"),
                destination.appendingPathComponent(
                    "references",
                    isDirectory: true)
                    .appendingPathComponent("model-routing.md")),
        ]
        try prepareOwnedDirectory(skillsURL)
        try prepareOwnedDirectory(destination)
        try prepareOwnedDirectory(destination.appendingPathComponent(
            "references",
            isDirectory: true))
        for file in sourceFiles {
            let values = try file.source.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= 64 * 1_024 else {
                throw CodexRuntimeError.malformedProtocol(
                    "the bundled Cowork orchestration Skill is unsafe")
            }
            var data = try Data(contentsOf: file.source)
            guard data.count == size,
                  let sourceText = String(data: data, encoding: .utf8) else {
                throw CodexRuntimeError.malformedProtocol(
                    "the bundled Cowork orchestration Skill is not bounded UTF-8 text")
            }
            if hostApplicationIdentity != .intatis {
                data = Data(sourceText.replacingOccurrences(
                    of: "Intatis",
                    with: hostApplicationIdentity.name).utf8)
                guard !data.isEmpty, data.count <= 64 * 1_024 else {
                    throw CodexRuntimeError.malformedProtocol(
                        "the host-branded Cowork orchestration Skill exceeds its byte limit")
                }
            }
            do {
                try DurableOwnerOnlyFile.writeAtomically(
                    data,
                    to: file.destination,
                    temporaryPrefix: "." + hostApplicationIdentity
                        .temporaryPrefix("cowork-skill-"))
            } catch {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
        }
    }

    func writeChildProfiles(
        _ profiles: [CodexRuntimeChildProfile],
        providerIDs: [String: String],
        mcpConfiguration: CodexRuntimeMCPConfiguration = .empty
    ) throws -> [String: URL] {
        guard !profiles.isEmpty || !mcpConfiguration.isEmpty else {
            return [:]
        }
        try prepareOwnedDirectory(childProfilesURL)
        var result: [String: URL] = [:]
        let mcpDenyOverlay = try mcpConfiguration
            .renderedDisabledRoleOverlayTOML()
        for profile in profiles {
            guard let providerID = providerIDs[profile.roleName] else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex child profile is missing its official provider id")
            }
            let url = childProfileURL(roleName: profile.roleName)
            let workspacePath = profile.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            let role = try Self.tomlString(profile.roleName)
            let description = try Self.tomlString(profile.description)
            let model = try Self.tomlString(profile.route.model.rawValue)
            let provider = try Self.tomlString(providerID)
            let sandbox = try Self.tomlString(profile.sandbox.rawValue)
            let workspace = try Self.tomlString(workspacePath)
            let developerInstructions = try Self.tomlString(
                "Use the user-approved workspace at \(workspacePath) as this role's task root. Keep all file work within that workspace and report if the assigned task requires another root.")
            var lines = [
                "name = \(role)",
                "description = \(description)",
                "model = \(model)",
                "model_provider = \(provider)",
                "sandbox_mode = \(sandbox)",
                "developer_instructions = \(developerInstructions)",
            ]
            if let effort = profile.route.reasoningEffort {
                lines.append(
                    "model_reasoning_effort = \(try Self.tomlString(effort))")
            }
            if profile.sandbox == .workspaceWrite {
                lines.append(contentsOf: [
                    "",
                    "[sandbox_workspace_write]",
                    "writable_roots = [\(workspace)]",
                    "network_access = false",
                    "exclude_tmpdir_env_var = true",
                    "exclude_slash_tmp = true",
                ])
            }
            if !mcpDenyOverlay.isEmpty {
                lines.append("")
                lines.append(contentsOf: mcpDenyOverlay)
            }
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            do {
                try DurableOwnerOnlyFile.writeAtomically(
                    data,
                    to: url,
                    temporaryPrefix: "." + hostApplicationIdentity
                        .temporaryPrefix("agent-profile-"))
            } catch {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
            result[profile.roleName] = url
        }
        if !mcpDenyOverlay.isEmpty {
            let url = defaultChildProfileURL
            let developerInstructions = try Self.tomlString(
                "Use only the current inherited workspace and host-approved tools.")
            var lines = [
                "developer_instructions = \(developerInstructions)",
                "",
            ]
            lines.append(contentsOf: mcpDenyOverlay)
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            do {
                try DurableOwnerOnlyFile.writeAtomically(
                    data,
                    to: url,
                    temporaryPrefix: "." + hostApplicationIdentity
                        .temporaryPrefix("agent-profile-"))
            } catch {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
            result["default"] = url
        }
        return result
    }

    func writeAgentRegistry(
        _ profiles: [CodexRuntimeChildProfile],
        profileURLs: [String: URL],
        mcpConfiguration: CodexRuntimeMCPConfiguration = .empty
    ) throws {
        var lines: [String] = []
        for profile in profiles.sorted(by: {
            $0.roleName < $1.roleName
        }) {
            guard let profileURL = profileURLs[profile.roleName] else {
                throw CodexRuntimeError.malformedProtocol(
                    "a Codex agent registry entry is missing its role file")
            }
            lines.append("[agents.\(profile.roleName)]")
            lines.append(
                "description = \(try Self.tomlString(profile.description))")
            lines.append(
                "config_file = \(try Self.tomlString(profileURL.path))")
            lines.append(
                "nickname_candidates = [\(try Self.tomlString(profile.roleName))]")
            lines.append("")
        }
        if let defaultProfileURL = profileURLs["default"] {
            let description = try Self.tomlString(
                "Inherit the parent route and workspace with descendant MCP disabled.")
            lines.append("[agents.default]")
            lines.append("description = \(description)")
            lines.append(
                "config_file = \(try Self.tomlString(defaultProfileURL.path))")
            lines.append("")
        }
        lines.append(contentsOf: try mcpConfiguration.renderedTOML())
        let data = Data(lines.joined(separator: "\n").utf8)
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: configURL,
                temporaryPrefix: "." + hostApplicationIdentity
                    .temporaryPrefix("codex-config-"))
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    func childProfileURL(roleName: String) -> URL {
        childProfilesURL.appendingPathComponent(
            hostApplicationIdentity.fileNameStem
                + "-" + roleName + ".toml")
    }

    var defaultChildProfileURL: URL {
        childProfilesURL.appendingPathComponent(
            hostApplicationIdentity.fileNameStem + "-default.toml")
    }

    func rejectPersistedShellSnapshots() throws {
        let snapshotURL = homeURL.appendingPathComponent(
            "shell_snapshots",
            isDirectory: true)
        do {
            _ = try FileManager.default.attributesOfItem(
                atPath: snapshotURL.path)
            throw CodexRuntimeError.shellSnapshotStoragePresent
        } catch let error as CodexRuntimeError {
            throw error
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
                || error.code == .fileNoSuchFile {
            return
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    func readRecord() throws -> Record? {
        guard let data = try DurableOwnerOnlyFile.read(
            from: recordURL,
            maximumBytes: 16 * 1_024) else {
            return nil
        }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schemaVersion == 2,
                  record.runtimeVersion
                    == CodexRuntimeExecutable.pinnedVersion,
                  record.derivationID
                    == CodexRuntimeExecutable.pinnedDerivationID,
                  record.materialized,
                  !record.threadID.isEmpty,
                  !record.threadID.contains("\n"),
                  !record.threadID.contains("\r"),
                  record.dynamicToolsetID.map({
                      !$0.isEmpty
                        && $0.count <= 256
                        && $0.unicodeScalars.allSatisfy {
                            !CharacterSet.controlCharacters.contains($0)
                        }
                  }) ?? true else {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
            return record
        } catch let error as CodexRuntimeError {
            throw error
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    func writeRecord(
        threadID: String,
        mode: CodexRuntimeMode,
        workspacePath: String,
        dynamicToolsetID: String? = nil
    ) throws {
        guard !threadID.isEmpty,
              !threadID.contains("\n"),
              !threadID.contains("\r"),
              dynamicToolsetID.map({
                  !$0.isEmpty
                    && $0.count <= 256
                    && $0.unicodeScalars.allSatisfy {
                        !CharacterSet.controlCharacters.contains($0)
                    }
              }) ?? true else {
            throw CodexRuntimeError.malformedProtocol(
                "thread/start returned an invalid thread or dynamic-tool identity")
        }
        let data = try JSONEncoder.intatisCodex.encode(Record(
            schemaVersion: 2,
            runtimeVersion: CodexRuntimeExecutable.pinnedVersion,
            derivationID: CodexRuntimeExecutable.pinnedDerivationID,
            threadID: threadID,
            mode: mode,
            workspacePath: workspacePath,
            dynamicToolsetID: dynamicToolsetID,
            materialized: true))
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: recordURL,
                temporaryPrefix: ".codex-runtime-")
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    /// Supplies model metadata through Codex's official static-catalog
    /// extension point. The selected Responses model is also the approval
    /// reviewer model, avoiding an implicit request for an unrelated OpenAI
    /// model on third-party Responses endpoints.
    func writeModelCatalog(
        modelID: String,
        baseInstructions: String,
        reasoningEffort: String? = nil,
        multiAgentEnabled: Bool = false,
        skillsEnabled: Bool = true,
        additionalModels: [(modelID: String, reasoningEffort: String?)] = []
    ) throws {
        let requestedModels = [(
            modelID: modelID,
            reasoningEffort: reasoningEffort)]
            + additionalModels
        guard requestedModels.allSatisfy({ candidate in
            !candidate.modelID.isEmpty
                && candidate.modelID.count <= 256
                && candidate.modelID.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }) else {
            throw CodexRuntimeError.malformedProtocol(
                "the selected Responses model id is invalid")
        }
        var orderedModelIDs: [String] = []
        var effortsByModel: [String: Set<String>] = [:]
        for candidate in requestedModels {
            if effortsByModel[candidate.modelID] == nil {
                orderedModelIDs.append(candidate.modelID)
                effortsByModel[candidate.modelID] = []
            }
            if let effort = candidate.reasoningEffort {
                effortsByModel[candidate.modelID, default: []]
                    .insert(effort)
            }
        }
        let models: [JSONValue] = orderedModelIDs.map { candidateModelID in
            let supportedReasoning = (effortsByModel[candidateModelID] ?? [])
                .sorted()
                .map { effort in
                    JSONValue.object([
                        "effort": .string(effort),
                        "description": .string(effort),
                    ])
                }
            return .object([
                "slug": .string(candidateModelID),
                "display_name": .string(candidateModelID),
                "description": .null,
                "base_instructions": .string(baseInstructions),
                "default_reasoning_level": .null,
                "supported_reasoning_levels": .array(
                    supportedReasoning),
                "shell_type": .string("unified_exec"),
                "visibility": .string("list"),
                "supported_in_api": .bool(true),
                "priority": .number(1),
                "availability_nux": .null,
                "upgrade": .null,
                "support_verbosity": .bool(false),
                "default_verbosity": .null,
                "apply_patch_tool_type": .null,
                "truncation_policy": .object([
                    "mode": .string("bytes"),
                    "limit": .number(10_000),
                ]),
                "supports_parallel_tool_calls": .bool(false),
                "experimental_supported_tools": .array([]),
                "input_modalities": .array([
                    .string("text"),
                    .string("image"),
                ]),
                "context_window": .number(272_000),
                "max_context_window": .number(272_000),
                "effective_context_window_percent": .number(95),
                "include_skills_usage_instructions": .bool(
                    skillsEnabled),
                "include_plugin_usage_instructions": .bool(false),
                "include_apps_usage_instructions": .bool(false),
                "supports_reasoning_summary_parameter": .bool(false),
                "default_reasoning_summary": .string("none"),
                "web_search_tool_type": .string("text"),
                "supports_image_detail_original": .bool(false),
                "supports_search_tool": .bool(false),
                "use_responses_lite": .bool(false),
                "node_repl_auto_review_required": .bool(false),
                "node_repl_disabled": .bool(false),
                "auto_review_model_override": .string(candidateModelID),
                "multi_agent_version": .string(
                    multiAgentEnabled ? "v2" : "disabled"),
            ])
        }
        let data = try JSONEncoder.intatisCodex.encode(
            JSONValue.object([
                "models": .array(models),
            ]))
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: modelCatalogURL,
                temporaryPrefix: ".codex-models-")
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    private func prepareOwnedDirectory(_ url: URL) throws {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [
                        .posixPermissions: NSNumber(value: 0o700),
                    ])
            }
            let canonical = try DurableOwnerOnlyFile
                .validateOwnedDirectory(at: url)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: canonical.path)
            guard let permissions = attributes[.posixPermissions]
                    as? NSNumber,
                  permissions.intValue & 0o777 == 0o700 else {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
        } catch {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
    }

    private static func tomlString(_ value: String) throws -> String {
        let data = try JSONEncoder.intatisCodex.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CodexRuntimeError.malformedProtocol(
                "a Codex child profile contains invalid text")
        }
        return encoded
    }
}

extension JSONEncoder {
    static var intatisCodex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return encoder
    }
}
