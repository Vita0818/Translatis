import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisTools requires CryptoKit or swift-crypto")
#endif
import IntatisCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum DocumentToolErrorCode: String, Codable, Sendable {
    case backendMissing = "backend_missing"
    case backendVersionMismatch = "backend_version_mismatch"
    case backendFailed = "backend_failed"
    case unsupportedOperation = "unsupported_operation"
    case unsupportedFeature = "unsupported_feature"
    case ocrRequired = "ocr_required"
    case validationFailed = "validation_failed"
    case renderFailed = "render_failed"
    case outputConflict = "output_conflict"
    case commitUncertain = "commit_uncertain"
}

struct DocumentToolError: Error, LocalizedError, Sendable {
    let code: DocumentToolErrorCode
    let summary: String

    init(_ code: DocumentToolErrorCode, _ summary: String) {
        self.code = code
        self.summary = summary
    }

    var errorDescription: String? { "\(code.rawValue): \(summary)" }
}

enum DocumentFormat: String, Sendable {
    case pdf, docx, pptx, xlsx, html, epub
}

struct DocumentFileSnapshot: Equatable, Sendable {
    let sha256: String
    let byteCount: UInt64
    let deviceID: UInt64
    let fileID: UInt64
}

struct DocumentCommitReceipt: Equatable, Sendable {
    let relativePath: String
    let sha256: String
    let byteCount: UInt64
}

struct DocumentInputSnapshot: Equatable, Sendable {
    let url: URL
    let identity: DocumentFileSnapshot
}

enum DocumentInputFile {
    static func freeze(
        path: String,
        expectedFormat: DocumentFormat,
        expectedSHA256: String? = nil,
        maximumBytes: UInt64 = 512 * 1_024 * 1_024,
        workspace: URL
    ) throws -> DocumentInputSnapshot {
        try validateDigest(expectedSHA256, field: "expected_source_sha256")
        let root = try PathConfinement.canonicalExistingDirectory(workspace)
        let url = try resolveDocumentInputPath(path, within: root)
        let actualExtension = url.pathExtension.lowercased()
        let allowedExtensions: Set<String> = expectedFormat == .html
            ? ["html", "htm"]
            : [expectedFormat.rawValue]
        guard allowedExtensions.contains(actualExtension) else {
            throw DocumentToolError(.validationFailed, "input extension does not match format")
        }
        let identity = try snapshotRegularFile(url, maximumBytes: maximumBytes)
        if let expectedSHA256,
           identity.sha256 != expectedSHA256.lowercased() {
            throw DocumentToolError(.outputConflict, "source digest does not match the reviewed input")
        }
        return DocumentInputSnapshot(url: url, identity: identity)
    }

    static func verifyUnchanged(_ snapshot: DocumentInputSnapshot) throws {
        let current = try snapshotRegularFile(
            snapshot.url,
            maximumBytes: snapshot.identity.byteCount)
        guard current == snapshot.identity else {
            throw DocumentToolError(.outputConflict, "source changed during document processing")
        }
    }

    /// Freezes an auxiliary input (for example an image referenced by a write
    /// operation) without imposing a document-format extension. Callers pass
    /// the returned snapshot into the staged request so the transaction checks
    /// the exact reviewed file both before backend work and inside the commit
    /// lock.
    static func freezeReadOnly(
        path: String,
        expectedSHA256: String? = nil,
        maximumBytes: UInt64 = 512 * 1_024 * 1_024,
        workspace: URL
    ) throws -> DocumentInputSnapshot {
        try validateDigest(expectedSHA256, field: "expected_input_sha256")
        let root = try PathConfinement.canonicalExistingDirectory(workspace)
        let url = try resolveDocumentInputPath(path, within: root)
        let identity = try snapshotRegularFile(url, maximumBytes: maximumBytes)
        if let expectedSHA256,
           identity.sha256 != expectedSHA256.lowercased() {
            throw DocumentToolError(.outputConflict, "read-only input digest does not match the reviewed input")
        }
        return DocumentInputSnapshot(url: url, identity: identity)
    }
}

struct DocumentStagedFileRequest: Sendable {
    let sourcePath: String?
    let expectedSourceSHA256: String?
    let destinationPath: String
    let replaceExisting: Bool
    let expectedDestinationSHA256: String?
    let fileExtension: String
    let maximumBytes: UInt64
    let readOnlyInputSnapshots: [DocumentInputSnapshot]

    init(
        sourcePath: String?,
        expectedSourceSHA256: String?,
        destinationPath: String,
        replaceExisting: Bool,
        expectedDestinationSHA256: String?,
        fileExtension: String,
        maximumBytes: UInt64,
        readOnlyInputSnapshots: [DocumentInputSnapshot] = []
    ) {
        self.sourcePath = sourcePath
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.destinationPath = destinationPath
        self.replaceExisting = replaceExisting
        self.expectedDestinationSHA256 = expectedDestinationSHA256
        self.fileExtension = fileExtension
        self.maximumBytes = maximumBytes
        self.readOnlyInputSnapshots = readOnlyInputSnapshots
    }
}

/// Host-owned staged output transaction for backend-generated documents.
/// The backend sees only a random same-parent stage. Validation and digesting
/// finish before the synchronous terminal commit begins; after that point no
/// cancellation check is performed until read-back reconciliation completes.
enum DocumentStagedOutput {
    static func writeFile(
        _ request: DocumentStagedFileRequest,
        workspace: URL,
        produce: @Sendable (URL) async throws -> Void,
        validate: @Sendable (URL) throws -> Void
    ) async throws -> DocumentCommitReceipt {
        try validateDigest(request.expectedSourceSHA256, field: "expected_source_sha256")
        try validateDigest(
            request.expectedDestinationSHA256,
            field: "expected_destination_sha256")
        guard request.maximumBytes > 0 else {
            throw DocumentToolError(.validationFailed, "maximum output size must be positive")
        }
        let locations = try preflightLocations(
            sourcePath: request.sourcePath,
            destinationPath: request.destinationPath,
            workspace: workspace)
        defer { _ = close(locations.parent.descriptor) }
        let baseline = try preflight(
            source: locations.source,
            expectedSourceSHA256: request.expectedSourceSHA256,
            readOnlyInputSnapshots: request.readOnlyInputSnapshots,
            destinationParent: locations.parent,
            destinationName: locations.destinationName,
            replaceExisting: request.replaceExisting,
            expectedDestinationSHA256: request.expectedDestinationSHA256)
        let stage = try createStageDirectory(parent: locations.parent)
        defer {
            _ = close(stage.descriptor)
            removeStageIfSafe(stage, parent: locations.parent)
        }
        let suffix = normalizedExtension(request.fileExtension)
        let payload = stage.url.appendingPathComponent("payload\(suffix)", isDirectory: false)
        let payloadName = payload.lastPathComponent
        try await produce(payload)
        try validate(payload)
        let staged = try snapshotRegularFile(
            at: stage.descriptor,
            name: payloadName,
            maximumBytes: request.maximumBytes)
        try Task.checkCancellation()

        return try commitFile(
            payloadName: payloadName,
            stage: stage,
            staged: staged,
            source: locations.source,
            destination: locations.destination,
            destinationParent: locations.parent,
            destinationName: locations.destinationName,
            baseline: baseline,
            replaceExisting: request.replaceExisting,
            workspace: workspace)
    }
}

private struct DocumentPreflightBaseline {
    let source: DocumentFileSnapshot?
    let readOnlyInputSnapshots: [DocumentInputSnapshot]
    let destinationFile: DocumentFileSnapshot?
    let destinationKind: DocumentDestinationKind
}

private enum DocumentDestinationKind: Equatable {
    case missing
    case file
}

private struct DocumentLocations {
    let source: URL?
    let destination: URL
    let parent: PinnedDirectory
    let destinationName: String
}

private struct PinnedDirectory {
    let url: URL
    let descriptor: Int32
    let identity: DirectoryIdentity
}

private func preflightLocations(
    sourcePath: String?,
    destinationPath: String,
    workspace: URL
) throws -> DocumentLocations {
    let root = try PathConfinement.canonicalExistingDirectory(workspace)
    let source = try sourcePath.map { try PathConfinement.resolve($0, within: root) }
    let destination = try PathConfinement.resolve(destinationPath, within: root)
    guard destination.path != root.path else {
        throw DocumentToolError(.validationFailed, "workspace root cannot be a document destination")
    }
    let parent = destination.deletingLastPathComponent()
    let descriptor = open(parent.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "destination parent must be an existing safe directory")
    }
    guard let identity = safeDirectoryIdentity(descriptor) else {
        _ = close(descriptor)
        throw DocumentToolError(.validationFailed, "destination parent must be an existing safe directory")
    }
    guard safeDirectoryIdentity(parent) == identity else {
        _ = close(descriptor)
        throw DocumentToolError(.validationFailed, "destination parent identity changed during preflight")
    }
    return DocumentLocations(
        source: source,
        destination: destination,
        parent: PinnedDirectory(url: parent, descriptor: descriptor, identity: identity),
        destinationName: destination.lastPathComponent)
}

private func preflight(
    source: URL?,
    expectedSourceSHA256: String?,
    readOnlyInputSnapshots: [DocumentInputSnapshot],
    destinationParent: PinnedDirectory,
    destinationName: String,
    replaceExisting: Bool,
    expectedDestinationSHA256: String?
) throws -> DocumentPreflightBaseline {
    let sourceSnapshot: DocumentFileSnapshot?
    if let source {
        sourceSnapshot = try snapshotRegularFile(source, maximumBytes: UInt64.max)
        if let expectedSourceSHA256,
           sourceSnapshot?.sha256 != expectedSourceSHA256.lowercased() {
            throw DocumentToolError(.outputConflict, "source digest does not match the reviewed input")
        }
    } else {
        sourceSnapshot = nil
        if expectedSourceSHA256 != nil {
            throw DocumentToolError(.validationFailed, "source digest requires source_path")
        }
    }

    try verifyReadOnlyInputs(readOnlyInputSnapshots, phase: "preflight")
    try verifyPinnedDirectoryPath(destinationParent)
    let destinationState = try destinationSnapshot(
        parentDescriptor: destinationParent.descriptor,
        name: destinationName)
    switch destinationState {
    case .missing:
        guard replaceExisting == false, expectedDestinationSHA256 == nil else {
            throw DocumentToolError(
                .outputConflict,
                "replacement was requested but the destination does not exist")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            readOnlyInputSnapshots: readOnlyInputSnapshots,
            destinationFile: nil,
            destinationKind: .missing)
    case .file(let snapshot):
        guard replaceExisting,
              let expectedDestinationSHA256,
              snapshot.sha256 == expectedDestinationSHA256.lowercased() else {
            throw DocumentToolError(
                .outputConflict,
                "existing destination requires replace_existing and its exact digest")
        }
        return DocumentPreflightBaseline(
            source: sourceSnapshot,
            readOnlyInputSnapshots: readOnlyInputSnapshots,
            destinationFile: snapshot,
            destinationKind: .file)
    case .directory:
        throw DocumentToolError(.outputConflict, "a document file cannot replace a directory")
    }
}

private enum DestinationSnapshot {
    case missing
    case file(DocumentFileSnapshot)
    case directory
}

private func destinationSnapshot(
    parentDescriptor: Int32,
    name: String
) throws -> DestinationSnapshot {
    var status = stat()
    let result = name.withCString {
        fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        if errno == ENOENT { return .missing }
        throw DocumentToolError(.validationFailed, "destination metadata could not be inspected")
    }
    switch status.st_mode & S_IFMT {
    case S_IFREG:
        let snapshot = try snapshotRegularFile(
            at: parentDescriptor,
            name: name,
            maximumBytes: UInt64.max)
        guard snapshot.deviceID == UInt64(status.st_dev),
              snapshot.fileID == UInt64(status.st_ino) else {
            throw DocumentToolError(.outputConflict, "destination changed while it was inspected")
        }
        return .file(snapshot)
    case S_IFDIR:
        return .directory
    default:
        throw DocumentToolError(.validationFailed, "destination must be a regular file or directory")
    }
}

private struct DocumentStage {
    let url: URL
    let name: String
    let descriptor: Int32
    let identity: DirectoryIdentity
}

private func createStageDirectory(parent: PinnedDirectory) throws -> DocumentStage {
    try verifyPinnedDirectoryPath(parent)
    guard safeDirectoryIdentity(parent.descriptor) == parent.identity else {
        throw DocumentToolError(.validationFailed, "destination parent identity changed")
    }
    for _ in 0..<8 {
        let name = "."
            + IntatisHostApplication.identity.temporaryPrefix(
                "document-stage-\(UUID().uuidString)")
        let created = name.withCString { mkdirat(parent.descriptor, $0, S_IRWXU) }
        if created == 0 {
            let descriptor: Int32 = name.withCString {
                openat(parent.descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
            }
            guard descriptor >= 0,
                  let identity = safeDirectoryIdentity(descriptor),
                  identity.permissions == UInt16(S_IRWXU) else {
                if descriptor >= 0 { _ = close(descriptor) }
                _ = name.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
                throw DocumentToolError(.validationFailed, "staging directory is unsafe")
            }
            return DocumentStage(
                url: parent.url.appendingPathComponent(name, isDirectory: true),
                name: name,
                descriptor: descriptor,
                identity: identity)
        }
        if errno != EEXIST { break }
    }
    throw DocumentToolError(.backendFailed, "could not create same-directory staging")
}

private func removeStageIfSafe(_ stage: DocumentStage, parent: PinnedDirectory) {
    let expectedPrefix = "."
        + IntatisHostApplication.identity.temporaryPrefix(
            "document-stage-")
    guard stage.name.hasPrefix(expectedPrefix) else { return }
    try? removeDirectoryTree(
        parentDescriptor: parent.descriptor,
        name: stage.name,
        expectedIdentity: stage.identity)
}

private struct DirectoryIdentity: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let permissions: UInt16
}

private func safeDirectoryIdentity(_ url: URL) -> DirectoryIdentity? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return DirectoryIdentity(
        deviceID: UInt64(status.st_dev),
        fileID: UInt64(status.st_ino),
        permissions: UInt16(status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)))
}

private func safeDirectoryIdentity(_ descriptor: Int32) -> DirectoryIdentity? {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return DirectoryIdentity(
        deviceID: UInt64(status.st_dev),
        fileID: UInt64(status.st_ino),
        permissions: UInt16(status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)))
}

private func verifyPinnedDirectoryPath(_ directory: PinnedDirectory) throws {
    guard safeDirectoryIdentity(directory.descriptor) == directory.identity,
          safeDirectoryIdentity(directory.url) == directory.identity else {
        throw DocumentToolError(.outputConflict, "destination parent changed during document processing")
    }
}

private func snapshotRegularFile(
    _ url: URL,
    maximumBytes: UInt64
) throws -> DocumentFileSnapshot {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "document file could not be opened safely")
    }
    defer { _ = close(descriptor) }
    return try snapshotRegularFile(descriptor, maximumBytes: maximumBytes)
}

private func snapshotRegularFile(
    at directoryDescriptor: Int32,
    name: String,
    maximumBytes: UInt64
) throws -> DocumentFileSnapshot {
    let descriptor: Int32 = name.withCString {
        openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "document file could not be opened safely")
    }
    defer { _ = close(descriptor) }
    return try snapshotRegularFile(descriptor, maximumBytes: maximumBytes)
}

private func snapshotRegularFile(
    _ descriptor: Int32,
    maximumBytes: UInt64
) throws -> DocumentFileSnapshot {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          status.st_size >= 0 else {
        throw DocumentToolError(.validationFailed, "document output is not a safe single-link regular file")
    }
    let byteCount = UInt64(status.st_size)
    guard byteCount <= maximumBytes else {
        throw DocumentToolError(.validationFailed, "document output exceeds the configured byte limit")
    }
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw DocumentToolError(.validationFailed, "document output could not be read for digesting")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return read(descriptor, base, raw.count)
        }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw DocumentToolError(.validationFailed, "document output digest read failed")
        }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          UInt64(status.st_size) == byteCount else {
        throw DocumentToolError(.validationFailed, "document output changed while it was validated")
    }
    return DocumentFileSnapshot(
        sha256: hexadecimal(hasher.finalize()),
        byteCount: byteCount,
        deviceID: UInt64(status.st_dev),
        fileID: UInt64(status.st_ino))
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
            to: CChar.self,
            capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
            String(cString: $0)
        }
    }
}

private func openDirectory(at parentDescriptor: Int32, name: String) throws -> Int32 {
    let descriptor: Int32 = name.withCString {
        openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    }
    guard descriptor >= 0,
          safeDirectoryIdentity(descriptor) != nil else {
        if descriptor >= 0 { _ = close(descriptor) }
        throw DocumentToolError(.validationFailed, "document directory could not be opened safely")
    }
    return descriptor
}

private func commitFile(
    payloadName: String,
    stage: DocumentStage,
    staged: DocumentFileSnapshot,
    source: URL?,
    destination: URL,
    destinationParent: PinnedDirectory,
    destinationName: String,
    baseline: DocumentPreflightBaseline,
    replaceExisting: Bool,
    workspace: URL
) throws -> DocumentCommitReceipt {
    try verifyPinnedDirectoryPath(destinationParent)
    let lock = documentLockURL(destination: destination)
    return try DurableOwnerOnlyFile.withExclusiveLock(at: lock) {
        try verifyPinnedDirectoryPath(destinationParent)
        try recheckPreconditions(
            source: source,
            destinationParent: destinationParent,
            destinationName: destinationName,
            baseline: baseline)
        let stageNow = try snapshotRegularFile(
            at: stage.descriptor,
            name: payloadName,
            maximumBytes: staged.byteCount)
        guard stageNow == staged else {
            throw DocumentToolError(.validationFailed, "staged output changed before commit")
        }
        try synchronizeRegularFile(at: stage.descriptor, name: payloadName)

        var commitStarted = false
        do {
            if replaceExisting {
                let renamed = payloadName.withCString { payloadPointer in
                    destinationName.withCString { destinationPointer in
                        renameat(
                            stage.descriptor,
                            payloadPointer,
                            destinationParent.descriptor,
                            destinationPointer)
                    }
                }
                guard renamed == 0 else {
                    throw DocumentToolError(.backendFailed, "atomic document replacement failed")
                }
            } else {
                try installFileExclusively(
                    payloadDirectoryDescriptor: stage.descriptor,
                    payloadName: payloadName,
                    destinationParentDescriptor: destinationParent.descriptor,
                    destinationName: destinationName)
            }
            commitStarted = true
            guard synchronizeRegularFileIfPresent(
                    at: destinationParent.descriptor,
                    name: destinationName),
                  fsync(destinationParent.descriptor) == 0 else {
                throw DocumentToolError(.commitUncertain, "installed document could not be synchronized")
            }
            let installed = try snapshotRegularFile(
                at: destinationParent.descriptor,
                name: destinationName,
                maximumBytes: staged.byteCount)
            guard installed == staged else {
                throw DocumentToolError(.commitUncertain, "installed document does not match staged bytes")
            }
            try verifyPinnedDirectoryPath(destinationParent)
            return DocumentCommitReceipt(
                relativePath: PathConfinement.relativePath(of: destination, root: workspace),
                sha256: installed.sha256,
                byteCount: installed.byteCount)
        } catch let error as DocumentToolError {
            if commitStarted, error.code != .commitUncertain {
                throw DocumentToolError(.commitUncertain, "document commit began but reconciliation failed")
            }
            throw error
        } catch {
            throw DocumentToolError(
                commitStarted ? .commitUncertain : .backendFailed,
                commitStarted
                    ? "document commit began but reconciliation failed"
                    : "document could not be atomically installed")
        }
    }
}

private func recheckPreconditions(
    source: URL?,
    destinationParent: PinnedDirectory,
    destinationName: String,
    baseline: DocumentPreflightBaseline
) throws {
    if let source, let expected = baseline.source {
        let current = try snapshotRegularFile(source, maximumBytes: expected.byteCount)
        guard current == expected else {
            throw DocumentToolError(.outputConflict, "source changed before commit")
        }
    }
    try verifyReadOnlyInputs(baseline.readOnlyInputSnapshots, phase: "commit")
    try verifyPinnedDirectoryPath(destinationParent)
    let current = try destinationSnapshot(
        parentDescriptor: destinationParent.descriptor,
        name: destinationName)
    switch (baseline.destinationKind, current) {
    case (.missing, .missing):
        return
    case (.file, .file(let snapshot)) where snapshot == baseline.destinationFile:
        return
    default:
        throw DocumentToolError(.outputConflict, "destination changed before commit")
    }
}

private func documentLockURL(destination: URL) -> URL {
    let digest = hexadecimal(SHA256.hash(data: Data(destination.path.utf8)))
    return destination.deletingLastPathComponent().appendingPathComponent(
        "." + IntatisHostApplication.identity.temporaryPrefix(
            "document-lock-\(digest).lock"),
        isDirectory: false)
}

private func verifyReadOnlyInputs(
    _ snapshots: [DocumentInputSnapshot],
    phase: String
) throws {
    for snapshot in snapshots {
        do {
            let current = try snapshotRegularFile(
                snapshot.url,
                maximumBytes: snapshot.identity.byteCount)
            guard current == snapshot.identity else {
                throw DocumentToolError(
                    .outputConflict,
                    "read-only input changed during document processing")
            }
        } catch let error as DocumentToolError where error.code == .outputConflict {
            throw error
        } catch {
            throw DocumentToolError(
                .outputConflict,
                "read-only input failed the \(phase) identity check")
        }
    }
}

private func installFileExclusively(
    payloadDirectoryDescriptor: Int32,
    payloadName: String,
    destinationParentDescriptor: Int32,
    destinationName: String
) throws {
    #if canImport(Darwin)
    let result = payloadName.withCString { payloadPointer in
        destinationName.withCString { destinationPointer in
            renameatx_np(
                payloadDirectoryDescriptor,
                payloadPointer,
                destinationParentDescriptor,
                destinationPointer,
                UInt32(RENAME_EXCL))
        }
    }
    guard result == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "destination appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic document creation failed")
    }
    #else
    let linked = payloadName.withCString { payloadPointer in
        destinationName.withCString { destinationPointer in
            linkat(
                payloadDirectoryDescriptor,
                payloadPointer,
                destinationParentDescriptor,
                destinationPointer,
                0)
        }
    }
    guard linked == 0 else {
        if errno == EEXIST {
            throw DocumentToolError(.outputConflict, "destination appeared before commit")
        }
        throw DocumentToolError(.backendFailed, "atomic document creation failed")
    }
    guard payloadName.withCString({ unlinkat(payloadDirectoryDescriptor, $0, 0) }) == 0 else {
        throw DocumentToolError(.commitUncertain, "document was linked but staging cleanup failed")
    }
    #endif
}

private func synchronizeRegularFile(at directoryDescriptor: Int32, name: String) throws {
    let descriptor: Int32 = name.withCString {
        openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw DocumentToolError(.validationFailed, "staged document could not be reopened")
    }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          fsync(descriptor) == 0 else {
        throw DocumentToolError(.validationFailed, "staged document could not be synchronized")
    }
}

private func synchronizeRegularFileIfPresent(
    at directoryDescriptor: Int32,
    name: String
) -> Bool {
    (try? synchronizeRegularFile(at: directoryDescriptor, name: name)) != nil
}

private func removeDirectoryTree(
    parentDescriptor: Int32,
    name: String,
    expectedIdentity: DirectoryIdentity
) throws {
    let descriptor = try openDirectory(at: parentDescriptor, name: name)
    defer { _ = close(descriptor) }
    guard safeDirectoryIdentity(descriptor) == expectedIdentity else {
        throw DocumentToolError(.validationFailed, "staging directory identity changed before cleanup")
    }
    try removeDirectoryContents(descriptor)
    guard name.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
        throw DocumentToolError(.backendFailed, "staging directory could not be removed")
    }
}

private func removeDirectoryContents(_ descriptor: Int32) throws {
    let enumerationDescriptor = openat(
        descriptor,
        ".",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard enumerationDescriptor >= 0,
          let directory = fdopendir(enumerationDescriptor) else {
        if enumerationDescriptor >= 0 { _ = close(enumerationDescriptor) }
        throw DocumentToolError(.backendFailed, "staging directory could not be enumerated for cleanup")
    }
    defer { _ = closedir(directory) }

    while let entry = readdir(directory) {
        let name = directoryEntryName(entry)
        if name == "." || name == ".." { continue }
        var status = stat()
        let inspected = name.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0 else {
            throw DocumentToolError(.backendFailed, "staging entry changed during cleanup")
        }
        if (status.st_mode & S_IFMT) == S_IFDIR {
            let child = try openDirectory(at: descriptor, name: name)
            defer { _ = close(child) }
            try removeDirectoryContents(child)
            guard name.withCString({ unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                throw DocumentToolError(.backendFailed, "staging subdirectory could not be removed")
            }
        } else {
            guard name.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                throw DocumentToolError(.backendFailed, "staging entry could not be removed")
            }
        }
    }
}

private func resolveDocumentInputPath(_ path: String, within root: URL) throws -> URL {
    let lexical: URL
    if path.hasPrefix("~") {
        lexical = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    } else if path.hasPrefix("/") {
        lexical = URL(fileURLWithPath: path).standardizedFileURL
    } else {
        lexical = root.appendingPathComponent(path).standardizedFileURL
    }
    let resolved = try PathConfinement.resolve(path, within: root)
    guard lexical.path == resolved.path else {
        throw DocumentToolError(.validationFailed, "document inputs cannot traverse symbolic links")
    }
    return resolved
}

private func validateDigest(_ value: String?, field: String) throws {
    guard let value else { return }
    guard value.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
        throw DocumentToolError(.validationFailed, "\(field) must be a SHA-256 hex digest")
    }
}

private func normalizedExtension(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard trimmed.isEmpty == false,
          trimmed.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil else {
        return ""
    }
    return ".\(trimmed.lowercased())"
}

private func hexadecimal<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
