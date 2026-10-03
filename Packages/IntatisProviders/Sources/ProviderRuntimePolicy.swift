import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderRuntimePolicy: Equatable, Sendable {
    public var maxAttempts: Int
    public var requestTimeoutSeconds: Double
    public var initialRetryDelaySeconds: Double
    public var maxRetryDelaySeconds: Double
    public var maxRetryAfterDelaySeconds: Double

    public init(maxAttempts: Int = 2,
                requestTimeoutSeconds: Double = 120,
                initialRetryDelaySeconds: Double = 0.25,
                maxRetryDelaySeconds: Double = 2,
                maxRetryAfterDelaySeconds: Double = 30) {
        self.maxAttempts = max(1, maxAttempts)
        self.requestTimeoutSeconds = max(0.001, requestTimeoutSeconds)
        self.initialRetryDelaySeconds = max(0, initialRetryDelaySeconds)
        self.maxRetryDelaySeconds = max(self.initialRetryDelaySeconds, maxRetryDelaySeconds)
        self.maxRetryAfterDelaySeconds = max(0, maxRetryAfterDelaySeconds)
    }

    public static let streaming = ProviderRuntimePolicy(
        maxAttempts: 6,
        requestTimeoutSeconds: 120,
        initialRetryDelaySeconds: 1,
        maxRetryDelaySeconds: 16)

    /// Tool-calling Agent requests can legitimately spend longer reasoning
    /// before their first response byte than interactive Chat requests. Keep
    /// this separate from `streaming` so Chat responsiveness does not drift
    /// when Code/Cowork execution budgets are adjusted.
    public static let agentStreaming = ProviderRuntimePolicy(
        maxAttempts: 6,
        requestTimeoutSeconds: 180,
        initialRetryDelaySeconds: 1,
        maxRetryDelaySeconds: 16)

    public static let nonStreaming = ProviderRuntimePolicy(
        maxAttempts: 2,
        requestTimeoutSeconds: 180,
        initialRetryDelaySeconds: 0.25,
        maxRetryDelaySeconds: 2)
}

enum ProviderRuntime {
    private struct Timeout: Error, LocalizedError, Sendable {
        var operation: String
        var seconds: Double

        var errorDescription: String? {
            "\(operation) timed out after \(formatSeconds(seconds)). Check endpoint, network, provider latency, or proxy buffering."
        }
    }

    static func apply(_ policy: ProviderRuntimePolicy, to request: inout URLRequest) {
        request.timeoutInterval = policy.requestTimeoutSeconds
    }

    static func shouldRetry(error: Error,
                            attempt: Int,
                            policy: ProviderRuntimePolicy,
                            deliveredSemanticOutput: Bool = false) -> Bool {
        guard !deliveredSemanticOutput, attempt < policy.maxAttempts else { return false }
        return isRetryable(error)
    }

    static func retryDelayNanoseconds(forNextAttempt nextAttempt: Int,
                                      policy: ProviderRuntimePolicy,
                                      retryHint: ProviderRetryHint? = nil) -> UInt64 {
        if let retryHint {
            let seconds = min(policy.maxRetryAfterDelaySeconds, max(0, retryHint.delaySeconds))
            return UInt64(seconds * 1_000_000_000)
        }
        let exponent = max(0, nextAttempt - 2)
        let seconds = min(policy.maxRetryDelaySeconds,
                          policy.initialRetryDelaySeconds * pow(2, Double(exponent)))
        return UInt64(seconds * 1_000_000_000)
    }

    static func exhausted(_ error: Error, attempts: Int, operation: String) -> Error {
        let normalized = ProviderErrorFormatting.transport(error)
        if normalized is ProviderUsageLimitError
            || normalized is ProviderContextWindowExceededError {
            return normalized
        }
        guard attempts > 1 else { return normalized }
        let suffix = " Retried \(attempts - 1) time\(attempts == 2 ? "" : "s"); still failed."
        if let intatis = normalized as? IntatisError {
            switch intatis {
            case .provider(let message):
                return IntatisError.provider(message + suffix)
            case .config(let message):
                return IntatisError.config(message + suffix)
            case .decoding(let message):
                return IntatisError.decoding(message + suffix)
            case .io(let message):
                return IntatisError.io(message + suffix)
            case .notFound(let message):
                return IntatisError.notFound(message + suffix)
            case .permissionDenied(let message):
                return IntatisError.permissionDenied(message + suffix)
            case .cancelled:
                return intatis
            }
        }
        return IntatisError.provider("\(operation) failed. \(normalized.localizedDescription)\(suffix)")
    }

    static func sleepBeforeRetry(nextAttempt: Int,
                                 policy: ProviderRuntimePolicy,
                                 retryHint: ProviderRetryHint? = nil) async throws {
        let delay = retryDelayNanoseconds(forNextAttempt: nextAttempt,
                                          policy: policy,
                                          retryHint: retryHint)
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        try Task.checkCancellation()
    }

    static func sendData(_ request: URLRequest,
                         via client: HTTPDataClient,
                         policy: ProviderRuntimePolicy,
                         operation: String) async throws -> Data {
        var attempt = 1
        while true {
            let response: HTTPDataResponse
            do {
                response = try await withTimeout(seconds: policy.requestTimeoutSeconds, operation: operation) {
                    try await client.sendResponse(request)
                }
            } catch {
                if shouldRetry(error: error, attempt: attempt, policy: policy) {
                    attempt += 1
                    try await sleepBeforeRetry(nextAttempt: attempt,
                                               policy: policy,
                                               retryHint: ProviderErrorFormatting.retryHint(from: error))
                    continue
                }
                throw exhausted(error, attempts: attempt, operation: operation)
            }

            if (200..<300).contains(response.status) {
                return response.data
            }

            let error = ProviderErrorFormatting.httpStatus(response.status,
                                                           body: response.data,
                                                           headers: response.headers,
                                                           operation: operation)
            if shouldRetry(error: error, attempt: attempt, policy: policy) {
                attempt += 1
                try await sleepBeforeRetry(nextAttempt: attempt,
                                           policy: policy,
                                           retryHint: ProviderErrorFormatting.retryHint(headers: response.headers))
                continue
            }
            throw exhausted(error, attempts: attempt, operation: operation)
        }
    }

    /// Sends a request whose body is already materialized as an owner-only
    /// temporary file. Keeping retry/timeout/status handling here gives file
    /// transcription the same provider runtime contract as other non-streaming
    /// operations while avoiding a second full multipart body allocation in
    /// the shipping transport.
    static func sendUploadResponse(
        _ request: URLRequest,
        fromFile fileURL: URL,
        via client: HTTPDataClient,
        policy: ProviderRuntimePolicy,
        operation: String
    ) async throws -> HTTPDataResponse {
        var attempt = 1
        while true {
            let response: HTTPDataResponse
            do {
                response = try await withTimeout(
                    seconds: policy.requestTimeoutSeconds,
                    operation: operation
                ) {
                    try await client.uploadResponse(
                        request,
                        fromFile: fileURL)
                }
            } catch {
                if shouldRetry(
                    error: error,
                    attempt: attempt,
                    policy: policy) {
                    attempt += 1
                    try await sleepBeforeRetry(
                        nextAttempt: attempt,
                        policy: policy,
                        retryHint: ProviderErrorFormatting.retryHint(
                            from: error))
                    continue
                }
                throw exhausted(
                    error,
                    attempts: attempt,
                    operation: operation)
            }

            if (200..<300).contains(response.status) {
                return response
            }

            let error = ProviderErrorFormatting.httpStatus(
                response.status,
                body: response.data,
                headers: response.headers,
                operation: operation)
            if shouldRetry(
                error: error,
                attempt: attempt,
                policy: policy) {
                attempt += 1
                try await sleepBeforeRetry(
                    nextAttempt: attempt,
                    policy: policy,
                    retryHint: ProviderErrorFormatting.retryHint(
                        headers: response.headers))
                continue
            }
            throw exhausted(
                error,
                attempts: attempt,
                operation: operation)
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double,
                                                 operation: String,
                                                 body: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeoutSeconds = max(seconds, 0.001)
        let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw Timeout(operation: operation, seconds: timeoutSeconds)
            }

            do {
                guard let value = try await group.next() else {
                    throw IntatisError.provider("\(operation) did not produce a result.")
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is ProviderUsageLimitError { return false }
        if error is ProviderContextWindowExceededError { return false }
        if let status = error as? ProviderHTTPStatusError {
            return ProviderErrorFormatting.isRetryableHTTPStatus(
                status.statusCode)
        }
        if let intatis = error as? IntatisError {
            switch intatis {
            case .cancelled, .config, .decoding, .permissionDenied, .notFound:
                return false
            case .io:
                return true
            case .provider(let message):
                return isRetryableProviderMessage(message)
            }
        }
        if let urlError = error as? URLError {
            return isRetryable(urlError)
        }
        if error is Timeout {
            return true
        }
        return isRetryableProviderMessage(error.localizedDescription)
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func isRetryableProviderMessage(_ message: String) -> Bool {
        if let status = ProviderErrorFormatting.httpStatusCode(from: message) {
            return ProviderErrorFormatting.isRetryableHTTPStatus(status)
        }
        let lower = message.lowercased()
        return lower.contains("timed out")
            || lower.contains("network connection")
            || lower.contains("connection to the provider was lost")
            || lower.contains("could not connect")
            || lower.contains("could not resolve")
    }

    private static func formatSeconds(_ value: Double) -> String {
        value >= 1 ? String(format: "%.0fs", value) : String(format: "%.2fs", value)
    }
}
