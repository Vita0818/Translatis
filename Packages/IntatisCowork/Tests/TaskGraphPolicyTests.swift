import XCTest
import IntatisCore
import IntatisProtocol

final class TaskGraphPolicyTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let a = AgentID(rawValue: "agent-a")
    private let b = AgentID(rawValue: "agent-b")
    private let c = AgentID(rawValue: "agent-c")
    private let d = AgentID(rawValue: "agent-d")

    func testDelegationWithinBudgetAllowed() throws {
        var graph = TaskGraph(policy: TaskGraphPolicy(maxTaskDepth: 4, maxDelegationHops: 4))
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        let first = task(issuer: main, assignee: a, parent: root.id, objective: "First")
        let second = task(issuer: a, assignee: b, parent: first.id, objective: "Second")

        try graph.requireSuccess(first)
        try graph.requireSuccess(second)

        XCTAssertEqual(graph.depth(of: second.id), 3)
        XCTAssertEqual(graph.causalAgentChain(to: second.id), [main, a, b])
    }

    func testDelegationExceedingMaxDepthRejected() throws {
        var graph = TaskGraph(policy: TaskGraphPolicy(maxTaskDepth: 2, maxDelegationHops: 4))
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        let first = task(issuer: main, assignee: a, parent: root.id, objective: "First")
        try graph.requireSuccess(first)
        let tooDeep = task(issuer: a, assignee: b, parent: first.id, objective: "Too deep")

        let result = graph.addTask(tooDeep)

        XCTAssertEqual(result.violation?.kind, .maxDepthExceeded)
    }

    func testTooManyTasksUnderOneRootRejected() throws {
        var graph = TaskGraph(policy: TaskGraphPolicy(maxTasksPerRoot: 2))
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        try graph.requireSuccess(task(issuer: main, assignee: a, parent: root.id, objective: "One"))
        let third = task(issuer: main, assignee: b, parent: root.id, objective: "Two")

        let result = graph.addTask(third)

        XCTAssertEqual(result.violation?.kind, .maxTasksPerRootExceeded)
    }

    func testActiveAgentLimitRejected() throws {
        var graph = TaskGraph(policy: TaskGraphPolicy(maxActiveAgentsPerThread: 3))
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        try graph.requireSuccess(task(issuer: main, assignee: a, parent: root.id, objective: "A"))
        try graph.requireSuccess(task(issuer: main, assignee: b, parent: root.id, objective: "B"))
        let tooManyAgents = task(issuer: main, assignee: c, parent: root.id, objective: "C")

        let result = graph.addTask(tooManyAgents)

        XCTAssertEqual(result.violation?.kind, .maxActiveAgentsExceeded)
    }

    func testDuplicateTaskRejected() throws {
        var graph = TaskGraph()
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        let workspace = WorkspaceID(rawValue: "workspace_same")
        let first = task(issuer: main, assignee: a, parent: root.id,
                         objective: "  Count   Swift Files  ", workspaceID: workspace)
        try graph.requireSuccess(first)
        let duplicate = task(issuer: main, assignee: a, parent: root.id,
                             objective: "count swift files", workspaceID: workspace)

        let result = graph.addTask(duplicate)

        XCTAssertEqual(result.violation?.kind, .duplicateTask)
        XCTAssertEqual(result.violation?.existingTaskID, first.id)
    }

    func testCompletedTaskDoesNotBlockDuplicateObjective() throws {
        var graph = TaskGraph()
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        let first = task(issuer: main, assignee: a, parent: root.id, objective: "Count files")
        try graph.requireSuccess(first)
        XCTAssertTrue(graph.updateStatus(taskID: first.id, status: .assigned))
        XCTAssertTrue(graph.updateStatus(taskID: first.id, status: .queued))
        XCTAssertTrue(graph.updateStatus(taskID: first.id, status: .running))
        XCTAssertTrue(graph.updateStatus(taskID: first.id, status: .completed))
        let retry = task(issuer: main, assignee: a, parent: root.id, objective: "count files")

        try graph.requireSuccess(retry)

        XCTAssertNotNil(graph.node(retry.id))
    }

    func testHopLimitRejected() throws {
        var graph = TaskGraph(policy: TaskGraphPolicy(maxTaskDepth: 5, maxDelegationHops: 2))
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Root")
        try graph.requireRootSuccess(root)
        let first = task(issuer: main, assignee: a, parent: root.id, objective: "A")
        try graph.requireSuccess(first)
        let second = task(issuer: a, assignee: b, parent: first.id, objective: "B")
        try graph.requireSuccess(second)
        let tooManyHops = task(issuer: b, assignee: d, parent: second.id, objective: "D")

        let result = graph.addTask(tooManyHops)

        XCTAssertEqual(result.violation?.kind, .maxDelegationHopsExceeded)
    }

    private func task(kind: TaskKind = .agentInvocation,
                      issuer: AgentID?,
                      assignee: AgentID,
                      parent: TaskID? = nil,
                      objective: String,
                      workspaceID: WorkspaceID = WorkspaceID(rawValue: "workspace")) -> TaskContract {
        TaskContract(
            id: TaskID(rawValue: "task_\(UUID().uuidString)"),
            kind: kind,
            issuer: issuer,
            assignee: assignee,
            parentTaskID: parent,
            objective: objective,
            roleHint: "test role",
            expectedDeliverable: "test deliverable",
            workspaceID: workspaceID)
    }
}
