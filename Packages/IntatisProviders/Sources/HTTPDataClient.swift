import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Non-streaming request/response transport (for image generation, transcription,
/// and video job polling). Streaming chat uses `HTTPByteStreaming` instead. Tests
/// inject a fake; the real client is `URLSessionDataClient`.
public struct HTTPDataResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]

    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }

    static func headers(from response: HTTPURLResponse) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            values[String(describing: key).lowercased()] = String(describing: value)
        }
        return values
    }
}

public protocol HTTPDataClient: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse
    func uploadResponse(
        _ request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> HTTPDataResponse
}

public extension HTTPDataClient {
    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        let response = try await send(request)
        return HTTPDataResponse(data: response.data, status: response.status)
    }

    /// Test/custom transports that only implement `send` still receive the
    /// exact upload bytes. The shipping URLSession transport overrides this
    /// fallback so bounded transcription bodies are streamed from disk rather
    /// than copied into a second in-memory `Data` value.
    func uploadResponse(
        _ request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> HTTPDataResponse {
        var request = request
        request.httpBody = try Data(contentsOf: fileURL)
        return try await sendResponse(request)
    }
}

public struct URLSessionDataClient: HTTPDataClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }

    public func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        #if canImport(Darwin)
        let (data, response) = try await ProviderURLSession.noRedirect.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return HTTPDataResponse(data: data, status: 0)
        }
        return HTTPDataResponse(data: data,
                                status: http.statusCode,
                                headers: HTTPDataResponse.headers(from: http))
        #else
        throw IntatisError.provider("HTTP data client is unavailable on this platform")
        #endif
    }

    public func uploadResponse(
        _ request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> HTTPDataResponse {
        #if canImport(Darwin)
        let (data, response) = try await ProviderURLSession.noRedirect.upload(
            for: request,
            fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            return HTTPDataResponse(data: data, status: 0)
        }
        return HTTPDataResponse(
            data: data,
            status: http.statusCode,
            headers: HTTPDataResponse.headers(from: http))
        #else
        throw IntatisError.provider(
            "HTTP file upload client is unavailable on this platform")
        #endif
    }
}
