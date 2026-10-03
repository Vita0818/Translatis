import Foundation
import IntatisProtocol
@testable import IntatisTools
import XCTest

final class DocumentPythonWriteBackendTests: XCTestCase {
    private let exactWrites = [
        "docx_create_document", "docx_add_paragraph", "docx_set_paragraph_text",
        "docx_add_run", "docx_set_run_bold", "docx_set_run_italic",
        "docx_set_run_underline", "docx_add_table", "docx_set_table_cell_text",
        "docx_add_picture", "docx_set_header_paragraph_text",
        "docx_set_footer_paragraph_text", "docx_set_section_orientation",
        "docx_set_section_top_margin", "docx_set_section_right_margin",
        "docx_set_section_bottom_margin", "docx_set_section_left_margin",
        "pptx_create_presentation", "pptx_add_slide", "pptx_set_shape_text",
        "pptx_add_shape", "pptx_add_picture", "pptx_add_table",
        "pptx_set_table_cell_text", "xlsx_create_workbook", "xlsx_create_sheet",
        "xlsx_set_sheet_title", "xlsx_set_cell_value", "xlsx_append_row",
    ]

    func testEmbeddedProgramIsValidPython() throws {
        let invocation = try DocumentPythonBackend.invocation(
            operation: "docx_create_document",
            payload: .object(["output_path": .string("/tmp/output.docx")]),
            readableWorkspacePaths: [],
            writableWorkspacePaths: ["output.docx"])
        let program = try XCTUnwrap(invocation.arguments.last)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c",
            "import sys; compile(sys.argv[1], 'DocumentPythonBackend', 'exec')",
            program,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }

    func testBackendRouteTableContainsEveryExactEntryAndNoAggregateWriteDSL() throws {
        let program = try embeddedProgram()
        for route in [
            "read_docx", "read_pptx", "read_xlsx", "read_html", "read_epub",
            "ocr_pdf",
        ] + exactWrites {
            XCTAssertTrue(program.contains("'\(route)'"), route)
        }
        for removed in [
            "def write_native", "def verify_native_write", "def write_html",
            "def verify_docx_write", "def verify_pptx_write", "def verify_xlsx_write",
            "def verify_html_write", "'operations'", "'verify_write'",
            "chart.add", "range.set", "style.set", "metadata.set",
            "prepare_html_render", "validate_self_contained_html",
            "reject_xlsx_external_formulas", "reject_xlsx_preservation_hazards",
            "reject_external_spreadsheet_text", "present_main_parts",
        ] {
            XCTAssertFalse(program.contains(removed), removed)
        }
    }

    func testReadRoutesDoNotAcceptAFormatField() throws {
        let program = try embeddedProgram()
        XCTAssertFalse(program.contains("payload.get('format')"))
        XCTAssertFalse(program.contains("'format', 'input_path'"))
        XCTAssertTrue(program.contains("def read_docx(payload):"))
        XCTAssertTrue(program.contains("def read_pptx(payload):"))
        XCTAssertTrue(program.contains("def read_xlsx(payload):"))
        XCTAssertTrue(program.contains("def read_html(payload):"))
        XCTAssertTrue(program.contains("def read_epub(payload):"))
    }

    func testOCRUsesOfficialDoclingMarkdownInsteadOfParsedCellTraversal() throws {
        let program = try embeddedProgram()
        let start = try XCTUnwrap(program.range(of: "def ocr_pdf(payload):"))
        let end = try XCTUnwrap(program.range(of: "ROUTES = {", range: start.upperBound..<program.endIndex))
        let ocr = String(program[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(ocr.contains("conversion.document.export_to_markdown"))
        XCTAssertTrue(ocr.contains("lang=['eng']"))
        XCTAssertTrue(ocr.contains("psm=3"))
        XCTAssertFalse(ocr.contains("textline_cells"))
        XCTAssertFalse(ocr.contains("bbox"))
        XCTAssertFalse(ocr.contains("contiguous_page_runs"))
    }

    func testLegacyAggregateOperationsFailBeforeAnyDependencyImport() throws {
        for operation in ["read", "ocr", "write", "verify_write"] {
            let invocation = try DocumentPythonBackend.invocation(
                operation: operation,
                payload: .object([:]),
                readableWorkspacePaths: [])
            let envelope = try run(invocation)
            XCTAssertEqual(envelope["ok"] as? Bool, false, operation)
            XCTAssertEqual(envelope["code"] as? String, "unsupported_operation", operation)
        }
    }

    func testOperationMustMatchItsHostEnvironmentBinding() throws {
        let invocation = try DocumentPythonBackend.invocation(
            operation: "read_docx",
            payload: .object([:]),
            readableWorkspacePaths: [])
        var environment = invocation.environment
        environment["INTATIS_DOCUMENT_OPERATION"] = "read_pptx"
        let envelope = try run(invocation, environment: environment)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual(envelope["code"] as? String, "validation_failed")
    }

    func testUnexpectedPythonExceptionKeepsFixedSanitizedEnvelope() throws {
        let invocation = try DocumentPythonBackend.invocation(
            operation: "docx_create_document",
            payload: .object(["output_path": .string("/tmp/output.docx")]),
            readableWorkspacePaths: [],
            writableWorkspacePaths: ["output.docx"])
        let program = try XCTUnwrap(invocation.arguments.last)
            .replacingOccurrences(
                of: "operation, payload = require_request()",
                with: "operation, payload = require_request(); raise RuntimeError('/secret/path user text')")
        var arguments = invocation.arguments
        arguments[arguments.count - 1] = program
        let changed = DocumentBackendInvocation(
            executable: invocation.executable,
            arguments: arguments,
            environment: invocation.environment,
            readableWorkspacePaths: invocation.readableWorkspacePaths,
            writableWorkspacePaths: invocation.writableWorkspacePaths,
            internalWritableWorkspacePaths: invocation.internalWritableWorkspacePaths,
            internalReadOnlyWorkspacePaths: invocation.internalReadOnlyWorkspacePaths)
        let envelope = try run(changed)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual(envelope["code"] as? String, "backend_failed")
        XCTAssertEqual(envelope["summary"] as? String, "fixed document backend failed unexpectedly")
        XCTAssertFalse(String(describing: envelope).contains("/secret/path"))
    }

    func testExactWritersUseOnlyOneExternalMutationAtEachEntry() throws {
        let program = try embeddedProgram()
        let expectations: [String: String] = [
            "docx_add_paragraph": "document.add_paragraph(",
            "docx_set_paragraph_text": "paragraph.text =",
            "docx_add_run": "paragraph.add_run(",
            "docx_add_table": "document.add_table(",
            "docx_add_picture": "document.add_picture(",
            "pptx_add_slide": "presentation.slides.add_slide(",
            "pptx_set_shape_text": "shape.text =",
            "pptx_add_shape": "slide.shapes.add_shape(",
            "pptx_add_picture": "slide.shapes.add_picture(",
            "pptx_add_table": "slide.shapes.add_table(",
            "xlsx_create_sheet": "workbook.create_sheet(",
            "xlsx_set_cell_value": "].value =",
            "xlsx_append_row": "].append(",
        ]
        for (function, call) in expectations {
            guard let start = program.range(of: "def \(function)(payload):") else {
                return XCTFail("missing \(function)")
            }
            let tail = program[start.lowerBound...]
            let next = tail.dropFirst().range(of: "\ndef ")?.lowerBound ?? program.endIndex
            let body = String(program[start.lowerBound..<next])
            XCTAssertTrue(body.contains(call), "\(function): \(call)")
            XCTAssertFalse(body.contains("for operation in"), function)
        }
    }

    private func embeddedProgram() throws -> String {
        let invocation = try DocumentPythonBackend.invocation(
            operation: "docx_create_document",
            payload: .object(["output_path": .string("/tmp/output.docx")]),
            readableWorkspacePaths: [])
        return try XCTUnwrap(invocation.arguments.last)
    }

    private func run(
        _ invocation: DocumentBackendInvocation,
        environment: [String: String]? = nil
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + invocation.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment ?? invocation.environment,
            uniquingKeysWith: { _, new in new })
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
