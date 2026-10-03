import Foundation

/// Unified error type across all Intatis modules.
public enum IntatisError: Error, Sendable, Equatable, LocalizedError {
    case config(String)
    case provider(String)
    case decoding(String)
    case io(String)
    case notFound(String)
    case permissionDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .config(let m):           return "Configuration error: \(m)"
        case .provider(let m):         return "Provider error: \(m)"
        case .decoding(let m):         return "Decoding error: \(m)"
        case .io(let m):               return "I/O error: \(m)"
        case .notFound(let m):         return "Not found: \(m)"
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .cancelled:               return "Cancelled."
        }
    }
}

/// Distinguishes cancellation of the current structured task from a provider
/// that independently reports a cancellation-shaped failure.
///
/// Provider adapters may normalize `CancellationError` to
/// `IntatisError.cancelled`; callers must therefore check both the error shape
/// and the current task's cancellation bit before treating a turn as
/// user-interrupted.
public enum IntatisCancellation {
    public static func isCancellationSignal(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let intatisError = error as? IntatisError else {
            return false
        }
        return intatisError == .cancelled
    }

    public static func isCurrentTaskCancellation(_ error: Error) -> Bool {
        Task.isCancelled && isCancellationSignal(error)
    }
}
