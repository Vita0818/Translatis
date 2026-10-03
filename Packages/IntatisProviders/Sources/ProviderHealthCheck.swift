import Foundation
import IntatisCore
import IntatisProtocol

public enum ProviderHealthStatus: String, Equatable, Sendable {
    case ok
    case failed
}

public enum ProviderHealthRole: String, Equatable, Sendable {
    case chat
    case agent
}

public struct ProviderHealthCheckOptions: Equatable, Sendable {
    public var timeoutSeconds: Double
    public var prompt: String
    public var maxPreviewCharacters: Int

    public init(timeoutSeconds: Double = 15,
                prompt: String = "Reply with OK.",
                maxPreviewCharacters: Int = 160) {
        self.timeoutSeconds = timeoutSeconds
        self.prompt = prompt
        self.maxPreviewCharacters = maxPreviewCharacters
    }
}

public struct ProviderHealthReport: Equatable, Sendable {
    public var status: ProviderHealthStatus
    public var role: ProviderHealthRole
    public var endpointID: String
    public var model: ModelID
    public var wire: WireFormat?
    public var elapsedMillis: Int
    public var firstTokenMillis: Int?
    public var totalTokens: Int?
    public var code: String?
    public var message: String
    public var responsePreview: String?

    public var isOK: Bool { status == .ok }

    public var displayTitle: String {
        isOK ? "Provider check passed" : "Provider check failed"
    }

    public var displaySummary: String {
        var parts = [
            role.rawValue,
            endpointID,
            model.rawValue,
            "\(elapsedMillis) ms",
        ]
        if let code {
            parts.append(code)
        }
        return parts.joined(separator: " · ")
    }

    public var displayDetail: String {
        if let responsePreview, !responsePreview.isEmpty {
            return "\(message) Preview: \(responsePreview)"
        }
        return message
    }

    public init(status: ProviderHealthStatus,
                role: ProviderHealthRole,
                endpointID: String,
                model: ModelID,
                wire: WireFormat?,
                elapsedMillis: Int,
                firstTokenMillis: Int? = nil,
                totalTokens: Int? = nil,
                code: String? = nil,
                message: String,
                responsePreview: String? = nil) {
        self.status = status
        self.role = role
        self.endpointID = endpointID
        self.model = model
        self.wire = wire
        self.elapsedMillis = elapsedMillis
        self.firstTokenMillis = firstTokenMillis
        self.totalTokens = totalTokens
        self.code = code
        self.message = message
        self.responsePreview = responsePreview
    }
}

enum ProviderHealthChecker {
    private struct Timeout: Error, Sendable {
        var seconds: Double
    }

    static func checkChat(provider: ChatProvider,
                          endpoint: ProviderEndpoint,
                          model: ModelID,
                          options: ProviderHealthCheckOptions,
                          startedAt start: Date = Date()) async -> ProviderHealthReport {
        await check(endpoint: endpoint, model: model, role: .chat, options: options, startedAt: start) {
            try await runChat(provider: provider, model: model, options: options, startedAt: start)
        }
    }

    static func checkAgent(provider: ToolCallingProvider,
                           endpoint: ProviderEndpoint,
                           model: ModelID,
                           options: ProviderHealthCheckOptions,
                           startedAt start: Date = Date()) async -> ProviderHealthReport {
        await check(endpoint: endpoint, model: model, role: .agent, options: options, startedAt: start) {
            try await runAgent(provider: provider, model: model, options: options, startedAt: start)
        }
    }

    static func failed(role: ProviderHealthRole,
                       endpointID: String,
                       model: ModelID,
                       wire: WireFormat?,
                       code: String,
                       message: String,
                       startedAt start: Date) -> ProviderHealthReport {
        ProviderHealthReport(
            status: .failed,
            role: role,
            endpointID: endpointID,
            model: model,
            wire: wire,
            elapsedMillis: elapsedMillis(since: start),
            code: code,
            message: clean(message))
    }

    static func failed(role: ProviderHealthRole,
                       endpoint: ProviderEndpoint,
                       model: ModelID,
                       error: Error,
                       startedAt start: Date) -> ProviderHealthReport {
        failureReport(for: error, endpoint: endpoint, model: model, role: role, startedAt: start)
    }

    private static func check(endpoint: ProviderEndpoint,
                              model: ModelID,
                              role: ProviderHealthRole,
                              options: ProviderHealthCheckOptions,
                              startedAt start: Date,
                              operation: @escaping @Sendable () async throws -> ProviderHealthReport) async -> ProviderHealthReport {
        do {
            return try await withTimeout(seconds: options.timeoutSeconds, operation: operation)
        } catch {
            return failureReport(for: error, endpoint: endpoint, model: model, role: role, startedAt: start)
        }
    }

    private static func runChat(provider: ChatProvider,
                                model: ModelID,
                                options: ProviderHealthCheckOptions,
                                startedAt start: Date) async throws -> ProviderHealthReport {
        var firstTokenMillis: Int?
        var usage: Usage?
        var preview = ""
        var sawDone = false

        let request = ChatRequest(
            model: model,
            messages: [ChatMessage(role: .user, content: options.prompt)],
            includeUsage: true)

        do {
            for try await chunk in provider.stream(request) {
                try Task.checkCancellation()
                switch chunk {
                case .delta(let text):
                    if firstTokenMillis == nil {
                        firstTokenMillis = elapsedMillis(since: start)
                    }
                    appendPreview(text, to: &preview, limit: options.maxPreviewCharacters)
                case .citation:
                    break
                case .usage(let value):
                    usage = Usage.merging(usage, with: value)
                case .done:
                    sawDone = true
                }
            }
        } catch where ProviderErrorFormatting.isIncompleteStream(error) {
            return streamReport(role: .chat,
                                endpointID: "",
                                model: model,
                                wire: nil,
                                startedAt: start,
                                firstTokenMillis: firstTokenMillis,
                                usage: usage,
                                preview: preview,
                                sawDone: false)
        }

        return streamReport(role: .chat,
                            endpointID: "",
                            model: model,
                            wire: nil,
                            startedAt: start,
                            firstTokenMillis: firstTokenMillis,
                            usage: usage,
                            preview: preview,
                            sawDone: sawDone)
    }

    private static func runAgent(provider: ToolCallingProvider,
                                 model: ModelID,
                                 options: ProviderHealthCheckOptions,
                                 startedAt start: Date) async throws -> ProviderHealthReport {
        var firstTokenMillis: Int?
        var usage: Usage?
        var preview = ""
        var sawDone = false

        let request = AgentRequest(
            model: model,
            messages: [.user(options.prompt)],
            tools: [],
            includeUsage: true)

        do {
            for try await chunk in provider.stream(request) {
                try Task.checkCancellation()
                switch chunk {
                case .textDelta(let text):
                    if firstTokenMillis == nil {
                        firstTokenMillis = elapsedMillis(since: start)
                    }
                    appendPreview(text, to: &preview, limit: options.maxPreviewCharacters)
                case .toolCalls(let calls):
                    if !calls.isEmpty {
                        throw IntatisError.provider("Provider returned tool calls during a no-tool health check.")
                    }
                case .usage(let value):
                    usage = Usage.merging(usage, with: value)
                case .done:
                    sawDone = true
                }
            }
        } catch where ProviderErrorFormatting.isIncompleteStream(error) {
            return streamReport(role: .agent,
                                endpointID: "",
                                model: model,
                                wire: nil,
                                startedAt: start,
                                firstTokenMillis: firstTokenMillis,
                                usage: usage,
                                preview: preview,
                                sawDone: false)
        }

        return streamReport(role: .agent,
                            endpointID: "",
                            model: model,
                            wire: nil,
                            startedAt: start,
                            firstTokenMillis: firstTokenMillis,
                            usage: usage,
                            preview: preview,
                            sawDone: sawDone)
    }

    private static func streamReport(role: ProviderHealthRole,
                                     endpointID: String,
                                     model: ModelID,
                                     wire: WireFormat?,
                                     startedAt start: Date,
                                     firstTokenMillis: Int?,
                                     usage: Usage?,
                                     preview: String,
                                     sawDone: Bool) -> ProviderHealthReport {
        if !sawDone {
            let detail = preview.isEmpty
                ? "Provider stream ended before a completion marker and returned no text."
                : "Provider stream ended before a completion marker after returning partial text."
            return ProviderHealthReport(
                status: .failed,
                role: role,
                endpointID: endpointID,
                model: model,
                wire: wire,
                elapsedMillis: elapsedMillis(since: start),
                firstTokenMillis: firstTokenMillis,
                totalTokens: usage?.totalTokens,
                code: "provider.partial_stream",
                message: detail + " Check endpoint compatibility, proxy buffering, or provider stability.",
                responsePreview: preview.isEmpty ? nil : clean(preview))
        }

        let message = preview.isEmpty
            ? "Provider completed the health check; no text delta was returned."
            : "Provider completed the health check."
        return ProviderHealthReport(
            status: .ok,
            role: role,
            endpointID: endpointID,
            model: model,
            wire: wire,
            elapsedMillis: elapsedMillis(since: start),
            firstTokenMillis: firstTokenMillis,
            totalTokens: usage?.totalTokens,
            message: message,
            responsePreview: preview.isEmpty ? nil : clean(preview))
    }

    private static func failureReport(for error: Error,
                                      endpoint: ProviderEndpoint,
                                      model: ModelID,
                                      role: ProviderHealthRole,
                                      startedAt start: Date) -> ProviderHealthReport {
        if let timeout = error as? Timeout {
            return ProviderHealthReport(
                status: .failed,
                role: role,
                endpointID: endpoint.id,
                model: model,
                wire: endpoint.wire,
                elapsedMillis: elapsedMillis(since: start),
                code: "provider.timeout",
                message: "Provider health check timed out after \(formatSeconds(timeout.seconds)). Check endpoint, network, provider latency, or proxy buffering.")
        }
        if error is CancellationError {
            return ProviderHealthReport(
                status: .failed,
                role: role,
                endpointID: endpoint.id,
                model: model,
                wire: endpoint.wire,
                elapsedMillis: elapsedMillis(since: start),
                code: "cancelled",
                message: IntatisError.cancelled.localizedDescription)
        }
        return ProviderHealthReport(
            status: .failed,
            role: role,
            endpointID: endpoint.id,
            model: model,
            wire: endpoint.wire,
            elapsedMillis: elapsedMillis(since: start),
            code: code(for: error),
            message: clean(error.localizedDescription))
    }

    private static func code(for error: Error) -> String {
        if let intatis = error as? IntatisError {
            switch intatis {
            case .config: return "config"
            case .provider: return "provider"
            case .decoding: return "decoding"
            case .io: return "io"
            case .notFound: return "not_found"
            case .permissionDenied: return "permission_denied"
            case .cancelled: return "cancelled"
            }
        }
        if error is URLError {
            return "provider.network"
        }
        return "provider"
    }

    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeoutSeconds = max(seconds, 0.001)
        let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw Timeout(seconds: timeoutSeconds)
            }

            do {
                guard let value = try await group.next() else {
                    throw IntatisError.provider("Provider health check did not produce a result.")
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func appendPreview(_ text: String, to preview: inout String, limit: Int) {
        guard preview.count < limit else { return }
        let remaining = max(0, limit - preview.count)
        preview += String(text.prefix(remaining))
    }

    private static func elapsedMillis(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private static func clean(_ value: String, maxCharacters: Int = 360) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "..."
    }

    private static func formatSeconds(_ value: Double) -> String {
        value >= 1 ? String(format: "%.0fs", value) : String(format: "%.2fs", value)
    }
}
