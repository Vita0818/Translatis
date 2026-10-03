import Foundation
import IntatisCore
import IntatisProtocol

/// A renderable item in a Code/Cowork thread — the fold of tool, permission, and
/// patch events (v0.2) plus messages. Pure and testable; SharedUI renders it.
public struct CodeItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user, agent, runtimeEvent, toolCall, toolResult, patch, note, error, agentToAgent
    }

    /// Presentation-only provenance. This is not part of the EventLog wire
    /// schema; it lets SharedUI distinguish a real model message from a
    /// scheduler lifecycle row that mirrors the same completed invocation.
    public enum PresentationSource: String, Sendable {
        case conversation
        case executionTrace
    }

    public let id: String
    public var kind: Kind
    public var presentationSource: PresentationSource
    public var title: String
    public var body: String
    public var complete: Bool
    public var files: [String]
    public var tags: [String]
    public var goal: String?
    public var attachments: [ArtifactID]
    public var isFailure: Bool
    public var recoveryAdvice: RuntimeRecoveryAdvice?
    public var submissionID: SubmissionID?
    public var submissionStatus: SubmissionStatus?
    public var submissionAttempt: Int?
    public var submissionFailure: SubmissionFailure?
    public var timestamp: Date?
    public var turnStats: TurnStatsSnapshot?
    public var responsesUsage: ResponsesUsageSnapshot?
    public var messagePhase: MessagePhase?
    /// Exact bounded App Server event retained for the backend trace and for
    /// downstream semantic presentation. Natural-language UI copy is never
    /// persisted into this field or EventLog.
    public var codexAppServerEvent: CodexAppServerEventPayload?
    /// Presentation-only semantic reduction used by the default Code/Cowork
    /// transcript. Raw projection items leave this nil.
    public var codexActivity: CodexActivityPresentation?

    public init(id: String, kind: Kind, title: String, body: String,
                presentationSource: PresentationSource = .conversation,
                complete: Bool = true,
                files: [String] = [],
                tags: [String] = [],
                goal: String? = nil,
                attachments: [ArtifactID] = [],
                isFailure: Bool = false,
                recoveryAdvice: RuntimeRecoveryAdvice? = nil,
                submissionID: SubmissionID? = nil,
                submissionStatus: SubmissionStatus? = nil,
                submissionAttempt: Int? = nil,
                submissionFailure: SubmissionFailure? = nil,
                timestamp: Date? = nil,
                turnStats: TurnStatsSnapshot? = nil,
                responsesUsage: ResponsesUsageSnapshot? = nil,
                messagePhase: MessagePhase? = nil,
                codexAppServerEvent: CodexAppServerEventPayload? = nil,
                codexActivity: CodexActivityPresentation? = nil) {
        self.id = id
        self.kind = kind
        self.presentationSource = presentationSource
        self.title = title
        self.body = body
        self.complete = complete
        self.files = files
        self.tags = tags
        self.goal = goal
        self.attachments = attachments
        self.isFailure = isFailure
        self.recoveryAdvice = recoveryAdvice
        self.submissionID = submissionID
        self.submissionStatus = submissionStatus
        self.submissionAttempt = submissionAttempt
        self.submissionFailure = submissionFailure
        self.timestamp = timestamp
        self.turnStats = turnStats
        self.responsesUsage = responsesUsage
        self.messagePhase = messagePhase
        self.codexAppServerEvent = codexAppServerEvent
        self.codexActivity = codexActivity
    }

    /// The normal Chat/Code/Cowork transcript deliberately hides execution
    /// trace rows. Keeping the predicate beside the projected item lets the
    /// Cowork per-agent index apply the exact same policy before pagination,
    /// without making Conversation depend on SharedUI.
    public var isDefaultConversationPresentationItem: Bool {
        guard presentationSource == .conversation else { return false }
        switch kind {
        case .user, .agent, .runtimeEvent, .agentToAgent, .error:
            return true
        case .toolCall, .toolResult, .patch, .note:
            return false
        }
    }
}

/// Agent-scoped presentation impact produced by one exact EventLog fold.
/// `agentIDs` includes hidden execution-trace rows, while `visibleAgentIDs`
/// contains only rows that can change the default transcript.
public struct CodeProjectionChange: Equatable, Sendable {
    public var didChangeItems: Bool
    public var agentIDs: Set<AgentID>
    public var visibleAgentIDs: Set<AgentID>

    public init(
        didChangeItems: Bool = false,
        agentIDs: Set<AgentID> = [],
        visibleAgentIDs: Set<AgentID> = []
    ) {
        self.didChangeItems = didChangeItems
        self.agentIDs = agentIDs
        self.visibleAgentIDs = visibleAgentIDs
    }

    public static let none = Self()

    public mutating func formUnion(_ other: Self) {
        didChangeItems = didChangeItems || other.didChangeItems
        agentIDs.formUnion(other.agentIDs)
        visibleAgentIDs.formUnion(other.visibleAgentIDs)
    }
}

/// One selected agent's complete continuous transcript snapshot. Canonical
/// history remains actor-owned in CodeProjection; only the currently selected
/// agent's ordered rows cross into a window presentation model.
public struct CoworkAgentThreadSnapshot: Equatable, Sendable {
    public let agentID: AgentID
    public let items: [CodeItem]
    public let projectedThroughSeq: Int
    public let projectionGeneration: UUID
    public let isAgentWorking: Bool

    public init(
        agentID: AgentID,
        items: [CodeItem],
        projectedThroughSeq: Int,
        projectionGeneration: UUID,
        isAgentWorking: Bool
    ) {
        self.agentID = agentID
        self.items = items
        self.projectedThroughSeq = projectedThroughSeq
        self.projectionGeneration = projectionGeneration
        self.isAgentWorking = isAgentWorking
    }

    public static func empty(
        agentID: AgentID
    ) -> Self {
        Self(
            agentID: agentID,
            items: [],
            projectedThroughSeq: -1,
            projectionGeneration: UUID(),
            isAgentWorking: false)
    }
}

public struct CoworkAgentThreadUpdate: Equatable, Sendable {
    public let agentID: AgentID
    public let throughSeq: Int
    public let revision: UInt64

    public init(agentID: AgentID, throughSeq: Int, revision: UInt64) {
        self.agentID = agentID
        self.throughSeq = throughSeq
        self.revision = revision
    }
}

public struct ArtifactProgressSnapshot: Identifiable, Equatable, Sendable {
    public var id: ArtifactID
    public var progress: Double
    public var state: String
    public var seq: Int

    public init(id: ArtifactID, progress: Double, state: String, seq: Int) {
        self.id = id
        self.progress = progress
        self.state = state
        self.seq = seq
    }
}

public struct ArtifactProgressProjection: Equatable, Sendable {
    public private(set) var progressByID: [ArtifactID: ArtifactProgressSnapshot] = [:]

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .artifactProgress(let payload):
            progressByID[payload.artifactId] = ArtifactProgressSnapshot(
                id: payload.artifactId,
                progress: payload.progress,
                state: payload.state,
                seq: envelope.seq)
        case .artifactAdded(let payload):
            progressByID.removeValue(forKey: payload.artifactId)
        default:
            break
        }
    }

    public var active: [ArtifactProgressSnapshot] {
        progressByID.values.sorted { $0.seq < $1.seq }
    }

    public static func build(from envelopes: [Envelope]) -> ArtifactProgressProjection {
        var p = ArtifactProgressProjection()
        for e in envelopes { p.apply(e) }
        return p
    }
}

public struct TurnStatsSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var contextWindowTokens: Int?
    public var ttftMillis: Int?
    public var totalMillis: Int?
    public var model: String?
    public var turnID: TurnID?
    public var responseMessageID: MessageID?
    public var agentID: AgentID?
    public var agentInferenceBinding: AgentInferenceBinding?

    public init(id: String, payload: TurnStatsPayload) {
        self.id = id
        self.promptTokens = payload.promptTokens
        self.cachedPromptTokens = payload.cachedPromptTokens
        self.completionTokens = payload.completionTokens
        self.totalTokens = payload.totalTokens
        self.contextWindowTokens = payload.contextWindowTokens
        self.ttftMillis = payload.ttftMillis
        self.totalMillis = payload.totalMillis
        self.model = payload.model
        self.turnID = payload.turnID
        self.responseMessageID = payload.responseMessageID
        self.agentID = payload.agentID
        self.agentInferenceBinding = payload.agentInferenceBinding
    }

    public var hasDisplayableMetrics: Bool {
        promptTokens != nil
            || cachedPromptTokens != nil
            || completionTokens != nil
            || totalTokens != nil
            || contextWindowTokens != nil
            || ttftMillis != nil
            || totalMillis != nil
    }
}

/// Presentation snapshot for the native Responses usage emitted by Codex App
/// Server. These fields deliberately do not inherit the legacy `turn_stats`
/// prompt/completion/context semantics.
public struct ResponsesUsageSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var turnID: TurnID
    public var responseMessageID: MessageID?
    public var agentID: AgentID?
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public var durationMs: Int?

    public init(id: String, payload: ResponsesUsagePayload) {
        self.id = id
        self.turnID = payload.turnID
        self.responseMessageID = payload.responseMessageID
        self.agentID = payload.agentID
        self.inputTokens = payload.inputTokens
        self.cachedInputTokens = payload.cachedInputTokens
        self.cacheWriteInputTokens = payload.cacheWriteInputTokens
        self.outputTokens = payload.outputTokens
        self.reasoningOutputTokens = payload.reasoningOutputTokens
        self.totalTokens = payload.totalTokens
        self.durationMs = payload.durationMs
    }

    public var isValid: Bool {
        inputTokens >= 0
            && cachedInputTokens >= 0
            && cacheWriteInputTokens >= 0
            && outputTokens >= 0
            && reasoningOutputTokens >= 0
            && totalTokens >= 0
            && (durationMs.map { $0 >= 0 } ?? true)
    }
}

public struct TurnStatsProjection: Equatable, Sendable {
    public private(set) var latest: TurnStatsSnapshot?

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        guard case .turnStats(let payload) = envelope.event else { return }
        let snapshot = TurnStatsSnapshot(
            id: "\(envelope.session.rawValue):\(envelope.seq):turn_stats",
            payload: payload)
        latest = snapshot.hasDisplayableMetrics ? snapshot : nil
    }

    public static func build(from envelopes: [Envelope]) -> TurnStatsProjection {
        var projection = TurnStatsProjection()
        for envelope in envelopes {
            projection.apply(envelope)
        }
        return projection
    }
}

/// Folds the event stream into `[CodeItem]`. `permission_request` is intentionally
/// not folded here — the pending request is surfaced separately as an actionable
/// card (the gate runs before execution).
public struct CodeProjection: Equatable, Sendable {
    private static let maximumPendingTurnStats = 64
    private static let maximumPendingResponsesUsage = 64
    private struct TaskAttemptKey: Hashable, Sendable {
        var taskID: TaskID
        var attempt: Int?
    }

    private struct CompletedMessageReference: Equatable, Sendable {
        var agent: AgentID
        var itemIndex: Int
    }

    public private(set) var items: [CodeItem] = []
    private var activeTaskByAgent: [AgentID: TaskAttemptKey] = [:]
    private var latestCompletedMessageByTaskAttempt: [TaskAttemptKey: CompletedMessageReference] = [:]
    private let tracksAgentThreadIndex: Bool
    private var defaultConversationAgentID: AgentID?
    private var unattributedDefaultItemIndices: Set<Int> = []
    private var itemIndexByID: [String: Int] = [:]
    private var userItemIndexBySubmissionID: [SubmissionID: Int] = [:]
    private var submissionAgentByID: [SubmissionID: AgentID] = [:]
    private var toolNameByCallID: [String: String] = [:]
    private var toolAgentByCallID: [String: AgentID] = [:]
    private var pendingTurnStatsByMessageID: [String: TurnStatsSnapshot] = [:]
    private var pendingResponsesUsageByMessageID:
        [String: ResponsesUsageSnapshot] = [:]
    private var itemAgentIDs: [[AgentID]] = []
    private var itemIndicesByAgent: [AgentID: [Int]] = [:]
    private var visibleItemIndicesByAgent: [AgentID: [Int]] = [:]

    public init() {
        tracksAgentThreadIndex = false
    }

    /// Per-agent attribution and deferred durable-main repair exist only for
    /// Cowork presentation. Code still uses the O(1) message/tool indices, but
    /// must not retain Cowork's per-item attribution arrays for a long ordinary
    /// transcript.
    init(tracksAgentThreadIndex: Bool) {
        self.tracksAgentThreadIndex = tracksAgentThreadIndex
    }

    @discardableResult
    public mutating func apply(_ envelope: Envelope) -> CodeProjectionChange {
        let initialItemCount = items.count
        var mutationChange = CodeProjectionChange.none
        switch envelope.event {
        case .userMessage(let p):
            if let submissionID = p.submissionID,
               userItemIndexBySubmissionID[submissionID] != nil {
                // The first accepted payload is immutable. A retry reuses its
                // submission identity and must not create or overwrite a user
                // message.
                break
            }
            items.append(CodeItem(id: p.submissionID?.rawValue ?? stableID(envelope, "user"),
                                  kind: .user,
                                  title: "You",
                                  body: p.text,
                                  tags: p.tags ?? [],
                                  goal: p.goal,
                                  attachments: p.attachments ?? [],
                                  submissionID: p.submissionID))

        case .submissionStatusChanged(let p):
            guard let index = userItemIndexBySubmissionID[p.submissionID],
                  SubmissionStatusFold.accepts(
                currentStatus: items[index].submissionStatus,
                currentAttempt: items[index].submissionAttempt,
                next: p)
            else { break }
            items[index].submissionStatus = p.status
            items[index].submissionAttempt = p.attempt
            items[index].submissionFailure = p.failure
            items[index].isFailure = p.status == .failed || p.status == .cancelled
            mutationChange = changeForItem(at: index)

        case .messageDelta(let p):
            if let i = agentIndex(p.messageId.rawValue) {
                let previousAttributionChange = changeForItem(at: i)
                items[i].body += p.textDelta
                if let phase = p.phase {
                    items[i].messagePhase = phase
                }
                if items[i].timestamp == nil {
                    items[i].timestamp = envelope.ts
                }
                if let agent = p.agent {
                    replaceAttribution(at: i, with: [agent])
                }
                mutationChange = previousAttributionChange
                mutationChange.formUnion(changeForItem(at: i))
            } else {
                items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                      title: p.agent?.rawValue ?? "Agent", body: p.textDelta, complete: false,
                                      submissionID: p.submissionID,
                                      timestamp: envelope.ts,
                                      turnStats: takePendingTurnStats(
                                        for: p.messageId.rawValue),
                                      responsesUsage: takePendingResponsesUsage(
                                        for: p.messageId.rawValue),
                                      messagePhase: p.phase))
            }

        case .messageCompleted(let p):
            if let i = agentIndex(p.messageId.rawValue) {
                let previousAttributionChange = changeForItem(at: i)
                items[i].body = p.text
                items[i].complete = true
                if let phase = p.phase {
                    items[i].messagePhase = phase
                }
                if items[i].timestamp == nil {
                    items[i].timestamp = envelope.ts
                }
                if let agent = p.agent {
                    replaceAttribution(at: i, with: [agent])
                }
                recordCompletedMessage(at: i, from: p.agent)
                mutationChange = previousAttributionChange
                mutationChange.formUnion(changeForItem(at: i))
            } else {
                items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                      title: p.agent?.rawValue ?? "Agent", body: p.text,
                                      submissionID: p.submissionID,
                                      timestamp: envelope.ts,
                                      turnStats: takePendingTurnStats(
                                        for: p.messageId.rawValue),
                                      responsesUsage: takePendingResponsesUsage(
                                        for: p.messageId.rawValue),
                                      messagePhase: p.phase))
                recordCompletedMessage(at: items.count - 1, from: p.agent)
            }

        case .codexAppServerEvent(let p):
            let body = Self.codexAppServerEventBody(p)
            if let index = itemIndexByID[p.eventID],
               items.indices.contains(index),
               items[index].kind == .runtimeEvent {
                items[index].title = p.method
                if let delta = p.textDelta {
                    items[index].body += delta
                } else {
                    items[index].body = body
                }
                items[index].codexAppServerEvent = p
                items[index].timestamp = envelope.ts
                mutationChange = changeForItem(at: index)
            } else {
                items.append(CodeItem(
                    id: p.eventID,
                    kind: .runtimeEvent,
                    title: p.method,
                    body: body,
                    timestamp: envelope.ts,
                    codexAppServerEvent: p))
            }

        case .turnStats(let payload):
            let snapshot = TurnStatsSnapshot(
                id: "\(envelope.session.rawValue):\(envelope.seq):turn_stats",
                payload: payload)
            guard snapshot.hasDisplayableMetrics,
                  let messageID = payload.responseMessageID?.rawValue else {
                break
            }
            if let index = agentIndex(messageID) {
                guard items[index].turnStats == nil else { break }
                items[index].turnStats = snapshot
                mutationChange = changeForItem(at: index)
            } else if itemIndexByID[messageID] == nil,
                      pendingTurnStatsByMessageID[messageID] == nil,
                      pendingTurnStatsByMessageID.count
                        < Self.maximumPendingTurnStats {
                pendingTurnStatsByMessageID[messageID] = snapshot
            }

        case .responsesUsage(let payload):
            let snapshot = ResponsesUsageSnapshot(
                id: "\(envelope.session.rawValue):\(envelope.seq):responses_usage",
                payload: payload)
            guard snapshot.isValid,
                  let messageID = payload.responseMessageID?.rawValue else {
                break
            }
            if let index = agentIndex(messageID) {
                guard items[index].responsesUsage == nil else { break }
                items[index].responsesUsage = snapshot
                mutationChange = changeForItem(at: index)
            } else if itemIndexByID[messageID] == nil,
                      pendingResponsesUsageByMessageID[messageID] == nil,
                      pendingResponsesUsageByMessageID.count
                        < Self.maximumPendingResponsesUsage {
                pendingResponsesUsageByMessageID[messageID] = snapshot
            }

        case .toolCall(let p):
            items.append(CodeItem(id: p.toolCallId, kind: .toolCall, title: p.name, body: p.args))

        case .toolResult(let p):
            let toolName = toolName(for: p.toolCallId)
            let title = toolName.map { "result · \($0)" } ?? "result"
            // Current logs carry a typed call outcome. Keep the text
            // classifier only as an old-JSONL compatibility fallback; new
            // runtime/sandbox failures must never depend on presentation
            // wording, and successful output that happens to resemble an
            // error prefix must remain successful.
            let isFailure = p.outcome.map { $0 != .succeeded }
                ?? Self.isFailureObservation(p.observation)
            items.append(CodeItem(id: p.toolCallId + ":result", kind: .toolResult,
                                  title: title, body: p.observation,
                                  isFailure: isFailure,
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(forToolObservation: p.observation)))

        case .patchProposed(let p):
            items.append(CodeItem(id: p.patchId, kind: .patch, title: "patch", body: p.diff, files: p.files))

        case .permissionResolved(let p):
            items.append(CodeItem(id: stableID(envelope, "permission_resolved"), kind: .note, title: "permission",
                                  body: "\(p.decision.rawValue): \(p.tool) — \(p.reason)"))

        case .error(let p):
            markCurrentPartialAgentStopped(with: p)
            items.append(CodeItem(id: stableID(envelope, "error"),
                                  kind: .error,
                                  title: "error · \(p.code)",
                                  body: p.message,
                                  isFailure: true,
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(for: p),
                                  submissionID: p.submissionID))

        case .turnOutcome(let p):
            guard p.outcome != .completed else { break }
            mutationChange = markInvalidatedAgentCompletion(for: p)

        // v0.3 (Cowork)
        case .agentAttached(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_attached"), kind: .note, title: "agent",
                                  body: "+ @\(p.agent.rawValue) attached (\(p.path))"))

        case .agentAttachRequested(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_attach_requested"), kind: .note, title: "agent attach requested",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentDetached(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_detached"), kind: .note, title: "agent",
                                  body: "− @\(p.agent.rawValue) detached"))

        case .agentSpawnRequested(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_spawn_requested"), kind: .note, title: "agent spawn requested",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentSpawned(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_spawned"), kind: .note, title: "agent spawned",
                                  body: "@\(p.agent.rawValue): \(p.path)"))

        case .agentMessage(let p):
            let title = p.from.flatMap { from in p.to.map { "\(from.rawValue)->\($0.rawValue)" } }
                ?? p.agent.rawValue
            items.append(CodeItem(id: p.messageId.rawValue, kind: .agent,
                                  title: title, body: p.content,
                                  timestamp: envelope.ts))

        case .agentMessageConsumed, .agentMessageDiscarded:
            break

        case .agentToAgentMessage(let p):
            items.append(CodeItem(id: stableID(envelope, "agent_to_agent"), kind: .agentToAgent,
                                  title: "\(p.from.rawValue)->\(p.to.rawValue)", body: p.content,
                                  timestamp: envelope.ts))

        case .informationRequested(let p):
            items.append(CodeItem(id: p.requestID.rawValue, kind: .agentToAgent,
                                  title: "\(p.from.rawValue)->\(p.to.rawValue)", body: p.question,
                                  timestamp: envelope.ts))

        case .informationReplied(let p):
            items.append(CodeItem(id: p.replyID.rawValue, kind: .agentToAgent,
                                  title: "\(p.from.rawValue)->\(p.to.rawValue)", body: p.content,
                                  timestamp: envelope.ts))

        case .delegationApproved(let p):
            items.append(CodeItem(id: stableID(envelope, "delegation_approved"), kind: .note, title: "delegation approved",
                                  body: "@\(p.contract.assignee.rawValue): \(p.contract.objective)"))

        case .delegationRejected(let p):
            items.append(CodeItem(id: stableID(envelope, "delegation_rejected"), kind: .error, title: "delegation rejected",
                                  body: "\(p.objective) — \(p.reason)",
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "delegation_rejected",
                                    message: p.reason)))

        case .taskDelegated(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":delegated", kind: .note, title: "task delegated",
                                  body: "@\(p.assignee.rawValue): \(p.contract.objective)"))

        case .workspaceLeaseRequested(let p):
            items.append(CodeItem(id: stableID(envelope, "workspace_lease_requested"), kind: .note, title: "workspace lease requested",
                                  body: "\(p.access.rawValue): \(p.rootPath)"))

        case .workspaceLeaseGranted(let p):
            items.append(CodeItem(id: p.lease.id.rawValue, kind: .note, title: "workspace lease",
                                  body: "\(p.lease.access.rawValue): \(p.lease.rootPath)"))

        case .workspaceLeaseDenied(let p):
            items.append(CodeItem(id: stableID(envelope, "workspace_lease_denied"), kind: .error, title: "workspace lease denied",
                                  body: "\(p.rootPath) — \(p.reason)",
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "permission_denied",
                                    message: p.reason)))

        case .workspaceLeaseRevoked(let p):
            items.append(CodeItem(id: p.leaseID.rawValue + ":revoked", kind: .note,
                                  title: "workspace lease revoked", body: p.reason))

        case .capabilityLeaseCreated(let p):
            items.append(CodeItem(id: p.lease.id.rawValue, kind: .note, title: "capability lease",
                                  body: p.lease.tools.map(\.rawValue).sorted().joined(separator: ", ")))

        case .capabilityLeaseRevoked(let p):
            items.append(CodeItem(id: p.leaseID.rawValue + ":revoked", kind: .note, title: "capability lease revoked",
                                  body: p.reason))

        case .permissionReview(let p):
            items.append(CodeItem(id: stableID(envelope, "permission_review"), kind: .note, title: "review",
                                  body: "reviewer(\(p.reviewerModel)): \(p.decision.rawValue) \(p.tool) — \(p.reason)"))

        case .taskCreated(let p):
            items.append(CodeItem(id: p.contract.id.rawValue, kind: .note, title: "task",
                                  body: "created \(p.contract.roleHint): \(p.contract.objective)"))

        case .taskAssigned(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":assigned", kind: .note, title: "task",
                                  body: "assigned @\(p.contract.assignee.rawValue): \(p.contract.expectedDeliverable)"))

        case .taskQueued(let p):
            items.append(CodeItem(id: p.contract.id.rawValue + ":queued", kind: .note, title: "task",
                                  body: "queued @\(p.assignee.rawValue): \(p.contract.objective)"))

        case .taskStarted(let p):
            beginTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)
            items.append(CodeItem(id: p.taskID.rawValue + ":started", kind: .note, title: "task",
                                  body: "started @\(p.agent.rawValue)"))

        case .taskCompleted(let p):
            let presentationSource: CodeItem.PresentationSource = completedTaskMirrorsMessage(p)
                ? .executionTrace
                : .conversation
            items.append(CodeItem(id: p.taskID.rawValue + ":completed", kind: .agent,
                                  title: p.agent.rawValue, body: p.result,
                                  presentationSource: presentationSource,
                                  timestamp: envelope.ts))
            finishTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)

        case .taskFailed(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":failed", kind: .error,
                                  title: p.agent.rawValue,
                                  body: p.error,
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "task_failed",
                                    message: p.error)))
            finishTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)

        case .taskCancelled(let p):
            items.append(CodeItem(id: p.taskID.rawValue + ":cancelled", kind: .note,
                                  title: "task cancelled · (p.agent.rawValue)", body: p.reason))
            finishTaskTracking(taskID: p.taskID, agent: p.agent, attempt: p.attempt)

        case .taskRejected(let p):
            items.append(CodeItem(id: p.contract?.id.rawValue ?? stableID(envelope, "task_rejected"), kind: .error,
                                  title: "task rejected",
                                  body: "\(p.objective) — \(p.reason)",
                                  recoveryAdvice: RuntimeErrorPresentation.recoveryAdvice(
                                    code: "task_rejected",
                                    message: p.reason)))
        case .artifactAdded(let p):
            items.append(CodeItem(id: p.artifactId.rawValue, kind: .note, title: "artifact",
                                  body: "📎 \(p.kind)" + (p.prompt.map { ": \($0)" } ?? "")))

        case .mcpRequestProgress(let p):
            let id = [
                "mcp-progress",
                p.connectionGeneration.rawValue,
                p.requestIDFingerprint,
            ].joined(separator: ":")
            let status: String
            if let total = p.total, total > 0 {
                let percent = min(
                    100,
                    max(0, Int((p.progress / total * 100).rounded())))
                status = "\(percent)% · \(p.phase.rawValue)"
            } else {
                status = "\(p.progress) · \(p.phase.rawValue)"
            }
            let body = p.diagnostic.map {
                "\(status)\n\($0.summary)"
            } ?? status
            if let index = itemIndexByID[id] {
                items[index].body = body
                items[index].complete = p.phase != .reported
                items[index].timestamp = envelope.ts
                mutationChange = changeForItem(at: index)
            } else {
                items.append(CodeItem(
                    id: id,
                    kind: .note,
                    title:
                        "MCP · \(p.server.serverID.rawValue) · \(p.requestMethod)",
                    body: body,
                    complete: p.phase != .reported,
                    timestamp: envelope.ts))
            }

        case .sessionSettingsUpdated, .sessionStorageMigrated,
             .modelHistoryItem, .modelHistoryCompacted,
             .toolExecutionPrepared, .toolExecutionSettled,
             .permissionRequest, .permissionReviewRequested, .permissionReviewSettled,
             .agentStatus,
             .workTaskCreated, .workTaskUpdated, .workTaskDependencyChanged,
             .workTaskReady, .workTaskStarted, .workTaskProgressed, .workTaskBlocked,
             .workTaskCompleted, .workTaskFailed, .workTaskCancelled,
             .workTaskInvocationLinked, .workTaskEvidenceAdded,
             .goalCreated, .goalEdited, .goalPaused, .goalResumed, .goalAuditCompleted,
             .goalContinuationScheduled, .goalProgressed, .goalBlocked,
             .goalBudgetLimited, .goalUsageLimited, .goalCompleted, .goalCleared,
             .continuationRunCreated, .continuationRunStarted, .continuationRunCheckpointed,
             .continuationRunCloseRequested,
             .continuationRunCompleted, .continuationRunInterrupted, .continuationRunCancelled,
             .artifactProgress,
             .mcpServerAttached, .mcpServerDetached, .mcpAttachmentPolicyUpdated,
             .mcpConsentGranted, .mcpConsentRevoked,
             .mcpControlOperationRequested, .mcpControlOperationSettled,
             .mcpGrantGranted, .mcpGrantRevoked,
             .mcpRememberedApprovalGranted,
             .mcpRememberedApprovalRevoked,
             .mcpRootsPolicyUpdated, .mcpNetworkPolicyUpdated, .mcpPromptInserted,
             .mcpSamplingRequested, .mcpSamplingDecided, .mcpSamplingSettled,
             .mcpElicitationRequested, .mcpElicitationDecided, .mcpElicitationSettled,
             .mcpRemoteTaskRequested, .mcpRemoteTaskMapped,
             .mcpRemoteTaskStateChanged, .mcpRemoteTaskSettled,
             .mcpClientTaskRequested, .mcpClientTaskStateChanged, .mcpClientTaskSettled,
             .mcpConnectionTerminal, .mcpCatalogTerminal, .mcpExecutionUncertain:
            break
        }

        var change = mutationChange
        if items.count > initialItemCount {
            let agents = tracksAgentThreadIndex
                ? attributedAgents(for: envelope.event)
                : []
            for index in initialItemCount..<items.count {
                change.formUnion(registerItem(at: index, agents: agents))
                if tracksAgentThreadIndex,
                   agents.isEmpty,
                   requiresDefaultAttribution(envelope.event) {
                    unattributedDefaultItemIndices.insert(index)
                }
            }
        }
        return change
    }

    public static func build(from envelopes: [Envelope]) -> CodeProjection {
        var p = CodeProjection()
        for e in envelopes { p.apply(e) }
        return p
    }

    /// Sets the durable Cowork main identity used only for otherwise
    /// untargeted presentation rows. When deferred attribution is enabled by
    /// the Cowork reducer, legacy logs that place user rows before their
    /// settings event are repaired once during replay, rather than at click
    /// time.
    @discardableResult
    public mutating func setDefaultConversationAgentID(
        _ agentID: AgentID
    ) -> CodeProjectionChange {
        guard tracksAgentThreadIndex else { return .none }
        guard defaultConversationAgentID != agentID else { return .none }
        defaultConversationAgentID = agentID
        let pending = unattributedDefaultItemIndices
        unattributedDefaultItemIndices.removeAll(keepingCapacity: false)
        var change = CodeProjectionChange.none
        for index in pending where items.indices.contains(index) {
            replaceAttribution(at: index, with: [agentID])
            change.formUnion(changeForItem(at: index))
        }
        return change
    }

    public var indexedAgentIDs: Set<AgentID> {
        Set(itemIndicesByAgent.keys)
    }

    public var visibleIndexedAgentIDs: Set<AgentID> {
        Set(visibleItemIndicesByAgent.keys)
    }

    /// Reads the selected agent's complete ordered index. `additionalItems` is
    /// a pre-indexed owner-only outbox tail supplied by the app; unrelated
    /// agents remain actor-owned and are not copied to MainActor.
    public func coworkAgentThreadSnapshot(
        agentID: AgentID,
        showsExecutionTrace: Bool,
        additionalItems: [CodeItem] = [],
        projectedThroughSeq: Int,
        projectionGeneration: UUID,
        isAgentWorking: Bool
    ) -> CoworkAgentThreadSnapshot {
        let indices = showsExecutionTrace
            ? itemIndicesByAgent[agentID] ?? []
            : visibleItemIndicesByAgent[agentID] ?? []
        var snapshotItems: [CodeItem] = []
        snapshotItems.reserveCapacity(indices.count + additionalItems.count)
        for index in indices {
            snapshotItems.append(items[index])
        }
        snapshotItems.append(contentsOf: additionalItems)
        return CoworkAgentThreadSnapshot(
            agentID: agentID,
            items: snapshotItems,
            projectedThroughSeq: projectedThroughSeq,
            projectionGeneration: projectionGeneration,
            isAgentWorking: isAgentWorking)
    }

    private func agentIndex(_ id: String) -> Int? {
        guard let index = itemIndexByID[id],
              items[index].kind == .agent else { return nil }
        return index
    }

    private mutating func takePendingTurnStats(
        for messageID: String
    ) -> TurnStatsSnapshot? {
        pendingTurnStatsByMessageID.removeValue(forKey: messageID)
    }

    private mutating func takePendingResponsesUsage(
        for messageID: String
    ) -> ResponsesUsageSnapshot? {
        pendingResponsesUsageByMessageID.removeValue(forKey: messageID)
    }

    private func toolName(for toolCallId: String) -> String? {
        toolNameByCallID[toolCallId]
    }

    private func changeForItem(at index: Int) -> CodeProjectionChange {
        guard items.indices.contains(index) else { return .none }
        let agents = itemAgentIDs.indices.contains(index)
            ? Set(itemAgentIDs[index])
            : []
        return CodeProjectionChange(
            didChangeItems: true,
            agentIDs: agents,
            visibleAgentIDs:
                items[index].isDefaultConversationPresentationItem
                    ? agents
                    : [])
    }

    private mutating func registerItem(
        at index: Int,
        agents: [AgentID]
    ) -> CodeProjectionChange {
        guard items.indices.contains(index) else { return .none }
        let item = items[index]
        if itemIndexByID[item.id] == nil {
            itemIndexByID[item.id] = index
        }
        if item.kind == .user,
           let submissionID = item.submissionID,
           userItemIndexBySubmissionID[submissionID] == nil {
            userItemIndexBySubmissionID[submissionID] = index
        }
        if item.kind == .toolCall {
            toolNameByCallID[item.id] = item.title
        }
        replaceAttribution(at: index, with: agents)
        return changeForItem(at: index)
    }

    private mutating func replaceAttribution(
        at index: Int,
        with candidateAgents: [AgentID]
    ) {
        guard tracksAgentThreadIndex,
              items.indices.contains(index) else { return }
        while itemAgentIDs.count <= index {
            itemAgentIDs.append([])
        }
        let agents = Array(Set(candidateAgents)).sorted {
            $0.rawValue < $1.rawValue
        }
        let previous = itemAgentIDs[index]
        guard previous != agents else { return }
        for agent in previous {
            itemIndicesByAgent[agent]?.removeAll { $0 == index }
            visibleItemIndicesByAgent[agent]?.removeAll { $0 == index }
            if itemIndicesByAgent[agent]?.isEmpty == true {
                itemIndicesByAgent.removeValue(forKey: agent)
            }
            if visibleItemIndicesByAgent[agent]?.isEmpty == true {
                visibleItemIndicesByAgent.removeValue(forKey: agent)
            }
        }
        itemAgentIDs[index] = agents
        if !agents.isEmpty {
            unattributedDefaultItemIndices.remove(index)
        }
        for agent in agents {
            insertItemIndexInOrder(
                index,
                for: agent,
                into: &itemIndicesByAgent)
            if items[index].isDefaultConversationPresentationItem {
                insertItemIndexInOrder(
                    index,
                    for: agent,
                    into: &visibleItemIndicesByAgent)
            }
        }
        if let submissionID = items[index].submissionID,
           let first = agents.first {
            submissionAgentByID[submissionID] = first
        }
        if items[index].kind == .toolCall,
           let first = agents.first {
            toolAgentByCallID[items[index].id] = first
        }
    }

    private func insertItemIndexInOrder(
        _ index: Int,
        for agent: AgentID,
        into indexMap: inout [AgentID: [Int]]
    ) {
        var indices = indexMap[agent] ?? []
        guard indices.last.map({ $0 >= index }) == true else {
            indices.append(index)
            indexMap[agent] = indices
            return
        }
        var lower = 0
        var upper = indices.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if indices[middle] < index {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower == indices.count || indices[lower] != index {
            indices.insert(index, at: lower)
        }
        indexMap[agent] = indices
    }

    private func requiresDefaultAttribution(_ event: Event) -> Bool {
        switch event {
        case .userMessage(let payload):
            return payload.to == nil
        case .messageDelta(let payload):
            return payload.agent == nil
        case .messageCompleted(let payload):
            return payload.agent == nil
        case .codexAppServerEvent(let payload):
            return payload.agent == nil
        case .toolCall(let payload):
            return payload.agent == nil
        case .patchProposed(let payload):
            return payload.agent == nil
        default:
            return false
        }
    }

    private func attributedAgents(for event: Event) -> [AgentID] {
        switch event {
        case .userMessage(let payload):
            return compactAgents(payload.to ?? defaultConversationAgentID)
        case .messageDelta(let payload):
            return compactAgents(payload.agent ?? defaultConversationAgentID)
        case .messageCompleted(let payload):
            return compactAgents(payload.agent ?? defaultConversationAgentID)
        case .codexAppServerEvent(let payload):
            return compactAgents(payload.agent ?? defaultConversationAgentID)
        case .toolCall(let payload):
            return compactAgents(payload.agent ?? defaultConversationAgentID)
        case .toolResult(let payload):
            return compactAgents(toolAgentByCallID[payload.toolCallId])
        case .patchProposed(let payload):
            return compactAgents(payload.agent ?? defaultConversationAgentID)
        case .error(let payload):
            return compactAgents(
                payload.submissionID.flatMap { submissionAgentByID[$0] })
        case .agentAttached(let payload):
            return [payload.agent]
        case .agentAttachRequested(let payload):
            return [payload.agent]
        case .agentDetached(let payload):
            return [payload.agent]
        case .agentSpawnRequested(let payload):
            return [payload.agent]
        case .agentSpawned(let payload):
            return [payload.agent]
        case .agentMessage(let payload):
            return uniqueAgents([
                payload.from ?? payload.agent,
                payload.to,
            ])
        case .agentToAgentMessage(let payload):
            return uniqueAgents([payload.from, payload.to])
        case .informationRequested(let payload):
            return uniqueAgents([payload.from, payload.to])
        case .informationReplied(let payload):
            return uniqueAgents([payload.from, payload.to])
        case .delegationApproved(let payload):
            return uniqueAgents([
                payload.contract.issuer,
                payload.contract.assignee,
            ])
        case .delegationRejected(let payload):
            return uniqueAgents([payload.requester, payload.assignee])
        case .taskDelegated(let payload):
            return uniqueAgents([payload.issuer, payload.assignee])
        case .taskCreated(let payload):
            return uniqueAgents([
                payload.contract.issuer,
                payload.contract.assignee,
            ])
        case .taskAssigned(let payload):
            return uniqueAgents([
                payload.contract.issuer,
                payload.contract.assignee,
            ])
        case .taskQueued(let payload):
            return [payload.assignee]
        case .taskStarted(let payload):
            return [payload.agent]
        case .taskCompleted(let payload):
            return [payload.agent]
        case .taskFailed(let payload):
            return [payload.agent]
        case .taskCancelled(let payload):
            return [payload.agent]
        case .taskRejected(let payload):
            return uniqueAgents([
                payload.requester ?? payload.contract?.issuer,
                payload.assignee ?? payload.contract?.assignee,
            ])
        default:
            return []
        }
    }

    private func compactAgents(_ agent: AgentID?) -> [AgentID] {
        agent.map { [$0] } ?? []
    }

    private func uniqueAgents(_ agents: [AgentID?]) -> [AgentID] {
        Array(Set(agents.compactMap { $0 })).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    private mutating func beginTaskTracking(taskID: TaskID, agent: AgentID, attempt: Int?) {
        let key = TaskAttemptKey(taskID: taskID, attempt: attempt)
        activeTaskByAgent[agent] = key
        // A duplicate start for this exact invocation must not inherit an old
        // completed message. References for other attempts remain available
        // so a late terminal cannot consume the currently active attempt.
        latestCompletedMessageByTaskAttempt.removeValue(forKey: key)
    }

    private mutating func recordCompletedMessage(at index: Int, from agent: AgentID?) {
        guard items.indices.contains(index),
              items[index].messagePhase != .commentary else { return }
        guard let agent, let key = activeTaskByAgent[agent] else { return }
        latestCompletedMessageByTaskAttempt[key] = CompletedMessageReference(
            agent: agent,
            itemIndex: index)
    }

    private func completedTaskMirrorsMessage(_ payload: TaskCompletedPayload) -> Bool {
        let key = TaskAttemptKey(taskID: payload.taskID, attempt: payload.attempt)
        guard let reference = latestCompletedMessageByTaskAttempt[key],
              reference.agent == payload.agent,
              items.indices.contains(reference.itemIndex)
        else { return false }

        let message = items[reference.itemIndex]
        return message.kind == .agent
            && message.complete
            && message.body == payload.result
    }

    private mutating func finishTaskTracking(taskID: TaskID, agent: AgentID, attempt: Int?) {
        let key = TaskAttemptKey(taskID: taskID, attempt: attempt)
        if activeTaskByAgent[agent] == key {
            activeTaskByAgent.removeValue(forKey: agent)
        }
        latestCompletedMessageByTaskAttempt.removeValue(forKey: key)
    }

    private mutating func markCurrentPartialAgentStopped(with payload: ErrorPayload) {
        guard let index = items.indices.last else { return }
        guard items[index].kind == .agent, !items[index].complete else { return }
        items[index].isFailure = true
        items[index].recoveryAdvice = RuntimeErrorPresentation.partialResponseAdvice(for: payload)
    }

    /// Repairs logs written by older AgentLoop builds that published a normal
    /// `message_completed` before the authoritative turn terminal failed. The
    /// exact active task/attempt mapping is preferred; submission correlation
    /// is only a compatibility fallback and must resolve to one latest item.
    private mutating func markInvalidatedAgentCompletion(
        for payload: TurnOutcomePayload
    ) -> CodeProjectionChange {
        let exactIndex: Int? = {
            guard let agent = payload.agentID,
                  let key = activeTaskByAgent[agent],
                  payload.taskID == nil || key.taskID == payload.taskID,
                  let reference = latestCompletedMessageByTaskAttempt[key],
                  reference.agent == agent,
                  items.indices.contains(reference.itemIndex) else {
                return nil
            }
            return reference.itemIndex
        }()

        let fallbackIndex: Int? = exactIndex == nil ? items.indices.reversed().first { index in
            let item = items[index]
            guard item.kind == .agent,
                  item.complete,
                  item.messagePhase != .commentary,
                  let submissionID = payload.submissionID,
                  item.submissionID == submissionID else {
                return false
            }
            guard let agent = payload.agentID else { return true }
            if itemAgentIDs.indices.contains(index),
               !itemAgentIDs[index].isEmpty {
                return itemAgentIDs[index].contains(agent)
            }
            return item.title == agent.rawValue
        } : nil

        guard let index = exactIndex ?? fallbackIndex,
              items.indices.contains(index),
              items[index].kind == .agent else {
            return .none
        }

        items[index].complete = false
        items[index].isFailure = true
        let reason = payload.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedReason = reason.map { String($0.prefix(1_024)) }
        let detail = boundedReason.flatMap { $0.isEmpty ? nil : $0 }
            ?? "The authoritative turn outcome did not accept this response as complete. The partial text is preserved for review."
        items[index].recoveryAdvice = RuntimeRecoveryAdvice(
            title: payload.outcome == .interrupted
                ? "Response interrupted"
                : "Response was not accepted as complete",
            detail: detail,
            retryable: true)
        return changeForItem(at: index)
    }

    private static func codexAppServerEventBody(
        _ payload: CodexAppServerEventPayload
    ) -> String {
        var fields: [String] = []
        if let threadID = payload.threadID {
            fields.append("thread: \(threadID)")
        }
        if let itemType = payload.itemType {
            fields.append("type: \(itemType)")
        }
        if let phase = payload.phase {
            fields.append("phase: \(phase.rawValue)")
        }
        if let status = payload.status {
            fields.append("status: \(status)")
        }
        if let willRetry = payload.willRetry {
            fields.append("willRetry: \(willRetry)")
        }
        if let fromModel = payload.fromModel {
            fields.append("fromModel: \(fromModel)")
        }
        if let toModel = payload.toModel {
            fields.append("toModel: \(toModel)")
        }
        if let reason = payload.reason {
            fields.append("reason: \(reason)")
        }
        if let message = payload.message {
            fields.append(message)
        }
        if let details = payload.details {
            fields.append(details)
        }
        if let textDelta = payload.textDelta {
            fields.append(textDelta)
        }
        return fields.joined(separator: "\n")
    }

    private static func isFailureObservation(_ observation: String) -> Bool {
        let lower = observation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("tool error:")
            || lower.hasPrefix("permission denied:")
            || lower.hasPrefix("unknown tool:")
            || lower.hasPrefix("invalid tool input:")
    }

    private func stableID(_ envelope: Envelope, _ suffix: String) -> String {
        "\(envelope.session.rawValue):\(envelope.seq):\(suffix)"
    }
}

public enum PendingPermissionState: String, Equatable, Sendable {
    case livePending = "live_pending"
    case resolving
    case approved
    case rejected
    case expired
    case needsRerun = "needs_rerun"

    public var isActionable: Bool {
        self == .livePending
    }
}

public struct PendingPermission: Identifiable, Equatable, Sendable {
    public var id: RequestID { request.requestId }
    public var request: PermissionRequestPayload
    public var state: PendingPermissionState
    public var requestedSeq: Int
    public var hasIdentityConflict: Bool

    public init(request: PermissionRequestPayload,
                state: PendingPermissionState = .livePending,
                requestedSeq: Int,
                hasIdentityConflict: Bool = false) {
        self.request = request
        self.state = state
        self.requestedSeq = requestedSeq
        self.hasIdentityConflict = hasIdentityConflict
    }
}

public struct PermissionResolutionNotice: Identifiable, Equatable, Sendable {
    public var id: String
    public var requestId: RequestID?
    public var tool: String
    public var decision: PermissionDecision
    public var risk: RiskLevel
    public var reason: String
    public var authorization: ResolvedToolAuthorization?
    public var source: PermissionApprovalSource?
    public var reviewTaskID: PermissionReviewTaskID?
    public var reviewStatus: PermissionReviewStatus?
    public var failureKind: PermissionApprovalFailureKind?
    public var failureSource: ExecutionFailureSource?
    public var action: PermissionResponseAction?
    public var resolvedSeq: Int

    public init(id: String,
                requestId: RequestID?,
                tool: String,
                decision: PermissionDecision,
                risk: RiskLevel,
                reason: String,
                authorization: ResolvedToolAuthorization? = nil,
                source: PermissionApprovalSource? = nil,
                reviewTaskID: PermissionReviewTaskID? = nil,
                reviewStatus: PermissionReviewStatus? = nil,
                failureKind: PermissionApprovalFailureKind? = nil,
                failureSource: ExecutionFailureSource? = nil,
                action: PermissionResponseAction? = nil,
                resolvedSeq: Int) {
        self.id = id
        self.requestId = requestId
        self.tool = tool
        self.decision = decision
        self.risk = risk
        self.reason = reason
        self.authorization = authorization
        self.source = source
        self.reviewTaskID = reviewTaskID
        self.reviewStatus = reviewStatus
        self.failureKind = failureKind
        self.failureSource = failureSource
        self.action = action
        self.resolvedSeq = resolvedSeq
    }
}

/// Folds permission request/resolution events into recoverable pending state.
/// A replayed pending request may no longer have a live async tool continuation;
/// callers can mark it `needs_rerun` while still showing it in the UI.
public struct PermissionProjection: Equatable, Sendable {
    public private(set) var pending: [PendingPermission] = []
    public private(set) var resolved: [PermissionResolutionNotice] = []
    private var automaticReviewRequestIDs: Set<RequestID> = []

    public init() {}

    public mutating func apply(_ envelope: Envelope) {
        switch envelope.event {
        case .permissionRequest(let request):
            register(request, requestedSeq: envelope.seq)
        case .permissionReviewRequested(let review):
            let requestID = review.task.requestID
            automaticReviewRequestIDs.insert(requestID)
            if let index = pending.firstIndex(where: { $0.id == requestID }),
               pending[index].state == .livePending {
                pending[index].state = .resolving
            }
        case .permissionResolved(let resolved):
            if let requestID = resolved.requestId {
                // A permission request has one terminal result. Replayed,
                // duplicate, or conflicting late settlements cannot replace
                // the first durable terminal event.
                guard !self.resolved.contains(where: { $0.requestId == requestID }) else {
                    break
                }
                pending.removeAll { $0.request.requestId == requestID }
            }
            self.resolved.append(PermissionResolutionNotice(
                id: stableResolvedID(envelope, requestID: resolved.requestId),
                requestId: resolved.requestId,
                tool: resolved.tool,
                decision: resolved.decision,
                risk: resolved.risk,
                reason: resolved.reason,
                authorization: resolved.authorization,
                source: resolved.source,
                reviewTaskID: resolved.reviewTaskID,
                reviewStatus: resolved.reviewStatus,
                failureKind: resolved.failureKind,
                failureSource: resolved.failureSource,
                action: resolved.action,
                resolvedSeq: envelope.seq))
        default:
            break
        }
    }

    public mutating func markNeedsRerun() {
        pending = pending.map {
            var item = $0
            item.state = .needsRerun
            return item
        }
    }

    public var latest: PendingPermission? {
        // Kept under the historical `latest` API name for compatibility. The
        // presentation contract is FIFO: always surface the oldest unresolved
        // request, including a non-actionable automatic review ahead of later
        // requests.
        pending.min { lhs, rhs in
            if lhs.requestedSeq == rhs.requestedSeq {
                return lhs.id.rawValue < rhs.id.rawValue
            }
            return lhs.requestedSeq < rhs.requestedSeq
        }
    }

    public var latestResolved: PermissionResolutionNotice? {
        resolved.sorted { $0.resolvedSeq < $1.resolvedSeq }.last
    }

    public static func build(from envelopes: [Envelope], markNeedsRerun: Bool = false) -> PermissionProjection {
        var p = PermissionProjection()
        for e in envelopes { p.apply(e) }
        if markNeedsRerun { p.markNeedsRerun() }
        return p
    }

    private mutating func register(_ request: PermissionRequestPayload, requestedSeq: Int) {
        let requestID = request.requestId

        // A late request event must not reopen an identity which already has a
        // terminal result.
        guard !resolved.contains(where: { $0.requestId == requestID }) else { return }

        if let index = pending.firstIndex(where: { $0.id == requestID }) {
            // Exact duplicates are replay/idempotency noise. Preserve the
            // original position and state. A different payload reusing the
            // identity is ambiguous, so retain the first payload and fail
            // closed instead of exposing either version as actionable.
            if !requestsAreEquivalent(pending[index].request, request) {
                pending[index].state = .expired
                pending[index].hasIdentityConflict = true
            }
            return
        }

        let state: PendingPermissionState = request.effectiveApprovalMode == .automaticReviewer
            || automaticReviewRequestIDs.contains(requestID)
            ? .resolving
            : .livePending
        pending.append(PendingPermission(
            request: request,
            state: state,
            requestedSeq: requestedSeq))
    }

    private func requestsAreEquivalent(_ lhs: PermissionRequestPayload,
                                       _ rhs: PermissionRequestPayload) -> Bool {
        var normalizedLHS = lhs
        var normalizedRHS = rhs
        normalizedLHS.approvalMode = lhs.effectiveApprovalMode
        normalizedRHS.approvalMode = rhs.effectiveApprovalMode
        return normalizedLHS == normalizedRHS
    }

    private func stableResolvedID(_ envelope: Envelope, requestID: RequestID?) -> String {
        if let requestID {
            return "permission:\(requestID.rawValue):resolved"
        }
        return "\(envelope.session.rawValue):\(envelope.seq):permission_resolved"
    }
}
