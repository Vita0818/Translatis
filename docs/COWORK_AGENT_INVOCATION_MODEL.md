# Intatis Cowork Agent Invocation Model

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This document defines the v0.10+ invocation model for Intatis Cowork. It is an implementation reference for how agents are assigned work, how they communicate, how they delegate, and how execution is scheduled without recursive AgentLoop calls.

## 1. Purpose

The purpose of this document is to make agent invocation explicit and enforceable.

The current Cowork model can make a child agent behave like another coordinator because role, permission, context, and recursion budget are coupled together. The observed failure mode is:

```text
@main spawns @macos-counter
@macos-counter receives coordinator tools
@macos-counter sees the global user request
@macos-counter tries to spawn @macos-counter or @ios-counter again
@macos-counter can ask_agent(to: @macos-counter)
ask_agent creates another AgentLoop
```

The old model has these problems:

```text
child agent may continue to spawn child agents
ask_agent may self-call when caller == target
agent reads global history and thinks it should decompose the whole task again
coordinationDepth is treated as role semantics
AgentLoop recursion makes the execution graph uncontrolled
```

`coordinationDepth` may remain as a low-level safety fuse, but it must not decide whether an agent is a coordinator, worker, or leaf. The role must come from a task. The available tools must come from a capability lease. The visible context must come from a scoped projection.

Core rule:

```text
Agent identity is persistent.
Role belongs to a task.
Permissions are temporary capability leases.
Context is scoped and projected.
Collaboration happens through task graph + message bus + scheduler.
AgentLoop must never synchronously recurse into another AgentLoop.
```

## 2. Conceptual Model

Cowork invocation is organized around a conversation-level task graph:

```text
Conversation
└── TaskGraph
    ├── TaskContract
    ├── AgentIdentity
    ├── CapabilityLease
    ├── WorkspaceLease
    ├── ScopedContext
    └── MessageBus
```

Responsibilities:

```text
Conversation
    Owns the user-visible Cowork thread, public objective, event log, and roster.

TaskGraph
    Stores tasks, parent/child relationships, dependency edges, assignment state,
    causal chain metadata, cycle checks, and completion state.

TaskContract
    Defines a specific unit of work: issuer, assignee, objective, role hint,
    expected deliverable, constraints, related tasks, workspace lease, and
    capability lease.

AgentIdentity
    Represents a durable local agent identity: id, display name, model choice,
    mailbox, local memory, and status. It does not encode a permanent role.

CapabilityLease
    Grants task-bound tool and communication abilities. It expires with the task
    unless explicitly renewed or replaced.

WorkspaceLease
    Grants task-bound workspace access. It constrains roots, paths, denied
    patterns, and access mode. Workspace expansion is never read-only.

ScopedContext
    The projected context bundle an agent sees for a task. It is derived from
    events, contracts, leases, lineage, direct messages, shared artifacts, and
    workspace-relevant observations.

MessageBus
    Records and routes agent-to-agent communication. It does not create tasks by
    itself.
```

The scheduler consumes the TaskGraph and MessageBus state:

```text
agent emits message or task request
message/task request is recorded
scheduler queues eligible work
target agent executes independently
result is appended to event log
issuer or orchestrator observes the result
```

## 3. Agent Identity vs Task Role

Agent identity and task role are separate concepts.

```text
Agent identity = persistent identity
Task role = temporary responsibility inside one task
```

An agent identity can appear in many tasks:

```text
@alex executes a file count task
@alex coordinates a review task
@alex replies with information in another task
```

None of those roles should be represented by permanent runtime classes such as:

```text
CoordinatorAgent
WorkerAgent
LeafAgent
```

Instead, invocation should use:

```text
Agent + TaskContract.roleHint + CapabilityLease
```

Example:

```text
AgentIdentity(id: @macos-counter)
TaskContract.roleHint: "macOS Swift file counter"
CapabilityLease.delegation: none
```

The agent is not permanently a worker. In this task, it is assigned a counting role with no direct delegation power.

## 4. TaskContract

`TaskContract` is the unit of agent invocation. It explains why an agent is running and what it is allowed to do for this task.

Suggested shape:

```swift
struct TaskContract: Codable, Sendable {
    let id: TaskID
    let issuer: ParticipantID
    let assignee: AgentID
    let parentTaskID: TaskID?

    let objective: String
    let roleHint: String
    let expectedDeliverable: String

    let workspaceLease: WorkspaceLeaseID?
    let capabilityLease: CapabilityLeaseID

    let relatedAgents: [AgentID]
    let relatedTasks: [TaskID]
    let constraints: [String]
}
```

Required fields:

```text
task id
issuer
assignee
parent task id
objective
role hint
expected deliverable
workspace lease
capability lease
related agents
related tasks
constraints
```

A TaskContract must answer:

```text
Who assigned me?
Why am I here?
What is my task?
Which part am I responsible for?
What output should I produce?
Which tools may I use?
May I delegate?
```

Task contracts are required for delegation. Communication alone does not create a TaskContract.

## 5. CapabilityLease

Tool ability does not belong permanently to an agent identity. It belongs to a temporary task lease.

Suggested shape:

```swift
struct CapabilityLease: Codable, Sendable {
    let id: CapabilityLeaseID
    let taskID: TaskID
    let capabilities: Set<ToolCapability>
    let communication: CommunicationGrant
    let delegation: DelegationGrant
    let workspaceExpansion: WorkspaceExpansionGrant
    let expiresAtTaskCompletion: Bool
}

enum ToolCapability: String, Codable, Sendable {
    case canReadWorkspace
    case canSearchWorkspace
    case canRunShell
    case canProposePatch
    case canApplyPatch
    case canSendMessage
    case canRequestInformation
    case canDelegateTask
    case canAttachWorkspace
}
```

Required policy:

```text
ordinary counting task should not receive spawn/delegate capability
explicit coordination task may receive delegation capability
worker receives neither delegation nor spawn capability and reports blockers in its result
workspace expansion is never read-only
attach workspace must pass through the permission system
```

Delegation grant examples:

```swift
enum DelegationGrant: Codable, Sendable {
    case none
    case granted(DelegationBudget)
}
```

Interpretation:

```text
none
    The agent may not create downstream work. It reports any need for help in
    its result.

granted
    The agent may delegate within an explicit budget. The TaskGraph, Scheduler,
    WorkspaceLease, and CapabilityLease checks still apply.
```

The tool registry must be built from the active CapabilityLease. Prompt text may explain the lease, but prompt text must not be the enforcement layer.

## 6. Scoped Context Projection

An agent must not receive the full raw global transcript by default.

The runtime should construct a `ScopedContext` or `ContextBundle` for a specific `(agentID, taskID)` pair.

Runtime-visible context sources:

```text
global brief
safety policy
task contract
lineage
direct messages
agent-local history
explicitly shared artifacts
workspace-relevant observations
allowed tools
```

Suggested shape:

```swift
struct ContextBundle: Codable, Sendable {
    let globalBrief: String
    let safetyPolicy: String
    let taskContract: TaskContract
    let lineage: [LineageItem]
    let directMessages: [ScopedEvent]
    let agentLocalHistory: [ScopedEvent]
    let sharedArtifacts: [ArtifactDescriptor]
    let workspaceObservations: [WorkspaceObservation]
    let allowedTools: [ToolDescriptor]
}
```

Lineage projection should provide a causal view, not a transcript replay.

Example lineage:

```text
1. User requested the overall Swift file count.
2. @main decomposed the request into macOS and iOS count tasks.
3. @main created @macos-counter for the macOS count task.
4. @ios-counter is responsible for another related task.
5. @macos-counter is currently responsible only for macOS counting.
```

This answers why the agent is running without causing it to reprocess the raw global instruction as a new command. It also prevents unrelated tool calls, unrelated private observations, or other agents' local histories from leaking into the task context.

## 7. Message vs Delegation

The old `ask_agent` operation combines too many meanings. It must be split into communication and delegation.

Communication operations:

```text
send_message
request_information
reply_message
```

Delegation operations:

```text
delegate_task
```

Rules:

```text
communication does not create a new task
delegation creates a TaskContract
agent-to-agent communication must pass through MessageBus
delegation must pass through TaskGraph, Scheduler, and CapabilityLease checks
caller == target self-call is rejected by default
```

Communication examples:

```text
@macos-counter -> reply_message(@main, "macOS count is 42")
@main -> request_information(@ios-counter, "include ignored directories?")
```

Delegation examples:

```text
@main -> delegate_task(@macos-counter, TaskContract(...))
```

## 8. Scheduler and Non-recursive Execution

Hard rule:

```text
AgentLoop must not directly call another AgentLoop.
```

The new execution flow is:

```text
Agent emits message/task request
-> MessageBus or TaskGraph records it
-> Scheduler queues target task
-> target Agent executes independently
-> result is appended to event log
-> issuer/orchestrator observes result
```

The caller should not block by creating a nested target AgentLoop in the same call stack. It may wait for an event, subscribe to completion, or yield control to the scheduler.

This prevents:

```text
call-stack recursion
caller == target self-call recursion
A -> B -> A nested loop
unbounded delegation chain hidden inside one tool call
duplicate task creation caused by repeated prompt replay
```

Scheduler checks should include:

```text
task exists and is schedulable
assignee exists
CapabilityLease is valid
WorkspaceLease is valid
causal chain does not include a forbidden cycle
delegation budget is not exceeded
target task is not a duplicate of an active task
```

## 9. Event Model

Cowork should record semantic events in addition to generic tool traces.

Recommended event types:

```text
task_created
task_assigned
task_started
task_completed
task_failed
delegation_requested
delegation_approved
delegation_rejected
agent_message
agent_result
workspace_lease_requested
workspace_lease_granted
capability_lease_created
```

Recommended event metadata:

```text
taskID
sender
recipient
agentID
workspaceID
causalParentID
visibility
scope
```

Suggested shape:

```swift
struct CoworkEvent: Codable, Sendable {
    let id: EventID
    let type: CoworkEventType
    let taskID: TaskID?
    let sender: ParticipantID?
    let recipient: ParticipantID?
    let agentID: AgentID?
    let workspaceID: WorkspaceID?
    let causalParentID: EventID?
    let visibility: Visibility
    let scope: ContextScope
    let payload: EventPayload
    let createdAt: Date
}
```

The event log is the source for ContextProjector, TaskGraph auditing, scheduler decisions, and final user-visible synthesis.

## 10. Example: macOS/iOS Swift File Counting

User task:

```text
拉起两个子 Agent，分别对本文件夹下的 macOS 和 iOS Swift 文件进行计数。
```

Invocation flow:

```text
1. @main receives the user request.
2. @main creates a root task for the overall count objective.
3. @main decomposes the root task into two child tasks:
   - macOS Swift file count
   - iOS Swift file count
4. @main assigns the macOS task to @macos-counter.
5. @main assigns the iOS task to @ios-counter.
6. Scheduler runs both assigned tasks independently.
7. @macos-counter reports macOS result to @main.
8. @ios-counter reports iOS result to @main.
9. @main synthesizes the final answer.
```

Root task:

```text
task id: task-root-count
assignee: @main
objective: Count Swift files under the relevant macOS and iOS folders.
role hint: root task planner and result synthesizer
expected deliverable: final combined macOS/iOS count summary
```

macOS TaskContract:

```text
task id: task-count-macos
issuer: @main
assignee: @macos-counter
parent task id: task-root-count
objective: Count Swift files in the macOS workspace scope.
role hint: macOS Swift file counter
expected deliverable: macOS Swift file count and relevant path list
workspace lease: macOS workspace/path scope only
capability lease:
  canReadWorkspace
  canSearchWorkspace
  canSendMessage
  canRequestInformation
  no canDelegateTask
  no canAttachWorkspace
related agents: @main, @ios-counter
related tasks: task-root-count, task-count-ios
constraints:
  Do not count iOS files.
  Do not create or spawn agents.
  Report result to @main.
```

iOS TaskContract:

```text
task id: task-count-ios
issuer: @main
assignee: @ios-counter
parent task id: task-root-count
objective: Count Swift files in the iOS workspace scope.
role hint: iOS Swift file counter
expected deliverable: iOS Swift file count and relevant path list
workspace lease: iOS workspace/path scope only
capability lease:
  canReadWorkspace
  canSearchWorkspace
  canSendMessage
  canRequestInformation
  no canDelegateTask
  no canAttachWorkspace
related agents: @main, @macos-counter
related tasks: task-root-count, task-count-macos
constraints:
  Do not count macOS files.
  Do not create or spawn agents.
  Report result to @main.
```

Projected context for `@macos-counter`:

```text
Global brief:
  The user wants separate macOS and iOS Swift file counts.

Lineage:
  User asked for two agents to count macOS and iOS Swift files.
  @main split the task into two child tasks.
  @main assigned macOS counting to @macos-counter.
  @ios-counter is independently assigned the iOS count task.

Current task:
  You are responsible only for the macOS count.

Allowed tools:
  Read/search within the macOS workspace lease.
  Send result or clarification messages to @main.

Disallowed:
  Do not spawn @ios-counter.
  Do not spawn another @macos-counter.
  Do not ask_agent or send a task to yourself.
  Do not reinterpret the global request as your own decomposition task.
```

Expected behavior:

```text
@macos-counter does not re-spawn @ios-counter
@macos-counter does not re-spawn @macos-counter
@macos-counter does not self-call
@macos-counter returns only the macOS result
@ios-counter returns only the iOS result
@main performs the final synthesis
```

## 11. Required Invariants

These invariants must be enforced by code:

```text
AgentLoop does not synchronously call AgentLoop
caller == target is rejected by default
workspace expansion requires permission confirmation
tool exposure is determined by CapabilityLease
agent context is generated by ContextProjector
Agent does not read the full global history by default
delegation creates a TaskContract
Agent-to-Agent message is written to the event log
TaskGraph detects cycles
```

Additional invariants:

```text
Agent identity does not imply coordinator rights
roleHint does not grant tools by itself
CapabilityLease cannot grant workspace access without a WorkspaceLease
communication does not create hidden tasks
delegation budget is checked before task creation
event visibility is honored during context projection
```

## 12. Migration Notes

Migration order:

```text
1. First stop child agents from receiving coordinator tools by default.
2. Add a self-call guard to ask_agent.
3. Demote coordinationDepth to a safety fuse, not role semantics.
4. Introduce TaskContract.
5. Introduce ContextProjector.
6. Introduce CapabilityLease.
7. Split ask_agent into communication and delegation.
8. Replace synchronous nested AgentLoop with Scheduler.
```

Implementation guidance:

```text
Keep each step narrow.
Do not redesign the GUI as part of invocation migration.
Do not remove existing safety fuses while replacing their semantic use.
Prefer adapters that can translate current ask_agent/spawn_agent calls into
TaskContract and MessageBus events during migration.
```

## 13. Tests To Add

Required tests for later implementation:

```text
worker cannot spawn without delegation lease
worker cannot ask itself
agent context includes lineage
agent context does not include unrelated raw global transcript
capability lease controls tool registry
delegation creates TaskContract
communication does not create TaskContract
scheduler prevents AgentLoop recursion
task graph rejects A -> B -> A cycle
macOS/iOS counter scenario completes without nested spawning
```

Useful additional tests:

```text
workspace expansion requires permission
attach workspace is not treated as read-only
worker prompt does not advertise coordinator powers
TaskContract appears in generated context
agent-to-agent event records sender, recipient, taskID, and causalParentID
worker tool surface exposes neither delegation nor spawn_agent
coordinationDepth limit remains only as a safety fuse
```
