import Foundation
import IntatisProtocol

// MARK: - Model-facing document contracts

/// The document tools deliberately expose data, never backend selection or a
/// command line. Each argument type owns both its provider-facing schema and a
/// semantic validator for invariants that the generic schema checker cannot
/// express.
struct ReadPDFArguments: Codable, Equatable, Sendable {
    let path: String
    let pages: String?
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case path, pages
        case maxCharacters
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "path": DocumentContractSchema.path,
            "pages": DocumentContractSchema.pageSelection,
            "maxCharacters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["path"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["path", "pages", "maxCharacters"],
            required: ["path"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(value.path, extension: .pdf, field: "path")
        try DocumentContractValidation.validatePageSelection(value.pages, field: "pages")
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "maxCharacters")
        return value
    }
}

struct DocumentTextReadArguments: Codable, Equatable, Sendable {
    let path: String
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case path, maxCharacters
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "path": DocumentContractSchema.path,
            "maxCharacters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["path"])

    static func decodeValidated(_ args: ToolArgs, format: DocumentFormat) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["path", "maxCharacters"],
            required: ["path"])

        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(
            value.path,
            extension: format,
            field: "path")
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "maxCharacters")
        return value
    }
}

struct DocumentTextContinueArguments: Codable, Equatable, Sendable {
    let path: String
    let cursor: String
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case path, cursor, maxCharacters
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "path": DocumentContractSchema.path,
            "cursor": DocumentContractSchema.string(
                minimumLength: 1,
                maximumLength: 2_048,
                pattern: "^[A-Za-z0-9_-]+$"),
            "maxCharacters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["path", "cursor"])

    static func decodeValidated(_ args: ToolArgs, format: DocumentFormat) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["path", "cursor", "maxCharacters"],
            required: ["path", "cursor"])

        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(
            value.path,
            extension: format,
            field: "path")
        guard !value.cursor.isEmpty,
              value.cursor.utf8.count <= 2_048,
              value.cursor.range(
                  of: "^[A-Za-z0-9_-]+$",
                  options: .regularExpression) != nil else {
            throw DocumentToolError(.validationFailed, "cursor is not a valid opaque document cursor")
        }
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "maxCharacters")
        return value
    }
}

struct InspectPDFArguments: Codable, Equatable, Sendable {
    let path: String

    static let schema = DocumentContractSchema.object(
        properties: ["path": DocumentContractSchema.path],
        required: ["path"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["path"],
            required: ["path"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(value.path, extension: .pdf, field: "path")
        return value
    }
}

struct OCRPDFArguments: Codable, Equatable, Sendable {
    let inputPath: String
    let expectedSourceSHA256: String
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case maxCharacters = "max_characters"
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "max_characters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["input_path", "expected_source_sha256"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["input_path", "expected_source_sha256", "max_characters"],
            required: ["input_path", "expected_source_sha256"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(
            value.inputPath,
            extension: .pdf,
            field: "input_path")
        try DocumentContractValidation.validateSHA256(
            value.expectedSourceSHA256,
            field: "expected_source_sha256")
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "max_characters")
        return value
    }
}

struct PDFRenderPageArguments: Codable, Equatable, Sendable {
    let inputPath: String
    let expectedSourceSHA256: String
    let page: Int
    let outputPath: String
    let replaceExisting: Bool?
    let expectedOutputSHA256: String?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case page
        case outputPath = "output_path"
        case replaceExisting = "replace_existing"
        case expectedOutputSHA256 = "expected_output_sha256"
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "page": DocumentContractSchema.integer(minimum: 1, maximum: 100_000),
            "output_path": DocumentContractSchema.path,
            "replace_existing": DocumentContractSchema.boolean,
            "expected_output_sha256": DocumentContractSchema.sha256,
        ],
        required: ["input_path", "expected_source_sha256", "page", "output_path"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: [
                "input_path", "expected_source_sha256", "page", "output_path",
                "replace_existing", "expected_output_sha256",
            ],
            required: ["input_path", "expected_source_sha256", "page", "output_path"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(value.inputPath, extension: .pdf, field: "input_path")
        try DocumentContractValidation.validatePath(value.outputPath, rawExtensions: ["png"], field: "output_path")
        try DocumentContractValidation.validateDistinctPaths(input: value.inputPath, output: value.outputPath)
        try DocumentContractValidation.validateSHA256(value.expectedSourceSHA256, field: "expected_source_sha256")
        try DocumentContractValidation.validateInteger(value.page, minimum: 1, maximum: 100_000, field: "page")
        try DocumentContractValidation.validateReplacement(
            replaceExisting: value.replaceExisting ?? false,
            expectedOutputSHA256: value.expectedOutputSHA256)
        return value
    }
}

struct ExactPDFExportArguments: Codable, Equatable, Sendable {
    let inputPath: String
    let expectedSourceSHA256: String
    let localAssetPaths: [String]?
    let outputPath: String
    let replaceExisting: Bool?
    let expectedOutputSHA256: String?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case localAssetPaths = "local_asset_paths"
        case outputPath = "output_path"
        case replaceExisting = "replace_existing"
        case expectedOutputSHA256 = "expected_output_sha256"
    }

    static func schema(format: DocumentFormat) -> JSONValue {
        var properties: [String: JSONValue] = [
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "output_path": DocumentContractSchema.path,
            "replace_existing": DocumentContractSchema.boolean,
            "expected_output_sha256": DocumentContractSchema.sha256,
        ]
        if format == .html {
            properties["local_asset_paths"] = DocumentContractSchema.localAssetPaths
        }
        return DocumentContractSchema.object(
            properties: properties,
            required: ["input_path", "expected_source_sha256", "output_path"])
    }

    static func decodeValidated(_ args: ToolArgs, format: DocumentFormat) throws -> Self {
        guard [.docx, .pptx, .xlsx, .html].contains(format) else {
            throw DocumentToolError(.unsupportedOperation, "format has no fixed PDF export tool")
        }
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        var allowed: Set<String> = [
            "input_path", "expected_source_sha256", "output_path",
            "replace_existing", "expected_output_sha256",
        ]
        if format == .html { allowed.insert("local_asset_paths") }
        try DocumentContractValidation.requireKeys(
            object,
            allowed: allowed,
            required: ["input_path", "expected_source_sha256", "output_path"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(value.inputPath, extension: format, field: "input_path")
        try DocumentContractValidation.validatePath(value.outputPath, extension: .pdf, field: "output_path")
        try DocumentContractValidation.validateDistinctPaths(input: value.inputPath, output: value.outputPath)
        try DocumentContractValidation.validateSHA256(value.expectedSourceSHA256, field: "expected_source_sha256")
        try DocumentContractValidation.validateReplacement(
            replaceExisting: value.replaceExisting ?? false,
            expectedOutputSHA256: value.expectedOutputSHA256)
        if format == .html {
            try DocumentContractValidation.validateLocalAssetPaths(value.localAssetPaths, inputFormat: .html)
        } else if value.localAssetPaths != nil {
            throw DocumentToolError(.validationFailed, "local_asset_paths is only valid for html_export_pdf")
        }
        return value
    }
}

// MARK: - JSON Schema builders

enum DocumentContractSchema {
    static let boolean = JSONValue.object(["type": .string("boolean")])
    static let path = string(minimumLength: 1, maximumLength: 4_096)
    static let pageSelection = string(minimumLength: 1, maximumLength: 1_024)
    static let sha256 = JSONValue.object([
        "type": .string("string"),
        "minLength": .number(64),
        "maxLength": .number(64),
        "pattern": .string("^[A-Fa-f0-9]{64}$"),
    ])
    static let localAssetPaths = array(
        items: path,
        minimumItems: 1,
        maximumItems: 256,
        uniqueItems: true)

    static func object(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        pattern: String? = nil
    ) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string")]
        if let minimumLength { value["minLength"] = .number(Double(minimumLength)) }
        if let maximumLength { value["maxLength"] = .number(Double(maximumLength)) }
        if let pattern { value["pattern"] = .string(pattern) }
        return .object(value)
    }

    static func stringEnum(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    static func integer(minimum: Int, maximum: Int) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .number(Double(minimum)),
            "maximum": .number(Double(maximum)),
        ])
    }

    static func array(
        items: JSONValue,
        minimumItems: Int,
        maximumItems: Int,
        uniqueItems: Bool = false
    ) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": items,
            "minItems": .number(Double(minimumItems)),
            "maxItems": .number(Double(maximumItems)),
            "uniqueItems": .bool(uniqueItems),
        ])
    }

}

// MARK: - Semantic validation

enum DocumentContractValidation {
    private static let forbiddenExecutionControlKeys: Set<String> = [
        "args", "argv", "backend", "binary", "command", "cwd", "env", "environment",
        "executable", "network", "allow_network", "temp", "temp_dir",
        "temporary_directory", "working_directory",
    ]

    static func rootObject(_ args: ToolArgs) throws -> [String: JSONValue] {
        guard let data = args.raw.data(using: .utf8) else {
            throw DocumentToolError(.validationFailed, "arguments are not valid UTF-8")
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let object) = value else {
                throw DocumentToolError(.validationFailed, "arguments must be a JSON object")
            }
            return object
        } catch let error as DocumentToolError {
            throw error
        } catch {
            throw DocumentToolError(.validationFailed, "arguments are not valid JSON")
        }
    }

    static func decode<T: Decodable>(_ args: ToolArgs) throws -> T {
        guard let data = args.raw.data(using: .utf8) else {
            throw DocumentToolError(.validationFailed, "arguments are not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DocumentToolError(.validationFailed, "arguments do not match the document contract")
        }
    }

    static func requireKeys(
        _ object: [String: JSONValue],
        allowed: Set<String>,
        required: Set<String>
    ) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw DocumentToolError(.validationFailed, "arguments contain an unknown field")
        }
        guard required.isSubset(of: Set(object.keys)) else {
            throw DocumentToolError(.validationFailed, "arguments are missing a required field")
        }
    }

    static func rejectForbiddenExecutionControls(in value: JSONValue) throws {
        switch value {
        case .object(let object):
            if object.keys.contains(where: forbiddenExecutionControlKeys.contains) {
                throw DocumentToolError(
                    .unsupportedOperation,
                    "document tools do not accept backend, command, environment, network, or temporary-path controls")
            }
            for nested in object.values {
                try rejectForbiddenExecutionControls(in: nested)
            }
        case .array(let values):
            for nested in values {
                try rejectForbiddenExecutionControls(in: nested)
            }
        case .null, .bool, .number, .string:
            break
        }
    }

    static func validatePath(
        _ path: String,
        extension format: DocumentFormat,
        field: String
    ) throws {
        try validatePlainPath(path, field: field)
        let actual = URL(fileURLWithPath: path).pathExtension.lowercased()
        let allowed: Set<String> = format == .html ? ["html", "htm"] : [format.rawValue]
        guard allowed.contains(actual) else {
            throw DocumentToolError(
                .validationFailed,
                "\(field) extension does not match the declared format")
        }
    }

    static func validatePath(
        _ path: String,
        rawExtensions: Set<String>,
        field: String
    ) throws {
        try validatePlainPath(path, field: field)
        let actual = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard rawExtensions.contains(actual) else {
            throw DocumentToolError(
                .validationFailed,
                "\(field) extension does not match the required file type")
        }
    }

    static func validateDistinctPaths(input: String, output: String) throws {
        guard (input as NSString).standardizingPath != (output as NSString).standardizingPath else {
            throw DocumentToolError(.validationFailed, "input_path and output_path must differ")
        }
    }

    static func validateLocalAssetPaths(
        _ paths: [String]?,
        inputFormat: DocumentFormat
    ) throws {
        guard let paths else { return }
        guard inputFormat == .html else {
            throw DocumentToolError(
                .validationFailed,
                "local_asset_paths is only valid for HTML input")
        }
        guard (1...256).contains(paths.count), Set(paths).count == paths.count else {
            throw DocumentToolError(
                .validationFailed,
                "local_asset_paths must contain one to 256 distinct paths")
        }
        for path in paths {
            try validatePlainPath(path, field: "local_asset_paths")
        }
    }

    static func validatePlainPath(_ path: String, field: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096, !trimmed.contains("\0") else {
            throw DocumentToolError(.validationFailed, "\(field) is not a valid bounded path")
        }
        let lower = trimmed.lowercased()
        guard !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://"),
              !lower.hasPrefix("file://") else {
            throw DocumentToolError(.validationFailed, "\(field) must be a workspace file path")
        }
    }

    static func validateSHA256(_ digest: String, field: String) throws {
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }) else {
            throw DocumentToolError(.validationFailed, "\(field) must be a SHA-256 hex digest")
        }
    }

    static func validateReplacement(
        replaceExisting: Bool,
        expectedOutputSHA256: String?
    ) throws {
        if replaceExisting {
            guard let expectedOutputSHA256 else {
                throw DocumentToolError(
                    .validationFailed,
                    "replace_existing requires expected_output_sha256")
            }
            try validateSHA256(expectedOutputSHA256, field: "expected_output_sha256")
        } else if expectedOutputSHA256 != nil {
            throw DocumentToolError(
                .validationFailed,
                "expected_output_sha256 is only valid with replace_existing")
        }
    }

    static func validateInteger(
        _ value: Int?,
        minimum: Int,
        maximum: Int,
        field: String
    ) throws {
        guard let value else { return }
        guard (minimum...maximum).contains(value) else {
            throw DocumentToolError(
                .validationFailed,
                "\(field) is outside the supported bounds")
        }
    }

    static func validateInteger(
        _ value: Int,
        minimum: Int,
        maximum: Int,
        field: String
    ) throws {
        guard (minimum...maximum).contains(value) else {
            throw DocumentToolError(
                .validationFailed,
                "\(field) is outside the supported bounds")
        }
    }

    static func validatePageSelection(_ raw: String?, field: String) throws {
        guard let raw else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024 else {
            throw DocumentToolError(.validationFailed, "\(field) is empty or too long")
        }
        if trimmed.lowercased() == "all" { return }

        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 1_000 else {
            throw DocumentToolError(.validationFailed, "\(field) has too many page selectors")
        }
        for part in parts {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw DocumentToolError(.validationFailed, "\(field) contains an empty selector")
            }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2,
                  let start = Int(bounds[0]),
                  (1...100_000).contains(start) else {
                throw DocumentToolError(.validationFailed, "\(field) contains an invalid page selector")
            }
            if bounds.count == 2 {
                guard let end = Int(bounds[1]), start <= end, end <= 100_000 else {
                    throw DocumentToolError(.validationFailed, "\(field) contains an invalid page range")
                }
            }
        }
    }

    static func validatePattern(_ value: String, pattern: String, field: String) throws {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(in: value, range: range)?.range == range else {
            throw DocumentToolError(.validationFailed, "\(field) has an invalid value")
        }
    }
}
