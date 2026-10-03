import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class SessionKnowledgeAccessFileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) throws -> SessionKnowledgeAccessFileLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SessionKnowledgeAccessStoreError.lockUnavailable
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            _ = close(descriptor)
            throw SessionKnowledgeAccessStoreError.lockUnavailable
        }
        return SessionKnowledgeAccessFileLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

public struct SessionKnowledgeAccessEntry: Codable, Equatable, Sendable {
    public let path: String
    public let bookmarkData: Data
    public let revision: Int
    public let authorizationReferenceDigest: String

    public init(path: String,
                bookmarkData: Data,
                revision: Int = 1,
                authorizationReferenceDigest: String) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.bookmarkData = bookmarkData
        self.revision = revision
        self.authorizationReferenceDigest = authorizationReferenceDigest
    }
}

public struct SessionKnowledgeAccessDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: SessionID
    public var entries: [SessionKnowledgeAccessEntry]

    public init(sessionID: SessionID,
                entries: [SessionKnowledgeAccessEntry] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.entries = entries
    }
}

public enum SessionKnowledgeAccessStoreError:
    Error, LocalizedError, Equatable, Sendable {
    case invalidDocument
    case lockUnavailable
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "The session knowledge capability file is invalid."
        case .lockUnavailable:
            return "The session knowledge capability file is busy or unsafe."
        case .verificationFailed:
            return "The session knowledge capability file could not be verified."
        }
    }
}

/// Session-owned binary plist for raw macOS knowledge bookmarks. It is not an
/// EventLog/session.json/config projection, is written 0600/no-follow, and is
/// read-merged under a cross-process lock.
public enum SessionKnowledgeAccessStore {
    public static let fileName = "knowledge-access.plist"

    public static func fileURL(root: URL, session: SessionID) throws -> URL {
        try SessionHistoryStore.sessionDirectory(root: root, session: session)
            .appendingPathComponent(fileName)
    }

    public static func load(root: URL,
                            session: SessionID) throws
        -> SessionKnowledgeAccessDocument? {
        let url = try fileURL(root: root, session: session)
        let lock = try SessionKnowledgeAccessFileLock.acquire(
            at: url.appendingPathExtension("lock"))
        defer { lock.release() }
        return try loadUnlocked(url: url, session: session)
    }

    public static func entry(root: URL,
                             session: SessionID,
                             path: String) throws
        -> SessionKnowledgeAccessEntry? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return try load(root: root, session: session)?.entries.first {
            $0.path == normalized
        }
    }

    @discardableResult
    public static func upsert(root: URL,
                              session: SessionID,
                              entry: SessionKnowledgeAccessEntry) throws
        -> SessionKnowledgeAccessDocument {
        let url = try fileURL(root: root, session: session)
        let lock = try SessionKnowledgeAccessFileLock.acquire(
            at: url.appendingPathExtension("lock"))
        defer { lock.release() }
        var document = try loadUnlocked(url: url, session: session)
            ?? SessionKnowledgeAccessDocument(sessionID: session)
        if let index = document.entries.firstIndex(where: {
            $0.path == entry.path
        }) {
            document.entries[index] = entry
        } else {
            document.entries.append(entry)
        }
        document.entries.sort { $0.path < $1.path }
        try validate(document, session: session)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                try encoder.encode(document),
                to: url,
                temporaryPrefix: ".knowledge-access-")
        } catch {
            throw SessionKnowledgeAccessStoreError.verificationFailed
        }
        guard try loadUnlocked(url: url, session: session) == document else {
            throw SessionKnowledgeAccessStoreError.verificationFailed
        }
        return document
    }

    /// Revokes future restoration of one exact external directory without
    /// affecting any other session-owned Knowledge authorization. A caller
    /// must still drain an already-active scope before treating revocation as
    /// complete; this store owns only the durable bookmark capability.
    @discardableResult
    public static func remove(root: URL,
                              session: SessionID,
                              path: String) throws
        -> SessionKnowledgeAccessDocument {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let url = try fileURL(root: root, session: session)
        let lock = try SessionKnowledgeAccessFileLock.acquire(
            at: url.appendingPathExtension("lock"))
        defer { lock.release() }
        var document = try loadUnlocked(url: url, session: session)
            ?? SessionKnowledgeAccessDocument(sessionID: session)
        document.entries.removeAll { $0.path == normalized }
        try validate(document, session: session)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                try encoder.encode(document),
                to: url,
                temporaryPrefix: ".knowledge-access-")
        } catch {
            throw SessionKnowledgeAccessStoreError.verificationFailed
        }
        guard try loadUnlocked(url: url, session: session) == document else {
            throw SessionKnowledgeAccessStoreError.verificationFailed
        }
        return document
    }

    private static func loadUnlocked(
        url: URL,
        session: SessionID
    ) throws -> SessionKnowledgeAccessDocument? {
        let data: Data?
        do {
            data = try DurableOwnerOnlyFile.read(
                from: url,
                maximumBytes: 16 * 1_024 * 1_024)
        } catch {
            throw SessionKnowledgeAccessStoreError.invalidDocument
        }
        guard let data else { return nil }
        let document: SessionKnowledgeAccessDocument
        do {
            document = try PropertyListDecoder().decode(
                SessionKnowledgeAccessDocument.self,
                from: data)
        } catch {
            throw SessionKnowledgeAccessStoreError.invalidDocument
        }
        try validate(document, session: session)
        return document
    }

    private static func validate(
        _ document: SessionKnowledgeAccessDocument,
        session: SessionID
    ) throws {
        guard document.schemaVersion
                == SessionKnowledgeAccessDocument.currentSchemaVersion,
              document.sessionID == session,
              document.entries.count <= 128,
              Set(document.entries.map(\.path)).count
                == document.entries.count,
              document.entries.allSatisfy({ entry in
                  entry.path.hasPrefix("/")
                      && !entry.bookmarkData.isEmpty
                      && entry.bookmarkData.count <= 1 * 1_024 * 1_024
                      && entry.revision > 0
                      && KnowledgeDigest.isValid(
                          entry.authorizationReferenceDigest)
              }) else {
            throw SessionKnowledgeAccessStoreError.invalidDocument
        }
    }
}
