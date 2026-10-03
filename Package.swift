// swift-tools-version:5.9
import PackageDescription

// Translatis root SwiftPM manifest. Product versioning is owned by project.yml;
// package comments below that mention early v0.x milestones describe when a
// subsystem was introduced, not the current product version. See
// docs/VERSIONING.md.

let package = Package(
    name: "Intatis",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "IntatisCore", targets: ["IntatisCore"]),
        .library(name: "IntatisProtocol", targets: ["IntatisProtocol"]),
        .library(name: "IntatisProviders", targets: ["IntatisProviders"]),
        .library(name: "IntatisArtifacts", targets: ["IntatisArtifacts"]),
        .library(name: "IntatisConversation", targets: ["IntatisConversation"]),
        .library(name: "IntatisTools", targets: ["IntatisTools"]),
        .library(name: "IntatisKnowledge", targets: ["IntatisKnowledge"]),
        .library(name: "IntatisSkills", targets: ["IntatisSkills"]),
        .library(name: "IntatisPermission", targets: ["IntatisPermission"]),
        .library(name: "IntatisMCP", targets: ["IntatisMCP"]),
        .library(name: "IntatisMCPStdio", targets: ["IntatisMCPStdio"]),
        // Stable cross-project host product. Downstream Vitemis projects use
        // the v1 source contract in docs/CODEX_RUNTIME_INTEGRATION.md rather
        // than copying this target's source tree.
        .library(name: "IntatisCodexRuntime", targets: ["IntatisCodexRuntime"]),
        .library(name: "IntatisAgentKernel", targets: ["IntatisAgentKernel"]),
        .library(name: "IntatisCowork", targets: ["IntatisCowork"]),
        .library(name: "IntatisMultimodal", targets: ["IntatisMultimodal"]),
        .library(name: "IntatisSharedUI", targets: ["IntatisSharedUI"]),
        // Presentation-only Cowork right-hand content. Embedding hosts retain
        // their own session, runtime, provider, workspace, and dynamic tools.
        .library(name: "IntatisCoworkUI", targets: ["IntatisCoworkUI"]),
        // The CLI IS a SwiftPM executable (no Xcode needed): `swift run translatis chat`.
        .executable(name: "translatis", targets: ["TranslatisCLI"]),
        // The GUI apps (TranslatisMac, TranslatisiOS) are Xcode App targets, not SPM
        // products — SwiftPM cannot build a .app bundle, and iOS apps cannot be
        // built from SPM at all. See project.yml (XcodeGen) + README.
    ],
    dependencies: [
        // Audited in-tree thin derivative of Microsoft SwiftStreamingMarkdown
        // v0.6.0. Provenance and local patches live beside the vendored source.
        .package(path: "Vendor/SwiftStreamingMarkdown"),
        // Audited client-only derivative of the official Model Context
        // Protocol Swift SDK 0.12.1 at a0ae212e. Its upstream identity,
        // exclusions, licenses, and patch ledger live beside the source.
        .package(path: "Vendor/MCPClientSDK"),
        // Official portable CryptoKit-compatible backend for Linux CLI builds.
        // Exact release provenance and license inventory are recorded in
        // ThirdPartyNotices/SwiftCrypto.md.
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.1"
        ),
        // Safe YAML parser for bounded OKF frontmatter in the non-iOS
        // knowledge target. Exact commit/license provenance is recorded in
        // ThirdPartyNotices/KnowledgeRetrieval.md.
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        ),
    ],
    targets: [
        // MARK: Library targets (module == target)
        .target(
            name: "IntatisCore",
            path: "Packages/IntatisCore/Sources"
        ),
        .target(
            name: "IntatisProtocol",
            dependencies: ["IntatisCore"],
            path: "Packages/IntatisProtocol/Sources"
        ),
        .target(
            name: "IntatisProviders",
            dependencies: [
                "IntatisCore", "IntatisProtocol",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisProviders/Sources"
        ),
        .target(
            name: "IntatisArtifacts",
            dependencies: ["IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisArtifacts/Sources"
        ),
        .target(
            name: "IntatisConversation",
            // ChatLoop drives a ChatProvider, so Conversation depends on Providers
            // (still tool-free — see ARCHITECTURE.md §3.4 / §4: iOS links this, not the kernel).
            dependencies: ["IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisArtifacts"],
            path: "Packages/IntatisConversation/Sources"
        ),
        // v0.2 — Code: tools, deterministic permission gate, single-agent kernel.
        .target(
            name: "IntatisPTYLauncher",
            path: "Packages/IntatisPTYLauncher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "IntatisTools",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisPTYLauncher",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisTools/Sources"
        ),
        // OKF/Profile snapshots, deterministic validation, local embedding,
        // derived indexes, and the snapshot-bound search_knowledge tool.
        // No iOS app target links this product.
        .target(
            name: "IntatisKnowledge",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisTools",
                "IntatisProviders", "IntatisPermission",
                .product(name: "Yams", package: "Yams"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisKnowledge",
            exclude: ["Tests"],
            sources: ["Sources"],
            resources: [
                .copy("Resources/Schemas"),
            ]
        ),
        .target(
            name: "IntatisSkills",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisTools",
                "IntatisPermission",
            ],
            path: "Packages/IntatisSkills",
            exclude: ["Tests"],
            sources: ["Sources"],
            resources: [
                .copy("Resources/BundledSkills"),
            ]
        ),
        .target(
            name: "IntatisPermission",
            // Providers added in v0.3 for the model-backed reviewer (layer B).
            dependencies: ["IntatisCore", "IntatisProtocol", "IntatisProviders"],
            path: "Packages/IntatisPermission/Sources"
        ),
        // Production remote MCP HTTP/OAuth requests use libcurl's
        // CURLOPT_RESOLVE socket binding on macOS and Linux. The iOS product
        // does not link IntatisMCP.
        .target(
            name: "IntatisCurlTransport",
            path: "Packages/IntatisCurlTransport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("curl"),
            ]
        ),
        // External MCP Server client core, including the client-side handlers
        // for callbacks initiated by a connected server. This target contains
        // no MCP Server implementation or server-facing product seam. It has
        // no dependency on Conversation, Providers, AgentKernel, Cowork, or an
        // app target; those layers inject event/artifact/inference services
        // through narrow interfaces.
        .target(
            name: "IntatisMCP",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisTools",
                .target(
                    name: "IntatisCurlTransport",
                    condition: .when(platforms: [.macOS, .linux])
                ),
                .product(name: "MCP", package: "MCPClientSDK"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisMCP/Sources"
        ),
        // Linux-only kernel execution guard support for local MCP stdio.
        // The C shim is inert on Apple platforms; keeping it separate avoids
        // placing fork/ptrace/seccomp code in the portable client core.
        .target(
            name: "IntatisMCPStdioGuard",
            path: "Packages/IntatisMCPStdio/ExecutionGuard",
            publicHeadersPath: "include"
        ),
        // Local stdio process ownership is a separate linkage boundary so the
        // portable MCP client core and iOS subset never acquire process launch.
        .target(
            name: "IntatisMCPStdio",
            dependencies: [
                "IntatisMCP", "IntatisMCPStdioGuard",
                "IntatisCore", "IntatisProtocol", "IntatisTools",
                .product(name: "MCP", package: "MCPClientSDK"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisMCPStdio/Sources"
        ),
        // OpenAI Codex App Server host. This target owns process lifecycle,
        // official JSON-RPC transport, route/session projection, and the thin
        // client executor required by App Server `dynamicTools`. Codex still
        // owns the agent loop, tool scheduling, context, and multi-agent core;
        // first-party business tools reuse their existing Intatis registry,
        // permission, workspace-lease, and durable-execution boundaries.
        .target(
            name: "IntatisCodexRuntime",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation",
                "IntatisSkills", "IntatisMCP",
            ],
            path: "Packages/IntatisCodexRuntime/Sources"
        ),
        .target(
            name: "IntatisAgentKernel",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation",
                "IntatisArtifacts", "IntatisMCP", "IntatisSkills",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisAgentKernel/Sources"
        ),
        // v0.3 — Cowork: multi-agent orchestration over a mediated message bus.
        .target(
            name: "IntatisCowork",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisTools",
                "IntatisPermission", "IntatisConversation", "IntatisAgentKernel",
                "IntatisSkills",
            ],
            path: "Packages/IntatisCowork/Sources"
        ),
        // v0.4 — Multimodal: image/video generation + transcription → artifacts.
        .target(
            name: "IntatisMultimodal",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisArtifacts", "IntatisConversation",
            ],
            path: "Packages/IntatisMultimodal/Sources"
        ),
        .target(
            name: "IntatisSharedUI",
            // Providers is needed because ChatViewModel drives ProviderRegistry.
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisConversation", "IntatisArtifacts",
                .product(
                    name: "SwiftStreamingMarkdown",
                    package: "SwiftStreamingMarkdown",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
            ],
            path: "Packages/IntatisSharedUI/Sources",
            resources: [
                .copy("Resources/JetBrainsMono[wght].ttf"),
                .copy("Resources/JetBrainsMono-Italic[wght].ttf"),
            ]
        ),
        .target(
            name: "IntatisCoworkUI",
            dependencies: [
                "IntatisCore", "IntatisProtocol",
                "IntatisConversation", "IntatisSharedUI",
            ],
            path: "Packages/IntatisCoworkUI/Sources"
        ),
        // v0.6 — CLI: Swift-native `translatis` command (chat + code agent), talks to
        // any OpenAI-compatible endpoint via env vars.
        .executableTarget(
            name: "TranslatisCLI",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders", "IntatisConversation",
                "IntatisArtifacts", "IntatisTools", "IntatisPermission", "IntatisAgentKernel", "IntatisCowork",
                "IntatisMCP", "IntatisMCPStdio", "IntatisSkills", "IntatisKnowledge",
                "IntatisCodexRuntime",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Apps/translatis-cli/Sources"
        ),
        // Development-only executable exercised by the pinned official MCP
        // client conformance runner. It is not a shipped product and contains
        // no MCP server implementation or server-facing API.
        .executableTarget(
            name: "IntatisMCPConformanceClient",
            dependencies: [
                "IntatisMCP", "IntatisCore", "IntatisProtocol",
                .product(name: "MCP", package: "MCPClientSDK"),
            ],
            path: "Packages/IntatisMCPConformanceClient/Sources"
        ),
        // GUI app targets (TranslatisMac macOS app, TranslatisiOS iOS app) are defined in
        // the Xcode project generated from project.yml — they link these library
        // products. The iOS app intentionally links only the subset.

        // MARK: Test targets (none depend on app targets; SharedUI tests run headlessly on macOS)
        .testTarget(
            name: "IntatisCoreTests",
            dependencies: ["IntatisCore"],
            path: "Packages/IntatisCore/Tests"
        ),
        .testTarget(
            name: "IntatisProtocolTests",
            dependencies: ["IntatisProtocol", "IntatisCore"],
            path: "Packages/IntatisProtocol/Tests"
        ),
        .testTarget(
            name: "IntatisProvidersTests",
            dependencies: ["IntatisProviders", "IntatisCore", "IntatisProtocol"],
            path: "Packages/IntatisProviders/Tests"
        ),
        .testTarget(
            name: "IntatisArtifactsTests",
            dependencies: ["IntatisArtifacts", "IntatisCore"],
            path: "Packages/IntatisArtifacts/Tests"
        ),
        .testTarget(
            name: "IntatisConversationTests",
            dependencies: ["IntatisConversation", "IntatisCore", "IntatisProtocol", "IntatisProviders"],
            path: "Packages/IntatisConversation/Tests"
        ),
        .testTarget(
            name: "IntatisToolsTests",
            dependencies: ["IntatisTools", "IntatisCore"],
            path: "Packages/IntatisTools/Tests"
        ),
        .testTarget(
            name: "IntatisKnowledgeTests",
            dependencies: [
                "IntatisKnowledge", "IntatisCore", "IntatisProtocol",
                "IntatisTools",
            ],
            path: "Packages/IntatisKnowledge/Tests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "IntatisSkillsTests",
            dependencies: [
                "IntatisSkills", "IntatisCore", "IntatisProtocol", "IntatisTools",
            ],
            path: "Packages/IntatisSkills/Tests"
        ),
        .testTarget(
            name: "IntatisPermissionTests",
            dependencies: ["IntatisPermission", "IntatisCore", "IntatisProtocol", "IntatisProviders"],
            path: "Packages/IntatisPermission/Tests"
        ),
        .testTarget(
            name: "IntatisMCPTests",
            dependencies: [
                "IntatisMCP", "IntatisMCPStdio", "IntatisCore",
                "IntatisProtocol", "IntatisTools",
                .product(name: "MCP", package: "MCPClientSDK"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisMCP/Tests"
        ),
        .testTarget(
            name: "IntatisCodexRuntimeTests",
            dependencies: [
                "IntatisCodexRuntime", "IntatisCore", "IntatisProtocol",
                "IntatisProviders", "IntatisTools", "IntatisPermission",
                "IntatisConversation", "IntatisCowork", "IntatisMCP",
            ],
            path: "Packages/IntatisCodexRuntime/Tests"
        ),
        .testTarget(
            name: "TranslatisCLITests",
            dependencies: [
                "TranslatisCLI", "IntatisAgentKernel",
                "IntatisConversation", "IntatisCore",
                "IntatisMCP", "IntatisProtocol",
            ],
            path: "Apps/translatis-cli/Tests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "TranslatisRuntimeIntegrationTests",
            dependencies: [
                "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisCodexRuntime",
            ],
            path: "Tests/TranslatisRuntimeIntegrationTests"
        ),
        .testTarget(
            name: "IntatisAgentKernelTests",
            dependencies: [
                "IntatisAgentKernel", "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation",
                "IntatisArtifacts", "IntatisMCP", "IntatisSkills", "IntatisKnowledge",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Packages/IntatisAgentKernel/Tests"
        ),
        .testTarget(
            name: "IntatisCoworkTests",
            dependencies: [
                "IntatisCowork", "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisTools", "IntatisPermission", "IntatisConversation", "IntatisAgentKernel",
                "IntatisSkills",
            ],
            path: "Packages/IntatisCowork/Tests"
        ),
        .testTarget(
            name: "IntatisMultimodalTests",
            dependencies: [
                "IntatisMultimodal", "IntatisCore", "IntatisProtocol", "IntatisProviders",
                "IntatisArtifacts", "IntatisConversation",
            ],
            path: "Packages/IntatisMultimodal/Tests"
        ),
        .testTarget(
            name: "IntatisSharedUITests",
            dependencies: ["IntatisSharedUI"],
            path: "Packages/IntatisSharedUI/Tests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "IntatisCoworkUITests",
            dependencies: ["IntatisCoworkUI"],
            path: "Packages/IntatisCoworkUI/Tests"
        ),
    ]
)
