import Foundation
import IntatisCore
import IntatisProtocol
import IntatisConversation
import IntatisAgentKernel

func out(_ s: String) { try? FileHandle.standardOutput.write(contentsOf: Data(s.utf8)) }
func errOut(_ s: String) { try? FileHandle.standardError.write(contentsOf: Data(s.utf8)) }

private func truncate(_ s: String, _ n: Int) -> String {
    s.count > n ? String(s.prefix(n)) + "…" : s
}

/// First line only, hard-capped — for collapsed one-liners.
private func oneLine(_ s: String, _ n: Int) -> String {
    let first = s.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return first.count > n ? String(first.prefix(n)) + "…" : first
}

/// Collapsed tool / terminal output: first line, plus a "(+N 行)" hint if multiline.
private func summary(_ s: String) -> String {
    let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    let head = oneLine(s, 72)
    let extra = lines.count - 1
    return extra > 0 ? "\(head)  (+\(extra) 行，/verbose 看全部)" : head
}

private func isFailureObservation(_ s: String) -> Bool {
    let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lower.hasPrefix("tool error:")
        || lower.hasPrefix("permission denied:")
        || lower.hasPrefix("unknown tool:")
        || lower.hasPrefix("invalid tool input:")
}

/// Shared, mutable render verbosity. Collapsed by default; `/verbose` flips it.
final class RenderOptions: @unchecked Sendable {
    private let lock = NSLock()
    private var _verbose: Bool
    init(verbose: Bool = false) { _verbose = verbose }
    var verbose: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _verbose }
        set { lock.lock(); _verbose = newValue; lock.unlock() }
    }
}

// Minimal ANSI helpers.
private let dim = "\u{001B}[2m", cyan = "\u{001B}[36m", yellow = "\u{001B}[33m"
private let magenta = "\u{001B}[35m", red = "\u{001B}[31m", reset = "\u{001B}[0m"

/// Streams events from the log to stdout as they arrive. It only writes stdout
/// (never reads stdin), so it runs concurrently with the input loop and the
/// permission prompt with no contention.
func renderLoop(_ log: EventLog, showAgentLabels: Bool = false, spinner: TurnSpinner? = nil,
                options: RenderOptions = RenderOptions()) async {
    let stream = await log.stream(from: 0)
    var currentMessage = ""
    for await env in stream {
        // Keep the "Thinking…" line alive through the pre-output events
        // (user_message, agent_status); stop it only when real output arrives.
        switch env.event {
        case .userMessage, .agentStatus: break
        default: spinner?.stop()
        }
        switch env.event {
        case .messageDelta(let p):
            if showAgentLabels, let agent = p.agent, p.messageId.rawValue != currentMessage {
                out("\n\(cyan)● \(agent.rawValue)\(reset)\n")
                currentMessage = p.messageId.rawValue
            }
            out(p.textDelta)
        case .messageCompleted:
            out("\n")
        case .toolCall(let p):
            let args = options.verbose ? truncate(p.args, 800) : oneLine(p.args, 72)
            out("\n  \(cyan)· \(p.name)\(reset) \(dim)\(args)\(reset)\n")
        case .toolResult(let p):
            let color = p.outcome.map { $0 == .succeeded ? dim : red }
                ?? (isFailureObservation(p.observation) ? red : dim)
            if options.verbose {
                out("  \(color)⎿\(reset) \(truncate(p.observation, 4000))\n")
            } else {
                out("  \(color)⎿ \(summary(p.observation))\(reset)\n")
            }
        case .permissionResolved(let p):
            out("  \(yellow)[\(permissionResolutionLabel(p)): \(p.tool) — \(p.reason)]\(reset)\n")
        case .permissionReview(let p):
            out("  \(yellow)[review \(p.decision.rawValue): \(p.tool) by \(p.reviewerModel) — \(p.reason)]\(reset)\n")
        case .patchProposed(let p):
            out("  \(magenta)± patch: \(p.files.joined(separator: ", "))\(reset)\n")
        case .agentToAgentMessage(let p):
            out("  \(cyan)↔ \(p.from.rawValue)→\(p.to.rawValue):\(reset) \(truncate(p.content, 300))\n")
        case .artifactAdded(let p):
            out("  📎 \(p.kind): \(p.path)\n")
        case .turnStats(let p):
            var parts: [String] = []
            if let total = p.totalMillis { parts.append(String(format: "%.1fs", Double(total) / 1000)) }
            if let ttft = p.ttftMillis { parts.append("ttft \(String(format: "%.2fs", Double(ttft) / 1000))") }
            if let tot = p.totalTokens {
                if let pin = p.promptTokens, let pout = p.completionTokens {
                    parts.append("\(tot) tok (\(pin) in / \(pout) out)")
                } else {
                    parts.append("\(tot) tok")
                }
            }
            if !parts.isEmpty { out("  \(dim)⎿ \(parts.joined(separator: " · "))\(reset)\n") }
        case .error(let p):
            out("  \(red)! \(p.message)\(reset)\n")
        default:
            break
        }
    }
}

/// Terminal approval for `ask_user` decisions (Code mode).
struct TerminalResponder: PermissionResponder {
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await requestResolution(request).decision
    }

    func requestResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        await TerminalPermissionPromptQueue.shared.requestResolution(request)
    }
}

/// `readLine()` is process-global and cannot safely serve two permission
/// continuations concurrently. The control-plane fallback is FIFO, and this
/// queue also protects direct manual approvals after `/default`.
private actor TerminalPermissionPromptQueue {
    static let shared = TerminalPermissionPromptQueue()

    func requestResolution(
        _ request: PermissionRequestPayload
    ) -> PermissionApprovalResolution {
        while true {
            out("\n  \(yellow)⚠ [\(request.requestId.rawValue)] \(request.tool) (\(request.risk.rawValue)) — \(request.reason)\(reset)\n  [a]pprove call / [d]ecline call / [c]ancel turn: ")
            guard let line = readLine() else {
                return PermissionApprovalResolution(
                    decision: .deny,
                    action: .cancelTurn,
                    reason: "Turn cancelled because permission input closed",
                    risk: request.risk,
                    source: .user,
                    failureSource: .userCancelled)
            }
            switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "a", "approve", "y", "yes":
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    reason: "Permission approved by user",
                    risk: request.risk,
                    source: .user)
            case "d", "decline", "n", "no":
                return PermissionApprovalResolution(
                    decision: .deny,
                    action: .decline,
                    reason: "Permission declined by user",
                    risk: request.risk,
                    source: .user,
                    failureSource: .userDenied)
            case "c", "cancel", "cancel turn":
                return PermissionApprovalResolution(
                    decision: .deny,
                    action: .cancelTurn,
                    reason: "Turn cancelled by user",
                    risk: request.risk,
                    source: .user,
                    failureSource: .userCancelled)
            default:
                out("  Enter a, d, or c.\n")
            }
        }
    }
}

private func permissionResolutionLabel(_ payload: PermissionResolvedPayload) -> String {
    if payload.decision == .allow { return "approved" }
    if payload.action == .cancelTurn { return "turn cancelled" }
    switch payload.failureSource {
    case .userDenied: return "call declined"
    case .userCancelled, .turnCancelled: return "turn cancelled"
    case .policyDenied: return "policy denied"
    case .reviewerTimedOut: return "review timed out"
    case .reviewerFailed: return "review failed"
    case .sandboxDenied: return "sandbox denied"
    case .runtimeFailed: return "runtime failed"
    case nil: return "denied"
    }
}
