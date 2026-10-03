# Intatis Cowork Task and Context Model

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This document defines the desired task-scoped and context-scoped model for Intatis Cowork.

## 1. Problem

A multi-agent system fails if every agent receives the full transcript and a generic set of tools.

Agents need to know:

```text
What is the global goal?
Why am I here?
Who assigned this task to me?
What is my exact role in this task?
What is my workspace?
What should I return?
What can I share?
What can I delegate?
```

But they should not automatically see or act on unrelated global instructions.

## 2. Event Scope

Every event should have scope metadata.

Suggested event metadata:

```swift
struct ScopedEventMetadata {
    let threadID: ThreadID
    let taskID: TaskID?
    let taskGroupID: TaskGroupID?
    let sender: ParticipantID
    let recipients: [ParticipantID]
    let scope: ContextScope
    let visibility: Visibility
    let causalParentID: EventID?
}
```

Suggested visibility:

```swift
enum Visibility {
    case global
    case taskGroup(TaskGroupID)
    case task(TaskID)
    case agent(AgentID)
    case agents([AgentID])
    case privateAgent(AgentID)
}
```

## 3. Context Projection

An agent should receive a `ContextBundle`, not a raw transcript.

Suggested shape:

```swift
struct ContextBundle {
    let globalBrief: String
    let safetyPolicy: String
    let taskContract: TaskContract
    let lineage: [LineageItem]
    let relevantMessages: [ScopedEvent]
    let workspaceBrief: WorkspaceBrief?
    let artifacts: [ArtifactDescriptor]
    let allowedTools: [ToolDescriptor]
}
```

The projector should answer:

```text
What does this agent need for this task?
What does this agent have permission to know?
What must be hidden or summarized?
```

## 4. Lineage Projection

A spawned or selected agent should see its own lineage.

Example:

```text
1. User requested Swift file counts for macOS and iOS.
2. @main split the work into two tasks.
3. @main assigned macOS counting to @macos-counter.
4. @ios-counter was assigned the iOS part.
5. This task's expected deliverable is count + path list.
```

This is different from giving the raw global transcript. The lineage is causal and compact.

## 5. Shared Context

Some context is global and should be visible to all agents:

```text
user's top-level objective
project safety policy
current agent roster
public task graph summary
explicitly shared results
public artifacts
```

Some context should be local:

```text
agent's own tool calls
agent's private scratch messages
workspace file contents
other agent's detailed observations
unshared source snippets
```

## 6. TaskContract

A task should be the basic unit of work.

Suggested fields:

```swift
struct TaskContract: Codable, Sendable {
    let id: TaskID
    let kind: TaskKind
    let issuer: ParticipantID
    let assignee: AgentID
    let parentTaskID: TaskID?

    let objective: String
    let roleHint: String
    let expectedDeliverable: String

    let workspaceLeaseID: WorkspaceLeaseID?
    let capabilityLeaseID: CapabilityLeaseID

    let relatedAgents: [AgentID]
    let relatedTasks: [TaskID]
    let constraints: [String]
}
```

## 7. CapabilityLease

A capability lease grants tools for one task.

Suggested fields:

```swift
struct CapabilityLease: Codable, Sendable {
    let id: CapabilityLeaseID
    let taskID: TaskID
    let tools: Set<ToolCapability>
    let communication: CommunicationGrant
    let delegation: DelegationGrant
    let expiresAtTaskCompletion: Bool
}
```

Suggested tool capabilities:

```swift
enum ToolCapability {
    case readFile
    case listFiles
    case searchText
    case runShell
    case proposePatch
    case applyPatch
    case sendMessage
    case requestInformation
    case delegateTask
    case attachWorkspace
}
```

## 8. CommunicationGrant

Communication should be scoped.

```swift
enum CommunicationGrant {
    case none
    case replyOnly
    case selectedAgents(Set<AgentID>)
    case taskGroup(TaskGroupID)
    case anyAgentInThread
}
```

A simple worker might only have:

```text
replyOnly + selectedAgents([@main])
```

A cowork reviewer might have:

```text
selectedAgents([@main, @frontend, @backend])
```

## 9. DelegationGrant

Delegation should be explicit.

```swift
enum DelegationGrant {
    case none
    case granted(DelegationBudget)
}
```

`granted` means it may delegate within a specified budget.

## 10. WorkspaceLease

Workspace access should be explicit and task-bound.

```swift
struct WorkspaceLease: Codable, Sendable {
    let id: WorkspaceLeaseID
    let workspaceID: WorkspaceID
    let rootURL: URL
    let access: WorkspaceAccess
    let allowedPaths: [PathRule]
    let deniedPatterns: [String]
}
```

Every file, shell, patch, and search tool should use the lease rather than raw path strings.

## 11. Prompt Construction

The system prompt for an agent should include:

```text
You are Agent <name>.
You are executing Task <id>.
Your role in this task is: <roleHint>.
You were assigned by: <issuer>.
Your objective is: <objective>.
Your expected deliverable is: <expectedDeliverable>.
Your workspace is: <workspace>.
Your allowed capabilities are: <capabilities>.
Your delegation permission is: <delegation>.
Do not perform unrelated parts of the global task.
Do not create or call other agents unless your capability lease explicitly allows it.
If you need help without delegation capability, report the blocker in your response. Only an agent with an explicit coordinator lease may use `delegate_task`.
```

This prompt should be generated from state, not hand-written per scenario.

## 12. Key Design Rule

Do not depend only on prompt text.

The prompt helps the model behave well, but the kernel must enforce:

```text
tool exposure
workspace leases
communication grants
delegation grants
cycle detection
self-call rejection
event visibility
```
