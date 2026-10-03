# Syntax highlighting distribution status

## Current status: not distributed

Syntax highlighting is disabled in the current SwiftStreamingMarkdown
derivative used by Intatis. Code blocks are rendered as plain text with native
SwiftUI/AppKit/UIKit presentation and a native copy button.

The current root `Package.swift`, `Package.resolved`, and derivative manifest
contain no HighlightSwift or highlight.js dependency. The former Intatis
vendored resources are removed from the current working tree and from the
`IntatisSharedUI` resource list:

- `highlight.min.js`
- `a11y-light.css`
- `a11y-dark.css`

No highlight.js engine, language grammar, CSS theme, HighlighterSwift wrapper,
HighlighterSwift resource bundle, or related CC BY-SA theme is intended to be
present in a current macOS or iOS product artifact.

## Historical provenance

Intatis previously shipped a selectively vendored highlight.js 11.11.1 engine
and two HighlighterSwift-derived a11y styles. That provenance remains available
in Git history, but those files and their runtime are not part of the current
renderer or distribution notice set. Reintroducing syntax highlighting requires
a new exact-version dependency and asset audit, restored license texts and
copyright notices, artifact inventory, security review, and an update to
`NOTICE.md` before release.
