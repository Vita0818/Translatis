import Foundation
import IntatisCore
import IntatisAgentKernel

/// The set of agents active in one Cowork conversation, keyed by `@name`
/// (ARCHITECTURE.md §7). A value type held by the `Orchestrator` actor.
public struct AgentRegistry: Sendable {
    private var agents: [AgentID: Agent] = [:]

    public init() {}

    public mutating func add(_ agent: Agent) { agents[agent.name] = agent }
    public mutating func remove(_ name: AgentID) { agents[name] = nil }

    public func agent(_ name: AgentID) -> Agent? { agents[name] }
    public func all() -> [Agent] { Array(agents.values) }
    public var names: [AgentID] { Array(agents.keys) }
    public var isEmpty: Bool { agents.isEmpty }
}
