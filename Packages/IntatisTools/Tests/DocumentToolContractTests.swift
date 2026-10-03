import Foundation
import IntatisProtocol
@testable import IntatisTools
import XCTest

final class DocumentToolContractTests: XCTestCase {
    private let legacyAggregates = [
        "document_read", "document_ocr", "document_render",
        "document_export_pdf", "document_write",
    ]

    private let exactExports = [
        "docx_export_pdf", "pptx_export_pdf",
        "xlsx_export_pdf", "html_export_pdf",
    ]

    private let exactWrites = [
        "docx_create_document", "docx_add_paragraph",
        "docx_set_paragraph_text", "docx_add_run",
        "docx_set_run_bold", "docx_set_run_italic",
        "docx_set_run_underline", "docx_add_table",
        "docx_set_table_cell_text", "docx_add_picture",
        "docx_set_header_paragraph_text", "docx_set_footer_paragraph_text",
        "docx_set_section_orientation", "docx_set_section_top_margin",
        "docx_set_section_right_margin", "docx_set_section_bottom_margin",
        "docx_set_section_left_margin",
        "pptx_create_presentation", "pptx_add_slide",
        "pptx_set_shape_text", "pptx_add_shape", "pptx_add_picture",
        "pptx_add_table", "pptx_set_table_cell_text",
        "xlsx_create_workbook", "xlsx_create_sheet",
        "xlsx_set_sheet_title", "xlsx_set_cell_value", "xlsx_append_row",
    ]

    func testFreshRegistryExposesOnlyExactDocumentOperations() {
        let registry = ToolRegistry.standard()
        for name in ["ocr_pdf", "pdf_render_page"] + exactExports + exactWrites {
            XCTAssertNotNil(registry.registration(named: name), name)
        }
        for name in legacyAggregates {
            XCTAssertNil(registry.registration(named: name), name)
        }
        for unsupported in [
            "pptx_add_chart", "xlsx_set_range", "xlsx_set_style",
            "xlsx_add_table", "xlsx_set_name", "xlsx_add_chart",
            "html_set_text", "html_set_attribute", "html_append", "html_remove",
            "epub_set_metadata", "epub_add_resource", "epub_append_spine", "epub_add_toc",
        ] {
            XCTAssertNil(registry.registration(named: unsupported), unsupported)
        }
        XCTAssertEqual(registry.registryVersion, "intatis.standard.v5")
    }

    func testExactSchemasAreClosedAndNeverExposeAggregateOrExecutionControls() throws {
        let registry = ToolRegistry.standard()
        let names = ["ocr_pdf", "pdf_render_page"] + exactExports + exactWrites
        for name in names {
            guard let descriptor = registry.registration(named: name)?.descriptor,
                  case .object(let schema) = descriptor.parameters else {
                return XCTFail("missing schema for \(name)")
            }
            XCTAssertEqual(schema["additionalProperties"], .bool(false), name)
            let encoded = String(
                data: try JSONEncoder().encode(descriptor.parameters),
                encoding: .utf8) ?? ""
            for forbidden in [
                "format", "mode", "operation", "operations", "backend",
                "engine", "command", "environment", "working_directory",
            ] {
                XCTAssertFalse(encoded.contains("\"\(forbidden)\""), "\(name): \(forbidden)")
            }
        }
    }

    func testOCRIsOneFixedDoclingTesseractCall() throws {
        XCTAssertNoThrow(try OCRPDFTool().validateArguments(ToolArgs(raw: """
        {"input_path":"scan.pdf","expected_source_sha256":"\(digest)","max_characters":12000}
        """)))
        for rejected in [
            "{\"input_path\":\"scan.pdf\",\"expected_source_sha256\":\"\(digest)\",\"languages\":[\"eng\"]}",
            "{\"input_path\":\"scan.pdf\",\"expected_source_sha256\":\"\(digest)\",\"psm\":3}",
            "{\"input_path\":\"scan.pdf\",\"expected_source_sha256\":\"\(digest)\",\"pages\":\"1\"}",
            "{\"input_path\":\"scan.docx\",\"expected_source_sha256\":\"\(digest)\"}",
        ] {
            XCTAssertThrowsError(try OCRPDFTool().validateArguments(ToolArgs(raw: rejected)))
        }
    }

    func testPDFRenderAcceptsOnePageAndOnePNGOutput() throws {
        let valid = """
        {"input_path":"input.pdf","expected_source_sha256":"\(digest)","page":2,"output_path":"page.png"}
        """
        XCTAssertNoThrow(try PDFRenderPageTool().validateArguments(ToolArgs(raw: valid)))
        for rejected in [
            "{\"input_path\":\"input.pdf\",\"expected_source_sha256\":\"\(digest)\",\"pages\":\"1-2\",\"output_path\":\"pages\"}",
            "{\"input_path\":\"input.docx\",\"expected_source_sha256\":\"\(digest)\",\"page\":1,\"output_path\":\"page.png\"}",
            "{\"input_path\":\"input.pdf\",\"expected_source_sha256\":\"\(digest)\",\"page\":1,\"output_path\":\"page.jpg\"}",
            "{\"input_path\":\"input.pdf\",\"expected_source_sha256\":\"\(digest)\",\"page\":0,\"output_path\":\"page.png\"}",
        ] {
            XCTAssertThrowsError(try PDFRenderPageTool().validateArguments(ToolArgs(raw: rejected)))
        }
    }

    func testEachExportOwnsItsFormatAndOnlyHTMLAcceptsAssets() throws {
        let registry = ToolRegistry.standard()
        let cases = [
            ("docx_export_pdf", "input.docx"),
            ("pptx_export_pdf", "input.pptx"),
            ("xlsx_export_pdf", "input.xlsx"),
            ("html_export_pdf", "input.html"),
        ]
        for (name, input) in cases {
            let raw = """
            {"input_path":"\(input)","expected_source_sha256":"\(digest)","output_path":"output.pdf"}
            """
            XCTAssertNoThrow(try registry.registration(named: name)?.validateArguments(ToolArgs(raw: raw)), name)
        }
        XCTAssertThrowsError(try registry.registration(named: "docx_export_pdf")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"input.pptx","expected_source_sha256":"\(digest)","output_path":"output.pdf"}
            """)))
        XCTAssertNoThrow(try registry.registration(named: "html_export_pdf")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"input.html","expected_source_sha256":"\(digest)","local_asset_paths":["image.png"],"output_path":"output.pdf"}
            """)))
        XCTAssertThrowsError(try registry.registration(named: "xlsx_export_pdf")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"input.xlsx","expected_source_sha256":"\(digest)","local_asset_paths":["image.png"],"output_path":"output.pdf"}
            """)))
    }

    func testCreateAndMutationContractsKeepCASOutsideBusinessArguments() throws {
        let registry = ToolRegistry.standard()
        XCTAssertNoThrow(try registry.registration(named: "docx_create_document")?.validateArguments(
            ToolArgs(raw: #"{"output_path":"new.docx"}"#)))
        XCTAssertThrowsError(try registry.registration(named: "docx_create_document")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"old.docx","expected_source_sha256":"\(digest)","output_path":"new.docx"}
            """)))

        let mutation = """
        {"input_path":"old.docx","expected_source_sha256":"\(digest)","output_path":"new.docx","text":"hello"}
        """
        XCTAssertNoThrow(try registry.registration(named: "docx_add_paragraph")?.validateArguments(
            ToolArgs(raw: mutation)))
        XCTAssertThrowsError(try registry.registration(named: "docx_add_paragraph")?.validateArguments(
            ToolArgs(raw: #"{"input_path":"old.docx","output_path":"new.docx","text":"hello"}"#)))

        let inPlace = """
        {"input_path":"same.docx","expected_source_sha256":"\(digest)","output_path":"same.docx","replace_existing":true,"expected_output_sha256":"\(digest)","text":"hello"}
        """
        XCTAssertNoThrow(try registry.registration(named: "docx_add_paragraph")?.validateArguments(
            ToolArgs(raw: inPlace)))
        XCTAssertThrowsError(try registry.registration(named: "docx_add_paragraph")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"same.docx","expected_source_sha256":"\(digest)","output_path":"same.docx","text":"hello"}
            """)))
    }

    func testPreviouslyBundledBusinessOperationsCannotHideInsideAnExactCall() throws {
        let registry = ToolRegistry.standard()
        XCTAssertThrowsError(try registry.registration(named: "pptx_add_slide")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"slides.pptx","expected_source_sha256":"\(digest)","output_path":"next.pptx","slide_layout_index":0,"title":"bundled"}
            """)))
        XCTAssertThrowsError(try registry.registration(named: "pptx_add_shape")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"slides.pptx","expected_source_sha256":"\(digest)","output_path":"next.pptx","slide_index":0,"shape_type":1,"left":0,"top":0,"width":100,"height":100,"text":"bundled"}
            """)))
        XCTAssertThrowsError(try registry.registration(named: "pptx_add_table")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"slides.pptx","expected_source_sha256":"\(digest)","output_path":"next.pptx","slide_index":0,"rows":2,"cols":2,"left":0,"top":0,"width":100,"height":100,"values":[["x"]]}
            """)))
    }

    func testXLSXSurfaceIsCellValueAndAppendOnly() throws {
        let registry = ToolRegistry.standard()
        XCTAssertNoThrow(try registry.registration(named: "xlsx_set_cell_value")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"book.xlsx","expected_source_sha256":"\(digest)","output_path":"next.xlsx","sheet":"Sheet","cell":"A1","value":42}
            """)))
        XCTAssertNoThrow(try registry.registration(named: "xlsx_append_row")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"book.xlsx","expected_source_sha256":"\(digest)","output_path":"next.xlsx","sheet":"Sheet","values":[1,"two",true,null]}
            """)))
        XCTAssertThrowsError(try registry.registration(named: "xlsx_set_cell_value")?.validateArguments(
            ToolArgs(raw: """
            {"input_path":"book.xlsx","expected_source_sha256":"\(digest)","output_path":"next.xlsx","sheet":"Sheet","cell":"A1","value":"=WEBSERVICE(\"https://example.com\")"}
            """)))
    }

    func testCompileLaTeXHasNoEngineSelector() throws {
        guard case .object(let schema) = CompileLaTeXTool.descriptor.parameters,
              case .object(let properties)? = schema["properties"] else {
            return XCTFail("compile_latex schema missing")
        }
        XCTAssertEqual(Set(properties.keys), ["inputPath", "outputDir"])
        XCTAssertFalse(properties.keys.contains("engine"))
    }

    private var digest: String { String(repeating: "a", count: 64) }
}
