import Foundation
import IntatisCore
import IntatisProtocol

/// One atomically resolved tool-calling route. Provider, model, and durable
/// binding always originate from the same exact catalog snapshot revision.
public struct ResolvedInferenceProfile: Sendable {
    public let binding: AgentInferenceBinding
    public let model: ModelID
    public let provider: ToolCallingProvider
    public let modelContextPolicy: AgentModelContextPolicy
    public let hostedWebSearch: ResolvedHostedWebSearchRoute?

    public init(binding: AgentInferenceBinding,
                model: ModelID,
                provider: ToolCallingProvider,
                modelContextPolicy: AgentModelContextPolicy = .unspecified,
                hostedWebSearch: ResolvedHostedWebSearchRoute? = nil) {
        self.binding = binding
        self.model = model
        self.provider = provider
        self.modelContextPolicy = modelContextPolicy
        self.hostedWebSearch = hostedWebSearch
    }
}

/// One provider-hosted search route frozen with the exact agent model route.
/// It is intentionally separate from browser, URL-fetch, and MCP tools.
public struct ResolvedHostedWebSearchRoute: Sendable {
    public let provider: ChatProvider
    public let model: ModelID
    public let configuration: ChatWebSearchConfiguration

    public init(provider: ChatProvider,
                model: ModelID,
                configuration: ChatWebSearchConfiguration) {
        self.provider = provider
        self.model = model
        self.configuration = configuration
    }
}

/// Runtime route for visible Code sessions. When the selected legacy model
/// maps unambiguously to one current base profile, provider/model/context
/// metadata come from that same immutable resolution. Otherwise the legacy
/// provider remains usable and compaction metadata stays unspecified.
public struct ResolvedAgentRuntimeRoute: Sendable {
    public let provider: ToolCallingProvider
    public let model: ModelID
    public let modelContextPolicy: AgentModelContextPolicy
    public let hostedWebSearch: ResolvedHostedWebSearchRoute?

    public init(
        provider: ToolCallingProvider,
        model: ModelID,
        modelContextPolicy: AgentModelContextPolicy,
        hostedWebSearch: ResolvedHostedWebSearchRoute? = nil
    ) {
        self.provider = provider
        self.model = model
        self.modelContextPolicy = modelContextPolicy
        self.hostedWebSearch = hostedWebSearch
    }
}

/// One atomically resolved Chat route. Provider, model, effective variant
/// options, and optional provider-hosted search dialect all belong to the
/// user's current exact Chat selection.
public struct ResolvedChatRuntimeRoute: Sendable {
    public let provider: ChatProvider
    public let model: ModelID
    public let webSearch: ChatWebSearchConfiguration?

    public init(provider: ChatProvider,
                model: ModelID,
                webSearch: ChatWebSearchConfiguration? = nil) {
        self.provider = provider
        self.model = model
        self.webSearch = webSearch
    }
}

/// Resolves a `ModelRef` to a concrete provider for a capability. v0.1 only
/// resolves `.chat`; the `switch endpoint.wire` is where new dialects plug in
/// (ARCHITECTURE.md §3.3, §9.2). Secrets are fetched lazily via the injected
/// `SecretResolver`, never stored in the config.
public actor ProviderRegistry {
    let config: ProviderConfig
    let resolver: SecretResolver
    private let http: HTTPByteStreaming
    let dataClient: HTTPDataClient
    let inferenceCatalogSnapshot: InferenceCatalogSnapshot?

    public init(config: ProviderConfig,
                resolver: SecretResolver,
                http: HTTPByteStreaming = URLSessionStreamingClient(),
                dataClient: HTTPDataClient = URLSessionDataClient(),
                inferenceCatalogSnapshot: InferenceCatalogSnapshot? = nil) {
        self.config = config
        self.resolver = resolver
        self.http = http
        self.dataClient = dataClient
        self.inferenceCatalogSnapshot = inferenceCatalogSnapshot
    }

    public func chatProvider(for ref: ModelRef) async throws -> ChatProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAIWireProvider(endpoint: endpoint, apiKey: apiKey, http: http)
        }
    }

    /// Convenience: the default chat provider from `models.chat`.
    public func defaultChatProvider() async throws -> ChatProvider {
        try await chatProvider(for: config.models.chat)
    }

    /// Resolves one exact Chat selection. The legacy `models.webSearch`
    /// binding is deliberately ignored: hosted search can only be advertised
    /// by the current route when both its model capability and exact adapter
    /// dialect are known. Unsupported/unknown search remains an ordinary Chat
    /// request on the same provider and model without a user-facing warning.
    public func chatRuntimeRoute(model overrideModel: ModelID? = nil)
        async throws -> ResolvedChatRuntimeRoute
    {
        let selected = config.models.chat
        let ref = ModelRef(
            endpoint: selected.endpoint,
            model: overrideModel ?? selected.model)
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }

        let requestAdapter = endpoint.requestAdapter(for: ref.model)
        // Search capability must never mask an unsupported ordinary Chat
        // adapter. Validate the primary route before planning the optional
        // hosted-search extension.
        _ = try requestAdapter.chatCompletionsAdapter()

        let webSearch: ChatWebSearchConfiguration?
        if endpoint.capabilities(for: ref.model)
            .contains(.hostedWebSearch),
           let dialect = requestAdapter.hostedWebSearchDialect() {
            webSearch = ChatWebSearchConfiguration(
                dialect: dialect,
                contextSize: .medium)
        } else {
            webSearch = nil
        }

        return ResolvedChatRuntimeRoute(
            provider: try await chatProvider(for: ref),
            model: ref.model,
            webSearch: webSearch)
    }

    /// Runs a minimal model-backed request and returns a user-facing diagnostic
    /// without exposing secrets. This is intended for Settings/CLI health checks,
    /// not for normal chat history.
    public func healthCheck(role: ProviderHealthRole = .chat,
                            options: ProviderHealthCheckOptions = ProviderHealthCheckOptions()) async -> ProviderHealthReport {
        let start = Date()
        let ref = role == .agent ? (config.models.agent ?? config.models.chat) : config.models.chat
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            return ProviderHealthChecker.failed(
                role: role,
                endpointID: ref.endpoint,
                model: ref.model,
                wire: nil,
                code: "config",
                message: "unknown endpoint '\(ref.endpoint)'",
                startedAt: start)
        }

        do {
            let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
            switch endpoint.wire {
            case .openai:
                let runtimePolicy: ProviderRuntimePolicy = role == .agent
                    ? .agentStreaming
                    : .streaming
                let provider = OpenAIWireProvider(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    http: http,
                    runtimePolicy: runtimePolicy,
                    toolCallingCapabilities:
                        toolCallingCapabilities(
                            endpoint: endpoint,
                            model: ref.model))
                switch role {
                case .chat:
                    var report = await ProviderHealthChecker.checkChat(
                        provider: provider,
                        endpoint: endpoint,
                        model: ref.model,
                        options: options,
                        startedAt: start)
                    report.endpointID = endpoint.id
                    report.wire = endpoint.wire
                    return report
                case .agent:
                    var report = await ProviderHealthChecker.checkAgent(
                        provider: provider,
                        endpoint: endpoint,
                        model: ref.model,
                        options: options,
                        startedAt: start)
                    report.endpointID = endpoint.id
                    report.wire = endpoint.wire
                    return report
                }
            }
        } catch {
            return ProviderHealthChecker.failed(
                role: role,
                endpoint: endpoint,
                model: ref.model,
                error: error,
                startedAt: start)
        }
    }

    /// The model id bound to the chat role.
    public func chatModel() -> ModelID {
        config.models.chat.model
    }

    /// The resolved model bindings (chat/agent/reviewer/…).
    public func models() -> ResolvedModels {
        config.models
    }

    // MARK: Tool-calling (v0.2)

    public func agentProvider(for ref: ModelRef) async throws -> ToolCallingProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        return makeAgentWireProvider(
            endpoint: endpoint,
            model: ref.model,
            apiKey: apiKey)
    }

    /// Resolves an exact immutable profile revision. No current/default profile
    /// is consulted, and credentials are requested only after exact resolution
    /// and capability validation succeed.
    public func agentInference(for ref: InferenceProfileRef) async throws -> ResolvedInferenceProfile {
        guard let inferenceCatalogSnapshot else {
            throw InferenceCatalogError.unresolvedProfile
        }
        let resolution = try inferenceCatalogSnapshot.resolve(ref)
        return try await makeAgentInference(from: resolution)
    }

    /// Recovery path that additionally revalidates every durable binding field
    /// and its immutable-definition fingerprint before resolving a credential.
    public func agentInference(for binding: AgentInferenceBinding) async throws -> ResolvedInferenceProfile {
        guard let inferenceCatalogSnapshot else {
            throw InferenceCatalogError.unresolvedProfile
        }
        let resolution = try inferenceCatalogSnapshot.resolve(binding)
        return try await makeAgentInference(from: resolution)
    }

    /// The default agent provider, from `models.agent` (falling back to `models.chat`).
    public func defaultAgentProvider() async throws -> ToolCallingProvider {
        try await agentProvider(for: config.models.agent ?? config.models.chat)
    }

    public func defaultAgentRuntimeRoute() async throws
        -> ResolvedAgentRuntimeRoute
    {
        let legacyRef = config.models.agent ?? config.models.chat
        return try await agentRuntimeRoute(for: legacyRef)
    }

    /// Resolves the provider, exact selected model, and optional context
    /// metadata as one route. This overload preserves CLI `/model` switching:
    /// the endpoint remains the configured agent endpoint while catalog
    /// metadata is attached only for one unambiguous matching base profile.
    public func agentRuntimeRoute(model: ModelID) async throws
        -> ResolvedAgentRuntimeRoute
    {
        let configured = config.models.agent ?? config.models.chat
        return try await agentRuntimeRoute(
            for: ModelRef(
                endpoint: configured.endpoint,
                model: model))
    }

    public func agentRuntimeRoute(for legacyRef: ModelRef) async throws
        -> ResolvedAgentRuntimeRoute
    {
        if let inferenceCatalogSnapshot {
            let candidates = inferenceCatalogSnapshot.catalog
                .currentProfileRefs.compactMap { profileRef
                    -> InferenceProfileRef? in
                    guard let profile = try? inferenceCatalogSnapshot
                            .profile(for: profileRef),
                          profile.modelID == legacyRef.model,
                          profile.variantID == nil,
                          profile.connectionRef
                            .inferenceConnectionID.rawValue
                            == legacyRef.endpoint else {
                        return nil
                    }
                    return profileRef
                }
            if candidates.count == 1,
               let profileRef = candidates.first {
                let resolved = try await agentInference(
                    for: profileRef)
                return ResolvedAgentRuntimeRoute(
                    provider: resolved.provider,
                    model: resolved.model,
                    modelContextPolicy:
                        resolved.modelContextPolicy,
                    hostedWebSearch:
                        resolved.hostedWebSearch)
            }
        }
        guard let endpoint = config.endpoint(id: legacyRef.endpoint) else {
            throw IntatisError.config(
                "unknown endpoint '\(legacyRef.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        let provider = makeAgentWireProvider(
            endpoint: endpoint,
            model: legacyRef.model,
            apiKey: apiKey)
        return ResolvedAgentRuntimeRoute(
            provider: provider,
            model: legacyRef.model,
            modelContextPolicy: .unspecified,
            hostedWebSearch: hostedWebSearchRoute(
                endpoint: endpoint,
                model: legacyRef.model,
                provider: provider))
    }

    public func agentModel() -> ModelID {
        (config.models.agent ?? config.models.chat).model
    }

    /// Resolves hosted search from one explicit legacy/current model ref
    /// without consulting the inference-catalog current pointer. Shipping
    /// Code/CLI use this beside the Responses route derived from the same ref,
    /// so a temporarily stale catalog snapshot cannot select another endpoint
    /// revision or provider service.
    func agentHostedWebSearchRoute(
        for ref: ModelRef,
        bearerToken: String
    ) throws -> ResolvedHostedWebSearchRoute? {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config(
                "unknown endpoint '\(ref.endpoint)'")
        }
        let provider = makeAgentWireProvider(
            endpoint: endpoint,
            model: ref.model,
            apiKey: bearerToken)
        return hostedWebSearchRoute(
            endpoint: endpoint,
            model: ref.model,
            provider: provider)
    }

    /// Reconstructs the hosted-search provider from the same immutable binding
    /// and already-resolved credential used by the App Server route. No current
    /// profile pointer or second credential lookup is permitted here.
    func agentHostedWebSearchRoute(
        for binding: AgentInferenceBinding,
        bearerToken: String
    ) throws -> ResolvedHostedWebSearchRoute? {
        guard let inferenceCatalogSnapshot else {
            throw InferenceCatalogError.unresolvedProfile
        }
        let resolution = try inferenceCatalogSnapshot.resolve(binding)
        guard resolution.binding == binding else {
            throw InferenceCatalogError.bindingMismatch
        }
        let endpoint = try agentEndpoint(from: resolution)
        let provider = makeAgentWireProvider(
            endpoint: endpoint,
            model: resolution.profile.modelID,
            apiKey: bearerToken)
        return hostedWebSearchRoute(
            endpoint: endpoint,
            model: resolution.profile.modelID,
            provider: provider)
    }

    private func makeAgentInference(
        from resolution: InferenceProfileResolution
    ) async throws -> ResolvedInferenceProfile {
        let profile = resolution.profile
        let endpoint = try agentEndpoint(from: resolution)
        let apiKey = try await resolver.secret(
            for: resolution.connection.credentialRef)
        let wireProvider = makeAgentWireProvider(
            endpoint: endpoint,
            model: profile.modelID,
            apiKey: apiKey)
        return ResolvedInferenceProfile(
            binding: resolution.binding,
            model: profile.modelID,
            provider: wireProvider,
            modelContextPolicy: profile.modelContextPolicy,
            hostedWebSearch: hostedWebSearchRoute(
                endpoint: endpoint,
                model: profile.modelID,
                provider: wireProvider))
    }

    private func agentEndpoint(
        from resolution: InferenceProfileResolution
    ) throws -> ProviderEndpoint {
        let profile = resolution.profile
        if !profile.declaredCapabilities.isEmpty,
           !profile.declaredCapabilities.contains(where: { $0 == .toolCalling }) {
            throw InferenceCatalogError.incompatibleProfileCapability
        }

        let connection = resolution.connection
        return ProviderEndpoint(
            id: connection.connectionRef.inferenceConnectionID.rawValue,
            baseURL: connection.baseURL,
            chatEndpoint: connection.chatEndpoint,
            apiKeyRef: connection.credentialRef,
            wire: connection.wire,
            requestAdapter:
                profile.requestAdapter,
            modelRequestOptions: [
                profile.modelID.rawValue:
                    profile.effectiveRequestOptions,
            ],
            modelCapabilities: [
                profile.modelID.rawValue:
                    profile.declaredCapabilities,
            ])
    }

    private func makeAgentWireProvider(
        endpoint: ProviderEndpoint,
        model: ModelID,
        apiKey: String
    ) -> OpenAIWireProvider {
        switch endpoint.wire {
        case .openai:
            return OpenAIWireProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                http: http,
                runtimePolicy: .agentStreaming,
                toolCallingCapabilities:
                    toolCallingCapabilities(
                        endpoint: endpoint,
                        model: model))
        }
    }

    private func hostedWebSearchRoute(
        endpoint: ProviderEndpoint,
        model: ModelID,
        provider: ChatProvider
    ) -> ResolvedHostedWebSearchRoute? {
        guard endpoint.capabilities(for: model)
                .contains(.hostedWebSearch),
              let dialect = endpoint.requestAdapter(for: model)
                .hostedWebSearchDialect() else {
            return nil
        }
        return ResolvedHostedWebSearchRoute(
            provider: provider,
            model: model,
            configuration: ChatWebSearchConfiguration(
                dialect: dialect,
                contextSize: .medium,
                unsupportedBehavior: .failClosed,
                toolChoice: .required))
    }

    private func toolCallingCapabilities(
        endpoint: ProviderEndpoint,
        model: ModelID
    ) -> ToolCallingProviderCapabilities {
        let declaredCapabilities =
            endpoint.capabilities(for: model)
        let isReviewedNativeOpenAIResponsesRoute: Bool
        switch endpoint.wire {
        case .openai:
            isReviewedNativeOpenAIResponsesRoute =
                endpoint.requestAdapter(for: model) == .openAI
        }
        let supportsImageInput =
            isReviewedNativeOpenAIResponsesRoute
            && declaredCapabilities.contains(.visionInput)
        return ToolCallingProviderCapabilities(
            supportsToolSearch:
                declaredCapabilities.contains(.toolSearch),
            supportsUserImageInput: supportsImageInput,
            supportsFunctionOutputImageInput:
                supportsImageInput)
    }

    // MARK: Multimodal (v0.4)

    public func imageProvider(for ref: ModelRef) async throws -> ImageGenerationProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAIImageProvider(endpoint: endpoint, apiKey: apiKey, http: dataClient)
        }
    }

    public func imageEditingProvider(for ref: ModelRef) async throws -> ImageEditingProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAIImageProvider(endpoint: endpoint, apiKey: apiKey, http: dataClient)
        }
    }

    public func transcriptionProvider(for ref: ModelRef) async throws -> TranscriptionProvider {
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config("unknown endpoint '\(ref.endpoint)'")
        }
        let adapter = try endpoint.requestAdapter(for: ref.model)
            .transcriptionAdapter()
        let requestEncoding: TranscriptionRequestEncoding
        switch adapter {
        case .openAICompatibleMultipart:
            requestEncoding = .multipartFormData
        case .openRouterJSONBase64:
            requestEncoding = .jsonBase64
        }
        let apiKey = try await resolver.secret(for: endpoint.apiKeyRef)
        switch endpoint.wire {
        case .openai:
            return OpenAITranscriptionProvider(
                endpoint: endpoint,
                apiKey: apiKey,
                http: dataClient,
                requestEncoding: requestEncoding)
        }
    }

    /// nil when no image model is configured (`models.imageGen`).
    public func defaultImageProvider() async throws -> ImageGenerationProvider? {
        guard let ref = config.models.imageGen else { return nil }
        return try await imageProvider(for: ref)
    }

    /// Uses the same host-owned `image_model` route as generation. The model
    /// never selects a provider or model through `edit_image` arguments.
    public func defaultImageEditingProvider() async throws -> ImageEditingProvider? {
        guard let ref = config.models.imageGen else { return nil }
        return try await imageEditingProvider(for: ref)
    }

    public func defaultTranscriptionProvider() async throws -> TranscriptionProvider? {
        guard let ref = config.models.transcription else { return nil }
        return try await transcriptionProvider(for: ref)
    }

    /// Builds the single recorded-file runtime without resolving its
    /// credential. This mirrors Flotis's adapter-plan boundary while keeping
    /// Intatis configuration intentionally narrow: WAV/16 kHz/mono and the
    /// duration/upload bounds are host defaults, not new settings fields.
    public func configuredTranscriptionRuntime() throws
        -> ConfiguredTranscriptionRuntime? {
        guard let ref = config.models.transcription else { return nil }
        guard let endpoint = config.endpoint(id: ref.endpoint) else {
            throw IntatisError.config(
                "unknown endpoint '\(ref.endpoint)'")
        }
        _ = try endpoint.requestAdapter(for: ref.model)
            .transcriptionAdapter()
        return ConfiguredTranscriptionRuntime(
            model: ref,
            audio: RecordedFileTranscriptionConfiguration(
                format: .wav,
                sampleRate: 16_000,
                channels: 1,
                maximumRecordingDurationSeconds: 120,
                stopLeadSeconds: 0,
                maximumUploadBytes: maximumTranscriptionUploadBytes))
    }

    /// Returns the exact host-configured transcription route without resolving
    /// its credential. Composer voice input freezes this reference when
    /// recording starts, then resolves the provider only when audio is ready to
    /// transcribe. A missing endpoint or unsupported adapter is a configuration
    /// error rather than a reason to fall back to the current Chat model.
    public func configuredTranscriptionModelRef() throws -> ModelRef? {
        try configuredTranscriptionRuntime()?.model
    }

    public func imageModel() -> ModelID? { config.models.imageGen?.model }
    public func transcriptionModel() -> ModelID? { config.models.transcription?.model }
}
