import Foundation
import IntatisProtocol
@testable import IntatisTools
import XCTest

final class DocumentReadToolSplitTests: XCTestCase {
    func testStandardRegistryExposesExactReadersAndContinuationsAndNoAggregateReader() {
        let registry = ToolRegistry.standard()

        for name in [
            "read_docx", "continue_docx_read",
            "read_pptx", "continue_pptx_read",
            "read_xlsx", "continue_xlsx_read",
            "read_html", "continue_html_read",
            "read_epub", "continue_epub_read",
        ] {
            XCTAssertNotNil(registry.tool(named: name), name)
        }
        XCTAssertNil(registry.tool(named: "document_read"))
        XCTAssertEqual(registry.registryVersion, "intatis.standard.v5")
    }

    func testContinuationsExposeOnlyPathOpaqueCursorAndCharacterBudget() throws {
        let descriptors = [
            ContinueDOCXReadTool.descriptor,
            ContinuePPTXReadTool.descriptor,
            ContinueXLSXReadTool.descriptor,
            ContinueHTMLReadTool.descriptor,
            ContinueEPUBReadTool.descriptor,
        ]

        for descriptor in descriptors {
            XCTAssertEqual(descriptor.sideEffect, .exec)
            guard case .object(let schema) = descriptor.parameters,
                  case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(descriptor.name) must expose an object schema")
            }
            XCTAssertEqual(Set(properties.keys), ["path", "cursor", "maxCharacters"])
            XCTAssertEqual(schema["additionalProperties"], .bool(false))
            let encoded = String(
                data: try JSONEncoder().encode(descriptor.parameters),
                encoding: .utf8) ?? ""
            for forbidden in ["format", "options", "sheet", "range", "xpath", "backend"] {
                XCTAssertFalse(encoded.contains("\"\(forbidden)\""), "\(descriptor.name): \(forbidden)")
            }
        }
    }

    func testReadersExposeOnlyPathAndCharacterBudget() throws {
        let descriptors = [
            ReadDOCXTool.descriptor,
            ReadPPTXTool.descriptor,
            ReadXLSXTool.descriptor,
            ReadHTMLTool.descriptor,
            ReadEPUBTool.descriptor,
        ]

        for descriptor in descriptors {
            XCTAssertEqual(descriptor.sideEffect, .exec)
            guard case .object(let schema) = descriptor.parameters,
                  case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(descriptor.name) must expose an object schema")
            }
            XCTAssertEqual(Set(properties.keys), ["path", "maxCharacters"])
            XCTAssertEqual(schema["additionalProperties"], .bool(false))
            let encoded = String(
                data: try JSONEncoder().encode(descriptor.parameters),
                encoding: .utf8) ?? ""
            for forbidden in ["format", "options", "sheet", "range", "xpath", "backend"] {
                XCTAssertFalse(encoded.contains("\"\(forbidden)\""), "\(descriptor.name): \(forbidden)")
            }
        }
    }

    func testEachReaderOwnsItsFileExtension() throws {
        XCTAssertNoThrow(try ReadDOCXTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.docx","maxCharacters":12000}"#)))
        XCTAssertNoThrow(try ReadPPTXTool().validateArguments(
            ToolArgs(raw: #"{"path":"slides.pptx"}"#)))
        XCTAssertNoThrow(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"table.xlsx"}"#)))
        XCTAssertNoThrow(try ReadHTMLTool().validateArguments(
            ToolArgs(raw: #"{"path":"page.html"}"#)))
        XCTAssertNoThrow(try ReadEPUBTool().validateArguments(
            ToolArgs(raw: #"{"path":"book.epub"}"#)))

        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"slides.pptx"}"#)))
        XCTAssertThrowsError(try ReadDOCXTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.docx","format":"docx"}"#)))
        XCTAssertThrowsError(try ReadHTMLTool().validateArguments(
            ToolArgs(raw: #"{"path":"page.html","options":{}}"#)))
        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"table.xlsx","maxCharacters":0}"#)))
        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"path":"table.xlsx","maxCharacters":500001}"#)))
        XCTAssertThrowsError(try ReadXLSXTool().validateArguments(
            ToolArgs(raw: #"{"maxCharacters":12000}"#)))

        XCTAssertNoThrow(try ContinueDOCXReadTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.docx","cursor":"abc_DEF-123"}"#)))
        XCTAssertThrowsError(try ContinueDOCXReadTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.pptx","cursor":"abc_DEF-123"}"#)))
        XCTAssertThrowsError(try ContinueDOCXReadTool().validateArguments(
            ToolArgs(raw: #"{"path":"notes.docx","cursor":"not+base64url"}"#)))
    }

    func testReadersAreReviewedProcessExecutionsButSafeToReplay() {
        let workspace = URL(fileURLWithPath: "/workspace")
        let cases: [(PermissionIntent, DocumentFormat)] = [
            (ReadDOCXTool().permissionIntent(
                ToolArgs(raw: #"{"path":"notes.docx"}"#), workspaceRoot: workspace), .docx),
            (ReadPPTXTool().permissionIntent(
                ToolArgs(raw: #"{"path":"slides.pptx"}"#), workspaceRoot: workspace), .pptx),
            (ReadXLSXTool().permissionIntent(
                ToolArgs(raw: #"{"path":"table.xlsx"}"#), workspaceRoot: workspace), .xlsx),
            (ReadHTMLTool().permissionIntent(
                ToolArgs(raw: #"{"path":"page.html"}"#), workspaceRoot: workspace), .html),
            (ReadEPUBTool().permissionIntent(
                ToolArgs(raw: #"{"path":"book.epub"}"#), workspaceRoot: workspace), .epub),
        ]

        for (intent, format) in cases {
            XCTAssertEqual(intent.action, "document.read.\(format.rawValue)")
            XCTAssertEqual(intent.dataEffects, [.read, .execute])
            XCTAssertEqual(intent.risks, [.processExecution])
            XCTAssertEqual(intent.replayPolicy, .safeToReplay)
            XCTAssertTrue(intent.isStructuredReadOnlyExecution)
            XCTAssertTrue(intent.isReadOnlyWorkspaceCompatible)
        }

        let continuation = ContinueDOCXReadTool().permissionIntent(
            ToolArgs(raw: #"{"path":"notes.docx","cursor":"abc"}"#),
            workspaceRoot: workspace)
        XCTAssertEqual(continuation.action, "document.read.docx.continue")
        XCTAssertEqual(continuation.metadata["operation"], .string("continue_bounded_markdown"))
        XCTAssertEqual(continuation.replayPolicy, .safeToReplay)
        XCTAssertTrue(continuation.isStructuredReadOnlyExecution)
        XCTAssertTrue(continuation.isReadOnlyWorkspaceCompatible)
    }
}
