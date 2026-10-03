#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Safe identities and persisted secret handles

public struct MCPOAuthCredentialGeneration:
    Codable, Equatable, Hashable, Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public func next() throws -> MCPOAuthCredentialGeneration {
        guard rawValue < UInt64.max else {
            throw MCPOAuthError.generationOverflow
        }
        return MCPOAuthCredentialGeneration(rawValue: rawValue + 1)
    }
}

/// Secret-free binding for a credential acquired before a server definition
/// exists in the catalog. The binding is exact to the predicted revision,
/// catalog generation/digest, configuration, and random preparation
/// challenge; it can never authorize a later ordinal.
public struct MCPOAuthStagingBinding:
    Codable, Equatable, Hashable, Sendable
{
    public let plannedReference: MCPServerReference
    public let catalogPublication:
        MCPCatalogPublicationIdentity
    public let configurationFingerprint: String
    public let preparationChallengeID: String
    public let preparationFingerprint: String

    public init(
        prepared: MCPPreparedServerConfiguration
    ) {
        plannedReference = prepared.expectedServerReference
        catalogPublication = prepared.catalogPublication
        configurationFingerprint =
            prepared.definition.definitionFingerprint
        preparationChallengeID =
            prepared.challenge.challengeID
        preparationFingerprint =
            prepared.preparationFingerprint
    }

    public func exactlyMatches(
        _ prepared: MCPPreparedServerConfiguration
    ) -> Bool {
        self == MCPOAuthStagingBinding(prepared: prepared)
    }
}

/// Proof retained on an activated staged credential. Token bytes and their
/// secret-store source binding are not rewritten after catalog Save.
public struct MCPOAuthActivationBinding:
    Codable, Equatable, Hashable, Sendable
{
    public let publishedReference: MCPServerReference
    public let publishedCatalog:
        MCPCatalogPublicationIdentity
    public let preparationFingerprint: String

    init(
        publishedReference: MCPServerReference,
        publishedCatalog: MCPCatalogPublicationIdentity,
        preparationFingerprint: String
    ) {
        self.publishedReference = publishedReference
        self.publishedCatalog = publishedCatalog
        self.preparationFingerprint =
            preparationFingerprint
    }
}

public struct MCPOAuthAuthorityIdentity:
    Codable, Equatable, Hashable, Sendable
{
    public let serverID: MCPServerID
    public let canonicalOrigin: String
    public let canonicalResource: String
    public let accountReference: MCPAccountReference
    public let clientIDFingerprint: String

    public init(
        serverID: MCPServerID,
        canonicalOrigin: String,
        canonicalResource: String,
        accountReference: MCPAccountReference,
        clientID: String
    ) throws {
        guard let originURL = URL(string: canonicalOrigin),
              let resourceURL = URL(string: canonicalResource),
              !clientID.isEmpty,
              clientID.utf8.count <= 2_048 else {
            throw MCPOAuthError.authorityMismatch
        }
        let configuredOrigin = try MCPHTTPOrigin.canonical(originURL)
        let resourceOrigin = try MCPHTTPOrigin.canonical(resourceURL)
        guard configuredOrigin == resourceOrigin else {
            throw MCPOAuthError.authorityMismatch
        }
        self.serverID = serverID
        self.canonicalOrigin = configuredOrigin
        self.canonicalResource =
            try MCPOAuthCanonical.resource(resourceURL).absoluteString
        self.accountReference = accountReference
        self.clientIDFingerprint = MCPOAuthCanonical.digest(clientID)
    }
}

/// Safe-to-persist handle. All token strings remain inside the referenced
/// MCPSecretStore record.
public struct MCPOAuthTokenHandle:
    Codable, Equatable, Hashable, Sendable, CustomStringConvertible
{
    public let authority: MCPOAuthAuthorityIdentity
    public let secretReference: MCPSecretReference
    public let generation: MCPOAuthCredentialGeneration
    public let scopes: Set<String>
    public let expiresAt: Date?
    public let authorizationServerOrigin: String
    public let stagingBinding: MCPOAuthStagingBinding?
    public let activationBinding:
        MCPOAuthActivationBinding?

    public init(
        authority: MCPOAuthAuthorityIdentity,
        secretReference: MCPSecretReference,
        generation: MCPOAuthCredentialGeneration,
        scopes: Set<String>,
        expiresAt: Date?,
        authorizationServerOrigin: String,
        stagingBinding: MCPOAuthStagingBinding? = nil,
        activationBinding:
            MCPOAuthActivationBinding? = nil
    ) {
        self.authority = authority
        self.secretReference = secretReference
        self.generation = generation
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.authorizationServerOrigin = authorizationServerOrigin
        self.stagingBinding = stagingBinding
        self.activationBinding = activationBinding
    }

    public var description: String {
        "MCPOAuthTokenHandle(server:\(authority.serverID.rawValue), generation:\(generation.rawValue), scopes:\(scopes.count), staged:\(stagingBinding != nil), active:\(isActive), secret:<redacted>)"
    }

    public var isActive: Bool {
        stagingBinding == nil || activationBinding != nil
    }

    public func isActive(
        for reference: MCPServerReference
    ) -> Bool {
        guard authority.serverID == reference.serverID else {
            return false
        }
        guard let stagingBinding else { return true }
        guard let activationBinding else { return false }
        return stagingBinding.plannedReference == reference
            && activationBinding.publishedReference == reference
            && activationBinding.preparationFingerprint
                == stagingBinding.preparationFingerprint
    }
}

public struct MCPOAuthClientRegistrationHandle:
    Codable, Equatable, Hashable, Sendable, CustomStringConvertible
{
    public let authorizationServerOrigin: String
    public let secretReference: MCPSecretReference
    public let clientIDFingerprint: String

    public init(
        authorizationServerOrigin: String,
        secretReference: MCPSecretReference,
        clientIDFingerprint: String
    ) {
        self.authorizationServerOrigin = authorizationServerOrigin
        self.secretReference = secretReference
        self.clientIDFingerprint = clientIDFingerprint
    }

    public var description: String {
        "MCPOAuthClientRegistrationHandle(origin:\(authorizationServerOrigin), client:<redacted>, secret:<redacted>)"
    }
}

private struct MCPOAuthSecretToken: Codable, Sendable {
    let schemaVersion: Int
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let scopes: Set<String>
    let expiresAt: Date?
    let authorizationServer: String
    let canonicalResource: String
    let clientID: String
    let accountReference: MCPAccountReference
    let generation: MCPOAuthCredentialGeneration
    let stagingBinding: MCPOAuthStagingBinding?
}

private struct MCPOAuthSecretRegistration: Codable, Sendable {
    let schemaVersion: Int
    let clientID: String
    let clientSecret: String?
    let tokenEndpointAuthMethod: String
    let authorizationServerOrigin: String
}

struct MCPOAuthResolvedClient: Sendable {
    let clientID: String
    let clientSecret: String?
    let tokenEndpointAuthMethod: String
    let registrationHandle: MCPOAuthClientRegistrationHandle?
}

public actor MCPOAuthCredentialVault {
    private let secretStore: any MCPSecretStore

    public init(secretStore: any MCPSecretStore) {
        self.secretStore = secretStore
    }

    public func storeToken(
        authority: MCPOAuthAuthorityIdentity,
        accessToken: String,
        refreshToken: String?,
        tokenType: String,
        scopes: Set<String>,
        expiresAt: Date?,
        authorizationServer: URL,
        clientID: String,
        generation: MCPOAuthCredentialGeneration,
        stagingBinding:
            MCPOAuthStagingBinding? = nil
    ) async throws -> MCPOAuthTokenHandle {
        try Self.validateToken(accessToken)
        if let refreshToken { try Self.validateToken(refreshToken) }
        guard tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MCPOAuthError.unsupportedTokenType
        }
        let canonicalASOrigin = try MCPHTTPOrigin.canonical(
            authorizationServer)
        let record = MCPOAuthSecretToken(
            schemaVersion: 1,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: "Bearer",
            scopes: scopes,
            expiresAt: expiresAt,
            authorizationServer: authorizationServer.absoluteString,
            canonicalResource: authority.canonicalResource,
            clientID: clientID,
            accountReference: authority.accountReference,
            generation: generation,
            stagingBinding: stagingBinding)
        let encoded = try Self.encode(record)
        let reference = try await secretStore.store(
            encoded,
            sourceBindingFingerprint: Self.bindingFingerprint(
                authority,
                stagingBinding: stagingBinding))
        return MCPOAuthTokenHandle(
            authority: authority,
            secretReference: reference,
            generation: generation,
            scopes: scopes,
            expiresAt: expiresAt,
            authorizationServerOrigin: canonicalASOrigin,
            stagingBinding: stagingBinding)
    }

    public func replaceToken(
        _ handle: MCPOAuthTokenHandle,
        accessToken: String,
        refreshToken: String?,
        tokenType: String,
        scopes: Set<String>,
        expiresAt: Date?,
        authorizationServer: URL,
        clientID: String
    ) async throws -> MCPOAuthTokenHandle {
        let current = try await resolveToken(handle)
        let next = try handle.generation.next()
        try Self.validateToken(accessToken)
        let retainedRefresh = refreshToken ?? current.refreshToken
        if let retainedRefresh { try Self.validateToken(retainedRefresh) }
        guard tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              current.clientID == clientID,
              current.canonicalResource
                == handle.authority.canonicalResource,
              try MCPHTTPOrigin.canonical(authorizationServer)
                == handle.authorizationServerOrigin else {
            throw MCPOAuthError.authorityMismatch
        }
        let record = MCPOAuthSecretToken(
            schemaVersion: 1,
            accessToken: accessToken,
            refreshToken: retainedRefresh,
            tokenType: "Bearer",
            scopes: scopes,
            expiresAt: expiresAt,
            authorizationServer: authorizationServer.absoluteString,
            canonicalResource: current.canonicalResource,
            clientID: current.clientID,
            accountReference: current.accountReference,
            generation: next,
            stagingBinding: current.stagingBinding)
        try await secretStore.replace(
            try Self.encode(record),
            for: handle.secretReference)
        return MCPOAuthTokenHandle(
            authority: handle.authority,
            secretReference: handle.secretReference,
            generation: next,
            scopes: scopes,
            expiresAt: expiresAt,
            authorizationServerOrigin:
                handle.authorizationServerOrigin,
            stagingBinding: handle.stagingBinding,
            activationBinding: handle.activationBinding)
    }

    /// Activates a staged handle only after the exact planned definition was
    /// published by the one-generation CAS. The secret record and its source
    /// binding are intentionally unchanged, avoiding a non-atomic post-Save
    /// secret rebind.
    public func activateStagedToken(
        _ handle: MCPOAuthTokenHandle,
        prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof,
        publishedCatalog: MCPServerCatalog,
        now: Date = Date()
    ) async throws -> MCPOAuthTokenHandle {
        guard case .streamableHTTP(let http) =
                prepared.definition.configuration.transport,
              let originURL = URL(
                string: http.canonicalOrigin),
              let preparedOrigin =
                try? MCPHTTPOrigin.canonical(originURL) else {
            throw MCPOAuthError.stagedCredentialMismatch
        }
        guard let stagingBinding = handle.stagingBinding,
              handle.activationBinding == nil,
              stagingBinding.exactlyMatches(prepared),
              handle.authority.serverID
                == prepared.expectedServerReference.serverID,
              let oauth = http.oauth,
              oauth.enabled,
              let accountReference =
                oauth.accountReference,
              handle.authority.canonicalOrigin
                == preparedOrigin,
              handle.authority.canonicalResource
                == oauth.canonicalResource,
              handle.authority.accountReference
                == accountReference,
              Set(oauth.scopes)
                .isSubset(of: handle.scopes),
              (oauth.clientID.map {
                  handle.authority.clientIDFingerprint
                    == MCPOAuthCanonical.digest($0)
              } ?? true)
        else {
            throw MCPOAuthError.stagedCredentialMismatch
        }
        try prepared.validate(proof: proof, at: now)
        guard prepared.catalogPublication.generation
                < UInt64.max,
              publishedCatalog.generation
                == prepared.catalogPublication.generation + 1,
              publishedCatalog.definition(
                  for: prepared.expectedServerReference)
                == prepared.definition,
              publishedCatalog.head(
                  for: prepared.expectedServerReference.serverID)?
                .currentRevision
                == prepared.expectedServerReference.serverRevision,
              !publishedCatalog.isTombstoned(
                  prepared.expectedServerReference)
        else {
            throw MCPOAuthError.stagedCredentialMismatch
        }
        _ = try await resolveToken(handle)
        let activation = MCPOAuthActivationBinding(
            publishedReference:
                prepared.expectedServerReference,
            publishedCatalog:
                MCPCatalogPublicationIdentity(
                    catalog: publishedCatalog),
            preparationFingerprint:
                prepared.preparationFingerprint)
        return MCPOAuthTokenHandle(
            authority: handle.authority,
            secretReference: handle.secretReference,
            generation: handle.generation,
            scopes: handle.scopes,
            expiresAt: handle.expiresAt,
            authorizationServerOrigin:
                handle.authorizationServerOrigin,
            stagingBinding: stagingBinding,
            activationBinding: activation)
    }

    public func discardStagedToken(
        _ handle: MCPOAuthTokenHandle
    ) async throws {
        guard handle.stagingBinding != nil,
              handle.activationBinding == nil
        else {
            throw MCPOAuthError.stagedCredentialMismatch
        }
        try await removeToken(handle)
    }

    public func removeToken(_ handle: MCPOAuthTokenHandle) async throws {
        _ = try await resolveToken(handle)
        try await secretStore.remove(handle.secretReference)
    }

    public func tokenExists(_ handle: MCPOAuthTokenHandle) async throws -> Bool {
        try await secretStore.contains(handle.secretReference)
    }

    public func storeRegistration(
        authorizationServerOrigin: String,
        clientID: String,
        clientSecret: String?,
        tokenEndpointAuthMethod: String
    ) async throws -> MCPOAuthClientRegistrationHandle {
        guard !clientID.isEmpty, clientID.utf8.count <= 2_048 else {
            throw MCPOAuthError.invalidClientRegistration
        }
        if let clientSecret { try Self.validateToken(clientSecret) }
        let record = MCPOAuthSecretRegistration(
            schemaVersion: 1,
            clientID: clientID,
            clientSecret: clientSecret,
            tokenEndpointAuthMethod: tokenEndpointAuthMethod,
            authorizationServerOrigin: authorizationServerOrigin)
        let fingerprint = MCPOAuthCanonical.digest(clientID)
        let reference = try await secretStore.store(
            try Self.encode(record),
            sourceBindingFingerprint: MCPOAuthCanonical.digest(
                "\(authorizationServerOrigin)|\(fingerprint)"))
        return MCPOAuthClientRegistrationHandle(
            authorizationServerOrigin: authorizationServerOrigin,
            secretReference: reference,
            clientIDFingerprint: fingerprint)
    }

    func resolveRegistration(
        _ handle: MCPOAuthClientRegistrationHandle
    ) async throws -> MCPOAuthResolvedClient {
        let data = try await secretStore.resolve(handle.secretReference)
        guard data.count <= 2 * 1_024 * 1_024,
              let value = try? JSONDecoder().decode(
                MCPOAuthSecretRegistration.self,
                from: data),
              value.schemaVersion == 1,
              value.authorizationServerOrigin
                == handle.authorizationServerOrigin,
              MCPOAuthCanonical.digest(value.clientID)
                == handle.clientIDFingerprint else {
            throw MCPOAuthError.corruptCredential
        }
        return MCPOAuthResolvedClient(
            clientID: value.clientID,
            clientSecret: value.clientSecret,
            tokenEndpointAuthMethod: value.tokenEndpointAuthMethod,
            registrationHandle: handle)
    }

    public func removeRegistration(
        _ handle: MCPOAuthClientRegistrationHandle
    ) async throws {
        _ = try await resolveRegistration(handle)
        try await secretStore.remove(handle.secretReference)
    }

    fileprivate func resolveToken(
        _ handle: MCPOAuthTokenHandle
    ) async throws -> MCPOAuthSecretToken {
        guard handle.secretReference.sourceBindingFingerprint
                == Self.bindingFingerprint(
                    handle.authority,
                    stagingBinding:
                        handle.stagingBinding)
        else {
            throw MCPOAuthError.authorityMismatch
        }
        let data = try await secretStore.resolve(handle.secretReference)
        guard data.count <= 2 * 1_024 * 1_024,
              let record = try? JSONDecoder().decode(
                MCPOAuthSecretToken.self,
                from: data),
              record.schemaVersion == 1,
              record.canonicalResource
                == handle.authority.canonicalResource,
              record.accountReference
                == handle.authority.accountReference,
              record.stagingBinding
                == handle.stagingBinding,
              MCPOAuthCanonical.digest(record.clientID)
                == handle.authority.clientIDFingerprint,
              try MCPHTTPOrigin.canonical(
                URL(string: record.authorizationServer)
                    ?? URL(fileURLWithPath: "/"))
                == handle.authorizationServerOrigin else {
            throw MCPOAuthError.corruptCredential
        }
        guard record.generation == handle.generation else {
            throw MCPOAuthError.staleCredentialGeneration
        }
        guard record.scopes == handle.scopes,
              record.expiresAt == handle.expiresAt else {
            throw MCPOAuthError.corruptCredential
        }
        if let staging = handle.stagingBinding {
            guard staging.plannedReference.serverID
                    == handle.authority.serverID,
                  handle.activationBinding == nil
                    || (handle.activationBinding?
                        .publishedReference
                        == staging.plannedReference
                        && handle.activationBinding?
                            .preparationFingerprint
                            == staging
                                .preparationFingerprint)
            else {
                throw MCPOAuthError
                    .stagedCredentialMismatch
            }
        } else if handle.activationBinding != nil {
            throw MCPOAuthError.stagedCredentialMismatch
        }
        try Self.validateToken(record.accessToken)
        if let refreshToken = record.refreshToken {
            try Self.validateToken(refreshToken)
        }
        return record
    }

    private static func validateToken(_ token: String) throws {
        guard !token.isEmpty,
              token.utf8.count <= MCPSecretStoreLimits.maximumSecretBytes,
              !token.contains("\0"),
              !token.contains(where: \.isNewline) else {
            throw MCPOAuthError.invalidTokenResponse
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= MCPSecretStoreLimits.maximumSecretBytes else {
            throw MCPSecretStoreError.valueTooLarge
        }
        return data
    }

    private static func bindingFingerprint(
        _ authority: MCPOAuthAuthorityIdentity,
        stagingBinding: MCPOAuthStagingBinding?
    ) -> String {
        var fields = [
            authority.serverID.rawValue,
            authority.canonicalOrigin,
            authority.canonicalResource,
            authority.accountReference.rawValue,
            authority.clientIDFingerprint,
        ]
        if let stagingBinding {
            fields += [
                stagingBinding.plannedReference
                    .serverRevision.rawValue,
                String(stagingBinding
                    .catalogPublication.generation),
                stagingBinding.catalogPublication
                    .catalogFingerprint,
                stagingBinding.configurationFingerprint,
                stagingBinding.preparationChallengeID,
                stagingBinding.preparationFingerprint,
            ]
        }
        return MCPOAuthCanonical.digest(
            fields.joined(separator: "|"))
    }
}

/// Authorization adapter for one exact connection/token generation. Refresh,
/// account switch, logout, and origin changes construct a new adapter and
/// retire the old connection rather than mutating credentials under it.
public actor MCPOAuthAuthorizationProvider:
    MCPHTTPAuthorizationProviding
{
    private let vault: MCPOAuthCredentialVault
    private let handle: MCPOAuthTokenHandle
    private let connectionGeneration: MCPConnectionGeneration
    private let expectedServerReference:
        MCPServerReference?
    private let stagedTestPreparationFingerprint:
        String?
    private var retired = false

    public init(
        vault: MCPOAuthCredentialVault,
        handle: MCPOAuthTokenHandle,
        connectionGeneration: MCPConnectionGeneration,
        expectedServerReference:
            MCPServerReference? = nil,
        stagedTestPreparationFingerprint:
            String? = nil
    ) {
        self.vault = vault
        self.handle = handle
        self.connectionGeneration = connectionGeneration
        self.expectedServerReference =
            expectedServerReference
        self.stagedTestPreparationFingerprint =
            stagedTestPreparationFingerprint
    }

    public func authorizationHeader(
        for canonicalResource: URL,
        connectionGeneration: MCPConnectionGeneration
    ) async throws -> String? {
        guard !retired,
              connectionGeneration == self.connectionGeneration else {
            throw MCPOAuthError.staleCredentialGeneration
        }
        if let staging = handle.stagingBinding {
            if let activation = handle.activationBinding {
                guard let expectedServerReference,
                      expectedServerReference
                        == staging.plannedReference,
                      activation.publishedReference
                        == expectedServerReference,
                      activation.preparationFingerprint
                        == staging.preparationFingerprint
                else {
                    throw MCPOAuthError
                        .stagedCredentialInactive
                }
            } else {
                guard let expectedServerReference,
                      expectedServerReference
                        == staging.plannedReference,
                      stagedTestPreparationFingerprint
                        == staging.preparationFingerprint
                else {
                    throw MCPOAuthError
                        .stagedCredentialInactive
                }
            }
        } else if handle.activationBinding != nil {
            throw MCPOAuthError.stagedCredentialMismatch
        }
        let resource = try MCPOAuthCanonical.resource(canonicalResource)
        guard let authorized = URL(
                string: handle.authority.canonicalResource),
              MCPOAuthCanonical.resource(
                authorized,
                authorizes: resource),
              try MCPHTTPOrigin.canonical(resource)
                == handle.authority.canonicalOrigin else {
            throw MCPOAuthError.authorityMismatch
        }
        let record = try await vault.resolveToken(handle)
        if let expiresAt = record.expiresAt,
           Date().addingTimeInterval(30) >= expiresAt {
            throw MCPOAuthError.refreshRequired
        }
        return "Bearer \(record.accessToken)"
    }

    public func retire() {
        retired = true
    }
}

// MARK: - Discovery and HTTP

public struct MCPOAuthProtectedResourceMetadata:
    Codable, Equatable, Sendable
{
    public let resource: String
    public let authorizationServers: [URL]
    public let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    public init(
        resource: String,
        authorizationServers: [URL],
        scopesSupported: [String]?
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }
}

public struct MCPOAuthAuthorizationServerMetadata:
    Codable, Equatable, Sendable
{
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    public let revocationEndpoint: URL?
    public let codeChallengeMethodsSupported: [String]?
    public let tokenEndpointAuthMethodsSupported: [String]?
    public let clientIDMetadataDocumentSupported: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case codeChallengeMethodsSupported =
            "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported =
            "token_endpoint_auth_methods_supported"
        case clientIDMetadataDocumentSupported =
            "client_id_metadata_document_supported"
    }

    public init(
        issuer: URL,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL?,
        revocationEndpoint: URL?,
        codeChallengeMethodsSupported: [String]?,
        tokenEndpointAuthMethodsSupported: [String]?,
        clientIDMetadataDocumentSupported: Bool?
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.codeChallengeMethodsSupported =
            codeChallengeMethodsSupported
        self.tokenEndpointAuthMethodsSupported =
            tokenEndpointAuthMethodsSupported
        self.clientIDMetadataDocumentSupported =
            clientIDMetadataDocumentSupported
    }
}

public struct MCPOAuthDiscoveryResult: Equatable, Sendable {
    public let canonicalResource: URL
    public let protectedResourceMetadataURL: URL
    public let protectedResourceMetadata:
        MCPOAuthProtectedResourceMetadata
    public let authorizationServerMetadataURL: URL
    public let authorizationServerMetadata:
        MCPOAuthAuthorizationServerMetadata

    public init(
        canonicalResource: URL,
        protectedResourceMetadataURL: URL,
        protectedResourceMetadata:
            MCPOAuthProtectedResourceMetadata,
        authorizationServerMetadataURL: URL,
        authorizationServerMetadata:
            MCPOAuthAuthorizationServerMetadata
    ) {
        self.canonicalResource = canonicalResource
        self.protectedResourceMetadataURL =
            protectedResourceMetadataURL
        self.protectedResourceMetadata =
            protectedResourceMetadata
        self.authorizationServerMetadataURL =
            authorizationServerMetadataURL
        self.authorizationServerMetadata =
            authorizationServerMetadata
    }
}

public struct MCPOAuthHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol MCPOAuthHTTPClient: Sendable {
    func send(
        _ request: URLRequest,
        allowedOrigin: String
    ) async throws -> MCPOAuthHTTPResponse
}

public actor MCPURLSessionOAuthHTTPClient: MCPOAuthHTTPClient {
    private let session: URLSession
    private let delegate: MCPOAuthURLSessionDelegate
    private let resolver: any MCPDNSResolving
    private let egressAuthorizer: any MCPHTTPEgressAuthorizing
    private let ambientProxyValidationError: Error?
    private let proxyPolicy: MCPHTTPProxyPolicy
    private let maximumBodyBytes: Int
    private let maximumHeaderBytes: Int
    private let usesInjectedURLSessionTestSeam: Bool
    #if canImport(IntatisCurlTransport)
    private let curlExecutor: MCPCurlHTTPExecutor?
    #endif
    private var fences: [String: MCPHTTPEgressFence] = [:]

    public init(
        proxyPolicy: MCPHTTPProxyPolicy = .direct,
        resolver: any MCPDNSResolving = MCPSystemDNSResolver(),
        egressAuthorizer: any MCPHTTPEgressAuthorizing =
            MCPExactOriginEgressPolicy(),
        maximumBodyBytes: Int = 2 * 1_024 * 1_024,
        maximumHeaderBytes: Int = 64 * 1_024
    ) {
        self.init(
            proxyPolicy: proxyPolicy,
            resolver: resolver,
            egressAuthorizer: egressAuthorizer,
            testingSessionConfiguration: nil,
            maximumBodyBytes: maximumBodyBytes,
            maximumHeaderBytes: maximumHeaderBytes)
    }

    init(
        proxyPolicy: MCPHTTPProxyPolicy = .direct,
        resolver: any MCPDNSResolving = MCPSystemDNSResolver(),
        egressAuthorizer: any MCPHTTPEgressAuthorizing =
            MCPExactOriginEgressPolicy(),
        testingSessionConfiguration:
            URLSessionConfiguration?,
        maximumBodyBytes: Int = 2 * 1_024 * 1_024,
        maximumHeaderBytes: Int = 64 * 1_024
    ) {
        let configuration =
            testingSessionConfiguration
        let delegate = MCPOAuthURLSessionDelegate(
            maximumBodyBytes: max(1_024, maximumBodyBytes),
            maximumHeaderBytes: max(1_024, maximumHeaderBytes))
        self.delegate = delegate
        self.session = URLSession(
            configuration: MCPStreamableHTTPTransport
                .makeSessionConfiguration(
                    base: configuration,
                    proxyPolicy: proxyPolicy),
            delegate: delegate,
            delegateQueue: nil)
        self.resolver = resolver
        self.egressAuthorizer = egressAuthorizer
        self.proxyPolicy = proxyPolicy
        self.maximumBodyBytes = max(1_024, maximumBodyBytes)
        self.maximumHeaderBytes = max(1_024, maximumHeaderBytes)
        usesInjectedURLSessionTestSeam = configuration != nil
        #if canImport(IntatisCurlTransport)
        // A caller-supplied URLSession configuration is a deterministic
        // URLProtocol test seam. Production never falls back from curl.
        curlExecutor = configuration == nil
            ? MCPCurlHTTPExecutor()
            : nil
        #endif
        do {
            try MCPStreamableHTTPTransport
                .validateAmbientProxyEnvironment(
                    ProcessInfo.processInfo.environment,
                    proxyPolicy: proxyPolicy)
            ambientProxyValidationError = nil
        } catch {
            ambientProxyValidationError = error
        }
    }

    deinit {
        #if canImport(IntatisCurlTransport)
        curlExecutor?.cancelAll()
        #endif
        session.invalidateAndCancel()
    }

    public nonisolated static func validateAmbientProxyEnvironment(
        _ environment: [String: String],
        proxyPolicy: MCPHTTPProxyPolicy,
        foundationNetworkingBacked: Bool
    ) throws {
        try MCPStreamableHTTPTransport
            .validateAmbientProxyEnvironment(
                environment,
                proxyPolicy: proxyPolicy,
                foundationNetworkingBacked:
                    foundationNetworkingBacked)
    }

    public func send(
        _ request: URLRequest,
        allowedOrigin: String
    ) async throws -> MCPOAuthHTTPResponse {
        if let ambientProxyValidationError {
            throw ambientProxyValidationError
        }
        guard let url = request.url,
              try MCPHTTPOrigin.canonical(url) == allowedOrigin else {
            throw MCPOAuthError.originMismatch
        }
        let resolvedAddresses: Set<String>
        switch proxyPolicy {
        case .direct:
            let fence: MCPHTTPEgressFence
            if let existing = fences[allowedOrigin] {
                fence = existing
            } else {
                fence = try MCPHTTPEgressFence(
                    endpoint: url,
                    canonicalOrigin: allowedOrigin,
                    resolver: resolver,
                    authorizer: egressAuthorizer)
                fences[allowedOrigin] = fence
            }
            resolvedAddresses =
                try await fence.authorizeRequest()
        case .systemConfigured:
            // The configured proxy owns upstream target resolution. Passing
            // an empty set makes that delegation explicit and avoids
            // presenting a local target lookup as a socket-binding proof.
            resolvedAddresses = []
        }

        let operation = MCPOAuthHTTPTaskOperation()
        #if canImport(IntatisCurlTransport)
        if let curlExecutor {
            let timeoutSeconds =
                request.timeoutInterval
            let timeoutMilliseconds =
                timeoutSeconds.isFinite
                    && timeoutSeconds > 0
                ? Int(min(
                    timeoutSeconds * 1_000,
                    10 * 60 * 1_000))
                : 60_000
            do {
                let hop = try await curlExecutor.perform(
                    MCPCurlRequest(
                        request: request,
                        resolvedAddresses: resolvedAddresses,
                        proxyPolicy: proxyPolicy,
                        tlsPolicy: .systemTrust,
                        timeoutMilliseconds: max(
                            100,
                            timeoutMilliseconds),
                        maximumHeaderBytes:
                            maximumHeaderBytes),
                    onResponse: { response in
                        try operation.receive(
                            response: response,
                            maximumHeaderBytes:
                                self.maximumHeaderBytes)
                    },
                    onData: { data in
                        try operation.receive(
                            data: data,
                            maximumBodyBytes:
                                self.maximumBodyBytes)
                        return false
                    })
                guard !(300..<400).contains(
                    hop.response.statusCode) else {
                    throw MCPOAuthError.redirectDenied
                }
                operation.complete(error: nil)
            } catch let error as MCPCurlExecutorError {
                switch error {
                case .responseHeadersTooLarge:
                    operation.fail(
                        MCPOAuthError.responseTooLarge)
                case .connectedAddressMismatch:
                    operation.fail(
                        MCPHTTPTransportError
                            .connectedAddressMismatch)
                case .tlsPinMismatch:
                    operation.fail(
                        MCPHTTPTransportError
                            .tlsPinMismatch)
                case .cancelled:
                    operation.fail(CancellationError())
                case .invalidRequest, .invalidResponse,
                        .transferFailed:
                    operation.fail(
                        MCPOAuthError.invalidHTTPResponse)
                }
            } catch {
                operation.fail(error)
            }
            return try await operation.value()
        }
        #endif
        guard usesInjectedURLSessionTestSeam else {
            throw MCPHTTPTransportError
                .socketBindingUnavailable
        }
        let task = session.dataTask(with: request)
        delegate.register(operation, for: task)
        task.resume()
        return try await withTaskCancellationHandler {
            try await operation.value()
        } onCancel: {
            task.cancel()
        }
    }
}

private final class MCPOAuthHTTPTaskOperation:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var headers: [String: String] = [:]
    private var body = Data()
    private var terminal: Result<MCPOAuthHTTPResponse, Error>?
    private var continuation:
        CheckedContinuation<MCPOAuthHTTPResponse, Error>?

    func receive(
        response: HTTPURLResponse,
        maximumHeaderBytes: Int
    ) throws {
        let fields = response.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        let headerBytes = fields.reduce(0) {
            $0 + $1.key.utf8.count + $1.value.utf8.count + 4
        }
        guard headerBytes <= maximumHeaderBytes else {
            throw MCPOAuthError.responseTooLarge
        }
        guard !(300..<400).contains(response.statusCode) else {
            throw MCPOAuthError.redirectDenied
        }
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil else { return }
        self.response = response
        headers = fields
    }

    func receive(
        data: Data,
        maximumBodyBytes: Int
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil else { return }
        guard data.count <= maximumBodyBytes,
              body.count <= maximumBodyBytes - data.count else {
            throw MCPOAuthError.responseTooLarge
        }
        body.append(data)
    }

    func complete(error: Error?) {
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        let result: Result<MCPOAuthHTTPResponse, Error>
        if let error {
            result = .failure(error)
        } else if let response {
            result = .success(MCPOAuthHTTPResponse(
                statusCode: response.statusCode,
                headers: headers,
                body: body))
        } else {
            result = .failure(MCPOAuthError.invalidHTTPResponse)
        }
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        let result = Result<MCPOAuthHTTPResponse, Error>.failure(error)
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func value() async throws -> MCPOAuthHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminal {
                lock.unlock()
                continuation.resume(with: terminal)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class MCPOAuthURLSessionDelegate:
    NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumBodyBytes: Int
    private let maximumHeaderBytes: Int
    private var operations: [Int: MCPOAuthHTTPTaskOperation] = [:]

    init(
        maximumBodyBytes: Int,
        maximumHeaderBytes: Int
    ) {
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumHeaderBytes = maximumHeaderBytes
    }

    func register(
        _ operation: MCPOAuthHTTPTaskOperation,
        for task: URLSessionTask
    ) {
        lock.lock()
        operations[task.taskIdentifier] = operation
        lock.unlock()
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        operation(for: task)?.fail(MCPOAuthError.redirectDenied)
        task.cancel()
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let operation = operation(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        do {
            try operation.receive(
                response: response,
                maximumHeaderBytes: maximumHeaderBytes)
            completionHandler(.allow)
        } catch {
            operation.fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let operation = operation(for: dataTask) else { return }
        do {
            try operation.receive(
                data: data,
                maximumBodyBytes: maximumBodyBytes)
        } catch {
            operation.fail(error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let operation = operations.removeValue(
            forKey: task.taskIdentifier)
        lock.unlock()
        operation?.complete(error: error)
    }

    private func operation(
        for task: URLSessionTask
    ) -> MCPOAuthHTTPTaskOperation? {
        lock.lock()
        defer { lock.unlock() }
        return operations[task.taskIdentifier]
    }
}

// MARK: - OAuth coordinator

public struct MCPOAuthLoginPolicy: Equatable, Sendable {
    public let allowDynamicClientRegistration: Bool
    public let clientMetadataDocumentURL: URL?
    /// Exact fixed callback URIs present in pre-registration metadata. This
    /// set is not used for OS-assigned ephemeral listener ports.
    public let registeredRedirectURIs: Set<URL>

    public init(
        allowDynamicClientRegistration: Bool = false,
        clientMetadataDocumentURL: URL? = nil,
        registeredRedirectURIs: Set<URL> = []
    ) {
        self.allowDynamicClientRegistration =
            allowDynamicClientRegistration
        self.clientMetadataDocumentURL = clientMetadataDocumentURL
        self.registeredRedirectURIs = registeredRedirectURIs
    }
}

public enum MCPOAuthRedirectPolicy: Equatable, Sendable {
    case ephemeralIPv4(port: Int)
    case ephemeralIPv6(port: Int)
    case registered(URL)

    public var url: URL {
        switch self {
        case .ephemeralIPv4(let port):
            return URL(string: "http://127.0.0.1:\(port)/callback")!
        case .ephemeralIPv6(let port):
            return URL(string: "http://[::1]:\(port)/callback")!
        case .registered(let value):
            return value
        }
    }

    func validated() throws -> URL {
        let value = url
        guard let components = URLComponents(
            url: value,
            resolvingAgainstBaseURL: false) else {
            throw MCPOAuthError.invalidLoopbackRedirect
        }
        let normalizedHost = components.host?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard
              components.scheme?.lowercased() == "http",
              normalizedHost == "127.0.0.1"
                || normalizedHost == "::1",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let port = components.port,
              (1_024...65_535).contains(port),
              !components.path.isEmpty else {
            throw MCPOAuthError.invalidLoopbackRedirect
        }
        return value
    }
}

public final class MCPOAuthLoginAttempt:
    @unchecked Sendable, CustomStringConvertible
{
    public let generation: UInt64
    public let authorizationURL: URL
    public let redirectURI: URL
    public let requestedScopes: Set<String>

    fileprivate let state: String
    fileprivate let nonce: String
    fileprivate let codeVerifier: String
    fileprivate let discovery: MCPOAuthDiscoveryResult
    fileprivate let client: MCPOAuthResolvedClient
    fileprivate let serverID: MCPServerID
    fileprivate let accountReference: MCPAccountReference
    fileprivate let stagingBinding:
        MCPOAuthStagingBinding?
    fileprivate var consumed = false

    fileprivate init(
        generation: UInt64,
        authorizationURL: URL,
        redirectURI: URL,
        requestedScopes: Set<String>,
        state: String,
        nonce: String,
        codeVerifier: String,
        discovery: MCPOAuthDiscoveryResult,
        client: MCPOAuthResolvedClient,
        serverID: MCPServerID,
        accountReference: MCPAccountReference,
        stagingBinding:
            MCPOAuthStagingBinding?
    ) {
        self.generation = generation
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
        self.requestedScopes = requestedScopes
        self.state = state
        self.nonce = nonce
        self.codeVerifier = codeVerifier
        self.discovery = discovery
        self.client = client
        self.serverID = serverID
        self.accountReference = accountReference
        self.stagingBinding = stagingBinding
    }

    public var description: String {
        "MCPOAuthLoginAttempt(generation:\(generation), origin:\((try? MCPHTTPOrigin.canonical(authorizationURL)) ?? "<invalid>"), verifier:<redacted>, state:<redacted>)"
    }
}

public actor MCPOAuthCoordinator {
    private let httpClient: any MCPOAuthHTTPClient
    private let vault: MCPOAuthCredentialVault
    private let secretStore: any MCPSecretStore
    private var loginGeneration: UInt64 = 0
    private var activeAttempt: MCPOAuthLoginAttempt?
    private var refreshTasks:
        [MCPSecretReference: Task<MCPOAuthTokenHandle, Error>] = [:]

    public init(
        httpClient: any MCPOAuthHTTPClient,
        vault: MCPOAuthCredentialVault,
        secretStore: any MCPSecretStore
    ) {
        self.httpClient = httpClient
        self.vault = vault
        self.secretStore = secretStore
    }

    public func discover(
        endpoint: URL,
        configuredResource: URL,
        challenge: MCPOAuthChallenge? = nil
    ) async throws -> MCPOAuthDiscoveryResult {
        let resource = try MCPOAuthCanonical.resource(
            configuredResource)
        let endpointOrigin = try MCPHTTPOrigin.canonical(endpoint)
        let resourceOrigin = try MCPHTTPOrigin.canonical(resource)
        guard endpointOrigin == resourceOrigin else {
            throw MCPOAuthError.resourceMismatch
        }
        let candidates = try protectedResourceCandidates(
            endpoint: endpoint,
            challengeURL: challenge?.resourceMetadataURL)
        var selectedResource:
            (URL, URL, MCPOAuthProtectedResourceMetadata)?
        for candidate in candidates {
            do {
                let metadata: MCPOAuthProtectedResourceMetadata =
                    try await fetchJSON(candidate)
                let declared = try MCPOAuthCanonical.resource(
                    URL(string: metadata.resource)
                        ?? URL(fileURLWithPath: "/"))
                guard MCPOAuthCanonical.acceptsDiscoveredResource(
                        declared,
                        configuredResource: resource,
                        metadataURL: candidate),
                      !metadata.authorizationServers.isEmpty else {
                    throw MCPOAuthError.resourceMismatch
                }
                selectedResource = (candidate, declared, metadata)
                break
            } catch MCPOAuthError.httpStatus(let status)
                where status == 404 {
                continue
            }
        }
        guard let selectedResource else {
            throw MCPOAuthError.protectedResourceDiscoveryFailed
        }

        var selectedAuthorization:
            (URL, MCPOAuthAuthorizationServerMetadata)?
        for issuer in selectedResource.2.authorizationServers {
            let canonicalIssuer = try MCPOAuthCanonical
                .authorizationServer(issuer)
            for candidate in authorizationMetadataCandidates(
                issuer: canonicalIssuer)
            {
                do {
                    let metadata:
                        MCPOAuthAuthorizationServerMetadata =
                        try await fetchJSON(candidate)
                    let declaredIssuer = try MCPOAuthCanonical
                        .authorizationServer(metadata.issuer)
                    guard declaredIssuer == canonicalIssuer else {
                        throw MCPOAuthError.issuerMismatch
                    }
                    try validateAuthorizationEndpoints(metadata)
                    selectedAuthorization = (candidate, metadata)
                    break
                } catch MCPOAuthError.httpStatus(let status)
                    where status == 404 {
                    continue
                }
            }
            if selectedAuthorization != nil { break }
        }
        guard let selectedAuthorization else {
            throw MCPOAuthError
                .authorizationServerDiscoveryFailed
        }
        return MCPOAuthDiscoveryResult(
            canonicalResource: selectedResource.1,
            protectedResourceMetadataURL: selectedResource.0,
            protectedResourceMetadata: selectedResource.2,
            authorizationServerMetadataURL: selectedAuthorization.0,
            authorizationServerMetadata: selectedAuthorization.1)
    }

    public func beginLogin(
        serverID: MCPServerID,
        accountReference: MCPAccountReference,
        configuration: MCPOAuthConfiguration,
        discovery: MCPOAuthDiscoveryResult,
        redirectPolicy: MCPOAuthRedirectPolicy,
        loginPolicy: MCPOAuthLoginPolicy = .init(),
        requiredScopes: Set<String> = [],
        stagingBinding:
            MCPOAuthStagingBinding? = nil
    ) async throws -> MCPOAuthLoginAttempt {
        guard configuration.enabled else {
            throw MCPOAuthError.resourceMismatch
        }
        if let stagingBinding {
            guard stagingBinding.plannedReference.serverID
                    == serverID
            else {
                throw MCPOAuthError
                    .stagedCredentialMismatch
            }
        }
        let configuredResource = try MCPOAuthCanonical.resource(
            URL(string: configuration.canonicalResource)
                ?? URL(fileURLWithPath: "/"))
        guard configuredResource == discovery.canonicalResource
                || MCPOAuthCanonical.acceptsDiscoveredResource(
                    discovery.canonicalResource,
                    configuredResource: configuredResource,
                    metadataURL:
                        discovery.protectedResourceMetadataURL) else {
            throw MCPOAuthError.resourceMismatch
        }
        let redirectURI = try redirectPolicy.validated()
        if case .registered = redirectPolicy,
           !loginPolicy.registeredRedirectURIs.contains(redirectURI)
        {
            throw MCPOAuthError.unregisteredFixedRedirect
        }
        let client = try await resolveClient(
            configuration: configuration,
            discovery: discovery,
            redirectURI: redirectURI,
            policy: loginPolicy)
        let metadata = discovery.authorizationServerMetadata
        if let methods = metadata.codeChallengeMethodsSupported {
            guard methods.contains(where: {
                $0.caseInsensitiveCompare("S256") == .orderedSame
            }) else {
                throw MCPOAuthError.pkceS256Required
            }
        }

        guard loginGeneration < UInt64.max else {
            throw MCPOAuthError.generationOverflow
        }
        loginGeneration += 1
        activeAttempt?.consumed = true

        let verifier = PKCE.makeVerifier(length: 64)
        let challenge = try PKCE.makeChallenge(from: verifier)
        let state = Self.randomURLSafe(bytes: 32)
        let nonce = Self.randomURLSafe(bytes: 32)
        let configuredScopes = Set(configuration.scopes)
        let scopes = configuredScopes.union(requiredScopes)
        for scope in scopes {
            try Self.validateScope(scope)
        }
        let authorizationURL = try makeAuthorizationURL(
            endpoint: metadata.authorizationEndpoint,
            clientID: client.clientID,
            redirectURI: redirectURI,
            resource: discovery.canonicalResource,
            scopes: scopes,
            state: state,
            nonce: nonce,
            codeChallenge: challenge)
        let attempt = MCPOAuthLoginAttempt(
            generation: loginGeneration,
            authorizationURL: authorizationURL,
            redirectURI: redirectURI,
            requestedScopes: scopes,
            state: state,
            nonce: nonce,
            codeVerifier: verifier,
            discovery: discovery,
            client: client,
            serverID: serverID,
            accountReference: accountReference,
            stagingBinding: stagingBinding)
        activeAttempt = attempt
        return attempt
    }

    public func completeLogin(
        _ attempt: MCPOAuthLoginAttempt,
        callbackURL: URL
    ) async throws -> MCPOAuthTokenHandle {
        guard activeAttempt === attempt,
              attempt.generation == loginGeneration,
              !attempt.consumed else {
            throw MCPOAuthError.staleLoginGeneration
        }
        attempt.consumed = true
        activeAttempt = nil
        let code = try validateCallback(
            callbackURL,
            expectedRedirect: attempt.redirectURI,
            expectedState: attempt.state)

        let response = try await tokenRequest(
            endpoint:
                attempt.discovery.authorizationServerMetadata
                    .tokenEndpoint,
            parameters: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": attempt.redirectURI.absoluteString,
                "code_verifier": attempt.codeVerifier,
                "resource":
                    attempt.discovery.canonicalResource.absoluteString,
            ],
            client: attempt.client)
        let token = try decodeTokenResponse(
            response,
            requestedScopes: attempt.requestedScopes,
            canonicalResource: attempt.discovery.canonicalResource)
        let authority = try MCPOAuthAuthorityIdentity(
            serverID: attempt.serverID,
            canonicalOrigin: try MCPHTTPOrigin.canonical(
                attempt.discovery.canonicalResource),
            canonicalResource:
                attempt.discovery.canonicalResource.absoluteString,
            accountReference: attempt.accountReference,
            clientID: attempt.client.clientID)
        return try await vault.storeToken(
            authority: authority,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scopes: token.scopes,
            expiresAt: token.expiresAt,
            authorizationServer:
                attempt.discovery.authorizationServerMetadata.issuer,
            clientID: attempt.client.clientID,
            generation: .init(rawValue: 1),
            stagingBinding: attempt.stagingBinding)
    }

    public func cancelLogin(_ attempt: MCPOAuthLoginAttempt? = nil) {
        if let attempt, activeAttempt !== attempt { return }
        activeAttempt?.consumed = true
        activeAttempt = nil
        if loginGeneration < UInt64.max {
            loginGeneration += 1
        }
    }

    public func refresh(
        _ handle: MCPOAuthTokenHandle,
        discovery: MCPOAuthDiscoveryResult,
        clientRegistration:
            MCPOAuthClientRegistrationHandle? = nil,
        configuredClientSecret:
            MCPSecretReference? = nil
    ) async throws -> MCPOAuthTokenHandle {
        if let existing = refreshTasks[handle.secretReference] {
            return try await existing.value
        }
        let task = Task<MCPOAuthTokenHandle, Error> {
            let current = try await self.vault.resolveToken(handle)
            guard let refreshToken = current.refreshToken else {
                throw MCPOAuthError.refreshTokenUnavailable
            }
            let client: MCPOAuthResolvedClient
            if let clientRegistration {
                client = try await self.vault.resolveRegistration(
                    clientRegistration)
            } else {
                let secret: String?
                if let configuredClientSecret {
                    let data = try await self.secretStore.resolve(
                        configuredClientSecret)
                    secret = String(data: data, encoding: .utf8)
                    guard secret != nil else {
                        throw MCPOAuthError.corruptCredential
                    }
                } else {
                    secret = nil
                }
                client = MCPOAuthResolvedClient(
                    clientID: current.clientID,
                    clientSecret: secret,
                    tokenEndpointAuthMethod:
                        secret == nil ? "none" : "client_secret_basic",
                    registrationHandle: nil)
            }
            let response = try await self.tokenRequest(
                endpoint:
                    discovery.authorizationServerMetadata.tokenEndpoint,
                parameters: [
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "resource": discovery.canonicalResource.absoluteString,
                ],
                client: client)
            let decoded = try self.decodeTokenResponse(
                response,
                requestedScopes: handle.scopes,
                canonicalResource: discovery.canonicalResource)
            return try await self.vault.replaceToken(
                handle,
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken,
                tokenType: decoded.tokenType,
                scopes: decoded.scopes,
                expiresAt: decoded.expiresAt,
                authorizationServer:
                    discovery.authorizationServerMetadata.issuer,
                clientID: current.clientID)
        }
        refreshTasks[handle.secretReference] = task
        do {
            let result = try await task.value
            refreshTasks[handle.secretReference] = nil
            return result
        } catch {
            refreshTasks[handle.secretReference] = nil
            throw error
        }
    }

    public func logout(
        _ handle: MCPOAuthTokenHandle,
        discovery: MCPOAuthDiscoveryResult?,
        bestEffortRevoke: Bool = true
    ) async throws {
        let record = try await vault.resolveToken(handle)
        if bestEffortRevoke,
           let endpoint = discovery?.authorizationServerMetadata
                .revocationEndpoint
        {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode([
                "token": record.refreshToken ?? record.accessToken,
                "token_type_hint":
                    record.refreshToken == nil
                        ? "access_token" : "refresh_token",
                "client_id": record.clientID,
            ])
            _ = try? await httpClient.send(
                request,
                allowedOrigin: try MCPHTTPOrigin.canonical(endpoint))
        }
        try await vault.removeToken(handle)
        refreshTasks[handle.secretReference]?.cancel()
        refreshTasks[handle.secretReference] = nil
    }

    public func reset(
        token: MCPOAuthTokenHandle?,
        registration: MCPOAuthClientRegistrationHandle?
    ) async throws {
        cancelLogin()
        if let token {
            try await vault.removeToken(token)
            refreshTasks[token.secretReference]?.cancel()
            refreshTasks[token.secretReference] = nil
        }
        if let registration {
            try await vault.removeRegistration(registration)
        }
    }

    public func stepUpScopes(
        current: Set<String>,
        challenge: MCPOAuthChallenge
    ) throws -> Set<String> {
        guard challenge.statusCode == 401
                || challenge.statusCode == 403,
              !challenge.requiredScopes.isEmpty else {
            throw MCPOAuthError.invalidScopeChallenge
        }
        for scope in challenge.requiredScopes {
            try Self.validateScope(scope)
        }
        return current.union(challenge.requiredScopes)
    }

    // MARK: private discovery/client/token helpers

    private func protectedResourceCandidates(
        endpoint: URL,
        challengeURL: URL?
    ) throws -> [URL] {
        var result: [URL] = []
        if let challengeURL {
            let challengeOrigin = try MCPHTTPOrigin.canonical(challengeURL)
            let endpointOrigin = try MCPHTTPOrigin.canonical(endpoint)
            guard challengeOrigin == endpointOrigin else {
                throw MCPOAuthError.originMismatch
            }
            result.append(challengeURL)
        }
        result.append(
            contentsOf: DefaultOAuthMetadataDiscovery()
                .protectedResourceMetadataURLs(for: endpoint))
        var seen: Set<String> = []
        return result.filter {
            seen.insert($0.absoluteString).inserted
        }
    }

    private func authorizationMetadataCandidates(
        issuer: URL
    ) -> [URL] {
        DefaultOAuthMetadataDiscovery()
            .authorizationServerMetadataURLs(for: issuer)
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        let origin = try MCPHTTPOrigin.canonical(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept")
        let response = try await httpClient.send(
            request,
            allowedOrigin: origin)
        guard response.statusCode == 200 else {
            throw MCPOAuthError.httpStatus(response.statusCode)
        }
        let contentType = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type")
                == .orderedSame
        })?.value.lowercased()
        guard contentType?.contains("application/json") == true,
              let decoded = try? JSONDecoder().decode(
                T.self,
                from: response.body) else {
            throw MCPOAuthError.invalidMetadata
        }
        return decoded
    }

    private func validateAuthorizationEndpoints(
        _ value: MCPOAuthAuthorizationServerMetadata
    ) throws {
        let origin = try MCPHTTPOrigin.canonical(value.issuer)
        for endpoint in [
            value.authorizationEndpoint,
            value.tokenEndpoint,
            value.registrationEndpoint,
            value.revocationEndpoint,
        ].compactMap({ $0 }) {
            guard try MCPHTTPOrigin.canonical(endpoint) == origin else {
                throw MCPOAuthError.originMismatch
            }
        }
    }

    private func resolveClient(
        configuration: MCPOAuthConfiguration,
        discovery: MCPOAuthDiscoveryResult,
        redirectURI: URL,
        policy: MCPOAuthLoginPolicy
    ) async throws -> MCPOAuthResolvedClient {
        let metadata = discovery.authorizationServerMetadata
        if let clientID = configuration.clientID {
            if let clientURL = URL(string: clientID),
               clientURL.scheme?.lowercased() == "https"
            {
                guard metadata.clientIDMetadataDocumentSupported == true,
                      policy.clientMetadataDocumentURL == nil
                        || policy.clientMetadataDocumentURL == clientURL else {
                    throw MCPOAuthError
                        .clientMetadataDocumentUnsupported
                }
            }
            let secret: String?
            if let reference = configuration.clientSecretReference {
                let data = try await secretStore.resolve(reference)
                guard let value = String(data: data, encoding: .utf8),
                      !value.isEmpty else {
                    throw MCPOAuthError.corruptCredential
                }
                secret = value
            } else {
                secret = nil
            }
            return MCPOAuthResolvedClient(
                clientID: clientID,
                clientSecret: secret,
                tokenEndpointAuthMethod:
                    try chooseTokenAuthMethod(
                        hasSecret: secret != nil,
                        supported:
                            metadata
                                .tokenEndpointAuthMethodsSupported),
                registrationHandle: nil)
        }

        if let document = policy.clientMetadataDocumentURL {
            guard metadata.clientIDMetadataDocumentSupported == true,
                  document.scheme?.lowercased() == "https",
                  document.user == nil, document.password == nil,
                  metadata.tokenEndpointAuthMethodsSupported == nil
                    || metadata.tokenEndpointAuthMethodsSupported?
                        .contains("none") == true else {
                throw MCPOAuthError
                    .clientMetadataDocumentUnsupported
            }
            return MCPOAuthResolvedClient(
                clientID: document.absoluteString,
                clientSecret: nil,
                tokenEndpointAuthMethod: "none",
                registrationHandle: nil)
        }

        guard policy.allowDynamicClientRegistration,
              let endpoint = metadata.registrationEndpoint else {
            throw MCPOAuthError.clientRegistrationRequired
        }
        let registration = try await dynamicRegister(
            endpoint: endpoint,
            redirectURI: redirectURI,
            metadata: metadata)
        let origin = try MCPHTTPOrigin.canonical(metadata.issuer)
        let handle = try await vault.storeRegistration(
            authorizationServerOrigin: origin,
            clientID: registration.clientID,
            clientSecret: registration.clientSecret,
            tokenEndpointAuthMethod:
                registration.tokenEndpointAuthMethod)
        return MCPOAuthResolvedClient(
            clientID: registration.clientID,
            clientSecret: registration.clientSecret,
            tokenEndpointAuthMethod:
                registration.tokenEndpointAuthMethod,
            registrationHandle: handle)
    }

    private struct RegistrationResponse: Decodable {
        let clientID: String
        let clientSecret: String?
        let tokenEndpointAuthMethod: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case tokenEndpointAuthMethod =
                "token_endpoint_auth_method"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(
                keyedBy: CodingKeys.self)
            clientID = try container.decode(
                String.self,
                forKey: .clientID)
            clientSecret = try container.decodeIfPresent(
                String.self,
                forKey: .clientSecret)
            tokenEndpointAuthMethod =
                try container.decodeIfPresent(
                    String.self,
                    forKey: .tokenEndpointAuthMethod) ?? "none"
        }
    }

    private func dynamicRegister(
        endpoint: URL,
        redirectURI: URL,
        metadata: MCPOAuthAuthorizationServerMetadata
    ) async throws -> RegistrationResponse {
        let supported = metadata.tokenEndpointAuthMethodsSupported
            ?? ["none"]
        let requestedAuthentication: String
        if supported.contains("none") {
            requestedAuthentication = "none"
        } else if supported.contains("client_secret_basic") {
            requestedAuthentication = "client_secret_basic"
        } else if supported.contains("client_secret_post") {
            requestedAuthentication = "client_secret_post"
        } else {
            throw MCPOAuthError.unsupportedClientAuthentication
        }
        let payload: [String: Any] = [
            "client_name": IntatisHostApplication.identity.name,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": [
                "authorization_code",
                "refresh_token",
            ],
            "response_types": ["code"],
            "token_endpoint_auth_method":
                requestedAuthentication,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys])
        let response = try await httpClient.send(
            request,
            allowedOrigin: try MCPHTTPOrigin.canonical(metadata.issuer))
        guard response.statusCode == 200 || response.statusCode == 201,
              Self.hasJSONContentType(response.headers),
              let value = try? JSONDecoder().decode(
                RegistrationResponse.self,
                from: response.body),
              !value.clientID.isEmpty,
              ["none", "client_secret_basic", "client_secret_post"]
                .contains(value.tokenEndpointAuthMethod),
              metadata.tokenEndpointAuthMethodsSupported == nil
                || metadata.tokenEndpointAuthMethodsSupported?
                    .contains(value.tokenEndpointAuthMethod) == true,
              value.tokenEndpointAuthMethod == "none"
                || value.clientSecret != nil else {
            throw MCPOAuthError.invalidClientRegistration
        }
        return value
    }

    private func tokenRequest(
        endpoint: URL,
        parameters: [String: String],
        client: MCPOAuthResolvedClient
    ) async throws -> MCPOAuthHTTPResponse {
        var values = parameters
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type")
        switch client.tokenEndpointAuthMethod {
        case "client_secret_basic":
            guard let secret = client.clientSecret else {
                throw MCPOAuthError.clientRegistrationRequired
            }
            let basic = Data(
                "\(client.clientID):\(secret)".utf8)
                .base64EncodedString()
            request.setValue(
                "Basic \(basic)",
                forHTTPHeaderField: "Authorization")
        case "client_secret_post":
            guard let secret = client.clientSecret else {
                throw MCPOAuthError.clientRegistrationRequired
            }
            values["client_id"] = client.clientID
            values["client_secret"] = secret
        case "none":
            values["client_id"] = client.clientID
        default:
            throw MCPOAuthError.unsupportedClientAuthentication
        }
        request.httpBody = Self.formEncode(values)
        let response = try await httpClient.send(
            request,
            allowedOrigin: try MCPHTTPOrigin.canonical(endpoint))
        guard response.statusCode == 200,
              Self.hasJSONContentType(response.headers) else {
            throw MCPOAuthError.tokenRequestFailed(
                response.statusCode)
        }
        return response
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: Int?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private struct DecodedToken {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let scopes: Set<String>
        let expiresAt: Date?
    }

    private func decodeTokenResponse(
        _ response: MCPOAuthHTTPResponse,
        requestedScopes: Set<String>,
        canonicalResource: URL
    ) throws -> DecodedToken {
        guard let value = try? JSONDecoder().decode(
            TokenResponse.self,
            from: response.body),
              !value.accessToken.isEmpty,
              value.accessToken.utf8.count
                <= MCPSecretStoreLimits.maximumSecretBytes,
              value.tokenType.caseInsensitiveCompare("Bearer")
                == .orderedSame else {
            throw MCPOAuthError.invalidTokenResponse
        }
        let scopes: Set<String>
        if let scope = value.scope {
            scopes = Set(
                scope.split(whereSeparator: \.isWhitespace)
                    .map(String.init))
        } else {
            scopes = requestedScopes
        }
        guard scopes.isSuperset(of: requestedScopes) else {
            throw MCPOAuthError.insufficientGrantedScope
        }
        for scope in scopes { try Self.validateScope(scope) }
        try MCPOAuthCanonical.validateJWTAudienceIfPresent(
            value.accessToken,
            resource: canonicalResource)
        let expiresAt = value.expiresIn.map {
            Date().addingTimeInterval(
                TimeInterval(max(0, $0)))
        }
        return DecodedToken(
            accessToken: value.accessToken,
            refreshToken: value.refreshToken,
            tokenType: "Bearer",
            scopes: scopes,
            expiresAt: expiresAt)
    }

    private func makeAuthorizationURL(
        endpoint: URL,
        clientID: String,
        redirectURI: URL,
        resource: URL,
        scopes: Set<String>,
        state: String,
        nonce: String,
        codeChallenge: String
    ) throws -> URL {
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(
                name: "redirect_uri",
                value: redirectURI.absoluteString),
            URLQueryItem(name: "resource", value: resource.absoluteString),
            URLQueryItem(
                name: "scope",
                value: scopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(
                name: "code_challenge",
                value: codeChallenge),
            URLQueryItem(
                name: "code_challenge_method",
                value: "S256"),
        ]
        guard let url = components?.url else {
            throw MCPOAuthError.invalidMetadata
        }
        return url
    }

    private func validateCallback(
        _ callback: URL,
        expectedRedirect: URL,
        expectedState: String
    ) throws -> String {
        guard let actual = URLComponents(
            url: callback,
            resolvingAgainstBaseURL: false),
              let expected = URLComponents(
                url: expectedRedirect,
                resolvingAgainstBaseURL: false),
              actual.scheme?.lowercased()
                == expected.scheme?.lowercased(),
              actual.host?.lowercased()
                == expected.host?.lowercased(),
              actual.port == expected.port,
              actual.path == expected.path,
              actual.fragment == nil else {
            throw MCPOAuthError.callbackMismatch
        }
        let values = Dictionary(
            uniqueKeysWithValues:
                (actual.queryItems ?? []).map { ($0.name, $0.value) })
        guard let state = values["state"] ?? nil,
              Self.constantTimeEqual(state, expectedState) else {
            throw MCPOAuthError.stateMismatch
        }
        guard let code = values["code"] ?? nil, !code.isEmpty,
              code.utf8.count <= 8 * 1_024 else {
            throw MCPOAuthError.authorizationCodeMissing
        }
        return code
    }

    private func chooseTokenAuthMethod(
        hasSecret: Bool,
        supported: [String]?
    ) throws -> String {
        let supported = supported ?? (
            hasSecret
                ? ["client_secret_basic"]
                : ["none"])
        if hasSecret && supported.contains("client_secret_basic") {
            return "client_secret_basic"
        }
        if hasSecret && supported.contains("client_secret_post") {
            return "client_secret_post"
        }
        if !hasSecret && supported.contains("none") {
            return "none"
        }
        throw MCPOAuthError.unsupportedClientAuthentication
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func validateScope(_ scope: String) throws {
        guard !scope.isEmpty, scope.utf8.count <= 256,
              !scope.contains(where: \.isWhitespace),
              !scope.contains("\0") else {
            throw MCPOAuthError.invalidScopeChallenge
        }
    }

    private static func formEncode(
        _ values: [String: String]
    ) -> Data {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = values.sorted { $0.key < $1.key }.map {
            let key = $0.key.addingPercentEncoding(
                withAllowedCharacters: allowed) ?? ""
            let value = $0.value.addingPercentEncoding(
                withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func hasJSONContentType(
        _ headers: [String: String]
    ) -> Bool {
        headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type")
                == .orderedSame
        })?.value.lowercased().contains("application/json") == true
    }

    private static func constantTimeEqual(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(
            truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}

// MARK: - Canonical validation and errors

private enum MCPOAuthCanonical {
    static func resource(_ url: URL) throws -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else {
            throw MCPOAuthError.invalidResource
        }
        let normalizedHost = host.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        guard scheme == "https"
                || (scheme == "http"
                    && (normalizedHost == "127.0.0.1"
                        || normalizedHost == "::1")) else {
            throw MCPOAuthError.invalidResource
        }
        components.scheme = scheme
        components.host = normalizedHost
        components.query = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        if components.path == "/" { components.path = "" }
        guard let value = components.url else {
            throw MCPOAuthError.invalidResource
        }
        return value
    }

    static func authorizationServer(_ url: URL) throws -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MCPOAuthError.invalidMetadata
        }
        let normalizedHost = host.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        guard scheme == "https"
                || (scheme == "http"
                    && (normalizedHost == "127.0.0.1"
                        || normalizedHost == "::1")) else {
            throw MCPOAuthError.invalidMetadata
        }
        components.scheme = scheme
        components.host = normalizedHost
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        guard let value = components.url else {
            throw MCPOAuthError.invalidMetadata
        }
        return value
    }

    /// RFC 9728 permits origin-wide protected-resource metadata at the root
    /// well-known location. Accept that one widening only when the client
    /// actually reached the exact root fallback on the same origin; challenge
    /// URLs and path-based metadata cannot silently broaden a configured
    /// resource.
    static func acceptsDiscoveredResource(
        _ declared: URL,
        configuredResource: URL,
        metadataURL: URL
    ) -> Bool {
        if declared == configuredResource { return true }
        guard metadataURL.path
                == "/.well-known/oauth-protected-resource",
              metadataURL.query == nil,
              metadataURL.fragment == nil,
              (try? MCPHTTPOrigin.canonical(declared))
                == (try? MCPHTTPOrigin.canonical(configuredResource)),
              let declaredComponents = URLComponents(
                url: declared,
                resolvingAgainstBaseURL: false),
              declaredComponents.path.isEmpty,
              declaredComponents.query == nil,
              declaredComponents.fragment == nil else {
            return false
        }
        return true
    }

    /// A token issued for an origin-root resource may be presented to an MCP
    /// endpoint on that exact origin. Non-root resource identifiers remain
    /// exact, preventing a token for one path from crossing into a sibling.
    static func resource(
        _ authorizedResource: URL,
        authorizes requestResource: URL
    ) -> Bool {
        guard let authorized = try? resource(authorizedResource),
              let request = try? resource(requestResource),
              (try? MCPHTTPOrigin.canonical(authorized))
                == (try? MCPHTTPOrigin.canonical(request)) else {
            return false
        }
        if authorized == request { return true }
        guard let components = URLComponents(
                url: authorized,
                resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.path.isEmpty
            && components.query == nil
            && components.fragment == nil
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func validateJWTAudienceIfPresent(
        _ accessToken: String,
        resource: URL
    ) throws {
        let pieces = accessToken.split(separator: ".")
        guard pieces.count == 3 else { return } // opaque token
        var encoded = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(
            repeating: "=",
            count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any] else {
            throw MCPOAuthError.invalidTokenResponse
        }
        let audiences: Set<String>
        if let value = object["aud"] as? String {
            audiences = [value]
        } else if let values = object["aud"] as? [String] {
            audiences = Set(values)
        } else {
            throw MCPOAuthError.audienceMismatch
        }
        guard audiences.contains(resource.absoluteString) else {
            throw MCPOAuthError.audienceMismatch
        }
    }
}

public enum MCPOAuthError:
    Error, Equatable, LocalizedError, Sendable
{
    case authorityMismatch
    case originMismatch
    case resourceMismatch
    case issuerMismatch
    case invalidResource
    case invalidMetadata
    case protectedResourceDiscoveryFailed
    case authorizationServerDiscoveryFailed
    case redirectDenied
    case responseTooLarge
    case invalidHTTPResponse
    case httpStatus(Int)
    case clientMetadataDocumentUnsupported
    case clientRegistrationRequired
    case invalidClientRegistration
    case unsupportedClientAuthentication
    case pkceS256Required
    case invalidLoopbackRedirect
    case unregisteredFixedRedirect
    case staleLoginGeneration
    case callbackMismatch
    case stateMismatch
    case authorizationCodeMissing
    case tokenRequestFailed(Int)
    case invalidTokenResponse
    case unsupportedTokenType
    case insufficientGrantedScope
    case invalidScopeChallenge
    case audienceMismatch
    case refreshTokenUnavailable
    case refreshRequired
    case staleCredentialGeneration
    case corruptCredential
    case stagedCredentialInactive
    case stagedCredentialMismatch
    case generationOverflow

    public var errorDescription: String? {
        switch self {
        case .authorityMismatch:
            return "OAuth credential authority does not match the MCP server."
        case .originMismatch:
            return "OAuth request origin is outside the discovered authority."
        case .resourceMismatch:
            return "OAuth resource metadata does not match the configured MCP resource."
        case .issuerMismatch:
            return "OAuth issuer metadata does not match the discovered issuer."
        case .invalidResource:
            return "The OAuth resource URI is invalid."
        case .invalidMetadata:
            return "The OAuth metadata document is invalid."
        case .protectedResourceDiscoveryFailed:
            return "OAuth Protected Resource Metadata discovery failed."
        case .authorizationServerDiscoveryFailed:
            return "OAuth Authorization Server discovery failed."
        case .redirectDenied:
            return "An OAuth HTTP redirect was denied."
        case .responseTooLarge:
            return "An OAuth response exceeded its hard size limit."
        case .invalidHTTPResponse:
            return "The OAuth server returned an invalid HTTP response."
        case .httpStatus(let status):
            return "OAuth metadata request returned HTTP \(status)."
        case .clientMetadataDocumentUnsupported:
            return "The authorization server does not support the selected Client ID Metadata Document."
        case .clientRegistrationRequired:
            return "A pre-registered client, Client ID Metadata Document, or explicitly authorized dynamic registration is required."
        case .invalidClientRegistration:
            return "The OAuth dynamic client registration response is invalid."
        case .unsupportedClientAuthentication:
            return "The OAuth token endpoint requires an unsupported client authentication method."
        case .pkceS256Required:
            return "The OAuth server does not support required PKCE S256."
        case .invalidLoopbackRedirect:
            return "OAuth callback must use an exact 127.0.0.1 or ::1 loopback URI."
        case .unregisteredFixedRedirect:
            return "A fixed OAuth callback port must be present in the selected client registration metadata."
        case .staleLoginGeneration:
            return "The OAuth login generation is no longer active."
        case .callbackMismatch:
            return "The OAuth callback URI does not exactly match the active login."
        case .stateMismatch:
            return "The OAuth callback state does not match the active login."
        case .authorizationCodeMissing:
            return "The OAuth callback did not contain an authorization code."
        case .tokenRequestFailed(let status):
            return "The OAuth token request returned HTTP \(status)."
        case .invalidTokenResponse:
            return "The OAuth token response is invalid."
        case .unsupportedTokenType:
            return "Only OAuth Bearer access tokens are supported."
        case .insufficientGrantedScope:
            return "The OAuth server did not grant all explicitly requested scopes."
        case .invalidScopeChallenge:
            return "The OAuth scope challenge is invalid."
        case .audienceMismatch:
            return "The OAuth token audience does not contain the canonical MCP resource."
        case .refreshTokenUnavailable:
            return "No refresh token is available for this MCP account."
        case .refreshRequired:
            return "The OAuth token must be refreshed in a new connection generation."
        case .staleCredentialGeneration:
            return "The OAuth credential generation is stale or retired."
        case .corruptCredential:
            return "The protected OAuth credential record is corrupt or belongs to another authority."
        case .stagedCredentialInactive:
            return "The staged OAuth credential is inactive outside its exact configuration Test."
        case .stagedCredentialMismatch:
            return "The staged OAuth credential does not match the exact prepared or published MCP revision."
        case .generationOverflow:
            return "The OAuth generation cannot advance."
        }
    }
}
