# OpenAI Codex Runtime patch

Intatis Code, Cowork, and CLI use a narrowly derived build of the official
open-source OpenAI Codex App Server.

- Upstream release: `rust-v0.145.0`
- Peeled upstream commit: `25af12f7e61572b0bc18ddb1008be543b91519b0`
- Derived runtime version: `0.145.0-intatis.4`
- Patch set, in order:
  `0001-responses-provider-passthrough.patch`,
  `0002-openrouter-strict-routing-shape.patch`,
  `0003-cowork-subagent-reconnection.patch`
- License and provenance: `ThirdPartyNotices/OpenAICodexRuntime.md`

The patch restores the former Intatis request-owned passthrough semantics for
exactly one isolated subtree: top-level Responses `provider`. Intatis passes
the already-decoded, non-secret `options.provider` JSON object through the
derived custom-provider config field `intatis_responses_provider`; Codex
clones that object into `ResponsesApiRequest.provider` without enumerating,
interpreting, renaming, or merging its children. Future provider-owned keys
therefore do not require another Codex patch.

The second patch is activated only by the explicit Intatis OpenRouter provider
body marker. It omits Codex-generated optional OpenAI request controls that the
exact configured route did not declare, and removes an unadvertised reasoning
summary; it does not infer adapter identity from a URL or provider name. Host
configuration uses Codex's official `web_search = "disabled"` control and the
third patch's explicit, provider-agnostic MultiAgent V2 `flat_tools = true`
extension. Cowork therefore keeps native V2 collaboration and ordinary
dynamic business functions as top-level Responses function tools, including
on the configured OpenRouter route, without claiming OpenAI-specific hosted
web-search or namespace-tool support.

The third patch reconnects native Cowork subagents through Codex's existing
MultiAgent V2 and App Server control paths. Children inherit the parent
thread's registered App Server `dynamic_tools` for `fork_turns = "none"`,
`"all"`, and positive last-N forks. Intatis supplies strict
`intatis_agent_workspaces` presets containing an absolute cwd, exact
parent-approved runtime workspace roots, a safe model-visible description,
and an explicit `read-only` or `workspace-write` sandbox; the model chooses
only the preset ID, never a raw path. The same patch adds the experimental
`thread/subagent/message` App Server method, which validates exact root-tree
membership and delivers host messages through the existing `AgentControl`
mailbox rather than through a provider or legacy message bus. Model-authored
V2 task/message payloads use ordinary mailbox text, not an OpenAI-internal
encrypted-content envelope. Relationship-filtered `thread/list` also retains
spawned descendants with an empty preview, which is normal when their only
input is inter-agent communication.

This is not a generic `extra_body`: provider JSON cannot replace host-owned
`model`, `input`, `tools`, `stream`, `reasoning`, or other request fields. No
control header, proxy, protocol translator, or OpenRouter-specific parser is
introduced. Intatis applies recursive secret/transport-key scanning and
structural resource bounds before the object crosses the process boundary.

Apply and build from the exact upstream commit:

```sh
git checkout 25af12f7e61572b0bc18ddb1008be543b91519b0
git apply /absolute/path/to/0001-responses-provider-passthrough.patch
git apply /absolute/path/to/0002-openrouter-strict-routing-shape.patch
git apply /absolute/path/to/0003-cowork-subagent-reconnection.patch
cd codex-rs
INTATIS_CODEX_DERIVATION_ID=0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285 \
  cargo build --release -p codex-cli
./target/release/codex --version
./target/release/codex --intatis-derivation-id
```

The expected outputs are `codex-cli 0.145.0-intatis.4` and the exact derivation
string above. The patch set reuses the workspace's existing `serde_json`
version and records that package-edge in `Cargo.lock`; do not retain
Cargo-generated workspace-version-only rewrites. The current patch 0003
SHA-256 is
`9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`.
The validated isolated thin arm64 build has SHA-256
`880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`.
Intatis checks both version and derivation before starting App Server. The
user's existing Intatis-named `.4` and official `codex` installations were not
overwritten; the old same-version binary is deliberately rejected by the new
derivation gate. No binary is copied into the App bundle, so this does not
complete the deferred release bundle gate.

Each patch can be retired independently when the exact official Codex release
exposes its equivalent request-owned Responses `provider` body,
provider-specific optional-field capability, or native dynamic-tool/workspace/
flat-collaboration/control-plane extension without a local change.
