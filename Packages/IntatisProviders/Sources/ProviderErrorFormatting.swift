import Foundation
import IntatisCore
import IntatisProtocol

/// A provider/account hard usage limit that cannot be resolved by retrying the
/// current request. This is intentionally distinct from transient HTTP 429
/// rate limiting, which remains a normal retryable provider error.
public struct ProviderUsageLimitError: Error, LocalizedError, Equatable, Sendable {
    public var signal: String
    public var providerMessage: String?
    public var statusCode: Int?
    public var operation: String?

    public init(signal: String,
                providerMessage: String? = nil,
                statusCode: Int? = nil,
                operation: String? = nil) {
        self.signal = signal
        self.providerMessage = providerMessage
        self.statusCode = statusCode
        self.operation = operation
    }

    public var errorDescription: String? {
        var parts: [String] = []
        if let operation, let statusCode {
            parts.append("\(operation) failed with HTTP \(statusCode).")
        } else if let operation {
            parts.append("\(operation) failed.")
        }
        parts.append("The provider account reached a hard usage limit.")
        if !signal.isEmpty {
            let safeSignal = PermissionReviewTextSanitizer.sanitizeDiagnostic(
                signal,
                maxCharacters: 80).text
            parts.append("Provider signal: \(safeSignal).")
        }
        if let providerMessage, !providerMessage.isEmpty {
            let safeMessage = PermissionReviewTextSanitizer.sanitizeDiagnostic(
                providerMessage,
                maxCharacters: 360).text
            parts.append("Provider said: \(safeMessage)")
        }
        return parts.joined(separator: " ")
    }
}

/// Machine-classified provider rejection indicating that the request input
/// exceeded the selected model's context window. Compaction may retry only
/// this typed condition; arbitrary localized error text is never sufficient.
public struct ProviderContextWindowExceededError:
    Error, LocalizedError, Equatable, Sendable
{
    public var signal: String
    public var providerMessage: String?
    public var statusCode: Int?
    public var operation: String?

    public init(
        signal: String,
        providerMessage: String? = nil,
        statusCode: Int? = nil,
        operation: String? = nil
    ) {
        self.signal = signal
        self.providerMessage = providerMessage
        self.statusCode = statusCode
        self.operation = operation
    }

    public var errorDescription: String? {
        var parts = [operation.map { "\($0) exceeded the model context window." }
            ?? "The request exceeded the model context window."]
        if !signal.isEmpty {
            parts.append("Provider signal: \(signal).")
        }
        if let providerMessage, !providerMessage.isEmpty {
            parts.append(
                "Provider said: "
                + PermissionReviewTextSanitizer.sanitizeDiagnostic(
                    providerMessage,
                    maxCharacters: 360).text)
        }
        return parts.joined(separator: " ")
    }
}

/// Raw, bounded HTTP failure retained inside the provider layer long enough for
/// an exact adapter to perform structured classification. It is always reduced
/// to the existing sanitized public error before crossing that boundary.
struct ProviderHTTPStatusError: Error, LocalizedError, Sendable {
    var statusCode: Int
    var body: Data
    var headers: [String: String]
    var operation: String

    var formattedError: Error {
        ProviderErrorFormatting.httpStatus(
            statusCode,
            body: body,
            headers: headers,
            operation: operation)
    }

    var errorDescription: String? {
        formattedError.localizedDescription
    }
}

struct ProviderRetryHint: Equatable, Sendable {
    var delaySeconds: Double
    var source: String
    var rawValue: String

    var display: String {
        ProviderErrorFormatting.formatSeconds(delaySeconds)
    }
}

enum ProviderErrorFormatting {
    static let maxBodyBytes = 8192

    static func httpStatus(_ status: Int,
                           body: Data? = nil,
                           headers: [String: String] = [:],
                           operation: String) -> Error {
        if let body,
           let contextWindow = structuredContextWindowExceededError(
               from: body,
               statusCode: status,
               operation: operation) {
            return contextWindow
        }
        if let body,
           let usageLimit = structuredUsageLimitError(
               from: body,
               statusCode: status,
               operation: operation) {
            return usageLimit
        }
        var parts = ["\(operation) failed with HTTP \(status)\(statusLabel(status))."]
        if let guidance = statusGuidance(status) {
            parts.append(guidance)
        }
        if let hint = retryHint(headers: headers) {
            parts.append("Provider asked to retry after about \(hint.display) via \(hint.source).")
        }
        if let body {
            if let message = structuredProviderMessage(from: body) {
                parts.append("Provider said: \(message)")
            } else if let preview = responsePreview(from: body) {
                parts.append("Preview: \(preview)")
            }
        }
        return IntatisError.provider(parts.joined(separator: " "))
    }

    static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        status == 408 || status == 409 || status == 425 || status == 429 || (500...599).contains(status)
    }

    static func httpStatusCode(from message: String) -> Int? {
        guard let match = message.range(of: #"HTTP\s+(\d{3})"#, options: .regularExpression) else {
            return nil
        }
        let value = message[match]
            .replacingOccurrences(of: "HTTP", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(value)
    }

    static func retryHint(headers: [String: String], now: Date = Date()) -> ProviderRetryHint? {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            normalized[key.lowercased()] = value
        }
        let candidates = [
            "retry-after",
            "x-ratelimit-reset",
            "x-ratelimit-reset-requests",
            "x-ratelimit-reset-tokens",
            "ratelimit-reset",
        ]
        for key in candidates {
            guard let raw = normalized[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let seconds = retryDelaySeconds(raw, now: now) else {
                continue
            }
            return ProviderRetryHint(delaySeconds: max(0, seconds), source: key, rawValue: raw)
        }
        return nil
    }

    static func retryHint(from error: Error) -> ProviderRetryHint? {
        if let status = error as? ProviderHTTPStatusError {
            return retryHint(headers: status.headers)
        }
        return retryHint(fromMessage: error.localizedDescription)
    }

    static func transport(_ error: Error) -> Error {
        if error is CancellationError {
            return IntatisError.cancelled
        }
        if let usageLimit = error as? ProviderUsageLimitError {
            return usageLimit
        }
        if let contextWindow =
            error as? ProviderContextWindowExceededError {
            return contextWindow
        }
        if let status = error as? ProviderHTTPStatusError {
            return status.formattedError
        }
        if let intatis = error as? IntatisError {
            return sanitized(intatis)
        }
        if let urlError = error as? URLError {
            return IntatisError.provider(transportMessage(urlError))
        }
        return IntatisError.provider(clean(error.localizedDescription))
    }

    static func streamErrorPayload(_ data: Data) -> Error? {
        if let contextWindow = structuredContextWindowExceededError(
            from: data,
            operation: "streaming request") {
            return contextWindow
        }
        if let usageLimit = structuredUsageLimitError(
            from: data,
            operation: "streaming request") {
            return usageLimit
        }
        guard let message = providerErrorMessage(from: data) else { return nil }
        return IntatisError.provider(
            "Provider rejected the streaming request. Provider said: \(message)")
    }

    static func contextWindowExceeded(
        from value: JSONValue,
        statusCode: Int? = nil,
        operation: String? = nil
    ) -> ProviderContextWindowExceededError? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return structuredContextWindowExceededError(
            from: data,
            statusCode: statusCode,
            operation: operation)
    }

    static func invalidStreamPayload(_ payload: String, underlying: Error) -> IntatisError {
        let preview = clean(payload, maxCharacters: 180)
        return .decoding(
            "provider stream returned non-JSON SSE data. Check endpoint compatibility. " +
            "Preview: \(preview). Decoder said: \(clean(underlying.localizedDescription, maxCharacters: 180))")
    }

    static func incompleteStream(operation: String) -> IntatisError {
        .decoding(
            "\(operation) ended before a completion marker. " +
            "Check endpoint compatibility, proxy buffering, or provider stability.")
    }

    static func invalidToolCallStream(_ message: String) -> IntatisError {
        .decoding(
            "provider tool-call stream was incomplete. \(clean(message)) " +
            "Check tool-calling compatibility for this endpoint/model.")
    }

    static func invalidResponsePayload(_ data: Data,
                                       operation: String,
                                       expected: String,
                                       underlying: Error? = nil) -> IntatisError {
        var parts = [
            "\(operation) returned a response that did not match \(expected).",
            "Check endpoint compatibility, provider path, selected model, and response format.",
        ]
        if let message = structuredProviderMessage(from: data) {
            parts.append("Provider said: \(message)")
        } else if let preview = responsePreview(from: data) {
            parts.append("Preview: \(preview)")
        }
        if let underlying {
            parts.append("Decoder said: \(clean(underlying.localizedDescription, maxCharacters: 180))")
        }
        return .decoding(parts.joined(separator: " "))
    }

    static func isIncompleteStream(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("ended before a completion marker")
    }

    static func cappedBody<S: AsyncSequence>(from bytes: S) async throws -> Data where S.Element == UInt8 {
        var body = Data()
        for try await byte in bytes {
            if body.count < maxBodyBytes {
                body.append(byte)
            } else {
                break
            }
        }
        return body
    }

    static func providerMessage(from data: Data) -> String? {
        let capped = Data(data.prefix(maxBodyBytes))
        if let message = structuredProviderMessage(from: capped) {
            return clean(message)
        }
        guard let text = String(data: capped, encoding: .utf8) else { return nil }
        let cleaned = clean(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func responsePreview(from data: Data) -> String? {
        let capped = Data(data.prefix(maxBodyBytes))
        guard let text = String(data: capped, encoding: .utf8) else { return nil }
        let cleaned = clean(text, maxCharacters: 180)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func structuredProviderMessage(from data: Data) -> String? {
        let capped = Data(data.prefix(maxBodyBytes))
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: capped),
              let message = providerMessage(from: value) else {
            return nil
        }
        return clean(message)
    }

    /// Classification is deliberately limited to machine-readable fields in
    /// a structured provider payload. Neither HTTP 429 alone nor arbitrary
    /// unstructured body text is sufficient to claim an account hard limit.
    private static func structuredUsageLimitError(
        from data: Data,
        statusCode: Int? = nil,
        operation: String? = nil
    ) -> ProviderUsageLimitError? {
        let capped = Data(data.prefix(maxBodyBytes))
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: capped),
              case .object(let root) = value else {
            return nil
        }

        var objects: [[String: JSONValue]] = []
        if let error = root["error"], case .object(let nestedError) = error {
            objects.append(nestedError)
        }
        objects.append(root)

        for object in objects {
            for key in ["code", "type", "message"] {
                guard let candidate = object[key]?.displayString,
                      let signal = hardUsageLimitSignal(in: candidate) else {
                    continue
                }
                return ProviderUsageLimitError(
                    signal: signal,
                    providerMessage: providerMessage(from: value).map { clean($0) },
                    statusCode: statusCode,
                    operation: operation)
            }
        }
        return nil
    }

    private static func structuredContextWindowExceededError(
        from data: Data,
        statusCode: Int? = nil,
        operation: String? = nil
    ) -> ProviderContextWindowExceededError? {
        let capped = Data(data.prefix(maxBodyBytes))
        guard let value = try? JSONDecoder().decode(
                  JSONValue.self,
                  from: capped),
              case .object(let root) = value else {
            return nil
        }
        var objects: [[String: JSONValue]] = []
        if let error = root["error"], case .object(let nested) = error {
            objects.append(nested)
        }
        if let response = root["response"],
           case .object(let responseObject) = response {
            if let error = responseObject["error"],
               case .object(let nested) = error {
                objects.append(nested)
            }
            objects.append(responseObject)
        }
        objects.append(root)

        let known = Set([
            "context_length_exceeded",
            "context_window_exceeded",
            "maximum_context_length_exceeded",
            "prompt_too_long",
        ])
        for object in objects {
            for key in ["code", "type"] {
                guard let rawValue = object[key]?.displayString else {
                    continue
                }
                let value = rawValue.lowercased()
                guard known.contains(value) else { continue }
                return ProviderContextWindowExceededError(
                    signal: value,
                    providerMessage:
                        providerMessage(from: .object(root))
                            .map { clean($0) },
                    statusCode: statusCode,
                    operation: operation)
            }
        }
        return nil
    }

    private static func hardUsageLimitSignal(in value: String) -> String? {
        let tokens = value.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }
        let knownSignals = [
            "insufficient_quota",
            "billing_hard_limit_reached",
            "usage_limit_reached",
        ]
        return knownSignals.first { signal in
            tokens.contains { $0 == Substring(signal) }
        }
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        structuredProviderMessage(from: data)
    }

    private static func providerMessage(from value: JSONValue) -> String? {
        guard case .object(let object) = value else {
            if case .string(let string) = value { return string }
            return nil
        }

        if let error = object["error"] {
            if case .object(let errorObject) = error {
                var pieces: [String] = []
                if let message = errorObject["message"]?.displayString { pieces.append(message) }
                if let type = errorObject["type"]?.displayString { pieces.append("type=\(type)") }
                if let code = errorObject["code"]?.displayString { pieces.append("code=\(code)") }
                if let param = errorObject["param"]?.displayString { pieces.append("param=\(param)") }
                if !pieces.isEmpty { return pieces.joined(separator: " ") }
            }
            if let string = error.displayString { return string }
        }

        for key in ["message", "detail", "error_description"] {
            if let value = object[key]?.displayString { return value }
        }
        return nil
    }

    static func formatSeconds(_ value: Double) -> String {
        value >= 1 ? String(format: "%.0fs", value) : String(format: "%.2fs", value)
    }

    private static func retryDelaySeconds(_ raw: String, now: Date) -> Double? {
        if let seconds = Double(raw) {
            // Some providers use epoch seconds in x-ratelimit-reset, while
            // Retry-After uses relative seconds. Large values are treated as an epoch.
            if seconds > 10_000_000 {
                return max(0, seconds - now.timeIntervalSince1970)
            }
            return seconds
        }
        if let seconds = durationDelaySeconds(raw) {
            return seconds
        }
        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd'-'MMM'-'yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    private static func durationDelaySeconds(_ raw: String) -> Double? {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !normalized.isEmpty else { return nil }

        let pattern = #"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, range: fullRange)
        guard !matches.isEmpty else { return nil }

        var cursor = 0
        var total = 0.0
        for match in matches {
            guard match.range.location == cursor,
                  let valueRange = Range(match.range(at: 1), in: normalized),
                  let unitRange = Range(match.range(at: 2), in: normalized),
                  let value = Double(normalized[valueRange]) else {
                return nil
            }
            switch normalized[unitRange] {
            case "ms":
                total += value / 1_000
            case "s":
                total += value
            case "m":
                total += value * 60
            case "h":
                total += value * 3_600
            default:
                return nil
            }
            cursor = match.range.location + match.range.length
        }
        return cursor == fullRange.length ? total : nil
    }

    private static func retryHint(fromMessage message: String) -> ProviderRetryHint? {
        guard let range = message.range(
            of: #"retry after about ([0-9]+(?:\.[0-9]+)?)s"#,
            options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let matched = String(message[range])
        guard let valueRange = matched.range(of: #"([0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression),
              let seconds = Double(matched[valueRange]) else {
            return nil
        }
        return ProviderRetryHint(delaySeconds: seconds, source: "message", rawValue: matched)
    }

    private static func statusLabel(_ status: Int) -> String {
        switch status {
        case 400: return " Bad Request"
        case 401: return " Unauthorized"
        case 403: return " Forbidden"
        case 404: return " Not Found"
        case 408: return " Request Timeout"
        case 409: return " Conflict"
        case 422: return " Unprocessable Entity"
        case 429: return " Too Many Requests"
        case 500: return " Internal Server Error"
        case 502: return " Bad Gateway"
        case 503: return " Service Unavailable"
        case 504: return " Gateway Timeout"
        default: return ""
        }
    }

    private static func statusGuidance(_ status: Int) -> String? {
        switch status {
        case 400, 422:
            return "Check model id, request shape, tool schema, and endpoint compatibility."
        case 401:
            return "Check the API key source and provider authentication."
        case 403:
            return "The key or account is not allowed to use this model or endpoint."
        case 404:
            return "Check the base URL, chat endpoint, provider path, and model id."
        case 408, 429:
            return "Retry later or reduce request rate/context size."
        case 500...599:
            return "The provider or upstream gateway failed; retry later or switch provider."
        default:
            return nil
        }
    }

    private static func transportMessage(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "Network timed out while contacting the provider. Check connectivity, endpoint, or provider latency."
        case .notConnectedToInternet:
            return "No internet connection while contacting the provider."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not resolve the provider host. Check the base URL."
        case .cannotConnectToHost:
            return "Could not connect to the provider host. Check endpoint availability."
        case .networkConnectionLost:
            return "Network connection to the provider was lost during streaming. Retry the request."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted:
            return "TLS validation failed for the provider endpoint. Check the endpoint certificate and URL."
        default:
            return clean(error.localizedDescription)
        }
    }

    private static func clean(_ value: String, maxCharacters: Int = 360) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PermissionReviewTextSanitizer.sanitizeDiagnostic(
            collapsed,
            maxCharacters: maxCharacters).text
    }

    private static func sanitized(_ error: IntatisError) -> IntatisError {
        switch error {
        case .config(let message):
            return .config(clean(message))
        case .provider(let message):
            return .provider(clean(message))
        case .decoding(let message):
            return .decoding(clean(message))
        case .io(let message):
            return .io(clean(message))
        case .notFound(let message):
            return .notFound(clean(message))
        case .permissionDenied(let message):
            return .permissionDenied(clean(message))
        case .cancelled:
            return .cancelled
        }
    }
}

private extension JSONValue {
    var displayString: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }
}
