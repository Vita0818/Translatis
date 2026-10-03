#if canImport(SwiftUI)
import Foundation
import AppKit
import IntatisCore
import IntatisKnowledge
import IntatisProtocol

enum KnowledgeAccess {
    /// Host seam used by session/permission ownership code to revoke one
    /// remembered external Knowledge directory after active tool leases have
    /// drained. No raw bookmark data leaves the session-owned plist.
    @discardableResult
    static func revokeRememberedAccess(
        session: SessionID,
        path: String
    ) throws -> SessionKnowledgeAccessDocument {
        try SessionKnowledgeAccessStore.remove(
            root: AppConfig.appSupportDir(),
            session: session,
            path: path)
    }

    static func externalAuthorityProvider() -> KnowledgeExternalAuthorityProvider {
        KnowledgeExternalAuthorityProvider { request in
            let scoped = try await MainActor.run {
                try acquireExactDirectory(for: request)
            }
            do {
                let access: KnowledgeLeaseAccess = request.operation == .search
                    ? .readOnly
                    : .readWrite
                let stored = try SessionKnowledgeAccessStore.entry(
                    root: AppConfig.appSupportDir(),
                    session: request.sessionID,
                    path: scoped.canonicalPath)
                guard let stored else {
                    throw KnowledgeDomainError(
                        .accessDenied,
                        "The external knowledge bookmark was not persisted.")
                }
                let lease = try KnowledgeLease(
                    root: scoped.canonicalURL,
                    sessionID: request.sessionID,
                    agentID: request.agentID,
                    taskID: request.taskID,
                    reuseScope: .session,
                    access: access,
                    operations: [request.operation],
                    authorizationReferenceKind: .macOSSecurityScopedBookmark,
                    authorizationReferenceDigest:
                        stored.authorizationReferenceDigest,
                    revision: stored.revision)
                return KnowledgeExternalAuthorityGrant(
                    lease: lease,
                    release: { scoped.release() })
            } catch {
                scoped.release()
                throw error
            }
        }
    }

    @MainActor
    private static func acquireExactDirectory(
        for request: KnowledgeExternalAuthorityRequest
    ) throws -> WorkspaceAccessLease {
        if let entry = try SessionKnowledgeAccessStore.entry(
            root: AppConfig.appSupportDir(),
            session: request.sessionID,
            path: request.requestedRoot.path),
           let restored = try restore(entry, session: request.sessionID),
           restored.canonicalPath == request.requestedRoot.path {
            return restored
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = request.operation != .search
        panel.allowsMultipleSelection = false
        panel.directoryURL = existingAncestor(of: request.requestedRoot)
        panel.prompt = request.operation == .search
            ? "Authorize Knowledge Search"
            : "Authorize Knowledge Store"
        panel.message = "Select exactly ‘\(request.requestedRoot.lastPathComponent)’ to authorize this knowledge directory."
        TranslatisMacProcessDiagnostics.shared.setKnownModalPresented(true)
        defer {
            TranslatisMacProcessDiagnostics.shared.setKnownModalPresented(false)
        }
        guard panel.runModal() == .OK, let selected = panel.url else {
            throw KnowledgeDomainError(
                .accessDenied,
                "External knowledge directory authorization was cancelled.")
        }
        let scoped = try WorkspaceAccessLease(scopedURL: selected)
        do {
            guard scoped.canonicalPath == request.requestedRoot.path else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "The selected directory does not exactly match store_path.")
            }
            try remember(scoped, session: request.sessionID)
            return scoped
        } catch {
            scoped.release()
            throw error
        }
    }

    @MainActor
    private static func restore(
        _ entry: SessionKnowledgeAccessEntry,
        session: SessionID
    ) throws -> WorkspaceAccessLease? {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: entry.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
        } catch {
            return nil
        }
        let scoped: WorkspaceAccessLease
        do {
            scoped = try WorkspaceAccessLease(scopedURL: url)
        } catch {
            return nil
        }
        guard scoped.canonicalPath == entry.path else {
            scoped.release()
            return nil
        }
        if stale {
            do {
                try remember(scoped, session: session, revision: entry.revision + 1)
            } catch {
                scoped.release()
                throw error
            }
        }
        return scoped
    }

    @MainActor
    private static func remember(
        _ scoped: WorkspaceAccessLease,
        session: SessionID,
        revision: Int = 1
    ) throws {
        let bookmark = try scoped.scopedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        _ = try SessionKnowledgeAccessStore.upsert(
            root: AppConfig.appSupportDir(),
            session: session,
            entry: SessionKnowledgeAccessEntry(
                path: scoped.canonicalPath,
                bookmarkData: bookmark,
                revision: revision,
                authorizationReferenceDigest: KnowledgeDigest.sha256(bookmark)))
    }

    private static func existingAncestor(of requested: URL) -> URL {
        var candidate = requested
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }
}
#endif
