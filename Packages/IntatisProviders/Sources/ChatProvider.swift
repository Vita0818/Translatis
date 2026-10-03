import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// An image attached to a message (vision input). `url` is either a remote URL
/// or a `data:<mime>;base64,...` URL for a local file.
public struct ImageAttachment: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
    public static func base64(mime: String, base64: String) -> ImageAttachment {
        ImageAttachment(url: "data:\(mime);base64,\(base64)")
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: ChatRole
    public var content: String
    public var images: [ImageAttachment]
    public init(role: ChatRole, content: String, images: [ImageAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// Reasoning/thinking effort for reasoning models (OpenAI o-series / gpt-5 style
/// `reasoning_effort`). Sent on the wire only when set, so non-reasoning models
/// and endpoints that don't support it are unaffected.
public enum ReasoningEffort: String, Codable, Sendable {
    case minimal, low, medium, high
}

/// The reviewed provider-specific hosted-search request shape for one exact
/// Chat route. Compatible/custom endpoints do not inherit a dialect merely
/// because they use an OpenAI-shaped wire.
public enum ChatHostedWebSearchDialect: Equatable, Sendable {
    case openAIResponses
    case openRouterServerTool
}

/// Hosted web-search options for a chat request. This is provider-side search,
/// not an Intatis local tool, so the iOS Chat subset keeps its no-tools boundary.
public struct ChatWebSearchConfiguration: Equatable, Sendable {
    public enum ContextSize: String, Equatable, Sendable {
        case low, medium, high
    }

    /// Chat may preserve its transparent-search behavior by retrying one
    /// ordinary request when an endpoint rejects the hosted-search shape.
    /// Explicit agent tools must fail closed instead of returning an ordinary
    /// model answer under a successful search-tool result.
    public enum UnsupportedBehavior: Equatable, Sendable {
        case retryOrdinaryChat
        case failClosed
    }

    public enum ToolChoice: String, Equatable, Sendable {
        case automatic = "auto"
        case required
    }

    public var dialect: ChatHostedWebSearchDialect
    public var contextSize: ContextSize
    public var unsupportedBehavior: UnsupportedBehavior
    public var toolChoice: ToolChoice

    public init(dialect: ChatHostedWebSearchDialect,
                contextSize: ContextSize = .medium,
                unsupportedBehavior: UnsupportedBehavior = .retryOrdinaryChat,
                toolChoice: ToolChoice = .automatic) {
        self.dialect = dialect
        self.contextSize = contextSize
        self.unsupportedBehavior = unsupportedBehavior
        self.toolChoice = toolChoice
    }
}

/// Token usage reported by the endpoint (when available).
public struct Usage: Equatable, Sendable {
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var contextWindowTokens: Int?
    public init(promptTokens: Int? = nil,
                cachedPromptTokens: Int? = nil,
                completionTokens: Int? = nil,
                totalTokens: Int? = nil,
                contextWindowTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.contextWindowTokens = contextWindowTokens
    }
}

public extension Usage {
    /// Merge usage chunks from the same provider response. Later non-nil fields
    /// win, while nil fields do not erase values reported by earlier chunks.
    static func merging(_ current: Usage?, with update: Usage) -> Usage {
        current?.merged(with: update) ?? update
    }

    /// Add usage totals from separate provider requests, such as each turn in a
    /// tool-calling loop.
    static func adding(_ current: Usage?, _ increment: Usage?) -> Usage? {
        guard let increment else { return current }
        guard let current else { return increment }
        return current.adding(increment)
    }

    func merged(with update: Usage) -> Usage {
        Usage(
            promptTokens: update.promptTokens ?? promptTokens,
            cachedPromptTokens: update.cachedPromptTokens ?? cachedPromptTokens,
            completionTokens: update.completionTokens ?? completionTokens,
            totalTokens: update.totalTokens ?? totalTokens,
            contextWindowTokens: update.contextWindowTokens ?? contextWindowTokens)
    }

    func adding(_ other: Usage) -> Usage {
        Usage(
            promptTokens: Self.add(promptTokens, other.promptTokens),
            cachedPromptTokens: Self.add(cachedPromptTokens, other.cachedPromptTokens),
            completionTokens: Self.add(completionTokens, other.completionTokens),
            totalTokens: Self.add(totalTokens, other.totalTokens),
            contextWindowTokens: contextWindowTokens ?? other.contextWindowTokens)
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return l + r
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        case (nil, nil):
            return nil
        }
    }
}

public struct ChatRequest: Equatable, Sendable {
    public var model: ModelID
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var reasoningEffort: ReasoningEffort?
    /// Ask the endpoint to report token usage (OpenAI `stream_options.include_usage`).
    public var includeUsage: Bool
    public var stream: Bool
    /// When present, the adapter uses the Responses API with hosted web search.
    public var webSearch: ChatWebSearchConfiguration?
    public init(model: ModelID, messages: [ChatMessage], temperature: Double? = nil,
                reasoningEffort: ReasoningEffort? = nil, includeUsage: Bool = false,
                stream: Bool = true, webSearch: ChatWebSearchConfiguration? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.stream = stream
        self.webSearch = webSearch
    }
}

/// One piece of a streaming chat response.
public enum ChatChunk: Equatable, Sendable {
    case delta(String)
    case citation(MessageCitation)
    case usage(Usage)
    case done
}

/// A model that can stream a chat completion. The only `Capability.chat` surface
/// v0.1 needs. Concrete adapters (e.g. `OpenAIWireProvider`) conform per wire.
///
/// `stream(_:)` must return promptly with a request-owned stream. Conformers
/// must move blocking network/provider work into that stream's producer and
/// propagate consumer termination to the producer. Synchronously blocking in
/// this method is outside the protocol contract: Chat hosts use the return as
/// the request-dispatch boundary for cancellation, timeout, and attempt
/// accounting. Propagation is cooperative and does not imply that an arbitrary
/// transport can physically stop remote work instantaneously.
public protocol ChatProvider: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>
}

/// Transport seam so adapters are testable without a network. The real
/// implementation (`URLSessionStreamingClient`) lives in OpenAIWireProvider.swift;
/// tests inject a fake that replays canned bytes.
public protocol HTTPByteStreaming: Sendable {
    /// Performs `request` and yields the response body as it arrives. Each yielded
    /// `Data` is an arbitrary slice of the body — the SSE parser re-frames lines.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}
