import Foundation
import XCTest
@testable import IntatisTools

private actor DocumentInvocationCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor DocumentContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func resume() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}

final class DocumentInfrastructureTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeWorkspace() throws -> URL {
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(
            "intatis-document-infrastructure-tests-\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
        return workspace
    }

    private func makeParent(_ relativePath: String, workspace: URL) throws {
        try fileManager.createDirectory(
            at: workspace.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func writeFile(
        _ data: Data,
        destinationPath: String,
        workspace: URL,
        sourcePath: String? = nil,
        expectedSourceSHA256: String? = nil,
        replaceExisting: Bool = false,
        expectedDestinationSHA256: String? = nil,
        maximumBytes: UInt64 = 32 * 1_024 * 1_024,
        readOnlyInputSnapshots: [DocumentInputSnapshot] = [],
        produceMutation: @escaping @Sendable () throws -> Void = {}
    ) async throws -> DocumentCommitReceipt {
        try await DocumentStagedOutput.writeFile(
            DocumentStagedFileRequest(
                sourcePath: sourcePath,
                expectedSourceSHA256: expectedSourceSHA256,
                destinationPath: destinationPath,
                replaceExisting: replaceExisting,
                expectedDestinationSHA256: expectedDestinationSHA256,
                fileExtension: "docx",
                maximumBytes: maximumBytes,
                readOnlyInputSnapshots: readOnlyInputSnapshots),
            workspace: workspace,
            produce: { url in
                try data.write(to: url)
                try produceMutation()
            },
            validate: { url in
                guard try Data(contentsOf: url) == data else {
                    throw DocumentToolError(.validationFailed, "fixture read-back mismatch")
                }
            })
    }

    private func assertDocumentError(
        _ expectedCode: DocumentToolErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expectedCode.rawValue)", file: file, line: line)
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, expectedCode, error.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    func testExistingFileIsNotOverwrittenByDefaultAndReplacementRequiresDigest() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        let destination = workspace.appendingPathComponent("docs/output.docx")
        let original = Data("original bytes".utf8)
        _ = try await writeFile(original, destinationPath: "docs/output.docx", workspace: workspace)
        let counter = DocumentInvocationCounter()

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: nil,
                    expectedSourceSHA256: nil,
                    destinationPath: "docs/output.docx",
                    replaceExisting: false,
                    expectedDestinationSHA256: nil,
                    fileExtension: "docx",
                    maximumBytes: 1_024),
                workspace: workspace,
                produce: { url in
                    await counter.record()
                    try Data("unexpected".utf8).write(to: url)
                },
                validate: { _ in })
        }

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: nil,
                    expectedSourceSHA256: nil,
                    destinationPath: "docs/output.docx",
                    replaceExisting: true,
                    expectedDestinationSHA256: nil,
                    fileExtension: "docx",
                    maximumBytes: 1_024),
                workspace: workspace,
                produce: { url in
                    await counter.record()
                    try Data("unexpected".utf8).write(to: url)
                },
                validate: { _ in })
        }

        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testSourceAndDestinationCASChangesPreventCommit() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        let source = workspace.appendingPathComponent("docs/source.docx")
        let sourceOriginal = Data("source-A".utf8)
        let sourceChanged = Data("source-B".utf8)
        let sourceReceipt = try await writeFile(
            sourceOriginal,
            destinationPath: "docs/source.docx",
            workspace: workspace)

        let sourceDestination = workspace.appendingPathComponent("docs/from-source.docx")
        let destinationOriginal = Data("destination original".utf8)
        let sourceDestinationReceipt = try await writeFile(
            destinationOriginal,
            destinationPath: "docs/from-source.docx",
            workspace: workspace)
        let staged = Data("staged replacement".utf8)

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: "docs/source.docx",
                    expectedSourceSHA256: sourceReceipt.sha256,
                    destinationPath: "docs/from-source.docx",
                    replaceExisting: true,
                    expectedDestinationSHA256: sourceDestinationReceipt.sha256,
                    fileExtension: "docx",
                    maximumBytes: 1_024),
                workspace: workspace,
                produce: { payload in
                    try staged.write(to: payload)
                    try sourceChanged.write(to: source)
                },
                validate: { _ in })
        }
        XCTAssertEqual(try Data(contentsOf: sourceDestination), destinationOriginal)

        let concurrentDestination = workspace.appendingPathComponent("docs/concurrent.docx")
        let concurrentReceipt = try await writeFile(
            destinationOriginal,
            destinationPath: "docs/concurrent.docx",
            workspace: workspace)
        let concurrentWriter = Data("concurrent writer won".utf8)

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: nil,
                    expectedSourceSHA256: nil,
                    destinationPath: "docs/concurrent.docx",
                    replaceExisting: true,
                    expectedDestinationSHA256: concurrentReceipt.sha256,
                    fileExtension: "docx",
                    maximumBytes: 1_024),
                workspace: workspace,
                produce: { payload in
                    try staged.write(to: payload)
                    try concurrentWriter.write(to: concurrentDestination)
                },
                validate: { _ in })
        }
        XCTAssertEqual(try Data(contentsOf: concurrentDestination), concurrentWriter)
    }

    func testBackendAndValidatorFailuresLeaveDestinationUnchanged() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        let destination = workspace.appendingPathComponent("docs/output.docx")
        let original = Data("known good output".utf8)
        let receipt = try await writeFile(
            original,
            destinationPath: "docs/output.docx",
            workspace: workspace)
        let request = DocumentStagedFileRequest(
            sourcePath: nil,
            expectedSourceSHA256: nil,
            destinationPath: "docs/output.docx",
            replaceExisting: true,
            expectedDestinationSHA256: receipt.sha256,
            fileExtension: "docx",
            maximumBytes: 1_024)

        await assertDocumentError(.backendFailed) {
            _ = try await DocumentStagedOutput.writeFile(
                request,
                workspace: workspace,
                produce: { _ in
                    throw DocumentToolError(.backendFailed, "fixture backend failed")
                },
                validate: { _ in })
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)

        await assertDocumentError(.validationFailed) {
            _ = try await DocumentStagedOutput.writeFile(
                request,
                workspace: workspace,
                produce: { url in
                    try Data("invalid output".utf8).write(to: url)
                },
                validate: { _ in
                    throw DocumentToolError(.validationFailed, "fixture validator failed")
                })
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testFileCreateAndReplaceReturnsReconciledReceiptAndReadback() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        let destination = workspace.appendingPathComponent("docs/output.docx")
        let created = Data("created document".utf8)

        let createReceipt = try await writeFile(
            created,
            destinationPath: "docs/output.docx",
            workspace: workspace)

        XCTAssertEqual(createReceipt.relativePath, "docs/output.docx")
        XCTAssertEqual(createReceipt.byteCount, UInt64(created.count))
        XCTAssertEqual(createReceipt.sha256.count, 64)
        XCTAssertEqual(try Data(contentsOf: destination), created)

        let replacement = Data("replacement document".utf8)
        let replaceReceipt = try await writeFile(
            replacement,
            destinationPath: "docs/output.docx",
            workspace: workspace,
            replaceExisting: true,
            expectedDestinationSHA256: createReceipt.sha256)

        XCTAssertEqual(replaceReceipt.relativePath, "docs/output.docx")
        XCTAssertEqual(replaceReceipt.byteCount, UInt64(replacement.count))
        XCTAssertNotEqual(replaceReceipt.sha256, createReceipt.sha256)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
    }

    func testNonRegularStagedFileOutputIsRejected() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("outputs", workspace: workspace)

        await assertDocumentError(.validationFailed) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: nil,
                    expectedSourceSHA256: nil,
                    destinationPath: "outputs/non-regular.docx",
                    replaceExisting: false,
                    expectedDestinationSHA256: nil,
                    fileExtension: "docx",
                    maximumBytes: 1_024),
                workspace: workspace,
                produce: { payload in
                    try FileManager.default.createDirectory(
                        at: payload,
                        withIntermediateDirectories: false)
                },
                validate: { _ in })
        }
        XCTAssertFalse(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("outputs/non-regular.docx").path))
    }

    func testFileLargerThanEightMiBUsesConfiguredMaximum() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        let size = 9 * 1_024 * 1_024 + 17
        let maximum = UInt64(10 * 1_024 * 1_024)
        let data = Data(repeating: 0xA5, count: size)

        let receipt = try await writeFile(
            data,
            destinationPath: "docs/large.docx",
            workspace: workspace,
            maximumBytes: maximum)

        XCTAssertEqual(receipt.byteCount, UInt64(size))
        XCTAssertEqual(
            try Data(contentsOf: workspace.appendingPathComponent("docs/large.docx")),
            data)
    }

    func testPrecommitCancellationDoesNotInstallStagedFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        let destination = workspace.appendingPathComponent("docs/cancelled.docx")
        let gate = DocumentContinuationGate()
        let data = Data("cancel before commit".utf8)
        let request = DocumentStagedFileRequest(
            sourcePath: nil,
            expectedSourceSHA256: nil,
            destinationPath: "docs/cancelled.docx",
            replaceExisting: false,
            expectedDestinationSHA256: nil,
            fileExtension: "docx",
            maximumBytes: 1_024)

        let operation = Task {
            try await DocumentStagedOutput.writeFile(
                request,
                workspace: workspace,
                produce: { payload in
                    try data.write(to: payload)
                    await gate.suspend()
                },
                validate: { url in
                    guard try Data(contentsOf: url) == data else {
                        throw DocumentToolError(.validationFailed, "fixture read-back mismatch")
                    }
                })
        }
        await gate.waitUntilSuspended()
        operation.cancel()
        await gate.resume()

        do {
            _ = try await operation.value
            XCTFail("cancelled staged output unexpectedly committed")
        } catch is CancellationError {
            // Expected before the synchronous commit boundary.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        let docsContents = try fileManager.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        XCTAssertFalse(docsContents.contains {
            $0.lastPathComponent.hasPrefix(".intatis-document-stage-")
        })
    }

    func testAuxiliaryInputSameBytesReplacementFailsExactIdentityCAS() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        try makeParent("assets", workspace: workspace)
        let asset = workspace.appendingPathComponent("assets/logo.png")
        let original = Data("reviewed image bytes".utf8)
        try original.write(to: asset)
        let snapshot = try DocumentInputFile.freezeReadOnly(
            path: "assets/logo.png",
            workspace: workspace)
        let replacementBackup = workspace.appendingPathComponent("assets/logo.original.png")
        let destination = workspace.appendingPathComponent("docs/output.docx")

        await assertDocumentError(.outputConflict) {
            _ = try await self.writeFile(
                Data("generated document".utf8),
                destinationPath: "docs/output.docx",
                workspace: workspace,
                readOnlyInputSnapshots: [snapshot],
                produceMutation: {
                    try self.fileManager.moveItem(at: asset, to: replacementBackup)
                    // Restore the exact reviewed bytes at the reviewed path, but
                    // on a different inode. Digest-only CAS would accept this.
                    try original.write(to: asset)
                })
        }

        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: asset), original)
    }

    func testAuxiliaryInputHardlinkIsRejectedBeforeBackendInvocation() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        try makeParent("assets", workspace: workspace)
        let asset = workspace.appendingPathComponent("assets/logo.png")
        try Data("reviewed image bytes".utf8).write(to: asset)
        let snapshot = try DocumentInputFile.freezeReadOnly(
            path: "assets/logo.png",
            workspace: workspace)
        try fileManager.linkItem(
            at: asset,
            to: workspace.appendingPathComponent("assets/logo-hardlink.png"))
        let counter = DocumentInvocationCounter()

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: nil,
                    expectedSourceSHA256: nil,
                    destinationPath: "docs/output.docx",
                    replaceExisting: false,
                    expectedDestinationSHA256: nil,
                    fileExtension: "docx",
                    maximumBytes: 1_024,
                    readOnlyInputSnapshots: [snapshot]),
                workspace: workspace,
                produce: { payload in
                    await counter.record()
                    try Data("must not run".utf8).write(to: payload)
                },
                validate: { _ in })
        }

        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertFalse(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("docs/output.docx").path))
    }

    func testAuxiliaryInputSymlinkCannotBeFrozen() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("assets", workspace: workspace)
        let target = workspace.appendingPathComponent("assets/target.png")
        try Data("reviewed image bytes".utf8).write(to: target)
        try fileManager.createSymbolicLink(
            at: workspace.appendingPathComponent("assets/logo.png"),
            withDestinationURL: target)

        XCTAssertThrowsError(try DocumentInputFile.freezeReadOnly(
            path: "assets/logo.png",
            workspace: workspace)) { error in
            XCTAssertEqual((error as? DocumentToolError)?.code, .validationFailed)
        }
    }

    func testDestinationParentRenameAndSymlinkCannotRedirectCommit() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try makeParent("docs", workspace: workspace)
        try makeParent("attacker", workspace: workspace)
        let originalParent = workspace.appendingPathComponent("docs", isDirectory: true)
        let movedParent = workspace.appendingPathComponent("docs-moved", isDirectory: true)
        let attackerParent = workspace.appendingPathComponent("attacker", isDirectory: true)
        let generated = Data("generated document".utf8)

        await assertDocumentError(.outputConflict) {
            _ = try await DocumentStagedOutput.writeFile(
                DocumentStagedFileRequest(
                    sourcePath: nil,
                    expectedSourceSHA256: nil,
                    destinationPath: "docs/output.docx",
                    replaceExisting: false,
                    expectedDestinationSHA256: nil,
                    fileExtension: "docx",
                    maximumBytes: 1_024),
                workspace: workspace,
                produce: { payload in
                    // Populate the pinned stage first, then redirect the textual
                    // parent path and mirror a plausible stage under the symlink
                    // target so path-only validation still succeeds.
                    try generated.write(to: payload)
                    let stageName = payload.deletingLastPathComponent().lastPathComponent
                    try self.fileManager.moveItem(at: originalParent, to: movedParent)
                    try self.fileManager.createSymbolicLink(
                        at: originalParent,
                        withDestinationURL: attackerParent)
                    let decoyStage = attackerParent.appendingPathComponent(
                        stageName,
                        isDirectory: true)
                    try self.fileManager.createDirectory(
                        at: decoyStage,
                        withIntermediateDirectories: false)
                    try generated.write(to: decoyStage.appendingPathComponent(payload.lastPathComponent))
                },
                validate: { payload in
                    guard try Data(contentsOf: payload) == generated else {
                        throw DocumentToolError(.validationFailed, "fixture read-back mismatch")
                    }
                })
        }

        XCTAssertFalse(fileManager.fileExists(
            atPath: attackerParent.appendingPathComponent("output.docx").path))
        XCTAssertFalse(fileManager.fileExists(
            atPath: movedParent.appendingPathComponent("output.docx").path))
    }
}
