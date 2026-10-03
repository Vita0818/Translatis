import Foundation
import IntatisCore
import IntatisProtocol

/// Host-control operations that can create or change MCP ambient authority.
public enum MCPControlPlaneAction:
    String, Codable, Equatable, Hashable, Sendable {
    case test
    case launch
    case connect
    case authenticate
    case refresh
    case subscribe
    case disconnect
    case installProposal = "install_proposal"

    var requiresExactConnectionConsent: Bool {
        switch self {
        case .launch, .connect, .refresh, .subscribe:
            return true
        case .test, .authenticate, .disconnect, .installProposal:
            return false
        }
    }

    var requiresDirectUserActionWithoutConnectionConsent: Bool {
        switch self {
        case .test, .authenticate, .disconnect, .installProposal:
            return true
        case .launch, .connect, .refresh, .subscribe:
            return false
        }
    }
}

/// Exact, secret-free consent lookup key.
public struct MCPConsentRequirement: Equatable, Hashable, Sendable {
    public let kind: MCPConsentKind
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let authorityFingerprint: String
    public let launchArtifactFingerprint: String?
    public let accountReference: MCPAccountReference?
    public let environmentReference: MCPEnvironmentReference
    public let policyRevision: MCPPolicyRevision

    public init(
        identity: MCPConnectionReuseIdentity
    ) {
        kind = identity.transport == .stdio ? .launch : .connect
        server = identity.server
        attachmentID = identity.authority.attachmentID
        authorityFingerprint = identity.authority.fingerprint
        launchArtifactFingerprint = identity.launchArtifactFingerprint
        accountReference = identity.oauthAccountReference
        environmentReference = identity.environmentReference
        policyRevision = identity.authority.attachmentPolicyRevision
    }

    public func exactlyMatches(_ consent: MCPConsent) -> Bool {
        consent.kind == kind
            && consent.server == server
            && consent.attachmentID == attachmentID
            && consent.authorityFingerprint == authorityFingerprint
            && consent.launchArtifactFingerprint
                == launchArtifactFingerprint
            && consent.accountReference == accountReference
            && consent.environmentReference == environmentReference
            && consent.policyRevision == policyRevision
    }
}

/// A sanitized request persisted before control-plane authorization is used.
public struct MCPControlPlaneAdmissionRequest: Equatable, Sendable {
    public let operationID: MCPControlOperationID
    public let action: MCPControlPlaneAction
    public let sessionID: SessionID
    public let identity: MCPConnectionReuseIdentity
    public let revocationGeneration: MCPRevocationGeneration
    public let callerFingerprint: String
    public let directUserAction: Bool
    public let correlation: MCPEventCorrelation

    public init(
        operationID: MCPControlOperationID = .new(),
        action: MCPControlPlaneAction,
        sessionID: SessionID,
        identity: MCPConnectionReuseIdentity,
        revocationGeneration: MCPRevocationGeneration,
        callerFingerprint: String,
        directUserAction: Bool,
        correlation: MCPEventCorrelation = .init()
    ) {
        self.operationID = operationID
        self.action = action
        self.sessionID = sessionID
        self.identity = identity
        self.revocationGeneration = revocationGeneration
        self.callerFingerprint = callerFingerprint
        self.directUserAction = directUserAction
        self.correlation = correlation
    }
}

public enum MCPControlPlaneHardGateDecision: Equatable, Sendable {
    case allow
    case deny(MCPDiagnosticSummary)
}

/// Deterministic platform/identity/root/network/sandbox gate.
///
/// It is required injection; there is deliberately no permissive default.
public protocol MCPControlPlaneHardGate: Sendable {
    func evaluate(
        _ request: MCPControlPlaneAdmissionRequest
    ) async -> MCPControlPlaneHardGateDecision
}

/// Durable consent projection. Implementations normally read an EventLog-first
/// session projection, but the MCP module does not depend on EventLog.
public protocol MCPExactConsentSource: Sendable {
    func consent(
        matching requirement: MCPConsentRequirement
    ) async throws -> MCPConsent?
}

/// Host-neutral durable audit seam.
///
/// Implementations must provide first-write request and first-terminal
/// settlement semantics. A failed/uncertain write makes admission fail closed.
public protocol MCPControlPlaneAuditSink: Sendable {
    func register(
        _ request: MCPControlPlaneAdmissionRequest
    ) async throws
    func settle(
        _ settlement: MCPControlPlaneAdmissionSettlement
    ) async throws
}

public struct MCPControlPlaneAdmissionTicket: Equatable, Sendable {
    public let request: MCPControlPlaneAdmissionRequest
    public let consentID: MCPConsentID?

    init(
        request: MCPControlPlaneAdmissionRequest,
        consentID: MCPConsentID?
    ) {
        self.request = request
        self.consentID = consentID
    }
}

public struct MCPControlPlaneAdmissionSettlement: Equatable, Sendable {
    public let operationID: MCPControlOperationID
    public let action: MCPControlPlaneAction
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let status: MCPDurableTerminalStatus
    public let connectionGeneration: MCPConnectionGeneration?
    public let diagnostic: MCPDiagnosticSummary?

    public init(
        operationID: MCPControlOperationID,
        action: MCPControlPlaneAction,
        server: MCPServerReference,
        attachmentID: MCPAttachmentID,
        status: MCPDurableTerminalStatus,
        connectionGeneration: MCPConnectionGeneration? = nil,
        diagnostic: MCPDiagnosticSummary? = nil
    ) {
        self.operationID = operationID
        self.action = action
        self.server = server
        self.attachmentID = attachmentID
        self.status = status
        self.connectionGeneration = connectionGeneration
        self.diagnostic = diagnostic
    }
}

public enum MCPControlPlaneAdmissionError:
    Error, Equatable, LocalizedError {
    case stopped
    case wrongSession(expected: SessionID, actual: SessionID)
    case duplicateOperation(MCPControlOperationID)
    case unknownTicket(MCPControlOperationID)
    case conflictingSettlement(MCPControlOperationID)
    case directUserActionRequired(MCPControlPlaneAction)
    case actionTransportMismatch(
        action: MCPControlPlaneAction,
        transport: MCPTransportKind
    )
    case hardDenied(MCPDiagnosticSummary)
    case exactConsentMissing(MCPConsentRequirement)
    case exactConsentMismatch(MCPConsentRequirement)
    case auditFailure(MCPDiagnosticSummary)

    public var errorDescription: String? {
        switch self {
        case .stopped:
            return "MCP control-plane admission is stopped"
        case .wrongSession(let expected, let actual):
            return "MCP control operation belongs to session \(actual), expected \(expected)"
        case .duplicateOperation(let operationID):
            return "MCP control operation \(operationID) is already registered"
        case .unknownTicket(let operationID):
            return "MCP control operation \(operationID) has no live admission ticket"
        case .conflictingSettlement(let operationID):
            return "MCP control operation \(operationID) already has a different terminal"
        case .directUserActionRequired(let action):
            return "MCP control action \(action.rawValue) requires a direct user action"
        case .actionTransportMismatch(let action, let transport):
            return "MCP action \(action.rawValue) does not match transport \(transport.rawValue)"
        case .hardDenied(let diagnostic):
            return diagnostic.summary
        case .exactConsentMissing:
            return "Exact MCP launch/connect consent is missing"
        case .exactConsentMismatch:
            return "MCP launch/connect consent does not match the current identity"
        case .auditFailure(let diagnostic):
            return diagnostic.summary
        }
    }
}

public struct MCPControlPlaneAdmissionShutdownReport:
    Equatable, Sendable {
    public let settledOperationIDs: [MCPControlOperationID]
    public let unresolvedOperationIDs: [MCPControlOperationID]

    public init(
        settledOperationIDs: [MCPControlOperationID],
        unresolvedOperationIDs: [MCPControlOperationID]
    ) {
        self.settledOperationIDs = settledOperationIDs.sorted {
            $0.rawValue < $1.rawValue
        }
        self.unresolvedOperationIDs = unresolvedOperationIDs.sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

/// Exact session control-plane gate and operation ledger coordinator.
public actor MCPControlPlaneAdmission {
    public nonisolated let sessionID: SessionID

    private let hardGate: any MCPControlPlaneHardGate
    private let consentSource: any MCPExactConsentSource
    private let auditSink: any MCPControlPlaneAuditSink
    private var accepting = true
    private var outstanding:
        [MCPControlOperationID: MCPControlPlaneAdmissionTicket] = [:]
    private var settled:
        [MCPControlOperationID: MCPControlPlaneAdmissionSettlement] = [:]
    private var settlementOrder: [MCPControlOperationID] = []
    private let retainedSettlementLimit = 1_024

    public init(
        sessionID: SessionID,
        hardGate: any MCPControlPlaneHardGate,
        consentSource: any MCPExactConsentSource,
        auditSink: any MCPControlPlaneAuditSink
    ) {
        self.sessionID = sessionID
        self.hardGate = hardGate
        self.consentSource = consentSource
        self.auditSink = auditSink
    }

    public func begin(
        _ request: MCPControlPlaneAdmissionRequest
    ) async throws -> MCPControlPlaneAdmissionTicket {
        guard accepting else {
            throw MCPControlPlaneAdmissionError.stopped
        }
        guard request.sessionID == sessionID else {
            throw MCPControlPlaneAdmissionError.wrongSession(
                expected: sessionID,
                actual: request.sessionID)
        }
        guard outstanding[request.operationID] == nil,
              settled[request.operationID] == nil else {
            throw MCPControlPlaneAdmissionError.duplicateOperation(
                request.operationID)
        }

        do {
            try await auditSink.register(request)
        } catch {
            throw MCPControlPlaneAdmissionError.auditFailure(
                Self.auditDiagnostic(error))
        }

        guard accepting else {
            let diagnostic = MCPDiagnosticSummary(
                code: "control_plane_stopped",
                summary: "MCP control-plane admission stopped before authorization")
            try await persistRejected(
                request,
                status: .cancelled,
                diagnostic: diagnostic)
            throw MCPControlPlaneAdmissionError.stopped
        }

        if request.action.requiresDirectUserActionWithoutConnectionConsent,
           !request.directUserAction {
            let diagnostic = MCPDiagnosticSummary(
                code: "direct_user_action_required",
                summary: "This MCP control action requires an explicit user action")
            try await persistRejected(
                request,
                status: .denied,
                diagnostic: diagnostic)
            throw MCPControlPlaneAdmissionError.directUserActionRequired(
                request.action)
        }

        if (request.action == .launch
                && request.identity.transport != .stdio)
            || (request.action == .connect
                && request.identity.transport != .streamableHTTP) {
            let diagnostic = MCPDiagnosticSummary(
                code: "action_transport_mismatch",
                summary: "MCP launch/connect action does not match the configured transport")
            try await persistRejected(
                request,
                status: .denied,
                diagnostic: diagnostic)
            throw MCPControlPlaneAdmissionError.actionTransportMismatch(
                action: request.action,
                transport: request.identity.transport)
        }

        switch await hardGate.evaluate(request) {
        case .allow:
            break
        case .deny(let diagnostic):
            try await persistRejected(
                request,
                status: .denied,
                diagnostic: diagnostic)
            throw MCPControlPlaneAdmissionError.hardDenied(diagnostic)
        }

        var consentID: MCPConsentID?
        if request.action.requiresExactConnectionConsent {
            let requirement = MCPConsentRequirement(
                identity: request.identity)
            let consent: MCPConsent?
            do {
                consent = try await consentSource.consent(
                    matching: requirement)
            } catch {
                let diagnostic = Self.auditDiagnostic(error)
                try await persistRejected(
                    request,
                    status: .denied,
                    diagnostic: diagnostic)
                throw MCPControlPlaneAdmissionError.auditFailure(
                    diagnostic)
            }
            guard let consent else {
                let diagnostic = MCPDiagnosticSummary(
                    code: "exact_consent_missing",
                    summary: "No exact launch/connect consent exists for this MCP identity")
                try await persistRejected(
                    request,
                    status: .denied,
                    diagnostic: diagnostic)
                throw MCPControlPlaneAdmissionError.exactConsentMissing(
                    requirement)
            }
            guard requirement.exactlyMatches(consent) else {
                let diagnostic = MCPDiagnosticSummary(
                    code: "exact_consent_mismatch",
                    summary: "Stored MCP consent does not match the current revision, authority, account, environment, or launch identity")
                try await persistRejected(
                    request,
                    status: .denied,
                    diagnostic: diagnostic)
                throw MCPControlPlaneAdmissionError.exactConsentMismatch(
                    requirement)
            }
            consentID = consent.consentID
        }

        guard accepting else {
            let diagnostic = MCPDiagnosticSummary(
                code: "control_plane_stopped",
                summary: "MCP control-plane admission stopped before action start")
            try await persistRejected(
                request,
                status: .cancelled,
                diagnostic: diagnostic)
            throw MCPControlPlaneAdmissionError.stopped
        }

        let ticket = MCPControlPlaneAdmissionTicket(
            request: request,
            consentID: consentID)
        outstanding[request.operationID] = ticket
        return ticket
    }

    public func settle(
        _ ticket: MCPControlPlaneAdmissionTicket,
        status: MCPDurableTerminalStatus,
        connectionGeneration: MCPConnectionGeneration? = nil,
        diagnostic: MCPDiagnosticSummary? = nil
    ) async throws {
        let operationID = ticket.request.operationID
        let settlement = MCPControlPlaneAdmissionSettlement(
            operationID: operationID,
            action: ticket.request.action,
            server: ticket.request.identity.server,
            attachmentID:
                ticket.request.identity.authority.attachmentID,
            status: status,
            connectionGeneration: connectionGeneration,
            diagnostic: diagnostic)

        if let existing = settled[operationID] {
            guard existing == settlement else {
                throw MCPControlPlaneAdmissionError.conflictingSettlement(
                    operationID)
            }
            return
        }
        guard outstanding[operationID] == ticket else {
            throw MCPControlPlaneAdmissionError.unknownTicket(operationID)
        }

        do {
            try await auditSink.settle(settlement)
        } catch {
            throw MCPControlPlaneAdmissionError.auditFailure(
                Self.auditDiagnostic(error))
        }
        outstanding.removeValue(forKey: operationID)
        remember(settlement)
    }

    /// Closes new-operation admission before a session/app drain begins.
    public func quiesce() {
        accepting = false
    }

    public func outstandingOperationIDs() -> [MCPControlOperationID] {
        outstanding.keys.sorted { $0.rawValue < $1.rawValue }
    }

    @discardableResult
    public func shutdown(
        reason: String
    ) async -> MCPControlPlaneAdmissionShutdownReport {
        accepting = false
        let tickets = outstanding.values.sorted {
            $0.request.operationID.rawValue
                < $1.request.operationID.rawValue
        }
        var settledIDs: [MCPControlOperationID] = []
        var unresolvedIDs: [MCPControlOperationID] = []
        let diagnostic = MCPDiagnosticSummary(
            code: "control_plane_shutdown",
            summary: reason)

        for ticket in tickets {
            do {
                try await settle(
                    ticket,
                    status: .cancelled,
                    diagnostic: diagnostic)
                settledIDs.append(ticket.request.operationID)
            } catch {
                unresolvedIDs.append(ticket.request.operationID)
            }
        }
        return MCPControlPlaneAdmissionShutdownReport(
            settledOperationIDs: settledIDs,
            unresolvedOperationIDs: unresolvedIDs)
    }

    private func persistRejected(
        _ request: MCPControlPlaneAdmissionRequest,
        status: MCPDurableTerminalStatus,
        diagnostic: MCPDiagnosticSummary
    ) async throws {
        let settlement = MCPControlPlaneAdmissionSettlement(
            operationID: request.operationID,
            action: request.action,
            server: request.identity.server,
            attachmentID: request.identity.authority.attachmentID,
            status: status,
            diagnostic: diagnostic)
        do {
            try await auditSink.settle(settlement)
        } catch {
            throw MCPControlPlaneAdmissionError.auditFailure(
                Self.auditDiagnostic(error))
        }
        remember(settlement)
    }

    private func remember(
        _ settlement: MCPControlPlaneAdmissionSettlement
    ) {
        settled[settlement.operationID] = settlement
        settlementOrder.append(settlement.operationID)
        while settlementOrder.count > retainedSettlementLimit {
            let removed = settlementOrder.removeFirst()
            settled.removeValue(forKey: removed)
        }
    }

    private static func auditDiagnostic(_ error: Error)
        -> MCPDiagnosticSummary {
        MCPDiagnosticSummary(
            code: "control_plane_persistence_failed",
            summary: "MCP control-plane persistence failed: \(error.localizedDescription)")
    }
}
