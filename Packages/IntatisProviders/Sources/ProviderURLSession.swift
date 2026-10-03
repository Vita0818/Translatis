import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider traffic must stay on the exact endpoint selected by the resolved
/// inference connection. Foundation follows HTTP redirects by default, which
/// would let an approved endpoint forward prompts and bearer credentials to an
/// unreviewed route while EventLog still attributed the call to the original
/// connection. Returning `nil` exposes the 3xx response to the caller and never
/// creates the redirected request.
final class ProviderNoRedirectURLSessionDelegate: NSObject,
                                                  URLSessionTaskDelegate,
                                                  @unchecked Sendable {
    static let shared = ProviderNoRedirectURLSessionDelegate()

    private override init() {}

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ProviderURLSession {
    static let noRedirect: URLSession = makeNoRedirectSession()

    static func makeNoRedirectSession(
        configuration source: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        let configuration = source.copy() as? URLSessionConfiguration ?? source
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: ProviderNoRedirectURLSessionDelegate.shared,
            delegateQueue: nil)
    }
}
