import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

public struct RuntimeRecoveryAdvice: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var retryable: Bool

    public init(title: String, detail: String, retryable: Bool) {
        self.title = title
        self.detail = detail
        self.retryable = retryable
    }
}

public enum RuntimeErrorPresentation {
    public static func payload(for error: Error, fallbackCode: String, fatal: Bool = false) -> ErrorPayload {
        ErrorPayload(code: code(for: error, fallbackCode: fallbackCode),
                     message: message(for: error),
                     fatal: fatal)
    }

    public static func code(for error: Error, fallbackCode: String) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if error is ProviderUsageLimitError {
            return "provider.usage_limit"
        }
        if let intatis = error as? IntatisError {
            switch intatis {
            case .config:
                return "config"
            case .provider:
                return "provider"
            case .decoding:
                return "decoding"
            case .io:
                return "io"
            case .notFound:
                return "not_found"
            case .permissionDenied:
                return "permission_denied"
            case .cancelled:
                return "cancelled"
            }
        }
        if error is URLError {
            return "provider.network"
        }
        return fallbackCode
    }

    public static func message(for error: Error) -> String {
        if error is CancellationError {
            return IntatisError.cancelled.localizedDescription
        }
        // Provider, decoder, and plug-in errors are untrusted strings. This is
        // the last common boundary before messages become durable EventLog or
        // task-failure facts, so sanitize even when an upstream formatter was
        // bypassed by a custom provider implementation.
        return PermissionReviewTextSanitizer.sanitizeDiagnostic(
            error.localizedDescription,
            maxCharacters: 1_024).text
    }

    public static func recoveryAdvice(for payload: ErrorPayload) -> RuntimeRecoveryAdvice? {
        recoveryAdvice(code: payload.code, message: payload.message)
    }

    public static func partialResponseAdvice(for payload: ErrorPayload) -> RuntimeRecoveryAdvice {
        let base = recoveryAdvice(for: payload)
        let suffix = base?.detail ?? "Review the provider error before retrying."
        return RuntimeRecoveryAdvice(
            title: "Response stopped before completion",
            detail: "The provider stopped after partial output. The partial text is preserved. \(suffix)",
            retryable: base?.retryable ?? true)
    }

    public static func recoveryAdvice(forToolObservation observation: String) -> RuntimeRecoveryAdvice? {
        let normalized = observation.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        if lower.hasPrefix("permission denied:") {
            return RuntimeRecoveryAdvice(
                title: "Rerun after permission change",
                detail: "The tool was skipped because permission was denied. Rerun the task if you want to approve it.",
                retryable: false)
        }
        if lower.hasPrefix("unknown tool:") {
            return RuntimeRecoveryAdvice(
                title: "Use an available tool",
                detail: "The model requested a tool this client does not expose. Ask it to retry with one of the listed tools.",
                retryable: false)
        }
        if lower.hasPrefix("invalid tool input:") {
            return RuntimeRecoveryAdvice(
                title: "Fix tool input",
                detail: "The model provided invalid tool arguments. Ask it to retry with a JSON object that matches the tool schema.",
                retryable: true)
        }
        if lower.hasPrefix("tool error:") {
            return RuntimeRecoveryAdvice(
                title: "Inspect tool inputs and retry",
                detail: "The tool ran but failed. Check the paths, arguments, and permission context before rerunning.",
                retryable: true)
        }
        return nil
    }

    public static func recoveryAdvice(code: String, message: String) -> RuntimeRecoveryAdvice? {
        let normalizedCode = code.lowercased()
        let lower = message.lowercased()

        if normalizedCode == "cancelled" || lower.contains("cancelled") {
            return RuntimeRecoveryAdvice(
                title: "Request cancelled",
                detail: "No recovery is needed unless you still want the result; rerun the request when ready.",
                retryable: true)
        }
        if normalizedCode == "config"
            || lower.contains("api key")
            || lower.contains("authentication")
            || lower.contains("unauthorized")
            || lower.contains("http 401")
            || lower.contains("http 403") {
            return RuntimeRecoveryAdvice(
                title: "Fix provider configuration",
                detail: "Check the API key source, provider access, selected model, and endpoint before retrying.",
                retryable: false)
        }
        if normalizedCode == "decoding"
            || lower.contains("malformed")
            || lower.contains("non-json")
            || lower.contains("stream returned")
            || lower.contains("completion marker") {
            return RuntimeRecoveryAdvice(
                title: "Check endpoint compatibility",
                detail: "The response did not match the expected OpenAI-compatible stream. Verify the chat endpoint and wire format.",
                retryable: false)
        }
        if normalizedCode == "permission_denied" {
            return RuntimeRecoveryAdvice(
                title: "Review permission and rerun",
                detail: "The operation was blocked by policy or user decision. Rerun only after changing the request or permission.",
                retryable: false)
        }
        if normalizedCode == "not_found"
            || lower.contains("http 404")
            || lower.contains("model not found") {
            return RuntimeRecoveryAdvice(
                title: "Check endpoint or model",
                detail: "Verify the base URL, chat endpoint, provider path, and model id before retrying.",
                retryable: false)
        }
        if normalizedCode == "provider.network"
            || lower.contains("network")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("could not connect")
            || lower.contains("could not resolve")
            || lower.contains("connection to the provider was lost")
            || lower.contains("http 408")
            || lower.contains("http 409")
            || lower.contains("http 425")
            || lower.contains("http 429")
            || lower.contains("http 500")
            || lower.contains("http 502")
            || lower.contains("http 503")
            || lower.contains("http 504")
            || lower.contains("retry later") {
            return RuntimeRecoveryAdvice(
                title: "Retry or switch provider",
                detail: "This looks transient or provider-side. Retry after the suggested delay, reduce context size, or switch provider.",
                retryable: true)
        }
        if normalizedCode == "provider" {
            return RuntimeRecoveryAdvice(
                title: "Review provider response",
                detail: "Check the provider message, endpoint, selected model, and request shape before rerunning.",
                retryable: false)
        }
        if normalizedCode == "io" {
            return RuntimeRecoveryAdvice(
                title: "Check local files",
                detail: "Verify the workspace path, file permissions, and whether the file still exists before rerunning.",
                retryable: true)
        }
        return nil
    }
}
