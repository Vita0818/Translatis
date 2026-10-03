import Foundation
import IntatisCore

/// Secret-free workspace metadata owned by one Cowork session. Security-scoped
/// bookmark bytes are deliberately stored in `workspace-access.plist`, never
/// in EventLog or the derived `session.json` projection.
public struct CoworkSessionWorkspace: Identifiable, Codable, Equatable, Sendable {
    public var path: String
    public var agentName: String?
    public var isPrimary: Bool
    public var addedAt: Date

    public var id: String { path }

    public init(path: String,
                agentName: String? = nil,
                isPrimary: Bool = false,
                addedAt: Date = Date()) {
        self.path = path
        self.agentName = agentName
        self.isPrimary = isPrimary
        self.addedAt = addedAt
    }
}

/// One user-approved Codex custom-agent role for a Cowork session. This is a
/// secret-free definition: the immutable inference binding is resolved only
/// when the isolated runtime starts, and the workspace path still requires a
/// live session-owned security-scoped capability.
public struct CoworkCodexAgentProfile: Identifiable, Codable, Equatable,
    Sendable
{
    public var roleName: String
    public var description: String
    public var workspacePath: String
    public var inferenceBinding: AgentInferenceBinding
    public var permissionProfile: String
    public var addedAt: Date

    public var id: String { roleName }

    public init(
        roleName: String,
        description: String,
        workspacePath: String,
        inferenceBinding: AgentInferenceBinding,
        permissionProfile: String = "reviewed",
        addedAt: Date = Date()
    ) {
        self.roleName = roleName
        self.description = description
        self.workspacePath = workspacePath
        self.inferenceBinding = inferenceBinding
        self.permissionProfile = permissionProfile
        self.addedAt = addedAt
    }
}

/// The complete, versioned Cowork project settings snapshot. This is project
/// metadata only: it never grants a capability/workspace lease and contains no
/// endpoint, credential, header, query, or bookmark material.
public struct CoworkSessionSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentCodexRuntimeGeneration = "codex-native-v6"

    public var schemaVersion: Int
    public var sessionID: SessionID
    public var mainAgentName: String
    /// In-memory/legacy compatibility mirror only. Provider IDs are user
    /// supplied and may contain private route-like text, so canonical session
    /// encoding deliberately omits this field. Exact resolution uses the
    /// secret-free immutable inference binding instead.
    public var defaultProviderID: String?
    public var defaultModelID: String?
    public var defaultInferenceProfileBinding: AgentInferenceBinding?
    public var defaultPermissionProfile: String
    public var tokenBudget: Int?
    public var workspaces: [CoworkSessionWorkspace]
    public var codexAgentProfiles: [CoworkCodexAgentProfile]
    /// Durable admission marker for sessions created by the current native
    /// Codex Cowork runtime. Missing means legacy/unknown and must never be
    /// inferred as a fresh App Server thread from launch UI state.
    public var codexRuntimeGeneration: String?

    public init(schemaVersion: Int = CoworkSessionSettings.currentSchemaVersion,
                sessionID: SessionID,
                mainAgentName: String = "main",
                defaultProviderID: String? = nil,
                defaultModelID: String? = nil,
                defaultInferenceProfileBinding: AgentInferenceBinding? = nil,
                defaultPermissionProfile: String = "reviewed",
                tokenBudget: Int? = nil,
                workspaces: [CoworkSessionWorkspace] = [],
                codexAgentProfiles: [CoworkCodexAgentProfile] = [],
                codexRuntimeGeneration: String? = nil) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.mainAgentName = mainAgentName
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.defaultInferenceProfileBinding = defaultInferenceProfileBinding
        self.defaultPermissionProfile = defaultPermissionProfile
        self.tokenBudget = tokenBudget
        self.workspaces = workspaces
        self.codexAgentProfiles = codexAgentProfiles
        self.codexRuntimeGeneration = codexRuntimeGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, mainAgentName, defaultProviderID, defaultModelID
        case defaultInferenceProfileBinding, defaultPermissionProfile, tokenBudget, workspaces
        case codexAgentProfiles, codexRuntimeGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CoworkSessionSettings.currentSchemaVersion
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        mainAgentName = try container.decodeIfPresent(String.self, forKey: .mainAgentName) ?? "main"
        defaultProviderID = try container.decodeIfPresent(String.self, forKey: .defaultProviderID)
        defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID)
        defaultInferenceProfileBinding = try container.decodeIfPresent(
            AgentInferenceBinding.self,
            forKey: .defaultInferenceProfileBinding)
        defaultPermissionProfile = try container.decodeIfPresent(
            String.self,
            forKey: .defaultPermissionProfile) ?? "reviewed"
        tokenBudget = try container.decodeIfPresent(Int.self, forKey: .tokenBudget)
        workspaces = try container.decodeIfPresent(
            [CoworkSessionWorkspace].self,
            forKey: .workspaces) ?? []
        codexAgentProfiles = try container.decodeIfPresent(
            [CoworkCodexAgentProfile].self,
            forKey: .codexAgentProfiles) ?? []
        codexRuntimeGeneration = try container.decodeIfPresent(
            String.self,
            forKey: .codexRuntimeGeneration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(mainAgentName, forKey: .mainAgentName)
        // `defaultProviderID` intentionally remains decode-only.
        try container.encodeIfPresent(defaultModelID, forKey: .defaultModelID)
        try container.encodeIfPresent(
            defaultInferenceProfileBinding,
            forKey: .defaultInferenceProfileBinding)
        try container.encode(defaultPermissionProfile, forKey: .defaultPermissionProfile)
        try container.encodeIfPresent(tokenBudget, forKey: .tokenBudget)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(
            codexAgentProfiles,
            forKey: .codexAgentProfiles)
        try container.encodeIfPresent(
            codexRuntimeGeneration,
            forKey: .codexRuntimeGeneration)
    }
}

public enum SessionSettingsChangeKind: String, Codable, Equatable, Sendable {
    case created
    case updated
    case migrated
    case renamed
}

/// Identifies the host surface that explicitly changed the session's display
/// name. This is audit metadata only: it never changes SessionID, storage
/// paths, runtime ownership, or task recovery semantics.
public enum SessionDisplayNameSource: String, Codable, Equatable, Sendable {
    case userInterface = "user_interface"
    case modelTool = "model_tool"
}

/// Full-snapshot settings event. Full snapshots make replay deterministic and
/// keep migration/update code independent from historical in-memory defaults.
public struct SessionSettingsUpdatedPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: Int
    public var previousRevision: Int?
    public var changeKind: SessionSettingsChangeKind
    public var kind: SessionKind
    public var displayName: String?
    /// Optional additive idempotency key for an explicit rename operation.
    /// Manual UI renames may omit it; model-tool renames bind it to the exact
    /// durable tool execution so re-entering the same executor cannot
    /// append or overwrite another rename.
    public var renameOperationID: String?
    public var displayNameSource: SessionDisplayNameSource?
    public var cowork: CoworkSessionSettings?

    public init(schemaVersion: Int = SessionSettingsUpdatedPayload.currentSchemaVersion,
                revision: Int,
                previousRevision: Int? = nil,
                changeKind: SessionSettingsChangeKind,
                kind: SessionKind,
                displayName: String? = nil,
                renameOperationID: String? = nil,
                displayNameSource: SessionDisplayNameSource? = nil,
                cowork: CoworkSessionSettings? = nil) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.previousRevision = previousRevision
        self.changeKind = changeKind
        self.kind = kind
        self.displayName = displayName
        self.renameOperationID = renameOperationID
        self.displayNameSource = displayNameSource
        self.cowork = cowork
    }
}

public enum SessionStorageMigrationSource: String, Codable, Equatable, Sendable {
    case legacyCoworkUserDefaults = "legacy_cowork_user_defaults"
    case legacyWorkspaceUserDefaults = "legacy_workspace_user_defaults"
    case legacySessionMetadata = "legacy_session_metadata"
}

/// Idempotent marker for a completed compatibility migration. The stable
/// migration ID, rather than deletion of a legacy preference key, is the
/// canonical proof that retrying must not append the same migration again.
public struct SessionStorageMigratedPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var migrationID: String
    public var source: SessionStorageMigrationSource
    public var settingsRevision: Int?

    public init(schemaVersion: Int = SessionStorageMigratedPayload.currentSchemaVersion,
                migrationID: String,
                source: SessionStorageMigrationSource,
                settingsRevision: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.migrationID = migrationID
        self.source = source
        self.settingsRevision = settingsRevision
    }
}
