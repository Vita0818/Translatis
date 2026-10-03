import Foundation
import IntatisCore
import IntatisProtocol
import MCP

// MARK: - Task-augmentation negotiation

public enum MCPTaskInvocationPreference: Equatable, Sendable {
    case automatic
    case preferTask
    case requireTask
    case forbidTask
}

public enum MCPTaskAugmentationDecision: Equatable, Sendable {
    case ordinary
    case task(ttlMilliseconds: Int?)
}

public enum MCPTaskAugmentationError: Error, Equatable, LocalizedError,
    Sendable
{
    case unsupportedProfile
    case serverCapabilityMissing
    case toolForbidsTasks
    case toolRequiresTasks

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile:
            return "Experimental MCP tasks require the standard-extended profile."
        case .serverCapabilityMissing:
            return "The exact server generation does not advertise task-augmented tools/call."
        case .toolForbidsTasks:
            return "The exact tool revision forbids task augmentation."
        case .toolRequiresTasks:
            return "The exact tool revision requires task augmentation."
        }
    }
}

public enum MCPTaskAugmentationPolicy {
    public static func decide(
        profile: MCPProtocolProfile,
        serverSupportsToolCallTasks: Bool,
        toolTaskSupport: MCPToolTaskSupport?,
        preference: MCPTaskInvocationPreference,
        requestedTTLMilliseconds: Int? = nil
    ) throws -> MCPTaskAugmentationDecision {
        let support = toolTaskSupport ?? .forbidden
        if support == .required {
            guard profile == .standardExtended else {
                throw MCPTaskAugmentationError.unsupportedProfile
            }
            guard serverSupportsToolCallTasks else {
                throw MCPTaskAugmentationError.serverCapabilityMissing
            }
            guard preference != .forbidTask else {
                throw MCPTaskAugmentationError.toolRequiresTasks
            }
            return .task(ttlMilliseconds: requestedTTLMilliseconds)
        }

        if preference == .requireTask || preference == .preferTask {
            guard profile == .standardExtended else {
                throw MCPTaskAugmentationError.unsupportedProfile
            }
            guard serverSupportsToolCallTasks else {
                if preference == .requireTask {
                    throw MCPTaskAugmentationError.serverCapabilityMissing
                }
                return .ordinary
            }
            guard support == .optional else {
                if preference == .requireTask {
                    throw MCPTaskAugmentationError.toolForbidsTasks
                }
                return .ordinary
            }
            return .task(ttlMilliseconds: requestedTTLMilliseconds)
        }
        return .ordinary
    }
}

// MARK: - Common task policy and errors

public struct MCPTaskRuntimePolicy: Equatable, Sendable {
    public let defaultTTLMilliseconds: Int
    public let maximumTTLMilliseconds: Int
    public let minimumPollIntervalMilliseconds: Int
    public let maximumPollIntervalMilliseconds: Int
    public let maximumTasks: Int
    public let listPageSize: Int
    public let maximumResultBytes: Int

    public init(
        defaultTTLMilliseconds: Int = 24 * 60 * 60 * 1_000,
        maximumTTLMilliseconds: Int = 7 * 24 * 60 * 60 * 1_000,
        minimumPollIntervalMilliseconds: Int = 100,
        maximumPollIntervalMilliseconds: Int = 60 * 60 * 1_000,
        maximumTasks: Int = 1_024,
        listPageSize: Int = 50,
        maximumResultBytes: Int = 1024 * 1_024
    ) {
        self.defaultTTLMilliseconds = max(1_000, defaultTTLMilliseconds)
        self.maximumTTLMilliseconds = max(
            self.defaultTTLMilliseconds,
            maximumTTLMilliseconds)
        self.minimumPollIntervalMilliseconds = max(
            50,
            minimumPollIntervalMilliseconds)
        self.maximumPollIntervalMilliseconds = max(
            self.minimumPollIntervalMilliseconds,
            maximumPollIntervalMilliseconds)
        self.maximumTasks = max(1, maximumTasks)
        self.listPageSize = max(1, min(500, listPageSize))
        self.maximumResultBytes = max(1_024, maximumResultBytes)
    }
}

public enum MCPTaskRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProfile
    case capabilityMissing
    case tooManyTasks
    case taskNotFound
    case taskExpired
    case taskAlreadyMapped
    case taskNotMapped
    case scopeMismatch
    case malformedTask(String)
    case invalidTransition(from: MCPTaskState, to: MCPTaskState)
    case conflictingTerminal
    case notTerminal
    case resultUnavailable
    case cancelled
    case timedOut
    case failed
    case invalidCursor
    case resultTooLarge
    case relatedTaskMetadataMissing
    case relatedTaskMetadataMismatch
    case persistenceFailed
    case transportFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile:
            return "Experimental MCP tasks require the standard-extended profile."
        case .capabilityMissing:
            return "The exact peer generation does not advertise this MCP task operation."
        case .tooManyTasks:
            return "The MCP task limit was reached."
        case .taskNotFound:
            return "The MCP task was not found in this authority."
        case .taskExpired:
            return "The MCP task has expired."
        case .taskAlreadyMapped:
            return "The MCP task already has a remote mapping."
        case .taskNotMapped:
            return "The MCP task has no remote mapping."
        case .scopeMismatch:
            return "The MCP task belongs to a different authority or generation."
        case .malformedTask(let reason):
            return "The MCP task payload is invalid: \(reason)"
        case .invalidTransition(let from, let to):
            return "Invalid MCP task transition \(from.rawValue) → \(to.rawValue)."
        case .conflictingTerminal:
            return "The MCP task already has a different terminal state."
        case .notTerminal:
            return "The MCP task is not terminal."
        case .resultUnavailable:
            return "The MCP task result is unavailable."
        case .cancelled:
            return "The MCP task was cancelled."
        case .timedOut:
            return "The MCP task exceeded its bounded wait deadline."
        case .failed:
            return "The MCP task failed."
        case .invalidCursor:
            return "The MCP task list cursor is invalid for this authority."
        case .resultTooLarge:
            return "The MCP task result exceeds the protected payload limit."
        case .relatedTaskMetadataMissing:
            return "The MCP task result is missing related-task metadata."
        case .relatedTaskMetadataMismatch:
            return "The MCP task result references a different task."
        case .persistenceFailed:
            return "The MCP task lifecycle could not be persisted."
        case .transportFailed:
            return "The exact MCP task transport operation failed."
        }
    }
}

private extension MCPTaskState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .requested, .working, .inputRequired:
            return false
        }
    }
}

private extension MCPTaskStatus {
    var protocolState: MCPTaskState {
        switch self {
        case .working:
            return .working
        case .inputRequired:
            return .inputRequired
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }
}

private extension MCPTaskState {
    var SDKStatus: MCPTaskStatus {
        switch self {
        case .requested, .working:
            return .working
        case .inputRequired:
            return .inputRequired
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }
}

// MARK: - Remote-server-owned tasks

public struct MCPRemoteTaskAuthority: Codable, Equatable, Hashable, Sendable {
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let authorityFingerprint: String

    public init(
        server: MCPServerReference,
        connectionGeneration: MCPConnectionGeneration,
        authorityFingerprint: String
    ) {
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.authorityFingerprint = authorityFingerprint
    }
}

public struct MCPRemoteTaskSnapshot: Codable, Equatable, Sendable {
    public let taskID: MCPRemoteServerTaskID
    public let authority: MCPRemoteTaskAuthority
    public let operation: MCPRemoteTaskOperation
    public let originatingToolCallID: String?
    public let remoteIDReference: MCPResultReference?
    public let state: MCPTaskState
    public let stateRevision: Int
    public let createdAt: Date
    public let lastUpdatedAt: Date
    public let expiresAt: Date?
    public let pollIntervalMilliseconds: Int?
    public let resultReference: MCPResultReference?
    public let durablySettled: Bool

    public init(
        taskID: MCPRemoteServerTaskID,
        authority: MCPRemoteTaskAuthority,
        operation: MCPRemoteTaskOperation,
        originatingToolCallID: String?,
        remoteIDReference: MCPResultReference?,
        state: MCPTaskState,
        stateRevision: Int,
        createdAt: Date,
        lastUpdatedAt: Date,
        expiresAt: Date?,
        pollIntervalMilliseconds: Int?,
        resultReference: MCPResultReference?,
        durablySettled: Bool = false
    ) {
        self.taskID = taskID
        self.authority = authority
        self.operation = operation
        self.originatingToolCallID = originatingToolCallID
        self.remoteIDReference = remoteIDReference
        self.state = state
        self.stateRevision = stateRevision
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.expiresAt = expiresAt
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.resultReference = resultReference
        self.durablySettled = durablySettled
    }
}

public protocol MCPRemoteTaskClient: Sendable {
    func getRemoteTask(
        _ remoteTaskID: String,
        timeoutMilliseconds: Int?
    ) async throws -> MCPTaskWire
    func getRemoteTaskResult(
        _ remoteTaskID: String,
        timeoutMilliseconds: Int?
    ) async throws -> Value
    func cancelRemoteTask(
        _ remoteTaskID: String,
        timeoutMilliseconds: Int?
    ) async throws -> MCPTaskWire
}

/// Requestor-side state machine for tasks owned by an external MCP server.
/// Every network method performs one exact-generation operation and never
/// retries an operation whose side effects may already exist.
public actor MCPRemoteTaskManager {
    private let authority: MCPRemoteTaskAuthority
    private let profile: MCPProtocolProfile
    private var supportsGetAndResult: Bool
    private var supportsCancel: Bool
    private let policy: MCPTaskRuntimePolicy
    private let events: any MCPBrokerEventSink
    private let payloadStore: any MCPBrokerPayloadStore
    private var records: [MCPRemoteServerTaskID: MCPRemoteTaskSnapshot] = [:]

    public init(
        authority: MCPRemoteTaskAuthority,
        profile: MCPProtocolProfile,
        supportsGetAndResult: Bool,
        supportsCancel: Bool,
        policy: MCPTaskRuntimePolicy = .init(),
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore
    ) {
        self.authority = authority
        self.profile = profile
        self.supportsGetAndResult = supportsGetAndResult
        self.supportsCancel = supportsCancel
        self.policy = policy
        self.events = events
        self.payloadStore = payloadStore
    }

    /// Freezes the task sub-capabilities selected by the completed initialize
    /// handshake before this generation can execute a task operation.
    ///
    /// The production factory creates the exact-authority manager before
    /// initialize so status notification routing exists for the generation,
    /// but starts it with both flags false. Startup then calls this once with
    /// the negotiated server surface. A later notification cannot widen it.
    public func applyNegotiatedCapabilities(
        supportsGetAndResult: Bool,
        supportsCancel: Bool
    ) throws {
        guard records.isEmpty else {
            throw MCPTaskRuntimeError.scopeMismatch
        }
        self.supportsGetAndResult = supportsGetAndResult
        self.supportsCancel = supportsCancel
    }

    /// Creates the host identity and durable request fact before dispatching a
    /// task-augmented operation. It does not perform network I/O.
    public func begin(
        operation: MCPRemoteTaskOperation,
        requestPayload: Data,
        originatingToolCallID: String? = nil,
        correlation: MCPEventCorrelation = .init(),
        now: Date = Date()
    ) async throws -> MCPRemoteServerTaskID {
        guard profile == .standardExtended else {
            throw MCPTaskRuntimeError.unsupportedProfile
        }
        guard operation == .toolCall else {
            // The exhaustive 2025-11-25 server task capability contains only
            // requests.tools.call. Resources/prompts/completions are ordinary
            // requests in this protocol revision.
            throw MCPTaskRuntimeError.capabilityMissing
        }
        try await cleanupExpired(now: now)
        guard records.count < policy.maximumTasks else {
            throw MCPTaskRuntimeError.tooManyTasks
        }
        let taskID = MCPRemoteServerTaskID.new()
        let snapshot = MCPRemoteTaskSnapshot(
            taskID: taskID,
            authority: authority,
            operation: operation,
            originatingToolCallID: originatingToolCallID,
            remoteIDReference: nil,
            state: .requested,
            stateRevision: 0,
            createdAt: now,
            lastUpdatedAt: now,
            expiresAt: now.addingTimeInterval(
                Double(policy.defaultTTLMilliseconds) / 1_000),
            pollIntervalMilliseconds: nil,
            resultReference: nil,
            durablySettled: false)
        let fingerprint = Self.fingerprint(requestPayload)
        do {
            try await events.appendMCPBrokerEvent(
                .mcpRemoteTaskRequested(.init(
                    taskID: taskID,
                    server: authority.server,
                    connectionGeneration: authority.connectionGeneration,
                    operation: operation,
                    request: fingerprint,
                    correlation: correlation)))
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        records[taskID] = snapshot
        return taskID
    }

    /// Commits the receiver-issued opaque ID into protected storage and
    /// publishes the first remote state. The raw ID never enters EventLog.
    public func acceptCreation(
        taskID: MCPRemoteServerTaskID,
        task: MCPTaskWire,
        now: Date = Date()
    ) async throws {
        guard var record = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        guard record.remoteIDReference == nil else {
            throw MCPTaskRuntimeError.taskAlreadyMapped
        }
        let validated = try validateWireTask(task, now: now)
        guard validated.state == .working else {
            throw MCPTaskRuntimeError.malformedTask(
                "newly created task did not begin in working status")
        }
        let scope = remoteIDScope(taskID)
        let remoteReference: MCPResultReference
        do {
            remoteReference = try await payloadStore.store(
                Data(task.taskId.utf8),
                scopeFingerprint: scope)
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        let nextRevision = record.stateRevision + 1
        let next = MCPRemoteTaskSnapshot(
            taskID: record.taskID,
            authority: record.authority,
            operation: record.operation,
            originatingToolCallID: record.originatingToolCallID,
            remoteIDReference: remoteReference,
            state: validated.state,
            stateRevision: nextRevision,
            createdAt: record.createdAt,
            lastUpdatedAt: now,
            expiresAt: validated.expiresAt,
            pollIntervalMilliseconds: validated.pollInterval,
            resultReference: record.resultReference,
            durablySettled: validated.state == .cancelled)
        let mappedFingerprint = Self.fingerprint(Data(task.taskId.utf8))
        do {
            var durable: [Event] = [
                .mcpRemoteTaskMapped(.init(
                    taskID: taskID,
                    remoteTaskReference: mappedFingerprint)),
                .mcpRemoteTaskStateChanged(.init(
                    taskID: taskID,
                    state: next.state,
                    stateRevision: nextRevision)),
            ]
            if validated.state == .cancelled {
                durable.append(.mcpRemoteTaskSettled(.init(
                    taskID: taskID,
                    status: .cancelled)))
            }
            try await events.appendMCPBrokerEvents(durable)
        } catch {
            try? await payloadStore.remove(
                remoteReference,
                scopeFingerprint: scope)
            throw MCPTaskRuntimeError.persistenceFailed
        }
        record = next
        records[taskID] = record
    }

    /// Settles the host identity when an initial task-augmented request ended
    /// without a receiver-issued task ID. No remote cancellation is
    /// fabricated; the durable terminal explicitly preserves uncertainty.
    public func settleUnmappedCreation(
        taskID: MCPRemoteServerTaskID,
        status: MCPDurableTerminalStatus = .uncertain,
        now: Date = Date()
    ) async throws {
        guard var record = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        guard record.remoteIDReference == nil else {
            throw MCPTaskRuntimeError.taskAlreadyMapped
        }
        if record.durablySettled { return }
        let next = MCPRemoteTaskSnapshot(
            taskID: record.taskID,
            authority: record.authority,
            operation: record.operation,
            originatingToolCallID: record.originatingToolCallID,
            remoteIDReference: nil,
            state: .failed,
            stateRevision: record.stateRevision + 1,
            createdAt: record.createdAt,
            lastUpdatedAt: now,
            expiresAt: record.expiresAt,
            pollIntervalMilliseconds: nil,
            resultReference: nil,
            durablySettled: true)
        do {
            try await events.appendMCPBrokerEvents([
                .mcpRemoteTaskStateChanged(.init(
                    taskID: taskID,
                    state: .failed,
                    stateRevision: next.stateRevision)),
                .mcpRemoteTaskSettled(.init(
                    taskID: taskID,
                    status: status,
                    diagnostic: .init(
                        code: "remote_task_unmapped",
                        summary:
                            "The task-augmented request ended before a remote task ID was received."))),
            ])
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        record = next
        records[taskID] = record
    }

    public func snapshot(
        _ taskID: MCPRemoteServerTaskID,
        now: Date = Date()
    ) async throws -> MCPRemoteTaskSnapshot {
        guard let record = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        return record
    }

    public func snapshots(now: Date = Date()) async throws
        -> [MCPRemoteTaskSnapshot]
    {
        try await cleanupExpired(now: now)
        return records.values.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.taskID.rawValue < $1.taskID.rawValue
        }
    }

    /// Cold restore only reconstructs protected mappings and states. It does
    /// not poll, reconnect, call a provider, or continue user interaction.
    public func restore(
        _ snapshots: [MCPRemoteTaskSnapshot],
        now: Date = Date()
    ) throws {
        var restored: [MCPRemoteServerTaskID: MCPRemoteTaskSnapshot] = [:]
        for snapshot in snapshots {
            guard snapshot.authority == authority else {
                throw MCPTaskRuntimeError.scopeMismatch
            }
            guard snapshot.stateRevision >= 0 else {
                throw MCPTaskRuntimeError.malformedTask(
                    "negative state revision")
            }
            if let expiresAt = snapshot.expiresAt, expiresAt <= now {
                continue
            }
            guard restored[snapshot.taskID] == nil else {
                throw MCPTaskRuntimeError.malformedTask(
                    "duplicate host task identity")
            }
            restored[snapshot.taskID] = snapshot
        }
        records = restored
    }

    /// Explicit Resume obtains the list of non-terminal mappings. Merely
    /// restoring or inspecting the manager never calls this method for users.
    public func explicitResumeCandidates(
        now: Date = Date()
    ) async throws -> [MCPRemoteServerTaskID] {
        try await cleanupExpired(now: now)
        return records.values
            .filter { !$0.state.isTerminal && $0.remoteIDReference != nil }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.taskID.rawValue < $1.taskID.rawValue
            }
            .map(\.taskID)
    }

    @discardableResult
    public func refresh(
        _ taskID: MCPRemoteServerTaskID,
        client: any MCPRemoteTaskClient,
        timeoutMilliseconds: Int? = nil,
        now: Date = Date()
    ) async throws -> MCPRemoteTaskSnapshot {
        guard supportsGetAndResult else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        let remoteID = try await resolveRemoteID(taskID, now: now)
        let wire: MCPTaskWire
        do {
            wire = try await client.getRemoteTask(
                remoteID,
                timeoutMilliseconds: timeoutMilliseconds)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MCPTaskRuntimeError.transportFailed
        }
        guard wire.taskId == remoteID else {
            throw MCPTaskRuntimeError.scopeMismatch
        }
        return try await applyWireUpdate(
            taskID: taskID,
            wire: wire,
            now: now)
    }

    @discardableResult
    public func cancel(
        _ taskID: MCPRemoteServerTaskID,
        client: any MCPRemoteTaskClient,
        timeoutMilliseconds: Int? = nil,
        now: Date = Date()
    ) async throws -> MCPRemoteTaskSnapshot {
        guard supportsCancel else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        guard let current = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        if current.state.isTerminal {
            return current
        }
        let remoteID = try await resolveRemoteID(taskID, now: now)
        let wire: MCPTaskWire
        do {
            // Task cancellation uses tasks/cancel, never
            // notifications/cancelled.
            wire = try await client.cancelRemoteTask(
                remoteID,
                timeoutMilliseconds: timeoutMilliseconds)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MCPTaskRuntimeError.transportFailed
        }
        guard wire.taskId == remoteID else {
            throw MCPTaskRuntimeError.scopeMismatch
        }
        return try await applyWireUpdate(
            taskID: taskID,
            wire: wire,
            now: now)
    }

    /// Applies an advisory `notifications/tasks/status` update to the one
    /// protected mapping whose opaque remote ID matches. Unknown IDs are
    /// ignored; callers still use bounded polling and never rely on
    /// notifications as the sole state source.
    @discardableResult
    public func observeStatusNotification(
        _ wire: MCPTaskWire,
        now: Date = Date()
    ) async throws -> MCPRemoteTaskSnapshot? {
        guard supportsGetAndResult else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        try await cleanupExpired(now: now)
        let candidates = records.values
            .filter { $0.remoteIDReference != nil }
            .sorted { $0.taskID.rawValue < $1.taskID.rawValue }
        for candidate in candidates {
            let remoteID = try await resolveRemoteID(
                candidate.taskID,
                now: now)
            guard remoteID == wire.taskId else { continue }
            return try await applyWireUpdate(
                taskID: candidate.taskID,
                wire: wire,
                now: now)
        }
        return nil
    }

    /// Performs one `tasks/result` operation. It is never automatically
    /// replayed after disconnect or an ambiguous transport failure.
    public func retrieveResult(
        _ taskID: MCPRemoteServerTaskID,
        client: any MCPRemoteTaskClient,
        timeoutMilliseconds: Int? = nil,
        now: Date = Date()
    ) async throws -> Value {
        guard supportsGetAndResult else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        let remoteID = try await resolveRemoteID(taskID, now: now)
        let value: Value
        if let existingReference = recordResultReference(
            taskID,
            now: now) {
            let stored = try await payloadStore.resolve(
                existingReference,
                scopeFingerprint: resultScope(taskID))
            return try JSONDecoder().decode(Value.self, from: stored)
        }
        do {
            value = try await client.getRemoteTaskResult(
                remoteID,
                timeoutMilliseconds: timeoutMilliseconds)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MCPTaskRuntimeError.transportFailed
        }
        try Self.validateRelatedTaskMetadata(
            value,
            expectedRemoteTaskID: remoteID)
        let data = try JSONEncoder().encode(value)
        guard data.count <= policy.maximumResultBytes else {
            throw MCPTaskRuntimeError.resultTooLarge
        }
        guard var record = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        guard record.state != .cancelled else {
            throw MCPTaskRuntimeError.cancelled
        }
        guard record.state != .requested else {
            throw MCPTaskRuntimeError.taskNotMapped
        }
        guard !record.durablySettled else {
            throw MCPTaskRuntimeError.conflictingTerminal
        }
        let reference: MCPResultReference
        do {
            reference = try await payloadStore.store(
                data,
                scopeFingerprint: resultScope(taskID))
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        let targetState: MCPTaskState =
            record.state == .failed ? .failed : .completed
        try Self.validateTransition(
            from: record.state,
            to: targetState)
        let stateChanged = record.state != targetState
        let nextRevision = record.stateRevision
            + (stateChanged ? 1 : 0)
        let next = MCPRemoteTaskSnapshot(
            taskID: record.taskID,
            authority: record.authority,
            operation: record.operation,
            originatingToolCallID: record.originatingToolCallID,
            remoteIDReference: record.remoteIDReference,
            state: targetState,
            stateRevision: nextRevision,
            createdAt: record.createdAt,
            lastUpdatedAt: now,
            expiresAt: record.expiresAt,
            pollIntervalMilliseconds: record.pollIntervalMilliseconds,
            resultReference: reference,
            durablySettled: true)
        do {
            var durable: [Event] = []
            if stateChanged {
                durable.append(.mcpRemoteTaskStateChanged(.init(
                    taskID: taskID,
                    state: targetState,
                    stateRevision: nextRevision)))
            }
            durable.append(.mcpRemoteTaskSettled(.init(
                taskID: taskID,
                status: Self.terminalStatus(next.state),
                resultReference: reference)))
            try await events.appendMCPBrokerEvents(durable)
        } catch {
            try? await payloadStore.remove(
                reference,
                scopeFingerprint: resultScope(taskID))
            throw MCPTaskRuntimeError.persistenceFailed
        }
        record = next
        records[taskID] = record
        return value
    }

    private func applyWireUpdate(
        taskID: MCPRemoteServerTaskID,
        wire: MCPTaskWire,
        now: Date
    ) async throws -> MCPRemoteTaskSnapshot {
        guard let record = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        let validated = try validateWireTask(wire, now: now)
        try Self.validateTransition(
            from: record.state,
            to: validated.state)
        if record.state.isTerminal {
            guard record.state == validated.state else {
                throw MCPTaskRuntimeError.conflictingTerminal
            }
            return record
        }
        let nextRevision = record.stateRevision + 1
        let next = MCPRemoteTaskSnapshot(
            taskID: record.taskID,
            authority: record.authority,
            operation: record.operation,
            originatingToolCallID: record.originatingToolCallID,
            remoteIDReference: record.remoteIDReference,
            state: validated.state,
            stateRevision: nextRevision,
            createdAt: record.createdAt,
            lastUpdatedAt: now,
            expiresAt: validated.expiresAt,
            pollIntervalMilliseconds: validated.pollInterval,
            resultReference: record.resultReference,
            durablySettled: record.durablySettled
                || validated.state == .cancelled)
        do {
            var durable: [Event] = [
                .mcpRemoteTaskStateChanged(.init(
                    taskID: taskID,
                    state: next.state,
                    stateRevision: nextRevision)),
            ]
            if next.state == .cancelled {
                durable.append(.mcpRemoteTaskSettled(.init(
                    taskID: taskID,
                    status: Self.terminalStatus(next.state))))
            }
            try await events.appendMCPBrokerEvents(durable)
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        records[taskID] = next
        return next
    }

    private func resolveRemoteID(
        _ taskID: MCPRemoteServerTaskID,
        now: Date
    ) async throws -> String {
        guard let record = try activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        guard let reference = record.remoteIDReference else {
            throw MCPTaskRuntimeError.taskNotMapped
        }
        let data: Data
        do {
            data = try await payloadStore.resolve(
                reference,
                scopeFingerprint: remoteIDScope(taskID))
        } catch {
            throw MCPTaskRuntimeError.taskNotMapped
        }
        guard data.count <= 4_096,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw MCPTaskRuntimeError.malformedTask(
                "protected remote task ID is invalid")
        }
        return value
    }

    private func activeRecord(
        _ taskID: MCPRemoteServerTaskID,
        now: Date
    ) throws -> MCPRemoteTaskSnapshot? {
        guard let record = records[taskID] else {
            return nil
        }
        guard record.authority == authority else {
            throw MCPTaskRuntimeError.scopeMismatch
        }
        if let expiresAt = record.expiresAt, expiresAt <= now {
            throw MCPTaskRuntimeError.taskExpired
        }
        return record
    }

    private func recordResultReference(
        _ taskID: MCPRemoteServerTaskID,
        now: Date
    ) -> MCPResultReference? {
        guard let record = records[taskID],
              record.authority == authority,
              record.expiresAt.map({ $0 > now }) ?? true else {
            return nil
        }
        return record.resultReference
    }

    private func cleanupExpired(now: Date) async throws {
        let expired = records.values.filter {
            if let expiresAt = $0.expiresAt {
                return expiresAt <= now
            }
            return false
        }
        for record in expired {
            if let remote = record.remoteIDReference {
                try? await payloadStore.remove(
                    remote,
                    scopeFingerprint: remoteIDScope(record.taskID))
            }
            if let result = record.resultReference {
                try? await payloadStore.remove(
                    result,
                    scopeFingerprint: resultScope(record.taskID))
            }
            records[record.taskID] = nil
        }
    }

    private func validateWireTask(
        _ task: MCPTaskWire,
        now: Date
    ) throws -> (
        state: MCPTaskState,
        expiresAt: Date?,
        pollInterval: Int?
    ) {
        guard !task.taskId.isEmpty,
              task.taskId.utf8.count <= 4_096,
              Self.parseDate(task.createdAt) != nil,
              Self.parseDate(task.lastUpdatedAt) != nil else {
            throw MCPTaskRuntimeError.malformedTask(
                "identity or timestamps are invalid")
        }
        if let ttl = task.ttl, ttl < 0 {
            throw MCPTaskRuntimeError.malformedTask("negative TTL")
        }
        if let pollInterval = task.pollInterval, pollInterval < 0 {
            throw MCPTaskRuntimeError.malformedTask(
                "negative poll interval")
        }
        let boundedTTL = min(
            task.ttl ?? policy.maximumTTLMilliseconds,
            policy.maximumTTLMilliseconds)
        let expiresAt = task.ttl == nil
            ? now.addingTimeInterval(
                Double(policy.maximumTTLMilliseconds) / 1_000)
            : now.addingTimeInterval(Double(boundedTTL) / 1_000)
        let poll = task.pollInterval.map {
            max(
                policy.minimumPollIntervalMilliseconds,
                min(policy.maximumPollIntervalMilliseconds, $0))
        }
        return (task.status.protocolState, expiresAt, poll)
    }

    private func remoteIDScope(
        _ taskID: MCPRemoteServerTaskID
    ) -> String {
        scopePrefix(taskID) + "\u{1f}remote-id"
    }

    private func resultScope(
        _ taskID: MCPRemoteServerTaskID
    ) -> String {
        scopePrefix(taskID) + "\u{1f}result"
    }

    private func scopePrefix(
        _ taskID: MCPRemoteServerTaskID
    ) -> String {
        [
            "remote-task",
            authority.server.serverID.rawValue,
            authority.server.serverRevision.rawValue,
            authority.connectionGeneration.rawValue,
            authority.authorityFingerprint,
            taskID.rawValue,
        ].joined(separator: "\u{1f}")
    }

    private static func validateTransition(
        from: MCPTaskState,
        to: MCPTaskState
    ) throws {
        if from == to { return }
        if from.isTerminal {
            throw MCPTaskRuntimeError.conflictingTerminal
        }
        switch (from, to) {
        case (.requested, .working),
             (.requested, .inputRequired),
             (.requested, .completed),
             (.requested, .failed),
             (.requested, .cancelled),
             (.working, .inputRequired),
             (.working, .completed),
             (.working, .failed),
             (.working, .cancelled),
             (.inputRequired, .working),
             (.inputRequired, .completed),
             (.inputRequired, .failed),
             (.inputRequired, .cancelled):
            return
        default:
            throw MCPTaskRuntimeError.invalidTransition(
                from: from,
                to: to)
        }
    }

    private static func validateRelatedTaskMetadata(
        _ value: Value,
        expectedRemoteTaskID: String
    ) throws {
        guard case .object(let object) = value,
              case .object(let metadata)? = object["_meta"],
              case .object(let related)? =
                metadata[MCPRelatedTaskMetadataKey],
              let taskID = related["taskId"]?.stringValue else {
            throw MCPTaskRuntimeError.relatedTaskMetadataMissing
        }
        guard taskID == expectedRemoteTaskID else {
            throw MCPTaskRuntimeError.relatedTaskMetadataMismatch
        }
    }

    private static func terminalStatus(
        _ state: MCPTaskState
    ) -> MCPDurableTerminalStatus {
        switch state {
        case .completed:
            return .succeeded
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .requested, .working, .inputRequired:
            return .uncertain
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func fingerprint(
        _ data: Data
    ) -> MCPPayloadFingerprint {
        MCPPayloadFingerprint(
            sha256: MCPConfigurationCanonical.sha256(data),
            characterCount: String(decoding: data, as: UTF8.self).count)
    }
}

// MARK: - Client-hosted callback tasks

public protocol MCPClientTaskNotificationSink: Sendable {
    func notifyClientHostedTaskStatus(_ task: MCPTaskWire) async
}

public struct MCPNoopClientTaskNotificationSink:
    MCPClientTaskNotificationSink
{
    public init() {}

    public func notifyClientHostedTaskStatus(_ task: MCPTaskWire) async {}
}

public struct MCPClientHostedTaskSnapshot: Codable, Equatable, Sendable {
    public let taskID: MCPClientHostedTaskID
    public let kind: MCPClientTaskKind
    public let state: MCPTaskState
    public let stateRevision: Int
    public let createdAt: Date
    public let lastUpdatedAt: Date
    public let ttlMilliseconds: Int?
    public let expiresAt: Date?
    public let resultReference: MCPResultReference?

    public init(
        taskID: MCPClientHostedTaskID,
        kind: MCPClientTaskKind,
        state: MCPTaskState,
        stateRevision: Int,
        createdAt: Date,
        lastUpdatedAt: Date,
        ttlMilliseconds: Int?,
        expiresAt: Date?,
        resultReference: MCPResultReference?
    ) {
        self.taskID = taskID
        self.kind = kind
        self.state = state
        self.stateRevision = stateRevision
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.ttlMilliseconds = ttlMilliseconds
        self.expiresAt = expiresAt
        self.resultReference = resultReference
    }
}

/// Receiver-side state machine for task-augmented sampling and elicitation
/// callbacks. It is scoped to one exact connection authority and owns every
/// operation task so cancellation and shutdown can drain them.
public actor MCPClientHostedTaskManager {
    private struct Record {
        var snapshot: MCPClientHostedTaskSnapshot
        var operation: Task<Void, Never>?
        var terminalError: MCPTaskRuntimeError?
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
    }

    private let authority: MCPCallbackAuthorityContext
    private let supportsList: Bool
    private let supportsCancel: Bool
    private let supportsSampling: Bool
    private let supportsElicitation: Bool
    private let policy: MCPTaskRuntimePolicy
    private let events: any MCPBrokerEventSink
    private let payloadStore: any MCPBrokerPayloadStore
    private let notifications: any MCPClientTaskNotificationSink
    private var records: [MCPClientHostedTaskID: Record] = [:]
    private var waiters: [MCPClientHostedTaskID: [Waiter]] = [:]
    private var stopping = false

    public init(
        authority: MCPCallbackAuthorityContext,
        supportsList: Bool,
        supportsCancel: Bool,
        supportsSampling: Bool,
        supportsElicitation: Bool,
        policy: MCPTaskRuntimePolicy = .init(),
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore,
        notifications: any MCPClientTaskNotificationSink =
            MCPNoopClientTaskNotificationSink()
    ) {
        self.authority = authority
        self.supportsList = supportsList
        self.supportsCancel = supportsCancel
        self.supportsSampling = supportsSampling
        self.supportsElicitation = supportsElicitation
        self.policy = policy
        self.events = events
        self.payloadStore = payloadStore
        self.notifications = notifications
    }

    public func createSamplingTask(
        parameters: CreateSamplingMessage.Parameters,
        broker: MCPSamplingBroker,
        flowID: MCPSamplingFlowID = .new(),
        correlation: MCPEventCorrelation = .init(),
        now: Date = Date()
    ) async throws -> CreateSamplingMessage.Result {
        guard supportsSampling else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        let data = try JSONEncoder().encode(parameters)
        let wire = try await create(
            kind: .sampling,
            taskMetadata: parameters.task,
            requestPayload: data,
            correlation: correlation,
            requiresUserInput: true,
            now: now
        ) {
            let result = try await broker.handle(
                parameters,
                flowID: flowID,
                correlation: correlation)
            return try JSONEncoder().encode(result)
        }
        return CreateSamplingMessage.Result(task: wire)
    }

    public func createElicitationTask(
        parameters: CreateElicitation.Parameters,
        broker: MCPElicitationBroker,
        correlation: MCPEventCorrelation = .init(),
        now: Date = Date()
    ) async throws -> CreateElicitation.Result {
        guard supportsElicitation else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        let taskMetadata: MCPTaskMetadata?
        switch parameters {
        case .form(let form):
            taskMetadata = form.task
        case .url(let URLParameters):
            taskMetadata = URLParameters.task
        }
        let data = try JSONEncoder().encode(parameters)
        let wire = try await create(
            kind: .elicitation,
            taskMetadata: taskMetadata,
            requestPayload: data,
            correlation: correlation,
            requiresUserInput: true,
            now: now
        ) {
            let result = try await broker.handle(
                parameters,
                correlation: correlation)
            return try JSONEncoder().encode(result)
        }
        return CreateElicitation.Result(task: wire)
    }

    /// Generic seam used by conformance fixtures and future stable callback
    /// categories without coupling this state machine to AgentLoop.
    public func create(
        kind: MCPClientTaskKind,
        taskMetadata: MCPTaskMetadata?,
        requestPayload: Data,
        correlation: MCPEventCorrelation = .init(),
        requiresUserInput: Bool,
        now: Date = Date(),
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> MCPTaskWire {
        guard authority.profile == .standardExtended else {
            throw MCPTaskRuntimeError.unsupportedProfile
        }
        guard !stopping else {
            throw MCPTaskRuntimeError.cancelled
        }
        try await cleanupExpired(now: now)
        guard records.count < policy.maximumTasks else {
            throw MCPTaskRuntimeError.tooManyTasks
        }
        let requestedTTL = taskMetadata?.ttl
        if let requestedTTL, requestedTTL < 0 {
            throw MCPTaskRuntimeError.malformedTask("negative TTL")
        }
        let ttl = min(
            requestedTTL ?? policy.defaultTTLMilliseconds,
            policy.maximumTTLMilliseconds)
        let taskID = MCPClientHostedTaskID.new()
        let initialState: MCPTaskState = requiresUserInput
            ? .inputRequired
            : .working
        let snapshot = MCPClientHostedTaskSnapshot(
            taskID: taskID,
            kind: kind,
            state: initialState,
            stateRevision: 1,
            createdAt: now,
            lastUpdatedAt: now,
            ttlMilliseconds: ttl,
            expiresAt: now.addingTimeInterval(Double(ttl) / 1_000),
            resultReference: nil)
        let fingerprint = MCPPayloadFingerprint(
            sha256: MCPConfigurationCanonical.sha256(requestPayload),
            characterCount: String(
                decoding: requestPayload,
                as: UTF8.self).count)
        do {
            try await events.appendMCPBrokerEvents([
                .mcpClientTaskRequested(.init(
                    taskID: taskID,
                    kind: kind,
                    server: authority.server,
                    connectionGeneration: authority.connectionGeneration,
                    request: fingerprint,
                    correlation: correlation)),
                .mcpClientTaskStateChanged(.init(
                    taskID: taskID,
                    state: initialState,
                    stateRevision: 1)),
            ])
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        records[taskID] = Record(
            snapshot: snapshot,
            operation: nil,
            terminalError: nil)

        let owned = Task { [weak self] in
            do {
                let data = try await operation()
                await self?.finish(
                    taskID: taskID,
                    result: .success(data),
                    now: Date())
            } catch is CancellationError {
                await self?.finish(
                    taskID: taskID,
                    result: .failure(.cancelled),
                    now: Date())
            } catch {
                await self?.finish(
                    taskID: taskID,
                    result: .failure(.failed),
                    now: Date())
            }
        }
        records[taskID]?.operation = owned
        let wire = Self.wire(snapshot)
        await notifications.notifyClientHostedTaskStatus(wire)
        return wire
    }

    public func get(
        taskID rawValue: String,
        now: Date = Date()
    ) async throws -> MCPTaskWire {
        let taskID = MCPClientHostedTaskID(rawValue: rawValue)
        guard let record = try await activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        return Self.wire(record.snapshot)
    }

    public func list(
        cursor: String?,
        now: Date = Date()
    ) async throws -> ListTasks.Result {
        guard supportsList else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        try await cleanupExpired(now: now)
        let ordered = records.values.map(\.snapshot).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.taskID.rawValue < $1.taskID.rawValue
        }
        let start = try decodeCursor(cursor)
        guard start <= ordered.count else {
            throw MCPTaskRuntimeError.invalidCursor
        }
        let end = min(start + policy.listPageSize, ordered.count)
        let nextCursor = end < ordered.count ? encodeCursor(end) : nil
        return ListTasks.Result(
            tasks: ordered[start..<end].map(Self.wire),
            nextCursor: nextCursor)
    }

    @discardableResult
    public func cancel(
        taskID rawValue: String,
        now: Date = Date()
    ) async throws -> MCPTaskWire {
        guard supportsCancel else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        let taskID = MCPClientHostedTaskID(rawValue: rawValue)
        guard let record = try await activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        if record.snapshot.state.isTerminal {
            return Self.wire(record.snapshot)
        }
        record.operation?.cancel()
        try await claimTerminal(
            taskID: taskID,
            state: .cancelled,
            resultReference: nil,
            error: .cancelled,
            now: now)
        guard let settled = records[taskID] else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        return Self.wire(settled.snapshot)
    }

    /// Implements blocking `tasks/result`. Cancellation removes only this
    /// waiter; it does not cancel the hosted task unless the requestor
    /// separately invokes `tasks/cancel`.
    public func result(
        taskID rawValue: String,
        now: Date = Date()
    ) async throws -> Value {
        let taskID = MCPClientHostedTaskID(rawValue: rawValue)
        guard let record = try await activeRecord(taskID, now: now) else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        if record.snapshot.state.isTerminal {
            return try await terminalValue(
                record,
                taskID: taskID)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Value, Error>) in
                if Task.isCancelled {
                    continuation.resume(
                        throwing: CancellationError())
                    return
                }
                waiters[taskID, default: []].append(Waiter(
                    id: waiterID,
                    continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    taskID: taskID,
                    waiterID: waiterID)
            }
        }
    }

    /// Reconciles cold-start active callback tasks without running their
    /// original provider/user flow. Active tasks become failed; terminal facts
    /// remain terminal. No operation is resumed.
    public func restore(
        _ snapshots: [MCPClientHostedTaskSnapshot],
        now: Date = Date()
    ) async throws {
        guard records.isEmpty else {
            throw MCPTaskRuntimeError.malformedTask(
                "restore requires an empty live manager")
        }
        for snapshot in snapshots {
            if let expiresAt = snapshot.expiresAt, expiresAt <= now {
                continue
            }
            var restored = snapshot
            var terminalError: MCPTaskRuntimeError?
            if !snapshot.state.isTerminal {
                restored = MCPClientHostedTaskSnapshot(
                    taskID: snapshot.taskID,
                    kind: snapshot.kind,
                    state: .failed,
                    stateRevision: snapshot.stateRevision + 1,
                    createdAt: snapshot.createdAt,
                    lastUpdatedAt: now,
                    ttlMilliseconds: snapshot.ttlMilliseconds,
                    expiresAt: snapshot.expiresAt,
                    resultReference: nil)
                terminalError = .failed
                do {
                    try await events.appendMCPBrokerEvents([
                        .mcpClientTaskStateChanged(.init(
                            taskID: restored.taskID,
                            state: .failed,
                            stateRevision: restored.stateRevision)),
                        .mcpClientTaskSettled(.init(
                            taskID: restored.taskID,
                            status: .failed,
                            diagnostic: .init(
                                code: "client_task_interrupted",
                                summary:
                                    "Client-hosted MCP callback could not be safely resumed after restart."))),
                    ])
                } catch {
                    throw MCPTaskRuntimeError.persistenceFailed
                }
            }
            records[restored.taskID] = Record(
                snapshot: restored,
                operation: nil,
                terminalError: terminalError)
        }
    }

    public func snapshots(now: Date = Date()) async throws
        -> [MCPClientHostedTaskSnapshot]
    {
        try await cleanupExpired(now: now)
        return records.values.map(\.snapshot).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.taskID.rawValue < $1.taskID.rawValue
        }
    }

    public func shutdown(now: Date = Date()) async {
        if stopping { return }
        stopping = true
        let active = records.values.compactMap(\.operation)
        for task in active {
            task.cancel()
        }
        for task in active {
            await task.value
        }
        let remaining = records.values
            .map(\.snapshot)
            .filter { !$0.state.isTerminal }
        for snapshot in remaining {
            try? await claimTerminal(
                taskID: snapshot.taskID,
                state: .cancelled,
                resultReference: nil,
                error: .cancelled,
                now: now)
        }
        for taskWaiters in waiters.values {
            for waiter in taskWaiters {
                waiter.continuation.resume(
                    throwing: CancellationError())
            }
        }
        waiters.removeAll(keepingCapacity: false)
    }

    private func finish(
        taskID: MCPClientHostedTaskID,
        result: Result<Data, MCPTaskRuntimeError>,
        now: Date
    ) async {
        guard let record = records[taskID],
              !record.snapshot.state.isTerminal else {
            return
        }
        switch result {
        case .success(let data):
            guard data.count <= policy.maximumResultBytes else {
                try? await claimTerminal(
                    taskID: taskID,
                    state: .failed,
                    resultReference: nil,
                    error: .resultTooLarge,
                    now: now)
                return
            }
            let reference: MCPResultReference
            do {
                reference = try await payloadStore.store(
                    data,
                    scopeFingerprint: hostedResultScope(taskID))
            } catch {
                try? await claimTerminal(
                    taskID: taskID,
                    state: .failed,
                    resultReference: nil,
                    error: .persistenceFailed,
                    now: now)
                return
            }
            do {
                try await claimTerminal(
                    taskID: taskID,
                    state: .completed,
                    resultReference: reference,
                    error: nil,
                    now: now)
            } catch {
                try? await payloadStore.remove(
                    reference,
                    scopeFingerprint: hostedResultScope(taskID))
            }
        case .failure(let error):
            try? await claimTerminal(
                taskID: taskID,
                state: error == .cancelled ? .cancelled : .failed,
                resultReference: nil,
                error: error,
                now: now)
        }
    }

    private func claimTerminal(
        taskID: MCPClientHostedTaskID,
        state: MCPTaskState,
        resultReference: MCPResultReference?,
        error: MCPTaskRuntimeError?,
        now: Date
    ) async throws {
        guard var record = records[taskID] else {
            throw MCPTaskRuntimeError.taskNotFound
        }
        guard state.isTerminal else {
            throw MCPTaskRuntimeError.malformedTask(
                "terminal claim used a non-terminal state")
        }
        if record.snapshot.state.isTerminal {
            guard record.snapshot.state == state,
                  record.snapshot.resultReference == resultReference else {
                throw MCPTaskRuntimeError.conflictingTerminal
            }
            return
        }
        let next = MCPClientHostedTaskSnapshot(
            taskID: record.snapshot.taskID,
            kind: record.snapshot.kind,
            state: state,
            stateRevision: record.snapshot.stateRevision + 1,
            createdAt: record.snapshot.createdAt,
            lastUpdatedAt: now,
            ttlMilliseconds: record.snapshot.ttlMilliseconds,
            expiresAt: record.snapshot.expiresAt,
            resultReference: resultReference)
        let durableStatus: MCPDurableTerminalStatus
        switch state {
        case .completed:
            durableStatus = .succeeded
        case .failed:
            durableStatus = .failed
        case .cancelled:
            durableStatus = .cancelled
        case .requested, .working, .inputRequired:
            durableStatus = .uncertain
        }
        do {
            try await events.appendMCPBrokerEvents([
                .mcpClientTaskStateChanged(.init(
                    taskID: taskID,
                    state: state,
                    stateRevision: next.stateRevision)),
                .mcpClientTaskSettled(.init(
                    taskID: taskID,
                    status: durableStatus,
                    resultReference: resultReference,
                    diagnostic: error.map {
                        MCPDiagnosticSummary(
                            code: "client_task_\($0)",
                            summary: $0.localizedDescription)
                    })),
            ])
        } catch {
            throw MCPTaskRuntimeError.persistenceFailed
        }
        record.snapshot = next
        record.terminalError = error
        record.operation = nil
        records[taskID] = record
        let wire = Self.wire(next)
        await notifications.notifyClientHostedTaskStatus(wire)
        await resumeWaiters(
            taskID: taskID,
            record: record)
    }

    private func activeRecord(
        _ taskID: MCPClientHostedTaskID,
        now: Date
    ) async throws -> Record? {
        try await cleanupExpired(now: now)
        return records[taskID]
    }

    private func cleanupExpired(now: Date) async throws {
        let expired = records.values.filter {
            if let expiresAt = $0.snapshot.expiresAt {
                return expiresAt <= now
            }
            return false
        }
        for record in expired {
            record.operation?.cancel()
            if let reference = record.snapshot.resultReference {
                try? await payloadStore.remove(
                    reference,
                    scopeFingerprint: hostedResultScope(
                        record.snapshot.taskID))
            }
            records[record.snapshot.taskID] = nil
            let taskWaiters = waiters.removeValue(
                forKey: record.snapshot.taskID) ?? []
            for waiter in taskWaiters {
                waiter.continuation.resume(
                    throwing: MCPTaskRuntimeError.taskExpired)
            }
        }
    }

    private func terminalValue(
        _ record: Record,
        taskID: MCPClientHostedTaskID
    ) async throws -> Value {
        switch record.snapshot.state {
        case .completed:
            guard let reference = record.snapshot.resultReference else {
                throw MCPTaskRuntimeError.resultUnavailable
            }
            let data: Data
            do {
                data = try await payloadStore.resolve(
                    reference,
                    scopeFingerprint: hostedResultScope(taskID))
            } catch {
                throw MCPTaskRuntimeError.resultUnavailable
            }
            var value = try JSONDecoder().decode(Value.self, from: data)
            value = Self.addRelatedTaskMetadata(
                to: value,
                taskID: taskID.rawValue)
            return value
        case .failed:
            throw record.terminalError ?? MCPTaskRuntimeError.failed
        case .cancelled:
            throw MCPTaskRuntimeError.cancelled
        case .requested, .working, .inputRequired:
            throw MCPTaskRuntimeError.notTerminal
        }
    }

    private func resumeWaiters(
        taskID: MCPClientHostedTaskID,
        record: Record
    ) async {
        let taskWaiters = waiters.removeValue(forKey: taskID) ?? []
        guard !taskWaiters.isEmpty else { return }
        let result: Result<Value, Error>
        do {
            result = .success(try await terminalValue(
                record,
                taskID: taskID))
        } catch {
            result = .failure(error)
        }
        for waiter in taskWaiters {
            waiter.continuation.resume(with: result)
        }
    }

    private func cancelWaiter(
        taskID: MCPClientHostedTaskID,
        waiterID: UUID
    ) {
        guard var taskWaiters = waiters[taskID],
              let index = taskWaiters.firstIndex(where: {
                  $0.id == waiterID
              }) else {
            return
        }
        let waiter = taskWaiters.remove(at: index)
        waiters[taskID] = taskWaiters.isEmpty ? nil : taskWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func encodeCursor(_ offset: Int) -> String {
        let scope = cursorScope()
        let body = "\(scope):\(offset)"
        return Data(body.utf8).base64EncodedString()
    }

    private func decodeCursor(_ cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.utf8.count <= 4_096,
              let data = Data(base64Encoded: cursor),
              let body = String(data: data, encoding: .utf8),
              body.hasPrefix(cursorScope() + ":"),
              let offset = Int(body.dropFirst(cursorScope().count + 1)),
              offset >= 0 else {
            throw MCPTaskRuntimeError.invalidCursor
        }
        return offset
    }

    private func cursorScope() -> String {
        let seed = [
            authority.server.serverID.rawValue,
            authority.server.serverRevision.rawValue,
            authority.connectionGeneration.rawValue,
            authority.authorityFingerprint,
        ].joined(separator: "\u{1f}")
        return String(MCPConfigurationCanonical.sha256(
            Data(seed.utf8)).prefix(24))
    }

    private func hostedResultScope(
        _ taskID: MCPClientHostedTaskID
    ) -> String {
        [
            "client-task",
            authority.server.serverID.rawValue,
            authority.server.serverRevision.rawValue,
            authority.connectionGeneration.rawValue,
            authority.authorityFingerprint,
            taskID.rawValue,
            "result",
        ].joined(separator: "\u{1f}")
    }

    private static func wire(
        _ snapshot: MCPClientHostedTaskSnapshot
    ) -> MCPTaskWire {
        let formatter = ISO8601DateFormatter()
        return MCPTaskWire(
            taskId: snapshot.taskID.rawValue,
            status: snapshot.state.SDKStatus,
            statusMessage: nil,
            createdAt: formatter.string(from: snapshot.createdAt),
            lastUpdatedAt: formatter.string(from: snapshot.lastUpdatedAt),
            ttl: snapshot.ttlMilliseconds,
            pollInterval: nil)
    }

    private static func addRelatedTaskMetadata(
        to value: Value,
        taskID: String
    ) -> Value {
        guard case .object(var object) = value else {
            return value
        }
        var metadata = object["_meta"]?.objectValue ?? [:]
        metadata[MCPRelatedTaskMetadataKey] = .object([
            "taskId": .string(taskID),
        ])
        object["_meta"] = .object(metadata)
        return .object(object)
    }
}
