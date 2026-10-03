#if canImport(AppKit)
import AppKit
import CryptoKit
import Darwin
import Foundation
import IntatisMCP
import IntatisProtocol

enum MCPAppOAuthError: Error, LocalizedError, Equatable {
    case unsupportedTransport
    case oauthNotConfigured
    case accountNotConfigured
    case exactRevisionMismatch
    case exactAuthorityMismatch
    case credentialNotFound
    case unsafeMetadataStore
    case corruptMetadataStore
    case metadataStoreIO
    case browserLaunchDenied
    case loginCancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport:
            return "OAuth is available only for a remote Streamable HTTP MCP server."
        case .oauthNotConfigured:
            return "This MCP server revision does not enable OAuth."
        case .accountNotConfigured:
            return "Choose an opaque MCP account reference before signing in."
        case .exactRevisionMismatch:
            return "The OAuth account belongs to a different immutable MCP server revision."
        case .exactAuthorityMismatch:
            return "The OAuth account does not match the exact MCP resource and connection authority."
        case .credentialNotFound:
            return "No active OAuth account is stored for this exact MCP server revision."
        case .unsafeMetadataStore:
            return "The MCP OAuth account metadata store is not an owner-only regular file."
        case .corruptMetadataStore:
            return "The MCP OAuth account metadata store is corrupt or has a newer schema."
        case .metadataStoreIO:
            return "The MCP OAuth account metadata store could not be read or committed safely."
        case .browserLaunchDenied:
            return "The system did not open the OAuth authorization page."
        case .loginCancelled:
            return "OAuth sign-in was cancelled."
        }
    }
}

struct MCPAppOAuthAccountSummary: Codable, Equatable, Identifiable, Sendable {
    let server: MCPServerReference
    let canonicalResource: String
    let accountReference: MCPAccountReference
    let scopes: [String]
    let authorizationServerOrigin: String
    let expiresAt: Date?
    let credentialGeneration: UInt64
    let active: Bool
    let updatedAt: Date

    var id: String {
        [
            server.serverID.rawValue,
            server.serverRevision.rawValue,
            canonicalResource,
            accountReference.rawValue,
        ].joined(separator: "\u{1f}")
    }
}

struct MCPAppOAuthAuthorizationPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let server: MCPServerReference
    let displayName: String
    let canonicalResource: String
    let authorizationOrigin: String
    let accountReference: MCPAccountReference
    let scopes: [String]
    let usesDynamicClientRegistration: Bool
    let authorizationURL: URL

    init(
        server: MCPServerReference,
        displayName: String,
        canonicalResource: String,
        authorizationOrigin: String,
        accountReference: MCPAccountReference,
        scopes: [String],
        usesDynamicClientRegistration: Bool,
        authorizationURL: URL
    ) {
        id = UUID()
        self.server = server
        self.displayName = displayName
        self.canonicalResource = canonicalResource
        self.authorizationOrigin = authorizationOrigin
        self.accountReference = accountReference
        self.scopes = scopes
        self.usesDynamicClientRegistration =
            usesDynamicClientRegistration
        self.authorizationURL = authorizationURL
    }
}

private struct MCPAppOAuthAccountRecord: Codable, Equatable, Sendable {
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

    var summary: MCPAppOAuthAccountSummary {
        MCPAppOAuthAccountSummary(
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

private struct MCPAppOAuthAccountFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generation: UInt64
    let records: [MCPAppOAuthAccountRecord]
    let contentDigest: String

    init(
        generation: UInt64,
        records: [MCPAppOAuthAccountRecord]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.records = records.sorted { $0.key < $1.key }
        contentDigest = try Self.digest(
            schemaVersion: schemaVersion,
            generation: generation,
            records: self.records)
    }

    func validated() throws -> MCPAppOAuthAccountFile {
        guard schemaVersion == Self.currentSchemaVersion,
              generation > 0 || records.isEmpty,
              Set(records.map(\.key)).count == records.count,
              records.allSatisfy(Self.validRecord),
              contentDigest == (try Self.digest(
                schemaVersion: schemaVersion,
                generation: generation,
                records: records))
        else {
            throw MCPAppOAuthError.corruptMetadataStore
        }
        return self
    }

    private struct DigestMaterial: Codable {
        let schemaVersion: Int
        let generation: UInt64
        let records: [MCPAppOAuthAccountRecord]
    }

    private static func digest(
        schemaVersion: Int,
        generation: UInt64,
        records: [MCPAppOAuthAccountRecord]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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
        _ record: MCPAppOAuthAccountRecord
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
                == .macOSKeychain,
              record.tokenHandle.generation.rawValue > 0
        else {
            return false
        }
        return record.active ? record.revokedAt == nil : record.revokedAt != nil
    }
}

/// Owner-only, no-follow account-handle metadata.
///
/// OAuth token bytes remain in `MCPKeychainSecretStore`; this file contains
/// only exact authority metadata and opaque Keychain handles. A sidecar lock
/// serializes independent app windows/processes, and every read/write checks
/// current UID, regular-file type, link count and `0600` permissions.
actor MCPAppOAuthAccountStore {
    static let fileName = "mcp-oauth-accounts-v1.json"

    private let fileURL: URL
    private let lockURL: URL
    private let maximumBytes = 2 * 1_024 * 1_024

    init(fileURL: URL) {
        self.fileURL = fileURL
        lockURL = fileURL.appendingPathExtension("lock")
    }

    func summaries() throws -> [MCPAppOAuthAccountSummary] {
        try withExclusiveLock {
            try loadLocked().records.map(\.summary)
        }
    }

    fileprivate func activeRecord(
        server: MCPServerReference,
        canonicalResource: String,
        accountReference: MCPAccountReference
    ) throws -> MCPAppOAuthAccountRecord? {
        try withExclusiveLock {
            try loadLocked().records.first {
                $0.server == server
                    && $0.canonicalResource == canonicalResource
                    && $0.accountReference == accountReference
                    && $0.active
            }
        }
    }

    @discardableResult
    fileprivate func publish(
        server: MCPServerReference,
        canonicalOrigin: String,
        canonicalResource: String,
        accountReference: MCPAccountReference,
        tokenHandle: MCPOAuthTokenHandle
    ) throws -> MCPAppOAuthAccountRecord? {
        try withExclusiveLock {
            let file = try loadLocked()
            guard file.generation < UInt64.max else {
                throw MCPAppOAuthError.metadataStoreIO
            }
            let replacement = MCPAppOAuthAccountRecord(
                server: server,
                canonicalOrigin: canonicalOrigin,
                canonicalResource: canonicalResource,
                accountReference: accountReference,
                tokenHandle: tokenHandle,
                active: true,
                updatedAt: Date(),
                revokedAt: nil)
            let previous = file.records.first {
                $0.key == replacement.key && $0.active
            }
            var records = file.records.filter {
                $0.key != replacement.key
            }
            records.append(replacement)
            try saveLocked(try MCPAppOAuthAccountFile(
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
        try withExclusiveLock {
            let file = try loadLocked()
            guard file.generation < UInt64.max,
                  let index = file.records.firstIndex(where: {
                      $0.server == server
                        && $0.canonicalResource == canonicalResource
                        && $0.accountReference == accountReference
                        && $0.active
                  })
            else {
                throw MCPAppOAuthError.credentialNotFound
            }
            var records = file.records
            let current = records[index]
            records[index] = MCPAppOAuthAccountRecord(
                server: current.server,
                canonicalOrigin: current.canonicalOrigin,
                canonicalResource: current.canonicalResource,
                accountReference: current.accountReference,
                tokenHandle: current.tokenHandle,
                active: false,
                updatedAt: Date(),
                revokedAt: Date())
            try saveLocked(try MCPAppOAuthAccountFile(
                generation: file.generation + 1,
                records: records))
        }
    }

    private func loadLocked() throws -> MCPAppOAuthAccountFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return try MCPAppOAuthAccountFile(
                generation: 0,
                records: [])
        }
        let descriptor = open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MCPAppOAuthError.unsafeMetadataStore
        }
        defer { _ = close(descriptor) }
        try validateDescriptor(descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes
        else {
            throw MCPAppOAuthError.unsafeMetadataStore
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw MCPAppOAuthError.metadataStoreIO
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let value = try? decoder.decode(
            MCPAppOAuthAccountFile.self,
            from: data)
        else {
            throw MCPAppOAuthError.corruptMetadataStore
        }
        return try value.validated()
    }

    private func saveLocked(
        _ value: MCPAppOAuthAccountFile
    ) throws {
        let checked = try value.validated()
        try ensureDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let descriptor = open(
                fileURL.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw MCPAppOAuthError.unsafeMetadataStore
            }
            defer { _ = close(descriptor) }
            try validateDescriptor(descriptor)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(checked)
        guard data.count <= maximumBytes else {
            throw MCPAppOAuthError.metadataStoreIO
        }

        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MCPAppOAuthError.metadataStoreIO
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove {
                _ = unlink(temporary.path)
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw MCPAppOAuthError.metadataStoreIO
        }
        try validateDescriptor(descriptor)
        do {
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw MCPAppOAuthError.metadataStoreIO
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw MCPAppOAuthError.metadataStoreIO
        }
        shouldRemove = false
        try synchronizeParentDirectory()
    }

    private func withExclusiveLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try ensureDirectory()
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MCPAppOAuthError.unsafeMetadataStore
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw MCPAppOAuthError.unsafeMetadataStore
        }
        try validateDescriptor(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw MCPAppOAuthError.metadataStoreIO
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func validateDescriptor(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              value.st_nlink == 1,
              (value.st_mode & (S_IRWXG | S_IRWXO)) == 0
        else {
            throw MCPAppOAuthError.unsafeMetadataStore
        }
    }

    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: NSNumber(value: 0o700),
                ])
        } catch {
            throw MCPAppOAuthError.metadataStoreIO
        }
        var value = stat()
        guard lstat(directory.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == geteuid(),
              (value.st_mode & (S_IRWXG | S_IRWXO)) == 0
        else {
            throw MCPAppOAuthError.unsafeMetadataStore
        }
    }

    private func synchronizeParentDirectory() throws {
        let descriptor = open(
            fileURL.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MCPAppOAuthError.metadataStoreIO
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MCPAppOAuthError.metadataStoreIO
        }
    }
}

/// GUI host OAuth lifecycle. Login is explicit, uses a one-shot exact
/// loopback listener and does not create an MCP connection. The returned
/// handle is validated against an exact provider before account metadata is
/// published. Logout removes/revokes the Keychain token first, tombstones the
/// mapping second, and then asks every session owner to drain the authority.
actor MCPAppOAuthCoordinator {
    typealias AuthorizationPresenter = @Sendable (
        MCPAppOAuthAuthorizationPresentation
    ) async -> Bool
    typealias RevocationHandler = @Sendable (
        MCPServerReference,
        MCPAccountReference
    ) async throws -> Void

    private let secretStore: MCPKeychainSecretStore
    private let vault: MCPOAuthCredentialVault
    private let coordinator: MCPOAuthCoordinator
    private let accounts: MCPAppOAuthAccountStore
    private var revocationHandler: RevocationHandler?
    /// Inactive credentials acquired for one exact, not-yet-published
    /// prepared revision. They are usable only by that preparation's isolated
    /// Test and are either activated by its catalog CAS receipt or removed.
    private var stagedLogins:
        [String: MCPOAuthTokenHandle] = [:]

    init(
        secretStore: MCPKeychainSecretStore,
        accounts: MCPAppOAuthAccountStore,
        revocationHandler: RevocationHandler? = nil
    ) {
        self.secretStore = secretStore
        self.accounts = accounts
        self.revocationHandler = revocationHandler
        vault = MCPOAuthCredentialVault(secretStore: secretStore)
        coordinator = MCPOAuthCoordinator(
            httpClient: MCPURLSessionOAuthHTTPClient(),
            vault: vault,
            secretStore: secretStore)
    }

    func setRevocationHandler(
        _ handler: RevocationHandler?
    ) {
        revocationHandler = handler
    }

    func summaries() async throws -> [MCPAppOAuthAccountSummary] {
        try await accounts.summaries()
    }

    func login(
        definition: MCPServerDefinition,
        allowDynamicClientRegistration: Bool,
        present: AuthorizationPresenter
    ) async throws -> MCPAppOAuthAccountSummary {
        guard case .streamableHTTP(let http) =
                definition.configuration.transport else {
            throw MCPAppOAuthError.unsupportedTransport
        }
        guard let oauth = http.oauth, oauth.enabled else {
            throw MCPAppOAuthError.oauthNotConfigured
        }
        guard let account = oauth.accountReference else {
            throw MCPAppOAuthError.accountNotConfigured
        }
        guard let endpoint = URL(string: http.endpoint),
              let resource = URL(
                string: oauth.canonicalResource) else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }

        let listener = try MCPOAuthLoopbackCallbackListener.bind(
            host: .ipv4,
            port: 0,
            callbackPath: "/callback")
        defer { listener.close() }
        let discovery = try await coordinator.discover(
            endpoint: endpoint,
            configuredResource: resource)
        let redirectPort = listener.redirectURI.port ?? 0
        let attempt = try await coordinator.beginLogin(
            serverID: definition.reference.serverID,
            accountReference: account,
            configuration: oauth,
            discovery: discovery,
            redirectPolicy: .ephemeralIPv4(port: redirectPort),
            loginPolicy: MCPOAuthLoginPolicy(
                allowDynamicClientRegistration:
                    allowDynamicClientRegistration))
        let presentation = MCPAppOAuthAuthorizationPresentation(
            server: definition.reference,
            displayName: definition.configuration.displayName,
            canonicalResource: oauth.canonicalResource,
            authorizationOrigin:
                try Self.canonicalHTTPSOrigin(
                    discovery.authorizationServerMetadata.issuer),
            accountReference: account,
            scopes: Array(attempt.requestedScopes).sorted(),
            usesDynamicClientRegistration:
                oauth.clientID == nil
                    && allowDynamicClientRegistration,
            authorizationURL: attempt.authorizationURL)
        guard await present(presentation) else {
            await coordinator.cancelLogin(attempt)
            throw MCPAppOAuthError.loginCancelled
        }
        let opened = await MainActor.run {
            NSWorkspace.shared.open(attempt.authorizationURL)
        }
        guard opened else {
            await coordinator.cancelLogin(attempt)
            throw MCPAppOAuthError.browserLaunchDenied
        }

        let callback = try await listener.waitForCallback()
        let token = try await coordinator.completeLogin(
            attempt,
            callbackURL: callback)
        do {
            let generation = MCPConnectionGeneration.new()
            let provider = MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: token,
                connectionGeneration: generation)
            let header = try await provider.authorizationHeader(
                for: resource,
                connectionGeneration: generation)
            guard header?.hasPrefix("Bearer ") == true else {
                throw MCPAppOAuthError.exactAuthorityMismatch
            }
            await provider.retire()

            let previous = try await accounts.publish(
                server: definition.reference,
                canonicalOrigin: http.canonicalOrigin,
                canonicalResource: oauth.canonicalResource,
                accountReference: account,
                tokenHandle: token)
            if let previous,
               previous.tokenHandle.secretReference
                    != token.secretReference {
                try? await vault.removeToken(
                    previous.tokenHandle)
            }
            guard let record = try await accounts.activeRecord(
                server: definition.reference,
                canonicalResource: oauth.canonicalResource,
                accountReference: account)
            else {
                throw MCPAppOAuthError.metadataStoreIO
            }
            return record.summary
        } catch {
            try? await vault.removeToken(token)
            throw error
        }
    }

    /// Acquires an inactive token for the exact revision predicted by
    /// `prepared`. This never publishes account metadata and never makes the
    /// token available to a normal session connection.
    func loginStaged(
        prepared: MCPPreparedServerConfiguration,
        allowDynamicClientRegistration: Bool,
        present: AuthorizationPresenter
    ) async throws {
        let definition = prepared.definition
        guard definition.reference
                == prepared.expectedServerReference,
              case .streamableHTTP(let http) =
                definition.configuration.transport else {
            throw MCPAppOAuthError.unsupportedTransport
        }
        guard let oauth = http.oauth, oauth.enabled else {
            throw MCPAppOAuthError.oauthNotConfigured
        }
        guard let account = oauth.accountReference else {
            throw MCPAppOAuthError.accountNotConfigured
        }
        guard let endpoint = URL(string: http.endpoint),
              let resource = URL(
                string: oauth.canonicalResource) else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }

        if let prior = stagedLogins.removeValue(
            forKey: prepared.preparationFingerprint)
        {
            try? await vault.discardStagedToken(prior)
        }

        let listener = try MCPOAuthLoopbackCallbackListener.bind(
            host: .ipv4,
            port: 0,
            callbackPath: "/callback")
        defer { listener.close() }
        let discovery = try await coordinator.discover(
            endpoint: endpoint,
            configuredResource: resource)
        let redirectPort = listener.redirectURI.port ?? 0
        let attempt = try await coordinator.beginLogin(
            serverID: definition.reference.serverID,
            accountReference: account,
            configuration: oauth,
            discovery: discovery,
            redirectPolicy: .ephemeralIPv4(
                port: redirectPort),
            loginPolicy: MCPOAuthLoginPolicy(
                allowDynamicClientRegistration:
                    allowDynamicClientRegistration),
            stagingBinding:
                MCPOAuthStagingBinding(prepared: prepared))
        let presentation =
            MCPAppOAuthAuthorizationPresentation(
                server: definition.reference,
                displayName:
                    definition.configuration.displayName,
                canonicalResource:
                    oauth.canonicalResource,
                authorizationOrigin:
                    try Self.canonicalHTTPSOrigin(
                        discovery
                            .authorizationServerMetadata
                            .issuer),
                accountReference: account,
                scopes:
                    Array(attempt.requestedScopes)
                        .sorted(),
                usesDynamicClientRegistration:
                    oauth.clientID == nil
                        && allowDynamicClientRegistration,
                authorizationURL:
                    attempt.authorizationURL)
        guard await present(presentation) else {
            await coordinator.cancelLogin(attempt)
            throw MCPAppOAuthError.loginCancelled
        }
        let opened = await MainActor.run {
            NSWorkspace.shared.open(
                attempt.authorizationURL)
        }
        guard opened else {
            await coordinator.cancelLogin(attempt)
            throw MCPAppOAuthError.browserLaunchDenied
        }

        let callback = try await listener.waitForCallback()
        let token = try await coordinator.completeLogin(
            attempt,
            callbackURL: callback)
        do {
            let generation =
                MCPConnectionGeneration.new()
            let provider =
                MCPOAuthAuthorizationProvider(
                    vault: vault,
                    handle: token,
                    connectionGeneration: generation,
                    expectedServerReference:
                        prepared.expectedServerReference,
                    stagedTestPreparationFingerprint:
                        prepared.preparationFingerprint)
            let header =
                try await provider.authorizationHeader(
                    for: resource,
                    connectionGeneration: generation)
            guard header?.hasPrefix("Bearer ") == true else {
                throw MCPAppOAuthError
                    .exactAuthorityMismatch
            }
            await provider.retire()
            stagedLogins[
                prepared.preparationFingerprint] = token
        } catch {
            try? await vault.discardStagedToken(token)
            throw error
        }
    }

    /// Activates and publishes the token only after the same preparation's
    /// Test proof and exact post-CAS catalog receipt are available.
    func activateStagedLogin(
        prepared: MCPPreparedServerConfiguration,
        proof: MCPPreparedConfigurationTestProof,
        publishedCatalog: MCPServerCatalog
    ) async throws -> MCPAppOAuthAccountSummary {
        guard let token = stagedLogins[
            prepared.preparationFingerprint] else {
            throw MCPAppOAuthError.credentialNotFound
        }
        let definition = prepared.definition
        guard case .streamableHTTP(let http) =
                definition.configuration.transport,
              let oauth = http.oauth,
              oauth.enabled,
              let account = oauth.accountReference else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }
        let active = try await vault.activateStagedToken(
            token,
            prepared: prepared,
            proof: proof,
            publishedCatalog: publishedCatalog)
        do {
            let previous = try await accounts.publish(
                server: prepared.expectedServerReference,
                canonicalOrigin: http.canonicalOrigin,
                canonicalResource:
                    oauth.canonicalResource,
                accountReference: account,
                tokenHandle: active)
            stagedLogins.removeValue(
                forKey: prepared.preparationFingerprint)
            if let previous,
               previous.tokenHandle.secretReference
                    != active.secretReference {
                try? await vault.removeToken(
                    previous.tokenHandle)
            }
            guard let record =
                    try await accounts.activeRecord(
                        server:
                            prepared.expectedServerReference,
                        canonicalResource:
                            oauth.canonicalResource,
                        accountReference: account) else {
                throw MCPAppOAuthError.metadataStoreIO
            }
            return record.summary
        } catch {
            stagedLogins.removeValue(
                forKey: prepared.preparationFingerprint)
            try? await vault.removeToken(active)
            throw error
        }
    }

    func discardStagedLogin(
        prepared: MCPPreparedServerConfiguration
    ) async {
        guard let token = stagedLogins.removeValue(
            forKey: prepared.preparationFingerprint)
        else { return }
        try? await vault.discardStagedToken(token)
    }

    func logout(
        definition: MCPServerDefinition
    ) async throws {
        guard case .streamableHTTP(let http) =
                definition.configuration.transport else {
            throw MCPAppOAuthError.unsupportedTransport
        }
        guard let oauth = http.oauth, oauth.enabled else {
            throw MCPAppOAuthError.oauthNotConfigured
        }
        guard let account = oauth.accountReference else {
            throw MCPAppOAuthError.accountNotConfigured
        }
        guard let record = try await accounts.activeRecord(
            server: definition.reference,
            canonicalResource: oauth.canonicalResource,
            accountReference: account)
        else {
            throw MCPAppOAuthError.credentialNotFound
        }

        var discovery: MCPOAuthDiscoveryResult?
        if let endpoint = URL(string: http.endpoint),
           let resource = URL(string: oauth.canonicalResource) {
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
            canonicalResource: oauth.canonicalResource,
            accountReference: account)
        if let revocationHandler {
            try await revocationHandler(
                definition.reference,
                account)
        }
    }

    nonisolated func providerBuilder()
        -> MCPProductionOAuthProviderBuilder
    {
        return { [self] definition, identity, generation in
            try await authorizationProvider(
                definition: definition,
                identity: identity,
                generation: generation)
        }
    }

    private func authorizationProvider(
        definition: MCPServerDefinition,
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) async throws -> any MCPHTTPAuthorizationProviding {
        guard definition.reference == identity.server else {
            throw MCPAppOAuthError.exactRevisionMismatch
        }
        guard case .streamableHTTP(let http) =
                definition.configuration.transport,
              let oauth = http.oauth,
              oauth.enabled,
              let account = oauth.accountReference,
              identity.oauthAccountReference == account
        else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }

        let exactStaged = stagedLogins.filter {
            _, handle in
            handle.stagingBinding?.plannedReference
                == definition.reference
                && handle.authority.serverID
                    == definition.reference.serverID
                && handle.authority.canonicalOrigin
                    == http.canonicalOrigin
                && handle.authority.canonicalResource
                    == oauth.canonicalResource
                && handle.authority.accountReference
                    == account
        }
        guard exactStaged.count <= 1 else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }
        if let (preparationFingerprint, handle) =
                exactStaged.first {
            guard try await secretStore.contains(
                    handle.secretReference) else {
                throw MCPAppOAuthError.credentialNotFound
            }
            return MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: handle,
                connectionGeneration: generation,
                expectedServerReference:
                    definition.reference,
                stagedTestPreparationFingerprint:
                    preparationFingerprint)
        }

        guard let record = try await accounts.activeRecord(
            server: definition.reference,
            canonicalResource: oauth.canonicalResource,
            accountReference: account)
        else {
            throw MCPAppOAuthError.credentialNotFound
        }
        guard record.canonicalOrigin == http.canonicalOrigin,
              record.canonicalResource
                == oauth.canonicalResource,
              record.tokenHandle.authority.serverID
                == definition.reference.serverID,
              record.tokenHandle.authority.canonicalOrigin
                == http.canonicalOrigin,
              record.tokenHandle.authority.canonicalResource
                == oauth.canonicalResource,
              record.tokenHandle.authority.accountReference
                == account,
              try await secretStore.contains(
                record.tokenHandle.secretReference)
        else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }
        return MCPOAuthAuthorizationProvider(
            vault: vault,
            handle: record.tokenHandle,
            connectionGeneration: generation,
            expectedServerReference:
                definition.reference)
    }

    private nonisolated static func canonicalHTTPSOrigin(
        _ url: URL
    ) throws -> String {
        guard let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw MCPAppOAuthError.exactAuthorityMismatch
        }
        let port = components.port
        return port == nil || port == 443
            ? "https://\(host)"
            : "https://\(host):\(port!)"
    }
}
#endif
