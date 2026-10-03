# OpenAI Codex `skill-creator` derivative

## Upstream identity

- Project: OpenAI Codex (`https://github.com/openai/codex`)
- Upstream release: `rust-v0.145.0`
- Fixed commit: `25af12f7e61572b0bc18ddb1008be543b91519b0`
- Copyright: Copyright 2025 OpenAI
- License: Apache License 2.0
- Upstream root license SHA-256:
  `d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc`
- Upstream root NOTICE SHA-256:
  `9d71575ecfd9a843fc1677b0efb08053c6ba9fd686a0de1a6f5382fd3c220915`

The adopted source is the `skill-creator` sample below
`codex-rs/skills/src/assets/samples/skill-creator/`. The fixed upstream Git
blob identities reviewed for this adoption are:

| Upstream file | Git blob |
|---|---|
| `SKILL.md` | `57f4e58b10cec3b0d2b3eccfd510201fefa140eb` |
| `scripts/init_skill.py` | `69673eaa048a24bdf2fa188484e721a43b2bac4c` |
| `scripts/quick_validate.py` | `0547b4041a5f58fa19892079a114a1df98286406` |
| `scripts/generate_openai_yaml.py` | `3fd7405345a41e811c03db1448524ef0bbb287f5` |
| `references/openai_yaml.md` | `90f9e8e863dff501c0125e2ead20c1dd6c3028d5` |
| `agents/openai.yaml` | `3095c600ce769c862519df036ab5777a5a947fec` |

## Local adoption

- Local path: `.agents/skills/intatis-skill-creator/`
- Reuse classification: `vendored` + `derived`
- Distributed local files:
  - `SKILL.md`
  - `references/design-guide.md`
  - `references/openai_yaml.md`
  - `scripts/init_skill.py`
  - `scripts/quick_validate.py`
  - `scripts/generate_openai_yaml.py`

Every distributed file above is modified by Intatis. The upstream
`agents/openai.yaml`, icons, images, branded assets, and all other Codex
system Skills are not copied.

## Intatis modifications

- Renamed the Skill from `skill-creator` to `intatis-skill-creator` so the
  project copy does not collide with the separately discovered Codex system
  Skill of the same upstream name.
- Reworked the operating instructions for Intatis project roots,
  invocation-scoped snapshots, `WorkspaceLease`, the ordinary permission
  chain, the 48 KiB text-resource limit, and truthful tool availability.
- Removed examples that trigger Intatis' credential-shaped-content scanner
  and documented the prohibition against sensitive examples.
- Split and reorganized design guidance into
  `references/design-guide.md`.
- Replaced the upstream PyYAML-based helpers with Python-standard-library
  implementations so the installed Skill has no undeclared Python package
  dependency.
- Changed initialization to default to `.agents/skills`, removed binary asset
  scaffolding, made portable `agents/openai.yaml` metadata opt-in, and added
  same-directory/name, placeholder, UTF-8, secret-marker, symlink, 48 KiB
  text-resource, and separate 16 KiB `agents/openai.yaml` safety checks.
- Narrowed `agents/openai.yaml` guidance to Intatis' supported MCP dependency
  subset. Interface and policy fields remain optional cross-harness metadata;
  they are not described as Intatis runtime permissions. The helper does not
  claim to duplicate the authoritative Swift MCP schema parser.

The Skill is contextual guidance, not an executable privilege bundle.
Bundled scripts can run only when the active agent already has an advertised
execution tool, an appropriate workspace lease, and authorization through the
normal Intatis permission and durable-execution path. It adds no network,
filesystem, shell, MCP, communication, or delegation capability of its own.
It is not linked into the iOS target.

## License and upgrades

The complete Apache License 2.0 text used for this derivative is preserved at
`ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`.

When upgrading, fix a new upstream commit, recheck the exact target files and
their blob identities, review the upstream license and NOTICE, reapply and
document all local modifications, and rerun the Intatis Skill validation and
focused loader tests before changing this record.
