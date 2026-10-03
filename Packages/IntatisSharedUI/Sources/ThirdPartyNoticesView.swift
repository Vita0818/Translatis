#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore

/// User-accessible, renderer-independent presentation of the notices shipped
/// in the final app bundle. It deliberately uses verbatim SwiftUI text so legal
/// notices remain readable even when rich Markdown is disabled or unavailable;
/// the Debug-only typography experiment may still replace its English glyphs.
public struct IntatisThirdPartyNoticesView: View {
    private let text: String

    public init(bundle: Bundle = .main) {
        text = Self.loadNotices(from: bundle)
    }

    public var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(IntatisTypography.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .accessibilityIdentifier(
            IntatisHostApplication.identity.namespacedIdentifier(
                "third-party-notices"))
    }

    static func loadNotices(from bundle: Bundle) -> String {
        var documents: [(String, String)] = []
        if let noticeURL = bundle.url(forResource: "NOTICE", withExtension: "md"),
           let notice = try? String(contentsOf: noticeURL, encoding: .utf8) {
            documents.append(("NOTICE.md", notice))
        }

        if let noticesDirectory = bundle.url(
            forResource: "ThirdPartyNotices",
            withExtension: nil),
           let urls = try? FileManager.default.contentsOfDirectory(
            at: noticesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for url in urls
                .filter({ $0.pathExtension.lowercased() == "md" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    documents.append(("ThirdPartyNotices/\(url.lastPathComponent)", contents))
                }
            }
        }

        guard !documents.isEmpty else {
            return IntatisLocalization.string(
                "Third-party notices are missing from this build.")
        }
        return documents
            .map { "===== \($0.0) =====\n\n\($0.1)" }
            .joined(separator: "\n\n")
    }
}
#endif
