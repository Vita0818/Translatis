#if canImport(IntatisCurlTransport)
import Foundation
import IntatisCurlTransport

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum MCPCurlExecutorError: Error, Sendable {
    case invalidRequest
    case invalidResponse
    case responseHeadersTooLarge
    case connectedAddressMismatch
    case tlsPinMismatch
    case cancelled
    case transferFailed(Int32)
}

struct MCPCurlHopResult: @unchecked Sendable {
    let response: HTTPURLResponse
    let primaryIPAddress: String
}

struct MCPCurlRequest: Sendable {
    let request: URLRequest
    let resolvedAddresses: Set<String>
    let proxyPolicy: MCPHTTPProxyPolicy
    let tlsPolicy: MCPTLSPolicy
    let timeoutMilliseconds: Int
    let maximumHeaderBytes: Int
}

/// One-hop libcurl executor. `CURLOPT_RESOLVE` binds direct-mode sockets to
/// the exact address set authorized by the request preflight while the URL
/// retains its canonical hostname for Host, SNI, and certificate validation.
final class MCPCurlHTTPExecutor: @unchecked Sendable {
    typealias ResponseHandler =
        @Sendable (HTTPURLResponse) throws -> Void
    typealias DataHandler =
        @Sendable (Data) throws -> Bool
    private let lock = NSLock()
    private var active:
        [UUID: MCPCurlCallbackState] = [:]

    func perform(
        _ value: MCPCurlRequest,
        onResponse: @escaping ResponseHandler,
        onData: @escaping DataHandler
    ) async throws -> MCPCurlHopResult {
        let callbacks = MCPCurlCallbackState(
            requestURL: try Self.validatedURL(value.request),
            maximumHeaderBytes: value.maximumHeaderBytes,
            onResponse: onResponse,
            onData: onData)
        let operationID = UUID()
        lock.withLock {
            active[operationID] = callbacks
        }
        defer {
            lock.withLock {
                _ = active.removeValue(forKey: operationID)
            }
        }
        let worker = Task.detached(priority: .utility) {
            try Self.performBlocking(
                value,
                callbacks: callbacks)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            callbacks.cancel()
        }
    }

    func cancelAll() {
        let snapshot = lock.withLock {
            Array(active.values)
        }
        snapshot.forEach { $0.cancel() }
    }

    private static func validatedURL(
        _ request: URLRequest
    ) throws -> URL {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              request.httpMethod != nil else {
            throw MCPCurlExecutorError.invalidRequest
        }
        return url
    }

    private static func performBlocking(
        _ value: MCPCurlRequest,
        callbacks: MCPCurlCallbackState
    ) throws -> MCPCurlHopResult {
        let request = value.request
        let url = try validatedURL(request)
        guard let method = request.httpMethod,
              let host = url.host else {
            throw MCPCurlExecutorError.invalidRequest
        }
        let body = request.httpBody ?? Data()
        let requestHeaders =
            request.allHTTPHeaderFields ?? [:]
        let forbiddenHeaders: Set<String> = [
            "connection",
            "content-length",
            "cookie",
            "expect",
            "host",
            "proxy-authorization",
            "transfer-encoding",
        ]
        guard requestHeaders.allSatisfy({
            !forbiddenHeaders.contains(
                $0.key.lowercased())
                && !$0.key.isEmpty
                && !$0.key.contains("\0")
                && !$0.key.contains(where: \.isNewline)
                && !$0.value.contains("\0")
                && !$0.value.contains(where: \.isNewline)
        }) else {
            throw MCPCurlExecutorError.invalidRequest
        }
        let headerLines = requestHeaders
            .sorted { lhs, rhs in
                let comparison = lhs.key.localizedStandardCompare(
                    rhs.key)
                return comparison == .orderedSame
                    ? lhs.value < rhs.value
                    : comparison == .orderedAscending
            }
            .map { "\($0.key): \($0.value)" }
        let port = url.port ?? (
            url.scheme?.lowercased() == "https" ? 443 : 80)
        let resolveEntries = try Self.resolveEntries(
            host: host,
            port: port,
            addresses: value.resolvedAddresses,
            proxyPolicy: value.proxyPolicy)
        let publicKeyPins = try Self.curlPublicKeyPins(
            value.tlsPolicy)

        let allocatedHeaders = headerLines.map {
            $0.withCString { strdup($0) }
        }
        let allocatedResolve = resolveEntries.map {
            $0.withCString { strdup($0) }
        }
        defer {
            allocatedHeaders.forEach { free($0) }
            allocatedResolve.forEach { free($0) }
        }
        guard allocatedHeaders.allSatisfy({ $0 != nil }),
              allocatedResolve.allSatisfy({ $0 != nil }) else {
            throw MCPCurlExecutorError.invalidRequest
        }
        var headerPointers: [UnsafePointer<CChar>?] =
            allocatedHeaders.map {
                UnsafePointer<CChar>($0!)
        }
        var resolvePointers: [UnsafePointer<CChar>?] =
            allocatedResolve.map {
                UnsafePointer<CChar>($0!)
        }
        var statusCode: Int64 = 0
        var primaryIP = [CChar](repeating: 0, count: 128)
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let headerCount = headerPointers.count
        let resolveCount = resolvePointers.count

        let code: Int32 = url.absoluteString.withCString {
            urlCString in
            method.withCString { methodCString in
                publicKeyPins.withOptionalCString {
                    pinCString in
                    body.withUnsafeBytes { bodyBytes in
                        headerPointers.withUnsafeMutableBufferPointer {
                            headerBuffer in
                            resolvePointers
                                .withUnsafeMutableBufferPointer {
                                    resolveBuffer in
                                    var cRequest = intatis_curl_request(
                                        url: urlCString,
                                        method: methodCString,
                                        body: bodyBytes.baseAddress?
                                            .assumingMemoryBound(
                                                to: UInt8.self),
                                        body_length: body.count,
                                        headers: headerBuffer.baseAddress,
                                        header_count:
                                            headerCount,
                                        resolve_entries:
                                            resolveBuffer.baseAddress,
                                        resolve_entry_count:
                                            resolveCount,
                                        pinned_public_key:
                                            pinCString,
                                        timeout_milliseconds:
                                            Int64(max(
                                                100,
                                                value
                                                    .timeoutMilliseconds)),
                                        connect_timeout_milliseconds:
                                            Int64(min(
                                                30_000,
                                                max(
                                                    100,
                                                    value
                                                        .timeoutMilliseconds))),
                                        direct_proxy:
                                            value.proxyPolicy == .direct
                                                ? 1 : 0)
                                    return intatis_curl_perform(
                                        &cRequest,
                                        mcpCurlHeaderCallback,
                                        mcpCurlBodyCallback,
                                        mcpCurlCancelCallback,
                                        Unmanaged.passUnretained(
                                            callbacks).toOpaque(),
                                        &statusCode,
                                        &primaryIP,
                                        primaryIP.count,
                                        &errorBuffer,
                                        errorBuffer.count)
                                }
                        }
                    }
                }
            }
        }

        if let callbackError = callbacks.failure() {
            throw callbackError
        }
        if callbacks.isCancelled() {
            throw CancellationError()
        }
        let primary = String(cString: primaryIP)
        if value.proxyPolicy == .direct {
            guard !primary.isEmpty,
                  value.resolvedAddresses.contains(primary)
                    || Self.numericAddress(
                        primary,
                        equalsOneOf:
                            value.resolvedAddresses) else {
                throw MCPCurlExecutorError
                    .connectedAddressMismatch
            }
        }
        // CURLE_WRITE_ERROR is the expected result when a consumer has
        // already observed its exact SSE response and deliberately stopped
        // only this HTTP operation.
        if code
            == intatis_curl_code_ssl_pinned_public_key_mismatch() {
            throw MCPCurlExecutorError.tlsPinMismatch
        }
        if code != 0, !callbacks.didStopEarly() {
            throw MCPCurlExecutorError.transferFailed(code)
        }
        guard let response = callbacks.finalResponse(),
              response.statusCode == Int(statusCode)
                || statusCode == 0 else {
            throw MCPCurlExecutorError.invalidResponse
        }
        return MCPCurlHopResult(
            response: response,
            primaryIPAddress: primary)
    }

    static func curlPublicKeyPins(
        _ policy: MCPTLSPolicy
    ) throws -> String? {
        guard case .pinnedPublicKeySHA256(let values) = policy else {
            return nil
        }
        let rendered = try values.map { value -> String in
            guard value.count == 64 else {
                throw MCPCurlExecutorError.invalidRequest
            }
            var data = Data()
            data.reserveCapacity(32)
            var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(index, offsetBy: 2)
                guard let byte = UInt8(value[index..<next], radix: 16) else {
                    throw MCPCurlExecutorError.invalidRequest
                }
                data.append(byte)
                index = next
            }
            return "sha256//\(data.base64EncodedString())"
        }
        return rendered.joined(separator: ";")
    }

    private static func renderResolveAddress(
        _ value: String
    ) -> String {
        value.contains(":") ? "[\(value)]" : value
    }

    static func resolveEntries(
        host: String,
        port: Int,
        addresses: Set<String>,
        proxyPolicy: MCPHTTPProxyPolicy
    ) throws -> [String] {
        guard proxyPolicy == .direct,
              !isNumericAddress(host) else {
            return []
        }
        let rendered = addresses
            .sorted()
            .map(renderResolveAddress)
            .joined(separator: ",")
        guard !rendered.isEmpty else {
            throw MCPCurlExecutorError.invalidRequest
        }
        return ["\(host):\(port):\(rendered)"]
    }

    private static func isNumericAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, value, &ipv6) == 1
    }

    private static func numericAddress(
        _ value: String,
        equalsOneOf candidates: Set<String>
    ) -> Bool {
        var lhs4 = in_addr()
        if inet_pton(AF_INET, value, &lhs4) == 1 {
            return candidates.contains { candidate in
                var rhs4 = in_addr()
                return inet_pton(AF_INET, candidate, &rhs4) == 1
                    && memcmp(
                        &lhs4,
                        &rhs4,
                        MemoryLayout<in_addr>.size) == 0
            }
        }
        var lhs6 = in6_addr()
        if inet_pton(AF_INET6, value, &lhs6) == 1 {
            return candidates.contains { candidate in
                var rhs6 = in6_addr()
                return inet_pton(AF_INET6, candidate, &rhs6) == 1
                    && memcmp(
                        &lhs6,
                        &rhs6,
                        MemoryLayout<in6_addr>.size) == 0
            }
        }
        return false
    }
}

private final class MCPCurlCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private let requestURL: URL
    private let maximumHeaderBytes: Int
    private let onResponse:
        MCPCurlHTTPExecutor.ResponseHandler
    private let onData:
        MCPCurlHTTPExecutor.DataHandler
    private var totalHeaderBytes = 0
    private var currentStatusCode: Int?
    private var currentHeaders: [String: String] = [:]
    private var response: HTTPURLResponse?
    private var terminalError: Error?
    private var cancelled = false
    private var stoppedEarly = false
    private var redirectResponse = false

    init(
        requestURL: URL,
        maximumHeaderBytes: Int,
        onResponse:
            @escaping MCPCurlHTTPExecutor.ResponseHandler,
        onData:
            @escaping MCPCurlHTTPExecutor.DataHandler
    ) {
        self.requestURL = requestURL
        self.maximumHeaderBytes = max(1_024, maximumHeaderBytes)
        self.onResponse = onResponse
        self.onData = onData
    }

    func receiveHeader(
        bytes: UnsafePointer<UInt8>,
        length: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, terminalError == nil else { return 0 }
        guard length <= maximumHeaderBytes,
              totalHeaderBytes <= maximumHeaderBytes - length else {
            terminalError =
                MCPCurlExecutorError.responseHeadersTooLarge
            return 0
        }
        totalHeaderBytes += length
        let data = Data(bytes: bytes, count: length)
        guard let line = String(data: data, encoding: .isoLatin1) else {
            terminalError = MCPCurlExecutorError.invalidResponse
            return 0
        }
        let trimmed = line.trimmingCharacters(
            in: .newlines)
        if trimmed.hasPrefix("HTTP/") {
            let components = trimmed.split(
                whereSeparator: \.isWhitespace)
            guard components.count >= 2,
                  let status = Int(components[1]),
                  (100...599).contains(status) else {
                terminalError =
                    MCPCurlExecutorError.invalidResponse
                return 0
            }
            currentStatusCode = status
            currentHeaders = [:]
            return length
        }
        if trimmed.isEmpty {
            guard let status = currentStatusCode else {
                terminalError =
                    MCPCurlExecutorError.invalidResponse
                return 0
            }
            if (100..<200).contains(status) {
                currentStatusCode = nil
                currentHeaders = [:]
                return length
            }
            guard let value = HTTPURLResponse(
                url: requestURL,
                statusCode: status,
                httpVersion: nil,
                headerFields: currentHeaders) else {
                terminalError =
                    MCPCurlExecutorError.invalidResponse
                return 0
            }
            response = value
            redirectResponse = (300..<400).contains(status)
            if !redirectResponse {
                do {
                    try onResponse(value)
                } catch {
                    terminalError = error
                    return 0
                }
            }
            return length
        }
        guard !trimmed.first.map({
            $0 == " " || $0 == "\t"
        })!,
              let separator = trimmed.firstIndex(of: ":") else {
            terminalError = MCPCurlExecutorError.invalidResponse
            return 0
        }
        let name = String(trimmed[..<separator])
        let value = String(trimmed[
            trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            terminalError = MCPCurlExecutorError.invalidResponse
            return 0
        }
        let normalizedName = name.lowercased()
        if let existingName = currentHeaders.keys.first(where: {
            $0.lowercased() == normalizedName
        }) {
            let singletonHeaders: Set<String> = [
                "content-length",
                "content-type",
                "location",
                "mcp-session-id",
            ]
            guard !singletonHeaders.contains(normalizedName) else {
                terminalError =
                    MCPCurlExecutorError.invalidResponse
                return 0
            }
            currentHeaders[existingName] =
                "\(currentHeaders[existingName] ?? ""), \(value)"
        } else {
            currentHeaders[name] = value
        }
        return length
    }

    func receiveBody(
        bytes: UnsafePointer<UInt8>,
        length: Int
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, terminalError == nil else { return 0 }
        guard response != nil else {
            terminalError = MCPCurlExecutorError.invalidResponse
            return 0
        }
        if redirectResponse {
            stoppedEarly = true
            return 0
        }
        do {
            let shouldStop = try onData(
                Data(bytes: bytes, count: length))
            if shouldStop {
                stoppedEarly = true
                return 0
            }
            return length
        } catch {
            terminalError = error
            return 0
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func failure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    func didStopEarly() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedEarly
    }

    func finalResponse() -> HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

private let mcpCurlHeaderCallback:
    @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeMutableRawPointer?
    ) -> Int = { bytes, length, context in
        guard let bytes, let context else { return 0 }
        return Unmanaged<MCPCurlCallbackState>
            .fromOpaque(context)
            .takeUnretainedValue()
            .receiveHeader(bytes: bytes, length: length)
    }

private let mcpCurlBodyCallback:
    @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeMutableRawPointer?
    ) -> Int = { bytes, length, context in
        guard let bytes, let context else { return 0 }
        return Unmanaged<MCPCurlCallbackState>
            .fromOpaque(context)
            .takeUnretainedValue()
            .receiveBody(bytes: bytes, length: length)
    }

private let mcpCurlCancelCallback:
    @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Int32 = { context in
        guard let context else { return 1 }
        return Unmanaged<MCPCurlCallbackState>
            .fromOpaque(context)
            .takeUnretainedValue()
            .isCancelled() ? 1 : 0
    }

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        switch self {
        case .some(let value):
            return try value.withCString(body)
        case .none:
            return try body(nil)
        }
    }
}
#endif
