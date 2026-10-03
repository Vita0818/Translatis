# NOTICE

## Project origin and source-reuse policy

Translatis is an Apple-first, Swift-native-first local AI workbench built on the
shared Intatis source baseline. Project-owned
code and assets are original unless an upstream source is identified here.
Compatible open-source work may be linked, vendored, or modified only after
its provenance and licenses have been reviewed under
`docs/OPEN_SOURCE_REUSE.md`.

Translatis does not use leaked or private source code or prompts, and does not use
third-party names, logos, icons, screenshots, UI assets, trademarks, or brand
copy as its product identity. Open-source reuse does not bypass Translatis'
permission, workspace, event-log, secret, or Apple-platform boundaries.

## JetBrains Mono product typography

Translatis bundles two unmodified variable-font files from **JetBrains Mono
2.304** (`JetBrains/JetBrainsMono`, tag `v2.304`, commit
`cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9`) under the SIL Open Font License
1.1. Following the initial visual trial, the user approved JetBrains Mono on
2026-08-19 as the unified first-party English product typeface for macOS and
iOS. It is now an unconditional product resource rather than a runtime A/B.

The exact file inventory, hashes, adoption/exclusion scope, fail-closed Core
Text registration boundary, and CJK fallback observation are recorded in
`ThirdPartyNotices/JetBrainsMono.md`. The complete OFL-1.1 text is preserved at
`ThirdPartyNotices/Licenses/JetBrainsMono-2.304-OFL-1.1.txt`. Any resource,
hash, descriptor-inventory, license, or final-bundle drift remains a release
failure; the approved exact resources themselves are not a release blocker.

## Open Knowledge Format v0.2 standard

Translatis pins the unmodified, self-contained Open Knowledge Format v0.2
specification from `GoogleCloudPlatform/knowledge-catalog` at commit
`3fcbb9f828c2f23d109c855ee403c3a4c81f3a96`. The adopted documentation is
Apache License 2.0. The exact specification, license, upstream identities, and
SHA-256 inventory are stored under
`ThirdPartyStandards/OpenKnowledgeFormat/0.2/`; detailed scope and exclusions
are recorded in `ThirdPartyNotices/OpenKnowledgeFormat.md`. The upstream
reference agent, prompts, samples, viewer, Python runtime, and data bundles are
not copied, linked, or executed.

## Knowledge retrieval parser dependency

The non-iOS shared `IntatisKnowledge` target uses **Yams 6.2.2**
(`jpsim/Yams`, commit `a27b21e0c81c5bf42049b897a62aaf387e80f279`),
including its in-package CYaml/libYAML sources, under the MIT License. It is an
exact SwiftPM dependency with no external package dependencies. Provenance,
runtime scope, parser-hardening boundaries, and the complete license are in
`ThirdPartyNotices/KnowledgeRetrieval.md` and
`ThirdPartyNotices/Licenses/Yams-6.2.2-MIT.txt`.

## Fixed document external runtime

The macOS/non-iOS document tools use a separately assembled, architecture-
specific external runtime rather than in-tree document parsers. Its direct
pins are CPython 3.11.9, Docling 2.117.0, docling-core 2.89.0,
docling-parse 7.8.1, python-docx 1.2.0, python-pptx 1.0.2, openpyxl 3.1.5,
lxml 6.1.1, pypdfium2 5.12.1, Tesseract 5.5.3 with English tessdata,
Tectonic 0.15.0, LibreOfficeDev 26.8.0.0.beta1, and the pinned Docling Heron
layout model. Apple PDFKit and WebKit are used only through their native
public APIs for PDF inspection/read/page rendering and HTML-to-PDF export.

Exact provenance, direct licenses, runtime layout, SHA-256/SBOM/license
requirements, signing gates, and the explicit absence of completed dual-
architecture release evidence are recorded in
`ThirdPartyNotices/DocumentReadingRuntime.md`. The source repository contains
the release contract and validator, not the runtime binaries. The retired
rbook/EPUBCheck/pdfcpu write-and-verification closure is no longer part of the
production document surface or release manifest.

## Fixed browser external runtime

The shipping macOS structured browser tools use an architecture-specific
runtime containing Node.js 24.20.0, Playwright/Playwright Core 1.56.1, and
Playwright Chromium revision 1194 (Chromium 141.0.7390.37, fixed commit
`9f043f63b0e5b728c8d09f3e3ddfc1681a4bd58e`). Node.js is MIT licensed;
Playwright is Apache-2.0; Chromium uses its BSD license and the exact binary's
built-in third-party license inventory. Shipping does not use a system
browser, global npm install, caller CDP endpoint, or browser-runtime fallback.

Exact artifact hashes, bundle layout, runtime-owned SBOM/license inventory,
and product boundaries are recorded in `ThirdPartyNotices/BrowserRuntime.md`
and `Packages/IntatisTools/Runtime/browser-runtime/`. No browser binary is
checked into the source tree; release assembly stages reviewed external roots.

## OpenAI Codex App Server external runtime

Code, Cowork, and the corresponding CLI modes now integrate the official
OpenAI Codex App Server as a narrowly **derived external runtime**, pinned to
release `rust-v0.145.0` and source commit
`25af12f7e61572b0bc18ddb1008be543b91519b0`. The reproducible local patches are
`ThirdPartyPatches/OpenAICodexRuntime/0001-responses-provider-passthrough.patch`,
`0002-openrouter-strict-routing-shape.patch`, and
`0003-cowork-subagent-reconnection.patch`.

- **OpenAI Codex** (`openai/codex`): Apache License 2.0, Copyright 2025
  OpenAI. Reuse type: `derived external-runtime` + official stdio JSON-RPC
  App Server API and a narrow derived experimental control-plane extension.
- Translatis supplies only process/version lifecycle, a `requires_openai_auth =
  false` Responses provider projection, isolated owner-only runtime storage,
  credential environment injection, and UI/EventLog projection. Codex owns
  the agent loop, tools, sandbox, approval review, thread/turn/item history,
  Goals, and subagent execution.
- Patch 0003 makes MultiAgent V2 children inherit registered App Server
  dynamic business tools in every fork mode; exposes only strict host-approved
  workspace preset IDs with exact roots and read/write sandbox selection;
  keeps V2 collaboration as flat top-level functions, including on the exact
  OpenRouter route; and adds ancestry-checked `thread/subagent/message`
  delivery through Codex's existing `AgentControl` mailbox.
- ChatGPT login is not used. The selected Translatis Responses credential is
  never placed in runtime files, EventLog, documentation, or process
  arguments.
- No Codex executable is copied into this source revision or current release
  resources. Development lookup accepts only exact
  `codex-cli 0.145.0-intatis.4` **and** derivation identity
  `0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285`;
  it fails explicitly if either differs and never falls back to the former
  Swift agent kernel. A separate 2026-08-24 arm64 release-profile validation
  build has SHA-256
  `880dbbbd97ad3077a54296940c0c219a33ac153979126be7129a8998a4ff5685`.
  It was built in an isolated source/target directory and is now installed
  only as the Translatis-named `~/.local/bin/translatis-codex`. The prior
  same-version/different-derivation Translatis binary remains recoverable under a
  distinct backup name with SHA-256
  `61350e40759975bb4ae3669ddbbb73b1d25c4beddb34f2233abde7f7196cbde3`.
  The official `codex-cli 0.145.0` installation remains untouched. This local evidence completes the
  current-patch development build gate, not the deferred App bundle,
  dual-architecture, license-closure, signing, or notarization gates.

Exact upstream identity, local integration paths, authentication/persistence
boundaries, first-version exclusions, Ratatui-derived NOTICE attribution, and
the binary license/sign/notarization gate are recorded in
`ThirdPartyNotices/OpenAICodexRuntime.md`. The complete Apache-2.0 text is at
`ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`.

## OpenAI Codex Skill Creator derivative

The project-local `.agents/skills/intatis-skill-creator/` Skill is a modified
derivative of the public `skill-creator` sample in OpenAI Codex release
`rust-v0.145.0`, fixed at commit
`25af12f7e61572b0bc18ddb1008be543b91519b0`.

- **OpenAI Codex `skill-creator` sample** (`openai/codex`): Apache License
  2.0, Copyright 2025 OpenAI. Reuse type: `vendored` + `derived`.
- Translatis renamed and adapted the instructions, references, initializer,
  validator, and metadata generator for project-local roots, Translatis
  invocation and permission semantics, secret scanning, resource bounds, and
  a Python-standard-library-only runtime.
- The upstream `agents/openai.yaml`, icons, images, branded assets, and other
  system Skills are not copied by this Skill adoption. The separately adopted
  external Codex runtime is described in the preceding section and is not yet
  bundled in release resources.

Exact source paths, upstream blob identities, the modification and execution
boundary, and upgrade procedure are recorded in
`ThirdPartyNotices/OpenAICodexSkillCreator.md`. The complete Apache-2.0 text is
preserved at
`ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`.

## Current Markdown and math renderer integration

The current Translatis working tree replaces the former MarkdownUI/highlight.js renderer
stack with an in-tree, thin derivative of Microsoft's
SwiftStreamingMarkdown. The complete buildable derivative is vendored at
`Vendor/SwiftStreamingMarkdown`; the containing Translatis Git revision versions
the source, tests, Microsoft MIT license, and adjacent patch/provenance ledger
together. No separately published Translatis fork is required for reproducible
resolution of this package.

- **SwiftStreamingMarkdown 0.6.0**
  (`microsoft/SwiftStreamingMarkdown`), upstream tag `v0.6.0`, commit
  `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`: MIT. The Translatis candidate is a
  modified derivative whose initial cutover removed optional runtimes and
  branded assets, then selectively restored only exact iosMath 2.5.0 for the
  code-aware LaTeX path. It hardens the ownership/concurrency boundary
  and the macOS native paragraph measurement boundary, giving SwiftUI sole
  ownership of paragraph width while retaining only one exact-width height
  measurement. Its macOS path also coordinates direct drag selection across
  the existing native TextKit leaves of one document without restoring a
  SwiftUI whole-document selection overlay or introducing another renderer.
  It retains the upstream Markdown parser and
  SwiftUI/AppKit/UIKit rendering structure; the removed highlighting,
  animation, image, citation, and legacy regex-math runtimes remain absent.
  **Derivative location: `Vendor/SwiftStreamingMarkdown` in the Translatis root
  revision being built or distributed.**
- **swift-markdown 0.8.0** (`swiftlang/swift-markdown`), revision
  `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`: Apache License 2.0 with the
  Swift Runtime Library Exception. Direct dependency of the derivative.
- **swift-cmark 0.8.0** (`swiftlang/swift-cmark`), revision
  `924936d0427cb25a61169739a7660230bffa6ea6`: BSD-2-Clause core with the
  MIT-derived runtime portions identified by upstream `COPYING`. Transitive
  parser dependency through swift-markdown.
- **iosMath 2.5.0** (`kostub/iosMath`), tag `2.5.0`, commit
  `838cddc01fdd67efd530f8bb67959ad2715f9b06`: MIT. Exact, conditionally linked
  Apple-platform dependency of the derivative for native TeX math parsing and
  layout. iosMath has no transitive package dependency. Its SwiftPM resource
  bundle copies eight OpenType math fonts and their table/license/readme
  resources without modification; four fonts use the GUST Font License
  (LPPL 1.3c or later) and four use the SIL Open Font License 1.1. The copied
  `fonts/` payload is 26 files / 7,234,424 bytes; a built Xcode bundle has 27
  files after the generated root `Info.plist` is included.

Copyright, license, exact upstream/parser versions, distribution requirements,
and the current high-level modification summary are in
`ThirdPartyNotices/MarkdownRendering.md`. The persistent modified-file and
patch ledger is stored beside the vendored source at
`Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md`. The iosMath engine,
font inventory, attributions, shipped GUST notice, and OFL terms are in
`ThirdPartyNotices/MathRendering.md`.

## External MCP Server client integration

The external MCP client uses an in-tree, client-only derivative of the
official Model Context Protocol Swift SDK. The derivative is vendored at
`Vendor/MCPClientSDK`; the containing Translatis revision fixes the exact source,
combined upstream license, exclusions, and patch ledger.

- **MCP Swift SDK 0.12.1**
  (`modelcontextprotocol/swift-sdk`), upstream commit
  `a0ae212ebf6eab5f754c3129608bc5557637e605`: combined upstream licensing
  transition covering Apache-2.0 contributions, legacy MIT contributions, and
  CC-BY-4.0 documentation. Reuse type: `vendored` + `derived`.
- **swift-system 1.4.0**, commit
  `c8a44d836fe7913603e246acab7c528c2e780168`: Apache-2.0 with the Swift Runtime
  Library Exception.
- **swift-log 1.6.2**, commit
  `96a2f8a0fa41e9e09af4585e2724c4e825410b91`: Apache-2.0 and its upstream
  NOTICE attributions.
- **EventSource 1.1.0**, commit
  `e83f076811f32757305b8bf69ac92d05626ffdd7`: Apache-2.0; Apple-platform-only
  dependency of the remote HTTP client.
- **Swift Crypto 4.5.1**, commit
  `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6`: Apache-2.0; Linux-only
  CryptoKit-compatible backend. Its distribution includes vendored BoringSSL
  commit `0226f30467f540a3f62ef48d453f93927da199b6` and XKCP commit
  `11297f566178023faba59ff14b6b399241488283`, whose complete combined/per-file
  terms are preserved.
- **Swift ASN.1 1.7.1**, commit
  `a9a5efd40eaf558a2bcd48d64b1d1646be686008`: Apache-2.0; transitive
  Linux-only dependency of Swift Crypto.
- **Native MCP HTTP transport.** `IntatisCurlTransport` links the libcurl
  supplied by the Apple SDK/operating system in macOS products; no Darwin
  libcurl archive is vendored or copied into the App bundle. The Linux CLI is
  fully static and therefore incorporates the corresponding object code from
  the official
  `swift-6.3.3-RELEASE_static-linux-0.1.0` SDK: curl (`8.15.0` in the SBOM,
  `8.15.0-DEV` in the headers, source tag `curl-8_15_0` at
  `cfbfb65047e85e6b08af65fe9cdbcf68e9ad496a`, SPDX `curl` terms used
  conservatively), BoringSSL `libssl`/`libcrypto`
  (`817ab07ebb53da35afea409ab9328f578492832d`, vendor license expression
  `OpenSSL AND ISC AND MIT`, with the exact revision's complete combined
  license and acknowledgments preserved), and zlib 1.3.1 (`v1.3.1` at
  `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`, `Zlib`). The official SDK
  archive checksum, extracted SBOM hash, Swift recipe and source/header
  identity checks, both architecture archive hashes, provenance boundary, and
  full distribution obligations are in
  `ThirdPartyNotices/MCPHTTPTransport.md`.

Translatis keeps only the client protocol/runtime closure. It does not ship the
upstream Server actor, HTTP Server transports, paired in-memory/custom network
transports, conformance server/client executables, server-side OAuth
publishing/validation API, SwiftNIO, or the documentation plugin. Protocol
wire schemas located upstream under `Server/` are retained only where the
client must encode/decode tools, resources, prompts, completion, and logging.
The complete source inventory and modifications are in
`Vendor/MCPClientSDK/UPSTREAM.md` and `Vendor/MCPClientSDK/PATCHES.md`; full
dependency notices and license texts are in
`ThirdPartyNotices/MCPClient.md` and `ThirdPartyNotices/Licenses/`.

The client-side deferred-tool search is a Swift derivative of the public
`tool_search` behavior in OpenAI Codex commit
`61a44880a85d2fd0d8770908dea5733495e571c8` (Apache-2.0) and of the exact
`bm25 2.3.2` English tokenizer/scoring closure selected there. It embeds
licensed deunicode tables, the stop-word list, and a Swift port of the English
Snowball stemmer; no Rust runtime or MCP Server is shipped. Exact source
revisions/checksums, reuse classifications, modifications, exclusions, and
license notices are in `ThirdPartyNotices/MCPToolSearch.md`.
The portable cryptography dependency graph, exact component provenance,
integrity hashes, BoringSSL/XKCP attributions, and distributed license/NOTICE
texts are in `ThirdPartyNotices/SwiftCrypto.md` and
`ThirdPartyNotices/Licenses/`.
The separate native HTTP link closure and the distinction between Apple
system libcurl, the Static Linux SDK's BoringSSL commit
`817ab07ebb53da35afea409ab9328f578492832d`, and Swift Crypto's independently
pinned BoringSSL source are recorded in
`ThirdPartyNotices/MCPHTTPTransport.md`; neither BoringSSL identity may be used
as provenance for the other.

## Feature and asset status

- Syntax highlighting is disabled. The current root dependency graph contains
  no HighlightSwift or highlight.js package, and the former vendored
  `highlight.min.js` and a11y CSS resources are removed. See
  `ThirdPartyNotices/SyntaxHighlighting.md`.
- The Microsoft renderer supports code-aware TeX delimited by `$...$` or
  `\(...\)` for inline math and `$$...$$` or `\[...\]` for display math
  through iosMath on macOS and iOS. The derivative adds no formula-count,
  per-formula UTF-8, or fixed attachment-size cap. Fenced and inline code
  remain byte-exact literal text; currency, escaped delimiters, and malformed
  formulas remain literal. The permanent `.plainSafe` mode bypasses Markdown
  and math parsing entirely.
- The derivative also removes Shimmer, SnapshotTesting, upstream branded color
  and media asset catalogs, and their associated first-release surface. Its
  directly owned package resource remains the localization catalog. iosMath
  separately supplies `iosMath_iosMath.bundle` with its audited math-font and
  license resources.

## Integration and distribution boundary

- Markdown rendering is linked only through `IntatisSharedUI` on Apple
  platforms. It does not add shell, Git, workspace-agent, or Cowork execution
  capabilities to iOS or to the CLI/headless graph.
- Rendering operates on projected message text and does not own or mutate
  EventLog records, capability leases, permission decisions, workspace paths,
  credentials, or provider requests.
- The current first-release profile disables images, citations, animation,
  and syntax highlighting. Inline and display LaTeX math are native; code
  blocks remain plain text with a native copy control.
- iosMath uses AppKit/UIKit/Core Text and its bundled OpenType math data. It
  does not add a WebView, JavaScript runtime, network request, shell, Git,
  workspace-agent, or Cowork capability. The bundled math fonts are
  typesetting resources and do not change Translatis' separately selected
  product-interface font. Translatis hosts formulas as live TextKit 2 attachment
  views using iosMath intrinsic layout, semantic appearance, and Dynamic Type,
  without a derivative formula-count, source-size, or fixed attachment-size
  cap; it does not retain a formula raster cache.
- Distributed macOS and iOS artifacts must make this file and the referenced
  detailed notices readable in the application. Merely keeping them in the
  source tree is not sufficient.
- A distributed source or binary must be traceable to a Translatis root revision
  containing the vendored package, its Microsoft `LICENSE`, and the adjacent
  patch ledger. Uncommitted local edits are not a release identity.

## Other source status

- `Experiments/WebRendererParity` is a source-tree-only, private npm
  experiment. It independently implements a Markdown/TeX/code rendering
  behavior contract with exact dependencies recorded in its
  `package-lock.json`: React/react-dom 19.2.8, react-markdown 10.1.0,
  remark-gfm 4.0.1, remark-breaks 4.0.0,
  micromark-extension-llm-math 3.1.1-20250610, mdast-util-math 3.0.0,
  KaTeX 0.16.21, and CodeMirror 6 packages. Its build/test tooling includes
  Vite 7.2.4, TypeScript 7.0.2, Vitest 4.1.10, jsdom 29.1.1, and Testing
  Library.
  **Reuse type: `dependency`; scope: the isolated experiment only.**
  Exact direct-package provenance, licenses, font/grammar scope, and the
  transitive-license audit command are in
  `Experiments/WebRendererParity/THIRD_PARTY_NOTICES.md`.
- The experiment is not referenced by SwiftPM, XcodeGen, App/CLI targets,
  release resources, or the Translatis runtime. Its npm packages, generated
  JavaScript, CSS, language chunks, and fonts are not included in current
  macOS/iOS/CLI distributions. It does not copy or redistribute ChatGPT
  production bundles, private source, prompts, brand assets, screenshots, or
  user conversations.
- OpenCode (`anomalyco/opencode`, MIT) remains research-only. No OpenCode
  source, public prompt, UI asset, or runtime is currently linked, vendored, or
  copied into Translatis.
- `CodeEditor` (`mchakravarty/CodeEditor`) was evaluated but is not adopted,
  linked, vendored, or copied.
- libgit2 / SwiftGit2 remain planned candidates only and require a separate
  license and integration review before adoption.

The Swift standard library, Foundation, SwiftUI, AppKit, UIKit, and other Apple
system frameworks are provided by the Apple toolchain and are not vendored
third-party packages in this repository.

Update this file whenever an upstream source, dependency, bundled runtime,
licensed asset, or immutable renderer revision changes.
