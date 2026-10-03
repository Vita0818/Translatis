import Foundation
import IntatisProtocol

/// Exact, non-wire model metadata used to reason about context-window limits.
///
/// The values mirror Codex model metadata but remain separate from provider
/// request options. Missing raw/max metadata uses the product-wide fallback;
/// callers must not infer a context window from a model slug.
public struct AgentModelContextPolicy: Codable, Equatable, Sendable {
    public static let defaultContextWindowTokens = 1_000_000
    public static let defaultAutomaticCompactionPercent = 90
    public static let defaultEffectiveContextWindowPercent = 95

    /// Model-advertised context window.
    public let contextWindowTokens: Int?
    /// Maximum context window available when the primary value is absent.
    public let maxContextWindowTokens: Int?
    /// Explicit automatic-compaction threshold before the Codex 90% clamp.
    public let autoCompactTokenLimit: Int?
    /// Percentage of the resolved context window considered usable.
    public let effectiveContextWindowPercent: Int
    /// Opaque identifier for compaction-compatible model configurations.
    public let compHash: String?

    public init(
        contextWindowTokens: Int? = nil,
        maxContextWindowTokens: Int? = nil,
        autoCompactTokenLimit: Int? = nil,
        effectiveContextWindowPercent: Int =
            AgentModelContextPolicy.defaultEffectiveContextWindowPercent,
        compHash: String? = nil
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.maxContextWindowTokens = maxContextWindowTokens
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.effectiveContextWindowPercent =
            effectiveContextWindowPercent
        self.compHash = compHash
    }

    /// Legacy/default profile value. Its metadata remains unspecified for
    /// encoding and fingerprinting, while resolved runtime limits use the
    /// product-wide context-window fallback.
    public static let unspecified = AgentModelContextPolicy()

    /// Resolves the primary context window first, then its maximum value, then
    /// the product-wide fallback when neither is explicitly configured.
    public var resolvedContextWindowTokens: Int? {
        contextWindowTokens
            ?? maxContextWindowTokens
            ?? Self.defaultContextWindowTokens
    }

    /// Derives the default percentage of the resolved window and clamps an
    /// explicit threshold to that value. An explicit threshold remains usable
    /// when the raw window is unknown.
    public var resolvedAutoCompactTokenLimit: Int? {
        let derived = resolvedContextWindowTokens.map {
            Self.percent(
                $0,
                numerator: Self.defaultAutomaticCompactionPercent,
                denominator: 100)
        }
        switch (derived, autoCompactTokenLimit) {
        case (.some(let derived), .some(let configured)):
            return min(derived, configured)
        case (.some(let derived), .none):
            return derived
        case (.none, .some(let configured)):
            return configured
        case (.none, .none):
            return nil
        }
    }

    /// Hard usable context boundary after reserving output/tool headroom.
    public var hardUsableContextWindowTokens: Int? {
        resolvedContextWindowTokens.map {
            Self.percent(
                $0,
                numerator: effectiveContextWindowPercent,
                denominator: 100)
        }
    }

    /// Earliest total-scope rollover boundary. The normal 90% automatic
    /// threshold usually wins, while a deliberately smaller effective window
    /// remains an independent hard trigger as in Codex.
    public var automaticCompactionTriggerTokens: Int? {
        switch (
            resolvedAutoCompactTokenLimit,
            hardUsableContextWindowTokens
        ) {
        case (.some(let automatic), .some(let hard)):
            return min(automatic, hard)
        case (.some(let automatic), .none):
            return automatic
        case (.none, .some(let hard)):
            return hard
        case (.none, .none):
            return nil
        }
    }

    public var isAutomaticCompactionEnabled: Bool {
        automaticCompactionTriggerTokens != nil
    }

    /// Extracts only explicit model metadata. Numeric strings, booleans,
    /// fractional values, and non-positive values are ignored.
    ///
    /// Codex snake_case takes precedence over OpenCode's `limit.context`
    /// fallback. The returned metadata is never copied into request options.
    public init(configurationMetadata metadata: [String: JSONValue]) {
        let openCodeContext: Int?
        if case .object(let limit)? = metadata["limit"] {
            openCodeContext = Self.positiveInteger(limit["context"])
        } else {
            openCodeContext = nil
        }

        contextWindowTokens =
            Self.positiveInteger(metadata["context_window"])
            ?? openCodeContext
        maxContextWindowTokens =
            Self.positiveInteger(metadata["max_context_window"])
        autoCompactTokenLimit =
            Self.positiveInteger(metadata["auto_compact_token_limit"])

        let configuredPercent =
            Self.positiveInteger(
                metadata["effective_context_window_percent"])
        if let configuredPercent,
           (1...100).contains(configuredPercent) {
            effectiveContextWindowPercent = configuredPercent
        } else {
            effectiveContextWindowPercent =
                Self.defaultEffectiveContextWindowPercent
        }

        if case .string(let value)? = metadata["comp_hash"],
           Self.validCompHash(value) {
            compHash = value
        } else {
            compHash = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case contextWindowTokens
        case maxContextWindowTokens
        case autoCompactTokenLimit
        case effectiveContextWindowPercent
        case compHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextWindowTokens =
            try container.decodeIfPresent(
                Int.self,
                forKey: .contextWindowTokens)
        maxContextWindowTokens =
            try container.decodeIfPresent(
                Int.self,
                forKey: .maxContextWindowTokens)
        autoCompactTokenLimit =
            try container.decodeIfPresent(
                Int.self,
                forKey: .autoCompactTokenLimit)
        effectiveContextWindowPercent =
            try container.decodeIfPresent(
                Int.self,
                forKey: .effectiveContextWindowPercent)
            ?? Self.defaultEffectiveContextWindowPercent
        compHash =
            try container.decodeIfPresent(
                String.self,
                forKey: .compHash)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(
            contextWindowTokens,
            forKey: .contextWindowTokens)
        try container.encodeIfPresent(
            maxContextWindowTokens,
            forKey: .maxContextWindowTokens)
        try container.encodeIfPresent(
            autoCompactTokenLimit,
            forKey: .autoCompactTokenLimit)
        if effectiveContextWindowPercent
            != Self.defaultEffectiveContextWindowPercent {
            try container.encode(
                effectiveContextWindowPercent,
                forKey: .effectiveContextWindowPercent)
        }
        try container.encodeIfPresent(
            compHash,
            forKey: .compHash)
    }

    /// Catalog validation is intentionally separate from metadata extraction:
    /// programmatic drafts with impossible values fail closed instead of being
    /// silently normalized.
    var isValidForCatalog: Bool {
        [
            contextWindowTokens,
            maxContextWindowTokens,
            autoCompactTokenLimit,
        ].allSatisfy { $0.map { $0 > 0 } ?? true }
            && (1...100).contains(effectiveContextWindowPercent)
            && (compHash.map(Self.validCompHash) ?? true)
    }

    /// An unspecified policy must not change legacy binding fingerprints.
    var fingerprintComponents: [String] {
        guard self != .unspecified else { return [] }
        return [
            "model-context-policy-v1",
            contextWindowTokens.map(String.init) ?? "",
            maxContextWindowTokens.map(String.init) ?? "",
            autoCompactTokenLimit.map(String.init) ?? "",
            String(effectiveContextWindowPercent),
            compHash ?? "",
        ]
    }

    private static func positiveInteger(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value,
              number.isFinite,
              let integer = Int(exactly: number),
              integer > 0 else {
            return nil
        }
        return integer
    }

    private static func validCompHash(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && value
                == value.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    /// Overflow-safe floor(value * numerator / denominator) for a positive
    /// value and a numerator no greater than its denominator.
    private static func percent(
        _ value: Int,
        numerator: Int,
        denominator: Int
    ) -> Int {
        let quotient = value / denominator
        let remainder = value % denominator
        return quotient * numerator
            + (remainder * numerator) / denominator
    }
}
