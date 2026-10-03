import Foundation
import XCTest
@testable import IntatisCore

final class IntatisDiagnosticExportTests: XCTestCase {
    func testEventLogRedactorPreservesDiagnosticStructureWithoutPrivateContent() throws {
        let raw = #"{"seq":42,"ts":"2026-08-02T04:56:00Z","session":"sess_example","v":1,"type":"error","payload":{"status":"failed","code":"NSURLError-1005","providerID":"openrouter","modelID":"deepseek-v4","message":"Provider failed at https://private.example/v1?token=secret from /Users/example/Private/project using api_key=sk-supersecretvalue","content":"private user prompt","args":{"command":"print secret","password":"hunter2"},"workspacePath":"/Users/example/Private/project"}}"#
        let snapshot = IntatisDiagnosticFileSnapshot(
            data: Data((raw + "\n").utf8),
            sourceByteCount: raw.utf8.count + 1,
            wasTruncated: false)

        let redacted = IntatisDiagnosticEventLogRedactor.redact(snapshot)
        let text = try XCTUnwrap(String(data: redacted.data, encoding: .utf8))

        XCTAssertTrue(text.contains("NSURLError-1005"))
        XCTAssertTrue(text.contains("openrouter"))
        XCTAssertTrue(text.contains("deepseek-v4"))
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("error"))
        XCTAssertFalse(text.contains("private user prompt"))
        XCTAssertFalse(text.contains("print secret"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("private.example"))
        XCTAssertFalse(text.contains("/Users/example"))
        XCTAssertFalse(text.contains("sk-supersecretvalue"))
        XCTAssertGreaterThan(redacted.redactedValueCount, 0)
        XCTAssertEqual(redacted.exportedLineCount, 1)
        XCTAssertEqual(redacted.invalidLineCount, 0)
    }

    func testEventLogRedactorKeepsNewestCompleteRecordsWhenOutputIsBounded() throws {
        let lines = (0..<40).map { index in
            #"{"seq":\#(index),"ts":"2026-08-02T04:56:00Z","session":"sess_example","v":1,"type":"error","payload":{"code":"diagnostic-code-\#(index)","message":"\#(String(repeating: "x", count: 220))"}}"#
        }
        let raw = lines.joined(separator: "\n") + "\n"
        let snapshot = IntatisDiagnosticFileSnapshot(
            data: Data(raw.utf8),
            sourceByteCount: raw.utf8.count,
            wasTruncated: false)

        let redacted = IntatisDiagnosticEventLogRedactor.redact(
            snapshot,
            maximumOutputBytes: 1_024)
        let text = try XCTUnwrap(String(data: redacted.data, encoding: .utf8))

        XCTAssertTrue(redacted.wasTruncated)
        XCTAssertTrue(text.contains("diagnostic-code-39"))
        XCTAssertFalse(text.contains("diagnostic-code-0\""))
        XCTAssertLessThanOrEqual(redacted.data.count, 1_024)
    }

    func testSnapshotReaderAcceptsOwnedReadOnlyFileAndRejectsLeafSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let source = Data(String(repeating: "a", count: 2_048).utf8)
        try source.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: file.path)

        let snapshot = try IntatisDiagnosticSnapshotReader.readTail(
            from: file,
            maximumBytes: 1_024)
        XCTAssertEqual(snapshot.sourceByteCount, 2_048)
        XCTAssertEqual(snapshot.data.count, 1_024)
        XCTAssertTrue(snapshot.wasTruncated)

        let link = root.appendingPathComponent("events-link.jsonl")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: file)
        XCTAssertThrowsError(
            try IntatisDiagnosticSnapshotReader.readTail(
                from: link,
                maximumBytes: 1_024)
        ) { error in
            XCTAssertEqual(
                error as? IntatisDiagnosticSnapshotError,
                .unsafeFile)
        }
    }

    func testDiagnosticTextSanitizerCoversCommonCredentialAndIdentityShapes() {
        // Construct unmistakably synthetic input instead of embedding a credential.
        let syntheticSlackFixture = ["xoxb", "diagnostic", "test", "fixture"]
            .joined(separator: "-")
        let raw = """
        email=user@example.com
        github=ghp_abcdefghijklmnopqrstuvwxyz0123456789
        slack=\(syntheticSlackFixture)
        jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue
        volume=/Volumes/Private Disk/customer/file.txt
        """

        let sanitized = IntatisHangDiagnosticTextSanitizer.sanitize(raw)

        XCTAssertFalse(sanitized.contains("user@example.com"))
        XCTAssertFalse(sanitized.contains("ghp_abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(sanitized.contains("xoxb-1234567890"))
        XCTAssertFalse(sanitized.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertFalse(sanitized.contains("/Volumes/Private Disk"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-diagnostic-export-tests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        return url
    }
}
