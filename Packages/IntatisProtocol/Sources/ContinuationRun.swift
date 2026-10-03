import Foundation
import IntatisCore

public enum ContinuationRunStatus: String, Codable, Sendable, Hashable {
    case created
    case running
    case checkpointed
    case completed
    case interrupted
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .interrupted || self == .cancelled
    }

    public func canTransition(to next: ContinuationRunStatus) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.created, .running),
             (.created, .checkpointed),
             (.created, .interrupted),
             (.created, .cancelled),
             (.running, .checkpointed),
             (.running, .completed),
             (.running, .interrupted),
             (.running, .cancelled),
             (.checkpointed, .completed),
             (.checkpointed, .interrupted),
             (.checkpointed, .cancelled):
            return true
        default:
            return false
        }
    }
}

/// Short compatibility spelling for code that models the report's `RunStatus`.
public typealias RunStatus = ContinuationRunStatus

public struct ContinuationRunViolation: Error, Codable, Sendable, Hashable,
    CustomStringConvertible {
    public enum Kind: String, Codable, Sendable, Hashable {
        case invalidStatusTransition = "invalid_status_transition"
        case invalidOrdinal = "invalid_ordinal"
    }

    public var kind: Kind
    public var message: String
    public var runID: ContinuationRunID

    public init(kind: Kind, message: String, runID: ContinuationRunID) {
        self.kind = kind
        self.message = message
        self.runID = runID
    }

    public var description: String { message }
}

/// One ordinary Cowork turn or one continuation cycle of a durable Goal.
public struct ContinuationRun: Codable, Sendable, Hashable, Identifiable {
    public var id: ContinuationRunID
    public var sessionID: SessionID
    public var goalID: GoalID?
    public var ordinal: Int
    public var status: ContinuationRunStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var progressSummary: String?

    public init(id: ContinuationRunID = ContinuationRunID.new(),
                sessionID: SessionID,
                goalID: GoalID? = nil,
                ordinal: Int = 0,
                status: ContinuationRunStatus = .created,
                startedAt: Date = Date(),
                endedAt: Date? = nil,
                progressSummary: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.goalID = goalID
        self.ordinal = ordinal
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.progressSummary = progressSummary
    }

    public func transitioning(to status: ContinuationRunStatus,
                              progressSummary: String? = nil,
                              at date: Date = Date()) -> Result<ContinuationRun, ContinuationRunViolation> {
        guard ordinal >= 0 else {
            return .failure(ContinuationRunViolation(
                kind: .invalidOrdinal,
                message: "continuation run ordinal cannot be negative",
                runID: id))
        }
        guard self.status.canTransition(to: status) else {
            return .failure(ContinuationRunViolation(
                kind: .invalidStatusTransition,
                message: "invalid continuation run status transition \(self.status.rawValue) -> \(status.rawValue)",
                runID: id))
        }
        var next = self
        next.status = status
        if let progressSummary { next.progressSummary = progressSummary }
        next.endedAt = status.isTerminal ? date : nil
        return .success(next)
    }
}
