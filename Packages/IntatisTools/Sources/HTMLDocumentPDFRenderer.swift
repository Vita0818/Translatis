import Foundation
import IntatisCore

#if os(macOS) && canImport(WebKit)
import WebKit

@MainActor
enum HTMLDocumentPDFRenderer {
    static let engineVersion = "WKWebView-system"

    static func render(
        input: URL,
        stageRoot: URL,
        stagedPDF: URL,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> [String: String] {
        let canonicalStageRoot = try? PathConfinement.canonicalExistingDirectory(stageRoot)
        let stageValues = try? stageRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        let inputValues = try? input.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard let canonicalStageRoot,
              stageRoot.isFileURL,
              stageValues?.isDirectory == true,
              stageValues?.isSymbolicLink != true,
              input.isFileURL,
              stagedPDF.isFileURL,
              inputValues?.isRegularFile == true,
              inputValues?.isSymbolicLink != true,
              (inputValues?.fileSize ?? 0) > 0,
              (inputValues?.fileSize ?? 0) <= 96 * 1_024 * 1_024,
              PathConfinement.isWithin(input.path, root: canonicalStageRoot),
              PathConfinement.isWithin(stagedPDF.path, root: canonicalStageRoot),
              FileManager.default.fileExists(atPath: stagedPDF.path) == false else {
            throw DocumentToolError(.validationFailed, "HTML render paths are invalid")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let blocker = try await networkBlocker()
        configuration.userContentController.add(blocker)

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration)
        let navigation = HTMLNavigationGuard()
        webView.navigationDelegate = navigation
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        let stream = navigation.events
        guard webView.loadFileURL(
            input,
            allowingReadAccessTo: canonicalStageRoot) != nil else {
            throw DocumentToolError(.renderFailed, "WKWebView rejected the local HTML load")
        }
        try await waitForNavigation(stream, timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        let data: Data
        do {
            data = try await webView.pdf(configuration: WKPDFConfiguration())
        } catch {
            throw DocumentToolError(.renderFailed, "WKWebView could not print the HTML document")
        }
        guard data.starts(with: Data("%PDF-".utf8)), data.count > 8 else {
            throw DocumentToolError(.renderFailed, "WKWebView returned an invalid PDF payload")
        }
        do {
            try data.write(to: stagedPDF, options: .withoutOverwriting)
        } catch {
            throw DocumentToolError(.renderFailed, "WKWebView PDF could not be staged")
        }
        return ["html_renderer": engineVersion]
    }

    private static func networkBlocker() async throws -> WKContentRuleList {
        let rules = #"[{"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^https://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ws://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss://"},"action":{"type":"block"}}]"#
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: IntatisHostApplication.identity
                    .temporaryPrefix("document-network-deny-v2"),
                encodedContentRuleList: rules
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(
                        throwing: error ?? DocumentToolError(
                            .renderFailed,
                            "WKWebView network blocker could not be installed"))
                }
            }
        }
    }

    private static func waitForNavigation(
        _ events: AsyncThrowingStream<Void, Error>,
        timeoutSeconds: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in events { return }
                throw DocumentToolError(.renderFailed, "WKWebView navigation ended without a document")
            }
            group.addTask {
                let nanos = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw DocumentToolError(.renderFailed, "WKWebView HTML load timed out")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

@MainActor
private final class HTMLNavigationGuard: NSObject, WKNavigationDelegate {
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    let events: AsyncThrowingStream<Void, Error>

    override init() {
        var stored: AsyncThrowingStream<Void, Error>.Continuation?
        events = AsyncThrowingStream { stored = $0 }
        continuation = stored!
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(),
              ["file", "about", "data"].contains(scheme) else {
            decisionHandler(.cancel)
            continuation.finish(
                throwing: DocumentToolError(
                    .renderFailed,
                    "WKWebView blocked a non-local navigation"))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation.yield(())
        continuation.finish()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation.finish(
            throwing: DocumentToolError(.renderFailed, "WKWebView failed to load local HTML"))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation.finish(
            throwing: DocumentToolError(.renderFailed, "WKWebView rejected local HTML"))
    }
}

#else

enum HTMLDocumentPDFRenderer {
    static func render(
        input: URL,
        stageRoot: URL,
        stagedPDF: URL,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> [String: String] {
        throw DocumentToolError(
            .backendMissing,
            "WKWebView HTML rendering is unavailable on this platform")
    }
}

#endif
