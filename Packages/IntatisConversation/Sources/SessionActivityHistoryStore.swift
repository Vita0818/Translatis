import Foundation
import IntatisCore
import IntatisProtocol

/// Builds the session list's recency from durable, user-visible work
/// settlements instead of the EventLog file's modification date.
///
/// Opening an existing session may append migration, recovery, lease, or
/// settings events. Those writes must not make a selected session jump to the
/// top of history. A running turn also keeps its previous settled timestamp
/// until the new turn reaches a terminal event.
public enum SessionActivityHistoryStore {
    private struct Metadata: Decodable {
        var displayName: String?
    }

    private struct CacheKey: Hashable {
        let rootPath: String
        let sessionID: SessionID
    }

    private struct FileSignature: Equatable {
        let eventSize: Int
        let eventModificationDate: Date?
        let metadataSize: Int?
        let metadataModificationDate: Date?
    }

    private struct CacheEntry {
        let signature: FileSignature
        let summary: SessionSummary
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheKey: CacheEntry] = [:]

        func summary(for key: CacheKey, signature: FileSignature) -> SessionSummary? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key], entry.signature == signature else {
                return nil
            }
            return entry.summary
        }

        func store(_ entry: CacheEntry, for key: CacheKey) {
            lock.lock()
            entries[key] = entry
            lock.unlock()
        }

        func prune(rootPath: String, retaining keys: Set<CacheKey>) {
            lock.lock()
            entries = entries.filter { key, _ in
                key.rootPath != rootPath || keys.contains(key)
            }
            lock.unlock()
        }
    }

    private static let cache = Cache()

    public static func recentSessions(
        root: URL,
        kind: SessionKind
    ) -> [SessionSummary] {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }

        let prefix = sessionPrefix(for: kind)
        var retainedKeys: Set<CacheKey> = []
        let summaries = directories.compactMap { directory -> SessionSummary? in
            let rawID = directory.lastPathComponent
            guard rawID.hasPrefix(prefix),
                  let directoryValues = try? directory.resourceValues(
                      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true else {
                return nil
            }

            let sessionID = SessionID(rawValue: rawID)
            let key = CacheKey(rootPath: rootPath, sessionID: sessionID)
            let eventURL = directory.appendingPathComponent("events.jsonl")
            let metadataURL = directory.appendingPathComponent("session.json")
            guard let signature = fileSignature(
                eventURL: eventURL,
                metadataURL: metadataURL) else {
                return nil
            }
            retainedKeys.insert(key)

            if let cached = cache.summary(for: key, signature: signature) {
                return cached
            }
            guard let data = try? Data(contentsOf: eventURL) else {
                return nil
            }
            let lines = data.split(
                separator: 0x0A,
                omittingEmptySubsequences: true)
            let summary = SessionSummary(
                id: sessionID,
                kind: kind,
                updatedAt: lastSettledAt(
                    lines: lines,
                    sessionID: sessionID) ?? .distantPast,
                eventCount: lines.count,
                displayName: displayName(at: metadataURL))
            cache.store(
                CacheEntry(signature: signature, summary: summary),
                for: key)
            return summary
        }

        cache.prune(rootPath: rootPath, retaining: retainedKeys)
        return summaries.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func sessionPrefix(for kind: SessionKind) -> String {
        switch kind {
        case .chat:
            return "sess_"
        case .code:
            return "code_"
        case .cowork:
            return "cowork_"
        }
    }

    /// Reads newest-first. Modern sessions normally find a turn terminal near
    /// the tail, so history refresh does not decode every event. Counting and
    /// recency still share the same single Data read.
    private static func lastSettledAt(
        lines: [Data.SubSequence],
        sessionID: SessionID
    ) -> Date? {
        let decoder = Envelope.makeDecoder()
        var legacyMessageCompletion: Date?

        for line in lines.reversed() {
            guard let envelope = try? decoder.decode(
                Envelope.self,
                from: Data(line)),
                envelope.session == sessionID else {
                // History is presentation-only. A damaged tail or a future
                // event must not rewrite or otherwise mutate the EventLog.
                continue
            }

            switch envelope.event {
            case .turnOutcome:
                return envelope.ts
            case .messageCompleted(let payload)
                where legacyMessageCompletion == nil
                    && (payload.role == .assistant || payload.role == .agent):
                legacyMessageCompletion = envelope.ts
            default:
                break
            }
        }

        return legacyMessageCompletion
    }

    private static func fileSignature(
        eventURL: URL,
        metadataURL: URL
    ) -> FileSignature? {
        guard let eventValues = try? eventURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let eventSize = eventValues.fileSize else {
            return nil
        }
        let metadataValues = try? metadataURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileSignature(
            eventSize: eventSize,
            eventModificationDate: eventValues.contentModificationDate,
            metadataSize: metadataValues?.fileSize,
            metadataModificationDate: metadataValues?.contentModificationDate)
    }

    private static func displayName(at metadataURL: URL) -> String? {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let displayName = metadata.displayName else {
            return nil
        }
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
}
