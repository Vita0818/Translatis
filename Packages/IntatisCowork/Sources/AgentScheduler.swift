import Foundation
import IntatisCore
import IntatisProtocol

public struct ScheduledTask: Codable, Sendable, Hashable {
    public var contract: TaskContract
    public var input: String
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var issuer: AgentID?
    public var assignee: AgentID
    public var causalParentID: TaskID?
    public var hopCount: Int
    public var visitedAgents: [AgentID]
    public var attempt: Int?

    public init(contract: TaskContract,
                input: String,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID,
                causalParentID: TaskID? = nil,
                hopCount: Int,
                visitedAgents: [AgentID],
                attempt: Int? = nil) {
        self.contract = contract
        self.input = input
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.causalParentID = causalParentID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
        self.attempt = attempt
    }
}

public struct ExecutionRecord: Codable, Sendable, Hashable {
    public var taskID: TaskID
    public var assignee: AgentID
    public var status: TaskStatus
    public var result: String?
    public var error: String?
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var hopCount: Int
    public var visitedAgents: [AgentID]
    public var attempt: Int?

    public init(taskID: TaskID,
                assignee: AgentID,
                status: TaskStatus,
                result: String? = nil,
                error: String? = nil,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                hopCount: Int,
                visitedAgents: [AgentID],
                attempt: Int? = nil) {
        self.taskID = taskID
        self.assignee = assignee
        self.status = status
        self.result = result
        self.error = error
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
        self.attempt = attempt
    }
}

/// The runtime payload held in an agent mailbox. It deliberately stays in the
/// Cowork module so the scheduler can evolve independently from the persisted
/// wire event schema.
public struct PendingAgentMessage: Codable, Sendable, Hashable {
    public var id: MessageID
    public var sender: AgentID?
    public var recipient: AgentID
    public var content: String
    public var kind: String
    public var taskID: TaskID?
    public var causalParentID: TaskID?
    public var inReplyTo: MessageID?
    public var conversationID: MessageID?
    public var basedOn: MessageID?
    public var createdAt: Date

    public init(id: MessageID = MessageID.new(),
                sender: AgentID? = nil,
                recipient: AgentID,
                content: String,
                kind: String = "message",
                taskID: TaskID? = nil,
                causalParentID: TaskID? = nil,
                inReplyTo: MessageID? = nil,
                conversationID: MessageID? = nil,
                basedOn: MessageID? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.sender = sender
        self.recipient = recipient
        self.content = content
        self.kind = kind
        self.taskID = taskID
        self.causalParentID = causalParentID
        self.inReplyTo = inReplyTo
        self.conversationID = conversationID
        self.basedOn = basedOn
        self.createdAt = createdAt
    }
}

public struct AgentMailbox: Codable, Sendable, Hashable {
    /// Kept as an ID list for source compatibility with existing projections and
    /// callers. `pendingMessageDetails` carries the runtime delivery payload.
    public var pendingMessages: [MessageID]
    public var pendingMessageDetails: [PendingAgentMessage]
    public var pendingTasks: [TaskID]
    public var completedResults: [ExecutionRecord]

    public init(pendingMessages: [MessageID] = [],
                pendingTasks: [TaskID] = [],
                completedResults: [ExecutionRecord] = [],
                pendingMessageDetails: [PendingAgentMessage] = []) {
        var messageIDs = pendingMessages
        for message in pendingMessageDetails where !messageIDs.contains(message.id) {
            messageIDs.append(message.id)
        }
        self.pendingMessages = messageIDs
        self.pendingMessageDetails = pendingMessageDetails
        self.pendingTasks = pendingTasks
        self.completedResults = completedResults
    }
}

public enum ScheduledTaskEnqueueMode: String, Codable, Sendable, Hashable {
    /// New tasks are accepted; an exact failed/cancelled task is treated as a retry.
    case automatic
    case newTask = "new"
    case retry
}

public enum ScheduledTaskEnqueueRejection: String, Codable, Sendable, Hashable {
    case duplicateQueued = "duplicate_queued"
    case duplicateClaimed = "duplicate_claimed"
    case existingTask = "existing_task"
    case retryMissingOriginal = "retry_missing_original"
    case retryNotTerminal = "retry_not_terminal"
    case retryTaskMismatch = "retry_task_mismatch"
    case retryAttemptMismatch = "retry_attempt_mismatch"
    case retryAttemptLimitExceeded = "retry_attempt_limit_exceeded"
}

public enum ScheduledTaskEnqueueResult: Sendable, Hashable {
    case enqueued(TaskID)
    case retryReplaced(TaskID)
    case rejected(TaskID, ScheduledTaskEnqueueRejection)

    public var accepted: Bool {
        switch self {
        case .enqueued, .retryReplaced:
            return true
        case .rejected:
            return false
        }
    }
}

public enum ClaimedTaskRestorePolicy: String, Codable, Sendable, Hashable {
    /// A process restart has no live executor, so claimed/running work becomes
    /// queued work that the new scheduler instance may claim again.
    case requeue
    /// Useful for an in-process handoff where the owner of each claim survives.
    case preserve
}

public struct AgentSchedulerSnapshot: Codable, Sendable, Equatable {
    public var version: Int
    public var queuedTasks: [ScheduledTask]
    public var claimedTasks: [ScheduledTask]
    public var knownTasks: [TaskID: ScheduledTask]
    public var records: [TaskID: ExecutionRecord]
    public var mailboxes: [AgentID: AgentMailbox]

    public init(version: Int = 1,
                queuedTasks: [ScheduledTask],
                claimedTasks: [ScheduledTask],
                knownTasks: [TaskID: ScheduledTask],
                records: [TaskID: ExecutionRecord],
                mailboxes: [AgentID: AgentMailbox]) {
        self.version = version
        self.queuedTasks = queuedTasks
        self.claimedTasks = claimedTasks
        self.knownTasks = knownTasks
        self.records = records
        self.mailboxes = mailboxes
    }
}

/// Value-type scheduler state owned by `Orchestrator`. Claiming is synchronous:
/// callers never hold an actor method across a long-running AgentLoop. A claimed
/// assignee stays busy until the claim is completed, failed, cancelled, released,
/// or explicitly requeued.
public struct AgentScheduler: Sendable {
    private var queue: [ScheduledTask] = []
    private var records: [TaskID: ExecutionRecord] = [:]
    private var mailboxes: [AgentID: AgentMailbox] = [:]
    private var knownTasks: [TaskID: ScheduledTask] = [:]
    private var claimedTasks: [TaskID: ScheduledTask] = [:]
    private var claimedTaskOrder: [TaskID] = []
    private var claimedTaskByAgent: [AgentID: TaskID] = [:]

    public init() {}

    public init(snapshot: AgentSchedulerSnapshot,
                claimedTaskPolicy: ClaimedTaskRestorePolicy = .requeue) {
        self.init()
        restore(from: snapshot, claimedTaskPolicy: claimedTaskPolicy)
    }

    /// Compatibility entrypoint used by the current Orchestrator. New integration
    /// code should inspect the richer result from `enqueue(_:mode:)`.
    @discardableResult
    public mutating func enqueue(_ task: ScheduledTask) -> TaskID {
        _ = enqueue(task, mode: .automatic)
        return task.contract.id
    }

    @discardableResult
    public mutating func enqueue(_ task: ScheduledTask,
                                 mode: ScheduledTaskEnqueueMode) -> ScheduledTaskEnqueueResult {
        let taskID = task.contract.id
        if queue.contains(where: { $0.contract.id == taskID }) {
            return .rejected(taskID, .duplicateQueued)
        }
        if claimedTasks[taskID] != nil {
            return .rejected(taskID, .duplicateClaimed)
        }

        switch mode {
        case .newTask:
            guard knownTasks[taskID] == nil, records[taskID] == nil else {
                return .rejected(taskID, .existingTask)
            }
            acceptQueuedTask(task)
            return .enqueued(taskID)

        case .retry:
            return acceptRetry(task)

        case .automatic:
            if knownTasks[taskID] == nil, records[taskID] == nil {
                acceptQueuedTask(task)
                return .enqueued(taskID)
            }
            return acceptRetry(task)
        }
    }

    /// Claims the first eligible queued task. Tasks for a busy assignee remain in
    /// FIFO order while a later task for another assignee may be claimed.
    public mutating func claimNext(excluding excludedTaskIDs: Set<TaskID> = []) -> ScheduledTask? {
        guard let index = queue.firstIndex(where: {
            !excludedTaskIDs.contains($0.contract.id) && claimedTaskByAgent[$0.assignee] == nil
        }) else {
            return nil
        }
        let task = queue.remove(at: index)
        claim(task)
        mailboxes[task.assignee, default: AgentMailbox()].pendingTasks.removeAll {
            $0 == task.contract.id
        }
        return task
    }

    /// Backward-compatible name. `runNext` now performs only a short synchronous
    /// claim; execution remains the Orchestrator's responsibility.
    public mutating func runNext() -> ScheduledTask? {
        claimNext()
    }

    /// Claims one eligible task per currently idle agent.
    public mutating func runUntilIdle() -> [ScheduledTask] {
        var claimed: [ScheduledTask] = []
        while let task = claimNext() {
            claimed.append(task)
        }
        return claimed
    }

    public func awaitResult(taskID: TaskID) -> ExecutionRecord? {
        records[taskID]
    }

    @discardableResult
    public mutating func recordStarted(task: ScheduledTask) -> Bool {
        guard records[task.contract.id]?.status == .queued else { return false }
        guard ensureClaim(for: task) else { return false }
        var record = records[task.contract.id] ?? makeRecord(task: task, status: .queued)
        record.status = .running
        record.result = nil
        record.error = nil
        records[task.contract.id] = record
        mailboxes[task.assignee, default: AgentMailbox()].pendingTasks.removeAll {
            $0 == task.contract.id
        }
        return true
    }

    public mutating func recordCompleted(task: ScheduledTask, result: String) {
        let record = makeRecord(task: task, status: .completed, result: result)
        records[task.contract.id] = record
        appendTerminalRecord(record, for: task.assignee)
        releaseClaim(taskID: task.contract.id)
    }

    public mutating func recordFailed(task: ScheduledTask, error: String) {
        let record = makeRecord(task: task, status: .failed, error: error)
        records[task.contract.id] = record
        appendTerminalRecord(record, for: task.assignee)
        releaseClaim(taskID: task.contract.id)
    }

    public mutating func recordCancelled(task: ScheduledTask, reason: String? = nil) {
        let record = makeRecord(task: task, status: .cancelled, error: reason)
        records[task.contract.id] = record
        appendTerminalRecord(record, for: task.assignee)
        releaseClaim(taskID: task.contract.id)
    }

    /// Frees a claim without changing its execution record. Terminal record APIs
    /// call this automatically; it is public for an executor that persists its own
    /// terminal state before releasing the assignee.
    @discardableResult
    public mutating func releaseClaim(taskID: TaskID) -> ScheduledTask? {
        guard let task = claimedTasks.removeValue(forKey: taskID) else { return nil }
        claimedTaskOrder.removeAll { $0 == taskID }
        if claimedTaskByAgent[task.assignee] == taskID {
            claimedTaskByAgent.removeValue(forKey: task.assignee)
        }
        return task
    }

    @discardableResult
    public mutating func requeueClaimedTask(taskID: TaskID, atFront: Bool = true) -> ScheduledTask? {
        guard let task = releaseClaim(taskID: taskID) else { return nil }
        if atFront {
            queue.insert(task, at: 0)
        } else {
            queue.append(task)
        }
        records[taskID] = makeRecord(task: task, status: .queued)
        appendPendingTask(taskID, for: task.assignee)
        return task
    }

    /// Requeues an invocation whose terminal event could not be persisted. The
    /// preceding taskQueued event must already be durable before this is called.
    @discardableResult
    public mutating func requeueAfterTerminalPersistenceFailure(_ task: ScheduledTask) -> Bool {
        let taskID = task.contract.id
        guard !queue.contains(where: { $0.contract.id == taskID }),
              claimedTasks[taskID] == nil,
              let original = knownTasks[taskID],
              let record = records[taskID],
              record.status == .running,
              sameTaskIdentity(original, task),
              let currentAttempt = record.attempt,
              let retryAttempt = task.attempt,
              retryAttempt == currentAttempt + 1 else {
            return false
        }
        if let maxAttempts = original.contract.maxAttempts,
           retryAttempt > maxAttempts {
            return false
        }
        acceptQueuedTask(task)
        return true
    }

    /// Cancels only queued (unclaimed) work. Claimed work must be cooperatively
    /// cancelled by its executor and finalized with `recordCancelled(task:)`.
    @discardableResult
    public mutating func cancelQueuedTask(taskID: TaskID, reason: String? = nil) -> ScheduledTask? {
        guard let index = queue.firstIndex(where: { $0.contract.id == taskID }) else { return nil }
        let task = queue.remove(at: index)
        let record = makeRecord(task: task, status: .cancelled, error: reason)
        records[taskID] = record
        appendTerminalRecord(record, for: task.assignee)
        mailboxes[task.assignee, default: AgentMailbox()].pendingTasks.removeAll { $0 == taskID }
        return task
    }

    /// Removes queued work and its scheduler history entirely. Prefer cancellation
    /// when auditability or retry is required.
    @discardableResult
    public mutating func removeQueuedTask(taskID: TaskID) -> ScheduledTask? {
        guard let index = queue.firstIndex(where: { $0.contract.id == taskID }) else { return nil }
        let task = queue.remove(at: index)
        records.removeValue(forKey: taskID)
        knownTasks.removeValue(forKey: taskID)
        mailboxes[task.assignee, default: AgentMailbox()].pendingTasks.removeAll { $0 == taskID }
        mailboxes[task.assignee, default: AgentMailbox()].completedResults.removeAll { $0.taskID == taskID }
        return task
    }

    // MARK: - Runtime message mailbox

    @discardableResult
    public mutating func enqueueMessage(_ message: PendingAgentMessage) -> Bool {
        guard !mailboxes.values.contains(where: { $0.pendingMessages.contains(message.id) }) else {
            return false
        }
        var mailbox = mailboxes[message.recipient, default: AgentMailbox()]
        mailbox.pendingMessages.append(message.id)
        mailbox.pendingMessageDetails.append(message)
        mailboxes[message.recipient] = mailbox
        return true
    }

    public func peekMessage(for recipient: AgentID) -> PendingAgentMessage? {
        peekMessages(for: recipient).first
    }

    public func peekMessages(for recipient: AgentID) -> [PendingAgentMessage] {
        guard let mailbox = mailboxes[recipient] else { return [] }
        var details: [MessageID: PendingAgentMessage] = [:]
        for message in mailbox.pendingMessageDetails where details[message.id] == nil {
            details[message.id] = message
        }
        return mailbox.pendingMessages.compactMap { details[$0] }
    }

    @discardableResult
    public mutating func acknowledgeMessage(_ messageID: MessageID, recipient: AgentID) -> Bool {
        guard var mailbox = mailboxes[recipient], mailbox.pendingMessages.contains(messageID) else {
            return false
        }
        mailbox.pendingMessages.removeAll { $0 == messageID }
        mailbox.pendingMessageDetails.removeAll { $0.id == messageID }
        mailboxes[recipient] = mailbox
        return true
    }

    public mutating func consumeNextMessage(for recipient: AgentID) -> PendingAgentMessage? {
        guard let message = peekMessage(for: recipient) else { return nil }
        _ = acknowledgeMessage(message.id, recipient: recipient)
        return message
    }

    public mutating func drainMessages(for recipient: AgentID) -> [PendingAgentMessage] {
        let messages = peekMessages(for: recipient)
        guard var mailbox = mailboxes[recipient] else { return messages }
        mailbox.pendingMessages.removeAll()
        mailbox.pendingMessageDetails.removeAll()
        mailboxes[recipient] = mailbox
        return messages
    }

    // MARK: - Snapshot / restore

    public func snapshot() -> AgentSchedulerSnapshot {
        AgentSchedulerSnapshot(
            queuedTasks: queue,
            claimedTasks: claimedTaskOrder.compactMap { claimedTasks[$0] },
            knownTasks: knownTasks,
            records: records,
            mailboxes: mailboxes)
    }

    public mutating func restore(from snapshot: AgentSchedulerSnapshot,
                                 claimedTaskPolicy: ClaimedTaskRestorePolicy = .requeue) {
        queue = []
        records = snapshot.records
        mailboxes = snapshot.mailboxes
        knownTasks = snapshot.knownTasks
        claimedTasks = [:]
        claimedTaskOrder = []
        claimedTaskByAgent = [:]

        var seen = Set<TaskID>()
        let restoredQueue = claimedTaskPolicy == .requeue
            ? snapshot.claimedTasks + snapshot.queuedTasks
            : snapshot.queuedTasks
        for task in restoredQueue where seen.insert(task.contract.id).inserted {
            queue.append(task)
            knownTasks[task.contract.id] = task
            records[task.contract.id] = makeRecord(task: task, status: .queued)
        }

        if claimedTaskPolicy == .preserve {
            for task in snapshot.claimedTasks {
                let taskID = task.contract.id
                guard seen.insert(taskID).inserted,
                      claimedTaskByAgent[task.assignee] == nil else {
                    if !queue.contains(where: { $0.contract.id == taskID }) {
                        queue.append(task)
                        records[taskID] = makeRecord(task: task, status: .queued)
                    }
                    continue
                }
                knownTasks[taskID] = task
                claim(task)
                if records[taskID] == nil {
                    records[taskID] = makeRecord(task: task, status: .running)
                }
            }
        }

        rebuildPendingTaskIndexes()
    }

    public func queuedTasks() -> [ScheduledTask] {
        queue
    }

    public func queuedTask(taskID: TaskID) -> ScheduledTask? {
        queue.first { $0.contract.id == taskID }
    }

    public func currentlyClaimedTasks() -> [ScheduledTask] {
        claimedTaskOrder.compactMap { claimedTasks[$0] }
    }

    public func claimedTask(taskID: TaskID) -> ScheduledTask? {
        claimedTasks[taskID]
    }

    public func knownTask(taskID: TaskID) -> ScheduledTask? {
        knownTasks[taskID]
    }

    public func isAgentBusy(_ agent: AgentID) -> Bool {
        claimedTaskByAgent[agent] != nil
    }

    public func mailbox(for agent: AgentID) -> AgentMailbox {
        mailboxes[agent] ?? AgentMailbox()
    }

    public func record(for taskID: TaskID) -> ExecutionRecord? {
        records[taskID]
    }

    // MARK: - Internal consistency helpers

    private mutating func acceptQueuedTask(_ task: ScheduledTask) {
        let taskID = task.contract.id
        queue.append(task)
        knownTasks[taskID] = task
        records[taskID] = makeRecord(task: task, status: .queued)
        appendPendingTask(taskID, for: task.assignee)
    }

    private mutating func acceptRetry(_ task: ScheduledTask) -> ScheduledTaskEnqueueResult {
        let taskID = task.contract.id
        guard let original = knownTasks[taskID], let record = records[taskID] else {
            return .rejected(taskID, .retryMissingOriginal)
        }
        guard record.status == .failed || record.status == .cancelled else {
            return .rejected(taskID, .retryNotTerminal)
        }
        guard sameTaskIdentity(original, task) else {
            return .rejected(taskID, .retryTaskMismatch)
        }
        guard let currentAttempt = record.attempt,
              let retryAttempt = task.attempt,
              retryAttempt == currentAttempt + 1 else {
            return .rejected(taskID, .retryAttemptMismatch)
        }
        if let maxAttempts = original.contract.maxAttempts,
           retryAttempt > maxAttempts {
            return .rejected(taskID, .retryAttemptLimitExceeded)
        }
        acceptQueuedTask(task)
        return .retryReplaced(taskID)
    }

    private mutating func claim(_ task: ScheduledTask) {
        let taskID = task.contract.id
        claimedTasks[taskID] = task
        claimedTaskOrder.append(taskID)
        claimedTaskByAgent[task.assignee] = taskID
    }

    private mutating func ensureClaim(for task: ScheduledTask) -> Bool {
        let taskID = task.contract.id
        if let claimed = claimedTasks[taskID] {
            return claimed == task && claimedTaskByAgent[task.assignee] == taskID
        }
        guard claimedTaskByAgent[task.assignee] == nil else { return false }
        if let index = queue.firstIndex(where: { $0.contract.id == taskID }) {
            let queued = queue.remove(at: index)
            guard queued == task else {
                queue.insert(queued, at: index)
                return false
            }
        } else if knownTasks[taskID] != task {
            return false
        }
        claim(task)
        return true
    }

    private func makeRecord(task: ScheduledTask,
                            status: TaskStatus,
                            result: String? = nil,
                            error: String? = nil) -> ExecutionRecord {
        ExecutionRecord(
            taskID: task.contract.id,
            assignee: task.assignee,
            status: status,
            result: result,
            error: error,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            hopCount: task.hopCount,
            visitedAgents: task.visitedAgents,
            attempt: task.attempt)
    }

    private func sameTaskIdentity(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        lhs.contract.id == rhs.contract.id
            && lhs.contract.kind == rhs.contract.kind
            && lhs.contract.issuer == rhs.contract.issuer
            && lhs.contract.assignee == rhs.contract.assignee
            && lhs.contract.parentTaskID == rhs.contract.parentTaskID
            && lhs.contract.objective == rhs.contract.objective
            && lhs.contract.agentInferenceBinding == rhs.contract.agentInferenceBinding
            && lhs.input == rhs.input
            && lhs.rootTaskID == rhs.rootTaskID
            && lhs.parentTaskID == rhs.parentTaskID
            && lhs.issuer == rhs.issuer
            && lhs.assignee == rhs.assignee
            && lhs.causalParentID == rhs.causalParentID
            && lhs.hopCount == rhs.hopCount
            && lhs.visitedAgents == rhs.visitedAgents
    }

    private mutating func appendPendingTask(_ taskID: TaskID, for agent: AgentID) {
        if !mailboxes[agent, default: AgentMailbox()].pendingTasks.contains(taskID) {
            mailboxes[agent, default: AgentMailbox()].pendingTasks.append(taskID)
        }
    }

    private mutating func appendTerminalRecord(_ record: ExecutionRecord, for agent: AgentID) {
        mailboxes[agent, default: AgentMailbox()].pendingTasks.removeAll { $0 == record.taskID }
        mailboxes[agent, default: AgentMailbox()].completedResults.append(record)
    }

    private mutating func rebuildPendingTaskIndexes() {
        let agents = Set(mailboxes.keys).union(queue.map(\.assignee)).union(claimedTasks.values.map(\.assignee))
        for agent in agents {
            mailboxes[agent, default: AgentMailbox()].pendingTasks = queue
                .filter { $0.assignee == agent }
                .map { $0.contract.id }
        }
    }
}
