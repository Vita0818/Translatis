# OpenAI Codex App Server external runtime

## Upstream identity

- Project: OpenAI Codex (`https://github.com/openai/codex`)
- Adopted release: `rust-v0.145.0`
- Annotated tag object: `1635de866c61d1b76e50b31928ee6d61482435a8`
- Fixed source commit: `25af12f7e61572b0bc18ddb1008be543b91519b0`
- Copyright: Copyright 2025 OpenAI
- Root license: Apache License 2.0
- Root LICENSE SHA-256:
  `d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc`
- Root NOTICE SHA-256:
  `9d71575ecfd9a843fc1677b0efb08053c6ba9fd686a0de1a6f5382fd3c220915`

The upstream NOTICE reads:

> OpenAI Codex
>
> Copyright 2025 OpenAI
>
> This project includes code derived from Ratatui, licensed under the MIT
> license. Copyright (c) 2016-2022 Florian Dehau; Copyright (c) 2023-2025 The
> Ratatui Developers.

The complete Apache-2.0 text already preserved for the same upstream project
and release is at
`ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`.

## Reuse classification and local integration

- Reuse type: `derived external-runtime` + official App Server API plus one
  narrow derived experimental control-plane method.
- Reproducible patch set, applied in order:
  `ThirdPartyPatches/OpenAICodexRuntime/0001-responses-provider-passthrough.patch`,
  `0002-openrouter-strict-routing-shape.patch`, and
  `0003-cowork-subagent-reconnection.patch`.
- Local Swift host:
  `Packages/IntatisCodexRuntime/Sources/`.
- Provider projection:
  `Packages/IntatisProviders/Sources/ResponsesRuntimeRoute.swift`.
- macOS product wiring:
  `Apps/TranslatisMac/Sources/CodeViewModel.swift` and
  `Apps/TranslatisMac/Sources/CoworkViewModel.swift`.
- CLI wiring:
  `Apps/translatis-cli/Sources/CodexRuntimeCLI.swift`.
- Tests:
  `Packages/IntatisCodexRuntime/Tests/CodexRuntimeTests.swift`.

No complete Codex Rust source tree is copied into the Translatis repository. The
first checked-in patch adds a request-owned opaque JSON channel for exactly
the top-level Responses `provider` object and tests unknown nested fields for
lossless HTTP/WebSocket serialization. The second patch uses that explicit
marker to omit Codex-generated optional OpenAI controls that the exact
OpenRouter route did not declare, without URL/name inference or protocol
translation. No local Swift implementation substitutes for Codex's agent loop, tool
orchestration, sandbox, approval review, context management, thread/turn/item lifecycle, or
subagent runtime. The Swift target is limited to executable discovery and
version verification, process lifecycle, newline-delimited JSON-RPC,
Translatis-provider configuration, owner-only thread identity, and projection
onto existing Intatis UI/event types.

The third patch keeps that ownership boundary while reconnecting the existing
MultiAgent V2 and App Server extension points. It explicitly carries the
parent's registered App Server `dynamic_tools` into children for no-history,
full-history, and positive last-N forks; adds strict host-supplied
`intatis_agent_workspaces` presets with absolute cwd, exact parent-approved
runtime roots, safe descriptions, and `read-only`/`workspace-write` sandbox
selection; and adds the explicit `flat_tools` mode so V2 collaboration tools
remain ordinary top-level Responses functions without provider-name or URL
inference. Its experimental `thread/subagent/message` method verifies the
root/descendant relationship twice and routes the host message through the
root thread's existing `AgentControl` mailbox, not through a provider or the
retired Intatis message bus. Model-authored V2 messages use ordinary plaintext
mailbox content instead of an OpenAI-internal encrypted-content envelope, so
third-party Responses providers deliver the task without a provider adapter.
Persisted relationship listings also retain spawned descendants whose preview
is empty because they received only inter-agent input; the ordinary global
thread-list preview filter remains unchanged.

The integration accepts exactly `codex-cli 0.145.0-intatis.4`, built from the
fixed upstream commit plus the checked-in patch set. It uses stable stdio App
Server methods including `initialize`, `thread/start`, `thread/resume`,
`turn/start`, `turn/interrupt`, stable item/turn notifications, server-initiated
command/file/permission approvals, and stable thread Goal methods. Cowork also
uses the pinned official experimental dynamic-tool/native-descendant APIs and
the derived experimental `thread/subagent/message` method. App Server
initialization explicitly enables experimental APIs for that exact Cowork
surface; there is no local rollout scanner or legacy-kernel substitute.

## Authentication and provider boundary

Translatis does not use Codex's ChatGPT login flow. Each process receives an
isolated session-owned `CODEX_HOME`; thread configuration selects an
`translatis` model provider with `wire_api = "responses"` and
`requires_openai_auth = false`. The exact credential resolved by Translatis is
placed only in a request-specific child-process environment variable. It is
not written to `runtime.json`, `models.json`, EventLog, project documentation,
or command-line arguments.

For an exact OpenRouter route, Translatis takes the already-decoded
`options.provider` object after recursive secret/transport-key scanning and
structural resource validation, then supplies it as
`intatis_responses_provider` in the custom-provider config. The derived runtime
clones the object into `ResponsesApiRequest.provider` without enumerating,
interpreting, renaming, or merging its children. Provider-owned future fields
therefore cross unchanged. There is no control header, OpenRouter parser,
generic whole-request `extra_body`, protocol translator, or proxy; this object
cannot override host-owned `model`, `input`, `tools`, `stream`, or `reasoning`.

When and only when that explicit OpenRouter marker is present, the derived
runtime removes a host-unadvertised reasoning summary and omits optional
`include`, `parallel_tool_calls`, `prompt_cache_key`, and `client_metadata`
controls generated by upstream Codex. Translatis configures upstream's official
`web_search = "disabled"`, enables MultiAgent V2 for Cowork, and explicitly
sets the third patch's provider-agnostic `flat_tools = true`. The exact
OpenRouter request therefore keeps native V2 collaboration and registered
dynamic business tools as ordinary top-level functions while making no claim
of OpenAI-specific hosted web-search or namespace-tool support. Translatis
preserves the user's strict provider routing object, including
`require_parameters`; it does not relax routing or silently choose another
provider.

Codex's official `shell_environment_policy` is set to inherit only core shell
variables, enable the runtime's default `*KEY*` / `*SECRET*` / `*TOKEN*`
exclusions, and explicitly exclude `INTATIS_*`, `TRANSLATIS_*`, plus `CODEX_HOME`. The provider
credential is therefore available to the App Server HTTP client but not to
agent-launched shell children. Codex 0.145.0's stable `shell_snapshot` feature
captures the parent process environment before that tool filter, so this
integration explicitly disables that official feature; otherwise it would
persist the provider token below `CODEX_HOME/shell_snapshots`. If an isolated
home already contains that directory from an older configuration, startup
fails before credential injection and requires a new session; Translatis does not
inspect, rewrite, or delete potentially sensitive snapshots.

The generated owner-only `models.json` uses Codex's official
`model_catalog_json` extension point. It binds `auto_review_model_override` to
the same selected Responses model so a third-party endpoint is never silently
asked for an unrelated OpenAI model. This is configuration of the upstream
runtime, not a replacement reviewer implementation. The catalog advertises
only the configured reasoning effort and does not invent reasoning-summary or
parallel-tool support.

## Persistence and migration boundary

Every Translatis Code/Cowork session owns `codex-runtime/` beside its EventLog:

- `codex-home/` is the isolated upstream runtime home and rollout store;
- `runtime.json` is an owner-only schema-v2 mapping to an exact, materialized
  Codex thread. A thread created and closed before its first accepted turn is
  not recorded, so the next open may safely create another empty thread;
- `models.json` is the non-secret fixed model catalog supplied to Codex.
- `runtime.lock` is a safe owner-only `flock` lease; only one process may own
  the session's Codex home/thread at a time. Host shutdown releases it only
  after observing process exit; a TERM timeout escalates to KILL, and an
  unconfirmed exit keeps the lease through deferred retirement.

Codex rollout history is authoritative for future model context. Translatis
EventLog remains the UI/audit projection and intentionally stores only bounded,
redacted presentation facts for Codex tool items. A legacy Intatis agent
session without `runtime.json` is not auto-migrated or silently replayed into a
new Codex thread; it fails clearly and requires a new session. The current
`.4` host accepts only a schema-v2 record whose `runtimeVersion` is exactly
`0.145.0-intatis.4`, whose `derivationID` matches the exact checked-in patch
hash, whose ThreadID is materialized, and whose optional dynamic-toolset
identity matches the currently registered business-tool surface. Every prior
runtime version or same-version/different-derivation record is rejected rather
than silently resumed under the new subagent/tool contract.

Historical note: the former `.3` host briefly allowed one exact `.2` to `.3`
mapping after an identical official `thread/resume`/ThreadID check. That was
the migration policy of the earlier two-patch runtime, not a current migration
path; `.4` removed it and requires a new session for every prior record.

## Local arm64 build evidence (not a release artifact)

The current 2026-08-24 arm64 Cargo release-profile build uses the fixed
upstream source and all three checked-in patches. The source/lock identity from
the 2026-08-23 two-patch build remains applicable because patch 0003 adds no
dependency and does not change `Cargo.lock`. Evidence:

- upstream `codex-rs/Cargo.lock` SHA-256:
  `e0843448b5767ff36a2a3b15212feb480cd4eaafe8a0c0ca08547e3c7da03a05`;
- derived `codex-rs/Cargo.lock` SHA-256 (existing `serde_json` package-edge
  only):
  `aca116b64735186879a2108a154db4d9cbe39ff9430d91edd0d4d813b9d1ed5a`;
- patch 0001 SHA-256:
  `24b9d75efee98175df5a7a73dd2b17564776e09b710354c94fb267d2f5e29c14`;
- patch 0002 SHA-256:
  `b7756f0dbcdc671e851143312cd9fb3f8f490f195d99cca88cbfdac565bc5887`;
- patch 0003 SHA-256:
  `9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`;
- separate current-patch arm64 release-profile validation binary SHA-256:
  `880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`;
- current Translatis-only `~/.local/bin/translatis-codex` uses that exact validation
  binary; the previously installed same-version/different-derivation binary
  is retained under a distinct backup name with SHA-256:
  `61350e40759975bb4ae3669ddbbb73b1d25c4beddb34f2233abde7f7196cbde3`;
- historical arm64 `codex-cli 0.145.0-intatis.3` SHA-256:
  `6c4850f4db3ed3e393837b9174ff21257e535f286bd01a923549719c994edd61`;
- reused same-version/same-target rusty_v8 v149.2.0 release-profile archive
  SHA-256:
  `7131418bf7a62a02cbc53cc07aa80776fec10e2197812fdfc0ee0def15686adf`.

Cargo 1.97.1 mechanically rewrites upstream workspace package versions in
the lockfile from `0.0.0` to `0.145.0`; that generated-only drift was discarded.
The sole retained lock change records the existing workspace `serde_json`
dependency for `codex-model-provider-info`. The current validation executable
was cleanly rebuilt from the checked-in patch hash with compile-time derivation
identity
`0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`.
The previously installed `.4` remains thin arm64 and stale for this source;
Intatis rejects it even though the human-readable version is identical. The
former `.3` executable is retained only as a versioned local backup/history
artifact, and the separately installed official `codex-cli 0.145.0`
executable remains untouched. None of these executables is copied into the
repository or App bundle. This evidence satisfies the current-patch arm64
development gate, not the universal/license/Developer-ID/notarization gate
below.

## Current distribution gate

This source revision does **not** copy a Codex executable into the repository
or into release resources. The separate arm64 validation binary proves the
current source/derivation but is not a release artifact or installed runtime.
Development/runtime discovery checks, in
order, an explicit `TRANSLATIS_CODEX_RUNTIME`, an app-bundled auxiliary executable, normal
local installation locations beginning with `~/.local/bin/translatis-codex`, and
`PATH`, then requires the exact version and derivation above. The separately installed
official `codex` remains untouched. This is dependency discovery, not a
fallback to the former Swift kernel.

Before a public Translatis macOS archive can bundle Codex, release engineering
must separately:

1. produce and hash arm64 and x86_64 binaries from the fixed source commit and
   checked-in patch set;
2. audit the exact Cargo lock closure and preserve every required license and
   NOTICE, including Ratatui-derived attribution;
3. assemble a universal or otherwise architecture-correct auxiliary
   executable;
4. sign the nested executable with the same Developer ID team before signing
   the outer app, then verify Hardened Runtime, notarization, stapling, and
   Gatekeeper from a fresh account;
5. verify final-bundle license inventory and the exact `codex --version`
   runtime gate.

Until that gate is complete, a missing or mismatched runtime is an explicit
startup error. Translatis never falls back to `AgentLoop`, `Orchestrator`, another
provider, a mock runtime, or a compatibility protocol.

## Upgrade procedure

For an upgrade, pin a new annotated release and peeled commit, first test
whether the official runtime has made any patch unnecessary, regenerate the
stable JSON schemas from that exact executable, compare all consumed request,
response, and notification shapes, update the model-catalog schema from that
same release source, rerun the fake lifecycle and real offline App Server
handshakes, repeat the complete dependency/license/distribution audit, and
only then change `CodexRuntimeExecutable.pinnedVersion`, the patch set (or its
documented partial/full removal), and this record.
