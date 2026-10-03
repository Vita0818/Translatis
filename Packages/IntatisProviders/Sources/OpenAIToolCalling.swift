import Foundation
import IntatisCore
import IntatisProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Streaming DTOs (internal)

private struct OAAgentStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let tool_calls: [ToolCallFragment]?
        }
        struct ToolCallFragment: Decodable {
            struct Fn: Decodable {
                let name: String?
                let arguments: String?

                enum CodingKeys: String, CodingKey {
                    case name
                    case arguments
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decodeIfPresent(String.self, forKey: .name)
                    if let stringArguments = try? container.decodeIfPresent(String.self, forKey: .arguments) {
                        arguments = stringArguments
                    } else if container.contains(.arguments) {
                        let value = try container.decode(JSONValue.self, forKey: .arguments)
                        arguments = try Self.argumentString(from: value)
                    } else {
                        arguments = nil
                    }
                }

                private static func argumentString(from value: JSONValue) throws -> String? {
                    if value == .null { return nil }
                    let data = try JSONEncoder().encode(value)
                    return String(data: data, encoding: .utf8)
                }
            }
            let index: Int?
            let id: String?
            let function: Fn?

            enum CodingKeys: String, CodingKey {
                case index
                case id
                case function
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let intIndex = try? container.decodeIfPresent(Int.self, forKey: .index) {
                    index = intIndex
                } else if let stringIndex = try? container.decodeIfPresent(String.self, forKey: .index),
                          let parsed = Int(stringIndex) {
                    index = parsed
                } else {
                    index = nil
                }
                id = try container.decodeIfPresent(String.self, forKey: .id)
                function = try container.decodeIfPresent(Fn.self, forKey: .function)
            }
        }
        let index: Int?
        let delta: Delta?
        let finish_reason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finish_reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let intIndex = try? container.decodeIfPresent(Int.self, forKey: .index) {
                index = intIndex
            } else if let stringIndex = try? container.decodeIfPresent(String.self, forKey: .index),
                      let parsed = Int(stringIndex) {
                index = parsed
            } else {
                index = nil
            }
            delta = try container.decodeIfPresent(Delta.self, forKey: .delta)
            finish_reason = try container.decodeIfPresent(String.self, forKey: .finish_reason)
        }
    }
    struct UsageDTO: Decodable {
        struct PromptTokensDetailsDTO: Decodable {
            let cached_tokens: Int?
        }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: PromptTokensDetailsDTO?

        var usage: Usage {
            Usage(promptTokens: prompt_tokens,
                  cachedPromptTokens: prompt_tokens_details?.cached_tokens,
                  completionTokens: completion_tokens,
                  totalTokens: total_tokens)
        }
    }
    let choices: [Choice]?
    let usage: UsageDTO?
}

private struct ToolCallAccum {
    var id = ""
    var name = ""
    var args = ""
}

private struct ToolCallAccumKey: Comparable, Hashable {
    var choiceIndex: Int
    var toolIndex: Int

    static func < (lhs: ToolCallAccumKey, rhs: ToolCallAccumKey) -> Bool {
        if lhs.choiceIndex != rhs.choiceIndex {
            return lhs.choiceIndex < rhs.choiceIndex
        }
        return lhs.toolIndex < rhs.toolIndex
    }
}

private func preferredToolFinishReason(_ current: String?, _ candidate: String) -> String {
    if candidate == "tool_calls" || candidate == "function_call" {
        return candidate
    }
    return current ?? candidate
}

private func validatedToolCallArguments(_ arguments: String,
                                        key: ToolCallAccumKey,
                                        reason: String) throws -> String {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return arguments }
    guard let data = trimmed.data(using: .utf8) else {
        throw ProviderErrorFormatting.invalidToolCallStream(
            "The provider finished with \(reason) but emitted non-UTF-8 arguments for choice/tool index \(key.choiceIndex):\(key.toolIndex).")
    }
    do {
        _ = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        throw ProviderErrorFormatting.invalidToolCallStream(
            "The provider finished with \(reason) but emitted invalid JSON arguments for choice/tool index \(key.choiceIndex):\(key.toolIndex).")
    }
    return arguments
}

// MARK: - ToolCallingProvider conformance

extension OpenAIWireProvider: ToolCallingProvider {

    public func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        if let capabilityError = toolCallingCapabilityError(
            for: request)
        {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: capabilityError)
            }
        }
        if request.requiresResponsesAPI {
            return streamResponses(request)
        }
        return streamChatCompletions(request)
    }

    private func toolCallingCapabilityError(
        for request: AgentRequest
    ) -> ToolCallingProviderCapabilityError? {
        if request.requiresToolSearchCapability,
           !toolCallingCapabilities.supportsToolSearch {
            return .toolSearchUnsupported
        }
        if request.containsUserImageInput,
           !toolCallingCapabilities.supportsUserImageInput {
            return .userImageInputUnsupported
        }
        if request.containsFunctionOutputImageInput,
           !toolCallingCapabilities
            .supportsFunctionOutputImageInput {
            return .functionOutputImageInputUnsupported
        }
        return nil
    }

    private func streamChatCompletions(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildAgentRequest(request)
                    var attempt = 1

                    while true {
                        let parser = SSEParser()
                        var acc: [ToolCallAccumKey: ToolCallAccum] = [:]
                        var finished = false
                        var deliveredSemanticOutput = false

                        func handle(_ payload: String) throws -> Bool {
                            if payload == "[DONE]" {
                                if !finished {
                                    deliveredSemanticOutput = true
                                    continuation.yield(.done(finishReason: nil))
                                    finished = true
                                }
                                continuation.finish()
                                return true
                            }
                            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                                return false
                            }
                            if let providerError = ProviderErrorFormatting.streamErrorPayload(data) {
                                throw providerError
                            }
                            let chunk: OAAgentStreamChunk
                            do {
                                chunk = try JSONDecoder().decode(OAAgentStreamChunk.self, from: data)
                            } catch {
                                throw ProviderErrorFormatting.invalidStreamPayload(trimmed, underlying: error)
                            }
                            if let u = chunk.usage {
                                deliveredSemanticOutput = true
                                continuation.yield(.usage(u.usage))
                            }
                            var finishReason: String?
                            if let choices = chunk.choices {
                                for (choiceOffset, choice) in choices.enumerated() {
                                    let choiceIndex = choice.index ?? choiceOffset
                                    if let content = choice.delta?.content, !content.isEmpty {
                                        deliveredSemanticOutput = true
                                        continuation.yield(.textDelta(content))
                                    }
                                    if let frags = choice.delta?.tool_calls {
                                        for (toolOffset, f) in frags.enumerated() {
                                            let key = ToolCallAccumKey(choiceIndex: choiceIndex,
                                                                       toolIndex: f.index ?? toolOffset)
                                            var e = acc[key] ?? ToolCallAccum()
                                            if let id = f.id { e.id = id }
                                            if let fn = f.function {
                                                if let n = fn.name { e.name = n }
                                                if let a = fn.arguments { e.args += a }
                                            }
                                            acc[key] = e
                                        }
                                    }
                                    if let reason = choice.finish_reason {
                                        finishReason = preferredToolFinishReason(finishReason, reason)
                                    }
                                }
                            }
                            if let reason = finishReason, !finished {
                                let toolCallKeys = acc.keys.sorted()
                                let incomplete = toolCallKeys.filter { key in
                                    guard let entry = acc[key] else { return true }
                                    return entry.name.isEmpty
                                }
                                if reason == "tool_calls" || reason == "function_call" {
                                    if toolCallKeys.isEmpty {
                                        throw ProviderErrorFormatting.invalidToolCallStream(
                                            "The provider finished with \(reason) but did not emit any tool call deltas.")
                                    }
                                }
                                if !incomplete.isEmpty {
                                    let indexes = incomplete
                                        .map { "\($0.choiceIndex):\($0.toolIndex)" }
                                        .joined(separator: ", ")
                                    throw ProviderErrorFormatting.invalidToolCallStream(
                                        "The provider finished with \(reason) but omitted tool names for choice/tool index \(indexes).")
                                }
                                let calls: [ToolCall] = try toolCallKeys.map { key in
                                    guard let e = acc[key], !e.name.isEmpty else {
                                        throw ProviderErrorFormatting.invalidToolCallStream(
                                            "The provider finished with \(reason) but omitted tool names for choice/tool index \(key.choiceIndex):\(key.toolIndex).")
                                    }
                                    let fallbackID = key.choiceIndex == 0
                                        ? "call_\(key.toolIndex)"
                                        : "call_\(key.choiceIndex)_\(key.toolIndex)"
                                    let arguments = try validatedToolCallArguments(e.args, key: key, reason: reason)
                                    return ToolCall(id: e.id.isEmpty ? fallbackID : e.id,
                                                    name: e.name, arguments: arguments)
                                }
                                if !calls.isEmpty {
                                    deliveredSemanticOutput = true
                                    continuation.yield(.toolCalls(calls))
                                }
                                deliveredSemanticOutput = true
                                continuation.yield(.done(finishReason: reason))
                                finished = true
                            }
                            return false
                        }

                        do {
                            for try await chunk in http.stream(urlRequest) {
                                for payload in parser.consume(chunk) {
                                    if try handle(payload) { return }
                                }
                            }
                            for payload in parser.flush() {
                                if try handle(payload) { return }
                            }
                            guard finished else {
                                continuation.finish(throwing: ProviderErrorFormatting.incompleteStream(
                                    operation: "tool-calling streaming request"))
                                return
                            }
                            continuation.finish()
                            return
                        } catch {
                            if ProviderRuntime.shouldRetry(error: error,
                                                           attempt: attempt,
                                                           policy: runtimePolicy,
                                                           deliveredSemanticOutput: deliveredSemanticOutput) {
                                attempt += 1
                                try await ProviderRuntime.sleepBeforeRetry(
                                    nextAttempt: attempt,
                                    policy: runtimePolicy,
                                    retryHint: ProviderErrorFormatting.retryHint(from: error))
                                continue
                            }
                            continuation.finish(throwing: ProviderRuntime.exhausted(
                                error,
                                attempts: attempt,
                                operation: "tool-calling streaming request"))
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: ProviderErrorFormatting.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamResponses(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildResponsesAgentRequest(request)
                    var attempt = 1

                    while true {
                        let parser = SSEParser()
                        var completed = false
                        var deliveredSemanticOutput = false
                        var emittedText = ""

                        func handle(_ payload: String) throws -> Bool {
                            if payload == "[DONE]" {
                                guard completed else {
                                    throw ProviderErrorFormatting
                                        .incompleteStream(
                                            operation:
                                                "Responses tool-calling streaming request")
                                }
                                continuation.finish()
                                return true
                            }
                            let trimmed = payload.trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty,
                                  let data = trimmed.data(using: .utf8)
                            else {
                                return false
                            }
                            if let providerError =
                                ProviderErrorFormatting
                                    .streamErrorPayload(data) {
                                throw providerError
                            }
                            let value: JSONValue
                            do {
                                value = try JSONDecoder().decode(
                                    JSONValue.self,
                                    from: data)
                            } catch {
                                throw ProviderErrorFormatting
                                    .invalidStreamPayload(
                                        trimmed,
                                        underlying: error)
                            }
                            guard case .object(let event) = value,
                                  case .string(let eventType)? =
                                    event["type"] else {
                                throw IntatisError.decoding(
                                    "Responses stream event is missing its type.")
                            }

                            switch eventType {
                            case "response.output_text.delta":
                                if case .string(let delta)? = event["delta"],
                                   !delta.isEmpty {
                                    emittedText += delta
                                    deliveredSemanticOutput = true
                                    continuation.yield(.textDelta(delta))
                                }

                            case "response.output_item.done":
                                guard case .object(let item)? =
                                        event["item"],
                                      case .string(let itemType)? =
                                        item["type"] else {
                                    throw IntatisError.decoding(
                                        "Responses output_item.done is missing a typed item.")
                                }
                                switch itemType {
                                case "function_call":
                                    let call = try Self.responsesFunctionCall(
                                        item)
                                    deliveredSemanticOutput = true
                                    continuation.yield(.toolCalls([call]))
                                case "tool_search_call":
                                    let call = try Self.responsesToolSearchCall(
                                        item)
                                    deliveredSemanticOutput = true
                                    continuation.yield(.toolCalls([call]))
                                case "message":
                                    let fullText =
                                        Self.responsesMessageText(item)
                                    if !fullText.isEmpty,
                                       fullText.hasPrefix(emittedText) {
                                        let suffix = String(
                                            fullText.dropFirst(
                                                emittedText.count))
                                        if !suffix.isEmpty {
                                            emittedText += suffix
                                            deliveredSemanticOutput = true
                                            continuation.yield(
                                                .textDelta(suffix))
                                        }
                                    } else if emittedText.isEmpty,
                                              !fullText.isEmpty {
                                        emittedText = fullText
                                        deliveredSemanticOutput = true
                                        continuation.yield(
                                            .textDelta(fullText))
                                    }
                                default:
                                    break
                                }

                            case "response.completed":
                                guard case .object(let response)? =
                                        event["response"],
                                      case .string(let responseID)? =
                                        response["id"],
                                      !responseID.isEmpty else {
                                    throw IntatisError.decoding(
                                        "Responses completion is missing its response ID.")
                                }
                                if let usage =
                                    Self.responsesUsage(response) {
                                    deliveredSemanticOutput = true
                                    continuation.yield(.usage(usage))
                                }
                                deliveredSemanticOutput = true
                                continuation.yield(
                                    .done(finishReason: "completed"))
                                completed = true
                                continuation.finish()
                                return true

                            case "response.failed":
                                if let contextWindow =
                                    ProviderErrorFormatting
                                        .contextWindowExceeded(
                                            from: .object(event),
                                            operation:
                                                "Responses request")
                                {
                                    throw contextWindow
                                }
                                let message =
                                    Self.responsesFailureMessage(event)
                                throw IntatisError.provider(
                                    "Responses request failed. \(message)")

                            case "response.incomplete":
                                let reason =
                                    Self.responsesIncompleteReason(event)
                                throw IntatisError.decoding(
                                    "Responses request was incomplete: \(reason).")

                            default:
                                break
                            }
                            return false
                        }

                        do {
                            for try await chunk in http.stream(urlRequest) {
                                for payload in parser.consume(chunk) {
                                    if try handle(payload) { return }
                                }
                            }
                            for payload in parser.flush() {
                                if try handle(payload) { return }
                            }
                            guard completed else {
                                continuation.finish(
                                    throwing: ProviderErrorFormatting
                                        .incompleteStream(
                                            operation:
                                                "Responses tool-calling streaming request"))
                                return
                            }
                            continuation.finish()
                            return
                        } catch {
                            if ProviderRuntime.shouldRetry(
                                error: error,
                                attempt: attempt,
                                policy: runtimePolicy,
                                deliveredSemanticOutput:
                                    deliveredSemanticOutput) {
                                attempt += 1
                                try await ProviderRuntime.sleepBeforeRetry(
                                    nextAttempt: attempt,
                                    policy: runtimePolicy,
                                    retryHint: ProviderErrorFormatting
                                        .retryHint(from: error))
                                continue
                            }
                            continuation.finish(
                                throwing: ProviderRuntime.exhausted(
                                    error,
                                    attempts: attempt,
                                    operation:
                                        "Responses tool-calling streaming request"))
                            return
                        }
                    }
                } catch {
                    continuation.finish(
                        throwing: ProviderErrorFormatting.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func buildAgentRequest(_ request: AgentRequest) throws -> URLRequest {
        if let capabilityError = toolCallingCapabilityError(
            for: request)
        {
            throw capabilityError
        }
        if request.requiresResponsesAPI {
            return try buildResponsesAgentRequest(request)
        }
        return try buildChatCompletionsAgentRequest(request)
    }

    private func buildChatCompletionsAgentRequest(
        _ request: AgentRequest
    ) throws -> URLRequest {
        let requestAdapter =
            endpoint.requestAdapter(for: request.model)
        var root = try Self.configuredRequestBody(
            endpoint: endpoint,
            model: request.model)
        root["model"] = .string(request.model.rawValue)
        root["messages"] = .array(request.messages.map(Self.messageJSON))
        root["stream"] = .bool(true)
        if !request.tools.isEmpty {
            root["tools"] = .array(
                request.tools.map(Self.chatCompletionsToolJSON))
        }
        try Self.applyChatCompletionsInvocationControls(
            to: &root,
            requestAdapter: requestAdapter,
            parallelToolCalls:
                request.parallelToolCalls)
        if let t = request.temperature {
            root["temperature"] = .number(t)
        }
        Self.applyChatCompletionsReasoningOptions(
            to: &root,
            runtimeEffort: request.reasoningEffort,
            requestAdapter: requestAdapter)
        if let maxOutputTokens = request.maxOutputTokens {
            // The invocation ceiling is host-owned. A durable inference profile
            // may carry a provider-native limit when no host ceiling is set,
            // but it must not leave a competing alias that an upstream could
            // prefer over the narrower runtime value.
            for key in Array(root.keys) where Self.isOutputTokenCeilingKey(key) {
                root.removeValue(forKey: key)
            }
            root["max_tokens"] = .number(Double(maxOutputTokens))
        }
        if request.includeUsage {
            root["stream_options"] = .object(["include_usage": .bool(true)])
        }

        var r = URLRequest(url: try endpoint.validatedChatCompletionsURL(operation: "tool-calling streaming request"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        r.httpBody = try Self.encodeRequestBody(root)
        return r
    }

    private func buildResponsesAgentRequest(
        _ request: AgentRequest
    ) throws -> URLRequest {
        var root = try Self.configuredRequestBody(
            endpoint: endpoint,
            model: request.model)
        let instructions = request.messages
            .filter { $0.role == .system }
            .compactMap(\.content)
            .joined(separator: "\n\n")
        let input = request.effectiveInputItems.compactMap {
            Self.responsesInputJSON($0)
        }

        root["model"] = .string(request.model.rawValue)
        if instructions.isEmpty {
            root.removeValue(forKey: "instructions")
        } else {
            root["instructions"] = .string(instructions)
        }
        root["input"] = .array(input)
        root["stream"] = .bool(true)
        root["store"] = .bool(false)
        root["tool_choice"] = .string("auto")
        // Responses requires the switch even when no individual tool advertises
        // parallel execution. The host still serializes non-parallel tools.
        root["parallel_tool_calls"] = .bool(
            request.parallelToolCalls ?? false)
        root.removeValue(forKey: "messages")
        root.removeValue(forKey: "n")

        if request.tools.isEmpty {
            root.removeValue(forKey: "tools")
        } else {
            root["tools"] = .array(
                request.tools.map(Self.responsesToolJSON))
        }
        if let temperature = request.temperature {
            root["temperature"] = .number(temperature)
        }
        Self.applyResponsesReasoningOptions(
            to: &root,
            runtimeEffort: request.reasoningEffort)
        if let maxOutputTokens = request.maxOutputTokens {
            for key in Array(root.keys)
            where Self.isOutputTokenCeilingKey(key) {
                root.removeValue(forKey: key)
            }
            root["max_output_tokens"] = .number(
                Double(maxOutputTokens))
        }
        if request.includeUsage {
            root["stream_options"] = .object([
                "include_usage": .bool(true),
            ])
        }

        var urlRequest = URLRequest(
            url: try endpoint.validatedResponsesURL(
                operation: "Responses tool-calling streaming request"))
        ProviderRuntime.apply(runtimePolicy, to: &urlRequest)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            "text/event-stream",
            forHTTPHeaderField: "Accept")
        urlRequest.setValue(
            ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
            forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try Self.encodeRequestBody(root)
        return urlRequest
    }

    private static func isOutputTokenCeilingKey(_ rawKey: String) -> Bool {
        let normalized = rawKey.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return [
            "maxtokens",
            "maxcompletiontokens",
            "maxoutputtokens",
            "maxnewtokens",
        ].contains(normalized)
    }

    static func responsesInputJSON(
        _ item: AgentInputItem
    ) -> JSONValue? {
        switch item {
        case .message(let role, let content, let images):
            // Responses carries trusted system instructions outside `input`.
            guard role != .system else { return nil }
            let textType = role == .assistant
                ? "output_text"
                : "input_text"
            var parts: [JSONValue] = []
            if let content, !content.isEmpty {
                parts.append(.object([
                    "type": .string(textType),
                    "text": .string(content),
                ]))
            }
            if role == .user {
                parts.append(contentsOf: images.map {
                    .object([
                        "type": .string("input_image"),
                        "image_url": .string($0.url),
                    ])
                })
            }
            guard !parts.isEmpty else { return nil }
            return .object([
                "type": .string("message"),
                "role": .string(role.rawValue),
                "content": .array(parts),
            ])

        case .functionCall(let call):
            let wireName = responsesWireFunctionName(call)
            var object: [String: JSONValue] = [
                "type": .string("function_call"),
                "call_id": .string(call.id),
                "name": .string(wireName),
                "arguments": .string(call.arguments),
            ]
            if let namespace = call.namespace {
                object["namespace"] = .string(namespace)
            }
            return .object(object)

        case .functionCallOutput(let callID, let output, let images):
            guard !images.isEmpty else {
                return .object([
                    "type": .string("function_call_output"),
                    "call_id": .string(callID),
                    "output": .string(output),
                ])
            }
            var parts: [JSONValue] = []
            if !output.isEmpty {
                parts.append(.object([
                    "type": .string("input_text"),
                    "text": .string(output),
                ]))
            }
            parts.append(contentsOf: images.map {
                .object([
                    "type": .string("input_image"),
                    "image_url": .string($0.url),
                ])
            })
            return .object([
                "type": .string("function_call_output"),
                "call_id": .string(callID),
                "output": .array(parts),
            ])

        case .toolSearchCall(
            let callID,
            let status,
            let execution,
            let arguments):
            var object: [String: JSONValue] = [
                "type": .string("tool_search_call"),
                "call_id": .string(callID),
                "execution": .string(execution),
                "arguments": arguments,
            ]
            if let status {
                object["status"] = .string(status)
            }
            return .object(object)

        case .toolSearchOutput(
            let callID,
            let status,
            let execution,
            let tools):
            return .object([
                "type": .string("tool_search_output"),
                "call_id": .string(callID),
                "status": .string(status),
                "execution": .string(execution),
                "tools": .array(tools),
            ])
        }
    }

    static func responsesToolJSON(_ tool: ToolSpec) -> JSONValue {
        switch tool.kind {
        case .function:
            return .object([
                "type": .string("function"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters,
            ].merging(functionOptionalFields(tool)) {
                _, replacement in replacement
            })
        case .namespace, .toolSearch:
            // These two shapes are already Responses-native.
            return toolJSON(tool)
        }
    }

    static func chatCompletionsToolJSON(_ tool: ToolSpec) -> JSONValue {
        switch tool.kind {
        case .function:
            var function: [String: JSONValue] = [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters,
            ]
            if let strict = tool.strict {
                function["strict"] = .bool(strict)
            }
            return .object([
                "type": .string("function"),
                "function": .object(function),
            ])
        case .namespace, .toolSearch:
            // AgentRequest routes Responses-native tool kinds through the
            // Responses API. Keep this fallback deterministic for callers
            // constructing a request directly.
            return toolJSON(tool)
        }
    }

    private static func responsesWireFunctionName(
        _ call: ToolCall
    ) -> String {
        guard let namespace = call.namespace,
              call.name.hasPrefix(namespace) else {
            return call.name
        }
        let child = String(call.name.dropFirst(namespace.count))
        return child.isEmpty ? call.name : child
    }

    private static func responsesFunctionCall(
        _ item: [String: JSONValue]
    ) throws -> ToolCall {
        guard case .string(let callID)? = item["call_id"],
              !callID.isEmpty,
              case .string(let wireName)? = item["name"],
              !wireName.isEmpty,
              case .string(let arguments)? = item["arguments"] else {
            throw ProviderErrorFormatting.invalidToolCallStream(
                "Responses function_call omitted call_id, name, or arguments.")
        }
        let namespace: String?
        if case .string(let value)? = item["namespace"],
           !value.isEmpty {
            namespace = value
        } else {
            namespace = nil
        }
        let routingName = namespace.map { $0 + wireName } ?? wireName
        try validateResponsesArgumentObject(
            arguments,
            callID: callID,
            kind: "function_call")
        return ToolCall(
            id: callID,
            name: routingName,
            arguments: arguments,
            namespace: namespace)
    }

    private static func responsesToolSearchCall(
        _ item: [String: JSONValue]
    ) throws -> ToolCall {
        guard case .string(let callID)? = item["call_id"],
              !callID.isEmpty,
              let arguments = item["arguments"] else {
            throw ProviderErrorFormatting.invalidToolCallStream(
                "Responses tool_search_call omitted call_id or arguments.")
        }
        guard case .object = arguments else {
            throw ProviderErrorFormatting.invalidToolCallStream(
                "Responses tool_search_call arguments were not a JSON object.")
        }
        let data = try JSONEncoder().encode(arguments)
        guard let argumentString = String(
            data: data,
            encoding: .utf8) else {
            throw ProviderErrorFormatting.invalidToolCallStream(
                "Responses tool_search_call arguments were not UTF-8.")
        }
        let status: String?
        if case .string(let value)? = item["status"] {
            status = value
        } else {
            status = nil
        }
        let execution: String
        if case .string(let value)? = item["execution"],
           !value.isEmpty {
            execution = value
        } else {
            execution = "client"
        }
        return ToolCall(
            id: callID,
            name: "tool_search",
            arguments: argumentString,
            kind: .toolSearch,
            status: status,
            execution: execution)
    }

    private static func validateResponsesArgumentObject(
        _ arguments: String,
        callID: String,
        kind: String
    ) throws {
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  JSONValue.self,
                  from: data),
              case .object = value else {
            throw ProviderErrorFormatting.invalidToolCallStream(
                "Responses \(kind) \(callID) arguments were not a JSON object.")
        }
    }

    private static func responsesMessageText(
        _ item: [String: JSONValue]
    ) -> String {
        guard case .array(let content)? = item["content"] else {
            return ""
        }
        return content.compactMap { part -> String? in
            guard case .object(let object) = part,
                  case .string(let type)? = object["type"],
                  type == "output_text",
                  case .string(let text)? = object["text"] else {
                return nil
            }
            return text
        }.joined()
    }

    private static func responsesUsage(
        _ response: [String: JSONValue]
    ) -> Usage? {
        guard case .object(let usage)? = response["usage"] else {
            return nil
        }
        func integer(_ key: String) -> Int? {
            guard case .number(let value)? = usage[key],
                  value.isFinite else {
                return nil
            }
            return Int(value)
        }
        var cachedTokens: Int?
        if case .object(let details)? =
                usage["input_tokens_details"],
           case .number(let value)? = details["cached_tokens"],
           value.isFinite {
            cachedTokens = Int(value)
        }
        return Usage(
            promptTokens: integer("input_tokens"),
            cachedPromptTokens: cachedTokens,
            completionTokens: integer("output_tokens"),
            totalTokens: integer("total_tokens"))
    }

    private static func responsesFailureMessage(
        _ event: [String: JSONValue]
    ) -> String {
        guard case .object(let response)? = event["response"],
              case .object(let error)? = response["error"] else {
            return "The provider did not include an error message."
        }
        if case .string(let message)? = error["message"],
           !message.isEmpty {
            return PermissionReviewTextSanitizer.sanitizeDiagnostic(
                message,
                maxCharacters: 360).text
        }
        return "The provider did not include an error message."
    }

    private static func responsesIncompleteReason(
        _ event: [String: JSONValue]
    ) -> String {
        guard case .object(let response)? = event["response"],
              case .object(let details)? =
                response["incomplete_details"],
              case .string(let reason)? = details["reason"],
              !reason.isEmpty else {
            return "unknown"
        }
        return PermissionReviewTextSanitizer.sanitizeDiagnostic(
            reason,
            maxCharacters: 160).text
    }

    static func messageJSON(_ m: AgentMessage) -> JSONValue {
        // Preserve the request's exact role on every wire. An endpoint that
        // cannot accept `developer` must fail explicitly; silently projecting
        // it to system/user would change the Skill trust contract.
        var obj: [String: JSONValue] = ["role": .string(m.role.rawValue)]
        if !m.images.isEmpty {
            var parts: [JSONValue] = []
            if let c = m.content, !c.isEmpty {
                parts.append(.object(["type": .string("text"), "text": .string(c)]))
            }
            for image in m.images {
                parts.append(.object(["type": .string("image_url"),
                                      "image_url": .object(["url": .string(image.url)])]))
            }
            obj["content"] = .array(parts)
        } else if let content = m.content {
            obj["content"] = .string(content)
        } else if m.role == .assistant {
            obj["content"] = .null   // assistant-with-tool_calls requires explicit null content
        }
        if let toolCalls = m.toolCalls {
            obj["tool_calls"] = .array(toolCalls.map { tc in
                .object([
                    "id": .string(tc.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tc.name),
                        "arguments": .string(tc.arguments),
                    ]),
                ])
            })
        }
        if let toolCallId = m.toolCallId {
            obj["tool_call_id"] = .string(toolCallId)
        }
        return .object(obj)
    }

    static func toolJSON(_ tool: ToolSpec) -> JSONValue {
        switch tool.kind {
        case .function:
            return .object([
                "type": .string("function"),
                "function": functionToolJSON(tool),
            ])
        case .namespace:
            return .object([
                "type": .string("namespace"),
                "name": .string(tool.name),
                "description": .string(tool.description),
                "tools": .array(tool.namespaceTools.map { nested in
                    .object([
                        "type": .string("function"),
                        "name": .string(nested.name),
                        "description": .string(nested.description),
                        "parameters": nested.parameters,
                    ].merging(functionOptionalFields(nested)) {
                        _, replacement in replacement
                    })
                }),
            ])
        case .toolSearch:
            return .object([
                "type": .string("tool_search"),
                "execution": .string(tool.execution ?? "client"),
                "description": .string(tool.description),
                "parameters": tool.parameters,
            ])
        }
    }

    private static func functionToolJSON(_ tool: ToolSpec) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters,
        ].merging(functionOptionalFields(tool)) { _, replacement in
            replacement
        })
    }

    private static func functionOptionalFields(
        _ tool: ToolSpec
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let strict = tool.strict {
            fields["strict"] = .bool(strict)
        }
        if let deferLoading = tool.deferLoading {
            fields["defer_loading"] = .bool(deferLoading)
        }
        if let outputSchema = tool.outputSchema {
            fields["output_schema"] = outputSchema
        }
        return fields
    }
}
