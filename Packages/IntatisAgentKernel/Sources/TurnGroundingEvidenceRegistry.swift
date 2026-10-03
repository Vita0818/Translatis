import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import IntatisProtocol
import IntatisTools

/// Request-local authority for model-visible knowledge citations. The
/// registry is deliberately recreated for every AgentLoop turn: durable tool
/// history is context, never authority for a new citation.
struct TurnGroundingEvidenceRegistry: Sendable {
    struct Binding: Equatable, Sendable {
        let evidenceID: String
        let knowledgeBase: String
        let knowledgeBaseRevision: String
        let retrievalSnapshot: String
        let retrievalSnapshotRevision: String
        let textSHA256: String
        let evidenceURI: String
    }

    enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        case malformedSearchResult(String)
        case malformedCitation
        case missingCitation
        case unknownCitation(String)
        case evidenceChanged(String)

        var errorDescription: String? {
            switch self {
            case .malformedSearchResult(let reason):
                return "search_knowledge returned an invalid grounding result: \(reason)"
            case .malformedCitation:
                return "The final answer contains a malformed evidence citation."
            case .missingCitation:
                return "The final answer must cite evidence returned by the successful current-turn knowledge search."
            case .unknownCitation(let evidenceID):
                return "The final answer cites evidence that was not returned successfully in this turn: \(evidenceID)"
            case .evidenceChanged(let evidenceID):
                return "The final answer cites evidence that is no longer mechanically valid: \(evidenceID)"
            }
        }
    }

    private(set) var bindings: [String: Binding] = [:]
    private struct Entry: Sendable {
        let evidence: ToolGroundingEvidence
        let revalidator: ToolGroundingEvidenceRevalidator
    }
    private var entries: [String: Entry] = [:]

    mutating func record(toolName: String,
                         observation: ToolObservation,
                         revalidator: ToolGroundingEvidenceRevalidator? = nil) throws {
        guard toolName == "search_knowledge",
              observation.structuredResult?.isError == false,
              let value = observation.structuredResult?.structuredContent else {
            return
        }
        guard case .object(let root) = value,
              root.string("status") == "ok" else {
            return
        }
        guard let knowledgeBase = root.string("knowledge_base"),
              let knowledgeBaseRevision = root.digest("knowledge_base_revision"),
              let retrievalSnapshot = root.string("retrieval_snapshot"),
              let retrievalSnapshotRevision = root.digest("retrieval_snapshot_revision"),
              case .array(let evidence)? = root["evidence"],
              !evidence.isEmpty else {
            throw ValidationError.malformedSearchResult("required snapshot identity or evidence is missing")
        }
        guard let revalidator else {
            throw ValidationError.malformedSearchResult(
                "the exact tool registration has no final grounding revalidator")
        }

        var result: [String: Binding] = [:]
        var replay: [String: Entry] = [:]
        for (offset, item) in evidence.enumerated() {
            guard case .object(let object) = item,
                  let evidenceID = object.string("evidence_id"),
                  evidenceID.range(
                    of: #"^ev_[A-Za-z0-9._-]{1,128}$"#,
                    options: .regularExpression) != nil,
                  object.integer("rank") == offset + 1,
                  let text = object.string("text"),
                  let textSHA256 = object.digest("text_sha256"),
                  textSHA256 == Self.sha256(Data(text.utf8)),
                  let evidenceURI = object.string("evidence_uri"),
                  evidenceURI.hasPrefix(
                    "knowledge://\(knowledgeBase)/\(retrievalSnapshot)/"),
                  case .array(let sourceIDs)? = object["source_ids"],
                  !sourceIDs.isEmpty,
                  sourceIDs.allSatisfy({ $0.nonEmptyString != nil }),
                  result[evidenceID] == nil else {
                throw ValidationError.malformedSearchResult("evidence ordering, digest, URI, source binding, or identity is invalid")
            }
            let binding = Binding(
                evidenceID: evidenceID,
                knowledgeBase: knowledgeBase,
                knowledgeBaseRevision: knowledgeBaseRevision,
                retrievalSnapshot: retrievalSnapshot,
                retrievalSnapshotRevision: retrievalSnapshotRevision,
                textSHA256: textSHA256,
                evidenceURI: evidenceURI)
            if let existing = bindings[evidenceID], existing != binding {
                throw ValidationError.malformedSearchResult(
                    "a stable evidence ID changed its snapshot, digest, or URI binding")
            }
            result[evidenceID] = binding
            replay[evidenceID] = Entry(
                evidence: ToolGroundingEvidence(
                    toolName: toolName,
                    evidenceID: evidenceID,
                    knowledgeBase: knowledgeBase,
                    knowledgeBaseRevision: knowledgeBaseRevision,
                    retrievalSnapshot: retrievalSnapshot,
                    retrievalSnapshotRevision: retrievalSnapshotRevision,
                    textSHA256: textSHA256,
                    evidenceURI: evidenceURI,
                    structuredEvidence: item),
                revalidator: revalidator)
        }
        // Stable evidence IDs may legitimately recur across multiple searches
        // in one turn. Exact bindings are idempotent; the most recent exact
        // registration supplies the replay payload and revalidator.
        bindings.merge(result) { existing, _ in existing }
        entries.merge(replay) { _, latest in latest }
    }

    func validateCitations(
        in text: String,
        requireAtLeastOne: Bool = false
    ) async throws {
        let marker = "[[evidence:"
        guard text.contains(marker) else {
            if requireAtLeastOne, !bindings.isEmpty {
                throw ValidationError.missingCitation
            }
            return
        }
        let pattern = #"\[\[evidence:(ev_[A-Za-z0-9._-]{1,128})\]\]"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else {
            throw ValidationError.malformedCitation
        }

        var covered = IndexSet()
        var citedEvidenceIDs = Set<String>()
        for match in matches {
            covered.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
            guard let idRange = Range(match.range(at: 1), in: text) else {
                throw ValidationError.malformedCitation
            }
            let evidenceID = String(text[idRange])
            guard bindings[evidenceID] != nil else {
                throw ValidationError.unknownCitation(evidenceID)
            }
            citedEvidenceIDs.insert(evidenceID)
        }

        let utf16 = Array(text.utf16)
        var searchStart = 0
        let markerUnits = Array(marker.utf16)
        while searchStart + markerUnits.count <= utf16.count {
            guard let offset = Self.firstOccurrence(
                of: markerUnits,
                in: utf16,
                startingAt: searchStart) else { break }
            guard covered.contains(offset) else {
                throw ValidationError.malformedCitation
            }
            searchStart = offset + markerUnits.count
        }

        for evidenceID in citedEvidenceIDs.sorted() {
            guard let entry = entries[evidenceID] else {
                throw ValidationError.unknownCitation(evidenceID)
            }
            do {
                try await entry.revalidator(entry.evidence)
            } catch {
                throw ValidationError.evidenceChanged(evidenceID)
            }
        }
    }

    private static func firstOccurrence(of needle: [UInt16],
                                        in haystack: [UInt16],
                                        startingAt start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start <= haystack.count else { return nil }
        guard needle.count <= haystack.count else { return nil }
        let upper = haystack.count - needle.count
        guard start <= upper else { return nil }
        for index in start...upper where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        self[key]?.nonEmptyString
    }

    func integer(_ key: String) -> Int? {
        guard case .number(let value)? = self[key],
              value.isFinite,
              value.rounded() == value else { return nil }
        return Int(value)
    }

    func digest(_ key: String) -> String? {
        guard let value = string(key),
              value.range(
                of: #"^sha256:[0-9a-f]{64}$"#,
                options: .regularExpression) != nil else { return nil }
        return value
    }
}

private extension JSONValue {
    var nonEmptyString: String? {
        guard case .string(let value) = self,
              !value.isEmpty else { return nil }
        return value
    }
}
