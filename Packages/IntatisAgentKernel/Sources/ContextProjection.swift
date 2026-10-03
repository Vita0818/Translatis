import Foundation
import IntatisCore
import IntatisProtocol

public struct LineageItem: Codable, Sendable, Hashable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ContextEventSummary: Codable, Sendable, Hashable {
    public var seq: Int
    public var kind: String
    public var messageID: MessageID?
    public var sender: AgentID?
    public var recipient: AgentID?
    public var agent: AgentID?
    public var taskID: TaskID?
    public var content: String

    public init(seq: Int,
                kind: String,
                messageID: MessageID? = nil,
                sender: AgentID? = nil,
                recipient: AgentID? = nil,
                agent: AgentID? = nil,
                taskID: TaskID? = nil,
                content: String) {
        self.seq = seq
        self.kind = kind
        self.messageID = messageID
        self.sender = sender
        self.recipient = recipient
        self.agent = agent
        self.taskID = taskID
        self.content = content
    }
}

public struct ContextBundle: Codable, Sendable, Hashable {
    public var globalBrief: String
    public var safetyPolicy: String
    public var taskContract: TaskContract?
    public var lineage: [LineageItem]
    public var taskGroupEvents: [ContextEventSummary]
    public var directMessages: [ContextEventSummary]
    public var agentLocalEvents: [ContextEventSummary]
    public var explicitlySharedArtifacts: [ArtifactID]
    public var workspaceBrief: String?
    public var allowedToolNames: [String]

    public init(globalBrief: String,
                safetyPolicy: String,
                taskContract: TaskContract? = nil,
                lineage: [LineageItem] = [],
                taskGroupEvents: [ContextEventSummary] = [],
                directMessages: [ContextEventSummary] = [],
                agentLocalEvents: [ContextEventSummary] = [],
                explicitlySharedArtifacts: [ArtifactID] = [],
                workspaceBrief: String? = nil,
                allowedToolNames: [String] = []) {
        self.globalBrief = globalBrief
        self.safetyPolicy = safetyPolicy
        self.taskContract = taskContract
        self.lineage = lineage
        self.taskGroupEvents = taskGroupEvents
        self.directMessages = directMessages
        self.agentLocalEvents = agentLocalEvents
        self.explicitlySharedArtifacts = explicitlySharedArtifacts
        self.workspaceBrief = workspaceBrief
        self.allowedToolNames = allowedToolNames
    }
}

/// Hard limits for the event-derived context placed in one model request.
/// Counts and character budgets are enforced independently so a long-running
/// Cowork session cannot grow a prompt without bound.
public struct ContextProjectionBudget: Sendable, Hashable {
    public var maxGlobalBriefCharacters: Int
    public var maxLineageItems: Int
    public var maxLineageCharacters: Int
    public var maxTaskGroupEvents: Int
    public var maxTaskGroupCharacters: Int
    public var maxDirectMessages: Int
    public var maxDirectMessageCharacters: Int
    public var maxAgentLocalEvents: Int
    public var maxAgentLocalCharacters: Int
    public var maxArtifacts: Int
    public var maxArtifactIDCharacters: Int
    public var maxEventCharacters: Int

    public init(maxGlobalBriefCharacters: Int = 600,
                maxLineageItems: Int = 8,
                maxLineageCharacters: Int = 1_600,
                maxTaskGroupEvents: Int = 12,
                maxTaskGroupCharacters: Int = 2_400,
                maxDirectMessages: Int = 8,
                maxDirectMessageCharacters: Int = 3_200,
                maxAgentLocalEvents: Int = 12,
                maxAgentLocalCharacters: Int = 4_000,
                maxArtifacts: Int = 8,
                maxArtifactIDCharacters: Int = 800,
                maxEventCharacters: Int = 600) {
        self.maxGlobalBriefCharacters = max(0, maxGlobalBriefCharacters)
        self.maxLineageItems = max(0, maxLineageItems)
        self.maxLineageCharacters = max(0, maxLineageCharacters)
        self.maxTaskGroupEvents = max(0, maxTaskGroupEvents)
        self.maxTaskGroupCharacters = max(0, maxTaskGroupCharacters)
        self.maxDirectMessages = max(0, maxDirectMessages)
        self.maxDirectMessageCharacters = max(0, maxDirectMessageCharacters)
        self.maxAgentLocalEvents = max(0, maxAgentLocalEvents)
        self.maxAgentLocalCharacters = max(0, maxAgentLocalCharacters)
        self.maxArtifacts = max(0, maxArtifacts)
        self.maxArtifactIDCharacters = max(0, maxArtifactIDCharacters)
        self.maxEventCharacters = max(0, maxEventCharacters)
    }

    public static let `default` = ContextProjectionBudget()
}

public struct ContextProjector: Sendable {
    private let budget: ContextProjectionBudget

    public init(budget: ContextProjectionBudget = .default) {
        self.budget = budget
    }

    public func project(agentID: AgentID,
                        taskContract: TaskContract?,
                        events: [Envelope],
                        allowedToolNames: [String],
                        workspaceRoot: URL?,
                        projectsCompletedRootAnswersIntoConversation: Bool = false) -> ContextBundle {
        let submissionBoundary = taskContract.flatMap {
            Self.submissionContextBoundary(for: $0, events: events)
        }
        // Task-group state is metadata-only and may use the complete verified
        // event snapshot. Content-bearing history is stricter: once a task is
        // bound to a durable submission, only output proven to belong to an
        // earlier accepted submission may enter the model request.
        let scopedContentEvents = submissionBoundary.map {
            $0.scopedContentEvents(from: events)
        } ?? events
        let globalBrief = Self.globalBrief(
            for: agentID,
            taskContract: taskContract,
            events: events,
            maxCharacters: budget.maxGlobalBriefCharacters)
        let lineage = Self.boundedLineage(
            Self.lineage(for: agentID, taskContract: taskContract),
            budget: budget)
        let relevantTaskIDs = taskContract.map { Self.taskGroupTaskIDs(for: $0, events: events) } ?? []
        let taskAnchor = submissionBoundary == nil
            ? taskContract.flatMap { Self.firstTaskEventSequence(for: $0.id, events: events) }
            : nil
        let taskGroupEvents = Self.taskGroupEvents(
            taskContract: taskContract,
            events: events,
            budget: budget)
        let duplicateTexts = Self.duplicateContextTexts(taskContract: taskContract, globalBrief: globalBrief)
        let directMessages = Self.directMessages(
            for: agentID,
            taskContract: taskContract,
            relevantTaskIDs: relevantTaskIDs,
            taskAnchor: taskAnchor,
            events: scopedContentEvents,
            duplicateTexts: duplicateTexts,
            budget: budget)
        let toolTaskByCallID = submissionBoundary?.taskByToolCallID ?? [:]
        var agentLocalEvents = Self.agentLocalEvents(
            for: agentID,
            taskContract: taskContract,
            relevantTaskIDs: relevantTaskIDs,
            taskAnchor: taskAnchor,
            events: scopedContentEvents,
            toolAgentByCallID: Self.toolAgentByCallID(from: events),
            toolTaskByCallID: toolTaskByCallID,
            duplicateTexts: duplicateTexts,
            budget: budget)
        if projectsCompletedRootAnswersIntoConversation,
           let taskContract,
           taskContract.kind == .root,
           taskContract.issuer == nil,
           taskContract.submissionID != nil {
            // AgentLoop reconstructs completed root-turn answers as real
            // assistant-role thread history. Direct model-history tool pairs
            // likewise supersede their bounded audit previews. Keep legacy
            // tool facts until a direct model record exists; they cannot be
            // safely promoted into assistant/tool roles, but remain useful
            // as explicitly untrusted context data.
            let redundantToolAuditSequences =
                Self.modelHistoryBackedToolAuditSequences(
                    agentID: agentID,
                    events: events,
                    toolTaskByCallID: toolTaskByCallID)
            agentLocalEvents.removeAll {
                $0.kind == "agent_message_completed"
                    || redundantToolAuditSequences.contains($0.seq)
            }
        }
        return ContextBundle(
            globalBrief: globalBrief,
            safetyPolicy: "Follow workspace confinement, permission policy, and the current task constraints.",
            taskContract: taskContract,
            lineage: lineage,
            taskGroupEvents: taskGroupEvents,
            directMessages: directMessages,
            agentLocalEvents: agentLocalEvents,
            // `artifact_added` has no task, recipient, or visibility metadata.
            // Until the event schema can prove an explicit share, fail closed.
            explicitlySharedArtifacts: [],
            workspaceBrief: workspaceRoot.map { "Workspace root: \($0.path)" },
            allowedToolNames: allowedToolNames.sorted())
    }

    private static func globalBrief(for agentID: AgentID,
                                    taskContract: TaskContract?,
                                    events: [Envelope],
                                    maxCharacters: Int) -> String {
        guard let taskContract else {
            let latest = events.reversed().compactMap { envelope -> String? in
                guard case .userMessage(let payload) = envelope.event,
                      payload.to == nil || payload.to == agentID else {
                    return nil
                }
                return validUserObjective(payload)
            }.first
            return truncate(
                latest ?? "No global user objective was recorded before this turn.",
                maxCharacters: maxCharacters)
        }

        let contracts = taskContractsByID(from: events)
        let rootContract = rootContract(for: taskContract, contracts: contracts)
        if let submissionID = rootContract.submissionID {
            let exactPayload = events.compactMap { envelope -> UserMessagePayload? in
                guard case .userMessage(let payload) = envelope.event,
                      payload.submissionID == submissionID else { return nil }
                return payload
            }.first
            let fallback = rootContract.objective
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let selected: String
            if let exactPayload,
               let exactObjective = validUserObjective(exactPayload) {
                selected = exactObjective
            } else if let count = exactPayload?.attachments?.count, count > 0 {
                selected = "The user submitted \(count) attachment\(count == 1 ? "" : "s") for this task."
            } else {
                // A correlated submission must never fall back to a different
                // user turn merely because its text is empty or unavailable.
                selected = fallback.isEmpty
                    ? "The correlated user submission has no textual objective."
                    : fallback
            }
            return truncate(selected, maxCharacters: maxCharacters)
        }
        let anchorSequence = firstTaskEventSequence(for: rootContract.id, events: events)
            ?? firstTaskEventSequence(for: taskContract.id, events: events)
            ?? Int.max
        var intendedRecipients = Set([rootContract.assignee])
        if let issuer = rootContract.issuer { intendedRecipients.insert(issuer) }
        if let issuer = taskContract.issuer { intendedRecipients.insert(issuer) }

        // `/goal` is explicit structured user intent. Prefer the latest such goal
        // before the root task was created; never use a later unrelated turn.
        let explicitGoal = events.reversed().compactMap { envelope -> String? in
            guard envelope.seq <= anchorSequence,
                  case .userMessage(let payload) = envelope.event,
                  let goal = payload.goal?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !goal.isEmpty else {
                return nil
            }
            if let recipient = payload.to, !intendedRecipients.contains(recipient) { return nil }
            return goal
        }.first

        // An explicitly addressed non-/goal turn is also a reliable causal hint.
        let addressedObjective = events.reversed().compactMap { envelope -> String? in
            guard envelope.seq <= anchorSequence,
                  case .userMessage(let payload) = envelope.event,
                  let recipient = payload.to,
                  intendedRecipients.contains(recipient) else {
                return nil
            }
            return validUserObjective(payload)
        }.first

        let fallback = rootContract.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = explicitGoal ?? addressedObjective
            ?? (fallback.isEmpty ? taskContract.objective : fallback)
        return truncate(selected, maxCharacters: maxCharacters)
    }

    private static func lineage(for agentID: AgentID,
                                taskContract: TaskContract?) -> [LineageItem] {
        guard let contract = taskContract else {
            return [
                LineageItem(text: "@\(agentID.rawValue) is handling the current user-directed turn."),
            ]
        }

        var items: [LineageItem] = [
            LineageItem(text: "\(contract.issuer.map { "@\($0.rawValue)" } ?? "The user") assigned task \(contract.id.rawValue) to @\(contract.assignee.rawValue)."),
        ]

        if let parentTaskID = contract.parentTaskID {
            items.append(LineageItem(text: "Parent task: \(parentTaskID.rawValue)."))
        }
        if !contract.relatedAgents.isEmpty {
            let related = contract.relatedAgents.map { "@\($0.rawValue)" }.joined(separator: ", ")
            items.append(LineageItem(text: "Related agents in the task group: \(related)."))
        }
        return items
    }

    private static func boundedLineage(_ items: [LineageItem],
                                       budget: ContextProjectionBudget) -> [LineageItem] {
        var remainingCharacters = budget.maxLineageCharacters
        var selected: [LineageItem] = []
        for item in items.prefix(budget.maxLineageItems) where remainingCharacters > 0 {
            let text = truncate(
                item.text,
                maxCharacters: min(budget.maxEventCharacters, remainingCharacters))
            guard !text.isEmpty else { continue }
            selected.append(LineageItem(text: text))
            remainingCharacters -= text.count
        }
        return selected
    }

    private static func taskGroupEvents(taskContract: TaskContract?,
                                        events: [Envelope],
                                        budget: ContextProjectionBudget) -> [ContextEventSummary] {
        guard let contract = taskContract else { return [] }
        let relevantTaskIDs = taskGroupTaskIDs(for: contract, events: events)

        let candidates = events.compactMap { envelope in
            switch envelope.event {
            case .taskCreated(let payload) where relevantTaskIDs.contains(payload.contract.id):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_created",
                    status: .created,
                    taskID: payload.contract.id,
                    agent: payload.contract.assignee,
                    relation: taskRelation(taskID: payload.contract.id, agent: payload.contract.assignee, current: contract))
            case .taskAssigned(let payload) where relevantTaskIDs.contains(payload.contract.id):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_assigned",
                    status: .assigned,
                    taskID: payload.contract.id,
                    agent: payload.contract.assignee,
                    relation: taskRelation(taskID: payload.contract.id, agent: payload.contract.assignee, current: contract))
            case .taskQueued(let payload) where relevantTaskIDs.contains(payload.contract.id):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_queued",
                    status: .queued,
                    taskID: payload.contract.id,
                    agent: payload.contract.assignee,
                    relation: taskRelation(taskID: payload.contract.id, agent: payload.contract.assignee, current: contract))
            case .taskStarted(let payload) where relevantTaskIDs.contains(payload.taskID):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_started",
                    status: .running,
                    taskID: payload.taskID,
                    agent: payload.agent,
                    relation: taskRelation(taskID: payload.taskID, agent: payload.agent, current: contract))
            case .taskCompleted(let payload) where relevantTaskIDs.contains(payload.taskID):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_completed",
                    status: .completed,
                    taskID: payload.taskID,
                    agent: payload.agent,
                    relation: taskRelation(taskID: payload.taskID, agent: payload.agent, current: contract))
            case .taskFailed(let payload) where relevantTaskIDs.contains(payload.taskID):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_failed",
                    status: .failed,
                    taskID: payload.taskID,
                    agent: payload.agent,
                    relation: taskRelation(taskID: payload.taskID, agent: payload.agent, current: contract))
            case .taskCancelled(let payload) where relevantTaskIDs.contains(payload.taskID):
                return taskGroupSummary(
                    envelope: envelope,
                    kind: "task_cancelled",
                    status: .cancelled,
                    taskID: payload.taskID,
                    agent: payload.agent,
                    relation: taskRelation(taskID: payload.taskID, agent: payload.agent, current: contract))
            case .taskRejected(let payload):
                guard let rejectedContract = payload.contract,
                      relevantTaskIDs.contains(rejectedContract.id) else {
                    return nil
                }
                let relation = taskRelation(
                    taskID: rejectedContract.id,
                    agent: rejectedContract.assignee,
                    current: contract)
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_rejected",
                    agent: rejectedContract.assignee,
                    taskID: rejectedContract.id,
                    content: "\(relation) task \(rejectedContract.id.rawValue) rejected for @\(rejectedContract.assignee.rawValue)\(payload.violationKind.map { " (\($0))" } ?? "").")
            default:
                return nil
            }
        }
        var latestByTask: [TaskID: ContextEventSummary] = [:]
        for candidate in candidates {
            guard let taskID = candidate.taskID else { continue }
            if latestByTask[taskID].map({ $0.seq < candidate.seq }) ?? true {
                latestByTask[taskID] = candidate
            }
        }
        let ranked = latestByTask.values.sorted { lhs, rhs in
            let lhsPriority = taskGroupPriority(lhs.taskID, current: contract)
            let rhsPriority = taskGroupPriority(rhs.taskID, current: contract)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.seq > rhs.seq
        }
        return boundedSummaries(
            ranked,
            maxCount: budget.maxTaskGroupEvents,
            maxCharacters: budget.maxTaskGroupCharacters,
            maxEventCharacters: budget.maxEventCharacters)
            .sorted { $0.seq < $1.seq }
    }

    private static func taskGroupPriority(_ taskID: TaskID?, current: TaskContract) -> Int {
        guard let taskID else { return 4 }
        if taskID == current.id { return 0 }
        if taskID == current.parentTaskID { return 1 }
        if current.relatedTasks.contains(taskID) { return 2 }
        return 3
    }

    private static func taskGroupTaskIDs(for current: TaskContract, events: [Envelope]) -> Set<TaskID> {
        var result = Set([current.id])
        if let parentTaskID = current.parentTaskID {
            result.insert(parentTaskID)
        }
        result.formUnion(current.relatedTasks)

        for envelope in events {
            guard let contract = taskContract(from: envelope.event),
                  belongsToTaskGroup(contract, current: current) else {
                continue
            }
            result.insert(contract.id)
        }
        return result
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

    private static func belongsToTaskGroup(_ contract: TaskContract, current: TaskContract) -> Bool {
        if contract.id == current.id { return true }
        if contract.id == current.parentTaskID { return true }
        if current.relatedTasks.contains(contract.id) { return true }
        if current.kind == .root, contract.parentTaskID == current.id { return true }
        if let parentTaskID = current.parentTaskID {
            return contract.parentTaskID == parentTaskID
        }
        return false
    }

    private static func taskGroupSummary(envelope: Envelope,
                                         kind: String,
                                         status: TaskStatus,
                                         taskID: TaskID,
                                         agent: AgentID,
                                         relation: String) -> ContextEventSummary {
        ContextEventSummary(
            seq: envelope.seq,
            kind: kind,
            agent: agent,
            taskID: taskID,
            content: "\(relation) task \(taskID.rawValue) is \(status.rawValue) for @\(agent.rawValue).")
    }

    private static func taskRelation(taskID: TaskID, agent: AgentID, current: TaskContract) -> String {
        if taskID == current.id { return "current" }
        if taskID == current.parentTaskID { return "parent" }
        if current.relatedTasks.contains(taskID) { return "related" }
        if let parentTaskID = current.parentTaskID, taskID != parentTaskID { return "sibling" }
        if current.kind == .root { return "child" }
        if current.relatedAgents.contains(agent) { return "related" }
        return "task-group"
    }

    private static func directMessages(for agentID: AgentID,
                                       taskContract: TaskContract?,
                                       relevantTaskIDs: Set<TaskID>,
                                       taskAnchor: Int?,
                                       events: [Envelope],
                                       duplicateTexts: Set<String>,
                                       budget: ContextProjectionBudget) -> [ContextEventSummary] {
        let frozenMailboxMessageIDs: Set<MessageID>? = {
            guard taskContract?.kind == .mailboxDelivery,
                  let ids = taskContract?.mailboxMessageIDs else {
                return nil
            }
            return Set(ids.prefix(budget.maxDirectMessages))
        }()
        let settledAt = events.reduce(into: [MessageID: Int]()) { result, envelope in
            let settlement: (MessageID, AgentID)?
            switch envelope.event {
            case .agentMessageConsumed(let payload):
                settlement = (payload.messageID, payload.agent)
            case .agentMessageDiscarded(let payload):
                settlement = (payload.messageID, payload.agent)
            default:
                settlement = nil
            }
            guard let settlement, settlement.1 == agentID else { return }
            result[settlement.0] = max(result[settlement.0] ?? Int.min, envelope.seq)
        }
        let candidates = events.compactMap { envelope -> ContextEventSummary? in
            switch envelope.event {
            case .agentToAgentMessage(let payload) where payload.to == agentID:
                // This legacy event shape has no stable MessageID. A new
                // mailbox contract with an exact frozen set must not absorb it
                // merely because it happens to be in the same task window.
                guard frozenMailboxMessageIDs == nil else { return nil }
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: nil,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "agent_to_agent_message",
                    sender: payload.from,
                    recipient: payload.to,
                    content: payload.content)
            case .agentMessage(let payload) where payload.to == agentID:
                guard frozenMailboxMessageIDs.map({
                    $0.contains(payload.messageId)
                }) ?? true else { return nil }
                guard settledAt[payload.messageId].map({ $0 > envelope.seq }) != true else { return nil }
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: payload.kind?.rawValue ?? "agent_message",
                    messageID: payload.messageId,
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: payload.content)
            case .informationRequested(let payload) where payload.to == agentID:
                guard frozenMailboxMessageIDs.map({
                    $0.contains(payload.requestID)
                }) ?? true else { return nil }
                guard settledAt[payload.requestID].map({ $0 > envelope.seq }) != true else { return nil }
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_requested",
                    messageID: payload.requestID,
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: payload.question)
            case .informationReplied(let payload) where payload.to == agentID:
                guard frozenMailboxMessageIDs.map({
                    $0.contains(payload.replyID)
                }) ?? true else { return nil }
                guard settledAt[payload.replyID].map({ $0 > envelope.seq }) != true else { return nil }
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_replied",
                    messageID: payload.replyID,
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: payload.content)
            default:
                return nil
            }
        }
        return boundedNewestUniqueSummaries(
            candidates,
            excludingNormalizedTexts: duplicateTexts,
            maxCount: budget.maxDirectMessages,
            maxCharacters: budget.maxDirectMessageCharacters,
            maxEventCharacters: budget.maxEventCharacters)
    }

    private static func agentLocalEvents(for agentID: AgentID,
                                         taskContract: TaskContract?,
                                         relevantTaskIDs: Set<TaskID>,
                                         taskAnchor: Int?,
                                         events: [Envelope],
                                         toolAgentByCallID: [String: AgentID],
                                         toolTaskByCallID: [String: TaskID],
                                         duplicateTexts: Set<String>,
                                         budget: ContextProjectionBudget) -> [ContextEventSummary] {
        let candidates = events.compactMap { envelope -> ContextEventSummary? in
            switch envelope.event {
            case .agentToAgentMessage(let payload) where payload.from == agentID:
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: nil,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "agent_to_agent_message_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    content: payload.content)
            case .agentMessage(let payload) where payload.from == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: payload.taskID,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: payload.kind?.rawValue ?? "agent_message_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: payload.content)
            case .informationRequested(let payload) where payload.from == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: payload.taskID,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_requested_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: payload.question)
            case .informationReplied(let payload) where payload.from == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: payload.taskID,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "information_replied_sent",
                    sender: payload.from,
                    recipient: payload.to,
                    taskID: payload.taskID,
                    content: payload.content)
            case .messageCompleted(let payload) where payload.agent == agentID:
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: nil,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "agent_message_completed",
                    agent: payload.agent,
                    content: payload.text)
            case .toolCall(let payload) where payload.agent == agentID:
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: nil,
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "tool_call",
                    agent: payload.agent,
                    taskID: toolTaskByCallID[payload.toolCallId],
                    content: "\(payload.name): \(payload.args)")
            case .toolResult(let payload) where toolAgentByCallID[payload.toolCallId] == agentID:
                guard isWithinTaskWindow(
                    sequence: envelope.seq,
                    taskID: toolTaskByCallID[payload.toolCallId],
                    taskContract: taskContract,
                    taskAnchor: taskAnchor) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "tool_result",
                    agent: agentID,
                    taskID: toolTaskByCallID[payload.toolCallId],
                    content: payload.observation)
            case .taskAssigned(let payload) where payload.contract.assignee == agentID:
                guard isRelevant(payload.contract.id, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_assigned",
                    agent: agentID,
                    taskID: payload.contract.id,
                    content: payload.contract.objective)
            case .taskStarted(let payload) where payload.agent == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_started",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: "Task started.")
            case .taskCompleted(let payload) where payload.agent == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_completed",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: payload.report?.summary ?? payload.result)
            case .taskFailed(let payload) where payload.agent == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_failed",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: payload.report?.summary ?? payload.error)
            case .taskCancelled(let payload) where payload.agent == agentID:
                guard isRelevant(payload.taskID, taskContract: taskContract, relevantTaskIDs: relevantTaskIDs) else {
                    return nil
                }
                return ContextEventSummary(
                    seq: envelope.seq,
                    kind: "task_cancelled",
                    agent: agentID,
                    taskID: payload.taskID,
                    content: payload.report?.summary ?? payload.reason)
            default:
                return nil
            }
        }
        return boundedNewestUniqueSummaries(
            candidates,
            excludingNormalizedTexts: duplicateTexts,
            maxCount: budget.maxAgentLocalEvents,
            maxCharacters: budget.maxAgentLocalCharacters,
            maxEventCharacters: budget.maxEventCharacters)
    }

    /// Submission-aware content boundary for Cowork prompts. Event append
    /// order is not conversation order: submission B may be accepted while A
    /// is still running, and an older submission may finish after both. The
    /// accepted user-message sequence is therefore the only ordering key.
    private struct SubmissionContextBoundary {
        let currentSubmissionID: SubmissionID
        let currentAcceptedSequence: Int?
        let acceptedSequenceBySubmission: [SubmissionID: Int]
        let submissionByTaskID: [TaskID: SubmissionID]
        let submissionByToolCallID: [String: SubmissionID]
        let taskByToolCallID: [String: TaskID]

        func scopedContentEvents(from events: [Envelope]) -> [Envelope] {
            events.filter(allowsContentEvent)
        }

        private func allowsContentEvent(_ envelope: Envelope) -> Bool {
            switch envelope.event {
            case .userMessage(let payload):
                return allows(submissionID: payload.submissionID)
            case .messageDelta(let payload):
                return allows(submissionID: payload.submissionID)
            case .messageCompleted(let payload):
                return allows(submissionID: payload.submissionID)
            case .error(let payload):
                return allows(submissionID: payload.submissionID)
            case .toolCall(let payload):
                return allows(toolCallID: payload.toolCallId)
            case .toolResult(let payload):
                return allows(toolCallID: payload.toolCallId)
            case .agentToAgentMessage:
                // This legacy payload has no task/submission identity. Once a
                // durable submission boundary exists, guessing by raw seq can
                // replay a current attempt or a logically later queued turn.
                return false
            case .agentMessage(let payload):
                return allows(taskID: payload.taskID)
            case .informationRequested(let payload):
                return allows(taskID: payload.taskID)
            case .informationReplied(let payload):
                return allows(taskID: payload.taskID)
            case .taskCreated(let payload):
                return allows(taskID: payload.contract.id)
            case .taskAssigned(let payload):
                return allows(taskID: payload.contract.id)
            case .taskQueued(let payload):
                return allows(taskID: payload.contract.id)
            case .taskDelegated(let payload):
                return allows(taskID: payload.contract.id)
            case .delegationApproved(let payload):
                return allows(taskID: payload.contract.id)
            case .taskStarted(let payload):
                return allows(taskID: payload.taskID)
            case .taskCompleted(let payload):
                return allows(taskID: payload.taskID)
            case .taskFailed(let payload):
                return allows(taskID: payload.taskID)
            case .taskCancelled(let payload):
                return allows(taskID: payload.taskID)
            case .taskRejected(let payload):
                return allows(taskID: payload.contract?.id)
            default:
                // Settlement and authorization records are not projected as
                // model-visible content. Keep them so pending-message state
                // remains correct while their content records are filtered.
                return true
            }
        }

        private func allows(submissionID: SubmissionID?) -> Bool {
            guard let submissionID,
                  let currentAcceptedSequence,
                  let acceptedSequence = acceptedSequenceBySubmission[submissionID] else {
                return false
            }
            return acceptedSequence < currentAcceptedSequence
        }

        private func allows(taskID: TaskID?) -> Bool {
            guard let taskID else { return false }
            return allows(submissionID: submissionByTaskID[taskID])
        }

        private func allows(toolCallID: String) -> Bool {
            allows(submissionID: submissionByToolCallID[toolCallID])
        }
    }

    private static func submissionContextBoundary(
        for current: TaskContract,
        events: [Envelope]
    ) -> SubmissionContextBoundary? {
        var acceptedSequenceBySubmission: [SubmissionID: Int] = [:]
        var submissionCandidatesByTaskID: [TaskID: Set<SubmissionID>] = [:]
        var parentCandidatesByTaskID: [TaskID: Set<TaskID>] = [:]
        var taskCandidatesByToolCallID: [String: Set<TaskID>] = [:]

        func record(contract: TaskContract) {
            if let submissionID = contract.submissionID {
                submissionCandidatesByTaskID[contract.id, default: []].insert(submissionID)
            }
            if let parentTaskID = contract.parentTaskID {
                parentCandidatesByTaskID[contract.id, default: []].insert(parentTaskID)
            }
        }

        func recordLineage(taskID: TaskID?, parentTaskID: TaskID?, rootTaskID: TaskID?) {
            guard let taskID else { return }
            if let parentTaskID, parentTaskID != taskID {
                parentCandidatesByTaskID[taskID, default: []].insert(parentTaskID)
            } else if let rootTaskID, rootTaskID != taskID {
                parentCandidatesByTaskID[taskID, default: []].insert(rootTaskID)
            }
        }

        func recordTool(taskID: TaskID?, toolCallID: String?) {
            guard let taskID, let toolCallID, !toolCallID.isEmpty else { return }
            taskCandidatesByToolCallID[toolCallID, default: []].insert(taskID)
        }

        func record(authorization: ResolvedToolAuthorization?) {
            guard let authorization else { return }
            recordTool(taskID: authorization.taskID, toolCallID: authorization.toolCallID)
            recordLineage(
                taskID: authorization.taskID,
                parentTaskID: authorization.parentTaskID,
                rootTaskID: authorization.rootTaskID)
        }

        record(contract: current)
        for envelope in events {
            if case .userMessage(let payload) = envelope.event,
               let submissionID = payload.submissionID {
                acceptedSequenceBySubmission[submissionID] = min(
                    acceptedSequenceBySubmission[submissionID] ?? Int.max,
                    envelope.seq)
            }
            if let contract = taskContract(from: envelope.event) {
                record(contract: contract)
            }

            switch envelope.event {
            case .toolExecutionPrepared(let payload):
                recordTool(taskID: payload.taskID, toolCallID: payload.toolCallID)
                recordTool(taskID: payload.authorization?.taskID, toolCallID: payload.toolCallID)
                record(authorization: payload.authorization)
                recordLineage(
                    taskID: payload.taskID,
                    parentTaskID: payload.authorization?.parentTaskID,
                    rootTaskID: payload.authorization?.rootTaskID)
            case .toolExecutionSettled(let payload):
                recordTool(taskID: payload.taskID, toolCallID: payload.toolCallID)
                recordTool(taskID: payload.authorization?.taskID, toolCallID: payload.toolCallID)
                record(authorization: payload.authorization)
                recordLineage(
                    taskID: payload.taskID,
                    parentTaskID: payload.authorization?.parentTaskID,
                    rootTaskID: payload.authorization?.rootTaskID)
            case .permissionRequest(let payload):
                if let context = payload.context {
                    if let contract = context.taskContract { record(contract: contract) }
                    recordTool(taskID: context.taskID, toolCallID: context.toolCallID)
                    recordTool(taskID: context.taskContract?.id, toolCallID: context.toolCallID)
                    recordTool(taskID: context.authorization?.taskID, toolCallID: context.toolCallID)
                    record(authorization: context.authorization)
                    recordLineage(
                        taskID: context.taskID,
                        parentTaskID: context.parentTaskID,
                        rootTaskID: context.rootTaskID)
                }
            case .permissionResolved(let payload):
                record(authorization: payload.authorization)
            default:
                break
            }
        }

        // Propagate submission identity through task parentage. Multiple
        // conflicting candidates deliberately produce no mapping.
        var changed = true
        while changed {
            changed = false
            for (taskID, parentIDs) in parentCandidatesByTaskID {
                var candidates = submissionCandidatesByTaskID[taskID] ?? []
                for parentID in parentIDs {
                    candidates.formUnion(submissionCandidatesByTaskID[parentID] ?? [])
                }
                if candidates != submissionCandidatesByTaskID[taskID] ?? [] {
                    submissionCandidatesByTaskID[taskID] = candidates
                    changed = true
                }
            }
        }

        let submissionByTaskID = submissionCandidatesByTaskID.compactMapValues { candidates in
            candidates.count == 1 ? candidates.first : nil
        }
        guard let currentSubmissionID = current.submissionID ?? submissionByTaskID[current.id] else {
            return nil
        }

        var submissionByToolCallID: [String: SubmissionID] = [:]
        var taskByToolCallID: [String: TaskID] = [:]
        for (toolCallID, taskIDs) in taskCandidatesByToolCallID {
            let submissions = taskIDs.compactMap { submissionByTaskID[$0] }
            guard submissions.count == taskIDs.count,
                  Set(submissions).count == 1,
                  let submissionID = submissions.first else {
                continue
            }
            submissionByToolCallID[toolCallID] = submissionID
            if taskIDs.count == 1 {
                taskByToolCallID[toolCallID] = taskIDs.first
            }
        }

        return SubmissionContextBoundary(
            currentSubmissionID: currentSubmissionID,
            currentAcceptedSequence: acceptedSequenceBySubmission[currentSubmissionID],
            acceptedSequenceBySubmission: acceptedSequenceBySubmission,
            submissionByTaskID: submissionByTaskID,
            submissionByToolCallID: submissionByToolCallID,
            taskByToolCallID: taskByToolCallID)
    }

    private static func toolAgentByCallID(from events: [Envelope]) -> [String: AgentID] {
        var candidatesByCallID: [String: Set<AgentID>] = [:]
        func record(_ toolCallID: String?, _ agent: AgentID?) {
            guard let toolCallID, !toolCallID.isEmpty, let agent else { return }
            candidatesByCallID[toolCallID, default: []].insert(agent)
        }
        func record(_ authorization: ResolvedToolAuthorization?) {
            guard let authorization else { return }
            record(authorization.toolCallID, authorization.agent)
        }

        for envelope in events {
            switch envelope.event {
            case .toolCall(let payload):
                record(payload.toolCallId, payload.agent)
            case .toolExecutionPrepared(let payload):
                record(payload.toolCallID, payload.agent)
                record(payload.toolCallID, payload.authorization?.agent)
                record(payload.authorization)
            case .toolExecutionSettled(let payload):
                record(payload.toolCallID, payload.agent)
                record(payload.toolCallID, payload.authorization?.agent)
                record(payload.authorization)
            case .permissionRequest(let payload):
                record(payload.context?.toolCallID, payload.agent)
                record(payload.context?.toolCallID, payload.context?.authorization?.agent)
                record(payload.context?.authorization)
            case .permissionResolved(let payload):
                record(payload.authorization)
            default:
                break
            }
        }
        return candidatesByCallID.compactMapValues { candidates in
            candidates.count == 1 ? candidates.first : nil
        }
    }

    private struct ModelHistoryToolKey: Hashable {
        var taskID: TaskID
        var callID: String
    }

    private static func modelHistoryBackedToolAuditSequences(
        agentID: AgentID,
        events: [Envelope],
        toolTaskByCallID: [String: TaskID]
    ) -> Set<Int> {
        var directCallKeys = Set<ModelHistoryToolKey>()
        var directOutputKeys = Set<ModelHistoryToolKey>()
        for envelope in events {
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.schemaVersion
                    == ModelHistoryItemPayload.currentSchemaVersion
                    || payload.schemaVersion
                        == ModelHistoryItemPayload.mediaSchemaVersion,
                  (try? payload.validate()) != nil,
                  payload.agent == agentID,
                  let taskID = payload.taskID else {
                continue
            }
            switch payload.kind {
            case .functionCallBatch:
                for call in payload.functionCalls ?? [] {
                    directCallKeys.insert(ModelHistoryToolKey(
                        taskID: taskID,
                        callID: call.callID))
                }
            case .functionCallOutput, .toolSearchOutput:
                if let callID = payload.callID {
                    directOutputKeys.insert(ModelHistoryToolKey(
                        taskID: taskID,
                        callID: callID))
                }
            case .message, .reasoning:
                break
            }
        }

        var result = Set<Int>()
        for envelope in events {
            let callID: String
            let matchingKeys: Set<ModelHistoryToolKey>
            switch envelope.event {
            case .toolCall(let payload) where payload.agent == agentID:
                callID = payload.toolCallId
                matchingKeys = directCallKeys
            case .toolResult(let payload):
                callID = payload.toolCallId
                matchingKeys = directOutputKeys
            default:
                continue
            }
            guard let taskID = toolTaskByCallID[callID],
                  matchingKeys.contains(ModelHistoryToolKey(
                      taskID: taskID,
                      callID: callID)) else {
                continue
            }
            result.insert(envelope.seq)
        }
        return result
    }

    private static func validUserObjective(_ payload: UserMessagePayload) -> String? {
        let goal = payload.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let goal, !goal.isEmpty { return goal }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func taskContractsByID(from events: [Envelope]) -> [TaskID: TaskContract] {
        var result: [TaskID: TaskContract] = [:]
        for envelope in events {
            if let contract = taskContract(from: envelope.event) {
                result[contract.id] = contract
            }
        }
        return result
    }

    private static func rootContract(for current: TaskContract,
                                     contracts: [TaskID: TaskContract]) -> TaskContract {
        var root = current
        var visited = Set([current.id])
        while let parentID = root.parentTaskID,
              !visited.contains(parentID),
              let parent = contracts[parentID] {
            visited.insert(parentID)
            root = parent
        }
        return root
    }

    private static func firstTaskEventSequence(for taskID: TaskID,
                                               events: [Envelope]) -> Int? {
        events.first { envelope in
            switch envelope.event {
            case .taskCreated(let payload): return payload.contract.id == taskID
            case .taskAssigned(let payload): return payload.contract.id == taskID
            case .taskQueued(let payload): return payload.contract.id == taskID
            case .taskDelegated(let payload): return payload.contract.id == taskID
            case .delegationApproved(let payload): return payload.contract.id == taskID
            case .taskStarted(let payload): return payload.taskID == taskID
            case .taskCompleted(let payload): return payload.taskID == taskID
            case .taskFailed(let payload): return payload.taskID == taskID
            case .taskCancelled(let payload): return payload.taskID == taskID
            case .taskRejected(let payload): return payload.contract?.id == taskID
            default: return false
            }
        }?.seq
    }

    private static func duplicateContextTexts(taskContract: TaskContract?,
                                              globalBrief: String) -> Set<String> {
        var values = Set([normalizedText(globalBrief)])
        if let taskContract {
            values.insert(normalizedText(taskContract.objective))
            values.insert(normalizedText(taskContract.expectedDeliverable))
        }
        values.remove("")
        return values
    }

    private static func isRelevant(_ taskID: TaskID?,
                                   taskContract: TaskContract?,
                                   relevantTaskIDs: Set<TaskID>) -> Bool {
        guard taskContract != nil else { return true }
        guard let taskID else { return true } // legacy message without task metadata
        return relevantTaskIDs.contains(taskID)
    }

    /// Events written before task metadata existed have no task ID. Preserve
    /// those events for compatibility, but only inside the current task's time
    /// window so a later task assigned to the same agent does not inherit stale
    /// private messages or local execution history.
    private static func isWithinTaskWindow(sequence: Int,
                                           taskID: TaskID?,
                                           taskContract: TaskContract?,
                                           taskAnchor: Int?) -> Bool {
        guard taskContract != nil, taskID == nil, let taskAnchor else { return true }
        return sequence >= taskAnchor
    }

    private static func boundedNewestUniqueSummaries(_ summaries: [ContextEventSummary],
                                                     excludingNormalizedTexts excluded: Set<String>,
                                                     maxCount: Int,
                                                     maxCharacters: Int,
                                                     maxEventCharacters: Int) -> [ContextEventSummary] {
        var seenTexts = Set<String>()
        var seenMessageIDs = Set<MessageID>()
        let newestUnique = summaries.sorted { $0.seq > $1.seq }.filter { summary in
            let normalized = normalizedText(summary.content)
            guard !normalized.isEmpty else {
                return false
            }

            // A typed mailbox item remains actionable until its message ID is
            // consumed. Its text may intentionally repeat the task contract,
            // global brief, or another pending message, so content-based
            // deduplication must never make that ID disappear permanently.
            if let messageID = summary.messageID {
                return seenMessageIDs.insert(messageID).inserted
            }

            guard !excluded.contains(normalized),
                  !seenTexts.contains(normalized) else {
                return false
            }
            seenTexts.insert(normalized)
            return true
        }
        return boundedSummaries(
            newestUnique,
            maxCount: maxCount,
            maxCharacters: maxCharacters,
            maxEventCharacters: maxEventCharacters)
            .sorted { $0.seq < $1.seq }
    }

    private static func boundedSummaries(_ summaries: [ContextEventSummary],
                                         maxCount: Int,
                                         maxCharacters: Int,
                                         maxEventCharacters: Int) -> [ContextEventSummary] {
        var remainingCharacters = maxCharacters
        var selected: [ContextEventSummary] = []
        for var summary in summaries where selected.count < maxCount && remainingCharacters > 0 {
            summary.content = truncate(
                summary.content,
                maxCharacters: min(maxEventCharacters, remainingCharacters))
            guard !summary.content.isEmpty else { continue }
            remainingCharacters -= summary.content.count
            selected.append(summary)
        }
        return selected
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        guard maxCharacters > 3 else { return String(text.prefix(maxCharacters)) }
        return String(text.prefix(maxCharacters - 3)) + "..."
    }
}
