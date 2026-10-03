# Intatis document runtime release contract

The document tools use external document engines; Intatis does not implement
DOCX, PPTX, XLSX, HTML, EPUB, or OCR parsers. Ordinary reads are performed by
the pinned Docling public converter/serializer/chunker APIs. Explicit PDF OCR
uses the pinned Docling PDF pipeline and Tesseract. The remaining fixed tools
use PDFKit, WebKit, LibreOffice, python-docx, python-pptx, openpyxl, and
Tectonic only for their declared exact operations.

`release-spec.json` is the repository-owned compatibility contract. It is not
a binary runtime and must not be treated as one. A releasable runtime is built
outside the source tree for each supported architecture and has this layout:

```text
<architecture-root>/
  runtime-manifest.json
  SHA256SUMS.txt
  bin/python3
  bin/tesseract
  bin/tectonic
  libreoffice/26.8.0.0.beta1/LibreOffice.app/
  models/docling/docling-project--docling-layout-heron/
  share/tessdata/eng.traineddata
  share/tectonic/cache/
  ThirdPartyNotices/runtime.spdx.json
  ThirdPartyNotices/LICENSES.txt
  ThirdPartyNotices/licenses/
```

`runtime-manifest.json` repeats `schema_version`, `layout_version`,
`runtime_release`, `components`, and `maximum_resident_bytes` from the release
spec and adds the exact `architecture`. `SHA256SUMS.txt` must inventory every
regular file except the inventory itself, using lowercase SHA-256 followed by
two spaces and a `./` relative path. Symlinks may only resolve within their
architecture root. The release validator additionally compares the three
runtime Heron model files and the fixed English Tesseract data against
repository-owned SHA-256 values. Tectonic's offline cache is shipped as part
of the per-architecture inventory and SBOM; it is never populated by a model
tool call. Model-card images and package-manager metadata are not shipped.

`python-requirements.in` fixes the direct compatibility surface. Each release
also has an architecture-specific generated lock that names every resolved
wheel and its accepted SHA-256. The x86_64 `docling-parse` wheel is built from
the exact official 7.8.1 sdist because that release does not publish a macOS
x86_64 wheel; its build toolchain, static-source commits, final wheel filename,
and SHA-256 are in the release spec. It is an exact-source build artifact, not
an alternate parser. Root assembly requires the exact uv version recorded by
the same spec and uses only the architecture lock plus this reviewed local
wheelhouse entry.

The SBOM and license bundle must describe the complete resolved distribution,
including Python itself, every wheel and native library, model/data licenses,
Tesseract/tessdata, Tectonic plus its pinned offline resource closure, and
LibreOffice with its bundled components. Direct package metadata or a `pip
freeze` file is not a substitute for this transitive inventory.
The automated gate checks valid SPDX-2.3 document metadata, a non-empty
package array, the license bundle, and exact file inventory. Those structural
checks do not prove that an SBOM author found every transitive component;
release review must compare the SBOM and license texts with the resolved
binary closure before accepting either architecture root.

`scripts/build-document-runtime.sh` assembles each architecture root from the
fixed source artifacts and hash locks, emits its SPDX/license bundle and full
file inventory, and publishes the root only after static validation succeeds.
Mach-O load commands may reference only Apple system
libraries or bundle-relative `@loader_path`, `@executable_path`, and `@rpath`
locations; build-machine/Homebrew/user-framework absolute dependencies and
non-system absolute `LC_RPATH` values are rejected. The release script first
validates both unsigned build roots without executing their contents, stages
them, signs all nested code bottom-up with the selected identity and reviewed
entitlements, regenerates signature-sensitive hashes, and then signs the
outer App. The final locations are:

```text
Intatis.app/Contents/Resources/DocumentRuntime/arm64
Intatis.app/Contents/Resources/DocumentRuntime/x86_64
```

Only after the outer App has been signed and its strict resource seal and
exact identity have been verified does the second validation phase execute
the fixed versions plus real Docling DOCX conversion, LibreOffice PDF export,
Tesseract OCR, Tectonic offline compilation, and Docling PDF/OCR/model
pipeline. Those probes use the target architecture with an empty environment
and validation-owned temporary `HOME`/`TMPDIR`.
Direct `execute` mode is rejected unless the runtime is already inside that
verified final App layout.

At runtime the active universal-app slice selects only its matching root. A
CLI or debug build may still use the historical user-managed runtime as an
explicit development fallback; that fallback never satisfies the App release
gate. The tools remain offline and subject to WorkspaceLease, Seatbelt,
timeout/cancellation, process-tree cleanup, output bounds, and the independent
2 GiB aggregate resident-memory ceiling.
