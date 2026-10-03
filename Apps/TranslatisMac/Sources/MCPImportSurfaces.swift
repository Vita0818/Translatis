#if canImport(SwiftUI)
import AppKit
import CryptoKit
import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisSharedUI
import SwiftUI
import IntatisMCPStdio

enum MCPImportConflictChoice:
    String, CaseIterable, Identifiable
{
    case rename
    case replace
    case skip

    var id: String { rawValue }
}

struct MCPImportConflictResolutionDraft: Sendable {
    var choice: MCPImportConflictChoice
    var renamedAlias: String
}

struct MCPImportWorkspace: Sendable {
    let parsed: MCPImportParseResult
    let plan: MCPPlannedImport
}

private enum MCPImportEndpointPolicy {
    static func isInsecureLoopbackDevelopmentHTTP(
        _ rawValue: String
    ) -> Bool {
        guard let components =
                URLComponents(
                    string:
                        rawValue.trimmingCharacters(
                            in:
                                .whitespacesAndNewlines)),
              components.scheme?
                .lowercased() == "http",
              let host =
                components.host?
                    .lowercased()
        else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }
}

extension AppMCPService {
    func prepareImport(
        at url: URL,
        format: MCPImportFormat
    ) async throws -> MCPImportWorkspace {
        let parsed = try await management.importPreview(
            at: url,
            format: format)
        let catalog = try await management.catalog()
        let plan = try MCPImportPlanner.plan(
            preview: parsed.preview,
            catalog: catalog)
        return MCPImportWorkspace(
            parsed: parsed,
            plan: plan)
    }

    func commitImport(
        workspace: MCPImportWorkspace,
        conflictResolutions:
            [String: MCPImportConflictResolutionDraft],
        launchClosures:
            [String: [MCPServerEditorLaunchFile]],
        protocolProfile: MCPProtocolProfile,
        insecureLoopbackDevelopmentHTTP:
            Set<String>
    ) async -> Bool {
        var succeeded = false
        await perform {
            let catalog = try await self.management.catalog()
            let decisions = try Dictionary(
                uniqueKeysWithValues:
                    workspace.plan.conflicts.map {
                        conflict in
                        guard let draft =
                                conflictResolutions[
                                    conflict.proposalID] else {
                            throw MCPImportError
                                .unresolvedConflict
                        }
                        let decision:
                            MCPImportConflictDecision
                        switch draft.choice {
                        case .rename:
                            decision = .rename(
                                draft.renamedAlias)
                        case .replace:
                            decision = .replaceExisting(
                                conflict.existingServerID)
                        case .skip:
                            decision = .skip
                        }
                        return (
                            conflict.proposalID,
                            decision)
                    })
            let proposals =
                try workspace.plan.resolving(
                    decisions,
                    catalog: catalog)
            guard !proposals.isEmpty else {
                throw MCPImportError
                    .previewHasBlockingIssues
            }

            var migrated:
                [String: MCPSecretReference] = [:]
            do {
                migrated = try await workspace.parsed
                    .secretStaging.migrate(
                        to: self.secretStore)
                var preparedInputs:
                    [(alias: String,
                      configuration:
                        MCPServerConfiguration)] = []
                var configurations:
                    [MCPServerConfiguration] = []
                for proposal in proposals {
                    let artifact:
                        LaunchArtifactIdentity?
                    switch proposal.transport {
                    case .streamableHTTP:
                        artifact = nil
                    case .stdio:
                        guard let files =
                                launchClosures[
                                    proposal.proposalID],
                              !files.isEmpty,
                              files.filter({
                                  $0.role == .executable
                              }).count == 1,
                              files.allSatisfy({
                                  $0.path
                                      .trimmingCharacters(
                                          in: .whitespacesAndNewlines)
                                      .hasPrefix("/")
                              }) else {
                            throw MCPImportError
                                .launchArtifactTestRequired
                        }
                        artifact =
                            try MCPLaunchArtifactIdentityVerifier
                                .captureBeforeSave(
                                    files.map {
                                        MCPLaunchArtifactInput(
                                            role: $0.role
                                                .protocolRole,
                                            path: $0.path
                                                .trimmingCharacters(
                                                    in: .whitespacesAndNewlines))
                                    })
                    }
                    let configuration =
                        try proposal.makeConfiguration(
                            resolution:
                                MCPImportedServerResolution(
                                    launchArtifact: artifact,
                                    secretReferences: migrated,
                                    environmentReference:
                                        MCPEnvironmentReference(
                                            rawValue:
                                                "mcpenv_app_import"),
                                    protocolProfile:
                                        protocolProfile,
                                    allowInsecureLoopbackDevelopmentHTTP:
                                        insecureLoopbackDevelopmentHTTP
                                            .contains(
                                                proposal
                                                    .proposalID)))
                    configurations.append(configuration)
                    preparedInputs.append((
                        alias: proposal.alias,
                        configuration:
                            configuration))
                }

                let used = Set(
                    configurations.flatMap(
                        Self.secretReferences))
                for reference in migrated.values
                    where !used.contains(reference) {
                    try? await self.secretStore.remove(
                        reference)
                }
                let preview = workspace.parsed.preview
                let sourceKind:
                    MCPConfigurationSourceKind =
                        preview.format == .mcpJSON
                            ? .importedMCPJSON
                            : .importedClaudeJSON
                let marker = try MCPImportMarker(
                    sourceKind: sourceKind,
                    sourceFingerprint:
                        preview.sourceFingerprint,
                    formatVersion:
                        preview.parserVersion,
                    importedServerIDs:
                        proposals.map(\.serverID))
                let prepared =
                    try await self.management
                        .prepareBatch(
                            preparedInputs)
                let authorization =
                    try MCPConfigurationTestAuthorization(
                        directUserAction: true,
                        callerFingerprint:
                            SHA256.hash(data: Data([
                                IntatisHostApplication.identity
                                    .temporaryPrefix(
                                        "mac-import-test-v1"),
                                preview.sourceFingerprint,
                            ].joined(separator: "\u{1f}")
                                .utf8))
                            .map {
                                String(
                                    format: "%02x",
                                    $0)
                            }.joined())
                _ = try await self.management
                    .testAndSavePreparedBatch(
                        prepared,
                        authorization:
                            authorization,
                        importMarker: marker)
                await workspace.parsed.secretStaging
                    .discard()
                succeeded = true
                return "Tested and atomically imported \(prepared.count) MCP server(s)."
            } catch {
                for reference in migrated.values {
                    try? await self.secretStore.remove(
                        reference)
                }
                await workspace.parsed.secretStaging
                    .discard()
                throw error
            }
        }
        return succeeded
    }

    private static func secretReferences(
        _ configuration: MCPServerConfiguration
    ) -> [MCPSecretReference] {
        switch configuration.transport {
        case .stdio(let stdio):
            return stdio.environment.values.compactMap {
                guard case .secret(let reference) = $0
                else { return nil }
                return reference
            } + Array(
                stdio.inheritedEnvironmentReferences.values)
        case .streamableHTTP(let http):
            var values: [MCPSecretReference] =
                http.headers.values.compactMap {
                guard case .secret(let reference) = $0
                else { return nil }
                return reference
            }
            if let bearer = http.bearerTokenReference {
                values.append(bearer)
            }
            if let clientSecret =
                    http.oauth?.clientSecretReference {
                values.append(clientSecret)
            }
            return values
        }
    }
}

@MainActor
private final class MCPImportViewModel:
    ObservableObject
{
    @Published var fileURL: URL?
    @Published var format = MCPImportFormat.mcpJSON
    @Published var protocolProfile =
        MCPProtocolProfile.codexCompat
    @Published var workspace: MCPImportWorkspace?
    @Published var resolutions:
        [String: MCPImportConflictResolutionDraft] = [:]
    @Published var launchClosures:
        [String: [MCPServerEditorLaunchFile]] = [:]
    @Published var insecureLoopbackDevelopmentHTTP:
        Set<String> = []
    @Published var isWorking = false
    @Published var errorMessage: String?

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        TranslatisMacProcessDiagnostics.shared
            .setKnownModalPresented(true)
        defer {
            TranslatisMacProcessDiagnostics.shared
                .setKnownModalPresented(false)
        }
        guard panel.runModal() == .OK,
              let value = panel.url else { return }
        fileURL = value
        workspace = nil
        resolutions = [:]
        launchClosures = [:]
        insecureLoopbackDevelopmentHTTP = []
        errorMessage = nil
    }

    func prepare(service: AppMCPService) async {
        guard let fileURL else { return }
        isWorking = true
        errorMessage = nil
        do {
            let value = try await service.prepareImport(
                at: fileURL,
                format: format)
            workspace = value
            var used = Set(
                value.parsed.preview.proposals.map(\.alias))
            resolutions = Dictionary(
                uniqueKeysWithValues:
                    value.plan.conflicts.map {
                        conflict in
                        var index = 2
                        var alias =
                            "\(conflict.alias)-imported"
                        while used.contains(alias) {
                            alias =
                                "\(conflict.alias)-imported-\(index)"
                            index += 1
                        }
                        used.insert(alias)
                        return (
                            conflict.proposalID,
                            MCPImportConflictResolutionDraft(
                                choice: .rename,
                                renamedAlias: alias))
                    })
            launchClosures = Dictionary(
                uniqueKeysWithValues:
                    value.parsed.preview.proposals.compactMap {
                        proposal in
                        guard case .stdio(let stdio) =
                                proposal.transport else {
                            return nil
                        }
                        return (
                            proposal.proposalID,
                            [
                                MCPServerEditorLaunchFile(
                                    role: .executable,
                                    path:
                                        stdio.command
                                            .hasPrefix("/")
                                            ? stdio.command
                                            : ""),
                            ])
                    })
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func discard() {
        guard let workspace else { return }
        Task {
            await workspace.parsed.secretStaging.discard()
        }
        self.workspace = nil
        insecureLoopbackDevelopmentHTTP = []
    }
}

struct MCPImportServerSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model =
        MCPImportViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Explicit source") {
                        HStack {
                            LabeledContent("File") {
                                Text(
                                    model.fileURL?
                                        .lastPathComponent
                                        ?? "No file selected")
                                    .textSelection(.enabled)
                            }
                            Button("Choose…") {
                                model.chooseFile()
                            }
                        }
                        Picker(
                            "Source format",
                            selection: $model.format
                        ) {
                            Text("mcp.json")
                                .tag(MCPImportFormat.mcpJSON)
                            Text("Claude JSON")
                                .tag(MCPImportFormat.claudeJSON)
                        }
                        Picker(
                            "Protocol profile",
                            selection:
                                $model.protocolProfile
                        ) {
                            Text("codex-compat")
                                .tag(
                                    MCPProtocolProfile
                                        .codexCompat)
                            Text("standard-extended")
                                .tag(
                                    MCPProtocolProfile
                                        .standardExtended)
                        }
                        Button("Parse and Review") {
                            Task {
                                await model.prepare(
                                    service: env.mcp)
                            }
                        }
                        .disabled(
                            model.fileURL == nil
                                || model.isWorking)
                    }
                    if let workspace = model.workspace {
                        preview(workspace)
                    }
                    if let error = model.errorMessage {
                        Section("Import Error") {
                            Text(error)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle("Import MCP Servers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.discard()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Test & Import") {
                        guard let workspace =
                                model.workspace else {
                            return
                        }
                        Task {
                            let saved =
                                await env.mcp.commitImport(
                                    workspace:
                                        workspace,
                                    conflictResolutions:
                                        model.resolutions,
                                    launchClosures:
                                        model.launchClosures,
                                    protocolProfile:
                                        model.protocolProfile,
                                    insecureLoopbackDevelopmentHTTP:
                                        model
                                            .insecureLoopbackDevelopmentHTTP)
                            if saved { dismiss() }
                        }
                    }
                    .disabled(!canCommit)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 720)
    }

    @ViewBuilder
    private func preview(
        _ workspace: MCPImportWorkspace
    ) -> some View {
        let preview = workspace.parsed.preview
        Section("Review") {
            LabeledContent("Source") {
                Text(preview.sourceLabel)
            }
            LabeledContent("Source fingerprint") {
                Text(preview.sourceFingerprint)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Parser version") {
                Text("\(preview.parserVersion)")
            }
            LabeledContent("Servers") {
                Text("\(preview.proposals.count)")
            }
            LabeledContent("Secrets to migrate") {
                Text("\(preview.secretDescriptors.count)")
            }
            Text(
                "Preview never displays imported secret values. Test & Import migrates them directly from bounded in-memory staging to Keychain, tests every exact draft, then commits the catalog as one atomic batch.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
        if !preview.issues.isEmpty {
            Section("Parser Issues") {
                ForEach(
                    Array(preview.issues.enumerated()),
                    id: \.offset
                ) { _, issue in
                    Label {
                        Text(
                            "\(issue.code.rawValue) · \(issue.path)")
                            .font(IntatisTypography.system(.body, design: .monospaced))
                    } icon: {
                        Image(systemName:
                            issue.blocking
                                ? "xmark.octagon"
                                : "exclamationmark.triangle")
                    }
                    .foregroundStyle(
                        issue.blocking
                            ? Color.red
                            : Color.orange)
                }
            }
        }
        if !preview.secretDescriptors.isEmpty {
            Section("Secret Migration") {
                ForEach(
                    preview.secretDescriptors,
                    id: \.stagingID
                ) { descriptor in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.kind.rawValue)
                            .font(IntatisTypography.system(.body, weight: .semibold))
                        Text(descriptor.fieldPath)
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("Server Proposals") {
            ForEach(
                preview.proposals,
                id: \.proposalID
            ) { proposal in
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        "\(proposal.alias) — \(proposal.displayName)")
                        .font(IntatisTypography.system(.body, weight: .semibold))
                    switch proposal.transport {
                    case .streamableHTTP(let http):
                        Text(http.endpoint)
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        if MCPImportEndpointPolicy
                            .isInsecureLoopbackDevelopmentHTTP(
                                http.endpoint) {
                            Toggle(
                                "Allow insecure loopback HTTP for development",
                                isOn:
                                    insecureLoopbackBinding(
                                        proposal
                                            .proposalID))
                            if model
                                .insecureLoopbackDevelopmentHTTP
                                .contains(
                                    proposal
                                        .proposalID) {
                                Text(
                                    "Development only. Plain HTTP is accepted only for this exact loopback endpoint; OAuth, redirects, proxies, and non-loopback hosts remain blocked.")
                                    .font(IntatisTypography.system(.caption))
                                    .foregroundStyle(
                                        .orange)
                            }
                        }
                    case .stdio(let stdio):
                        Text(stdio.command)
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        if !stdio.arguments.isEmpty {
                            Text(
                                "Imported arguments: \(stdio.arguments.joined(separator: " "))")
                                .font(IntatisTypography.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        let closure = launchClosure(
                            proposal.proposalID,
                            importedCommand:
                                stdio.command)
                        ForEach(closure) { $file in
                            HStack {
                                Picker(
                                    "Role",
                                    selection:
                                        $file.role
                                ) {
                                    ForEach(
                                        MCPServerEditorFileRole
                                            .allCases
                                    ) { role in
                                        Text(role.rawValue)
                                            .tag(role)
                                    }
                                }
                                .frame(width: 180)
                                TextField(
                                    "Exact absolute path",
                                    text: $file.path)
                                if closure
                                    .wrappedValue
                                    .count > 1 {
                                    Button(
                                        role:
                                            .destructive
                                    ) {
                                        closure
                                            .wrappedValue
                                            .removeAll {
                                                $0.id
                                                    == file.id
                                            }
                                    } label: {
                                        Image(
                                            systemName:
                                                "minus.circle")
                                    }
                                }
                            }
                        }
                        Button("Add launch-closure file") {
                            closure.wrappedValue.append(
                                .init(role: .script))
                        }
                        Text(
                            "Declare the complete launch closure explicitly: exactly one executable plus every interpreter, script, package entrypoint, lockfile, and helper. \(IntatisHostApplication.identity.name) does not infer files from imported arguments.")
                            .font(IntatisTypography.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !workspace.plan.conflicts.isEmpty {
            Section("Conflicts") {
                ForEach(
                    workspace.plan.conflicts,
                    id: \.proposalID
                ) { conflict in
                    let binding = resolution(
                        conflict.proposalID,
                        fallbackAlias:
                            "\(conflict.alias)-imported")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conflict.alias)
                            .font(IntatisTypography.system(.body, weight: .semibold))
                        Picker(
                            "Resolution",
                            selection: binding.choice
                        ) {
                            Text("Rename imported server")
                                .tag(
                                    MCPImportConflictChoice
                                        .rename)
                            Text("Replace current server")
                                .tag(
                                    MCPImportConflictChoice
                                        .replace)
                            Text("Skip")
                                .tag(
                                    MCPImportConflictChoice
                                        .skip)
                        }
                        if binding.wrappedValue.choice
                            == .rename {
                            TextField(
                                "New alias",
                                text:
                                    binding.renamedAlias)
                        }
                        Text(
                            "No conflict is overwritten implicitly.")
                            .font(IntatisTypography.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func resolution(
        _ proposalID: String,
        fallbackAlias: String
    ) -> Binding<MCPImportConflictResolutionDraft> {
        Binding(
            get: {
                model.resolutions[proposalID]
                    ?? .init(
                        choice: .rename,
                        renamedAlias: fallbackAlias)
            },
            set: {
                model.resolutions[proposalID] = $0
            })
    }

    private func launchClosure(
        _ proposalID: String,
        importedCommand: String
    ) -> Binding<[MCPServerEditorLaunchFile]> {
        Binding(
            get: {
                model.launchClosures[proposalID]
                    ?? [
                        MCPServerEditorLaunchFile(
                            role: .executable,
                            path:
                                importedCommand
                                    .hasPrefix("/")
                                    ? importedCommand
                                    : ""),
                    ]
            },
            set: {
                model.launchClosures[proposalID] = $0
            })
    }

    private func insecureLoopbackBinding(
        _ proposalID: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                model
                    .insecureLoopbackDevelopmentHTTP
                    .contains(proposalID)
            },
            set: { enabled in
                if enabled {
                    model
                        .insecureLoopbackDevelopmentHTTP
                        .insert(proposalID)
                } else {
                    model
                        .insecureLoopbackDevelopmentHTTP
                        .remove(proposalID)
                }
            })
    }

    private var canCommit: Bool {
        guard let workspace = model.workspace,
              workspace.parsed.preview
                .canProceedToResolution,
              !env.mcp.isWorking,
              !model.isWorking else {
            return false
        }
        let skipped = Set(
            workspace.plan.conflicts.compactMap {
                model.resolutions[$0.proposalID]?
                    .choice == .skip
                    ? $0.proposalID : nil
            })
        for proposal in workspace.parsed.preview.proposals {
            if case .stdio = proposal.transport,
               !skipped.contains(proposal.proposalID) {
                let files =
                    model.launchClosures[
                        proposal.proposalID] ?? []
                guard !files.isEmpty,
                      files.count <= 256,
                      files.filter({
                          $0.role == .executable
                      }).count == 1,
                      files.allSatisfy({
                          $0.path
                              .trimmingCharacters(
                                  in: .whitespacesAndNewlines)
                              .hasPrefix("/")
                      }) else {
                    return false
                }
            }
        }
        for conflict in workspace.plan.conflicts {
            guard let value =
                    model.resolutions[
                        conflict.proposalID] else {
                return false
            }
            if value.choice == .rename,
               value.renamedAlias.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }
}
#endif
