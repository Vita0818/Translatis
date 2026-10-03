import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisProtocol
import IntatisProviders

/// PermissionResponder backed by the reserved Cowork permission-review agent.
/// Review work is delegated to a dedicated control-plane actor: it never enters
/// TaskGraph/AgentScheduler and never starts a nested AgentLoop.
public struct AgentPermissionResponder: PermissionResponder {
    private let controlPlane: PermissionReviewControlPlane

    public var approvalMode: PermissionApprovalMode { .automaticReviewer }

    public init(log: EventLog,
                reviewerAgent: Agent,
                provider: ToolCallingProvider,
                fallback: PermissionResponder,
                maxRecentEvents: Int = 36,
                policy: PermissionReviewControlPlanePolicy? = nil,
                eventAppender: PermissionReviewEventAppender? = nil) {
        self.init(
            log: log,
            reviewerAgent: reviewerAgent,
            providerFactory: { provider },
            fallback: fallback,
            maxRecentEvents: maxRecentEvents,
            policy: policy,
            eventAppender: eventAppender)
    }

    public init(log: EventLog,
                reviewerAgent: Agent,
                providerFactory: @escaping PermissionReviewProviderFactory,
                fallback: PermissionResponder,
                maxRecentEvents: Int = 36,
                policy: PermissionReviewControlPlanePolicy? = nil,
                eventAppender: PermissionReviewEventAppender? = nil) {
        var effectivePolicy = policy ?? PermissionReviewControlPlanePolicy()
        if policy == nil {
            effectivePolicy.maxRecentEvents = max(1, maxRecentEvents)
        }
        controlPlane = PermissionReviewControlPlane(
            log: log,
            reviewerAgent: reviewerAgent,
            providerFactory: providerFactory,
            fallback: fallback,
            policy: effectivePolicy,
            eventAppender: eventAppender)
    }

    public func requestApproval(_ request: PermissionRequestPayload) async -> PermissionDecision {
        await controlPlane.submit(request)
    }

    public func requestResolution(_ request: PermissionRequestPayload) async -> PermissionApprovalResolution {
        await controlPlane.submitResolution(request)
    }

    public func requestResolution(
        _ request: PermissionRequestPayload,
        invocation: PermissionReviewInvocationInput
    ) async -> PermissionApprovalResolution {
        await controlPlane.submitResolution(
            request,
            invocation: invocation)
    }

    /// Dedicated host-only entry for the synthetic `agent.attach` admission
    /// transaction. Ordinary model-authored tools must use the bound invocation
    /// overload above and cannot obtain this exemption from request fields.
    func requestHostAgentAdmissionResolution(
        _ request: PermissionRequestPayload
    ) async -> PermissionApprovalResolution {
        await controlPlane.submitHostAgentAdmissionResolution(request)
    }

    public func health() async -> PermissionReviewControlPlaneHealth {
        await controlPlane.health()
    }

    public func quiesce(reason: String) async {
        await controlPlane.quiesce(reason: reason)
    }

    public func resumeAfterFailedQuiesce() async {
        await controlPlane.resumeAfterFailedQuiesce()
    }

    public func finalizeShutdown() async {
        await controlPlane.finalizeShutdown()
    }

    /// Stops accepting review work and resolves queued/running requests safely.
    /// The provider race is cancellation-aware and does not wait for a provider
    /// implementation that ignores cooperative cancellation.
    public func shutdown(reason: String = "automatic permission review disabled") async {
        await controlPlane.shutdown(reason: reason)
    }
}
