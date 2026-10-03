import Foundation
import IntatisProtocol

/// A minimal model-authored permission verdict. Risk remains a host policy
/// fact and is intentionally absent from this value.
public struct PermissionReviewTextVerdict: Equatable, Sendable {
    public let decision: PermissionDecision
    public let reason: String

    public init(decision: PermissionDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}

/// Secret-free structural diagnosis for one rejected reviewer output. The raw
/// model text remains transient and must never be persisted with this value.
public enum PermissionReviewTextVerdictParseFailure: String, Equatable, Sendable {
    case missingVerdictMarker = "missing_verdict_marker"
    case multipleVerdictMarkers = "multiple_verdict_markers"
    case verdictMarkerNotFinal = "verdict_marker_not_final"
    case missingReason = "missing_reason"
    case structuredOutput = "structured_output"
}

public enum PermissionReviewTextVerdictParseResult: Equatable, Sendable {
    case verdict(PermissionReviewTextVerdict)
    case failure(PermissionReviewTextVerdictParseFailure)
}

/// Parses the shared permission-review text protocol. Provider completion and
/// finish-reason validation belong to the transport-owning caller, not this
/// pure text parser.
public enum PermissionReviewTextVerdictParser {
    /// Readability and downstream-summary target, not a validity ceiling.
    public static let recommendedReasonCharacterCount = 240

    /// Source-compatibility alias for callers compiled against the former hard
    /// limit. Parsing no longer rejects a reason solely because it is longer.
    public static let maximumReasonCharacterCount = recommendedReasonCharacterCount

    /// Single source of truth shared by reviewer system and user prompts.
    public static let modelOutputContract = """
    Return a nonempty plain-text audit reason, then put exactly one ASCII verdict marker on the final nonempty line: ALLOW or DENY.
    Keep the reason concise—prefer 1–3 sentences and about 240 characters or fewer. This length is guidance only; a longer non-sensitive reason remains valid.
    Do not return JSON, Markdown code fences, a tool call, punctuation on the verdict line, or any text after the verdict marker.
    """

    public static func parse(_ text: String) -> PermissionReviewTextVerdict? {
        guard case .verdict(let verdict) = parseResult(text) else { return nil }
        return verdict
    }

    public static func parseResult(_ text: String) -> PermissionReviewTextVerdictParseResult {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !containsCodeFence(normalized),
              !containsJSONPayload(normalized) else {
            return .failure(.structuredOutput)
        }
        var lines = normalized.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }

        let markerIndices = lines.indices.filter {
            decision(forExactASCIIMarker: lines[$0]) != nil
        }
        guard !markerIndices.isEmpty else {
            return .failure(.missingVerdictMarker)
        }
        guard markerIndices.count == 1 else {
            return .failure(.multipleVerdictMarkers)
        }
        guard let markerIndex = markerIndices.first,
              markerIndex == lines.index(before: lines.endIndex),
              let parsedDecision = decision(forExactASCIIMarker: lines[markerIndex]) else {
            return .failure(.verdictMarkerNotFinal)
        }

        let reason = lines.dropLast()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            return .failure(.missingReason)
        }

        return .verdict(PermissionReviewTextVerdict(
            decision: parsedDecision,
            reason: reason))
    }

    private static func decision(forExactASCIIMarker line: String) -> PermissionDecision? {
        let bytes = Array(line.utf8)
        if equalsASCIICaseInsensitive(bytes, Array("ALLOW".utf8)) {
            return .allow
        }
        if equalsASCIICaseInsensitive(bytes, Array("DENY".utf8)) {
            return .deny
        }
        return nil
    }

    private static func equalsASCIICaseInsensitive(_ candidate: [UInt8], _ expected: [UInt8]) -> Bool {
        guard candidate.count == expected.count else { return false }
        return zip(candidate, expected).allSatisfy { byte, expectedByte in
            let uppercased: UInt8
            switch byte {
            case 97 ... 122:
                uppercased = byte - 32
            default:
                uppercased = byte
            }
            return uppercased == expectedByte
        }
    }

    private static func containsCodeFence(_ reason: String) -> Bool {
        reason.contains("```") || reason.contains("~~~")
    }

    private static func containsJSONPayload(_ reason: String) -> Bool {
        for (opening, closing) in [("{", "}"), ("[", "]")] {
            guard let start = reason.firstIndex(of: Character(opening)),
                  let end = reason.lastIndex(of: Character(closing)),
                  start < end,
                  let data = String(reason[start ... end]).data(using: .utf8) else {
                continue
            }
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return true
            }
        }
        return false
    }
}
