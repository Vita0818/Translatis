import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisProviders
import MCP

public enum MCPProviderSamplingInferenceError:
    Error, LocalizedError, Sendable {
    case unsupportedAudio
    case malformedValue
    case providerReturnedNoTerminal

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudio:
            return "The selected provider cannot receive MCP sampling audio content."
        case .malformedValue:
            return "The MCP sampling value could not be converted safely."
        case .providerReturnedNoTerminal:
            return "The sampling provider ended without a completion marker."
        }
    }
}

/// Provider-neutral sampling bridge. It submits only the approved sampling
/// payload and exact inference binding; it has no AgentLoop, ToolRegistry,
/// workspace, conversation history, or access to another MCP server.
public struct MCPProviderSamplingInferenceService:
    MCPSamplingInferenceService, Sendable {
    public typealias Resolver =
        @Sendable (AgentInferenceBinding) async throws
            -> ResolvedInferenceProfile

    private let resolve: Resolver

    public init(resolve: @escaping Resolver) {
        self.resolve = resolve
    }

    public func createSamplingMessage(
        parameters: CreateSamplingMessage.Parameters,
        inferenceBinding: AgentInferenceBinding
    ) async throws -> CreateSamplingMessage.Result {
        let resolved = try await resolve(inferenceBinding)
        guard resolved.binding == inferenceBinding,
              resolved.model == inferenceBinding.modelID else {
            throw IntatisError.config(
                "MCP sampling inference resolution did not match the approved exact binding.")
        }
        var messages: [AgentMessage] = []
        if let systemPrompt = parameters.systemPrompt,
           !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }
        for message in parameters.messages {
            messages.append(contentsOf:
                try Self.convert(message))
        }
        let tools = try (parameters.tools ?? []).map {
            ToolSpec(
                name: $0.name,
                description: $0.description ?? $0.title ?? "",
                parameters: try Self.protocolJSONValue(
                    $0.inputSchema),
                strict: false,
                outputSchema: nil,
                supportsParallelCalls: true)
        }
        var request = AgentRequest(
            model: resolved.model,
            messages: messages,
            tools: tools,
            temperature: parameters.temperature,
            reasoningEffort: nil,
            includeUsage: false,
            parallelToolCalls:
                tools.isEmpty ? nil : true,
            maxOutputTokens: parameters.maxTokens)
        // The server's provider-specific metadata, model hints, and context
        // inclusion request are untrusted hints and are deliberately not
        // forwarded to a provider adapter.
        request.inputItems = AgentInputItem.from(
            messages: messages)

        var text = ""
        var toolCalls: [ToolCall] = []
        var finishReason: String?
        var receivedTerminal = false
        for try await chunk in resolved.provider.stream(request) {
            try Task.checkCancellation()
            switch chunk {
            case .textDelta(let delta):
                text += delta
            case .toolCalls(let calls):
                toolCalls.append(contentsOf: calls)
            case .usage:
                break
            case .done(let reason):
                receivedTerminal = true
                finishReason = reason
            }
        }
        guard receivedTerminal else {
            throw MCPProviderSamplingInferenceError
                .providerReturnedNoTerminal
        }
        var blocks:
            [Sampling.Message.Content.ContentBlock] = []
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        for call in toolCalls {
            let value = try Self.mcpValue(
                try Self.arguments(call.arguments))
            guard case .object(let object) = value else {
                throw MCPProviderSamplingInferenceError
                    .malformedValue
            }
            blocks.append(.toolUse(.init(
                id: call.id,
                name: call.name,
                input: object)))
        }
        let content: Sampling.Message.Content
        if blocks.count == 1, let first = blocks.first {
            content = .single(first)
        } else {
            content = .multiple(blocks)
        }
        return CreateSamplingMessage.Result(
            model: resolved.model.rawValue,
            stopReason:
                toolCalls.isEmpty
                    ? Self.stopReason(finishReason)
                    : .toolUse,
            role: .assistant,
            content: content)
    }

    private static func convert(
        _ message: Sampling.Message
    ) throws -> [AgentMessage] {
        var textParts: [String] = []
        var images: [ImageAttachment] = []
        var calls: [ToolCall] = []
        var toolResults: [AgentMessage] = []
        for block in message.content.asArray {
            switch block {
            case .text(let text):
                textParts.append(text)
            case .image(let data, let mimeType):
                images.append(.base64(
                    mime: mimeType,
                    base64: data))
            case .audio:
                throw MCPProviderSamplingInferenceError
                    .unsupportedAudio
            case .toolUse(let use):
                let arguments = try jsonString(
                    try protocolJSONValue(
                        .object(use.input)))
                calls.append(ToolCall(
                    id: use.id,
                    name: use.name,
                    arguments: arguments))
            case .toolResult(let result):
                let encoded = try JSONEncoder().encode(
                    result)
                let value = try JSONDecoder().decode(
                    IntatisProtocol.JSONValue.self,
                    from: encoded)
                toolResults.append(.tool(
                    id: result.toolUseId,
                    content: try jsonString(value)))
            }
        }
        let joined = textParts.joined(separator: "\n")
        var result: [AgentMessage] = []
        switch message.role {
        case .user:
            if !joined.isEmpty || !images.isEmpty {
                result.append(.user(
                    joined,
                    images: images))
            }
            result.append(contentsOf: toolResults)
            if !calls.isEmpty {
                throw MCPProviderSamplingInferenceError
                    .malformedValue
            }
        case .assistant:
            guard images.isEmpty,
                  toolResults.isEmpty else {
                throw MCPProviderSamplingInferenceError
                    .malformedValue
            }
            if !calls.isEmpty {
                result.append(.assistant(
                    toolCalls: calls,
                    content: joined.isEmpty
                        ? nil : joined))
            } else {
                result.append(.assistant(joined))
            }
        }
        return result
    }

    private static func arguments(
        _ raw: String
    ) throws -> JSONValue {
        guard let data = raw.data(using: .utf8) else {
            throw MCPProviderSamplingInferenceError
                .malformedValue
        }
        return try JSONDecoder().decode(
            IntatisProtocol.JSONValue.self,
            from: data)
    }

    private static func jsonString(
        _ value: JSONValue
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(value)
        guard let result = String(
            data: data,
            encoding: .utf8) else {
            throw MCPProviderSamplingInferenceError
                .malformedValue
        }
        return result
    }

    private static func protocolJSONValue(
        _ value: Value
    ) throws -> IntatisProtocol.JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(
            IntatisProtocol.JSONValue.self,
            from: data)
    }

    private static func mcpValue(
        _ value: IntatisProtocol.JSONValue
    ) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(
            Value.self,
            from: data)
    }

    private static func stopReason(
        _ reason: String?
    ) -> Sampling.StopReason {
        switch reason {
        case "length":
            return .maxTokens
        case "stop", nil:
            return .endTurn
        default:
            return Sampling.StopReason(
                rawValue: reason ?? "endTurn")
        }
    }
}
