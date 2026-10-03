import Foundation
import IntatisProtocol

/// A read-only UI projection over arbitrary model configuration JSON.
///
/// This type never rewrites request options or infers provider behavior. It
/// only recognizes common reasoning-control spellings so a client can display
/// the exact configured value next to a model name.
public struct ModelConfigurationPresentation: Equatable, Sendable {
    public var reasoningLabel: String?

    public init(modelMetadata: [String: JSONValue] = [:],
                requestOptions: [String: JSONValue]) {
        self.reasoningLabel = Self.reasoningLabel(
            modelMetadata: modelMetadata,
            requestOptions: requestOptions)
    }

    private struct Candidate: Comparable {
        var rank: Int
        var path: String
        var label: String

        static func < (lhs: Candidate, rhs: Candidate) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.path < rhs.path
        }
    }

    private static func reasoningLabel(modelMetadata: [String: JSONValue],
                                       requestOptions: [String: JSONValue]) -> String? {
        var candidates: [Candidate] = []
        collectCandidates(in: requestOptions,
                          path: ["options"],
                          semanticAncestors: [],
                          into: &candidates)

        // Model-level metadata is also eligible, but variants are deliberately
        // excluded: without an explicit selected variant, choosing one value
        // would falsely present it as active.
        let presentationMetadata = modelMetadata.filter { key, _ in
            let normalized = normalizedKey(key)
            return normalized != "options" && normalized != "variants"
        }
        collectCandidates(in: presentationMetadata,
                          path: ["model"],
                          semanticAncestors: [],
                          into: &candidates)
        return candidates.min()?.label
    }

    private static func collectCandidates(in object: [String: JSONValue],
                                          path: [String],
                                          semanticAncestors: [String],
                                          into candidates: inout [Candidate]) {
        for (key, value) in object {
            let normalized = normalizedKey(key)
            let currentPath = path + [key]
            let ancestorSet = Set(semanticAncestors)

            if let label = scalarLabel(value) {
                if normalized == "reasoningeffort" {
                    candidates.append(Candidate(
                        rank: 0,
                        path: currentPath.joined(separator: "."),
                        label: label))
                } else if normalized == "effort",
                          !ancestorSet.isDisjoint(with: ["reasoning", "thinking", "outputconfig"]) {
                    candidates.append(Candidate(
                        rank: 0,
                        path: currentPath.joined(separator: "."),
                        label: label))
                } else if normalized == "thinkinglevel"
                            || (normalized == "level" && ancestorSet.contains("thinking")) {
                    candidates.append(Candidate(
                        rank: 1,
                        path: currentPath.joined(separator: "."),
                        label: label))
                } else if normalized == "thinkingbudget"
                            || (normalized == "budgettokens"
                                && !ancestorSet.isDisjoint(with: ["reasoning", "thinking"]))
                            || (normalized == "maxtokens" && ancestorSet.contains("reasoning")) {
                    candidates.append(Candidate(
                        rank: 2,
                        path: currentPath.joined(separator: "."),
                        label: tokenBudgetLabel(value, fallback: label)))
                }
            }

            if case .object(let nested) = value {
                collectCandidates(
                    in: nested,
                    path: currentPath,
                    semanticAncestors: semanticAncestors + [normalized],
                    into: &candidates)
            }
        }
    }

    private static func normalizedKey(_ key: String) -> String {
        key.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func scalarLabel(_ value: JSONValue) -> String? {
        switch value {
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let number):
            return number.rounded() == number ? String(Int64(number)) : String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }

    private static func tokenBudgetLabel(_ value: JSONValue, fallback: String) -> String {
        switch value {
        case .number:
            return "\(fallback) tokens"
        default:
            return fallback
        }
    }
}
