# Intatis Codex runtime release contract

Code, Cowork, and their CLI surfaces use the official OpenAI Codex App Server
through the exact derived runtime identified by `release-spec.json`. The
repository stores the source identity and the only three permitted patches;
it does not store generated binaries.

Each architecture root has this layout:

```text
<architecture-root>/
  codex
  runtime-manifest.json
  SHA256SUMS.txt
  ThirdPartyNotices/runtime.spdx.json
  ThirdPartyNotices/LICENSES.txt
  ThirdPartyNotices/licenses/
```

`scripts/build-codex-runtime.sh` downloads the fixed upstream archive, verifies
the upstream and derived lock identities, applies the checked-in patches in
order, and uses upstream's Rust 1.95.0 toolchain. The peeled release commit
changed `workspace.package.version` after generating its lock, so the builder
requires exactly 130 workspace-only `0.0.0` entries, changes only those values
to `0.145.0`, and verifies a second fixed lock hash before Cargo may resolve or
build. Dependency sources, versions, and checksums are not rewritten. The
official `rusty_v8` 149.2.0 static archives for arm64 and x86_64 are separately
downloaded, SHA-256 verified against the release spec, and passed to the
upstream build through its official `RUSTY_V8_ARCHIVE` extension. The builder
also extracts the Cargo license closure from that locked graph.
`scripts/validate-codex-runtime.sh` then verifies the manifest, complete file
inventory, architecture, load commands, signatures when requested, exact
runtime/derivation output, and a real isolated App Server stdio initialize.

The shipping App stages these roots at
`Contents/Resources/CodexRuntime/{arm64,x86_64}`. The active App slice accepts
only its matching bundled root. Environment, local installation, and `PATH`
lookup remain development-only seams and cannot satisfy an IntatisMac bundle.

Local v0.66 preview packaging may use ad-hoc Hardened Runtime signatures. That
mode is intentionally named `execute-local`; it does not satisfy the separate
Developer ID, timestamp, notarization, staple, Gatekeeper, or fresh-user
release gates.
