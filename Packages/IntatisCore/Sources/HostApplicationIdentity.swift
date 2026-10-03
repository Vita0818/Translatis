import Foundation

/// The product identity of an application embedding the shared Intatis
/// runtime and public packages.
///
/// Swift module/type names and fixed third-party protocol extensions remain
/// Intatis implementation identities. This value owns host-visible and
/// host-persisted namespaces: application-support/config paths, environment
/// variables, defaults, diagnostics, Keychain services, workspace metadata,
/// registry identities, and model-facing reserved fields.
public struct IntatisHostApplicationIdentity: Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public static let intatis = try! IntatisHostApplicationIdentity(
        name: "Intatis")

    /// User-facing product name supplied by the embedding host.
    public let name: String
    /// Safe case-preserving component used for Application Support and other
    /// product-owned filesystem roots. Separators in `name` are removed.
    public let storageName: String
    /// Lowercase, hyphen-separated identifier used for files and commands.
    public let fileNameStem: String
    /// Lowercase, underscore-separated identifier used inside field names.
    public let fieldNameStem: String
    /// Uppercase, underscore-separated environment-variable prefix.
    public let environmentPrefix: String

    public init(name rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 64,
              name.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar.value == 32
                    || scalar.value == 45
                    || scalar.value == 95
              }) else {
            throw IntatisHostApplicationIdentityError.invalidName
        }

        let scalars = Array(name.unicodeScalars)
        let isASCIILetter: (Unicode.Scalar) -> Bool = { scalar in
            (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
        }
        let isASCIIDigit: (Unicode.Scalar) -> Bool = { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
        let isSeparator: (Unicode.Scalar) -> Bool = { scalar in
            scalar.value == 32 || scalar.value == 45 || scalar.value == 95
        }
        guard let first = scalars.first,
              let last = scalars.last,
              isASCIILetter(first),
              isASCIILetter(last) || isASCIIDigit(last),
              !zip(scalars, scalars.dropFirst()).contains(where: {
                  isSeparator($0.0) && isSeparator($0.1)
              }) else {
            throw IntatisHostApplicationIdentityError.invalidName
        }

        let tokens = name.split(whereSeparator: { character in
            character == " " || character == "-" || character == "_"
        }).map(String.init)
        guard !tokens.isEmpty,
              tokens.allSatisfy({ token in
                  token.unicodeScalars.contains(where: {
                      CharacterSet.letters.contains($0)
                        || CharacterSet.decimalDigits.contains($0)
                  })
              }),
              let firstScalar = tokens.first?.unicodeScalars.first,
              isASCIILetter(firstScalar) else {
            throw IntatisHostApplicationIdentityError.invalidName
        }

        let storageName = tokens.joined()
        let fileNameStem = tokens.map { $0.lowercased() }.joined(separator: "-")
        let fieldNameStem = tokens.map { $0.lowercased() }.joined(separator: "_")
        let environmentPrefix = tokens.map { $0.uppercased() }.joined(separator: "_")
        guard !storageName.isEmpty,
              !fileNameStem.isEmpty,
              !fieldNameStem.isEmpty,
              !environmentPrefix.isEmpty else {
            throw IntatisHostApplicationIdentityError.invalidName
        }

        self.name = name
        self.storageName = storageName
        self.fileNameStem = fileNameStem
        self.fieldNameStem = fieldNameStem
        self.environmentPrefix = environmentPrefix
    }

    public var commandName: String { fileNameStem }
    public var indefiniteArticle: String {
        guard let first = name.unicodeScalars.first else { return "a" }
        return "AEIOUaeiou".unicodeScalars.contains(first) ? "an" : "a"
    }
    public var macOSProcessNameCandidates: [String] {
        self == .intatis
            ? [storageName + "Mac", storageName]
            : [storageName, storageName + "Mac"]
    }
    public var macOSProcessName: String {
        macOSProcessNameCandidates[0]
    }
    public var hiddenWorkspaceDirectoryName: String { "." + fileNameStem }
    public var knowledgeBundleDirectoryName: String {
        "." + fileNameStem + "-rag"
    }
    public var knowledgeStoreFileName: String {
        "." + fileNameStem + "-rag-store.json"
    }
    public var knowledgeSnapshotsDirectoryName: String {
        "." + fileNameStem + "-rag-snapshots"
    }
    public var knowledgeHostDirectoryName: String {
        "." + fileNameStem + "-rag-host"
    }
    public var configurationFileName: String { fileNameStem + ".json" }
    public var configurationJSONCFileName: String { fileNameStem + ".jsonc" }
    public var authorizationContextFieldName: String {
        "__" + fieldNameStem + "_authorization_context"
    }
    public var secretReferenceFieldName: String {
        "$" + fieldNameStem + "SecretRef"
    }
    public var redactedArgumentsFieldName: String { "_" + fieldNameStem }
    public var diagnosticSubsystem: String {
        "com.Vita0818." + storageName
    }
    public var macOSBundleIdentifierCandidates: [String] {
        let base = "com.Vita0818." + storageName
        return self == .intatis
            ? [base + "Mac", base]
            : [base, base + "Mac"]
    }
    public var expectedMacBundleIdentifier: String {
        macOSBundleIdentifierCandidates[0]
    }

    public func environmentVariable(_ suffix: String) -> String {
        environmentPrefix + "_" + suffix
    }

    public func userDefaultsKey(_ suffix: String) -> String {
        fileNameStem + "." + suffix
    }

    public func namespacedIdentifier(_ suffix: String) -> String {
        fileNameStem + "." + suffix
    }

    public func colonIdentifier(_ suffix: String) -> String {
        fileNameStem + ":" + suffix
    }

    public func temporaryPrefix(_ suffix: String) -> String {
        fileNameStem + "-" + suffix
    }

    public func keychainService(_ suffix: String) -> String {
        "com.vitemis." + fileNameStem + "." + suffix
    }

    public func applicationSupportRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
            .appendingPathComponent(storageName, isDirectory: true)
    }

    public func userConfigurationDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(fileNameStem, isDirectory: true)
    }

    public func userDataDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".local/share", isDirectory: true)
            .appendingPathComponent(fileNameStem, isDirectory: true)
    }

    /// Product-owned path components that must stay protected while reading
    /// legacy Intatis data. Downstream products write only their own first
    /// element; the legacy name remains a deny/secret-recognition floor.
    public var protectedIdentityStems: Set<String> {
        [fileNameStem, IntatisHostApplicationIdentity.intatis.fileNameStem]
    }

    public var description: String {
        "IntatisHostApplicationIdentity(name: \(name), namespace: \(fileNameStem))"
    }

    public var debugDescription: String { description }
}

public enum IntatisHostApplicationIdentityError: Error, LocalizedError,
    Equatable, Sendable
{
    case invalidName
    case alreadyConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "The host application name must begin with an ASCII letter, end with a letter or number, and contain only letters, numbers, or single spaces, hyphens, and underscores between name segments."
        case .alreadyConfigured:
            return "The shared runtime host application identity has already been resolved for this process."
        }
    }
}

/// Process-wide installation point for an embedding App or CLI.
///
/// A host calls `configure(name:)` once, before it constructs storage,
/// provider, tool, or runtime objects. The first read seals the identity so a
/// later product cannot redirect already-derived paths or protocol fields.
/// Existing Intatis callers remain source-compatible through the exact
/// `.intatis` default.
public enum IntatisHostApplication {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var identity = IntatisHostApplicationIdentity.intatis
        var explicitlyConfigured = false
        var sealed = false
    }

    private static let storage = Storage()

    @discardableResult
    public static func configure(
        name: String
    ) throws -> IntatisHostApplicationIdentity {
        try configure(try IntatisHostApplicationIdentity(name: name))
    }

    @discardableResult
    public static func configure(
        _ identity: IntatisHostApplicationIdentity
    ) throws -> IntatisHostApplicationIdentity {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if storage.identity == identity {
            storage.explicitlyConfigured = true
            return identity
        }
        guard !storage.sealed, !storage.explicitlyConfigured else {
            throw IntatisHostApplicationIdentityError.alreadyConfigured
        }
        storage.identity = identity
        storage.explicitlyConfigured = true
        return identity
    }

    public static var identity: IntatisHostApplicationIdentity {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.sealed = true
        return storage.identity
    }

    public static var isExplicitlyConfigured: Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.explicitlyConfigured
    }
}
