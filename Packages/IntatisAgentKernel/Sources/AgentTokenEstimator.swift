import Foundation
import IntatisProtocol
import IntatisProviders

/// Deterministic provider-neutral token estimate used by the current local
/// compaction policy. Intatis does not yet route these calculations through
/// provider-specific tokenizers.
///
/// Codex's local history truncation uses UTF-8 bytes rather than Swift
/// grapheme count. Matching that rule avoids badly under-counting CJK text and
/// emoji while keeping this layer independent from any one model tokenizer.
enum AgentTokenEstimator {
    static let imageTokenCost = 4_096

    static func approximateTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.utf8.count + 3) / 4)
    }

    static func approximateInputTokens(
        messages: [AgentMessage],
        tools: [ToolSpec] = []
    ) -> Int {
        let messageBytes = messages.reduce(0) { partial, message in
            partial
                + message.role.rawValue.utf8.count
                + (message.content?.utf8.count ?? 0)
                + (message.toolCallId?.utf8.count ?? 0)
                + (message.toolCalls?.reduce(0) {
                    $0
                        + $1.id.utf8.count
                        + $1.name.utf8.count
                        + $1.arguments.utf8.count
                        + $1.kind.rawValue.utf8.count
                        + ($1.namespace?.utf8.count ?? 0)
                        + ($1.status?.utf8.count ?? 0)
                        + ($1.execution?.utf8.count ?? 0)
                } ?? 0)
                + (message.toolSearchOutput.map {
                    $0.status.utf8.count
                        + $0.execution.utf8.count
                        + $0.tools.reduce(0) {
                            $0 + canonicalJSONByteCount($1)
                        }
                } ?? 0)
        }
        let toolBytes = tools.reduce(0) { partial, tool in
            partial + toolByteCount(tool)
        }
        let imageCount = messages.reduce(0) {
            $0 + $1.images.count
        }
        let textTokens = (messageBytes + toolBytes + 3) / 4
        let imageTokens = approximateImageTokens(count: imageCount)
        let (total, overflow) = textTokens.addingReportingOverflow(
            imageTokens)
        return overflow ? Int.max : max(1, total)
    }

    static func approximateImageTokens(count: Int) -> Int {
        guard count > 0 else { return 0 }
        let (tokens, overflow) = count.multipliedReportingOverflow(
            by: imageTokenCost)
        return overflow ? Int.max : tokens
    }

    static func approximateTotalTokens(
        request: AgentRequest,
        assistantText: String,
        toolCalls: [ToolCall]
    ) -> Int {
        let input = approximateInputTokens(
            messages: request.messages,
            tools: request.tools)
        let responseBytes = assistantText.utf8.count
            + toolCalls.reduce(0) {
                $0
                    + $1.name.utf8.count
                    + $1.arguments.utf8.count
            }
        let response = responseBytes == 0
            ? 0
            : max(1, (responseBytes + 3) / 4)
        return max(1, input + response)
    }

    /// Keeps the newest real user messages within the Codex-compatible budget.
    /// If the boundary message does not fit, its newest UTF-8-safe suffix is
    /// retained and marked as truncated by the caller.
    static func newestSuffix(
        of text: String,
        fittingTokenBudget budget: Int
    ) -> String {
        guard budget > 0, !text.isEmpty else { return "" }
        let maximumBytes = budget * 4
        let bytes = Array(text.utf8)
        guard bytes.count > maximumBytes else { return text }

        var start = bytes.count - maximumBytes
        while start < bytes.count,
              (bytes[start] & 0b1100_0000) == 0b1000_0000 {
            start += 1
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private static func toolByteCount(_ tool: ToolSpec) -> Int {
        tool.name.utf8.count
            + tool.description.utf8.count
            + tool.kind.rawValue.utf8.count
            + canonicalJSONByteCount(tool.parameters)
            + (tool.strict == nil ? 0 : 5)
            + (tool.deferLoading == nil ? 0 : 5)
            + (tool.outputSchema.map(canonicalJSONByteCount) ?? 0)
            + (tool.execution?.utf8.count ?? 0)
            + tool.namespaceTools.reduce(0) {
                $0 + toolByteCount($1)
            }
    }

    /// Deterministic encoded-size approximation. Object keys are sorted so an
    /// equivalent schema has the same threshold behavior across processes.
    private static func canonicalJSONByteCount(_ value: JSONValue) -> Int {
        switch value {
        case .null:
            return 4
        case .bool(let value):
            return value ? 4 : 5
        case .number(let value):
            return String(value).utf8.count
        case .string(let value):
            return value.utf8.count + 2
        case .array(let values):
            return 2
                + max(0, values.count - 1)
                + values.reduce(0) {
                    $0 + canonicalJSONByteCount($1)
                }
        case .object(let object):
            return 2
                + max(0, object.count - 1)
                + object.keys.sorted().reduce(0) { partial, key in
                    partial
                        + key.utf8.count
                        + 3
                        + canonicalJSONByteCount(object[key] ?? .null)
                }
        }
    }
}
