import Foundation
import IntatisCore
import IntatisProtocol

// MARK: - inspect_pdf / read_pdf

public struct InspectPDFTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "inspect_pdf",
        description: "Inspect one workspace PDF with the native PDFKit reader and return its host-computed source SHA-256, byte count, page count, and native-text/OCR status. Use source_sha256 as ocr_pdf.expected_source_sha256; this tool never returns document text or performs OCR.",
        sideEffect: .readOnly,
        parameters: InspectPDFArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try InspectPDFArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? InspectPDFArguments.decodeValidated(args)).map { [$0.path] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "document.inspect.pdf",
            resources: touchedPaths(args).map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
            },
            metadata: ["operation": .string("inspect_native_pdf_identity")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try InspectPDFArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.path,
            expectedFormat: .pdf,
            workspace: context.workspaceRoot)
        let result: PDFNativeTextReadResult
        do {
            result = try PDFNativeDocumentService.readNativeText(
                from: snapshot.url,
                pages: nil,
                maximumCharacters: 1)
        } catch let error as PDFNativeDocumentServiceError {
            throw mapPDFReadError(error, operation: "inspect")
        }
        try DocumentInputFile.verifyUnchanged(snapshot)
        let nativeTextStatus: String
        if result.pageCount == 0 {
            nativeTextStatus = "empty_document"
        } else if result.requiresOCR {
            nativeTextStatus = "image_only"
        } else {
            nativeTextStatus = "present"
        }
        let payload: JSONValue = .object([
            "schema_version": .number(1),
            "source_sha256": .string(snapshot.identity.sha256.lowercased()),
            "source_byte_count": .number(Double(snapshot.identity.byteCount)),
            "page_count": .number(Double(result.pageCount)),
            "native_text_status": .string(nativeTextStatus),
            "requires_ocr": .bool(result.requiresOCR),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentToolError(.backendFailed, "PDF inspection result could not be encoded")
        }
        return ToolObservation(text: text)
    }
}

public struct ReadPDFTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.read"
    public static let descriptor = ToolDescriptor(
        name: "read_pdf",
        description: "Read only the text already embedded in selected pages of a workspace PDF. This never edits the PDF and never performs OCR. An image-only PDF returns the typed ocr_required error so ocr_pdf can be requested explicitly.",
        sideEffect: .readOnly,
        parameters: ReadPDFArguments.schema)

    public func validateArguments(_ args: ToolArgs) throws {
        _ = try ReadPDFArguments.decodeValidated(args)
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? ReadPDFArguments.decodeValidated(args)).map { [$0.path] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "document.read.pdf",
            resources: touchedPaths(args).map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readOnly)
            },
            metadata: ["operation": .string("read_native_pdf_text")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try ReadPDFArguments.decodeValidated(args)
        let snapshot = try DocumentInputFile.freeze(
            path: value.path,
            expectedFormat: .pdf,
            workspace: context.workspaceRoot)
        let pages = try DocumentPageSelection.parse(value.pages, maximumCount: 10_000)
        let result: PDFNativeTextReadResult
        do {
            result = try PDFNativeDocumentService.readNativeText(
                from: snapshot.url,
                pages: pages,
                maximumCharacters: value.maxCharacters ?? 200_000)
        } catch let error as PDFNativeDocumentServiceError {
            throw mapPDFReadError(error, operation: "read")
        }
        try DocumentInputFile.verifyUnchanged(snapshot)
        guard !result.requiresOCR else {
            throw DocumentToolError(
                .ocrRequired,
                "the selected PDF pages have no extractable native text; request ocr_pdf explicitly")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedResult = try encoder.encode(result)
        guard case .object(var resultObject) = try JSONDecoder().decode(
            JSONValue.self,
            from: encodedResult) else {
            throw DocumentToolError(.backendFailed, "PDF result could not be encoded")
        }
        resultObject["source_sha256"] = .string(snapshot.identity.sha256.lowercased())
        resultObject["source_byte_count"] = .number(Double(snapshot.identity.byteCount))
        let data = try encoder.encode(JSONValue.object(resultObject))
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentToolError(.backendFailed, "PDF result could not be encoded")
        }
        return ToolObservation(text: text, truncated: result.truncated)
    }
}

private func mapPDFReadError(
    _ error: PDFNativeDocumentServiceError,
    operation: String
) -> DocumentToolError {
    switch error {
    case .unavailable:
        return DocumentToolError(.backendMissing, "PDFKit native \(operation) is unavailable")
    case .inputChangedWhileReading:
        return DocumentToolError(.outputConflict, "PDF changed while it was being read")
    case .lockedPDF:
        return DocumentToolError(.unsupportedFeature, "password-protected PDF input is unsupported")
    default:
        return DocumentToolError(.validationFailed, "PDF input or page selection is invalid")
    }
}

// MARK: - compile_latex

public struct CompileLaTeXTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "document.compile"
    public static let descriptor = ToolDescriptor(
        name: "compile_latex",
        description: "Compile one workspace LaTeX .tex file to PDF with exactly Tectonic. The engine and flags are fixed; no compiler discovery or fallback is performed.",
        sideEffect: .exec,
        parameters: Schema.object([
            "inputPath": Schema.nonEmptyString,
            "outputDir": Schema.nonEmptyString,
        ], required: ["inputPath"])
    )

    struct Args: Decodable {
        let inputPath: String
        let outputDir: String?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let a = try? args.decode(Args.self) else { return [] }
        return [a.inputPath, a.outputDir].compactMap { $0 }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        guard let a = try? args.decode(Args.self) else {
            return PermissionIntent.derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        let outputDirectory = a.outputDir?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? (a.inputPath as NSString).deletingLastPathComponent
        return PermissionIntent(
            action: "document.compile.latex",
            resources: [
                PermissionResource(
                    kind: .workspacePath,
                    value: a.inputPath,
                    access: .readOnly),
                PermissionResource(
                    kind: .workspacePath,
                    value: outputDirectory.isEmpty ? "." : outputDirectory,
                    access: .readWrite),
            ],
            metadata: ["operation": .string("compile_latex")],
            dataEffects: [.read, .execute, .mutate],
            risks: [.processExecution, .workspaceMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let input = try DocumentInputFile.freezeReadOnly(
            path: a.inputPath,
            maximumBytes: 128 * 1_024 * 1_024,
            workspace: context.workspaceRoot)
        let inputURL = input.url
        guard inputURL.pathExtension.lowercased() == "tex" else {
            throw IntatisError.decoding("compile_latex inputPath must point to a .tex file")
        }
        let defaultOutputDirectory = PathConfinement.relativePath(
            of: inputURL.deletingLastPathComponent(),
            root: context.workspaceRoot)
        let outputDirectoryPath = a.outputDir?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? defaultOutputDirectory
        let outputDirectoryURL = try PathConfinement.resolve(
            outputDirectoryPath,
            within: context.workspaceRoot)
        let existingOutputDirectory = try PathConfinement.canonicalExistingDirectory(
            outputDirectoryURL)
        guard PathConfinement.isWithin(
            existingOutputDirectory.path,
            root: context.workspaceRoot) else {
            throw DocumentToolError(.validationFailed, "LaTeX output directory escapes the workspace")
        }
        let outputPDF = existingOutputDirectory.appendingPathComponent(
            inputURL.deletingPathExtension().lastPathComponent + ".pdf",
            isDirectory: false)
        let changed = PathConfinement.relativePath(of: outputPDF, root: context.workspaceRoot)
        let request = DocumentStagedFileRequest(
            sourcePath: a.inputPath,
            expectedSourceSHA256: nil,
            destinationPath: changed,
            replaceExisting: false,
            expectedDestinationSHA256: nil,
            fileExtension: "pdf",
            maximumBytes: 1_024 * 1_024 * 1_024,
            readOnlyInputSnapshots: [input])
        let accumulator = DocumentExecutionAccumulator()
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedPDF in
                let versions = try await TectonicDocumentBackend.compile(
                    actualInput: inputURL,
                    reviewedInputPath: a.inputPath,
                    stagedPDF: stagedPDF,
                    reviewedOutputPath: changed,
                    in: context)
                await accumulator.record(versions: versions)
            },
            validate: { pdf in
                try DocumentToolSupport.validatePDFFile(pdf)
            })
        let execution = await accumulator.snapshot()
        return try DocumentToolSupport.observation(
            operation: "compile_latex",
            format: .pdf,
            engineVersions: execution.versions,
            warnings: execution.warnings,
            receipt: receipt,
            changedFiles: [changed])
    }
}

private enum TectonicDocumentBackend {
    static let expectedVersion = "0.15.0"

    static func compile(
        actualInput: URL,
        reviewedInputPath: String,
        stagedPDF: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        let version = try await requireVersion(in: context)
        let stageRoot = stagedPDF.deletingLastPathComponent()
        let outputDirectory = stageRoot.appendingPathComponent(
            "tectonic-output",
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw DocumentToolError(.backendFailed, "Tectonic output staging could not be created")
        }
        let invocation = DocumentBackendInvocation(
            executable: .tectonic,
            arguments: [
                "--untrusted",
                "--only-cached",
                "--outdir", outputDirectory.path,
                actualInput.path,
            ],
            readableWorkspacePaths: [reviewedInputPath],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(
                .backendFailed,
                "Tectonic compilation failed with the fixed offline contract")
        }
        let expectedPDF = outputDirectory.appendingPathComponent(
            actualInput.deletingPathExtension().lastPathComponent + ".pdf",
            isDirectory: false)
        let values = try? expectedPDF.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              (values?.fileSize ?? 0) > 0,
              FileManager.default.fileExists(atPath: stagedPDF.path) == false else {
            throw DocumentToolError(.validationFailed, "Tectonic did not produce its exact PDF output")
        }
        do {
            try FileManager.default.moveItem(at: expectedPDF, to: stagedPDF)
        } catch {
            throw DocumentToolError(.backendFailed, "Tectonic PDF output could not be staged")
        }
        return ["tectonic": version]
    }

    private static func requireVersion(in context: ToolContext) async throws -> String {
        let invocation = DocumentBackendInvocation(
            executable: .tectonic,
            arguments: ["--version"],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let result = try await run(invocation, in: context)
        let firstLine = result.stdout.split(whereSeparator: { $0.isNewline }).first.map(String.init)
            ?? result.stderr.split(whereSeparator: { $0.isNewline }).first.map(String.init)
            ?? ""
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendMissing, "Tectonic is unavailable")
        }
        guard firstLine == "tectonic \(expectedVersion)" else {
            throw DocumentToolError(
                .backendVersionMismatch,
                "Tectonic version does not match the fixed manifest")
        }
        return expectedVersion
    }

    private static func run(
        _ invocation: DocumentBackendInvocation,
        in context: ToolContext
    ) async throws -> ShellResult {
        do {
            return try await context.documentBackend.run(invocation, cwd: context.workspaceRoot)
        } catch let error as DocumentToolError {
            throw error
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "Tectonic is unavailable at its fixed path")
            }
            throw DocumentToolError(.backendFailed, "Tectonic could not be started")
        } catch {
            throw DocumentToolError(.backendFailed, "Tectonic could not be started")
        }
    }
}

// MARK: - generate_image

public struct GenerateImageTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "generate_image",
        description: "Generate image files from a prompt using the configured image provider or injected local image model backend.",
        sideEffect: .write,
        parameters: Schema.object([
            "prompt": Schema.nonEmptyString,
            "outputPath": Schema.nonEmptyString,
            "size": Schema.nonEmptyString,
            "count": Schema.boundedInteger(minimum: 1, maximum: 4),
        ], required: ["prompt", "outputPath"])
    )

    struct Args: Decodable {
        let prompt: String
        let outputPath: String
        let size: String?
        let count: Int?
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).outputPath).map { [$0] } ?? []
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try PathConfinement.resolve(a.outputPath, within: context.workspaceRoot)
        guard let generator = context.imageGenerator else {
            throw IntatisError.config("generate_image is not configured; attach an image provider or local image backend before using this tool")
        }
        return try await generator.generateImage(
            prompt: a.prompt,
            size: a.size?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "1024x1024",
            count: a.count ?? 1,
            outputPath: a.outputPath,
            workspaceRoot: context.workspaceRoot)
    }
}

// MARK: - edit_image

public struct EditImageTool: Tool {
    public init() {}

    static let maximumInputMiB = 50
    static let maximumInputBytes = maximumInputMiB * 1_024 * 1_024
    private static let supportedImageMIMEs: [String: String] = [
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
    ]

    public static let descriptor = ToolDescriptor(
        name: "edit_image",
        description: "Edit one existing PNG, JPEG, or WebP image in the workspace using the configured image provider. Writes a new PNG file; imagePath and outputPath must be different.",
        sideEffect: .write,
        parameters: Schema.object([
            "imagePath": Schema.nonEmptyString,
            "prompt": Schema.boundedString(minLength: 1, maxLength: 32_000),
            "outputPath": Schema.nonEmptyString,
        ], required: ["imagePath", "prompt", "outputPath"])
    )

    struct Args: Decodable {
        let imagePath: String
        let prompt: String
        let outputPath: String
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? args.decode(Args.self) else { return [] }
        return [value.imagePath, value.outputPath]
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        var resources: [PermissionResource] = []
        if let imagePath = value?.imagePath {
            resources.append(PermissionResource(
                kind: .workspacePath,
                value: imagePath,
                access: .readOnly))
        }
        if let outputPath = value?.outputPath {
            resources.append(PermissionResource(
                kind: .workspacePath,
                value: outputPath,
                access: .readWrite))
        }
        return PermissionIntent(
            action: "media.edit",
            resources: resources,
            metadata: [
                "operation": .string("edit_image"),
                "promptCharacterCount": .number(Double(value?.prompt.count ?? 0)),
            ],
            dataEffects: [.read, .mutate, .network],
            risks: [.workspaceMutation, .networkAccess, .modelCost],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        let prompt = value.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_empty_prompt",
                message: "edit_image prompt must contain non-whitespace text")
        }

        let inputURL: URL
        let outputURL: URL
        do {
            inputURL = try PathConfinement.resolve(value.imagePath, within: context.workspaceRoot)
            outputURL = try PathConfinement.resolve(value.outputPath, within: context.workspaceRoot)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_invalid_path",
                message: "edit_image input and output must resolve inside the workspace")
        }
        guard inputURL.standardizedFileURL.path != outputURL.standardizedFileURL.path else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_same_path",
                message: "edit_image outputPath must be different from imagePath")
        }
        guard outputURL.pathExtension.lowercased() == "png" else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_output_must_be_png",
                message: "edit_image outputPath must use the .png extension")
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try inputURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_input_unavailable",
                message: "edit_image could not inspect the input image")
        }
        guard resourceValues.isRegularFile == true else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_not_regular_file",
                message: "edit_image imagePath must be a regular file")
        }
        if let fileSize = resourceValues.fileSize,
           fileSize > Self.maximumInputBytes {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_input_too_large",
                message: "edit_image input exceeds the \(Self.maximumInputMiB) MiB safety limit")
        }

        let fileExtension = inputURL.pathExtension.lowercased()
        guard let mime = Self.supportedImageMIMEs[fileExtension] else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_unsupported_format",
                message: "edit_image supports PNG, JPEG, and WebP input images")
        }

        let image: Data
        do {
            image = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        } catch {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_input_unreadable",
                message: "edit_image could not read the input image")
        }
        guard !image.isEmpty, image.count <= Self.maximumInputBytes else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: image.isEmpty ? "edit_image_input_empty" : "edit_image_input_too_large",
                message: image.isEmpty
                    ? "edit_image input image is empty"
                    : "edit_image input exceeds the \(Self.maximumInputMiB) MiB safety limit")
        }
        guard Self.matchesImageSignature(image, fileExtension: fileExtension) else {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: "edit_image_invalid_image",
                message: "edit_image input bytes do not match the file extension")
        }
        guard let generator = context.imageGenerator else {
            throw IntatisError.config("edit_image is not configured; attach an image provider or local image backend before using this tool")
        }

        let normalizedExtension = fileExtension == "jpeg" ? "jpg" : fileExtension
        return try await generator.editImage(
            image: image,
            filename: "input.\(normalizedExtension)",
            mime: mime,
            prompt: prompt,
            outputPath: value.outputPath,
            workspaceRoot: context.workspaceRoot)
    }

    private static func matchesImageSignature(_ data: Data,
                                              fileExtension: String) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        switch fileExtension {
        case "png":
            return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "jpg", "jpeg":
            return bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case "webp":
            return bytes.count >= 12
                && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
                && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
        default:
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
