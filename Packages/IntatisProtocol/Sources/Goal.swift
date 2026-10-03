import Foundation
import IntatisCore

public enum GoalStatus: String, Codable, Sendable, Hashable {
    case active
    case paused
    case blocked
    case budgetLimited = "budget_limited"
    case usageLimited = "usage_limited"
    case completed

    public var isTerminal: Bool { self == .completed }

    /// Goal state authority is enforced by the caller: pause/resume and limit
    /// recovery are user/host actions, while completion requires an audit.
    public func canTransition(to next: GoalStatus) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.active, .paused),
             (.active, .blocked),
             (.active, .budgetLimited),
             (.active, .usageLimited),
             (.active, .completed),
             (.paused, .active),
             (.blocked, .active),
             (.budgetLimited, .active),
             (.usageLimited, .active):
            return true
        default:
            return false
        }
    }
}

public enum GoalAuditVerdict: String, Codable, Sendable, Hashable {
    case complete
    case `continue`
    case blockedCandidate = "blocked_candidate"
}

public enum GoalRequirementStatus: String, Codable, Sendable, Hashable {
    case proven
    case unproven
    case contradicted
}

public struct GoalRequirementAudit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var status: GoalRequirementStatus
    public var evidence: [TaskEvidence]
    public var gap: String?

    public init(id: String,
                text: String,
                status: GoalRequirementStatus,
                evidence: [TaskEvidence] = [],
                gap: String? = nil) {
        self.id = id
        self.text = text
        self.status = status
        self.evidence = evidence
        self.gap = gap
    }
}

/// Structured verifier output. A `complete` verdict is only internally
/// consistent when every requirement is proven with evidence and no work or
/// blocker remains. Goal-specific completion must additionally use
/// ``isCompletionProof(for:)`` so the audit covers the user's entire Goal.
public struct GoalAuditSummary: Codable, Sendable, Hashable {
    public var verdict: GoalAuditVerdict
    public var requirements: [GoalRequirementAudit]
    public var progressMade: Bool
    public var remainingWork: [String]
    public var blocker: String?
    public var auditedAt: Date

    public init(verdict: GoalAuditVerdict,
                requirements: [GoalRequirementAudit] = [],
                progressMade: Bool,
                remainingWork: [String] = [],
                blocker: String? = nil,
                auditedAt: Date = Date()) {
        self.verdict = verdict
        self.requirements = requirements
        self.progressMade = progressMade
        self.remainingWork = remainingWork
        self.blocker = blocker
        self.auditedAt = auditedAt
    }

    public var isCompletionProof: Bool {
        guard verdict == .complete,
              !requirements.isEmpty,
              remainingWork.isEmpty,
              Self.normalizedRequirementText(blocker ?? "").isEmpty else {
            return false
        }
        return requirements.allSatisfy {
            $0.status == .proven &&
                !Self.normalizedRequirementText($0.text).isEmpty &&
                !$0.evidence.isEmpty
        }
    }

    /// Validates the self-contained audit proof and verifies that distinct
    /// normalized requirement entries cover the Goal objective, every success
    /// criterion, and every constraint. Comparing normalized text rather than
    /// verifier-provided IDs keeps completion authority tied to user content.
    public func isCompletionProof(for goal: Goal) -> Bool {
        guard isCompletionProof else { return false }

        let required = goal.completionRequirementTexts.map(Self.normalizedRequirementText)
        guard !required.isEmpty, required.allSatisfy({ !$0.isEmpty }) else { return false }

        var available = requirements.reduce(into: [String: Int]()) { counts, requirement in
            counts[Self.normalizedRequirementText(requirement.text), default: 0] += 1
        }
        for requirement in required {
            guard let count = available[requirement], count > 0 else { return false }
            available[requirement] = count - 1
        }
        return true
    }

    /// Stable comparison form for requirement coverage. This preserves the
    /// semantic text while ignoring Unicode composition, case, and whitespace
    /// layout differences introduced by provider output.
    public static func normalizedRequirementText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}

public struct GoalMutationViolation: Error, Codable, Sendable, Hashable,
    CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, Hashable {
        case staleRevision = "stale_revision"
        case invalidStatusTransition = "invalid_status_transition"
        case invalidCompletionAudit = "invalid_completion_audit"
        case invalidBudget = "invalid_budget"
    }

    public var kind: Kind
    public var message: String
    public var goalID: GoalID
    public var expectedRevision: Int?
    public var actualRevision: Int?

    public init(kind: Kind,
                message: String,
                goalID: GoalID,
                expectedRevision: Int? = nil,
                actualRevision: Int? = nil) {
        self.kind = kind
        self.message = message
        self.goalID = goalID
        self.expectedRevision = expectedRevision
        self.actualRevision = actualRevision
    }

    public var description: String { message }
}

/// A durable objective that may span multiple ``ContinuationRun`` values.
public struct Goal: Codable, Sendable, Hashable, Identifiable {
    public var id: GoalID
    public var sessionID: SessionID
    public var objective: String
    public var successCriteria: [String]
    public var constraints: [String]
    public var status: GoalStatus
    public var revision: Int

    /// Optional by design: a budget exists only when the user explicitly set it.
    public var tokenBudget: Int?
    public var tokensUsed: Int
    public var activeElapsedSeconds: Double

    public var latestAudit: GoalAuditSummary?
    public var blockerFingerprint: String?
    public var consecutiveBlockedRuns: Int
    public var noProgressRuns: Int

    /// Exact, secret-free `@main` binding selected when this durable Goal was
    /// submitted. New Goal continuations keep this route across retries and
    /// restart; legacy/model-created Goals decode it as `nil`.
    public var mainAgentInferenceBinding: AgentInferenceBinding?

    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    /// The complete set of user-owned statements that a completion audit must
    /// cover. Order is stable and duplicates are intentional: each Goal item
    /// requires a distinct audit requirement.
    public var completionRequirementTexts: [String] {
        [objective] + successCriteria + constraints
    }

    public var hasValidCompletionProof: Bool {
        status == .completed &&
            (latestAudit?.isCompletionProof(for: self) ?? false)
    }

    public init(id: GoalID = GoalID.new(),
                sessionID: SessionID,
                objective: String,
                successCriteria: [String] = [],
                constraints: [String] = [],
                status: GoalStatus = .active,
                revision: Int = 0,
                tokenBudget: Int? = nil,
                tokensUsed: Int = 0,
                activeElapsedSeconds: Double = 0,
                latestAudit: GoalAuditSummary? = nil,
                blockerFingerprint: String? = nil,
                consecutiveBlockedRuns: Int = 0,
                noProgressRuns: Int = 0,
                mainAgentInferenceBinding: AgentInferenceBinding? = nil,
                createdAt: Date = Date(),
                updatedAt: Date? = nil,
                completedAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.objective = objective
        self.successCriteria = successCriteria
        self.constraints = constraints
        self.status = status
        self.revision = revision
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.activeElapsedSeconds = activeElapsedSeconds
        self.latestAudit = latestAudit
        self.blockerFingerprint = blockerFingerprint
        self.consecutiveBlockedRuns = consecutiveBlockedRuns
        self.noProgressRuns = noProgressRuns
        self.mainAgentInferenceBinding = mainAgentInferenceBinding
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
    }

    public func edited(objective: String,
                       successCriteria: [String],
                       constraints: [String],
                       tokenBudget: Int?,
                       expectedRevision: Int,
                       at date: Date = Date()) -> Result<Goal, GoalMutationViolation> {
        guard revision == expectedRevision else {
            return .failure(staleRevision(expectedRevision))
        }
        guard !status.isTerminal else {
            return .failure(GoalMutationViolation(
                kind: .invalidStatusTransition,
                message: "completed goal cannot be edited",
                goalID: id))
        }
        if let tokenBudget, tokenBudget < 0 {
            return .failure(GoalMutationViolation(
                kind: .invalidBudget,
                message: "goal token budget cannot be negative",
                goalID: id))
        }
        var next = self
        next.objective = objective
        next.successCriteria = successCriteria
        next.constraints = constraints
        next.tokenBudget = tokenBudget
        // An audit and blocker streak are evidence about one exact user-owned
        // Goal revision. Reusing them after any edit could complete or block a
        // materially different objective with stale proof.
        next.latestAudit = nil
        next.blockerFingerprint = nil
        next.consecutiveBlockedRuns = 0
        next.noProgressRuns = 0
        next.revision += 1
        next.updatedAt = date
        return .success(next)
    }

    public func transitioning(to status: GoalStatus,
                              expectedRevision: Int,
                              audit: GoalAuditSummary? = nil,
                              at date: Date = Date()) -> Result<Goal, GoalMutationViolation> {
        guard revision == expectedRevision else {
            return .failure(staleRevision(expectedRevision))
        }
        guard self.status.canTransition(to: status) else {
            return .failure(GoalMutationViolation(
                kind: .invalidStatusTransition,
                message: "invalid goal status transition \(self.status.rawValue) -> \(status.rawValue)",
                goalID: id))
        }
        if status == .completed {
            guard let audit = audit ?? latestAudit,
                  audit.isCompletionProof(for: self) else {
                return .failure(GoalMutationViolation(
                    kind: .invalidCompletionAudit,
                    message: "completed goal requires evidence-backed proof of its objective, success criteria, and constraints with no remaining work or blocker",
                    goalID: id))
            }
        }
        var next = self
        next.status = status
        if let audit { next.latestAudit = audit }
        next.revision += 1
        next.updatedAt = date
        next.completedAt = status == .completed ? date : nil
        if status == .active && self.status == .blocked {
            next.blockerFingerprint = nil
            next.consecutiveBlockedRuns = 0
        }
        return .success(next)
    }

    public func applyingAudit(_ audit: GoalAuditSummary,
                              expectedRevision: Int,
                              at date: Date = Date()) -> Result<Goal, GoalMutationViolation> {
        guard revision == expectedRevision else {
            return .failure(staleRevision(expectedRevision))
        }
        var next = self
        next.latestAudit = audit
        next.noProgressRuns = audit.progressMade ? 0 : noProgressRuns + 1
        next.revision += 1
        next.updatedAt = date
        return .success(next)
    }

    private func staleRevision(_ expectedRevision: Int) -> GoalMutationViolation {
        GoalMutationViolation(
            kind: .staleRevision,
            message: "expected revision \(expectedRevision), actual \(revision)",
            goalID: id,
            expectedRevision: expectedRevision,
            actualRevision: revision)
    }
}
