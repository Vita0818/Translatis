import XCTest
@testable import IntatisCore

final class DurableOwnerOnlyFileTests: XCTestCase {
    func testBoundedReadAcceptsExactLimitAndRejectsLargerFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-bounded-read-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("payload.bin")
        let payload = Data(repeating: 0xA5, count: 4_096)
        try DurableOwnerOnlyFile.writeAtomically(payload, to: url)

        XCTAssertEqual(
            try DurableOwnerOnlyFile.read(
                from: url,
                maximumBytes: payload.count),
            payload)
        XCTAssertThrowsError(
            try DurableOwnerOnlyFile.read(
                from: url,
                maximumBytes: payload.count - 1)
        ) { error in
            XCTAssertEqual(
                error as? DurableOwnerOnlyFileError,
                .fileTooLarge)
        }
    }

    func testBoundedReadPreservesNoFollowAndSingleLinkChecks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-bounded-read-safety-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.bin")
        let hardLink = directory.appendingPathComponent("hard-link.bin")
        let symbolicLink = directory.appendingPathComponent("symbolic-link.bin")
        try DurableOwnerOnlyFile.writeAtomically(Data("safe".utf8), to: target)
        try FileManager.default.linkItem(at: target, to: hardLink)
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: target)

        for url in [target, hardLink, symbolicLink] {
            XCTAssertThrowsError(
                try DurableOwnerOnlyFile.read(
                    from: url,
                    maximumBytes: 64)
            ) { error in
                XCTAssertEqual(
                    error as? DurableOwnerOnlyFileError,
                    .unsafeFile)
            }
        }
    }
}
