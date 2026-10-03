import Foundation
import IntatisCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum MCPOAuthLoopbackHost: Equatable, Sendable {
    case ipv4
    case ipv6

    fileprivate var literal: String {
        switch self {
        case .ipv4: return "127.0.0.1"
        case .ipv6: return "::1"
        }
    }
}

public enum MCPOAuthLoopbackListenerError:
    Error, Equatable, LocalizedError, Sendable
{
    case invalidPath
    case socketUnavailable
    case bindPermissionDenied
    case bindFailed
    case listenFailed
    case acceptFailed
    case requestTimedOut
    case requestTooLarge
    case malformedRequest
    case wrongMethod
    case callbackPathMismatch
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "The OAuth loopback callback path is invalid."
        case .socketUnavailable:
            return "A loopback callback socket could not be created."
        case .bindPermissionDenied:
            return "The host denied permission to bind the OAuth loopback callback address."
        case .bindFailed:
            return "The exact OAuth loopback address could not be bound."
        case .listenFailed:
            return "The OAuth loopback callback listener could not start."
        case .acceptFailed:
            return "The OAuth loopback callback connection could not be accepted."
        case .requestTimedOut:
            return "The OAuth loopback callback timed out."
        case .requestTooLarge:
            return "The OAuth loopback callback request exceeded its hard limit."
        case .malformedRequest:
            return "The OAuth loopback callback request is malformed."
        case .wrongMethod:
            return "The OAuth loopback callback must use GET."
        case .callbackPathMismatch:
            return "The OAuth callback path does not match the bound listener."
        case .cancelled:
            return "The OAuth loopback callback listener was cancelled."
        }
    }
}

/// One-shot exact-loopback OAuth callback server for macOS/Linux hosts.
///
/// The listener binds only `127.0.0.1` or `::1`, never a wildcard address.
/// It accepts one bounded HTTP GET, returns a constant response that does not
/// reflect query data, then closes. The coordinator separately validates the
/// callback's state and login generation.
public final class MCPOAuthLoopbackCallbackListener:
    @unchecked Sendable
{
    public let redirectURI: URL

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: IntatisHostApplication.identity
            .namespacedIdentifier("mcp.oauth.loopback"))
    private var socketDescriptor: Int32
    private var closed = false
    private var waiting = false

    private init(
        socketDescriptor: Int32,
        redirectURI: URL
    ) {
        self.socketDescriptor = socketDescriptor
        self.redirectURI = redirectURI
    }

    deinit {
        close()
    }

    public static func bind(
        host: MCPOAuthLoopbackHost = .ipv4,
        port: UInt16 = 0,
        callbackPath: String = "/callback"
    ) throws -> MCPOAuthLoopbackCallbackListener {
        guard callbackPath.hasPrefix("/"),
              callbackPath.utf8.count <= 1_024,
              !callbackPath.contains("?"),
              !callbackPath.contains("#"),
              !callbackPath.contains("\0"),
              !callbackPath.split(
                separator: "/",
                omittingEmptySubsequences: false
              ).contains(where: { $0 == "." || $0 == ".." }) else {
            throw MCPOAuthLoopbackListenerError.invalidPath
        }
        let family = host == .ipv4 ? AF_INET : AF_INET6
        let descriptor = systemSocket(family)
        guard descriptor >= 0 else {
            throw MCPOAuthLoopbackListenerError.socketUnavailable
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size))
        }

        do {
            let actualPort: UInt16
            switch host {
            case .ipv4:
                var address = sockaddr_in()
                #if !os(Linux)
                address.sin_len = UInt8(
                    MemoryLayout<sockaddr_in>.size)
                #endif
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                guard inet_pton(
                    AF_INET,
                    host.literal,
                    &address.sin_addr) == 1 else {
                    throw MCPOAuthLoopbackListenerError.bindFailed
                }
                try withUnsafePointer(to: &address) {
                    try $0.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        guard systemBind(
                            descriptor,
                            $0,
                            socklen_t(
                                MemoryLayout<sockaddr_in>.size)) == 0
                        else {
                            throw currentBindError()
                        }
                    }
                }
                var bound = sockaddr_in()
                var length = socklen_t(
                    MemoryLayout<sockaddr_in>.size)
                let result = withUnsafeMutablePointer(to: &bound) {
                    $0.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                guard result == 0 else {
                    throw MCPOAuthLoopbackListenerError.bindFailed
                }
                actualPort = UInt16(bigEndian: bound.sin_port)
            case .ipv6:
                var onlyV6: Int32 = 1
                _ = withUnsafePointer(to: &onlyV6) {
                    setsockopt(
                        descriptor,
                        IPPROTO_IPV6,
                        IPV6_V6ONLY,
                        $0,
                        socklen_t(MemoryLayout<Int32>.size))
                }
                var address = sockaddr_in6()
                #if !os(Linux)
                address.sin6_len = UInt8(
                    MemoryLayout<sockaddr_in6>.size)
                #endif
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                guard inet_pton(
                    AF_INET6,
                    host.literal,
                    &address.sin6_addr) == 1 else {
                    throw MCPOAuthLoopbackListenerError.bindFailed
                }
                try withUnsafePointer(to: &address) {
                    try $0.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        guard systemBind(
                            descriptor,
                            $0,
                            socklen_t(
                                MemoryLayout<sockaddr_in6>.size)) == 0
                        else {
                            throw currentBindError()
                        }
                    }
                }
                var bound = sockaddr_in6()
                var length = socklen_t(
                    MemoryLayout<sockaddr_in6>.size)
                let result = withUnsafeMutablePointer(to: &bound) {
                    $0.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                guard result == 0 else {
                    throw MCPOAuthLoopbackListenerError.bindFailed
                }
                actualPort = UInt16(bigEndian: bound.sin6_port)
            }

            guard listen(descriptor, 1) == 0 else {
                throw MCPOAuthLoopbackListenerError.listenFailed
            }
            let hostText = host == .ipv6
                ? "[\(host.literal)]"
                : host.literal
            guard let redirectURI = URL(
                string:
                    "http://\(hostText):\(actualPort)\(callbackPath)")
            else {
                throw MCPOAuthLoopbackListenerError.invalidPath
            }
            return MCPOAuthLoopbackCallbackListener(
                socketDescriptor: descriptor,
                redirectURI: redirectURI)
        } catch {
            systemClose(descriptor)
            throw error
        }
    }

    public func waitForCallback(
        maximumRequestBytes: Int = 32 * 1_024,
        readTimeoutSeconds: Int = 120
    ) async throws -> URL {
        let descriptor = try beginWaiting()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let result = try acceptOne(
                            descriptor: descriptor,
                            maximumRequestBytes: max(
                                1_024,
                                maximumRequestBytes),
                            readTimeoutSeconds: max(
                                1,
                                readTimeoutSeconds))
                        close()
                        continuation.resume(returning: result)
                    } catch {
                        close()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.close()
        }
    }

    private func beginWaiting() throws -> Int32 {
        lock.lock()
        guard !closed, !waiting else {
            lock.unlock()
            throw MCPOAuthLoopbackListenerError.cancelled
        }
        waiting = true
        let descriptor = socketDescriptor
        lock.unlock()
        return descriptor
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let descriptor = socketDescriptor
        socketDescriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            systemClose(descriptor)
        }
    }

    private func acceptOne(
        descriptor: Int32,
        maximumRequestBytes: Int,
        readTimeoutSeconds: Int
    ) throws -> URL {
        let accepted = accept(descriptor, nil, nil)
        guard accepted >= 0 else {
            if isClosed() {
                throw MCPOAuthLoopbackListenerError.cancelled
            }
            throw MCPOAuthLoopbackListenerError.acceptFailed
        }
        defer { systemClose(accepted) }
        _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)

        var timeout = timeval(
            tv_sec: readTimeoutSeconds,
            tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                accepted,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size))
        }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while request.range(
            of: Data("\r\n\r\n".utf8)) == nil
        {
            let count = recv(
                accepted,
                &buffer,
                buffer.count,
                0)
            if count == 0 {
                throw MCPOAuthLoopbackListenerError.malformedRequest
            }
            if count < 0 {
                #if os(Linux)
                let timedOut = errno == EAGAIN || errno == EWOULDBLOCK
                #else
                let timedOut = errno == EAGAIN || errno == EWOULDBLOCK
                #endif
                throw timedOut
                    ? MCPOAuthLoopbackListenerError.requestTimedOut
                    : MCPOAuthLoopbackListenerError.malformedRequest
            }
            guard request.count <= maximumRequestBytes - count else {
                try? sendResponse(
                    descriptor: accepted,
                    status: "413 Payload Too Large")
                throw MCPOAuthLoopbackListenerError.requestTooLarge
            }
            request.append(buffer, count: count)
        }

        guard let text = String(data: request, encoding: .utf8),
              let firstLine = text.components(
                separatedBy: "\r\n").first else {
            throw MCPOAuthLoopbackListenerError.malformedRequest
        }
        let parts = firstLine.split(
            separator: " ",
            omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            throw MCPOAuthLoopbackListenerError.malformedRequest
        }
        guard parts[0] == "GET" else {
            try? sendResponse(
                descriptor: accepted,
                status: "405 Method Not Allowed")
            throw MCPOAuthLoopbackListenerError.wrongMethod
        }
        let target = String(parts[1])
        guard target.hasPrefix("/") && !target.contains("#"),
              target.utf8.count <= maximumRequestBytes,
              let callback = URL(
                string: target,
                relativeTo: redirectURI)?.absoluteURL,
              callback.path == redirectURI.path else {
            try? sendResponse(
                descriptor: accepted,
                status: "404 Not Found")
            throw MCPOAuthLoopbackListenerError.callbackPathMismatch
        }
        try sendResponse(
            descriptor: accepted,
            status: "200 OK")
        return callback
    }

    private func sendResponse(
        descriptor: Int32,
        status: String
    ) throws {
        let body =
            "<!doctype html><meta charset=\"utf-8\"><title>\(IntatisHostApplication.identity.name)</title><p>Authorization received. You may close this window.</p>"
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nPragma: no-cache\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let data = Data(response.utf8)
        let sent = data.withUnsafeBytes {
            send(
                descriptor,
                $0.baseAddress,
                data.count,
                0)
        }
        guard sent == data.count else {
            throw MCPOAuthLoopbackListenerError.malformedRequest
        }
    }

    private func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

private func systemSocket(_ family: Int32) -> Int32 {
    #if canImport(Musl)
    return socket(family, SOCK_STREAM, 0)
    #elseif os(Linux)
    return socket(family, Int32(SOCK_STREAM.rawValue), 0)
    #else
    return socket(family, SOCK_STREAM, 0)
    #endif
}

private func systemBind(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
    #if canImport(Glibc)
    return Glibc.bind(descriptor, address, length)
    #elseif canImport(Musl)
    return Musl.bind(descriptor, address, length)
    #elseif canImport(Darwin)
    return Darwin.bind(descriptor, address, length)
    #else
    return -1
    #endif
}

private func systemClose(_ descriptor: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(descriptor)
    #elseif canImport(Musl)
    _ = Musl.close(descriptor)
    #elseif canImport(Darwin)
    _ = Darwin.close(descriptor)
    #endif
}

private func currentBindError() -> MCPOAuthLoopbackListenerError {
    if errno == EPERM || errno == EACCES {
        return .bindPermissionDenied
    }
    return .bindFailed
}
