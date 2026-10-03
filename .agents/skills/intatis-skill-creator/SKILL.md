---
name: intatis-skill-creator
description: Create, adapt, validate, and iterate on Intatis or Codex-compatible Agent Skills. Use when a user asks to add a Skill, improve an existing SKILL.md, organize Skill scripts or references, validate discovery compatibility, or design a reusable workflow for Code or Cowork.
---

<!-- Modified by Intatis from the OpenAI Codex skill-creator sample.
See ThirdPartyNotices/OpenAICodexSkillCreator.md. -->

# Intatis Skill Creator

Create small, self-contained Skills that another agent can discover and follow reliably.
Treat a Skill as contextual procedure, not as a permission grant.

## Operating contract

- Follow the active repository instructions before changing files.
- Use the path selected by the user. When no path is given, create project Skills under
  `.agents/skills/<skill-name>/`.
- Keep the Skill inside the active workspace unless the user explicitly selects an allowed
  global root.
- Use one directory per Skill and name the required entry file exactly `SKILL.md`.
- Use lowercase letters, digits, and hyphens for the directory and frontmatter `name`.
- Keep the directory name and frontmatter `name` identical.
- Never place credentials, credential-shaped examples, private data, or sensitive configuration
  in a Skill.
- Do not claim that a Skill adds file, shell, network, MCP, communication, or delegation
  capability. It may use only tools and leases already granted to the current agent.
- Run bundled scripts only through tools actually advertised by the current request and through
  the normal permission chain.
- Remember that Intatis freezes a fresh Skill snapshot for each Code send or Cowork
  AgentInvocation. Newly created or edited Skills become visible on the next invocation.

## Design principles

### Keep the activated body compact

Assume the model already understands general programming and reasoning. Put only the
non-obvious workflow, domain rules, and failure boundaries in `SKILL.md`.

Use three disclosure levels:

1. `name` and `description`: always-visible discovery metadata.
2. `SKILL.md`: the core procedure loaded when the Skill activates.
3. `scripts/` and `references/`: resources read or run only when needed.

Read `references/design-guide.md` when choosing a structure, deciding what belongs in a
resource, or reviewing a complex Skill.

### Match specificity to risk

- Use flexible prose when several solutions can be correct.
- Use ordered steps when a preferred workflow matters.
- Use deterministic scripts when formatting or validation has only one acceptable outcome.

### Keep execution honest

A script bundled with a Skill is not automatically executable. Before instructing an agent to
run it, verify that the script is inside the active workspace, the agent has a read-write
WorkspaceLease when output is required, and `exec_command` or an equivalent tool is present.

## Skill structure

Use this layout:

```text
skill-name/
├── SKILL.md
├── scripts/          # optional deterministic helpers
├── references/       # optional detailed UTF-8 guidance
└── agents/
    └── openai.yaml   # optional cross-harness metadata or MCP dependencies
```

Intatis currently freezes text resources. Do not make a Skill depend on an unreadable binary
asset. Keep each `SKILL.md` and text resource within the current 48 KiB per-file limit.

## Creation workflow

### 1. Establish concrete use cases

Identify:

- what the user will ask;
- what successful output looks like;
- which failure modes matter;
- which tools and permissions the workflow genuinely requires;
- whether the Skill is project-specific or reusable globally.

Ask only for missing information that materially changes the result.

### 2. Plan reusable contents

For each use case, decide whether it needs:

- instructions in `SKILL.md`;
- a deterministic helper in `scripts/`;
- detailed facts or schemas in `references/`;
- an MCP dependency in `agents/openai.yaml`.

Do not duplicate the same guidance in both the main body and a reference.

### 3. Initialize the directory

When the Skill does not exist, run the project-local initializer from the workspace root:

```sh
python3 .agents/skills/intatis-skill-creator/scripts/init_skill.py my-skill
```

Select optional resources only when needed:

```sh
python3 .agents/skills/intatis-skill-creator/scripts/init_skill.py my-skill \
  --resources scripts,references
```

Use `--path <allowed-root>` only when the user selected another destination. Use
`--portable-metadata` when the Skill should also carry Codex-compatible interface metadata.

### 4. Implement the Skill

Write frontmatter first:

```md
---
name: my-skill
description: Describe what the Skill does and the concrete situations that should activate it.
---
```

Put every activation cue in `description`; the body is unavailable until after activation.
Write the body as direct operational instructions. Reference each optional resource explicitly
and state when it should be read or run.

If the Skill declares MCP dependencies, read `references/openai_yaml.md` and describe only
dependencies that the Intatis host can attest in the same request-owned MCP snapshot.

### 5. Validate

Run the standard-library validator:

```sh
python3 .agents/skills/intatis-skill-creator/scripts/quick_validate.py \
  .agents/skills/my-skill
```

Fix every error before handoff. Also inspect the final directory and confirm that:

- no placeholder remains;
- no unrelated file was added;
- all referenced resources exist;
- no same-name Skill exists in another active root;
- commands use paths valid from the workspace root;
- the Skill does not promise unavailable tools.

The helper enforces structural and text-safety bounds, including the separate 16 KiB
`agents/openai.yaml` limit. It does not reimplement Intatis' strict Swift MCP metadata parser;
when MCP dependencies are present, the actual Intatis loader is authoritative for their schema
and locator validity.

### 6. Exercise and iterate

Use the Skill on a realistic request. For complex Skills, give an independent agent the raw
request and artifacts without leaking the intended answer. Compare the result with explicit
acceptance criteria, then refine the Skill or its resources.

Do not call a fake-provider unit test a real provider test, and do not call an in-process replay
a process-restart test.

## Updating an existing Skill

1. Read the complete `SKILL.md`.
2. Read every resource directly required by its instructions.
3. Preserve useful behavior and provenance.
4. Remove stale paths, unavailable tool names, redundant explanations, and unused resources.
5. Re-run validation and at least one realistic exercise.

## Handoff

Report:

- the installed path and Skill name;
- files created or modified;
- tools or MCP dependencies required at runtime;
- validation actually run;
- any untested real-provider, GUI, network, or long-duration behavior.
