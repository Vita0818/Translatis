import Foundation

/// Immutable identity for executable original-source replay behavior.
///
/// The descriptor is data only. A descriptor becomes admissible only after a
/// `KnowledgeSourceLocatorAdapterRegistry` has paired it with executable code
/// and validated its identity, version, and supported locator kinds.
public struct KnowledgeSourceLocatorAdapterDescriptor: Codable, Equatable, Hashable, Sendable {
    public let identity: String
    public let version: String
    public let kinds: [String]

    public var key: String { identity + "@" + version }

    public init(identity: String,
                version: String,
                kinds: [String]) {
        self.identity = identity
        self.version = version
        self.kinds = kinds
    }
}

/// Bounded replay result returned by a concrete source-locator adapter.
public struct KnowledgeSourceLocatorReplay: Equatable, Sendable {
    public let byteRange: Range<Int>?
    public let content: Data

    public init(byteRange: Range<Int>?, content: Data) {
        self.byteRange = byteRange
        self.content = content
    }

    public var utf8Text: String? {
        String(data: content, encoding: .utf8)
    }
}

/// Executable, versioned source-locator behavior. Implementations receive only
/// bytes that the deterministic Validator already obtained through
/// `KnowledgeSecureFileSystem` with no-follow and explicit size bounds.
public protocol KnowledgeSourceLocatorAdapter: Sendable {
    var descriptor: KnowledgeSourceLocatorAdapterDescriptor { get }

    func replay(
        _ locator: KnowledgeSourceLocator,
        in immutableSourceBytes: Data
    ) throws -> KnowledgeSourceLocatorReplay
}

/// Deterministic registry of executable source-locator adapters. The registry
/// rejects duplicate descriptor keys instead of allowing last-write-wins and
/// hashes canonical descriptors, never process-local type names or closures.
public struct KnowledgeSourceLocatorAdapterRegistry: Equatable, Sendable {
    private struct RegisteredAdapter: Sendable {
        let descriptor: KnowledgeSourceLocatorAdapterDescriptor
        let implementation: any KnowledgeSourceLocatorAdapter
    }

    private let adaptersByKey: [String: RegisteredAdapter]

    public let descriptors: [KnowledgeSourceLocatorAdapterDescriptor]
    public let digest: String

    /// Passing `nil` installs the P0 built-in adapter. Passing an explicit
    /// empty array creates a registry that admits no source locators.
    public init(
        adapters: [any KnowledgeSourceLocatorAdapter]? = nil
    ) throws {
        let selected = adapters ?? [KnowledgeUTF8ByteRangeSourceLocatorAdapter()]
        var byKey: [String: RegisteredAdapter] = [:]
        var canonicalDescriptors: [KnowledgeSourceLocatorAdapterDescriptor] = []
        canonicalDescriptors.reserveCapacity(selected.count)

        for adapter in selected {
            let descriptor = adapter.descriptor
            try Self.validate(descriptor)
            let canonical = KnowledgeSourceLocatorAdapterDescriptor(
                identity: descriptor.identity,
                version: descriptor.version,
                kinds: descriptor.kinds.sorted())
            guard byKey.updateValue(
                RegisteredAdapter(
                    descriptor: canonical,
                    implementation: adapter),
                forKey: canonical.key) == nil else {
                throw KnowledgeDomainError(
                    .profileInvalid,
                    "Source-locator adapter registry contains a duplicate exact identity and version.")
            }
            canonicalDescriptors.append(canonical)
        }

        canonicalDescriptors.sort(by: Self.order)
        struct Projection: Codable {
            let version: String
            let adapters: [KnowledgeSourceLocatorAdapterDescriptor]
        }
        adaptersByKey = byKey
        descriptors = canonicalDescriptors
        digest = try KnowledgeDigest.canonical(Projection(
            version: KnowledgeHostIdentity.schema(
                "source-locator-adapter-registry/1"),
            adapters: canonicalDescriptors))
    }

    public var adapterKeys: Set<String> {
        Set(descriptors.map(\.key))
    }

    public func replay(
        _ locator: KnowledgeSourceLocator,
        in immutableSourceBytes: Data
    ) throws -> KnowledgeSourceLocatorReplay {
        let key = locator.adapterIdentity + "@" + locator.adapterVersion
        guard KnowledgeSourceIdentity.isPortable(locator.sourceID),
              let adapter = adaptersByKey[key],
              adapter.descriptor.kinds.contains(locator.kind) else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Source locator cannot be replayed by an exact registered adapter and kind.")
        }
        return try adapter.implementation.replay(
            locator,
            in: immutableSourceBytes)
    }

    public static func == (
        lhs: KnowledgeSourceLocatorAdapterRegistry,
        rhs: KnowledgeSourceLocatorAdapterRegistry
    ) -> Bool {
        lhs.digest == rhs.digest && lhs.descriptors == rhs.descriptors
    }

    private static func validate(
        _ descriptor: KnowledgeSourceLocatorAdapterDescriptor
    ) throws {
        let componentPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$"#
        let kindPattern = #"^[a-z0-9][a-z0-9._-]{0,127}$"#
        guard descriptor.identity.range(
                of: componentPattern,
                options: .regularExpression) != nil,
              descriptor.version.range(
                of: componentPattern,
                options: .regularExpression) != nil,
              !descriptor.kinds.isEmpty,
              descriptor.kinds.count <= 64,
              Set(descriptor.kinds).count == descriptor.kinds.count,
              descriptor.kinds.allSatisfy({
                  $0.range(of: kindPattern, options: .regularExpression) != nil
              }) else {
            throw KnowledgeDomainError(
                .profileInvalid,
                "Source-locator adapter descriptor is invalid or ambiguous.")
        }
    }

    private static func order(
        _ lhs: KnowledgeSourceLocatorAdapterDescriptor,
        _ rhs: KnowledgeSourceLocatorAdapterDescriptor
    ) -> Bool {
        if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
        return lhs.version < rhs.version
    }
}

/// P0's replayable original-source locator. `value` is the canonical decimal
/// UTF-8 byte range `start:end` (end-exclusive).
public struct KnowledgeUTF8ByteRangeSourceLocatorAdapter: KnowledgeSourceLocatorAdapter {
    public static let identity = KnowledgeContract.utf8SourceLocatorAdapterIdentity
    public static let version = KnowledgeContract.utf8SourceLocatorAdapterVersion
    public static let key = KnowledgeContract.utf8SourceLocatorAdapterKey

    public let descriptor = KnowledgeSourceLocatorAdapterDescriptor(
        identity: identity,
        version: version,
        kinds: ["utf8-byte-range"])

    public init() {}

    public func replay(
        _ locator: KnowledgeSourceLocator,
        in immutableSourceBytes: Data
    ) throws -> KnowledgeSourceLocatorReplay {
        let range = try Self.replay(locator, in: immutableSourceBytes)
        return KnowledgeSourceLocatorReplay(
            byteRange: range,
            content: immutableSourceBytes.subdata(in: range))
    }

    /// Compatibility convenience for callers that need the exact byte range.
    public static func replay(
        _ locator: KnowledgeSourceLocator,
        in immutableSourceBytes: Data
    ) throws -> Range<Int> {
        guard locator.schema == KnowledgeHostIdentity.schema(
                "source-locator/1"),
              KnowledgeSourceIdentity.isPortable(locator.sourceID),
              locator.adapterIdentity == identity,
              locator.adapterVersion == version,
              locator.kind == "utf8-byte-range",
              locator.sourceRevision
                == KnowledgeDigest.sha256(immutableSourceBytes),
              String(data: immutableSourceBytes, encoding: .utf8) != nil else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Source locator does not bind this exact UTF-8 adapter and immutable source revision.")
        }
        let parts = locator.value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]),
              start >= 0,
              end > start,
              end <= immutableSourceBytes.count,
              locator.value == "\(start):\(end)" else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Source locator UTF-8 byte range is not canonical or is out of bounds.")
        }
        let range = start..<end
        guard String(
            data: immutableSourceBytes.subdata(in: range),
            encoding: .utf8) != nil else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Source locator does not resolve on UTF-8 code point boundaries.")
        }
        return range
    }
}
