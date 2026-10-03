# Intatis browser runtime release contract

The shipping macOS browser tools use one fixed official runtime chain:
Node.js 24.20.0 LTS, Playwright/Playwright Core 1.56.1, and the exact
Playwright-matched open-source Chromium revision 1194 (141.0.7390.37).
Chrome for Testing, system Chrome/Edge/Chromium, a workspace `node_modules`,
global npm roots, `PATH`, and the legacy CDP launcher cannot satisfy the App
runtime contract.

Each architecture root has this layout:

```text
<architecture-root>/
  runtime-manifest.json
  SHA256SUMS.txt
  bin/node
  node_modules/playwright/
  node_modules/playwright-core/
  chromium/Chromium.app/
  ThirdPartyNotices/runtime.spdx.json
  ThirdPartyNotices/LICENSES.txt
  ThirdPartyNotices/licenses/
```

`scripts/build-browser-runtime.sh` obtains only the fixed source artifacts,
verifies every archive before extraction, normalizes the Chromium application
layout, captures the exact binary's built-in `chrome://credits` dependency
notices, and writes a complete file inventory. The shipping host additionally
checks the Node and Playwright versions and forces Playwright to launch the
bundled Chromium executable.

`scripts/validate-browser-runtime.sh` performs static integrity, architecture,
load-command, license/SBOM, and optional signature checks. Signed roots must
give only the fixed Node and Chromium main/helper processes the reviewed JIT,
unsigned-executable-memory, and library-validation entitlements required by
V8/Chromium under Hardened Runtime. Its execute modes perform a real
Playwright launch, page render, and clean close, and are permitted only after
the root is inside a strictly sealed outer App.
`execute-local` accepts only ad-hoc Hardened Runtime signing and is not a
Developer ID/notarization release result.
