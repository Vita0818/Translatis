# Intatis Cowork Migration Plan

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This document describes a staged migration from the current Cowork implementation toward a task-scoped, capability-scoped multi-agent architecture.

## Phase 0: Immediate Safety Patch

Goal: stop the observed recursive behavior with minimal code changes.

Required changes:

```text
1. Spawned child agents default to no coordinator tools.
2. `ask_agent` rejects caller == target.
3. `spawn_agent` is no longer `.readOnly`.
4. Worker prompt must not advertise coordinator behavior.
5. Add simple delegation hop / causal chain metadata to `ask_agent`.
```

Do not redesign everything in this phase.

## Phase 1: TaskContract Introduction

Add minimal task types without replacing all existing logic.

Introduce:

```text
TaskID
TaskContract
TaskKind
TaskStatus
TaskEvent
```

When `@main` asks another agent to do work, create a `TaskContract`.

Every `ask_agent` / delegated task should know:

```text
issuer
assignee
objective
roleHint
expectedDeliverable
parentTaskID
workspace
capabilityLease
```

## Phase 2: Context Projection

Replace global `priorHistory()` usage with a scoped context projector.

Introduce:

```text
ContextProjector
ContextBundle
LineageProjection
```

The agent should see:

```text
global brief
task contract
lineage
direct messages
own history
explicitly shared artifacts
workspace brief
```

It should not automatically see unrelated raw transcript.

## Phase 3: CapabilityLease

Replace `coordinationDepth` as the source of tool exposure.

Introduce:

```text
CapabilityLease
ToolCapability
DelegationGrant
CommunicationGrant
WorkspaceLease
```

Tool registry construction should use the lease:

```text
worker lease      → no coordinator tools
coordinator lease → can delegate within budget
reviewer lease    → can inspect, not modify
```

## Phase 4: Message / Delegation Split

Replace overloaded `ask_agent`.

Introduce:

```text
send_message
request_information
reply_message
delegate_task
```

Semantics:

```text
message operations do not create new tasks
delegation operations create tasks
workspace expansion is always mediated
```

## Phase 5: Scheduler

Replace synchronous nested AgentLoop calls.

Introduce:

```text
Scheduler
Mailbox
TaskQueue
ExecutionRecord
```

Behavior:

```text
AgentLoop submits messages/tasks.
Scheduler runs target agent independently.
Caller observes result events.
AgentLoop does not directly recurse into another AgentLoop.
```

## Phase 6: TaskGraph Cycle Detection

Introduce graph-level checks:

```text
self-call rejection
A → B → A cycle rejection
max task hops
max task count
max active agents
max delegation budget
duplicate task detection
```

These are safety fuses, not the main role model.

## Phase 7: Event Schema Improvements

Add explicit events:

```text
task_created
task_assigned
task_started
task_completed
task_failed
delegation_requested
delegation_approved
delegation_rejected
agent_spawn_requested
agent_spawned
agent_message
agent_result
```

Existing generic tool events may stay, but Cowork should have semantic events.

## Phase 8: Tests

Add tests for:

```text
worker cannot spawn without lease
worker cannot ask self
worker sees lineage but not raw global spawn instruction
coordinator can delegate within budget
delegation cycle is rejected
workspace expansion requires permission
task contract is present in agent prompt
capability lease controls tool registry
context projection filters unrelated events
```

## Non-goals

Do not do these during the migration:

```text
Do not remove Chat/Code surfaces.
Do not redesign the whole GUI first.
Do not implement automatic permission reviewer while task/capability model is unstable.
Do not make iOS support local agents.
Do not add more model providers as part of this migration.
```

## Success Criteria

The migration is successful when:

```text
@main can create @macos-counter and @ios-counter.
@macos-counter understands it was created by @main for the macOS count task.
@macos-counter does not try to spawn or call other agents unless its task lease grants delegation.
@ios-counter works independently.
@main receives both results and synthesizes the final answer.
All events are recorded.
No AgentLoop directly recurses into another AgentLoop.
```
