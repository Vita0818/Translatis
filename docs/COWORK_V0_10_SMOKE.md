# Intatis Cowork v0.10 Smoke Checklist

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This checklist validates the v0.10 Cowork Agent Invocation architecture after the automated test suite passes.

## 1. Build And Test

Run from the repository root:

```bash
swift test
swift run intatis --help
```

If XcodeGen is available:

```bash
xcodegen generate
```

Optional macOS app build:

```bash
xcodebuild -scheme IntatisMac build
```

Run the Xcode build only when validating the app target. The SwiftPM tests are the primary automated validation for the Cowork invocation model.

## 2. Manual CLI Cowork Smoke

1. Enter the Intatis repository.
2. Run:

   ```bash
   swift run intatis
   ```

3. Switch to Cowork:

   ```text
   /mode cowork
   ```

4. Allow `@main` to attach the current workspace when prompted.
5. Send:

   ```text
   拉起两个子 Agent，分别对 Apps/IntatisMac 和 Apps/IntatisiOS 下的 Swift 文件计数。
   ```

6. Observe the session:

   ```text
   @main creates or uses two worker agents.
   @main assigns one macOS counting task and one iOS counting task.
   Each worker receives a scoped TaskContract.
   Workers do not spawn agents.
   Workers do not call ask_agent on themselves.
   Workers count only their assigned workspace scope.
   Worker results return to @main for synthesis.
   ```

## 3. Expected Semantic Events

A healthy run should include these semantic events:

```text
agent_attach_requested
workspace_lease_requested
workspace_lease_granted
capability_lease_created
agent_attached
task_created
task_assigned
delegation_approved
task_delegated
task_queued
task_started
task_completed
agent_result or message_completed
```

Rejected or denied paths should include:

```text
delegation_rejected
task_rejected
workspace_lease_denied
permission_resolved
```

## 4. Failure Criteria

Treat any of these as a v0.10 Cowork invocation failure:

```text
worker attempts spawn_agent
worker attempts delegate_task
worker uses ask_agent to call itself
worker receives spawn_agent, remove_agent, list_agents, ask_agent, or delegate_task in its tool registry
worker sees the full raw global transcript as a fresh user command
Scheduler runs a target AgentLoop inside caller tool execution instead of queueing work
TaskGraph accepts A -> B -> A or A -> B -> C -> A delegation
duplicate active worker task is queued under the same parent
event replay loses task status after task_queued/task_started/task_completed
CoworkProjection cannot reconstruct agent roster, leases, mailboxes, or completed tasks
```

## 5. Focused Automated Coverage

The Phase 8 E2E tests cover the main smoke path without relying on a live model:

```text
CoworkEndToEndTests
  macOS/iOS Swift count fixture
  worker scoped context and task contract
  worker capability/tool surface
  no nested spawn or direct delegate
  no self-call scheduling
  semantic replay through CoworkProjection
```
