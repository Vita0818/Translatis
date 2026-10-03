#if canImport(SwiftUI)
import Foundation
import IntatisCore
#if canImport(AppKit)
import AppKit
#endif

/// Workspace folder selection for the direct-distribution macOS product. The
/// selected directory remains canonical and uses the same security-scoped
/// bookmark lifecycle for durable user-granted access.
final class WorkspaceAccessLease: @unchecked Sendable {
    let scopedURL: URL
    let canonicalURL: URL
    var canonicalPath: String { canonicalURL.path }

    private let lock = NSLock()
    private var didStartAccessing: Bool
    private var released = false

    init(scopedURL: URL) throws {
        self.scopedURL = scopedURL
        let didStart = scopedURL.startAccessingSecurityScopedResource()
        do {
            self.canonicalURL = try PathConfinement.canonicalExistingDirectory(scopedURL)
            self.didStartAccessing = didStart
        } catch {
            if didStart { scopedURL.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        let shouldStop = didStartAccessing
        didStartAccessing = false
        lock.unlock()
        if shouldStop {
            scopedURL.stopAccessingSecurityScopedResource()
        }
    }

    deinit { release() }
}

enum WorkspaceAccess {
    struct LegacyBookmarkMigrationResult: Equatable {
        var didMigrate: Bool
        /// Keys are syntactically normalized current settings paths. Values are the
        /// canonical identities proven only after resolving and enabling the
        /// corresponding security-scoped bookmark.
        var canonicalPathsByStoredPath: [String: String]

        static let none = LegacyBookmarkMigrationResult(
            didMigrate: false,
            canonicalPathsByStoredPath: [:])
    }

    @MainActor
    static func choose(prompt: String = "Choose Workspace") -> WorkspaceAccessLease? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        TranslatisMacProcessDiagnostics.shared
            .setKnownModalPresented(true)
        defer {
            TranslatisMacProcessDiagnostics.shared
                .setKnownModalPresented(false)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? WorkspaceAccessLease(scopedURL: url)
        #else
        return nil
        #endif
    }

    @discardableResult
    static func remember(_ url: URL,
                         for session: SessionID,
                         isPrimary: Bool = false) throws -> SessionWorkspaceAccessDocument {
        #if canImport(AppKit)
        let canonicalURL = try PathConfinement.canonicalExistingDirectory(url)
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        return try SessionWorkspaceAccessStore.upsert(
            root: AppConfig.appSupportDir(),
            session: session,
            entry: SessionWorkspaceAccessEntry(
                path: canonicalURL.path,
                bookmarkData: data,
                isPrimary: isPrimary))
        #else
        throw IntatisError.io("Security-scoped workspace bookmarks are unavailable on this platform.")
        #endif
    }

    static func hasRememberedAccess(forPath path: String,
                                    in session: SessionID) throws -> Bool {
        // Session settings already persist the canonical identity. Do not stat
        // the directory before restoring its security scope on app relaunch.
        let normalizedPath = storedPath(path)
        return try SessionWorkspaceAccessStore.entry(
            root: AppConfig.appSupportDir(),
            session: session,
            path: normalizedPath) != nil
    }

    @discardableResult
    static func restoreAccess(forPath path: String,
                              in session: SessionID) throws -> WorkspaceAccessLease? {
        #if canImport(AppKit)
        let normalizedPath = storedPath(path)
        guard let document = try SessionWorkspaceAccessStore.load(
            root: AppConfig.appSupportDir(),
            session: session) else { return nil }
        if let entry = document.entries.first(where: { $0.path == normalizedPath }),
           let lease = resolveLease(entry, session: session) {
            return lease
        }
        // Legacy settings could contain a symbolic-link spelling while the
        // session capability file correctly keyed the same directory by its
        // canonical identity. Resolve a bookmark and enable its scope first;
        // only then canonicalize the stored alias and compare identities.
        return resolvedEntryMatchingExpectedPath(
            path,
            entries: document.entries,
            session: session)?.lease
        #else
        return nil
        #endif
    }

    /// Returns canonical replacements only for settings paths that can be
    /// matched unambiguously to a session-owned bookmark while its security
    /// scope is active. Missing or ambiguous paths are intentionally omitted.
    static func validatedCanonicalPathMappings(
        for workspacePaths: [String],
        in session: SessionID
    ) throws -> [String: String] {
        #if canImport(AppKit)
        guard let document = try SessionWorkspaceAccessStore.load(
            root: AppConfig.appSupportDir(),
            session: session) else { return [:] }
        var mappings: [String: String] = [:]
        for rawPath in workspacePaths {
            let normalized = storedPath(rawPath)
            if let entry = document.entries.first(where: { $0.path == normalized }),
               let lease = resolveLease(entry, session: session) {
                mappings[normalized] = lease.canonicalPath
                lease.release()
                continue
            }
            if let match = resolvedEntryMatchingExpectedPath(
                rawPath,
                entries: document.entries,
                session: session) {
                mappings[normalized] = match.lease.canonicalPath
                match.lease.release()
            }
        }
        return mappings
        #else
        return [:]
        #endif
    }

    /// The caller-supplied lease already holds the selected security scope.
    /// Canonicalizing the expected legacy spelling is therefore safe here and
    /// never turns a mere text match into a capability grant.
    static func selectedLease(_ lease: WorkspaceAccessLease,
                              matchesStoredPath expectedPath: String) -> Bool {
        (try? canonicalPath(expectedPath)) == lease.canonicalPath
    }

    @discardableResult
    static func restoredWorkspace(for session: SessionID) throws -> WorkspaceAccessLease? {
        #if canImport(AppKit)
        if let document = try SessionWorkspaceAccessStore.load(
            root: AppConfig.appSupportDir(),
            session: session),
           let entry = document.entries.first(where: \.isPrimary) ?? document.entries.first,
           let lease = resolveLease(entry, session: session) {
            return lease
        }
        guard let data = UserDefaults.standard.data(forKey: sessionBookmarkKey(session)),
              let path = UserDefaults.standard.string(forKey: sessionPathKey(session)) else {
            return nil
        }
        guard let lease = resolveLegacyLease(
            bookmarkData: data,
            expectedPath: path) else {
            return nil
        }
        do {
            _ = try remember(lease.scopedURL, for: session, isPrimary: true)
            guard let verified = try SessionWorkspaceAccessStore.entry(
                root: AppConfig.appSupportDir(),
                session: session,
                path: lease.canonicalPath),
                  let verificationLease = resolveLease(verified, session: session) else {
                throw IntatisError.io("Migrated workspace access could not be verified safely.")
            }
            verificationLease.release()
            UserDefaults.standard.removeObject(forKey: sessionBookmarkKey(session))
            UserDefaults.standard.removeObject(forKey: sessionPathKey(session))
            return lease
        } catch {
            lease.release()
            throw error
        }
        #else
        return nil
        #endif
    }

    static func workspacePath(for session: SessionID) -> String? {
        try? workspacePathChecked(for: session)
    }

    static func workspacePathChecked(for session: SessionID) throws -> String? {
        if let document = try SessionWorkspaceAccessStore.load(
            root: AppConfig.appSupportDir(),
            session: session) {
            return document.entries.first(where: \.isPrimary)?.path
                ?? document.entries.first?.path
        }
        return UserDefaults.standard.string(forKey: sessionPathKey(session))
    }

    /// Copies every available legacy bookmark into the owner-only session
    /// document and verifies every source-backed entry. The result is true
    /// whenever a legacy source was found and verified, including a retry after
    /// the prior run wrote the session document but crashed before cleanup.
    /// The shared path map is intentionally retained because another legacy
    /// session may still reference the same path.
    @discardableResult
    static func migrateLegacyBookmarks(
        for session: SessionID,
        workspacePaths: [String],
        primaryPath: String?,
        sharedLegacyPaths: Set<String>
    ) throws -> LegacyBookmarkMigrationResult {
        #if canImport(AppKit)
        let existing = try SessionWorkspaceAccessStore.load(
            root: AppConfig.appSupportDir(),
            session: session)
        var existingEntries = Dictionary(uniqueKeysWithValues:
            (existing?.entries ?? []).map { ($0.path, $0) })
        let legacyPrimaryData = UserDefaults.standard.data(forKey: sessionBookmarkKey(session))
        let legacyPrimaryPath = UserDefaults.standard
            .string(forKey: sessionPathKey(session))
            .flatMap { NSString(string: $0).isAbsolutePath ? storedPath($0) : nil }
        var shared: [String: Data] = [:]
        for (path, data) in bookmarkStore() {
            shared[storedPath(path)] = data
        }
        let normalizedSharedLegacyPaths = Set(sharedLegacyPaths.map(storedPath))
        let normalizedPrimaryPath = primaryPath.map(storedPath)
        var legacyEvidencePaths = normalizedSharedLegacyPaths
        if legacyPrimaryData != nil, let legacyPrimaryPath {
            legacyEvidencePaths.insert(legacyPrimaryPath)
        }
        func legacyBookmarkData(for legacyPath: String) -> Data? {
            if legacyPath == legacyPrimaryPath, let legacyPrimaryData {
                return legacyPrimaryData
            }
            guard normalizedSharedLegacyPaths.contains(legacyPath) else {
                return nil
            }
            return shared[legacyPath]
        }
        var legacyPathByCurrentPath: [String: String] = [:]
        for rawPath in workspacePaths {
            let currentPath = storedPath(rawPath)
            if legacyEvidencePaths.contains(currentPath) {
                legacyPathByCurrentPath[currentPath] = currentPath
                continue
            }
            // A prior attempt may have written the canonical capability and
            // canonical settings event, then crashed before the migration
            // marker. Match the still-retained legacy alias to that entry only
            // while its scope is active so the retry can finish and clean up.
            var matchingLegacyPath: String?
            for legacyPath in legacyEvidencePaths.sorted() {
                guard let match = resolvedEntryMatchingExpectedPath(
                    legacyPath,
                    entries: Array(existingEntries.values),
                    session: session) else { continue }
                let currentCanonical = try? canonicalPath(rawPath)
                let isMatch = currentCanonical == match.lease.canonicalPath
                match.lease.release()
                guard isMatch else { continue }
                guard matchingLegacyPath == nil else {
                    throw IntatisError.io(
                        "Legacy workspace aliases are ambiguous for \(currentPath).")
                }
                matchingLegacyPath = legacyPath
            }
            // On a first migration there is no session plist yet. Resolve the
            // legacy source bookmark itself, enable its security scope, and
            // only then compare the legacy alias with the current settings
            // path's canonical identity. This covers `/alias/ws` evidence for
            // settings that already contain `/real/ws` without granting a
            // capability from a syntactic path match.
            if matchingLegacyPath == nil {
                for legacyPath in legacyEvidencePaths.sorted() {
                    guard let data = legacyBookmarkData(for: legacyPath) else {
                        continue
                    }
                    guard let legacyLease = resolveLegacyLease(
                        bookmarkData: data,
                        expectedPath: legacyPath) else {
                        // This is only candidate discovery. An unrelated stale
                        // legacy entry must not prevent another valid alias
                        // from converging. A source selected for the current
                        // workspace is resolved again strictly in the migration
                        // loop below before any capability or marker is kept.
                        continue
                    }
                    let currentCanonical = try? canonicalPath(rawPath)
                    let isMatch = currentCanonical == legacyLease.canonicalPath
                    legacyLease.release()
                    guard isMatch else { continue }
                    guard matchingLegacyPath == nil else {
                        throw IntatisError.io(
                            "Legacy workspace aliases are ambiguous for \(currentPath).")
                    }
                    matchingLegacyPath = legacyPath
                }
            }
            if let matchingLegacyPath {
                legacyPathByCurrentPath[currentPath] = matchingLegacyPath
            }
        }
        let requiredLegacyPaths = Set(legacyPathByCurrentPath.values)
        guard !requiredLegacyPaths.isEmpty else { return .none }

        // Process the declared primary last so an upsert can deterministically
        // demote any legacy entry that was incorrectly marked primary.
        let orderedWorkspacePaths = workspacePaths.sorted {
            storedPath($0) != normalizedPrimaryPath
                && storedPath($1) == normalizedPrimaryPath
        }
        var sourceBackedPaths: Set<String> = []
        var completedLegacyPaths: Set<String> = []
        var expectedPrimaryByCanonicalPath: [String: Bool] = [:]
        var canonicalPathsByStoredPath: [String: String] = [:]
        for rawPath in orderedWorkspacePaths {
            let currentLookupPath = storedPath(rawPath)
            guard let legacyLookupPath = legacyPathByCurrentPath[currentLookupPath] else {
                continue
            }
            let mayUseSharedBookmark = normalizedSharedLegacyPaths.contains(legacyLookupPath)
            let shouldBePrimary = currentLookupPath == normalizedPrimaryPath

            if let match = resolvedEntryMatchingExpectedPath(
                rawPath,
                entries: Array(existingEntries.values),
                session: session) {
                let current = match.entry
                let canonical = match.lease.canonicalPath
                match.lease.release()
                let refreshed = SessionWorkspaceAccessEntry(
                    path: canonical,
                    bookmarkData: current.bookmarkData,
                    isPrimary: shouldBePrimary)
                let updated = try SessionWorkspaceAccessStore.upsert(
                    root: AppConfig.appSupportDir(),
                    session: session,
                    entry: refreshed)
                existingEntries = Dictionary(uniqueKeysWithValues:
                    updated.entries.map { ($0.path, $0) })
                sourceBackedPaths.insert(canonical)
                completedLegacyPaths.insert(legacyLookupPath)
                expectedPrimaryByCanonicalPath[canonical] = shouldBePrimary
                canonicalPathsByStoredPath[currentLookupPath] = canonical
                continue
            }

            let data: Data?
            if legacyLookupPath == legacyPrimaryPath {
                data = legacyPrimaryData
                    ?? (mayUseSharedBookmark ? shared[legacyLookupPath] : nil)
            } else {
                data = mayUseSharedBookmark ? shared[legacyLookupPath] : nil
            }
            guard let data else {
                throw IntatisError.io(
                    "Legacy workspace access is incomplete for \(legacyLookupPath). Reauthorize that workspace before migration can finish.")
            }
            guard let legacyLease = resolveLegacyLease(
                bookmarkData: data,
                expectedPath: legacyLookupPath) else {
                throw IntatisError.io("Legacy workspace access is invalid or points to another directory.")
            }
            defer { legacyLease.release() }
            let path = legacyLease.canonicalPath
            sourceBackedPaths.insert(path)
            completedLegacyPaths.insert(legacyLookupPath)
            expectedPrimaryByCanonicalPath[path] = shouldBePrimary
            canonicalPathsByStoredPath[currentLookupPath] = path
            let legacyEntry = SessionWorkspaceAccessEntry(
                path: path,
                bookmarkData: data,
                isPrimary: shouldBePrimary)
            let updated = try SessionWorkspaceAccessStore.upsert(
                root: AppConfig.appSupportDir(),
                session: session,
                entry: legacyEntry)
            existingEntries = Dictionary(uniqueKeysWithValues:
                updated.entries.map { ($0.path, $0) })
        }
        guard completedLegacyPaths == requiredLegacyPaths else {
            throw IntatisError.io("Not every session-owned legacy workspace capability was migrated.")
        }
        let verified = try SessionWorkspaceAccessStore.load(
            root: AppConfig.appSupportDir(),
            session: session)
        let verifiedEntries = Dictionary(uniqueKeysWithValues:
            (verified?.entries ?? []).map { ($0.path, $0) })
        let verifiedPaths = Set(verifiedEntries.keys)
        guard sourceBackedPaths.isSubset(of: verifiedPaths) else {
            throw IntatisError.io("Legacy workspace access could not be verified in session storage.")
        }
        guard sourceBackedPaths.allSatisfy({ path in
            guard let entry = verifiedEntries[path],
                  entry.isPrimary == expectedPrimaryByCanonicalPath[path],
                  let lease = resolveLease(entry, session: session) else { return false }
            lease.release()
            return true
        }) else {
            throw IntatisError.io("Migrated workspace access could not be resolved safely.")
        }
        return LegacyBookmarkMigrationResult(
            didMigrate: true,
            canonicalPathsByStoredPath: canonicalPathsByStoredPath)
        #else
        return .none
        #endif
    }

    static func forget(session: SessionID) {
        UserDefaults.standard.removeObject(forKey: sessionBookmarkKey(session))
        UserDefaults.standard.removeObject(forKey: sessionPathKey(session))
    }

    static func clearLegacySessionStorage(for session: SessionID) {
        forget(session: session)
    }

    static func forget(path: String,
                       in session: SessionID,
                       allowPrimaryRemoval: Bool = false) throws {
        _ = try SessionWorkspaceAccessStore.remove(
            root: AppConfig.appSupportDir(),
            session: session,
            path: storedPath(path),
            allowPrimaryRemoval: allowPrimaryRemoval)
    }

    private static var bookmarkStoreKey: String {
        IntatisHostApplication.identity.userDefaultsKey(
            "workspace.bookmarks")
    }

    private static func sessionBookmarkKey(_ session: SessionID) -> String {
        IntatisHostApplication.identity.userDefaultsKey(
            "workspace.sessionBookmark.\(session.rawValue)")
    }

    private static func sessionPathKey(_ session: SessionID) -> String {
        IntatisHostApplication.identity.userDefaultsKey(
            "workspace.sessionPath.\(session.rawValue)")
    }

    private static func bookmarkStore() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: bookmarkStoreKey) as? [String: Data] ?? [:]
    }

    @discardableResult
    private static func resolveLease(_ entry: SessionWorkspaceAccessEntry,
                                     session: SessionID?) -> WorkspaceAccessLease? {
        #if canImport(AppKit)
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: entry.bookmarkData,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            let validationLease = try WorkspaceAccessLease(scopedURL: url)
            guard validationLease.canonicalPath == entry.path else {
                validationLease.release()
                return nil
            }
            do {
                if stale, let session {
                    _ = try remember(url, for: session, isPrimary: entry.isPrimary)
                }
                return validationLease
            } catch {
                validationLease.release()
                throw error
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func resolvedEntryMatchingExpectedPath(
        _ expectedPath: String,
        entries: [SessionWorkspaceAccessEntry],
        session: SessionID?
    ) -> (entry: SessionWorkspaceAccessEntry, lease: WorkspaceAccessLease)? {
        #if canImport(AppKit)
        var match: (entry: SessionWorkspaceAccessEntry, lease: WorkspaceAccessLease)?
        for entry in entries {
            guard let lease = resolveLease(entry, session: session) else { continue }
            guard (try? canonicalPath(expectedPath)) == lease.canonicalPath else {
                lease.release()
                continue
            }
            guard match == nil else {
                // More than one capability claims the same alias. Keep both
                // capabilities untouched and fail closed rather than choosing
                // one by array order.
                lease.release()
                match?.lease.release()
                return nil
            }
            match = (entry, lease)
        }
        return match
        #else
        return nil
        #endif
    }

    /// Resolves an old bookmark before touching the protected path, then uses
    /// that active scope to prove that the stored path names the same canonical
    /// directory. This ordering is required after an App Sandbox relaunch.
    private static func resolveLegacyLease(
        bookmarkData: Data,
        expectedPath: String
    ) -> WorkspaceAccessLease? {
        #if canImport(AppKit)
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
            let lease = try WorkspaceAccessLease(scopedURL: url)
            do {
                let expectedCanonical = try canonicalPath(expectedPath)
                guard lease.canonicalPath == expectedCanonical else {
                    lease.release()
                    return nil
                }
                return lease
            } catch {
                lease.release()
                throw error
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func canonicalPath(_ path: String) throws -> String {
        try PathConfinement.canonicalExistingDirectory(
            URL(fileURLWithPath: path)).path
    }

    private static func storedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
    }
}
#endif
