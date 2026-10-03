# JetBrains Mono product typography notice

This notice covers the two unmodified JetBrains Mono font files bundled for
Translatis' unified first-party English typography. The user approved retaining
the exact implementation on 2026-08-19 after its visual trial; it is an
approved v0.55 product design decision for macOS and iOS.

## Upstream and license

- Project: JetBrains Mono
- Upstream repository: <https://github.com/JetBrains/JetBrainsMono>
- Official product page: <https://www.jetbrains.com/lp/mono/>
- Version/tag: `v2.304`
- Commit: `cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9`
- Reuse type: `vendored`, unmodified font binaries
- License: SIL Open Font License 1.1 (`OFL-1.1`)
- Typeface designer: Philipp Nurullin
- Project lead: Konstantin Bulenkov

The complete upstream license text is preserved byte-for-byte at
`ThirdPartyNotices/Licenses/JetBrainsMono-2.304-OFL-1.1.txt`.

## Exact adopted files

| Upstream path | Local bundle resource | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `fonts/variable/JetBrainsMono[wght].ttf` | `Packages/IntatisSharedUI/Sources/Resources/JetBrainsMono[wght].ttf` | 303,144 | `662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016` |
| `fonts/variable/JetBrainsMono-Italic[wght].ttf` | `Packages/IntatisSharedUI/Sources/Resources/JetBrainsMono-Italic[wght].ttf` | 308,888 | `f115aaa12113718c02ce72864fe6823b87241bc23d3e44cf1220155f861063f2` |
| `OFL.txt` | `ThirdPartyNotices/Licenses/JetBrainsMono-2.304-OFL-1.1.txt` | 4,399 | `30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad` |

No JetBrains source files, build scripts, static-font collection, webfonts,
IDE integration, logo, screenshots, product copy, or other brand assets are
adopted by this integration.

## Intatis integration boundary

- Normal macOS and iOS launches always use JetBrains Mono for first-party
  English typography. There is no runtime opt-out, alternate product default,
  UserDefaults preference, or release-script switch.
- The two files are owned by the `IntatisSharedUI` SwiftPM resource bundle, so
  macOS, iOS, plain/rich rendering, and SharedUI tests resolve the same exact
  bytes through `Bundle.module`; there is no App-only duplicate copy.
- Before use, Intatis verifies the two bundled SHA-256 values and
  the complete expected Core Text PostScript-name inventories before
  registering either file at process scope. It then verifies every registered
  name resolves back to the exact bundled URL. Missing, altered, conflicting,
  or unresolvable resources fail application startup; Intatis does not
  switch to an installed copy or another typeface.
- The product typography routes first-party SwiftUI role fonts, direct semantic/system
  font call sites, plain messages, and the existing Markdown render
  configuration through the registered family. The vendored Markdown
  derivative only received a narrow patch so its code block uses its existing
  `MarkdownRenderConfig` fonts instead of bypassing them.
- JetBrains Mono does not contain CJK glyphs used by Translatis. Core Text retains
  normal glyph fallback, so Chinese text continues to resolve to the Apple
  system CJK family; a local Core Text probe resolved `English` to
  `JetBrainsMono-Regular` and `中文` to `PingFangSC-Regular`.
- The typography decision does not change EventLog, localization, provider prompts,
  model output bytes, session data, permissions, platform linkage, or user
  preferences. It adds no network or executable runtime.

Formal releases must preserve the exact two-resource inventory, hashes,
OFL notice, Core Text resolution checks, CJK fallback boundary, and normal
accessibility/localization/final-bundle verification. A changed or incomplete
font closure fails closed and requires a new dependency and product review.
