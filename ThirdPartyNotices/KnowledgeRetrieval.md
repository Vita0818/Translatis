# Yams 6.2.2 and bundled libYAML

Intatis uses Yams only inside the non-iOS `IntatisKnowledge` target to parse
bounded OKF YAML frontmatter. The dependency is resolved exactly at release
6.2.2.

- Repository: https://github.com/jpsim/Yams.git
- Version: 6.2.2
- Commit: a27b21e0c81c5bf42049b897a62aaf387e80f279
- License: MIT
- SwiftPM product: `Yams`
- Runtime closure: `Yams` plus its in-package `CYaml` target
- External SwiftPM dependencies: none

The upstream README states that both Yams and the bundled libYAML sources are
MIT licensed. Intatis does not copy Yams source into this repository; SwiftPM
resolves the exact release. The complete upstream MIT license is preserved at
`ThirdPartyNotices/Licenses/Yams-6.2.2-MIT.txt`.

Intatis applies its own pre-parse byte limits, rejects aliases and custom tags,
walks the parsed node tree with depth/node/scalar bounds, and never uses YAML
input to select or execute a type, command, Skill, URL, or runtime.
