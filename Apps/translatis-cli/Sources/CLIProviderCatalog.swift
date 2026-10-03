import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

/// One named variant from the shared Intatis/OpenCode-compatible provider
/// configuration. The raw configuration name stays local; durable bindings use
/// an opaque derived variant identifier.
struct CLIProviderVariant: Equatable, Sendable {
    let id: String
    let requestOptions: [String: JSONValue]
}

struct CLIProviderModel: Equatable, Sendable {
    let id: String
    let displayName: String
    let requestOptions: [String: JSONValue]
    /// Complete raw model object. Non-wire metadata such as context-window
    /// limits is parsed from here and never copied into request options.
    let configurationMetadata: [String: JSONValue]
    let variants: [CLIProviderVariant]
    let declaredCapabilities: [Capability]

    var requestAdapterOverride:
        ProviderRequestAdapter?
    {
        guard case .object(let provider)? =
                configurationMetadata["provider"],
              case .string(let npm)? =
                provider["npm"] else {
            return nil
        }
        return ProviderRequestAdapter
            .configuredModelOverride(npm)
    }

    init(id: String,
         displayName: String,
         requestOptions: [String: JSONValue] = [:],
         configurationMetadata: [String: JSONValue] = [:],
         variants: [CLIProviderVariant] = [],
         declaredCapabilities: [Capability] = [
            .chat,
            .toolCalling,
         ]) {
        self.id = id
        self.displayName = displayName
        self.requestOptions = requestOptions
        self.configurationMetadata = configurationMetadata
        self.variants = variants
        self.declaredCapabilities =
            declaredCapabilities
    }
}

/// A role-specific model route from the local provider configuration. This is
/// not an inference profile and does not add the model to any chat/Cowork menu.
struct CLIProviderModelSelection: Equatable, Sendable {
    let providerID: String
    let modelID: String
}

/// A logical provider route. `id` is used only as local configuration input;
/// catalog/EventLog identifiers are opaque hashes. Secret material is either a
/// lazy `credentialRef` or an in-memory value for the legacy/env override path.
struct CLIProviderRoute: Equatable, Sendable {
    let id: String
    let displayName: String
    var baseURL: URL
    var chatEndpoint: URL?
    let wire: WireFormat
    let requestAdapter: ProviderRequestAdapter
    var credentialRef: KeychainRef
    var inlineSecret: String?
    var models: [CLIProviderModel]

    var safeDisplayName: String {
        "route \(CLIInferenceRouteIdentity.logicalDigest(routeID: id).prefix(8))"
    }

    static func legacy(baseURL: URL,
                       apiKey: String,
                       model: String,
                       wire: WireFormat) -> CLIProviderRoute {
        let routeID = "legacy-default"
        let variants = CLIInferenceProfiles.reasoningLevels.map { effort in
            CLIProviderVariant(
                id: "reasoning-\(effort.rawValue)",
                requestOptions: [
                    "reasoningEffort":
                        .string(effort.rawValue),
                ])
        }
        return CLIProviderRoute(
            id: routeID,
            displayName: "CLI legacy route",
            baseURL: baseURL,
            chatEndpoint: nil,
            wire: wire,
            requestAdapter: .openAICompatible,
            credentialRef: CLIInferenceRouteIdentity.inlineCredentialRef(
                routeID: routeID,
                baseURL: baseURL,
                wire: wire),
            inlineSecret: apiKey,
            models: [CLIProviderModel(
                id: model,
                displayName: model,
                variants: variants)])
    }

    static func validHTTPURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}

/// Decoder for the same advanced configuration shape used by the macOS app:
/// `model`, `enabled_providers`, and a `provider.<id>` map containing
/// connection options plus model `options` and named `variants`.
struct CLIModernProviderConfig: Sendable {
    private static var hostIdentity: IntatisHostApplicationIdentity {
        IntatisHostApplication.identity
    }
    let routes: [CLIProviderRoute]
    let selectedProviderID: String
    let selectedModelID: String
    let permissionReviewerModel: CLIProviderModelSelection
    let imageModel: CLIProviderModelSelection?
    let embeddingModel: CLIProviderModelSelection?
    let rerankerModel: CLIProviderModelSelection?
    let sourceURL: URL

    static func existingURL(environment: [String: String]) -> URL? {
        if let override = environment[
            hostIdentity.environmentVariable("CONFIG")]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: expandedPath(override)).standardizedFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = hostIdentity.userConfigurationDirectory(
            homeDirectory: home)
        var candidates = [
            config.appendingPathComponent(hostIdentity.configurationFileName),
            config.appendingPathComponent(
                hostIdentity.configurationJSONCFileName),
        ]
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first {
            let directory = support.appendingPathComponent(
                hostIdentity.storageName,
                isDirectory: true)
            candidates.append(directory.appendingPathComponent(
                hostIdentity.configurationFileName))
            candidates.append(directory.appendingPathComponent(
                hostIdentity.configurationJSONCFileName))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func load(from url: URL,
                     environment: [String: String]) throws -> CLIModernProviderConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IntatisError.config(
                "selected \(hostIdentity.name) provider config is unavailable")
        }
        let data = try JSONC.data(contentsOf: url)
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data),
              let providerMap = root.object("provider"),
              !providerMap.isEmpty else {
            throw IntatisError.config(
                "selected \(hostIdentity.name) provider config has no provider map")
        }

        let enabled = Set((root.stringArray("enabled_providers")
            ?? root.stringArray("enabledProviders") ?? []).map(normalizedID))
        let disabled = Set((root.stringArray("disabled_providers")
            ?? root.stringArray("disabledProviders") ?? []).map(normalizedID))
        let selectedRaw = resolvedConfigValue(
            root.string("model") ?? root.string("small_model") ?? root.string("smallModel"),
            environment: environment,
            configDirectory: url.deletingLastPathComponent())
        let permissionReviewerFieldPresent = root["permission_reviewer_model"] != nil
        let permissionReviewerModelRaw = resolvedConfigValue(
            root.string("permission_reviewer_model"),
            environment: environment,
            configDirectory: url.deletingLastPathComponent())
        if permissionReviewerFieldPresent,
           permissionReviewerModelRaw?.trimmingCharacters(
               in: .whitespacesAndNewlines).isEmpty != false {
            throw IntatisError.config(
                "invalid CLI permission_reviewer_model")
        }
        let imageModelRaw = resolvedConfigValue(
            root.string("image_model") ?? root.string("imageModel"),
            environment: environment,
            configDirectory: url.deletingLastPathComponent())
        // Knowledge role fields intentionally accept only their canonical
        // snake_case spellings. This freezes one portable encoder/decoder
        // contract instead of adding untested aliases.
        let embeddingModelRaw = resolvedConfigValue(
            root.string("embedding_model"),
            environment: environment,
            configDirectory: url.deletingLastPathComponent())
        let rerankerModelRaw = resolvedConfigValue(
            root.string("reranker_model"),
            environment: environment,
            configDirectory: url.deletingLastPathComponent())
        let explicitRoleProviderIDs = Set([
            imageModelRaw,
            embeddingModelRaw,
            rerankerModelRaw,
        ].compactMap {
            providerID(
                referencedBy: $0,
                availableProviderIDs: Array(providerMap.keys))
        })

        var routes: [CLIProviderRoute] = []
        for providerID in providerMap.keys.sorted() {
            let normalized = normalizedID(providerID)
            if disabled.contains(normalized) || (!enabled.isEmpty && !enabled.contains(normalized)) {
                continue
            }
            guard case .object(let provider) = providerMap[providerID] else { continue }
            let options = provider.object("options") ?? [:]
            guard let rawBase = options.string("baseURL") ?? provider.string("baseURL"),
                  let baseURL = CLIProviderRoute.validHTTPURL(rawBase) else {
                continue
            }
            let chatEndpoint: URL?
            if let rawChat = options.string("chatEndpoint") ?? provider.string("chatEndpoint") {
                guard let validated = CLIProviderRoute.validHTTPURL(rawChat) else {
                    throw IntatisError.config("invalid CLI provider chat endpoint")
                }
                chatEndpoint = validated
            } else {
                chatEndpoint = nil
            }
            let credentialRef = credentialReference(
                providerID: providerID,
                provider: provider,
                options: options,
                sourceURL: url)
            let models = parseModels(provider.object("models") ?? [:])
            guard !models.isEmpty || explicitRoleProviderIDs.contains(providerID) else {
                continue
            }
            routes.append(CLIProviderRoute(
                id: providerID,
                displayName: provider.string("displayName")
                    ?? provider.string("name")
                    ?? providerID,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                wire: .openai,
                requestAdapter:
                    .configuredProvider(
                        provider.string("npm")),
                credentialRef: credentialRef,
                inlineSecret: nil,
                models: models))
        }
        // Role models may need model-scoped adapter/options, but they are not
        // Chat/Code/Cowork inference choices. Resolve the two canonical roles
        // first, then remove those exact pairs only from the menu/catalog view;
        // the original routes stay intact for ProviderConfig lowering.
        let provisionalProviderID = routes.first?.id ?? ""
        let embeddingModel = try selectRoleModel(
            embeddingModelRaw,
            preferredProviderID: provisionalProviderID,
            routes: routes,
            roleName: "embedding",
            requiresQualifiedProvider: true)
        let rerankerModel = try selectRoleModel(
            rerankerModelRaw,
            preferredProviderID: provisionalProviderID,
            routes: routes,
            roleName: "reranker",
            requiresQualifiedProvider: true)
        let knowledgeRoleKeys = Set([
            embeddingModel,
            rerankerModel,
        ].compactMap { selection in
            selection.map {
                $0.providerID + "\u{1F}" + $0.modelID
            }
        })
        let inferenceRoutes = routes.compactMap { route -> CLIProviderRoute? in
            var filtered = route
            filtered.models.removeAll { model in
                knowledgeRoleKeys.contains(route.id + "\u{1F}" + model.id)
            }
            return filtered.models.isEmpty ? nil : filtered
        }
        guard !inferenceRoutes.isEmpty else {
            throw IntatisError.config(
                "selected \(hostIdentity.name) provider config has no usable routes")
        }

        let selection = try selectModel(selectedRaw, routes: inferenceRoutes)
        let permissionReviewerModel: CLIProviderModelSelection
        if permissionReviewerFieldPresent {
            permissionReviewerModel = try selectPermissionReviewerModel(
                permissionReviewerModelRaw,
                routes: inferenceRoutes)
        } else {
            // Compatibility is intentionally tied to the JSON document's
            // configured default, not to TRANSLATIS_MODEL or a runtime @main
            // rebind performed after the document is loaded. Unlike ordinary
            // main selection, this authorization role cannot invent a missing
            // or unknown model by falling back to the first route.
            guard let inheritedRaw = selectedRaw?.trimmingCharacters(
                in: .whitespacesAndNewlines),
                !inheritedRaw.isEmpty else {
                throw IntatisError.config(
                    "permission_reviewer_model is absent and the JSON top-level model is unavailable")
            }
            let inherited = try selectModel(
                inheritedRaw,
                routes: inferenceRoutes)
            guard inferenceRoutes.contains(where: { route in
                route.id == inherited.providerID
                    && route.models.contains(where: {
                        $0.id == inherited.modelID
                    })
            }) else {
                throw IntatisError.config(
                    "permission_reviewer_model cannot inherit an unknown JSON top-level model")
            }
            permissionReviewerModel = CLIProviderModelSelection(
                providerID: inherited.providerID,
                modelID: inherited.modelID)
        }
        let imageModel = try selectRoleModel(
            imageModelRaw,
            preferredProviderID: selection.providerID,
            routes: routes,
            roleName: "image")
        return CLIModernProviderConfig(
            routes: routes,
            selectedProviderID: selection.providerID,
            selectedModelID: selection.modelID,
            permissionReviewerModel: permissionReviewerModel,
            imageModel: imageModel,
            embeddingModel: embeddingModel,
            rerankerModel: rerankerModel,
            sourceURL: url.standardizedFileURL)
    }

    func providerQualifiedModel(_ raw: String) throws -> (providerID: String, modelID: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = routes.filter { route in
            route.models.contains(where: { $0.id == trimmed })
                && !isKnowledgeRoleModel(
                    providerID: route.id,
                    modelID: trimmed)
        }
        if exact.count == 1, let route = exact.first {
            return (route.id, trimmed)
        }
        if exact.count > 1 {
            if let selected = exact.first(where: { $0.id == selectedProviderID }) {
                return (selected.id, trimmed)
            }
            throw IntatisError.config(
                "ambiguous CLI model override; qualify a model that is not also a complete configured model ID")
        }
        for route in routes.sorted(by: { $0.id.count > $1.id.count }) {
            let prefix = route.id + "/"
            if trimmed.hasPrefix(prefix) {
                let model = String(trimmed.dropFirst(prefix.count))
                if !model.isEmpty {
                    guard !isKnowledgeRoleModel(
                        providerID: route.id,
                        modelID: model) else {
                        throw IntatisError.config(
                            "Knowledge role models cannot be selected as CLI inference models")
                    }
                    return (route.id, model)
                }
            }
        }
        return nil
    }

    func isKnowledgeRoleModel(
        providerID: String,
        modelID: String
    ) -> Bool {
        [embeddingModel, rerankerModel].compactMap { $0 }.contains {
            $0.providerID == providerID && $0.modelID == modelID
        }
    }

    func selectedVariantID(providerID: String,
                           modelID: String,
                           reasoningEffort: ReasoningEffort?) throws -> String? {
        guard let reasoningEffort,
              let model = routes.first(where: { $0.id == providerID })?
                .models.first(where: { $0.id == modelID }) else {
            return nil
        }
        let matchingVariants = model.variants.filter {
            Self.reasoningEffort(in: $0.requestOptions) == reasoningEffort
        }
        let baseMatches = Self.reasoningEffort(in: model.requestOptions) == reasoningEffort
        guard matchingVariants.count + (baseMatches ? 1 : 0) <= 1 else {
            throw IntatisError.config(
                "selected CLI reasoning effort matches multiple configured profiles; select an exact profile instead")
        }
        return matchingVariants.first?.id
    }

    func baseModel(providerID: String,
                   modelID: String,
                   hasReasoningEffort effort: ReasoningEffort) -> Bool {
        guard let model = routes.first(where: { $0.id == providerID })?
            .models.first(where: { $0.id == modelID }) else {
            return false
        }
        return Self.reasoningEffort(in: model.requestOptions) == effort
    }

    private static func selectModel(
        _ raw: String?,
        routes: [CLIProviderRoute]
    ) throws -> (providerID: String, modelID: String) {
        if let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // A configured model ID may itself contain `/` (for example a
            // gateway model namespace). Exact model keys therefore win over
            // Intatis' provider/model shorthand.
            let exact = routes.compactMap { route -> (String, String)? in
                route.models.contains(where: { $0.id == raw }) ? (route.id, raw) : nil
            }
            if exact.count == 1, let only = exact.first { return only }
            if exact.count > 1 {
                throw IntatisError.config(
                    "ambiguous configured model ID across CLI provider routes")
            }
            for route in routes.sorted(by: { $0.id.count > $1.id.count }) {
                let prefix = route.id + "/"
                if raw.hasPrefix(prefix) {
                    let model = String(raw.dropFirst(prefix.count))
                    if !model.isEmpty { return (route.id, model) }
                }
            }
        }
        let route = routes[0]
        return (route.id, route.models[0].id)
    }

    /// Reviewer configuration is an authorization boundary, so it does not
    /// inherit `selectModel`'s permissive unknown-model fallback. An explicit
    /// value must name one enabled inference model using the canonical
    /// `<provider>/<model-id>` shape or loading fails closed.
    private static func selectPermissionReviewerModel(
        _ raw: String?,
        routes: [CLIProviderRoute]
    ) throws -> CLIProviderModelSelection {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw IntatisError.config(
                "invalid CLI permission_reviewer_model")
        }
        for route in routes.sorted(by: { $0.id.count > $1.id.count }) {
            let prefix = route.id + "/"
            guard raw.hasPrefix(prefix) else { continue }
            let modelID = String(raw.dropFirst(prefix.count))
            guard !modelID.isEmpty,
                  route.models.contains(where: { $0.id == modelID }) else {
                throw IntatisError.config(
                    "CLI permission_reviewer_model does not resolve to a configured inference model")
            }
            return CLIProviderModelSelection(
                providerID: route.id,
                modelID: modelID)
        }
        throw IntatisError.config(
            "CLI permission_reviewer_model must use the canonical provider/model shape")
    }

    private static func selectRoleModel(
        _ raw: String?,
        preferredProviderID: String,
        routes: [CLIProviderRoute],
        roleName: String,
        requiresQualifiedProvider: Bool = false
    ) throws -> CLIProviderModelSelection? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if !requiresQualifiedProvider {
            let exact = routes.filter { route in
                route.models.contains(where: { $0.id == raw })
            }
            if exact.count == 1, let route = exact.first {
                return CLIProviderModelSelection(
                    providerID: route.id,
                    modelID: raw)
            }
            if exact.count > 1 {
                if let preferred = exact.first(where: { $0.id == preferredProviderID }) {
                    return CLIProviderModelSelection(
                        providerID: preferred.id,
                        modelID: raw)
                }
                throw IntatisError.config(
                    "ambiguous CLI \(roleName) model; qualify it with a provider ID")
            }
        }

        for route in routes.sorted(by: { $0.id.count > $1.id.count }) {
            let prefix = route.id + "/"
            if raw.hasPrefix(prefix) {
                let modelID = String(raw.dropFirst(prefix.count))
                guard !modelID.isEmpty else {
                    throw IntatisError.config("invalid CLI \(roleName) model")
                }
                return CLIProviderModelSelection(
                    providerID: route.id,
                    modelID: modelID)
            }
        }

        if requiresQualifiedProvider {
            throw IntatisError.config(
                "CLI \(roleName)_model must use the canonical provider/model shape")
        }

        guard routes.contains(where: { $0.id == preferredProviderID }) else {
            throw IntatisError.config(
                "selected CLI \(roleName) provider route is unavailable")
        }
        return CLIProviderModelSelection(
            providerID: preferredProviderID,
            modelID: raw)
    }

    private static func providerID(
        referencedBy raw: String?,
        availableProviderIDs: [String]
    ) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return availableProviderIDs
            .sorted(by: { $0.count > $1.count })
            .first { raw.hasPrefix($0 + "/") }
    }

    private static func parseModels(
        _ map: [String: JSONValue]
    ) -> [CLIProviderModel] {
        map.keys.sorted().compactMap { configuredID in
            guard let value = map[configuredID] else { return nil }
            switch value {
            case .string(let name):
                return CLIProviderModel(id: configuredID, displayName: name)
            case .object(let object):
                let modelID = object.string("id") ?? configuredID
                let name = object.string("displayName")
                    ?? object.string("name")
                    ?? modelID
                let modelOptions = object.object("options") ?? [:]
                var variants: [CLIProviderVariant] = []
                if let variantMap = object.object("variants") {
                    for variantID in variantMap.keys.sorted() {
                        guard case .object(var variantOptions) = variantMap[variantID],
                              variantOptions["disabled"] != .bool(true) else {
                            continue
                        }
                        variantOptions.removeValue(forKey: "disabled")
                        variants.append(CLIProviderVariant(
                            id: variantID,
                            requestOptions: variantOptions))
                    }
                }
                return CLIProviderModel(
                    id: modelID,
                    displayName: name,
                    requestOptions: modelOptions,
                    configurationMetadata: object,
                    variants: variants,
                    declaredCapabilities:
                        ModelCapabilityMetadata
                            .declaredCapabilities(
                                in: object))
            default:
                return nil
            }
        }
    }

    private static func credentialReference(
        providerID: String,
        provider: [String: JSONValue],
        options: [String: JSONValue],
        sourceURL: URL
    ) -> KeychainRef {
        if let environmentName = options.string("apiKeyEnv")
            ?? provider.string("apiKeyEnv") {
            return .environment(environmentName)
        }
        if let file = options.string("apiKeyFile") ?? provider.string("apiKeyFile") {
            return .file(resolvedPath(file, relativeTo: sourceURL.deletingLastPathComponent()))
        }
        if let raw = options.string("apiKey") ?? provider.string("apiKey") {
            if let variable = configVariable(in: raw) {
                switch variable.kind {
                case "env":
                    return .environment(variable.value)
                case "file":
                    return .file(resolvedPath(
                        variable.value,
                        relativeTo: sourceURL.deletingLastPathComponent()))
                default:
                    break
                }
            }
            // Literal values remain in the owner-selected config and are read
            // lazily; the catalog stores only this provider/path reference.
            return .providerConfig(path: sourceURL.standardizedFileURL.path,
                                   providerID: providerID)
        }
        return .authFile(providerID: providerID)
    }

    private static func reasoningEffort(
        in options: [String: JSONValue]
    ) -> ReasoningEffort? {
        if case .string(let value) =
            options["reasoningEffort"] {
            return ReasoningEffort(
                rawValue: value.lowercased())
        }
        if case .string(let value) = options["reasoning_effort"] {
            return ReasoningEffort(rawValue: value.lowercased())
        }
        if case .object(let reasoning) = options["reasoning"],
           case .string(let value) = reasoning["effort"] {
            return ReasoningEffort(rawValue: value.lowercased())
        }
        return nil
    }

    private static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Exact multi-route credential resolver. It never substitutes the selected
/// route's key: every catalog connection revision supplies its own ref. Lazy
/// env/file/auth/config refs remain resolvable for retained old revisions.
struct CLIExactSecretResolver: SecretResolver {
    private let routes: [CLIProviderRoute]
    private let allowedProviderConfigPaths: Set<String>

    init(config: CLIConfig) {
        routes = config.providerRoutes
        var paths = Set<String>()
        if let url = config.configurationFileURL {
            paths.insert(url.standardizedFileURL.path)
        }
        for route in config.providerRoutes where route.credentialRef.source == .providerConfig {
            paths.insert(URL(fileURLWithPath: route.credentialRef.service).standardizedFileURL.path)
        }
        allowedProviderConfigPaths = paths
    }

    func secret(for ref: KeychainRef) async throws -> String {
        let value: String?
        switch ref.source {
        case .keychain:
            value = routes.first(where: { $0.credentialRef == ref })?.inlineSecret
        case .environment:
            value = ProcessInfo.processInfo.environment[ref.account]
        case .file:
            value = try? String(contentsOfFile: ref.account, encoding: .utf8)
        case .authFile:
            value = readAuthSecret(providerID: ref.account)
        case .providerConfig:
            let path = URL(fileURLWithPath: ref.service).standardizedFileURL.path
            value = allowedProviderConfigPaths.contains(path)
                ? readProviderConfigSecret(providerID: ref.account, path: path)
                : nil
        }
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            throw IntatisError.config(
                "credential unavailable for the exact CLI inference route")
        }
        return trimmed
    }

    private func readAuthSecret(providerID: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        var urls: [URL] = []
        let identity = IntatisHostApplication.identity
        if let override = environment[
            identity.environmentVariable("AUTH_FILE")]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            urls = [URL(fileURLWithPath: expandedPath(override))]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            urls = [
                identity.userConfigurationDirectory(homeDirectory: home)
                    .appendingPathComponent("auth.json"),
                identity.userDataDirectory(homeDirectory: home)
                    .appendingPathComponent("auth.json"),
            ]
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if let secret = readSecret(providerID: providerID, url: url) { return secret }
        }
        return nil
    }

    private func readProviderConfigSecret(providerID: String, path: String) -> String? {
        readSecret(providerID: providerID, url: URL(fileURLWithPath: path))
    }

    private func readSecret(providerID: String, url: URL) -> String? {
        guard let data = try? JSONC.data(contentsOf: url),
              case .object(let root) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        let providerValue = root.object("provider")?.caseInsensitiveValue(for: providerID)
            ?? root.object("providers")?.caseInsensitiveValue(for: providerID)
            ?? root.caseInsensitiveValue(for: providerID)
        return secretValue(providerValue, configDirectory: url.deletingLastPathComponent())
    }

    private func secretValue(_ value: JSONValue?, configDirectory: URL) -> String? {
        let raw: String?
        switch value {
        case .string(let string):
            raw = string
        case .object(let object):
            let options = object.object("options") ?? [:]
            raw = options.string("apiKey")
                ?? object.string("apiKey")
                ?? object.string("api_key")
                ?? object.string("token")
        default:
            raw = nil
        }
        guard let raw else { return nil }
        if let variable = configVariable(in: raw) {
            switch variable.kind {
            case "env":
                return ProcessInfo.processInfo.environment[variable.value]
            case "file":
                let path = resolvedPath(variable.value, relativeTo: configDirectory)
                return try? String(contentsOfFile: path, encoding: .utf8)
            default:
                return nil
            }
        }
        return raw
    }
}

private enum JSONC {
    static func data(contentsOf url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return data }
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
                        if text[index] == "*", lookahead < text.endIndex, text[lookahead] == "/" {
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

    func stringArray(_ key: String) -> [String]? {
        guard case .array(let values) = self[key] else { return nil }
        return values.compactMap {
            guard case .string(let string) = $0 else { return nil }
            return string
        }
    }

    func caseInsensitiveValue(for key: String) -> JSONValue? {
        if let exact = self[key] { return exact }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return first {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }?.value
    }
}

private func configVariable(in raw: String) -> (kind: String, value: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
    let body = trimmed.dropFirst().dropLast()
    guard let separator = body.firstIndex(of: ":") else { return nil }
    let kind = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let value = body[body.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kind.isEmpty, !value.isEmpty else { return nil }
    return (kind, value)
}

private func resolvedConfigValue(_ raw: String?,
                                 environment: [String: String],
                                 configDirectory: URL) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else { return nil }
    guard let variable = configVariable(in: raw) else { return raw }
    switch variable.kind {
    case "env":
        return environment[variable.value]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    case "file":
        let path = resolvedPath(variable.value, relativeTo: configDirectory)
        return try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    default:
        return raw
    }
}

private func resolvedPath(_ raw: String, relativeTo directory: URL) -> String {
    let expanded = expandedPath(raw)
    if expanded.hasPrefix("/") { return expanded }
    return directory.appendingPathComponent(expanded).standardizedFileURL.path
}

private func expandedPath(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
    if trimmed.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser.path
            + String(trimmed.dropFirst())
    }
    return trimmed
}
