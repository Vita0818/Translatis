# Translatis Runtime Kit 0.66

This directory documents the small, reusable integration boundary for the
fixed macOS runtimes used by Translatis. It is not another runtime implementation
and it does not add an application feature.

The locally prepared kit lives at:

```text
/Users/vita/Vitemis/Translatis/.translatis/runtime-kit/0.66
```

`.translatis/` is intentionally ignored by Git because the runtime payload is
about 5.8 GiB. The checked-in release specifications, build scripts, validators,
patches, locks, and notices remain the reproducible source contract; generated
binaries do not enter source control.

## Fixed layout

```text
0.66/
  runtime-kit.json
  CodexRuntime/
    arm64/
    x86_64/
  DocumentRuntime/
    arm64/
    x86_64/
  BrowserRuntime/
    arm64/
    x86_64/
```

Every architecture root contains its own `runtime-manifest.json`, complete
`SHA256SUMS.txt`, SPDX inventory, and license/notice closure. The common runtime
release is `2026.08.27.1`.

The fixed components are:

- Codex: `codex-cli 0.145.0-intatis.4`, derived from OpenAI Codex
  `rust-v0.145.0`, including the exact three checked-in Intatis patches.
- Document: CPython, Docling, PyTorch, Tesseract, Tectonic, LibreOffice, and the
  fixed document-model assets declared by the document release spec.
- Browser: Node.js `24.20.0`, Playwright `1.56.1`, and its matching Chromium
  revision `1194` (`141.0.7390.37`).

## Consumer contract

1. Select exactly the host application's active architecture. Do not fall back
   to a system Codex, Python, Node.js, Playwright, Chrome, or another provider.
2. Validate the kit before copying or launching anything:

   ```sh
   /Users/vita/Vitemis/Translatis/scripts/validate-runtime-kit.sh \
     /Users/vita/Vitemis/Translatis/.translatis/runtime-kit/0.66
   ```

3. A macOS application embeds only the roots it uses at these exact resource
   paths:

   ```text
   Contents/Resources/CodexRuntime/<architecture>
   Contents/Resources/DocumentRuntime/<architecture>
   Contents/Resources/BrowserRuntime/<architecture>
   ```

   A universal distributable application may embed both architecture roots.
   A local Apple-silicon development application normally needs only `arm64`.
4. Swift consumers add this repository as a package and depend only on the
   products they use:

   - `IntatisCodexRuntime` for the official Codex App Server lifecycle and
     protocol host;
   - `IntatisTools` for the existing document and browser tools.

   The runtime payload stays outside SwiftPM and is copied as an application
   resource. This avoids duplicating multi-gigabyte binaries in every package
   checkout.
5. Preserve each selected root without removing its manifest, hash inventory,
   SBOM, or third-party notices. A consumer build is responsible for its own
   final nested-code signing and outer application resource seal.

## What this kit is not

The local kit is not Developer ID signed, notarized, stapled, or a public
release artifact. It is a fixed development/integration payload for other
local projects. It does not authorize publishing the binaries and it does not
replace the separate formal distribution gates.

No compatibility layer is provided. A missing, changed, wrong-architecture,
or incompatible root must fail clearly rather than switching to a system or
legacy runtime.
