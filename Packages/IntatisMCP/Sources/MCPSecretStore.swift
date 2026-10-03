#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore

#if canImport(Security)
import Security
#endif

// MARK: - Common contract

/// Dedicated secret backend for MCP credentials.
///
/// Implementations persist secret bytes only in a platform security service or
/// in an authenticated encrypted container. Catalogs, EventLog payloads and
/// diagnostic values retain only `MCPSecretReference`.
public protocol MCPSecretStore: MCPImportSecretSink, Sendable {
    var storageClass: MCPSecretStorageClass { get }

    func store(
        _ secret: Data,
        sourceBindingFingerprint: String?
    ) async throws -> MCPSecretReference

    func resolve(_ reference: MCPSecretReference) async throws -> Data

    func replace(
        _ secret: Data,
        for reference: MCPSecretReference
    ) async throws

    func remove(_ reference: MCPSecretReference) async throws

    func contains(_ reference: MCPSecretReference) async throws -> Bool
}

public extension MCPSecretStore {
    func storeImportedSecret(
        _ secret: Data,
        descriptor: MCPImportedSecretDescriptor
    ) async throws -> MCPSecretReference {
        try await store(
            secret,
            sourceBindingFingerprint: descriptor.sourceFingerprint)
    }
}

public enum MCPSecretStoreError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case locked
    case notInitialized
    case alreadyInitialized
    case invalidReference
    case invalidPassphrase
    case notFound
    case valueTooLarge
    case unsafeStore
    case corruptStore
    case authenticationFailed
    case revisionOverflow
    case operationFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The required secure credential backend is unavailable."
        case .locked:
            return "The encrypted MCP credential store is locked."
        case .notInitialized:
            return "The encrypted MCP credential store is not initialized."
        case .alreadyInitialized:
            return "The encrypted MCP credential store is already initialized."
        case .invalidReference:
            return "The MCP credential reference is invalid for this store."
        case .invalidPassphrase:
            return "The MCP credential-store passphrase is invalid."
        case .notFound:
            return "The requested MCP credential does not exist."
        case .valueTooLarge:
            return "The MCP credential exceeds the secure-store size limit."
        case .unsafeStore:
            return "The MCP credential store does not have a safe owner-only identity."
        case .corruptStore:
            return "The MCP credential store is damaged or has an unsupported schema."
        case .authenticationFailed:
            return "The MCP credential store could not be authenticated."
        case .revisionOverflow:
            return "The MCP credential-store revision cannot advance."
        case .operationFailed:
            return "The secure credential operation failed."
        }
    }
}

public enum MCPSecretStoreLimits {
    public static let maximumSecretBytes = 1024 * 1024
    public static let maximumStoreBytes = 32 * 1024 * 1024
    public static let productionPBKDF2Iterations = 210_000
    public static let minimumPassphraseBytes = 16
    public static let maximumPassphraseBytes = 4 * 1024
}

private enum MCPSecretStoreValidation {
    static func validateSecret(_ secret: Data) throws {
        guard !secret.isEmpty,
              secret.count <= MCPSecretStoreLimits.maximumSecretBytes else {
            throw MCPSecretStoreError.valueTooLarge
        }
    }

    static func validate(
        _ reference: MCPSecretReference,
        storageClass: MCPSecretStorageClass
    ) throws {
        guard reference.storageClass == storageClass else {
            throw MCPSecretStoreError.invalidReference
        }
    }

    static func identifier() throws -> String {
        // The colon also ensures the opaque identifier is not mistaken for a
        // long secret by the conservative catalog validator.
        try MCPSecretReference(
            storageClass: .hostOwned,
            identifier: "mcp:\(UUID().uuidString.lowercased())"
        ).identifier
    }
}

// MARK: - macOS Keychain

private struct MCPKeychainPayload: Codable {
    let schemaVersion: Int
    let secret: Data
    let sourceBindingFingerprint: String?
}

/// Real Security.framework generic-password storage for macOS app targets.
///
/// The account is the opaque MCP reference and the value is a small encoded
/// envelope containing the source-binding fingerprint plus the secret. No
/// plaintext-file implementation is used when Keychain is unavailable.
public actor MCPKeychainSecretStore: MCPSecretStore {
    public nonisolated let storageClass = MCPSecretStorageClass.macOSKeychain

    private let service: String
    private let accessGroup: String?
    private let useDataProtectionKeychain: Bool

    public init(
        service: String = IntatisHostApplication.identity
            .keychainService("mcp.credentials"),
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        useDataProtectionKeychain = true
    }

    /// Unsigned SwiftPM test processes do not have an application-identifier
    /// entitlement and therefore cannot access the macOS data-protection
    /// Keychain. Production callers cannot select the legacy Keychain; this
    /// internal initializer exists solely so integration tests can exercise
    /// Security.framework CRUD while separately asserting the production query.
    init(
        service: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func store(
        _ secret: Data,
        sourceBindingFingerprint: String? = nil
    ) async throws -> MCPSecretReference {
        try MCPSecretStoreValidation.validateSecret(secret)
        let identifier = try MCPSecretStoreValidation.identifier()
        let reference = try MCPSecretReference(
            storageClass: storageClass,
            identifier: identifier,
            sourceBindingFingerprint: sourceBindingFingerprint)
        let payload = try encodePayload(
            secret: secret,
            sourceBindingFingerprint: sourceBindingFingerprint)
        try add(payload, account: identifier)
        return reference
    }

    public func resolve(_ reference: MCPSecretReference) async throws -> Data {
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        let payload = try decodePayload(try copy(account: reference.identifier))
        guard payload.sourceBindingFingerprint
                == reference.sourceBindingFingerprint else {
            throw MCPSecretStoreError.invalidReference
        }
        return payload.secret
    }

    public func replace(
        _ secret: Data,
        for reference: MCPSecretReference
    ) async throws {
        try MCPSecretStoreValidation.validateSecret(secret)
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        let existing = try decodePayload(try copy(account: reference.identifier))
        guard existing.sourceBindingFingerprint
                == reference.sourceBindingFingerprint else {
            throw MCPSecretStoreError.invalidReference
        }
        let payload = try encodePayload(
            secret: secret,
            sourceBindingFingerprint: reference.sourceBindingFingerprint)
        try update(payload, account: reference.identifier)
    }

    public func remove(_ reference: MCPSecretReference) async throws {
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        let payload = try decodePayload(
            try copy(account: reference.identifier))
        guard payload.sourceBindingFingerprint
                == reference.sourceBindingFingerprint else {
            throw MCPSecretStoreError.invalidReference
        }
        try delete(account: reference.identifier)
    }

    public func contains(_ reference: MCPSecretReference) async throws -> Bool {
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        do {
            let payload = try decodePayload(try copy(account: reference.identifier))
            return payload.sourceBindingFingerprint
                == reference.sourceBindingFingerprint
        } catch MCPSecretStoreError.notFound {
            return false
        }
    }

    private func encodePayload(
        secret: Data,
        sourceBindingFingerprint: String?
    ) throws -> Data {
        try JSONEncoder().encode(MCPKeychainPayload(
            schemaVersion: 1,
            secret: secret,
            sourceBindingFingerprint: sourceBindingFingerprint))
    }

    private func decodePayload(_ data: Data) throws -> MCPKeychainPayload {
        guard data.count <= MCPSecretStoreLimits.maximumSecretBytes + 4_096,
              let payload = try? JSONDecoder().decode(
                MCPKeychainPayload.self,
                from: data),
              payload.schemaVersion == 1,
              !payload.secret.isEmpty,
              payload.secret.count <= MCPSecretStoreLimits.maximumSecretBytes
        else {
            throw MCPSecretStoreError.corruptStore
        }
        return payload
    }

    #if canImport(Security)
    private func baseQuery(account: String) -> [CFString: Any] {
        Self.makeBaseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain)
    }

    static func makeBaseQuery(
        service: String,
        account: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    static func makeAddQuery(
        service: String,
        account: String,
        accessGroup: String?,
        useDataProtectionKeychain: Bool,
        data: Data
    ) -> [CFString: Any] {
        var query = makeBaseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecValueData] = data
        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    private func add(_ data: Data, account: String) throws {
        let query = Self.makeAddQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            useDataProtectionKeychain: useDataProtectionKeychain,
            data: data)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
    }

    private func copy(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
        guard let data = item as? Data else {
            throw MCPSecretStoreError.corruptStore
        }
        return data
    }

    private func update(_ data: Data, account: String) throws {
        let status = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData: data] as CFDictionary)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess else {
            throw mapStatus(status)
        }
    }

    private func mapStatus(_ status: OSStatus) -> MCPSecretStoreError {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecNotAvailable,
             errSecMissingEntitlement:
            return .unavailable
        default:
            return .operationFailed
        }
    }
    #else
    private func add(_: Data, account _: String) throws {
        throw MCPSecretStoreError.unavailable
    }

    private func copy(account _: String) throws -> Data {
        throw MCPSecretStoreError.unavailable
    }

    private func update(_: Data, account _: String) throws {
        throw MCPSecretStoreError.unavailable
    }

    private func delete(account _: String) throws {
        throw MCPSecretStoreError.unavailable
    }
    #endif
}

// MARK: - CLI authenticated encrypted store

private struct MCPCLISecretRecord: Codable, Equatable {
    let secret: Data
    let sourceBindingFingerprint: String?
}

private struct MCPCLISecretPayload: Codable, Equatable {
    var records: [String: MCPCLISecretRecord]
}

private struct MCPCLISecretEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let generation: UInt64
    let kdf: String
    let iterations: Int
    let salt: Data
    let ciphertext: Data
}

/// Cross-platform CLI credential store using PBKDF2-HMAC-SHA256 and AES-GCM.
///
/// The passphrase-derived key is retained only while the actor is unlocked.
/// The file contains a non-secret salt and authenticated ciphertext, is guarded
/// by an owner-only cross-process lock, and is written using durable atomic
/// replacement. There is no plaintext key file and no plaintext downgrade.
public actor MCPCLIEncryptedSecretStore: MCPSecretStore {
    public nonisolated let storageClass =
        MCPSecretStorageClass.encryptedCLIStore

    private static let schemaVersion = 1
    private static let kdfName = "pbkdf2-hmac-sha256"
    private static let authenticatedContext =
        Data("\(IntatisHostApplication.identity.name) MCP CLI credential store v1".utf8)

    public nonisolated let fileURL: URL
    public nonisolated let lockURL: URL

    private let minimumIterations: Int
    private let defaultIterations: Int
    private var unlockedKey: SymmetricKey?
    private var unlockedSalt: Data?
    private var unlockedIterations: Int?

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        self.lockURL = fileURL
            .appendingPathExtension("lock")
            .standardizedFileURL
        self.minimumIterations =
            MCPSecretStoreLimits.productionPBKDF2Iterations
        self.defaultIterations =
            MCPSecretStoreLimits.productionPBKDF2Iterations
    }

    /// Test-only constructor keeps production callers from weakening the KDF.
    init(
        fileURL: URL,
        minimumIterations: Int,
        defaultIterations: Int
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.lockURL = fileURL
            .appendingPathExtension("lock")
            .standardizedFileURL
        self.minimumIterations = minimumIterations
        self.defaultIterations = defaultIterations
    }

    public var isUnlocked: Bool { unlockedKey != nil }

    public func initialize(passphrase: Data) throws {
        try validatePassphrase(passphrase)
        try validateStoreParent()
        let iterations = defaultIterations
        let salt = randomBytes(count: 32)
        let key = try Self.deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: iterations)

        do {
            try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
                if try DurableOwnerOnlyFile.read(from: fileURL) != nil {
                    throw MCPSecretStoreError.alreadyInitialized
                }
                let payload = MCPCLISecretPayload(records: [:])
                let envelope = try seal(
                    payload,
                    generation: 0,
                    salt: salt,
                    iterations: iterations,
                    key: key)
                try write(envelope)
            }
        } catch {
            throw mapFileError(error)
        }

        unlockedKey = key
        unlockedSalt = salt
        unlockedIterations = iterations
    }

    public func unlock(passphrase: Data) throws {
        try validatePassphrase(passphrase)
        let envelope = try readEnvelope()
        let key = try Self.deriveKey(
            passphrase: passphrase,
            salt: envelope.salt,
            iterations: envelope.iterations)
        do {
            _ = try open(envelope, key: key)
        } catch {
            throw MCPSecretStoreError.authenticationFailed
        }
        unlockedKey = key
        unlockedSalt = envelope.salt
        unlockedIterations = envelope.iterations
    }

    public func lock() {
        unlockedKey = nil
        unlockedSalt = nil
        unlockedIterations = nil
    }

    public func store(
        _ secret: Data,
        sourceBindingFingerprint: String? = nil
    ) async throws -> MCPSecretReference {
        try MCPSecretStoreValidation.validateSecret(secret)
        let identifier = try MCPSecretStoreValidation.identifier()
        let reference = try MCPSecretReference(
            storageClass: storageClass,
            identifier: identifier,
            sourceBindingFingerprint: sourceBindingFingerprint)
        try mutate { payload in
            guard payload.records[identifier] == nil else {
                throw MCPSecretStoreError.operationFailed
            }
            payload.records[identifier] = MCPCLISecretRecord(
                secret: secret,
                sourceBindingFingerprint: sourceBindingFingerprint)
        }
        return reference
    }

    public func resolve(_ reference: MCPSecretReference) async throws -> Data {
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        let payload = try currentPayload()
        guard let record = payload.records[reference.identifier] else {
            throw MCPSecretStoreError.notFound
        }
        guard record.sourceBindingFingerprint
                == reference.sourceBindingFingerprint else {
            throw MCPSecretStoreError.invalidReference
        }
        return record.secret
    }

    public func replace(
        _ secret: Data,
        for reference: MCPSecretReference
    ) async throws {
        try MCPSecretStoreValidation.validateSecret(secret)
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        try mutate { payload in
            guard let existing = payload.records[reference.identifier] else {
                throw MCPSecretStoreError.notFound
            }
            guard existing.sourceBindingFingerprint
                    == reference.sourceBindingFingerprint else {
                throw MCPSecretStoreError.invalidReference
            }
            payload.records[reference.identifier] = MCPCLISecretRecord(
                secret: secret,
                sourceBindingFingerprint: reference.sourceBindingFingerprint)
        }
    }

    public func remove(_ reference: MCPSecretReference) async throws {
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        try mutate { payload in
            guard let existing = payload.records[reference.identifier] else {
                throw MCPSecretStoreError.notFound
            }
            guard existing.sourceBindingFingerprint
                    == reference.sourceBindingFingerprint else {
                throw MCPSecretStoreError.invalidReference
            }
            payload.records.removeValue(forKey: reference.identifier)
        }
    }

    public func contains(_ reference: MCPSecretReference) async throws -> Bool {
        try MCPSecretStoreValidation.validate(
            reference,
            storageClass: storageClass)
        guard let record = try currentPayload()
            .records[reference.identifier] else {
            return false
        }
        return record.sourceBindingFingerprint
            == reference.sourceBindingFingerprint
    }

    public func rotatePassphrase(
        currentPassphrase: Data,
        newPassphrase: Data
    ) throws {
        try validatePassphrase(currentPassphrase)
        try validatePassphrase(newPassphrase)
        try validateStoreParent()

        var replacementKey: SymmetricKey?
        var replacementSalt: Data?
        do {
            try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
                let envelope = try readEnvelopeUnlocked()
                let oldKey = try Self.deriveKey(
                    passphrase: currentPassphrase,
                    salt: envelope.salt,
                    iterations: envelope.iterations)
                let payload: MCPCLISecretPayload
                do {
                    payload = try open(envelope, key: oldKey)
                } catch {
                    throw MCPSecretStoreError.authenticationFailed
                }
                guard envelope.generation < UInt64.max else {
                    throw MCPSecretStoreError.revisionOverflow
                }
                let salt = randomBytes(count: 32)
                let key = try Self.deriveKey(
                    passphrase: newPassphrase,
                    salt: salt,
                    iterations: defaultIterations)
                let replacement = try seal(
                    payload,
                    generation: envelope.generation + 1,
                    salt: salt,
                    iterations: defaultIterations,
                    key: key)
                try write(replacement)
                replacementKey = key
                replacementSalt = salt
            }
        } catch {
            throw mapFileError(error)
        }
        unlockedKey = replacementKey
        unlockedSalt = replacementSalt
        unlockedIterations = defaultIterations
    }

    private func currentPayload() throws -> MCPCLISecretPayload {
        guard let key = unlockedKey,
              let expectedSalt = unlockedSalt,
              let expectedIterations = unlockedIterations else {
            throw MCPSecretStoreError.locked
        }
        let envelope = try readEnvelope()
        guard envelope.salt == expectedSalt,
              envelope.iterations == expectedIterations else {
            lock()
            throw MCPSecretStoreError.authenticationFailed
        }
        do {
            return try open(envelope, key: key)
        } catch {
            lock()
            throw MCPSecretStoreError.authenticationFailed
        }
    }

    private func mutate(
        _ mutation: (inout MCPCLISecretPayload) throws -> Void
    ) throws {
        guard let key = unlockedKey,
              let expectedSalt = unlockedSalt,
              let expectedIterations = unlockedIterations else {
            throw MCPSecretStoreError.locked
        }
        try validateStoreParent()

        do {
            try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
                let envelope = try readEnvelopeUnlocked()
                guard envelope.salt == expectedSalt,
                      envelope.iterations == expectedIterations else {
                    throw MCPSecretStoreError.authenticationFailed
                }
                var payload: MCPCLISecretPayload
                do {
                    payload = try open(envelope, key: key)
                } catch {
                    throw MCPSecretStoreError.authenticationFailed
                }
                try mutation(&payload)
                guard envelope.generation < UInt64.max else {
                    throw MCPSecretStoreError.revisionOverflow
                }
                let replacement = try seal(
                    payload,
                    generation: envelope.generation + 1,
                    salt: envelope.salt,
                    iterations: envelope.iterations,
                    key: key)
                try write(replacement)
            }
        } catch {
            throw mapFileError(error)
        }
    }

    private func validatePassphrase(_ passphrase: Data) throws {
        guard passphrase.count
                >= MCPSecretStoreLimits.minimumPassphraseBytes,
              passphrase.count
                <= MCPSecretStoreLimits.maximumPassphraseBytes else {
            throw MCPSecretStoreError.invalidPassphrase
        }
    }

    private func validateStoreParent() throws {
        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true)
            _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: parent)
        } catch {
            throw MCPSecretStoreError.unsafeStore
        }
    }

    private func readEnvelope() throws -> MCPCLISecretEnvelope {
        try validateStoreParent()
        do {
            return try readEnvelopeUnlocked()
        } catch {
            throw mapFileError(error)
        }
    }

    private func readEnvelopeUnlocked() throws -> MCPCLISecretEnvelope {
        guard let data = try DurableOwnerOnlyFile.read(from: fileURL) else {
            throw MCPSecretStoreError.notInitialized
        }
        guard data.count <= MCPSecretStoreLimits.maximumStoreBytes,
              let envelope = try? JSONDecoder().decode(
                MCPCLISecretEnvelope.self,
                from: data),
              envelope.schemaVersion == Self.schemaVersion,
              envelope.kdf == Self.kdfName,
              envelope.iterations >= minimumIterations,
              envelope.salt.count == 32,
              !envelope.ciphertext.isEmpty else {
            throw MCPSecretStoreError.corruptStore
        }
        return envelope
    }

    private func write(_ envelope: MCPCLISecretEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= MCPSecretStoreLimits.maximumStoreBytes else {
            throw MCPSecretStoreError.valueTooLarge
        }
        try DurableOwnerOnlyFile.writeAtomically(
            data,
            to: fileURL,
            temporaryPrefix: ".mcp-secret-")
    }

    private func seal(
        _ payload: MCPCLISecretPayload,
        generation: UInt64,
        salt: Data,
        iterations: Int,
        key: SymmetricKey
    ) throws -> MCPCLISecretEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(payload)
        guard plaintext.count <= MCPSecretStoreLimits.maximumStoreBytes else {
            throw MCPSecretStoreError.valueTooLarge
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Self.authenticatedContext)
        guard let combined = sealed.combined else {
            throw MCPSecretStoreError.operationFailed
        }
        return MCPCLISecretEnvelope(
            schemaVersion: Self.schemaVersion,
            generation: generation,
            kdf: Self.kdfName,
            iterations: iterations,
            salt: salt,
            ciphertext: combined)
    }

    private func open(
        _ envelope: MCPCLISecretEnvelope,
        key: SymmetricKey
    ) throws -> MCPCLISecretPayload {
        let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
        let plaintext = try AES.GCM.open(
            box,
            using: key,
            authenticating: Self.authenticatedContext)
        guard plaintext.count <= MCPSecretStoreLimits.maximumStoreBytes,
              let payload = try? JSONDecoder().decode(
                MCPCLISecretPayload.self,
                from: plaintext),
              payload.records.count <= 100_000,
              payload.records.allSatisfy({
                  !$0.key.isEmpty
                    && $0.value.secret.count
                        <= MCPSecretStoreLimits.maximumSecretBytes
                    && !$0.value.secret.isEmpty
              }) else {
            throw MCPSecretStoreError.corruptStore
        }
        return payload
    }

    private func mapFileError(_ error: Error) -> Error {
        if let error = error as? MCPSecretStoreError {
            return error
        }
        if let error = error as? DurableOwnerOnlyFileError {
            switch error {
            case .unsafeFile:
                return MCPSecretStoreError.unsafeStore
            case .commitUncertain:
                return MCPSecretStoreError.operationFailed
            default:
                return MCPSecretStoreError.operationFailed
            }
        }
        return error
    }

    private func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func deriveKey(
        passphrase: Data,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        guard iterations > 0, salt.count == 32 else {
            throw MCPSecretStoreError.corruptStore
        }
        let passwordKey = SymmetricKey(data: passphrase)
        var block = UInt32(1).bigEndian
        var firstInput = salt
        withUnsafeBytes(of: &block) {
            firstInput.append(contentsOf: $0)
        }
        var u = Data(HMAC<SHA256>.authenticationCode(
            for: firstInput,
            using: passwordKey))
        var result = u
        if iterations > 1 {
            for _ in 2...iterations {
                u = Data(HMAC<SHA256>.authenticationCode(
                    for: u,
                    using: passwordKey))
                for index in result.indices {
                    result[index] ^= u[index]
                }
            }
        }
        return SymmetricKey(data: result)
    }
}
