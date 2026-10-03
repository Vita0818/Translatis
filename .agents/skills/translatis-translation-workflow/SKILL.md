---
name: translatis-translation-workflow
description: Run an Translatis-native translation workflow for workspace documents, source files, technical material, and localized content. Use when the user asks to translate a document, batch, chapter, project, or file tree; preserve structure, terminology, code, formulas, citations, and output evidence; or prepare a translation job with glossary and QA rules.
---

# Translatis Translation Workflow

Translatis is an Translatis product baseline. Treat this Skill as workflow guidance layered on
the existing Translatis Codex Runtime, native Skills discovery, document tools, Knowledge tools,
workspace leases, permissions, and EventLog. It does not add a provider, parser, writer,
permission, scheduler, or fallback implementation.

## Operating contract

- Establish the source path, source language, target language, output policy, and acceptance
  criteria before translating. If any of these materially changes the result, ask one focused
  question or record the value as `UNKNOWN`; do not invent a language pair or output format.
- Preserve meaning, qualifications, terminology, identifiers, code, formulas, citations,
  numbering, links, tables, captions, and cross-references. Never silently summarize, omit,
  repair, or machine-rewrite content.
- Keep source and output as separate files unless the user explicitly requests replacement.
  Freeze and record the source identity before translation; if the source changes, stop and
  require a fresh run.
- Use only the exact Translatis document tool for the input format. Use continuation tools with
  their source-bound cursors for bounded reads. For PDF, inspect first; use native text when
  available and request the explicit OCR tool when the source is image-only.
- Use only the exact Translatis writer/export tool that expresses the requested output. If the
  format or required fidelity cannot be represented by an existing exact tool, fail clearly
  and report the unsupported boundary. Do not switch parser, writer, backend, shell, Python,
  MCP, or another provider as a fallback.
- Use `build_knowledge` / `search_knowledge` only when Translatis has an active configured
  Knowledge route and the current agent has the corresponding lease. A glossary or translation
  memory is evidence/context, not permission and not a replacement translation engine.
- Keep credentials, raw secret-bearing source material, private bookmarks, and provider
  diagnostics out of Skill files, durable summaries, prompts intended for other agents, and
  output reports. Follow the active workspace and permission boundaries for every read/write.

## Preferred workflow

1. Preflight the source with the exact format reader, source digest, and bounded size/page or
   section plan. For a technical PDF book, activate the specialized `translate-cs-ai-pdf-book`
   Skill and follow its per-page rendering and searchable-PDF QA contract.
2. Establish a living terminology record: preferred target term, preserved English name or
   acronym, context exception, and evidence/source. Reuse the record for every later segment.
3. Read in source order using bounded windows. Maintain source segment/section identity and do
   not use a model-authored cursor or path as authority.
4. Translate semantically in the current Codex turn, retaining code and formulas byte-safe
   where required. When the task is large, use the existing Codex Goal/WorkTask/continuation
   mechanisms rather than inventing a second loop.
5. Write a translated copy through the exact format-specific writer. Use staged atomic output
   and the source digest/CAS fields where the tool provides them. Do not mix translation with
   an unrelated formatting mutation.
6. Validate before claiming completion: source identity, coverage, output existence and
   format, section/paragraph/slide/sheet counts where observable, terminology consistency,
   preserved code/formula/link markers, and any format-specific render/export checks.
7. Record a concise result with input/output paths, source digest, language pair, glossary or
   Knowledge snapshot identity when used, completed/failed/cancelled status, and unresolved
   fidelity or provider limitations. Do not claim a real-provider or visual validation that was
   not actually run.

## Failure boundary

Any missing exact runtime, unavailable document backend, unsupported format operation, source
identity drift, lease/permission denial, malformed result, or provider incompatibility is an
explicit failure for the affected translation job. Stop that capability and report the reason;
do not silently retry through a different implementation.

## Validation

Run the Translatis Skill validator from the workspace root:

```sh
python3 .agents/skills/intatis-skill-creator/scripts/quick_validate.py \
  .agents/skills/translatis-translation-workflow
```

The validator checks structure and text-safety bounds. It does not prove document runtime,
provider, visual, or long-running translation behavior.
