# Fixed browser runtime

## Distribution identity

The macOS structured browser tools use one architecture-specific external
runtime. Intatis does not implement a browser engine, DOM, accessibility
tree, JavaScript runtime, or Playwright protocol. The host only selects the
fixed root, invokes the official Playwright public API, applies the existing
workspace/permission/process boundaries, and projects bounded results.

The `2026.08.27.1` runtime release pins:

- Node.js `24.20.0` (MIT);
- Playwright and Playwright Core `1.56.1` (Apache-2.0);
- Playwright Chromium revision `1194`, Chromium
  `141.0.7390.37`, upstream Chromium commit
  `9f043f63b0e5b728c8d09f3e3ddfc1681a4bd58e` (Chromium BSD license plus
  the exact binary's built-in third-party credits).

The exact source URLs and SHA-256 values are in
`Packages/IntatisTools/Runtime/browser-runtime/release-spec.json`. The
architecture roots are assembled outside the source tree by
`scripts/build-browser-runtime.sh`; each root carries its own SPDX-2.3 SBOM,
license inventory, license texts, generated Chromium third-party credits,
manifest, and complete regular-file SHA-256 inventory.

## Product boundary

Shipping `TranslatisMac` selects only
`Contents/Resources/BrowserRuntime/<active-architecture>`. It does not consult
`PATH`, a global npm installation, a system Chrome/Chromium, or a caller CDP
endpoint. Missing, altered, wrong-version, or wrong-architecture runtime
content is a typed failure. Debug and CLI builds may retain explicitly trusted
development lookup, but that path never satisfies an App release gate.

The browser runtime has no iOS target linkage. Runtime processes remain
subject to the existing managed-process cleanup, permission, WorkspaceLease,
Seatbelt, output, and cancellation boundaries.

Primary upstream references checked for this contract on 2026-08-27:

- Node.js 24 release archive: <https://nodejs.org/en/download/archive/v24>
- Playwright browser binaries: <https://playwright.dev/docs/browsers>
- Playwright 1.56.1 source release:
  <https://github.com/microsoft/playwright/releases/tag/v1.56.1>
- Chromium license at the fixed commit:
  <https://chromium.googlesource.com/chromium/src.git/+/9f043f63b0e5b728c8d09f3e3ddfc1681a4bd58e/LICENSE>
