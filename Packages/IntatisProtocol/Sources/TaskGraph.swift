import Foundation
import IntatisCore

public struct TaskNode: Codable, Sendable, Hashable {
    public var id: TaskID
    public var contract: TaskContract
    public var status: TaskStatus
    public var rootTaskID: TaskID
    public var parentTaskID: TaskID?
    public var issuer: AgentID?
    public var assignee: AgentID
    public var createdAt: Date

    public init(id: TaskID,
                contract: TaskContract,
                status: TaskStatus,
                rootTaskID: TaskID,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID,
                createdAt: Date = Date()) {
        self.id = id
        self.contract = contract
        self.status = status
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.createdAt = createdAt
    }
}

public enum TaskEdgeKind: String, Codable, Sendable, Hashable {
    case delegates
    case requestsInformation = "requests_information"
    case replies
    case blocks
}

public struct TaskEdge: Codable, Sendable, Hashable {
    public var fromTaskID: TaskID
    public var toTaskID: TaskID
    public var issuer: AgentID?
    public var assignee: AgentID
    public var kind: TaskEdgeKind

    public init(fromTaskID: TaskID,
                toTaskID: TaskID,
                issuer: AgentID? = nil,
                assignee: AgentID,
                kind: TaskEdgeKind) {
        self.fromTaskID = fromTaskID
        self.toTaskID = toTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.kind = kind
    }
}

public struct TaskGraphPolicy: Codable, Sendable, Hashable {
    public var maxTaskDepth: Int
    public var maxDelegationHops: Int
    public var maxTasksPerRoot: Int
    public var maxActiveAgentsPerThread: Int

    public init(maxTaskDepth: Int = 4,
                maxDelegationHops: Int = 4,
                maxTasksPerRoot: Int = 32,
                maxActiveAgentsPerThread: Int = 8) {
        self.maxTaskDepth = maxTaskDepth
        self.maxDelegationHops = maxDelegationHops
        self.maxTasksPerRoot = maxTasksPerRoot
        self.maxActiveAgentsPerThread = maxActiveAgentsPerThread
    }

    public static let `default` = TaskGraphPolicy()
}

public struct TaskGraphViolation: Error, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case selfDelegation = "self_delegation"
        case cycleDetected = "cycle_detected"
        case maxDepthExceeded = "max_depth_exceeded"
        case maxDelegationHopsExceeded = "max_delegation_hops_exceeded"
        case maxTasksPerRootExceeded = "max_tasks_per_root_exceeded"
        case maxActiveAgentsExceeded = "max_active_agents_exceeded"
        case duplicateTask = "duplicate_task"
        case missingParentTask = "missing_parent_task"
        case duplicateTaskID = "duplicate_task_id"
    }

    public var kind: Kind
    public var message: String
    public var taskID: TaskID?
    public var existingTaskID: TaskID?

    public init(kind: Kind,
                message: String,
                taskID: TaskID? = nil,
                existingTaskID: TaskID? = nil) {
        self.kind = kind
        self.message = message
        self.taskID = taskID
        self.existingTaskID = existingTaskID
    }
}

public struct TaskGraphAdmission: Codable, Sendable, Hashable {
    public var node: TaskNode
    public var edge: TaskEdge?
    public var rootTaskID: TaskID
    public var hopCount: Int
    public var visitedAgents: [AgentID]

    public init(node: TaskNode,
                edge: TaskEdge? = nil,
                rootTaskID: TaskID,
                hopCount: Int,
                visitedAgents: [AgentID]) {
        self.node = node
        self.edge = edge
        self.rootTaskID = rootTaskID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
    }
}

public struct TaskGraph: Codable, Sendable, Hashable {
    public private(set) var nodes: [TaskID: TaskNode]
    public private(set) var edges: [TaskEdge]
    public var policy: TaskGraphPolicy

    public init(nodes: [TaskID: TaskNode] = [:],
                edges: [TaskEdge] = [],
                policy: TaskGraphPolicy = .default) {
        self.nodes = nodes
        self.edges = edges
        self.policy = policy
    }

    public func node(_ id: TaskID) -> TaskNode? {
        nodes[id]
    }

    @discardableResult
    public mutating func replaceContract(_ contract: TaskContract) -> Bool {
        guard var node = nodes[contract.id],
              node.assignee == contract.assignee,
              node.parentTaskID == contract.parentTaskID else {
            return false
        }
        node.contract = contract
        nodes[contract.id] = node
        return true
    }

    @discardableResult
    public mutating func addRootTask(_ contract: TaskContract,
                                     createdAt: Date = Date()) -> Result<TaskGraphAdmission, TaskGraphViolation> {
        guard nodes[contract.id] == nil else {
            return .failure(TaskGraphViolation(
                kind: .duplicateTaskID,
                message: "task id already exists: \(contract.id.rawValue)",
                taskID: contract.id,
                existingTaskID: contract.id))
        }
        var activeAgents = Set(nodes.values.filter { Self.isActive($0.status) }.map(\.assignee))
        activeAgents.insert(contract.assignee)
        guard activeAgents.count <= policy.maxActiveAgentsPerThread else {
            return .failure(TaskGraphViolation(
                kind: .maxActiveAgentsExceeded,
                message: "active agent count \(activeAgents.count) exceeds limit \(policy.maxActiveAgentsPerThread)",
                taskID: contract.id))
        }
        let node = TaskNode(
            id: contract.id,
            contract: contract,
            status: .created,
            rootTaskID: contract.id,
            parentTaskID: nil,
            issuer: contract.issuer,
            assignee: contract.assignee,
            createdAt: createdAt)
        let admission = TaskGraphAdmission(
            node: node,
            rootTaskID: contract.id,
            hopCount: contract.issuer == nil ? 0 : 1,
            visitedAgents: Self.uniqueAgents([contract.issuer, contract.assignee].compactMap { $0 }))
        nodes[contract.id] = node
        return .success(admission)
    }

    public func validateAddTask(_ contract: TaskContract,
                                createdAt: Date = Date()) -> Result<TaskGraphAdmission, TaskGraphViolation> {
        guard nodes[contract.id] == nil else {
            return .failure(TaskGraphViolation(
                kind: .duplicateTaskID,
                message: "task id already exists: \(contract.id.rawValue)",
                taskID: contract.id,
                existingTaskID: contract.id))
        }
        if let issuer = contract.issuer, issuer == contract.assignee {
            return .failure(TaskGraphViolation(
                kind: .selfDelegation,
                message: "agent cannot delegate to itself",
                taskID: contract.id))
        }

        let parentNode: TaskNode?
        if let parentTaskID = contract.parentTaskID {
            guard let parent = nodes[parentTaskID] else {
                return .failure(TaskGraphViolation(
                    kind: .missingParentTask,
                    message: "parent task does not exist: \(parentTaskID.rawValue)",
                    taskID: contract.id))
            }
            parentNode = parent
        } else {
            parentNode = nil
        }

        let rootTaskID = parentNode?.rootTaskID ?? contract.id
        let taskDepth = parentNode.map { depth(of: $0.id) + 1 } ?? 1
        guard taskDepth <= policy.maxTaskDepth else {
            return .failure(TaskGraphViolation(
                kind: .maxDepthExceeded,
                message: "task depth \(taskDepth) exceeds limit \(policy.maxTaskDepth)",
                taskID: contract.id))
        }

        var visitedAgents = parentNode.map { causalAgentChain(to: $0.id) } ?? []
        if let issuer = contract.issuer, visitedAgents.last != issuer {
            visitedAgents.append(issuer)
        }
        if visitedAgents.contains(contract.assignee) {
            return .failure(TaskGraphViolation(
                kind: .cycleDetected,
                message: "delegation cycle rejected for @\(contract.assignee.rawValue)",
                taskID: contract.id))
        }
        visitedAgents.append(contract.assignee)
        visitedAgents = Self.uniqueAgents(visitedAgents)

        let hopCount = max(0, visitedAgents.count - 1)
        guard hopCount <= policy.maxDelegationHops else {
            return .failure(TaskGraphViolation(
                kind: .maxDelegationHopsExceeded,
                message: "delegation hops \(hopCount) exceeds limit \(policy.maxDelegationHops)",
                taskID: contract.id))
        }

        let tasksForRoot = nodes.values.filter { $0.rootTaskID == rootTaskID }.count + 1
        guard tasksForRoot <= policy.maxTasksPerRoot else {
            return .failure(TaskGraphViolation(
                kind: .maxTasksPerRootExceeded,
                message: "root task \(rootTaskID.rawValue) exceeds task limit \(policy.maxTasksPerRoot)",
                taskID: contract.id))
        }

        var activeAgents = Set(nodes.values.filter { Self.isActive($0.status) }.map(\.assignee))
        activeAgents.insert(contract.assignee)
        guard activeAgents.count <= policy.maxActiveAgentsPerThread else {
            return .failure(TaskGraphViolation(
                kind: .maxActiveAgentsExceeded,
                message: "active agent count \(activeAgents.count) exceeds limit \(policy.maxActiveAgentsPerThread)",
                taskID: contract.id))
        }

        if let duplicate = duplicateActiveTask(for: contract) {
            return .failure(TaskGraphViolation(
                kind: .duplicateTask,
                message: "duplicate active task rejected",
                taskID: contract.id,
                existingTaskID: duplicate.id))
        }

        let edge = parentNode.map {
            TaskEdge(
                fromTaskID: $0.id,
                toTaskID: contract.id,
                issuer: contract.issuer,
                assignee: contract.assignee,
                kind: .delegates)
        }
        if let edge, wouldCreateTaskCycle(edge) {
            return .failure(TaskGraphViolation(
                kind: .cycleDetected,
                message: "task edge would create a cycle",
                taskID: contract.id))
        }

        let node = TaskNode(
            id: contract.id,
            contract: contract,
            status: .created,
            rootTaskID: rootTaskID,
            parentTaskID: contract.parentTaskID,
            issuer: contract.issuer,
            assignee: contract.assignee,
            createdAt: createdAt)
        return .success(TaskGraphAdmission(
            node: node,
            edge: edge,
            rootTaskID: rootTaskID,
            hopCount: hopCount,
            visitedAgents: visitedAgents))
    }

    @discardableResult
    public mutating func addTask(_ contract: TaskContract,
                                 createdAt: Date = Date()) -> Result<TaskGraphAdmission, TaskGraphViolation> {
        let result = validateAddTask(contract, createdAt: createdAt)
        if case .success(let admission) = result {
            nodes[admission.node.id] = admission.node
            if let edge = admission.edge {
                edges.append(edge)
            }
        }
        return result
    }

    @discardableResult
    public mutating func updateStatus(taskID: TaskID,
                                      status: TaskStatus,
                                      isRetry: Bool = false) -> Bool {
        guard var node = nodes[taskID],
              node.status.canTransition(to: status, isRetry: isRetry) else {
            return false
        }
        node.status = status
        nodes[taskID] = node
        return true
    }

    public func causalAgentChain(to taskID: TaskID) -> [AgentID] {
        guard let node = nodes[taskID] else { return [] }
        var chain: [AgentID] = []
        if let parentTaskID = node.parentTaskID {
            chain.append(contentsOf: causalAgentChain(to: parentTaskID))
        }
        if let issuer = node.issuer, chain.last != issuer {
            chain.append(issuer)
        }
        if chain.last != node.assignee {
            chain.append(node.assignee)
        }
        return Self.uniqueAgents(chain)
    }

    public func depth(of taskID: TaskID) -> Int {
        guard let node = nodes[taskID] else { return 0 }
        guard let parentTaskID = node.parentTaskID else { return 1 }
        return depth(of: parentTaskID) + 1
    }

    private func duplicateActiveTask(for contract: TaskContract) -> TaskNode? {
        let objective = Self.normalizedObjective(contract.objective)
        return nodes.values.first { node in
            guard Self.isActive(node.status) else { return false }
            guard node.parentTaskID == contract.parentTaskID else { return false }
            guard node.assignee == contract.assignee else { return false }
            guard Self.normalizedObjective(node.contract.objective) == objective else { return false }
            return Self.sameWorkspaceScope(node.contract, contract)
        }
    }

    private func wouldCreateTaskCycle(_ newEdge: TaskEdge) -> Bool {
        var adjacency: [TaskID: [TaskID]] = [:]
        for edge in edges where edge.kind == .delegates {
            adjacency[edge.fromTaskID, default: []].append(edge.toTaskID)
        }
        adjacency[newEdge.fromTaskID, default: []].append(newEdge.toTaskID)
        return hasPath(from: newEdge.toTaskID, to: newEdge.fromTaskID, adjacency: adjacency)
    }

    private func hasPath(from start: TaskID, to target: TaskID, adjacency: [TaskID: [TaskID]]) -> Bool {
        if start == target { return true }
        var visited = Set<TaskID>()
        var stack = [start]
        while let current = stack.popLast() {
            if current == target { return true }
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            stack.append(contentsOf: adjacency[current] ?? [])
        }
        return false
    }

    private static func normalizedObjective(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    private static func sameWorkspaceScope(_ lhs: TaskContract, _ rhs: TaskContract) -> Bool {
        if lhs.workspaceLeaseID == rhs.workspaceLeaseID { return true }
        if lhs.workspaceID != nil, lhs.workspaceID == rhs.workspaceID { return true }
        return lhs.workspaceLeaseID == nil && rhs.workspaceLeaseID == nil
    }

    private static func isActive(_ status: TaskStatus) -> Bool {
        switch status {
        case .created, .assigned, .queued, .running:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private static func uniqueAgents(_ agents: [AgentID]) -> [AgentID] {
        var seen = Set<AgentID>()
        var result: [AgentID] = []
        for agent in agents where !seen.contains(agent) {
            seen.insert(agent)
            result.append(agent)
        }
        return result
    }
}
