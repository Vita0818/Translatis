import Foundation
import IntatisCore

/// The provider SDK package whose option semantics a route was configured for.
///
/// Intatis remains Swift-native and does not execute npm packages. The package
/// name selects a reviewed Swift lowering that mirrors the corresponding
/// OpenCode/AI SDK boundary. Unknown package names are retained for lossless
/// configuration and durable identity, but fail closed before network I/O.
public struct ProviderRequestAdapter:
    RawRepresentable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let openAICompatible = ProviderRequestAdapter(
        rawValue: "@ai-sdk/openai-compatible")
    public static let openRouter = ProviderRequestAdapter(
        rawValue: "@openrouter/ai-sdk-provider")
    public static let openAI = ProviderRequestAdapter(
        rawValue: "@ai-sdk/openai")
    /// Explicit native dialect for SiliconFlow's documented OpenAI-style
    /// embeddings plus its dedicated `/rerank` API. It is intentionally not
    /// inferred from an arbitrary OpenAI-compatible URL.
    public static var siliconFlowV1: ProviderRequestAdapter {
        ProviderRequestAdapter(
            rawValue: IntatisHostApplication.identity
                .colonIdentifier("siliconflow-v1"))
    }
    /// Explicit native dialect for Cohere's v2 rerank API. A provider using
    /// this adapter can be Knowledge-only and need not expose Chat models.
    public static var cohereV2: ProviderRequestAdapter {
        ProviderRequestAdapter(
            rawValue: IntatisHostApplication.identity
                .colonIdentifier("cohere-v2"))
    }

    /// Missing adapter fields in previously persisted Intatis values decode to
    /// the pre-adapter request behavior. New OpenCode-shaped configuration must
    /// always freeze an explicit package instead.
    public static var legacyOpenAIWire: ProviderRequestAdapter {
        ProviderRequestAdapter(
            rawValue: IntatisHostApplication.identity
                .colonIdentifier("legacy-openai-wire"))
    }

    public let rawValue: String

    public init(rawValue: String) {
        // Package identity is configuration data, not a display label.
        // Preserve it byte-for-byte; an empty or whitespace-only explicit
        // value is unsupported and must fail closed instead of being fixed up.
        self.rawValue = rawValue
    }

    /// OpenCode's default for a custom provider when no provider/model npm
    /// package is configured.
    public static func configuredProvider(
        _ rawValue: String?
    ) -> ProviderRequestAdapter {
        guard let rawValue else {
            return .openAICompatible
        }
        // OpenCode uses nullish selection, not an empty-string fallback.
        // Preserve an explicitly empty value so it fails closed as an
        // unsupported package instead of silently changing adapter semantics.
        return ProviderRequestAdapter(rawValue: rawValue)
    }

    /// A model-level package is an override whenever the field is present.
    /// Only a missing (`nil`) field leaves the provider-level adapter in force.
    public static func configuredModelOverride(
        _ rawValue: String?
    ) -> ProviderRequestAdapter? {
        guard let rawValue else {
            return nil
        }
        // As above, an explicitly empty model package remains an exact
        // override and is rejected at the request boundary.
        return ProviderRequestAdapter(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ProviderChatCompletionsAdapter: Equatable {
    case legacyOpenAIWire
    case openAICompatible
    case openRouter
}

enum ProviderTranscriptionAdapter: Equatable {
    case openAICompatibleMultipart
    case openRouterJSONBase64
}

extension ProviderRequestAdapter {
    /// Resolves only adapters whose Chat Completions behavior is implemented by
    /// the native runtime. No package-name or endpoint-name fallback is used.
    func chatCompletionsAdapter()
        throws -> ProviderChatCompletionsAdapter
    {
        switch self {
        case .legacyOpenAIWire:
            return .legacyOpenAIWire
        case .openAICompatible:
            return .openAICompatible
        case .openRouter:
            return .openRouter
        case .siliconFlowV1:
            return .openAICompatible
        case .cohereV2:
            throw IntatisError.config(
                "the selected Cohere v2 adapter does not provide Chat completions")
        case .openAI:
            throw IntatisError.config(
                "the selected @ai-sdk/openai package adapter is not implemented by the native request runtime")
        default:
            throw IntatisError.config(
                "the selected provider npm adapter is not supported by the native runtime")
        }
    }

    /// Returns a hosted-search dialect only for exact, reviewed provider
    /// adapters. Callers must independently verify that the ordinary Chat
    /// adapter is executable and that the exact model declares the capability.
    func hostedWebSearchDialect() -> ChatHostedWebSearchDialect? {
        switch self {
        case .openAI:
            return .openAIResponses
        case .openRouter:
            return .openRouterServerTool
        case .legacyOpenAIWire,
             .openAICompatible:
            return nil
        default:
            return nil
        }
    }

    /// Selects the reviewed batch-transcription lowering for the exact package
    /// configured on the chosen model route. This deliberately does not infer
    /// a provider from a display name or URL.
    func transcriptionAdapter() throws -> ProviderTranscriptionAdapter {
        switch self {
        case .legacyOpenAIWire,
             .openAICompatible,
             .openAI,
             .siliconFlowV1:
            return .openAICompatibleMultipart
        case .openRouter:
            return .openRouterJSONBase64
        case .cohereV2:
            throw IntatisError.config(
                "the selected Cohere v2 adapter does not provide transcription")
        default:
            throw IntatisError.config(
                "the selected provider npm adapter is not supported by the transcription runtime")
        }
    }
}
