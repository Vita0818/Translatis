import Foundation
import IntatisAgentKernel
import IntatisCore
import IntatisProviders

enum Mode: String { case chat, code, cowork }

/// Persistent config at the configured host application's user config root
/// (all values are strings). The host CLI writes it; environment variables
/// override it; both override defaults.
enum ConfigFile {
    static var url: URL {
        IntatisHostApplication.identity.userConfigurationDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("config.json")
    }

    static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        return obj
    }

    static func write(_ dict: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Connect to ANY OpenAI-compatible endpoint. Resolution precedence per field:
/// environment variable → config file → built-in default.
struct CLIConfig {
    private static var hostIdentity: IntatisHostApplicationIdentity {
        IntatisHostApplication.identity
    }

    private static func environmentVariable(_ suffix: String) -> String {
        hostIdentity.environmentVariable(suffix)
    }
    let baseURL: URL
    let apiKey: String
    let model: String
    let wire: WireFormat
    let reasoningEffort: ReasoningEffort?
    let mode: Mode
    let includeUsage: Bool
    /// Code keeps its conservative default while Cowork gets the larger
    /// long-running budget. An explicit host override applies to both modes.
    let maxSteps: Int
    let coworkMaxSteps: Int
    /// Every host-configured route eligible for this CLI process. Chat/Code
    /// continue to use the selected route while Cowork compiles all routes into
    /// exact, versioned inference profiles.
    let providerRoutes: [CLIProviderRoute]
    let selectedProviderID: String
    let selectedVariantID: String?
    /// Exact host-configured model used by the automatic permission reviewer.
    /// This is resolved from `permission_reviewer_model`, or from the JSON
    /// document's top-level `model` when that field is absent. It never follows
    /// a later @main selection or rebind.
    let permissionReviewerModel: CLIProviderModelSelection
    /// Host-side route used by `generate_image` and `edit_image`. Agent tool
    /// arguments never carry this provider/model selection.
    let imageModel: CLIProviderModelSelection?
    /// Independent Knowledge roles. Both must be present before the Knowledge
    /// tool surface is composed; neither follows the selected inference model.
    let embeddingModel: CLIProviderModelSelection?
    let rerankerModel: CLIProviderModelSelection?
    /// The explicitly selected Intatis config is retained only so a lazy
    /// `providerConfig` credential reference can be revalidated. It is never
    /// copied into EventLog/profile bindings or printed by the CLI.
    let configurationFileURL: URL?

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    init(baseURL: URL,
         apiKey: String,
         model: String,
         wire: WireFormat,
         reasoningEffort: ReasoningEffort?,
         mode: Mode,
         includeUsage: Bool,
         maxSteps: Int,
         coworkMaxSteps: Int? = nil,
         providerRoutes: [CLIProviderRoute]? = nil,
         selectedProviderID: String? = nil,
         selectedVariantID: String? = nil,
         permissionReviewerModel: CLIProviderModelSelection? = nil,
         imageModel: CLIProviderModelSelection? = nil,
         embeddingModel: CLIProviderModelSelection? = nil,
         rerankerModel: CLIProviderModelSelection? = nil,
         configurationFileURL: URL? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.wire = wire
        self.reasoningEffort = reasoningEffort
        self.mode = mode
        self.includeUsage = includeUsage
        self.maxSteps = maxSteps
        self.coworkMaxSteps = coworkMaxSteps ?? maxSteps
        let legacy = CLIProviderRoute.legacy(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            wire: wire)
        self.providerRoutes = providerRoutes?.isEmpty == false ? providerRoutes! : [legacy]
        let resolvedSelectedProviderID = selectedProviderID ?? legacy.id
        self.selectedProviderID = resolvedSelectedProviderID
        self.selectedVariantID = selectedVariantID
        self.permissionReviewerModel = permissionReviewerModel
            ?? CLIProviderModelSelection(
                providerID: resolvedSelectedProviderID,
                modelID: model)
        self.imageModel = imageModel
        self.embeddingModel = embeddingModel
        self.rerankerModel = rerankerModel
        self.configurationFileURL = configurationFileURL
    }

    static func load() throws -> CLIConfig {
        let env = ProcessInfo.processInfo.environment
        if let modernURL = CLIModernProviderConfig.existingURL(environment: env) {
            return try load(configurationFileURL: modernURL, environment: env)
        }
        let file = ConfigFile.read()
        func value(_ envKey: String, _ fileKey: String, fallback: String?) -> String? {
            if let e = env[envKey], !e.isEmpty { return e }
            if let f = file[fileKey], !f.isEmpty { return f }
            return fallback
        }

        let baseString = value(
            environmentVariable("BASE_URL"),
            "baseURL",
            fallback: defaultBaseURL)!
        guard let baseURL = CLIProviderRoute.validHTTPURL(baseString) else {
            throw IntatisError.config("invalid CLI provider endpoint")
        }
        let apiKeyVariable = environmentVariable("API_KEY")
        guard let apiKey = value(apiKeyVariable, "apiKey", fallback: nil),
              !apiKey.isEmpty else {
            throw IntatisError.config(
                "no API key — run `\(hostIdentity.commandName) settings`, or set \(apiKeyVariable)")
        }
        let model = value(
            environmentVariable("MODEL"),
            "model",
            fallback: defaultModel)!
        let rawReasoning = value(
            environmentVariable("REASONING"),
            "reasoning",
            fallback: nil)
        let reasoning = try parsedReasoningEffort(rawReasoning)
        let mode = Mode(rawValue: value(
            environmentVariable("MODE"),
            "mode",
            fallback: "chat")!.lowercased()) ?? .chat
        // Ask the endpoint for token usage (default on). Set TRANSLATIS_USAGE=0 if an
        // endpoint rejects the stream_options field.
        let usageStr = value(
            environmentVariable("USAGE"),
            "usage",
            fallback: "1")!.lowercased()
        let includeUsage = !(usageStr == "0" || usageStr == "false" || usageStr == "off")
        // How many tool round-trips one turn may take before giving up. Long
        // agentic tasks need plenty; override with TRANSLATIS_MAX_STEPS.
        let configuredMaxSteps = value(
            environmentVariable("MAX_STEPS"),
            "maxSteps",
            fallback: nil)
        let maxSteps = max(
            1,
            Int(configuredMaxSteps ?? "\(AgentRuntime.defaultCodeMaxIterations)")
                ?? AgentRuntime.defaultCodeMaxIterations)
        let coworkMaxSteps = configuredMaxSteps == nil
            ? AgentRuntime.defaultCoworkMaxIterations
            : maxSteps

        return CLIConfig(baseURL: baseURL, apiKey: apiKey, model: model, wire: .openai,
                         reasoningEffort: reasoning, mode: mode, includeUsage: includeUsage,
                         maxSteps: maxSteps,
                         coworkMaxSteps: coworkMaxSteps,
                         selectedVariantID: reasoning.map { "reasoning-\($0.rawValue)" })
    }

    /// Deterministic seam used by the offline self-test and by `TRANSLATIS_CONFIG`.
    /// The schema is the same Intatis/OpenCode-compatible provider map used by
    /// the macOS app; no CLI-only provider format is introduced.
    static func load(configurationFileURL: URL,
                     environment: [String: String]) throws -> CLIConfig {
        let document = try CLIModernProviderConfig.load(
            from: configurationFileURL,
            environment: environment)
        func value(_ envKey: String, fallback: String?) -> String? {
            if let e = environment[envKey], !e.isEmpty { return e }
            return fallback
        }

        let requestedModel = value(
            environmentVariable("MODEL"),
            fallback: document.selectedModelID) ?? document.selectedModelID
        var selectedProviderID = document.selectedProviderID
        var selectedModelID = requestedModel
        if let split = try document.providerQualifiedModel(requestedModel) {
            selectedProviderID = split.providerID
            selectedModelID = split.modelID
        } else {
            // An unqualified host override may name a model that exists on one
            // configured route other than the document default. Preserve that
            // exact route instead of silently inventing the model on the
            // current provider. Ambiguous IDs stay on the explicitly selected
            // provider when possible; otherwise the host must qualify them.
            let matchingRoutes = document.routes.filter { route in
                route.models.contains(where: { $0.id == requestedModel })
                    && !document.isKnowledgeRoleModel(
                        providerID: route.id,
                        modelID: requestedModel)
            }
            if matchingRoutes.count == 1, let only = matchingRoutes.first {
                selectedProviderID = only.id
            } else if matchingRoutes.count > 1,
                      !matchingRoutes.contains(where: { $0.id == selectedProviderID }) {
                throw IntatisError.config(
                    "ambiguous CLI model override; qualify it with a provider ID")
            }
        }

        guard var selectedRoute = document.routes.first(where: {
            $0.id == selectedProviderID
        }) ?? document.routes.first else {
            throw IntatisError.config("no usable CLI provider routes")
        }
        if !selectedRoute.models.contains(where: { $0.id == selectedModelID }) {
            selectedRoute.models.append(CLIProviderModel(
                id: selectedModelID,
                displayName: selectedModelID))
        }

        var routes = document.routes
        if let baseOverride = environment[environmentVariable("BASE_URL")],
           !baseOverride.isEmpty {
            guard let url = CLIProviderRoute.validHTTPURL(baseOverride) else {
                throw IntatisError.config("invalid CLI provider endpoint")
            }
            selectedRoute.baseURL = url
            selectedRoute.chatEndpoint = nil
        }
        let selectedInlineKey = environment[environmentVariable("API_KEY")]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedInlineKey, !selectedInlineKey.isEmpty {
            selectedRoute.credentialRef = CLIInferenceRouteIdentity.inlineCredentialRef(
                routeID: selectedRoute.id,
                baseURL: selectedRoute.baseURL,
                wire: selectedRoute.wire)
            selectedRoute.inlineSecret = selectedInlineKey
        }
        if let index = routes.firstIndex(where: { $0.id == selectedRoute.id }) {
            routes[index] = selectedRoute
        }

        let rawReasoning = value(environmentVariable("REASONING"), fallback: nil)
        let reasoning = try parsedReasoningEffort(rawReasoning)
        let mode = Mode(rawValue: value(
            environmentVariable("MODE"),
            fallback: "chat")!.lowercased()) ?? .chat
        let usageStr = value(
            environmentVariable("USAGE"),
            fallback: "1")!.lowercased()
        let includeUsage = !(usageStr == "0" || usageStr == "false" || usageStr == "off")
        let configuredMaxSteps = value(
            environmentVariable("MAX_STEPS"),
            fallback: nil)
        let maxSteps = max(
            1,
            Int(configuredMaxSteps ?? "\(AgentRuntime.defaultCodeMaxIterations)")
                ?? AgentRuntime.defaultCodeMaxIterations)
        let coworkMaxSteps = configuredMaxSteps == nil
            ? AgentRuntime.defaultCoworkMaxIterations
            : maxSteps
        let selectedVariantID = try document.selectedVariantID(
            providerID: selectedRoute.id,
            modelID: selectedModelID,
            reasoningEffort: reasoning)
        if let reasoning,
           selectedVariantID == nil,
           !document.baseModel(
                providerID: selectedRoute.id,
                modelID: selectedModelID,
                hasReasoningEffort: reasoning) {
            throw IntatisError.config(
                "selected CLI reasoning effort has no configured variant for the selected model")
        }

        return CLIConfig(
            baseURL: selectedRoute.baseURL,
            apiKey: selectedRoute.inlineSecret ?? "",
            model: selectedModelID,
            wire: selectedRoute.wire,
            reasoningEffort: reasoning,
            mode: mode,
            includeUsage: includeUsage,
            maxSteps: maxSteps,
            coworkMaxSteps: coworkMaxSteps,
            providerRoutes: routes,
            selectedProviderID: selectedRoute.id,
            selectedVariantID: selectedVariantID,
            permissionReviewerModel: document.permissionReviewerModel,
            imageModel: document.imageModel,
            embeddingModel: document.embeddingModel,
            rerankerModel: document.rerankerModel,
            configurationFileURL: configurationFileURL.standardizedFileURL)
    }

    private static func parsedReasoningEffort(_ raw: String?) throws -> ReasoningEffort? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard let effort = ReasoningEffort(rawValue: normalized) else {
            throw IntatisError.config("invalid CLI reasoning effort")
        }
        return effort
    }

    func providerConfig() -> ProviderConfig {
        let endpoints = providerRoutes.map { route in
            let requestOptions =
                Dictionary(
                    uniqueKeysWithValues:
                        route.models.map { configuredModel in
                            var options =
                                configuredModel.requestOptions
                            if route.id == selectedProviderID,
                               configuredModel.id == model,
                               let selectedVariantID,
                               let variant =
                                   configuredModel.variants.first(
                                       where: {
                                           $0.id
                                               == selectedVariantID
                                       }) {
                                options =
                                    InferenceRequestOptionMerge
                                        .deepOverlay([
                                            options,
                                            variant.requestOptions,
                                        ])
                            }
                            return (
                                configuredModel.id,
                                options)
                        })
            return ProviderEndpoint(
                id: CLIInferenceRouteIdentity.endpointID(route: route),
                baseURL: route.baseURL,
                chatEndpoint: route.chatEndpoint,
                apiKeyRef: route.credentialRef,
                wire: route.wire,
                requestAdapter:
                    route.requestAdapter,
                modelRequestAdapters:
                    Dictionary(
                        uniqueKeysWithValues:
                            route.models.compactMap {
                                model in
                                model.requestAdapterOverride
                                    .map {
                                        (model.id, $0)
                                    }
                            }),
                modelRequestOptions:
                    requestOptions,
                modelCapabilities: Dictionary(
                    uniqueKeysWithValues:
                        route.models.map {
                            ($0.id, $0.declaredCapabilities)
                        }))
        }
        let selectedRoute = providerRoutes.first { $0.id == selectedProviderID }
            ?? providerRoutes[0]
        let ref = ModelRef(
            endpoint: CLIInferenceRouteIdentity.endpointID(route: selectedRoute),
            model: ModelID(rawValue: model))
        var models = ResolvedModels(chat: ref, agent: ref)
        if let reviewerRoute = providerRoutes.first(where: {
            $0.id == permissionReviewerModel.providerID
        }) {
            models.reviewer = ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: reviewerRoute),
                model: ModelID(rawValue: permissionReviewerModel.modelID))
        }
        if let imageModel,
           let imageRoute = providerRoutes.first(where: {
               $0.id == imageModel.providerID
           }) {
            models.imageGen = ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: imageRoute),
                model: ModelID(rawValue: imageModel.modelID))
        }
        if let embeddingModel,
           let embeddingRoute = providerRoutes.first(where: {
               $0.id == embeddingModel.providerID
           }) {
            models.embedding = ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: embeddingRoute),
                model: ModelID(rawValue: embeddingModel.modelID))
        }
        if let rerankerModel,
           let rerankerRoute = providerRoutes.first(where: {
               $0.id == rerankerModel.providerID
           }) {
            models.reranker = ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: rerankerRoute),
                model: ModelID(rawValue: rerankerModel.modelID))
        }
        return ProviderConfig(endpoints: endpoints, models: models)
    }

    func isKnowledgeRoleModel(
        providerID: String,
        modelID: String
    ) -> Bool {
        [embeddingModel, rerankerModel].compactMap { $0 }.contains {
            $0.providerID == providerID && $0.modelID == modelID
        }
    }

    var selectedRouteLabel: String {
        let route = providerRoutes.first { $0.id == selectedProviderID } ?? providerRoutes[0]
        return route.safeDisplayName
    }

    var hasConfiguredCredential: Bool {
        let route = providerRoutes.first { $0.id == selectedProviderID } ?? providerRoutes[0]
        return route.inlineSecret?.isEmpty == false || route.credentialRef.source != .keychain
    }
}
