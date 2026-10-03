# Markdown rendering third-party notices

This notice covers the renderer derivative and the exact parser dependency
versions currently resolved by the Intatis working tree. The renderer itself is
a modified upstream work, not an independently authored Intatis renderer.

## Vendored source identity

The root manifest resolves SwiftStreamingMarkdown from the relative in-tree
path `Vendor/SwiftStreamingMarkdown`. The containing Intatis Git revision is
the immutable identity for the derivative source, tests, Microsoft MIT license,
and patch ledger; no separate Intatis fork URL or commit is required. The exact
Microsoft upstream basis and parser revisions below remain fixed and verified.

The package is not fully offline: it still resolves the exact-pinned
`swift-markdown`, transitive `swift-cmark`, and Apple-only `iosMath`
dependencies from their upstream Git repositories when they are absent from
the local SwiftPM cache.

## Microsoft SwiftStreamingMarkdown

- Upstream: <https://github.com/microsoft/SwiftStreamingMarkdown>
- Version/tag: `v0.6.0`
- Upstream commit: `c7b12f7b3d77caa188fd1fc056d0f7ce305ef5cd`
- Local reuse mode: `derived` and `vendored`
- Product role: Markdown document model, parser integration, and native
  SwiftUI/AppKit/UIKit presentation
- License file reviewed: `LICENSE` at the upstream commit and in the local
  candidate
- License: MIT

The inspected upstream-derived candidate contains the MIT `LICENSE` above and
does not contain a separate upstream `NOTICE` file.

The Intatis-maintained vendored derivative is based on the commit above. Its
permanent adjacent ledger at
`Vendor/SwiftStreamingMarkdown/INTATIS_PATCH_LEDGER.md` records
dependency/resource thinning, ownership-transfer and Swift 6 concurrency
hardening, disabled optional features, a native code-copy control, zero native
paragraph-view retention, the later audited code-aware LaTeX patch,
and focused test changes. The initial import removed HighlightSwift, iosMath,
Shimmer, SnapshotTesting, upstream branded color/media assets, the unsafe
regex-based math path, syntax-highlighting implementations, and obsolete
optional-feature tests/snapshots. The current derivative does not restore that
old math implementation: it adds a request-local, code-aware path for common
inline and display delimiters plus an exact iosMath 2.5.0 dependency, without
Intatis-specific formula-count, per-formula byte, or fixed attachment-size
caps.
HighlightSwift, Shimmer, SnapshotTesting, branded assets, images, citations,
animation, and syntax highlighting remain removed or disabled. The
derivative's directly retained resource is the localization catalog; iosMath
owns a separate audited resource bundle containing math fonts and their
license/readme data. The derivative manifest contains only the library and
test targets; scratch validation probes and executable targets are absent
from the vendored tree.

The current macOS derivative also removes competing intrinsic paragraph
width, returns the exact SwiftUI proposal width with a measured height, and
bounds paragraph measurement memoization to the latest exact width. This is a
local derivative patch; it does not change the upstream basis, license,
parser dependency, or iosMath dependency.

The macOS derivative additionally coordinates direct mouse-drag selection
across the existing TextKit paragraph leaves of one rendered document. It does
not restore the removed SwiftUI whole-document `SelectionOverlay` or introduce
a second Markdown renderer: headings, paragraphs, list contents, block quotes,
tables, code, links, and live math attachments keep their existing native
owners, while a document-scoped AppKit coordinator distributes the transient
selection ranges, applies/restores system-accent emphasis only in each view's
disposable attributed projection, and combines displayed plain text for Copy. iOS keeps
the preceding leaf-selection path. This local patch does not change the
upstream identity, dependency graph, or licensing.

## iosMath integration

- Upstream: <https://github.com/kostub/iosMath>
- Version/tag: `2.5.0`
- Commit: `838cddc01fdd67efd530f8bb67959ad2715f9b06`
- Local reuse mode: `dependency` (exact, conditioned on iOS and macOS)
- Product role: native TeX parsing and layout for code-aware inline and
  display math
- Package dependencies: none
- Engine license: MIT

iosMath and its eight bundled OpenType math fonts are covered in
`ThirdPartyNotices/MathRendering.md`, including the complete engine/OFL terms,
the shipped GUST notice, attributions, resource inventory, and distribution
approval.
The font resources are not part of Microsoft's source or license.
The derivative hosts accepted formulas as live TextKit 2
`MTMathUILabel` attachment views using intrinsic layout, semantic appearance,
Dynamic Type-aware configuration, and exact literal fallback. It does not
generate or retain formula raster previews.

### MIT License

Copyright (c) Microsoft Corporation.

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

## swift-markdown

- Upstream: <https://github.com/swiftlang/swift-markdown>
- Version/tag: `0.8.0`
- Commit: `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`
- Local reuse mode: `dependency` (exact constraint in the derivative)
- Product role: CommonMark/GFM Markdown parsing API
- License files reviewed: `LICENSE.txt` and `NOTICE.txt` at the pinned commit
- License: Apache License 2.0 with Swift Runtime Library Exception

The relevant upstream NOTICE attribution is:

> The Swift Markdown Project. Copyright (c) 2021 Apple Inc. and the Swift
> project authors.

Upstream `NOTICE.txt` also mentions Swift Argument Parser, but it is not in the
current Intatis `Package.resolved` graph and is not linked into the renderer
product. The cmark attribution from that NOTICE applies and is reproduced in
the swift-cmark section below.

### Apache License 2.0

Apache License
Version 2.0, January 2004
<https://www.apache.org/licenses/>

#### Terms and conditions for use, reproduction, and distribution

1. **Definitions.**

   "License" shall mean the terms and conditions for use, reproduction, and
   distribution as defined by Sections 1 through 9 of this document.

   "Licensor" shall mean the copyright owner or entity authorized by the
   copyright owner that is granting the License.

   "Legal Entity" shall mean the union of the acting entity and all other
   entities that control, are controlled by, or are under common control with
   that entity. For the purposes of this definition, "control" means (i) the
   power, direct or indirect, to cause the direction or management of such
   entity, whether by contract or otherwise, or (ii) ownership of fifty
   percent (50%) or more of the outstanding shares, or (iii) beneficial
   ownership of such entity.

   "You" (or "Your") shall mean an individual or Legal Entity exercising
   permissions granted by this License.

   "Source" form shall mean the preferred form for making modifications,
   including but not limited to software source code, documentation source,
   and configuration files.

   "Object" form shall mean any form resulting from mechanical transformation
   or translation of a Source form, including but not limited to compiled
   object code, generated documentation, and conversions to other media types.

   "Work" shall mean the work of authorship, whether in Source or Object form,
   made available under the License, as indicated by a copyright notice that
   is included in or attached to the work (an example is provided in the
   Appendix below).

   "Derivative Works" shall mean any work, whether in Source or Object form,
   that is based on (or derived from) the Work and for which the editorial
   revisions, annotations, elaborations, or other modifications represent, as
   a whole, an original work of authorship. For the purposes of this License,
   Derivative Works shall not include works that remain separable from, or
   merely link (or bind by name) to the interfaces of, the Work and Derivative
   Works thereof.

   "Contribution" shall mean any work of authorship, including the original
   version of the Work and any modifications or additions to that Work or
   Derivative Works thereof, that is intentionally submitted to Licensor for
   inclusion in the Work by the copyright owner or by an individual or Legal
   Entity authorized to submit on behalf of the copyright owner. For the
   purposes of this definition, "submitted" means any form of electronic,
   verbal, or written communication sent to the Licensor or its
   representatives, including but not limited to communication on electronic
   mailing lists, source code control systems, and issue tracking systems that
   are managed by, or on behalf of, the Licensor for the purpose of discussing
   and improving the Work, but excluding communication that is conspicuously
   marked or otherwise designated in writing by the copyright owner as "Not a
   Contribution."

   "Contributor" shall mean Licensor and any individual or Legal Entity on
   behalf of whom a Contribution has been received by Licensor and
   subsequently incorporated within the Work.

2. **Grant of Copyright License.** Subject to the terms and conditions of this
   License, each Contributor hereby grants to You a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable copyright license to
   reproduce, prepare Derivative Works of, publicly display, publicly perform,
   sublicense, and distribute the Work and such Derivative Works in Source or
   Object form.

3. **Grant of Patent License.** Subject to the terms and conditions of this
   License, each Contributor hereby grants to You a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable (except as stated in
   this section) patent license to make, have made, use, offer to sell, sell,
   import, and otherwise transfer the Work, where such license applies only to
   those patent claims licensable by such Contributor that are necessarily
   infringed by their Contribution(s) alone or by combination of their
   Contribution(s) with the Work to which such Contribution(s) was submitted.
   If You institute patent litigation against any entity (including a
   cross-claim or counterclaim in a lawsuit) alleging that the Work or a
   Contribution incorporated within the Work constitutes direct or
   contributory patent infringement, then any patent licenses granted to You
   under this License for that Work shall terminate as of the date such
   litigation is filed.

4. **Redistribution.** You may reproduce and distribute copies of the Work or
   Derivative Works thereof in any medium, with or without modifications, and
   in Source or Object form, provided that You meet the following conditions:

   a. You must give any other recipients of the Work or Derivative Works a copy
      of this License; and
   b. You must cause any modified files to carry prominent notices stating
      that You changed the files; and
   c. You must retain, in the Source form of any Derivative Works that You
      distribute, all copyright, patent, trademark, and attribution notices
      from the Source form of the Work, excluding those notices that do not
      pertain to any part of the Derivative Works; and
   d. If the Work includes a `NOTICE` text file as part of its distribution,
      then any Derivative Works that You distribute must include a readable
      copy of the attribution notices contained within such NOTICE file,
      excluding those notices that do not pertain to any part of the
      Derivative Works, in at least one of the following places: within a
      NOTICE text file distributed as part of the Derivative Works; within the
      Source form or documentation, if provided along with the Derivative
      Works; or, within a display generated by the Derivative Works, if and
      wherever such third-party notices normally appear. The contents of the
      NOTICE file are for informational purposes only and do not modify the
      License. You may add Your own attribution notices within Derivative Works
      that You distribute, alongside or as an addendum to the NOTICE text from
      the Work, provided that such additional attribution notices cannot be
      construed as modifying the License.

   You may add Your own copyright statement to Your modifications and may
   provide additional or different license terms and conditions for use,
   reproduction, or distribution of Your modifications, or for any such
   Derivative Works as a whole, provided Your use, reproduction, and
   distribution of the Work otherwise complies with the conditions stated in
   this License.

5. **Submission of Contributions.** Unless You explicitly state otherwise, any
   Contribution intentionally submitted for inclusion in the Work by You to
   the Licensor shall be under the terms and conditions of this License,
   without any additional terms or conditions. Notwithstanding the above,
   nothing herein shall supersede or modify the terms of any separate license
   agreement you may have executed with Licensor regarding such Contributions.

6. **Trademarks.** This License does not grant permission to use the trade
   names, trademarks, service marks, or product names of the Licensor, except
   as required for reasonable and customary use in describing the origin of
   the Work and reproducing the content of the NOTICE file.

7. **Disclaimer of Warranty.** Unless required by applicable law or agreed to
   in writing, Licensor provides the Work (and each Contributor provides its
   Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
   KIND, either express or implied, including, without limitation, any
   warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or
   FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for
   determining the appropriateness of using or redistributing the Work and
   assume any risks associated with Your exercise of permissions under this
   License.

8. **Limitation of Liability.** In no event and under no legal theory, whether
   in tort (including negligence), contract, or otherwise, unless required by
   applicable law (such as deliberate and grossly negligent acts) or agreed to
   in writing, shall any Contributor be liable to You for damages, including
   any direct, indirect, special, incidental, or consequential damages of any
   character arising as a result of this License or out of the use or
   inability to use the Work (including but not limited to damages for loss of
   goodwill, work stoppage, computer failure or malfunction, or any and all
   other commercial damages or losses), even if such Contributor has been
   advised of the possibility of such damages.

9. **Accepting Warranty or Additional Liability.** While redistributing the
   Work or Derivative Works thereof, You may choose to offer, and charge a fee
   for, acceptance of support, warranty, indemnity, or other liability
   obligations and/or rights consistent with this License. However, in
   accepting such obligations, You may act only on Your own behalf and on Your
   sole responsibility, not on behalf of any other Contributor, and only if
   You agree to indemnify, defend, and hold each Contributor harmless for any
   liability incurred by, or claims asserted against, such Contributor by
   reason of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

#### Appendix: How to apply the Apache License to your work

To apply the Apache License to your work, attach the following boilerplate
notice, with the fields enclosed by brackets `[]` replaced with your own
identifying information. (Don't include the brackets!) The text should be
enclosed in the appropriate comment syntax for the file format. We also
recommend that a file or class name and description of purpose be included on
the same "printed page" as the copyright notice for easier identification
within third-party archives.

```text
Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

### Swift Runtime Library Exception

As an exception, if you use this Software to compile your source code and
portions of this Software are embedded into the binary product as a result,
you may redistribute such product without providing attribution as would
otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.

## swift-cmark

- Upstream: <https://github.com/swiftlang/swift-cmark>
- Version/tag: `0.8.0`
- Commit: `924936d0427cb25a61169739a7660230bffa6ea6`
- Local reuse mode: `dependency` (transitive through swift-markdown, exact in
  the current root lock file)
- Product role: cmark-gfm and cmark-gfm-extensions C parser products linked
  through swift-markdown
- License file reviewed: `COPYING` at the pinned commit
- Runtime-source licenses: BSD-2-Clause and MIT-derived portions

The upstream repository also licenses its CommonMark specification test data
under CC BY-SA 4.0. Those test/specification assets are not SwiftPM resources
of the Intatis application products and are not copied into Intatis. The
runtime-source notices that apply to the linked parser follow.

### Core cmark code — BSD 2-Clause License

Copyright (c) 2014, John MacFarlane

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

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

### MIT-derived runtime portions

The upstream `COPYING` file identifies these derived portions:

- `houdini.h`, `houdini_href_e.c`, `houdini_html_e.c`, and `houdini_html_u.c`,
  derived from `vmg/houdini`, copyright (c) 2012 Vicent Marti.
- `buffer.h`, `buffer.c`, and `chunk.h`, derived from code copyright (c) 2012
  GitHub, Inc.
- UTF-8 implementation files derived from utf8proc, copyright (c) 2009 Public
  Software Group e. V., Berlin, Germany.

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
