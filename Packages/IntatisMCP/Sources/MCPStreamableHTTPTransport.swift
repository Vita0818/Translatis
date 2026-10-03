#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol
import Logging
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Security)
import Security
#endif

public protocol MCPHTTPAuthorizationProviding: Sendable {
    /// Returns a complete Authorization value for the exact generation, or
    /// nil when this connection is anonymous. Implementations must fence
    /// account/token generation changes and fail instead of crossing identity.
    func authorizationHeader(
        for canonicalResource: URL,
        connectionGeneration: MCPConnectionGeneration
    ) async throws -> String?
}

public struct MCPNoHTTPAuthorization: MCPHTTPAuthorizationProviding {
    public init() {}

    public func authorizationHeader(
        for _: URL,
        connectionGeneration _: MCPConnectionGeneration
    ) async throws -> String? {
        nil
    }
}

public struct MCPStaticBearerAuthorization: MCPHTTPAuthorizationProviding {
    private let header: String

    public init(token: Data) throws {
        guard !token.isEmpty, token.count <= 1024 * 1024,
              let value = String(data: token, encoding: .utf8),
              !value.contains("\0"),
              !value.contains(where: \.isNewline) else {
            throw MCPSecretStoreError.valueTooLarge
        }
        header = "Bearer \(value)"
    }

    public func authorizationHeader(
        for _: URL,
        connectionGeneration _: MCPConnectionGeneration
    ) async throws -> String? {
        header
    }
}

public enum MCPHTTPGETStreamSupport: String, Equatable, Sendable {
    case unknown
    case supported
    case unsupported
}

public struct MCPHTTPTransportSnapshot: Equatable, Sendable {
    public let generation: MCPConnectionGeneration
    public let connected: Bool
    public let retired: Bool
    public let hasSession: Bool
    public let getStreamSupport: MCPHTTPGETStreamSupport
    public let activeStreams: Int

    public init(
        generation: MCPConnectionGeneration,
        connected: Bool,
        retired: Bool,
        hasSession: Bool,
        getStreamSupport: MCPHTTPGETStreamSupport,
        activeStreams: Int
    ) {
        self.generation = generation
        self.connected = connected
        self.retired = retired
        self.hasSession = hasSession
        self.getStreamSupport = getStreamSupport
        self.activeStreams = activeStreams
    }
}

/// Thread-safe session-header gate shared by the transport actor and the
/// URLSession/curl response callbacks. A response body is not admitted until
/// this gate has validated the header and synchronously registered a newly
/// issued identifier with the exact-value redactor.
private final class MCPHTTPSessionIdentifierGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumBytes: Int
    private let secretRedactionRegistrar:
        (any MCPSecretRedactionRegistering)?
    private var identifier: String?
    private var observedMismatch = false

    init(
        maximumBytes: Int,
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)?
    ) {
        self.maximumBytes = maximumBytes
        self.secretRedactionRegistrar =
            secretRedactionRegistrar
    }

    func accept(_ candidate: String?) throws {
        guard let candidate else { return }
        guard !candidate.isEmpty,
              candidate.utf8.count <= maximumBytes,
              !candidate.contains("\0"),
              !candidate.contains(where: \.isNewline) else {
            throw MCPHTTPTransportError.invalidSessionIdentifier
        }

        lock.lock()
        defer { lock.unlock() }
        if let identifier {
            guard identifier == candidate else {
                observedMismatch = true
                throw MCPHTTPTransportError.invalidSessionIdentifier
            }
            return
        }
        secretRedactionRegistrar?
            .registerMCPSecretRedactionValue(
                candidate)
        identifier = candidate
    }

    var currentIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return identifier
    }

    var requiresRetirement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMismatch
    }

    func clear() {
        lock.lock()
        identifier = nil
        lock.unlock()
    }
}

/// Intatis-owned implementation of MCP Streamable HTTP 2025-11-25.
///
/// It intentionally does not use the SDK's automatic authorization retry or
/// global Last-Event-ID state. Every POST is one operation, every SSE stream
/// has independent resume/deduplication state, and a session 404 retires the
/// exact connection generation without replaying a sent operation.
public actor MCPStreamableHTTPTransport:
    NegotiatedProtocolVersionTransport
{
    public nonisolated let logger: Logger
    public nonisolated let endpoint: URL
    public nonisolated let generation: MCPConnectionGeneration

    private let canonicalOrigin: String
    private let configuration: MCPHTTPServerConfiguration
    private let limits: MCPHTTPTransportLimits
    private let egressFence: MCPHTTPEgressFence
    private let authorizationProvider: any MCPHTTPAuthorizationProviding
    private let secretRedactionRegistrar:
        (any MCPSecretRedactionRegistering)?
    private let sessionIdentifierGate:
        MCPHTTPSessionIdentifierGate
    private let staticHeaders: [String: String]
    private let requestTimeoutMilliseconds: Int
    private let shutdownTimeoutMilliseconds: Int
    private let delegate: MCPHTTPURLSessionDelegate
    private let session: URLSession
    #if canImport(IntatisCurlTransport)
    private let curlExecutor: MCPCurlHTTPExecutor?
    #endif
    private let usesInjectedURLSessionTestSeam: Bool
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation:
        AsyncThrowingStream<Data, Error>.Continuation

    private var isConnected = false
    private var retiredState = false
    private var isStopping = false
    private var negotiatedProtocolVersion: String?
    private var getStreamSupport = MCPHTTPGETStreamSupport.unknown
    private var getStreamTask: Task<Void, Never>?
    private var getStreamState: MCPSSEStreamState?
    private var activeStreams = 0

    private var isRetired: Bool {
        get {
            retiredState
                || sessionIdentifierGate
                    .requiresRetirement
        }
        set {
            retiredState = newValue
        }
    }

    private var sessionIdentifier: String? {
        sessionIdentifierGate.currentIdentifier
    }

    public init(
        configuration: MCPHTTPServerConfiguration,
        generation: MCPConnectionGeneration,
        resolvedHeaders: [String: String] = [:],
        authorizationProvider: any MCPHTTPAuthorizationProviding =
            MCPNoHTTPAuthorization(),
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)? = nil,
        limits: MCPHTTPTransportLimits = .production,
        requestTimeoutMilliseconds: Int = 60_000,
        shutdownTimeoutMilliseconds: Int = 5_000,
        resolver: any MCPDNSResolving = MCPSystemDNSResolver(),
        egressAuthorizer: any MCPHTTPEgressAuthorizing =
            MCPExactOriginEgressPolicy(),
        logger: Logger? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            generation: generation,
            resolvedHeaders: resolvedHeaders,
            authorizationProvider: authorizationProvider,
            secretRedactionRegistrar:
                secretRedactionRegistrar,
            limits: limits,
            requestTimeoutMilliseconds:
                requestTimeoutMilliseconds,
            shutdownTimeoutMilliseconds:
                shutdownTimeoutMilliseconds,
            resolver: resolver,
            egressAuthorizer: egressAuthorizer,
            testingSessionConfiguration: nil,
            logger: logger)
    }

    init(
        configuration: MCPHTTPServerConfiguration,
        generation: MCPConnectionGeneration,
        resolvedHeaders: [String: String] = [:],
        authorizationProvider: any MCPHTTPAuthorizationProviding =
            MCPNoHTTPAuthorization(),
        secretRedactionRegistrar:
            (any MCPSecretRedactionRegistering)? = nil,
        limits: MCPHTTPTransportLimits = .production,
        requestTimeoutMilliseconds: Int = 60_000,
        shutdownTimeoutMilliseconds: Int = 5_000,
        resolver: any MCPDNSResolving = MCPSystemDNSResolver(),
        egressAuthorizer: any MCPHTTPEgressAuthorizing =
            MCPExactOriginEgressPolicy(),
        testingSessionConfiguration:
            URLSessionConfiguration?,
        logger: Logger? = nil
    ) throws {
        let sessionConfiguration =
            testingSessionConfiguration
        guard let endpoint = URL(string: configuration.endpoint),
              try MCPHTTPOrigin.canonical(endpoint)
                == Self.normalizedConfiguredOrigin(configuration.canonicalOrigin)
        else {
            throw MCPHTTPTransportError.invalidEndpoint
        }
        try Self.validateStaticHeaders(resolvedHeaders)
        try Self.validateAmbientProxyEnvironment(
            ProcessInfo.processInfo.environment,
            proxyPolicy: configuration.proxyPolicy)
        if sessionConfiguration != nil,
           case .pinnedPublicKeySHA256 =
                configuration.tlsPolicy {
            // The injected URLSession path is only a protocol test seam and
            // deliberately cannot emulate production DER-SPKI pinning.
            throw MCPHTTPTransportError.tlsPinningUnavailable
        }

        self.endpoint = endpoint
        self.generation = generation
        self.configuration = configuration
        self.canonicalOrigin = configuration.canonicalOrigin
        self.limits = limits
        self.authorizationProvider = authorizationProvider
        self.secretRedactionRegistrar =
            secretRedactionRegistrar
        self.sessionIdentifierGate =
            MCPHTTPSessionIdentifierGate(
                maximumBytes:
                    limits.maximumSessionIdentifierBytes,
                secretRedactionRegistrar:
                    secretRedactionRegistrar)
        self.staticHeaders = resolvedHeaders
        self.requestTimeoutMilliseconds = max(
            100,
            requestTimeoutMilliseconds)
        self.shutdownTimeoutMilliseconds = max(
            100,
            shutdownTimeoutMilliseconds)
        self.egressFence = try MCPHTTPEgressFence(
            endpoint: endpoint,
            canonicalOrigin: configuration.canonicalOrigin,
            resolver: resolver,
            authorizer: egressAuthorizer)
        self.logger = logger
            ?? Logger(
                label: IntatisHostApplication.identity
                    .namespacedIdentifier("mcp.http.client"),
                factory: { _ in SwiftLogNoOpLogHandler() })

        var continuation:
            AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream {
            continuation = $0
        }
        self.messageContinuation = continuation

        let delegate = MCPHTTPURLSessionDelegate(
            endpoint: endpoint,
            redirectPolicy: configuration.redirectPolicy,
            tlsPolicy: configuration.tlsPolicy)
        self.delegate = delegate
        usesInjectedURLSessionTestSeam =
            sessionConfiguration != nil
        #if canImport(IntatisCurlTransport)
        // The URLSession path exists only for deterministic URLProtocol test
        // injection. Production always uses the address-bound curl executor
        // and never falls back when curl setup or execution fails.
        curlExecutor = sessionConfiguration == nil
            ? MCPCurlHTTPExecutor()
            : nil
        #else
        guard sessionConfiguration != nil else {
            throw MCPHTTPTransportError.socketBindingUnavailable
        }
        #endif
        let prepared = Self.makeSessionConfiguration(
            base: sessionConfiguration,
            proxyPolicy: configuration.proxyPolicy)
        let queue = OperationQueue()
        queue.name = IntatisHostApplication.identity
            .namespacedIdentifier("mcp.http.url-session")
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(
            configuration: prepared,
            delegate: delegate,
            delegateQueue: queue)
    }

    public static func makeSessionConfiguration(
        base: URLSessionConfiguration? = nil,
        proxyPolicy: MCPHTTPProxyPolicy
    ) -> URLSessionConfiguration {
        let value = (base?.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.ephemeral
        value.httpCookieStorage = nil
        value.httpShouldSetCookies = false
        value.urlCache = nil
        value.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        value.httpAdditionalHeaders = nil
        switch proxyPolicy {
        case .direct:
            value.connectionProxyDictionary = [:]
        case .systemConfigured:
            // The user selected ambient system proxy behavior explicitly.
            break
        }
        return value
    }

    /// swift-corelibs-foundation does not currently guarantee that an empty
    /// `connectionProxyDictionary` disables libcurl's ambient proxy variables.
    /// A direct Linux connection therefore fails closed when any standard
    /// proxy variable is present; selecting `systemConfigured` is the explicit
    /// opt-in to ambient behavior.
    public static func validateAmbientProxyEnvironment(
        _ environment: [String: String],
        proxyPolicy: MCPHTTPProxyPolicy
    ) throws {
        try validateAmbientProxyEnvironment(
            environment,
            proxyPolicy: proxyPolicy,
            foundationNetworkingBacked:
                usesFoundationNetworking)
    }

    public static func validateAmbientProxyEnvironment(
        _ environment: [String: String],
        proxyPolicy: MCPHTTPProxyPolicy,
        foundationNetworkingBacked: Bool
    ) throws {
        guard foundationNetworkingBacked,
              proxyPolicy == .direct else {
            return
        }
        let denied = Set([
            "http_proxy",
            "https_proxy",
            "all_proxy",
            "no_proxy",
        ])
        guard !environment.keys.contains(where: {
            denied.contains($0.lowercased())
        }) else {
            throw MCPHTTPTransportError
                .ambientProxyDenied
        }
    }

    private static var usesFoundationNetworking: Bool {
        #if canImport(FoundationNetworking)
        return true
        #else
        return false
        #endif
    }

    /// Direct mode binds libcurl to the freshly authorized frozen answer set.
    /// `systemConfigured` is an explicit delegation to the configured proxy:
    /// the client must not claim that a local target lookup or primary-IP
    /// check constrains what that proxy resolves upstream.
    private func authorizedDirectAddresses()
        async throws -> Set<String>
    {
        switch configuration.proxyPolicy {
        case .direct:
            return try await egressFence.authorizeRequest()
        case .systemConfigured:
            return []
        }
    }

    public func connect() async throws {
        guard !isConnected else { return }
        guard !isRetired else {
            throw MCPHTTPTransportError.generationRetired(generation)
        }
        _ = try await authorizedDirectAddresses()
        isConnected = true
        isStopping = false
        logger.debug(
            "MCP HTTP generation connected",
            metadata: [
                "generation": "\(Self.safeGeneration(generation))",
                "origin": "\(canonicalOrigin)",
            ])
    }

    public func updateNegotiatedProtocolVersion(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 64,
              !value.contains(where: \.isWhitespace) else {
            throw MCPHTTPTransportError.invalidEndpoint
        }
        negotiatedProtocolVersion = value
        if isConnected, !isStopping, !isRetired,
           sessionIdentifier != nil, getStreamTask == nil,
           getStreamSupport != .unsupported
        {
            startGETStream()
        }
    }

    public func snapshot() -> MCPHTTPTransportSnapshot {
        MCPHTTPTransportSnapshot(
            generation: generation,
            connected: isConnected,
            retired: isRetired,
            hasSession: sessionIdentifier != nil,
            getStreamSupport: getStreamSupport,
            activeStreams: activeStreams)
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }

    public func send(_ data: Data) async throws {
        guard isConnected, !isStopping else {
            throw MCPHTTPTransportError.notConnected
        }
        guard !isRetired else {
            throw MCPHTTPTransportError.generationRetired(generation)
        }
        guard data.count <= limits.maximumRequestBytes else {
            throw MCPHTTPTransportError.requestTooLarge
        }

        let operation = MCPHTTPOperationDescriptor.classify(data)
        let expectedResponseID = mcpJSONRPCRequestID(in: data)
        let resolvedAddresses =
            try await authorizedDirectAddresses()
        let request = try await makeRequest(
            method: "POST",
            body: data,
            accept: "application/json, text/event-stream",
            lastEventID: nil)
        let streamState = MCPSSEStreamState(limits: limits)

        do {
            let result = try await perform(
                request,
                resolvedAddresses: resolvedAddresses,
                streamState: streamState,
                permitsEmptyAccepted: true,
                expectedResponseID: expectedResponseID)
            try acceptSessionIdentifier(result.sessionIdentifier)
            try handleStatus(
                result.response,
                operation: operation,
                requestWasDispatched: true)
            if let json = result.jsonBody, !json.isEmpty {
                messageContinuation.yield(json)
            }
            if result.sseEndedBeforeExpectedResponse,
               canResumePOSTStream(
                    state: streamState,
                    operation: operation,
                    error: MCPHTTPTransportError.disconnected)
            {
                try await resumePOSTStream(
                    state: streamState,
                    operation: operation,
                    expectedResponseID: expectedResponseID)
            }
            if sessionIdentifier != nil,
               negotiatedProtocolVersion != nil,
               getStreamTask == nil,
               getStreamSupport != .unsupported
            {
                startGETStream()
            }
        } catch {
            if canResumePOSTStream(
                state: streamState,
                operation: operation,
                error: error)
            {
                do {
                    try await resumePOSTStream(
                        state: streamState,
                        operation: operation,
                        expectedResponseID: expectedResponseID)
                    if sessionIdentifier != nil,
                       negotiatedProtocolVersion != nil,
                       getStreamTask == nil,
                       getStreamSupport != .unsupported
                    {
                        startGETStream()
                    }
                    return
                } catch {
                    if let transportError =
                        error as? MCPHTTPTransportError
                    {
                        throw mapDispatchedFailure(
                            transportError,
                            operation: operation)
                    }
                    if operation.risk.mayHaveSideEffects {
                        throw MCPHTTPTransportError.executionUncertain(
                            method: operation.method)
                    }
                    throw error
                }
            }
            if let transportError = error as? MCPHTTPTransportError {
                throw mapDispatchedFailure(
                    transportError,
                    operation: operation)
            }
            if operation.risk.mayHaveSideEffects {
                throw MCPHTTPTransportError.executionUncertain(
                    method: operation.method)
            }
            throw error
        }
    }

    private func canResumePOSTStream(
        state: MCPSSEStreamState,
        operation: MCPHTTPOperationDescriptor,
        error: Error
    ) -> Bool {
        guard operation.risk != .initialize,
              state.lastProcessedEventID != nil,
              sessionIdentifier != nil,
              negotiatedProtocolVersion != nil,
              !Task.isCancelled, !isStopping, !isRetired else {
            return false
        }
        if error is URLError { return true }
        // Foundation can surface an interrupted URLProtocol/HTTP body as
        // CancellationError even when the caller task itself was not
        // cancelled. The Task.isCancelled fence above keeps caller
        // cancellation terminal, while allowing the exact SSE stream to
        // resume without repeating its POST.
        if error is CancellationError { return true }
        if let value = error as? MCPHTTPTransportError,
           value == .disconnected {
            return true
        }
        return false
    }

    /// Resumes the exact POST-associated SSE stream by GET + Last-Event-ID.
    /// This never repeats the original JSON-RPC POST. A bounded sequence of
    /// resume attempts shares one absolute request deadline.
    private func resumePOSTStream(
        state: MCPSSEStreamState,
        operation: MCPHTTPOperationDescriptor,
        expectedResponseID: Data?
    ) async throws {
        let deadline = Date().addingTimeInterval(
            TimeInterval(requestTimeoutMilliseconds) / 1_000)
        var attempts = 0
        var lastError: Error = MCPHTTPTransportError.disconnected
        while attempts < 8, Date() < deadline,
              !Task.isCancelled, !isStopping, !isRetired
        {
            attempts += 1
            let delay = UInt64(state.retryMilliseconds) * 1_000_000
            try await Task.sleep(nanoseconds: delay)
            let resolvedAddresses =
                try await authorizedDirectAddresses()
            guard let lastEventID = state.lastProcessedEventID else {
                throw lastError
            }
            let request = try await makeRequest(
                method: "GET",
                body: nil,
                accept: "text/event-stream",
                lastEventID: lastEventID)
            let remaining = max(
                100,
                Int(deadline.timeIntervalSinceNow * 1_000))
            do {
                let result = try await perform(
                    request,
                    resolvedAddresses: resolvedAddresses,
                    streamState: state,
                    permitsEmptyAccepted: false,
                    timeoutMilliseconds: remaining,
                    expectedResponseID: expectedResponseID)
                try acceptSessionIdentifier(
                    result.sessionIdentifier)
                try handleStatus(
                    result.response,
                    operation: operation,
                    requestWasDispatched: true)
                if let json = result.jsonBody, !json.isEmpty {
                    messageContinuation.yield(json)
                }
                if result.sseEndedBeforeExpectedResponse {
                    lastError = MCPHTTPTransportError.disconnected
                    continue
                }
                return
            } catch {
                lastError = error
                guard canResumePOSTStream(
                    state: state,
                    operation: operation,
                    error: error) else {
                    throw error
                }
            }
        }
        throw lastError
    }

    public func disconnect() async {
        guard isConnected || isStopping else { return }
        isStopping = true

        if !isRetired, sessionIdentifier != nil {
            do {
                let resolvedAddresses =
                    try await authorizedDirectAddresses()
                let request = try await makeRequest(
                    method: "DELETE",
                    body: nil,
                    accept: "application/json",
                    lastEventID: nil)
                let result = try await perform(
                    request,
                    resolvedAddresses: resolvedAddresses,
                    streamState: nil,
                    permitsEmptyAccepted: true,
                    timeoutMilliseconds:
                        shutdownTimeoutMilliseconds)
                if result.response.statusCode != 405,
                   !(200..<300).contains(result.response.statusCode)
                {
                    logger.warning(
                        "MCP HTTP termination was not accepted",
                        metadata: [
                            "generation": "\(Self.safeGeneration(generation))",
                            "status": "\(result.response.statusCode)",
                        ])
                }
            } catch {
                logger.warning(
                    "MCP HTTP termination did not complete",
                    metadata: [
                        "generation": "\(Self.safeGeneration(generation))"
                    ])
            }
        }

        getStreamTask?.cancel()
        #if canImport(IntatisCurlTransport)
        curlExecutor?.cancelAll()
        #endif
        delegate.cancelAll()
        if let getStreamTask {
            await getStreamTask.value
        }
        self.getStreamTask = nil
        session.invalidateAndCancel()
        isConnected = false
        isStopping = false
        isRetired = true
        sessionIdentifierGate.clear()
        activeStreams = 0
        messageContinuation.finish()
        logger.debug(
            "MCP HTTP generation drained",
            metadata: [
                "generation": "\(Self.safeGeneration(generation))"
            ])
    }

    private func startGETStream() {
        let state = getStreamState ?? MCPSSEStreamState(limits: limits)
        getStreamState = state
        getStreamTask = Task { [weak self] in
            await self?.runGETStream(state: state)
        }
    }

    private func runGETStream(state: MCPSSEStreamState) async {
        while isConnected, !isStopping, !isRetired, !Task.isCancelled,
              getStreamSupport != .unsupported
        {
            do {
                let resolvedAddresses =
                    try await authorizedDirectAddresses()
                let request = try await makeRequest(
                    method: "GET",
                    body: nil,
                    accept: "text/event-stream",
                    lastEventID: state.lastProcessedEventID)
                let result = try await perform(
                    request,
                    resolvedAddresses: resolvedAddresses,
                    streamState: state,
                    permitsEmptyAccepted: false)
                try acceptSessionIdentifier(result.sessionIdentifier)
                if result.response.statusCode == 405 {
                    getStreamSupport = .unsupported
                    return
                }
                try handleStatus(
                    result.response,
                    operation: .init(
                        method: "GET-stream",
                        risk: .readOnlyRequest),
                    requestWasDispatched: true)
                getStreamSupport = .supported
            } catch is CancellationError {
                return
            } catch let error as MCPHTTPTransportError {
                switch error {
                case .sessionExpired, .generationRetired, .disconnected:
                    return
                default:
                    break
                }
            } catch {
                // A disconnected GET stream is resumable. No application
                // operation is replayed; only this exact stream reconnects.
            }

            guard isConnected, !isStopping, !isRetired, !Task.isCancelled else {
                return
            }
            let delay = UInt64(state.retryMilliseconds) * 1_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func perform(
        _ request: URLRequest,
        resolvedAddresses: Set<String>,
        streamState: MCPSSEStreamState?,
        permitsEmptyAccepted: Bool,
        timeoutMilliseconds: Int? = nil,
        expectedResponseID: Data? = nil
    ) async throws -> MCPHTTPTaskResult {
        guard activeStreams < limits.maximumConcurrentStreams else {
            throw MCPHTTPTransportError.tooManyStreams
        }
        activeStreams += 1
        defer { activeStreams -= 1 }

        let parser = streamState.map {
            MCPSSEParser(limits: limits, state: $0)
        }
        let operation = MCPHTTPTaskOperation(
            limits: limits,
            parser: parser,
            permitsEmptyAccepted: permitsEmptyAccepted,
            expectedResponseID: expectedResponseID,
            validateSessionIdentifier: {
                [sessionIdentifierGate] candidate in
                try sessionIdentifierGate.accept(
                    candidate)
            },
            onMessage: { [messageContinuation] data in
                messageContinuation.yield(data)
            })
        #if canImport(IntatisCurlTransport)
        if let curlExecutor {
            return try await performWithCurl(
                request,
                initialResolvedAddresses: resolvedAddresses,
                operation: operation,
                timeoutMilliseconds: max(
                    100,
                    timeoutMilliseconds
                        ?? requestTimeoutMilliseconds),
                executor: curlExecutor)
        }
        #endif
        guard usesInjectedURLSessionTestSeam else {
            throw MCPHTTPTransportError.socketBindingUnavailable
        }
        let task = session.dataTask(with: request)
        delegate.register(operation, for: task)
        task.resume()
        let timeout = max(
            100,
            timeoutMilliseconds ?? requestTimeoutMilliseconds)
        let watchdog = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(timeout) * 1_000_000)
            guard !Task.isCancelled else { return }
            task.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await operation.value()
        } onCancel: {
            task.cancel()
        }
    }

    #if canImport(IntatisCurlTransport)
    private func performWithCurl(
        _ request: URLRequest,
        initialResolvedAddresses: Set<String>,
        operation: MCPHTTPTaskOperation,
        timeoutMilliseconds: Int,
        executor: MCPCurlHTTPExecutor
    ) async throws -> MCPHTTPTaskResult {
        var current = request
        var resolvedAddresses = initialResolvedAddresses
        for redirectCount in 0...5 {
            let hop: MCPCurlHopResult
            do {
                hop = try await executor.perform(
                    MCPCurlRequest(
                        request: current,
                        resolvedAddresses: resolvedAddresses,
                        proxyPolicy: configuration.proxyPolicy,
                        tlsPolicy: configuration.tlsPolicy,
                        timeoutMilliseconds: timeoutMilliseconds,
                        maximumHeaderBytes:
                            limits.maximumHeaderBytes),
                    onResponse: { response in
                        try operation.receive(response: response)
                    },
                    onData: { data in
                        if try operation.receive(data: data) {
                            operation
                                .completeAfterExpectedSSEResponse()
                            return true
                        }
                        return false
                    })
            } catch {
                let mapped = Self.mapCurlError(error)
                operation.complete(error: mapped)
                return try await operation.value()
            }

            guard (300..<400).contains(
                hop.response.statusCode) else {
                operation.complete(error: nil)
                return try await operation.value()
            }
            guard configuration.redirectPolicy
                    == .sameOriginOnly,
                  redirectCount < 5,
                  let redirected = Self.redirectRequest(
                    from: current,
                    response: hop.response),
                  let redirectedURL = redirected.url,
                  MCPHTTPOrigin.isSameOrigin(
                    endpoint,
                    redirectedURL) else {
                let error =
                    MCPHTTPTransportError.redirectDenied
                operation.complete(error: error)
                return try await operation.value()
            }
            current = redirected
            // Each redirect hop repeats DNS/address authorization and receives
            // a fresh exact CURLOPT_RESOLVE binding for that hop.
            do {
                resolvedAddresses =
                    try await authorizedDirectAddresses()
            } catch {
                operation.complete(error: error)
                return try await operation.value()
            }
        }
        let error = MCPHTTPTransportError.redirectDenied
        operation.complete(error: error)
        return try await operation.value()
    }

    private static func redirectRequest(
        from request: URLRequest,
        response: HTTPURLResponse
    ) -> URLRequest? {
        guard let location = response.value(
            forHTTPHeaderField: "Location"),
              !location.isEmpty,
              location.utf8.count <= 16 * 1_024,
              let base = request.url,
              let url = URL(
                string: location,
                relativeTo: base)?.absoluteURL else {
            return nil
        }
        let method = request.httpMethod ?? "GET"
        if method != "GET" && method != "HEAD",
           response.statusCode != 307,
           response.statusCode != 308 {
            // Never rewrite or ambiguously replay a sent MCP operation.
            return nil
        }
        var redirected = request
        redirected.url = url
        redirected.setValue(
            nil,
            forHTTPHeaderField: "Cookie")
        redirected.setValue(
            nil,
            forHTTPHeaderField: "Proxy-Authorization")
        return redirected
    }

    private static func mapCurlError(
        _ error: Error
    ) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        guard let value = error as? MCPCurlExecutorError else {
            return error
        }
        switch value {
        case .responseHeadersTooLarge:
            return MCPHTTPTransportError
                .responseHeadersTooLarge
        case .connectedAddressMismatch:
            return MCPHTTPTransportError
                .connectedAddressMismatch
        case .tlsPinMismatch:
            return MCPHTTPTransportError.tlsPinMismatch
        case .invalidRequest:
            return MCPHTTPTransportError.invalidEndpoint
        case .invalidResponse:
            return MCPHTTPTransportError.disconnected
        case .cancelled:
            return CancellationError()
        case .transferFailed:
            return MCPHTTPTransportError.disconnected
        }
    }
    #endif

    private func makeRequest(
        method: String,
        body: Data?,
        accept: String,
        lastEventID: String?
    ) async throws -> URLRequest {
        guard try MCPHTTPOrigin.canonical(endpoint)
                == Self.normalizedConfiguredOrigin(canonicalOrigin)
        else {
            throw MCPHTTPTransportError.originMismatch
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type")
        }
        if sessionIdentifier != nil,
           negotiatedProtocolVersion == nil,
           method != "DELETE"
        {
            throw MCPHTTPTransportError.protocolVersionNotNegotiated
        }
        for (name, value) in staticHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method != "POST" || MCPHTTPOperationDescriptor.classify(
            body ?? Data()).risk != .initialize
        {
            if let negotiatedProtocolVersion {
                request.setValue(
                    negotiatedProtocolVersion,
                    forHTTPHeaderField: "MCP-Protocol-Version")
            }
        }
        if let sessionIdentifier {
            request.setValue(
                sessionIdentifier,
                forHTTPHeaderField: "MCP-Session-Id")
        }
        if let lastEventID {
            request.setValue(
                lastEventID,
                forHTTPHeaderField: "Last-Event-ID")
        }
        if let authorization = try await authorizationProvider
            .authorizationHeader(
                for: endpoint,
                connectionGeneration: generation)
        {
            guard !authorization.isEmpty,
                  authorization.utf8.count <= 1024 * 1024,
                  !authorization.contains("\0"),
                  !authorization.contains(where: \.isNewline) else {
                throw MCPHTTPTransportError.invalidEndpoint
            }
            registerAuthorizationForRedaction(
                authorization)
            request.setValue(
                authorization,
                forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private nonisolated func registerAuthorizationForRedaction(
        _ authorization: String
    ) {
        guard let secretRedactionRegistrar else {
            return
        }
        secretRedactionRegistrar
            .registerMCPSecretRedactionValue(
                authorization)
        guard let space =
                authorization.firstIndex(of: " ")
        else { return }
        let credential = String(
            authorization[
                authorization.index(after: space)...])
        guard !credential.isEmpty else { return }
        secretRedactionRegistrar
            .registerMCPSecretRedactionValue(
                credential)
        if authorization[..<space]
            .caseInsensitiveCompare("Basic")
                == .orderedSame,
           let decoded = Data(
                base64Encoded: credential) {
            secretRedactionRegistrar
                .registerMCPSecretRedactionValue(
                    decoded)
            if let colon = decoded.firstIndex(
                of: UInt8(ascii: ":")),
               colon < decoded.endIndex {
                secretRedactionRegistrar
                    .registerMCPSecretRedactionValue(
                        Data(decoded[
                            decoded.index(after: colon)...]))
            }
        }
    }

    private func acceptSessionIdentifier(_ candidate: String?) throws {
        try sessionIdentifierGate.accept(
            candidate)
    }

    private func handleStatus(
        _ response: HTTPURLResponse,
        operation: MCPHTTPOperationDescriptor,
        requestWasDispatched: Bool
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            let challenge = Self.parseChallenge(
                response,
                sideEffectsUncertain:
                    requestWasDispatched && operation.risk.mayHaveSideEffects)
            throw MCPHTTPTransportError.authenticationRequired(challenge)
        case 404 where sessionIdentifier != nil:
            isRetired = true
            getStreamTask?.cancel()
            if operation.risk.mayHaveSideEffects {
                throw MCPHTTPTransportError
                    .sessionExpiredAfterUncertainExecution(
                        generation: generation,
                        method: operation.method)
            }
            throw MCPHTTPTransportError.sessionExpired(generation)
        default:
            throw MCPHTTPTransportError.httpStatus(response.statusCode)
        }
    }

    private func mapDispatchedFailure(
        _ error: MCPHTTPTransportError,
        operation: MCPHTTPOperationDescriptor
    ) -> MCPHTTPTransportError {
        switch error {
        case .authenticationRequired, .sessionExpired,
                .sessionExpiredAfterUncertainExecution, .httpStatus,
                .requestTooLarge, .responseHeadersTooLarge,
                .responseBodyTooLarge, .sseFrameTooLarge,
                .sseStreamTooLarge, .invalidContentType,
                .invalidSessionIdentifier:
            return error
        default:
            if operation.risk.mayHaveSideEffects {
                return .executionUncertain(method: operation.method)
            }
            return error
        }
    }

    private static func parseChallenge(
        _ response: HTTPURLResponse,
        sideEffectsUncertain: Bool
    ) -> MCPOAuthChallenge {
        let headers = response.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        let parsed = DefaultOAuthWWWAuthenticateParser()
            .parseBearer(from: headers)
        let scopes = parsed?.scope.map {
            Set($0.split(whereSeparator: \.isWhitespace).map(String.init))
        } ?? []
        return MCPOAuthChallenge(
            statusCode: response.statusCode,
            resourceMetadataURL: parsed?.resourceMetadataURL,
            requiredScopes: scopes,
            errorCode: parsed?.error,
            sideEffectsUncertain: sideEffectsUncertain)
    }

    private static func validateStaticHeaders(
        _ headers: [String: String]
    ) throws {
        let forbidden: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "host",
            "content-length",
            "mcp-session-id",
            "mcp-protocol-version",
            "last-event-id",
        ]
        for (name, value) in headers {
            guard !forbidden.contains(name.lowercased()),
                  !name.isEmpty,
                  name.utf8.count <= 256,
                  value.utf8.count <= 64 * 1_024,
                  !name.contains(where: \.isNewline),
                  !value.contains("\0"),
                  !value.contains(where: \.isNewline) else {
                throw MCPHTTPTransportError.invalidEndpoint
            }
        }
    }

    private static func normalizedConfiguredOrigin(_ value: String) -> String {
        guard let url = URL(string: value),
              let origin = try? MCPHTTPOrigin.canonical(url) else {
            return value
        }
        return origin
    }

    private static func safeGeneration(
        _ value: MCPConnectionGeneration
    ) -> String {
        let digest = SHA256.hash(data: Data(value.rawValue.utf8))
        return digest.prefix(6).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

/// Returns a stable representation of a JSON-RPC request ID. Notifications,
/// malformed values, and batch payloads deliberately return nil.
private func mcpJSONRPCRequestID(in data: Data) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          object["method"] is String else {
        return nil
    }
    return mcpCanonicalJSONRPCID(object["id"])
}

/// Accept only response-shaped messages. A server-to-client request may reuse
/// the same scalar ID namespace and must not terminate the client request.
private func mcpJSONRPCResponseID(in data: Data) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          object["method"] == nil,
          object["result"] != nil || object["error"] != nil else {
        return nil
    }
    return mcpCanonicalJSONRPCID(object["id"])
}

private func mcpCanonicalJSONRPCID(_ value: Any?) -> Data? {
    guard let value, !(value is NSNull), !(value is Bool),
          value is String || value is NSNumber else {
        return nil
    }
    return try? JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed])
}

private struct MCPHTTPTaskResult: @unchecked Sendable {
    let response: HTTPURLResponse
    let sessionIdentifier: String?
    let jsonBody: Data?
    let sseEndedBeforeExpectedResponse: Bool
}

private final class MCPHTTPTaskOperation: @unchecked Sendable {
    private enum BodyMode {
        case undecided
        case none
        case json
        case sse
        case error
    }

    private let lock = NSLock()
    private let limits: MCPHTTPTransportLimits
    private let parser: MCPSSEParser?
    private let permitsEmptyAccepted: Bool
    private let expectedResponseID: Data?
    private let validateSessionIdentifier:
        @Sendable (String?) throws -> Void
    private let onMessage: @Sendable (Data) -> Void
    private var response: HTTPURLResponse?
    private var mode = BodyMode.undecided
    private var body = Data()
    private var terminal: Result<MCPHTTPTaskResult, Error>?
    private var continuation:
        CheckedContinuation<MCPHTTPTaskResult, Error>?
    private var deliveredExpectedResponse = false

    init(
        limits: MCPHTTPTransportLimits,
        parser: MCPSSEParser?,
        permitsEmptyAccepted: Bool,
        expectedResponseID: Data?,
        validateSessionIdentifier:
            @escaping @Sendable (String?) throws -> Void,
        onMessage: @escaping @Sendable (Data) -> Void
    ) {
        self.limits = limits
        self.parser = parser
        self.permitsEmptyAccepted = permitsEmptyAccepted
        self.expectedResponseID = expectedResponseID
        self.validateSessionIdentifier =
            validateSessionIdentifier
        self.onMessage = onMessage
    }

    func receive(response: HTTPURLResponse) throws {
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil else { return }
        let headerBytes = response.allHeaderFields.reduce(0) {
            $0 + String(describing: $1.key).utf8.count
                + String(describing: $1.value).utf8.count + 4
        }
        guard headerBytes <= limits.maximumHeaderBytes else {
            throw MCPHTTPTransportError.responseHeadersTooLarge
        }
        let nextMode: BodyMode
        guard (200..<300).contains(response.statusCode) else {
            nextMode = .error
            if !(300..<400).contains(
                response.statusCode)
            {
                try validateSessionIdentifier(
                    response.value(
                        forHTTPHeaderField:
                            "MCP-Session-Id"))
            }
            self.response = response
            mode = nextMode
            return
        }
        if response.statusCode == 202 || response.statusCode == 204 {
            nextMode = .none
        } else {
            let contentType = response.value(
                forHTTPHeaderField: "Content-Type")?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch contentType {
            case "application/json":
                nextMode = .json
            case "text/event-stream":
                guard parser != nil else {
                    throw MCPHTTPTransportError.invalidContentType
                }
                nextMode = .sse
            default:
                if permitsEmptyAccepted,
                   response.expectedContentLength == 0
                {
                    nextMode = .none
                } else {
                    throw MCPHTTPTransportError.invalidContentType
                }
            }
        }
        try validateSessionIdentifier(
            response.value(
                forHTTPHeaderField:
                    "MCP-Session-Id"))
        self.response = response
        mode = nextMode
    }

    func receive(data: Data) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminal == nil else { return false }
        switch mode {
        case .undecided:
            throw MCPHTTPTransportError.invalidContentType
        case .none:
            guard data.isEmpty else {
                throw MCPHTTPTransportError.responseBodyTooLarge
            }
        case .json, .error:
            guard body.count <= limits.maximumResponseBodyBytes - data.count else {
                throw MCPHTTPTransportError.responseBodyTooLarge
            }
            body.append(data)
        case .sse:
            guard let parser else {
                throw MCPHTTPTransportError.invalidContentType
            }
            for event in try parser.feed(data) {
                if let message = event.data, !message.isEmpty {
                    onMessage(message)
                    if let expectedResponseID,
                       mcpJSONRPCResponseID(in: message)
                        == expectedResponseID
                    {
                        deliveredExpectedResponse = true
                    }
                }
            }
        }
        return deliveredExpectedResponse
    }

    /// A POST-associated SSE stream may stay open indefinitely after yielding
    /// the response. Once that exact response ID is observed, finish only this
    /// URLSession operation and let the long-lived connection stream continue
    /// independently.
    func completeAfterExpectedSSEResponse() {
        lock.lock()
        guard terminal == nil, deliveredExpectedResponse,
              mode == .sse, let response else {
            lock.unlock()
            return
        }
        let result = Result<MCPHTTPTaskResult, Error>.success(
            MCPHTTPTaskResult(
                response: response,
                sessionIdentifier: response.value(
                    forHTTPHeaderField: "MCP-Session-Id"),
                jsonBody: nil,
                sseEndedBeforeExpectedResponse: false))
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func complete(error: Error?) {
        lock.lock()
        if terminal != nil {
            lock.unlock()
            return
        }
        let result: Result<MCPHTTPTaskResult, Error>
        if let error {
            result = .failure(error)
        } else if let response {
            do {
                if mode == .sse, let parser {
                    for event in try parser.finish() {
                        if let message = event.data, !message.isEmpty {
                            onMessage(message)
                        }
                    }
                }
                result = .success(MCPHTTPTaskResult(
                    response: response,
                    sessionIdentifier: response.value(
                        forHTTPHeaderField: "MCP-Session-Id"),
                    jsonBody: mode == .json ? body : nil,
                    sseEndedBeforeExpectedResponse:
                        mode == .sse
                        && expectedResponseID != nil
                        && !deliveredExpectedResponse))
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(MCPHTTPTransportError.disconnected)
        }
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation {
            continuation.resume(with: result)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        let result = Result<MCPHTTPTaskResult, Error>.failure(error)
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func value() async throws -> MCPHTTPTaskResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminal {
                lock.unlock()
                continuation.resume(with: terminal)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class MCPHTTPURLSessionDelegate:
    NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private let endpoint: URL
    private let redirectPolicy: MCPHTTPRedirectPolicy
    private let tlsPolicy: MCPTLSPolicy
    private var operations: [Int: MCPHTTPTaskOperation] = [:]
    private var tasks: [Int: URLSessionTask] = [:]

    init(
        endpoint: URL,
        redirectPolicy: MCPHTTPRedirectPolicy,
        tlsPolicy: MCPTLSPolicy
    ) {
        self.endpoint = endpoint
        self.redirectPolicy = redirectPolicy
        self.tlsPolicy = tlsPolicy
    }

    func register(
        _ operation: MCPHTTPTaskOperation,
        for task: URLSessionTask
    ) {
        lock.lock()
        operations[task.taskIdentifier] = operation
        tasks[task.taskIdentifier] = task
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let snapshot = Array(tasks.values)
        lock.unlock()
        snapshot.forEach { $0.cancel() }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allow: Bool
        switch redirectPolicy {
        case .deny:
            allow = false
        case .sameOriginOnly:
            allow = request.url.map {
                MCPHTTPOrigin.isSameOrigin(endpoint, $0)
            } ?? false
        }
        guard allow else {
            operation(for: task)?.fail(
                MCPHTTPTransportError.redirectDenied)
            task.cancel()
            completionHandler(nil)
            return
        }

        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        completionHandler(sanitized)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let operation = operation(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        do {
            try operation.receive(response: response)
            completionHandler(.allow)
        } catch {
            operation.fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let operation = operation(for: dataTask) else { return }
        do {
            if try operation.receive(data: data) {
                operation.completeAfterExpectedSSEResponse()
                dataTask.cancel()
            }
        } catch {
            operation.fail(error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let operation = operations.removeValue(
            forKey: task.taskIdentifier)
        tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        operation?.complete(error: error)
    }

    #if canImport(Security)
    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.serverTrust != nil else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch tlsPolicy {
        case .systemTrust:
            completionHandler(.performDefaultHandling, nil)
        case .pinnedPublicKeySHA256:
            failAll(MCPHTTPTransportError.tlsPinningUnavailable)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    #endif

    private func operation(
        for task: URLSessionTask
    ) -> MCPHTTPTaskOperation? {
        lock.lock()
        defer { lock.unlock() }
        return operations[task.taskIdentifier]
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let snapshot = Array(operations.values)
        let tasks = Array(self.tasks.values)
        lock.unlock()
        snapshot.forEach { $0.fail(error) }
        tasks.forEach { $0.cancel() }
    }
}
