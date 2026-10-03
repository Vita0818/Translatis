#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders

/// Resolves provider secrets from configuration files, environment variables,
/// and explicit secret files. Legacy `.keychain` refs are treated as config refs
/// so provider requests never call the macOS Keychain APIs.
public final class ConfigSecretResolver: SecretResolver, @unchecked Sendable {
    private static var hostIdentity: IntatisHostApplicationIdentity {
        IntatisHostApplication.identity
    }
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
            guard Self.isAllowedProviderConfigPath(ref.service) else {
                throw IntatisError.notFound(
                    "provider config is not a \(Self.hostIdentity.name)-owned or explicitly selected config")
            }
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
            return Self.authFileURLs().contains {
                FileManager.default.fileExists(atPath: $0.path)
                    && Self.authFileContainsSecret(providerID: providerID, url: $0)
            }
        case .environment:
            return !(ProcessInfo.processInfo.environment[ref.account] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            return FileManager.default.fileExists(atPath: expandedPath(ref.account))
        case .authFile:
            return Self.authFileURLs().contains {
                FileManager.default.fileExists(atPath: $0.path)
                    && Self.authFileContainsSecret(providerID: ref.account, url: $0)
            }
        case .providerConfig:
            guard Self.isAllowedProviderConfigPath(ref.service) else { return false }
            let url = URL(fileURLWithPath: expandedPath(ref.service))
            return FileManager.default.fileExists(atPath: url.path)
                && Self.authFileContainsSecret(providerID: ref.account, url: url)
        }
    }

    public static func writableAuthFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[
            hostIdentity.environmentVariable("AUTH_FILE")],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandedPath(override))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return hostIdentity.userConfigurationDirectory(homeDirectory: home)
            .appendingPathComponent("auth.json")
    }

    public static func writeSecrets(_ apiKeysByProviderID: [String: String]) throws {
        let entries = apiKeysByProviderID.compactMapValues(nonEmpty)
        guard !entries.isEmpty else { return }

        let url = writableAuthFileURL()
        var providers = existingAuthProviderMap(from: url)
        for (providerID, secret) in entries {
            providers[providerID] = secret
        }

        let object: [String: [String: String]] = ["providers": providers]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func cacheKey(for ref: KeychainRef) -> String {
        "\(ref.source.rawValue)\u{1F}\(ref.service)\u{1F}\(ref.account)"
    }

    private static func readSecretFile(path: String) throws -> String {
        let url = URL(fileURLWithPath: resolvedSecretFilePath(path, configDirectory: nil))
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
        for url in authFileURLs() where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? jsonCompatibleData(from: url),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            for candidate in candidateIDs {
                if let secret = authSecret(in: object,
                                           providerID: candidate,
                                           configDirectory: url.deletingLastPathComponent()) {
                    return secret
                }
            }
        }
        throw IntatisError.notFound("auth file secret for provider '\(providerID)'")
    }

    private static func readProviderConfigSecret(providerID: String, path: String) throws -> String {
        let url = URL(fileURLWithPath: expandedPath(path))
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? jsonCompatibleData(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw IntatisError.notFound("provider config secret for provider '\(providerID)'")
        }
        for candidate in authProviderIDCandidates(from: providerID) {
            if let secret = authSecret(in: object,
                                       providerID: candidate,
                                       configDirectory: url.deletingLastPathComponent()) {
                return secret
            }
        }
        throw IntatisError.notFound("provider config secret for provider '\(providerID)'")
    }

    private static func authFileContainsSecret(providerID: String, url: URL) -> Bool {
        let candidateIDs = authProviderIDCandidates(from: providerID)
        guard let data = try? jsonCompatibleData(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return candidateIDs.contains { candidate in
            authSecret(in: object,
                       providerID: candidate,
                       configDirectory: url.deletingLastPathComponent()) != nil
        }
    }

    private static func authSecret(in object: Any,
                                   providerID: String,
                                   configDirectory: URL?) -> String? {
        if let flat = object as? [String: String] {
            return secretString(flat[providerID], configDirectory: configDirectory)
                ?? secretString(value(in: flat, providerID: providerID), configDirectory: configDirectory)
        }
        guard let root = object as? [String: Any] else { return nil }
        if let value = secretString(root[providerID] as? String, configDirectory: configDirectory) {
            return value
        }
        if let value = secretValue(in: providerValue(in: root, providerID: providerID),
                                   configDirectory: configDirectory) {
            return value
        }
        if let providers = root["providers"] as? [String: Any] {
            if let value = secretString(providers[providerID] as? String,
                                        configDirectory: configDirectory) {
                return value
            }
            if let value = secretValue(in: providerValue(in: providers, providerID: providerID),
                                       configDirectory: configDirectory) {
                return value
            }
        }
        if let provider = root["provider"] as? [String: Any] {
            if let value = secretString(provider[providerID] as? String,
                                        configDirectory: configDirectory) {
                return value
            }
            if let value = secretValue(in: providerValue(in: provider, providerID: providerID),
                                       configDirectory: configDirectory) {
                return value
            }
        }
        return nil
    }

    private static func providerValue(in map: [String: Any], providerID: String) -> Any? {
        if let exact = map[providerID] { return exact }
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return map.first {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }?.value
    }

    private static func value(in map: [String: String], providerID: String) -> String? {
        if let exact = map[providerID] { return exact }
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return map.first {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }?.value
    }

    private static func secretValue(in object: Any?, configDirectory: URL?) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        for key in ["apiKey", "apikey", "api_key", "key", "token", "accessToken", "access_token"] {
            if let value = secretString(dict[key] as? String, configDirectory: configDirectory) {
                return value
            }
        }
        if let nested = dict["auth"] as? [String: Any] {
            for key in ["apiKey", "apikey", "api_key", "key", "token", "accessToken", "access_token"] {
                if let value = secretString(nested[key] as? String, configDirectory: configDirectory) {
                    return value
                }
            }
        }
        if let options = dict["options"] as? [String: Any] {
            for key in ["apiKey", "apikey", "api_key", "key", "token", "accessToken", "access_token"] {
                if let value = secretString(options[key] as? String, configDirectory: configDirectory) {
                    return value
                }
            }
        }
        return nil
    }

    private static func secretString(_ value: String?, configDirectory: URL?) -> String? {
        guard let trimmed = nonEmpty(value) else { return nil }
        guard let variable = configVariable(in: trimmed) else { return trimmed }
        switch variable.kind {
        case "env":
            return nonEmpty(ProcessInfo.processInfo.environment[variable.value])
        case "file":
            let path = resolvedSecretFilePath(variable.value, configDirectory: configDirectory)
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            return nonEmpty(contents)
        default:
            return trimmed
        }
    }

    private static func configVariable(in raw: String) -> (kind: String, value: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let body = trimmed.dropFirst().dropLast()
        guard let separator = body.firstIndex(of: ":") else { return nil }
        let kind = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !value.isEmpty else { return nil }
        return (kind, value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func authFileURLs() -> [URL] {
        if let override = ProcessInfo.processInfo.environment[
            hostIdentity.environmentVariable("AUTH_FILE")],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [URL(fileURLWithPath: expandedPath(override))]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = [
            writableAuthFileURL(),
            hostIdentity.userDataDirectory(homeDirectory: home)
                .appendingPathComponent("auth.json"),
        ]
        urls.append(contentsOf: providerConfigURLs())
        return urls
    }

    private static func providerConfigURLs() -> [URL] {
        if let configOverride = ProcessInfo.processInfo.environment[
            hostIdentity.environmentVariable("CONFIG")],
           !configOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [URL(fileURLWithPath: expandedPath(configOverride))]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = hostIdentity.userConfigurationDirectory(
            homeDirectory: home)
        return [
            configDirectory.appendingPathComponent(
                hostIdentity.configurationFileName),
            configDirectory.appendingPathComponent(
                hostIdentity.configurationJSONCFileName),
            configDirectory.appendingPathComponent("config.json"),
            configDirectory.appendingPathComponent("config.jsonc"),
            appSupportDir().appendingPathComponent(
                hostIdentity.configurationFileName),
            appSupportDir().appendingPathComponent(
                hostIdentity.configurationJSONCFileName),
            appSupportDir().appendingPathComponent("config.json"),
            appSupportDir().appendingPathComponent("config.jsonc"),
        ]
    }

    private static func isAllowedProviderConfigPath(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: expandedPath(path)).standardizedFileURL.path
        return providerConfigURLs().contains {
            $0.standardizedFileURL.path == candidate
        }
    }

    private static func authProviderID(from legacyAccount: String) -> String? {
        if legacyAccount == "default" || legacyAccount == "default-openai" {
            return "openai"
        }
        let prefix = "provider-"
        guard legacyAccount.hasPrefix(prefix) else { return nil }
        let providerID = String(legacyAccount.dropFirst(prefix.count))
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
              let data = try? jsonCompatibleData(from: url),
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

    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == "~" { return home }
        return home + String(trimmed.dropFirst())
    }

    private static func resolvedSecretFilePath(_ path: String, configDirectory: URL?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            return expandedPath(trimmed)
        }
        if trimmed.hasPrefix("/") { return trimmed }
        guard let configDirectory else { return trimmed }
        return configDirectory.appendingPathComponent(trimmed).path
    }

    private static func appSupportDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(
            hostIdentity.storageName,
            isDirectory: true)
    }

    private static func jsonCompatibleData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let stripped = stripTrailingCommas(from: stripJSONComments(from: text))
        return Data(stripped.utf8)
    }

    private static func stripJSONComments(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
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
                let nextCharacter = text[next]
                if nextCharacter == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    if index < text.endIndex {
                        output.append("\n")
                        index = text.index(after: index)
                    }
                    continue
                }
                if nextCharacter == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let current = text[index]
                        let lookahead = text.index(after: index)
                        if current == "\n" { output.append("\n") }
                        if current == "*", lookahead < text.endIndex, text[lookahead] == "/" {
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

    private static func stripTrailingCommas(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
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
#endif
