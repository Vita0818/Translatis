import Foundation
import IntatisCore
import IntatisProtocol

/// The provider-facing shape of a tool definition.
///
/// `function` preserves the original Chat Completions function-tool encoding.
/// `namespace` and `toolSearch` model the Responses API shapes used by Codex
/// for deferred tools. Providers that do not advertise those capabilities
/// must fail closed before constructing a request; they must not silently
/// flatten a namespace or turn `tool_search` into an unrelated function.
public enum ToolSpecKind: String, Codable, Equatable, Sendable {
    case function
    case namespace
    case toolSearch = "tool_search"
}

/// A tool the model may call. `parameters` is a JSON-Schema object.
///
/// The additional fields are intentionally additive. Old decoded values
/// become ordinary function tools with their historical wire representation.
public struct ToolSpec: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var kind: ToolSpecKind
    public var strict: Bool?
    public var deferLoading: Bool?
    public var outputSchema: JSONValue?
    public var supportsParallelCalls: Bool
    public var execution: String?
    public var namespaceTools: [ToolSpec]

    public init(name: String,
                description: String,
                parameters: JSONValue,
                kind: ToolSpecKind = .function,
                strict: Bool? = nil,
                deferLoading: Bool? = nil,
                outputSchema: JSONValue? = nil,
                supportsParallelCalls: Bool = false,
                execution: String? = nil,
                namespaceTools: [ToolSpec] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.kind = kind
        self.strict = strict
        self.deferLoading = deferLoading
        self.outputSchema = outputSchema
        self.supportsParallelCalls = supportsParallelCalls
        self.execution = execution
        self.namespaceTools = namespaceTools
    }

    public static func namespace(
        name: String,
        description: String,
        tools: [ToolSpec]
    ) -> ToolSpec {
        ToolSpec(
            name: name,
            description: description,
            parameters: .object([:]),
            kind: .namespace,
            namespaceTools: tools)
    }

    public static func toolSearch(
        description: String,
        parameters: JSONValue,
        execution: String = "client"
    ) -> ToolSpec {
        ToolSpec(
            name: "tool_search",
            description: description,
            parameters: parameters,
            kind: .toolSearch,
            supportsParallelCalls: true,
            execution: execution)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
        case kind
        case strict
        case deferLoading
        case outputSchema
        case supportsParallelCalls
        case execution
        case namespaceTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        parameters = try container.decode(JSONValue.self, forKey: .parameters)
        kind = try container.decodeIfPresent(ToolSpecKind.self, forKey: .kind)
            ?? .function
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict)
        deferLoading = try container.decodeIfPresent(
            Bool.self,
            forKey: .deferLoading)
        outputSchema = try container.decodeIfPresent(
            JSONValue.self,
            forKey: .outputSchema)
        supportsParallelCalls = try container.decodeIfPresent(
            Bool.self,
            forKey: .supportsParallelCalls) ?? false
        execution = try container.decodeIfPresent(
            String.self,
            forKey: .execution)
        namespaceTools = try container.decodeIfPresent(
            [ToolSpec].self,
            forKey: .namespaceTools) ?? []
    }
}

/// A fully-assembled tool call from the model.
public enum ToolCallKind: String, Codable, Equatable, Sendable {
    case function
    case toolSearch = "tool_search"
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String   // raw JSON string
    public var kind: ToolCallKind
    /// Responses namespace for a deferred function call. `name` remains the
    /// exact flat ToolRegistry routing name.
    public var namespace: String?
    public var status: String?
    public var execution: String?

    public init(id: String,
                name: String,
                arguments: String,
                kind: ToolCallKind = .function,
                namespace: String? = nil,
                status: String? = nil,
                execution: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.kind = kind
        self.namespace = namespace
        self.status = status
        self.execution = execution
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case arguments
        case kind
        case namespace
        case status
        case execution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decode(String.self, forKey: .arguments)
        kind = try container.decodeIfPresent(
            ToolCallKind.self,
            forKey: .kind) ?? .function
        namespace = try container.decodeIfPresent(
            String.self,
            forKey: .namespace)
        status = try container.decodeIfPresent(
            String.self,
            forKey: .status)
        execution = try container.decodeIfPresent(
            String.self,
            forKey: .execution)
    }
}

public enum AgentRole: String, Codable, Sendable {
    case system, developer, user, assistant, tool
}

/// A message in the tool-calling conversation. Assistant messages may carry
/// `toolCalls`; tool messages carry `toolCallId` + the observation as `content`.
public struct AgentMessage: Equatable, Sendable {
    public var role: AgentRole
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var images: [ImageAttachment]
    public var toolSearchOutput: ModelToolSearchOutput?

    public init(role: AgentRole, content: String? = nil,
                toolCalls: [ToolCall]? = nil, toolCallId: String? = nil,
                images: [ImageAttachment] = [],
                toolSearchOutput: ModelToolSearchOutput? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.images = images
        self.toolSearchOutput = toolSearchOutput
    }

    public static func system(_ text: String) -> AgentMessage { .init(role: .system, content: text) }
    public static func developer(_ text: String) -> AgentMessage {
        .init(role: .developer, content: text)
    }
    public static func user(_ text: String, images: [ImageAttachment] = []) -> AgentMessage {
        .init(role: .user, content: text, images: images)
    }
    public static func assistant(_ text: String) -> AgentMessage { .init(role: .assistant, content: text) }
    public static func assistant(toolCalls: [ToolCall], content: String? = nil) -> AgentMessage {
        .init(role: .assistant, content: content, toolCalls: toolCalls)
    }
    public static func tool(
        id: String,
        content: String,
        images: [ImageAttachment] = []
    ) -> AgentMessage {
        .init(
            role: .tool,
            content: content,
            toolCallId: id,
            images: images)
    }
    public static func toolSearchOutput(
        id: String,
        output: ModelToolSearchOutput
    ) -> AgentMessage {
        .init(
            role: .tool,
            toolCallId: id,
            toolSearchOutput: output)
    }
}

/// Provider-facing Responses input items. This keeps native call/output
/// history distinct from Chat Completions messages and, critically, preserves
/// `tool_search_output.tools` in history instead of mutating the top-level
/// request tool list.
public enum AgentInputItem: Equatable, Sendable {
    case message(
        role: AgentRole,
        content: String?,
        images: [ImageAttachment])
    case functionCall(ToolCall)
    case functionCallOutput(
        callID: String,
        output: String,
        images: [ImageAttachment] = [])
    case toolSearchCall(
        callID: String,
        status: String?,
        execution: String,
        arguments: JSONValue)
    case toolSearchOutput(
        callID: String,
        status: String,
        execution: String,
        tools: [JSONValue])

    public static func from(
        messages: [AgentMessage]
    ) -> [AgentInputItem] {
        var items: [AgentInputItem] = []
        for message in messages {
            if let output = message.toolSearchOutput,
               let callID = message.toolCallId {
                items.append(.toolSearchOutput(
                    callID: callID,
                    status: output.status,
                    execution: output.execution,
                    tools: output.tools))
                continue
            }

            if message.role == .tool,
               let callID = message.toolCallId {
                items.append(.functionCallOutput(
                    callID: callID,
                    output: message.content ?? "",
                    images: message.images))
                continue
            }

            if message.content != nil || !message.images.isEmpty {
                items.append(.message(
                    role: message.role,
                    content: message.content,
                    images: message.images))
            }
            for call in message.toolCalls ?? [] {
                switch call.kind {
                case .function:
                    items.append(.functionCall(call))
                case .toolSearch:
                    let arguments = Self.argumentsJSON(call.arguments)
                    items.append(.toolSearchCall(
                        callID: call.id,
                        status: call.status,
                        execution: call.execution ?? "client",
                        arguments: arguments))
                }
            }
        }
        return items
    }

    private static func argumentsJSON(_ raw: String) -> JSONValue {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  JSONValue.self,
                  from: data) else {
            return .object([:])
        }
        return value
    }
}

public struct AgentRequest: Sendable {
    public var model: ModelID
    public var messages: [AgentMessage]
    public var tools: [ToolSpec]
    /// Explicit Responses input. When nil, the adapter derives it from
    /// `messages`, preserving legacy call sites and Chat Completions behavior.
    public var inputItems: [AgentInputItem]?
    public var temperature: Double?
    public var reasoningEffort: ReasoningEffort?
    public var includeUsage: Bool
    /// OpenAI's request-wide parallel tool-call switch. Per-tool capability is
    /// still retained in `ToolSpec` for host routing and parity assertions.
    public var parallelToolCalls: Bool?
    /// Best-effort provider-side output ceiling. OpenAI-compatible providers map
    /// this to `max_tokens`; providers that do not support a ceiling may ignore it,
    /// so callers must still account the reported/estimated total after the stream.
    public var maxOutputTokens: Int?
    public init(model: ModelID, messages: [AgentMessage], tools: [ToolSpec],
                inputItems: [AgentInputItem]? = nil,
                temperature: Double? = nil,
                reasoningEffort: ReasoningEffort? = nil,
                includeUsage: Bool = false,
                parallelToolCalls: Bool? = nil,
                maxOutputTokens: Int? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.inputItems = inputItems
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.parallelToolCalls = parallelToolCalls
        self.maxOutputTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
    }

    public var effectiveInputItems: [AgentInputItem] {
        inputItems ?? AgentInputItem.from(messages: messages)
    }

    var requiresToolSearchCapability: Bool {
        if tools.contains(where: { $0.kind != .function }) {
            return true
        }
        return effectiveInputItems.contains { item in
            switch item {
            case .toolSearchCall, .toolSearchOutput:
                return true
            case .message, .functionCall, .functionCallOutput:
                return false
            }
        }
    }

    var containsUserImageInput: Bool {
        effectiveInputItems.contains { item in
            guard case .message(let role, _, let images) = item else {
                return false
            }
            return role == .user && !images.isEmpty
        }
    }

    var containsFunctionOutputImageInput: Bool {
        effectiveInputItems.contains { item in
            guard case .functionCallOutput(_, _, let images) = item else {
                return false
            }
            return !images.isEmpty
        }
    }

    public var requiresResponsesAPI: Bool {
        requiresToolSearchCapability
            || containsUserImageInput
            || containsFunctionOutputImageInput
    }
}

/// One piece of a streaming tool-calling response.
public enum AgentChunk: Equatable, Sendable {
    case textDelta(String)
    case toolCalls([ToolCall])
    case usage(Usage)
    case done(finishReason: String?)
}

/// Provider/model features already resolved for one exact inference route.
///
/// `supportsToolSearch` is deliberately a combined contract. It may be true
/// only when both the selected model understands the Responses `tool_search`
/// item and the selected provider route supports namespaced Responses tools.
/// This mirrors Codex's model-capability + provider-capability conjunction
/// without letting AgentKernel guess from a model name or endpoint URL.
public struct ToolCallingProviderCapabilities: Equatable, Sendable {
    public let supportsToolSearch: Bool
    public let supportsUserImageInput: Bool
    public let supportsFunctionOutputImageInput: Bool

    public init(
        supportsToolSearch: Bool = false,
        supportsUserImageInput: Bool = false,
        supportsFunctionOutputImageInput: Bool = false
    ) {
        self.supportsToolSearch = supportsToolSearch
        self.supportsUserImageInput = supportsUserImageInput
        self.supportsFunctionOutputImageInput =
            supportsFunctionOutputImageInput
    }

    public static let chatCompletionsOnly =
        ToolCallingProviderCapabilities()
    public static let responsesToolSearch =
        ToolCallingProviderCapabilities(
            supportsToolSearch: true)
}

public enum ToolCallingProviderCapabilityError:
    Error, Equatable, Sendable, LocalizedError
{
    case toolSearchUnsupported
    case userImageInputUnsupported
    case functionOutputImageInputUnsupported

    public var errorDescription: String? {
        switch self {
        case .toolSearchUnsupported:
            return "The selected model/provider route does not support the Responses tool_search contract."
        case .userImageInputUnsupported:
            return "The selected model/provider route does not support user image input."
        case .functionOutputImageInputUnsupported:
            return "The selected model/provider route does not support function-output image input."
        }
    }
}

/// A model that supports tool/function calling (`Capability.tool_calling`).
public protocol ToolCallingProvider: Sendable {
    /// Exact, route-scoped feature declaration. Implementations that do not
    /// opt in remain Chat-Completions-only.
    var toolCallingCapabilities: ToolCallingProviderCapabilities { get }

    /// Must return a request-owned stream promptly. Implementations perform
    /// network/blocking work in the stream producer, keep continuations scoped
    /// to this request, and propagate consumer termination to that producer.
    /// Synchronously blocking this method is outside the provider contract.
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error>
}

public extension ToolCallingProvider {
    var toolCallingCapabilities: ToolCallingProviderCapabilities {
        .chatCompletionsOnly
    }
}
