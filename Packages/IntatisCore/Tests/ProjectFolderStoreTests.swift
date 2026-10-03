import Foundation
import XCTest
@testable import IntatisCore

final class ProjectFolderStoreTests: XCTestCase {
    func testProjectFolderRoundTripUsesOwnerOnlyBinaryPlist() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)

        let project = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: folder.path,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let loaded = try ProjectFolderStore.load(root: root)

        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.projects, [project])
        XCTAssertEqual(project.kind, .chat)
        XCTAssertEqual(project.displayName, "Workspace")

        let fileURL = ProjectFolderStore.fileURL(root: root)
        let data = try XCTUnwrap(DurableOwnerOnlyFile.read(from: fileURL))
        XCTAssertTrue(data.starts(with: Data("bplist00".utf8)))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil) as? [String: Any])
        let projects = try XCTUnwrap(plist["projects"] as? [[String: Any]])
        let storedProject = try XCTUnwrap(projects.first)
        XCTAssertNil(storedProject["bookmarkData"])
        XCTAssertEqual(
            Set(storedProject.keys),
            Set(["id", "kind", "path", "createdAt", "conversations"]))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
    }

    func testAddingSameFolderPreservesIdentityAndMembership() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Project", isDirectory: true).path
        let first = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: path,
            now: Date(timeIntervalSince1970: 100))
        let conversation = ProjectConversationReference(
            sessionID: SessionID(rawValue: "sess_chat"),
            kind: .chat)
        _ = try ProjectFolderStore.associate(
            root: root,
            projectID: first.id,
            conversation: conversation)

        let refreshed = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: path,
            now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(refreshed.createdAt, first.createdAt)
        XCTAssertEqual(refreshed.conversations, [conversation])
        XCTAssertEqual(try ProjectFolderStore.load(root: root).projects.count, 1)
    }

    func testSameFolderIsRegisteredIndependentlyPerMode() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Shared", isDirectory: true).path

        let chat = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: path)
        let code = try ProjectFolderStore.add(
            root: root,
            kind: .code,
            path: path)

        XCTAssertNotEqual(chat.id, code.id)
        XCTAssertEqual(chat.kind, .chat)
        XCTAssertEqual(code.kind, .code)
        XCTAssertEqual(try ProjectFolderStore.load(root: root).projects.count, 2)
    }

    func testCrossModeConversationAssociationIsRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: "/tmp/chat-project")

        XCTAssertThrowsError(
            try ProjectFolderStore.associate(
                root: root,
                projectID: project.id,
                conversation: ProjectConversationReference(
                    sessionID: SessionID(rawValue: "code_wrong_mode"),
                    kind: .code))) { error in
            XCTAssertEqual(
                error as? ProjectFolderStoreError,
                .invalidProject)
        }
        XCTAssertEqual(
            try ProjectFolderStore.load(root: root).projects.first?.conversations,
            [])
    }

    func testLegacyMixedProjectIsSplitByMode() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy: [String: Any] = [
            "version": 1,
            "projects": [[
                "id": "project_legacy",
                "path": "/tmp/legacy-project",
                "createdAt": Date(timeIntervalSince1970: 100),
                "conversations": [
                    ["sessionID": "sess_legacy", "kind": "chat"],
                    ["sessionID": "code_legacy", "kind": "code"],
                ],
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: legacy,
            format: .binary,
            options: 0)
        try DurableOwnerOnlyFile.writeAtomically(
            data,
            to: ProjectFolderStore.fileURL(root: root))

        let loaded = try ProjectFolderStore.load(root: root)

        XCTAssertEqual(loaded.projects.map(\.kind), [.chat, .code])
        XCTAssertEqual(loaded.projects[0].conversations.map(\.kind), [.chat])
        XCTAssertEqual(loaded.projects[1].conversations.map(\.kind), [.code])
        XCTAssertEqual(
            Set(loaded.projects.map(\.path)),
            Set(["/tmp/legacy-project"]))
    }

    func testConversationAssociationMovesBetweenProjectsWithoutTouchingSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ProjectFolderStore.add(
            root: root,
            kind: .code,
            path: root.appendingPathComponent("One").path)
        let second = try ProjectFolderStore.add(
            root: root,
            kind: .code,
            path: root.appendingPathComponent("Two").path)
        let conversation = ProjectConversationReference(
            sessionID: SessionID(rawValue: "code_existing"),
            kind: .code)
        let sessionDirectory = root.appendingPathComponent(
            conversation.sessionID.rawValue,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true)
        let marker = sessionDirectory.appendingPathComponent("events.jsonl")
        try Data("session-truth".utf8).write(to: marker)

        _ = try ProjectFolderStore.associate(
            root: root,
            projectID: first.id,
            conversation: conversation)
        _ = try ProjectFolderStore.associate(
            root: root,
            projectID: second.id,
            conversation: conversation)

        let loaded = try ProjectFolderStore.load(root: root)
        XCTAssertEqual(
            loaded.projects.first(where: { $0.id == first.id })?.conversations,
            [])
        XCTAssertEqual(
            loaded.projects.first(where: { $0.id == second.id })?.conversations,
            [conversation])
        XCTAssertEqual(try Data(contentsOf: marker), Data("session-truth".utf8))
    }

    func testRemovingProjectLeavesFolderAndSessionDataUntouched() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("UserFolder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true)
        let userFile = folder.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: userFile)
        let session = root.appendingPathComponent("sess_keep", isDirectory: true)
        try FileManager.default.createDirectory(
            at: session,
            withIntermediateDirectories: true)
        let eventFile = session.appendingPathComponent("events.jsonl")
        try Data("keep-session".utf8).write(to: eventFile)
        let project = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: folder.path)
        _ = try ProjectFolderStore.associate(
            root: root,
            projectID: project.id,
            conversation: ProjectConversationReference(
                sessionID: SessionID(rawValue: "sess_keep"),
                kind: .chat))

        try ProjectFolderStore.remove(root: root, projectID: project.id)

        XCTAssertTrue(try ProjectFolderStore.load(root: root).projects.isEmpty)
        XCTAssertEqual(try Data(contentsOf: userFile), Data("keep".utf8))
        XCTAssertEqual(
            try Data(contentsOf: eventFile),
            Data("keep-session".utf8))
    }

    func testInvalidCatalogFailsClosedAndIsNotOverwritten() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsupported = ProjectFolderDocument(version: 2, projects: [])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(unsupported)
        let fileURL = ProjectFolderStore.fileURL(root: root)
        try DurableOwnerOnlyFile.writeAtomically(bytes, to: fileURL)

        XCTAssertThrowsError(try ProjectFolderStore.load(root: root)) { error in
            XCTAssertEqual(
                error as? ProjectFolderStoreError,
                .invalidDocument)
        }
        XCTAssertThrowsError(
            try ProjectFolderStore.add(
                root: root,
                kind: .chat,
                path: "/tmp/project"))
        XCTAssertEqual(try DurableOwnerOnlyFile.read(from: fileURL), bytes)
    }

    func testRelativeFolderAndUnsafeSessionIdentityAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try ProjectFolderStore.add(
                root: root,
                kind: .chat,
                path: "relative/folder")) { error in
            XCTAssertEqual(
                error as? ProjectFolderStoreError,
                .invalidProject)
        }

        let project = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: "/tmp/project")
        XCTAssertThrowsError(
            try ProjectFolderStore.associate(
                root: root,
                projectID: project.id,
                conversation: ProjectConversationReference(
                    sessionID: SessionID(rawValue: "../escape"),
                    kind: .chat))) { error in
            XCTAssertEqual(
                error as? ProjectFolderStoreError,
                .invalidProject)
        }
    }

    func testConcurrentAssociationsPreserveEveryConversation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectFolderStore.add(
            root: root,
            kind: .chat,
            path: "/tmp/concurrent-project")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try ProjectFolderStore.associate(
                        root: root,
                        projectID: project.id,
                        conversation: ProjectConversationReference(
                            sessionID: SessionID(rawValue: "sess_\(index)"),
                            kind: .chat))
                }
            }
            try await group.waitForAll()
        }

        let loaded = try ProjectFolderStore.load(root: root)
        XCTAssertEqual(loaded.projects.first?.conversations.count, 24)
        XCTAssertEqual(
            Set(loaded.projects.first?.conversations ?? []).count,
            24)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-project-store-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }
}
