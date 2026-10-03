import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Strict grammar used by both the on-disk store pointer and host admission.
/// Keeping this check out of model-visible code prevents a snapshot name from
/// becoming a path traversal primitive.
public enum KnowledgeStoreIdentifier {
    public static func isValidStoreID(_ value: String) -> Bool {
        value.range(
            of: #"^kb_[A-Za-z0-9._-]{1,125}$"#,
            options: .regularExpression) != nil
    }

    public static func isValidSnapshotID(_ value: String) -> Bool {
        value.range(
            of: #"^snap_[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression) != nil
    }

    public static func makeSnapshotID() -> String {
        "snap_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

public struct KnowledgeStagingSnapshot: Sendable {
    public let snapshotID: String
    public let root: URL

    fileprivate let storeIdentity: WorkspaceRootIdentity
    fileprivate let writerNonce: UUID
}

public struct KnowledgeSnapshotGarbageCollectionPolicy: Equatable, Sendable {
    /// A newly replaced snapshot is retained for at least this interval even
    /// after its readers drain. Operational timestamps are deliberately not
    /// part of the retrieval snapshot identity.
    public var minimumRetainedAge: TimeInterval
    /// Number of newest non-current snapshots retained regardless of age.
    public var retainNewestNonCurrent: Int
    public var maximumRemovals: Int
    /// Crash-left staging directories older than this interval are eligible
    /// for cleanup. `nil` leaves all staging state untouched.
    public var abandonedStagingAge: TimeInterval?

    public init(minimumRetainedAge: TimeInterval = 24 * 60 * 60,
                retainNewestNonCurrent: Int = 1,
                maximumRemovals: Int = 32,
                abandonedStagingAge: TimeInterval? = 24 * 60 * 60) {
        self.minimumRetainedAge = max(0, minimumRetainedAge)
        self.retainNewestNonCurrent = max(0, retainNewestNonCurrent)
        self.maximumRemovals = max(0, maximumRemovals)
        self.abandonedStagingAge = abandonedStagingAge.map { max(0, $0) }
    }
}

public struct KnowledgeSnapshotGarbageCollectionResult: Equatable, Sendable {
    public let removedSnapshotIDs: [String]
    public let removedStagingDirectories: [String]
    public let skippedCurrentSnapshotIDs: [String]
    public let skippedProtectedSnapshotIDs: [String]
    public let skippedActiveReaderSnapshotIDs: [String]
    public let skippedRetentionSnapshotIDs: [String]
}

public enum KnowledgeSnapshotAdmissionKind: String, Equatable, Sendable {
    case current
    case explicitExact = "explicit_exact"
}

/// A stable shared lock plus an open directory descriptor pins one exact
/// immutable snapshot for the duration of a query. Pointer changes do not
/// invalidate an already admitted reader, while replacement or mutation of
/// the pinned directory is detected by `verifyStable()`.
public final class KnowledgeSnapshotReaderLease: @unchecked Sendable {
    public let pointer: KnowledgeStorePointer
    public let admissionKind: KnowledgeSnapshotAdmissionKind
    public let admittedSnapshotID: String
    public let admittedSnapshotRevision: String
    public let snapshotRoot: URL
    public let snapshotRootIdentity: WorkspaceRootIdentity

    private let state = KnowledgeReaderLeaseState()

    fileprivate init(pointer: KnowledgeStorePointer,
                     admissionKind: KnowledgeSnapshotAdmissionKind,
                     admittedSnapshotID: String,
                     admittedSnapshotRevision: String,
                     snapshotRoot: URL,
                     snapshotRootIdentity: WorkspaceRootIdentity,
                     directoryDescriptor: Int32,
                     lock: KnowledgeAdvisoryFileLock,
                     admissionLock: KnowledgeAdvisoryFileLock?) {
        self.pointer = pointer
        self.admissionKind = admissionKind
        self.admittedSnapshotID = admittedSnapshotID
        self.admittedSnapshotRevision = admittedSnapshotRevision
        self.snapshotRoot = snapshotRoot
        self.snapshotRootIdentity = snapshotRootIdentity
        state.install(
            directoryDescriptor: directoryDescriptor,
            lock: lock,
            admissionLock: admissionLock)
    }

    public func verifyStable() throws {
        try state.withActiveDescriptor { descriptor in
            var openStatus = stat()
            var installedStatus = stat()
            guard fstat(descriptor, &openStatus) == 0,
                  lstat(snapshotRoot.path, &installedStatus) == 0,
                  (openStatus.st_mode & S_IFMT) == S_IFDIR,
                  (installedStatus.st_mode & S_IFMT) == S_IFDIR,
                  openStatus.st_uid == geteuid(),
                  installedStatus.st_uid == geteuid(),
                  openStatus.st_dev == installedStatus.st_dev,
                  openStatus.st_ino == installedStatus.st_ino,
                  (installedStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  WorkspaceRootIdentity.capture(rootPath: snapshotRoot.path)
                    == snapshotRootIdentity else {
                throw KnowledgeDomainError(
                    .revisionChanged,
                    retryable: true,
                    "Knowledge snapshot identity changed while a reader was active.")
            }
        }
    }

    public func release() {
        state.release()
    }

    /// Ends the short store-pointer admission critical section while keeping
    /// the exact snapshot reader lock and directory descriptor pinned.
    public func completeAdmission() {
        state.completeAdmission()
    }

    deinit {
        release()
    }
}

private final class KnowledgeReaderLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var directoryDescriptor: Int32 = -1
    private var advisoryLock: KnowledgeAdvisoryFileLock?
    private var admissionLock: KnowledgeAdvisoryFileLock?

    func install(directoryDescriptor: Int32,
                 lock advisoryLock: KnowledgeAdvisoryFileLock,
                 admissionLock: KnowledgeAdvisoryFileLock?) {
        lock.lock()
        self.directoryDescriptor = directoryDescriptor
        self.advisoryLock = advisoryLock
        self.admissionLock = admissionLock
        lock.unlock()
    }

    func withActiveDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard directoryDescriptor >= 0 else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge snapshot reader lease is no longer active.")
        }
        return try body(directoryDescriptor)
    }

    func release() {
        let descriptor: Int32
        let lease: KnowledgeAdvisoryFileLock?
        let admission: KnowledgeAdvisoryFileLock?
        lock.lock()
        descriptor = directoryDescriptor
        directoryDescriptor = -1
        lease = advisoryLock
        advisoryLock = nil
        admission = admissionLock
        admissionLock = nil
        lock.unlock()
        if descriptor >= 0 { _ = close(descriptor) }
        lease?.release()
        admission?.release()
    }

    func completeAdmission() {
        lock.lock()
        let admission = admissionLock
        admissionLock = nil
        lock.unlock()
        admission?.release()
    }
}

/// Stable wrapper around one user-selected, multi-version knowledge store.
/// It captures both the reviewed workspace authority and the exact store root
/// inode. Every operation revalidates both identities before using a path.
public struct KnowledgeSnapshotStore: Sendable {
    /// Reserved host-owned component. General workspace leases deny this
    /// component at every executor boundary; only the Knowledge store writer
    /// and reader operate below it.
    public static var publishedSnapshotsDirectoryName: String {
        KnowledgeHostIdentity.snapshotsDirectory
    }
    /// Pre-product core builds used this generic component. It is never opened
    /// in place because ordinary workspace tools could address it; an exact
    /// read-write Knowledge writer must migrate it under the store lock first.
    static let legacyPublishedSnapshotsDirectoryName = "snapshots"

    public let root: URL
    public let coordinationRoot: URL
    public let workspaceLeaseID: WorkspaceLeaseID
    public let workspaceRootIdentity: WorkspaceRootIdentity
    public let storeRootIdentity: WorkspaceRootIdentity
    public let coordinationRootIdentity: WorkspaceRootIdentity

    let workspaceLease: WorkspaceLease
    let fileSystem: KnowledgeSecureFileSystem
    private let pointerWriteOperation:
        @Sendable (Data, URL, String) throws -> Void

    private var snapshotsRoot: URL {
        root.appendingPathComponent(
            Self.publishedSnapshotsDirectoryName,
            isDirectory: true)
    }

    private var stagingRoot: URL {
        snapshotsRoot.appendingPathComponent(".staging", isDirectory: true)
    }

    private var pointerURL: URL {
        root.appendingPathComponent(
            KnowledgeHostIdentity.storeFile,
            isDirectory: false)
    }

    /// Knowledge-internal projection used only after the store root itself has
    /// passed the exact reviewed workspace/Knowledge authority check. General
    /// tools keep the original lease and therefore cannot use this projection
    /// to enter the host-owned publication components.
    var managedContentWorkspaceLease: WorkspaceLease {
        var projected = workspaceLease
        let managed = Set(
            WorkspaceLease.mandatoryManagedStoreDeniedPatterns.map {
                $0.lowercased()
            })
        projected.deniedPatterns.removeAll {
            managed.contains($0.lowercased())
        }
        return projected
    }

    private var storeLockURL: URL {
        coordinationRoot.appendingPathComponent("store.lock", isDirectory: false)
    }

    public init(root requestedRoot: URL,
                workspaceLease: WorkspaceLease,
                coordinationRoot requestedCoordinationRoot: URL? = nil,
                createIfMissing: Bool = false,
                fileSystem: KnowledgeSecureFileSystem = KnowledgeSecureFileSystem()) throws {
        try self.init(
            root: requestedRoot,
            workspaceLease: workspaceLease,
            coordinationRoot: requestedCoordinationRoot,
            createIfMissing: createIfMissing,
            fileSystem: fileSystem,
            pointerWriteOperation: { data, url, temporaryPrefix in
                try DurableOwnerOnlyFile.writeAtomically(
                    data,
                    to: url,
                    temporaryPrefix: temporaryPrefix)
            })
    }

    /// Internal deterministic fault seam for proving the post-rename pointer
    /// commit-uncertain contract. Shipping clients always use the public
    /// initializer above and therefore the hardened durable writer.
    init(root requestedRoot: URL,
         workspaceLease: WorkspaceLease,
         coordinationRoot requestedCoordinationRoot: URL? = nil,
         createIfMissing: Bool = false,
         fileSystem: KnowledgeSecureFileSystem = KnowledgeSecureFileSystem(),
         pointerWriteOperation:
            @escaping @Sendable (Data, URL, String) throws -> Void) throws {
        guard let workspaceIdentity = workspaceLease.rootIdentity,
              workspaceIdentity.matchesCurrentDirectory(rootPath: workspaceLease.rootPath) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge store workspace authority is unavailable or changed.")
        }
        let workspaceCanonical = URL(
            fileURLWithPath: workspaceIdentity.canonicalPath,
            isDirectory: true)
        let standardized = URL(
            fileURLWithPath: (requestedRoot.path as NSString).expandingTildeInPath,
            isDirectory: true).standardizedFileURL
        guard PathConfinement.isWithin(standardized.path, root: workspaceCanonical) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge store is outside the active workspace lease.")
        }

        if !FileManager.default.fileExists(atPath: standardized.path) {
            guard createIfMissing, workspaceLease.access == .readWrite else {
                throw KnowledgeDomainError(
                    .indexNotReady,
                    retryable: true,
                    "Knowledge store does not exist.")
            }
            try FileManager.default.createDirectory(
                at: standardized,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            guard chmod(standardized.path, S_IRWXU) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge store permissions could not be secured.")
            }
        }

        let authorized = try fileSystem.authorizeRoot(
            standardized,
            workspaceLease: workspaceLease)
        guard PathConfinement.isWithin(
                authorized.canonical.path,
                root: workspaceCanonical) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge store canonical path escapes the active workspace lease.")
        }

        let coordination = requestedCoordinationRoot.map {
            URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        } ?? authorized.canonical.appendingPathComponent(
            KnowledgeHostIdentity.hostDirectory,
            isDirectory: true)
        if !FileManager.default.fileExists(atPath: coordination.path) {
            guard createIfMissing, workspaceLease.access == .readWrite else {
                throw KnowledgeDomainError(
                    .indexNotReady,
                    retryable: true,
                    "Knowledge store coordination directory is missing.")
            }
            try Self.createOwnedDirectory(coordination)
        }
        let validatedCoordination = try DurableOwnerOnlyFile
            .validateOwnedDirectory(at: coordination)
        guard let coordinationIdentity = WorkspaceRootIdentity.capture(
                rootPath: validatedCoordination.path) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge coordination directory identity is unavailable.")
        }

        let snapshots = authorized.canonical.appendingPathComponent(
            Self.publishedSnapshotsDirectoryName,
            isDirectory: true)
        let legacySnapshots = authorized.canonical.appendingPathComponent(
            Self.legacyPublishedSnapshotsDirectoryName,
            isDirectory: true)
        var hasSnapshots = FileManager.default.fileExists(
            atPath: snapshots.path)
        var hasLegacySnapshots = FileManager.default.fileExists(
            atPath: legacySnapshots.path)
        guard !(hasSnapshots && hasLegacySnapshots) else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge store contains ambiguous current and legacy snapshot directories.")
        }
        if hasLegacySnapshots {
            guard createIfMissing, workspaceLease.access == .readWrite else {
                throw KnowledgeDomainError(
                    .indexNotReady,
                    retryable: false,
                    "Knowledge store uses a legacy snapshot layout and requires an explicit build/update migration.")
            }
            let validatedLegacy = try DurableOwnerOnlyFile
                .validateOwnedDirectory(at: legacySnapshots)
            guard let legacyIdentity = WorkspaceRootIdentity.capture(
                    rootPath: validatedLegacy.path) else {
                throw KnowledgeDomainError(
                    .unsafeStorage,
                    "Legacy knowledge snapshot identity is unavailable.")
            }
            guard let migrationLock = try KnowledgeAdvisoryFileLock.acquire(
                at: validatedCoordination.appendingPathComponent(
                    "store.lock",
                    isDirectory: false),
                mode: .exclusive,
                blocking: true,
                expectedParentIdentity: coordinationIdentity) else {
                throw KnowledgeDomainError(
                    .searchTimeout,
                    retryable: true,
                    "Knowledge legacy-layout migration could not acquire its writer lock.")
            }
            defer { migrationLock.release() }
            hasSnapshots = FileManager.default.fileExists(atPath: snapshots.path)
            hasLegacySnapshots = FileManager.default.fileExists(
                atPath: legacySnapshots.path)
            guard !(hasSnapshots && hasLegacySnapshots) else {
                throw KnowledgeDomainError(
                    .unsafeStorage,
                    "Knowledge store layout changed ambiguously during migration.")
            }
            if hasLegacySnapshots {
                guard rename(legacySnapshots.path, snapshots.path) == 0 else {
                    throw KnowledgeDomainError(
                        .unsafeStorage,
                        "Legacy knowledge snapshots could not be atomically migrated.")
                }
                guard let migratedIdentity = WorkspaceRootIdentity.capture(
                        rootPath: snapshots.path),
                      migratedIdentity.deviceID == legacyIdentity.deviceID,
                      migratedIdentity.fileID == legacyIdentity.fileID else {
                    throw KnowledgeDomainError(
                        .commitUncertain,
                        retryable: false,
                        "Legacy knowledge snapshot migration may have committed and requires disk reconciliation.")
                }
                do {
                    try KnowledgeSnapshotDurability.synchronizeDirectory(
                        authorized.canonical)
                } catch {
                    throw KnowledgeDomainError(
                        .commitUncertain,
                        retryable: false,
                        "Legacy knowledge snapshot migration may have committed and requires disk reconciliation.")
                }
                hasSnapshots = true
            }
        }

        if !hasSnapshots {
            guard createIfMissing, workspaceLease.access == .readWrite else {
                throw KnowledgeDomainError(
                    .indexNotReady,
                    retryable: true,
                    "Knowledge store snapshot directory is missing.")
            }
            try Self.createOwnedDirectory(snapshots)
            try Self.createOwnedDirectory(
                snapshots.appendingPathComponent(".staging", isDirectory: true))
        } else {
            _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: snapshots)
            let staging = snapshots.appendingPathComponent(".staging", isDirectory: true)
            if !FileManager.default.fileExists(atPath: staging.path), createIfMissing {
                try Self.createOwnedDirectory(staging)
            }
        }

        self.root = authorized.canonical
        coordinationRoot = validatedCoordination
        workspaceLeaseID = workspaceLease.id
        workspaceRootIdentity = workspaceIdentity
        storeRootIdentity = authorized.identity
        coordinationRootIdentity = coordinationIdentity
        self.workspaceLease = workspaceLease
        self.fileSystem = fileSystem
        self.pointerWriteOperation = pointerWriteOperation
    }

    public func loadCurrentPointer() throws -> KnowledgeStorePointer {
        try revalidateStoreAuthority()
        guard let lock = try KnowledgeAdvisoryFileLock.acquire(
            at: storeLockURL,
            mode: .shared,
            blocking: true,
            expectedParentIdentity: coordinationRootIdentity) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store lock could not be acquired.")
        }
        defer { lock.release() }
        guard let pointer = try readPointerWithoutLock() else {
            throw KnowledgeDomainError(
                .indexNotReady,
                retryable: true,
                "Knowledge store has no published snapshot.")
        }
        return pointer
    }

    public func acquireCurrentReaderLease(
        holdStoreAdmissionThroughValidation: Bool = false
    ) throws -> KnowledgeSnapshotReaderLease {
        try acquireReaderLease(
            selection: .current,
            holdStoreAdmissionThroughValidation: holdStoreAdmissionThroughValidation)
    }

    /// Host-only A/B admission for one exact retained snapshot. This never
    /// scans retained snapshots or selects a compatible fallback: the caller
    /// must provide exact store/snapshot identities and the validator must
    /// prove that exact revision before the handle is signed.
    public func acquireExplicitSnapshotReaderLease(
        storeID: String,
        snapshotID: String,
        snapshotRevision: String,
        holdStoreAdmissionThroughValidation: Bool = false
    ) throws -> KnowledgeSnapshotReaderLease {
        guard KnowledgeStoreIdentifier.isValidStoreID(storeID),
              KnowledgeStoreIdentifier.isValidSnapshotID(snapshotID),
              KnowledgeDigest.isValid(snapshotRevision) else {
            throw KnowledgeDomainError(.profileInvalid, "Explicit knowledge snapshot admission is invalid.")
        }
        return try acquireReaderLease(
            selection: .explicit(
                storeID: storeID,
                snapshotID: snapshotID,
                snapshotRevision: snapshotRevision),
            holdStoreAdmissionThroughValidation: holdStoreAdmissionThroughValidation)
    }

    private enum ReaderSelection {
        case current
        case explicit(storeID: String, snapshotID: String, snapshotRevision: String)
    }

    private func acquireReaderLease(
        selection: ReaderSelection,
        holdStoreAdmissionThroughValidation: Bool
    ) throws -> KnowledgeSnapshotReaderLease {
        try revalidateStoreAuthority()
        guard let admissionLock = try KnowledgeAdvisoryFileLock.acquire(
            at: storeLockURL,
            mode: .shared,
            blocking: true,
            expectedParentIdentity: coordinationRootIdentity) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store admission lock could not be acquired.")
        }
        var shouldReleaseAdmissionLock = true
        defer {
            if shouldReleaseAdmissionLock { admissionLock.release() }
        }

        guard let pointer = try readPointerWithoutLock() else {
            throw KnowledgeDomainError(
                .indexNotReady,
                retryable: true,
                "Knowledge store has no published snapshot.")
        }
        let admissionKind: KnowledgeSnapshotAdmissionKind
        let snapshotID: String
        let snapshotRevision: String
        switch selection {
        case .current:
            admissionKind = .current
            snapshotID = pointer.currentSnapshot
            snapshotRevision = pointer.currentSnapshotRevision
        case .explicit(let expectedStoreID, let exactSnapshotID, let exactRevision):
            guard pointer.storeID == expectedStoreID else {
                throw KnowledgeDomainError(
                    .revisionChanged,
                    retryable: true,
                    "Knowledge store identity changed before explicit admission.")
            }
            admissionKind = .explicitExact
            snapshotID = exactSnapshotID
            snapshotRevision = exactRevision
        }
        let snapshotRoot = try exactSnapshotRoot(snapshotID)
        guard let readerLock = try KnowledgeAdvisoryFileLock.acquire(
            at: snapshotLockURL(snapshotID),
            mode: .shared,
            blocking: true,
            expectedParentIdentity: coordinationRootIdentity) else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge snapshot could not be pinned.")
        }
        var shouldReleaseReaderLock = true
        defer {
            if shouldReleaseReaderLock { readerLock.release() }
        }

        let descriptor = open(snapshotRoot.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge snapshot directory could not be opened safely.")
        }
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor { _ = close(descriptor) }
        }
        guard let snapshotIdentity = WorkspaceRootIdentity.capture(
                rootPath: snapshotRoot.path) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot identity is unavailable.")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              UInt64(status.st_dev) == snapshotIdentity.deviceID,
              UInt64(status.st_ino) == snapshotIdentity.fileID else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot directory is unsafe.")
        }

        shouldReleaseReaderLock = false
        shouldCloseDescriptor = false
        if holdStoreAdmissionThroughValidation {
            shouldReleaseAdmissionLock = false
        }
        return KnowledgeSnapshotReaderLease(
            pointer: pointer,
            admissionKind: admissionKind,
            admittedSnapshotID: snapshotID,
            admittedSnapshotRevision: snapshotRevision,
            snapshotRoot: snapshotRoot,
            snapshotRootIdentity: snapshotIdentity,
            directoryDescriptor: descriptor,
            lock: readerLock,
            admissionLock: holdStoreAdmissionThroughValidation
                ? admissionLock
                : nil)
    }

    public func acquireWriterLease() throws -> KnowledgeStoreWriterLease {
        try revalidateStoreAuthority()
        guard workspaceLease.access == .readWrite else {
            throw KnowledgeDomainError(.accessDenied, "Knowledge store writer requires a read-write workspace lease.")
        }
        guard let lock = try KnowledgeAdvisoryFileLock.acquire(
            at: storeLockURL,
            mode: .exclusive,
            blocking: true,
            expectedParentIdentity: coordinationRootIdentity) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store writer lock could not be acquired.")
        }
        do {
            try revalidateStoreAuthority()
            return KnowledgeStoreWriterLease(store: self, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    public func tryAcquireWriterLease() throws -> KnowledgeStoreWriterLease? {
        try revalidateStoreAuthority()
        guard workspaceLease.access == .readWrite else {
            throw KnowledgeDomainError(.accessDenied, "Knowledge store writer requires a read-write workspace lease.")
        }
        guard let lock = try KnowledgeAdvisoryFileLock.acquire(
            at: storeLockURL,
            mode: .exclusive,
            blocking: false,
            expectedParentIdentity: coordinationRootIdentity) else {
            return nil
        }
        do {
            try revalidateStoreAuthority()
            return KnowledgeStoreWriterLease(store: self, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    fileprivate func readPointerWithoutLock() throws -> KnowledgeStorePointer? {
        let data: Data?
        do {
            data = try DurableOwnerOnlyFile.read(from: pointerURL)
        } catch {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store pointer is not a safe owner-only file.")
        }
        guard let data else { return nil }
        guard data.count <= 16 * 1_024 else {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge store pointer exceeds its byte limit.")
        }
        return try KnowledgeStorePointerCodec.decode(data)
    }

    fileprivate func writePointerWithoutLock(_ pointer: KnowledgeStorePointer) throws {
        try KnowledgeStorePointerCodec.validate(pointer)
        do {
            try pointerWriteOperation(
                try KnowledgeJSON.encode(pointer, pretty: true),
                pointerURL,
                "." + KnowledgeHostIdentity.host.temporaryPrefix(
                    "rag-store-"))
        } catch let error as DurableOwnerOnlyFileError {
            throw KnowledgeDomainError(
                error == .commitUncertain ? .commitUncertain : .unsafeStorage,
                retryable: false,
                error == .commitUncertain
                    ? "Knowledge store pointer commit is uncertain and must be reconciled from disk."
                    : "Knowledge store pointer could not be written safely.")
        }
    }

    /// Removes the only active-snapshot admission pointer while the caller
    /// holds the exclusive store writer lock. This is the persistent urgent
    /// purge tombstone: a crash after this boundary leaves the store with no
    /// queryable current snapshot, never with the deleted snapshot reactivated.
    fileprivate func removePointerWithoutLock(
        expectedStoreID: String
    ) throws -> KnowledgeStorePointer? {
        guard let pointer = try readPointerWithoutLock() else { return nil }
        guard pointer.storeID == expectedStoreID else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge store identity changed before deactivation.")
        }
        let descriptor = open(pointerURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge store pointer could not be opened for deactivation.")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var installed = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(pointerURL.path, &installed) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              (opened.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO))
                == (S_IRUSR | S_IWUSR),
              opened.st_dev == installed.st_dev,
              opened.st_ino == installed.st_ino else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge store pointer identity changed before deactivation.")
        }
        guard unlink(pointerURL.path) == 0 else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge store pointer could not be deactivated safely.")
        }
        try KnowledgeSnapshotDurability.synchronizeDirectory(root)
        return pointer
    }

    fileprivate func exactSnapshotRoot(_ snapshotID: String) throws -> URL {
        guard KnowledgeStoreIdentifier.isValidSnapshotID(snapshotID) else {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge store pointer contains an invalid snapshot identifier.")
        }
        let candidate = snapshotsRoot.appendingPathComponent(snapshotID, isDirectory: true)
        guard PathConfinement.isWithin(candidate.path, root: snapshotsRoot),
              let identity = WorkspaceRootIdentity.capture(rootPath: candidate.path),
              identity.canonicalPath == candidate.standardizedFileURL.path else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge store current snapshot is missing or unsafe.")
        }
        var status = stat()
        guard lstat(candidate.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot root is unsafe.")
        }
        return candidate
    }

    fileprivate func snapshotLockURL(_ snapshotID: String) -> URL {
        coordinationRoot.appendingPathComponent(
            "snapshot-\(snapshotID).lock",
            isDirectory: false)
    }

    fileprivate func revalidateStoreAuthority() throws {
        guard workspaceLease.id == workspaceLeaseID,
              workspaceRootIdentity.matchesCurrentDirectory(rootPath: workspaceLease.rootPath),
              WorkspaceRootIdentity.capture(rootPath: root.path) == storeRootIdentity,
              WorkspaceRootIdentity.capture(rootPath: coordinationRoot.path)
                == coordinationRootIdentity,
              PathConfinement.isWithin(root.path, root: URL(
                fileURLWithPath: workspaceRootIdentity.canonicalPath,
                isDirectory: true)) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge store authority or root identity changed.")
        }
        _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: root)
        _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: snapshotsRoot)
        _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: coordinationRoot)
    }

    fileprivate static func createOwnedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store directory permissions could not be secured.")
        }
        _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: url)
    }
}

/// Exclusive store mutation authority. The OS releases the underlying flock
/// on process death. Snapshot-reader locks are separate so publication never
/// waits for readers of a replaced immutable snapshot; GC does.
public final class KnowledgeStoreWriterLease: @unchecked Sendable {
    public let store: KnowledgeSnapshotStore

    private let nonce = UUID()
    private let state: KnowledgeWriterLeaseState

    fileprivate init(store: KnowledgeSnapshotStore,
                     lock: KnowledgeAdvisoryFileLock) {
        self.store = store
        state = KnowledgeWriterLeaseState(lock: lock)
    }

    public func createStagingSnapshot(
        snapshotID: String = KnowledgeStoreIdentifier.makeSnapshotID()
    ) throws -> KnowledgeStagingSnapshot {
        try requireActive()
        try store.revalidateStoreAuthority()
        guard KnowledgeStoreIdentifier.isValidSnapshotID(snapshotID) else {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge snapshot identifier is invalid.")
        }
        let stagingRoot = store.root
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        if !FileManager.default.fileExists(atPath: stagingRoot.path) {
            try KnowledgeSnapshotStore.createOwnedDirectory(stagingRoot)
        }
        let name = "\(snapshotID).tmp-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let candidate = stagingRoot.appendingPathComponent(name, isDirectory: true)
        try KnowledgeSnapshotStore.createOwnedDirectory(candidate)
        guard WorkspaceRootIdentity.capture(rootPath: candidate.path) != nil else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge staging snapshot identity is unavailable.")
        }
        return KnowledgeStagingSnapshot(
            snapshotID: snapshotID,
            root: candidate,
            storeIdentity: store.storeRootIdentity,
            writerNonce: nonce)
    }

    /// Reads the pointer already protected by this writer's exclusive store
    /// lock. Calling `KnowledgeSnapshotStore.loadCurrentPointer()` here would
    /// attempt to acquire the same lock again and can deadlock on `flock`.
    public func currentPointer() throws -> KnowledgeStorePointer? {
        try requireActive()
        try store.revalidateStoreAuthority()
        return try store.readPointerWithoutLock()
    }

    /// Persistently closes current-snapshot admission for an urgent purge.
    /// The snapshot bytes are removed separately only after reader locks drain.
    @discardableResult
    public func deactivateStorePointer(
        expectedStoreID: String
    ) throws -> KnowledgeStorePointer? {
        try requireActive()
        try store.revalidateStoreAuthority()
        return try store.removePointerWithoutLock(
            expectedStoreID: expectedStoreID)
    }

    public func abortStagingSnapshot(_ staging: KnowledgeStagingSnapshot) throws {
        try requireOwned(staging)
        try KnowledgeSnapshotDeletion.removeTree(
            staging.root,
            confinedTo: store.root
                .appendingPathComponent(
                    KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                    isDirectory: true)
                .appendingPathComponent(".staging", isDirectory: true))
    }

    /// Installs a complete validated staging directory, then atomically
    /// activates it. If pointer durability becomes uncertain after the rename,
    /// the complete snapshot remains as an orphan and can be reconciled using
    /// `activateValidatedSnapshot` without exposing a partial snapshot.
    @discardableResult
    public func publishValidatedStaging(
        _ staging: KnowledgeStagingSnapshot,
        validatedSnapshot: KnowledgeValidatedSnapshot,
        expectedPointerRevision: Int? = nil
    ) throws -> KnowledgeStorePointer {
        try requireOwned(staging)
        try validateBinding(
            validatedSnapshot,
            snapshotID: staging.snapshotID,
            expectedRoot: staging.root)
        let pointerBeforeInstall = try store.readPointerWithoutLock()
        if let expectedPointerRevision,
           pointerBeforeInstall?.revision != expectedPointerRevision {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge store pointer changed before snapshot installation.")
        }
        if let pointerBeforeInstall,
           pointerBeforeInstall.storeID != validatedSnapshot.profile.bundle.id {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Knowledge snapshot belongs to a different store identity.")
        }
        // macOS requires write permission on a directory being renamed. Freeze
        // every child now, keep only the staging root owner-writable through
        // rename, then freeze that exact inode before pointer activation.
        try KnowledgeSnapshotDurability.freezeAndSynchronizeTree(
            staging.root,
            keepRootWritableForRename: true)
        try verifyContentSeal(validatedSnapshot, at: staging.root)

        let finalRoot = store.root
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(staging.snapshotID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: finalRoot.path) else {
            throw KnowledgeDomainError(.revisionChanged, "Knowledge snapshot identifier is already published.")
        }
        let stagingIdentity = try requiredIdentity(staging.root)
        guard rename(staging.root.path, finalRoot.path) == 0 else {
            let code = errno
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge snapshot could not be atomically installed (system code \(code)).")
        }
        guard let installedIdentity = WorkspaceRootIdentity.capture(
                rootPath: finalRoot.path),
              installedIdentity.deviceID == stagingIdentity.deviceID,
              installedIdentity.fileID == stagingIdentity.fileID else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge snapshot install identity could not be verified.")
        }
        try KnowledgeSnapshotDurability.synchronizeDirectory(
            finalRoot.deletingLastPathComponent())
        try KnowledgeSnapshotDurability.synchronizeDirectory(
            staging.root.deletingLastPathComponent())
        return try activateValidatedSnapshot(
            validatedSnapshot,
            installedRoot: finalRoot,
            expectedPointerRevision: expectedPointerRevision)
    }

    /// Activates a complete already-installed snapshot. This is the crash
    /// recovery seam for a successful snapshot rename followed by an uncertain
    /// or failed pointer commit.
    @discardableResult
    public func activateValidatedSnapshot(
        _ validatedSnapshot: KnowledgeValidatedSnapshot,
        installedRoot: URL? = nil,
        expectedPointerRevision: Int? = nil
    ) throws -> KnowledgeStorePointer {
        try requireActive()
        try store.revalidateStoreAuthority()
        let snapshotID = validatedSnapshot.profile.retrievalSnapshot.id
        let root: URL
        if let installedRoot {
            root = installedRoot
        } else {
            root = try store.exactSnapshotRoot(snapshotID)
        }
        let exactInstalledRoot = try store.exactSnapshotRoot(snapshotID)
        guard root.standardizedFileURL.path == exactInstalledRoot.standardizedFileURL.path,
              WorkspaceRootIdentity.capture(rootPath: root.path)
                == WorkspaceRootIdentity.capture(rootPath: exactInstalledRoot.path) else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "Knowledge snapshot activation target is not the exact installed snapshot directory.")
        }
        try KnowledgeSnapshotDurability.freezeAndSynchronizeTree(root)
        try validateBinding(
            validatedSnapshot,
            snapshotID: snapshotID,
            expectedRoot: root)
        try verifyContentSeal(validatedSnapshot, at: root)
        let previous = try store.readPointerWithoutLock()
        if let expectedPointerRevision,
           previous?.revision != expectedPointerRevision {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge store pointer changed before activation.")
        }
        if let previous,
           previous.storeID != validatedSnapshot.profile.bundle.id {
            throw KnowledgeDomainError(.integrityFailed, "Knowledge snapshot belongs to a different store identity.")
        }
        let pointer = KnowledgeStorePointer(
            storeID: validatedSnapshot.profile.bundle.id,
            revision: (previous?.revision ?? 0) + 1,
            currentSnapshot: snapshotID,
            currentSnapshotRevision: validatedSnapshot.profile.retrievalSnapshot.revision)
        try store.writePointerWithoutLock(pointer)
        return pointer
    }

    public func garbageCollect(
        policy: KnowledgeSnapshotGarbageCollectionPolicy = KnowledgeSnapshotGarbageCollectionPolicy(),
        protectedSnapshotIDs: Set<String> = [],
        now: Date = Date()
    ) throws -> KnowledgeSnapshotGarbageCollectionResult {
        try requireActive()
        try store.revalidateStoreAuthority()
        let current = try store.readPointerWithoutLock()?.currentSnapshot
        let snapshotsRoot = store.root.appendingPathComponent(
            KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
            isDirectory: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [])
        var records: [(id: String, url: URL, modified: Date)] = []
        for child in children where child.lastPathComponent != ".staging" {
            let id = child.lastPathComponent
            guard KnowledgeStoreIdentifier.isValidSnapshotID(id) else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge store contains an unexpected snapshot entry.")
            }
            _ = try store.exactSnapshotRoot(id)
            let values = try child.resourceValues(forKeys: [.contentModificationDateKey])
            records.append((id, child, values.contentModificationDate ?? .distantPast))
        }
        records.sort {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.id < $1.id
        }

        var removed: [String] = []
        var skippedCurrent: [String] = []
        var skippedProtected: [String] = []
        var skippedReaders: [String] = []
        var skippedRetention: [String] = []
        var nonCurrentPosition = 0
        for record in records {
            if record.id == current {
                skippedCurrent.append(record.id)
                continue
            }
            defer { nonCurrentPosition += 1 }
            if protectedSnapshotIDs.contains(record.id) {
                skippedProtected.append(record.id)
                continue
            }
            if nonCurrentPosition < policy.retainNewestNonCurrent
                || now.timeIntervalSince(record.modified) < policy.minimumRetainedAge
                || removed.count >= policy.maximumRemovals {
                skippedRetention.append(record.id)
                continue
            }
            guard let snapshotLock = try KnowledgeAdvisoryFileLock.acquire(
                at: store.snapshotLockURL(record.id),
                mode: .exclusive,
                blocking: false,
                expectedParentIdentity: store.coordinationRootIdentity) else {
                skippedReaders.append(record.id)
                continue
            }
            defer { snapshotLock.release() }
            try KnowledgeSnapshotDeletion.removeTree(record.url, confinedTo: snapshotsRoot)
            try KnowledgeSnapshotDurability.synchronizeDirectory(snapshotsRoot)
            removed.append(record.id)
        }

        let removedStaging = try collectAbandonedStaging(
            olderThan: policy.abandonedStagingAge,
            now: now)
        return KnowledgeSnapshotGarbageCollectionResult(
            removedSnapshotIDs: removed.sorted(),
            removedStagingDirectories: removedStaging.sorted(),
            skippedCurrentSnapshotIDs: skippedCurrent.sorted(),
            skippedProtectedSnapshotIDs: skippedProtected.sorted(),
            skippedActiveReaderSnapshotIDs: skippedReaders.sorted(),
            skippedRetentionSnapshotIDs: skippedRetention.sorted())
    }

    /// Deletes exact non-current snapshots after admission has been closed and
    /// in-flight readers have drained. Physical media/backups are explicitly
    /// outside this active-store deletion guarantee.
    public func purgeDrainedSnapshots(_ snapshotIDs: Set<String>) throws -> [String] {
        try requireActive()
        try store.revalidateStoreAuthority()
        let current = try store.readPointerWithoutLock()?.currentSnapshot
        let snapshotsRoot = store.root.appendingPathComponent(
            KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
            isDirectory: true)
        var removed: [String] = []
        for id in snapshotIDs.sorted() {
            guard KnowledgeStoreIdentifier.isValidSnapshotID(id), id != current else {
                throw KnowledgeDomainError(.accessDenied, "Current or invalid knowledge snapshot cannot be purged.")
            }
            let candidate = snapshotsRoot.appendingPathComponent(id, isDirectory: true)
            var installed = stat()
            if lstat(candidate.path, &installed) != 0, errno == ENOENT {
                // Durable retry after an already-completed unlink is an exact
                // idempotent success for this snapshot.
                continue
            }
            let root = try store.exactSnapshotRoot(id)
            guard let snapshotLock = try KnowledgeAdvisoryFileLock.acquire(
                at: store.snapshotLockURL(id),
                mode: .exclusive,
                blocking: false,
                expectedParentIdentity: store.coordinationRootIdentity) else {
                throw KnowledgeDomainError(
                    .revisionChanged,
                    retryable: true,
                    "Knowledge snapshot still has active readers.")
            }
            defer { snapshotLock.release() }
            try KnowledgeSnapshotDeletion.removeTree(root, confinedTo: snapshotsRoot)
            try KnowledgeSnapshotDurability.synchronizeDirectory(snapshotsRoot)
            removed.append(id)
        }
        return removed
    }

    public func release() {
        state.release()
    }

    deinit {
        release()
    }

    private func validateBinding(_ snapshot: KnowledgeValidatedSnapshot,
                                 snapshotID: String,
                                 expectedRoot: URL) throws {
        try requireActive()
        let expectedIdentity = try requiredIdentity(expectedRoot)
        guard KnowledgeStoreIdentifier.isValidStoreID(snapshot.profile.bundle.id),
              KnowledgeStoreIdentifier.isValidSnapshotID(snapshotID),
              snapshot.profile.retrievalSnapshot.id == snapshotID,
              KnowledgeDigest.isValid(snapshot.profile.bundle.revision),
              KnowledgeDigest.isValid(snapshot.profile.retrievalSnapshot.revision),
              snapshot.profile.retrievalSnapshot.bundleRevision == snapshot.profile.bundle.revision,
              KnowledgeDigest.isValid(snapshot.contentSealDigest),
              snapshot.rootIdentity.deviceID == expectedIdentity.deviceID,
              snapshot.rootIdentity.fileID == expectedIdentity.fileID,
              snapshot.report.semanticVerdict else {
            throw KnowledgeDomainError(.integrityFailed, "Validated snapshot binding is inconsistent.")
        }
    }

    private func verifyContentSeal(_ snapshot: KnowledgeValidatedSnapshot,
                                   at root: URL) throws {
        guard try store.fileSystem.snapshotSealDigest(root: root)
                == snapshot.contentSealDigest else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Knowledge snapshot bytes changed between validation and publication.")
        }
    }

    private func requireOwned(_ staging: KnowledgeStagingSnapshot) throws {
        try requireActive()
        guard staging.writerNonce == nonce,
              staging.storeIdentity == store.storeRootIdentity,
              KnowledgeStoreIdentifier.isValidSnapshotID(staging.snapshotID),
            PathConfinement.isWithin(
                staging.root.path,
                root: store.root
                    .appendingPathComponent(
                        KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                        isDirectory: true)
                    .appendingPathComponent(".staging", isDirectory: true)) else {
            throw KnowledgeDomainError(.accessDenied, "Knowledge staging snapshot is not owned by this writer lease.")
        }
    }

    private func requireActive() throws {
        guard state.isActive else {
            throw KnowledgeDomainError(.accessDenied, "Knowledge store writer lease is no longer active.")
        }
    }

    private func requiredIdentity(_ url: URL) throws -> WorkspaceRootIdentity {
        guard let identity = WorkspaceRootIdentity.capture(rootPath: url.path) else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge snapshot identity is unavailable.")
        }
        return identity
    }

    private func collectAbandonedStaging(olderThan age: TimeInterval?,
                                         now: Date) throws -> [String] {
        guard let age else { return [] }
        let stagingRoot = store.root
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [])
        var removed: [String] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name.range(
                of: #"^snap_[A-Za-z0-9._-]{1,128}\.tmp-[0-9a-f]{32}$"#,
                options: .regularExpression) != nil else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge staging area contains an unexpected entry.")
            }
            let values = try child.resourceValues(forKeys: [.contentModificationDateKey])
            guard now.timeIntervalSince(values.contentModificationDate ?? .distantPast) >= age else {
                continue
            }
            try KnowledgeSnapshotDeletion.removeTree(child, confinedTo: stagingRoot)
            removed.append(name)
        }
        if !removed.isEmpty {
            try KnowledgeSnapshotDurability.synchronizeDirectory(stagingRoot)
        }
        return removed
    }
}

private final class KnowledgeWriterLeaseState: @unchecked Sendable {
    private let mutex = NSLock()
    private var lock: KnowledgeAdvisoryFileLock?

    init(lock: KnowledgeAdvisoryFileLock) {
        self.lock = lock
    }

    var isActive: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return lock != nil
    }

    func release() {
        mutex.lock()
        let active = lock
        lock = nil
        mutex.unlock()
        active?.release()
    }
}

private enum KnowledgeStorePointerCodec {
    static func decode(_ data: Data) throws -> KnowledgeStorePointer {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge store pointer is not valid JSON.")
        }
        guard let object = raw as? [String: Any],
              Set(object.keys) == Set([
                "schema", "store_id", "revision", "current_snapshot",
                "current_snapshot_revision",
              ]),
              object["schema"] as? String == KnowledgeContract.storeSchema,
              let storeID = object["store_id"] as? String,
              let revision = object["revision"] as? NSNumber,
              String(cString: revision.objCType) != "c",
              revision.doubleValue == Double(revision.intValue),
              let currentSnapshot = object["current_snapshot"] as? String,
              let currentSnapshotRevision = object["current_snapshot_revision"] as? String else {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge store pointer shape is invalid.")
        }
        let pointer = KnowledgeStorePointer(
            storeID: storeID,
            revision: revision.intValue,
            currentSnapshot: currentSnapshot,
            currentSnapshotRevision: currentSnapshotRevision)
        try validate(pointer)
        return pointer
    }

    static func validate(_ pointer: KnowledgeStorePointer) throws {
        guard pointer.schema == KnowledgeContract.storeSchema,
              KnowledgeStoreIdentifier.isValidStoreID(pointer.storeID),
              pointer.revision >= 1,
              KnowledgeStoreIdentifier.isValidSnapshotID(pointer.currentSnapshot),
              KnowledgeDigest.isValid(pointer.currentSnapshotRevision) else {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge store pointer contract is invalid.")
        }
    }
}

private final class KnowledgeAdvisoryFileLock: @unchecked Sendable {
    enum Mode {
        case shared
        case exclusive
    }

    private let mutex = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL,
                        mode: Mode,
                        blocking: Bool,
                        expectedParentIdentity: WorkspaceRootIdentity) throws
        -> KnowledgeAdvisoryFileLock? {
        let parent = url.deletingLastPathComponent()
        guard WorkspaceRootIdentity.capture(rootPath: parent.path)
                == expectedParentIdentity else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease directory identity changed.")
        }
        let parentDescriptor = open(
            parent.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease directory could not be opened safely.")
        }
        defer { _ = close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              UInt64(parentStatus.st_dev) == expectedParentIdentity.deviceID,
              UInt64(parentStatus.st_ino) == expectedParentIdentity.fileID,
              (parentStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease directory is unsafe.")
        }
        var created = false
        let leafName = url.lastPathComponent
        var descriptor = leafName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = leafName.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock could not be opened safely.")
        }
        var shouldClose = true
        defer {
            if shouldClose { _ = close(descriptor) }
        }
        if created {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fsync(descriptor) == 0,
                  fsync(parentDescriptor) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock could not be initialized safely.")
            }
        }
        guard safeLockStatus(descriptor) != nil else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock is unsafe.")
        }
        var operation: Int32 = mode == .shared ? LOCK_SH : LOCK_EX
        if !blocking { operation |= LOCK_NB }
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            if !blocking, errno == EWOULDBLOCK || errno == EAGAIN {
                return nil
            }
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock could not be acquired.")
        }
        guard let held = safeLockStatus(descriptor) else {
            _ = flock(descriptor, LOCK_UN)
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock changed while acquired.")
        }
        let installed = leafName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard installed >= 0 else {
            _ = flock(descriptor, LOCK_UN)
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock path is unsafe.")
        }
        defer { _ = close(installed) }
        guard let pathStatus = safeLockStatus(installed),
              held.st_dev == pathStatus.st_dev,
              held.st_ino == pathStatus.st_ino,
              WorkspaceRootIdentity.capture(rootPath: parent.path)
                == expectedParentIdentity else {
            _ = flock(descriptor, LOCK_UN)
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge lease lock identity changed.")
        }
        shouldClose = false
        return KnowledgeAdvisoryFileLock(descriptor: descriptor)
    }

    func release() {
        mutex.lock()
        let active = descriptor
        descriptor = -1
        mutex.unlock()
        guard active >= 0 else { return }
        _ = flock(active, LOCK_UN)
        _ = close(active)
    }

    deinit {
        release()
    }

    private static func safeLockStatus(_ descriptor: Int32) -> stat? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              (status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO))
                == (S_IRUSR | S_IWUSR) else {
            return nil
        }
        return status
    }
}

private enum KnowledgeSnapshotDurability {
    static func freezeAndSynchronizeTree(
        _ root: URL,
        keepRootWritableForRename: Bool = false
    ) throws {
        var directories: [URL] = [root]
        var files: [URL] = []
        var pending: [URL] = [root]
        while let directory = pending.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [])
            for child in children {
                var status = stat()
                guard lstat(child.path, &status) == 0,
                      status.st_uid == geteuid(),
                      (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot contains an unsafe entry.")
                }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    directories.append(child)
                    pending.append(child)
                case S_IFREG:
                    guard status.st_nlink == 1,
                          (status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0 else {
                        throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot contains an unsafe file.")
                    }
                    files.append(child)
                default:
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot contains a symlink or special file.")
                }
            }
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard chmod(file.path, S_IRUSR) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot file could not be frozen.")
            }
            let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot file could not be synchronized.")
            }
            let result = fsync(descriptor)
            _ = close(descriptor)
            guard result == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot file durability could not be proven.")
            }
        }
        for directory in directories.sorted(by: {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }) {
            let permissions: mode_t =
                keepRootWritableForRename && directory.standardizedFileURL.path
                    == root.standardizedFileURL.path
                ? S_IRWXU
                : (S_IRUSR | S_IXUSR)
            guard chmod(directory.path, permissions) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot directory could not be frozen.")
            }
            try synchronizeDirectory(directory)
        }
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store directory could not be opened for synchronization.")
        }
        let result = fsync(descriptor)
        _ = close(descriptor)
        guard result == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge store directory durability could not be proven.")
        }
    }
}

private enum KnowledgeSnapshotDeletion {
    static func removeTree(_ root: URL, confinedTo parent: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedParent = parent.standardizedFileURL
        guard standardizedRoot.path != standardizedParent.path,
              PathConfinement.isWithin(standardizedRoot.path, root: standardizedParent),
              let rootIdentity = WorkspaceRootIdentity.capture(rootPath: standardizedRoot.path),
              rootIdentity.canonicalPath == standardizedRoot.path else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot deletion target is unsafe.")
        }
        var directories: [URL] = [standardizedRoot]
        var pending: [URL] = [standardizedRoot]
        while let directory = pending.popLast() {
            guard chmod(directory.path, S_IRWXU) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot could not be prepared for deletion.")
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [])
            for child in children {
                var status = stat()
                guard lstat(child.path, &status) == 0,
                      status.st_uid == geteuid() else {
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot deletion encountered an unsafe entry.")
                }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    directories.append(child)
                    pending.append(child)
                case S_IFREG:
                    guard status.st_nlink == 1 else {
                        throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot deletion encountered a hard-linked file.")
                    }
                    guard unlink(child.path) == 0 else {
                        throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot file could not be removed.")
                    }
                default:
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot deletion encountered a symlink or special file.")
                }
            }
        }
        for directory in directories.sorted(by: {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }) {
            guard rmdir(directory.path) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot directory could not be removed.")
            }
        }
    }
}
