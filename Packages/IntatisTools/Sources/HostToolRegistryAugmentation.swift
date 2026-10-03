import Foundation
import IntatisCore
import IntatisProtocol

/// Exact, host-owned facts supplied when an internal tool surface is added to
/// one Code/Cowork invocation. Model arguments never construct this value.
public struct HostToolRegistryAugmentationInput: Sendable {
    public let sessionID: SessionID
    public let agentID: AgentID
    public let taskID: TaskID?
    public let capabilityLease: CapabilityLease
    public let workspaceLease: WorkspaceLease
    public let baseRegistry: ToolRegistry

    public init(sessionID: SessionID,
                agentID: AgentID,
                taskID: TaskID?,
                capabilityLease: CapabilityLease,
                workspaceLease: WorkspaceLease,
                baseRegistry: ToolRegistry) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.taskID = taskID
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.baseRegistry = baseRegistry
    }
}

private actor HostToolRegistryAugmentationCloseState {
    typealias CloseAction = @Sendable () async -> Bool

    private let closeAction: CloseAction
    private var closeTask: Task<Bool, Never>?

    init(closeAction: @escaping CloseAction) {
        self.closeAction = closeAction
    }

    func close() async -> Bool {
        if let closeTask {
            return await closeTask.value
        }
        let action = closeAction
        let task = Task { await action() }
        closeTask = task
        return await task.value
    }
}

/// A registry plus the host resource admission that keeps its dynamic tools
/// valid. `close()` is idempotent, concurrent callers join the same drain, and
/// runtime owners must await it before declaring an invocation stopped.
public final class HostToolRegistryAugmentationLease: @unchecked Sendable {
    public let registry: ToolRegistry
    private let closeState: HostToolRegistryAugmentationCloseState

    public init(registry: ToolRegistry,
                close: @escaping @Sendable () async -> Bool) {
        self.registry = registry
        closeState = HostToolRegistryAugmentationCloseState(
            closeAction: close)
    }

    @discardableResult
    public func close() async -> Bool {
        await closeState.close()
    }

    /// Runtime-owner boundary for invocations that are able to surface a
    /// terminal failure. A timed-out mount/provider/security-scope drain must
    /// not be silently converted into a successful turn or process command.
    public func closeRequiringDrain() async throws {
        guard await close() else {
            throw IntatisError.io(
                "Internal tool resources did not drain before invocation completion.")
        }
    }

    deinit {
        let state = closeState
        Task {
            _ = await state.close()
        }
    }
}

/// Optional internal-tool hook shared by Code and Cowork. The host declares
/// the exact additional capability before durable/task lease construction,
/// then receives the already-scoped leases again at registry construction.
public struct HostToolRegistryAugmenter: Sendable {
    public typealias Operation = @Sendable (
        HostToolRegistryAugmentationInput
    ) async throws -> HostToolRegistryAugmentationLease

    public let additionalCapabilities: Set<ToolCapability>
    private let operation: Operation

    public init(additionalCapabilities: Set<ToolCapability>,
                operation: @escaping Operation) {
        self.additionalCapabilities = additionalCapabilities
        self.operation = operation
    }

    public func augment(
        _ input: HostToolRegistryAugmentationInput
    ) async throws -> HostToolRegistryAugmentationLease {
        try await operation(input)
    }
}
