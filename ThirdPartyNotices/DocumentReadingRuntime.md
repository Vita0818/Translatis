# Structured document reading runtime provenance

## Adoption status and boundary

- Reuse class: pinned external runtime dependencies; no upstream parser source
  is copied into Intatis Swift sources.
- Product scope: macOS and non-iOS headless document tools only.
- Ordinary read formats: DOCX, PPTX, XLSX, HTML, and EPUB.
- Explicit OCR format: PDF only.
- Distribution status: the source integration, release manifest, integrity
  validator, and App staging gate exist. This repository does not contain or
  claim completed, signed `arm64`/`x86_64` runtime roots, a notarized App that
  embeds them, or a clean-machine acceptance result.

Ordinary readers call the public Docling `DocumentConverter`,
`DoclingDocument.iterate_items`, ranged `export_to_markdown`, and
`HierarchicalChunker` APIs. Intatis owns only the fixed tool schemas, source
identity checks, bounded result windows, opaque continuation cursors,
permission/lease enforcement, sandbox invocation, and result-envelope
validation. It does not implement an OOXML, HTML, EPUB, PDF, or OCR semantic
parser. The OOXML ZIP checks in the host script are hostile-input preflight
limits, not a content-reading fallback.

## Exact direct runtime contract

The canonical machine-readable pins are in
`Packages/IntatisTools/Runtime/document-runtime/release-spec.json`.

| Component | Fixed identity | Upstream/license metadata |
|---|---|---|
| CPython | 3.11.9 | Python Software Foundation License Version 2 |
| Docling / docling-slim | 2.117.0; upstream tag `v2.117.0`, commit `f2683c0b5aa14a53b74373b0640260891cdbc1b0` | MIT |
| docling-core | 2.89.0 | MIT |
| docling-parse | 7.8.1 | MIT |
| python-docx | 1.2.0 | MIT |
| python-pptx | 1.0.2 | MIT |
| openpyxl | 3.1.5 | MIT |
| lxml | 6.1.1 | BSD-3-Clause |
| pypdfium2 | 5.12.1 | BSD-3-Clause and Apache-2.0 code plus the bundled PDFium dependency-license closure; not a single-license binary |
| Docling layout model | `docling-project/docling-layout-heron` revision `8f39ad3c0b4c58e9c2d2c84a38465abf757272d8` | Apache-2.0; only `config.json`, `preprocessor_config.json`, and `model.safetensors` are runtime inputs |
| Tesseract | 5.5.3, upstream tag `5.5.3`, commit `db0ec62` | Apache-2.0 |
| tessdata_fast | 4.1.0; exact English `eng.traineddata` hash | Apache-2.0 |
| Tectonic | 0.15.0, upstream tag `tectonic@0.15.0`, commit `0a8e2f52b895e2fd60cb461c1859b927a18e024d` | MIT for Tectonic; the bundled XeTeX/TeXLive resource closure carries multiple upstream licenses and must be inventoried separately |
| LibreOfficeDev | 26.8.0.0.beta1 | The Document Foundation distribution; MPL-2.0/LGPL secondary-license and bundled third-party obligations must be taken from the exact App distribution |

Docling 2.117.0's PyPI release uses trusted publishing and records source
commit `f2683c0b5aa14a53b74373b0640260891cdbc1b0`; its source archive SHA-256 is
`48853b979450770a8e2e0c3a0bb6a2a8a22cede593b92083ca672584757ce31d`
and its universal wheel SHA-256 is
`524ed03a8036c8a192ff5d2f2dfa950d33be08f4bec5693d08365eb74ecfbcfa`.
Those direct hashes do not stand in for the resolved Python/native runtime
closure.

Primary upstream references checked for this contract on 2026-08-23:

- Docling 2.117.0 release and artifact attestations:
  <https://pypi.org/project/docling/2.117.0/>
- DoclingDocument iteration/ranged Markdown APIs:
  <https://docling-project.github.io/docling/reference/docling_document/>
- Docling hierarchical chunking:
  <https://docling-project.github.io/docling/concepts/chunking/>
- Heron model card and Apache-2.0 metadata:
  <https://huggingface.co/docling-project/docling-layout-heron>
- Tesseract 5.5.3 release:
  <https://github.com/tesseract-ocr/tesseract/releases/tag/5.5.3>
- Tectonic 0.15.0 release and MIT/source-derived licensing notice:
  <https://github.com/tectonic-typesetting/tectonic/releases/tag/tectonic%400.15.0>
  and <https://github.com/tectonic-typesetting/tectonic/blob/tectonic%400.15.0/LICENSE>
- LibreOfficeDev 26.8 beta1 announcement:
  <https://qa.blog.documentfoundation.org/2026/07/08/libreoffice-26-8-beta1-is-available-for-testing/>

The Heron model-card image and Hugging Face cache metadata are deliberately
excluded from the release runtime. The three required model files and the
single English Tesseract data file have repository-owned SHA-256 values in
the release spec, independently of each architecture root's complete
`SHA256SUMS.txt`. The Tectonic cache is release-built, read-only at tool time,
fully inventoried, and used with `--only-cached`; a tool call may not download
or substitute TeX resources.

## Required binary-distribution evidence

Every releasable architecture root must contain all of the following:

1. a manifest matching the repository release spec;
2. a complete regular-file SHA-256 inventory with no escaping symlink;
3. an SPDX JSON SBOM for Python, wheels, native libraries, models/data,
   Tesseract, Tectonic and its offline TeX resource closure, and LibreOffice;
4. a non-empty license inventory and the exact license/NOTICE/copyright texts
   for every distributed component;
5. the exact model and tessdata file sets and hashes plus complete Tectonic
   cache inventory;
6. executable version checks under the target architecture, the expected
   architecture in every Mach-O, and no build-machine/Homebrew/user-framework
   absolute dependency or non-system absolute `LC_RPATH`;
7. bottom-up Developer ID signatures for every Mach-O, using the same selected
   identity as the outer App.

`scripts/validate-document-runtime.sh` mechanically enforces the manifest,
file/hash, SPDX-2.3 structure, target-architecture, Mach-O load-command, and
signature conditions. SBOM completeness still requires release review against
the resolved distribution; a syntactically valid package list is not proof of
transitive completeness. Static validation never executes runtime content.
Fixed version probes run only in the second phase, after the runtime is inside
an outer App whose strict resource seal and exact Developer ID identity have
been verified, and use validation-owned temporary `HOME`/`TMPDIR` directories.
`scripts/package-macos-release.sh` requires independent `arm64` and `x86_64`
roots, validates them before and after copying them into
`Translatis.app/Contents/Resources/DocumentRuntime`, and refuses to continue if
the closure is missing or inconsistent. The outer App remains subject to its
existing Developer ID, Hardened Runtime, notarization, staple, and Gatekeeper
gates.

The current integration also enforces timeout/cancellation, process-tree
cleanup, generated-output bounds, workspace confinement, default network
denial, and an independent 2 GiB aggregate resident-set ceiling. None of
these host controls changes or substitutes for upstream license obligations.

## Upgrade rule

Any component, model revision, language-data file, direct package version, or
runtime layout change requires a new release spec, renewed upstream and
license review, regenerated per-architecture SBOM/license/inventory artifacts,
fresh signatures, focused document corpus tests, and a new clean-machine
release validation. Runtime code must never download or select an alternate
parser/model automatically.
