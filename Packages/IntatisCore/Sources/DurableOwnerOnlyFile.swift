import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum DurableOwnerOnlyFileError: Error, LocalizedError, Equatable, Sendable {
    case unsafeFile
    case readFailed
    case fileTooLarge
    case writeFailed
    /// `rename(2)` completed, but the caller could not prove the installed
    /// bytes and directory entry durable. The destination may contain either
    /// the old or new value and must be reconciled from disk.
    case commitUncertain
    case lockFailed
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeFile:
            return "The owner-only file is not a safe regular file."
        case .readFailed:
            return "The owner-only file could not be read."
        case .fileTooLarge:
            return "The owner-only file exceeds the permitted read size."
        case .writeFailed:
            return "The owner-only file could not be written durably."
        case .commitUncertain:
            return "The owner-only file may have been committed, but durability could not be verified."
        case .lockFailed:
            return "The owner-only file lock could not be acquired safely."
        case .verificationFailed:
            return "The owner-only file could not be verified after writing."
        }
    }
}

/// Shared crash-safe writer for session-owned capability and payload files.
/// It never follows the leaf symlink, writes mode 0600, fsyncs the file and
/// parent directory, and verifies the installed leaf before returning.
public enum DurableOwnerOnlyFile {
    /// Validates an application-owned directory without following its leaf and
    /// returns the canonical path for its existing inode. Ancestor symlinks
    /// (such as macOS `/var` -> `/private/var`) are allowed; a symlink at the
    /// requested directory itself is not.
    public static func validateOwnedDirectory(at url: URL) throws -> URL {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DurableOwnerOnlyFileError.unsafeFile }
            throw DurableOwnerOnlyFileError.readFailed
        }
        defer { _ = close(descriptor) }
        guard let originalStatus = safeOwnedDirectoryStatus(for: descriptor) else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }

        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDescriptor = open(
            canonical.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard canonicalDescriptor >= 0 else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        defer { _ = close(canonicalDescriptor) }
        guard let canonicalStatus = safeOwnedDirectoryStatus(for: canonicalDescriptor),
              canonicalStatus.st_dev == originalStatus.st_dev,
              canonicalStatus.st_ino == originalStatus.st_ino else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        return canonical
    }

    public static func read(from url: URL) throws -> Data? {
        try read(from: url, maximumBytes: nil)
    }

    /// Reads an owner-only regular file without following its leaf and without
    /// ever accumulating more than `maximumBytes` in memory. The limit is
    /// checked against the opened descriptor before reading and again while the
    /// same descriptor is consumed, so a concurrently growing file also fails
    /// closed.
    public static func read(
        from url: URL,
        maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes >= 0 else {
            throw DurableOwnerOnlyFileError.readFailed
        }
        return try read(
            from: url,
            maximumBytes: Optional(maximumBytes))
    }

    private static func read(
        from url: URL,
        maximumBytes: Int?
    ) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw DurableOwnerOnlyFileError.unsafeFile }
            throw DurableOwnerOnlyFileError.readFailed
        }
        defer { _ = close(descriptor) }
        guard let initialStatus = safeOwnerOnlyStatus(for: descriptor) else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        if let maximumBytes,
           (initialStatus.st_size < 0
            || UInt64(initialStatus.st_size) > UInt64(maximumBytes)) {
            throw DurableOwnerOnlyFileError.fileTooLarge
        }

        var result = Data()
        if let maximumBytes {
            result.reserveCapacity(
                min(maximumBytes, 64 * 1_024))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Darwin.read(descriptor, base, rawBuffer.count)
                #elseif canImport(Glibc)
                return Glibc.read(descriptor, base, rawBuffer.count)
                #elseif canImport(Musl)
                return Musl.read(descriptor, base, rawBuffer.count)
                #else
                return -1
                #endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DurableOwnerOnlyFileError.readFailed
            }
            if let maximumBytes,
               count > maximumBytes - result.count {
                throw DurableOwnerOnlyFileError.fileTooLarge
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard safeOwnerOnlyStatus(for: descriptor) != nil else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        return result
    }

    /// Explicitly adopts a legacy owner-created leaf whose only weakness is
    /// read access for group/other users (for example a historical 0644 file).
    /// Callers must first confine `url` to a trusted application-owned store.
    /// Symlinks, hard links, foreign ownership, writable group/other bits, and
    /// executable files are rejected; the general `read` API never calls this.
    public static func adoptLegacyReadOnlyFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DurableOwnerOnlyFileError.unsafeFile }
            throw DurableOwnerOnlyFileError.readFailed
        }
        defer { _ = close(descriptor) }

        guard let originalStatus = safeLegacyReadOnlyStatus(for: descriptor) else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        if safeOwnerOnlyStatus(for: descriptor) == nil {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw DurableOwnerOnlyFileError.writeFailed
            }
            guard safeOwnerOnlyStatus(for: descriptor) != nil,
                  fsync(descriptor) == 0,
                  synchronizeDirectory(url.deletingLastPathComponent()) else {
                throw DurableOwnerOnlyFileError.commitUncertain
            }
        }

        let installed = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard installed >= 0 else {
            throw DurableOwnerOnlyFileError.commitUncertain
        }
        defer { _ = close(installed) }
        guard let installedStatus = safeOwnerOnlyStatus(for: installed),
              installedStatus.st_dev == originalStatus.st_dev,
              installedStatus.st_ino == originalStatus.st_ino else {
            throw DurableOwnerOnlyFileError.commitUncertain
        }
    }

    /// Executes a synchronous mutation while holding a stable, owner-only
    /// cross-process lock. Existing unsafe leaves are rejected and are never
    /// repaired with `chmod`, so an attacker-controlled inode cannot be made
    /// trusted as a side effect of opening it.
    public static func withExclusiveLock<Result>(
        at url: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true)

        var created = false
        var descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DurableOwnerOnlyFileError.unsafeFile
            }
            throw DurableOwnerOnlyFileError.lockFailed
        }
        defer { _ = close(descriptor) }

        if created {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fsync(descriptor) == 0,
                  synchronizeDirectory(parent) else {
                throw DurableOwnerOnlyFileError.lockFailed
            }
        }
        guard safeOwnerOnlyStatus(for: descriptor) != nil else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }

        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw DurableOwnerOnlyFileError.lockFailed
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        // A lock inode can be renamed while a process waits on flock. Prove
        // that the path still names this exact safe inode before trusting the
        // critical section; otherwise two writers could hold different locks.
        guard let lockedStatus = safeOwnerOnlyStatus(for: descriptor) else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        let pathDescriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard pathDescriptor >= 0 else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }
        defer { _ = close(pathDescriptor) }
        guard let pathStatus = safeOwnerOnlyStatus(for: pathDescriptor),
              pathStatus.st_dev == lockedStatus.st_dev,
              pathStatus.st_ino == lockedStatus.st_ino else {
            throw DurableOwnerOnlyFileError.unsafeFile
        }

        return try body()
    }

    public static func writeAtomically(
        _ data: Data,
        to url: URL,
        temporaryPrefix: String = ".owner-only-"
    ) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DurableOwnerOnlyFileError.writeFailed
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporary.path) }
        }

        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < rawBuffer.count {
                let count: Int
                #if canImport(Darwin)
                count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #elseif canImport(Glibc)
                count = Glibc.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #elseif canImport(Musl)
                count = Musl.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                #else
                count = -1
                #endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              safeOwnerOnlyStatus(for: descriptor) != nil,
              fsync(descriptor) == 0 else {
            throw DurableOwnerOnlyFileError.writeFailed
        }

        // Everything below this successful rename is post-commit. A failure
        // cannot be reported as a clean rollback because the new directory
        // entry is already visible.
        guard rename(temporary.path, url.path) == 0 else {
            throw DurableOwnerOnlyFileError.writeFailed
        }
        shouldRemoveTemporary = false

        guard synchronizeDirectory(parent) else {
            throw DurableOwnerOnlyFileError.commitUncertain
        }
        do {
            guard let installed = try read(from: url), installed == data else {
                throw DurableOwnerOnlyFileError.commitUncertain
            }
        } catch {
            throw DurableOwnerOnlyFileError.commitUncertain
        }
    }

    private static func safeOwnerOnlyStatus(for descriptor: Int32) -> stat? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return nil
        }
        let permissions = status.st_mode
            & (S_IRWXU | S_IRWXG | S_IRWXO)
        guard permissions == (S_IRUSR | S_IWUSR) else { return nil }
        return status
    }

    private static func safeLegacyReadOnlyStatus(for descriptor: Int32) -> stat? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return nil
        }
        let permissions = status.st_mode
            & (S_IRWXU | S_IRWXG | S_IRWXO)
        guard (permissions & S_IRUSR) != 0,
              (permissions & (S_IWGRP | S_IWOTH)) == 0,
              (permissions & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0 else {
            return nil
        }
        return status
    }

    private static func safeOwnedDirectoryStatus(for descriptor: Int32) -> stat? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_nlink > 0 else {
            return nil
        }
        let permissions = status.st_mode
            & (S_IRWXU | S_IRWXG | S_IRWXO)
        guard (permissions & (S_IRUSR | S_IXUSR)) == (S_IRUSR | S_IXUSR),
              (permissions & (S_IWGRP | S_IWOTH)) == 0 else {
            return nil
        }
        return status
    }

    private static func synchronizeDirectory(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        return fsync(descriptor) == 0
    }
}
