import Foundation

/// A typed executor rejection that proves the declared side effect never
/// crossed its mutation boundary. This guarantee is intentionally narrow:
/// callers may durably settle the execution as safe to retry, so tools must
/// not use this error for timeouts, lost acknowledgements, or outcomes whose
/// executor completion cannot be established.
public struct ToolExecutionRejectedWithoutSideEffect: Error, Equatable, Sendable, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
