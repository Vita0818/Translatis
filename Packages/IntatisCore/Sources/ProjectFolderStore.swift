import Foundation

/// A reference from one folder project to an existing Intatis conversation.
/// The referenced session keeps its own directory, EventLog, runtime key, and
/// workspace capability lifecycle.
public struct ProjectConversationReference: Codable, Hashable, Sendable, Identifiable {
    public let sessionID: SessionID
    public let kind: SessionKind

    public init(sessionID: SessionID, kind: SessionKind) {
        self.sessionID = sessionID
        self.kind = kind
    }

    public var id: String {
        "\(kind.rawValue):\(sessionID.rawValue)"
    }
}

/// One mode-scoped user-selected folder plus same-kind conversations grouped
/// beneath it. The path is organizational metadata, not a workspace
/// capability; each Code or Cowork session still owns its own bookmark.
public struct ProjectFolderRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: ProjectID
    public let kind: SessionKind
    public let path: String
    public let createdAt: Date
    public let conversations: [ProjectConversationReference]

    public init(
        id: ProjectID,
        kind: SessionKind,
        path: String,
        createdAt: Date,
        conversations: [ProjectConversationReference] = []
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.createdAt = createdAt
        self.conversations = conversations
    }

    public var displayName: String {
        let name = URL(fileURLWithPath: path, isDirectory: true)
            .lastPathComponent
        return name.isEmpty ? path : name
    }
}

public struct ProjectFolderDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let projects: [ProjectFolderRecord]

    public init(version: Int = 1, projects: [ProjectFolderRecord]) {
        self.version = version
        self.projects = projects
    }
}

public enum ProjectFolderStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidDocument
    case invalidProject
    case projectNotFound
    case limitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "The project folder catalog is invalid or unsupported."
        case .invalidProject:
            return "The selected project folder is invalid."
        case .projectNotFound:
            return "The project folder is no longer registered."
        case .limitExceeded:
            return "The project folder catalog exceeds its supported size."
        }
    }
}

/// App-global, owner-only storage for the deliberately small folder-project
/// feature. This catalog is authoritative only for project grouping. Session
/// content and execution remain authoritative in each session's EventLog and
/// session-owned capability files.
public enum ProjectFolderStore {
    public static let currentVersion = 1

    private static let fileName = "projects-v1.plist"
    private static let lockName = "projects-v1.lock"
    private static let maximumFileBytes = 8 * 1_024 * 1_024
    private static let maximumProjects = 256
    private static let maximumConversations = 16_384
    private static let maximumPathCharacters = 4_096

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(root: URL) throws -> ProjectFolderDocument {
        try loadUnlocked(root: root)
    }

    /// Adds a new folder or returns the existing project for the same
    /// `{kind, canonical path}`. Re-adding never changes membership or ID.
    @discardableResult
    public static func add(
        root: URL,
        kind: SessionKind,
        path rawPath: String,
        now: Date = Date()
    ) throws -> ProjectFolderRecord {
        let path = try normalizedProjectPath(rawPath)
        return try mutate(root: root) { document in
            if let index = document.projects.firstIndex(where: {
                $0.kind == kind && $0.path == path
            }) {
                return document.projects[index]
            }
            guard document.projects.count < maximumProjects else {
                throw ProjectFolderStoreError.limitExceeded
            }
            let existingIDs = Set(document.projects.map(\.id))
            var id = ProjectID.new()
            var attempts = 0
            while existingIDs.contains(id), attempts < 32 {
                id = ProjectID.new()
                attempts += 1
            }
            guard !existingIDs.contains(id) else {
                throw ProjectFolderStoreError.invalidProject
            }
            let project = ProjectFolderRecord(
                id: id,
                kind: kind,
                path: path,
                createdAt: now)
            document.projects.append(project)
            return project
        }
    }

    /// Associates a conversation with exactly one project. Re-association
    /// moves only the catalog reference; it never moves or rewrites session
    /// data on disk.
    @discardableResult
    public static func associate(
        root: URL,
        projectID: ProjectID,
        conversation: ProjectConversationReference
    ) throws -> ProjectFolderRecord {
        try validateConversation(conversation)
        return try mutate(root: root) { document in
            guard document.projects.contains(where: { $0.id == projectID }) else {
                throw ProjectFolderStoreError.projectNotFound
            }
            guard document.projects.first(where: { $0.id == projectID })?.kind
                    == conversation.kind else {
                throw ProjectFolderStoreError.invalidProject
            }
            let currentCount = document.projects.reduce(0) {
                $0 + $1.conversations.count
            }
            let alreadyPresent = document.projects.contains {
                $0.conversations.contains(conversation)
            }
            guard alreadyPresent || currentCount < maximumConversations else {
                throw ProjectFolderStoreError.limitExceeded
            }

            for index in document.projects.indices {
                let project = document.projects[index]
                let filtered = project.conversations.filter { $0 != conversation }
                guard filtered.count != project.conversations.count else { continue }
                document.projects[index] = ProjectFolderRecord(
                    id: project.id,
                    kind: project.kind,
                    path: project.path,
                    createdAt: project.createdAt,
                    conversations: filtered)
            }

            guard let targetIndex = document.projects.firstIndex(where: {
                $0.id == projectID
            }) else {
                throw ProjectFolderStoreError.projectNotFound
            }
            let target = document.projects[targetIndex]
            let updated = ProjectFolderRecord(
                id: target.id,
                kind: target.kind,
                path: target.path,
                createdAt: target.createdAt,
                conversations: target.conversations + [conversation])
            document.projects[targetIndex] = updated
            return updated
        }
    }

    public static func removeConversation(
        root: URL,
        conversation: ProjectConversationReference
    ) throws {
        try validateConversation(conversation)
        _ = try mutate(root: root) { document in
            for index in document.projects.indices {
                let project = document.projects[index]
                let filtered = project.conversations.filter { $0 != conversation }
                guard filtered.count != project.conversations.count else { continue }
                document.projects[index] = ProjectFolderRecord(
                    id: project.id,
                    kind: project.kind,
                    path: project.path,
                    createdAt: project.createdAt,
                    conversations: filtered)
            }
        }
    }

    /// Removes only the project grouping. The folder and all referenced
    /// session directories remain untouched.
    public static func remove(root: URL, projectID: ProjectID) throws {
        _ = try mutate(root: root) { document in
            guard let index = document.projects.firstIndex(where: {
                $0.id == projectID
            }) else {
                throw ProjectFolderStoreError.projectNotFound
            }
            document.projects.remove(at: index)
        }
    }

    private static func mutate<Result>(
        root: URL,
        _ body: (inout MutableDocument) throws -> Result
    ) throws -> Result {
        let lockURL = root.appendingPathComponent(lockName, isDirectory: false)
        return try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
            let loaded = try loadUnlocked(root: root)
            var mutable = MutableDocument(projects: loaded.projects)
            let result = try body(&mutable)
            let document = ProjectFolderDocument(
                version: currentVersion,
                projects: mutable.projects)
            try validate(document)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data: Data
            do {
                data = try encoder.encode(document)
            } catch {
                throw ProjectFolderStoreError.invalidDocument
            }
            guard data.count <= maximumFileBytes else {
                throw ProjectFolderStoreError.limitExceeded
            }
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: fileURL(root: root),
                temporaryPrefix: ".projects-")
            return result
        }
    }

    private static func loadUnlocked(root: URL) throws -> ProjectFolderDocument {
        let data: Data?
        do {
            data = try DurableOwnerOnlyFile.read(
                from: fileURL(root: root),
                maximumBytes: maximumFileBytes)
        } catch DurableOwnerOnlyFileError.fileTooLarge {
            throw ProjectFolderStoreError.limitExceeded
        } catch {
            throw error
        }
        guard let data else {
            return ProjectFolderDocument(
                version: currentVersion,
                projects: [])
        }
        let document: ProjectFolderDocument
        do {
            document = try PropertyListDecoder().decode(
                ProjectFolderDocument.self,
                from: data)
        } catch {
            do {
                let legacy = try PropertyListDecoder().decode(
                    LegacyProjectFolderDocument.self,
                    from: data)
                document = try migrateLegacyDocument(legacy)
            } catch {
                throw ProjectFolderStoreError.invalidDocument
            }
        }
        try validate(document)
        return document
    }

    private static func validate(_ document: ProjectFolderDocument) throws {
        guard document.version == currentVersion,
              document.projects.count <= maximumProjects else {
            throw ProjectFolderStoreError.invalidDocument
        }
        var projectIDs: Set<ProjectID> = []
        var scopedPaths: Set<ScopedProjectPath> = []
        var conversations: Set<ProjectConversationReference> = []
        var conversationCount = 0

        for project in document.projects {
            guard isSafeProjectID(project.id),
                  project.path == (try? normalizedProjectPath(project.path)),
                  project.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  projectIDs.insert(project.id).inserted,
                  scopedPaths.insert(ScopedProjectPath(
                      kind: project.kind,
                      path: project.path)).inserted else {
                throw ProjectFolderStoreError.invalidDocument
            }
            conversationCount += project.conversations.count
            guard conversationCount <= maximumConversations else {
                throw ProjectFolderStoreError.limitExceeded
            }
            for conversation in project.conversations {
                try validateConversation(conversation)
                guard conversation.kind == project.kind,
                      conversations.insert(conversation).inserted else {
                    throw ProjectFolderStoreError.invalidDocument
                }
            }
        }
    }

    private static func normalizedProjectPath(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty,
              rawPath.count <= maximumPathCharacters,
              NSString(string: rawPath).isAbsolutePath,
              rawPath.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ProjectFolderStoreError.invalidProject
        }
        let path = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL.path
        guard !path.isEmpty,
              path.count <= maximumPathCharacters else {
            throw ProjectFolderStoreError.invalidProject
        }
        return path
    }

    private static func isSafeProjectID(_ id: ProjectID) -> Bool {
        let value = id.rawValue
        return value.hasPrefix("project_")
            && value.count <= 96
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "_"
                        || scalar == "-")
            }
    }

    private static func validateConversation(
        _ conversation: ProjectConversationReference
    ) throws {
        let value = conversation.sessionID.rawValue
        guard !value.isEmpty,
              value.count <= 256,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ProjectFolderStoreError.invalidProject
        }
    }

    private struct MutableDocument {
        var projects: [ProjectFolderRecord]
    }

    private struct ScopedProjectPath: Hashable {
        let kind: SessionKind
        let path: String
    }

    private struct LegacyProjectFolderRecord: Codable {
        let id: ProjectID
        let path: String
        let createdAt: Date
        let conversations: [ProjectConversationReference]
    }

    private struct LegacyProjectFolderDocument: Codable {
        let version: Int
        let projects: [LegacyProjectFolderRecord]
    }

    /// Compatibility for the first unreleased global-project draft. Existing
    /// mixed records are deterministically split by SessionKind. An empty
    /// legacy record is assigned to Chat because no session fact exists from
    /// which another mode could be proven; users can add the same path to a
    /// different mode without conflict.
    private static func migrateLegacyDocument(
        _ legacy: LegacyProjectFolderDocument
    ) throws -> ProjectFolderDocument {
        guard legacy.version == currentVersion else {
            throw ProjectFolderStoreError.invalidDocument
        }
        var migrated: [ProjectFolderRecord] = []
        var usedIDs: Set<ProjectID> = []
        for project in legacy.projects {
            guard isSafeProjectID(project.id),
                  project.path == (try? normalizedProjectPath(project.path)),
                  project.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ProjectFolderStoreError.invalidDocument
            }
            for conversation in project.conversations {
                try validateConversation(conversation)
            }
            let presentKinds = SessionKind.allCases.filter { kind in
                project.conversations.contains(where: { $0.kind == kind })
            }
            let kinds = presentKinds.isEmpty ? [.chat] : presentKinds
            for (index, kind) in kinds.enumerated() {
                let id = index == 0
                    ? project.id
                    : ProjectID(rawValue: "\(project.id.rawValue)_\(kind.rawValue)")
                guard isSafeProjectID(id), usedIDs.insert(id).inserted else {
                    throw ProjectFolderStoreError.invalidDocument
                }
                migrated.append(ProjectFolderRecord(
                    id: id,
                    kind: kind,
                    path: project.path,
                    createdAt: project.createdAt,
                    conversations: project.conversations.filter {
                        $0.kind == kind
                    }))
            }
        }
        let document = ProjectFolderDocument(
            version: currentVersion,
            projects: migrated)
        try validate(document)
        return document
    }
}
