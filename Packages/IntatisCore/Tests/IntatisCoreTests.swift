import XCTest
@testable import IntatisCore

final class IntatisCoreTests: XCTestCase {

    func testProfilePresets() {
        XCTAssertFalse(PlatformProfile.macAppStore.allowsShell)
        XCTAssertTrue(PlatformProfile.macDeveloperID.allowsShell)
        XCTAssertFalse(PlatformProfile.iOS.allowsWorkspace)
        XCTAssertEqual(PlatformProfile.iOS.surfaces, [.chat])
        XCTAssertTrue(PlatformProfile.macAppStore.supports(.cowork))
        XCTAssertFalse(PlatformProfile.iOS.supports(.code))
        XCTAssertFalse(PlatformProfile.iOS.allowsMCPRemoteHTTP)
        XCTAssertFalse(PlatformProfile.iOS.allowsMCPStdio)
        XCTAssertTrue(PlatformProfile.macAppStore.allowsMCPRemoteHTTP)
        XCTAssertFalse(PlatformProfile.macAppStore.allowsMCPStdio)
        XCTAssertTrue(PlatformProfile.macDeveloperID.allowsMCPRemoteHTTP)
        XCTAssertTrue(PlatformProfile.macDeveloperID.allowsMCPStdio)
    }

    func testIDCodesAsBareString() throws {
        let id = SessionID(rawValue: "sess_test")
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"sess_test\"")
        let back = try JSONDecoder().decode(SessionID.self, from: data)
        XCTAssertEqual(back, id)
    }

    func testIDGenPrefixAndUniqueness() {
        XCTAssertTrue(SessionID.new().rawValue.hasPrefix("sess_"))
        XCTAssertTrue(ProjectID.new().rawValue.hasPrefix("project_"))
        XCTAssertNotEqual(MessageID.new(), MessageID.new())
    }

    func testSessionKindWorkspace() {
        XCTAssertFalse(SessionKind.chat.usesWorkspace)
        XCTAssertTrue(SessionKind.code.usesWorkspace)
        XCTAssertTrue(SessionKind.cowork.usesWorkspace)
    }

    func testSessionHistoryRenamePersistsDisplayNameWithoutChangingIdentity() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "sess_rename")
        try createSession(session, root: root, lines: 2)

        try SessionHistoryStore.setDisplayName(
            "  Research notes  ",
            root: root,
            session: session)

        let summary = try XCTUnwrap(
            SessionHistoryStore.recentSessions(root: root, kind: .chat).first)
        XCTAssertEqual(summary.id, session)
        XCTAssertEqual(summary.displayName, "Research notes")
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionHistoryStore.sessionFile(root: root, session: session).path))
    }

    func testSessionHistoryRenamePreservesRichProjectionFields() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "sess_rich_projection")
        try createSession(session, root: root)
        let metadataURL = root
            .appendingPathComponent(session.rawValue)
            .appendingPathComponent("session.json")
        try Data(#"{"version":2,"sessionID":"sess_rich_projection","kind":"chat","projectedThroughSeq":42,"agentRegistrations":[],"displayName":"Old"}"#.utf8)
            .write(to: metadataURL)

        try SessionHistoryStore.setDisplayName("New", root: root, session: session)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        XCTAssertEqual(object["displayName"] as? String, "New")
        XCTAssertEqual(object["projectedThroughSeq"] as? Int, 42)
        XCTAssertNotNil(object["agentRegistrations"])
    }

    func testSessionWorkspaceAccessRoundTripIsSessionOwnedAndOwnerOnly() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "code_workspace_access")
        let first = SessionWorkspaceAccessEntry(
            path: "/tmp/first",
            bookmarkData: Data("bookmark-one".utf8),
            isPrimary: true)
        let second = SessionWorkspaceAccessEntry(
            path: "/tmp/second",
            bookmarkData: Data("bookmark-two".utf8))

        _ = try SessionWorkspaceAccessStore.upsert(root: root, session: session, entry: first)
        _ = try SessionWorkspaceAccessStore.upsert(root: root, session: session, entry: second)

        let loaded = try XCTUnwrap(SessionWorkspaceAccessStore.load(root: root, session: session))
        XCTAssertEqual(loaded.entries.map(\.path), ["/tmp/first", "/tmp/second"])
        XCTAssertEqual(loaded.entries.first(where: \.isPrimary)?.bookmarkData, first.bookmarkData)
        let url = try SessionWorkspaceAccessStore.fileURL(root: root, session: session)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSessionWorkspaceAccessRefreshDoesNotDemoteExistingPrimary() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "cowork_workspace_primary_refresh")
        _ = try SessionWorkspaceAccessStore.upsert(
            root: root,
            session: session,
            entry: SessionWorkspaceAccessEntry(
                path: "/tmp/primary",
                bookmarkData: Data("old".utf8),
                isPrimary: true))

        let refreshed = try SessionWorkspaceAccessStore.upsert(
            root: root,
            session: session,
            entry: SessionWorkspaceAccessEntry(
                path: "/tmp/primary",
                bookmarkData: Data("new".utf8)))

        XCTAssertEqual(refreshed.entries.filter(\.isPrimary).map(\.path), ["/tmp/primary"])
        XCTAssertEqual(refreshed.entries.first?.bookmarkData, Data("new".utf8))
    }

    func testSessionWorkspaceAccessWriteFailureDoesNotCreateVerifiedDocument() throws {
        let parent = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: root)
        let session = SessionID(rawValue: "code_workspace_failure")
        let document = SessionWorkspaceAccessDocument(
            sessionID: session,
            entries: [
                SessionWorkspaceAccessEntry(
                    path: "/tmp/failure",
                    bookmarkData: Data("bookmark".utf8),
                    isPrimary: true),
            ])

        XCTAssertThrowsError(try SessionWorkspaceAccessStore.save(document, root: root))
    }

    func testSessionWorkspaceAccessConcurrentUpsertsDoNotLoseEntries() async throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "cowork_workspace_concurrency")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    _ = try SessionWorkspaceAccessStore.upsert(
                        root: root,
                        session: session,
                        entry: SessionWorkspaceAccessEntry(
                            path: "/tmp/workspace-\(index)",
                            bookmarkData: Data("bookmark-\(index)".utf8),
                            isPrimary: index == 0))
                }
            }
            try await group.waitForAll()
        }

        let loaded = try XCTUnwrap(SessionWorkspaceAccessStore.load(
            root: root,
            session: session))
        XCTAssertEqual(loaded.entries.count, 12)
        XCTAssertEqual(loaded.entries.filter(\.isPrimary).map(\.path), ["/tmp/workspace-0"])
    }

    func testSessionWorkspaceAccessRejectsMultiplePrimaryEntries() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "cowork_workspace_primary")
        let document = SessionWorkspaceAccessDocument(
            sessionID: session,
            entries: [
                SessionWorkspaceAccessEntry(
                    path: "/tmp/first",
                    bookmarkData: Data("first".utf8),
                    isPrimary: true),
                SessionWorkspaceAccessEntry(
                    path: "/tmp/second",
                    bookmarkData: Data("second".utf8),
                    isPrimary: true),
            ])

        XCTAssertThrowsError(try SessionWorkspaceAccessStore.save(document, root: root)) {
            XCTAssertEqual(
                $0 as? SessionWorkspaceAccessStoreError,
                .multiplePrimaryEntries)
        }
    }

    func testSessionWorkspaceAccessPrimaryRemovalRequiresExplicitRollback() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "cowork_workspace_primary_removal")
        _ = try SessionWorkspaceAccessStore.upsert(
            root: root,
            session: session,
            entry: SessionWorkspaceAccessEntry(
                path: "/tmp/primary",
                bookmarkData: Data("primary".utf8),
                isPrimary: true))

        XCTAssertThrowsError(try SessionWorkspaceAccessStore.remove(
            root: root,
            session: session,
            path: "/tmp/primary")) { error in
            XCTAssertEqual(
                error as? SessionWorkspaceAccessStoreError,
                .primaryEntryRemovalForbidden)
        }
        XCTAssertEqual(
            try SessionWorkspaceAccessStore.load(root: root, session: session)?
                .entries.filter(\.isPrimary).map(\.path),
            ["/tmp/primary"])

        let rolledBack = try SessionWorkspaceAccessStore.remove(
            root: root,
            session: session,
            path: "/tmp/primary",
            allowPrimaryRemoval: true)
        XCTAssertEqual(rolledBack?.entries, [])
    }

    func testSessionHistoryRejectsInvalidDisplayNames() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionID(rawValue: "sess_invalid_name")
        try createSession(session, root: root)

        XCTAssertThrowsError(try SessionHistoryStore.setDisplayName(
            "  ", root: root, session: session)) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidDisplayName)
        }
        XCTAssertThrowsError(try SessionHistoryStore.setDisplayName(
            "line\nbreak", root: root, session: session)) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidDisplayName)
        }
    }

    func testSessionHistoryDeleteRemovesOnlyTargetSession() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = SessionID(rawValue: "sess_delete")
        let sibling = SessionID(rawValue: "sess_keep")
        try createSession(target, root: root)
        try createSession(sibling, root: root)

        try SessionHistoryStore.deleteSession(root: root, session: target)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(target.rawValue).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SessionHistoryStore.sessionFile(root: root, session: sibling).path))
    }

    func testSessionHistoryDeleteRejectsTraversalIdentifier() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("keep".utf8).write(to: outside.appendingPathComponent("events.jsonl"))

        XCTAssertThrowsError(try SessionHistoryStore.deleteSession(
            root: root,
            session: SessionID(rawValue: "../\(outside.lastPathComponent)"))) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidSessionID)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSessionHistoryRenameRejectsSymlinkedSessionDirectory() throws {
        let root = try temporarySessionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-session-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{}\n".utf8).write(to: outside.appendingPathComponent("events.jsonl"))
        let session = SessionID(rawValue: "sess_symlink")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(session.rawValue),
            withDestinationURL: outside)

        XCTAssertThrowsError(try SessionHistoryStore.setDisplayName(
            "Should not escape",
            root: root,
            session: session)) { error in
            XCTAssertEqual(error as? SessionHistoryStoreError, .invalidSessionID)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("session.json").path))
    }

    private func temporarySessionRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-sessions-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createSession(_ session: SessionID,
                               root: URL,
                               lines: Int = 1) throws {
        let events = SessionHistoryStore.sessionFile(root: root, session: session)
        try FileManager.default.createDirectory(
            at: events.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let body = Array(repeating: "{}", count: lines).joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: events)
    }
}
