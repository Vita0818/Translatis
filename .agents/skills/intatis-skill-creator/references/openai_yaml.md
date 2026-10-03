<!-- Modified by Intatis from the OpenAI Codex skill-creator sample.
See ThirdPartyNotices/OpenAICodexSkillCreator.md. -->

# `agents/openai.yaml` in Intatis

This file is optional. Intatis recognizes the Codex-shaped top-level sections `interface`,
`dependencies`, and `policy`, but their runtime meaning is intentionally narrower.

## What Intatis consumes

Intatis validates and freezes only `dependencies.tools` records of type `mcp` for activation
preflight. A Skill body or resource is disclosed only when the same provider request has an
exact, host-attested MCP server identifier and transport-locator match.

Example:

```yaml
dependencies:
  tools:
    - type: "mcp"
      value: "github"
      description: "GitHub MCP server"
      transport: "streamable_http"
      url: "https://example.invalid/mcp"
```

Supported transports:

- `streamable_http`, with an absolute HTTPS `url` that has no user information, query, or
  fragment;
- `stdio`, with a bounded canonical absolute executable path in `command`.

Do not put credentials, environment values, headers, tokens, or private endpoint material in
this file. Keep `agents/openai.yaml` within Intatis' separate 16 KiB metadata limit.

## Compatibility-only sections

`interface` and `policy` are accepted as bounded metadata so a Skill can remain
Codex-compatible, but Intatis currently does not use them for a Skill picker, icons, default
prompts, or implicit-invocation policy. Do not promise those behaviors in an Intatis Skill.

The bundled `generate_openai_yaml.py` helper creates only portable `interface` metadata. It does
not configure MCP servers and does not grant tools.

The bundled `quick_validate.py` enforces the metadata file's UTF-8, secret-marker, symlink, and
16 KiB boundaries, but intentionally does not duplicate Intatis' strict Swift MCP schema parser.
The loader remains authoritative for MCP dependency shape and locator validation.

## Failure behavior

Invalid dependency metadata, a missing request-owned MCP snapshot, or an identifier/locator
mismatch rejects activation before any Skill body or resource is returned. Intatis does not
install a server, run OAuth, rewrite external configuration, or continue anyway.
