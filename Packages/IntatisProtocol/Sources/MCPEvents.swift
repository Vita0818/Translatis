import Foundation
import IntatisCore

// MARK: - Shared event vocabulary

public struct MCPEventCorrelation: Codable, Equatable, Hashable, Sendable {
    public let agentID: AgentID?
    public let taskID: TaskID?
    public let turnID: TurnID?
    public let toolCallID: String?

    public init(agentID: AgentID? = nil,
                taskID: TaskID? = nil,
                turnID: TurnID? = nil,
                toolCallID: String? = nil) {
        self.agentID = agentID
        self.taskID = taskID
        self.turnID = turnID
        self.toolCallID = toolCallID
    }
}

/// Digest and character count of a request whose content is held elsewhere.
/// This deliberately cannot represent the request body.
public struct MCPPayloadFingerprint: Codable, Equatable, Hashable, Sendable {
    public let sha256: String
    public let characterCount: Int

    public init(sha256: String, characterCount: Int) {
        self.sha256 = sha256
        self.characterCount = characterCount
    }
}

/// Bounded, scrubbed connection/runtime diagnostic. Decoding sanitizes again
/// so imported or forged history cannot inject credential-shaped text.
public struct MCPDiagnosticSummary: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let summary: String
    public let redacted: Bool
    public let truncated: Bool

    public init(code: String, summary: String) {
        self = Self.normalized(
            code: code,
            summary: summary,
            declaredRedacted: false,
            declaredTruncated: false)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case summary
        case redacted
        case truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = Self.normalized(
            code: try container.decode(String.self, forKey: .code),
            summary: try container.decode(String.self, forKey: .summary),
            declaredRedacted: try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false,
            declaredTruncated: try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(summary, forKey: .summary)
        try container.encode(redacted, forKey: .redacted)
        try container.encode(truncated, forKey: .truncated)
    }

    private init(code: String, summary: String, redacted: Bool, truncated: Bool) {
        self.code = code
        self.summary = summary
        self.redacted = redacted
        self.truncated = truncated
    }

    private static func normalized(code: String,
                                   summary: String,
                                   declaredRedacted: Bool,
                                   declaredTruncated: Bool) -> MCPDiagnosticSummary {
        let safeCode = PermissionReviewTextSanitizer.sanitize(code, maxCharacters: 80)
        let safeSummary = PermissionReviewTextSanitizer.sanitizeDiagnostic(
            summary,
            maxCharacters: 800)
        return MCPDiagnosticSummary(
            code: safeCode.text,
            summary: safeSummary.text,
            redacted: declaredRedacted || safeCode.redacted || safeSummary.redacted,
            truncated: declaredTruncated || safeCode.truncated || safeSummary.truncated)
    }
}

public enum MCPDurableTerminalStatus: String, Codable, Equatable, Hashable, Sendable {
    case succeeded
    case failed
    case denied
    case cancelled
    case timedOut = "timed_out"
    case disconnected
    case uncertain
}

public enum MCPPolicyChangeReason: String, Codable, Equatable, Hashable, Sendable {
    case user
    case serverDisabled = "server_disabled"
    case serverTombstoned = "server_tombstoned"
    case sessionRemoved = "session_removed"
    case leaseRevoked = "lease_revoked"
    case policyTightened = "policy_tightened"
    case rootsChanged = "roots_changed"
    case networkChanged = "network_changed"
    case credentialChanged = "credential_changed"
    case catalogStale = "catalog_stale"
    case migration
}

// MARK: - Attachment, policy, consent, and grants

public struct MCPServerAttachedPayload: Codable, Equatable, Sendable {
    public let attachment: MCPServerAttachment
    public let actorAgentID: AgentID?

    public init(attachment: MCPServerAttachment, actorAgentID: AgentID? = nil) {
        self.attachment = attachment
        self.actorAgentID = actorAgentID
    }
}

public struct MCPServerDetachedPayload: Codable, Equatable, Sendable {
    public let attachmentID: MCPAttachmentID
    public let server: MCPServerReference
    public let reason: MCPPolicyChangeReason
    public let revocationGeneration: MCPRevocationGeneration
    public let actorAgentID: AgentID?

    public init(attachmentID: MCPAttachmentID,
                server: MCPServerReference,
                reason: MCPPolicyChangeReason,
                revocationGeneration: MCPRevocationGeneration,
                actorAgentID: AgentID? = nil) {
        self.attachmentID = attachmentID
        self.server = server
        self.reason = reason
        self.revocationGeneration = revocationGeneration
        self.actorAgentID = actorAgentID
    }
}

public struct MCPAttachmentPolicyUpdatedPayload: Codable, Equatable, Sendable {
    public let attachmentID: MCPAttachmentID
    public let server: MCPServerReference
    public let previousRevision: MCPPolicyRevision
    public let policy: MCPAttachmentPolicy
    public let revocationGeneration: MCPRevocationGeneration
    public let actorAgentID: AgentID?

    public init(attachmentID: MCPAttachmentID,
                server: MCPServerReference,
                previousRevision: MCPPolicyRevision,
                policy: MCPAttachmentPolicy,
                revocationGeneration: MCPRevocationGeneration,
                actorAgentID: AgentID? = nil) {
        self.attachmentID = attachmentID
        self.server = server
        self.previousRevision = previousRevision
        self.policy = policy
        self.revocationGeneration = revocationGeneration
        self.actorAgentID = actorAgentID
    }
}

public struct MCPConsentGrantedPayload: Codable, Equatable, Sendable {
    public let consent: MCPConsent
    public let actorAgentID: AgentID?

    public init(consent: MCPConsent, actorAgentID: AgentID? = nil) {
        self.consent = consent
        self.actorAgentID = actorAgentID
    }
}

public struct MCPConsentRevokedPayload: Codable, Equatable, Sendable {
    public let consentID: MCPConsentID
    public let kind: MCPConsentKind
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let reason: MCPPolicyChangeReason
    public let revocationGeneration: MCPRevocationGeneration
    public let actorAgentID: AgentID?

    public init(consentID: MCPConsentID,
                kind: MCPConsentKind,
                server: MCPServerReference,
                attachmentID: MCPAttachmentID,
                reason: MCPPolicyChangeReason,
                revocationGeneration: MCPRevocationGeneration,
                actorAgentID: AgentID? = nil) {
        self.consentID = consentID
        self.kind = kind
        self.server = server
        self.attachmentID = attachmentID
        self.reason = reason
        self.revocationGeneration = revocationGeneration
        self.actorAgentID = actorAgentID
    }
}

public struct MCPGrantGrantedPayload: Codable, Equatable, Sendable {
    public let grant: MCPGrant

    public init(grant: MCPGrant) {
        self.grant = grant
    }
}

public struct MCPGrantRevokedPayload: Codable, Equatable, Sendable {
    public let grantID: MCPGrantID
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let agentID: AgentID
    public let reason: MCPPolicyChangeReason
    public let revocationGeneration: MCPRevocationGeneration

    public init(grantID: MCPGrantID,
                server: MCPServerReference,
                attachmentID: MCPAttachmentID,
                agentID: AgentID,
                reason: MCPPolicyChangeReason,
                revocationGeneration: MCPRevocationGeneration) {
        self.grantID = grantID
        self.server = server
        self.attachmentID = attachmentID
        self.agentID = agentID
        self.reason = reason
        self.revocationGeneration = revocationGeneration
    }
}

public struct MCPRememberedApprovalGrantedPayload:
    Codable, Equatable, Sendable
{
    public let approval:
        MCPRememberedToolApproval

    public init(
        approval: MCPRememberedToolApproval
    ) {
        self.approval = approval
    }
}

public struct MCPRememberedApprovalRevokedPayload:
    Codable, Equatable, Sendable
{
    public let approvalID:
        MCPRememberedApprovalID
    public let reason: MCPPolicyChangeReason

    public init(
        approvalID: MCPRememberedApprovalID,
        reason: MCPPolicyChangeReason
    ) {
        self.approvalID = approvalID
        self.reason = reason
    }
}

// MARK: - Control-plane operations

public enum MCPControlOperationKind: String, Codable, Equatable, Hashable, Sendable {
    case test
    case connect
    case refresh
    case disconnect
}

public struct MCPControlOperationRequestedPayload: Codable, Equatable, Sendable {
    public let operationID: MCPControlOperationID
    public let kind: MCPControlOperationKind
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID?
    public let authorityFingerprint: String
    public let correlation: MCPEventCorrelation

    public init(operationID: MCPControlOperationID = .new(),
                kind: MCPControlOperationKind,
                server: MCPServerReference,
                attachmentID: MCPAttachmentID? = nil,
                authorityFingerprint: String,
                correlation: MCPEventCorrelation = .init()) {
        self.operationID = operationID
        self.kind = kind
        self.server = server
        self.attachmentID = attachmentID
        self.authorityFingerprint = authorityFingerprint
        self.correlation = correlation
    }
}

public struct MCPControlOperationSettledPayload: Codable, Equatable, Sendable {
    public let operationID: MCPControlOperationID
    public let kind: MCPControlOperationKind
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID?
    public let status: MCPDurableTerminalStatus
    public let connectionGeneration: MCPConnectionGeneration?
    public let diagnostic: MCPDiagnosticSummary?

    public init(operationID: MCPControlOperationID,
                kind: MCPControlOperationKind,
                server: MCPServerReference,
                attachmentID: MCPAttachmentID? = nil,
                status: MCPDurableTerminalStatus,
                connectionGeneration: MCPConnectionGeneration? = nil,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.operationID = operationID
        self.kind = kind
        self.server = server
        self.attachmentID = attachmentID
        self.status = status
        self.connectionGeneration = connectionGeneration
        self.diagnostic = diagnostic
    }
}

// MARK: - Roots and network policy

public struct MCPRootAuthoritySummary: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: WorkspaceID
    public let workspaceLeaseID: WorkspaceLeaseID
    public let rootIdentityFingerprint: String
    public let access: WorkspaceAccess

    public init(workspaceID: WorkspaceID,
                workspaceLeaseID: WorkspaceLeaseID,
                rootIdentityFingerprint: String,
                access: WorkspaceAccess) {
        self.workspaceID = workspaceID
        self.workspaceLeaseID = workspaceLeaseID
        self.rootIdentityFingerprint = rootIdentityFingerprint
        self.access = access
    }
}

public struct MCPRootsPolicyUpdatedPayload: Codable, Equatable, Sendable {
    public let revision: MCPPolicyRevision
    public let previousRevision: MCPPolicyRevision?
    public let roots: [MCPRootAuthoritySummary]
    public let revocationGeneration: MCPRevocationGeneration
    public let actorAgentID: AgentID?

    public init(revision: MCPPolicyRevision,
                previousRevision: MCPPolicyRevision? = nil,
                roots: [MCPRootAuthoritySummary],
                revocationGeneration: MCPRevocationGeneration,
                actorAgentID: AgentID? = nil) {
        self.revision = revision
        self.previousRevision = previousRevision
        self.roots = roots
        self.revocationGeneration = revocationGeneration
        self.actorAgentID = actorAgentID
    }
}

public enum MCPNetworkAccess: String, Codable, Equatable, Hashable, Sendable {
    case denied
    case httpsOnly = "https_only"
    case allowlisted
}

public enum MCPProxyPolicy: String, Codable, Equatable, Hashable, Sendable {
    case disabled
    case system
    case configuredReference = "configured_reference"
}

public struct MCPNetworkPolicyUpdatedPayload: Codable, Equatable, Sendable {
    public let revision: MCPPolicyRevision
    public let previousRevision: MCPPolicyRevision?
    public let access: MCPNetworkAccess
    /// Hashes of canonical origins; complete private origins are not persisted
    /// in the session EventLog.
    public let allowedOriginDigests: [String]
    public let proxyPolicy: MCPProxyPolicy
    public let revocationGeneration: MCPRevocationGeneration
    public let actorAgentID: AgentID?

    public init(revision: MCPPolicyRevision,
                previousRevision: MCPPolicyRevision? = nil,
                access: MCPNetworkAccess,
                allowedOriginDigests: [String] = [],
                proxyPolicy: MCPProxyPolicy = .disabled,
                revocationGeneration: MCPRevocationGeneration,
                actorAgentID: AgentID? = nil) {
        self.revision = revision
        self.previousRevision = previousRevision
        self.access = access
        self.allowedOriginDigests = Array(Set(allowedOriginDigests)).sorted()
        self.proxyPolicy = proxyPolicy
        self.revocationGeneration = revocationGeneration
        self.actorAgentID = actorAgentID
    }
}

// MARK: - Prompt insertion

public struct MCPPromptInsertedPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let promptName: String
    public let arguments: MCPPayloadFingerprint
    public let insertedMessageID: MessageID
    public let provenance: MCPContentProvenance
    public let selectedByAgentID: AgentID?

    public init(requestID: RequestID,
                promptName: String,
                arguments: MCPPayloadFingerprint,
                insertedMessageID: MessageID,
                provenance: MCPContentProvenance,
                selectedByAgentID: AgentID? = nil) {
        self.requestID = requestID
        self.promptName = promptName
        self.arguments = arguments
        self.insertedMessageID = insertedMessageID
        self.provenance = provenance
        self.selectedByAgentID = selectedByAgentID
    }
}

// MARK: - Sampling

public enum MCPBrokerDecision: String, Codable, Equatable, Hashable, Sendable {
    case allow
    case deny
    case cancel
}

public enum MCPBrokerDecisionSource: String, Codable, Equatable, Hashable, Sendable {
    case user
    case deterministicPolicy = "deterministic_policy"
    case automaticReviewer = "automatic_reviewer"
    case host
}

public struct MCPSamplingRequestedPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let request: MCPPayloadFingerprint
    public let maxOutputTokens: Int?
    public let correlation: MCPEventCorrelation

    public init(requestID: RequestID,
                server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                request: MCPPayloadFingerprint,
                maxOutputTokens: Int? = nil,
                correlation: MCPEventCorrelation = .init()) {
        self.requestID = requestID
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.request = request
        self.maxOutputTokens = maxOutputTokens
        self.correlation = correlation
    }
}

public struct MCPSamplingDecidedPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let decision: MCPBrokerDecision
    public let source: MCPBrokerDecisionSource
    public let reasonCode: String

    public init(requestID: RequestID,
                decision: MCPBrokerDecision,
                source: MCPBrokerDecisionSource,
                reasonCode: String) {
        self.requestID = requestID
        self.decision = decision
        self.source = source
        self.reasonCode = reasonCode
    }
}

public struct MCPSamplingSettledPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let status: MCPDurableTerminalStatus
    public let resultReference: MCPResultReference?
    public let diagnostic: MCPDiagnosticSummary?

    public init(requestID: RequestID,
                status: MCPDurableTerminalStatus,
                resultReference: MCPResultReference? = nil,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.requestID = requestID
        self.status = status
        self.resultReference = resultReference
        self.diagnostic = diagnostic
    }
}

// MARK: - Elicitation

public enum MCPElicitationMode: String, Codable, Equatable, Hashable, Sendable {
    case form
    case url
}

public struct MCPElicitationRequestedPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let mode: MCPElicitationMode
    public let request: MCPPayloadFingerprint
    public let correlation: MCPEventCorrelation

    public init(requestID: RequestID,
                server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                mode: MCPElicitationMode,
                request: MCPPayloadFingerprint,
                correlation: MCPEventCorrelation = .init()) {
        self.requestID = requestID
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.mode = mode
        self.request = request
        self.correlation = correlation
    }
}

public struct MCPElicitationDecidedPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let decision: MCPBrokerDecision
    public let source: MCPBrokerDecisionSource
    public let reasonCode: String

    public init(requestID: RequestID,
                decision: MCPBrokerDecision,
                source: MCPBrokerDecisionSource,
                reasonCode: String) {
        self.requestID = requestID
        self.decision = decision
        self.source = source
        self.reasonCode = reasonCode
    }
}

public struct MCPElicitationSettledPayload: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let status: MCPDurableTerminalStatus
    public let resultReference: MCPResultReference?
    public let diagnostic: MCPDiagnosticSummary?

    public init(requestID: RequestID,
                status: MCPDurableTerminalStatus,
                resultReference: MCPResultReference? = nil,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.requestID = requestID
        self.status = status
        self.resultReference = resultReference
        self.diagnostic = diagnostic
    }
}

// MARK: - MCP task lifecycles

public enum MCPTaskState: String, Codable, Equatable, Hashable, Sendable {
    case requested
    case working
    case inputRequired = "input_required"
    case completed
    case failed
    case cancelled
}

public enum MCPRemoteTaskOperation: String, Codable, Equatable, Hashable, Sendable {
    case toolCall = "tool_call"
    case resourceRead = "resource_read"
    case promptGet = "prompt_get"
    case completion
}

public struct MCPRemoteTaskRequestedPayload: Codable, Equatable, Sendable {
    public let taskID: MCPRemoteServerTaskID
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let operation: MCPRemoteTaskOperation
    public let request: MCPPayloadFingerprint
    public let correlation: MCPEventCorrelation

    public init(taskID: MCPRemoteServerTaskID = .new(),
                server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                operation: MCPRemoteTaskOperation,
                request: MCPPayloadFingerprint,
                correlation: MCPEventCorrelation = .init()) {
        self.taskID = taskID
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.operation = operation
        self.request = request
        self.correlation = correlation
    }
}

public struct MCPRemoteTaskMappedPayload: Codable, Equatable, Sendable {
    public let taskID: MCPRemoteServerTaskID
    /// Digest of the server-issued opaque task identifier; the raw identifier
    /// remains in the live runtime's protected mapping store.
    public let remoteTaskReference: MCPPayloadFingerprint

    public init(taskID: MCPRemoteServerTaskID, remoteTaskReference: MCPPayloadFingerprint) {
        self.taskID = taskID
        self.remoteTaskReference = remoteTaskReference
    }
}

public struct MCPRemoteTaskStateChangedPayload: Codable, Equatable, Sendable {
    public let taskID: MCPRemoteServerTaskID
    public let state: MCPTaskState
    public let stateRevision: Int

    public init(taskID: MCPRemoteServerTaskID, state: MCPTaskState, stateRevision: Int) {
        self.taskID = taskID
        self.state = state
        self.stateRevision = stateRevision
    }
}

public struct MCPRemoteTaskSettledPayload: Codable, Equatable, Sendable {
    public let taskID: MCPRemoteServerTaskID
    public let status: MCPDurableTerminalStatus
    public let resultReference: MCPResultReference?
    public let diagnostic: MCPDiagnosticSummary?

    public init(taskID: MCPRemoteServerTaskID,
                status: MCPDurableTerminalStatus,
                resultReference: MCPResultReference? = nil,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.taskID = taskID
        self.status = status
        self.resultReference = resultReference
        self.diagnostic = diagnostic
    }
}

public enum MCPClientTaskKind: String, Codable, Equatable, Hashable, Sendable {
    case sampling
    case elicitation
}

public struct MCPClientTaskRequestedPayload: Codable, Equatable, Sendable {
    public let taskID: MCPClientHostedTaskID
    public let kind: MCPClientTaskKind
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let request: MCPPayloadFingerprint
    public let correlation: MCPEventCorrelation

    public init(taskID: MCPClientHostedTaskID = .new(),
                kind: MCPClientTaskKind,
                server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                request: MCPPayloadFingerprint,
                correlation: MCPEventCorrelation = .init()) {
        self.taskID = taskID
        self.kind = kind
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.request = request
        self.correlation = correlation
    }
}

public struct MCPClientTaskStateChangedPayload: Codable, Equatable, Sendable {
    public let taskID: MCPClientHostedTaskID
    public let state: MCPTaskState
    public let stateRevision: Int

    public init(taskID: MCPClientHostedTaskID, state: MCPTaskState, stateRevision: Int) {
        self.taskID = taskID
        self.state = state
        self.stateRevision = stateRevision
    }
}

public struct MCPClientTaskSettledPayload: Codable, Equatable, Sendable {
    public let taskID: MCPClientHostedTaskID
    public let status: MCPDurableTerminalStatus
    public let resultReference: MCPResultReference?
    public let diagnostic: MCPDiagnosticSummary?

    public init(taskID: MCPClientHostedTaskID,
                status: MCPDurableTerminalStatus,
                resultReference: MCPResultReference? = nil,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.taskID = taskID
        self.status = status
        self.resultReference = resultReference
        self.diagnostic = diagnostic
    }
}

// MARK: - Low-frequency request progress

public enum MCPRequestProgressPhase:
    String, Codable, Equatable, Hashable, Sendable
{
    case reported
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"
}

/// Secret-free, low-frequency progress milestone for one exact outbound MCP
/// request. Raw request IDs, progress tokens, server log values, and request
/// arguments are deliberately absent; their cryptographic fingerprints retain
/// exact correlation without turning EventLog into a payload channel.
public struct MCPRequestProgressPayload:
    Codable, Equatable, Sendable
{
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let authorityFingerprint: String
    public let requestIDFingerprint: String
    public let progressTokenFingerprint: String
    public let requestMethod: String
    public let progress: Double
    public let total: Double?
    public let phase: MCPRequestProgressPhase
    public let diagnostic: MCPDiagnosticSummary?

    public init(
        server: MCPServerReference,
        connectionGeneration: MCPConnectionGeneration,
        authorityFingerprint: String,
        requestIDFingerprint: String,
        progressTokenFingerprint: String,
        requestMethod: String,
        progress: Double,
        total: Double? = nil,
        phase: MCPRequestProgressPhase,
        diagnostic: MCPDiagnosticSummary? = nil
    ) {
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.authorityFingerprint =
            Self.safeIdentity(authorityFingerprint)
        self.requestIDFingerprint =
            Self.safeIdentity(requestIDFingerprint)
        self.progressTokenFingerprint =
            Self.safeIdentity(progressTokenFingerprint)
        self.requestMethod =
            PermissionReviewTextSanitizer.sanitize(
                requestMethod,
                maxCharacters: 96).text
        let safeProgress =
            progress.isFinite ? max(0, progress) : 0
        self.progress = safeProgress
        if let total,
           total.isFinite,
           total > 0,
           total >= safeProgress {
            self.total = total
        } else {
            self.total = nil
        }
        self.phase = phase
        self.diagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case server
        case connectionGeneration
        case authorityFingerprint
        case requestIDFingerprint
        case progressTokenFingerprint
        case requestMethod
        case progress
        case total
        case phase
        case diagnostic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self)
        self.init(
            server: try container.decode(
                MCPServerReference.self,
                forKey: .server),
            connectionGeneration: try container.decode(
                MCPConnectionGeneration.self,
                forKey: .connectionGeneration),
            authorityFingerprint: try container.decode(
                String.self,
                forKey: .authorityFingerprint),
            requestIDFingerprint: try container.decode(
                String.self,
                forKey: .requestIDFingerprint),
            progressTokenFingerprint: try container.decode(
                String.self,
                forKey: .progressTokenFingerprint),
            requestMethod: try container.decode(
                String.self,
                forKey: .requestMethod),
            progress: try container.decode(
                Double.self,
                forKey: .progress),
            total: try container.decodeIfPresent(
                Double.self,
                forKey: .total),
            phase: try container.decode(
                MCPRequestProgressPhase.self,
                forKey: .phase),
            diagnostic: try container.decodeIfPresent(
                MCPDiagnosticSummary.self,
                forKey: .diagnostic))
    }

    private static func safeIdentity(_ value: String) -> String {
        PermissionReviewTextSanitizer.sanitize(
            value,
            maxCharacters: 128).text
    }
}

// MARK: - Important connection/catalog terminals and uncertain execution

public enum MCPConnectionTerminalStatus: String, Codable, Equatable, Hashable, Sendable {
    case ready
    case failed
    case disconnected
    case cancelled
}

public struct MCPConnectionTerminalPayload: Codable, Equatable, Sendable {
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let connectionGeneration: MCPConnectionGeneration
    public let authorityFingerprint: String
    public let status: MCPConnectionTerminalStatus
    public let negotiatedProtocolVersion: MCPNegotiatedProtocolVersion?
    public let diagnostic: MCPDiagnosticSummary?

    public init(server: MCPServerReference,
                attachmentID: MCPAttachmentID,
                connectionGeneration: MCPConnectionGeneration,
                authorityFingerprint: String,
                status: MCPConnectionTerminalStatus,
                negotiatedProtocolVersion: MCPNegotiatedProtocolVersion? = nil,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.server = server
        self.attachmentID = attachmentID
        self.connectionGeneration = connectionGeneration
        self.authorityFingerprint = authorityFingerprint
        self.status = status
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
        self.diagnostic = diagnostic
    }
}

public enum MCPCatalogTerminalStatus: String, Codable, Equatable, Hashable, Sendable {
    case published
    case failed
    case stale
}

public struct MCPCatalogTerminalPayload: Codable, Equatable, Sendable {
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let status: MCPCatalogTerminalStatus
    public let rawCatalogRevision: MCPRawCatalogRevision?
    public let catalogHash: String?
    public let toolCount: Int
    public let resourceCount: Int
    public let resourceTemplateCount: Int
    public let promptCount: Int
    public let diagnostic: MCPDiagnosticSummary?

    public init(server: MCPServerReference,
                connectionGeneration: MCPConnectionGeneration,
                status: MCPCatalogTerminalStatus,
                rawCatalogRevision: MCPRawCatalogRevision? = nil,
                catalogHash: String? = nil,
                toolCount: Int = 0,
                resourceCount: Int = 0,
                resourceTemplateCount: Int = 0,
                promptCount: Int = 0,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.status = status
        self.rawCatalogRevision = rawCatalogRevision
        self.catalogHash = catalogHash
        self.toolCount = toolCount
        self.resourceCount = resourceCount
        self.resourceTemplateCount = resourceTemplateCount
        self.promptCount = promptCount
        self.diagnostic = diagnostic
    }
}

public enum MCPExecutionUncertaintyReason: String, Codable, Equatable, Hashable, Sendable {
    case transportInterruptedAfterDispatch = "transport_interrupted_after_dispatch"
    case timeoutAfterDispatch = "timeout_after_dispatch"
    case cancellationAfterDispatch = "cancellation_after_dispatch"
    case processExitedAfterDispatch = "process_exited_after_dispatch"
    case recoveryGap = "recovery_gap"
}

public struct MCPExecutionUncertainPayload: Codable, Equatable, Sendable {
    public let executionID: String
    public let authorizationID: String
    public let correlation: MCPEventCorrelation
    public let authorization: MCPToolAuthorizationSnapshot
    public let reason: MCPExecutionUncertaintyReason
    public let effectDisposition: ToolExecutionEffectDisposition
    public let diagnostic: MCPDiagnosticSummary?

    public init(executionID: String,
                authorizationID: String,
                correlation: MCPEventCorrelation,
                authorization: MCPToolAuthorizationSnapshot,
                reason: MCPExecutionUncertaintyReason,
                effectDisposition: ToolExecutionEffectDisposition = .unknown,
                diagnostic: MCPDiagnosticSummary? = nil) {
        self.executionID = executionID
        self.authorizationID = authorizationID
        self.correlation = correlation
        self.authorization = authorization
        self.reason = reason
        self.effectDisposition = effectDisposition
        self.diagnostic = diagnostic
    }
}
