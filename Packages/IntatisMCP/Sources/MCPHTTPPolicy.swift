import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct MCPHTTPTransportLimits: Equatable, Sendable {
    public let maximumRequestBytes: Int
    public let maximumResponseBodyBytes: Int
    public let maximumSSEFrameBytes: Int
    public let maximumSSEStreamBytes: Int
    public let maximumHeaderBytes: Int
    public let maximumConcurrentStreams: Int
    public let maximumSessionIdentifierBytes: Int
    public let minimumRetryMilliseconds: Int
    public let maximumRetryMilliseconds: Int

    public init(
        maximumRequestBytes: Int = 8 * 1_024 * 1_024,
        maximumResponseBodyBytes: Int = 16 * 1_024 * 1_024,
        maximumSSEFrameBytes: Int = 2 * 1_024 * 1_024,
        maximumSSEStreamBytes: Int = 64 * 1_024 * 1_024,
        maximumHeaderBytes: Int = 64 * 1_024,
        maximumConcurrentStreams: Int = 64,
        maximumSessionIdentifierBytes: Int = 4 * 1_024,
        minimumRetryMilliseconds: Int = 100,
        maximumRetryMilliseconds: Int = 60_000
    ) {
        self.maximumRequestBytes = max(1_024, maximumRequestBytes)
        self.maximumResponseBodyBytes = max(1_024, maximumResponseBodyBytes)
        self.maximumSSEFrameBytes = max(1_024, maximumSSEFrameBytes)
        self.maximumSSEStreamBytes = max(
            self.maximumSSEFrameBytes,
            maximumSSEStreamBytes)
        self.maximumHeaderBytes = max(1_024, maximumHeaderBytes)
        self.maximumConcurrentStreams = max(1, maximumConcurrentStreams)
        self.maximumSessionIdentifierBytes = max(
            128,
            maximumSessionIdentifierBytes)
        self.minimumRetryMilliseconds = max(10, minimumRetryMilliseconds)
        self.maximumRetryMilliseconds = max(
            self.minimumRetryMilliseconds,
            maximumRetryMilliseconds)
    }

    public static let production = MCPHTTPTransportLimits()
}

public enum MCPHTTPTransportError:
    Error, Equatable, LocalizedError, Sendable
{
    case notConnected
    case generationRetired(MCPConnectionGeneration)
    case invalidEndpoint
    case originMismatch
    case redirectDenied
    case ambientProxyDenied
    case dnsResolutionFailed
    case egressDenied
    case resolvedAddressSetChanged
    case socketBindingUnavailable
    case connectedAddressMismatch
    case tlsPinningUnavailable
    case tlsPinMismatch
    case requestTooLarge
    case responseHeadersTooLarge
    case responseBodyTooLarge
    case sseFrameTooLarge
    case sseStreamTooLarge
    case tooManyStreams
    case malformedSSE
    case invalidContentType
    case invalidSessionIdentifier
    case protocolVersionNotNegotiated
    case sessionExpired(MCPConnectionGeneration)
    case sessionExpiredAfterUncertainExecution(
        generation: MCPConnectionGeneration,
        method: String)
    case authenticationRequired(MCPOAuthChallenge)
    case httpStatus(Int)
    case executionUncertain(method: String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The MCP HTTP transport is not connected."
        case .generationRetired:
            return "The MCP HTTP connection generation has been retired."
        case .invalidEndpoint:
            return "The MCP HTTP endpoint is invalid."
        case .originMismatch:
            return "The MCP HTTP request is outside the configured origin."
        case .redirectDenied:
            return "The MCP HTTP redirect was denied."
        case .ambientProxyDenied:
            return "Ambient proxy use is not authorized for this MCP server."
        case .dnsResolutionFailed:
            return "The MCP server hostname could not be resolved."
        case .egressDenied:
            return "The resolved MCP server address is outside the egress policy."
        case .resolvedAddressSetChanged:
            return "The MCP server resolved address set changed between request preflight checks."
        case .socketBindingUnavailable:
            return "The MCP HTTP host cannot provide exact socket address binding."
        case .connectedAddressMismatch:
            return "The MCP HTTP socket connected outside the authorized address set."
        case .tlsPinningUnavailable:
            return "TLS public-key pinning is unavailable on this host."
        case .tlsPinMismatch:
            return "The MCP server TLS identity does not match the configured pins."
        case .requestTooLarge:
            return "The MCP HTTP request exceeds the configured limit."
        case .responseHeadersTooLarge:
            return "The MCP HTTP response headers exceed the configured limit."
        case .responseBodyTooLarge:
            return "The MCP HTTP response exceeds the configured limit."
        case .sseFrameTooLarge:
            return "An MCP SSE frame exceeds the configured limit."
        case .sseStreamTooLarge:
            return "An MCP SSE stream exceeds the configured limit."
        case .tooManyStreams:
            return "The MCP server exceeded the concurrent stream limit."
        case .malformedSSE:
            return "The MCP server sent malformed SSE data."
        case .invalidContentType:
            return "The MCP HTTP response content type is not supported."
        case .invalidSessionIdentifier:
            return "The MCP server returned an invalid session identifier."
        case .protocolVersionNotNegotiated:
            return "The MCP protocol version is not negotiated for this session."
        case .sessionExpired:
            return "The MCP server session expired; a new generation is required."
        case .sessionExpiredAfterUncertainExecution(_, let method):
            return "The MCP server session expired after \(method) was sent; execution is unknown and a new generation is required."
        case .authenticationRequired:
            return "The MCP server requires authorization."
        case .httpStatus(let status):
            return "The MCP HTTP server returned status \(status)."
        case .executionUncertain(let method):
            return "The sent MCP operation \(method) has an unknown execution outcome."
        case .disconnected:
            return "The MCP HTTP connection was closed."
        }
    }
}

public struct MCPOAuthChallenge: Equatable, Sendable {
    public let statusCode: Int
    public let resourceMetadataURL: URL?
    public let requiredScopes: Set<String>
    public let errorCode: String?
    public let sideEffectsUncertain: Bool

    public init(
        statusCode: Int,
        resourceMetadataURL: URL?,
        requiredScopes: Set<String>,
        errorCode: String?,
        sideEffectsUncertain: Bool = false
    ) {
        self.statusCode = statusCode
        self.resourceMetadataURL = resourceMetadataURL
        self.requiredScopes = requiredScopes
        self.errorCode = errorCode
        self.sideEffectsUncertain = sideEffectsUncertain
    }
}

public enum MCPHTTPOperationRisk: Equatable, Sendable {
    case initialize
    case notification
    case readOnlyRequest
    case sideEffectingRequest

    public var mayHaveSideEffects: Bool {
        self == .sideEffectingRequest
    }
}

public struct MCPHTTPOperationDescriptor: Equatable, Sendable {
    public let method: String
    public let risk: MCPHTTPOperationRisk

    public init(method: String, risk: MCPHTTPOperationRisk) {
        self.method = method
        self.risk = risk
    }

    public static func classify(_ data: Data) -> MCPHTTPOperationDescriptor {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let method = object["method"] as? String
        else {
            return MCPHTTPOperationDescriptor(
                method: "json-rpc-response",
                risk: .notification)
        }

        let hasID = object["id"] != nil
        if method == "initialize" {
            return .init(method: method, risk: .initialize)
        }
        if !hasID {
            return .init(method: method, risk: .notification)
        }
        let readOnlyMethods: Set<String> = [
            "ping",
            "tools/list",
            "resources/list",
            "resources/templates/list",
            "resources/read",
            "prompts/list",
            "prompts/get",
            "completion/complete",
            "tasks/get",
            "tasks/list",
            "tasks/result",
        ]
        return .init(
            method: method,
            risk: readOnlyMethods.contains(method)
                ? .readOnlyRequest
                : .sideEffectingRequest)
    }
}

public protocol MCPDNSResolving: Sendable {
    func addresses(for host: String, port: Int) async throws -> Set<String>
}

public struct MCPSystemDNSResolver: MCPDNSResolving {
    public static let defaultTimeoutMilliseconds = 5_000

    private let timeoutMilliseconds: Int

    public init(
        timeoutMilliseconds: Int = defaultTimeoutMilliseconds
    ) {
        self.timeoutMilliseconds = max(
            100,
            min(30_000, timeoutMilliseconds))
    }

    public func addresses(
        for host: String,
        port: Int
    ) async throws -> Set<String> {
        try await MCPBoundedSystemDNSPool.shared.resolve(
            host: host,
            port: port,
            timeoutMilliseconds: timeoutMilliseconds)
    }

    /// Synchronous entry point for the stdio launch planner. The blocking
    /// system resolver runs only on the same bounded quarantine pool used by
    /// HTTP/OAuth, and the caller never waits past the supplied deadline.
    public static func resolveSynchronously(
        host: String,
        port: Int,
        timeoutMilliseconds: Int = defaultTimeoutMilliseconds
    ) throws -> Set<String> {
        try MCPBoundedSystemDNSPool.shared.resolveSynchronously(
            host: host,
            port: port,
            timeoutMilliseconds: max(
                100,
                min(30_000, timeoutMilliseconds)))
    }
}

/// `getaddrinfo` has no portable cancellation contract on the supported
/// Darwin/musl hosts. Quarantining it behind a small admission-limited pool
/// gives requests a real deadline without creating an unbounded number of
/// detached tasks or threads. A timed-out system call may finish late, but its
/// result is generation-fenced and at most this many calls can remain active.
private final class MCPBoundedSystemDNSPool: @unchecked Sendable {
    static let shared = MCPBoundedSystemDNSPool()
    private static let maximumConcurrentResolutions = 4

    private let stateLock = NSLock()
    private var activeResolutions = 0
    private let workers = DispatchQueue(
        label: IntatisHostApplication.identity
            .keychainService("mcp.dns"),
        qos: .utility,
        attributes: .concurrent)
    private let deadlines = DispatchQueue(
        label: IntatisHostApplication.identity
            .keychainService("mcp.dns.deadlines"),
        qos: .utility)

    func resolve(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) async throws -> Set<String> {
        let gate = MCPDNSAsyncResolutionGate()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                continuation in
                gate.install(continuation)
                submit(
                    host: host,
                    port: port,
                    timeoutMilliseconds: timeoutMilliseconds,
                    gate: gate)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    func resolveSynchronously(
        host: String,
        port: Int,
        timeoutMilliseconds: Int
    ) throws -> Set<String> {
        guard acquire() else {
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        let box = MCPDNSBlockingResolutionBox()
        workers.async { [self, box] in
            let value = Result {
                try Self.resolveBlocking(host: host, port: port)
            }
            release()
            box.finish(value)
        }
        let wait = box.semaphore.wait(
            timeout: .now()
                + .milliseconds(timeoutMilliseconds))
        guard wait == .success,
              let result = box.result() else {
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        return try result.get()
    }

    private func submit(
        host: String,
        port: Int,
        timeoutMilliseconds: Int,
        gate: MCPDNSAsyncResolutionGate
    ) {
        guard !gate.isFinished else { return }
        guard acquire() else {
            gate.finish(
                .failure(
                    MCPHTTPTransportError
                        .dnsResolutionFailed))
            return
        }
        guard !gate.isFinished else {
            release()
            return
        }
        deadlines.asyncAfter(
            deadline: .now()
                + .milliseconds(timeoutMilliseconds)
        ) {
            gate.finish(
                .failure(
                    MCPHTTPTransportError
                        .dnsResolutionFailed))
        }
        workers.async { [self, gate] in
            let value = Result {
                try Self.resolveBlocking(host: host, port: port)
            }
            release()
            gate.finish(value)
        }
    }

    private func acquire() -> Bool {
        stateLock.withLock {
            guard activeResolutions
                    < Self.maximumConcurrentResolutions else {
                return false
            }
            activeResolutions += 1
            return true
        }
    }

    private func release() {
        stateLock.withLock {
            activeResolutions -= 1
        }
    }

    private static func resolveBlocking(
        host: String,
        port: Int
    ) throws -> Set<String> {
        guard !host.isEmpty,
              host.utf8.count <= 1_024,
              !host.contains("\0"),
              (1...65_535).contains(port) else {
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        var hints = addrinfo()
        // Preserve the complete A/AAAA answer set. Socket connection attempts
        // are bounded later; AI_ADDRCONFIG would silently discard a valid
        // family and make the frozen authorization set host-interface
        // dependent.
        hints.ai_flags = AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        #if canImport(Musl)
        hints.ai_socktype = SOCK_STREAM
        #elseif os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(
            host,
            String(port),
            &hints,
            &result)
        guard code == 0, let first = result else {
            if let result { freeaddrinfo(result) }
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        defer { freeaddrinfo(first) }

        var addresses: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var storage = [CChar](
                repeating: 0,
                count: Int(NI_MAXHOST))
            let nameCode = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &storage,
                socklen_t(storage.count),
                nil,
                0,
                NI_NUMERICHOST)
            if nameCode == 0 {
                addresses.insert(String(cString: storage))
            }
            cursor = current.pointee.ai_next
        }
        guard !addresses.isEmpty else {
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        return addresses
    }
}

private final class MCPDNSAsyncResolutionGate:
    @unchecked Sendable
{
    typealias Output = Set<String>

    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<Output, Error>?
    private var terminal: Result<Output, Error>?

    var isFinished: Bool {
        lock.withLock { terminal != nil }
    }

    func install(
        _ value: CheckedContinuation<Output, Error>
    ) {
        let completed = lock.withLock {
            () -> Result<Output, Error>? in
            if let terminal { return terminal }
            continuation = value
            return nil
        }
        if let completed {
            value.resume(with: completed)
        }
    }

    func finish(_ value: Result<Output, Error>) {
        let waiter = lock.withLock {
            () -> CheckedContinuation<Output, Error>? in
            guard terminal == nil else { return nil }
            terminal = value
            let waiter = continuation
            continuation = nil
            return waiter
        }
        waiter?.resume(with: value)
    }
}

private final class MCPDNSBlockingResolutionBox:
    @unchecked Sendable
{
    typealias Output = Set<String>

    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Result<Output, Error>?

    func finish(_ result: Result<Output, Error>) {
        lock.withLock {
            guard value == nil else { return }
            value = result
        }
        semaphore.signal()
    }

    func result() -> Result<Output, Error>? {
        lock.withLock { value }
    }
}

public protocol MCPHTTPEgressAuthorizing: Sendable {
    func authorize(
        canonicalOrigin: String,
        resolvedAddresses: Set<String>
    ) throws
}

/// Default exact-origin policy. It rejects unspecified, multicast, link-local,
/// and private address space unless that class was explicitly enabled by the
/// server attachment policy.
public struct MCPExactOriginEgressPolicy: MCPHTTPEgressAuthorizing {
    public let allowsPrivateAddresses: Bool
    public let allowsLoopback: Bool

    public init(
        allowsPrivateAddresses: Bool = false,
        allowsLoopback: Bool = false
    ) {
        self.allowsPrivateAddresses = allowsPrivateAddresses
        self.allowsLoopback = allowsLoopback
    }

    public func authorize(
        canonicalOrigin _: String,
        resolvedAddresses: Set<String>
    ) throws {
        guard !resolvedAddresses.isEmpty else {
            throw MCPHTTPTransportError.dnsResolutionFailed
        }
        for value in resolvedAddresses {
            let category = MCPIPAddressCategory.classify(value)
            switch category {
            case .public:
                continue
            case .private:
                guard allowsPrivateAddresses else {
                    throw MCPHTTPTransportError.egressDenied
                }
            case .loopback:
                guard allowsLoopback else {
                    throw MCPHTTPTransportError.egressDenied
                }
            case .denied:
                throw MCPHTTPTransportError.egressDenied
            }
        }
    }
}

/// Request-time DNS/address policy preflight. Production HTTP/OAuth callers
/// pass the returned exact set to the libcurl socket binding for the same hop;
/// TLS hostname validation remains bound to the original URL host.
public actor MCPHTTPEgressFence {
    private let canonicalOrigin: String
    private let host: String
    private let port: Int
    private let resolver: any MCPDNSResolving
    private let authorizer: any MCPHTTPEgressAuthorizing
    private var frozenAddresses: Set<String>?

    public init(
        endpoint: URL,
        canonicalOrigin: String,
        resolver: any MCPDNSResolving = MCPSystemDNSResolver(),
        authorizer: any MCPHTTPEgressAuthorizing =
            MCPExactOriginEgressPolicy()
    ) throws {
        guard let host = endpoint.host, !host.isEmpty else {
            throw MCPHTTPTransportError.invalidEndpoint
        }
        self.canonicalOrigin = canonicalOrigin
        self.host = host
        self.port = endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)
        self.resolver = resolver
        self.authorizer = authorizer
    }

    @discardableResult
    public func authorizeRequest() async throws -> Set<String> {
        let addresses = try await resolver.addresses(for: host, port: port)
        try authorizer.authorize(
            canonicalOrigin: canonicalOrigin,
            resolvedAddresses: addresses)
        if let frozenAddresses {
            guard addresses == frozenAddresses else {
                throw MCPHTTPTransportError
                    .resolvedAddressSetChanged
            }
        } else {
            frozenAddresses = addresses
        }
        return addresses
    }

    public func reset() {
        frozenAddresses = nil
    }
}

enum MCPHTTPOrigin {
    static func canonical(_ url: URL) throws -> String {
        guard
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false),
            let schemeValue = components.scheme?.lowercased(),
            schemeValue == "https" || schemeValue == "http",
            let hostValue = components.host?.lowercased(),
            !hostValue.isEmpty,
            components.user == nil,
            components.password == nil
        else {
            throw MCPHTTPTransportError.invalidEndpoint
        }
        components.scheme = schemeValue
        components.host = hostValue
        let defaultPort = schemeValue == "https" ? 443 : 80
        let port = components.port ?? defaultPort
        let normalizedHost = hostValue.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        let renderedHost = normalizedHost.contains(":")
            ? "[\(normalizedHost)]"
            : normalizedHost
        return "\(schemeValue)://\(renderedHost):\(port)"
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        (try? canonical(lhs)) == (try? canonical(rhs))
    }
}

private enum MCPIPAddressCategory {
    case `public`
    case `private`
    case loopback
    case denied

    static func classify(_ value: String) -> MCPIPAddressCategory {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) {
                Array($0)
            }
            return classifyIPv4(bytes)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            guard bytes.count == 16 else { return .denied }
            let firstTwelveAreZero =
                bytes.prefix(12).allSatisfy { $0 == 0 }
            if bytes.dropLast().allSatisfy({ $0 == 0 }),
               bytes.last == 1 {
                return .loopback
            }
            if bytes.allSatisfy({ $0 == 0 }) {
                return .denied
            }
            // IPv4-mapped and deprecated IPv4-compatible forms must inherit
            // the embedded IPv4 classification. Otherwise
            // `::ffff:127.0.0.1` would look like a public IPv6 address.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[10] == 0xff,
               bytes[11] == 0xff {
                return classifyIPv4(Array(bytes.suffix(4)))
            }
            if firstTwelveAreZero {
                return classifyIPv4(Array(bytes.suffix(4)))
            }
            if bytes[0] & 0xfe == 0xfc {
                return .private
            }
            if bytes[0] == 0xff
                || (bytes[0] == 0xfe
                    && bytes[1] & 0xc0 == 0x80)
                || (bytes[0] == 0xfe
                    && bytes[1] & 0xc0 == 0xc0)
            {
                return .denied
            }
            // Translation/tunnel/documentation ranges can encode an address
            // whose true destination is not represented by the outer IPv6
            // category. Direct MCP egress denies them rather than treating
            // them as ordinary global-unicast endpoints.
            if Array(bytes.prefix(12))
                    == [0x00, 0x64, 0xff, 0x9b,
                        0, 0, 0, 0, 0, 0, 0, 0]
                || Array(bytes.prefix(4))
                    == [0x20, 0x01, 0x00, 0x00]
                || Array(bytes.prefix(4))
                    == [0x20, 0x01, 0x0d, 0xb8]
                || Array(bytes.prefix(2)) == [0x20, 0x02]
            {
                return .denied
            }
            guard bytes[0] & 0xe0 == 0x20 else {
                return .denied
            }
            return .public
        }
        return .denied
    }

    private static func classifyIPv4(
        _ bytes: [UInt8]
    ) -> MCPIPAddressCategory {
        guard bytes.count == 4 else { return .denied }
        if bytes[0] == 127 { return .loopback }
        if bytes[0] == 10
            || (bytes[0] == 172
                && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
        {
            return .private
        }
        if bytes[0] == 0
            || bytes[0] >= 224
            || (bytes[0] == 100
                && (64...127).contains(bytes[1]))
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 192 && bytes[1] == 0
                && bytes[2] == 0)
            || (bytes[0] == 192 && bytes[1] == 0
                && bytes[2] == 2)
            || (bytes[0] == 198
                && (bytes[1] == 18 || bytes[1] == 19))
            || (bytes[0] == 198 && bytes[1] == 51
                && bytes[2] == 100)
            || (bytes[0] == 203 && bytes[1] == 0
                && bytes[2] == 113)
        {
            return .denied
        }
        return .public
    }
}
