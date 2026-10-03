# Third-party notices — Web Renderer Parity Lab

Scope: `Experiments/WebRendererParity` only.

These npm dependencies are used as exact, package-manager-resolved
`dependency` reuse. Nothing in this file declares them to be part of the
Intatis macOS app, iOS app, CLI, SwiftPM graph, or product distribution. The
complete transitive package graph and integrity hashes are recorded in
`package-lock.json`; `npm run licenses` inventories the installed graph and
fails on licenses outside the experiment allowlist.

## Runtime dependencies

| Package | Version | License | Upstream |
|---|---:|---|---|
| React | 19.2.8 | MIT | https://github.com/facebook/react |
| React DOM | 19.2.8 | MIT | https://github.com/facebook/react |
| react-markdown | 10.1.0 | MIT | https://github.com/remarkjs/react-markdown |
| remark-gfm | 4.0.1 | MIT | https://github.com/remarkjs/remark-gfm |
| remark-breaks | 4.0.0 | MIT | https://github.com/remarkjs/remark-breaks |
| mdast-util-math | 3.0.0 | MIT | https://github.com/syntax-tree/mdast-util-math |
| micromark-extension-llm-math | 3.1.1-20250610 | MIT | https://github.com/ofk/micromark-extension-llm-math |
| KaTeX | 0.16.21 | MIT | https://github.com/KaTeX/KaTeX |
| @codemirror/state | 6.7.1 | MIT | https://github.com/codemirror/state |
| @codemirror/view | 6.43.6 | MIT | https://github.com/codemirror/view |
| @codemirror/language | 6.12.4 | MIT | https://github.com/codemirror/language |
| @codemirror/language-data | 6.5.2 | MIT | https://github.com/codemirror/language-data |

KaTeX CSS and the font files referenced by that CSS are bundled by Vite from
the installed KaTeX package and remain covered by the KaTeX distribution
license. CodeMirror language grammars are loaded from the exact transitive
packages pinned by `package-lock.json`; they are not copied into this
repository as source files.

## Development dependencies

| Package | Version | License | Upstream |
|---|---:|---|---|
| Vite | 7.2.4 | MIT | https://github.com/vitejs/vite |
| TypeScript | 7.0.2 | Apache-2.0 | https://github.com/microsoft/TypeScript |
| Vitest | 4.1.10 | MIT | https://github.com/vitest-dev/vitest |
| jsdom | 29.1.1 | MIT | https://github.com/jsdom/jsdom |
| Testing Library React | 16.3.2 | MIT | https://github.com/testing-library/react-testing-library |
| Testing Library jest-dom | 7.0.0 | MIT | https://github.com/testing-library/jest-dom |
| React type declarations | 19.2.17 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |
| React DOM type declarations | 19.2.3 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |
| Node.js type declarations | 26.1.1 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |
| KaTeX type declarations | 0.16.8 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |

## Behavior reference

The implementation is independent code written against public package APIs and
observed output behavior. It does not copy, translate, vendor, link, or
redistribute ChatGPT production JavaScript chunks, CSS, prompts, private
source, logos, icons, screenshots, conversations, or other product assets.
No affiliation or product compatibility guarantee is implied.
