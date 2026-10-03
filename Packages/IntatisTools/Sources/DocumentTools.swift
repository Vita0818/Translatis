import Foundation
import IntatisCore
import IntatisProtocol

// MARK: - Shared, host-owned document tool glue

enum DocumentPageSelection {
    /// Returns nil for the explicit/default `all` selection. Every returned
    /// page number is one-based, unique, and sorted.
    static func parse(_ raw: String?, maximumCount: Int) throws -> [Int]? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty || value.lowercased() == "all" { return nil }

        var selected = Set<Int>()
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            let token = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw DocumentToolError(.validationFailed, "page selection contains an empty item")
            }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2,
                  let first = Int(bounds[0]),
                  first > 0 else {
                throw DocumentToolError(.validationFailed, "page selection is invalid")
            }
            let last: Int
            if bounds.count == 2 {
                guard let parsed = Int(bounds[1]), parsed >= first else {
                    throw DocumentToolError(.validationFailed, "page range is invalid")
                }
                last = parsed
            } else {
                last = first
            }
            guard last - first < maximumCount else {
                throw DocumentToolError(.validationFailed, "page selection exceeds the operation limit")
            }
            for page in first...last {
                selected.insert(page)
                guard selected.count <= maximumCount else {
                    throw DocumentToolError(.validationFailed, "too many pages were selected")
                }
            }
        }
        return selected.sorted()
    }

    static func expand(
        _ raw: String?,
        pageCount: Int,
        maximumCount: Int
    ) throws -> [Int] {
        let selected = try parse(raw, maximumCount: maximumCount)
            ?? Array(1...pageCount)
        guard selected.count <= maximumCount,
              selected.allSatisfy({ (1...pageCount).contains($0) }) else {
            throw DocumentToolError(
                .validationFailed,
                "selected pages are outside the document or exceed the operation limit")
        }
        return selected
    }
}

actor DocumentExecutionAccumulator {
    private var engineVersions: [String: String] = [:]
    private var warnings: [String] = []
    private var result: JSONValue?

    func record(
        versions: [String: String] = [:],
        warnings newWarnings: [String] = [],
        result newResult: JSONValue? = nil
    ) {
        engineVersions.merge(versions) { _, new in new }
        warnings.append(contentsOf: newWarnings)
        if let newResult { result = newResult }
    }

    func snapshot() -> (
        versions: [String: String],
        warnings: [String],
        result: JSONValue?
    ) {
        (engineVersions, warnings, result)
    }
}

enum DocumentToolSupport {
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func observation(
        operation: String,
        format: DocumentFormat,
        result: JSONValue? = nil,
        engineVersions: [String: String] = [:],
        warnings: [String] = [],
        receipt: DocumentCommitReceipt? = nil,
        changedFiles: [String]? = nil,
        truncated: Bool = false
    ) throws -> ToolObservation {
        var object: [String: JSONValue] = [
            "status": .string("ok"),
            "operation": .string(operation),
            "format": .string(format.rawValue),
            "engine_versions": .object(engineVersions.mapValues(JSONValue.string)),
            "warnings": .array(warnings.map(JSONValue.string)),
        ]
        if let result { object["result"] = result }
        if let receipt {
            object["commit"] = .object([
                "path": .string(receipt.relativePath),
                "sha256": .string(receipt.sha256),
                "byte_count": .number(Double(receipt.byteCount)),
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(JSONValue.object(object))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentToolError(.backendFailed, "document result could not be encoded")
        }
        return ToolObservation(
            text: text,
            truncated: truncated,
            changedFiles: changedFiles)
    }

    static func processReadIntent(
        action: String,
        paths: [String],
        operation: String,
        format: DocumentFormat,
        replayPolicy: ToolExecutionReplayPolicy = .doNotReplay
    ) -> PermissionIntent {
        PermissionIntent(
            action: action,
            resources: paths.map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
            },
            metadata: [
                "operation": .string(operation),
                "format": .string(format.rawValue),
                "execution_class": .string(
                    PermissionIntent.structuredReadOnlyExecutionClass),
            ],
            dataEffects: [.read, .execute],
            risks: [.processExecution],
            replayPolicy: replayPolicy)
    }

    static func writeIntent(
        action: String,
        readPaths: [String],
        writePath: String,
        operation: String,
        format: DocumentFormat
    ) -> PermissionIntent {
        var resources = readPaths.map {
            PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
        }
        resources.append(PermissionResource(
            kind: .workspacePath,
            value: writePath,
            access: .readWrite))
        return PermissionIntent(
            action: action,
            resources: resources,
            metadata: [
                "operation": .string(operation),
                "format": .string(format.rawValue),
            ],
            dataEffects: [.read, .execute, .mutate],
            risks: [.processExecution, .workspaceMutation],
            replayPolicy: .doNotReplay)
    }

    struct FrozenAuxiliaryInputs: Sendable {
        let urlsByReviewedPath: [String: URL]
        let snapshots: [DocumentInputSnapshot]
    }

    static func freezeAuxiliaryInputs(
        _ paths: [String],
        workspace: URL
    ) throws -> FrozenAuxiliaryInputs {
        let maximumAssetBytes: UInt64 = 128 * 1_024 * 1_024
        let maximumTotalBytes: UInt64 = 512 * 1_024 * 1_024
        var urlsByReviewedPath: [String: URL] = [:]
        var snapshots: [DocumentInputSnapshot] = []
        var totalBytes: UInt64 = 0
        for path in paths {
            let snapshot = try DocumentInputFile.freezeReadOnly(
                path: path,
                maximumBytes: maximumAssetBytes,
                workspace: workspace)
            guard snapshot.identity.byteCount <= maximumTotalBytes - totalBytes else {
                throw DocumentToolError(
                    .validationFailed,
                    "document assets exceed the aggregate input budget")
            }
            totalBytes += snapshot.identity.byteCount
            urlsByReviewedPath[path] = snapshot.url
            snapshots.append(snapshot)
        }
        return FrozenAuxiliaryInputs(
            urlsByReviewedPath: urlsByReviewedPath,
            snapshots: snapshots)
    }

    static func validatePDFFile(_ pdf: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: pdf) else {
            throw DocumentToolError(.validationFailed, "generated PDF is not readable")
        }
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 5) ?? Data()
        guard prefix == Data("%PDF-".utf8) else {
            throw DocumentToolError(.validationFailed, "generated output is not a PDF")
        }
    }

    static func stageAndRenderHTML(
        input: URL,
        allowedHTMLAssets: [String: URL],
        stagedPDF: URL
    ) async throws -> [String: String] {
        let stageRoot = stagedPDF.deletingLastPathComponent()
        let renderRoot = stageRoot.appendingPathComponent(
            "html-input-\(UUID().uuidString)",
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: renderRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw DocumentToolError(.backendFailed, "HTML render staging could not be created")
        }
        defer { try? FileManager.default.removeItem(at: renderRoot) }

        let inputParent = input.deletingLastPathComponent().standardizedFileURL
        let stagedHTML = renderRoot.appendingPathComponent(
            input.lastPathComponent,
            isDirectory: false)
        try copyHTMLRenderInput(input, to: stagedHTML)

        for asset in allowedHTMLAssets.values.sorted(by: { $0.path < $1.path }) {
            let canonical = asset.standardizedFileURL
            guard canonical.path != input.path,
                  PathConfinement.isWithin(canonical.path, root: inputParent) else {
                throw DocumentToolError(
                    .validationFailed,
                    "HTML local assets must be files below the HTML source directory")
            }
            let relative = PathConfinement.relativePath(of: canonical, root: inputParent)
            guard relative.isEmpty == false,
                  relative != ".",
                  relative.hasPrefix("../") == false,
                  URL(fileURLWithPath: relative).isFileURL else {
                throw DocumentToolError(.validationFailed, "HTML local asset path is invalid")
            }
            let destination = renderRoot.appendingPathComponent(relative, isDirectory: false)
            guard PathConfinement.isWithin(destination.path, root: renderRoot),
                  destination.path != stagedHTML.path else {
                throw DocumentToolError(.validationFailed, "HTML local asset staging path is invalid")
            }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                try copyHTMLRenderInput(canonical, to: destination)
            } catch let error as DocumentToolError {
                throw error
            } catch {
                throw DocumentToolError(.backendFailed, "HTML local asset could not be staged")
            }
        }

        try Task.checkCancellation()
        let renderedPDF = renderRoot.appendingPathComponent("rendered.pdf", isDirectory: false)
        let versions = try await HTMLDocumentPDFRenderer.render(
            input: stagedHTML,
            stageRoot: renderRoot,
            stagedPDF: renderedPDF)
        do {
            try FileManager.default.moveItem(at: renderedPDF, to: stagedPDF)
        } catch {
            throw DocumentToolError(.backendFailed, "WKWebView PDF output could not be staged")
        }
        return versions
    }

    private static func copyHTMLRenderInput(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destination.path)
        } catch {
            throw DocumentToolError(.backendFailed, "HTML render input could not be staged")
        }
    }
}

// MARK: - Fixed-format text readers

private struct DocumentTextCursorPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let format: String
    let sourceSHA256: String
    let element: Int
    let characterOffset: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case format
        case sourceSHA256 = "source_sha256"
        case element
        case characterOffset = "character_offset"
    }
}

private enum DocumentTextReadSupport {
    private static let cursorSchemaVersion = 1

    static func value(_ args: ToolArgs, format: DocumentFormat) throws -> DocumentTextReadArguments {
        try DocumentTextReadArguments.decodeValidated(args, format: format)
    }

    static func continuationValue(
        _ args: ToolArgs,
        format: DocumentFormat
    ) throws -> DocumentTextContinueArguments {
        try DocumentTextContinueArguments.decodeValidated(args, format: format)
    }

    static func touchedPaths(_ args: ToolArgs, format: DocumentFormat) -> [String] {
        (try? value(args, format: format)).map { [$0.path] } ?? []
    }

    static func continuationTouchedPaths(_ args: ToolArgs, format: DocumentFormat) -> [String] {
        (try? continuationValue(args, format: format)).map { [$0.path] } ?? []
    }

    static func permissionIntent(
        _ args: ToolArgs,
        format: DocumentFormat,
        toolName: String,
        sideEffect: SideEffect
    ) -> PermissionIntent {
        guard let value = try? value(args, format: format) else {
            return PermissionIntent.derived(
                toolName: toolName,
                sideEffect: sideEffect,
                touchedPaths: touchedPaths(args, format: format),
                risksNetwork: false)
        }
        return DocumentToolSupport.processReadIntent(
            action: "document.read.\(format.rawValue)",
            paths: [value.path],
            operation: "read_bounded_markdown",
            format: format,
            replayPolicy: .safeToReplay)
    }

    static func continuationPermissionIntent(
        _ args: ToolArgs,
        format: DocumentFormat,
        toolName: String,
        sideEffect: SideEffect
    ) -> PermissionIntent {
        guard let value = try? continuationValue(args, format: format) else {
            return PermissionIntent.derived(
                toolName: toolName,
                sideEffect: sideEffect,
                touchedPaths: continuationTouchedPaths(args, format: format),
                risksNetwork: false)
        }
        return DocumentToolSupport.processReadIntent(
            action: "document.read.\(format.rawValue).continue",
            paths: [value.path],
            operation: "continue_bounded_markdown",
            format: format,
            replayPolicy: .safeToReplay)
    }

    static func execute(
        _ args: ToolArgs,
        format: DocumentFormat,
        operation: String,
        context: ToolContext
    ) async throws -> ToolObservation {
        let value = try value(args, format: format)
        return try await executeWindow(
            path: value.path,
            maximumCharacters: value.maxCharacters ?? 200_000,
            cursor: nil,
            format: format,
            operation: operation,
            context: context)
    }

    static func executeContinuation(
        _ args: ToolArgs,
        format: DocumentFormat,
        operation: String,
        context: ToolContext
    ) async throws -> ToolObservation {
        let value = try continuationValue(args, format: format)
        let cursor = try decodeCursor(value.cursor, expectedFormat: format)
        return try await executeWindow(
            path: value.path,
            maximumCharacters: value.maxCharacters ?? 200_000,
            cursor: cursor,
            format: format,
            operation: operation,
            context: context)
    }

    private static func executeWindow(
        path: String,
        maximumCharacters: Int,
        cursor: DocumentTextCursorPayload?,
        format: DocumentFormat,
        operation: String,
        context: ToolContext
    ) async throws -> ToolObservation {
        let snapshot = try DocumentInputFile.freeze(
            path: path,
            expectedFormat: format,
            expectedSHA256: cursor?.sourceSHA256,
            workspace: context.workspaceRoot)
        let envelope = try await DocumentPythonBackend.run(
            operation: "read_\(format.rawValue)",
            payload: .object([
                "input_path": .string(snapshot.url.path),
                "maximum_characters": .number(Double(maximumCharacters)),
                "maximum_file_bytes": .number(Double(snapshot.identity.byteCount)),
                "start_element": .number(Double(cursor?.element ?? 1)),
                "start_character_offset": .number(Double(cursor?.characterOffset ?? 0)),
            ]),
            readableWorkspacePaths: [path],
            in: context)
        try DocumentInputFile.verifyUnchanged(snapshot)
        let result = try decorateResult(
            envelope.result,
            format: format,
            sourceSHA256: snapshot.identity.sha256,
            sourceByteCount: snapshot.identity.byteCount)
        return try DocumentToolSupport.observation(
            operation: operation,
            format: format,
            result: result,
            engineVersions: envelope.engineVersions,
            warnings: envelope.warnings,
            truncated: {
                guard case .object(let result) = result,
                      case .bool(let truncated)? = result["truncated"] else { return false }
                return truncated
            }())
    }

    private static func decorateResult(
        _ rawResult: JSONValue?,
        format: DocumentFormat,
        sourceSHA256: String,
        sourceByteCount: UInt64
    ) throws -> JSONValue {
        guard case .object(var result)? = rawResult,
              case .string(let returnedFormat)? = result["format"],
              returnedFormat == format.rawValue,
              case .string? = result["markdown"],
              case .bool(let truncated)? = result["truncated"],
              case .object(var navigation)? = result["navigation"],
              let sourceElementCount = exactInteger(navigation["source_element_count"]),
              sourceElementCount >= 1,
              case .array(let rawLandmarks)? = navigation["landmarks"],
              rawLandmarks.count <= 256,
              case .bool? = navigation["landmarks_truncated"] else {
            throw DocumentToolError(.backendFailed, "Docling reader returned an invalid navigation envelope")
        }

        let nextCursor: JSONValue
        switch navigation["next"] {
        case .null?:
            guard truncated == false else {
                throw DocumentToolError(.backendFailed, "Docling reader omitted its continuation position")
            }
            nextCursor = .null
        case .object(let next)?:
            guard truncated,
                  let element = exactInteger(next["element"]),
                  let characterOffset = exactInteger(next["character_offset"]),
                  element >= 1,
                  element < sourceElementCount,
                  characterOffset >= 0 else {
                throw DocumentToolError(.backendFailed, "Docling reader returned an invalid continuation position")
            }
            nextCursor = .string(try encodeCursor(DocumentTextCursorPayload(
                schemaVersion: cursorSchemaVersion,
                format: format.rawValue,
                sourceSHA256: sourceSHA256.lowercased(),
                element: element,
                characterOffset: characterOffset)))
        default:
            throw DocumentToolError(.backendFailed, "Docling reader returned an invalid continuation position")
        }

        var landmarks: [JSONValue] = []
        landmarks.reserveCapacity(rawLandmarks.count)
        for rawLandmark in rawLandmarks {
            guard case .object(var landmark) = rawLandmark,
                  case .string(let kind)? = landmark["kind"],
                  !kind.isEmpty,
                  kind.utf8.count <= 64,
                  case .string(let title)? = landmark["title"],
                  !title.isEmpty,
                  title.count <= 240,
                  let element = exactInteger(landmark["element"]),
                  element >= 1,
                  element < sourceElementCount else {
                throw DocumentToolError(.backendFailed, "Docling reader returned an invalid landmark")
            }
            landmark.removeValue(forKey: "element")
            landmark["cursor"] = .string(try encodeCursor(DocumentTextCursorPayload(
                schemaVersion: cursorSchemaVersion,
                format: format.rawValue,
                sourceSHA256: sourceSHA256.lowercased(),
                element: element,
                characterOffset: 0)))
            landmarks.append(.object(landmark))
        }

        navigation.removeValue(forKey: "next")
        navigation["next_cursor"] = nextCursor
        navigation["landmarks"] = .array(landmarks)
        navigation["cursor_schema_version"] = .number(Double(cursorSchemaVersion))
        result["navigation"] = .object(navigation)
        result["source_sha256"] = .string(sourceSHA256.lowercased())
        result["source_byte_count"] = .number(Double(sourceByteCount))
        return .object(result)
    }

    private static func exactInteger(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value,
              number.isFinite,
              number.rounded(.towardZero) == number else { return nil }
        return Int(exactly: number)
    }

    private static func encodeCursor(_ cursor: DocumentTextCursorPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cursor)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeCursor(
        _ rawValue: String,
        expectedFormat: DocumentFormat
    ) throws -> DocumentTextCursorPayload {
        guard rawValue.count % 4 != 1 else {
            throw DocumentToolError(.validationFailed, "document cursor is malformed")
        }
        let padding = String(repeating: "=", count: (4 - rawValue.count % 4) % 4)
        let base64 = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: base64),
              data.count <= 1_024,
              let cursor = try? JSONDecoder().decode(DocumentTextCursorPayload.self, from: data),
              cursor.schemaVersion == cursorSchemaVersion,
              cursor.format == expectedFormat.rawValue,
              cursor.sourceSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression) != nil,
              cursor.element >= 1,
              cursor.characterOffset >= 0,
              cursor.characterOffset <= 512 * 1_024 * 1_024,
              try encodeCursor(cursor) == rawValue else {
            throw DocumentToolError(.validationFailed, "document cursor is invalid for this reader")
        }
        return cursor
    }
}

public struct ReadDOCXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_docx",
        description: "Read one DOCX workspace file as bounded Markdown with the fixed local Docling DOCX converter. The result includes source-bound next/section cursors for continue_docx_read. The format and backend are fixed; no fallback, edit, rendering, or OCR is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .docx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .docx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .docx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .docx, operation: Self.descriptor.name, context: context) }
}

public struct ReadPPTXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_pptx",
        description: "Read one PPTX workspace file as bounded Markdown with the fixed local Docling PPTX converter. The result includes source-bound next/slide/section cursors for continue_pptx_read. The format and backend are fixed; no fallback, edit, rendering, or OCR is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .pptx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .pptx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .pptx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .pptx, operation: Self.descriptor.name, context: context) }
}

public struct ReadXLSXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_xlsx",
        description: "Read one XLSX workspace file as bounded Markdown with the fixed local Docling XLSX converter. The result includes source-bound next/sheet/section cursors for continue_xlsx_read. The format and backend are fixed; no fallback, edit, recalculation, or formula execution is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .xlsx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .xlsx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .xlsx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .xlsx, operation: Self.descriptor.name, context: context) }
}

public struct ReadHTMLTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_html",
        description: "Read one local HTML workspace file as bounded Markdown with the fixed local Docling HTML converter. The result includes source-bound next/section cursors for continue_html_read. The format and backend are fixed; no fallback, script execution, network access, or rendering is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .html) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .html) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .html, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .html, operation: Self.descriptor.name, context: context) }
}

public struct ReadEPUBTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_epub",
        description: "Read one EPUB workspace file as bounded Markdown with the fixed local Docling EPUB converter. The result includes source-bound next/section cursors for continue_epub_read. The format and backend are fixed; no fallback, edit, rendering, or network access is attempted.",
        sideEffect: .exec,
        parameters: DocumentTextReadArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.value(args, format: .epub) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.touchedPaths(args, format: .epub) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.permissionIntent(args, format: .epub, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.execute(args, format: .epub, operation: Self.descriptor.name, context: context) }
}

// MARK: - Fixed-format text reader continuation

public struct ContinueDOCXReadTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "continue_docx_read",
        description: "Continue or jump within one DOCX using a source-bound opaque cursor returned by read_docx or this tool. Content and landmarks come from the same fixed local Docling DOCX converter.",
        sideEffect: .exec,
        parameters: DocumentTextContinueArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.continuationValue(args, format: .docx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.continuationTouchedPaths(args, format: .docx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.continuationPermissionIntent(args, format: .docx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.executeContinuation(args, format: .docx, operation: Self.descriptor.name, context: context) }
}

public struct ContinuePPTXReadTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "continue_pptx_read",
        description: "Continue or jump within one PPTX using a source-bound opaque cursor returned by read_pptx or this tool. Content and slide landmarks come from the same fixed local Docling PPTX converter.",
        sideEffect: .exec,
        parameters: DocumentTextContinueArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.continuationValue(args, format: .pptx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.continuationTouchedPaths(args, format: .pptx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.continuationPermissionIntent(args, format: .pptx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.executeContinuation(args, format: .pptx, operation: Self.descriptor.name, context: context) }
}

public struct ContinueXLSXReadTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "continue_xlsx_read",
        description: "Continue or jump within one XLSX using a source-bound opaque cursor returned by read_xlsx or this tool. Content and sheet landmarks come from the same fixed local Docling XLSX converter.",
        sideEffect: .exec,
        parameters: DocumentTextContinueArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.continuationValue(args, format: .xlsx) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.continuationTouchedPaths(args, format: .xlsx) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.continuationPermissionIntent(args, format: .xlsx, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.executeContinuation(args, format: .xlsx, operation: Self.descriptor.name, context: context) }
}

public struct ContinueHTMLReadTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "continue_html_read",
        description: "Continue or jump within one local HTML document using a source-bound opaque cursor returned by read_html or this tool. Content and landmarks come from the same fixed local Docling HTML converter.",
        sideEffect: .exec,
        parameters: DocumentTextContinueArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.continuationValue(args, format: .html) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.continuationTouchedPaths(args, format: .html) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.continuationPermissionIntent(args, format: .html, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.executeContinuation(args, format: .html, operation: Self.descriptor.name, context: context) }
}

public struct ContinueEPUBReadTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "continue_epub_read",
        description: "Continue or jump within one EPUB using a source-bound opaque cursor returned by read_epub or this tool. Content and chapter landmarks come from the same fixed local Docling EPUB converter.",
        sideEffect: .exec,
        parameters: DocumentTextContinueArguments.schema)
    public func validateArguments(_ args: ToolArgs) throws { _ = try DocumentTextReadSupport.continuationValue(args, format: .epub) }
    public func touchedPaths(_ args: ToolArgs) -> [String] { DocumentTextReadSupport.continuationTouchedPaths(args, format: .epub) }
    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent { DocumentTextReadSupport.continuationPermissionIntent(args, format: .epub, toolName: Self.descriptor.name, sideEffect: Self.descriptor.sideEffect) }
    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation { try await DocumentTextReadSupport.executeContinuation(args, format: .epub, operation: Self.descriptor.name, context: context) }
}

// MARK: - Exact PDF OCR and rendering

public struct OCRPDFTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.ocr"
    public static let descriptor = ToolDescriptor(
        name: "ocr_pdf",
        description: "Convert one image-only PDF to bounded Markdown with one fixed local Docling DocumentConverter call using the pinned Tesseract runtime. First pass inspect_pdf.source_sha256. The tool does not generate or edit a PDF.",
        sideEffect: .exec,
        parameters: OCRPDFArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try OCRPDFArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? OCRPDFArguments.decodeValidated(args)).map { [$0.inputPath] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        DocumentToolSupport.processReadIntent(
            action: "document.ocr.pdf",
            paths: touchedPaths(args),
            operation: Self.descriptor.name,
            format: .pdf)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try OCRPDFArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: .pdf,
            expectedSHA256: value.expectedSourceSHA256,
            maximumBytes: 100 * 1_024 * 1_024,
            workspace: context.workspaceRoot)
        let payload = try DocumentPythonBackend.fixedOCRPayload(
            inputPath: snapshot.url.path,
            maximumCharacters: value.maxCharacters ?? 200_000,
            maximumFileBytes: 100 * 1_024 * 1_024)
        let envelope = try await DocumentPythonBackend.run(
            operation: Self.descriptor.name,
            payload: payload,
            readableWorkspacePaths: [value.inputPath],
            in: context)
        try DocumentInputFile.verifyUnchanged(snapshot)
        return try DocumentToolSupport.observation(
            operation: Self.descriptor.name,
            format: .pdf,
            result: envelope.result,
            engineVersions: envelope.engineVersions,
            warnings: envelope.warnings,
            truncated: {
                guard case .object(let result)? = envelope.result,
                      case .bool(let truncated)? = result["truncated"] else { return false }
                return truncated
            }())
    }
}

public struct PDFRenderPageTool: Tool {
    public init() {}

    public static let canonicalPermission: String? = "document.render"
    public static let descriptor = ToolDescriptor(
        name: "pdf_render_page",
        description: "Draw exactly one page of one workspace PDF to one PNG with PDFKit PDFPage.draw. Rendering is fixed to the crop box, 144 DPI, a white background, and visible annotations; export other formats to PDF first.",
        sideEffect: .exec,
        parameters: PDFRenderPageArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try PDFRenderPageArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? PDFRenderPageArguments.decodeValidated(args) else { return [] }
        return [value.inputPath, value.outputPath]
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? PDFRenderPageArguments.decodeValidated(args) else {
            return PermissionIntent.derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        return DocumentToolSupport.writeIntent(
            action: "document.render.pdf.page",
            readPaths: [value.inputPath],
            writePath: value.outputPath,
            operation: Self.descriptor.name,
            format: .pdf)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try PDFRenderPageArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: .pdf,
            expectedSHA256: value.expectedSourceSHA256,
            workspace: context.workspaceRoot)
        let request = DocumentStagedFileRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputPath,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            fileExtension: "png",
            maximumBytes: 128 * 1_024 * 1_024)
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedPNG in
                let data = try PDFNativeDocumentService.renderPagePNG(
                    from: snapshot.url,
                    pageNumber: value.page,
                    box: .cropBox,
                    dpi: 144,
                    background: .white,
                    includeAnnotations: true,
                    maximumPagePixels: 40_000_000,
                    maximumOutputBytes: 128 * 1_024 * 1_024)
                try data.write(to: stagedPNG, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: stagedPNG.path)
            },
            validate: { output in
                let prefix = try Data(contentsOf: output, options: [.mappedIfSafe]).prefix(8)
                guard prefix.elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else {
                    throw DocumentToolError(.validationFailed, "PDFKit did not produce a PNG")
                }
            })
        let result: JSONValue = .object([
            "page": .number(Double(value.page)),
            "dpi": .number(144),
            "page_box": .string("crop"),
            "background": .string("white"),
            "annotations": .string("show"),
        ])
        return try DocumentToolSupport.observation(
            operation: Self.descriptor.name,
            format: .pdf,
            result: result,
            engineVersions: ["pdfkit": "system"],
            receipt: receipt,
            changedFiles: [value.outputPath])
    }
}
