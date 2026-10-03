#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation

typealias IOSSessionSummary = SessionSummary

struct IOSProviderModel: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }
}

struct IOSProviderAPIKeySource: Codable, Equatable {
    var type: String
    var value: String

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

struct IOSProviderSettings: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    var baseURL: String
    var chatEndpoint: String
    var apiKeyAccount: String
    var apiKeySource: IOSProviderAPIKeySource?
    var models: [IOSProviderModel]

    init(id: String,
         displayName: String,
         baseURL: String,
         chatEndpoint: String? = nil,
         apiKeyAccount: String,
         apiKeySource: IOSProviderAPIKeySource? = nil,
         models: [IOSProviderModel]) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint ?? IOSConfig.chatEndpoint(forBaseURL: baseURL)
        self.apiKeyAccount = apiKeyAccount
        self.apiKeySource = apiKeySource
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case chatEndpoint
        case apiKeyAccount
        case apiKeySource
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try container.decode(String.self, forKey: .baseURL)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.baseURL = baseURL
        self.chatEndpoint = try container.decodeIfPresent(String.self, forKey: .chatEndpoint)
            ?? IOSConfig.chatEndpoint(forBaseURL: baseURL)
        self.apiKeyAccount = try container.decodeIfPresent(String.self, forKey: .apiKeyAccount)
            ?? (self.id == "default" ? IOSConfig.legacyAPIKeyAccount : "provider-\(self.id)")
        self.apiKeySource = try container.decodeIfPresent(IOSProviderAPIKeySource.self, forKey: .apiKeySource)
        self.models = try container.decode([IOSProviderModel].self, forKey: .models)
    }

    var title: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: baseURL)?.host ?? id
    }
}

struct IOSProviderCatalog: Codable, Equatable {
    var selectedProviderID: String
    var selectedModelID: String
    var transcriptionModel: ModelRef? = nil
    var providers: [IOSProviderSettings]

    var selectedProvider: IOSProviderSettings? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
    }

    var selectedModel: IOSProviderModel? {
        guard let provider = selectedProvider else { return nil }
        return provider.models.first { $0.id == selectedModelID } ?? provider.models.first
    }
}

private struct IOSProviderSelection: Codable, Equatable {
    var providerID: String
    var modelID: String
}

private struct IOSImportedProviderConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sourceFilename: String
    var catalog: IOSProviderCatalog
    var providerConfig: ProviderConfig
}

/// iOS app configuration. Mirrors the macOS chat config with file-backed
/// provider secrets; there is deliberately no workspace/shell/agent setup.
enum IOSConfig {
    private static var hostIdentity: IntatisHostApplicationIdentity {
        IntatisHostApplication.identity
    }
    static let legacyAPIKeyAccount = "default-openai"
    static let defaultSession = SessionID(rawValue: "sess_ios")

    // User-configurable endpoint + model (persisted in UserDefaults).
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
    private static let importedConfigFilename = "imported-chat-configuration.json"
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
                    IOSProviderModel(id: modelID, displayName: defaultDisplayName(for: modelID)))
            }
            catalog.selectedModelID = modelID
            providerCatalog = catalog
            UserDefaults.standard.set(modelID, forKey: modelKey)
        }
    }

    static var selectedAPIKeyRef: KeychainRef {
        guard let provider = providerCatalog.selectedProvider else {
            return .authFile(providerID: defaultProviderID)
        }
        return apiKeyRef(for: provider)
    }

    static var providerCatalog: IOSProviderCatalog {
        get {
            let catalog: IOSProviderCatalog
            if let imported = importedConfiguration() {
                catalog = normalizedCatalog(imported.catalog)
            } else if let data = UserDefaults.standard.data(forKey: providerCatalogKey),
               let decoded = try? JSONDecoder().decode(IOSProviderCatalog.self, from: data) {
                catalog = normalizedCatalog(decoded)
            } else {
                catalog = normalizedCatalog(legacyProviderCatalog())
            }
            return applyingStoredSelection(to: catalog)
        }
        set {
            try? saveProviderCatalog(newValue)
        }
    }

    static var importedConfigDescription: String? {
        importedConfiguration()?.sourceFilename
    }

    @discardableResult
    static func installImportedConfiguration(
        _ imported: ImportedChatConfiguration,
        sourceFilename: String
    ) throws -> IOSProviderCatalog {
        let providers = imported.providers.map { provider in
            IOSProviderSettings(
                id: provider.id,
                displayName: provider.displayName,
                baseURL: provider.endpoint.baseURL.absoluteString,
                chatEndpoint: provider.endpoint.chatEndpoint?.absoluteString,
                apiKeyAccount: legacyAPIKeyAccount(forProviderID: provider.id),
                apiKeySource: apiKeySource(for: provider.endpoint.apiKeyRef),
                models: provider.models.map {
                    IOSProviderModel(id: $0.id, displayName: $0.displayName)
                })
        }
        let catalog = normalizedCatalog(IOSProviderCatalog(
            selectedProviderID: imported.selectedProviderID,
            selectedModelID: imported.selectedModelID,
            transcriptionModel: imported.transcriptionModel,
            providers: providers))
        var providerConfig = imported.providerConfig
        providerConfig.models = resolvedModels(
            for: catalog,
            webSearch: imported.webSearchModel,
            transcription: imported.transcriptionModel)
        let document = IOSImportedProviderConfiguration(
            schemaVersion: IOSImportedProviderConfiguration.currentSchemaVersion,
            sourceFilename: safeSourceFilename(sourceFilename),
            catalog: catalog,
            providerConfig: providerConfig)
        try writeImportedConfiguration(document)
        persistCatalogMirror(catalog)
        return providerCatalog
    }

    static func saveProviderCatalog(_ rawCatalog: IOSProviderCatalog) throws {
        let catalog = normalizedCatalog(rawCatalog)
        if var imported = importedConfiguration() {
            let webSearch = imported.providerConfig.models.webSearch
            let transcription = imported.providerConfig.models.transcription
            imported.catalog = catalog
            imported.providerConfig.endpoints = mergedEndpoints(
                catalog: catalog,
                existing: imported.providerConfig.endpoints)
            imported.providerConfig.models = resolvedModels(
                for: catalog,
                webSearch: webSearch,
                transcription: transcription)
            try writeImportedConfiguration(imported)
        }
        persistCatalogMirror(catalog)
    }

    @discardableResult
    static func selectProviderModel(providerID: String, modelID: String) -> IOSProviderCatalog {
        var catalog = providerCatalog
        guard let provider = catalog.providers.first(where: { $0.id == providerID }) else {
            return catalog
        }
        let selectedModelID = provider.models.first { $0.id == modelID }?.id
            ?? provider.models.first?.id
            ?? defaultModel
        catalog.selectedProviderID = provider.id
        catalog.selectedModelID = selectedModelID
        providerCatalog = catalog
        return providerCatalog
    }

    static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(
            hostIdentity.storageName,
            isDirectory: true)
    }

    static func sessionFile() -> URL {
        sessionFile(defaultSession)
    }

    static func sessionFile(_ session: SessionID) -> URL {
        SessionHistoryStore.sessionFile(root: appSupportDir(), session: session)
    }

    static func artifactsDir() -> URL {
        artifactsDir(defaultSession)
    }

    static func artifactsDir(_ session: SessionID) -> URL {
        SessionHistoryStore.artifactsDir(root: appSupportDir(), session: session)
    }

    static func recentSessions() -> [IOSSessionSummary] {
        SessionActivityHistoryStore.recentSessions(
            root: appSupportDir(),
            kind: .chat)
    }

    static func providerConfig() -> ProviderConfig {
        let catalog = providerCatalog
        if var imported = importedConfiguration() {
            let webSearch = imported.providerConfig.models.webSearch
            let transcription = imported.providerConfig.models.transcription
            imported.providerConfig.endpoints = mergedEndpoints(
                catalog: catalog,
                existing: imported.providerConfig.endpoints)
            imported.providerConfig.models = resolvedModels(
                for: catalog,
                webSearch: webSearch,
                transcription: transcription)
            return imported.providerConfig
        }
        let selectedProvider = catalog.selectedProvider ?? defaultProvider()
        let selectedModel = catalog.selectedModel ?? selectedProvider.models.first
            ?? IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))

        let endpoints = catalog.providers.map { provider in
            ProviderEndpoint(
                id: provider.id,
                baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
                chatEndpoint: URL(string: provider.chatEndpoint),
                apiKeyRef: apiKeyRef(for: provider),
                wire: .openai)
        }
        let chat = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: selectedModel.id))
        var models = ResolvedModels(chat: chat, agent: chat)
        models.imageGen = ModelRef(endpoint: selectedProvider.id, model: ModelID(rawValue: "dall-e-3"))
        models.transcription = catalog.transcriptionModel
        return ProviderConfig(endpoints: endpoints.isEmpty ? [endpoint(for: selectedProvider)] : endpoints,
                              models: models)
    }

    static func newProvider() -> IOSProviderSettings {
        let id = IDGen.random(prefix: "provider")
        return IOSProviderSettings(
            id: id,
            displayName: "New Provider",
            baseURL: defaultBaseURL,
            apiKeyAccount: legacyAPIKeyAccount(forProviderID: id),
            models: [IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    static func normalizedCatalog(_ catalog: IOSProviderCatalog) -> IOSProviderCatalog {
        var seenProviders = Set<String>()
        var providers = catalog.providers.compactMap { provider -> IOSProviderSettings? in
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenProviders.contains(id) else { return nil }
            seenProviders.insert(id)
            let isDedicatedTranscriptionProvider = catalog.transcriptionModel.map {
                normalizedProviderID($0.endpoint)
                    == normalizedProviderID(id)
            } ?? false
            let isSelectedProvider = normalizedProviderID(
                catalog.selectedProviderID) == normalizedProviderID(id)

            let baseURL = baseURL(fromChatEndpoint: provider.baseURL)
            let rawChatEndpoint = provider.chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatEndpoint = rawChatEndpoint.isEmpty
                ? chatEndpoint(forBaseURL: baseURL)
                : rawChatEndpoint
            var seenModels = Set<String>()
            let models = provider.models.compactMap { model -> IOSProviderModel? in
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelID.isEmpty, !seenModels.contains(modelID) else { return nil }
                seenModels.insert(modelID)
                return IOSProviderModel(
                    id: modelID,
                    displayName: model.displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !baseURL.isEmpty else { return nil }
            return IOSProviderSettings(
                id: id,
            displayName: provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKeyAccount: provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? legacyAPIKeyAccount(forProviderID: id)
                : provider.apiKeyAccount.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKeySource: provider.apiKeySource,
            models: models.isEmpty
                && (!isDedicatedTranscriptionProvider || isSelectedProvider)
                ? [IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))]
                : models)
        }

        if providers.isEmpty {
            providers = [defaultProvider()]
        }

        let selectedProviderID = providers.first {
            $0.id == catalog.selectedProviderID && !$0.models.isEmpty
        }?.id ?? providers.first { !$0.models.isEmpty }!.id
        let selectedProvider = providers.first { $0.id == selectedProviderID } ?? providers[0]
        let selectedModelID = selectedProvider.models.contains { $0.id == catalog.selectedModelID }
            ? catalog.selectedModelID
            : selectedProvider.models[0].id

        let transcriptionModel = normalizedRoleModelRef(
            catalog.transcriptionModel,
            providers: providers)
        return IOSProviderCatalog(
            selectedProviderID: selectedProviderID,
            selectedModelID: selectedModelID,
            transcriptionModel: transcriptionModel,
            providers: providers)
    }

    private static func legacyProviderCatalog() -> IOSProviderCatalog {
        let baseURL = baseURL(fromChatEndpoint: UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL)
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        let provider = IOSProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: baseURL,
            chatEndpoint: chatEndpoint(forBaseURL: baseURL),
            apiKeyAccount: legacyAPIKeyAccount,
            models: [IOSProviderModel(id: model, displayName: defaultDisplayName(for: model))])
        return IOSProviderCatalog(selectedProviderID: provider.id,
                                  selectedModelID: model,
                                  providers: [provider])
    }

    private static func applyingStoredSelection(to catalog: IOSProviderCatalog) -> IOSProviderCatalog {
        guard let selection = storedSelection(),
              let provider = catalog.providers.first(where: { $0.id == selection.providerID }),
              provider.models.contains(where: { $0.id == selection.modelID }) else {
            return catalog
        }
        var selected = catalog
        selected.selectedProviderID = selection.providerID
        selected.selectedModelID = selection.modelID
        return selected
    }

    private static func storedSelection() -> IOSProviderSelection? {
        guard let data = UserDefaults.standard.data(forKey: providerSelectionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(IOSProviderSelection.self, from: data)
    }

    private static func storeSelection(from catalog: IOSProviderCatalog) {
        let selection = IOSProviderSelection(providerID: catalog.selectedProviderID,
                                             modelID: catalog.selectedModelID)
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: providerSelectionKey)
        }
    }

    private static func persistCatalogMirror(_ catalog: IOSProviderCatalog) {
        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: providerCatalogKey)
        }
        storeSelection(from: catalog)
        if let provider = catalog.selectedProvider {
            UserDefaults.standard.set(provider.baseURL, forKey: baseURLKey)
        }
        if let model = catalog.selectedModel {
            UserDefaults.standard.set(model.id, forKey: modelKey)
        }
    }

    private static func importedConfigurationURL() -> URL {
        appSupportDir().appendingPathComponent(importedConfigFilename)
    }

    private static func importedConfiguration() -> IOSImportedProviderConfiguration? {
        let url = importedConfigurationURL()
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(
                  IOSImportedProviderConfiguration.self,
                  from: data),
              document.schemaVersion == IOSImportedProviderConfiguration.currentSchemaVersion else {
            return nil
        }
        return document
    }

    private static func writeImportedConfiguration(
        _ document: IOSImportedProviderConfiguration
    ) throws {
        let url = importedConfigurationURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }

    private static func safeSourceFilename(_ raw: String) -> String {
        let name = URL(fileURLWithPath: raw).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = hostIdentity.configurationFileName
        guard !name.isEmpty else { return fallback }
        return String(name.prefix(255))
    }

    private static func apiKeySource(for ref: KeychainRef) -> IOSProviderAPIKeySource? {
        switch ref.source {
        case .keychain, .authFile:
            return nil
        case .environment:
            return IOSProviderAPIKeySource(type: "env", value: ref.account)
        case .file:
            return IOSProviderAPIKeySource(type: "file", value: ref.account)
        case .providerConfig:
            return IOSProviderAPIKeySource(type: "providerConfig", value: ref.service)
        }
    }

    private static func mergedEndpoints(
        catalog: IOSProviderCatalog,
        existing: [ProviderEndpoint]
    ) -> [ProviderEndpoint] {
        catalog.providers.map { provider in
            var value = existing.first { $0.id == provider.id }
                ?? endpoint(for: provider)
            value.baseURL = URL(string: provider.baseURL)
                ?? URL(string: defaultBaseURL)!
            value.chatEndpoint = URL(string: provider.chatEndpoint)
            value.apiKeyRef = apiKeyRef(for: provider)

            let modelIDs = Set(provider.models.map(\.id))
            value.modelRequestAdapters = value.modelRequestAdapters.filter {
                modelIDs.contains($0.key)
            }
            value.modelRequestOptions = value.modelRequestOptions.filter {
                modelIDs.contains($0.key)
            }
            value.modelCapabilities = value.modelCapabilities.filter {
                modelIDs.contains($0.key)
            }
            return value
        }
    }

    private static func resolvedModels(
        for catalog: IOSProviderCatalog,
        webSearch: ModelRef? = nil,
        transcription: ModelRef? = nil
    ) -> ResolvedModels {
        let selectedProvider = catalog.selectedProvider ?? defaultProvider()
        let selectedModel = catalog.selectedModel ?? selectedProvider.models.first
            ?? IOSProviderModel(
                id: defaultModel,
                displayName: defaultDisplayName(for: defaultModel))
        let chat = ModelRef(
            endpoint: selectedProvider.id,
            model: ModelID(rawValue: selectedModel.id))
        var models = ResolvedModels(
            chat: chat,
            webSearch: webSearch,
            agent: chat)
        models.imageGen = ModelRef(
            endpoint: selectedProvider.id,
            model: ModelID(rawValue: "dall-e-3"))
        models.transcription = transcription ?? catalog.transcriptionModel
        return models
    }

    private static func normalizedRoleModelRef(
        _ ref: ModelRef?,
        providers: [IOSProviderSettings]
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

    private static func normalizedProviderID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func defaultProvider() -> IOSProviderSettings {
        IOSProviderSettings(
            id: defaultProviderID,
            displayName: "OpenAI",
            baseURL: defaultBaseURL,
            apiKeyAccount: legacyAPIKeyAccount,
            models: [IOSProviderModel(id: defaultModel, displayName: defaultDisplayName(for: defaultModel))])
    }

    private static func endpoint(for provider: IOSProviderSettings) -> ProviderEndpoint {
        ProviderEndpoint(
            id: provider.id,
            baseURL: URL(string: provider.baseURL) ?? URL(string: defaultBaseURL)!,
            chatEndpoint: URL(string: provider.chatEndpoint),
            apiKeyRef: apiKeyRef(for: provider),
            wire: .openai)
    }

    static func apiKeyRef(for provider: IOSProviderSettings) -> KeychainRef {
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

    private static func defaultDisplayName(for modelID: String) -> String {
        switch modelID {
        case "gpt-4o-mini":
            return "GPT-4o mini"
        case "gpt-4o":
            return "GPT-4o"
        default:
            return modelID
        }
    }
}
#endif
