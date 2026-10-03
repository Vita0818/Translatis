# MCP tool-search parity notices

This notice covers the external-MCP-client `tool_search` parity implementation
and its source-only differential oracle. It does not add an MCP server, a Rust
runtime, or a Rust dependency to any Intatis product target.

## OpenAI Codex

- Upstream: `https://github.com/openai/codex`
- Fixed commit: `61a44880a85d2fd0d8770908dea5733495e571c8`
- License: Apache License 2.0
- Reuse: `derived` for the public deferred-tool wire contract, model-history
  item shape, MCP search-text fields, and stdio schema-cache behavior
- Relevant upstream files:
  - `codex-rs/core/src/tools/handlers/tool_search.rs`
  - `codex-rs/core/src/tools/handlers/mcp.rs`
  - `codex-rs/core/src/tools/spec_plan.rs`
  - `codex-rs/tools/src/tool_spec.rs`
  - `codex-rs/protocol/src/models.rs`
  - `codex-rs/protocol/src/openai_models.rs`
  - `codex-rs/codex-mcp/src/tool_catalog_cache.rs`
  - `codex-rs/core/tests/suite/search_tool.rs`
  - `codex-rs/core/src/context_manager/normalize.rs`
  - the corresponding response-item and cache tests
- Local implementation:
  - `Packages/IntatisMCP/Sources/MCPToolSearch.swift`
  - `Packages/IntatisMCP/Sources/MCPStdioToolCatalogCache.swift`
  - `Packages/IntatisProtocol/Sources/ModelHistory.swift`
  - `Packages/IntatisProviders/Sources/OpenAIToolCalling.swift`
  - `Packages/IntatisProviders/Sources/Capability.swift`
  - `Packages/IntatisAgentKernel/Sources/AgentLoop.swift`

Intatis translates the public behavior into its own Swift types and retains
its own catalog revision, grant, capability lease, permission, durable tool
ticket, EventLog, and platform boundaries. It does not copy Codex branding,
UI assets, private prompts, or MCP Server code.

The exact upstream `LICENSE` from the fixed Codex commit is distributed
unchanged at
`ThirdPartyNotices/Licenses/Codex-61a44880-Apache-2.0.txt`; its SHA-256 is
`d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc`.

Upstream NOTICE attribution:

```text
OpenAI Codex
Copyright 2025 OpenAI
```

The upstream NOTICE also attributes Codex TUI code derived from Ratatui.
Intatis does not use or derive the Ratatui/TUI files, so that unrelated
attribution does not pertain to this derivative.

## bm25 2.3.2 and exact tokenizer closure

Codex selects
`SearchEngineBuilder::<usize>::with_documents(Language::English, ...)` from
the public `bm25` crate. Intatis has no Rust product dependency; it translates
the selected scoring/tokenization closure into Swift and keeps a source-only
Rust oracle under `Tests/MCPBM25ParityOracle`.

| Component | Fixed source | crates.io SHA-256 | Reuse | License |
| --- | --- | --- | --- | --- |
| `bm25 2.3.2` | `Michael-JB/bm25`, commit `8ef726045b41702e148d8996d344f3500844fde1` | `1cbd8ffdfb7b4c2ff038726178a780a94f90525ed0ad264c0afaa75dd8c18a64` | derived scoring, embedding, and tokenizer pipeline | MIT |
| `deunicode 1.6.2` | `kornelski/deunicode`, commit `cfb8552fbbdf6d1f3f996ee4f2e78ec5e482bcef` | `abd57806937c9cc163efc8ea3910e00a62e2aeb0b8119f1793a978088f8f6b04` | vendored unmodified `mapping.txt`/`pointers.bin` data plus derived lookup | BSD-3-Clause |
| `rust-stemmers 1.2.0` | `CurrySoftware/rust-stemmers`, commit `af9d47d5a52eaaded088145bc7432403dbf706a5` | `e46a2036019fdb888131db7a4c847a1063a7493f971ed94ea82c67eada63ca54` | direct Swift port of the generated English Snowball program | MIT plus the algorithm's BSD-3-Clause |
| `stop-words 0.9.0` | `cmccomb/stop-words`, commit `e3262de134a014843438e92abc35eec75c6b6fed` | `645a3d441ccf4bf47f2e4b7681461986681a6eeea9937d4c3bc9febd61d17c71` | vendored unmodified 179-word NLTK English list | MIT selected from `MIT OR Apache-2.0` |
| `fxhash 0.2.1` | `cbreeden/fxhash` crates.io release | `c31b6d751ae2c7f11320402d34e41349dd1016f8d5d45e48c4312bc8625af50c` | derived `hash32(&str)` behavior | MIT selected from `Apache-2.0/MIT` |
| `unicode-segmentation 1.12.0` | `unicode-rs/unicode-segmentation` crates.io release | `f6ccf251212114b54433ec949fd6a7841275f9ada20dddd2f29e9ceea4501493` | reference only for post-deunicode ASCII-observable UAX #29 behavior; no source or tables copied | MIT/Apache-2.0 |

Local modifications and boundaries:

- `MCPBM25Index.swift` uses the upstream `f32` operation order, parameters
  `k1 = 1.2` and `b = 0.75`, duplicate query terms, `fxhash` token IDs, and
  IDF formula. Exact-score ties receive a stable document-ID tie break because
  the upstream `HashSet` traversal order is unspecified.
- `MCPEnglishTokenizer.swift` performs deunicode-with-`[?]`, lowercasing,
  ASCII-observable Unicode-word boundaries, the exact stop list, then English
  Snowball stemming.
- `MCPDeunicode162Data.generated.swift` losslessly base64-packages the
  unmodified 56,405-byte mapping table and 419,994-byte pointer table. Their
  decoded SHA-256 values are
  `8cb5a957e0bf7b702accc3ba25bf01bb34c1b0cc5d5fa4f0081d36c2cb63db20`
  and
  `f2e1772f608f050555f6bd0f1d7a2b453b929bd02300927ce2db6afb88ad500f`.
- `MCPEnglishSnowballStemmer.swift` is a direct Swift translation over ASCII
  bytes after transliteration. No Rust runtime or FFI is shipped.
- Upstream `rust-stemmers/test_data` was used only in a temporary local
  validation run and is not copied, generated, or distributed by Intatis.
  The checked-in oracle generates its own bounded corpora.

## MIT notices

```text
MIT License

Copyright (c) 2024 Michael Barlow
Copyright (c) 2017 Jakob Demler
Copyright (c) 2023 Chris McComb
Copyright 2015 The Rust Project Developers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## deunicode BSD-3-Clause notice

```text
Copyright (c) 2015, Amit Chowdhury
Copyright (c) 2018-2021, Kornel Lesinski
Copyright (c) 2020-2021, Hunter WB <hunterwb.com>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
* The names of this software's contributors may not be used to endorse or
  promote products derived from this software without specific prior written
  permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## English Snowball BSD-3-Clause notice

```text
Copyright (c) 2001, Dr Martin Porter
Copyright (c) 2004,2005, Richard Boulton
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the Snowball project nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
