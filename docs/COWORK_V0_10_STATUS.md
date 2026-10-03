# Intatis Cowork v0.10 Status

> **历史文档：冻结于 v0.10 迁移阶段。** 本文只保留设计/迁移 provenance，不是当前
> 状态、测试或实现事实源。产品基线与当前规则见 `docs/VERSIONING.md`、
> `docs/COWORK_PRINCIPLES.md`、`docs/ARCHITECTURE.md` 和 `docs/CURRENT_STATE.md`。

This document summarizes the v0.10 Cowork Agent Invocation architecture after the Phase 0-8 migration pass.

## Implemented

```text
TaskContract
ContextProjection / ContextBundle
CapabilityLease / WorkspaceLease model
Message / Delegation split
Scheduler / Mailbox minimum implementation
TaskGraph cycle detection
Semantic Cowork events
CoworkProjection replay
Phase 8 fixture-based E2E validation
```

Implemented behavior:

```text
worker tasks receive TaskContract identity, objective, role hint, expected deliverable, constraints, leases, and related agents
worker tool registry is derived from CapabilityLease and excludes coordinator tools by default
ask_agent self-call is rejected
send_message, request_information, reply_message do not create TaskContract
delegate_task creates TaskContract and passes through TaskGraph validation before scheduler enqueue
Scheduler queues target work and prevents direct nested AgentLoop recursion
ContextProjection gives workers lineage and scoped context instead of raw global transcript history
CoworkProjection replays task state, roster, mailboxes, leases, messages, and delegation status
```

## Partial

```text
GUI mailbox / task graph UI
Scheduler persistence / recovery
Full lease enforcement across all file/shell/patch tools
Versioned event migration
Full task graph inspector in GUI
Manual end-to-end cowork smoke
```

Partial behavior:

```text
GUI consumes semantic events through existing projections, but does not yet expose a full operational task graph console
Scheduler records events and in-memory execution records, but does not restore queued work from disk after restart
CapabilityLease controls Cowork tool exposure, but lower-level file/shell/patch tools are not fully lease-native everywhere
Event additions are Codable-compatible and optional-metadata based, but no formal event schema version migration exists yet
```

## Planned

```text
Automatic permission reviewer
Full GUI Cowork inspector
Persistent scheduler recovery
Lease-native bottom tools for file/search/shell/patch
iOS remains non-local-agent subset
Multimodal integration with Cowork artifacts
```

## Known Risks

```text
in-memory scheduler
manual smoke still required
bottom tools not fully lease-native
GUI not complete operational console yet
event schema still additive rather than version-migrated
manual provider-backed cowork runs can still expose model behavior not covered by deterministic tests
```

## Manual Smoke Steps

Use the detailed checklist in `docs/COWORK_V0_10_SMOKE.md`.

Minimum closure commands:

```bash
swift test --quiet
swift run intatis --help
xcodegen generate
```

Manual CLI cowork flow:

```text
1. swift run intatis
2. /mode cowork
3. approve @main workspace attach
4. ask @main to create macOS and iOS Swift counters
5. confirm worker agents do not spawn, self-call, or re-run global decomposition
6. confirm results return to @main
7. confirm semantic replay preserves task and mailbox state
```
