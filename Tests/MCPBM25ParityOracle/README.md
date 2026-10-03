# MCP BM25 parity oracle

This source-only Rust fixture reproduces the exact public crates selected by
OpenAI Codex commit `61a44880a85d2fd0d8770908dea5733495e571c8` for MCP
`tool_search`: `bm25 2.3.2`, `deunicode 1.6.2`, `fxhash 0.2.1`,
`rust-stemmers 1.2.0`, `stop-words 0.9.0`, and
`unicode-segmentation 1.12.0`. Exact crates.io checksums and licenses are
recorded in `ThirdPartyNotices/MCPToolSearch.md`.

It is a developer verification fixture only. It is not linked into Intatis,
not included in an app target, and not an alternate runtime. It generates all
input corpora in code. In particular, it does not copy or distribute
`rust-stemmers/test_data`, whose separate license is outside this fixture.

Run from the Intatis repository root:

```sh
CARGO_TARGET_DIR=/private/tmp/intatis-mcp-bm25-oracle-target \
cargo fetch --locked \
  --manifest-path Tests/MCPBM25ParityOracle/Cargo.toml

CARGO_TARGET_DIR=/private/tmp/intatis-mcp-bm25-oracle-target \
cargo run --quiet --release --locked --offline \
  --manifest-path Tests/MCPBM25ParityOracle/Cargo.toml \
  -- ascii-tokenizer | shasum -a 256
CARGO_TARGET_DIR=/private/tmp/intatis-mcp-bm25-oracle-target \
cargo run --quiet --release --locked --offline \
  --manifest-path Tests/MCPBM25ParityOracle/Cargo.toml \
  -- stemmer | shasum -a 256
CARGO_TARGET_DIR=/private/tmp/intatis-mcp-bm25-oracle-target \
cargo run --quiet --release --locked --offline \
  --manifest-path Tests/MCPBM25ParityOracle/Cargo.toml \
  -- wide-bm25 | shasum -a 256
```

Expected stdout digests:

```text
dc0f9c7b7507cea5bf2298e47561dfe297777f464708da0fe2ea9b8717544f19
a876375f69ea0d7d7e8e60030760907b000652a4b39592d8fcf28ccbb1c68ead
983ecb3965370058ad7bcb405606a8364b1a15648d7c70258cf5db086cd0a06f
```

The corresponding Swift assertions are self-contained in
`Packages/IntatisMCP/Tests/MCPBM25CodexParityTests.swift`:

```sh
swift test --filter MCPBM25CodexParityTests
```

Use `cargo run ... -- golden` to inspect the small human-readable score
fixture. Exact-score ties are sorted by numeric document ID only for stable
oracle output; upstream `HashSet` traversal does not define a tie order.
