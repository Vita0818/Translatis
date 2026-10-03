import Foundation
import IntatisProviders

/// Resolves product-facing copy from the host application's localization
/// catalog. English source text is used as the key and the missing-key
/// fallback so package UI remains readable in hosts without app resources.
public enum IntatisLocalization {
    public static func string(_ key: String,
                              defaultValue: String? = nil) -> String {
        Bundle.main.localizedString(
            forKey: key,
            value: defaultValue ?? key,
            table: "Localizable")
    }

    public static func format(_ key: String,
                              _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.autoupdatingCurrent,
            arguments: arguments)
    }

    /// Localizes only the presentation-owned portions of a provider health
    /// report. Endpoint/model identifiers and provider-supplied diagnostics
    /// remain byte-for-byte unchanged.
    public static func providerHealthSummary(_ report: ProviderHealthReport) -> String {
        let role: String
        switch report.role {
        case .chat:
            role = string("chat")
        case .agent:
            role = string("agent")
        }

        var parts = [
            role,
            report.endpointID,
            report.model.rawValue,
            "\(report.elapsedMillis) ms",
        ]
        if let code = report.code {
            parts.append(code)
        }
        return parts.joined(separator: " · ")
    }

    public static func providerHealthDetail(_ report: ProviderHealthReport) -> String {
        guard let preview = report.responsePreview, !preview.isEmpty else {
            return report.message
        }
        return "\(report.message) \(format("Preview: %@", preview))"
    }
}
