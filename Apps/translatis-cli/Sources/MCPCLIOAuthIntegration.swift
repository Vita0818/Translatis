#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("TranslatisCLI requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol

enum MCPCLIOAuthError:
    Error, LocalizedError, Equatable
{
    case unsupportedTransport
    case oauthNotConfigured
    case accountNotConfigured
    case exactRevisionMismatch
    case exactAuthorityMismatch
    case credentialNotFound
    case unsafeMetadataStore
    case corruptMetadataStore
    case metadataStoreIO
    case browserLaunchFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport:
            return "OAuth requires a Streamable HTTP MCP server."
        case .oauthNotConfigured:
            return "OAuth is not enabled for this exact MCP server revision."
        case .accountNotConfigured:
            return "The MCP server has no opaque OAuth account reference."
        case .exactRevisionMismatch:
            return "The OAuth account belongs to a different immutable MCP server revision."
        case .exactAuthorityMismatch:
            return "The OAuth account does not match the exact server, resource, origin, and account authority."
        case .credentialNotFound:
            return "No active OAuth credential exists for this exact MCP server revision."
        case .unsafeMetadataStore:
            return "The OAuth account metadata is not a safe owner-only regular file."
        case .corruptMetadataStore:
            return "The OAuth account metadata is corrupt or uses an unsupported schema."
        case .metadataStoreIO:
            return "The OAuth account metadata could not be committed durably."
        case .browserLaunchFailed:
            return "The OAuth authorization page could not be opened."
        }
    }
}

struct MCPCLIOAuthAccountSummary:
    Codable, Equatable, Sendable
{
    let server: MCPServerReference
    let canonicalResource: String
    let accountReference: MCPAccountReference
    let scopes: [String]
    let authorizationServerOrigin: String
    let expiresAt: Date?
    let credentialGeneration: UInt64
    let active: Bool
    let updatedAt: Date
}

private struct MCPCLIOAuthAccountRecord:
    Codable, Equatable, Sendable
{
    let server: MCPServerReference
    let canonicalOrigin: String
    let canonicalResource: String
    let accountReference: MCPAccountReference
    let tokenHandle: MCPOAuthTokenHandle
    let active: Bool
    let updatedAt: Date
    let revokedAt: Date?

    var key: String {
        [
            server.serverID.rawValue,
            server.serverRevision.rawValue,
            canonicalResource,
            accountReference.rawValue,
        ].joined(separator: "\u{1f}")
    }

    var authorityScopeKey: String {
        [
            server.serverID.rawValue,
            canonicalResource,
            accountReference.rawValue,
        ].joined(separator: "\u{1f}")
    }

    var summary: MCPCLIOAuthAccountSummary {
        MCPCLIOAuthAccountSummary(
            server: server,
            canonicalResource: canonicalResource,
            accountReference: accountReference,
            scopes: tokenHandle.scopes.sorted(),
            authorizationServerOrigin:
                tokenHandle.authorizationServerOrigin,
            expiresAt: tokenHandle.expiresAt,
            credentialGeneration:
                tokenHandle.generation.rawValue,
            active: active,
            updatedAt: updatedAt)
    }
}

private struct MCPCLIOAuthAccountFile:
    Codable, Equatable, Sendable
{
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generation: UInt64
    let records: [MCPCLIOAuthAccountRecord]
    let contentDigest: String

    init(
        generation: UInt64,
        records: [MCPCLIOAuthAccountRecord]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.records = records.sorted { $0.key < $1.key }
        contentDigest = try Self.digest(
            schemaVersion: schemaVersion,
            generation: generation,
            records: self.records)
    }

    func validated() throws -> Self {
        let activeScopeKeys = records
            .filter(\.active)
            .map(\.authorityScopeKey)
        guard schemaVersion == Self.currentSchemaVersion,
              generation > 0 || records.isEmpty,
              Set(records.map(\.key)).count == records.count,
              Set(activeScopeKeys).count == activeScopeKeys.count,
              records.allSatisfy(Self.validRecord),
              contentDigest == (try Self.digest(
                schemaVersion: schemaVersion,
                generation: generation,
                records: records))
        else {
            throw MCPCLIOAuthError.corruptMetadataStore
        }
        return self
    }

    private struct DigestMaterial: Codable {
        let schemaVersion: Int
        let generation: UInt64
        let records: [MCPCLIOAuthAccountRecord]
    }

    private static func digest(
        schemaVersion: Int,
        generation: UInt64,
        records: [MCPCLIOAuthAccountRecord]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys, .withoutEscapingSlashes,
        ]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(DigestMaterial(
            schemaVersion: schemaVersion,
            generation: generation,
            records: records))
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validRecord(
        _ record: MCPCLIOAuthAccountRecord
    ) -> Bool {
        guard record.canonicalOrigin.hasPrefix("https://"),
              record.canonicalResource.hasPrefix("https://"),
              record.tokenHandle.authority.serverID
                == record.server.serverID,
              record.tokenHandle.authority.canonicalOrigin
                == record.canonicalOrigin,
              record.tokenHandle.authority.canonicalResource
                == record.canonicalResource,
              record.tokenHandle.authority.accountReference
                == record.accountReference,
              record.tokenHandle.secretReference.storageClass
                == .encryptedCLIStore,
              record.tokenHandle.generation.rawValue > 0,
              (!record.active
                || record.tokenHandle.isActive(
                    for: record.server))
        else {
            return false
        }
        return record.active
            ? record.revokedAt == nil
            : record.revokedAt != nil
    }
}

/// Durable secret-free mapping from one exact published MCP authority to the
/// opaque handle owned by `MCPCLIEncryptedSecretStore`.
actor MCPCLIOAuthAccountStore {
    static let fileName = "mcp-oauth-accounts-v1.json"

    private let fileURL: URL
    private let lockURL: URL
    private let maximumBytes = 2 * 1_024 * 1_024

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        lockURL = fileURL
            .appendingPathExtension("lock")
            .standardizedFileURL
    }

    func summaries()
        throws -> [MCPCLIOAuthAccountSummary] {
        try withLock {
            try loadLocked().records.map(\.summary)
        }
    }

    fileprivate func activeRecord(
        server: MCPServerReference,
        canonicalResource: String,
        accountReference: MCPAccountReference
    ) throws -> MCPCLIOAuthAccountRecord? {
        try withLock {
            try loadLocked().records.first {
                $0.server == server
                    && $0.canonicalResource
                        == canonicalResource
                    && $0.accountReference
                        == accountReference
                    && $0.active
            }
        }
    }

    /// Publishes one active exact revision and tombstones every older revision
    /// for the same server/resource/account authority in one durable write.
    fileprivate func publish(
        server: MCPServerReference,
        canonicalOrigin: String,
        canonicalResource: String,
        accountReference: MCPAccountReference,
        tokenHandle: MCPOAuthTokenHandle
    ) throws -> [MCPCLIOAuthAccountRecord] {
        try withLock {
            let file = try loadLocked()
            guard file.generation < UInt64.max else {
                throw MCPCLIOAuthError.metadataStoreIO
            }
            let now = Date()
            let replacement = MCPCLIOAuthAccountRecord(
                server: server,
                canonicalOrigin: canonicalOrigin,
                canonicalResource: canonicalResource,
                accountReference: accountReference,
                tokenHandle: tokenHandle,
                active: true,
                updatedAt: now,
                revokedAt: nil)
            let previous = file.records.filter {
                $0.authorityScopeKey
                    == replacement.authorityScopeKey
                    && $0.active
            }
            var records = file.records.filter {
                $0.key != replacement.key
            }.map { record in
                guard record.authorityScopeKey
                        == replacement.authorityScopeKey,
                      record.active else {
                    return record
                }
                return MCPCLIOAuthAccountRecord(
                    server: record.server,
                    canonicalOrigin:
                        record.canonicalOrigin,
                    canonicalResource:
                        record.canonicalResource,
                    accountReference:
                        record.accountReference,
                    tokenHandle: record.tokenHandle,
                    active: false,
                    updatedAt: now,
                    revokedAt: now)
            }
            records.append(replacement)
            try saveLocked(try MCPCLIOAuthAccountFile(
                generation: file.generation + 1,
                records: records))
            return previous
        }
    }

    func tombstone(
        server: MCPServerReference,
        canonicalResource: String,
        accountReference: MCPAccountReference
    ) throws {
        try withLock {
            let file = try loadLocked()
            guard file.generation < UInt64.max,
                  let index = file.records.firstIndex(
                    where: {
                        $0.server == server
                            && $0.canonicalResource
                                == canonicalResource
                            && $0.accountReference
                                == accountReference
                            && $0.active
                    })
            else {
                throw MCPCLIOAuthError.credentialNotFound
            }
            var records = file.records
            let current = records[index]
            let now = Date()
            records[index] = MCPCLIOAuthAccountRecord(
                server: current.server,
                canonicalOrigin: current.canonicalOrigin,
                canonicalResource:
                    current.canonicalResource,
                accountReference:
                    current.accountReference,
                tokenHandle: current.tokenHandle,
                active: false,
                updatedAt: now,
                revokedAt: now)
            try saveLocked(try MCPCLIOAuthAccountFile(
                generation: file.generation + 1,
                records: records))
        }
    }

    private func withLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try DurableOwnerOnlyFile
                .withExclusiveLock(at: lockURL) {
                    try operation()
                }
        } catch let error as MCPCLIOAuthError {
            throw error
        } catch is DurableOwnerOnlyFileError {
            throw MCPCLIOAuthError.unsafeMetadataStore
        } catch {
            throw MCPCLIOAuthError.metadataStoreIO
        }
    }

    private func loadLocked()
        throws -> MCPCLIOAuthAccountFile {
        let data: Data?
        do {
            data = try DurableOwnerOnlyFile.read(
                from: fileURL)
        } catch {
            throw MCPCLIOAuthError.unsafeMetadataStore
        }
        guard let data else {
            return try MCPCLIOAuthAccountFile(
                generation: 0,
                records: [])
        }
        guard data.count <= maximumBytes else {
            throw MCPCLIOAuthError.unsafeMetadataStore
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy =
            .millisecondsSince1970
        guard let value = try? decoder.decode(
            MCPCLIOAuthAccountFile.self,
            from: data) else {
            throw MCPCLIOAuthError.corruptMetadataStore
        }
        return try value.validated()
    }

    private func saveLocked(
        _ value: MCPCLIOAuthAccountFile
    ) throws {
        let checked = try value.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys, .withoutEscapingSlashes,
        ]
        encoder.dateEncodingStrategy =
            .millisecondsSince1970
        let data = try encoder.encode(checked)
        guard data.count <= maximumBytes else {
            throw MCPCLIOAuthError.metadataStoreIO
        }
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: fileURL,
                temporaryPrefix:
                    ".mcp-oauth-accounts-")
        } catch {
            throw MCPCLIOAuthError.metadataStoreIO
        }
    }
}

/// CLI OAuth host. Login credentials are staged for exactly one immutable
/// configuration Test and become active only after the corresponding catalog
/// CAS receipt is available.
actor MCPCLIOAuthCoordinator {
    private let secretStore:
        MCPCLIEncryptedSecretStore
    private let vault: MCPOAuthCredentialVault
    private let coordinator: MCPOAuthCoordinator
    private let accounts: MCPCLIOAuthAccountStore
    private var staged:
        [String: MCPOAuthTokenHandle] = [:]

    init(
        secretStore: MCPCLIEncryptedSecretStore,
        accounts: MCPCLIOAuthAccountStore
    ) {
        self.secretStore = secretStore
        self.accounts = accounts
        vault = MCPOAuthCredentialVault(
            secretStore: secretStore)
        coordinator = MCPOAuthCoordinator(
            httpClient:
                MCPURLSessionOAuthHTTPClient(),
            vault: vault,
            secretStore: secretStore)
    }

    func summaries()
        async throws -> [MCPCLIOAuthAccountSummary] {
        try await accounts.summaries()
    }

    func activeSummary(
        definition: MCPServerDefinition
    ) async throws -> MCPCLIOAuthAccountSummary? {
        let values = try oauthValues(definition)
        return try await accounts.activeRecord(
            server: definition.reference,
            canonicalResource:
                values.oauth.canonicalResource,
            accountReference: values.account)?
            .summary
    }

    func loginStaged(
        prepared: MCPPreparedServerConfiguration,
        allowDynamicClientRegistration: Bool,
        openBrowser: Bool
    ) async throws {
        let definition = prepared.definition
        guard definition.reference
                == prepared.expectedServerReference else {
            throw MCPCLIOAuthError.exactRevisionMismatch
        }
        let values = try oauthValues(definition)
        guard let endpoint = URL(
                string: values.http.endpoint),
              let resource = URL(
                string:
                    values.oauth.canonicalResource)
        else {
            throw MCPCLIOAuthError
                .exactAuthorityMismatch
        }
        if let previous = staged.removeValue(
            forKey: prepared.preparationFingerprint)
        {
            try await vault.discardStagedToken(
                previous)
        }

        let listener =
            try MCPOAuthLoopbackCallbackListener.bind(
                host: .ipv4,
                port: 0,
                callbackPath: "/callback")
        defer { listener.close() }
        let discovery = try await coordinator.discover(
            endpoint: endpoint,
            configuredResource: resource)
        let attempt = try await coordinator.beginLogin(
            serverID: definition.reference.serverID,
            accountReference: values.account,
            configuration: values.oauth,
            discovery: discovery,
            redirectPolicy: .ephemeralIPv4(
                port:
                    listener.redirectURI.port ?? 0),
            loginPolicy: MCPOAuthLoginPolicy(
                allowDynamicClientRegistration:
                    allowDynamicClientRegistration),
            stagingBinding:
                MCPOAuthStagingBinding(
                    prepared: prepared))

        errOut(
            """
            OAuth authorization
              server: \(definition.configuration.displayName)
              resource: \(values.oauth.canonicalResource)
              authorization server: \(attempt.authorizationURL.scheme ?? "unknown")://\(attempt.authorizationURL.host ?? "unknown")
              account: \(values.account.rawValue)
              scopes: \(attempt.requestedScopes.sorted().joined(separator: " "))
              redirect: \(attempt.redirectURI.absoluteString)
              URL: \(attempt.authorizationURL.absoluteString)

            """)
        if openBrowser,
           !MCPCLIOAuthBrowser.open(
                attempt.authorizationURL) {
            await coordinator.cancelLogin(attempt)
            throw MCPCLIOAuthError
                .browserLaunchFailed
        }

        let callback: URL
        do {
            callback =
                try await listener.waitForCallback()
        } catch {
            await coordinator.cancelLogin(attempt)
            throw error
        }
        let token = try await coordinator
            .completeLogin(
                attempt,
                callbackURL: callback)
        do {
            let generation =
                MCPConnectionGeneration.new()
            let provider =
                MCPOAuthAuthorizationProvider(
                    vault: vault,
                    handle: token,
                    connectionGeneration:
                        generation,
                    expectedServerReference:
                        prepared
                            .expectedServerReference,
                    stagedTestPreparationFingerprint:
                        prepared
                            .preparationFingerprint)
            let header =
                try await provider
                    .authorizationHeader(
                        for: resource,
                        connectionGeneration:
                            generation)
            guard header?.hasPrefix("Bearer ")
                    == true else {
                throw MCPCLIOAuthError
                    .exactAuthorityMismatch
            }
            await provider.retire()
            staged[prepared.preparationFingerprint] =
                token
        } catch {
            try await vault.discardStagedToken(token)
            throw error
        }
    }

    func activateStagedLogin(
        prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof,
        publishedCatalog: MCPServerCatalog
    ) async throws -> MCPCLIOAuthAccountSummary {
        guard let token = staged[
                prepared.preparationFingerprint] else {
            throw MCPCLIOAuthError.credentialNotFound
        }
        let values = try oauthValues(
            prepared.definition)
        let active = try await vault
            .activateStagedToken(
                token,
                prepared: prepared,
                proof: proof,
                publishedCatalog: publishedCatalog)
        do {
            let previous =
                try await accounts.publish(
                    server:
                        prepared
                            .expectedServerReference,
                    canonicalOrigin:
                        values.http.canonicalOrigin,
                    canonicalResource:
                        values.oauth
                            .canonicalResource,
                    accountReference:
                        values.account,
                    tokenHandle: active)
            staged.removeValue(
                forKey:
                    prepared.preparationFingerprint)
            for prior in previous
                where prior.tokenHandle
                    .secretReference
                    != active.secretReference {
                try? await vault.removeToken(
                    prior.tokenHandle)
            }
            guard let record =
                    try await accounts.activeRecord(
                        server:
                            prepared
                                .expectedServerReference,
                        canonicalResource:
                            values.oauth
                                .canonicalResource,
                        accountReference:
                            values.account) else {
                throw MCPCLIOAuthError
                    .metadataStoreIO
            }
            return record.summary
        } catch {
            staged.removeValue(
                forKey:
                    prepared.preparationFingerprint)
            try? await vault.removeToken(active)
            throw error
        }
    }

    func discardStagedLogin(
        prepared: MCPPreparedServerConfiguration
    ) async throws {
        guard let token = staged.removeValue(
            forKey: prepared.preparationFingerprint)
        else { return }
        try await vault.discardStagedToken(token)
    }

    /// Revokes every live generation and durable consent before removing the
    /// credential, so no in-flight connection can race local logout.
    func logout(
        definition: MCPServerDefinition
    ) async throws {
        let values = try oauthValues(definition)
        guard let record =
                try await accounts.activeRecord(
                    server: definition.reference,
                    canonicalResource:
                        values.oauth
                            .canonicalResource,
                    accountReference:
                        values.account) else {
            throw MCPCLIOAuthError.credentialNotFound
        }
        try await MCPProcessCatalogRuntimeRegistry
            .shared.revokeCredentialAuthority(
                definition.reference)

        var discovery:
            MCPOAuthDiscoveryResult?
        if let endpoint = URL(
                string: values.http.endpoint),
           let resource = URL(
                string:
                    values.oauth.canonicalResource) {
            discovery = try? await coordinator.discover(
                endpoint: endpoint,
                configuredResource: resource)
        }
        try await coordinator.logout(
            record.tokenHandle,
            discovery: discovery,
            bestEffortRevoke: true)
        try await accounts.tombstone(
            server: definition.reference,
            canonicalResource:
                values.oauth.canonicalResource,
            accountReference: values.account)
    }

    nonisolated func providerBuilder()
        -> MCPProductionOAuthProviderBuilder {
        { [self] definition, identity, generation in
            try await self.authorizationProvider(
                definition: definition,
                identity: identity,
                generation: generation)
        }
    }

    private func authorizationProvider(
        definition: MCPServerDefinition,
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) async throws
        -> any MCPHTTPAuthorizationProviding {
        guard definition.reference
                == identity.server else {
            throw MCPCLIOAuthError
                .exactRevisionMismatch
        }
        let values = try oauthValues(definition)
        guard identity.oauthAccountReference
                == values.account else {
            throw MCPCLIOAuthError
                .exactAuthorityMismatch
        }

        let candidates = staged.filter {
            _, handle in
            handle.stagingBinding?
                .plannedReference
                == definition.reference
                && handle.authority.serverID
                    == definition.reference
                        .serverID
                && handle.authority.canonicalOrigin
                    == values.http
                        .canonicalOrigin
                && handle.authority
                    .canonicalResource
                    == values.oauth
                        .canonicalResource
                && handle.authority
                    .accountReference
                    == values.account
        }
        guard candidates.count <= 1 else {
            throw MCPCLIOAuthError
                .exactAuthorityMismatch
        }
        if let (preparation, handle) =
                candidates.first {
            guard try await secretStore.contains(
                    handle.secretReference) else {
                throw MCPCLIOAuthError
                    .credentialNotFound
            }
            return MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: handle,
                connectionGeneration: generation,
                expectedServerReference:
                    definition.reference,
                stagedTestPreparationFingerprint:
                    preparation)
        }

        guard let record =
                try await accounts.activeRecord(
                    server: definition.reference,
                    canonicalResource:
                        values.oauth
                            .canonicalResource,
                    accountReference:
                        values.account),
              record.canonicalOrigin
                == values.http.canonicalOrigin,
              record.tokenHandle.isActive(
                for: definition.reference),
              try await secretStore.contains(
                record.tokenHandle
                    .secretReference)
        else {
            throw MCPCLIOAuthError
                .credentialNotFound
        }
        return MCPOAuthAuthorizationProvider(
            vault: vault,
            handle: record.tokenHandle,
            connectionGeneration: generation,
            expectedServerReference:
                definition.reference)
    }

    private nonisolated func oauthValues(
        _ definition: MCPServerDefinition
    ) throws -> (
        http: MCPHTTPServerConfiguration,
        oauth: MCPOAuthConfiguration,
        account: MCPAccountReference
    ) {
        guard case .streamableHTTP(let http) =
                definition.configuration.transport
        else {
            throw MCPCLIOAuthError
                .unsupportedTransport
        }
        guard let oauth = http.oauth,
              oauth.enabled else {
            throw MCPCLIOAuthError
                .oauthNotConfigured
        }
        guard let account =
                oauth.accountReference else {
            throw MCPCLIOAuthError
                .accountNotConfigured
        }
        return (http, oauth, account)
    }
}

private enum MCPCLIOAuthBrowser {
    static func open(_ url: URL) -> Bool {
        #if os(macOS)
        let executable = "/usr/bin/open"
        #elseif os(Linux)
        let executable = "/usr/bin/xdg-open"
        #else
        return false
        #endif
        guard FileManager.default.isExecutableFile(
            atPath: executable) else {
            return false
        }
        let process = Process()
        process.executableURL =
            URL(fileURLWithPath: executable)
        process.arguments = [url.absoluteString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit
                && process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
