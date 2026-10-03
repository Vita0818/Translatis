import Foundation
import IntatisCore
import IntatisProtocol

/// Process-memory-only registration surface for values that have been
/// resolved from an opaque MCP secret reference, minted for a local transport,
/// or returned by an authorization provider.
///
/// Implementations must never persist registered values. Registration is
/// synchronous so a value can be installed before it crosses a transport
/// boundary or an untrusted server can echo it back.
public protocol MCPSecretRedactionRegistering: Sendable {
    func registerMCPSecretRedactionValue(_ value: Data)
    func clearMCPSecretRedactionValues()
}

public extension MCPSecretRedactionRegistering {
    func registerMCPSecretRedactionValue(_ value: String) {
        registerMCPSecretRedactionValue(Data(value.utf8))
    }
}

public enum MCPOutputSecurityError:
    Error, Equatable, LocalizedError, Sendable
{
    case redactionContextCapacityExceeded
    case sensitiveBinaryPayload
    case sensitiveStructuralIdentifier

    public var errorDescription: String? {
        switch self {
        case .redactionContextCapacityExceeded:
            return "the MCP output redaction context exceeded its safe in-memory capacity"
        case .sensitiveBinaryPayload:
            return "untrusted MCP binary output contains sensitive material"
        case .sensitiveStructuralIdentifier:
            return "untrusted MCP output placed a sensitive value in a structural identifier"
        }
    }
}

public enum MCPOutputSanitization {
    public static func sanitizeJSON(
        _ value: JSONValue,
        using sanitizer:
            any MCPToolResultSanitizer
    ) throws -> JSONValue {
        switch value {
        case .string(let string):
            return .string(
                try sanitizer
                    .sanitizeMCPText(string))
        case .array(let values):
            return .array(
                try values.map {
                    try sanitizeJSON(
                        $0,
                        using: sanitizer)
                })
        case .object(let object):
            var sanitized:
                [String: JSONValue] = [:]
            for (key, nested) in object {
                let safeKey =
                    try sanitizer
                        .sanitizeMCPText(key)
                guard safeKey == key else {
                    throw MCPOutputSecurityError
                        .sensitiveStructuralIdentifier
                }
                sanitized[key] =
                    try sanitizeJSON(
                        nested,
                        using: sanitizer)
            }
            return .object(sanitized)
        case .null, .bool, .number:
            return value
        }
    }

    public static func requireUnchangedIdentifier(
        _ value: String,
        using sanitizer:
            any MCPToolResultSanitizer
    ) throws -> String {
        guard try sanitizer
            .sanitizeMCPText(value) == value else {
            throw MCPOutputSecurityError
                .sensitiveStructuralIdentifier
        }
        return value
    }
}

/// One session-runtime-owned exact-value redactor.
///
/// The conservative pattern scanner remains active, while every credential
/// actually resolved for this runtime is also registered as exact UTF-8,
/// bearer, Basic-proxy, percent-encoded, and base64 variants. A capacity
/// overflow poisons the context so later publication fails closed instead of
/// silently returning unredacted output.
public final class MCPResolvedSecretRedactor:
    MCPToolResultSanitizer,
    MCPSecretRedactionRegistering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumValues: Int
    private let maximumRetainedBytes: Int
    private var values: [Data] = []
    private var retainedBytes = 0
    private var poisoned = false
    private let conservative =
        MCPConservativeToolResultSanitizer()

    public init(
        maximumValues: Int = 1_024,
        maximumRetainedBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumValues = max(1, maximumValues)
        self.maximumRetainedBytes =
            max(1_024, maximumRetainedBytes)
    }

    deinit {
        clearMCPSecretRedactionValues()
    }

    public func registerMCPSecretRedactionValue(
        _ value: Data
    ) {
        guard !value.isEmpty else { return }
        let variants = Self.redactionVariants(for: value)
        lock.lock()
        defer { lock.unlock() }
        guard !poisoned else { return }
        for variant in variants {
            guard !variant.isEmpty,
                  !values.contains(variant) else {
                continue
            }
            guard values.count < maximumValues,
                  retainedBytes <=
                    maximumRetainedBytes - variant.count
            else {
                poisoned = true
                zeroAndRemoveAll()
                return
            }
            values.append(variant)
            retainedBytes += variant.count
        }
        values.sort { $0.count > $1.count }
    }

    public func clearMCPSecretRedactionValues() {
        lock.lock()
        zeroAndRemoveAll()
        poisoned = false
        lock.unlock()
    }

    public func sanitizeMCPText(
        _ text: String
    ) throws -> String {
        let snapshot: [Data]
        lock.lock()
        if poisoned {
            lock.unlock()
            throw MCPOutputSecurityError
                .redactionContextCapacityExceeded
        }
        snapshot = values
        lock.unlock()

        var result = try conservative
            .sanitizeMCPText(text)
        for encoded in snapshot {
            guard let value =
                    String(data: encoded, encoding: .utf8),
                  !value.isEmpty else {
                continue
            }
            result = result.replacingOccurrences(
                of: value,
                with: "[REDACTED]")
        }
        return result
    }

    public func validateMCPBinary(
        _ data: Data
    ) throws {
        if let text = String(
            data: data,
            encoding: .utf8
        ) {
            guard try sanitizeMCPText(text) == text else {
                throw MCPOutputSecurityError
                    .sensitiveBinaryPayload
            }
            return
        }

        let snapshot: [Data]
        lock.lock()
        if poisoned {
            lock.unlock()
            throw MCPOutputSecurityError
                .redactionContextCapacityExceeded
        }
        snapshot = values
        lock.unlock()
        guard !snapshot.contains(where: {
            !$0.isEmpty && data.range(of: $0) != nil
        }) else {
            throw MCPOutputSecurityError
                .sensitiveBinaryPayload
        }
    }

    public var registeredValueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    private func zeroAndRemoveAll() {
        for index in values.indices {
            values[index].resetBytes(
                in: 0..<values[index].count)
        }
        values.removeAll(keepingCapacity: false)
        retainedBytes = 0
    }

    private static func redactionVariants(
        for value: Data
    ) -> [Data] {
        var variants: [Data] = [value]
        let base64 = value.base64EncodedString()
        variants.append(Data(base64.utf8))
        guard let text =
                String(data: value, encoding: .utf8),
              !text.isEmpty else {
            return variants
        }
        variants.append(Data("Bearer \(text)".utf8))
        if let escaped = text.addingPercentEncoding(
            withAllowedCharacters: .urlUserAllowed),
           escaped != text {
            variants.append(Data(escaped.utf8))
        }
        let proxyPayload =
            Data("\(IntatisHostApplication.identity.fileNameStem):\(text)".utf8)
                .base64EncodedString()
        variants.append(Data(proxyPayload.utf8))
        variants.append(Data("Basic \(proxyPayload)".utf8))
        variants.append(
            Data("http://\(IntatisHostApplication.identity.fileNameStem):\(text)@127.0.0.1".utf8))
        return variants
    }
}
