#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools
import MCP

public enum MCPRawToolContent: Equatable, Sendable {
    case text(String)
    case image(base64: String, mimeType: String)
    case audio(base64: String, mimeType: String)
    case resourceLink(
        uri: String,
        name: String,
        title: String?,
        summary: String?,
        mimeType: String?)
    case embeddedResource(
        uri: String,
        mimeType: String?,
        text: String?,
        base64: String?)
}

public struct MCPRawToolCallResult: Equatable, Sendable {
    public let content: [MCPRawToolContent]
    public let structuredContent: JSONValue?
    public let isError: Bool

    public init(
        content: [MCPRawToolContent] = [],
        structuredContent: JSONValue? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

public struct MCPStoredToolArtifact: Equatable, Sendable {
    public let artifactID: ArtifactID
    public let byteCount: Int
    public let sha256: String

    public init(
        artifactID: ArtifactID,
        byteCount: Int,
        sha256: String
    ) {
        self.artifactID = artifactID
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Host seam implemented by the session's owner-only ArtifactStore adapter.
public protocol MCPToolArtifactSink: Sendable {
    func storeMCPToolArtifact(
        _ data: Data,
        mimeType: String?,
        provenance: MCPContentProvenance
    ) async throws -> MCPStoredToolArtifact
}

public protocol MCPToolResultSanitizer: Sendable {
    func sanitizeMCPText(_ text: String) throws -> String
    func validateMCPBinary(_ data: Data) throws
}

public extension MCPToolResultSanitizer {
    func validateMCPBinary(_ data: Data) throws {
        guard let text = String(
            data: data,
            encoding: .utf8
        ) else {
            return
        }
        guard try sanitizeMCPText(text) == text else {
            throw MCPOutputSecurityError
                .sensitiveBinaryPayload
        }
    }
}

/// Built-in conservative scanner for result text. Hosts may inject the shared
/// Intatis SecretScanner adapter, but a missing adapter never means raw text.
public struct MCPConservativeToolResultSanitizer:
    MCPToolResultSanitizer, Sendable {
    public init() {}

    public func sanitizeMCPText(_ text: String) throws -> String {
        var result = text
        for expression in Self.expressions {
            let range = NSRange(
                result.startIndex..<result.endIndex,
                in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[REDACTED]")
        }
        return result
    }

    private static let expressions: [NSRegularExpression] = {
        let patterns = [
            #"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{12,}"#,
            #"\b(sk-(?:proj-)?[A-Za-z0-9_-]{12,})\b"#,
            #"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)\s*[:=]\s*[^\s,;]{8,}"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}

public struct MCPToolResultLimits: Equatable, Sendable {
    public let maximumBlocks: Int
    public let maximumTextBytesPerBlock: Int
    public let maximumBinaryBytesPerBlock: Int
    public let maximumTotalBytes: Int
    public let maximumModelTextBytes: Int

    public init(
        maximumBlocks: Int = 256,
        maximumTextBytesPerBlock: Int = 256 * 1_024,
        maximumBinaryBytesPerBlock: Int = 16 * 1_024 * 1_024,
        maximumTotalBytes: Int = 32 * 1_024 * 1_024,
        maximumModelTextBytes: Int = 512 * 1_024
    ) {
        self.maximumBlocks = maximumBlocks
        self.maximumTextBytesPerBlock = maximumTextBytesPerBlock
        self.maximumBinaryBytesPerBlock = maximumBinaryBytesPerBlock
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumModelTextBytes = maximumModelTextBytes
    }
}

/// Atomic aggregate byte budget shared by all MCP output conversions in one
/// provider request or one Agent turn. Reservation happens before any
/// ArtifactStore write, so concurrent calls cannot each pass an obsolete
/// remaining-byte check.
public final class MCPToolResultAggregateBudget:
    @unchecked Sendable
{
    public enum Scope:
        String, Equatable, Sendable
    {
        case providerRequest = "provider_request"
        case turn
    }

    public let scope: Scope
    public let maximumBytes: Int

    private let lock = NSLock()
    private var consumedBytes = 0

    public init(
        scope: Scope,
        maximumBytes: Int
    ) {
        self.scope = scope
        self.maximumBytes = max(1, maximumBytes)
    }

    public func reserve(_ byteCount: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try validateReservationLocked(byteCount)
        consumedBytes += byteCount
    }

    /// Reserves one output against both aggregate scopes as a single
    /// transaction. Every production converter uses the same
    /// provider-request-then-turn lock order, so concurrent tool, resource,
    /// and tool-search results cannot consume one scope without the other.
    public static func reserveAtomically(
        _ byteCount: Int,
        providerRequest:
            MCPToolResultAggregateBudget?,
        turn:
            MCPToolResultAggregateBudget?
    ) throws {
        if let providerRequest,
           let turn,
           providerRequest !== turn {
            providerRequest.lock.lock()
            turn.lock.lock()
            defer {
                turn.lock.unlock()
                providerRequest.lock.unlock()
            }
            try providerRequest
                .validateReservationLocked(byteCount)
            try turn
                .validateReservationLocked(byteCount)
            providerRequest.consumedBytes += byteCount
            turn.consumedBytes += byteCount
            return
        }
        try (providerRequest ?? turn)?
            .reserve(byteCount)
    }

    public var consumed: Int {
        lock.lock()
        defer { lock.unlock() }
        return consumedBytes
    }

    private func validateReservationLocked(
        _ byteCount: Int
    ) throws {
        guard byteCount >= 0,
              byteCount <= maximumBytes,
              consumedBytes
                <= maximumBytes - byteCount
        else {
            throw MCPToolExecutionError
                .aggregateBudgetExceeded(
                    scope: scope.rawValue,
                    maximum: maximumBytes)
        }
    }
}

public enum MCPToolResultAggregateLimits {
    public static let maximumProviderRequestBytes =
        64 * 1_024 * 1_024
    public static let maximumTurnBytes =
        128 * 1_024 * 1_024
}

public enum MCPToolExecutionError:
    Error, Equatable, LocalizedError, Sendable {
    case operationUnsupported
    case invalidArguments(String)
    case serverOutputSchemaMismatch(String)
    case tooManyContentBlocks(maximum: Int)
    case contentBlockTooLarge(maximum: Int)
    case resultTooLarge(maximum: Int)
    case malformedBase64
    case artifactSinkRequired
    case artifactWriteFailed
    case aggregateBudgetExceeded(
        scope: String,
        maximum: Int)
    case notStarted(String)
    case executionUncertain(String)

    public var errorDescription: String? {
        switch self {
        case .operationUnsupported:
            return "this exact MCP client generation does not implement tool operations"
        case .invalidArguments(let reason):
            return "MCP tool arguments are invalid: \(reason)"
        case .serverOutputSchemaMismatch(let reason):
            return "MCP server output does not match its declared schema: \(reason)"
        case .tooManyContentBlocks(let maximum):
            return "MCP tool result exceeds \(maximum) content blocks"
        case .contentBlockTooLarge(let maximum):
            return "MCP tool result block exceeds \(maximum) bytes"
        case .resultTooLarge(let maximum):
            return "MCP tool result exceeds \(maximum) bytes"
        case .malformedBase64:
            return "MCP tool result contains malformed base64 data"
        case .artifactSinkRequired:
            return "MCP binary or oversized result requires an ArtifactStore sink"
        case .artifactWriteFailed:
            return "MCP tool result could not be committed to ArtifactStore"
        case .aggregateBudgetExceeded(
            let scope,
            let maximum):
            return "MCP \(scope) output exceeds the aggregate \(maximum)-byte limit"
        case .notStarted(let reason):
            return "MCP tool call did not start: \(reason)"
        case .executionUncertain(let reason):
            return "MCP tool call execution is uncertain: \(reason)"
        }
    }
}

/// Stable model-facing text for non-inline MCP content. Re-lowering a durable
/// structured result must use these same presentations as the live converter.
public enum MCPToolResultPresentation {
    public static func resource(uri: String) -> String {
        "[MCP resource \(uri)]"
    }

    public static func embeddedResource(uri: String) -> String {
        "[MCP embedded resource \(uri)]"
    }

    public static func textArtifact(artifactID: String) -> String {
        "[MCP text artifact \(artifactID)]"
    }
}

/// Converts untrusted MCP content into the additive structured observation.
public struct MCPToolResultConverter: Sendable {
    public let limits: MCPToolResultLimits
    private let sanitizer: any MCPToolResultSanitizer
    private let artifactSink: (any MCPToolArtifactSink)?
    private let providerRequestBudget:
        MCPToolResultAggregateBudget?
    private let turnBudget:
        MCPToolResultAggregateBudget?

    public init(
        limits: MCPToolResultLimits = .init(),
        sanitizer: any MCPToolResultSanitizer =
            MCPConservativeToolResultSanitizer(),
        artifactSink: (any MCPToolArtifactSink)? = nil,
        providerRequestBudget:
            MCPToolResultAggregateBudget? = nil,
        turnBudget:
            MCPToolResultAggregateBudget? = nil
    ) {
        self.limits = limits
        self.sanitizer = sanitizer
        self.artifactSink = artifactSink
        self.providerRequestBudget =
            providerRequestBudget
        self.turnBudget = turnBudget
    }

    public func scoped(
        providerRequestBudget:
            MCPToolResultAggregateBudget,
        turnBudget:
            MCPToolResultAggregateBudget
    ) -> MCPToolResultConverter {
        MCPToolResultConverter(
            limits: limits,
            sanitizer: sanitizer,
            artifactSink: artifactSink,
            providerRequestBudget:
                providerRequestBudget,
            turnBudget: turnBudget)
    }

    /// Charges an already-canonicalized non-tool-call MCP output (currently
    /// `tool_search`) against the exact same single-result and aggregate
    /// budgets used by remote tool results. Callers must invoke this before
    /// publishing state or returning the output.
    public func reserveCanonicalOutputBytes(
        _ byteCount: Int
    ) throws {
        guard byteCount >= 0,
              byteCount <= limits.maximumTotalBytes
        else {
            throw MCPToolExecutionError
                .resultTooLarge(
                    maximum:
                        limits.maximumTotalBytes)
        }
        try MCPToolResultAggregateBudget
            .reserveAtomically(
                byteCount,
                providerRequest:
                    providerRequestBudget,
                turn: turnBudget)
    }

    public func convert(
        _ raw: MCPRawToolCallResult,
        outputSchema: JSONValue?,
        outputSchemaHash: String?,
        provenance: MCPContentProvenance
    ) async throws -> ToolObservation {
        guard raw.content.count <= limits.maximumBlocks else {
            throw MCPToolExecutionError.tooManyContentBlocks(
                maximum: limits.maximumBlocks)
        }
        if let outputSchema {
            guard let structured = raw.structuredContent else {
                throw MCPToolExecutionError.serverOutputSchemaMismatch(
                    "structuredContent is missing")
            }
            do {
                try MCPJSONSchema.validate(
                    structured,
                    against: outputSchema)
            } catch {
                throw MCPToolExecutionError.serverOutputSchemaMismatch(
                    error.localizedDescription)
            }
        }
        let rawBytes =
            try preflightTotalBytes(raw)
        let sanitizedBytes =
            try preflightSanitizedTotalBytes(raw)
        let reservedBytes =
            max(rawBytes, sanitizedBytes)
        try MCPToolResultAggregateBudget
            .reserveAtomically(
                reservedBytes,
                providerRequest:
                    providerRequestBudget,
                turn: turnBudget)

        var blocks: [MCPContentBlock] = []
        var textParts: [String] = []
        var totalBytes = 0
        var modelTextBytes = 0
        var truncated = false

        for content in raw.content {
            switch content {
            case .text(let untrusted):
                let sanitized =
                    try sanitizer
                        .sanitizeMCPText(untrusted)
                let safeData =
                    Data(sanitized.utf8)
                totalBytes += safeData.count
                try enforceTotal(totalBytes)
                guard safeData.count
                        <= limits.maximumTextBytesPerBlock
                else {
                    let artifact = try await appendArtifact(
                        safeData,
                        mimeType: "text/plain",
                        provenance: provenance,
                        blocks: &blocks)
                    textParts.append(MCPToolResultPresentation.textArtifact(
                        artifactID: artifact.artifactID.rawValue))
                    truncated = true
                    continue
                }
                let available = max(
                    0,
                    limits.maximumModelTextBytes - modelTextBytes)
                let bounded = Self.utf8Prefix(sanitized, maximumBytes: available)
                if bounded.utf8.count < sanitized.utf8.count {
                    truncated = true
                }
                modelTextBytes += bounded.utf8.count
                if !bounded.isEmpty { textParts.append(bounded) }
                blocks.append(MCPContentBlock(
                    kind: .text,
                    text: bounded,
                    byteCount: safeData.count,
                    sha256: Self.sha256(safeData),
                    truncated: bounded.utf8.count < sanitized.utf8.count,
                    provenance: provenance))

            case .image(let encoded, let mimeType):
                let data = try decodeBinary(encoded)
                let safeMIMEType = try Self.validatedMimeType(mimeType)
                totalBytes += data.count
                try enforceTotal(totalBytes)
                let artifact = try await store(
                    data,
                    mimeType: safeMIMEType,
                    provenance: provenance)
                blocks.append(MCPContentBlock(
                    kind: .imageReference,
                    artifactID: artifact.artifactID,
                    mimeType: safeMIMEType,
                    byteCount: artifact.byteCount,
                    sha256: artifact.sha256,
                    provenance: provenance))
                textParts.append("[MCP image artifact \(artifact.artifactID.rawValue)]")

            case .audio(let encoded, let mimeType):
                let data = try decodeBinary(encoded)
                let safeMIMEType = try Self.validatedMimeType(mimeType)
                totalBytes += data.count
                try enforceTotal(totalBytes)
                let artifact = try await store(
                    data,
                    mimeType: safeMIMEType,
                    provenance: provenance)
                blocks.append(MCPContentBlock(
                    kind: .audioReference,
                    artifactID: artifact.artifactID,
                    mimeType: safeMIMEType,
                    byteCount: artifact.byteCount,
                    sha256: artifact.sha256,
                    provenance: provenance))
                textParts.append("[MCP audio artifact \(artifact.artifactID.rawValue)]")

            case .resourceLink(
                let uri,
                let name,
                let title,
                let summary,
                let mimeType):
                let boundedURI = try Self.validatedURI(uri)
                let safeURI = try sanitizer
                    .sanitizeMCPText(boundedURI)
                let safeMIMEType = try Self
                    .validatedMimeType(
                        mimeType)
                    .map {
                        try MCPOutputSanitization
                            .requireUnchangedIdentifier(
                                $0,
                                using: sanitizer)
                    }
                let display = try sanitizer.sanitizeMCPText(
                    [title, summary, name].compactMap { $0 }
                        .joined(separator: " — "))
                let bytes = safeURI.utf8.count + display.utf8.count
                totalBytes += bytes
                try enforceTotal(totalBytes)
                blocks.append(MCPContentBlock(
                    kind: .resourceLink,
                    text: Self.utf8Prefix(
                        display,
                        maximumBytes: limits.maximumTextBytesPerBlock),
                    uri: safeURI,
                    mimeType: safeMIMEType,
                    byteCount: bytes,
                    sha256: Self.sha256(Data(safeURI.utf8)),
                    provenance: provenance))
                textParts.append(MCPToolResultPresentation.resource(
                    uri: safeURI))

            case .embeddedResource(
                let uri,
                let mimeType,
                let embeddedText,
                let encoded):
                let boundedURI = try Self.validatedURI(uri)
                let safeURI = try sanitizer
                    .sanitizeMCPText(boundedURI)
                let safeMIMEType = try Self
                    .validatedMimeType(
                        mimeType)
                    .map {
                        try MCPOutputSanitization
                            .requireUnchangedIdentifier(
                                $0,
                                using: sanitizer)
                    }
                if let embeddedText {
                    let sanitized =
                        try sanitizer.sanitizeMCPText(
                            embeddedText)
                    let safeData =
                        Data(sanitized.utf8)
                    totalBytes += safeData.count
                    try enforceTotal(totalBytes)
                    if safeData.count
                            > limits.maximumTextBytesPerBlock {
                        _ = try await appendArtifact(
                            safeData,
                            mimeType: safeMIMEType ?? "text/plain",
                            provenance: provenance,
                            blocks: &blocks)
                        truncated = true
                    } else {
                        blocks.append(MCPContentBlock(
                            kind: .embeddedResourceReference,
                            text: sanitized,
                            uri: safeURI,
                            mimeType: safeMIMEType,
                            byteCount: safeData.count,
                            sha256: Self.sha256(safeData),
                            provenance: provenance))
                    }
                } else if let encoded {
                    let data = try decodeBinary(encoded)
                    totalBytes += data.count
                    try enforceTotal(totalBytes)
                    let artifact = try await store(
                        data,
                        mimeType: safeMIMEType,
                        provenance: provenance)
                    blocks.append(MCPContentBlock(
                        kind: .embeddedResourceReference,
                        artifactID: artifact.artifactID,
                        uri: safeURI,
                        mimeType: safeMIMEType,
                        byteCount: artifact.byteCount,
                        sha256: artifact.sha256,
                        provenance: provenance))
                } else {
                    throw MCPToolExecutionError.contentBlockTooLarge(
                        maximum: limits.maximumTextBytesPerBlock)
                }
                textParts.append(MCPToolResultPresentation.embeddedResource(
                    uri: safeURI))
            }
        }

        let sanitizedStructured = try raw.structuredContent.map {
            try MCPOutputSanitization
                .sanitizeJSON(
                    $0,
                    using: sanitizer)
        }
        if let sanitizedStructured {
            let data = try MCPJSONSchema.canonicalData(sanitizedStructured)
            totalBytes += data.count
            try enforceTotal(totalBytes)
            blocks.append(MCPContentBlock(
                kind: .structuredJSON,
                structuredJSON: sanitizedStructured,
                byteCount: data.count,
                sha256: Self.sha256(data),
                provenance: provenance))
        }

        let unboundedText = textParts.isEmpty
            ? (raw.isError
                ? "MCP tool returned an error."
                : "(no MCP text content)")
            : textParts.joined(separator: "\n")
        let text = Self.utf8Prefix(
            unboundedText,
            maximumBytes: limits.maximumModelTextBytes)
        if text.utf8.count < unboundedText.utf8.count {
            truncated = true
        }
        let structured = MCPStructuredToolResult(
            content: blocks,
            structuredContent: sanitizedStructured,
            outputSchemaHash: outputSchemaHash,
            isError: raw.isError,
            totalByteCount: totalBytes,
            truncated: truncated)
        return ToolObservation(
            text: text,
            truncated: truncated,
            structuredResult: structured)
    }

    private func decodeBinary(_ encoded: String) throws -> Data {
        guard let data = Data(base64Encoded: encoded),
              data.count <= limits.maximumBinaryBytesPerBlock else {
            if Data(base64Encoded: encoded) == nil {
                throw MCPToolExecutionError.malformedBase64
            }
            throw MCPToolExecutionError.contentBlockTooLarge(
                maximum: limits.maximumBinaryBytesPerBlock)
        }
        return data
    }

    private func preflightTotalBytes(
        _ raw: MCPRawToolCallResult
    ) throws -> Int {
        var total = 0
        for content in raw.content {
            let bytes: Int
            switch content {
            case .text(let text):
                bytes = text.utf8.count
            case .image(let encoded, _),
                 .audio(let encoded, _):
                bytes = try decodeBinary(encoded).count
            case .resourceLink(
                let uri,
                let name,
                let title,
                let summary,
                _):
                bytes = uri.utf8.count
                    + name.utf8.count
                    + (title?.utf8.count ?? 0)
                    + (summary?.utf8.count ?? 0)
            case .embeddedResource(
                _,
                _,
                let text,
                let encoded):
                if let text {
                    bytes = text.utf8.count
                } else if let encoded {
                    bytes =
                        try decodeBinary(encoded).count
                } else {
                    throw MCPToolExecutionError
                        .contentBlockTooLarge(
                            maximum:
                                limits
                                    .maximumTextBytesPerBlock)
                }
            }
            let (next, overflow) =
                total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw MCPToolExecutionError
                    .resultTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
            try enforceTotal(total)
        }
        if let structured =
                raw.structuredContent {
            let bytes =
                try MCPJSONSchema
                    .canonicalData(structured)
                    .count
            let (next, overflow) =
                total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw MCPToolExecutionError
                    .resultTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
            try enforceTotal(total)
        }
        return total
    }

    private func preflightSanitizedTotalBytes(
        _ raw: MCPRawToolCallResult
    ) throws -> Int {
        var total = 0
        for content in raw.content {
            let bytes: Int
            switch content {
            case .text(let text):
                bytes = try sanitizer
                    .sanitizeMCPText(text)
                    .utf8.count
            case .image(let encoded, let mimeType),
                 .audio(let encoded, let mimeType):
                let data = try decodeBinary(encoded)
                try sanitizer.validateMCPBinary(data)
                if let mimeType =
                        try Self.validatedMimeType(mimeType) {
                    _ = try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            mimeType,
                            using: sanitizer)
                }
                bytes = data.count
            case .resourceLink(
                let uri,
                let name,
                let title,
                let summary,
                let mimeType):
                let safeURI = try sanitizer
                    .sanitizeMCPText(
                        Self.validatedURI(uri))
                if let mimeType =
                        try Self.validatedMimeType(mimeType) {
                    _ = try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            mimeType,
                            using: sanitizer)
                }
                let display = try sanitizer
                    .sanitizeMCPText(
                        [title, summary, name]
                            .compactMap { $0 }
                            .joined(separator: " — "))
                bytes = safeURI.utf8.count
                    + display.utf8.count
            case .embeddedResource(
                let uri,
                let mimeType,
                let text,
                let encoded):
                _ = try sanitizer
                    .sanitizeMCPText(
                        Self.validatedURI(uri))
                if let mimeType =
                        try Self.validatedMimeType(mimeType) {
                    _ = try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            mimeType,
                            using: sanitizer)
                }
                if let text {
                    bytes = try sanitizer
                        .sanitizeMCPText(text)
                        .utf8.count
                } else if let encoded {
                    let data = try decodeBinary(encoded)
                    try sanitizer.validateMCPBinary(data)
                    bytes = data.count
                } else {
                    throw MCPToolExecutionError
                        .contentBlockTooLarge(
                            maximum:
                                limits
                                    .maximumTextBytesPerBlock)
                }
            }
            let (next, overflow) =
                total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw MCPToolExecutionError
                    .resultTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
            try enforceTotal(total)
        }
        if let structured = raw.structuredContent {
            let sanitized = try MCPOutputSanitization
                .sanitizeJSON(
                    structured,
                    using: sanitizer)
            let bytes = try MCPJSONSchema
                .canonicalData(sanitized)
                .count
            let (next, overflow) =
                total.addingReportingOverflow(bytes)
            guard !overflow else {
                throw MCPToolExecutionError
                    .resultTooLarge(
                        maximum:
                            limits.maximumTotalBytes)
            }
            total = next
            try enforceTotal(total)
        }
        return total
    }

    private func enforceTotal(_ total: Int) throws {
        guard total <= limits.maximumTotalBytes else {
            throw MCPToolExecutionError.resultTooLarge(
                maximum: limits.maximumTotalBytes)
        }
    }

    private func appendArtifact(
        _ data: Data,
        mimeType: String?,
        provenance: MCPContentProvenance,
        blocks: inout [MCPContentBlock]
    ) async throws -> MCPStoredToolArtifact {
        let artifact = try await store(
            data,
            mimeType: mimeType,
            provenance: provenance)
        blocks.append(MCPContentBlock(
            kind: .artifactReference,
            artifactID: artifact.artifactID,
            mimeType: mimeType,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            truncated: true,
            provenance: provenance))
        return artifact
    }

    private func store(
        _ data: Data,
        mimeType: String?,
        provenance: MCPContentProvenance
    ) async throws -> MCPStoredToolArtifact {
        guard let artifactSink else {
            throw MCPToolExecutionError.artifactSinkRequired
        }
        try sanitizer.validateMCPBinary(data)
        do {
            let stored = try await artifactSink.storeMCPToolArtifact(
                data,
                mimeType: mimeType,
                provenance: provenance)
            guard stored.byteCount == data.count,
                  stored.sha256 == Self.sha256(data) else {
                throw MCPToolExecutionError.artifactWriteFailed
            }
            return stored
        } catch let error as MCPToolExecutionError {
            throw error
        } catch {
            throw MCPToolExecutionError.artifactWriteFailed
        }
    }

    private static func validatedURI(_ value: String) throws -> String {
        guard value.utf8.count <= 16 * 1_024,
              !value.contains("\0"),
              !value.contains(where: \.isNewline),
              let components = URLComponents(string: value),
              components.scheme != nil else {
            throw MCPToolExecutionError.contentBlockTooLarge(
                maximum: 16 * 1_024)
        }
        return value
    }

    private static func validatedMimeType(
        _ value: String?
    ) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= 256,
              !value.contains("\0"),
              !value.contains(where: \.isNewline) else {
            throw MCPToolExecutionError.contentBlockTooLarge(maximum: 256)
        }
        return value
    }

    private static func utf8Prefix(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard maximumBytes > 0,
              value.utf8.count > maximumBytes else {
            return maximumBytes > 0 ? value : ""
        }
        var end = value.startIndex
        var count = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let bytes = value[end..<next].utf8.count
            if count + bytes > maximumBytes { break }
            count += bytes
            end = next
        }
        return String(value[..<end])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Pinned SDK result bridge

extension MCPRawToolCallResult {
    init(sdkResult: CallTool.Result) throws {
        content = sdkResult.content.map { item in
            switch item {
            case .text(let text, _, _):
                return .text(text)
            case .image(let data, let mimeType, _, _):
                return .image(base64: data, mimeType: mimeType)
            case .audio(let data, let mimeType, _, _):
                return .audio(base64: data, mimeType: mimeType)
            case .resource(let resource, _, _):
                return .embeddedResource(
                    uri: resource.uri,
                    mimeType: resource.mimeType,
                    text: resource.text,
                    base64: resource.blob)
            case .resourceLink(
                let uri,
                let name,
                let title,
                let description,
                let mimeType,
                _):
                return .resourceLink(
                    uri: uri,
                    name: name,
                    title: title,
                    summary: description,
                    mimeType: mimeType)
            }
        }
        structuredContent = try sdkResult.structuredContent.map(
            MCPJSONValueBridge.fromSDK)
        isError = sdkResult.isError ?? false
    }
}
