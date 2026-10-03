import Foundation

/// Minimal JSON-RPC 2.0 vocabulary. v0.1 runs the kernel in-process and does not
/// frame messages over a transport yet, but the mapping is fixed now so the
/// out-of-process transports (`intatis agent --stdio`, `intatis daemon`) in later
/// milestones are pure plumbing (ARCHITECTURE.md §5.1):
///
/// - `Command`  → JSON-RPC **request**       `{ "jsonrpc":"2.0","id":N,"method":...,"params":... }`
/// - `Envelope` → JSON-RPC **notification**  `{ "jsonrpc":"2.0","method":"event","params": <Envelope> }`
public enum JSONRPC {
    public static let version = "2.0"
    /// Method name carrying an `Envelope` as a notification.
    public static let eventMethod = "event"
}

public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    // Standard codes we will use once framing lands.
    public static let parseError = JSONRPCErrorObject(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCErrorObject(code: -32600, message: "Invalid request")
    public static let methodNotFound = JSONRPCErrorObject(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCErrorObject(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCErrorObject(code: -32603, message: "Internal error")
}
