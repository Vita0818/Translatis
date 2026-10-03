#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisSkills

typealias AppSessionSummary = SessionSummary

struct AppProviderModelVariant: Identifiable, Equatable {
    var id: String
    /// Variant fields are an opaque request-parameter preset. Intatis removes
    /// only the local `disabled` control flag and otherwise preserves keys and
    /// values exactly as configured.
    var requestOptions: [String: JSONValue]
    var configurationMetadata: [String: JSONValue]

    var reasoningLabel: String? {
        ModelConfigurationPresentation(
            modelMetadata: configurationMetadata,
            requestOptions: requestOptions).reasoningLabel
    }
}

struct AppProviderModel: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    /// Model-scoped API request options loaded from the external Intatis
    /// configuration. They stay in memory and are deliberately not mirrored to
    /// UserDefaults, where arbitrary user values could include secrets.
    var requestOptions: [String: JSONValue]
    /// Complete model-level configuration object loaded from the external file.
    /// It is retained only in memory so unknown metadata remains available for
    /// read-only UI projections without being normalized or written back.
    var configurationMetadata: [String: JSONValue]
    /// Named presets parsed from the config file. Like arbitrary model options,
    /// variants are intentionally memory-only and never mirrored to defaults.
    var variants: [AppProviderModelVariant]

    init(id: String,
         displayName: String,
         requestOptions: [String: JSONValue] = [:],
         configurationMetadata: [String: JSONValue] = [:],
         variants: [AppProviderModelVariant] = []) {
        self.id = id
        self.displayName = displayName
        self.requestOptions = requestOptions
        self.configurationMetadata = configurationMetadata
        self.variants = variants
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.requestOptions = [:]
        self.configurationMetadata = [:]
        self.variants = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
    }

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var reasoningLabel: String? {
        ModelConfigurationPresentation(
            modelMetadata: configurationMetadata,
            requestOptions: requestOptions).reasoningLabel
    }

    var declaredCapabilities: [Capability] {
        ModelCapabilityMetadata.declaredCapabilities(
            in: configurationMetadata)
    }

    var requestAdapterOverride: ProviderRequestAdapter? {
        guard case .object(let provider)? =
                configurationMetadata["provider"],
              case .string(let npm)? =
                provider["npm"] else {
            return nil
        }
        return ProviderRequestAdapter
            .configuredModelOverride(npm)
    }
}

struct AppProviderAPIKeySource: Codable, Equatable {
    var type: String
    var value: String

    static func environment(_ name: String) -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "env", value: name)
    }

    static func file(_ path: String) -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "file", value: path)
    }

    static func authFile() -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "authFile", value: "")
    }

    static func providerConfig(_ path: String) -> AppProviderAPIKeySource {
        AppProviderAPIKeySource(type: "providerConfig", value: path)
    }

    private var normalizedType: String {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "env", "environment":
            return "env"
        case "file", "path":
            return "file"
        case "authfile", "auth_file", "auth-json", "authjson", "json":
            return "authFile"
        case "providerconfig", "provider_config", "config", "configfile", "config_file":
            return "providerConfig"
        default:
            return "authFile"
        }
    }

    func ref(defaultRef: KeychainRef, providerID: String) -> KeychainRef {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedType {
        case "env":
            return trimmed.isEmpty ? defaultRef : .environment(trimmed)
        case "file":
            return trimmed.isEmpty ? defaultRef : .file(trimmed)
        case "authFile":
            return .authFile(providerID: providerID)
        case "providerConfig":
            return trimmed.isEmpty ? defaultRef : .providerConfig(path: trimmed, providerID: providerID)
        default:
            return defaultRef
        }
    }

    var isLegacyKeychain: Bool { normalizedType == "keychain" }

    var openCodeAPIKeyValue: String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch normalizedType {
        case "env":
            return "{env:\(trimmed)}"
        case "file":
            return "{file:\(trimmed)}"
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case value
        case name
        case path
    }

    init(type: String, value: String) {
        self.type = type
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        self.type = type
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .path)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(value, forKey: .value)
    }
}

struct AppProviderSettings: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    var npm: String
    var baseURL: String
    var chatEndpoint: String
    /// Optional Responses API override used by provider-hosted Chat search.
    /// It is configuration-only and is not exposed as a Settings control.
    var responsesEndpoint: String?
    var apiKeyAccount: String
    var apiKeySource: AppProviderAPIKeySource?
    var models: [AppProviderModel]

    init(id: String,
         displayName: String,
         npm: String = ProviderRequestAdapter
             .openAICompatible.rawValue,
         baseURL: String,
         chatEndpoint: String? = nil,
         responsesEndpoint: String? = nil,
         apiKeyAccount: String,
         apiKeySource: AppProviderAPIKeySource? = nil,
         models: [AppProviderModel]) {
        self.id = id
        self.displayName = displayName
        self.npm = ProviderRequestAdapter
            .configuredProvider(npm).rawValue
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint ?? AppConfig.chatEndpoint(forBaseURL: baseURL)
        self.responsesEndpoint = responsesEndpoint
        self.apiKeyAccount = apiKeyAccount
        self.apiKeySource = apiKeySource
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case npm
        case baseURL
        case chatEndpoint
        case responsesEndpoint
        case apiKeyAccount
        case apiKeySource
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try container.decode(String.self, forKey: .baseURL)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.npm = ProviderRequestAdapter.configuredProvider(
            try container.decodeIfPresent(
                String.self,
                forKey: .npm)).rawValue
        self.baseURL = baseURL
        self.chatEndpoint = try container.decodeIfPresent(String.self, forKey: .chatEndpoint)
            ?? AppConfig.chatEndpoint(forBaseURL: baseURL)
        self.responsesEndpoint = try container.decodeIfPresent(
            String.self,
            forKey: .responsesEndpoint)
        self.apiKeyAccount = try container.decodeIfPresent(String.self, forKey: .apiKeyAccount)
            ?? (self.id == "default" ? AppConfig.legacyAPIKeyAccount : "provider-\(self.id)")
        self.apiKeySource = try container.decodeIfPresent(AppProviderAPIKeySource.self, forKey: .apiKeySource)
        self.models = try container.decode([AppProviderModel].self, forKey: .models)
    }

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: baseURL)?.host ?? id
    }

    var requestAdapter: ProviderRequestAdapter {
        ProviderRequestAdapter.configuredProvider(npm)
    }
}

struct AppProviderCatalog: Codable, Equatable {
    var selectedProviderID: String
    var selectedModelID: String
    var selectedVariantID: String? = nil
    /// Host-owned route for the Cowork permission reviewer. The external
    /// configuration key is `permission_reviewer_model`; it is intentionally
    /// independent from the mutable Chat/Cowork model selection.
    var permissionReviewerModel: ModelRef? = nil
    /// Distinguishes an explicitly configured but invalid reviewer value from
    /// an older catalog that predates the role. Only the latter may inherit the
    /// configuration file's top-level `model` during normalization.
    var permissionReviewerModelWasExplicitlyConfigured: Bool? = nil
    /// Host-owned default for image generation and editing. Model-facing image
    /// tools never receive or select this route.
    var imageModel: ModelRef? = nil
    /// Host-owned route for composer voice transcription. It is configured by
    /// the top-level `transcription_model` field and never follows Chat model
    /// selection implicitly.
    var transcriptionModel: ModelRef? = nil
    /// Host-owned Knowledge embedding route. It is independent from Chat and
    /// Agent inference and has no hidden fallback.
    var embeddingModel: ModelRef? = nil
    /// Host-owned semantic reranker route. It is required together with the
    /// embedding route before Knowledge tools can be composed.
    var rerankerModel: ModelRef? = nil
    /// Legacy field retained only so existing configuration can be decoded and
    /// preserved. Chat runtime routing deliberately ignores it.
    var webSearchModel: ModelRef? = nil
    var providers: [AppProviderSettings]

    func isKnowledgeRoleModel(
        providerID: String,
        modelID: String
    ) -> Bool {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return [embeddingModel, rerankerModel].compactMap { $0 }.contains {
            normalized($0.endpoint) == normalized(providerID)
                && $0.model.rawValue == modelID
        }
    }

    func inferenceModels(for provider: AppProviderSettings)
        -> [AppProviderModel] {
        provider.models.filter {
            !isKnowledgeRoleModel(
                providerID: provider.id,
                modelID: $0.id)
        }
    }

    var selectedProvider: AppProviderSettings? {
        if let selected = providers.first(where: { $0.id == selectedProviderID }),
           !inferenceModels(for: selected).isEmpty {
            return selected
        }
        return providers.first { !inferenceModels(for: $0).isEmpty }
            ?? providers.first
    }

    var selectedModel: AppProviderModel? {
        guard let provider = selectedProvider else { return nil }
        let models = inferenceModels(for: provider)
        return models.first { $0.id == selectedModelID } ?? models.first
    }

    var selectedVariant: AppProviderModelVariant? {
        guard let selectedVariantID else { return nil }
        return selectedModel?.variants.first { $0.id == selectedVariantID }
    }
}

private struct AppProviderSelection: Codable, Equatable {
    var providerID: String
    var modelID: String
    var variantID: String? = nil
}

/// App configuration. Defaults to an OpenAI-compatible endpoint; provider
/// secrets are resolved from config/auth files, env vars, or explicit files.
/// The macOS build runs as the local DeveloperID workbench profile by default.
enum AppConfig {
    private static var hostIdentity: IntatisHostApplicationIdentity {
        IntatisHostApplication.identity
    }
    static let legacyAPIKeyAccount = "default-openai"

    /// The only macOS product is the local Developer ID workbench.
    static let platformProfile: PlatformProfile = .macDeveloperID
    static let skillRootAccess: SkillRootAccess = .workspaceAndGlobal

    static let defaultSession = SessionID(rawValue: "sess_default")

    // User-configurable endpoint + model (persisted in UserDefaults). This is what
    // makes the GUI vendor-agnostic — point baseURL at any OpenAI-compatible server.
    private static var baseURLKey: String {
        hostIdentity.userDefaultsKey("baseURL")
    }
    private static var modelKey: String {
        hostIdentity.userDefaultsKey("model")
    }
    private static var providerCatalogKey: String {
        hostIdentity.userDefaultsKey("providerCatalog.v1")
    }
    private static var providerSelectionKey: String {
        hostIdentity.userDefaultsKey("providerSelection.v1")
    }
    private static var configEnvKey: String {
        hostIdentity.environmentVariable("CONFIG")
    }
    private static let defaultProviderID = "default"
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultChatEndpoint = "https://api.openai.com/v1/chat/completions"
    static let defaultModel = "gpt-4o-mini"

    static var baseURL: String {
        get { providerCatalog.selectedProvider?.baseURL ?? defaultBaseURL }
        set {
            var catalog = providerCatalog
            guard let providerID = catalog.selectedProvider?.id,
                  let index = catalog.providers.firstIndex(where: { $0.id == providerID }) else {
                let normalizedBase = baseURL(fromChatEndpoint: newValue)
                UserDefaults.standard.set(normalizedBase, forKey: baseURLKey)
                return
            }
            let normalizedBase = baseURL(fromChatEndpoint: newValue)
            catalog.providers[index].baseURL = normalizedBase
            catalog.providers[index].chatEndpoint = chatEndpoint(forBaseURL: normalizedBase)
            providerCatalog = catalog
            UserDefaults.standard.set(normalizedBase, forKey: baseURLKey)
        }
    }
    static var chatModelName: String {
        get { providerCatalog.selectedModel?.id ?? defaultModel }
        set {
            var catalog = providerCatalog
            guard let providerID = catalog.selectedProvider?.id,
                  let providerIndex = catalog.providers.firstIndex(where: { $0.id == providerID }) else {
                UserDefaults.standard.set(newValue, forKey: modelKey)
                return
            }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = trimmed.isEmpty ? defaultModel : trimmed
            if !catalog.providers[providerIndex].models.contains(where: { $0.id == modelID }) {
                catalog.providers[providerIndex].models.append(
                    AppProviderModel(id: modelID, displayName: defaultDisplayName(for: modelID)))
            }
            catalog.selectedModelID = modelID
            providerCatalog = catalog
            UserDefaults.standard.set(modelID, forKey: modelKey)
        }
    }

    static var chatModelDisplayName: String {
        providerCatalog.selectedModel?.title ?? defaultDisplayName(for: defaultModel)
    }

    static var selectedProviderName: String {
        providerCatalog.selectedProvider?.title ?? "OpenAI"
    }

    static var selectedAPIKeyRef: KeychainRef {
        guard let provider = providerCatalog.selectedProvider else {
            return .authFile(providerID: defaultProviderID)
        }
        return apiKeyRef(for: provider)
    }

    static var providerCatalog: AppProviderCatalog {
        get {
            let catalog: AppProviderCatalog
            if let fileCatalog = fileProviderCatalog() {
                catalog = normalizedCatalog(fileCatalog)
            } else if let data = UserDefaults.standard.data(forKey: providerCatalogKey),
                      let decoded = try? JSONDecoder().decode(AppProviderCatalog.self, from: data) {
                catalog = normalizedCatalog(decoded)
            } else {
                catalog = normalizedCatalog(legacyProviderCatalog())
            }
            return applyingStoredSelection(to: catalog)
        }
        set {
            let normalized = normalizedCatalog(newValue)
            if let data = try? JSONEncoder().encode(normalized) {
                UserDefaults.standard.set(data, forKey: providerCatalogKey)
            }
            storeSelection(from: normalized)
            if let provider = normalized.selectedProvider {
                UserDefaults.standard.set(provider.baseURL, forKey: baseURLKey)
            }
            if let model = normalized.selectedModel {
                UserDefaults.standard.set(model.id, forKey: modelKey)
            }
        }
    }

    @discardableResult
    static func selectProviderModel(providerID: String,
                                    modelID: String,
                                    variantID: String? = nil) -> AppProviderCatalog {
        var catalog = providerCatalog
        guard let provider = catalog.providers.first(where: { $0.id == providerID }) else {
            return catalog
        }
        let models = catalog.inferenceModels(for: provider)
        let selectedModelID = models.first { $0.id == modelID }?.id
            ?? models.first?.id
            ?? defaultModel
        catalog.selectedProviderID = provider.id
        catalog.selectedModelID = selectedModelID
        catalog.selectedVariantID = models
            .first(where: { $0.id == selectedModelID })?
            .variants.first(where: { $0.id == variantID })?.id
        providerCatalog = catalog
        return providerCatalog
    }

    static var externalConfigDescription: String? {
        guard let url = existingConfigFileURL() else { return nil }
        return url.path
    }

    static var editableConfigDescription: String {
        if let existing = existingConfigFileURL(),
           configOverridePath() != nil || isModernConfigFile(existing) {
            return existing.path
        }
        return preferredConfigFileURL().path
    }

    static func prepareEditableConfigFile() throws -> URL {
        if let existing = existingConfigFileURL() {
            if configOverridePath() != nil || isModernConfigFile(existing) {
                return existing
            }
        }

        let preferred = preferredConfigFileURL()
        do {
            try writeConfigTemplate(to: preferred)
            return preferred
        } catch {
            if configOverridePath() != nil {
                throw error
            }
            let fallback = appSupportDir().appendingPathComponent(
                hostIdentity.configurationFileName)
            try writeConfigTemplate(to: fallback)
            return fallback
        }
    }

    @discardableResult
    static func writeEditableProviderConfig(catalog rawCatalog: AppProviderCatalog,
                                            apiKeysByProviderID: [String: String]) throws -> URL {
        let catalog = normalizedCatalog(rawCatalog)
        let apiKeys = normalizedAPIKeys(apiKeysByProviderID)
        let target = editableConfigFileURL()
        do {
            try writeProviderConfig(to: target,
                                    catalog: catalog,
                                    apiKeysByProviderID: apiKeys)
            return target
        } catch {
            if configOverridePath() != nil {
                throw error
            }
            let fallback = appSupportDir().appendingPathComponent(
                hostIdentity.configurationFileName)
            try writeProviderConfig(to: fallback,
                                    catalog: catalog,
                                    apiKeysByProviderID: apiKeys)
            return fallback
        }
    }

    static func appSupportDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(
            hostIdentity.storageName,
            isDirectory: true)
    }

    static func sessionFile(_ session: SessionID) -> URL {
        SessionHistoryStore.sessionFile(root: appSupportDir(), session: session)
    }

    static func artifactsDir(_ session: SessionID) -> URL {
        SessionHistoryStore.artifactsDir(root: appSupportDir(), session: session)
    }

    static func recentSessions(kind: SessionKind) -> [AppSessionSummary] {
        SessionActivityHistoryStore.recentSessions(
            root: appSupportDir(),
            kind: kind)
    }

    static func providerConfig() -> ProviderConfig {
        let catalog = providerCatalog
        let selectedProvider = catalog.selectedProvider ?? defaultProvider()
        let selectedModel = catalog.selectedModel
            ?? catalog.inferenceModels(for: selectedProvider).first
            ?? AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))

        let endpoints = catalog.providers.map { provider in
            ProviderEndpoint(
                id: provider.id,
                baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
                chatEndpoint: URL(string: provider.chatEndpoint),
                responsesEndpoint: provider.responsesEndpoint.flatMap { URL(string: $0) },
                apiKeyRef: apiKeyRef(for: provider),
                wire: .openai,
                requestAdapter:
                    provider.requestAdapter,
                modelRequestAdapters:
                    modelRequestAdapters(
                        for: provider),
                modelRequestOptions:
                    modelRequestOptions(
                        for: provider,
                        catalog: catalog),
                modelCapabilities:
                    modelCapabilities(for: provider))
        }
        let chat = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: selectedModel.id))
        var models = ResolvedModels(
            chat: chat,
            webSearch: catalog.webSearchModel,
            agent: chat,
            reviewer: catalog.permissionReviewerModel)
        // Image generation is an explicit role-specific route. Missing config
        // stays nil so the tool fails closed instead of selecting a hidden model.
        models.imageGen = catalog.imageModel
        // Composer voice input uses only the explicit host route. Missing
        // configuration stays nil and never falls back to the Chat selection.
        models.transcription = catalog.transcriptionModel
        models.embedding = catalog.embeddingModel
        models.reranker = catalog.rerankerModel
        return ProviderConfig(endpoints: endpoints.isEmpty ? [endpoint(for: selectedProvider)] : endpoints,
                              models: models)
    }

    static func newProvider() -> AppProviderSettings {
        let id = IDGen.random(prefix: "provider")
        return AppProviderSettings(
            id: id,
            displayName: "New Provider",
            baseURL: defaultBaseURL,
            apiKeyAccount: legacyAPIKeyAccount(forProviderID: id),
            models: [AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    static func normalizedCatalog(_ catalog: AppProviderCatalog) -> AppProviderCatalog {
        var seenProviders = Set<String>()
        var providers = catalog.providers.compactMap { provider -> AppProviderSettings? in
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenProviders.contains(id) else { return nil }
            seenProviders.insert(id)
            let isDedicatedRoleProvider = [
                catalog.permissionReviewerModel,
                catalog.imageModel,
                catalog.transcriptionModel,
                catalog.embeddingModel,
                catalog.rerankerModel,
            ].compactMap { $0 }.contains {
                normalizedProviderID($0.endpoint) == normalizedProviderID(id)
            }
            let isSelectedProvider = normalizedProviderID(catalog.selectedProviderID)
                == normalizedProviderID(id)

            let baseURL = baseURL(fromChatEndpoint: provider.baseURL)
            let rawChatEndpoint = provider.chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatEndpoint = rawChatEndpoint.isEmpty
                ? chatEndpoint(forBaseURL: baseURL)
                : rawChatEndpoint
            var seenModels = Set<String>()
            let models = provider.models.compactMap { model -> AppProviderModel? in
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelID.isEmpty, !seenModels.contains(modelID) else { return nil }
                seenModels.insert(modelID)
                return AppProviderModel(
                    id: modelID,
                    displayName: model.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    requestOptions: model.requestOptions,
                    configurationMetadata: model.configurationMetadata,
                    variants: model.variants)
            }
            guard !baseURL.isEmpty else { return nil }
            return AppProviderSettings(
                id: id,
                displayName: provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                npm: provider.npm,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                responsesEndpoint: provider.responsesEndpoint?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                apiKeyAccount: provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? legacyAPIKeyAccount(forProviderID: id)
                    : provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKeySource: provider.apiKeySource,
                models: models.isEmpty && (!isDedicatedRoleProvider || isSelectedProvider)
                    ? [AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))]
                    : models)
        }

        if providers.isEmpty {
            providers = [defaultProvider()]
        }

        let selectedProviderID = providers.first {
                $0.id == catalog.selectedProviderID
                    && !catalog.inferenceModels(for: $0).isEmpty
            }?.id
            ?? providers.first {
                normalizedProviderID($0.id) == normalizedProviderID(catalog.selectedProviderID)
                    && !catalog.inferenceModels(for: $0).isEmpty
            }?.id
            ?? providers.first {
                !catalog.inferenceModels(for: $0).isEmpty
            }?.id
            ?? providers[0].id
        let selectedProvider = providers.first { $0.id == selectedProviderID } ?? providers[0]
        let selectableModels = catalog.inferenceModels(for: selectedProvider)
        let selectedModelID = selectableModels.contains { $0.id == catalog.selectedModelID }
            ? catalog.selectedModelID
            : selectableModels.first?.id ?? defaultModel
        let selectedModel = selectableModels.first { $0.id == selectedModelID }
        let selectedVariantID = selectedModel?.variants
            .first(where: { $0.id == catalog.selectedVariantID })?.id
        let permissionReviewerFallback = ModelRef(
            endpoint: selectedProviderID,
            model: ModelID(rawValue: selectedModelID))
        let permissionReviewerModel = normalizedRoleModelRef(
            catalog.permissionReviewerModel
                // A nil marker means this is a legacy internal catalog that
                // predates the reviewer role. A parsed modern configuration
                // always writes true/false: false means the canonical field
                // was absent and its JSON top-level model was already resolved
                // (or proved unavailable) before UI selection is applied.
                ?? (catalog.permissionReviewerModelWasExplicitlyConfigured == nil
                    ? permissionReviewerFallback
                    : nil),
            providers: providers)
        let imageModel = normalizedRoleModelRef(
            catalog.imageModel,
            providers: providers)
        let transcriptionModel = normalizedRoleModelRef(
            catalog.transcriptionModel,
            providers: providers)
        let embeddingModel = normalizedRoleModelRef(
            catalog.embeddingModel,
            providers: providers)
        let rerankerModel = normalizedRoleModelRef(
            catalog.rerankerModel,
            providers: providers)
        let webSearchModel = normalizedRoleModelRef(
            catalog.webSearchModel,
            providers: providers)

        return AppProviderCatalog(
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            selectedVariantID: selectedVariantID,
            permissionReviewerModel: permissionReviewerModel,
            permissionReviewerModelWasExplicitlyConfigured:
                catalog.permissionReviewerModelWasExplicitlyConfigured ?? false,
            imageModel: imageModel,
            transcriptionModel: transcriptionModel,
            embeddingModel: embeddingModel,
            rerankerModel: rerankerModel,
            webSearchModel: webSearchModel,
            providers: providers)
    }

    private static func normalizedRoleModelRef(
        _ ref: ModelRef?,
        providers: [AppProviderSettings]
    ) -> ModelRef? {
        guard let ref else { return nil }
        let endpoint = ref.endpoint.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let model = ref.model.rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !model.isEmpty else { return nil }
        let actualEndpoint = providers.first { $0.id == endpoint }?.id
            ?? providers.first {
                normalizedProviderID($0.id)
                    == normalizedProviderID(endpoint)
            }?.id
            ?? endpoint
        return ModelRef(
            endpoint: actualEndpoint,
            model: ModelID(rawValue: model))
    }

    fileprivate static func variantSort(_ lhs: AppProviderModelVariant,
                                        _ rhs: AppProviderModelVariant) -> Bool {
        let ranks = [
            "none": 0,
            "minimal": 1,
            "low": 2,
            "medium": 3,
            "high": 4,
            "xhigh": 5,
            "max": 6,
        ]
        let left = lhs.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch (ranks[left], ranks[right]) {
        case let (leftRank?, rightRank?) where leftRank != rightRank:
            return leftRank < rightRank
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func legacyProviderCatalog() -> AppProviderCatalog {
        let baseURL = baseURL(fromChatEndpoint: UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL)
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        let provider = AppProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: baseURL,
            chatEndpoint: chatEndpoint(forBaseURL: baseURL),
            apiKeyAccount: legacyAPIKeyAccount,
            models: [AppProviderModel(id: model, displayName: defaultDisplayName(for: model))])
        return AppProviderCatalog(selectedProviderID: provider.id,
                                  selectedModelID: model,
                                  permissionReviewerModel: ModelRef(
                                      endpoint: provider.id,
                                      model: ModelID(rawValue: model)),
                                  permissionReviewerModelWasExplicitlyConfigured: false,
                                  providers: [provider])
    }

    private static func applyingStoredSelection(to catalog: AppProviderCatalog) -> AppProviderCatalog {
        guard let selection = storedSelection(),
              let provider = catalog.providers.first(where: { $0.id == selection.providerID }),
              catalog.inferenceModels(for: provider)
                .contains(where: { $0.id == selection.modelID }) else {
            return catalog
        }
        var selected = catalog
        selected.selectedProviderID = selection.providerID
        selected.selectedModelID = selection.modelID
        selected.selectedVariantID = catalog.inferenceModels(for: provider)
            .first(where: { $0.id == selection.modelID })?
            .variants.first(where: { $0.id == selection.variantID })?.id
        return selected
    }

    private static func storedSelection() -> AppProviderSelection? {
        guard let data = UserDefaults.standard.data(forKey: providerSelectionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AppProviderSelection.self, from: data)
    }

    private static func storeSelection(from catalog: AppProviderCatalog) {
        let selection = AppProviderSelection(providerID: catalog.selectedProviderID,
                                             modelID: catalog.selectedModelID,
                                             variantID: catalog.selectedVariantID)
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: providerSelectionKey)
        }
    }

    private static func defaultProvider() -> AppProviderSettings {
        AppProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: defaultBaseURL,
            apiKeyAccount: legacyAPIKeyAccount,
            models: [AppProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    private static func endpoint(for provider: AppProviderSettings) -> ProviderEndpoint {
        ProviderEndpoint(
            id: provider.id,
            baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
            chatEndpoint: URL(string: provider.chatEndpoint),
            responsesEndpoint: provider.responsesEndpoint.flatMap { URL(string: $0) },
            apiKeyRef: apiKeyRef(for: provider),
            wire: .openai,
            requestAdapter:
                provider.requestAdapter,
            modelRequestAdapters:
                modelRequestAdapters(
                    for: provider),
            modelRequestOptions:
                modelRequestOptions(
                    for: provider,
                    catalog: providerCatalog),
            modelCapabilities:
                modelCapabilities(for: provider))
    }

    private static func modelRequestOptions(for provider: AppProviderSettings,
                                            catalog: AppProviderCatalog)
        -> [String: [String: JSONValue]] {
        Dictionary(uniqueKeysWithValues: provider.models.compactMap { model in
            var options = model.requestOptions
            if provider.id == catalog.selectedProviderID,
               model.id == catalog.selectedModelID,
               let variant = catalog.selectedVariant {
                options = InferenceRequestOptionMerge
                    .deepOverlay([
                        options,
                        variant.requestOptions,
                    ])
            }
            return options.isEmpty ? nil : (model.id, options)
        })
    }

    private static func modelRequestAdapters(
        for provider: AppProviderSettings
    ) -> [String: ProviderRequestAdapter] {
        Dictionary(
            uniqueKeysWithValues:
                provider.models.compactMap { model in
                    model.requestAdapterOverride.map {
                        (model.id, $0)
                    }
                })
    }

    private static func modelCapabilities(
        for provider: AppProviderSettings
    ) -> [String: [Capability]] {
        Dictionary(uniqueKeysWithValues:
            provider.models.map {
                ($0.id, $0.declaredCapabilities)
            })
    }

    static func apiKeyRef(for provider: AppProviderSettings) -> KeychainRef {
        let configRef = KeychainRef.authFile(providerID: provider.id)
        return provider.apiKeySource?.ref(defaultRef: configRef, providerID: provider.id) ?? configRef
    }

    static func chatEndpoint(forBaseURL baseURL: String) -> String {
        let base = Self.baseURL(fromChatEndpoint: baseURL)
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            return base
        }
        return "\(trimTrailingPathSeparators(base))/chat/completions"
    }

    static func baseURL(fromChatEndpoint endpoint: String) -> String {
        let trimmed = trimTrailingPathSeparators(endpoint)
        let suffix = "/chat/completions"
        if trimmed.lowercased().hasSuffix(suffix) {
            return trimTrailingPathSeparators(String(trimmed.dropLast(suffix.count)))
        }
        return trimmed
    }

    static func defaultBaseURL(forProviderID providerID: String) -> String? {
        switch normalizedProviderID(providerID) {
        case "openai":
            return defaultBaseURL
        case "openrouter":
            return "https://openrouter.ai/api/v1"
        case "deepseek":
            return "https://api.deepseek.com/v1"
        case "ollama":
            return "http://localhost:11434/v1"
        case "lmstudio", "lm-studio":
            return "http://localhost:1234/v1"
        case "groq":
            return "https://api.groq.com/openai/v1"
        case "xai":
            return "https://api.x.ai/v1"
        case "together":
            return "https://api.together.xyz/v1"
        case "fireworks":
            return "https://api.fireworks.ai/inference/v1"
        case "cerebras":
            return "https://api.cerebras.ai/v1"
        case "moonshot":
            return "https://api.moonshot.ai/v1"
        default:
            return nil
        }
    }

    static func defaultProviderDisplayName(forProviderID providerID: String) -> String {
        switch normalizedProviderID(providerID) {
        case "openai":
            return "OpenAI"
        case "openrouter":
            return "OpenRouter"
        case "deepseek":
            return "DeepSeek"
        case "ollama":
            return "Ollama"
        case "lmstudio", "lm-studio":
            return "LM Studio"
        case "groq":
            return "Groq"
        case "xai":
            return "xAI"
        case "together":
            return "Together AI"
        case "fireworks":
            return "Fireworks AI"
        case "cerebras":
            return "Cerebras"
        case "moonshot":
            return "Moonshot AI"
        default:
            return providerID
        }
    }

    static func defaultAPIKeyConfigValue(forProviderID providerID: String) -> String {
        let normalized = normalizedProviderID(providerID)
        let name: String
        switch normalized {
        case "default", "openai":
            name = "OPENAI_API_KEY"
        case "openrouter":
            name = "OPENROUTER_API_KEY"
        case "deepseek":
            name = "DEEPSEEK_API_KEY"
        case "groq":
            name = "GROQ_API_KEY"
        case "xai":
            name = "XAI_API_KEY"
        case "together":
            name = "TOGETHER_API_KEY"
        case "fireworks":
            name = "FIREWORKS_API_KEY"
        case "cerebras":
            name = "CEREBRAS_API_KEY"
        case "moonshot":
            name = "MOONSHOT_API_KEY"
        default:
            let suffix = providerID.uppercased().map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
            name = "\(String(suffix))_API_KEY"
        }
        return "{env:\(name)}"
    }

    private static func trimTrailingPathSeparators(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") && !result.hasSuffix("://") {
            result.removeLast()
        }
        return result
    }

    private static func legacyAPIKeyAccount(forProviderID providerID: String) -> String {
        providerID == defaultProviderID ? legacyAPIKeyAccount : "provider-\(providerID)"
    }

    static func defaultDisplayName(for modelID: String) -> String {
        switch modelID {
        case "gpt-4o-mini":
            return "GPT-4o mini"
        case "gpt-4o":
            return "GPT-4o"
        default:
            return modelID
        }
    }

    private static func fileProviderCatalog() -> AppProviderCatalog? {
        guard let url = existingConfigFileURL() else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return catalogWithPermissionReviewerFailedClosed()
        }
        let configData = jsonCompatibleData(from: data)
        let decoder = JSONDecoder()
        let permissionReviewerFieldWasPresent: Bool?
        if case .object(let root)? = try? decoder.decode(
            JSONValue.self,
            from: configData) {
            permissionReviewerFieldWasPresent =
                root.keys.contains("permission_reviewer_model")
        } else {
            permissionReviewerFieldWasPresent = nil
        }
        if let compatible = try? decoder.decode(
            AppProviderConfigFile.self,
            from: configData),
           let catalog = compatible.catalog(
               configFileURL: url,
               permissionReviewerFieldWasPresent:
                   permissionReviewerFieldWasPresent) {
            return catalog
        }
        if permissionReviewerFieldWasPresent != true,
           let direct = try? decoder.decode(
            AppProviderCatalog.self,
            from: configData) {
            return direct
        }
        // A selected configuration file that cannot produce a catalog cannot
        // prove either the canonical reviewer value or its top-level-model
        // compatibility source. Preserve the app's existing cached-provider
        // fallback for ordinary data-plane use, but leave this authorization
        // role explicitly unavailable instead of retargeting it to stale UI or
        // @main state.
        return catalogWithPermissionReviewerFailedClosed()
    }

    private static func catalogWithPermissionReviewerFailedClosed()
        -> AppProviderCatalog {
        let fallback: AppProviderCatalog
        if let data = UserDefaults.standard.data(forKey: providerCatalogKey),
           let decoded = try? JSONDecoder().decode(
            AppProviderCatalog.self,
            from: data) {
            fallback = decoded
        } else {
            fallback = legacyProviderCatalog()
        }
        var failClosed = fallback
        failClosed.permissionReviewerModel = nil
        failClosed.permissionReviewerModelWasExplicitlyConfigured = true
        return failClosed
    }

    private static func existingConfigFileURL() -> URL? {
        for url in configFileCandidates() where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func configFileCandidates() -> [URL] {
        if configOverridePath() != nil {
            return [preferredConfigFileURL()]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userConfigDir = hostIdentity.userConfigurationDirectory(
            homeDirectory: home)
        return [
            userConfigDir.appendingPathComponent(
                hostIdentity.configurationFileName),
            userConfigDir.appendingPathComponent(
                hostIdentity.configurationJSONCFileName),
            appSupportDir().appendingPathComponent(
                hostIdentity.configurationFileName),
            appSupportDir().appendingPathComponent(
                hostIdentity.configurationJSONCFileName),
            userConfigDir.appendingPathComponent("config.json"),
            userConfigDir.appendingPathComponent("config.jsonc"),
            appSupportDir().appendingPathComponent("config.json"),
            appSupportDir().appendingPathComponent("config.jsonc"),
        ]
    }

    private static func preferredConfigFileURL() -> URL {
        if let override = configOverridePath() {
            return URL(fileURLWithPath: expandedPath(override))
        }
        return hostIdentity.userConfigurationDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(hostIdentity.configurationFileName)
    }

    private static func isModernConfigFile(_ url: URL) -> Bool {
        url.lastPathComponent == hostIdentity.configurationFileName
            || url.lastPathComponent
                == hostIdentity.configurationJSONCFileName
    }

    private static func configOverridePath() -> String? {
        let trimmed = ProcessInfo.processInfo.environment[configEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func editableConfigFileURL() -> URL {
        if let existing = existingConfigFileURL(),
           configOverridePath() != nil || isModernConfigFile(existing) {
            return existing
        }
        return preferredConfigFileURL()
    }

    private static func writeConfigTemplate(to url: URL) throws {
        try writeConfigTemplate(to: url,
                                catalog: normalizedCatalog(providerCatalog),
                                apiKeysByProviderID: [:])
    }

    private static func writeConfigTemplate(to url: URL,
                                            catalog: AppProviderCatalog,
                                            apiKeysByProviderID: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            AppProviderConfigTemplate(catalog: catalog,
                                      apiKeysByProviderID: apiKeysByProviderID))
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeProviderConfig(to url: URL,
                                            catalog: AppProviderCatalog,
                                            apiKeysByProviderID: [String: String]) throws {
        if FileManager.default.fileExists(atPath: url.path),
           var object = existingProviderConfigObject(from: url) {
            applyProviderConfig(catalog: catalog,
                                apiKeysByProviderID: apiKeysByProviderID,
                                to: &object)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        try writeConfigTemplate(to: url,
                                catalog: catalog,
                                apiKeysByProviderID: apiKeysByProviderID)
    }

    private static func existingProviderConfigObject(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let configData = jsonCompatibleData(from: data)
        guard let object = try? JSONSerialization.jsonObject(with: configData),
              let root = object as? [String: Any] else {
            return nil
        }
        return root
    }

    private static func applyProviderConfig(catalog: AppProviderCatalog,
                                            apiKeysByProviderID: [String: String],
                                            to root: inout [String: Any]) {
        let existingAPIKeys = existingAPIKeyValues(in: root)
        root.removeValue(forKey: "providers")
        root["$schema"] = "https://opencode.ai/config.json"
        root["enabled_providers"] = catalog.providers.map(\.id)
        root["model"] = selectedOpenCodeModel(in: catalog)
        if let permissionReviewerModel = catalog.permissionReviewerModel {
            root["permission_reviewer_model"] = openCodeModelReference(
                permissionReviewerModel)
        } else {
            // Nil is a fail-closed authorization state even when the source
            // key was merely absent but its top-level compatibility model
            // could not be proved. Persist null so rewriting the ordinary
            // selected model cannot silently enable review on the next load.
            root["permission_reviewer_model"] = NSNull()
        }
        if let imageModel = catalog.imageModel {
            root.removeValue(forKey: "imageModel")
            root["image_model"] = openCodeModelReference(imageModel)
        }
        if let transcriptionModel = catalog.transcriptionModel {
            root["transcription_model"] = openCodeModelReference(
                transcriptionModel)
        } else {
            root.removeValue(forKey: "transcription_model")
        }
        if let embeddingModel = catalog.embeddingModel {
            root["embedding_model"] = openCodeModelReference(
                embeddingModel)
        } else {
            root.removeValue(forKey: "embedding_model")
        }
        if let rerankerModel = catalog.rerankerModel {
            root["reranker_model"] = openCodeModelReference(
                rerankerModel)
        } else {
            root.removeValue(forKey: "reranker_model")
        }

        var providerMap = root["provider"] as? [String: Any] ?? [:]
        for provider in catalog.providers {
            var providerObject = providerMap[provider.id] as? [String: Any] ?? [:]
            providerObject["npm"] =
                provider.requestAdapter.rawValue
            providerObject["name"] = provider.title

            var options = providerObject["options"] as? [String: Any] ?? [:]
            options["baseURL"] = provider.baseURL
            let chatEndpoint = provider.chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chatEndpoint.isEmpty, chatEndpoint != AppConfig.chatEndpoint(forBaseURL: provider.baseURL) {
                options["chatEndpoint"] = chatEndpoint
            } else {
                options.removeValue(forKey: "chatEndpoint")
            }
            if let responsesEndpoint = provider.responsesEndpoint?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !responsesEndpoint.isEmpty {
                options["responsesEndpoint"] = responsesEndpoint
            }
            options["apiKey"] = apiKeyConfigValue(
                for: provider,
                explicitAPIKeys: apiKeysByProviderID,
                existingAPIKeys: existingAPIKeys)
            providerObject["options"] = options

            let existingModels = providerObject["models"] as? [String: Any] ?? [:]
            providerObject["models"] = modelConfigValues(for: provider, existingModels: existingModels)
            providerMap[provider.id] = providerObject
        }
        root["provider"] = providerMap
    }

    private static func selectedOpenCodeModel(in catalog: AppProviderCatalog) -> String {
        let selectedProvider = catalog.providers.first { $0.id == catalog.selectedProviderID }
            ?? catalog.providers.first
        guard let selectedProvider else { return defaultModel }
        let models = catalog.inferenceModels(for: selectedProvider)
        let selectedModel = models.first { $0.id == catalog.selectedModelID }
            ?? models.first
        return "\(selectedProvider.id)/\(selectedModel?.id ?? defaultModel)"
    }

    private static func openCodeModelReference(_ ref: ModelRef) -> String {
        "\(ref.endpoint)/\(ref.model.rawValue)"
    }

    private static func modelConfigValues(for provider: AppProviderSettings,
                                          existingModels: [String: Any]) -> [String: Any] {
        var models: [String: Any] = [:]
        for model in provider.models {
            var object = existingModels[model.id] as? [String: Any] ?? [:]
            object["name"] = model.title
            models[model.id] = object
        }
        return models
    }

    private static func apiKeyConfigValue(for provider: AppProviderSettings,
                                          explicitAPIKeys: [String: String],
                                          existingAPIKeys: [String: String]) -> String {
        if let explicit = value(in: explicitAPIKeys, providerID: provider.id) {
            return explicit
        }
        if let existing = value(in: existingAPIKeys, providerID: provider.id) {
            return existing
        }
        return provider.apiKeySource?.openCodeAPIKeyValue
            ?? defaultAPIKeyConfigValue(forProviderID: provider.id)
    }

    private static func existingAPIKeyValues(in root: [String: Any]) -> [String: String] {
        guard let providerMap = root["provider"] as? [String: Any] else { return [:] }
        var values: [String: String] = [:]
        for (providerID, rawProvider) in providerMap {
            guard let providerObject = rawProvider as? [String: Any] else { continue }
            let optionValue = (providerObject["options"] as? [String: Any])?["apiKey"] as? String
            let directValue = providerObject["apiKey"] as? String
            if let value = nonEmpty(optionValue ?? directValue) {
                values[providerID] = value
            }
        }
        return values
    }

    private static func normalizedAPIKeys(_ apiKeysByProviderID: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (providerID, rawKey) in apiKeysByProviderID {
            guard let id = nonEmpty(providerID),
                  let key = nonEmpty(rawKey) else {
                continue
            }
            result[id] = key
        }
        return result
    }

    private static func value(in map: [String: String], providerID: String) -> String? {
        if let exact = nonEmpty(map[providerID]) { return exact }
        let normalized = normalizedProviderID(providerID)
        return map.first {
            normalizedProviderID($0.key) == normalized
        }.flatMap { nonEmpty($0.value) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func jsonCompatibleData(from data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let stripped = stripTrailingCommas(from: stripJSONComments(from: text))
        return Data(stripped.utf8)
    }

    private static func stripJSONComments(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = next
                continue
            }

            if character == "/", next < text.endIndex {
                let nextCharacter = text[next]
                if nextCharacter == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    if index < text.endIndex {
                        output.append("\n")
                        index = text.index(after: index)
                    }
                    continue
                }
                if nextCharacter == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let current = text[index]
                        let lookahead = text.index(after: index)
                        if current == "\n" { output.append("\n") }
                        if current == "*", lookahead < text.endIndex, text[lookahead] == "/" {
                            index = text.index(after: lookahead)
                            break
                        }
                        index = lookahead
                    }
                    continue
                }
            }

            output.append(character)
            index = next
        }
        return output
    }

    private static func stripTrailingCommas(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "," {
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex, text[lookahead].isWhitespace {
                    lookahead = text.index(after: lookahead)
                }
                if lookahead < text.endIndex,
                   text[lookahead] == "}" || text[lookahead] == "]" {
                    index = text.index(after: index)
                    continue
                }
            }

            output.append(character)
            index = text.index(after: index)
        }
        return output
    }

    private static func normalizedProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == "~" { return home }
        return home + String(trimmed.dropFirst())
    }

}

private struct AppProviderConfigTemplate: Encodable {
    var schema = "https://opencode.ai/config.json"
    var enabledProviders: [String]
    var model: String
    var permissionReviewerModel: JSONValue?
    var imageModel: String?
    var transcriptionModel: String?
    var embeddingModel: String?
    var rerankerModel: String?
    var provider: [String: AppProviderConfigTemplateProvider]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case enabledProviders = "enabled_providers"
        case model
        case permissionReviewerModel = "permission_reviewer_model"
        case imageModel = "image_model"
        case transcriptionModel = "transcription_model"
        case embeddingModel = "embedding_model"
        case rerankerModel = "reranker_model"
        case provider
    }

    init(catalog: AppProviderCatalog,
         apiKeysByProviderID: [String: String] = [:]) {
        self.enabledProviders = catalog.providers.map(\.id)
        let selectedProvider = catalog.providers.first { $0.id == catalog.selectedProviderID }
            ?? catalog.providers.first
        if let selectedProvider {
            let models = catalog.inferenceModels(for: selectedProvider)
            let selectedModel = models.first { $0.id == catalog.selectedModelID }
                ?? models.first
            let modelID = selectedModel?.id ?? AppConfig.defaultModel
            self.model = "\(selectedProvider.id)/\(modelID)"
        } else {
            self.model = AppConfig.defaultModel
        }
        if let reviewer = catalog.permissionReviewerModel {
            self.permissionReviewerModel = .string(
                "\(reviewer.endpoint)/\(reviewer.model.rawValue)")
        } else {
            // Preserve every unresolved authorization route as explicit null.
            // Omitting the key after rewriting the ordinary selected model
            // would turn a fail-closed state into compatibility inheritance on
            // the next launch.
            self.permissionReviewerModel = .null
        }
        self.imageModel = catalog.imageModel.map {
            "\($0.endpoint)/\($0.model.rawValue)"
        }
        self.transcriptionModel = catalog.transcriptionModel.map {
            "\($0.endpoint)/\($0.model.rawValue)"
        }
        self.embeddingModel = catalog.embeddingModel.map {
            "\($0.endpoint)/\($0.model.rawValue)"
        }
        self.rerankerModel = catalog.rerankerModel.map {
            "\($0.endpoint)/\($0.model.rawValue)"
        }
        self.provider = Dictionary(uniqueKeysWithValues: catalog.providers.map { provider in
            (provider.id, AppProviderConfigTemplateProvider(
                provider: provider,
                apiKey: apiKeysByProviderID[provider.id]))
        })
    }
}

private struct AppProviderConfigTemplateProvider: Encodable {
    var npm: String
    var name: String
    var options: AppProviderConfigTemplateOptions
    var models: [String: AppProviderConfigTemplateModel]

    init(provider: AppProviderSettings, apiKey: String?) {
        self.npm = provider.requestAdapter.rawValue
        self.name = provider.title
        self.options = AppProviderConfigTemplateOptions(provider: provider, apiKey: apiKey)
        self.models = Dictionary(uniqueKeysWithValues: provider.models.map { model in
            (model.id, AppProviderConfigTemplateModel(name: model.title))
        })
    }
}

private struct AppProviderConfigTemplateOptions: Encodable {
    var baseURL: String
    var responsesEndpoint: String?
    var apiKey: String?

    init(provider: AppProviderSettings, apiKey: String?) {
        self.baseURL = provider.baseURL
        let responsesEndpoint = provider.responsesEndpoint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.responsesEndpoint = responsesEndpoint?.isEmpty == false
            ? responsesEndpoint
            : nil
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            self.apiKey = trimmed
        } else {
            self.apiKey = provider.apiKeySource?.openCodeAPIKeyValue
                ?? AppConfig.defaultAPIKeyConfigValue(forProviderID: provider.id)
        }
    }
}

private struct AppProviderConfigTemplateModel: Encodable {
    var name: String
}

private struct AppProviderConfigFile: Decodable {
    var selectedProviderID: String?
    var selectedModelID: String?
    var selectedVariantID: String?
    var model: String?
    var smallModel: String?
    var small_model: String?
    var permission_reviewer_model: JSONValue?
    var imageModel: String?
    var image_model: String?
    var transcription_model: String?
    var embedding_model: String?
    var reranker_model: String?
    var webSearchModel: String?
    var web_search_model: String?
    var enabledProviders: [String]?
    var enabled_providers: [String]?
    var disabledProviders: [String]?
    var disabled_providers: [String]?
    var providers: [AppProviderSettings]?
    var provider: [String: AppProviderConfigFileProvider]?

    func catalog(
        configFileURL: URL?,
        permissionReviewerFieldWasPresent: Bool? = nil
    ) -> AppProviderCatalog? {
        let configDirectory = configFileURL?.deletingLastPathComponent()
        var entries = providers ?? []
        let enabled = enabledProviders ?? enabled_providers
        let disabled = disabledProviders ?? disabled_providers
        let resolvedModel = resolvedConfigValue(model ?? smallModel ?? small_model,
                                                configDirectory: configDirectory)
        let permissionReviewerWasExplicitlyConfigured =
            permissionReviewerFieldWasPresent
                ?? (permission_reviewer_model != nil)
        let rawPermissionReviewerModel: String?
        if case .string(let value)? = permission_reviewer_model {
            rawPermissionReviewerModel = value
        } else {
            rawPermissionReviewerModel = nil
        }
        let resolvedPermissionReviewerModel = resolvedConfigValue(
            permissionReviewerWasExplicitlyConfigured
                ? rawPermissionReviewerModel
                : resolvedModel,
            configDirectory: configDirectory)
        let resolvedImageModel = resolvedConfigValue(
            image_model ?? imageModel,
            configDirectory: configDirectory)
        let resolvedTranscriptionModel = resolvedConfigValue(
            transcription_model,
            configDirectory: configDirectory)
        let resolvedEmbeddingModel = resolvedConfigValue(
            embedding_model,
            configDirectory: configDirectory)
        let resolvedRerankerModel = resolvedConfigValue(
            reranker_model,
            configDirectory: configDirectory)
        let resolvedWebSearchModel = resolvedConfigValue(
            webSearchModel ?? web_search_model,
            configDirectory: configDirectory)
        let split = splitModel(resolvedModel)
        let permissionReviewerSplit = splitModel(
            resolvedPermissionReviewerModel)
        let imageSplit = splitModel(resolvedImageModel)
        let transcriptionSplit = splitModel(resolvedTranscriptionModel)
        let embeddingSplit = splitModel(resolvedEmbeddingModel)
        let rerankerSplit = splitModel(resolvedRerankerModel)
        if !entries.isEmpty {
            entries = entries.filter {
                shouldIncludeProvider(id: $0.id, enabled: enabled, disabled: disabled)
            }
        }
        if entries.isEmpty, let provider {
            entries = provider.keys.sorted().compactMap { id in
                guard shouldIncludeProvider(id: id, enabled: enabled, disabled: disabled) else {
                    return nil
                }
                return provider[id]?.settings(
                    id: id,
                    selectedModelID: providerIDsMatch(split.providerID, id) ? split.modelID : nil,
                    allowsEmptyModels:
                        providerIDsMatch(
                            permissionReviewerSplit.providerID,
                            id)
                        || providerIDsMatch(imageSplit.providerID, id)
                        || providerIDsMatch(
                            transcriptionSplit.providerID,
                            id)
                        || providerIDsMatch(
                            embeddingSplit.providerID,
                            id)
                        || providerIDsMatch(
                            rerankerSplit.providerID,
                            id),
                    configDirectory: configDirectory,
                    configFileURL: configFileURL)
            }
        }
        if entries.isEmpty,
           let providerID = split.providerID,
           let modelID = split.modelID,
           shouldIncludeProvider(id: providerID, enabled: enabled, disabled: disabled),
           let fallback = fallbackProviderSettings(id: providerID, modelID: modelID) {
            entries = [fallback]
        }
        guard !entries.isEmpty else { return nil }

        // OpenAI-compatible model IDs commonly contain `/` themselves. Prefer
        // an exact model-key match across the enabled provider set before
        // interpreting the first path component as an Intatis provider ID.
        let exactModel = exactModelSelection(resolvedModel, in: entries)
        let configuredProviderID = exactModel?.providerID ?? split.providerID
        let configuredModelID = exactModel?.modelID ?? split.modelID

        if let providerID = configuredProviderID,
           let modelID = configuredModelID,
           let actualProviderID = actualProviderID(matching: providerID, in: entries),
           let index = entries.firstIndex(where: { $0.id == actualProviderID }),
           !entries[index].models.contains(where: { $0.id == modelID }) {
            entries[index].models.append(
                AppProviderModel(id: modelID,
                                 displayName: AppConfig.defaultDisplayName(for: modelID)))
        }
        let selectedProvider = actualProviderID(matching: selectedProviderID, in: entries)
            ?? actualProviderID(matching: configuredProviderID, in: entries)
            ?? entries[0].id
        let selectedModel = selectedModelID
            ?? configuredModelID
            ?? entries.first(where: { $0.id == selectedProvider })?.models.first?.id
            ?? entries[0].models.first?.id
            ?? AppConfig.defaultModel
        let permissionReviewerRef: ModelRef?
        if permissionReviewerWasExplicitlyConfigured {
            permissionReviewerRef = explicitProviderModelRef(
                resolvedPermissionReviewerModel,
                entries: entries)
        } else if let configuredProviderID,
                  let configuredModelID,
                  let actualProviderID = actualProviderID(
                      matching: configuredProviderID,
                      in: entries) {
            // Compatibility follows the JSON document's resolved top-level
            // model selection exactly once, including a uniquely resolvable
            // unqualified model ID. It never consults the later UI selection.
            permissionReviewerRef = ModelRef(
                endpoint: actualProviderID,
                model: ModelID(rawValue: configuredModelID))
        } else {
            permissionReviewerRef = nil
        }
        if let permissionReviewerRef,
           let actualProviderID = actualProviderID(
               matching: permissionReviewerRef.endpoint,
               in: entries),
           let index = entries.firstIndex(where: {
               $0.id == actualProviderID
           }),
           !entries[index].models.contains(where: {
               $0.id == permissionReviewerRef.model.rawValue
           }) {
            entries[index].models.append(AppProviderModel(
                id: permissionReviewerRef.model.rawValue,
                displayName: AppConfig.defaultDisplayName(
                    for: permissionReviewerRef.model.rawValue)))
        }
        let imageRef = backgroundModelRef(
            resolvedImageModel,
            preferredProviderID: selectedProvider,
            entries: entries)
        let transcriptionRef = backgroundModelRef(
            resolvedTranscriptionModel,
            preferredProviderID: selectedProvider,
            entries: entries)
        let embeddingRef = knowledgeModelRef(
            resolvedEmbeddingModel,
            entries: entries)
        let rerankerRef = knowledgeModelRef(
            resolvedRerankerModel,
            entries: entries)
        let webSearchRef = backgroundModelRef(
            resolvedWebSearchModel,
            preferredProviderID: selectedProvider,
            entries: entries)

        return AppProviderCatalog(selectedProviderID: selectedProvider,
                                  selectedModelID: selectedModel,
                                  selectedVariantID: selectedVariantID,
                                  permissionReviewerModel: permissionReviewerRef,
                                  permissionReviewerModelWasExplicitlyConfigured:
                                      permissionReviewerWasExplicitlyConfigured,
                                  imageModel: imageRef,
                                  transcriptionModel: transcriptionRef,
                                  embeddingModel: embeddingRef,
                                  rerankerModel: rerankerRef,
                                  webSearchModel: webSearchRef,
                                  providers: entries)
    }

    private func backgroundModelRef(
        _ raw: String?,
        preferredProviderID: String,
        entries: [AppProviderSettings]
    ) -> ModelRef? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let selection: (providerID: String, modelID: String)
        if let exact = exactModelSelection(raw, in: entries) {
            selection = exact
        } else {
            let split = splitModel(raw)
            if let providerID = split.providerID,
               let modelID = split.modelID {
                selection = (providerID, modelID)
            } else {
                selection = (preferredProviderID, raw)
            }
        }

        let endpointID = actualProviderID(
            matching: selection.providerID,
            in: entries) ?? selection.providerID
        return ModelRef(
            endpoint: endpointID,
            model: ModelID(rawValue: selection.modelID))
    }

    /// Authorization-role routes must name an enabled provider explicitly.
    /// Unlike the ordinary background-role parser, this never borrows the
    /// mutable selected provider for an unqualified value.
    private func explicitProviderModelRef(
        _ raw: String?,
        entries: [AppProviderSettings]
    ) -> ModelRef? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        for entry in entries.sorted(by: { $0.id.count > $1.id.count }) {
            let prefix = entry.id + "/"
            guard raw.hasPrefix(prefix) else { continue }
            let modelID = String(raw.dropFirst(prefix.count))
            guard !modelID.isEmpty,
                  entry.models.contains(where: { $0.id == modelID }) else {
                return nil
            }
            return ModelRef(
                endpoint: entry.id,
                model: ModelID(rawValue: modelID))
        }
        return nil
    }

    /// Knowledge roles never inherit the currently selected Chat provider.
    /// Only the canonical `<provider-id>/<model-id>` spelling produces a
    /// binding; malformed or unqualified values leave the tools unavailable.
    private func knowledgeModelRef(
        _ raw: String?,
        entries: [AppProviderSettings]
    ) -> ModelRef? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let split = splitModel(raw)
        guard let providerID = split.providerID,
              let modelID = split.modelID,
              !providerID.isEmpty,
              !modelID.isEmpty else {
            return nil
        }
        let endpointID = actualProviderID(
            matching: providerID,
            in: entries) ?? providerID
        return ModelRef(
            endpoint: endpointID,
            model: ModelID(rawValue: modelID))
    }

    private func fallbackProviderSettings(id: String, modelID: String) -> AppProviderSettings? {
        guard let baseURL = AppConfig.defaultBaseURL(forProviderID: id) else { return nil }
        return AppProviderSettings(
            id: id,
            displayName: AppConfig.defaultProviderDisplayName(forProviderID: id),
            baseURL: baseURL,
            apiKeyAccount: id == "default" ? AppConfig.legacyAPIKeyAccount : "provider-\(id)",
            models: [AppProviderModel(id: modelID,
                                      displayName: AppConfig.defaultDisplayName(for: modelID))])
    }

    private func splitModel(_ raw: String?) -> (providerID: String?, modelID: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return (nil, nil)
        }
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return (nil, raw)
        }
        return (String(parts[0]), String(parts[1]))
    }

    private func exactModelSelection(_ raw: String?,
                                     in entries: [AppProviderSettings])
        -> (providerID: String, modelID: String)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let matches = entries.filter { provider in
            provider.models.contains { $0.id == raw }
        }
        if let selectedProviderID,
           let selected = matches.first(where: {
               normalizedProviderID($0.id) == normalizedProviderID(selectedProviderID)
           }) {
            return (selected.id, raw)
        }
        guard matches.count == 1, let provider = matches.first else { return nil }
        return (provider.id, raw)
    }

    private func shouldIncludeProvider(id: String,
                                       enabled: [String]?,
                                       disabled: [String]?) -> Bool {
        let normalizedID = normalizedProviderID(id)
        let disabledIDs = Set((disabled ?? []).map(normalizedProviderID))
        if disabledIDs.contains(normalizedID) { return false }

        let enabledIDs = Set((enabled ?? []).map(normalizedProviderID))
        if enabledIDs.isEmpty { return true }
        return enabledIDs.contains(normalizedID)
    }

    private func providerIDsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return normalizedProviderID(lhs) == normalizedProviderID(rhs)
    }

    private func actualProviderID(matching candidate: String?, in entries: [AppProviderSettings]) -> String? {
        guard let candidate else { return nil }
        if let exact = entries.first(where: { $0.id == candidate })?.id {
            return exact
        }
        let normalizedCandidate = normalizedProviderID(candidate)
        return entries.first { normalizedProviderID($0.id) == normalizedCandidate }?.id
    }

    private func normalizedProviderID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct AppProviderConfigFileProvider: Decodable {
    var api: String?
    var env: [String]?
    var npm: String?
    var name: String?
    var displayName: String?
    var baseURL: String?
    var chatEndpoint: String?
    var responsesEndpoint: String?
    var apiKey: String?
    var apiKeyAccount: String?
    var apiKeySource: AppProviderAPIKeySource?
    var apiKeyEnv: String?
    var apiKeyFile: String?
    var options: AppProviderConfigFileOptions?
    var models: [String: AppProviderConfigFileModel]?

    func settings(id: String,
                  selectedModelID: String?,
                  allowsEmptyModels: Bool,
                  configDirectory: URL?,
                  configFileURL: URL?) -> AppProviderSettings? {
        let base = options?.baseURL ?? baseURL ?? AppConfig.defaultBaseURL(forProviderID: id)
        guard let base, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var source: AppProviderAPIKeySource?
        source = source ?? apiKeySource
        source = source ?? options?.apiKeySource
        source = source ?? parsedAPIKeySource(from: options?.apiKey, configDirectory: configDirectory)
        source = source ?? providerConfigAPIKeySource(from: options?.apiKey, configFileURL: configFileURL)
        source = source ?? parsedAPIKeySource(from: apiKey, configDirectory: configDirectory)
        source = source ?? providerConfigAPIKeySource(from: apiKey, configFileURL: configFileURL)
        if source == nil, let apiKeyEnv {
            source = AppProviderAPIKeySource.environment(apiKeyEnv)
        }
        if source == nil, let optionAPIKeyEnv = options?.apiKeyEnv {
            source = AppProviderAPIKeySource.environment(optionAPIKeyEnv)
        }
        if source == nil, let firstEnv = env?.first {
            source = AppProviderAPIKeySource.environment(firstEnv)
        }
        if source == nil, let apiKeyFile {
            source = AppProviderAPIKeySource.file(apiKeyFile)
        }
        if source == nil, let optionAPIKeyFile = options?.apiKeyFile {
            source = AppProviderAPIKeySource.file(optionAPIKeyFile)
        }
        var modelList = models?.keys.sorted().compactMap { modelID -> AppProviderModel? in
            guard let model = models?[modelID] else { return nil }
            return AppProviderModel(id: model.id ?? modelID,
                                    displayName: model.displayName ?? model.name ?? modelID,
                                    requestOptions: model.options ?? [:],
                                    configurationMetadata: model.rawConfiguration,
                                    variants: model.variants)
        } ?? []
        if let selectedModelID,
           !modelList.contains(where: { $0.id == selectedModelID }) {
            modelList.append(AppProviderModel(
                id: selectedModelID,
                displayName: AppConfig.defaultDisplayName(for: selectedModelID)))
        }
        return AppProviderSettings(
            id: id,
            displayName: displayName ?? name ?? AppConfig.defaultProviderDisplayName(forProviderID: id),
            npm: ProviderRequestAdapter
                .configuredProvider(npm).rawValue,
            baseURL: base,
            chatEndpoint: options?.chatEndpoint ?? chatEndpoint,
            responsesEndpoint: options?.responsesEndpoint ?? responsesEndpoint,
            apiKeyAccount: apiKeyAccount ?? (id == "default" ? AppConfig.legacyAPIKeyAccount : "provider-\(id)"),
            apiKeySource: source?.isLegacyKeychain == true ? nil : source,
            models: modelList.isEmpty && !allowsEmptyModels
                ? [AppProviderModel(id: AppConfig.defaultModel, displayName: AppConfig.defaultModel)]
                : modelList)
    }
}

private struct AppProviderConfigFileOptions: Decodable {
    var apiKey: String?
    var baseURL: String?
    var chatEndpoint: String?
    var responsesEndpoint: String?
    var apiKeySource: AppProviderAPIKeySource?
    var apiKeyEnv: String?
    var apiKeyFile: String?
}

private struct AppProviderConfigFileModel: Decodable {
    var id: String?
    var name: String?
    var displayName: String?
    var options: [String: JSONValue]?
    var rawConfiguration: [String: JSONValue]
    var variants: [AppProviderModelVariant]

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self.id = nil
            self.name = value
            self.displayName = value
            self.options = nil
            self.rawConfiguration = ["name": .string(value)]
            self.variants = []
            return
        }
        let value = try decoder.singleValueContainer().decode(JSONValue.self)
        guard case .object(let object) = value else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Model configuration must be a string or JSON object"))
        }
        self.id = object.string(forKey: "id")
        self.name = object.string(forKey: "name")
        self.displayName = object.string(forKey: "displayName")
        if case .object(let options) = object["options"] {
            self.options = options
        } else {
            self.options = nil
        }
        self.rawConfiguration = object
        if case .object(let variants) = object["variants"] {
            self.variants = variants.compactMap { variantID, value in
                guard case .object(var variantObject) = value,
                      variantObject["disabled"] != .bool(true) else {
                    return nil
                }
                variantObject.removeValue(forKey: "disabled")
                return AppProviderModelVariant(
                    id: variantID,
                    requestOptions: variantObject,
                    configurationMetadata: variantObject)
            }
            .sorted(by: AppConfig.variantSort)
        } else {
            self.variants = []
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(forKey key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }
}

private func resolvedConfigValue(_ raw: String?, configDirectory: URL?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else {
        return nil
    }
    guard let variable = configVariable(in: raw) else { return raw }
    switch variable.kind {
    case "env":
        return ProcessInfo.processInfo.environment[variable.value]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    case "file":
        let path = resolvedConfigFilePath(variable.value, configDirectory: configDirectory)
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    default:
        return raw
    }
}

private func parsedAPIKeySource(from raw: String?, configDirectory: URL?) -> AppProviderAPIKeySource? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let variable = configVariable(in: raw) else {
        return nil
    }
    switch variable.kind {
    case "env":
        return AppProviderAPIKeySource.environment(variable.value)
    case "file":
        return AppProviderAPIKeySource.file(
            resolvedConfigFilePath(variable.value, configDirectory: configDirectory))
    default:
        return nil
    }
}

private func providerConfigAPIKeySource(from raw: String?, configFileURL: URL?) -> AppProviderAPIKeySource? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          configVariable(in: raw) == nil,
          let path = configFileURL?.path,
          !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return AppProviderAPIKeySource.providerConfig(path)
}

private func configVariable(in raw: String) -> (kind: String, value: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
    let body = trimmed.dropFirst().dropLast()
    guard let separator = body.firstIndex(of: ":") else { return nil }
    let kind = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kind.isEmpty, !value.isEmpty else { return nil }
    return (kind, value)
}

private func resolvedConfigFilePath(_ path: String, configDirectory: URL?) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed == "~" || trimmed.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return trimmed == "~" ? home : home + String(trimmed.dropFirst())
    }
    if trimmed.hasPrefix("/") { return trimmed }
    guard let configDirectory else { return trimmed }
    return configDirectory.appendingPathComponent(trimmed).path
}
#endif
