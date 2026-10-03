import Foundation
import XCTest
import IntatisProtocol
@testable import IntatisKnowledge
#if canImport(Darwin)
import Darwin
#endif

final class KnowledgeFileSystemTests: XCTestCase {
    func testWorkspaceRelativeSymlinkToOutsideRootIsRejected() throws {
        let fixture = try FileSystemFixture.make()
        defer { fixture.remove() }

        let outside = fixture.parent.appendingPathComponent(
            "outside",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let link = fixture.workspace.appendingPathComponent(
            "knowledge-link",
            isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside)

        XCTAssertThrowsError(try KnowledgeSecureFileSystem().authorizeRoot(
            link,
            workspaceLease: fixture.lease)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .accessDenied)
        }
    }

    func testWorkspaceLeaseAllowAndDenyRulesApplyToKnowledgeRoot() throws {
        let fixture = try FileSystemFixture.make()
        defer { fixture.remove() }
        let allowed = fixture.workspace.appendingPathComponent(
            "knowledge/allowed",
            isDirectory: true)
        let denied = fixture.workspace.appendingPathComponent(
            "knowledge/private",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: allowed,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.createDirectory(
            at: denied,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let lease = WorkspaceLease(
            rootPath: fixture.workspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: "knowledge/**")],
            deniedPatterns: ["knowledge/private"])

        XCTAssertNoThrow(try KnowledgeSecureFileSystem().authorizeRoot(
            allowed,
            workspaceLease: lease))
        XCTAssertThrowsError(try KnowledgeSecureFileSystem().authorizeRoot(
            denied,
            workspaceLease: lease)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .accessDenied)
        }
    }

    func testRelativeReadRejectsAbsoluteAndTraversalPaths() throws {
        let fixture = try FileSystemFixture.make()
        defer { fixture.remove() }
        let root = try fixture.makeDirectory("knowledge")
        let fileSystem = KnowledgeSecureFileSystem()

        for path in ["../outside", "/private/outside", "a/../../outside"] {
            XCTAssertThrowsError(try fileSystem.readFile(
                root: root,
                relativePath: path)) { error in
                XCTAssertEqual(
                    (error as? KnowledgeDomainError)?.failure.code,
                    .unsafeStorage)
            }
        }
    }

    func testScanRejectsHardlinksSpecialFilesAndUnsafeModes() throws {
        let fixture = try FileSystemFixture.make()
        defer { fixture.remove() }
        let fileSystem = KnowledgeSecureFileSystem()

        let hardlinkRoot = try fixture.makeDirectory("hardlink-root")
        let original = fixture.workspace.appendingPathComponent("original")
        try Data("same inode".utf8).write(to: original)
        try FileManager.default.linkItem(
            at: original,
            to: hardlinkRoot.appendingPathComponent("linked"))
        XCTAssertThrowsError(try fileSystem.scan(root: hardlinkRoot)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .unsafeStorage)
        }

        #if canImport(Darwin)
        let specialRoot = try fixture.makeDirectory("special-root")
        let pipe = specialRoot.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try fileSystem.scan(root: specialRoot)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .unsafeStorage)
        }
        #endif

        let unsafeRoot = try fixture.makeDirectory("unsafe-root")
        let unsafeFile = unsafeRoot.appendingPathComponent("world-writable")
        try Data("unsafe".utf8).write(to: unsafeFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)],
            ofItemAtPath: unsafeFile.path)
        XCTAssertThrowsError(try fileSystem.scan(root: unsafeRoot)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .unsafeStorage)
        }
    }

    func testScanEnforcesFileByteAndDepthBounds() throws {
        let fixture = try FileSystemFixture.make()
        defer { fixture.remove() }

        var fileLimits = KnowledgeFileSystemLimits()
        fileLimits.maximumFiles = 1
        let filesRoot = try fixture.makeDirectory("files-root")
        try Data("one".utf8).write(
            to: filesRoot.appendingPathComponent("one"))
        try Data("two".utf8).write(
            to: filesRoot.appendingPathComponent("two"))
        XCTAssertThrowsError(try KnowledgeSecureFileSystem(
            limits: fileLimits).scan(root: filesRoot))

        var byteLimits = KnowledgeFileSystemLimits()
        byteLimits.maximumSingleFileBytes = 3
        let bytesRoot = try fixture.makeDirectory("bytes-root")
        try Data("four".utf8).write(
            to: bytesRoot.appendingPathComponent("four"))
        XCTAssertThrowsError(try KnowledgeSecureFileSystem(
            limits: byteLimits).scan(root: bytesRoot))

        var depthLimits = KnowledgeFileSystemLimits()
        depthLimits.maximumDepth = 1
        let depthRoot = try fixture.makeDirectory("depth-root")
        let nested = depthRoot.appendingPathComponent(
            "a/b",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try Data("deep".utf8).write(
            to: nested.appendingPathComponent("leaf"))
        XCTAssertThrowsError(try KnowledgeSecureFileSystem(
            limits: depthLimits).scan(root: depthRoot))
    }
}

private struct FileSystemFixture {
    let parent: URL
    let workspace: URL
    let lease: WorkspaceLease

    static func make() throws -> FileSystemFixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-knowledge-fs-\(UUID().uuidString)",
                isDirectory: true)
        let workspace = parent.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return FileSystemFixture(
            parent: parent,
            workspace: workspace,
            lease: WorkspaceLease(
                rootPath: workspace.path,
                access: .readOnly,
                deniedPatterns: []))
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let directory = workspace.appendingPathComponent(
            name,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return directory
    }
}
