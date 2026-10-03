#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisProviders requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol

/// An exact reference to one immutable connection definition.
///
/// Connection identity is deliberately separate from provider/model identity:
/// changing the endpoint, wire adapter, credential reference, or trust boundary
/// creates a new revision even when the logical connection ID stays the same.
public struct InferenceConnectionRef: Codable, Equatable, Hashable, Sendable {
    public let inferenceConnectionID: InferenceConnectionID
    public let inferenceConnectionRevision: InferenceConnectionRevision

    public init(inferenceConnectionID: InferenceConnectionID,
                inferenceConnectionRevision: InferenceConnectionRevision) {
        self.inferenceConnectionID = inferenceConnectionID
        self.inferenceConnectionRevision = inferenceConnectionRevision
    }
}

/// Safe classifications used for route review and user-facing attribution.
/// These values are identifiers, not URLs or free-form descriptions.
public struct InferenceConnectionTrust: Codable, Equatable, Sendable {
    public var trustDomain: String
    public var egressClassification: String

    public init(trustDomain: String = "unclassified",
                egressClassification: String = "unknown") {
        self.trustDomain = trustDomain
        self.egressClassification = egressClassification
    }
}

/// One immutable connection revision. It stores only a credential reference;
/// secret material remains lazy and outside the catalog.
public struct InferenceConnectionDefinition: Codable, Equatable, Sendable {
    public let connectionRef: InferenceConnectionRef
    public let wire: WireFormat
    public let requestAdapter: ProviderRequestAdapter
    public let baseURL: URL
    public let chatEndpoint: URL?
    public let credentialRef: KeychainRef
    public let trust: InferenceConnectionTrust
    public let defaultRequestOptions: [String: JSONValue]

    public init(connectionRef: InferenceConnectionRef,
                wire: WireFormat,
                requestAdapter: ProviderRequestAdapter = .legacyOpenAIWire,
                baseURL: URL,
                chatEndpoint: URL? = nil,
                credentialRef: KeychainRef,
                trust: InferenceConnectionTrust = InferenceConnectionTrust(),
                defaultRequestOptions: [String: JSONValue] = [:]) {
        self.connectionRef = connectionRef
        self.wire = wire
        self.requestAdapter = requestAdapter
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
        self.credentialRef = credentialRef
        self.trust = trust
        self.defaultRequestOptions = defaultRequestOptions
    }

    private enum CodingKeys: String, CodingKey {
        case connectionRef
        case wire
        case requestAdapter
        case baseURL
        case chatEndpoint
        case credentialRef
        case trust
        case defaultRequestOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self)
        connectionRef = try container.decode(
            InferenceConnectionRef.self,
            forKey: .connectionRef)
        wire = try container.decode(
            WireFormat.self,
            forKey: .wire)
        requestAdapter = try container.decodeIfPresent(
            ProviderRequestAdapter.self,
            forKey: .requestAdapter) ?? .legacyOpenAIWire
        baseURL = try container.decode(
            URL.self,
            forKey: .baseURL)
        chatEndpoint = try container.decodeIfPresent(
            URL.self,
            forKey: .chatEndpoint)
        credentialRef = try container.decode(
            KeychainRef.self,
            forKey: .credentialRef)
        trust = try container.decode(
            InferenceConnectionTrust.self,
            forKey: .trust)
        defaultRequestOptions = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .defaultRequestOptions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self)
        try container.encode(
            connectionRef,
            forKey: .connectionRef)
        try container.encode(wire, forKey: .wire)
        if requestAdapter != .legacyOpenAIWire {
            try container.encode(
                requestAdapter,
                forKey: .requestAdapter)
        }
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(
            chatEndpoint,
            forKey: .chatEndpoint)
        try container.encode(
            credentialRef,
            forKey: .credentialRef)
        try container.encode(trust, forKey: .trust)
        // Schema v1 readers predate requestAdapter and decode this original
        // field as required. Keep emitting it even when empty so the additive
        // adapter field does not break reverse compatibility.
        try container.encode(
            defaultRequestOptions,
            forKey: .defaultRequestOptions)
    }
}

/// One immutable profile revision. `effectiveRequestOptions` is the already
/// resolved OpenCode-compatible deep overlay of
/// connection/model/variant/profile layers.
public struct InferenceProfileDefinition: Codable, Equatable, Sendable {
    public let profileRef: InferenceProfileRef
    public let connectionRef: InferenceConnectionRef
    public let modelID: ModelID
    public let variantID: String?
    public let effectiveRequestOptions: [String: JSONValue]
    public let requestAdapter: ProviderRequestAdapter
    public let modelContextPolicy: AgentModelContextPolicy
    public let declaredCapabilities: [Capability]
    public let safeRouteLabel: String?

    public init(profileRef: InferenceProfileRef,
                connectionRef: InferenceConnectionRef,
                modelID: ModelID,
                variantID: String? = nil,
                effectiveRequestOptions: [String: JSONValue] = [:],
                requestAdapter: ProviderRequestAdapter = .legacyOpenAIWire,
                modelContextPolicy: AgentModelContextPolicy = .unspecified,
                declaredCapabilities: [Capability] = [],
                safeRouteLabel: String? = nil) {
        self.profileRef = profileRef
        self.connectionRef = connectionRef
        self.modelID = modelID
        self.variantID = variantID
        self.effectiveRequestOptions = effectiveRequestOptions
        self.requestAdapter = requestAdapter
        self.modelContextPolicy = modelContextPolicy
        self.declaredCapabilities = declaredCapabilities
        self.safeRouteLabel = safeRouteLabel
    }

    private enum CodingKeys: String, CodingKey {
        case profileRef
        case connectionRef
        case modelID
        case variantID
        case effectiveRequestOptions
        case requestAdapter
        case modelContextPolicy
        case declaredCapabilities
        case safeRouteLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileRef =
            try container.decode(
                InferenceProfileRef.self,
                forKey: .profileRef)
        connectionRef =
            try container.decode(
                InferenceConnectionRef.self,
                forKey: .connectionRef)
        modelID =
            try container.decode(
                ModelID.self,
                forKey: .modelID)
        variantID =
            try container.decodeIfPresent(
                String.self,
                forKey: .variantID)
        effectiveRequestOptions =
            try container.decodeIfPresent(
                [String: JSONValue].self,
                forKey: .effectiveRequestOptions)
            ?? [:]
        requestAdapter =
            try container.decodeIfPresent(
                ProviderRequestAdapter.self,
                forKey: .requestAdapter)
            ?? .legacyOpenAIWire
        modelContextPolicy =
            try container.decodeIfPresent(
                AgentModelContextPolicy.self,
                forKey: .modelContextPolicy)
            ?? .unspecified
        declaredCapabilities =
            try container.decodeIfPresent(
                [Capability].self,
                forKey: .declaredCapabilities)
            ?? []
        safeRouteLabel =
            try container.decodeIfPresent(
                String.self,
                forKey: .safeRouteLabel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileRef, forKey: .profileRef)
        try container.encode(connectionRef, forKey: .connectionRef)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(variantID, forKey: .variantID)
        try container.encode(
            effectiveRequestOptions,
            forKey: .effectiveRequestOptions)
        if requestAdapter != .legacyOpenAIWire {
            try container.encode(
                requestAdapter,
                forKey: .requestAdapter)
        }
        if modelContextPolicy != .unspecified {
            try container.encode(
                modelContextPolicy,
                forKey: .modelContextPolicy)
        }
        try container.encode(
            declaredCapabilities,
            forKey: .declaredCapabilities)
        try container.encodeIfPresent(
            safeRouteLabel,
            forKey: .safeRouteLabel)
    }

    /// A route-safe digest for durable binding revalidation. The digest covers
    /// canonical, validated non-secret semantics so a definition rewritten in
    /// place cannot satisfy an older binding. Only the digest leaves the
    /// catalog; endpoints, credential references, and raw options do not.
    public func immutableDefinitionFingerprint(
        connection: InferenceConnectionDefinition
    ) -> String {
        let capabilities = declaredCapabilities.map(\.rawValue).sorted().joined(separator: ",")
        var fields = [
            "profile",
            profileRef.inferenceProfileID.rawValue,
            profileRef.inferenceProfileRevision.rawValue,
            connectionRef.inferenceConnectionID.rawValue,
            connectionRef.inferenceConnectionRevision.rawValue,
            modelID.rawValue,
            variantID ?? "",
            connection.wire.rawValue,
            connection.baseURL.absoluteString,
            connection.chatEndpoint?.absoluteString ?? "",
            connection.credentialRef.source.rawValue,
            connection.credentialRef.service,
            connection.credentialRef.account,
            connection.trust.trustDomain,
            connection.trust.egressClassification,
            InferenceIdentityFingerprint.canonical(connection.defaultRequestOptions),
            InferenceIdentityFingerprint.canonical(effectiveRequestOptions),
            capabilities,
            safeRouteLabel ?? "",
        ]
        if connection.requestAdapter !=
            .legacyOpenAIWire {
            fields.append(
                "connection-request-adapter")
            fields.append(
                connection.requestAdapter.rawValue)
        }
        if requestAdapter != .legacyOpenAIWire {
            fields.append("profile-request-adapter")
            fields.append(requestAdapter.rawValue)
        }
        fields.append(contentsOf: modelContextPolicy.fingerprintComponents)
        return InferenceIdentityFingerprint.sha256(fields)
    }
}

/// Mutable connection input. Reconciliation turns this into an immutable,
/// versioned definition without mutating any prior revision.
public struct InferenceConnectionDraft: Equatable, Sendable {
    public var inferenceConnectionID: InferenceConnectionID
    public var wire: WireFormat
    public var requestAdapter: ProviderRequestAdapter
    public var baseURL: URL
    public var chatEndpoint: URL?
    public var credentialRef: KeychainRef
    public var trust: InferenceConnectionTrust
    public var defaultRequestOptions: [String: JSONValue]

    public init(inferenceConnectionID: InferenceConnectionID,
                wire: WireFormat,
                requestAdapter: ProviderRequestAdapter = .legacyOpenAIWire,
                baseURL: URL,
                chatEndpoint: URL? = nil,
                credentialRef: KeychainRef,
                trust: InferenceConnectionTrust = InferenceConnectionTrust(),
                defaultRequestOptions: [String: JSONValue] = [:]) {
        self.inferenceConnectionID = inferenceConnectionID
        self.wire = wire
        self.requestAdapter = requestAdapter
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
        self.credentialRef = credentialRef
        self.trust = trust
        self.defaultRequestOptions = defaultRequestOptions
    }
}

/// Mutable profile input. Provider-specific keys remain opaque. Shared plain
/// objects are recursively overlaid with later layers winning; arrays and
/// scalar/null values are replaced, matching OpenCode's `mergeDeep` behavior.
public struct InferenceProfileDraft: Equatable, Sendable {
    public var inferenceProfileID: InferenceProfileID
    public var inferenceConnectionID: InferenceConnectionID
    public var modelID: ModelID
    public var variantID: String?
    public var modelBaseRequestOptions: [String: JSONValue]
    public var variantRequestOptions: [String: JSONValue]
    public var profileRequestOptions: [String: JSONValue]
    public var requestAdapterOverride: ProviderRequestAdapter?
    public var modelContextPolicy: AgentModelContextPolicy
    public var declaredCapabilities: [Capability]
    public var safeRouteLabel: String?

    public init(inferenceProfileID: InferenceProfileID,
                inferenceConnectionID: InferenceConnectionID,
                modelID: ModelID,
                variantID: String? = nil,
                modelBaseRequestOptions: [String: JSONValue] = [:],
                variantRequestOptions: [String: JSONValue] = [:],
                profileRequestOptions: [String: JSONValue] = [:],
                requestAdapterOverride: ProviderRequestAdapter? = nil,
                modelContextPolicy: AgentModelContextPolicy = .unspecified,
                declaredCapabilities: [Capability] = [],
                safeRouteLabel: String? = nil) {
        self.inferenceProfileID = inferenceProfileID
        self.inferenceConnectionID = inferenceConnectionID
        self.modelID = modelID
        self.variantID = variantID
        self.modelBaseRequestOptions = modelBaseRequestOptions
        self.variantRequestOptions = variantRequestOptions
        self.profileRequestOptions = profileRequestOptions
        self.requestAdapterOverride = requestAdapterOverride
        self.modelContextPolicy = modelContextPolicy
        self.declaredCapabilities = declaredCapabilities
        self.safeRouteLabel = safeRouteLabel
    }
}

public struct InferenceCatalogDraft: Equatable, Sendable {
    public var connections: [InferenceConnectionDraft]
    public var profiles: [InferenceProfileDraft]

    public init(connections: [InferenceConnectionDraft],
                profiles: [InferenceProfileDraft]) {
        self.connections = connections
        self.profiles = profiles
    }
}

/// Durable catalog value. Arrays contain every retained immutable revision;
/// `current*Refs` are mutable selection pointers used only for new bindings.
public struct InferenceCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var connections: [InferenceConnectionDefinition]
    public var profiles: [InferenceProfileDefinition]
    public var currentConnectionRefs: [InferenceConnectionRef]
    public var currentProfileRefs: [InferenceProfileRef]

    public init(schemaVersion: Int = InferenceCatalog.currentSchemaVersion,
                connections: [InferenceConnectionDefinition],
                profiles: [InferenceProfileDefinition],
                currentConnectionRefs: [InferenceConnectionRef] = [],
                currentProfileRefs: [InferenceProfileRef] = []) {
        self.schemaVersion = schemaVersion
        self.connections = connections
        self.profiles = profiles
        self.currentConnectionRefs = currentConnectionRefs
        self.currentProfileRefs = currentProfileRefs
    }

    public static let empty = InferenceCatalog(connections: [], profiles: [])
}

/// Atomic, secret-free result of exact profile resolution. It contains matching
/// connection and profile revisions from the same immutable snapshot.
public struct InferenceProfileResolution: Equatable, Sendable {
    public let connection: InferenceConnectionDefinition
    public let profile: InferenceProfileDefinition

    public init(connection: InferenceConnectionDefinition,
                profile: InferenceProfileDefinition) {
        self.connection = connection
        self.profile = profile
    }

    public var binding: AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: profile.profileRef,
            inferenceConnectionID: connection.connectionRef.inferenceConnectionID,
            inferenceConnectionRevision: connection.connectionRef.inferenceConnectionRevision,
            modelID: profile.modelID,
            variantID: profile.variantID,
            safeRouteLabel: profile.safeRouteLabel,
            trustDomain: connection.trust.trustDomain,
            egressClassification: connection.trust.egressClassification,
            immutableDefinitionFingerprint: profile.immutableDefinitionFingerprint(connection: connection))
    }
}

/// Sanitized failures. Descriptions intentionally never echo URLs, credential
/// references, or raw request-option keys/values.
public enum InferenceCatalogError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion
    case invalidIdentifier
    case invalidRevision
    case invalidConnection
    case invalidProfile
    case duplicateDefinition
    case unresolvedConnection
    case unresolvedProfile
    case bindingMismatch
    case incompatibleProfileCapability
    case secretLikeRequestOptions
    case unsupportedDurableRequestOptions
    case storeCorrupted
    case storeInsecurePermissions
    case storeIO

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return "The inference catalog schema is not supported."
        case .invalidIdentifier:
            return "The inference catalog contains an invalid identifier."
        case .invalidRevision:
            return "The inference catalog contains an invalid revision."
        case .invalidConnection:
            return "The inference catalog contains an invalid connection definition."
        case .invalidProfile:
            return "The inference catalog contains an invalid profile definition."
        case .duplicateDefinition:
            return "The inference catalog contains duplicate immutable definitions."
        case .unresolvedConnection:
            return "The exact inference connection revision is unavailable."
        case .unresolvedProfile:
            return "The exact inference profile revision is unavailable."
        case .bindingMismatch:
            return "The inference binding does not match its immutable profile definition."
        case .incompatibleProfileCapability:
            return "The inference profile is incompatible with the requested provider capability."
        case .secretLikeRequestOptions:
            return "Inference request options contain secret-like material and cannot be persisted."
        case .unsupportedDurableRequestOptions:
            return "Inference request options are outside the explicit durable option schema."
        case .storeCorrupted:
            return "The inference catalog store is corrupted and cannot be used."
        case .storeInsecurePermissions:
            return "The inference catalog store permissions are not secure."
        case .storeIO:
            return "The inference catalog store could not be read or written safely."
        }
    }
}

/// Recursive fail-closed guard for options that are eligible for durable
/// profile storage. It is deliberately conservative: credentials belong in a
/// `KeychainRef`, never in request-body options.
public enum InferenceRequestOptionValidation {
    public static func validateNoSecretLikeMaterial(_ options: [String: JSONValue]) throws {
        guard !containsSecretLikeMaterial(.object(options)) else {
            throw InferenceCatalogError.secretLikeRequestOptions
        }
    }

    public static func validateDurableRequestOptions(
        _ options: [String: JSONValue]
    ) throws {
        try validateNoSecretLikeMaterial(options)
        guard conformsToDurableSchema(options) else {
            throw InferenceCatalogError.unsupportedDurableRequestOptions
        }
    }

    /// Validates the one opaque subtree that may cross into an external
    /// Responses runtime without Intatis interpreting provider-owned keys.
    public static func validateProviderPassthrough(
        _ options: [String: JSONValue]
    ) throws {
        try validateNoSecretLikeMaterial([
            "provider": .object(options),
        ])
        guard boundedOpaqueProviderValue(
            .object(options),
            depth: 0) else {
            throw InferenceCatalogError.unsupportedDurableRequestOptions
        }
    }

    /// Source-compatible spelling retained for callers created with the first
    /// catalog draft. Durable catalog inputs receive both secret scanning and
    /// explicit-schema validation; presentation labels must call the narrower
    /// `validateNoSecretLikeMaterial` API instead.
    public static func validateNonSecret(_ options: [String: JSONValue]) throws {
        try validateDurableRequestOptions(options)
    }

    /// The versioned Cowork catalog persists only fields whose request-body
    /// meaning is explicitly classified as non-secret. App/Chat configuration
    /// may still keep arbitrary provider options in memory and pass them to its
    /// legacy endpoint adapter; adding a new durable Cowork option requires an
    /// intentional schema extension here rather than a heuristic allow.
    private static let numericTopLevelKeys: Set<String> = [
        "temperature", "topp", "topk", "minp", "typicalp",
        "frequencypenalty", "presencepenalty", "repetitionpenalty",
        "seed", "maxtokens", "maxcompletiontokens", "maxoutputtokens",
        "maxnewtokens", "toplogprobs",
    ]

    private static let booleanTopLevelKeys: Set<String> = [
        "logprobs", "paralleltoolcalls",
    ]

    private static let safeTokenTopLevelKeys: Set<String> = [
        "reasoningeffort", "verbosity", "servicetier",
    ]

    private static func conformsToDurableSchema(_ options: [String: JSONValue]) -> Bool {
        options.allSatisfy { rawKey, value in
            let key = normalizedKey(rawKey)
            if numericTopLevelKeys.contains(key) {
                return finiteNumber(value)
            }
            if booleanTopLevelKeys.contains(key) {
                return boolean(value)
            }
            if safeTokenTopLevelKeys.contains(key) {
                return safeToken(value)
            }
            switch key {
            case "reasoning":
                return allowedObject(value) { nestedKey, nestedValue in
                    switch nestedKey {
                    case "effort", "summary": return safeToken(nestedValue)
                    case "maxtokens", "budgettokens": return finiteNumber(nestedValue)
                    case "enabled": return boolean(nestedValue)
                    default: return false
                    }
                }
            case "thinking":
                return allowedObject(value) { nestedKey, nestedValue in
                    switch nestedKey {
                    case "type", "level": return safeToken(nestedValue)
                    case "budgettokens", "maxtokens": return finiteNumber(nestedValue)
                    case "enabled": return boolean(nestedValue)
                    default: return false
                    }
                }
            case "outputconfig":
                return allowedObject(value) { nestedKey, nestedValue in
                    switch nestedKey {
                    case "effort", "verbosity": return safeToken(nestedValue)
                    default: return false
                    }
                }
            case "provider":
                guard case .object = value else { return false }
                return boundedOpaqueProviderValue(value, depth: 0)
            default:
                return false
            }
        }
    }

    private static func allowedObject(
        _ value: JSONValue,
        validator: (String, JSONValue) -> Bool
    ) -> Bool {
        guard case .object(let object) = value, object.count <= 32 else { return false }
        return object.allSatisfy { validator(normalizedKey($0.key), $0.value) }
    }

    private static func finiteNumber(_ value: JSONValue) -> Bool {
        guard case .number(let number) = value else { return false }
        return number.isFinite
    }

    private static func boolean(_ value: JSONValue) -> Bool {
        if case .bool = value { return true }
        return false
    }

    private static func safeToken(_ value: JSONValue) -> Bool {
        guard case .string(let raw) = value else { return false }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 128, token == raw else { return false }
        return token.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || "-_.:/+".unicodeScalars.contains($0)
        }
    }

    /// Provider-owned request options are opaque to Intatis. Keep only
    /// structural resource bounds here; the secret/transport-key scan runs
    /// before this function and the exact provider owns field semantics.
    private static func boundedOpaqueProviderValue(
        _ value: JSONValue,
        depth: Int
    ) -> Bool {
        guard depth <= 8 else { return false }
        switch value {
        case .null, .bool:
            return true
        case .number(let number):
            return number.isFinite
        case .string(let string):
            return string.count <= 2_048
                && string.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        case .array(let values):
            return values.count <= 128
                && values.allSatisfy {
                    boundedOpaqueProviderValue($0, depth: depth + 1)
                }
        case .object(let object):
            return object.count <= 64
                && object.allSatisfy { key, nested in
                    !key.isEmpty
                        && key.count <= 128
                        && key.unicodeScalars.allSatisfy {
                            !CharacterSet.controlCharacters.contains($0)
                        }
                        && boundedOpaqueProviderValue(
                            nested,
                            depth: depth + 1)
                }
        }
    }

    private static let deniedNormalizedKeys: Set<String> = [
        "authorization", "proxyauthorization", "apikey", "xapikey",
        "token", "accesstoken", "refreshtoken", "idtoken", "bearertoken",
        "clientsecret", "secret", "password", "passwd", "credential",
        "credentials", "cookie", "setcookie", "privatekey",
    ]

    /// Raw header/query/transport maps cannot be proven non-secret. They need a
    /// future typed reference surface instead of being copied into the durable
    /// versioned catalog.
    private static let deniedNormalizedContainers: Set<String> = [
        "header", "headers", "extraheader", "extraheaders", "requestheader",
        "requestheaders", "httpheader", "httpheaders", "query", "queryparams",
        "queryparameters", "url", "baseurl", "endpoint", "proxyurl",
    ]

    private static let secretPrefixes = [
        "sk-", "ghp_", "github_pat_", "glpat-", "xoxb-", "xoxa-",
        "xoxp-", "xoxr-", "akia", "asia",
    ]

    private static func containsSecretLikeMaterial(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool, .number:
            return false
        case .string(let string):
            return secretLikeString(string)
        case .array(let values):
            return values.contains(where: containsSecretLikeMaterial)
        case .object(let object):
            for (key, nested) in object {
                let normalized = normalizedKey(key)
                if deniedNormalizedKeys.contains(normalized)
                    || deniedNormalizedContainers.contains(normalized)
                    || normalized.contains("authorization")
                    || normalized.contains("credential")
                    || normalized.contains("clientsecret")
                    || normalized.contains("privatekey")
                    || normalized.contains("apikey")
                    || normalized.hasSuffix("auth")
                    || normalized.hasPrefix("auth") {
                    return true
                }
                if containsSecretLikeMaterial(nested) {
                    return true
                }
            }
            return false
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func secretLikeString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty else { return false }

        if lower.contains("-----begin ") && lower.contains("private key-----") {
            return true
        }
        if lower.hasPrefix("bearer ") || lower.hasPrefix("basic ") {
            return true
        }
        if lower.contains("api_key=") || lower.contains("apikey=")
            || lower.contains("access_token=") || lower.contains("refresh_token=") {
            return true
        }
        if lower.contains("://"),
           let schemeRange = lower.range(of: "://"),
           lower[schemeRange.upperBound...].split(separator: "/", maxSplits: 1).first?.contains("@") == true {
            return true
        }

        let compact = lower.filter { !$0.isWhitespace }
        if compact.count >= 16,
           secretPrefixes.contains(where: { compact.hasPrefix($0.filter { !$0.isWhitespace }) }) {
            return true
        }
        // JWTs are three sizeable base64url-looking segments. Do not flag
        // ordinary dotted model names or version strings.
        let jwtParts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if jwtParts.count == 3,
           jwtParts.allSatisfy({ $0.count >= 12 && $0.allSatisfy(isBase64URLCharacter) }) {
            return true
        }
        return false
    }

    private static func isBase64URLCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}

/// Shared top-level overlay used by catalog reconciliation. Every layer must
/// first conform to the explicit durable non-secret schema; accepted values are
/// then retained byte-for-byte at the JSON-value level.
public enum InferenceRequestOptionMerge {
    public static func shallowMerge(_ layers: [[String: JSONValue]]) throws -> [String: JSONValue] {
        for layer in layers {
            try InferenceRequestOptionValidation.validateDurableRequestOptions(layer)
        }
        var result: [String: JSONValue] = [:]
        for layer in layers {
            result.merge(layer) { _, newer in newer }
        }
        return result
    }

    /// OpenCode uses Remeda `mergeDeep`: shared values recurse only when both
    /// sides are plain objects; arrays and every scalar/null value from the
    /// newer layer replace the older value.
    public static func deepMerge(
        _ layers: [[String: JSONValue]]
    ) throws -> [String: JSONValue] {
        for layer in layers {
            try InferenceRequestOptionValidation
                .validateDurableRequestOptions(layer)
        }
        return deepOverlay(layers)
    }

    /// Pure JSON overlay used by non-durable Chat configuration after decoding.
    /// Callers persisting the result must use `deepMerge` so validation remains
    /// part of the durable transaction.
    public static func deepOverlay(
        _ layers: [[String: JSONValue]]
    ) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for layer in layers {
            result = deepOverlay(
                destination: result,
                source: layer)
        }
        return result
    }

    private static func deepOverlay(
        destination: [String: JSONValue],
        source: [String: JSONValue]
    ) -> [String: JSONValue] {
        var result = destination
        for (key, sourceValue) in source {
            if case .object(let destinationObject)? =
                    destination[key],
               case .object(let sourceObject) =
                    sourceValue {
                result[key] = .object(
                    deepOverlay(
                        destination:
                            destinationObject,
                        source:
                            sourceObject))
            } else {
                result[key] = sourceValue
            }
        }
        return result
    }
}

/// Immutable exact-ref resolver. It never substitutes a current/default
/// profile when an exact revision is unavailable.
public struct InferenceCatalogSnapshot: Sendable {
    public let catalog: InferenceCatalog

    private let connectionsByRef: [InferenceConnectionRef: InferenceConnectionDefinition]
    private let profilesByRef: [InferenceProfileRef: InferenceProfileDefinition]
    private let currentConnectionsByID: [InferenceConnectionID: InferenceConnectionRef]
    private let currentProfilesByID: [InferenceProfileID: InferenceProfileRef]

    public init(catalog: InferenceCatalog) throws {
        guard catalog.schemaVersion == InferenceCatalog.currentSchemaVersion else {
            throw InferenceCatalogError.unsupportedSchemaVersion
        }

        var connections: [InferenceConnectionRef: InferenceConnectionDefinition] = [:]
        for definition in catalog.connections {
            try Self.validate(definition)
            guard connections.updateValue(definition, forKey: definition.connectionRef) == nil else {
                throw InferenceCatalogError.duplicateDefinition
            }
        }

        var profiles: [InferenceProfileRef: InferenceProfileDefinition] = [:]
        for definition in catalog.profiles {
            try Self.validate(definition)
            guard connections[definition.connectionRef] != nil else {
                throw InferenceCatalogError.unresolvedConnection
            }
            guard profiles.updateValue(definition, forKey: definition.profileRef) == nil else {
                throw InferenceCatalogError.duplicateDefinition
            }
        }

        var currentConnections: [InferenceConnectionID: InferenceConnectionRef] = [:]
        for ref in catalog.currentConnectionRefs {
            guard connections[ref] != nil else {
                throw InferenceCatalogError.unresolvedConnection
            }
            guard currentConnections.updateValue(ref, forKey: ref.inferenceConnectionID) == nil else {
                throw InferenceCatalogError.duplicateDefinition
            }
        }

        var currentProfiles: [InferenceProfileID: InferenceProfileRef] = [:]
        for ref in catalog.currentProfileRefs {
            guard profiles[ref] != nil else {
                throw InferenceCatalogError.unresolvedProfile
            }
            guard currentProfiles.updateValue(ref, forKey: ref.inferenceProfileID) == nil else {
                throw InferenceCatalogError.duplicateDefinition
            }
        }

        self.catalog = catalog
        self.connectionsByRef = connections
        self.profilesByRef = profiles
        self.currentConnectionsByID = currentConnections
        self.currentProfilesByID = currentProfiles
    }

    public func connection(for ref: InferenceConnectionRef) throws -> InferenceConnectionDefinition {
        guard let definition = connectionsByRef[ref] else {
            throw InferenceCatalogError.unresolvedConnection
        }
        return definition
    }

    public func profile(for ref: InferenceProfileRef) throws -> InferenceProfileDefinition {
        guard let definition = profilesByRef[ref] else {
            throw InferenceCatalogError.unresolvedProfile
        }
        return definition
    }

    public func currentConnectionRef(for id: InferenceConnectionID) -> InferenceConnectionRef? {
        currentConnectionsByID[id]
    }

    public func currentProfileRef(for id: InferenceProfileID) -> InferenceProfileRef? {
        currentProfilesByID[id]
    }

    public func resolve(_ ref: InferenceProfileRef) throws -> InferenceProfileResolution {
        let profile = try profile(for: ref)
        let connection = try connection(for: profile.connectionRef)
        return InferenceProfileResolution(connection: connection, profile: profile)
    }

    public func resolve(_ binding: AgentInferenceBinding) throws -> InferenceProfileResolution {
        let resolution = try resolve(binding.inferenceProfileRef)
        let expected = resolution.binding
        guard binding.inferenceConnectionID == expected.inferenceConnectionID,
              binding.inferenceConnectionRevision == expected.inferenceConnectionRevision,
              binding.modelID == expected.modelID,
              binding.variantID == expected.variantID,
              binding.safeRouteLabel == expected.safeRouteLabel,
              binding.trustDomain == expected.trustDomain,
              binding.egressClassification == expected.egressClassification,
              binding.immutableDefinitionFingerprint == expected.immutableDefinitionFingerprint else {
            throw InferenceCatalogError.bindingMismatch
        }
        return resolution
    }

    private static func validate(_ definition: InferenceConnectionDefinition) throws {
        try validateIdentifier(definition.connectionRef.inferenceConnectionID.rawValue)
        try validateRevision(definition.connectionRef.inferenceConnectionRevision.rawValue)
        guard validHTTPURL(definition.baseURL),
              definition.chatEndpoint.map(validHTTPURL) ?? true,
              validClassification(definition.trust.trustDomain),
              validClassification(definition.trust.egressClassification) else {
            throw InferenceCatalogError.invalidConnection
        }
        try InferenceRequestOptionValidation.validateDurableRequestOptions(
            definition.defaultRequestOptions)
    }

    private static func validate(_ definition: InferenceProfileDefinition) throws {
        try validateIdentifier(definition.profileRef.inferenceProfileID.rawValue)
        try validateRevision(definition.profileRef.inferenceProfileRevision.rawValue)
        try validateIdentifier(definition.connectionRef.inferenceConnectionID.rawValue)
        try validateRevision(definition.connectionRef.inferenceConnectionRevision.rawValue)
        try validateIdentifier(definition.modelID.rawValue)
        if let variantID = definition.variantID {
            try validateIdentifier(variantID)
        }
        if let label = definition.safeRouteLabel, !validRouteLabel(label) {
            throw InferenceCatalogError.invalidProfile
        }
        let capabilityNames = definition.declaredCapabilities.map(\.rawValue)
        guard Set(capabilityNames).count == capabilityNames.count,
              definition.modelContextPolicy.isValidForCatalog else {
            throw InferenceCatalogError.invalidProfile
        }
        try InferenceRequestOptionValidation.validateDurableRequestOptions(
            definition.effectiveRequestOptions)
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw InferenceCatalogError.invalidIdentifier
        }
    }

    private static func validateRevision(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 128,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw InferenceCatalogError.invalidRevision
        }
    }

    private static func validHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.user == nil && url.password == nil
    }

    private static func validClassification(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
            }
    }

    private static func validRouteLabel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0)
            }
    }
}

/// Pure reconciliation of mutable drafts into immutable revisions. Existing
/// definitions are retained; equal semantics reuse an old revision, while any
/// semantic change appends a new revision.
public enum InferenceCatalogReconciler {
    public static func reconcile(existing: InferenceCatalog = .empty,
                                 draft: InferenceCatalogDraft) throws -> InferenceCatalog {
        _ = try InferenceCatalogSnapshot(catalog: existing)
        try validateUniqueDraftIDs(draft)

        var connections = existing.connections
        var currentConnectionRefs: [InferenceConnectionRef] = []
        var currentConnectionsByID: [InferenceConnectionID: InferenceConnectionDefinition] = [:]

        for connectionDraft in draft.connections {
            let normalized = try normalized(connectionDraft)
            let matching = connections.first {
                $0.connectionRef.inferenceConnectionID == normalized.inferenceConnectionID
                    && semanticallyEqual($0, normalized)
            }
            let definition: InferenceConnectionDefinition
            if let matching {
                definition = matching
            } else {
                let ref = InferenceConnectionRef(
                    inferenceConnectionID: normalized.inferenceConnectionID,
                    inferenceConnectionRevision: nextConnectionRevision(
                        for: normalized.inferenceConnectionID,
                        in: connections))
                definition = InferenceConnectionDefinition(
                    connectionRef: ref,
                    wire: normalized.wire,
                    requestAdapter:
                        normalized.requestAdapter,
                    baseURL: normalized.baseURL,
                    chatEndpoint: normalized.chatEndpoint,
                    credentialRef: normalized.credentialRef,
                    trust: normalized.trust,
                    defaultRequestOptions: normalized.defaultRequestOptions)
                connections.append(definition)
            }
            currentConnectionRefs.append(definition.connectionRef)
            currentConnectionsByID[normalized.inferenceConnectionID] = definition
        }

        var profiles = existing.profiles
        var currentProfileRefs: [InferenceProfileRef] = []
        for profileDraft in draft.profiles {
            guard let connection = currentConnectionsByID[profileDraft.inferenceConnectionID] else {
                throw InferenceCatalogError.unresolvedConnection
            }
            let normalized = try normalized(profileDraft, connection: connection)
            let matching = profiles.first {
                $0.profileRef.inferenceProfileID == normalized.inferenceProfileID
                    && semanticallyEqual($0, normalized, connectionRef: connection.connectionRef)
            }
            let definition: InferenceProfileDefinition
            if let matching {
                definition = matching
            } else {
                let ref = InferenceProfileRef(
                    inferenceProfileID: normalized.inferenceProfileID,
                    inferenceProfileRevision: nextProfileRevision(
                        for: normalized.inferenceProfileID,
                        in: profiles))
                definition = InferenceProfileDefinition(
                    profileRef: ref,
                    connectionRef: connection.connectionRef,
                    modelID: normalized.modelID,
                    variantID: normalized.variantID,
                    effectiveRequestOptions: normalized.effectiveRequestOptions,
                    requestAdapter:
                        normalized.requestAdapter,
                    modelContextPolicy: normalized.modelContextPolicy,
                    declaredCapabilities: normalized.declaredCapabilities,
                    safeRouteLabel: normalized.safeRouteLabel)
                profiles.append(definition)
            }
            currentProfileRefs.append(definition.profileRef)
        }

        connections.sort(by: connectionDefinitionOrder)
        profiles.sort(by: profileDefinitionOrder)
        currentConnectionRefs.sort(by: connectionRefOrder)
        currentProfileRefs.sort(by: profileRefOrder)

        let catalog = InferenceCatalog(
            connections: connections,
            profiles: profiles,
            currentConnectionRefs: currentConnectionRefs,
            currentProfileRefs: currentProfileRefs)
        _ = try InferenceCatalogSnapshot(catalog: catalog)
        return catalog
    }

    private struct NormalizedProfileDraft {
        var inferenceProfileID: InferenceProfileID
        var modelID: ModelID
        var variantID: String?
        var effectiveRequestOptions: [String: JSONValue]
        var requestAdapter: ProviderRequestAdapter
        var modelContextPolicy: AgentModelContextPolicy
        var declaredCapabilities: [Capability]
        var safeRouteLabel: String?
    }

    private static func normalized(_ draft: InferenceConnectionDraft) throws -> InferenceConnectionDraft {
        try validateDraftIdentifier(draft.inferenceConnectionID.rawValue)
        try InferenceRequestOptionValidation.validateDurableRequestOptions(
            draft.defaultRequestOptions)
        guard validHTTPURL(draft.baseURL),
              draft.chatEndpoint.map(validHTTPURL) ?? true,
              validClassification(draft.trust.trustDomain),
              validClassification(draft.trust.egressClassification) else {
            throw InferenceCatalogError.invalidConnection
        }
        return draft
    }

    private static func normalized(_ draft: InferenceProfileDraft,
                                   connection: InferenceConnectionDefinition) throws -> NormalizedProfileDraft {
        try validateDraftIdentifier(draft.inferenceProfileID.rawValue)
        try validateDraftIdentifier(draft.modelID.rawValue)
        if let variantID = draft.variantID {
            try validateDraftIdentifier(variantID)
        }
        if let label = draft.safeRouteLabel, !validRouteLabel(label) {
            throw InferenceCatalogError.invalidProfile
        }
        guard draft.modelContextPolicy.isValidForCatalog else {
            throw InferenceCatalogError.invalidProfile
        }
        let effective = try InferenceRequestOptionMerge.deepMerge([
            connection.defaultRequestOptions,
            draft.modelBaseRequestOptions,
            draft.variantRequestOptions,
            draft.profileRequestOptions,
        ])
        var capabilitiesByName: [String: Capability] = [:]
        for capability in draft.declaredCapabilities {
            capabilitiesByName[capability.rawValue] = capability
        }
        return NormalizedProfileDraft(
            inferenceProfileID: draft.inferenceProfileID,
            modelID: draft.modelID,
            variantID: draft.variantID,
            effectiveRequestOptions: effective,
            requestAdapter:
                draft.requestAdapterOverride
                    ?? connection.requestAdapter,
            modelContextPolicy: draft.modelContextPolicy,
            declaredCapabilities: capabilitiesByName.keys.sorted().compactMap { capabilitiesByName[$0] },
            safeRouteLabel: draft.safeRouteLabel)
    }

    private static func validateUniqueDraftIDs(_ draft: InferenceCatalogDraft) throws {
        let connectionIDs = draft.connections.map(\.inferenceConnectionID)
        let profileIDs = draft.profiles.map(\.inferenceProfileID)
        guard Set(connectionIDs).count == connectionIDs.count,
              Set(profileIDs).count == profileIDs.count else {
            throw InferenceCatalogError.duplicateDefinition
        }
    }

    private static func semanticallyEqual(_ definition: InferenceConnectionDefinition,
                                          _ draft: InferenceConnectionDraft) -> Bool {
        definition.wire == draft.wire
            && definition.requestAdapter
                == draft.requestAdapter
            && definition.baseURL == draft.baseURL
            && definition.chatEndpoint == draft.chatEndpoint
            && definition.credentialRef == draft.credentialRef
            && definition.trust == draft.trust
            && definition.defaultRequestOptions == draft.defaultRequestOptions
    }

    private static func semanticallyEqual(_ definition: InferenceProfileDefinition,
                                          _ draft: NormalizedProfileDraft,
                                          connectionRef: InferenceConnectionRef) -> Bool {
        definition.connectionRef == connectionRef
            && definition.modelID == draft.modelID
            && definition.variantID == draft.variantID
            && definition.effectiveRequestOptions == draft.effectiveRequestOptions
            && definition.requestAdapter
                == draft.requestAdapter
            && definition.modelContextPolicy == draft.modelContextPolicy
            && definition.declaredCapabilities.map(\.rawValue).sorted()
                == draft.declaredCapabilities.map(\.rawValue).sorted()
            && definition.safeRouteLabel == draft.safeRouteLabel
    }

    private static func nextConnectionRevision(
        for id: InferenceConnectionID,
        in definitions: [InferenceConnectionDefinition]
    ) -> InferenceConnectionRevision {
        let used = Set(definitions.lazy
            .filter { $0.connectionRef.inferenceConnectionID == id }
            .map { $0.connectionRef.inferenceConnectionRevision.rawValue })
        return InferenceConnectionRevision(rawValue: nextNumericRevision(excluding: used))
    }

    private static func nextProfileRevision(
        for id: InferenceProfileID,
        in definitions: [InferenceProfileDefinition]
    ) -> InferenceProfileRevision {
        let used = Set(definitions.lazy
            .filter { $0.profileRef.inferenceProfileID == id }
            .map { $0.profileRef.inferenceProfileRevision.rawValue })
        return InferenceProfileRevision(rawValue: nextNumericRevision(excluding: used))
    }

    private static func nextNumericRevision(excluding used: Set<String>) -> String {
        var candidate = used.compactMap(Int.init).max().map { $0 + 1 } ?? 1
        while used.contains(String(candidate)) {
            candidate += 1
        }
        return String(candidate)
    }

    private static func validateDraftIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw InferenceCatalogError.invalidIdentifier
        }
    }

    private static func validHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.user == nil && url.password == nil
    }

    private static func validClassification(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
            }
    }

    private static func validRouteLabel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0)
            }
    }

    private static func connectionDefinitionOrder(_ lhs: InferenceConnectionDefinition,
                                                  _ rhs: InferenceConnectionDefinition) -> Bool {
        connectionRefOrder(lhs.connectionRef, rhs.connectionRef)
    }

    private static func profileDefinitionOrder(_ lhs: InferenceProfileDefinition,
                                               _ rhs: InferenceProfileDefinition) -> Bool {
        profileRefOrder(lhs.profileRef, rhs.profileRef)
    }

    private static func connectionRefOrder(_ lhs: InferenceConnectionRef,
                                           _ rhs: InferenceConnectionRef) -> Bool {
        let leftID = lhs.inferenceConnectionID.rawValue
        let rightID = rhs.inferenceConnectionID.rawValue
        if leftID != rightID { return leftID < rightID }
        return revisionOrder(lhs.inferenceConnectionRevision.rawValue,
                             rhs.inferenceConnectionRevision.rawValue)
    }

    private static func profileRefOrder(_ lhs: InferenceProfileRef,
                                        _ rhs: InferenceProfileRef) -> Bool {
        let leftID = lhs.inferenceProfileID.rawValue
        let rightID = rhs.inferenceProfileID.rawValue
        if leftID != rightID { return leftID < rightID }
        return revisionOrder(lhs.inferenceProfileRevision.rawValue,
                             rhs.inferenceProfileRevision.rawValue)
    }

    private static func revisionOrder(_ lhs: String, _ rhs: String) -> Bool {
        if let left = Int(lhs), let right = Int(rhs), left != right {
            return left < right
        }
        return lhs < rhs
    }
}

private enum InferenceIdentityFingerprint {
    /// Length-prefixing makes component boundaries unambiguous before hashing.
    static func sha256(_ components: [String]) -> String {
        var data = Data()
        for component in components {
            let bytes = Data(component.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable type-tagged representation used only as hash input. Object keys
    /// are sorted; no representation is returned to logs, events, or errors.
    static func canonical(_ object: [String: JSONValue]) -> String {
        canonical(.object(object))
    }

    private static func canonical(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "n"
        case .bool(let value):
            return value ? "b1" : "b0"
        case .number(let value):
            return "d\(String(value.bitPattern, radix: 16))"
        case .string(let value):
            return "s\(value.utf8.count):\(value)"
        case .array(let values):
            return "a\(values.count):" + values.map(canonical).map(lengthPrefixed).joined()
        case .object(let object):
            let fields = object.keys.sorted().map { key in
                lengthPrefixed("k\(key.utf8.count):\(key)")
                    + lengthPrefixed(canonical(object[key] ?? .null))
            }
            return "o\(fields.count):" + fields.joined()
        }
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
