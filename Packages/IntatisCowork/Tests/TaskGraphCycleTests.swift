import XCTest
import IntatisCore
import IntatisProtocol

final class TaskGraphCycleTests: XCTestCase {
    private let main = AgentID(rawValue: "main")
    private let a = AgentID(rawValue: "agent-a")
    private let b = AgentID(rawValue: "agent-b")
    private let c = AgentID(rawValue: "agent-c")

    func testSelfDelegationRejected() {
        var graph = TaskGraph()
        let contract = task(issuer: a, assignee: a, objective: "self task")

        let result = graph.addTask(contract)

        XCTAssertEqual(result.violation?.kind, .selfDelegation)
        XCTAssertTrue(graph.nodes.isEmpty)
    }

    func testABACycleRejected() throws {
        var graph = TaskGraph()
        let ab = task(issuer: main, assignee: a, objective: "A handles first task")
        try graph.requireSuccess(ab)
        let ba = task(issuer: a, assignee: main, parent: ab.id, objective: "Back to main")

        let result = graph.addTask(ba)

        XCTAssertEqual(result.violation?.kind, .cycleDetected)
        XCTAssertNil(graph.node(ba.id))
    }

    func testLongerABCARejected() throws {
        var graph = TaskGraph()
        let ab = task(issuer: main, assignee: a, objective: "A task")
        try graph.requireSuccess(ab)
        let bc = task(issuer: a, assignee: b, parent: ab.id, objective: "B task")
        try graph.requireSuccess(bc)
        let ca = task(issuer: b, assignee: main, parent: bc.id, objective: "Cycle to main")

        let result = graph.addTask(ca)

        XCTAssertEqual(result.violation?.kind, .cycleDetected)
        XCTAssertNil(graph.node(ca.id))
    }

    func testSiblingTasksUnderSameRootAreNotACycle() throws {
        var graph = TaskGraph()
        let root = task(kind: .root, issuer: nil, assignee: main, objective: "Count all Swift files")
        try graph.requireRootSuccess(root)
        let macos = task(issuer: main, assignee: a, parent: root.id, objective: "Count macOS Swift files")
        let ios = task(issuer: main, assignee: b, parent: root.id, objective: "Count iOS Swift files")

        try graph.requireSuccess(macos)
        try graph.requireSuccess(ios)

        XCTAssertEqual(graph.node(macos.id)?.rootTaskID, root.id)
        XCTAssertEqual(graph.node(ios.id)?.rootTaskID, root.id)
        XCTAssertEqual(graph.edges.filter { $0.kind == .delegates }.count, 2)
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

extension TaskGraph {
    mutating func requireSuccess(_ contract: TaskContract,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        switch addTask(contract) {
        case .success:
            return
        case .failure(let violation):
            XCTFail("expected success, got \(violation.kind)", file: file, line: line)
            throw violation
        }
    }

    mutating func requireRootSuccess(_ contract: TaskContract,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        switch addRootTask(contract) {
        case .success:
            return
        case .failure(let violation):
            XCTFail("expected root success, got \(violation.kind)", file: file, line: line)
            throw violation
        }
    }
}

extension Result where Success == TaskGraphAdmission, Failure == TaskGraphViolation {
    var violation: TaskGraphViolation? {
        if case .failure(let violation) = self { return violation }
        return nil
    }
}
