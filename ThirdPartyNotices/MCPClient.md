# External MCP client third-party notices

This notice covers the external MCP Server client source derivative and the
three upstream packages in the vendored SDK's final SwiftPM dependency graph.
The Linux portable-crypto closure and the native libcurl transport closure
have their own notices at `ThirdPartyNotices/SwiftCrypto.md` and
`ThirdPartyNotices/MCPHTTPTransport.md`. None of these notices covers or
authorizes an MCP server product: Intatis excludes every upstream server
runtime, server transport, server/conformance executable, and hosting API.

## Official Model Context Protocol Swift SDK

- Upstream: `modelcontextprotocol/swift-sdk`
- Version: `0.12.1`
- Commit: `a0ae212ebf6eab5f754c3129608bc5557637e605`
- Reuse: `vendored` and `derived`
- Local package: `Vendor/MCPClientSDK`
- Upstream license: a transition covering Apache License 2.0 contributions,
  legacy MIT contributions, and CC-BY-4.0 documentation as stated in the
  upstream combined license
- Copyright in the MIT portion:
  `2024-2025 Model Context Protocol a Series of LF Projects, LLC.`
- Complete combined license:
  `ThirdPartyNotices/Licenses/MCP-Swift-SDK-0.12.1.txt`

The copied client source consists of the upstream Base, Client, and Extensions
closure plus the client-consumed Completion, Logging, Prompts, Resources, and
Tools wire schemas. Intatis moved those five wire-schema files out of the
upstream `Server` directory because they define data and JSON-RPC methods used
by the client and do not host requests.

Intatis modifications:

- replaces the nested upstream `Server.Info` and `Server.Capabilities` wire
  values with client-only `RemoteServerInfo` and
  `RemoteServerCapabilities`;
- adds exact per-server requested/allowed protocol negotiation;
- omits the protocol-version HTTP header until initialization succeeds;
- isolates the HTTP client header/content-type constants from an upstream
  server-transport source file;
- omits server-side OAuth token-validation and protected-resource publishing
  types; and
- publishes no server actor, server transport, conformance executable,
  in-memory paired transport, custom raw-network transport, SwiftNIO
  dependency, or documentation plugin.

The fixed source inventory, exclusions, and persistent patch ledger are in
`Vendor/MCPClientSDK/UPSTREAM.md` and
`Vendor/MCPClientSDK/PATCHES.md`. Modified upstream files carry a local
modification notice.

## Swift System

- Upstream: `apple/swift-system`
- Version: `1.4.0`
- Commit: `c8a44d836fe7913603e246acab7c528c2e780168`
- Reuse: exact SwiftPM dependency
- License: Apache License 2.0 with the Swift Runtime Library Exception
- Complete terms:
  `ThirdPartyNotices/Licenses/SwiftSystem-1.4.0.txt`

## SwiftLog

- Upstream: `apple/swift-log`
- Version: `1.6.2`
- Commit: `96a2f8a0fa41e9e09af4585e2724c4e825410b91`
- Reuse: exact SwiftPM dependency
- License: Apache License 2.0
- Complete terms:
  `ThirdPartyNotices/Licenses/SwiftLog-1.6.2.txt`
- Upstream attribution notice:
  `ThirdPartyNotices/Licenses/SwiftLog-NOTICE-1.6.2.txt`

The SwiftLog notice identifies derivations from Tony Stone's
`process_test_files.rb` and from SwiftNIO scripts/locking code. SwiftNIO is not
an Intatis MCP client package dependency.

## EventSource

- Upstream: `mattt/EventSource`
- Version: `1.1.0`
- Commit: `e83f076811f32757305b8bf69ac92d05626ffdd7`
- Reuse: exact, Apple-platform-only SwiftPM dependency
- License: Apache License 2.0
- Copyright: `2025 Loopwork Limited`
- Complete terms:
  `ThirdPartyNotices/Licenses/EventSource-1.1.0.txt`

EventSource has no package dependency. In the final client graph, SwiftNIO,
swift-docc-plugin, swift-atomics, and swift-collections are absent.

## Native production HTTP transport

Production MCP HTTP/OAuth I/O uses the Intatis-owned
`IntatisCurlTransport` boundary, not the SDK HTTP transport. macOS links the
Apple system libcurl; the fully static Linux CLI incorporates libcurl,
BoringSSL `libssl`/`libcrypto`, and zlib from the pinned official Swift Static
Linux SDK. Exact artifact/SBOM/archive hashes, the Swift build recipe and
byte-matched source pins (including BoringSSL
`817ab07ebb53da35afea409ab9328f578492832d`), the
artifact/source-attestation boundary, platform distribution boundaries,
complete license texts, and release obligations are in
`ThirdPartyNotices/MCPHTTPTransport.md`.
