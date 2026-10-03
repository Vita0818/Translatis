import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class SessionWorkspaceAccessFileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) throws -> SessionWorkspaceAccessFileLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SessionWorkspaceAccessStoreError.lockUnavailable
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw SessionWorkspaceAccessStoreError.lockUnavailable
        }
        return SessionWorkspaceAccessFileLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

public struct SessionWorkspaceAccessEntry: Codable, Equatable, Sendable {
    public var path: String
    public var bookmarkData: Data
    public var isPrimary: Bool

    public init(path: String, bookmarkData: Data, isPrimary: Bool = false) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.bookmarkData = bookmarkData
        self.isPrimary = isPrimary
    }
}

public struct SessionWorkspaceAccessDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionID: SessionID
    public var entries: [SessionWorkspaceAccessEntry]

    public init(schemaVersion: Int = SessionWorkspaceAccessDocument.currentSchemaVersion,
                sessionID: SessionID,
                entries: [SessionWorkspaceAccessEntry] = []) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case legacyVersion = "version"
        case sessionID, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyVersion)
            ?? 1
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        entries = try container.decodeIfPresent(
            [SessionWorkspaceAccessEntry].self,
            forKey: .entries) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(entries, forKey: .entries)
    }
}

public enum SessionWorkspaceAccessStoreError: Error, LocalizedError, Equatable, Sendable {
    case sessionMismatch
    case unsupportedVersion
    case invalidPath
    case multiplePrimaryEntries
    case primaryEntryRemovalForbidden
    case lockUnavailable
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .sessionMismatch:
            return "The workspace access file belongs to another session."
        case .unsupportedVersion:
            return "The workspace access file uses an unsupported version."
        case .invalidPath:
            return "The workspace access file contains an invalid workspace path."
        case .multiplePrimaryEntries:
            return "The workspace access file contains more than one primary workspace."
        case .primaryEntryRemovalForbidden:
            return "The primary workspace capability cannot be removed outside explicit session rollback."
        case .lockUnavailable:
            return "The workspace access file is busy or its lock cannot be opened."
        case .verificationFailed:
            return "The workspace access file could not be verified after writing."
        }
    }
}

/// Stores opaque Apple security-scoped bookmark bytes with the session that
/// owns them. This file is capability material, not an EventLog payload or a
/// `session.json` projection, and is therefore owner-readable only.
public enum SessionWorkspaceAccessStore {
    public static let fileName = "workspace-access.plist"

    public static func fileURL(root: URL, session: SessionID) throws -> URL {
        try SessionHistoryStore.sessionDirectory(root: root, session: session)
            .appendingPathComponent(fileName)
    }

    public static func load(root: URL,
                            session: SessionID) throws -> SessionWorkspaceAccessDocument? {
        let url = try fileURL(root: root, session: session)
        let lock = try SessionWorkspaceAccessFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        return try loadUnlocked(from: url, session: session)
    }

    @discardableResult
    public static func save(_ document: SessionWorkspaceAccessDocument,
                            root: URL) throws -> SessionWorkspaceAccessDocument {
        try validate(document, expectedSession: document.sessionID)
        let normalizedDocument = normalized(document)
        let url = try fileURL(root: root, session: document.sessionID)
        let lock = try SessionWorkspaceAccessFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        return try saveUnlocked(normalizedDocument, to: url)
    }

    @discardableResult
    public static func upsert(root: URL,
                              session: SessionID,
                              entry: SessionWorkspaceAccessEntry) throws -> SessionWorkspaceAccessDocument {
        let url = try fileURL(root: root, session: session)
        let lock = try SessionWorkspaceAccessFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        var document = try loadUnlocked(from: url, session: session)
            ?? SessionWorkspaceAccessDocument(sessionID: session)
        var normalizedEntry = SessionWorkspaceAccessEntry(
            path: entry.path,
            bookmarkData: entry.bookmarkData,
            isPrimary: entry.isPrimary)
        // Refreshing an existing bookmark without an explicit promotion must
        // not demote the current primary workspace. A primary changes only
        // when another entry is explicitly upserted with `isPrimary: true`.
        if let existing = document.entries.first(where: { $0.path == normalizedEntry.path }),
           existing.isPrimary,
           !normalizedEntry.isPrimary {
            normalizedEntry.isPrimary = true
        }
        if normalizedEntry.isPrimary {
            for index in document.entries.indices {
                document.entries[index].isPrimary = false
            }
        }
        if let index = document.entries.firstIndex(where: { $0.path == normalizedEntry.path }) {
            document.entries[index] = normalizedEntry
        } else {
            document.entries.append(normalizedEntry)
        }
        return try saveUnlocked(normalized(document), to: url)
    }

    public static func entry(root: URL,
                             session: SessionID,
                             path: String) throws -> SessionWorkspaceAccessEntry? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let url = try fileURL(root: root, session: session)
        let lock = try SessionWorkspaceAccessFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        return try loadUnlocked(from: url, session: session)?.entries.first {
            $0.path == normalizedPath
        }
    }

    @discardableResult
    public static func remove(root: URL,
                              session: SessionID,
                              path: String,
                              allowPrimaryRemoval: Bool = false) throws -> SessionWorkspaceAccessDocument? {
        let url = try fileURL(root: root, session: session)
        let lock = try SessionWorkspaceAccessFileLock.acquire(at: lockURL(for: url))
        defer { lock.release() }
        guard var document = try loadUnlocked(from: url, session: session) else { return nil }
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if !allowPrimaryRemoval,
           document.entries.contains(where: {
               $0.path == normalizedPath && $0.isPrimary
           }) {
            throw SessionWorkspaceAccessStoreError.primaryEntryRemovalForbidden
        }
        document.entries.removeAll { $0.path == normalizedPath }
        return try saveUnlocked(normalized(document), to: url)
    }

    private static func validate(_ document: SessionWorkspaceAccessDocument,
                                 expectedSession: SessionID) throws {
        guard document.sessionID == expectedSession else {
            throw SessionWorkspaceAccessStoreError.sessionMismatch
        }
        guard document.schemaVersion == SessionWorkspaceAccessDocument.currentSchemaVersion else {
            throw SessionWorkspaceAccessStoreError.unsupportedVersion
        }
        guard document.entries.allSatisfy({ entry in
            !entry.path.isEmpty
                && entry.path.hasPrefix("/")
                && !entry.bookmarkData.isEmpty
        }) else {
            throw SessionWorkspaceAccessStoreError.invalidPath
        }
        guard document.entries.filter(\.isPrimary).count <= 1 else {
            throw SessionWorkspaceAccessStoreError.multiplePrimaryEntries
        }
    }

    private static func lockURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("lock")
    }

    private static func loadUnlocked(
        from url: URL,
        session: SessionID
    ) throws -> SessionWorkspaceAccessDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let document = try makeDecoder().decode(SessionWorkspaceAccessDocument.self, from: data)
        try validate(document, expectedSession: session)
        return normalized(document)
    }

    private static func saveUnlocked(
        _ document: SessionWorkspaceAccessDocument,
        to url: URL
    ) throws -> SessionWorkspaceAccessDocument {
        try validate(document, expectedSession: document.sessionID)
        let data = try makeEncoder().encode(document)
        try writeOwnerOnlyAtomically(data, to: url)
        guard let verified = try loadUnlocked(from: url, session: document.sessionID),
              verified == document else {
            throw SessionWorkspaceAccessStoreError.verificationFailed
        }
        return verified
    }

    private static func writeOwnerOnlyAtomically(_ data: Data, to url: URL) throws {
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: url,
                temporaryPrefix: ".workspace-access-")
        } catch {
            throw SessionWorkspaceAccessStoreError.verificationFailed
        }
    }

    private static func normalized(
        _ document: SessionWorkspaceAccessDocument
    ) -> SessionWorkspaceAccessDocument {
        var result = document
        var entriesByPath: [String: SessionWorkspaceAccessEntry] = [:]
        for entry in result.entries {
            let normalizedEntry = SessionWorkspaceAccessEntry(
                path: entry.path,
                bookmarkData: entry.bookmarkData,
                isPrimary: entry.isPrimary)
            entriesByPath[normalizedEntry.path] = normalizedEntry
        }
        result.entries = entriesByPath.values.sorted { $0.path < $1.path }
        return result
    }

    private static func makeEncoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }

    private static func makeDecoder() -> PropertyListDecoder {
        PropertyListDecoder()
    }
}
