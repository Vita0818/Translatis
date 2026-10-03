import Foundation
import IntatisCore
import IntatisProtocol

/// Model-visible document registrations. Every descriptor fixes one file
/// format and one mature-library operation; the shared Swift executor only
/// freezes reviewed inputs, forwards that exact call, and atomically commits
/// the resulting file.
public enum ExactDocumentToolCatalog {
    public static func exportRegistrations(
        grantingCapabilities: Set<ToolCapability> = []
    ) -> [ToolRegistration] {
        ExactPDFExportSpec.all.map { spec in
            let tool = ExactPDFExportTool(spec: spec)
            return ToolRegistration(
                descriptor: spec.descriptor,
                tool: tool,
                canonicalPermission: "document.export.pdf",
                grantingCapabilities: grantingCapabilities,
                argumentValidator: { args in
                    _ = try ExactPDFExportArguments.decodeValidated(
                        args,
                        format: spec.format)
                })
        }
    }

    public static func writeRegistrations(
        grantingCapabilities: Set<ToolCapability> = []
    ) -> [ToolRegistration] {
        ExactDocumentWriteSpec.all.map { spec in
            let tool = ExactDocumentWriteTool(spec: spec)
            return ToolRegistration(
                descriptor: spec.descriptor,
                tool: tool,
                canonicalPermission: "document.write",
                grantingCapabilities: grantingCapabilities,
                argumentValidator: { args in
                    _ = try spec.validate(args)
                })
        }
    }

    /// Returns one fixed export registration. The caller selects from this
    /// host-owned table; no model argument can choose a format or backend.
    public static func exportRegistration(
        named name: String,
        grantingCapabilities: Set<ToolCapability> = []
    ) -> ToolRegistration? {
        exportRegistrations(grantingCapabilities: grantingCapabilities)
            .first { $0.descriptor.name == name }
    }

    /// Returns one fixed write registration. The selected registration still
    /// invokes exactly one dependency API and produces one ToolResult.
    public static func writeRegistration(
        named name: String,
        grantingCapabilities: Set<ToolCapability> = []
    ) -> ToolRegistration? {
        writeRegistrations(grantingCapabilities: grantingCapabilities)
            .first { $0.descriptor.name == name }
    }
}

// MARK: - Exact PDF export registrations

private struct ExactPDFExportSpec: Sendable {
    let name: String
    let format: DocumentFormat
    let externalOperation: String

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: "Export one \(format.rawValue.uppercased()) workspace file to one PDF using exactly \(externalOperation). The host only freezes paths, checks the output file signature, and commits it atomically; no format or backend selection is accepted.",
            sideEffect: .exec,
            parameters: ExactPDFExportArguments.schema(format: format))
    }

    static let all: [Self] = [
        .init(
            name: "docx_export_pdf",
            format: .docx,
            externalOperation: "LibreOffice writer_pdf_Export"),
        .init(
            name: "pptx_export_pdf",
            format: .pptx,
            externalOperation: "LibreOffice impress_pdf_Export"),
        .init(
            name: "xlsx_export_pdf",
            format: .xlsx,
            externalOperation: "LibreOffice calc_pdf_Export"),
        .init(
            name: "html_export_pdf",
            format: .html,
            externalOperation: "WebKit WKWebView.createPDF"),
    ]
}

private struct ExactPDFExportTool: Tool {
    let spec: ExactPDFExportSpec

    static let descriptor = ToolDescriptor(
        name: "__exact_document_export_transport",
        description: "Internal exact document export transport.",
        sideEffect: .exec,
        parameters: DocumentContractSchema.object(properties: [:], required: []))

    func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let value = try? ExactPDFExportArguments.decodeValidated(
            args,
            format: spec.format) else { return [] }
        return [value.inputPath] + (value.localAssetPaths ?? []) + [value.outputPath]
    }

    func permissionIntent(
        _ args: ToolArgs,
        descriptor: ToolDescriptor,
        workspaceRoot: URL
    ) -> PermissionIntent {
        guard let value = try? ExactPDFExportArguments.decodeValidated(
            args,
            format: spec.format) else {
            return PermissionIntent.derived(
                toolName: descriptor.name,
                sideEffect: descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        return DocumentToolSupport.writeIntent(
            action: "document.export.\(spec.format.rawValue).pdf",
            readPaths: [value.inputPath] + (value.localAssetPaths ?? []),
            writePath: value.outputPath,
            operation: spec.name,
            format: spec.format)
    }

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try ExactPDFExportArguments.decodeValidated(args, format: spec.format)
        let snapshot = try DocumentInputFile.freeze(
            path: value.inputPath,
            expectedFormat: spec.format,
            expectedSHA256: value.expectedSourceSHA256,
            workspace: context.workspaceRoot)
        let assets = try DocumentToolSupport.freezeAuxiliaryInputs(
            value.localAssetPaths ?? [],
            workspace: context.workspaceRoot)
        let request = DocumentStagedFileRequest(
            sourcePath: value.inputPath,
            expectedSourceSHA256: value.expectedSourceSHA256,
            destinationPath: value.outputPath,
            replaceExisting: value.replaceExisting ?? false,
            expectedDestinationSHA256: value.expectedOutputSHA256,
            fileExtension: "pdf",
            maximumBytes: 1_024 * 1_024 * 1_024,
            readOnlyInputSnapshots: assets.snapshots)
        let accumulator = DocumentExecutionAccumulator()
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedPDF in
                let exporterVersions: [String: String]
                switch spec.format {
                case .docx:
                    exporterVersions = try await LibreOfficeDocumentBackend.exportDOCXPDF(
                        actualInput: snapshot.url,
                        reviewedInputPath: value.inputPath,
                        stagedPDF: stagedPDF,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                case .pptx:
                    exporterVersions = try await LibreOfficeDocumentBackend.exportPPTXPDF(
                        actualInput: snapshot.url,
                        reviewedInputPath: value.inputPath,
                        stagedPDF: stagedPDF,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                case .xlsx:
                    exporterVersions = try await LibreOfficeDocumentBackend.exportXLSXPDF(
                        actualInput: snapshot.url,
                        reviewedInputPath: value.inputPath,
                        stagedPDF: stagedPDF,
                        reviewedOutputPath: value.outputPath,
                        in: context)
                case .html:
                    exporterVersions = try await DocumentToolSupport.stageAndRenderHTML(
                        input: snapshot.url,
                        allowedHTMLAssets: assets.urlsByReviewedPath,
                        stagedPDF: stagedPDF)
                case .pdf, .epub:
                    throw DocumentToolError(.unsupportedOperation, "format has no PDF export registration")
                }
                await accumulator.record(versions: exporterVersions)
            },
            validate: { pdf in
                try DocumentToolSupport.validatePDFFile(pdf)
            })
        let execution = await accumulator.snapshot()
        return try DocumentToolSupport.observation(
            operation: spec.name,
            format: spec.format,
            engineVersions: execution.versions,
            warnings: execution.warnings,
            receipt: receipt,
            changedFiles: [value.outputPath])
    }
}

// MARK: - Exact document write registrations

private enum ExactDocumentWriteMode: Sendable {
    case create
    case mutate
}

private enum ExactDocumentFieldRule: Sendable {
    case string(minimum: Int, maximum: Int)
    case stringEnum([String])
    case integer(minimum: Int, maximum: Int)
    case boolean
    case path
    case a1Cell
    case scalar
    case scalarArray(maximum: Int)

    var schema: JSONValue {
        switch self {
        case .string(let minimum, let maximum):
            return DocumentContractSchema.string(
                minimumLength: minimum,
                maximumLength: maximum)
        case .stringEnum(let values):
            return DocumentContractSchema.stringEnum(values)
        case .integer(let minimum, let maximum):
            return DocumentContractSchema.integer(minimum: minimum, maximum: maximum)
        case .boolean:
            return DocumentContractSchema.boolean
        case .path:
            return DocumentContractSchema.path
        case .a1Cell:
            return DocumentContractSchema.string(
                minimumLength: 2,
                maximumLength: 16,
                pattern: #"^\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}$"#)
        case .scalar:
            return Self.scalarSchema
        case .scalarArray(let maximum):
            return DocumentContractSchema.array(
                items: Self.scalarSchema,
                minimumItems: 1,
                maximumItems: maximum)
        }
    }

    func validate(_ value: JSONValue, field: String) throws {
        let valid: Bool
        switch (self, value) {
        case (.string(let minimum, let maximum), .string(let string)):
            valid = (minimum...maximum).contains(string.count) && !string.contains("\0")
        case (.stringEnum(let values), .string(let string)):
            valid = values.contains(string)
        case (.integer(let minimum, let maximum), .number(let number)):
            valid = number.isFinite
                && number.rounded(.towardZero) == number
                && number >= Double(minimum)
                && number <= Double(maximum)
        case (.boolean, .bool):
            valid = true
        case (.path, .string(let path)):
            try DocumentContractValidation.validatePlainPath(path, field: field)
            return
        case (.a1Cell, .string(let cell)):
            try DocumentContractValidation.validatePattern(
                cell,
                pattern: #"^\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}$"#,
                field: field)
            return
        case (.scalar, let scalar):
            valid = Self.isScalar(scalar)
        case (.scalarArray(let maximum), .array(let values)):
            valid = (1...maximum).contains(values.count) && values.allSatisfy(Self.isScalar)
        default:
            valid = false
        }
        guard valid else {
            throw DocumentToolError(.validationFailed, "\(field) does not match the external operation")
        }
    }

    private static let scalarSchema: JSONValue = .object([
        "oneOf": .array([
            DocumentContractSchema.string(maximumLength: 65_536),
            .object([
                "type": .string("number"),
                "minimum": .number(-1_000_000_000_000),
                "maximum": .number(1_000_000_000_000),
            ]),
            DocumentContractSchema.boolean,
            .object(["type": .string("null")]),
        ]),
    ])

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool:
            return true
        case .number(let number):
            return number.isFinite && abs(number) <= 1_000_000_000_000
        case .string(let string):
            return string.count <= 65_536 && !string.contains("\0")
        case .array, .object:
            return false
        }
    }
}

private struct ExactDocumentWriteSpec: Sendable {
    let name: String
    let format: DocumentFormat
    let mode: ExactDocumentWriteMode
    let externalOperation: String
    let fields: [String: ExactDocumentFieldRule]
    let requiredFields: Set<String>
    let assetField: String?

    init(
        _ name: String,
        format: DocumentFormat,
        mode: ExactDocumentWriteMode,
        externalOperation: String,
        fields: [String: ExactDocumentFieldRule] = [:],
        required: Set<String> = [],
        assetField: String? = nil
    ) {
        self.name = name
        self.format = format
        self.mode = mode
        self.externalOperation = externalOperation
        self.fields = fields
        requiredFields = required
        self.assetField = assetField
    }

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: "Apply exactly \(externalOperation) to one \(format.rawValue.uppercased()) document. The host forwards only this operation's arguments, then saves and atomically commits the result; there is no operations array, format selection, preview pipeline, or fallback.",
            sideEffect: .exec,
            parameters: schema)
    }

    private var schema: JSONValue {
        var properties: [String: JSONValue] = [
            "output_path": DocumentContractSchema.path,
            "replace_existing": DocumentContractSchema.boolean,
            "expected_output_sha256": DocumentContractSchema.sha256,
        ]
        var required: Set<String> = ["output_path"]
        if mode == .mutate {
            properties["input_path"] = DocumentContractSchema.path
            properties["expected_source_sha256"] = DocumentContractSchema.sha256
            required.formUnion(["input_path", "expected_source_sha256"])
        }
        for (name, rule) in fields { properties[name] = rule.schema }
        required.formUnion(requiredFields)
        return DocumentContractSchema.object(
            properties: properties,
            required: required.sorted())
    }

    func validate(_ args: ToolArgs) throws -> [String: JSONValue] {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        var allowed = Set(fields.keys)
        allowed.formUnion(["output_path", "replace_existing", "expected_output_sha256"])
        var required = requiredFields
        required.insert("output_path")
        if mode == .mutate {
            allowed.formUnion(["input_path", "expected_source_sha256"])
            required.formUnion(["input_path", "expected_source_sha256"])
        }
        try DocumentContractValidation.requireKeys(object, allowed: allowed, required: required)
        guard case .string(let outputPath)? = object["output_path"] else {
            throw DocumentToolError(.validationFailed, "output_path is required")
        }
        try DocumentContractValidation.validatePath(outputPath, extension: format, field: "output_path")
        let replaceExisting: Bool
        switch object["replace_existing"] {
        case .bool(let value)?: replaceExisting = value
        case nil: replaceExisting = false
        default: throw DocumentToolError(.validationFailed, "replace_existing must be a boolean")
        }
        let expectedOutputSHA256: String?
        switch object["expected_output_sha256"] {
        case .string(let value)?: expectedOutputSHA256 = value
        case nil: expectedOutputSHA256 = nil
        default: throw DocumentToolError(.validationFailed, "expected_output_sha256 must be a digest")
        }
        try DocumentContractValidation.validateReplacement(
            replaceExisting: replaceExisting,
            expectedOutputSHA256: expectedOutputSHA256)

        if mode == .mutate {
            guard case .string(let inputPath)? = object["input_path"],
                  case .string(let sourceSHA256)? = object["expected_source_sha256"] else {
                throw DocumentToolError(.validationFailed, "mutation requires a source and its digest")
            }
            try DocumentContractValidation.validatePath(inputPath, extension: format, field: "input_path")
            try DocumentContractValidation.validateSHA256(sourceSHA256, field: "expected_source_sha256")
            if (inputPath as NSString).standardizingPath == (outputPath as NSString).standardizingPath {
                guard replaceExisting,
                      expectedOutputSHA256?.lowercased() == sourceSHA256.lowercased() else {
                    throw DocumentToolError(
                        .validationFailed,
                        "in-place mutation requires replace_existing and the same source/output digest")
                }
            }
        }
        for (field, rule) in fields {
            if let value = object[field] { try rule.validate(value, field: field) }
        }
        try validateOperationSpecificValues(object)
        return object
    }

    private func validateOperationSpecificValues(_ object: [String: JSONValue]) throws {
        if name == "xlsx_set_sheet_title",
           case .string(let title)? = object["title"] {
            guard !title.hasPrefix("'"),
                  !title.hasSuffix("'"),
                  title.range(of: #"[\\/*?:\[\]]"#, options: .regularExpression) == nil else {
                throw DocumentToolError(.validationFailed, "title is not a valid Excel worksheet title")
            }
        }
        if name == "xlsx_set_cell_value",
           case .string(let value)? = object["value"],
           value.hasPrefix("=") {
            throw DocumentToolError(.unsupportedFeature, "formula creation is outside this exact value setter")
        }
        if name == "xlsx_append_row",
           case .array(let values)? = object["values"],
           values.contains(where: {
               guard case .string(let value) = $0 else { return false }
               return value.hasPrefix("=")
           }) {
            throw DocumentToolError(.unsupportedFeature, "formula creation is outside Worksheet.append")
        }
    }

    static let all: [Self] = docx + pptx + xlsx

    private static let index = ExactDocumentFieldRule.integer(minimum: 0, maximum: 1_000_000)
    private static let emu = ExactDocumentFieldRule.integer(minimum: 0, maximum: 2_147_483_647)
    private static let text = ExactDocumentFieldRule.string(minimum: 0, maximum: 1_000_000)
    private static let style = ExactDocumentFieldRule.string(minimum: 1, maximum: 255)

    private static let docx: [Self] = [
        .init("docx_create_document", format: .docx, mode: .create, externalOperation: "python-docx Document()"),
        .init("docx_add_paragraph", format: .docx, mode: .mutate, externalOperation: "Document.add_paragraph", fields: ["text": text, "style": style]),
        .init("docx_set_paragraph_text", format: .docx, mode: .mutate, externalOperation: "Paragraph.text", fields: ["paragraph_index": index, "text": text], required: ["paragraph_index", "text"]),
        .init("docx_add_run", format: .docx, mode: .mutate, externalOperation: "Paragraph.add_run", fields: ["paragraph_index": index, "text": text, "style": style], required: ["paragraph_index"]),
        .init("docx_set_run_bold", format: .docx, mode: .mutate, externalOperation: "Run.bold", fields: ["paragraph_index": index, "run_index": index, "value": .boolean], required: ["paragraph_index", "run_index", "value"]),
        .init("docx_set_run_italic", format: .docx, mode: .mutate, externalOperation: "Run.italic", fields: ["paragraph_index": index, "run_index": index, "value": .boolean], required: ["paragraph_index", "run_index", "value"]),
        .init("docx_set_run_underline", format: .docx, mode: .mutate, externalOperation: "Run.underline", fields: ["paragraph_index": index, "run_index": index, "value": .boolean], required: ["paragraph_index", "run_index", "value"]),
        .init("docx_add_table", format: .docx, mode: .mutate, externalOperation: "Document.add_table", fields: ["rows": .integer(minimum: 1, maximum: 100_000), "cols": .integer(minimum: 1, maximum: 16_384), "style": style], required: ["rows", "cols"]),
        .init("docx_set_table_cell_text", format: .docx, mode: .mutate, externalOperation: "_Cell.text", fields: ["table_index": index, "row_index": index, "column_index": .integer(minimum: 0, maximum: 16_383), "text": text], required: ["table_index", "row_index", "column_index", "text"]),
        .init("docx_add_picture", format: .docx, mode: .mutate, externalOperation: "Document.add_picture", fields: ["path": .path, "width": emu, "height": emu], required: ["path"], assetField: "path"),
        .init("docx_set_header_paragraph_text", format: .docx, mode: .mutate, externalOperation: "Header Paragraph.text", fields: ["section_index": index, "paragraph_index": index, "text": text], required: ["section_index", "paragraph_index", "text"]),
        .init("docx_set_footer_paragraph_text", format: .docx, mode: .mutate, externalOperation: "Footer Paragraph.text", fields: ["section_index": index, "paragraph_index": index, "text": text], required: ["section_index", "paragraph_index", "text"]),
        .init("docx_set_section_orientation", format: .docx, mode: .mutate, externalOperation: "Section.orientation", fields: ["section_index": index, "orientation": .stringEnum(["portrait", "landscape"])], required: ["section_index", "orientation"]),
        .init("docx_set_section_top_margin", format: .docx, mode: .mutate, externalOperation: "Section.top_margin", fields: ["section_index": index, "value": emu], required: ["section_index", "value"]),
        .init("docx_set_section_right_margin", format: .docx, mode: .mutate, externalOperation: "Section.right_margin", fields: ["section_index": index, "value": emu], required: ["section_index", "value"]),
        .init("docx_set_section_bottom_margin", format: .docx, mode: .mutate, externalOperation: "Section.bottom_margin", fields: ["section_index": index, "value": emu], required: ["section_index", "value"]),
        .init("docx_set_section_left_margin", format: .docx, mode: .mutate, externalOperation: "Section.left_margin", fields: ["section_index": index, "value": emu], required: ["section_index", "value"]),
    ]

    private static let pptx: [Self] = [
        .init("pptx_create_presentation", format: .pptx, mode: .create, externalOperation: "python-pptx Presentation()"),
        .init("pptx_add_slide", format: .pptx, mode: .mutate, externalOperation: "Slides.add_slide", fields: ["slide_layout_index": index], required: ["slide_layout_index"]),
        .init("pptx_set_shape_text", format: .pptx, mode: .mutate, externalOperation: "Shape.text", fields: ["slide_index": index, "shape_index": index, "text": text], required: ["slide_index", "shape_index", "text"]),
        .init("pptx_add_shape", format: .pptx, mode: .mutate, externalOperation: "SlideShapes.add_shape", fields: ["slide_index": index, "shape_type": .integer(minimum: 1, maximum: 1_000), "left": emu, "top": emu, "width": emu, "height": emu], required: ["slide_index", "shape_type", "left", "top", "width", "height"]),
        .init("pptx_add_picture", format: .pptx, mode: .mutate, externalOperation: "SlideShapes.add_picture", fields: ["slide_index": index, "path": .path, "left": emu, "top": emu, "width": emu, "height": emu], required: ["slide_index", "path", "left", "top"], assetField: "path"),
        .init("pptx_add_table", format: .pptx, mode: .mutate, externalOperation: "SlideShapes.add_table", fields: ["slide_index": index, "rows": .integer(minimum: 1, maximum: 100_000), "cols": .integer(minimum: 1, maximum: 16_384), "left": emu, "top": emu, "width": emu, "height": emu], required: ["slide_index", "rows", "cols", "left", "top", "width", "height"]),
        .init("pptx_set_table_cell_text", format: .pptx, mode: .mutate, externalOperation: "TableCell.text", fields: ["slide_index": index, "shape_index": index, "row_index": index, "column_index": .integer(minimum: 0, maximum: 16_383), "text": text], required: ["slide_index", "shape_index", "row_index", "column_index", "text"]),
    ]

    private static let xlsx: [Self] = [
        .init("xlsx_create_workbook", format: .xlsx, mode: .create, externalOperation: "openpyxl Workbook()"),
        .init("xlsx_create_sheet", format: .xlsx, mode: .mutate, externalOperation: "Workbook.create_sheet", fields: ["title": .string(minimum: 1, maximum: 31), "index": index]),
        .init("xlsx_set_sheet_title", format: .xlsx, mode: .mutate, externalOperation: "Worksheet.title", fields: ["sheet_index": index, "title": .string(minimum: 1, maximum: 31)], required: ["sheet_index", "title"]),
        .init("xlsx_set_cell_value", format: .xlsx, mode: .mutate, externalOperation: "Cell.value", fields: ["sheet": .string(minimum: 1, maximum: 31), "cell": .a1Cell, "value": .scalar], required: ["sheet", "cell", "value"]),
        .init("xlsx_append_row", format: .xlsx, mode: .mutate, externalOperation: "Worksheet.append", fields: ["sheet": .string(minimum: 1, maximum: 31), "values": .scalarArray(maximum: 16_384)], required: ["sheet", "values"]),
    ]
}

private struct ExactDocumentWriteTool: Tool {
    let spec: ExactDocumentWriteSpec

    static let descriptor = ToolDescriptor(
        name: "__exact_document_write_transport",
        description: "Internal exact document write transport.",
        sideEffect: .exec,
        parameters: DocumentContractSchema.object(properties: [:], required: []))

    func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let object = try? spec.validate(args) else { return [] }
        var paths: [String] = []
        for field in ["input_path", spec.assetField, "output_path"].compactMap({ $0 }) {
            if case .string(let path)? = object[field] { paths.append(path) }
        }
        return paths
    }

    func permissionIntent(
        _ args: ToolArgs,
        descriptor: ToolDescriptor,
        workspaceRoot: URL
    ) -> PermissionIntent {
        guard let object = try? spec.validate(args),
              case .string(let outputPath)? = object["output_path"] else {
            return PermissionIntent.derived(
                toolName: descriptor.name,
                sideEffect: descriptor.sideEffect,
                touchedPaths: touchedPaths(args),
                risksNetwork: false)
        }
        var readPaths: [String] = []
        for field in ["input_path", spec.assetField].compactMap({ $0 }) {
            if case .string(let path)? = object[field] { readPaths.append(path) }
        }
        return DocumentToolSupport.writeIntent(
            action: "document.write."
                + spec.name.replacingOccurrences(of: "_", with: "."),
            readPaths: readPaths,
            writePath: outputPath,
            operation: spec.name,
            format: spec.format)
    }

    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let object = try spec.validate(args)
        guard case .string(let outputPath)? = object["output_path"] else {
            throw DocumentToolError(.validationFailed, "output_path is required")
        }
        let inputPath: String?
        let expectedSourceSHA256: String?
        if spec.mode == .mutate {
            guard case .string(let path)? = object["input_path"],
                  case .string(let digest)? = object["expected_source_sha256"] else {
                throw DocumentToolError(.validationFailed, "mutation source is missing")
            }
            inputPath = path
            expectedSourceSHA256 = digest
        } else {
            inputPath = nil
            expectedSourceSHA256 = nil
        }
        let source = try inputPath.map {
            try DocumentInputFile.freeze(
                path: $0,
                expectedFormat: spec.format,
                expectedSHA256: expectedSourceSHA256,
                workspace: context.workspaceRoot)
        }
        let assetPath: String? = spec.assetField.flatMap { field in
            guard case .string(let path)? = object[field] else { return nil }
            return path
        }
        let asset = try assetPath.map {
            try DocumentInputFile.freezeReadOnly(
                path: $0,
                maximumBytes: 128 * 1_024 * 1_024,
                workspace: context.workspaceRoot)
        }
        let replaceExisting: Bool
        if case .bool(let value)? = object["replace_existing"] { replaceExisting = value }
        else { replaceExisting = false }
        let expectedOutputSHA256: String?
        if case .string(let value)? = object["expected_output_sha256"] { expectedOutputSHA256 = value }
        else { expectedOutputSHA256 = nil }
        let request = DocumentStagedFileRequest(
            sourcePath: inputPath,
            expectedSourceSHA256: expectedSourceSHA256,
            destinationPath: outputPath,
            replaceExisting: replaceExisting,
            expectedDestinationSHA256: expectedOutputSHA256,
            fileExtension: spec.format.rawValue,
            maximumBytes: 1_024 * 1_024 * 1_024,
            readOnlyInputSnapshots: asset.map { [$0] } ?? [])
        let accumulator = DocumentExecutionAccumulator()
        let receipt = try await DocumentStagedOutput.writeFile(
            request,
            workspace: context.workspaceRoot,
            produce: { stagedOutput in
                var payload = object
                for key in [
                    "expected_source_sha256", "replace_existing",
                    "expected_output_sha256",
                ] {
                    payload.removeValue(forKey: key)
                }
                if let source { payload["input_path"] = .string(source.url.path) }
                payload["output_path"] = .string(stagedOutput.path)
                if let field = spec.assetField, let asset {
                    payload[field] = .string(asset.url.path)
                }
                let reviewedInputs = [inputPath, assetPath].compactMap { $0 }
                let envelope = try await DocumentPythonBackend.run(
                    operation: spec.name,
                    payload: .object(payload),
                    readableWorkspacePaths: reviewedInputs,
                    writableWorkspacePaths: [outputPath],
                    internalWritableWorkspacePaths: [stagedOutput.deletingLastPathComponent().path],
                    in: context)
                await accumulator.record(
                    versions: envelope.engineVersions,
                    warnings: envelope.warnings,
                    result: envelope.result)
            },
            validate: { output in
                let values = try output.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) > 0 else {
                    throw DocumentToolError(.validationFailed, "external document operation produced no safe output")
                }
            })
        let execution = await accumulator.snapshot()
        return try DocumentToolSupport.observation(
            operation: spec.name,
            format: spec.format,
            result: execution.result,
            engineVersions: execution.versions,
            warnings: execution.warnings,
            receipt: receipt,
            changedFiles: [outputPath])
    }
}
