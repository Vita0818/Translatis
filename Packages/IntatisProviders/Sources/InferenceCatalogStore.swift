import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// File-backed owner of the immutable inference catalog. Callers inject the
/// location; this type never guesses an app-support path.
///
/// Writes use a same-directory temporary file, synchronize its contents, set
/// owner-only permissions, and atomically replace the catalog. Reconciliation
/// always starts from the complete stored catalog so prior revisions survive.
public actor InferenceCatalogStore {
    public static let maximumEncodedBytes = 16 * 1024 * 1024
    /// POSIX record locks are process-scoped on Darwin and Linux. This mutex
    /// prevents two independently opened descriptors in this process from
    /// entering the same process-owned advisory lock concurrently; `fcntl`
    /// below provides the corresponding cross-process exclusion.
    private static let processMutationLock = NSLock()

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func loadCatalog() throws -> InferenceCatalog {
        try readCatalog()
    }

    public func loadSnapshot() throws -> InferenceCatalogSnapshot {
        try InferenceCatalogSnapshot(catalog: readCatalog())
    }

    /// Reconciles current mutable definitions while retaining every immutable
    /// revision already in the store. A corrupted or insecure existing store
    /// fails closed and is never replaced with an empty catalog.
    @discardableResult
    public func reconcile(_ draft: InferenceCatalogDraft) throws -> InferenceCatalogSnapshot {
        try withExclusiveStoreLock {
            // The read, immutable-revision allocation, and atomic replacement
            // are one transaction across every store instance and process that
            // follows this lock protocol. Keeping the lock outside `readCatalog`
            // is intentional: callers may load an atomically replaced snapshot
            // without blocking a writer, while reconciliation may never act on
            // a stale pre-lock catalog.
            let existing = try readCatalog()
            let updated = try InferenceCatalogReconciler.reconcile(
                existing: existing,
                draft: draft)
            let snapshot = try InferenceCatalogSnapshot(catalog: updated)
            try writeCatalog(updated)
            return snapshot
        }
    }

    /// Runs a complete catalog mutation while holding an OS advisory lock on a
    /// stable sidecar inode. The sidecar is never removed, so atomic replacement
    /// of the catalog itself cannot change which inode cooperating processes
    /// synchronize on.
    private func withExclusiveStoreLock<T>(_ operation: () throws -> T) throws -> T {
        try ensureStoreDirectory()

        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }

        let descriptor = try openLockFile()
        var locked = false
        defer {
            if locked {
                _ = systemUnlock(descriptor)
            }
            _ = systemClose(descriptor)
        }

        while systemLockExclusive(descriptor) != 0 {
            guard errno == EINTR else {
                throw InferenceCatalogError.storeIO
            }
        }
        locked = true
        return try operation()
        #else
        // An unknown platform must not silently reconcile without a real
        // cross-process lock.
        throw InferenceCatalogError.storeIO
        #endif
    }

    private func ensureStoreDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } catch {
            throw InferenceCatalogError.storeIO
        }
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private func openLockFile() throws -> Int32 {
        let lockURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(fileURL.lastPathComponent).lock",
            isDirectory: false)
        let creationFlags = O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let existingFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let descriptor: Int32
        let created: Bool

        let creationResult = lockURL.path.withCString {
            systemOpen($0, creationFlags, mode_t(0o600))
        }
        if creationResult >= 0 {
            descriptor = creationResult
            created = true
        } else if errno == EEXIST {
            let existingResult = lockURL.path.withCString {
                systemOpen($0, existingFlags, mode_t(0))
            }
            guard existingResult >= 0 else {
                throw InferenceCatalogError.storeIO
            }
            descriptor = existingResult
            created = false
        } else {
            throw InferenceCatalogError.storeIO
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = systemClose(descriptor)
            }
        }

        // A restrictive umask may remove owner bits at creation time. Restore
        // exactly 0600 only for the inode we created; an existing insecure or
        // foreign-owned sidecar is rejected rather than silently repaired.
        if created, systemFchmod(descriptor, mode_t(0o600)) != 0 {
            throw InferenceCatalogError.storeIO
        }

        var metadata = stat()
        guard systemFstat(descriptor, &metadata) == 0,
              metadata.st_uid == systemEffectiveUserID(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw InferenceCatalogError.storeIO
        }

        let descriptorFlags = systemFcntlGetFD(descriptor)
        guard descriptorFlags >= 0,
              systemFcntlSetFD(descriptor, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw InferenceCatalogError.storeIO
        }

        shouldClose = false
        return descriptor
    }
    #endif

    private func readCatalog() throws -> InferenceCatalog {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        try validateStoredFilePermissions()

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw InferenceCatalogError.storeIO
        }
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= Self.maximumEncodedBytes else {
            throw InferenceCatalogError.storeCorrupted
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw InferenceCatalogError.storeIO
        }
        let catalog: InferenceCatalog
        do {
            catalog = try JSONDecoder().decode(InferenceCatalog.self, from: data)
        } catch {
            throw InferenceCatalogError.storeCorrupted
        }
        _ = try InferenceCatalogSnapshot(catalog: catalog)
        return catalog
    }

    private func writeCatalog(_ catalog: InferenceCatalog) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(catalog)
        } catch {
            throw InferenceCatalogError.storeCorrupted
        }
        guard !data.isEmpty, data.count <= Self.maximumEncodedBytes else {
            throw InferenceCatalogError.storeCorrupted
        }

        let directory = fileURL.deletingLastPathComponent()
        try ensureStoreDirectory()

        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw InferenceCatalogError.storeIO
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path)

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            shouldRemoveTemporary = false
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path)
        } catch {
            throw InferenceCatalogError.storeIO
        }
    }

    private func validateStoredFilePermissions() throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw InferenceCatalogError.storeIO
        }
        guard let rawPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              rawPermissions & 0o777 == 0o600 else {
            throw InferenceCatalogError.storeInsecurePermissions
        }
    }
}

#if canImport(Darwin)
private func systemOpen(_ path: UnsafePointer<CChar>,
                        _ flags: Int32,
                        _ mode: mode_t) -> Int32 {
    Darwin.open(path, flags, mode)
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    Darwin.close(descriptor)
}

private func systemLockExclusive(_ descriptor: Int32) -> Int32 {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Darwin.fcntl(descriptor, F_SETLKW, &lock)
}

private func systemUnlock(_ descriptor: Int32) -> Int32 {
    var lock = flock()
    lock.l_type = Int16(F_UNLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Darwin.fcntl(descriptor, F_SETLK, &lock)
}

private func systemFchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
    Darwin.fchmod(descriptor, mode)
}

private func systemFstat(_ descriptor: Int32, _ metadata: UnsafeMutablePointer<stat>) -> Int32 {
    Darwin.fstat(descriptor, metadata)
}

private func systemFcntlGetFD(_ descriptor: Int32) -> Int32 {
    Darwin.fcntl(descriptor, F_GETFD)
}

private func systemFcntlSetFD(_ descriptor: Int32, _ flags: Int32) -> Int32 {
    Darwin.fcntl(descriptor, F_SETFD, flags)
}

private func systemEffectiveUserID() -> uid_t {
    Darwin.geteuid()
}
#elseif canImport(Glibc)
private func systemOpen(_ path: UnsafePointer<CChar>,
                        _ flags: Int32,
                        _ mode: mode_t) -> Int32 {
    Glibc.open(path, flags, mode)
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    Glibc.close(descriptor)
}

private func systemLockExclusive(_ descriptor: Int32) -> Int32 {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Glibc.fcntl(descriptor, F_SETLKW, &lock)
}

private func systemUnlock(_ descriptor: Int32) -> Int32 {
    var lock = flock()
    lock.l_type = Int16(F_UNLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Glibc.fcntl(descriptor, F_SETLK, &lock)
}

private func systemFchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
    Glibc.fchmod(descriptor, mode)
}

private func systemFstat(_ descriptor: Int32, _ metadata: UnsafeMutablePointer<stat>) -> Int32 {
    Glibc.fstat(descriptor, metadata)
}

private func systemFcntlGetFD(_ descriptor: Int32) -> Int32 {
    Glibc.fcntl(descriptor, F_GETFD)
}

private func systemFcntlSetFD(_ descriptor: Int32, _ flags: Int32) -> Int32 {
    Glibc.fcntl(descriptor, F_SETFD, flags)
}

private func systemEffectiveUserID() -> uid_t {
    Glibc.geteuid()
}
#elseif canImport(Musl)
private func systemOpen(_ path: UnsafePointer<CChar>,
                        _ flags: Int32,
                        _ mode: mode_t) -> Int32 {
    Musl.open(path, flags, mode)
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    Musl.close(descriptor)
}

private func systemLockExclusive(_ descriptor: Int32) -> Int32 {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Musl.fcntl(descriptor, F_SETLKW, &lock)
}

private func systemUnlock(_ descriptor: Int32) -> Int32 {
    var lock = flock()
    lock.l_type = Int16(F_UNLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    return Musl.fcntl(descriptor, F_SETLK, &lock)
}

private func systemFchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
    Musl.fchmod(descriptor, mode)
}

private func systemFstat(
    _ descriptor: Int32,
    _ metadata: UnsafeMutablePointer<stat>
) -> Int32 {
    Musl.fstat(descriptor, metadata)
}

private func systemFcntlGetFD(_ descriptor: Int32) -> Int32 {
    Musl.fcntl(descriptor, F_GETFD)
}

private func systemFcntlSetFD(_ descriptor: Int32, _ flags: Int32) -> Int32 {
    Musl.fcntl(descriptor, F_SETFD, flags)
}

private func systemEffectiveUserID() -> uid_t {
    Musl.geteuid()
}
#endif
