import XCTest
import IntatisCore
@testable import IntatisProtocol

final class WorkspaceLeaseTests: XCTestCase {
    func testWorkspaceLeaseCodableRoundTrip() throws {
        let lease = WorkspaceLease(
            id: WorkspaceLeaseID(rawValue: "wlease_1"),
            workspaceID: WorkspaceID(rawValue: "ws_1"),
            taskID: TaskID(rawValue: "task_1"),
            rootPath: "/tmp/project",
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: "Sources/**")],
            deniedPatterns: [".env", ".ssh"],
            expiresAtTaskCompletion: true)

        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(WorkspaceLease.self, from: data)

        XCTAssertEqual(decoded, lease)
        XCTAssertEqual(decoded.taskID, TaskID(rawValue: "task_1"))
        XCTAssertTrue(decoded.expiresAtTaskCompletion)
    }

    func testLegacyWorkspaceLeaseWithoutTaskExpiryDecodesAsPersistent() throws {
        let json = """
        {
          "id": "wlease_legacy",
          "workspaceID": "ws_legacy",
          "rootPath": "/tmp/legacy-project",
          "access": "read_only",
          "allowedPathRules": [{"pattern": "."}],
          "deniedPatterns": [".env", ".ssh"]
        }
        """

        let decoded = try JSONDecoder().decode(WorkspaceLease.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, WorkspaceLeaseID(rawValue: "wlease_legacy"))
        XCTAssertNil(decoded.taskID)
        XCTAssertNil(decoded.rootIdentity)
        XCTAssertFalse(decoded.expiresAtTaskCompletion)
    }

    func testWorkspaceLeaseBindsExistingDirectoryIdentityAndDetectsReplacement() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-lease-identity-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("worker", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let lease = WorkspaceLease(rootPath: root.path, access: .readWrite)
        let identity = try XCTUnwrap(lease.rootIdentity)
        XCTAssertTrue(identity.matchesCurrentDirectory(rootPath: lease.rootPath))

        let moved = parent.appendingPathComponent("worker-old", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertFalse(identity.matchesCurrentDirectory(rootPath: lease.rootPath))
    }

    func testWorkspaceLeaseExpressesRootAccessAndDeniedPatterns() {
        let lease = WorkspaceLease(rootPath: "/tmp/project", access: .readWrite)

        XCTAssertEqual(
            WorkspaceLease.defaultDeniedPatterns,
            WorkspaceLease.mandatoryTerminalDeniedPatterns)
        XCTAssertEqual(lease.rootPath, "/tmp/project")
        XCTAssertEqual(lease.access, .readWrite)
        XCTAssertTrue(lease.allowedPathRules.contains(PathRule(pattern: ".")))
        XCTAssertTrue(lease.deniedPatterns.contains(".ssh"))
        XCTAssertTrue(lease.deniedPatterns.contains { $0.contains("token") })
        for required in [
            ".netrc", ".pgpass", ".npmrc", ".aws", ".gnupg",
            "**/.config/gh/**", "**/.config/intatis/**", "**/.git/config",
            ".intatis-rag-store.json", ".intatis-rag-snapshots",
            ".intatis-rag-host",
        ] {
            XCTAssertTrue(
                lease.deniedPatterns.contains(required),
                "default WorkspaceLease must deny \(required)")
        }
        XCTAssertTrue(
            Set(WorkspaceLease.mandatoryManagedStoreDeniedPatterns)
                .isSubset(of: Set(lease.deniedPatterns)))
    }
}
