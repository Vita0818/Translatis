# Intatis Cowork Current Findings

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This document summarizes the read-only findings about the current Cowork invocation behavior and why a child agent attempted to spawn or ask itself.

## 1. Observed Behavior

In a Cowork session, the user asked:

```text
现在拉起两个子Agent，分别对本文件夹下的macOS和iOS Swift文件进行计数
```

Observed flow:

```text
@main
  ├─ spawned @macos-counter
  ├─ spawned @ios-counter
  └─ asked @macos-counter to count macOS Swift files

@macos-counter
  ├─ explored its workspace
  ├─ attempted to spawn @macos-counter again
  ├─ attempted to spawn @ios-counter again
  └─ attempted ask_agent(to: macos-counter)
```

This is not merely a model hallucination. The system made the behavior plausible by giving a first-level child agent coordinator tools and global history.

## 2. Actual Current Mechanism

According to the read-only inspection:

- Cowork has a `coordinationDepth` mechanism.
- `@main` and GUI/CLI manually added agents default to `coordinationDepth = 2`.
- A model-spawned child receives `parent.coordinationDepth - 1`.
- Therefore, the first child receives `coordinationDepth = 1`.
- If `coordinationDepth > 0`, the agent can receive coordinator tools such as:
  - `spawn_agent`
  - `ask_agent`
  - `list_agents`
  - `remove_agent`

This means the first-level child is not a pure worker. It is still treated as a coordinator-capable agent.

## 3. Why the Child Tried to Spawn Agents

The root cause is the combination of several design choices:

```text
1. Default coordinationDepth = 2.
2. First-level child still has coordinationDepth = 1.
3. Child receives coordinator tools.
4. Child system prompt says it can act as coordinator when depth > 0.
5. Child reads global conversation history.
6. The global history includes the user's original instruction to spawn two agents.
7. Child interprets the global instruction as still relevant to itself.
```

So the child tries to perform task decomposition again.

## 4. Why Self-call Was Possible

The current `ask_agent` path does not reject:

```text
caller == target
```

Also:

- `ask_agent` creates a new `AgentLoop` for the target.
- If caller and target are the same, this creates a fresh loop for the same agent.
- There is no graph-level delegation depth, call count, causal chain, or visited-agent guard.
- Single-loop `maxIterations` does not stop cross-agent recursion.

Therefore, a self-call can recursively create new execution loops.

## 5. Why `coordinationDepth` Is Not the Right Semantic Model

`coordinationDepth` is useful as a circuit breaker, but it should not define agent roles.

Problems:

```text
- It hardcodes an artificial hierarchy.
- It conflates role, permission, and recursion budget.
- It gives child agents coordinator powers by numeric accident.
- It does not express task intent.
- It does not explain to the agent why it was created.
- It does not isolate context.
```

The target architecture should replace semantic use of `coordinationDepth` with:

```text
TaskContract
CapabilityLease
ContextProjection
TaskGraph
Scheduler
```

A low-level max-depth guard can still exist as a safety fuse, but not as the primary role model.

## 6. Immediate Minimal Fixes

Before the larger architecture migration, the current implementation should be hardened.

### P0

```text
1. First-level spawned child should default to no coordinator tools.
2. `ask_agent` must reject caller == target.
3. `spawn_agent` should not be `.readOnly`.
4. `spawn_agent` should be treated as workspace/capability expansion.
5. `ask_agent` should include causal chain or hop count.
6. The worker prompt must not advertise coordinator powers unless explicitly granted.
```

### P1

```text
1. Add AgentCapabilities or CapabilityLease.
2. Separate coordinator tool registry from worker tool registry.
3. Add max delegation hops and cycle detection.
4. Add per-agent/per-task context projection.
5. Add parentTaskID / taskID / causal chain to agent-to-agent events.
```

## 7. Desired New Behavior for the Count Scenario

The desired behavior is:

```text
@main sees the global task.
@main creates @macos-counter and @ios-counter.
@macos-counter sees:
  - it was created by @main
  - @main already split the task
  - it is assigned only macOS counting
  - @ios-counter is assigned iOS counting
  - it has no delegation capability for this task
@macos-counter counts macOS Swift files and returns result.
@ios-counter counts iOS Swift files and returns result.
@main synthesizes the final answer.
```

The child agent should understand its lineage, not receive raw global history that makes it re-run orchestration.

## 8. Tests to Add

Suggested tests:

```text
child cannot see spawn_agent unless capability lease grants delegation
child cannot ask itself
child receiving a count task does not receive the raw global spawn instruction as a fresh command
worker prompt does not say it can coordinate
task contract includes issuer, assignee, objective, roleHint, expectedDeliverable
context projection contains lineage but not unrelated global transcript
agent-to-agent call includes taskID and causal chain
delegation cycle is rejected
```
