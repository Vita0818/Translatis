import Foundation
import IntatisProtocol
import MCP

/// Audited upstream identity for the only MCP SDK linked by Intatis.
///
/// The semantic tag is recorded for humans and release provenance; the package
/// manifest pins the immutable commit so a moved tag cannot change a build.
public enum OfficialMCPSDKPin {
    public static let repository =
        "https://github.com/modelcontextprotocol/swift-sdk.git"
    public static let version = "0.12.1"
    public static let revision =
        "a0ae212ebf6eab5f754c3129608bc5557637e605"
    public static let upstreamProduct = "MCP"
    public static let localPackage = "MCPClientSDK"
    public static let localProduct = "MCP"
}

/// A feature whose SDK surface must be verified independently from Intatis's
/// host behavior. `requiresAdapter` means the SDK primitive is usable only
/// behind a reviewed Intatis lifecycle/policy adapter; `requiresPatch` means
/// the pinned SDK cannot directly express the complete client contract.
public enum MCPSDKCompatibilityDisposition: String, Codable, Sendable {
    case available
    case requiresAdapter = "requires_adapter"
    case requiresPatch = "requires_patch"
}

public struct MCPSDKCompatibilityEntry: Codable, Equatable, Sendable {
    public let patchID: String
    public let feature: String
    public let disposition: MCPSDKCompatibilityDisposition
    public let upstreamFiles: [String]
    public let upstreamBlobIDs: [String: String]
    public let upstreamEvidence: String
    public let intatisContract: String
    public let conformanceTests: [String]
    public let upgradeReplay: [String]

    public init(
        patchID: String,
        feature: String,
        disposition: MCPSDKCompatibilityDisposition,
        upstreamFiles: [String],
        upstreamBlobIDs: [String: String],
        upstreamEvidence: String,
        intatisContract: String,
        conformanceTests: [String],
        upgradeReplay: [String]
    ) {
        self.patchID = patchID
        self.feature = feature
        self.disposition = disposition
        self.upstreamFiles = upstreamFiles
        self.upstreamBlobIDs = upstreamBlobIDs
        self.upstreamEvidence = upstreamEvidence
        self.intatisContract = intatisContract
        self.conformanceTests = conformanceTests
        self.upgradeReplay = upgradeReplay
    }
}

/// W0 compatibility ledger for the pinned SDK.
///
/// This is deliberately executable source rather than a prose-only claim:
/// tests freeze the upstream protocol surface and every known patch boundary.
/// Runtime adapters must not advertise a feature until its later conformance
/// gate passes.
public enum SDKPatchCompatibility {
    public static let codexCompatibilityMaximumVersion =
        MCPProtocolProfile.codexCompat.defaultMaximumVersion.rawValue
    public static let standardExtendedMaximumVersion =
        MCPProtocolProfile.standardExtended.defaultMaximumVersion.rawValue

    public static var sdkSupportedProtocolVersions: Set<String> {
        Version.supported
    }

    public static var sdkLatestProtocolVersion: String {
        Version.latest
    }

    public static let entries: [MCPSDKCompatibilityEntry] = [
        MCPSDKCompatibilityEntry(
            patchID: "P001",
            feature: "client_only_source_derivative",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Package.swift",
                "Sources/MCP/Server/Server.swift",
                "Sources/MCP/Base/Transports/HTTPServer/**",
                "Sources/MCP/Base/Authorization/OAuthModels.swift",
            ],
            upstreamBlobIDs: [
                "Package.swift": "273715abe61180310dd181de71afe526d85d9f6b",
                "Sources/MCP/Server/Server.swift":
                    "060b51f8eb437b3a936d94bce00f01a4f17810c5",
                "Sources/MCP/Base/Authorization/OAuthModels.swift":
                    "28043b9f82a8799893372f1cf48d61e5b0808e4d",
            ],
            upstreamEvidence:
                "The upstream MCP product compiles client, Server actor, HTTP Server transports, and server-side OAuth APIs together.",
            intatisContract:
                "The vendored derivative exposes one client library and no MCP server target, actor, transport, binary, handler, namespace, or hosting seam.",
            conformanceTests: [
                "SDKClientOnlySurfaceTests",
                "MCPPlatformLinkageTests",
            ],
            upgradeReplay: [
                "Recompute the exact client source closure.",
                "Deny-list server symbols/products and inspect the resolved graph for SwiftNIO.",
                "Build the client target on every supported host.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P002",
            feature: "per_server_initialize_version",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Sources/MCP/Base/Versioning.swift",
                "Sources/MCP/Base/Lifecycle.swift",
                "Sources/MCP/Client/Client.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Base/Versioning.swift":
                    "0bed5c49e691979778d245fd784cadd33ac8154f",
                "Sources/MCP/Base/Lifecycle.swift":
                    "08ea967c2e50483f35398d916db244d2e78402f9",
                "Sources/MCP/Client/Client.swift":
                    "3eea124045b4f436d02bf75cbef5c89c811da420",
            ],
            upstreamEvidence:
                "Client.connect/_initialize sends Version.latest in swift-sdk 0.12.1",
            intatisContract:
                "Each immutable server revision selects a requested/max version; an invalid negotiated version is rejected before initialized/catalog publication.",
            conformanceTests: [
                "MCPVersionNegotiationTests",
                "MCPCodexCompatibilityConformanceTests",
                "MCPStandardExtendedConformanceTests",
            ],
            upgradeReplay: [
                "Diff lifecycle/version code against the pinned blobs.",
                "Run both profiles plus out-of-range initialize fixtures.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P003",
            feature: "experimental_tasks_2025_11_25",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Sources/MCP/Client/Client.swift",
                "Sources/MCP/Client/Sampling.swift",
                "Sources/MCP/Client/Elicitation.swift",
                "Sources/MCP/Server/Server.swift",
                "Sources/MCP/Server/Tools.swift",
                "Sources/MCP/Server/Resources.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Client/Client.swift":
                    "3eea124045b4f436d02bf75cbef5c89c811da420",
                "Sources/MCP/Server/Server.swift":
                    "060b51f8eb437b3a936d94bce00f01a4f17810c5",
                "Sources/MCP/Server/Tools.swift":
                    "478ba60192b66921462773bd21dcc60baffd020d",
                "Sources/MCP/Server/Resources.swift":
                    "fb512a032e9ffddbdd36da7e23cf212e5886fa02",
            ],
            upstreamEvidence:
                "The pinned source contains no tasks/get, tasks/result, tasks/list, tasks/cancel, notifications/tasks/status, task metadata, or tasks capability.",
            intatisContract:
                "Intatis supplies the exact task wire surface, including discriminated CallTool/CreateSamplingMessage/CreateElicitation result unions whose task branch is the exact CreateTaskResult shape; separate remote-server and client-hosted state machines are advertised only for standard-extended after conformance.",
            conformanceTests: [
                "MCPTaskWireTests",
                "MCPTaskWireTests.testTaskAugmentedMethodResultsUseExactCreateTaskShape",
                "MCPRemoteTaskStateMachineTests",
                "MCPClientTaskStateMachineTests",
            ],
            upgradeReplay: [
                "Search the new SDK for every 2025-11-25 tasks method and capability.",
                "Reconcile upstream wire types without weakening Intatis durable state machines.",
                "Run task timeout/cancel/resume/generation fixtures.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P004",
            feature: "request_ownership_and_cancellation",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Sources/MCP/Client/Client.swift",
                "Sources/MCP/Base/Utilities/RequestContext.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Client/Client.swift":
                    "3eea124045b4f436d02bf75cbef5c89c811da420",
                "Sources/MCP/Base/Utilities/RequestContext.swift":
                    "8caf1c4d1dafc97ee860285ba7fe09df05093a43",
            ],
            upstreamEvidence:
                "Caller cancellation does not fully own pending registration and ordinary versus task-augmented cancellation differs.",
            intatisContract:
                "Every request has generation-owned registration, timeout, consumer cancellation, exactly one terminal, and method-appropriate notifications/cancelled or tasks/cancel behavior.",
            conformanceTests: [
                "MCPRequestOwnershipTests",
                "MCPCancellationConformanceTests",
            ],
            upgradeReplay: [
                "Re-run cancel-before-register, response/cancel, disconnect/cancel, and late-response races.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P005",
            feature: "managed_stdio_process",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Sources/MCP/Base/Transports/StdioTransport.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Base/Transports/StdioTransport.swift":
                    "45522fac20da1064f3ab2e3381ae7b280fd46d5d",
            ],
            upstreamEvidence:
                "StdioTransport accepts existing file descriptors, buffers an unbounded partial line, does not own/await its read task, and drops partial EOF frames.",
            intatisContract:
                "Intatis owns executable identity, sandbox, environment, process group, bounded framing, stderr diagnostics, cancellation, and TERM/KILL drain.",
            conformanceTests: [
                "MCPManagedStdioTests",
                "MCPStdioHostileFixtureTests",
            ],
            upgradeReplay: [
                "Re-run oversized frame, partial EOF, descriptor close, cancellation, and orphan-process fixtures.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P006",
            feature: "streamable_http",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Sources/MCP/Base/Transports/HTTPClientTransport.swift",
                "Sources/MCP/Base/Transports/HTTPServer/HTTPServerTypes.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Base/Transports/HTTPClientTransport.swift":
                    "060cd1336cd07323dcaab26dc81f726ee37e2d03",
                "Sources/MCP/Base/Transports/HTTPServer/HTTPServerTypes.swift":
                    "bd56191c4b7f2b5873ac4d0a7e9172a66b282b70",
            ],
            upstreamEvidence:
                "HTTPClientTransport provides partial JSON/SSE/session primitives but lacks complete Linux SSE, DELETE, per-stream resume/dedup, hard caps, strict redirect/cookie/proxy policy, and owned drain.",
            intatisContract:
                "Intatis owns POST/GET/SSE/202/resume/session/404/DELETE, exact origin/trust/proxy/egress, body/frame caps, generation fencing, cancellation, and no replay of side-effecting requests.",
            conformanceTests: [
                "MCPStreamableHTTPTests",
                "MCPStreamableHTTPTests.testPOSTSSEDisconnectResumesByGETWithoutReplayingPOST",
                "MCPStreamableHTTPTests.testSession404RetiresGenerationWithoutToolReplay",
                "MCPStreamableHTTPTests.testNetworkFailureAfterToolDispatchIsUncertainAndNotRetried",
                "MCPStreamableHTTPTests.testAuthorizationChallengeNeverReplaysDispatchedToolCall",
                "MCPStreamableHTTPTests.testDNSRebindingFenceRejectsAddressChange",
            ],
            upgradeReplay: [
                "Re-run Apple/Linux transport matrix and all generation/replay/redirect/body-cap fixtures.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P007",
            feature: "oauth",
            disposition: .requiresPatch,
            upstreamFiles: [
                "Sources/MCP/Base/Authorization/OAuthModels.swift",
                "Sources/MCP/Base/Authorization/OAuthAuthorizer.swift",
                "Sources/MCP/Base/Authorization/TokenStorage.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Base/Authorization/OAuthModels.swift":
                    "28043b9f82a8799893372f1cf48d61e5b0808e4d",
                "Sources/MCP/Base/Authorization/OAuthAuthorizer.swift":
                    "b2e5be3bc02ce5940be6c142eff663c713ee8f6c",
                "Sources/MCP/Base/Authorization/TokenStorage.swift":
                    "07a5e3c945ed0f2ea3c577cf2e8d10209b11bd9e",
            ],
            upstreamEvidence:
                "OAuth 2.1, PKCE, discovery, and refresh primitives exist, but storage cannot fail, DCR credentials are memory-only, refresh may drop the old refresh token, and challenge handling can replay the original request.",
            intatisContract:
                "Intatis owns canonical resource/audience, scope step-up, callback generation, account/authority isolation, durable secret storage, DNS/origin policy, and explicit non-replaying challenge recovery.",
            conformanceTests: [
                "MCPOAuthTests",
                "MCPOAuthTests.testDiscoveryUsesChallengePRMThenRFC8414OIDCOrder",
                "MCPOAuthTests.testRefreshIsSingleFlightAndPreservesOldRefreshToken",
                "MCPOAuthTests.testLoginBuildsPKCEStateNonceResourceAndStoresOnlyHandle",
                "MCPOAuthTests.testLoopbackListenerBindsExactAddressAndReturnsBoundedCallback",
            ],
            upgradeReplay: [
                "Re-run discovery/PKCE/state/DCR/refresh/account/resource/origin and replay fixtures.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "P008",
            feature: "pinned_conformance_runner",
            disposition: .requiresPatch,
            upstreamFiles: [
                "conformance-baseline.yml",
                "scripts/run-conformance.sh",
                "Sources/MCPConformance/Client/main.swift",
            ],
            upstreamBlobIDs: [
                "conformance-baseline.yml":
                    "7127a6b96eac080b9947b2cff0a25db2be6a6bcc",
                "scripts/run-conformance.sh":
                    "6812461c52fe49c3f219fb0b1d3fa66a56419ca2",
                "Sources/MCPConformance/Client/main.swift":
                    "60b4baefcea2e2e23f16fa6249432a26d36f60a6",
            ],
            upstreamEvidence:
                "The upstream client baseline is empty, invokes an unpinned npm conformance package, and unknown scenarios can initialize then exit successfully.",
            intatisContract:
                "Intatis pins its conformance runner and scenario inventory; unknown/unexecuted scenarios fail, and hostile fixtures complement official conformance.",
            conformanceTests: [
                "MCPConformanceInventoryTests",
                "MCPConformanceRunnerSelfTests",
            ],
            upgradeReplay: [
                "Pin the new runner digest and enumerate every expected scenario.",
                "Prove an unknown scenario and a skipped required scenario fail.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "A001",
            feature: "sampling_tools",
            disposition: .requiresAdapter,
            upstreamFiles: [
                "Sources/MCP/Client/Sampling.swift",
                "Sources/MCP/Client/Client.swift",
                "Sources/MCP/Server/Tools.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Client/Client.swift":
                    "3eea124045b4f436d02bf75cbef5c89c811da420",
                "Sources/MCP/Server/Tools.swift":
                    "478ba60192b66921462773bd21dcc60baffd020d",
            ],
            upstreamEvidence:
                "Client capabilities and sampling tool-use types exist",
            intatisContract:
                "A non-recursive, user-reviewed MCPSamplingBroker enforces independent model, cost, iteration, and privacy limits.",
            conformanceTests: [
                "MCPSamplingBrokerTests",
                "MCPSamplingToolsConformanceTests",
            ],
            upgradeReplay: [
                "Re-run broker authorization, tool loop, privacy, cost, and no-AgentLoop-recursion fixtures.",
            ]
        ),
        MCPSDKCompatibilityEntry(
            patchID: "A002",
            feature: "form_and_url_elicitation",
            disposition: .requiresAdapter,
            upstreamFiles: [
                "Sources/MCP/Client/Elicitation.swift",
                "Sources/MCP/Client/Client.swift",
            ],
            upstreamBlobIDs: [
                "Sources/MCP/Client/Client.swift":
                    "3eea124045b4f436d02bf75cbef5c89c811da420",
            ],
            upstreamEvidence:
                "Form and URL elicitation types and handlers exist",
            intatisContract:
                "A provider-neutral broker rejects secret fields, binds origin/generation, and requires an explicit user decision.",
            conformanceTests: [
                "MCPElicitationBrokerTests",
                "MCPURLElicitationConformanceTests",
            ],
            upgradeReplay: [
                "Re-run form/url schema, secret-field, origin, generation, cancel, and explicit-user-decision fixtures.",
            ]
        ),
    ]

    /// Compile-time proof that the pinned SDK exposes the stable client
    /// capability shape used by both Intatis protocol profiles.
    public static func makeCapabilityProbe(
        extended: Bool
    ) -> Client.Capabilities {
        makeCapabilityProbe(
            profile: extended ? .standardExtended : .codexCompat,
            callbacks: .complete(
                for: extended ? .standardExtended : .codexCompat))
    }

    /// Builds the exact per-generation client capability surface. Tests and
    /// protocol probes may request the complete profile surface, while a live
    /// session advertises only callbacks for which handlers were installed.
    public static func makeCapabilityProbe(
        profile: MCPProtocolProfile,
        callbacks: MCPClientCallbackCapabilities
    ) -> Client.Capabilities {
        Client.Capabilities(
            sampling: callbacks.samplingTools
                ? .init(tools: .init(), context: nil)
                : nil,
            elicitation: callbacks.hasElicitation
                ? .init(
                    form: callbacks.formElicitation ? .init() : nil,
                    url: callbacks.URLElicitation ? .init() : nil)
                : nil,
            experimental: nil,
            roots: profile == .standardExtended
                ? .init(listChanged: true)
                : nil,
            tasks: callbacks.hasTasks
                ? .init(
                    list: callbacks.taskList ? .init() : nil,
                    cancel: callbacks.taskCancel ? .init() : nil,
                    requests: .init(
                        sampling: callbacks.taskSampling
                            ? .init(createMessage: .init())
                            : nil,
                        elicitation: callbacks.taskElicitation
                            ? .init(create: .init())
                            : nil))
                : nil
        )
    }
}
