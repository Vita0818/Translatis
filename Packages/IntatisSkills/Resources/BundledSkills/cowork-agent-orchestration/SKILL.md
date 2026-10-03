---
name: cowork-agent-orchestration
description: Plan, track, route, and finish Intatis Cowork work through Codex native V2 subagents, including direct work versus spawn, host-approved agent_type inference presets, host-approved workspace presets, durable WorkTask cards, child messaging and waiting, least authority, and evidence-backed completion.
---

# Cowork agent orchestration

Use this procedure before creating or steering a Cowork subagent. This Skill is
context, not authority: it cannot add tools, models, credentials, workspaces,
permissions, agents, or budgets.

## Hard boundaries

- Treat the current tool schemas as authoritative. `spawn_agent`, `send_message`,
  `followup_task`, `wait_agent`, `list_agents`, and `interrupt_agent` are Codex
  control-plane tools. Do not recreate them with shell, MCP, an Intatis agent
  manager, or prose.
- Every `agent_type` shown by `spawn_agent` is one complete host-approved inference
  preset. It already fixes the model, provider route, credential reference,
  reasoning setting, and request options. Choose only an advertised value. Never
  invent or submit a raw endpoint, credential, provider, model option, or unlisted
  model.
- Every `workspace` shown by `spawn_agent` is one user-approved directory preset.
  Choose only an advertised value. Never submit a raw path as a substitute. Omit
  `workspace` to inherit the caller's exact directory and access policy.
- Omit `agent_type`, `model`, and `reasoning_effort` when a different approved
  profile is not clearly required. The child then inherits the parent selection.
  If this host hides raw `model` or `reasoning_effort` fields, do not look for a
  workaround; use an advertised `agent_type` or inherit.
- WorkTask tools create and update user-visible plan cards only. They never create,
  queue, run, wait for, resume, or close a Codex agent.
- A child result is candidate evidence. It does not by itself complete a WorkTask,
  Goal, or user request.
- A multi-call assistant response is not a transaction and does not guarantee
  execution order. Any ID, task name, agent, or state created by one call becomes
  usable only after its successful ToolResult.

## Drive the request

1. Derive the concrete objective, deliverables, constraints, affected workspace,
   and verification method from the user request.
2. For a non-trivial request, use `task_create` when it is advertised to record the
   smallest useful graph of verifiable WorkTasks. Keep task state, result, and
   evidence current; do not maintain a conflicting prose-only scheduler.
3. Decide which work must remain local and which bounded branches can proceed
   independently. Spawn only when parallelism, specialization, a different approved
   workspace, an explicitly different approved inference preset, or an independent
   review materially repays coordination cost.
4. Continue useful work on the current critical path after spawning. Do not wait
   idly while an independent child is running.
5. Read and verify child results. Update a WorkTask to completed only with a
   non-empty result and the evidence required by its acceptance criteria.
6. Finish only when the user's requested outcome is verified or a genuine blocker
   remains. Use ordinary final response text; do not call removed legacy run-control
   tools.

## Decide direct work versus a child

Work directly when the task is short, tightly coupled, needs one coherent context,
or would take no more effort than specifying and validating a child task. Spawn a
child only when at least one is true:

- two or more independent deliverables can run in parallel;
- a bounded specialist investigation or independent review materially lowers risk;
- the task belongs in a different advertised workspace preset;
- an explicitly different advertised inference preset is justified by capability,
  cost, latency, or user instruction;
- the child will own several related follow-ups and therefore benefits from a
  persistent Codex thread;
- the user explicitly requests multi-agent execution.

Do not split a serial chain merely to create agents. Avoid simultaneous overlapping
writes unless the user has explicitly accepted that risk and the workspaces or
artifact sets are demonstrably disjoint.

## Choose an approved inference preset

Use the following gates in order:

1. Derive the exact input and output capabilities needed by the child task.
2. Consider only `agent_type` values present in the current `spawn_agent` schema.
   Their descriptions are the host-approved safe catalog for this invocation.
3. Reject any option whose declared capabilities do not cover the task. An absent or
   unspecified capability is not proof of support.
4. Prefer inheritance when several presets are adequate and no meaningful route
   change is justified.
5. When an explicit different preset remains useful, read
   `references/model-routing.md`. Its dated matrix can rank already-advertised
   choices; it cannot create a route, capability, endpoint, credential, or option.

For visual, audio, or media work, use a companion only when an advertised preset
explicitly declares every required input/output capability and the actual artifact
can be delivered to that child. Otherwise report the exact blocker.

## Choose an approved workspace

- Keep the child in the inherited workspace unless another advertised workspace is
  necessary for the deliverable.
- When `spawn_agent` advertises `workspace`, select only one listed preset ID whose
  description matches the assigned work. The host binds its canonical directory and
  workspace roots after the call; the model does not author them.
- A configured custom role uses the same preset ID for `agent_type` and `workspace`.
  When choosing an explicit role, pass its matching workspace value; never combine
  one role with another role's directory.
- If the necessary directory is not listed, do not guess a path or ask shell tools
  to escape the current workspace. Report that the directory requires user approval.
- Default to the least access advertised for the preset. A read-only reviewer does
  not need write authority.

## Spawn and communicate causally

For a recorded WorkTask and a new child:

1. Call `task_create` and wait for its successful result if a durable card is useful.
2. In a later tool-call round, call `spawn_agent` with a concrete, bounded message,
   unique lowercase `task_name`, and only the justified advertised `agent_type` and
   `workspace` presets. Do not pass a planned WorkTask or agent as though it already
   exists.
3. Wait for the successful spawn result. The returned canonical task name is the
   only target identity for later Codex communication.
4. If `task_link_agent` is advertised and a WorkTask was created, call it in a
   later round with that exact canonical task name and the WorkTask's current
   revision. This records the relationship only; it does not schedule either side.
5. Use `send_message` for queued information that should not start a turn. Use
   `followup_task` when the child is idle and must act on a new bounded request.
6. Use `wait_agent` only when the next local step genuinely depends on the result.
   Use `interrupt_agent` only to stop or redirect work, not as routine cleanup.

Full-history forks inherit the parent's model, reasoning, workspace, tools, and
surrounding context. When an advertised agent/workspace preset must differ, use the
non-full fork mode required by the current `spawn_agent` schema. All fork modes must
still retain the host-registered business-tool surface; if the runtime does not,
report a runtime failure rather than substituting another backend.

## Give a child a bounded contract

Include only what it needs:

- concrete objective and expected deliverable;
- relevant advertised workspace choice and paths within it;
- acceptance criteria and required evidence;
- read/write expectations;
- constraints, exclusions, and what must be reported back.

Do not forward secrets or an entire transcript when a focused context is enough.
Do not ask a child to create another child unless the task truly contains an
independent subgraph and the current tool/host policy permits it.

## Settle and synthesize

- Verify file changes, commands, citations, calculations, and acceptance evidence in
  proportion to risk.
- Use `task_get` before an update when the latest revision is uncertain. Send only
  fields that actually change and preserve `expected_revision` compare-and-set.
- Do not infer Goal completion from all children becoming idle. Native Codex Goal
  state remains authoritative; Intatis validation information is supplementary.
- Replan only the failed branch. Reuse a suitable existing child with
  `followup_task` instead of reflexively spawning replacements.
- Return one synthesized result containing verified outcomes, unresolved risks, and
  any exact capability, workspace, provider, or permission blocker.
