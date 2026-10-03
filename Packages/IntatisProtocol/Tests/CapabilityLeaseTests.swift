import Foundation
import XCTest
import IntatisCore
@testable import IntatisProtocol

final class CapabilityLeaseTests: XCTestCase {
    private static let documentCapabilities = Set<ToolCapability>([
        .readPDF,
    ])
        .union(ToolCapability.exactDocumentReaderCapabilities)
        .union([.ocrPDF])
        .union(ToolCapability.exactDocumentMutationCapabilities)

    private static let documentObservationCapabilities =
        ToolCapability.exactDocumentObservationCapabilities

    private static let documentMutationCapabilities =
        ToolCapability.exactDocumentMutationCapabilities

    private static let legacyDocumentCapabilities = ToolCapability.legacyDocumentCapabilities

    func testWorkerLeaseDoesNotGrantDirectDelegation() throws {
        let lease = CapabilityLease.worker(taskID: TaskID(rawValue: "task_worker"))

        XCTAssertTrue(lease.tools.contains(.readWorkspace))
        XCTAssertTrue(lease.tools.contains(.listWorkspace))
        XCTAssertTrue(lease.tools.contains(.searchWorkspace))
        XCTAssertTrue(lease.tools.contains(.readPDF))
        XCTAssertTrue(Self.documentObservationCapabilities.isSubset(of: lease.tools))
        XCTAssertFalse(lease.tools.contains(.hostedWebSearch))
        XCTAssertTrue(lease.tools.isDisjoint(with: Self.documentMutationCapabilities))
        XCTAssertTrue(lease.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        XCTAssertFalse(lease.tools.contains(.delegateTask))
        XCTAssertFalse(lease.tools.contains(.attachWorkspace))
        XCTAssertFalse(lease.tools.contains(.generateMedia))
        XCTAssertTrue(lease.tools.isDisjoint(
            with: ToolCapability.exactImageMutationCapabilities))
        XCTAssertFalse(lease.tools.contains(.browseWeb))
        XCTAssertFalse(lease.tools.contains(.gitControl))
        XCTAssertFalse(lease.tools.contains(.gitRemote))
        XCTAssertEqual(lease.delegation, .none)
    }

    func testCoordinatorLeaseGrantsDelegationTools() {
        let lease = CapabilityLease.coordinator(taskID: TaskID(rawValue: "task_coord"))

        XCTAssertTrue(lease.tools.contains(.delegateTask))
        XCTAssertTrue(lease.tools.contains(.attachWorkspace))
        XCTAssertTrue(lease.tools.contains(.requestInformation))
        XCTAssertTrue(Self.documentCapabilities.isSubset(of: lease.tools))
        XCTAssertTrue(lease.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        XCTAssertTrue(lease.tools.contains(.compileLaTeX))
        XCTAssertTrue(lease.tools.contains(.generateMedia))
        XCTAssertTrue(lease.tools.contains(.browseWeb))
        XCTAssertTrue(lease.tools.contains(.hostedWebSearch))
        XCTAssertTrue(lease.tools.contains(.gitControl))
        XCTAssertTrue(lease.tools.contains(.gitRemote))
        XCTAssertTrue(lease.tools.contains(.runShell))
        guard case .granted(let budget) = lease.delegation else {
            return XCTFail("coordinator lease should grant delegation")
        }
        XCTAssertGreaterThan(budget.maxTasks, 0)
        XCTAssertEqual(budget.maxDepth, 1)
    }

    func testReadWriteWorkerReceivesManagedTerminalCapability() {
        let readOnly = CapabilityLease.worker(workspaceAccess: .readOnly)
        let readWrite = CapabilityLease.worker(workspaceAccess: .readWrite)

        XCTAssertFalse(readOnly.tools.contains(.runShell))
        XCTAssertTrue(readWrite.tools.contains(.runShell))
        XCTAssertFalse(readOnly.tools.contains(.hostedWebSearch))
        XCTAssertTrue(readWrite.tools.contains(.hostedWebSearch))
        XCTAssertTrue(Self.documentObservationCapabilities.isSubset(of: readOnly.tools))
        XCTAssertTrue(readOnly.tools.isDisjoint(with: Self.documentMutationCapabilities))
        XCTAssertTrue(Self.documentCapabilities.isSubset(of: readWrite.tools))
        XCTAssertTrue(readOnly.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        XCTAssertTrue(readWrite.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
    }

    func testLegacyDocumentCapabilitiesDecodeButFreshLeasesDoNotIssueThem() throws {
        let template = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_legacy_document"),
            tools: [])
        let templateData = try JSONEncoder().encode(template)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: templateData) as? [String: Any])
        payload["tools"] = [
            "document_read",
            "document_ocr",
            "document_render",
            "document_export_pdf",
            "document_write",
            "read_document",
            "edit_pdf",
            "reconstruct_document",
        ]

        let legacyData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(CapabilityLease.self, from: legacyData)

        XCTAssertEqual(decoded.tools, Self.legacyDocumentCapabilities)

        let freshLeases = [
            CapabilityLease.worker(workspaceAccess: .readOnly),
            CapabilityLease.worker(workspaceAccess: .readWrite),
            CapabilityLease.coordinator(workspaceAccess: .readOnly),
            CapabilityLease.coordinator(workspaceAccess: .readWrite),
        ]
        for lease in freshLeases {
            XCTAssertTrue(lease.tools.isDisjoint(with: Self.legacyDocumentCapabilities))
        }
    }

    func testExactDocumentCapabilitiesEncodeWithConcreteToolNames() throws {
        let expectedNames: Set<String> = [
            "read_pdf",
            "read_docx", "continue_docx_read",
            "read_pptx", "continue_pptx_read",
            "read_xlsx", "continue_xlsx_read",
            "read_html", "continue_html_read",
            "read_epub", "continue_epub_read",
            "ocr_pdf", "pdf_render_page",
            "docx_export_pdf", "pptx_export_pdf", "xlsx_export_pdf", "html_export_pdf",
            "docx_create_document", "docx_add_paragraph", "docx_set_paragraph_text",
            "docx_add_run", "docx_set_run_bold", "docx_set_run_italic",
            "docx_set_run_underline", "docx_add_table", "docx_set_table_cell_text",
            "docx_add_picture", "docx_set_header_paragraph_text",
            "docx_set_footer_paragraph_text", "docx_set_section_orientation",
            "docx_set_section_top_margin", "docx_set_section_bottom_margin",
            "docx_set_section_left_margin", "docx_set_section_right_margin",
            "pptx_create_presentation", "pptx_add_slide", "pptx_set_shape_text",
            "pptx_add_shape", "pptx_add_picture", "pptx_add_table",
            "pptx_set_table_cell_text", "xlsx_create_workbook", "xlsx_create_sheet",
            "xlsx_set_sheet_title", "xlsx_set_cell_value", "xlsx_append_row",
        ]
        let exactCapabilities = Self.documentCapabilities

        XCTAssertEqual(Set(exactCapabilities.map(\.rawValue)), expectedNames)
        for capability in exactCapabilities {
            let encoded = try JSONEncoder().encode(capability)
            XCTAssertEqual(try JSONDecoder().decode(ToolCapability.self, from: encoded), capability)
        }
    }

    func testExactImageCapabilitiesEncodeWithConcreteToolNames() throws {
        let capabilities = ToolCapability.exactImageMutationCapabilities

        XCTAssertEqual(
            Set(capabilities.map(\.rawValue)),
            ["generate_image", "edit_image"])
        for capability in capabilities {
            let encoded = try JSONEncoder().encode(capability)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    ToolCapability.self,
                    from: encoded),
                capability)
        }
    }

    func testExactDocumentToolsDeriveIndependentActions() {
        let actions: [String: String] = [
            "inspect_pdf": "document.inspect.pdf",
            "read_pdf": "document.read.pdf",
            "read_docx": "document.read.docx",
            "continue_docx_read": "document.read.docx.continue",
            "read_pptx": "document.read.pptx",
            "continue_pptx_read": "document.read.pptx.continue",
            "read_xlsx": "document.read.xlsx",
            "continue_xlsx_read": "document.read.xlsx.continue",
            "read_html": "document.read.html",
            "continue_html_read": "document.read.html.continue",
            "read_epub": "document.read.epub",
            "continue_epub_read": "document.read.epub.continue",
            "ocr_pdf": "document.ocr.pdf",
            "pdf_render_page": "document.render.pdf.page",
            "docx_export_pdf": "document.export.docx.pdf",
            "pptx_export_pdf": "document.export.pptx.pdf",
            "xlsx_export_pdf": "document.export.xlsx.pdf",
            "html_export_pdf": "document.export.html.pdf",
            "compile_latex": "document.compile.latex",
        ]
        for (toolName, action) in actions {
            let intent = PermissionIntent.derived(
                toolName: toolName,
                sideEffect: .exec,
                touchedPaths: ["document"],
                risksNetwork: false)
            XCTAssertEqual(intent.action, action, toolName)
        }
        for capability in ToolCapability.exactDocumentWriteCapabilities {
            let intent = PermissionIntent.derived(
                toolName: capability.rawValue,
                sideEffect: .exec,
                touchedPaths: ["document"],
                risksNetwork: false)
            XCTAssertEqual(
                intent.action,
                "document.write."
                    + capability.rawValue.replacingOccurrences(of: "_", with: "."),
                capability.rawValue)
        }
    }

    func testCapabilityLeaseCodableRoundTrip() throws {
        let lease = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_1"),
            taskID: TaskID(rawValue: "task_1"),
            tools: [.readWorkspace, .delegateTask],
            communication: .anyAgentInThread,
            delegation: .granted(DelegationBudget(maxTasks: 2, maxDepth: 1)))

        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(CapabilityLease.self, from: data)

        XCTAssertEqual(decoded, lease)
    }
}
