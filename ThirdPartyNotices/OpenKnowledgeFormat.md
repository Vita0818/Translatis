# Open Knowledge Format v0.2

Intatis adopts a byte-exact copy of the self-contained Open Knowledge Format
(OKF) v0.2 specification as a third-party standard baseline for portable
knowledge content. This adoption does not include or execute the upstream
reference implementation.

## Provenance

- Repository: `https://github.com/GoogleCloudPlatform/knowledge-catalog.git`
- Specification commit: `3fcbb9f828c2f23d109c855ee403c3a4c81f3a96`
- Specification path: `okf/SPEC.md`
- Specification Git blob: `a516d50128f5aa1f5746d1464661a39f7143e875`
- Specification SHA-256: `5a3311d270bebb16d558010e75064f5b75323f284992641732b1c8097511f948`
- Audited upstream head for the license: `374e0bc4c644310ff56cdf9c0fe81eccdec862b0`
- License path: `okf/LICENSE.md`
- License SHA-256: `8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac`
- License: Apache License 2.0
- Reuse classification: pinned, unmodified standard documentation

The inspected upstream repository did not provide a dedicated v0.2 tag, so
the commit and byte hashes above are the reproducible identity. The adopted
files live at `ThirdPartyStandards/OpenKnowledgeFormat/0.2/` and are verified
by the adjacent `SHA256SUMS` file.

## Included and excluded scope

Included:

- the self-contained `okf/SPEC.md` document;
- the upstream Apache-2.0 `okf/LICENSE.md` text;
- Intatis-authored provenance and checksum records.

Excluded:

- the upstream Python reference agent and package;
- public prompts, samples, example data bundles, viewers, HTML, CSS, and JavaScript;
- executors, attesters, connectors, hosted services, and brand assets.

Intatis' OKF RAG Profile, validator, snapshot store, indexes, and tool
contracts are separately authored integration code. They do not modify the
pinned specification and do not claim that OKF itself defines embeddings,
vector indexes, reranking, access control, or a RAG runtime.
