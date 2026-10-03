# Conversation Renderer Lifecycle Lab

This is a source-tree-only Web rendering and session-lifecycle experiment. It
reconstructs observed Markdown, LaTeX, fenced-code, route-switch, and delayed
thread-release behavior with public open-source packages and independently
written code. It does not copy a production Web bundle, stylesheet, prompt,
logo, screenshot, or brand asset.

The directory is intentionally independent:

- it is not referenced by `Package.swift`, `project.yml`, `Makefile`, `Apps/`,
  `Packages/`, `Vendor/`, or the release scripts;
- it has its own exact npm dependency graph and lockfile;
- generated files stay inside this directory and are ignored;
- the local server binds only to `127.0.0.1`;
- it has no bridge to Intatis sessions, EventLog, credentials, tools, leases,
  or permissions.

The implementation-to-production comparison and recommended native integration
seam are documented in
[INTEGRATION_ASSESSMENT.md](./INTEGRATION_ASSESSMENT.md).

## Implemented session lifecycle

- Three fully local, sanitized conversations exercise prose, tables, formulas,
  known and unknown code languages, and long-history navigation.
- The outer page shell survives a switch while the keyed active-message
  subtree is unmounted and replaced. The old conversation is not kept as
  hidden DOM.
- A small residency controller models `active`, `warm`, and `cold` states.
  Leaving a session starts a 30-second warm timer; returning before expiry
  cancels that timer. `Release warm` evicts all inactive entries immediately.
- Warm thread entries retain only local lifecycle metadata and never hidden
  message DOM. Shared renderer-kernel state is accounted separately: the math
  cache is bounded and loaded grammar modules remain in the JavaScript realm.
  Raw sample messages remain immutable fixture input; the experiment does not
  claim to reproduce a production thread object or its memory size.
- The conversation initially projects the newest 12 messages. `Load older`
  reveals history in pages of 10.
- Messages outside a 900-pixel viewport margin replace their Markdown,
  KaTeX, and CodeMirror subtree with a measured-height placeholder. Re-entering
  the margin remounts from canonical raw source.
- A session switch cancels the local streaming generation before mounting the
  next conversation. CodeMirror append-only updates insert only the new suffix;
  non-append edits fall back to a bounded full replacement.
- `Stress switch` performs 36 timed route changes; the bounded harness accepts
  up to 1,000. Live diagnostics expose DOM nodes, mounted messages, math nodes,
  CodeMirror views, switch count, and warm countdowns.

This is an independently designed lifecycle probe, not a claim that any
external product uses exactly this component tree, timer, cache, or viewport
policy.

## Implemented rendering contract

Markdown:

- CommonMark through `react-markdown`;
- GFM tables, task lists, autolinks, and strikethrough;
- `singleTilde: false`;
- ordinary newlines become `<br>`;
- source positions are exposed as `data-source-start` / `data-source-end`;
- raw HTML is converted to literal text and is never passed to an HTML parser;
- Markdown images become non-loading text placeholders;
- links use an explicit allowlist; dangerous schemes are removed.

LaTeX:

- `\(...\)` inline math;
- `\[...\]`, `$$...$$`, and fenced `math` display math;
- single-dollar `$...$` remains literal;
- KaTeX is fixed at `0.16.21`, with HTML + MathML output;
- `trust: false`, bounded expansion/size, strict first render, and
  non-throwing visible fallback for KaTeX parse errors;
- display math scrolls horizontally;
- the small render cache is capped at 256 entries and approximately 512 Ki
  characters, and skips source over 4,096 characters.

Code:

- fenced blocks use a read-only, non-editable CodeMirror 6 view;
- language parsers are loaded on demand from `@codemirror/language-data`;
- unknown languages stay plain and do not fail the whole message;
- the Copy button writes the canonical raw code, not highlighted DOM text;
- long lines scroll horizontally;
- append-only streaming keeps the newest tail visibly plain, then reveals the
  parser result after a 500 ms trailing window; completion settles on the next
  animation frame.

The UI is deliberately neutral. It is a behavior lab, not a visual or branded
clone. It also omits code execution: rendering code must not silently become an
execution surface.

## Run

```sh
cd /Users/vita/Vitemis/Intatis/Experiments/WebRendererParity
npm ci
npm test
npm run licenses
npm run build
npm run dev
```

Open `http://127.0.0.1:4173`.

The rendered conversation is the primary surface; source is never mistaken for
output. On wide screens, local sessions, the active conversation, and lifecycle
diagnostics are shown together. At narrower widths, sessions become a
horizontal picker and diagnostics collapse.

Controls:

- `Stream code` appends a local assistant message and demonstrates an
  incrementally updated fenced block.
- `Stress switch` cycles through all three sessions with a visible switch
  counter; the same control stops an active run.
- `Release warm` clears inactive residency metadata without touching the
  active message subtree.
- `Load older` expands the current session's pagination window.

The page publishes a bounded test harness:

```js
window.rendererHarness.switchSession("latex-long-thread")
window.rendererHarness.stressSwitch({ cycles: 60, intervalMs: 80 })
window.rendererHarness.stopStress()
window.rendererHarness.releaseInactive()

// Backward-compatible renderer injection: replaces the newest assistant
// message in the active local sample only.
window.rendererHarness.set({
  source: "## Heading\n\n\\(x^2\\)",
  isStreaming: false
})

window.rendererHarness.snapshot()
```

The snapshot contains public experiment state only: active sanitized session
ID, route generation, switch count, warm residency metadata, DOM/message/math
counts, and per-code-block language/highlight progress. It never returns
message contents, parser instances, browser state, credentials, or Intatis
data.

## Verification boundary

Unit tests assert DOM structure, parser contracts, suffix-only code updates,
timer cancellation, delayed eviction, and exact session-subtree replacement.
Browser verification uses DOM, accessibility roles, computed styles, clipboard
content, and harness state; screenshots are not used as evidence.

The current production build emits an approximately 941.04 kB minified main
entry (about 290.19 kB gzip), plus lazy language chunks and KaTeX fonts. This
is useful feasibility evidence, not a production size target.

Known non-equivalence:

- KaTeX `0.16.21` is the only exact live Web dependency version established by
  code inspection. Exact live versions of React, remark, CodeMirror, and Lezer
  remain unknown, so this experiment uses pinned compatible public releases.
- The streaming-code tail reproduces the observed state transition, but its
  internal incremental parse/cache implementation is independent.
- Product-only citation, sandbox-link routing, attachment/image resolution,
  and code execution controls are outside this renderer-only experiment.
- The 30-second residency controller is a transparent behavior model. It
  retains metadata rather than a private production thread tree, and therefore
  is not a memory benchmark or proof that a production leak is fixed.
- The viewport boundary is intentionally simple. A production implementation
  would need scroll-anchor preservation, focus/selection retention,
  accessibility verification, cache-byte budgets, and memory-pressure
  recycling.

See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for provenance and
license scope.
