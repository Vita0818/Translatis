# Intatis Cowork Agent Architecture

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This document defines the intended architecture for Intatis Cowork. It replaces a fixed recursive-agent model with a task-scoped, context-scoped, capability-scoped multi-agent system.

## 1. Core Principle

Intatis should not model agents as a hardcoded tree of permanent roles such as `main`, `coordinator`, `worker`, and `leaf`.

Instead:

```text
Agent identity is persistent.
Role belongs to a task.
Permissions are temporary leases.
Context is scoped and projected.
Collaboration happens through a task graph and message bus.
AgentLoop must never directly recurse into another AgentLoop.
```

This means an agent may coordinate in one task, count files in another task, and review code in a third task. Its current behavior should be determined by the task contract and capability lease it receives, not by a hardcoded type.

## 2. Required Top-level Abstractions

The Cowork architecture should be built around five abstractions:

```text
Agent Identity
Task Contract
Scoped Context
Capability Lease
Task Graph + Scheduler
```

### 2.1 Agent Identity

An Agent is a durable local identity.

It should contain:

```text
Agent
- id
- displayName
- model
- workspace lease or default workspace
- local memory / mailbox
- status
```

It should not contain a permanent “leaf” or “coordinator” role.

### 2.2 Task Contract

A role is assigned per task.

A task contract should tell an agent why it exists in the current workflow and what it is expected to deliver.

Suggested shape:

```swift
struct TaskContract {
    let id: TaskID
    let issuerAgentID: AgentID?
    let assigneeAgentID: AgentID

    let objective: String
    let roleHint: String
    let expectedDeliverable: String

    let parentTaskID: TaskID?
    let relatedTaskIDs: [TaskID]
    let relatedAgentIDs: [AgentID]

    let workspaceLease: WorkspaceLease?
    let capabilityLease: CapabilityLease
    let contextScopes: Set<ContextScope>
}
```

A good task contract answers:

```text
Who created this task?
Why was this agent created or selected?
What is the agent's role in this task?
What workspace is available?
What is the expected deliverable?
What related agents or sibling tasks exist?
What tools and delegation abilities are allowed?
```

### 2.3 Scoped Context

An agent must not automatically receive the full global conversation history.

Instead, each event should have a scope and visibility.

Suggested scopes:

```swift
enum ContextScope {
    case global
    case taskGroup(TaskGroupID)
    case task(TaskID)
    case agent(AgentID)
    case workspace(WorkspaceID)
    case privateAgent(AgentID)
}
```

The context shown to an agent should be projected from the event log:

```text
ContextView(agent, task) =
    global user goal and safety policy
  + relevant task group plan
  + current task contract and lineage
  + messages directly addressed to this agent
  + this agent's local history
  + explicitly shared artifacts and summaries
  + current workspace summary and relevant tool observations
```

Do not give an agent unrelated tool calls, unrelated workspace source, or raw messages intended for other agents unless explicitly shared.

### 2.4 Capability Lease

Tools and permissions should be granted per task, not permanently per agent identity.

Suggested shape:

```swift
struct CapabilityLease {
    let tools: Set<ToolCapability>
    let workspaceScopes: Set<WorkspaceID>
    let communicationTargets: CommunicationScope
    let delegation: DelegationGrant
    let expiresWithTask: Bool
}
```

Delegation should be explicit:

```swift
enum DelegationGrant {
    case none
    case granted(DelegationBudget)
}
```

Default should usually be:

```text
ordinary execution task: none
explicit coordination task: granted(...)
high-risk task: none
```

### 2.5 Task Graph + Scheduler

Do not model multi-agent work as nested synchronous function calls.

Do not implement:

```text
Agent A AgentLoop
→ ask Agent B
→ create Agent B AgentLoop
→ B asks A
→ create Agent A AgentLoop again
```

Instead, use:

```text
Agent A
→ MessageBus / TaskGraph
→ Scheduler queues work for Agent B
→ Agent B executes independently
→ Agent B publishes result
→ Agent A or Orchestrator observes result
```

The scheduler should track:

```text
task id
parent task id
issuer
assignee
status
causal chain
hop count / graph path
created capabilities
created artifacts
```

This prevents call-stack recursion and makes loops detectable.

## 3. Message vs Delegation

The current `ask_agent` concept should be split.

### 3.1 Communication

Communication is for exchanging information.

Suggested operations:

```text
send_message
request_information
reply_message
```

Communication should not create a new task unless explicitly requested.

### 3.2 Delegation

Delegation creates a task.

Suggested operations:

```text
delegate_task
```

A worker does not receive delegation or spawn authority. If it needs help, it reports that need in its result; a coordinator may then explicitly call `spawn_agent` and/or `delegate_task`.

## 4. Delegation Model

Only an agent with an explicit granted delegation lease may call `delegate_task`; workspace expansion and agent creation remain separate `spawn_agent` admission.

Flow:

```text
Agent proposes delegation
→ delegation_requested event
→ Orchestrator checks TaskContract and CapabilityLease
→ Permission / policy check
→ user approval if needed
→ agent or task created
→ task_assigned event
```

This keeps flexibility without hardcoding roles.

## 5. Example: Swift File Count Task

User request:

```text
拉起两个子 Agent，分别对本文件夹下的 macOS 和 iOS Swift 文件进行计数。
```

The root orchestrator creates a task group:

```text
Root Task:
  objective = count Swift files under macOS and iOS app folders
```

Task decomposition:

```text
Task M:
  assignee = @macos-counter
  roleHint = macOS Swift file counter
  workspace = Apps/IntatisMac
  expectedDeliverable = count + path list
  delegation = none
  relatedAgent = @ios-counter

Task I:
  assignee = @ios-counter
  roleHint = iOS Swift file counter
  workspace = Apps/IntatisiOS
  expectedDeliverable = count + path list
  delegation = none
  relatedAgent = @macos-counter
```

The `@macos-counter` context should say:

```text
You were created by @main as part of a two-agent count task.
@main already split the global task into macOS and iOS parts.
Your assigned role is macOS Swift file counter.
Your workspace is Apps/IntatisMac.
@ios-counter is independently responsible for Apps/IntatisiOS.
Return only the macOS Swift count and file paths.
You do not have delegation authority for this task. If you believe delegation is needed, ask @main.
```

This gives the agent its lineage without making it re-run the global instruction.

## 6. Required Invariants

The following invariants should be enforced by code, not just prompt text.

```text
1. An AgentLoop must not synchronously call another AgentLoop.
2. Every agent-to-agent interaction must go through MessageBus or TaskGraph.
3. Every task assignment must have a TaskContract.
4. Every tool set must come from a CapabilityLease.
5. Every workspace access must be backed by a WorkspaceLease.
6. Context shown to an agent must be projected by scope.
7. Agent-to-agent self-call must be rejected unless a future explicit self-reflection feature is designed.
8. Delegation cycles must be detected in the TaskGraph.
9. Workspace expansion must be permissioned.
10. Agent identity must not imply permanent coordinator rights.
```

## 7. Implementation Direction

A useful package-level shape:

```text
IntatisCowork
├── AgentRegistry
├── TaskGraph
├── Scheduler
├── MessageBus
├── ContextProjector
├── CapabilityService
├── WorkspaceLeaseService
├── DelegationService
└── Orchestrator
```

Responsibilities:

```text
AgentRegistry       manages durable agent identities
TaskGraph           stores tasks, parent/child links, state, causal chains
Scheduler           queues agent execution and prevents recursive AgentLoop calls
MessageBus          stores and routes agent messages
ContextProjector    builds scoped context views for each agent/task
CapabilityService   creates per-task capability leases
WorkspaceLease      controls directory access
Orchestrator        handles root task planning and result synthesis
```

## 8. Migration Path From Current Implementation

1. Introduce `TaskContract` and `TaskID`.
2. Replace global `priorHistory()` with `contextProjection(for: agentID, taskID)`.
3. Replace synchronous `Orchestrator.ask()` execution with mailbox + scheduler.
4. Replace `coordinationDepth` as a semantic role mechanism with `CapabilityLease.delegation`.
5. Keep `spawn_agent` and `delegate_task` as separate explicit calls; delegation never creates an agent implicitly.
6. Split `ask_agent` into communication and delegation operations.
7. Add graph-level cycle detection and self-call guards.
8. Add tests for task-scoped context and capability leases.
