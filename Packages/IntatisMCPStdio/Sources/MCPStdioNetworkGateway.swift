import Foundation
import IntatisCore
import IntatisMCP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One canonical HTTPS origin admitted by a local stdio authority.
///
/// The gateway intentionally stores only host and port. The child still
/// performs the TLS handshake through the CONNECT tunnel, so the original
/// hostname remains the HTTP Host and TLS SNI value.
struct MCPStdioCanonicalNetworkOrigin: Hashable, Sendable {
    let host: String
    let port: UInt16

    init(_ origin: String) throws {
        guard origin.utf8.count <= 8 * 1_024,
              let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        let normalizedHost = rawHost.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        guard !normalizedHost.isEmpty,
              !normalizedHost.contains("\0"),
              let rawPort = components.port ?? 443 as Int?,
              (1...65_535).contains(rawPort) else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        host = normalizedHost
        port = UInt16(rawPort)
    }

    var authority: String {
        host.contains(":")
            ? "[\(host)]:\(port)"
            : "\(host):\(port)"
    }
}

struct MCPStdioFrozenNetworkAddress: Hashable, Sendable {
    let family: Int32
    let bytes: Data

    init(family: Int32, bytes: Data) throws {
        let expected: Int
        switch family {
        case AF_INET:
            expected = MemoryLayout<sockaddr_in>.size
        case AF_INET6:
            expected = MemoryLayout<sockaddr_in6>.size
        default:
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        guard bytes.count == expected else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        self.family = family
        self.bytes = bytes
    }
}

struct MCPStdioFrozenNetworkEndpoint: Hashable, Sendable {
    let origin: MCPStdioCanonicalNetworkOrigin
    let addresses: [MCPStdioFrozenNetworkAddress]
}

/// Strict, body-free HTTP/1.1 CONNECT request parser.
///
/// This is deliberately much smaller than a general HTTP parser. Supporting
/// proxy authentication, forwarding requests, upgrade methods, request
/// bodies, or arbitrary extension headers would enlarge the child's network
/// authority beyond the exact HTTPS tunnel contract.
enum MCPStdioConnectRequestParser {
    static let maximumHeaderBytes = 16 * 1_024

    static func parse(
        _ data: Data,
        expectedProxyAuthorization: [UInt8]
    ) throws
        -> MCPStdioCanonicalNetworkOrigin
    {
        guard !data.isEmpty,
              data.count <= maximumHeaderBytes,
              !data.contains(0),
              data.suffix(4) == Data([13, 10, 13, 10]),
              let request = String(data: data, encoding: .utf8),
              request.unicodeScalars.allSatisfy({
                  $0.value == 9 || $0.value == 13
                      || $0.value == 10
                      || ($0.value >= 32 && $0.value <= 126)
              }),
              !request.replacingOccurrences(
                  of: "\r\n",
                  with: "").contains("\n"),
              !request.replacingOccurrences(
                  of: "\r\n",
                  with: "").contains("\r") else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }

        guard let headerText = String(
            data: Data(data.dropLast(4)),
            encoding: .utf8) else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              !requestLine.contains("\t") else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        let requestParts = requestLine.split(
            separator: " ",
            omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[0] == "CONNECT",
              requestParts[2] == "HTTP/1.1" else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        let rawAuthority = String(requestParts[1])
        let origin = try parseAuthority(rawAuthority)

        var headers: [String: String] = [:]
        let allowedHeaders = Set([
            "host",
            "proxy-connection",
            "connection",
            "user-agent",
            "proxy-authorization",
        ])
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ",
                  line.first != "\t",
                  let colon = line.firstIndex(of: ":") else {
                throw MCPManagedPipeError.invalidNetworkOrigin
            }
            let rawName = line[..<colon]
            let name = rawName.lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !rawName.isEmpty,
                  rawName.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics
                          .union(CharacterSet(charactersIn: "-"))
                          .contains($0)
                  }),
                  allowedHeaders.contains(name),
                  headers[name] == nil,
                  value.utf8.count <= 1_024 else {
                throw MCPManagedPipeError.invalidNetworkOrigin
            }
            if name == "connection" || name == "proxy-connection" {
                let normalized = value.lowercased()
                guard normalized == "keep-alive"
                        || normalized == "close" else {
                    throw MCPManagedPipeError.invalidNetworkOrigin
                }
            }
            headers[name] = value
        }
        guard let host = headers["host"],
              try parseAuthority(host) == origin,
              let authorization = headers["proxy-authorization"],
              constantTimeEqual(
                  Array(authorization.utf8),
                  expectedProxyAuthorization) else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        return origin
    }

    static func parseAuthority(
        _ rawAuthority: String
    ) throws -> MCPStdioCanonicalNetworkOrigin {
        guard !rawAuthority.isEmpty,
              rawAuthority.utf8.count <= 1_024,
              !rawAuthority.contains("/"),
              !rawAuthority.contains("?"),
              !rawAuthority.contains("#"),
              !rawAuthority.contains("@"),
              let components = URLComponents(
                  string: "https://\(rawAuthority)"),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.port != nil else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        return try MCPStdioCanonicalNetworkOrigin(
            "https://\(rawAuthority)")
    }

    static func constantTimeEqual(
        _ left: [UInt8],
        _ right: [UInt8]
    ) -> Bool {
        let maximum = max(left.count, right.count)
        var difference = UInt64(left.count ^ right.count)
        for index in 0..<maximum {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= UInt64(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

/// Host-owned exact-origin CONNECT gateway used by local stdio generations.
///
/// DNS is resolved once before the child starts. Each tunnel connects directly
/// to one frozen sockaddr; no URLSession, system proxy, ambient proxy, or
/// post-start DNS lookup is involved. The child can reach only this exact
/// loopback listener at the OS sandbox boundary.
final class MCPStdioExactNetworkGateway: @unchecked Sendable {
    static let maximumConcurrentTunnels = 32
    static let maximumBytesPerDirection: UInt64 =
        256 * 1_024 * 1_024
    static let connectTimeoutMilliseconds = 5_000
    static let headerTimeoutMilliseconds = 5_000
    static let idleTimeoutMilliseconds = 300_000

    let port: UInt16
    let endpoints: [MCPStdioFrozenNetworkEndpoint]

    private let listener: Int32
    private let stateLock = NSLock()
    private let workerGroup = DispatchGroup()
    private let acceptQueue = DispatchQueue(
        label: IntatisHostApplication.identity
            .keychainService("mcp.stdio.network.accept"))
    private var acceptSource: DispatchSourceRead?
    private let workerQueue = DispatchQueue(
        label: IntatisHostApplication.identity
            .keychainService("mcp.stdio.network.tunnel"),
        attributes: .concurrent)
    private var stopping = false
    private var activeTunnels = 0
    private var activeDescriptors: Set<Int32> = []
    private var proxyURLStorage: String
    private var expectedProxyAuthorization: [UInt8]
    private let initialDiagnosticRedactionValues: [String]

    init(origins: [String]) throws {
        let canonical = try origins.map(
            MCPStdioCanonicalNetworkOrigin.init)
        guard !canonical.isEmpty,
              Set(canonical).count == canonical.count else {
            throw MCPManagedPipeError.invalidNetworkOrigin
        }
        endpoints = try canonical.sorted {
            if $0.host == $1.host { return $0.port < $1.port }
            return $0.host < $1.host
        }.map { origin in
            let addresses = try Self.resolve(origin)
            guard !addresses.isEmpty else {
                throw MCPManagedPipeError.exactNetworkPolicyUnavailable
            }
            return MCPStdioFrozenNetworkEndpoint(
                origin: origin,
                addresses: addresses)
        }

        let credential = Self.makeCredential()
        let proxyUser = IntatisHostApplication.identity.fileNameStem
        let basicPayload = Data(
            "\(proxyUser):\(credential)".utf8).base64EncodedString()
        let authorization = "Basic \(basicPayload)"
        let proxyURL =
            "http://\(proxyUser):\(credential)@127.0.0.1"

        let bound = try Self.makeListener()
        listener = bound.descriptor
        port = bound.port
        proxyURLStorage = "\(proxyURL):\(bound.port)"
        expectedProxyAuthorization = Array(authorization.utf8)
        initialDiagnosticRedactionValues = [
            credential,
            basicPayload,
            authorization,
            proxyURLStorage,
        ]
        let source = DispatchSource.makeReadSource(
            fileDescriptor: listener,
            queue: acceptQueue)
        acceptSource = source
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler { [listener] in
            _ = close(listener)
        }
        source.resume()
    }

    deinit {
        stop()
    }

    var proxyURL: String {
        stateLock.withLock { proxyURLStorage }
    }

    var diagnosticRedactionValues: [String] {
        initialDiagnosticRedactionValues
    }

    func registerDiagnosticRedactionValues(
        with registrar: any MCPSecretRedactionRegistering
    ) {
        for value in initialDiagnosticRedactionValues {
            registrar.registerMCPSecretRedactionValue(
                Data(value.utf8))
        }
    }

    func stop() {
        let transitioned = stateLock.withLock {
            if stopping { return false }
            stopping = true
            for index in expectedProxyAuthorization.indices {
                expectedProxyAuthorization[index] = 0
            }
            expectedProxyAuthorization.removeAll(keepingCapacity: false)
            proxyURLStorage = ""
            /*
             * Workers remove an fd under this same lock before closing it.
             * Shutdown while holding the lock therefore cannot race an fd
             * close/reuse and accidentally affect an unrelated host socket.
             */
            for descriptor in activeDescriptors {
                _ = shutdown(descriptor, Int32(SHUT_RDWR))
            }
            return true
        }
        guard transitioned else { return }
        acceptSource?.cancel()
        _ = workerGroup.wait(timeout: .now() + .seconds(2))
    }

    private func acceptAvailableConnections() {
        while !isStopping {
            var address = sockaddr_storage()
            var length = socklen_t(
                MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1) {
                    accept(listener, $0, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            guard Self.configureDescriptor(client) else {
                _ = close(client)
                continue
            }
            let admitted = stateLock.withLock { () -> Bool in
                guard !stopping,
                      activeTunnels < Self.maximumConcurrentTunnels else {
                    return false
                }
                activeTunnels += 1
                activeDescriptors.insert(client)
                workerGroup.enter()
                return true
            }
            guard admitted else {
                Self.sendRejection(client, status: 503)
                _ = close(client)
                continue
            }
            let group = workerGroup
            workerQueue.async { [weak self, group] in
                guard let self else {
                    _ = close(client)
                    group.leave()
                    return
                }
                self.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var remote: Int32 = -1
        defer {
            stateLock.withLock {
                activeDescriptors.remove(client)
                if remote >= 0 {
                    activeDescriptors.remove(remote)
                }
                activeTunnels -= 1
            }
            _ = close(client)
            if remote >= 0 { _ = close(remote) }
            workerGroup.leave()
        }
        do {
            let header = try receiveHeader(client)
            let expectedAuthorization = stateLock.withLock {
                expectedProxyAuthorization
            }
            guard !expectedAuthorization.isEmpty else { return }
            let requested = try MCPStdioConnectRequestParser.parse(
                header,
                expectedProxyAuthorization: expectedAuthorization)
            guard let endpoint = endpoints.first(where: {
                $0.origin == requested
            }) else {
                Self.sendRejection(client, status: 403)
                return
            }
            remote = try connectDirect(endpoint)
            let registered = stateLock.withLock { () -> Bool in
                !stopping && activeDescriptors.contains(remote)
            }
            guard registered else { return }
            try writeAll(
                Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                to: client,
                timeoutMilliseconds: Self.connectTimeoutMilliseconds)
            try tunnel(client: client, remote: remote)
        } catch {
            if remote < 0 {
                Self.sendRejection(client, status: 400)
            }
        }
    }

    private func receiveHeader(_ descriptor: Int32) throws -> Data {
        let deadline = Self.deadline(
            milliseconds: Self.headerTimeoutMilliseconds)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4 * 1_024)
        while !isStopping {
            guard Self.wait(
                descriptor,
                events: Int16(POLLIN),
                deadline: deadline) else {
                throw MCPManagedPipeError.exactNetworkPolicyUnavailable
            }
            let count = chunk.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <=
                        MCPStdioConnectRequestParser.maximumHeaderBytes else {
                    throw MCPManagedPipeError.invalidNetworkOrigin
                }
                if let boundary = buffer.range(
                    of: Data([13, 10, 13, 10])) {
                    guard boundary.upperBound == buffer.endIndex else {
                        throw MCPManagedPipeError.invalidNetworkOrigin
                    }
                    return buffer
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        throw MCPManagedPipeError.exactNetworkPolicyUnavailable
    }

    private func connectDirect(
        _ endpoint: MCPStdioFrozenNetworkEndpoint
    ) throws -> Int32 {
        let deadline = Self.deadline(
            milliseconds: Self.connectTimeoutMilliseconds)
        for address in endpoint.addresses where !isStopping {
            let descriptor = socket(
                address.family,
                Self.streamSocketType,
                Int32(IPPROTO_TCP))
            guard descriptor >= 0 else { continue }
            let registered = stateLock.withLock { () -> Bool in
                guard !stopping else { return false }
                activeDescriptors.insert(descriptor)
                return true
            }
            guard registered,
                  Self.configureDescriptor(descriptor) else {
                stateLock.withLock {
                    activeDescriptors.remove(descriptor)
                }
                _ = close(descriptor)
                continue
            }
            var connected = false
            defer {
                if !connected {
                    stateLock.withLock {
                        activeDescriptors.remove(descriptor)
                    }
                    _ = close(descriptor)
                }
            }
            let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.baseAddress else { return -1 }
                return base.assumingMemoryBound(to: sockaddr.self)
                    .withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1) {
                        connect(
                            descriptor,
                            $0,
                            socklen_t(address.bytes.count))
                    }
            }
            if result == 0 {
                connected = true
                return descriptor
            }
            if errno == EINPROGRESS,
               Self.wait(
                   descriptor,
                   events: Int16(POLLOUT),
                   deadline: deadline) {
                var socketError: Int32 = 0
                var length = socklen_t(
                    MemoryLayout<Int32>.size)
                if getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &length) == 0,
                   socketError == 0 {
                    connected = true
                    return descriptor
                }
            }
        }
        throw MCPManagedPipeError.exactNetworkPolicyUnavailable
    }

    private func tunnel(client: Int32, remote: Int32) throws {
        var clientToRemote: UInt64 = 0
        var remoteToClient: UInt64 = 0
        var lastActivity = DispatchTime.now().uptimeNanoseconds
        var descriptors = [
            pollfd(fd: client, events: Int16(POLLIN), revents: 0),
            pollfd(fd: remote, events: Int16(POLLIN), revents: 0),
        ]
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while !isStopping {
            descriptors[0].revents = 0
            descriptors[1].revents = 0
            let ready = poll(&descriptors, 2, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if ready == 0 {
                let idleMilliseconds = (now - lastActivity) / 1_000_000
                if idleMilliseconds
                    >= UInt64(Self.idleTimeoutMilliseconds) {
                    return
                }
                continue
            }
            for index in 0..<2 {
                let revents = descriptors[index].revents
                if revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    return
                }
                guard revents & Int16(POLLIN) != 0 else { continue }
                let source = index == 0 ? client : remote
                let destination = index == 0 ? remote : client
                let count = buffer.withUnsafeMutableBytes {
                    recv(source, $0.baseAddress, $0.count, 0)
                }
                if count <= 0 {
                    if count < 0,
                       errno == EINTR || errno == EAGAIN
                           || errno == EWOULDBLOCK {
                        continue
                    }
                    return
                }
                if index == 0 {
                    clientToRemote += UInt64(count)
                    guard clientToRemote
                            <= Self.maximumBytesPerDirection else {
                        return
                    }
                } else {
                    remoteToClient += UInt64(count)
                    guard remoteToClient
                            <= Self.maximumBytesPerDirection else {
                        return
                    }
                }
                try buffer.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    try writeAll(
                        Data(bytes: base, count: count),
                        to: destination,
                        timeoutMilliseconds:
                            Self.connectTimeoutMilliseconds)
                }
                lastActivity = now
            }
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        timeoutMilliseconds: Int
    ) throws {
        let deadline = Self.deadline(
            milliseconds: timeoutMilliseconds)
        var offset = 0
        while offset < data.count, !isStopping {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return send(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    Self.noSignalSendFlag)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard Self.wait(
                    descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline) else {
                    break
                }
                continue
            }
            break
        }
        guard offset == data.count else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
    }

    private var isStopping: Bool {
        stateLock.withLock { stopping }
    }

    private static func resolve(
        _ origin: MCPStdioCanonicalNetworkOrigin
    ) throws -> [MCPStdioFrozenNetworkAddress] {
        let numericAddresses: Set<String>
        do {
            numericAddresses =
                try MCPSystemDNSResolver.resolveSynchronously(
                    host: origin.host,
                    port: Int(origin.port),
                    timeoutMilliseconds:
                        connectTimeoutMilliseconds)
        } catch {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }

        var addresses: Set<MCPStdioFrozenNetworkAddress> = []
        for numericAddress in numericAddresses {
            if let address = try freezeIPv4(
                numericAddress,
                port: origin.port) {
                addresses.insert(address)
            } else if let address = try freezeIPv6(
                numericAddress,
                port: origin.port) {
                addresses.insert(address)
            }
        }
        guard !addresses.isEmpty else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        return addresses.sorted {
            if $0.family != $1.family {
                return $0.family < $1.family
            }
            return $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
    }

    private static func freezeIPv4(
        _ numericAddress: String,
        port: UInt16
    ) throws -> MCPStdioFrozenNetworkAddress? {
        guard !numericAddress.contains("%") else { return nil }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let parsed = numericAddress.withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard parsed == 1 else { return nil }
        return try withUnsafeBytes(of: &address) {
            try MCPStdioFrozenNetworkAddress(
                family: AF_INET,
                bytes: Data($0))
        }
    }

    private static func freezeIPv6(
        _ numericAddress: String,
        port: UInt16
    ) throws -> MCPStdioFrozenNetworkAddress? {
        let addressText: String
        let scopeID: UInt32
        if let separator = numericAddress.lastIndex(of: "%") {
            addressText = String(numericAddress[..<separator])
            let scopeText = String(
                numericAddress[
                    numericAddress.index(after: separator)...])
            guard !addressText.isEmpty,
                  !scopeText.isEmpty else {
                return nil
            }
            if let numericScope = UInt32(scopeText) {
                guard numericScope != 0 else { return nil }
                scopeID = numericScope
            } else {
                let interfaceIndex = scopeText.withCString {
                    if_nametoindex($0)
                }
                guard interfaceIndex != 0 else { return nil }
                scopeID = interfaceIndex
            }
        } else {
            addressText = numericAddress
            scopeID = 0
        }

        var address = sockaddr_in6()
        #if canImport(Darwin)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_scope_id = scopeID
        let parsed = addressText.withCString {
            inet_pton(AF_INET6, $0, &address.sin6_addr)
        }
        guard parsed == 1 else { return nil }
        return try withUnsafeBytes(of: &address) {
            try MCPStdioFrozenNetworkAddress(
                family: AF_INET6,
                bytes: Data($0))
        }
    }

    private static func makeListener() throws
        -> (descriptor: Int32, port: UInt16)
    {
        let descriptor = socket(
            AF_INET,
            streamSocketType,
            Int32(IPPROTO_TCP))
        guard descriptor >= 0 else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        var shouldClose = true
        defer {
            if shouldClose { _ = close(descriptor) }
        }
        guard configureDescriptor(descriptor) else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        var reuse: Int32 = 0
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0,
              listen(descriptor, 32) == 0 else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        guard nameResult == 0, port > 0 else {
            throw MCPManagedPipeError.exactNetworkPolicyUnavailable
        }
        shouldClose = false
        return (descriptor, port)
    }

    static func makeCredential() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func configureDescriptor(_ descriptor: Int32) -> Bool {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard descriptorFlags >= 0,
              statusFlags >= 0,
              fcntl(
                  descriptor,
                  F_SETFD,
                  descriptorFlags | FD_CLOEXEC) == 0,
              fcntl(
                  descriptor,
                  F_SETFL,
                  statusFlags | O_NONBLOCK) == 0 else {
            return false
        }
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }
        #endif
        return true
    }

    private static func sendRejection(
        _ descriptor: Int32,
        status: Int
    ) {
        let reason = status == 403
            ? "Forbidden"
            : status == 503
                ? "Service Unavailable"
                : "Bad Request"
        let response = Data(
            "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                .utf8)
        _ = response.withUnsafeBytes { bytes in
            send(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                noSignalSendFlag)
        }
    }

    private static func deadline(milliseconds: Int) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
            + UInt64(max(1, milliseconds)) * 1_000_000
    }

    private static func wait(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = min(
                250,
                Int((deadline - now + 999_999) / 1_000_000))
            var item = pollfd(
                fd: descriptor,
                events: events,
                revents: 0)
            let result = poll(&item, 1, Int32(remaining))
            if result > 0 {
                return item.revents & events != 0
                    && item.revents
                        & Int16(POLLERR | POLLHUP | POLLNVAL) == 0
            }
            if result < 0, errno == EINTR { continue }
            if result < 0 { return false }
        }
    }

    #if canImport(Darwin)
    private static let streamSocketType = SOCK_STREAM
    private static let noSignalSendFlag: Int32 = 0
    #elseif canImport(Glibc)
    private static let streamSocketType = Int32(SOCK_STREAM.rawValue)
    private static let noSignalSendFlag = Int32(MSG_NOSIGNAL)
    #else
    private static let streamSocketType = Int32(SOCK_STREAM)
    private static let noSignalSendFlag = Int32(MSG_NOSIGNAL)
    #endif
}

private extension NSLock {
    @discardableResult
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
