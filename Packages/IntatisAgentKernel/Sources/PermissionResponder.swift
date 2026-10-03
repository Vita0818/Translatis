import Foundation
import IntatisCore
import IntatisProtocol

/// Exact, request-local evidence for one automatic permission review.
///
/// This value is deliberately not `Codable`: complete business arguments and
/// the acting model's same-generation authorization context are not copied
/// into permission lifecycle payloads. The raw sidecar is never durable;
/// sidecar-free business calls may still follow the existing bounded,
/// secret-safe model-history/tool-call persistence path. Durable permission
/// identity remains the digest/count stored in the request, and this transient
/// reviewer copy is released when the live review job ends.
public struct PermissionReviewInvocationInput: Equatable, Sendable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let taskID: TaskID?
    public let toolCallID: String
    public let toolName: String
    public let sourceGenerationID: String
    public let toolSnapshotID: String
    public let canonicalBusinessArguments: String
    public let businessArgumentsDigest: String
    public let businessArgumentsCharacterCount: Int
    public let modelAuthorizationContextJSON: String
    public let modelAuthorizationContextDigest: String

    public init(sessionID: SessionID,
                turnID: TurnID,
                taskID: TaskID?,
                toolCallID: String,
                toolName: String,
                sourceGenerationID: String,
                toolSnapshotID: String,
                canonicalBusinessArguments: String,
                businessArgumentsDigest: String,
                businessArgumentsCharacterCount: Int,
                modelAuthorizationContextJSON: String,
                modelAuthorizationContextDigest: String) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.taskID = taskID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.sourceGenerationID = sourceGenerationID
        self.toolSnapshotID = toolSnapshotID
        self.canonicalBusinessArguments = canonicalBusinessArguments
        self.businessArgumentsDigest = businessArgumentsDigest
        self.businessArgumentsCharacterCount = businessArgumentsCharacterCount
        self.modelAuthorizationContextJSON = modelAuthorizationContextJSON
        self.modelAuthorizationContextDigest = modelAuthorizationContextDigest
    }
}

/// Bridges an `ask_user` decision to whoever can answer it. In the GUI this is
/// backed by the permission card; in tests, a stub. The kernel emits a
/// `permission_request` event and then awaits this.
public protocol PermissionResponder: Sendable {
    /// Declares whether a newly persisted request is answered by a user-facing
    /// manual queue or the reserved automatic reviewer control plane.
    var approvalMode: PermissionApprovalMode { get }
    /// Returns `.allow` or `.deny` for the given request.
    func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision
    /// Returns the decision together with its authoritative reason/source when
    /// the responder supports structured settlement.
    func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution
    /// Automatic-review-only overload carrying complete, non-durable evidence
    /// for the exact invocation. This is a protocol requirement (rather than
    /// only an extension overload) so existential dispatch reaches the Cowork
    /// control-plane implementation. Manual responders use the default adapter
    /// below and never receive or persist this evidence.
    func requestResolution(
        _ request: PermissionRequestPayload,
        invocation: PermissionReviewInvocationInput
    ) async -> PermissionApprovalResolution
}

public extension PermissionResponder {
    var approvalMode: PermissionApprovalMode { .manual }

    func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution {
        PermissionApprovalResolution(
            decision: await requestApproval(request),
            risk: request.risk,
            source: .user)
    }

    func requestResolution(
        _ request: PermissionRequestPayload,
        invocation _: PermissionReviewInvocationInput
    ) async -> PermissionApprovalResolution {
        guard approvalMode != .automaticReviewer else {
            return PermissionApprovalResolution(
                decision: .deny,
                reason: "automatic permission responder does not implement the bound invocation contract",
                risk: request.risk,
                source: .automaticReviewerFailure,
                reviewStatus: .failed,
                failureKind: .authorizationContextUnavailable,
                failureSource: .reviewerFailed)
        }
        return await requestResolution(request)
    }
}

/// Convenience responder that always returns the same decision (tests / autopilot UI off).
public struct FixedResponder: PermissionResponder {
    public let decision: PermissionDecision
    public init(_ decision: PermissionDecision) { self.decision = decision }
    public func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision { decision }
}
