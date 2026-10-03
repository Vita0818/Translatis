<!-- Modified by Intatis from the OpenAI Codex skill-creator sample.
See ThirdPartyNotices/OpenAICodexSkillCreator.md. -->

# Skill design guide

Use this reference when the main workflow needs more detail.

## Choose a structure

### Sequential workflow

Use ordered steps when later work depends on earlier evidence.

```text
Overview → Preconditions → Step 1 → Step 2 → Validation → Handoff
```

Good examples include release preparation, migrations, incident response, and document
conversion.

### Operation catalog

Use peer sections when the Skill exposes independent operations.

```text
Overview → Read → Create → Update → Delete → Troubleshooting
```

State shared safety rules once, before the operation sections.

### Reference and policy

Use requirements grouped by topic for coding conventions, schemas, brand rules, or compliance
policies. Put large tables and exhaustive examples in `references/`.

### Capability map

Use capability sections when several tools form one integrated workflow. For each capability,
state its inputs, output, required tool, permission class, and failure behavior.

## Decide where information belongs

Keep content in `SKILL.md` when it is required on almost every activation:

- the core decision process;
- invariant safety rules;
- the shortest valid execution path;
- resource routing instructions;
- completion criteria.

Move content to `references/` when it is needed only for a subset of requests:

- API or schema details;
- long policy text;
- framework-specific variants;
- troubleshooting matrices;
- exhaustive examples.

Move deterministic work to `scripts/` when agents would otherwise repeatedly rewrite fragile
logic. Scripts must still be inspectable, bounded, and run through the host permission chain.

## Write effective discovery metadata

The `description` must answer both questions:

1. What does the Skill do?
2. When should an agent activate it?

Prefer concrete nouns, file types, workflow names, and user intents. Avoid vague descriptions
such as “helps with development.”

Keep names short and action-oriented. Namespace a name only when it prevents a real collision.

## Design for partial capability

Never assume a tool exists merely because the Skill mentions it.

- State required tools in the procedure.
- Provide a read-only path when useful and truthful.
- Stop with a precise blocker when the required capability is absent.
- Do not invent a generic file-read, shell, browser, network, or MCP fallback.
- Do not instruct a worker to delegate unless it has an explicit delegation capability.

## Design scripts

Prefer the language and runtime already present in the target workspace. Avoid adding a package
dependency for simple validation or scaffolding.

A bundled script should:

- accept explicit paths;
- reject an existing destination instead of overwriting it;
- avoid credentials and network by default;
- produce bounded, actionable output;
- return a nonzero status on validation failure;
- avoid following symlinks when that would escape the intended root;
- leave permission and sandbox decisions to Intatis.

## Review checklist

- The folder name matches the frontmatter name.
- The description contains activation cues.
- The body is operational rather than promotional.
- Every referenced resource exists.
- No resource is included without a use.
- No text resource exceeds the loader limit.
- No credential-like sample appears.
- No duplicate Skill name exists in another active root.
- Tool and path assumptions match the target host.
- Validation evidence is distinguished from untested behavior.
