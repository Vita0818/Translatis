import Foundation
import IntatisCore
import IntatisProtocol

/// A bounded, secret-aware projection of an Intatis/OpenCode-compatible
/// provider configuration for Chat surfaces. Literal credentials are kept only
/// in the import result until the host migrates them into its credential store;
/// endpoint metadata contains only non-secret references.
public struct ImportedChatConfiguration: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public struct Model: Equatable, Sendable {
        public var id: String
        public var displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    public struct Provider: Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var endpoint: ProviderEndpoint
        public var models: [Model]

        public init(id: String,
                    displayName: String,
                    endpoint: ProviderEndpoint,
                    models: [Model]) {
            self.id = id
            self.displayName = displayName
            self.endpoint = endpoint
            self.models = models
        }
    }

    public enum Warning: Equatable, Sendable {
        case ignoredModelVariants(providerID: String, modelID: String)
        case externalCredentialReference(providerID: String, kind: String)
        case unsupportedRequestAdapter(providerID: String, package: String)
        case skippedProviderWithoutBaseURL(providerID: String)
    }

    public var selectedProviderID: String
    public var selectedModelID: String
    public var transcriptionModel: ModelRef?
    public var embeddingModel: ModelRef?
    public var rerankerModel: ModelRef?
    public var webSearchModel: ModelRef?
    public var providers: [Provider]
    public var warnings: [Warning]
    private var literalSecretsByProviderID: [String: String]

    public init(selectedProviderID: String,
                selectedModelID: String,
                transcriptionModel: ModelRef? = nil,
                embeddingModel: ModelRef? = nil,
                rerankerModel: ModelRef? = nil,
                webSearchModel: ModelRef? = nil,
                providers: [Provider],
                warnings: [Warning] = [],
                literalSecretsByProviderID: [String: String] = [:]) {
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.transcriptionModel = transcriptionModel
        self.embeddingModel = embeddingModel
        self.rerankerModel = rerankerModel
        self.webSearchModel = webSearchModel
        self.providers = providers
        self.warnings = warnings
        self.literalSecretsByProviderID = literalSecretsByProviderID
    }

    public var providerConfig: ProviderConfig {
        let chat = ModelRef(
            endpoint: selectedProviderID,
            model: ModelID(rawValue: selectedModelID))
        return ProviderConfig(
            endpoints: providers.map(\.endpoint),
            models: ResolvedModels(
                chat: chat,
                webSearch: webSearchModel,
                agent: chat,
                transcription: transcriptionModel,
                embedding: embeddingModel,
                reranker: rerankerModel))
    }

    public var providerCount: Int { providers.count }

    public var modelCount: Int {
        providers.reduce(0) { $0 + $1.models.count }
    }

    public var literalSecretProviderIDs: [String] {
        literalSecretsByProviderID.keys.sorted()
    }

    /// Delivers literal credentials to the importing host without exposing
    /// them through descriptions or provider metadata.
    public func forEachLiteralSecret(
        _ body: (_ providerID: String, _ secret: String) throws -> Void
    ) rethrows {
        for providerID in literalSecretsByProviderID.keys.sorted() {
            if let secret = literalSecretsByProviderID[providerID] {
                try body(providerID, secret)
            }
        }
    }

    public var description: String {
        "ImportedChatConfiguration(providers: \(providerCount), models: \(modelCount), literalSecrets: <redacted>)"
    }

    public var debugDescription: String { description }
}

public enum ChatConfigurationImportError: Error, Equatable, Sendable,
    LocalizedError
{
    case fileTooLarge
    case malformedDocument
    case missingProviderConfiguration
    case noUsableProviders
    case duplicateProviderID
    case duplicateModelID
    case invalidProviderEndpoint
    case invalidModelSelection
    case invalidCredential

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The selected configuration is larger than the 1 MiB import limit."
        case .malformedDocument:
            return "The selected file is not valid JSON or JSONC."
        case .missingProviderConfiguration:
            return "The selected file does not contain a \(IntatisHostApplication.identity.name) provider configuration."
        case .noUsableProviders:
            return "The selected configuration has no usable Chat providers and models."
        case .duplicateProviderID:
            return "The selected configuration contains duplicate provider identifiers."
        case .duplicateModelID:
            return "The selected configuration contains duplicate model identifiers."
        case .invalidProviderEndpoint:
            return "The selected configuration contains an invalid provider endpoint."
        case .invalidModelSelection:
            return "The selected configuration contains an invalid model route."
        case .invalidCredential:
            return "The selected configuration contains an invalid credential value."
        }
    }
}

/// Parses the same modern `provider` map and legacy direct `providers` catalog
/// accepted by the macOS Chat configuration. The parser performs no network
/// access and never writes the selected file.
public enum ChatConfigurationImporter {
    public static let maximumByteCount = 1_048_576

    private static let maximumProviderCount = 64
    private static let maximumModelsPerProvider = 512
    private static let maximumIdentifierLength = 512
    private static let maximumDisplayNameLength = 1_024
    private static let maximumURLLength = 4_096
    private static let maximumSecretLength = 65_536

    public static func parse(
        data: Data,
        sourceURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ImportedChatConfiguration {
        guard data.count <= maximumByteCount else {
            throw ChatConfigurationImportError.fileTooLarge
        }
        let compatible = try JSONC.compatibleData(from: data)
        guard case .object(let root) = try? JSONDecoder().decode(
            JSONValue.self,
            from: compatible) else {
            throw ChatConfigurationImportError.malformedDocument
        }

        if root.object("provider") != nil {
            return try parseModern(
                root: root,
                sourceURL: sourceURL,
                environment: environment)
        }
        if root.array("providers") != nil {
            return try parseDirectCatalog(
                root: root,
                sourceURL: sourceURL,
                environment: environment)
        }
        throw ChatConfigurationImportError.missingProviderConfiguration
    }

    private static func parseModern(
        root: [String: JSONValue],
        sourceURL: URL?,
        environment: [String: String]
    ) throws -> ImportedChatConfiguration {
        guard let providerMap = root.object("provider"),
              !providerMap.isEmpty,
              providerMap.count <= maximumProviderCount else {
            throw ChatConfigurationImportError.noUsableProviders
        }

        let enabled = Set((root.stringArray("enabled_providers")
            ?? root.stringArray("enabledProviders") ?? []).map(normalizedID))
        let disabled = Set((root.stringArray("disabled_providers")
            ?? root.stringArray("disabledProviders") ?? []).map(normalizedID))
        let selectedRaw = resolvedSelection(
            root.string("model")
                ?? root.string("small_model")
                ?? root.string("smallModel"),
            environment: environment)
        let webSearchRaw = resolvedSelection(
            root.string("web_search_model")
                ?? root.string("webSearchModel"),
            environment: environment)
        let transcriptionRaw = resolvedSelection(
            root.string("transcription_model"),
            environment: environment)
        let embeddingRaw = resolvedSelection(
            root.string("embedding_model"),
            environment: environment)
        let rerankerRaw = resolvedSelection(
            root.string("reranker_model"),
            environment: environment)

        var providers: [ImportedChatConfiguration.Provider] = []
        var warnings: [ImportedChatConfiguration.Warning] = []
        var literalSecrets: [String: String] = [:]
        var seenProviderIDs = Set<String>()

        for configuredID in providerMap.keys.sorted() {
            let id = try boundedIdentifier(configuredID)
            let normalized = normalizedID(id)
            if disabled.contains(normalized)
                || (!enabled.isEmpty && !enabled.contains(normalized)) {
                continue
            }
            guard seenProviderIDs.insert(normalized).inserted else {
                throw ChatConfigurationImportError.duplicateProviderID
            }
            guard case .object(let providerObject) = providerMap[configuredID] else {
                continue
            }

            var modelWarnings: [ImportedChatConfiguration.Warning] = []
            var models = try parseModernModels(
                providerObject.object("models") ?? [:],
                providerID: id,
                warnings: &modelWarnings)
            if models.isEmpty,
               let selectedModel = selectedModelForProvider(
                   selectedRaw,
                   providerID: id) {
                models = [ParsedModel(
                    display: .init(id: selectedModel, displayName: selectedModel),
                    requestOptions: [:],
                    requestAdapter: nil,
                    capabilities: [])]
            }
            if models.isEmpty,
               !explicitRoleModel(
                   transcriptionRaw,
                   targetsProviderID: id),
               !explicitRoleModel(
                   embeddingRaw,
                   targetsProviderID: id),
               !explicitRoleModel(
                   rerankerRaw,
                   targetsProviderID: id) {
                models = [ParsedModel(
                    display: .init(id: "gpt-4o-mini", displayName: "GPT-4o mini"),
                    requestOptions: [:],
                    requestAdapter: nil,
                    capabilities: [])]
            }

            let options = providerObject.object("options") ?? [:]
            let explicitChatEndpoint = options.string("chatEndpoint")
                ?? providerObject.string("chatEndpoint")
            let configuredBaseURL = options.string("baseURL")
                ?? providerObject.string("baseURL")
                ?? explicitChatEndpoint.map(baseURLFromChatEndpoint)
            guard let rawBaseURL = configuredBaseURL
                ?? defaultBaseURL(forProviderID: id) else {
                warnings.append(.skippedProviderWithoutBaseURL(providerID: id))
                continue
            }
            guard let baseURL = validHTTPURL(rawBaseURL) else {
                throw ChatConfigurationImportError.invalidProviderEndpoint
            }
            let chatEndpoint = try optionalHTTPURL(explicitChatEndpoint)
            let responsesEndpoint = try optionalHTTPURL(
                options.string("responsesEndpoint")
                    ?? providerObject.string("responsesEndpoint"))

            let credential = try credential(
                providerID: id,
                provider: providerObject,
                options: options,
                sourceURL: sourceURL)
            if let secret = credential.literalSecret {
                literalSecrets[id] = secret
            }
            if let warningKind = credential.warningKind {
                warnings.append(.externalCredentialReference(
                    providerID: id,
                    kind: warningKind))
            }

            let requestAdapter = ProviderRequestAdapter.configuredProvider(
                providerObject.string("npm"))
            if !isImplementedChatAdapter(requestAdapter) {
                warnings.append(.unsupportedRequestAdapter(
                    providerID: id,
                    package: requestAdapter.rawValue))
            }
            warnings.append(contentsOf: modelWarnings)

            let endpoint = ProviderEndpoint(
                id: id,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                responsesEndpoint: responsesEndpoint,
                apiKeyRef: credential.ref,
                wire: .openai,
                requestAdapter: requestAdapter,
                modelRequestAdapters: Dictionary(uniqueKeysWithValues:
                    models.compactMap { model in
                        model.requestAdapter.map { (model.display.id, $0) }
                    }),
                modelRequestOptions: Dictionary(uniqueKeysWithValues:
                    models.map { ($0.display.id, $0.requestOptions) }),
                modelCapabilities: Dictionary(uniqueKeysWithValues:
                    models.filter { !$0.capabilities.isEmpty }
                        .map { ($0.display.id, $0.capabilities) }))
            let displayName = boundedDisplayName(
                providerObject.string("displayName")
                    ?? providerObject.string("name")
                    ?? defaultDisplayName(forProviderID: id))
            providers.append(.init(
                id: id,
                displayName: displayName,
                endpoint: endpoint,
                models: models.map(\.display)))
        }

        guard providers.contains(where: { !$0.models.isEmpty }) else {
            throw ChatConfigurationImportError.noUsableProviders
        }
        let selection = select(
            selectedProviderID: root.string("selectedProviderID"),
            selectedModelID: root.string("selectedModelID"),
            selectedRaw: selectedRaw,
            providers: providers)
        let webSearchModel = try? backgroundModelRef(
            webSearchRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        let transcriptionModel = try? backgroundModelRef(
            transcriptionRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        let embeddingModel = try knowledgeModelRef(
            embeddingRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        let rerankerModel = try knowledgeModelRef(
            rerankerRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        return ImportedChatConfiguration(
            selectedProviderID: selection.providerID,
            selectedModelID: selection.modelID,
            transcriptionModel: transcriptionModel,
            embeddingModel: embeddingModel,
            rerankerModel: rerankerModel,
            webSearchModel: webSearchModel,
            providers: providers,
            warnings: warnings,
            literalSecretsByProviderID: literalSecrets)
    }

    private static func parseDirectCatalog(
        root: [String: JSONValue],
        sourceURL: URL?,
        environment: [String: String]
    ) throws -> ImportedChatConfiguration {
        guard let values = root.array("providers"),
              !values.isEmpty,
              values.count <= maximumProviderCount else {
            throw ChatConfigurationImportError.noUsableProviders
        }

        let transcriptionRaw = resolvedSelection(
            root.string("transcription_model"),
            environment: environment)
        let embeddingRaw = resolvedSelection(
            root.string("embedding_model"),
            environment: environment)
        let rerankerRaw = resolvedSelection(
            root.string("reranker_model"),
            environment: environment)
        var providers: [ImportedChatConfiguration.Provider] = []
        var warnings: [ImportedChatConfiguration.Warning] = []
        var literalSecrets: [String: String] = [:]
        var seenProviderIDs = Set<String>()

        for value in values {
            guard case .object(let object) = value,
                  let rawID = object.string("id") else { continue }
            let id = try boundedIdentifier(rawID)
            guard seenProviderIDs.insert(normalizedID(id)).inserted else {
                throw ChatConfigurationImportError.duplicateProviderID
            }
            let modelValues = object.array("models") ?? []
            guard modelValues.count <= maximumModelsPerProvider else {
                throw ChatConfigurationImportError.noUsableProviders
            }
            var seenModels = Set<String>()
            var models: [ImportedChatConfiguration.Model] = []
            for modelValue in modelValues {
                let rawModelID: String?
                let displayName: String?
                switch modelValue {
                case .string(let value):
                    rawModelID = value
                    displayName = value
                case .object(let model):
                    rawModelID = model.string("id")
                    displayName = model.string("displayName") ?? model.string("name")
                default:
                    rawModelID = nil
                    displayName = nil
                }
                guard let rawModelID else { continue }
                let modelID = try boundedIdentifier(rawModelID)
                guard seenModels.insert(modelID).inserted else {
                    throw ChatConfigurationImportError.duplicateModelID
                }
                models.append(.init(
                    id: modelID,
                    displayName: boundedDisplayName(displayName ?? modelID)))
            }
            if models.isEmpty,
               !explicitRoleModel(
                   transcriptionRaw,
                   targetsProviderID: id),
               !explicitRoleModel(
                   embeddingRaw,
                   targetsProviderID: id),
               !explicitRoleModel(
                   rerankerRaw,
                   targetsProviderID: id) {
                models = [.init(id: "gpt-4o-mini", displayName: "GPT-4o mini")]
            }

            let explicitChatEndpoint = object.string("chatEndpoint")
            let configuredBaseURL = object.string("baseURL")
                ?? explicitChatEndpoint.map(baseURLFromChatEndpoint)
            guard let rawBaseURL = configuredBaseURL
                ?? defaultBaseURL(forProviderID: id) else {
                warnings.append(.skippedProviderWithoutBaseURL(providerID: id))
                continue
            }
            guard let baseURL = validHTTPURL(rawBaseURL) else {
                throw ChatConfigurationImportError.invalidProviderEndpoint
            }

            let credential = try credential(
                providerID: id,
                provider: object,
                options: object.object("options") ?? [:],
                sourceURL: sourceURL)
            if let secret = credential.literalSecret {
                literalSecrets[id] = secret
            }
            if let warningKind = credential.warningKind {
                warnings.append(.externalCredentialReference(
                    providerID: id,
                    kind: warningKind))
            }

            let adapter = object.string("npm").map(
                ProviderRequestAdapter.init(rawValue:)) ?? .legacyOpenAIWire
            if !isImplementedChatAdapter(adapter) {
                warnings.append(.unsupportedRequestAdapter(
                    providerID: id,
                    package: adapter.rawValue))
            }
            let endpoint = ProviderEndpoint(
                id: id,
                baseURL: baseURL,
                chatEndpoint: try optionalHTTPURL(explicitChatEndpoint),
                responsesEndpoint: try optionalHTTPURL(object.string("responsesEndpoint")),
                apiKeyRef: credential.ref,
                wire: .openai,
                requestAdapter: adapter)
            providers.append(.init(
                id: id,
                displayName: boundedDisplayName(
                    object.string("displayName")
                        ?? object.string("name")
                        ?? defaultDisplayName(forProviderID: id)),
                endpoint: endpoint,
                models: models))
        }

        guard providers.contains(where: { !$0.models.isEmpty }) else {
            throw ChatConfigurationImportError.noUsableProviders
        }
        let selectedRaw = resolvedSelection(
            root.string("model"),
            environment: environment)
        let selection = select(
            selectedProviderID: root.string("selectedProviderID"),
            selectedModelID: root.string("selectedModelID"),
            selectedRaw: selectedRaw,
            providers: providers)
        let webSearchModel = try? backgroundModelRef(
            resolvedSelection(
                root.string("web_search_model")
                    ?? root.string("webSearchModel"),
                environment: environment),
            preferredProviderID: selection.providerID,
            providers: providers)
        let transcriptionModel = try? backgroundModelRef(
            transcriptionRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        let embeddingModel = try knowledgeModelRef(
            embeddingRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        let rerankerModel = try knowledgeModelRef(
            rerankerRaw,
            preferredProviderID: selection.providerID,
            providers: providers)
        return ImportedChatConfiguration(
            selectedProviderID: selection.providerID,
            selectedModelID: selection.modelID,
            transcriptionModel: transcriptionModel,
            embeddingModel: embeddingModel,
            rerankerModel: rerankerModel,
            webSearchModel: webSearchModel,
            providers: providers,
            warnings: warnings,
            literalSecretsByProviderID: literalSecrets)
    }

    private struct ParsedModel {
        var display: ImportedChatConfiguration.Model
        var requestOptions: [String: JSONValue]
        var requestAdapter: ProviderRequestAdapter?
        var capabilities: [Capability]
    }

    private static func parseModernModels(
        _ map: [String: JSONValue],
        providerID: String,
        warnings: inout [ImportedChatConfiguration.Warning]
    ) throws -> [ParsedModel] {
        guard map.count <= maximumModelsPerProvider else {
            throw ChatConfigurationImportError.noUsableProviders
        }
        var seen = Set<String>()
        var result: [ParsedModel] = []
        for configuredID in map.keys.sorted() {
            guard let value = map[configuredID] else { continue }
            let modelID: String
            let displayName: String
            let options: [String: JSONValue]
            let metadata: [String: JSONValue]
            switch value {
            case .string(let name):
                modelID = try boundedIdentifier(configuredID)
                displayName = boundedDisplayName(name)
                options = [:]
                metadata = [:]
            case .object(let object):
                modelID = try boundedIdentifier(object.string("id") ?? configuredID)
                displayName = boundedDisplayName(
                    object.string("displayName")
                        ?? object.string("name")
                        ?? modelID)
                options = object.object("options") ?? [:]
                metadata = object
                if let variants = object.object("variants"), !variants.isEmpty {
                    warnings.append(.ignoredModelVariants(
                        providerID: providerID,
                        modelID: modelID))
                }
            default:
                continue
            }
            guard seen.insert(modelID).inserted else {
                throw ChatConfigurationImportError.duplicateModelID
            }
            let modelAdapter: ProviderRequestAdapter?
            if case .object(let provider)? = metadata["provider"] {
                modelAdapter = ProviderRequestAdapter.configuredModelOverride(
                    provider.string("npm"))
            } else {
                modelAdapter = nil
            }
            result.append(ParsedModel(
                display: .init(id: modelID, displayName: displayName),
                requestOptions: options,
                requestAdapter: modelAdapter,
                capabilities: ModelCapabilityMetadata.declaredCapabilities(
                    in: metadata)))
        }
        return result
    }

    private struct ParsedCredential {
        var ref: KeychainRef
        var literalSecret: String?
        var warningKind: String?
    }

    private static func credential(
        providerID: String,
        provider: [String: JSONValue],
        options: [String: JSONValue],
        sourceURL: URL?
    ) throws -> ParsedCredential {
        if let source = provider.object("apiKeySource")
            ?? options.object("apiKeySource") {
            return try credentialSource(
                source,
                providerID: providerID,
                sourceURL: sourceURL)
        }
        if let raw = options.string("apiKey") ?? provider.string("apiKey") {
            return try credentialValue(
                raw,
                providerID: providerID,
                sourceURL: sourceURL)
        }
        if let environmentName = options.string("apiKeyEnv")
            ?? provider.string("apiKeyEnv")
            ?? provider.stringArray("env")?.first {
            let name = try boundedCredentialComponent(environmentName)
            return ParsedCredential(
                ref: .environment(name),
                literalSecret: nil,
                warningKind: "environment")
        }
        if let path = options.string("apiKeyFile")
            ?? provider.string("apiKeyFile") {
            let resolved = try resolvedCredentialPath(path, sourceURL: sourceURL)
            return ParsedCredential(
                ref: .file(resolved),
                literalSecret: nil,
                warningKind: "file")
        }
        return ParsedCredential(
            ref: .authFile(providerID: providerID),
            literalSecret: nil,
            warningKind: nil)
    }

    private static func credentialSource(
        _ source: [String: JSONValue],
        providerID: String,
        sourceURL: URL?
    ) throws -> ParsedCredential {
        let type = (source.string("type") ?? "authFile")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = source.string("value")
            ?? source.string("name")
            ?? source.string("path")
            ?? ""
        switch type {
        case "env", "environment":
            let name = try boundedCredentialComponent(value)
            return ParsedCredential(
                ref: .environment(name),
                literalSecret: nil,
                warningKind: "environment")
        case "file", "path":
            let path = try resolvedCredentialPath(value, sourceURL: sourceURL)
            return ParsedCredential(
                ref: .file(path),
                literalSecret: nil,
                warningKind: "file")
        case "authfile", "auth_file", "auth-json", "authjson", "json":
            return ParsedCredential(
                ref: .authFile(providerID: providerID),
                literalSecret: nil,
                warningKind: nil)
        case "providerconfig", "provider_config", "config", "configfile", "config_file":
            return ParsedCredential(
                ref: .authFile(providerID: providerID),
                literalSecret: nil,
                warningKind: "providerConfig")
        default:
            return ParsedCredential(
                ref: .authFile(providerID: providerID),
                literalSecret: nil,
                warningKind: "unknown")
        }
    }

    private static func credentialValue(
        _ raw: String,
        providerID: String,
        sourceURL: URL?
    ) throws -> ParsedCredential {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumSecretLength else {
            throw ChatConfigurationImportError.invalidCredential
        }
        if let variable = configVariable(in: trimmed) {
            switch variable.kind {
            case "env":
                let name = try boundedCredentialComponent(variable.value)
                return ParsedCredential(
                    ref: .environment(name),
                    literalSecret: nil,
                    warningKind: "environment")
            case "file":
                let path = try resolvedCredentialPath(
                    variable.value,
                    sourceURL: sourceURL)
                return ParsedCredential(
                    ref: .file(path),
                    literalSecret: nil,
                    warningKind: "file")
            default:
                throw ChatConfigurationImportError.invalidCredential
            }
        }
        return ParsedCredential(
            ref: .authFile(providerID: providerID),
            literalSecret: trimmed,
            warningKind: nil)
    }

    private static func backgroundModelRef(
        _ raw: String?,
        preferredProviderID: String,
        providers: [ImportedChatConfiguration.Provider]
    ) throws -> ModelRef? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let exactMatches = providers.indices.filter { index in
            providers[index].models.contains { $0.id == raw }
        }
        let providerIndex: Int
        let modelID: String
        if exactMatches.count == 1, let index = exactMatches.first {
            providerIndex = index
            modelID = raw
        } else if let index = exactMatches.first(where: {
            normalizedID(providers[$0].id)
                == normalizedID(preferredProviderID)
        }) {
            providerIndex = index
            modelID = raw
        } else if let prefixed = providers.indices
            .sorted(by: { providers[$0].id.count > providers[$1].id.count })
            .first(where: { index in
                raw.lowercased().hasPrefix(
                    providers[index].id.lowercased() + "/")
            }) {
            providerIndex = prefixed
            let prefixLength = providers[prefixed].id.count + 1
            modelID = String(raw.dropFirst(prefixLength))
        } else if !raw.contains("/"),
                  let preferred = providers.firstIndex(where: {
                      normalizedID($0.id) == normalizedID(preferredProviderID)
                  }) {
            providerIndex = preferred
            modelID = raw
        } else if let separator = raw.firstIndex(of: "/") {
            let endpoint = String(raw[..<separator])
            let modelStart = raw.index(after: separator)
            let unknownModel = String(raw[modelStart...])
            return ModelRef(
                endpoint: try boundedIdentifier(endpoint),
                model: ModelID(rawValue:
                    try boundedIdentifier(unknownModel)))
        } else {
            throw ChatConfigurationImportError.invalidModelSelection
        }

        let boundedModelID = try boundedIdentifier(modelID)
        return ModelRef(
            endpoint: providers[providerIndex].id,
            model: ModelID(rawValue: boundedModelID))
    }

    /// Knowledge roles intentionally have no implicit "current Chat provider"
    /// fallback. Their portable configuration contract is the canonical
    /// `<provider-id>/<model-id>` shape, so an unqualified or malformed value
    /// must fail before any provider or credential is touched.
    private static func knowledgeModelRef(
        _ raw: String?,
        preferredProviderID: String,
        providers: [ImportedChatConfiguration.Provider]
    ) throws -> ModelRef? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        guard providers.contains(where: { provider in
            let prefix = provider.id + "/"
            return raw.hasPrefix(prefix) && raw.count > prefix.count
        }) else {
            throw ChatConfigurationImportError.invalidModelSelection
        }
        return try backgroundModelRef(
            raw,
            preferredProviderID: preferredProviderID,
            providers: providers)
    }

    /// Role routes use the canonical `<provider>/<model-id>` shape. Only an
    /// explicit provider prefix authorizes an otherwise model-less provider to
    /// remain out of the visible Chat model catalog.
    private static func explicitRoleModel(
        _ raw: String?,
        targetsProviderID providerID: String
    ) -> Bool {
        guard let raw = raw?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              let separator = raw.firstIndex(of: "/"),
              separator != raw.startIndex else { return false }
        return normalizedID(String(raw[..<separator]))
            == normalizedID(providerID)
    }

    private static func select(
        selectedProviderID: String?,
        selectedModelID: String?,
        selectedRaw: String?,
        providers: [ImportedChatConfiguration.Provider]
    ) -> (providerID: String, modelID: String) {
        if let selectedProviderID,
           let provider = provider(matching: selectedProviderID, in: providers),
           let selectedModelID,
           provider.models.contains(where: { $0.id == selectedModelID }) {
            return (provider.id, selectedModelID)
        }
        if let raw = selectedRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let exact = providers.filter { provider in
                provider.models.contains(where: { $0.id == raw })
            }
            if exact.count == 1, let provider = exact.first {
                return (provider.id, raw)
            }
            if let selectedProviderID,
               let provider = exact.first(where: {
                   normalizedID($0.id) == normalizedID(selectedProviderID)
               }) {
                return (provider.id, raw)
            }
            for provider in providers.sorted(by: { $0.id.count > $1.id.count }) {
                let prefix = provider.id + "/"
                if raw.hasPrefix(prefix) {
                    let modelID = String(raw.dropFirst(prefix.count))
                    if provider.models.contains(where: { $0.id == modelID }) {
                        return (provider.id, modelID)
                    }
                }
            }
        }
        if let selectedProviderID,
           let provider = provider(matching: selectedProviderID, in: providers),
           let model = provider.models.first {
            return (provider.id, model.id)
        }
        let provider = providers.first { !$0.models.isEmpty }!
        return (provider.id, provider.models[0].id)
    }

    private static func provider(
        matching id: String,
        in providers: [ImportedChatConfiguration.Provider]
    ) -> ImportedChatConfiguration.Provider? {
        providers.first { $0.id == id }
            ?? providers.first { normalizedID($0.id) == normalizedID(id) }
    }

    private static func selectedModelForProvider(
        _ raw: String?,
        providerID: String
    ) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let prefix = providerID + "/"
        if raw.hasPrefix(prefix) {
            let model = String(raw.dropFirst(prefix.count))
            return model.isEmpty ? nil : model
        }
        return nil
    }

    private static func boundedIdentifier(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumIdentifierLength else {
            throw ChatConfigurationImportError.noUsableProviders
        }
        return value
    }

    private static func boundedDisplayName(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.utf8.count <= maximumDisplayNameLength { return value }
        return String(value.prefix(maximumDisplayNameLength))
    }

    private static func boundedCredentialComponent(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumURLLength else {
            throw ChatConfigurationImportError.invalidCredential
        }
        return value
    }

    private static func validHTTPURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumURLLength,
              let url = URL(string: baseURLFromChatEndpoint(value)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private static func optionalHTTPURL(_ raw: String?) throws -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard raw.utf8.count <= maximumURLLength,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            throw ChatConfigurationImportError.invalidProviderEndpoint
        }
        return url
    }

    private static func baseURLFromChatEndpoint(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") && !value.hasSuffix("://") {
            value.removeLast()
        }
        let suffix = "/chat/completions"
        if value.lowercased().hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        return value
    }

    private static func defaultBaseURL(forProviderID providerID: String) -> String? {
        switch normalizedID(providerID) {
        case "default", "openai": return "https://api.openai.com/v1"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "deepseek": return "https://api.deepseek.com/v1"
        case "ollama": return "http://localhost:11434/v1"
        case "lmstudio", "lm-studio": return "http://localhost:1234/v1"
        case "groq": return "https://api.groq.com/openai/v1"
        case "xai": return "https://api.x.ai/v1"
        case "together": return "https://api.together.xyz/v1"
        case "fireworks": return "https://api.fireworks.ai/inference/v1"
        case "cerebras": return "https://api.cerebras.ai/v1"
        case "moonshot": return "https://api.moonshot.ai/v1"
        default: return nil
        }
    }

    private static func defaultDisplayName(forProviderID providerID: String) -> String {
        switch normalizedID(providerID) {
        case "default", "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "deepseek": return "DeepSeek"
        case "ollama": return "Ollama"
        case "lmstudio", "lm-studio": return "LM Studio"
        case "groq": return "Groq"
        case "xai": return "xAI"
        case "together": return "Together AI"
        case "fireworks": return "Fireworks AI"
        case "cerebras": return "Cerebras"
        case "moonshot": return "Moonshot AI"
        default: return providerID
        }
    }

    private static func isImplementedChatAdapter(
        _ adapter: ProviderRequestAdapter
    ) -> Bool {
        adapter == .legacyOpenAIWire
            || adapter == .openAICompatible
            || adapter == .openRouter
    }

    private static func normalizedID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func resolvedSelection(
        _ raw: String?,
        environment: [String: String]
    ) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let variable = configVariable(in: raw) else { return raw }
        guard variable.kind == "env" else { return nil }
        return environment[variable.value]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func configVariable(
        in raw: String
    ) -> (kind: String, value: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let body = trimmed.dropFirst().dropLast()
        guard let separator = body.firstIndex(of: ":") else { return nil }
        let kind = body[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = body[body.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !value.isEmpty else { return nil }
        return (kind, value)
    }

    private static func resolvedCredentialPath(
        _ raw: String,
        sourceURL: URL?
    ) throws -> String {
        let value = try boundedCredentialComponent(raw)
        let expanded: String
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
        if value == "~" {
            expanded = homeDirectory
        } else if value.hasPrefix("~/") {
            expanded = homeDirectory + String(value.dropFirst())
        } else {
            expanded = value
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        guard let sourceURL else { return expanded }
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent(expanded)
            .standardizedFileURL.path
    }
}

private enum JSONC {
    static func compatibleData(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChatConfigurationImportError.malformedDocument
        }
        return Data(stripTrailingCommas(stripComments(text)).utf8)
    }

    private static func stripComments(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
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
                if text[next] == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if text[next] == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let lookahead = text.index(after: index)
                        if text[index] == "\n" { output.append("\n") }
                        if text[index] == "*", lookahead < text.endIndex,
                           text[lookahead] == "/" {
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

    private static func stripTrailingCommas(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
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
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func object(_ key: String) -> [String: JSONValue]? {
        guard case .object(let value) = self[key] else { return nil }
        return value
    }

    func array(_ key: String) -> [JSONValue]? {
        guard case .array(let value) = self[key] else { return nil }
        return value
    }

    func stringArray(_ key: String) -> [String]? {
        guard let values = array(key) else { return nil }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
    }
}
