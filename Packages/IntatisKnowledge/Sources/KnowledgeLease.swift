import Foundation
import IntatisCore
import IntatisPermission
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum KnowledgeLeaseAccess: String, Codable, Hashable, Sendable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

public enum KnowledgeLeaseOperation: String, Codable, Hashable, Sendable {
    case search
    case build
    case update
}

public enum KnowledgeLeaseReuseScope: String, Codable, Hashable, Sendable {
    case turn
    case session
}

public enum KnowledgeAuthorizationReferenceKind: String, Codable, Hashable, Sendable {
    case workspaceLease = "workspace_lease"
    case macOSSecurityScopedBookmark = "macos_security_scoped_bookmark"
    case cliPermission = "cli_permission"
}

/// Exact-directory authority used only by the Knowledge reader/writer. It is
/// intentionally not a WorkspaceLease and cannot be supplied to generic file,
/// Git, terminal, document, browser, or MCP tools.
public struct KnowledgeLease: Codable, Hashable, Sendable {
    public let id: String
    public let revision: Int
    public let sessionID: SessionID
    public let agentID: AgentID
    public let taskID: TaskID?
    public let turnID: TurnID?
    public let reuseScope: KnowledgeLeaseReuseScope
    public let rootPath: String
    public let rootIdentity: WorkspaceRootIdentity
    public let access: KnowledgeLeaseAccess
    public let operations: Set<KnowledgeLeaseOperation>
    public let authorizationReferenceKind: KnowledgeAuthorizationReferenceKind
    /// Digest of the bookmark record or CLI permission record. Raw bookmark
    /// bytes and authorization payloads never enter this value.
    public let authorizationReferenceDigest: String
    public let expiresAt: Date?
    public let revocationGeneration: Int
    public let fingerprint: String

    private let projectedWorkspaceLeaseID: WorkspaceLeaseID
    private let projectedWorkspaceID: WorkspaceID

    public init(root: URL,
                sessionID: SessionID,
                agentID: AgentID,
                taskID: TaskID? = nil,
                turnID: TurnID? = nil,
                reuseScope: KnowledgeLeaseReuseScope = .turn,
                access: KnowledgeLeaseAccess,
                operations: Set<KnowledgeLeaseOperation>,
                authorizationReferenceKind: KnowledgeAuthorizationReferenceKind,
                authorizationReferenceDigest: String,
                revision: Int = 1,
                expiresAt: Date? = nil,
                revocationGeneration: Int = 0,
                id: String = "knowledge-lease-" + UUID().uuidString.lowercased()) throws {
        guard revision > 0,
              revocationGeneration >= 0,
              !operations.isEmpty,
              authorizationReferenceDigest.range(
                  of: #"^sha256:[0-9a-f]{64}$"#,
                  options: .regularExpression) != nil,
              id.range(
                  of: #"^knowledge-lease-[a-z0-9-]{8,96}$"#,
                  options: .regularExpression) != nil else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge lease metadata is invalid.")
        }
        if reuseScope == .turn, turnID == nil {
            throw KnowledgeDomainError(
                .accessDenied,
                "Turn-scoped knowledge authority requires an exact turn identity.")
        }
        if access == .readOnly,
           !operations.isSubset(of: [.search]) {
            throw KnowledgeDomainError(
                .accessDenied,
                "A read-only knowledge lease cannot grant build or update.")
        }
        let canonical = try Self.validateExistingRoot(root)
        guard let identity = WorkspaceRootIdentity.capture(
            rootPath: canonical.path) else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge directory identity is unavailable.")
        }
        struct FingerprintProjection: Codable {
            let schema: String
            let id: String
            let revision: Int
            let sessionID: SessionID
            let agentID: AgentID
            let taskID: TaskID?
            let turnID: TurnID?
            let reuseScope: KnowledgeLeaseReuseScope
            let rootIdentity: WorkspaceRootIdentity
            let access: KnowledgeLeaseAccess
            let operations: [KnowledgeLeaseOperation]
            let authorizationReferenceKind: KnowledgeAuthorizationReferenceKind
            let authorizationReferenceDigest: String
            let expiresAt: Date?
            let revocationGeneration: Int
        }
        let fingerprint = try KnowledgeDigest.canonical(FingerprintProjection(
            schema: KnowledgeHostIdentity.schema(
                "knowledge-lease/1"),
            id: id,
            revision: revision,
            sessionID: sessionID,
            agentID: agentID,
            taskID: taskID,
            turnID: turnID,
            reuseScope: reuseScope,
            rootIdentity: identity,
            access: access,
            operations: operations.sorted { $0.rawValue < $1.rawValue },
            authorizationReferenceKind: authorizationReferenceKind,
            authorizationReferenceDigest: authorizationReferenceDigest,
            expiresAt: expiresAt,
            revocationGeneration: revocationGeneration))

        self.id = id
        self.revision = revision
        self.sessionID = sessionID
        self.agentID = agentID
        self.taskID = taskID
        self.turnID = turnID
        self.reuseScope = reuseScope
        rootPath = identity.canonicalPath
        rootIdentity = identity
        self.access = access
        self.operations = operations
        self.authorizationReferenceKind = authorizationReferenceKind
        self.authorizationReferenceDigest = authorizationReferenceDigest
        self.expiresAt = expiresAt
        self.revocationGeneration = revocationGeneration
        self.fingerprint = fingerprint
        projectedWorkspaceLeaseID = WorkspaceLeaseID.new()
        projectedWorkspaceID = WorkspaceID.new()
    }

    public func validate(sessionID: SessionID,
                         agentID: AgentID,
                         taskID: TaskID?,
                         turnID: TurnID?,
                         operation: KnowledgeLeaseOperation,
                         now: Date = Date()) throws {
        guard self.sessionID == sessionID,
              self.agentID == agentID,
              self.taskID == nil || self.taskID == taskID,
              reuseScope == .session || self.turnID == turnID,
              operations.contains(operation),
              expiresAt.map({ $0 > now }) ?? true,
              rootIdentity.matchesCurrentDirectory(rootPath: rootPath),
              try Self.validateExistingRoot(URL(
                  fileURLWithPath: rootPath,
                  isDirectory: true)).path == rootPath else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge lease is expired, revoked, out of scope, or its directory identity changed.")
        }
        if operation != .search, access != .readWrite {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge mutation requires an exact read-write knowledge lease.")
        }
    }

    /// Safe durable/event projection. It deliberately omits the absolute path,
    /// bookmark bytes, and raw authorization reference.
    public var durableProjection: KnowledgeLeaseDurableProjection {
        KnowledgeLeaseDurableProjection(
            leaseID: id,
            revision: revision,
            reuseScope: reuseScope,
            access: access,
            operations: operations.sorted { $0.rawValue < $1.rawValue },
            rootFingerprint: KnowledgeDigest.sha256(rootPath),
            rootIdentityDigest: KnowledgeDigest.sha256(
                "\(rootIdentity.deviceID):\(rootIdentity.fileID)"),
            authorizationReferenceKind: authorizationReferenceKind,
            authorizationReferenceDigest: authorizationReferenceDigest,
            revocationGeneration: revocationGeneration,
            fingerprint: fingerprint)
    }

    /// Private projection for reusing hardened Knowledge filesystem/store code.
    /// It is module-internal so an external caller cannot turn Knowledge access
    /// into a general-purpose WorkspaceLease.
    func projectedStoreWorkspaceLease() -> WorkspaceLease {
        WorkspaceLease(
            id: projectedWorkspaceLeaseID,
            workspaceID: projectedWorkspaceID,
            taskID: taskID,
            rootPath: rootPath,
            rootIdentity: rootIdentity,
            access: access == .readWrite ? .readWrite : .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: WorkspaceLease.defaultDeniedPatterns,
            expiresAtTaskCompletion: reuseScope == .turn)
    }

    public static func validateRequestedPath(_ path: String) throws -> URL {
        guard NSString(string: path).isAbsolutePath,
              !path.contains("\0"),
              path.count <= 4_096 else {
            throw KnowledgeDomainError(
                .toolInputInvalid,
                "External knowledge paths must be bounded absolute paths.")
        }
        let standardized = URL(
            fileURLWithPath: path,
            isDirectory: true).standardizedFileURL
        try rejectBroadOrSensitive(standardized)
        var entry = stat()
        if lstat(standardized.path, &entry) == 0 {
            guard (entry.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "A symbolic link cannot be authorized as a knowledge directory.")
            }
        } else if errno != ENOENT {
            throw KnowledgeDomainError(
                .accessDenied,
                "The requested knowledge directory could not be inspected safely.")
        }
        // Canonicalize any existing ancestor (for example macOS /var ->
        // /private/var) before the exact path is reviewed and bound. The leaf
        // itself was checked with lstat above, so this does not turn a leaf
        // symlink into authority for its target.
        let canonical = standardized.resolvingSymlinksInPath()
            .standardizedFileURL
        try rejectBroadOrSensitive(canonical)
        return canonical
    }

    private static func validateExistingRoot(_ root: URL) throws -> URL {
        let requested = try validateRequestedPath(root.path)
        let canonical: URL
        do {
            canonical = try DurableOwnerOnlyFile.validateOwnedDirectory(at: requested)
        } catch {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge directory must be an existing, owner-controlled, no-follow directory.")
        }
        try rejectBroadOrSensitive(canonical)
        return canonical
    }

    private static func rejectBroadOrSensitive(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        let broadRoots = Set([
            "/", "/Users", "/home", "/Volumes", "/System", "/Library",
            "/Applications", "/usr", "/etc", "/var", "/tmp", "/private",
            "/private/var", "/private/tmp", "/Network", home,
        ])
        guard !broadRoots.contains(path),
              !SecretScanner.isSensitivePath(path),
              !PathConfinement.isSensitivePath(path) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "The requested knowledge directory is too broad or sensitive.")
        }
    }
}

public struct KnowledgeLeaseDurableProjection: Codable, Equatable, Sendable {
    public let leaseID: String
    public let revision: Int
    public let reuseScope: KnowledgeLeaseReuseScope
    public let access: KnowledgeLeaseAccess
    public let operations: [KnowledgeLeaseOperation]
    public let rootFingerprint: String
    public let rootIdentityDigest: String
    public let authorizationReferenceKind: KnowledgeAuthorizationReferenceKind
    public let authorizationReferenceDigest: String
    public let revocationGeneration: Int
    public let fingerprint: String
}
