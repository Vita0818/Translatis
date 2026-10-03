import Foundation

/// The three Intatis product surfaces. A surface is a *policy* over the same
/// kernel, not a separate codebase (ARCHITECTURE.md §1.2, principle C).
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case chat
    case code
    case cowork

    /// Whether this surface binds local workspaces and runs tools.
    public var usesWorkspace: Bool {
        switch self {
        case .chat: return false
        case .code, .cowork: return true
        }
    }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public let id: SessionID
    public let kind: SessionKind
    public let updatedAt: Date
    public let eventCount: Int
    public let displayName: String?

    public init(id: SessionID,
                kind: SessionKind,
                updatedAt: Date,
                eventCount: Int,
                displayName: String? = nil) {
        self.id = id
        self.kind = kind
        self.updatedAt = updatedAt
        self.eventCount = eventCount
        self.displayName = displayName
    }
}

public enum SessionHistoryStoreError: Error, LocalizedError, Equatable {
    case invalidSessionID
    case invalidDisplayName
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            return "The session identifier is invalid."
        case .invalidDisplayName:
            return "Session names must contain 1–120 characters and cannot contain line breaks or control characters."
        case .sessionNotFound:
            return "The session no longer exists."
        }
    }
}

public enum SessionHistoryStore {
    private struct Metadata: Codable {
        var version: Int?
        var displayName: String?
    }

    public static func sessionFile(root: URL, session: SessionID) -> URL {
        root
            .appendingPathComponent(session.rawValue, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    public static func artifactsDir(root: URL, session: SessionID) -> URL {
        root
            .appendingPathComponent(session.rawValue, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    public static func sessionDirectory(root: URL, session: SessionID) throws -> URL {
        try validatedSessionDirectory(root: root, session: session)
    }

    public static func setDisplayName(_ rawName: String,
                                      root: URL,
                                      session: SessionID) throws {
        let directory = try validatedSessionDirectory(root: root, session: session)
        let events = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: events.path) else {
            throw SessionHistoryStoreError.sessionNotFound
        }
        let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty,
              displayName.count <= 120,
              displayName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SessionHistoryStoreError.invalidDisplayName
        }
        let metadataURL = directory.appendingPathComponent("session.json")
        var object: [String: Any] = [:]
        if let existing = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            object = decoded
        }
        if object["version"] == nil {
            object["version"] = 1
        }
        object["displayName"] = displayName
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        try data.write(
            to: metadataURL,
            options: .atomic)
    }

    public static func deleteSession(root: URL, session: SessionID) throws {
        let directory = try validatedSessionDirectory(root: root, session: session)
        let events = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: events.path) else {
            throw SessionHistoryStoreError.sessionNotFound
        }
        try FileManager.default.removeItem(at: directory)
    }

    public static func recentSessions(root: URL, kind: SessionKind) -> [SessionSummary] {
        let prefix: String
        switch kind {
        case .chat:
            prefix = "sess_"
        case .code:
            prefix = "code_"
        case .cowork:
            prefix = "cowork_"
        }

        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        return sessions.compactMap { url -> SessionSummary? in
            let raw = url.lastPathComponent
            guard raw.hasPrefix(prefix) else { return nil }
            let events = url.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: events.path) else { return nil }
            let values = try? events.resourceValues(forKeys: [.contentModificationDateKey])
            return SessionSummary(
                id: SessionID(rawValue: raw),
                kind: kind,
                updatedAt: values?.contentModificationDate ?? .distantPast,
                eventCount: eventCount(in: events),
                displayName: displayName(in: url))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func validatedSessionDirectory(root: URL,
                                                  session: SessionID) throws -> URL {
        let raw = session.rawValue
        guard !raw.isEmpty,
              raw != ".",
              raw != "..",
              !raw.contains("/"),
              !raw.contains("\\") else {
            throw SessionHistoryStoreError.invalidSessionID
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(raw, isDirectory: true)
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw SessionHistoryStoreError.invalidSessionID
        }
        let directory = candidate.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent().standardizedFileURL == canonicalRoot else {
            throw SessionHistoryStoreError.invalidSessionID
        }
        return directory
    }

    private static func displayName(in directory: URL) -> String? {
        let metadataURL = directory.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return nil
        }
        guard let displayName = metadata.displayName else { return nil }
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 120,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func eventCount(in fileURL: URL) -> Int {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return 0 }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }
}
