import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol

enum AgentToolOutputLoweringError:
    Error,
    Equatable,
    Sendable,
    LocalizedError
{
    case unsupportedMedia(String)
    case invalidBlock(index: Int, reason: String)
    case canonicalJSON(index: Int)

    var stableCode: String {
        switch self {
        case .unsupportedMedia:
            return "media_output_unsupported"
        case .invalidBlock, .canonicalJSON:
            return "media_output_invalid"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia(let kind):
            return "Tool output contains unsupported media kind \(kind)."
        case .invalidBlock(let index, let reason):
            return "Tool output block \(index) is invalid: \(reason)"
        case .canonicalJSON(let index):
            return "Tool output JSON block \(index) could not be canonicalized."
        }
    }
}

struct AgentCanonicalToolOutput: Equatable, Sendable {
    static let maximumTextBytes = 65_536

    var output: String
    var imageReferences: [ModelHistoryImageReference]

    static func lower(
        structuredResult: MCPStructuredToolResult?,
        legacyObservation: String
    ) throws -> AgentCanonicalToolOutput {
        guard let structuredResult else {
            return AgentCanonicalToolOutput(
                output: utf8Prefix(
                    sanitizedProviderText(legacyObservation),
                    maximumBytes: maximumTextBytes),
                imageReferences: [])
        }

        var textParts: [String] = []
        var references: [ModelHistoryImageReference] = []
        for (index, block) in structuredResult.content.enumerated() {
            switch block.kind {
            case .text:
                guard let text = block.text else {
                    throw AgentToolOutputLoweringError.invalidBlock(
                        index: index,
                        reason: "text is missing")
                }
                let safeText = sanitizedProviderText(text)
                if !safeText.isEmpty { textParts.append(safeText) }

            case .structuredJSON:
                guard let value = block.structuredJSON,
                      let rendered = String(
                        data: try MCPJSONSchema.canonicalData(value),
                        encoding: .utf8) else {
                    throw AgentToolOutputLoweringError.canonicalJSON(
                        index: index)
                }
                textParts.append(sanitizedProviderText(rendered))

            case .imageReference:
                guard let artifactID = block.artifactID,
                      let mimeType = block.mimeType,
                      let byteCount = block.byteCount,
                      byteCount > 0,
                      let sha256 = block.sha256,
                      Self.isCanonicalImageMIME(mimeType),
                      Self.isCanonicalSHA256(sha256) else {
                    throw AgentToolOutputLoweringError.invalidBlock(
                        index: index,
                        reason: "image descriptor is incomplete or non-canonical")
                }
                references.append(ModelHistoryImageReference(
                    artifactID: artifactID,
                    mimeType: mimeType,
                    byteCount: byteCount,
                    sha256: sha256))

            case .audioReference:
                throw AgentToolOutputLoweringError.unsupportedMedia(
                    block.kind.rawValue)

            case .resourceLink:
                guard let uri = block.uri, !uri.isEmpty else {
                    throw AgentToolOutputLoweringError.invalidBlock(
                        index: index,
                        reason: "resource URI is missing")
                }
                textParts.append(MCPToolResultPresentation.resource(
                    uri: sanitizedProviderText(uri)))

            case .embeddedResourceReference:
                guard let uri = block.uri, !uri.isEmpty else {
                    throw AgentToolOutputLoweringError.invalidBlock(
                        index: index,
                        reason: "embedded resource URI is missing")
                }
                textParts.append(MCPToolResultPresentation.embeddedResource(
                    uri: sanitizedProviderText(uri)))

            case .artifactReference:
                guard let artifactID = block.artifactID else {
                    throw AgentToolOutputLoweringError.invalidBlock(
                        index: index,
                        reason: "artifact identity is missing")
                }
                textParts.append(MCPToolResultPresentation.textArtifact(
                    artifactID: sanitizedProviderText(artifactID.rawValue)))
            }
        }

        if textParts.isEmpty, references.isEmpty {
            textParts.append(
                structuredResult.isError
                    ? "MCP tool returned an error."
                    : "MCP tool returned no content.")
        }
        let joined = textParts.joined(separator: "\n")
        return AgentCanonicalToolOutput(
            output: utf8Prefix(joined, maximumBytes: maximumTextBytes),
            imageReferences: references)
    }

    private static func isCanonicalImageMIME(_ value: String) -> Bool {
        value == "image/png" || value == "image/jpeg"
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
                    || (97...102).contains(scalar.value)
            }
    }

    private static func sanitizedProviderText(_ value: String) -> String {
        PermissionReviewTextSanitizer.sanitize(
            value,
            maxCharacters: maximumTextBytes).text
    }

    private static func utf8Prefix(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.endIndex
        while end > value.startIndex,
              value[..<end].utf8.count > maximumBytes {
            end = value.index(before: end)
        }
        return String(value[..<end])
    }
}
