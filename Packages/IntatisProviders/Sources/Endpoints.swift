import Foundation
import IntatisCore
import IntatisProtocol

/// The wire dialect an endpoint speaks. v0.1 ships only `.openai`; adding a
/// dialect later is a new case + a new adapter, with no change to the registry,
/// kernel, or UI (ARCHITECTURE.md §9.2).
public enum WireFormat: String, Codable, Sendable {
    case openai
    // case anthropic, gemini, …  (later)
}

/// A reference to a secret. `keychain` is retained as a legacy wire value, but
/// app resolvers may map it to configuration files. New GUI provider configs use
/// env vars, files, or auth JSON entries instead of OS credential stores.
public enum SecretRefSource: String, Codable, Sendable {
    case keychain
    case environment
    case file
    case authFile
    case providerConfig
}

public struct KeychainRef: Codable, Equatable, Sendable {
    public var service: String
    public var account: String
    public var source: SecretRefSource

    public init(service: String, account: String) {
        self.service = service
        self.account = account
        self.source = .keychain
    }

    public static func environment(_ name: String) -> KeychainRef {
        KeychainRef(source: .environment, service: "environment", account: name)
    }

    public static func file(_ path: String) -> KeychainRef {
        KeychainRef(source: .file, service: "file", account: path)
    }

    public static func authFile(providerID: String) -> KeychainRef {
        KeychainRef(source: .authFile, service: "auth-file", account: providerID)
    }

    public static func providerConfig(path: String, providerID: String) -> KeychainRef {
        KeychainRef(source: .providerConfig, service: path, account: providerID)
    }

    private init(source: SecretRefSource, service: String, account: String) {
        self.service = service
        self.account = account
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case account
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.service = try container.decode(String.self, forKey: .service)
        self.account = try container.decode(String.self, forKey: .account)
        self.source = try container.decodeIfPresent(SecretRefSource.self, forKey: .source) ?? .keychain
    }
}

public protocol SecretResolver: Sendable {
    func secret(for ref: KeychainRef) async throws -> String
}

/// A named provider endpoint. `chat` and `reviewer` can point at different
/// endpoints with different base URLs / keys / wire formats (ARCHITECTURE.md §9.3).
public struct ProviderEndpoint: Codable, Equatable, Sendable {
    public var id: String
    public var baseURL: URL
    public var chatEndpoint: URL?
    public var responsesEndpoint: URL?
    public var apiKeyRef: KeychainRef
    public var wire: WireFormat
    /// Provider SDK option semantics selected by OpenCode-compatible `npm`
    /// configuration. This is separate from the HTTP wire dialect.
    public var requestAdapter: ProviderRequestAdapter
    /// Optional model-level `provider.npm` overrides. OpenCode resolves these
    /// before the provider-level package.
    public var modelRequestAdapters: [String: ProviderRequestAdapter]
    /// Arbitrary model-scoped request body options from the user's provider
    /// configuration. Wire adapters merge the selected model's object into the
    /// outgoing request without enumerating provider-specific keys.
    public var modelRequestOptions: [String: [String: JSONValue]]
    /// Explicit route-scoped model capabilities. Absence is intentionally
    /// conservative: an OpenAI-compatible URL alone never proves deferred
    /// `tool_search` or Chat provider-hosted web-search support.
    public var modelCapabilities: [String: [Capability]]

    public init(id: String, baseURL: URL, chatEndpoint: URL? = nil,
                responsesEndpoint: URL? = nil,
                apiKeyRef: KeychainRef, wire: WireFormat,
                requestAdapter: ProviderRequestAdapter = .legacyOpenAIWire,
                modelRequestAdapters: [String: ProviderRequestAdapter] = [:],
                modelRequestOptions: [String: [String: JSONValue]] = [:],
                modelCapabilities: [String: [Capability]] = [:]) {
        self.id = id
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
        self.responsesEndpoint = responsesEndpoint
        self.apiKeyRef = apiKeyRef
        self.wire = wire
        self.requestAdapter = requestAdapter
        self.modelRequestAdapters = modelRequestAdapters
        self.modelRequestOptions = modelRequestOptions
        self.modelCapabilities = modelCapabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseURL
        case chatEndpoint
        case responsesEndpoint
        case apiKeyRef
        case wire
        case requestAdapter
        case modelRequestAdapters
        case modelRequestOptions
        case modelCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.baseURL = try container.decode(URL.self, forKey: .baseURL)
        self.chatEndpoint = try container.decodeIfPresent(URL.self, forKey: .chatEndpoint)
        self.responsesEndpoint = try container.decodeIfPresent(
            URL.self,
            forKey: .responsesEndpoint)
        self.apiKeyRef = try container.decode(KeychainRef.self, forKey: .apiKeyRef)
        self.wire = try container.decode(WireFormat.self, forKey: .wire)
        self.requestAdapter = try container.decodeIfPresent(
            ProviderRequestAdapter.self,
            forKey: .requestAdapter) ?? .legacyOpenAIWire
        self.modelRequestAdapters = try container.decodeIfPresent(
            [String: ProviderRequestAdapter].self,
            forKey: .modelRequestAdapters) ?? [:]
        self.modelRequestOptions = try container.decodeIfPresent(
            [String: [String: JSONValue]].self,
            forKey: .modelRequestOptions) ?? [:]
        self.modelCapabilities = try container.decodeIfPresent(
            [String: [Capability]].self,
            forKey: .modelCapabilities) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(chatEndpoint, forKey: .chatEndpoint)
        try container.encodeIfPresent(
            responsesEndpoint,
            forKey: .responsesEndpoint)
        try container.encode(apiKeyRef, forKey: .apiKeyRef)
        try container.encode(wire, forKey: .wire)
        if requestAdapter != .legacyOpenAIWire {
            try container.encode(
                requestAdapter,
                forKey: .requestAdapter)
        }
        if !modelRequestAdapters.isEmpty {
            try container.encode(
                modelRequestAdapters,
                forKey: .modelRequestAdapters)
        }
        if !modelRequestOptions.isEmpty {
            try container.encode(modelRequestOptions, forKey: .modelRequestOptions)
        }
        if !modelCapabilities.isEmpty {
            try container.encode(
                modelCapabilities,
                forKey: .modelCapabilities)
        }
    }

    public var chatCompletionsURL: URL {
        chatEndpoint ?? baseURL.appendingPathComponent("chat/completions")
    }

    public var responsesURL: URL {
        responsesEndpoint ?? baseURL.appendingPathComponent("responses")
    }

    public func requestOptions(for model: ModelID) -> [String: JSONValue] {
        modelRequestOptions[model.rawValue] ?? [:]
    }

    public func requestAdapter(
        for model: ModelID
    ) -> ProviderRequestAdapter {
        modelRequestAdapters[model.rawValue] ?? requestAdapter
    }

    public func capabilities(
        for model: ModelID
    ) -> [Capability] {
        modelCapabilities[model.rawValue] ?? []
    }
}

extension ProviderEndpoint {
    func validatedChatCompletionsURL(operation: String) throws -> URL {
        let field = chatEndpoint == nil ? "Base URL" : "Chat endpoint"
        return try Self.validatedHTTPURL(chatCompletionsURL,
                                         endpointID: id,
                                         field: field,
                                         operation: operation)
    }

    func validatedResponsesURL(operation: String) throws -> URL {
        let field = responsesEndpoint == nil
            ? "Base URL"
            : "Responses endpoint"
        return try Self.validatedHTTPURL(
            responsesURL,
            endpointID: id,
            field: field,
            operation: operation)
    }

    func validatedBaseURLAppendingPathComponent(_ pathComponent: String,
                                                operation: String) throws -> URL {
        try Self.validatedHTTPURL(baseURL.appendingPathComponent(pathComponent),
                                  endpointID: id,
                                  field: "Base URL",
                                  operation: operation)
    }

    private static func validatedHTTPURL(_ url: URL,
                                         endpointID: String,
                                         field: String,
                                         operation: String) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw IntatisError.config(
                "invalid provider endpoint '\(endpointID)' for \(operation): \(field) is missing a URL scheme. Use an http:// or https:// URL with a host.")
        }
        guard scheme == "http" || scheme == "https" else {
            throw IntatisError.config(
                "invalid provider endpoint '\(endpointID)' for \(operation): \(field) scheme '\(scheme)' is not supported. Use an http:// or https:// URL with a host.")
        }
        guard let host = url.host, !host.isEmpty else {
            throw IntatisError.config(
                "invalid provider endpoint '\(endpointID)' for \(operation): \(field) host is missing. Check the Base URL or Chat endpoint.")
        }
        return url
    }
}

/// A role binding: which endpoint + which model.
public struct ModelRef: Codable, Equatable, Sendable {
    public var endpoint: String
    public var model: ModelID
    public init(endpoint: String, model: ModelID) {
        self.endpoint = endpoint
        self.model = model
    }
}

/// Default model per role. v0.1 only requires `chat`; the rest are forward slots.
public struct ResolvedModels: Codable, Equatable, Sendable {
    public var chat: ModelRef
    /// Legacy compatibility field decoded from `web_search_model`. Runtime
    /// Chat routing deliberately ignores it; provider-hosted search belongs to
    /// the current exact `chat` route.
    public var webSearch: ModelRef?
    public var agent: ModelRef?
    public var reviewer: ModelRef?
    public var vision: ModelRef?
    public var transcription: ModelRef?
    public var imageGen: ModelRef?
    public var videoGen: ModelRef?
    /// Exact host-owned route used for knowledge document/query embeddings.
    /// Missing configuration stays nil; Knowledge must never fall back to the
    /// current Chat or Agent route.
    public var embedding: ModelRef?
    /// Exact host-owned route used for semantic knowledge reranking. This is a
    /// dedicated model role and must not be substituted with embedding cosine.
    public var reranker: ModelRef?
    public init(chat: ModelRef,
                webSearch: ModelRef? = nil,
                agent: ModelRef? = nil,
                reviewer: ModelRef? = nil,
                vision: ModelRef? = nil,
                transcription: ModelRef? = nil,
                imageGen: ModelRef? = nil,
                videoGen: ModelRef? = nil,
                embedding: ModelRef? = nil,
                reranker: ModelRef? = nil) {
        self.chat = chat
        self.webSearch = webSearch
        self.agent = agent
        self.reviewer = reviewer
        self.vision = vision
        self.transcription = transcription
        self.imageGen = imageGen
        self.videoGen = videoGen
        self.embedding = embedding
        self.reranker = reranker
    }
}

/// The full provider configuration: a set of named endpoints + role bindings.
public struct ProviderConfig: Codable, Equatable, Sendable {
    public var endpoints: [ProviderEndpoint]
    public var models: ResolvedModels
    public init(endpoints: [ProviderEndpoint], models: ResolvedModels) {
        self.endpoints = endpoints
        self.models = models
    }

    public func endpoint(id: String) -> ProviderEndpoint? {
        endpoints.first { $0.id == id }
    }
}
