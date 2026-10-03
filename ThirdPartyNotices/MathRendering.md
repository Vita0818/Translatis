# Math rendering third-party notices

This notice covers the native math engine and font resources conditionally
linked into the Intatis Markdown renderer on macOS and iOS.

## iosMath

- Upstream: <https://github.com/kostub/iosMath>
- Version/tag: `2.5.0`
- Commit: `838cddc01fdd67efd530f8bb67959ad2715f9b06`
- Tree: `a01638e2bffe9064cb77c66f766ce67c83ca3201`
- Local reuse mode: `dependency`
- Product role: native TeX math parsing and layout for code-aware
  inline and display math on macOS and iOS
- License files reviewed: root `LICENSE`, `iosMath/fonts/*.txt`, the bundled
  per-font README files, and the font inventory at the pinned revision
- Engine license: MIT
- SwiftPM contract: Swift tools 6.0, iOS 13 or newer, macOS 10.15 or newer,
  one `iosMath` library product, and no transitive package dependency

The Intatis derivative pins iosMath exactly to 2.5.0 and links its product only
when building for iOS or macOS. Intatis does not copy or modify the iosMath
parser/layout engine or its sample wrapper. The code-aware delimiter
preprocessing, attachment integration, accessibility source preservation, and
first-release feature policy are changes maintained in the vendored
SwiftStreamingMarkdown derivative and recorded in its adjacent patch ledger.
The derivative recognizes `$...$` / `\(...\)` inline and `$$...$$` /
`\[...\]` display delimiters outside protected Markdown literals. It adds no
formula-count, per-formula UTF-8, or fixed attachment-size cap.

iosMath uses Foundation, Core Graphics, QuartzCore, Core Text, and UIKit or
AppKit. It does not use a WebView, JavaScript runtime, network service, shell,
Git, provider credential, or workspace-agent capability. Rendering consumes a
disposable projection of the raw message and does not mutate EventLog content.

The upstream package uses `.copy("fonts")`. The audited 2.5.0 resource
directory therefore enters `iosMath_iosMath.bundle` without filename or byte
changes:

- 8 OpenType fonts: 5,177,720 bytes
- 8 math-table property lists: 2,018,072 bytes
- 5 license texts, 4 per-font README files, and
  `math_table_to_plist.py`
- 26 files and 7,234,424 bytes in the copied `fonts/` payload

Xcode/SwiftPM also generates a root `Info.plist` for the resource bundle.
Consequently, a built `iosMath_iosMath.bundle` contains 27 files in total:
that generated plist plus the exact 26-file / 7,234,424-byte `fonts/`
payload. The resource-copy behavior was checked by byte comparison against an
isolated iOS Simulator Release product. Cambria Math is proprietary and is
intentionally not included by iosMath or Intatis.

The exact dependency audit used Swift 6.3.3 / Xcode 26.6. macOS SwiftPM Debug,
macOS SwiftPM Release, compile-only `swift build --build-tests`, and an
unsigned iOS Simulator Release build all completed at the pinned revision.
The upstream test executables were not run, so this evidence must not be
described as an upstream test pass. Intatis' renderer integration, streaming,
accessibility, resource, and GUI-performance gates remain separate release
obligations.

Intatis explicitly approved use of iosMath 2.5.0 and distribution of the
audited unmodified GUST/LPPL and OFL font resources on 2026-07-23.

### MIT License — iosMath

Copyright (c) 2013 MathChat

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

## Bundled font inventory and license mapping

The following files are iosMath resources, not Intatis-owned interface assets.
They are distributed unmodified under their upstream filenames. The default
iosMath font is Latin Modern Math; all eight fonts remain in the package
resource bundle regardless of which one is selected for formula layout.

| Bundled file | Version and upstream attribution | License |
| --- | --- | --- |
| `latinmodern-math.otf` | Latin Modern Math 1.959; Bogusław Jackowski, Piotr Strzelczyk, Piotr Pianowski; math extensions copyright 2012–2014 on behalf of TeX Users Groups | GUST Font License / LPPL 1.3c or later |
| `newcm-math.otf` | New Computer Modern Math 4.0; Antonis Tsolomitis; embedded copyright 2019–2026 | GUST Font License / LPPL 1.3c or later |
| `texgyrepagella-math.otf` | TeX Gyre Pagella Math 1.632; README credits Bogusław Jackowski, Janusz M. Nowacki, Piotr Strzelczyk and GUST e-foundry; embedded OTF metadata instead names Jackowski, Strzelczyk and Pianowski | GUST Font License / LPPL 1.3c or later |
| `texgyretermes-math.otf` | TeX Gyre Termes Math 1.543; Bogusław Jackowski, Piotr Strzelczyk, Piotr Pianowski | GUST Font License / LPPL 1.3c or later |
| `xits-math.otf` | XITS Math 1.302; STI Pub Companies, MicroPress, Elsevier, (URW)++, Khaled Hosny, Daniel Benjamin Miller | SIL Open Font License 1.1; reserved names include STIX Fonts and TM Math |
| `stixtwo-math.otf` | STIX Two Math 2.13 b171; copyright 2001–2021 The STIX Fonts Project Authors | SIL Open Font License 1.1; reserved name `TM Math`; STIX Fonts is an IEEE trademark |
| `firamath.otf` | Fira Math 0.3.4; copyright 2018–2020 The Fira Math Project Authors; Xiangdong Zeng | SIL Open Font License 1.1 |
| `notosansmath.otf` | Noto Sans Math 3.000; copyright 2022 The Noto Project Authors / Google LLC | SIL Open Font License 1.1 |

For artifact verification, the audited OpenType SHA-256 values are:

| Bundled file | SHA-256 |
| --- | --- |
| `firamath.otf` | `2028cbd3dd4d8c0cf1608520eb4759956a83a67931d7b6d8e7c313520186e35b` |
| `latinmodern-math.otf` | `6075562b771f8b82f0c179e363389684f2dd09de30038269e2628e504bd7be0f` |
| `newcm-math.otf` | `141c93c9ac86810e9a7285eb82a5a5feeb7777edc7aa29cfe20091ecf34ca50a` |
| `notosansmath.otf` | `a1afc85eed062ed59da17d228d65e89a379032b9cb07603cd4f26cc7a2535ab9` |
| `stixtwo-math.otf` | `3a5f3f26f40d5698b3c62dd085d48d6663696a3f80825aab8b553d5097518e8c` |
| `texgyrepagella-math.otf` | `1f9e010f60e947d0e925910009b2ea85ad54edc7cefb106f8cdefb9ffd1d5f2f` |
| `texgyretermes-math.otf` | `e5ce42b4fe826b7ea4c0874359decf0b294439355c511a4794107a9924e2cd5a` |
| `xits-math.otf` | `3025792adb0b7072ace08bf5726d341de32f2254612ddec6dd98271a8dd29689` |

## GUST Font License notice

The following notice is shipped by iosMath as
`iosMath/fonts/GUST-FONT-LICENSE.txt`:

> This is a preliminary version (2006-09-30), barring acceptance from the
> LaTeX Project Team and other feedback, of the GUST Font License. (GUST is the
> Polish TeX Users Group, <http://www.gust.org.pl>.)
>
> For the most recent version of this license see
> <http://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt> or
> <http://tug.org/fonts/licenses/GUST-FONT-LICENSE.txt>.
>
> This work may be distributed and/or modified under the conditions of the
> LaTeX Project Public License, either version 1.3c of this license or (at your
> option) any later version.
>
> Please also observe the following clause: it is requested, but not legally
> required, that derived works be distributed only after changing the names of
> the fonts comprising this work and given in an accompanying "manifest", and
> that the files comprising the Work, as listed in the manifest, also be given
> new names. Any exceptions to this request are also given in the manifest.
>
> We recommend the manifest be given in a separate file named
> `MANIFEST-<fontid>.txt`, where `<fontid>` is some unique identification of
> the font family. If a separate "readme" file accompanies the Work, we
> recommend a name of the form `README-<fontid>.txt`.
>
> The latest version of the LaTeX Project Public License is in
> <http://www.latex-project.org/lppl.txt> and version 1.3c or later is part of
> all distributions of LaTeX version 2006/05/20 or later.

The rename clause is a request, not a legal requirement. Intatis distributes
these fonts unmodified under their upstream filenames. The raw GUST notice and
the four per-font README files are also preserved inside the iosMath resource
bundle.

## SIL Open Font License 1.1 attributions

The copyright and reserved-name statements shipped with the four OFL fonts
are preserved below:

- XITS Math: Copyright (c) 2001–2010, STI Pub Companies, consisting of the
  American Institute of Physics, the American Chemical Society, the American
  Mathematical Society, the American Physical Society, Elsevier, Inc., and The
  Institute of Electrical and Electronic Engineers, Inc.
  (`www.stixfonts.org`), with Reserved Font Name STIX Fonts; STIX Fonts is a
  trademark of IEEE. Copyright (c) 1998–2003, MicroPress, Inc.
  (`www.micropress-inc.com`), with Reserved Font Name TM Math. Copyright (c)
  1990, Elsevier, Inc. Copyright (c) 2014, 2015, (URW)++ Design & Development.
  Copyright (c) 2009–2019, Khaled Hosny. Copyright (c) 2019, Daniel Benjamin
  Miller.
- STIX Two Math: Copyright 2001–2021 The STIX Fonts Project Authors
  (<https://github.com/stipub/stixfonts>), with Reserved Font Name `TM Math`.
  STIX Fonts is a trademark of The Institute of Electrical and Electronics
  Engineers, Inc.
- Fira Math: Copyright 2018–2020 The Fira Math Project Authors
  (<https://github.com/firamath/firamath>).
- Noto Sans Math: Copyright 2022 The Noto Project Authors
  (<https://github.com/notofonts/math>).

The four source notices remain in `iosMath_iosMath.bundle` as `OFL.txt`,
`OFL-STIXTwo.txt`, `OFL-FiraMath.txt`, and `OFL-NotoSansMath.txt`.

### SIL Open Font License Version 1.1 — 26 February 2007

PREAMBLE

The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership with
others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The fonts,
including any derivative works, can be bundled, embedded, redistributed
and/or sold with any software provided that any reserved names are not used by
derivative works. The fonts and derivatives, however, cannot be released under
any other type of license. The requirement for fonts to remain under this
license does not apply to any document created using the fonts or their
derivatives.

DEFINITIONS

"Font Software" refers to the set of files released by the Copyright Holder(s)
under this license and clearly marked as such. This may include source files,
build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the copyright
statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting, or
substituting -- in part or in whole -- any of the components of the Original
Version, by changing formats or by porting the Font Software to a new
environment.

"Author" refers to any designer, engineer, programmer, technical writer or
other person who contributed to the Font Software.

PERMISSION & CONDITIONS

Permission is hereby granted, free of charge, to any person obtaining a copy
of the Font Software, to use, study, copy, merge, embed, modify, redistribute,
and sell modified and unmodified copies of the Font Software, subject to the
following conditions:

1. Neither the Font Software nor any of its individual components, in Original
   or Modified Versions, may be sold by itself.
2. Original or Modified Versions of the Font Software may be bundled,
   redistributed and/or sold with any software, provided that each copy
   contains the above copyright notice and this license. These can be included
   either as stand-alone text files, human-readable headers or in the
   appropriate machine-readable metadata fields within text or binary files as
   long as those fields can be easily viewed by the user.
3. No Modified Version of the Font Software may use the Reserved Font Name(s)
   unless explicit written permission is granted by the corresponding
   Copyright Holder. This restriction only applies to the primary font name as
   presented to the users.
4. The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software
   shall not be used to promote, endorse or advertise any Modified Version,
   except to acknowledge the contribution(s) of the Copyright Holder(s) and
   the Author(s) or with their explicit written permission.
5. The Font Software, modified or unmodified, in part or in whole, must be
   distributed entirely under this license, and must not be distributed under
   any other license. The requirement for fonts to remain under this license
   does not apply to any document created using the Font Software.

TERMINATION

This license becomes null and void if any of the above conditions are not met.

DISCLAIMER

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT,
TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL,
INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF THE USE OR INABILITY TO USE
THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE FONT SOFTWARE.
