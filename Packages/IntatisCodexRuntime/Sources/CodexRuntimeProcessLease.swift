import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Cross-process single-writer lease for one session's isolated Codex home.
/// The safe lock inode remains on disk; `flock` ownership ends on release or
/// process death, so crashes do not require stale-sentinel deletion.
final class CodexRuntimeProcessLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    init(url: URL) throws {
        var created = false
        var descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = open(
                url.path,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
        var shouldClose = true
        defer {
            if shouldClose { _ = close(descriptor) }
        }
        if created {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fsync(descriptor) == 0 else {
                throw CodexRuntimeError.unsafeRuntimeStorage
            }
        }
        guard let lockedStatus = Self.safeStatus(
            descriptor: descriptor) else {
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw CodexRuntimeError.runtimeAlreadyActive
            }
            throw CodexRuntimeError.unsafeRuntimeStorage
        }

        let pathDescriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard pathDescriptor >= 0 else {
            _ = flock(descriptor, LOCK_UN)
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
        defer { _ = close(pathDescriptor) }
        guard let pathStatus = Self.safeStatus(
            descriptor: pathDescriptor),
              pathStatus.st_dev == lockedStatus.st_dev,
              pathStatus.st_ino == lockedStatus.st_ino else {
            _ = flock(descriptor, LOCK_UN)
            throw CodexRuntimeError.unsafeRuntimeStorage
        }
        self.descriptor = descriptor
        shouldClose = false
    }

    func release() {
        stateLock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        stateLock.unlock()
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit {
        release()
    }

    private static func safeStatus(
        descriptor: Int32
    ) -> stat? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return nil
        }
        let permissions = status.st_mode
            & (S_IRWXU | S_IRWXG | S_IRWXO)
        guard permissions == (S_IRUSR | S_IWUSR) else {
            return nil
        }
        return status
    }
}
