import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

/// Legacy bridge for Cowork sessions created before durable model-history
/// items existed. It can recover only completed user/final-assistant text.
///
/// New turns are projected from `model_history_item` records instead; this
/// bridge must never infer tool calls from UI/audit events.
public struct AgentThreadHistoryProjector: Sendable {
    public init() {}

    public func project(
        agentID: AgentID,
        currentTask: TaskContract,
        events: [Envelope]
    ) -> [AgentMessage] {
        turns(
            agentID: agentID,
            currentTask: currentTask,
            events: events)
            .flatMap { [.user($0.userText), .assistant($0.assistantText)] }
    }

    func turns(
        agentID: AgentID,
        currentTask: TaskContract,
        events: [Envelope]
    ) -> [AgentLegacyThreadTurn] {
        guard currentTask.kind == .root,
              currentTask.issuer == nil,
              currentTask.assignee == agentID,
              let currentSubmissionID = currentTask.submissionID else {
            return []
        }

        let acceptedTurns = Self.acceptedTurns(from: events)
        guard let currentTurn = acceptedTurns[currentSubmissionID],
              !currentTurn.conflicted else {
            return []
        }

        let rootBindings = Self.rootBindings(
            currentTask: currentTask,
            events: events)
        guard Self.target(
            for: currentTurn.payload,
            submissionID: currentSubmissionID,
            rootTargets: rootBindings.targetsBySubmission) == agentID else {
            return []
        }
        let priorTurns = acceptedTurns.compactMap { submissionID, accepted -> AcceptedTurn? in
            guard submissionID != currentSubmissionID,
                  !accepted.conflicted,
                  accepted.sequence < currentTurn.sequence,
                  Self.target(
                      for: accepted.payload,
                      submissionID: submissionID,
                      rootTargets: rootBindings.targetsBySubmission) == agentID,
                  !accepted.payload.text.trimmingCharacters(
                      in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AcceptedTurn(
                submissionID: submissionID,
                sequence: accepted.sequence,
                payload: accepted.payload)
        }
        .sorted {
            if $0.sequence == $1.sequence {
                return $0.submissionID.rawValue < $1.submissionID.rawValue
            }
            return $0.sequence < $1.sequence
        }

        let priorSubmissionIDs = Set(priorTurns.map(\.submissionID))
        var completedBySubmission: [SubmissionID: [CompletedAssistantMessage]] = [:]
        let uniqueSubmissionByRootTaskID = rootBindings.submissionsByTaskID.compactMapValues {
            $0.count == 1 ? $0.first : nil
        }
        for envelope in events {
            guard case .taskCompleted(let payload) = envelope.event,
                  let submissionID = uniqueSubmissionByRootTaskID[payload.taskID],
                  priorSubmissionIDs.contains(submissionID),
                  payload.agent == agentID,
                  let accepted = acceptedTurns[submissionID],
                  envelope.seq > accepted.sequence,
                  !payload.result.isEmpty else {
                continue
            }
            completedBySubmission[submissionID, default: []].append(
                CompletedAssistantMessage(
                    sequence: envelope.seq,
                    stableID: "task:\(payload.taskID.rawValue)",
                    text: payload.result))
        }

        var projectedTurns: [AgentLegacyThreadTurn] = []
        for turn in priorTurns {
            let candidates = completedBySubmission[turn.submissionID] ?? []
            guard let assistant = candidates.max(by: {
                if $0.sequence == $1.sequence {
                    return $0.stableID < $1.stableID
                }
                return $0.sequence < $1.sequence
            }) else {
                continue
            }
            projectedTurns.append(AgentLegacyThreadTurn(
                submissionID: turn.submissionID,
                acceptedSequence: turn.sequence,
                completedSequence: assistant.sequence,
                userText: turn.payload.text,
                assistantText: assistant.text))
        }
        return projectedTurns
    }

    private struct AcceptedSubmission {
        var sequence: Int
        var payload: UserMessagePayload
        var conflicted: Bool
    }

    private struct AcceptedTurn {
        var submissionID: SubmissionID
        var sequence: Int
        var payload: UserMessagePayload
    }

    private struct CompletedAssistantMessage {
        var sequence: Int
        var stableID: String
        var text: String
    }

    private struct RootBindings {
        var targetsBySubmission: [SubmissionID: Set<AgentID>]
        var submissionsByTaskID: [TaskID: Set<SubmissionID>]
    }

    private static func acceptedTurns(
        from events: [Envelope]
    ) -> [SubmissionID: AcceptedSubmission] {
        var result: [SubmissionID: AcceptedSubmission] = [:]
        for envelope in events {
            guard case .userMessage(let payload) = envelope.event,
                  let submissionID = payload.submissionID else {
                continue
            }
            if var existing = result[submissionID] {
                if existing.payload != payload {
                    existing.conflicted = true
                    result[submissionID] = existing
                }
            } else {
                result[submissionID] = AcceptedSubmission(
                    sequence: envelope.seq,
                    payload: payload,
                    conflicted: false)
            }
        }
        return result
    }

    private static func rootBindings(
        currentTask: TaskContract,
        events: [Envelope]
    ) -> RootBindings {
        var targetsBySubmission: [SubmissionID: Set<AgentID>] = [:]
        var submissionsByTaskID: [TaskID: Set<SubmissionID>] = [:]

        func record(_ contract: TaskContract) {
            guard contract.kind == .root,
                  contract.issuer == nil,
                  let submissionID = contract.submissionID else {
                return
            }
            targetsBySubmission[submissionID, default: []].insert(contract.assignee)
            submissionsByTaskID[contract.id, default: []].insert(submissionID)
        }

        record(currentTask)
        for envelope in events {
            guard let contract = taskContract(from: envelope.event) else {
                continue
            }
            record(contract)
        }
        return RootBindings(
            targetsBySubmission: targetsBySubmission,
            submissionsByTaskID: submissionsByTaskID)
    }

    private static func target(
        for payload: UserMessagePayload,
        submissionID: SubmissionID,
        rootTargets: [SubmissionID: Set<AgentID>]
    ) -> AgentID? {
        let durableTargets = rootTargets[submissionID] ?? []
        guard durableTargets.count == 1,
              let durableTarget = durableTargets.first else {
            return nil
        }
        if let explicitTarget = payload.to {
            guard durableTarget == explicitTarget else {
                return nil
            }
        }
        return durableTarget
    }

    private static func taskContract(from event: Event) -> TaskContract? {
        switch event {
        case .taskCreated(let payload):
            return payload.contract
        case .taskAssigned(let payload):
            return payload.contract
        case .taskQueued(let payload):
            return payload.contract
        case .taskDelegated(let payload):
            return payload.contract
        case .delegationApproved(let payload):
            return payload.contract
        case .taskRejected(let payload):
            return payload.contract
        default:
            return nil
        }
    }
}

struct AgentLegacyThreadTurn: Equatable, Sendable {
    var submissionID: SubmissionID
    var acceptedSequence: Int
    var completedSequence: Int
    var userText: String
    var assistantText: String
}
