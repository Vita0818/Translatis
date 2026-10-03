import Foundation

enum ProviderAuthorization {
    static func bearerHeaderValue(apiKey: String) -> String {
        "Bearer \(bearerToken(from: apiKey))"
    }

    static func bearerToken(from rawValue: String) -> String {
        var value = stripWrappingQuotes(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        if value.lowercased().hasPrefix("bearer ") {
            let tokenStart = value.index(value.startIndex, offsetBy: 7)
            value = stripWrappingQuotes(String(value[tokenStart...]))
        }
        return value
    }

    private static func stripWrappingQuotes(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}
