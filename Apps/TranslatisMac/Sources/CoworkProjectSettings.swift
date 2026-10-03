#if canImport(SwiftUI)
import SwiftUI
import Foundation
import IntatisCore
import IntatisConversation
import IntatisCowork
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisSharedUI

typealias CoworkProjectWorkspace = CoworkSessionWorkspace
typealias CoworkProjectSettings = CoworkSessionSettings

extension CoworkSessionSettings {

    static func fresh(sessionID: SessionID,
                      primaryWorkspace: URL,
                      catalog: AppProviderCatalog,
                      defaultInferenceProfileBinding: AgentInferenceBinding? = nil,
                      inferenceCatalogSnapshot: InferenceCatalogSnapshot? = nil) -> CoworkProjectSettings {
        CoworkProjectSettings(
            sessionID: sessionID,
            defaultProviderID: catalog.selectedProviderID,
            defaultModelID: catalog.selectedModelID,
            defaultInferenceProfileBinding: defaultInferenceProfileBinding
                ?? inferenceCatalogSnapshot.flatMap {
                    AppInferenceCatalogCompiler.selectedBinding(catalog: catalog, snapshot: $0)
                },
            workspaces: [
                CoworkProjectWorkspace(
                    path: primaryWorkspace.standardizedFileURL.path,
                    agentName: "main",
                    isPrimary: true)
            ],
            codexRuntimeGeneration:
                CoworkSessionSettings.currentCodexRuntimeGeneration)
    }

    static func restored(sessionID: SessionID,
                         catalog: AppProviderCatalog,
                         inferenceCatalogSnapshot: InferenceCatalogSnapshot? = nil) -> CoworkProjectSettings {
        CoworkProjectSettings(
            sessionID: sessionID,
            defaultProviderID: catalog.selectedProviderID,
            defaultModelID: catalog.selectedModelID,
            defaultInferenceProfileBinding: inferenceCatalogSnapshot.flatMap {
                AppInferenceCatalogCompiler.selectedBinding(catalog: catalog, snapshot: $0)
            })
    }

    var defaultProfile: PermissionProfile {
        PermissionProfile(rawValue: defaultPermissionProfile) ?? .reviewed
    }

    var primaryWorkspace: CoworkProjectWorkspace? {
        workspaces.first(where: \.isPrimary) ?? workspaces.first
    }

    mutating func upsertWorkspace(path: String,
                                  agentName: String?,
                                  isPrimary: Bool = false) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if isPrimary {
            for index in workspaces.indices {
                workspaces[index].isPrimary = false
            }
        }
        if let index = workspaces.firstIndex(where: {
            Self.storedWorkspacePath($0.path) == normalizedPath
        }) {
            workspaces[index].path = normalizedPath
            // One path can be used by a project entry and any number of
            // agents. `agentName` is therefore an optional *exclusive* owner,
            // not a last-writer-wins roster projection. Once a second owner
            // (or a project-level entry) references the same path, retain the
            // path as shared metadata instead of attributing it to one agent.
            workspaces[index].agentName = Self.mergedWorkspaceOwner(
                workspaces[index].agentName,
                agentName)
            workspaces[index].isPrimary = isPrimary || workspaces[index].isPrimary
            return
        }
        workspaces.append(CoworkProjectWorkspace(
            path: normalizedPath,
            agentName: agentName,
            isPrimary: isPrimary))
    }

    mutating func removeWorkspace(path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        workspaces.removeAll { $0.path == normalizedPath }
    }

    mutating func removeWorkspaces(
        forAgent agentName: String,
        retainingPaths: Set<String> = []
    ) {
        let normalizedRetainingPaths = Set(retainingPaths.map(Self.storedWorkspacePath))
        workspaces = workspaces.compactMap { workspace in
            guard workspace.agentName == agentName else { return workspace }
            let path = Self.storedWorkspacePath(workspace.path)
            if workspace.isPrimary || normalizedRetainingPaths.contains(path) {
                var shared = workspace
                shared.agentName = nil
                return shared
            }
            return nil
        }
    }

    mutating func upsertCodexAgentProfile(
        _ profile: CoworkCodexAgentProfile
    ) {
        if let index = codexAgentProfiles.firstIndex(where: {
            $0.roleName == profile.roleName
        }) {
            codexAgentProfiles[index] = profile
        } else {
            codexAgentProfiles.append(profile)
            codexAgentProfiles.sort {
                $0.roleName.localizedStandardCompare($1.roleName)
                    == .orderedAscending
            }
        }
    }

    mutating func removeCodexAgentProfile(roleName: String) {
        codexAgentProfiles.removeAll { $0.roleName == roleName }
    }

    /// Replaces only aliases whose canonical identity was already proven while
    /// their security scope was active. Collisions are merged as shared project
    /// metadata rather than assigning the path to whichever record was last.
    mutating func applyValidatedWorkspacePathMappings(_ mappings: [String: String]) {
        guard !mappings.isEmpty else { return }
        var merged: [CoworkProjectWorkspace] = []
        for workspace in workspaces {
            var canonical = workspace
            let key = Self.storedWorkspacePath(workspace.path)
            canonical.path = mappings[key].map(Self.storedWorkspacePath) ?? key
            if let index = merged.firstIndex(where: { $0.path == canonical.path }) {
                merged[index].agentName = Self.mergedWorkspaceOwner(
                    merged[index].agentName,
                    canonical.agentName)
                merged[index].isPrimary = merged[index].isPrimary || canonical.isPrimary
                merged[index].addedAt = min(merged[index].addedAt, canonical.addedAt)
            } else {
                merged.append(canonical)
            }
        }
        workspaces = merged
    }

    private static func mergedWorkspaceOwner(_ existing: String?, _ incoming: String?) -> String? {
        guard let existing, let incoming, existing == incoming else { return nil }
        return existing
    }

    private static func storedWorkspacePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum CoworkProjectSettingsStore {
    struct LoadResult {
        var settings: CoworkProjectSettings
        var warning: String?
        /// True only after the exact legacy inference binding has been written
        /// to EventLog and the matching migration marker was read back. This
        /// prevents workspace-bookmark migration from deleting unresolved
        /// provider/model evidence.
        var legacySettingsCleanupEligible: Bool
    }

    static func loadAndMigrate(
        sessionID: SessionID,
        log: EventLog,
        inferenceCatalogSnapshot: InferenceCatalogSnapshot? = nil
    ) async -> LoadResult {
        let document: SessionProjectionDocument
        do {
            // Capture and durably migrate a projection-only legacy name before
            // any schema-v2 rebuild can replace the old session.json. This is
            // the Cowork equivalent of the Chat/Code startup migration path.
            document = try await SessionProjectionStore.migrateLegacyDisplayName(
                in: log,
                kind: .cowork)
        } catch {
            let fallback: CoworkProjectSettings
            let legacyWarning: String?
            do {
                fallback = try legacySettings(
                    sessionID: sessionID,
                    inferenceCatalogSnapshot: inferenceCatalogSnapshot)
                    ?? recoveredSettings(sessionID: sessionID, document: nil)
                legacyWarning = nil
            } catch {
                fallback = recoveredSettings(sessionID: sessionID, document: nil)
                legacyWarning = " " + IntatisLocalization.format(
                    "Legacy settings were retained but could not be decoded safely: %@",
                    error.localizedDescription)
            }
            return LoadResult(
                settings: fallback,
                warning: IntatisLocalization.format(
                    "Session settings projection could not be rebuilt: %@",
                    error.localizedDescription) + (legacyWarning ?? ""),
                legacySettingsCleanupEligible: false)
        }
        if let canonical = document.coworkSettings {
            let hasVerifiedLegacyMigration = document.completedMigrations.contains {
                $0.migrationID == SessionProjectionStore.legacyCoworkSettingsMigrationID
            }
            return LoadResult(
                settings: normalized(
                    canonical,
                    sessionID: sessionID,
                    inferenceCatalogSnapshot: inferenceCatalogSnapshot),
                warning: nil,
                legacySettingsCleanupEligible:
                    hasVerifiedLegacyMigration
                    && canonical.defaultInferenceProfileBinding != nil)
        }

        let legacy: CoworkProjectSettings?
        do {
            legacy = try legacySettings(
                sessionID: sessionID,
                inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        } catch {
            // A present-but-invalid legacy value is not equivalent to absence.
            // Keep it untouched and do not manufacture canonical state from a
            // current global selection.
            return LoadResult(
                settings: recoveredSettings(sessionID: sessionID, document: document),
                warning: "Legacy session settings could not be migrated safely and were retained: \(error.localizedDescription)",
                legacySettingsCleanupEligible: false)
        }
        let settings = legacy
            ?? recoveredSettings(sessionID: sessionID, document: document)
        if legacy != nil, settings.defaultInferenceProfileBinding == nil {
            return LoadResult(
                settings: settings,
                warning: "Legacy session settings were retained because their provider/model cannot be resolved to an exact inference profile yet.",
                legacySettingsCleanupEligible: false)
        }
        do {
            let migrated: SessionProjectionDocument
            if legacy != nil {
                migrated = try await SessionProjectionStore.migrateLegacyCoworkSettings(
                    in: log,
                    settings: settings,
                    displayName: document.displayName)
            } else {
                migrated = try await SessionProjectionStore.updateSettings(
                    in: log,
                    kind: .cowork,
                    coworkSettings: settings,
                    displayName: document.displayName,
                    changeKind: .migrated)
            }
            guard let canonical = migrated.coworkSettings else {
                return LoadResult(
                    settings: settings,
                    warning: "Session settings migration did not produce a canonical snapshot.",
                    legacySettingsCleanupEligible: false)
            }
            return LoadResult(
                settings: canonical,
                warning: nil,
                legacySettingsCleanupEligible:
                    legacy != nil
                    && canonical.defaultInferenceProfileBinding != nil
                    && migrated.completedMigrations.contains {
                        $0.migrationID == SessionProjectionStore.legacyCoworkSettingsMigrationID
                    })
        } catch {
            // Compatibility fallback is intentional: the old key remains and
            // the next open can retry the same idempotent migration.
            return LoadResult(
                settings: settings,
                warning: "Legacy session settings are in use because migration failed: \(error.localizedDescription)",
                legacySettingsCleanupEligible: false)
        }
    }

    static func primaryWorkspacePath(sessionID: SessionID) -> String? {
        let projectionURL = AppConfig.appSupportDir()
            .appendingPathComponent(sessionID.rawValue, isDirectory: true)
            .appendingPathComponent(SessionProjectionStore.fileName)
        if let document = try? SessionProjectionStore.load(
            from: projectionURL,
            expectedSession: sessionID),
           let path = document.coworkSettings?.primaryWorkspace?.path {
            return path
        }
        if let data = UserDefaults.standard.data(forKey: key(sessionID)),
           let decoded = try? decoder.decode(CoworkProjectSettings.self, from: data) {
            return decoded.primaryWorkspace?.path ?? WorkspaceAccess.workspacePath(for: sessionID)
        }
        return WorkspaceAccess.workspacePath(for: sessionID)
    }

    static func remove(sessionID: SessionID) {
        UserDefaults.standard.removeObject(forKey: key(sessionID))
    }

    /// Returns only the concrete workspace paths that a validated legacy
    /// settings record assigned to this session. Callers may use this set to
    /// authorize a one-time lookup in the old process-global bookmark map;
    /// the mere presence of any legacy record is deliberately insufficient.
    static func legacyOwnedWorkspacePaths(sessionID: SessionID) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)),
              let decoded = try? decoder.decode(CoworkProjectSettings.self, from: data) else {
            return []
        }
        guard decoded.sessionID == sessionID,
              decoded.schemaVersion <= CoworkSessionSettings.currentSchemaVersion,
              decoded.workspaces.allSatisfy({ NSString(string: $0.path).isAbsolutePath }) else {
            return []
        }
        return Set(decoded.workspaces.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
    }

    static func clearLegacyStorage(sessionID: SessionID) {
        UserDefaults.standard.removeObject(forKey: key(sessionID))
    }

    private static func key(_ sessionID: SessionID) -> String {
        IntatisHostApplication.identity.userDefaultsKey(
            "cowork.projectSettings.\(sessionID.rawValue)")
    }

    private static func legacySettings(
        sessionID: SessionID,
        inferenceCatalogSnapshot: InferenceCatalogSnapshot?
    ) throws -> CoworkProjectSettings? {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)) else {
            return nil
        }
        let decoded = try decoder.decode(CoworkProjectSettings.self, from: data)
        guard decoded.sessionID == sessionID else {
            throw IntatisError.config("Legacy Cowork settings belong to another session.")
        }
        guard decoded.schemaVersion <= CoworkSessionSettings.currentSchemaVersion else {
            throw IntatisError.config("Legacy Cowork settings use a newer unsupported schema.")
        }
        guard decoded.workspaces.allSatisfy({ NSString(string: $0.path).isAbsolutePath }) else {
            throw IntatisError.config("Legacy Cowork settings contain a non-absolute workspace path.")
        }
        return normalized(
            decoded,
            sessionID: sessionID,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
    }

    private static func recoveredSettings(
        sessionID: SessionID,
        document: SessionProjectionDocument?
    ) -> CoworkProjectSettings {
        let main = document?.agentRegistrations.first(where: {
            $0.agent == Orchestrator.mainAgentID
        })
        let registrations = (document?.agentRegistrations ?? [])
            .filter { $0.agent != Orchestrator.automaticPermissionReviewerID }
            .sorted { lhs, rhs in
                if lhs.agent == Orchestrator.mainAgentID { return true }
                if rhs.agent == Orchestrator.mainAgentID { return false }
                return lhs.agent.rawValue < rhs.agent.rawValue
            }
        var seenPaths: Set<String> = []
        let workspaces = registrations.compactMap { registration -> CoworkProjectWorkspace? in
            let path = URL(fileURLWithPath: registration.path).standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return nil }
            return CoworkProjectWorkspace(
                path: path,
                agentName: registration.agent.rawValue,
                isPrimary: registration.agent == Orchestrator.mainAgentID)
        }
        return CoworkProjectSettings(
            sessionID: sessionID,
            mainAgentName: Orchestrator.mainAgentID.rawValue,
            defaultModelID: main?.model.rawValue,
            defaultInferenceProfileBinding: main?.agentInferenceBinding,
            defaultPermissionProfile: main?.profile ?? PermissionProfile.reviewed.rawValue,
            workspaces: workspaces)
    }

    private static func normalized(
        _ value: CoworkProjectSettings,
        sessionID: SessionID,
        inferenceCatalogSnapshot: InferenceCatalogSnapshot?
    ) -> CoworkProjectSettings {
        var settings = value
        settings.schemaVersion = CoworkSessionSettings.currentSchemaVersion
        settings.sessionID = sessionID
        if settings.mainAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.mainAgentName = Orchestrator.mainAgentID.rawValue
        }
        if settings.defaultInferenceProfileBinding == nil,
           let snapshot = inferenceCatalogSnapshot,
           let providerID = settings.defaultProviderID,
           let modelID = settings.defaultModelID {
            settings.defaultInferenceProfileBinding = AppInferenceCatalogCompiler.binding(
                providerID: providerID,
                modelID: modelID,
                variantID: nil,
                snapshot: snapshot)
        }
        return settings
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct CoworkProjectSettingsSheet: View {
    @ObservedObject var vm: CoworkViewModel
    let catalog: AppProviderCatalog
    let inferenceProfileOptions: [AppInferenceProfileOption]
    let onAddWorkspace: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var draft: CoworkProjectSettings
    @State private var tokenBudgetText: String
    @State private var settingsError: String?
    @State private var isSaving = false

    init(vm: CoworkViewModel,
         catalog: AppProviderCatalog,
         inferenceCatalogSnapshot: InferenceCatalogSnapshot? = nil,
         inferenceProfileOptions explicitInferenceProfileOptions: [AppInferenceProfileOption]? = nil,
         onAddWorkspace: @escaping () -> Void) {
        self.vm = vm
        self.catalog = catalog
        let resolvedInferenceProfileOptions = explicitInferenceProfileOptions ?? inferenceCatalogSnapshot.map {
            AppInferenceCatalogCompiler.options(catalog: catalog, snapshot: $0)
        } ?? []
        self.inferenceProfileOptions = resolvedInferenceProfileOptions
        self.onAddWorkspace = onAddWorkspace
        var initialDraft = vm.projectSettings
        if initialDraft.defaultInferenceProfileBinding == nil {
            if let snapshot = inferenceCatalogSnapshot,
               let providerID = initialDraft.defaultProviderID,
               let modelID = initialDraft.defaultModelID {
                initialDraft.defaultInferenceProfileBinding = AppInferenceCatalogCompiler.binding(
                    providerID: providerID,
                    modelID: modelID,
                    variantID: nil,
                    snapshot: snapshot)
            } else if let providerID = initialDraft.defaultProviderID,
                      let modelID = initialDraft.defaultModelID {
                initialDraft.defaultInferenceProfileBinding = resolvedInferenceProfileOptions.first {
                    $0.providerID == providerID
                        && $0.modelID == modelID
                        && $0.variantID == nil
                }?.binding
            }
        }
        _draft = State(initialValue: initialDraft)
        _tokenBudgetText = State(initialValue: vm.projectSettings.tokenBudget.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cowork Project")
                        .font(IntatisTypography.system(.headline))
                    Text(vm.sessionID.rawValue)
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            settingsGrid

            agentInferenceSection

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Workspaces")
                        .font(IntatisTypography.system(.caption, bold: true))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: addWorkspace) {
                        Label("Add Directory", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.isRuntimeMutationBlocked)
                }
                workspaceList
            }

            recoveryActionsSection

            if let settingsError {
                Text(settingsError)
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 780)
        .onChange(of: vm.projectSettings) { updated in
            draft = updated
            tokenBudgetText = updated.tokenBudget.map(String.init) ?? ""
        }
    }

    private var ordinaryAgents: [CoworkAgentInfo] {
        vm.agents.filter { agent in
            agent.isAttached && agent.name != "permission-reviewer"
                && !vm.projectSettings.codexAgentProfiles.contains(where: {
                    $0.roleName == agent.role
                })
        }
    }

    @ViewBuilder private var agentInferenceSection: some View {
        if !ordinaryAgents.isEmpty
            || !vm.projectSettings.codexAgentProfiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Agent inference profiles")
                        .font(IntatisTypography.system(.caption, bold: true))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Rebind applies after the current invocation boundary")
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.projectSettings.codexAgentProfiles) { profile in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(profile.roleName) · Codex role")
                                .font(IntatisTypography.system(
                                    .caption,
                                    bold: true))
                            Text(inferenceProfileOptions.first(where: {
                                $0.binding == profile.inferenceBinding
                            })?.title
                                ?? IntatisLocalization.string(
                                    "Saved inference profile"))
                                .font(IntatisTypography.system(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        Menu("Rebind…") {
                            ForEach(inferenceProfileOptions) { option in
                                Button(option.title) {
                                    vm.rebindAgentInferenceProfile(
                                        name: profile.roleName,
                                        binding: option.binding)
                                }
                                .disabled(
                                    profile.inferenceBinding
                                        == option.binding)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(
                            vm.isRuntimeMutationBlocked
                                || inferenceProfileOptions.isEmpty)
                        .accessibilityIdentifier(
                            "cowork.codex-role.\(profile.roleName).rebind")
                    }
                    .padding(8)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous)
                            .stroke(
                                TranslatisTheme.separator(scheme),
                                lineWidth: 1)
                    }
                }
                ForEach(ordinaryAgents) { agent in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(agent.name)")
                                .font(IntatisTypography.system(.caption, bold: true))
                            Text(agent.inferenceDisplayLabel
                                ?? IntatisLocalization.string("Inference profile unavailable"))
                                .font(IntatisTypography.system(.caption2))
                                .foregroundStyle(agent.inferenceResolution.requiresAttention
                                    ? TranslatisTheme.accent(scheme)
                                    : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        Menu("Rebind…") {
                            ForEach(inferenceProfileOptions) { option in
                                Button(option.title) {
                                    vm.rebindAgentInferenceProfile(
                                        name: agent.name,
                                        binding: option.binding)
                                }
                                .disabled(vm.agentInferenceBinding(
                                    name: agent.name) == option.binding)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(vm.isRuntimeMutationBlocked || inferenceProfileOptions.isEmpty)
                        .accessibilityIdentifier("cowork.agent.\(agent.id).rebind")
                    }
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var recoveryActionsSection: some View {
        if vm.needsPrimaryWorkspaceAuthorization || vm.permissionReviewerStatus.canRetry {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recovery")
                    .font(IntatisTypography.system(.caption, bold: true))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if vm.needsPrimaryWorkspaceAuthorization {
                        Button("Reauthorize Workspace") {
                            dismiss()
                            DispatchQueue.main.async {
                                vm.reauthorizePrimaryWorkspace()
                            }
                        }
                        .accessibilityIdentifier("cowork.workspace.reauthorize")
                    }
                    if vm.permissionReviewerStatus.canRetry {
                        Button("Retry Automatic Review") {
                            vm.retryAutomaticPermissionReview()
                        }
                        .accessibilityIdentifier("cowork.permission-reviewer.retry")
                    }
                }
            }
            .padding(12)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
            }
        }
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            formRow("Main agent") {
                Text("@\(draft.mainAgentName)")
                    .font(IntatisTypography.system(.body, weight: .medium))
                    .foregroundStyle(.primary)
            }
            formRow("Default inference profile (new agents)") {
                VStack(alignment: .leading, spacing: 4) {
                    if inferenceProfileOptions.isEmpty {
                        legacyModelPicker
                        Text("Exact inference profiles are unavailable; the legacy provider/model default is retained.")
                            .font(IntatisTypography.system(.caption2))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("", selection: inferenceProfileSelectionBinding) {
                            if let retained = retainedDefaultBinding,
                               !inferenceProfileOptions.contains(where: { $0.id == retained.key }) {
                                Text(retained.title).tag(retained.key)
                            }
                            ForEach(inferenceProfileOptions) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 360, alignment: .leading)
                    }
                }
            }
            formRow("Default permission") {
                Picker("", selection: $draft.defaultPermissionProfile) {
                    ForEach(permissionOptions, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
            formRow("Soft token budget") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Unlimited", text: $tokenBudgetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Text("Reserved before each request; provider tokenization and output-limit support may vary.")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
        }
    }

    private func formRow<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(IntatisLocalization.string(title))
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(.secondary)
                .frame(width: 210, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var workspaceList: some View {
        if vm.project.workspaces.isEmpty {
            Text("No workspace directories")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 7) {
                ForEach(vm.project.workspaces) { workspace in
                    HStack(spacing: 9) {
                        Image(systemName: workspace.isPrimary ? "house" : "folder")
                            .foregroundStyle(workspace.isPrimary ? TranslatisTheme.accent(scheme) : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.displayName)
                                .font(IntatisTypography.system(.caption, bold: true))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(workspace.path)
                                .font(IntatisTypography.system(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if let agentName = workspace.agentName {
                            Text("@\(agentName)")
                                .font(IntatisTypography.system(.caption2, bold: true))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            remove(workspace)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!workspace.canRemove || vm.isRuntimeMutationBlocked)
                        .help(workspace.canRemove
                            ? IntatisLocalization.string("Remove workspace")
                            : IntatisLocalization.format(
                                "Primary workspace is kept with @%@",
                                draft.mainAgentName))
                    }
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var inferenceProfileSelectionBinding: Binding<String> {
        Binding(
            get: {
                if let binding = draft.defaultInferenceProfileBinding {
                    return bindingSelectionKey(binding)
                }
                return legacyMatchingOption?.id ?? inferenceProfileOptions.first?.id ?? ""
            },
            set: { value in
                guard let option = inferenceProfileOptions.first(where: { $0.id == value }) else {
                    return
                }
                draft.defaultInferenceProfileBinding = option.binding
                // Keep these fields as a compatibility mirror for older builds.
                draft.defaultProviderID = option.providerID
                draft.defaultModelID = option.modelID
            })
    }

    private var legacyMatchingOption: AppInferenceProfileOption? {
        guard let providerID = draft.defaultProviderID,
              let modelID = draft.defaultModelID else {
            return nil
        }
        return inferenceProfileOptions.first {
            $0.providerID == providerID && $0.modelID == modelID && $0.variantID == nil
        }
    }

    private var retainedDefaultBinding: (key: String, title: String)? {
        guard let binding = draft.defaultInferenceProfileBinding else { return nil }
        return (
            bindingSelectionKey(binding),
            IntatisLocalization.string("Saved inference profile (retained revision)"))
    }

    private func bindingSelectionKey(_ binding: AgentInferenceBinding) -> String {
        let ref = binding.inferenceProfileRef
        return "\(ref.inferenceProfileID.rawValue)\u{001F}\(ref.inferenceProfileRevision.rawValue)"
    }

    private var legacyModelPicker: some View {
        Picker("", selection: modelSelectionBinding) {
            ForEach(catalog.providers) { provider in
                Section(AppInferenceCatalogCompiler.safeProviderTitle(provider)) {
                    ForEach(catalog.inferenceModels(for: provider)) { model in
                        Text(AppInferenceCatalogCompiler.safeModelTitle(model))
                            .tag(modelSelectionKey(providerID: provider.id, modelID: model.id))
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: {
                modelSelectionKey(
                    providerID: draft.defaultProviderID ?? catalog.selectedProviderID,
                    modelID: draft.defaultModelID ?? catalog.selectedModelID)
            },
            set: { value in
                let parts = value.components(separatedBy: "::")
                guard parts.count >= 2 else { return }
                draft.defaultProviderID = parts[0]
                draft.defaultModelID = parts.dropFirst().joined(separator: "::")
            })
    }

    private func modelSelectionKey(providerID: String, modelID: String) -> String {
        "\(providerID)::\(modelID)"
    }

    private var permissionOptions: [(rawValue: String, title: String)] {
        [
            (PermissionProfile.reviewed.rawValue, IntatisLocalization.string("Reviewed")),
            (PermissionProfile.manual.rawValue, IntatisLocalization.string("Manual")),
            (PermissionProfile.readOnly.rawValue, IntatisLocalization.string("Read only")),
            (PermissionProfile.locked.rawValue, IntatisLocalization.string("Locked")),
        ]
    }

    private func addWorkspace() {
        dismiss()
        onAddWorkspace()
    }

    private func remove(_ workspace: CoworkWorkspaceInfo) {
        if let agentName = workspace.agentName {
            if vm.projectSettings.codexAgentProfiles.contains(where: {
                $0.roleName == agentName
            }) {
                vm.removeCodexAgentProfile(name: agentName)
            } else {
                vm.removeAgent(name: agentName)
            }
        } else {
            vm.removeWorkspace(path: workspace.path)
        }
    }

    private func save() {
        let trimmed = tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft.tokenBudget = nil
        } else if let value = Int(trimmed), value > 0 {
            draft.tokenBudget = value
        } else {
            settingsError = IntatisLocalization.string(
                "Soft token budget must be empty or a positive integer.")
            return
        }
        settingsError = nil
        isSaving = true
        Task { @MainActor in
            let saved = await vm.updateProjectSettings(draft)
            isSaving = false
            if saved {
                dismiss()
            } else {
                settingsError = vm.composerError
                    ?? IntatisLocalization.string("Session settings could not be saved.")
            }
        }
    }
}
#endif
