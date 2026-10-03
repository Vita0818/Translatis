#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders

/// Resolves provider secrets from configuration files, environment variables,
/// and explicit secret files. Legacy `.keychain` refs are treated as config refs
/// so iOS chat requests never call the Keychain APIs.
public final class ConfigSecretResolver: SecretResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init() {}

    public func secret(for ref: KeychainRef) async throws -> String {
        let cacheKey = Self.cacheKey(for: ref)
        if let cached = cachedSecret(for: cacheKey) { return cached }

        let secret: String
        switch ref.source {
        case .keychain:
            let providerID = Self.authProviderID(from: ref.account) ?? ref.account
            secret = try Self.readAuthFileSecret(providerID: providerID)
        case .environment:
            guard let value = ProcessInfo.processInfo.environment[ref.account],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntatisError.notFound("environment secret '\(ref.account)'")
            }
            secret = value
        case .file:
            secret = try Self.readSecretFile(path: ref.account)
        case .authFile:
            secret = try Self.readAuthFileSecret(providerID: ref.account)
        case .providerConfig:
            secret = try Self.readProviderConfigSecret(providerID: ref.account, path: ref.service)
        }
        cache(secret, for: ref)
        return secret
    }

    public func cache(_ secret: String, for ref: KeychainRef) {
        store(secret, for: Self.cacheKey(for: ref))
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func cachedSecret(for cacheKey: String) -> String? {
        lock.lock()
        let cached = cache[cacheKey]
        lock.unlock()
        return cached
    }

    private func store(_ secret: String, for cacheKey: String) {
        lock.lock()
        cache[cacheKey] = secret
        lock.unlock()
    }

    public static func exists(_ ref: KeychainRef) -> Bool {
        switch ref.source {
        case .keychain:
            let providerID = Self.authProviderID(from: ref.account) ?? ref.account
            return authFileContainsSecret(providerID: providerID)
        case .environment:
            return !(ProcessInfo.processInfo.environment[ref.account] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            return FileManager.default.fileExists(atPath: expandedPath(ref.account))
        case .authFile:
            return authFileContainsSecret(providerID: ref.account)
        case .providerConfig:
            let url = URL(fileURLWithPath: expandedPath(ref.service))
            return FileManager.default.fileExists(atPath: url.path)
                && providerConfigContainsSecret(providerID: ref.account, url: url)
        }
    }

    public static func writeSecrets(_ apiKeysByProviderID: [String: String]) throws {
        let entries = apiKeysByProviderID.compactMapValues { nonEmpty($0) }
        guard !entries.isEmpty else { return }

        let url = authFileURL()
        var providers = existingAuthProviderMap(from: url)
        for (providerID, secret) in entries {
            providers[providerID] = secret
        }

        let object: [String: [String: String]] = ["providers": providers]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func cacheKey(for ref: KeychainRef) -> String {
        "\(ref.source.rawValue)\u{1F}\(ref.service)\u{1F}\(ref.account)"
    }

    private static func readSecretFile(path: String) throws -> String {
        let url = URL(fileURLWithPath: expandedPath(path))
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            throw IntatisError.notFound("empty secret file '\(path)'")
        }
        return value
    }

    private static func readAuthFileSecret(providerID: String) throws -> String {
        let candidateIDs = authProviderIDCandidates(from: providerID)
        let data = try Data(contentsOf: authFileURL())
        let object = try JSONSerialization.jsonObject(with: data)
        for candidate in candidateIDs {
            if let value = authSecret(in: object, providerID: candidate) {
                return value
            }
        }
        throw IntatisError.notFound("auth file secret for provider '\(providerID)'")
    }

    private static func readProviderConfigSecret(providerID: String, path: String) throws -> String {
        let url = URL(fileURLWithPath: expandedPath(path))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        for candidate in authProviderIDCandidates(from: providerID) {
            if let value = authSecret(in: object, providerID: candidate) {
                return value
            }
        }
        throw IntatisError.notFound("provider config secret for provider '\(providerID)'")
    }

    private static func authFileContainsSecret(providerID: String) -> Bool {
        guard FileManager.default.fileExists(atPath: authFileURL().path),
              let data = try? Data(contentsOf: authFileURL()),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return authProviderIDCandidates(from: providerID).contains {
            authSecret(in: object, providerID: $0) != nil
        }
    }

    private static func providerConfigContainsSecret(providerID: String, url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return authProviderIDCandidates(from: providerID).contains {
            authSecret(in: object, providerID: $0) != nil
        }
    }

    private static func authSecret(in object: Any, providerID: String) -> String? {
        if let flat = object as? [String: String],
           let value = nonEmpty(flat[providerID]) {
            return value
        }
        guard let root = object as? [String: Any] else { return nil }
        if let value = nonEmpty(root[providerID] as? String) {
            return value
        }
        if let providers = root["providers"] as? [String: String],
           let value = nonEmpty(providers[providerID]) {
            return value
        }
        if let provider = root["provider"] as? [String: String],
           let value = nonEmpty(provider[providerID]) {
            return value
        }
        return nil
    }

    private static func authProviderID(from value: String) -> String? {
        if value == "default" || value == "default-openai" {
            return "openai"
        }
        let prefix = "provider-"
        guard value.hasPrefix(prefix) else { return nil }
        let providerID = String(value.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return providerID.isEmpty ? nil : providerID
    }

    private static func authProviderIDCandidates(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = authProviderID(from: trimmed) ?? trimmed
        var candidates = [trimmed, normalized]
        if trimmed == "default" || normalized == "openai" {
            candidates.append("OpenAI")
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !seen.contains(value.lowercased()) else { return nil }
            seen.insert(value.lowercased())
            return value
        }
    }

    private static func existingAuthProviderMap(from url: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
        if let flat = object as? [String: String] {
            return flat
        }
        guard let root = object as? [String: Any] else { return [:] }
        if let providers = root["providers"] as? [String: String] {
            return providers
        }
        if let providers = root["provider"] as? [String: String] {
            return providers
        }
        return [:]
    }

    private static func authFileURL() -> URL {
        let identity = IntatisHostApplication.identity
        if let override = ProcessInfo.processInfo.environment[
            identity.environmentVariable("AUTH_FILE")],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandedPath(override))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent(identity.storageName, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = NSHomeDirectory()
        if trimmed == "~" { return home }
        return home + String(trimmed.dropFirst())
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
#endif
