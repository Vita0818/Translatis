import Foundation

/// The side-effect class a tool call declares. The deterministic policy gate
/// (IntatisPermission, v0.2) reads this to make fast allow/deny/ask decisions
/// before any model is consulted (ARCHITECTURE.md §3.7, §6.2).
public enum SideEffect: String, Codable, Sendable {
    case readOnly = "read_only"
    case write
    case exec
    case network
    case destructive
}
