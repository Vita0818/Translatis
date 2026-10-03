import Foundation
import IntatisCore
import IntatisProtocol
@testable import IntatisTools
import XCTest

#if canImport(CoreGraphics) && canImport(PDFKit)
import CoreGraphics
import CoreText
import PDFKit
#endif

private actor RecordingDocumentBackendRunner: DocumentBackendRunner {
    private let result: ShellResult
    private var invocations: [DocumentBackendInvocation] = []

    init(result: ShellResult) {
        self.result = result
    }

    func run(
        _ invocation: DocumentBackendInvocation,
        cwd: URL
    ) async throws -> ShellResult {
        invocations.append(invocation)
        return result
    }

    func invocationCount() -> Int {
        invocations.count
    }
}

final class DocumentToolsIntegrationTests: XCTestCase {
    private let fileManager = FileManager.default

    func testShippingDocumentRuntimeSelectionNeverFallsBackToUserManagedRoot() {
        let bundled = URL(fileURLWithPath: "/Applications/Intatis.app/Contents/Resources/DocumentRuntime/arm64")
        let userManaged = URL(fileURLWithPath: "/Users/example/Library/Application Support/Intatis/document-runtime")

        XCTAssertEqual(
            selectDocumentRuntimeRoot(
                bundledRoot: bundled,
                userManagedRoot: userManaged,
                requiresBundledRuntime: true),
            bundled)
        XCTAssertNil(selectDocumentRuntimeRoot(
            bundledRoot: nil,
            userManagedRoot: userManaged,
            requiresBundledRuntime: true))
        XCTAssertEqual(
            selectDocumentRuntimeRoot(
                bundledRoot: nil,
                userManagedRoot: userManaged,
                requiresBundledRuntime: false),
            userManaged)
    }

    func testInstalledDocumentRuntimeExactDOCXChainWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 to run the installed document runtime smoke")
        }
        guard let runtime = intatisDocumentRuntimeRoot(),
              let libreOffice = intatisLibreOfficeRuntimeAppURL()?
                  .appendingPathComponent("Contents/MacOS/soffice"),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path),
              fileManager.isExecutableFile(atPath: libreOffice.path) else {
            throw XCTSkip("fixed Python or LibreOffice runtime is not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let context = ToolContext(
            workspaceRoot: workspace,
            documentBackend: DocumentBackendProcessRunner(timeoutSeconds: 300))
        let registry = ToolRegistry.standard()
        let marker = "INTATIS EXACT DOCUMENT RUNTIME 73921"

        let create = try XCTUnwrap(registry.registration(named: "docx_create_document"))
        _ = try await create.execute(
            ToolArgs(raw: #"{"output_path":"empty.docx"}"#),
            in: context)
        let emptyDigest = try DocumentInputFile.freeze(
            path: "empty.docx",
            expectedFormat: .docx,
            workspace: workspace).identity.sha256
        let addParagraph = try XCTUnwrap(registry.registration(named: "docx_add_paragraph"))
        let write = try await addParagraph.execute(
            ToolArgs(raw: """
            {"input_path":"empty.docx","expected_source_sha256":"\(emptyDigest)",
             "output_path":"runtime-smoke.docx","text":"\(marker)"}
            """),
            in: context)
        XCTAssertTrue(write.text.contains(#""operation":"docx_add_paragraph""#), write.text)

        let read = try await ReadDOCXTool().execute(
            ToolArgs(raw: #"{"path":"runtime-smoke.docx"}"#),
            in: context)
        XCTAssertTrue(read.text.contains(marker), read.text)

        let docxDigest = try DocumentInputFile.freeze(
            path: "runtime-smoke.docx",
            expectedFormat: .docx,
            workspace: workspace).identity.sha256
        let export = try XCTUnwrap(registry.registration(named: "docx_export_pdf"))
        let exported = try await export.execute(
            ToolArgs(raw: """
            {"input_path":"runtime-smoke.docx","expected_source_sha256":"\(docxDigest)",
             "output_path":"runtime-smoke.pdf"}
            """),
            in: context)
        XCTAssertTrue(exported.text.contains(#""libreoffice":"26.8.0.0.beta1""#), exported.text)

        let pdfDigest = try DocumentInputFile.freeze(
            path: "runtime-smoke.pdf",
            expectedFormat: .pdf,
            workspace: workspace).identity.sha256
        _ = try await PDFRenderPageTool().execute(
            ToolArgs(raw: """
            {"input_path":"runtime-smoke.pdf","expected_source_sha256":"\(pdfDigest)",
             "page":1,"output_path":"runtime-page.png"}
            """),
            in: context)
        XCTAssertTrue(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("runtime-page.png").path))
    }


    func testInstalledDocumentRuntimeReadsUserCorpusWhenConfigured() async throws {
        guard let rawRoot = ProcessInfo.processInfo.environment[
            "INTATIS_REAL_DOCUMENT_CORPUS_ROOT"],
              !rawRoot.isEmpty else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_CORPUS_ROOT to run the external document corpus smoke")
        }
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path) else {
            throw XCTSkip("fixed Python document runtime is not installed")
        }

        let sourceRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
        let sourceFiles = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        let xlsxFiles = sourceFiles.filter { $0.pathExtension.lowercased() == "xlsx" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        let pptxFiles = sourceFiles.filter { $0.pathExtension.lowercased() == "pptx" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        XCTAssertFalse(xlsxFiles.isEmpty, "corpus must contain at least one XLSX")
        XCTAssertGreaterThanOrEqual(pptxFiles.count, 3, "corpus must contain the three lecture PPTX files")
        guard let xlsx = xlsxFiles.first, pptxFiles.count >= 3 else { return }

        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let context = ToolContext(
            workspaceRoot: workspace,
            documentBackend: DocumentBackendProcessRunner(timeoutSeconds: 300))

        let xlsxName = "corpus.xlsx"
        try fileManager.copyItem(
            at: xlsx,
            to: workspace.appendingPathComponent(xlsxName))
        let xlsxRead = try await ReadXLSXTool().execute(
            ToolArgs(raw: #"{"path":"corpus.xlsx","maxCharacters":500000}"#),
            in: context)
        try assertNonemptyMarkdown(xlsxRead, operation: "read_xlsx")

        for (index, source) in pptxFiles.prefix(3).enumerated() {
            let name = "corpus-\(index + 1).pptx"
            try fileManager.copyItem(
                at: source,
                to: workspace.appendingPathComponent(name))
            let read = try await ReadPPTXTool().execute(
                ToolArgs(raw: "{\"path\":\"\(name)\",\"maxCharacters\":500000}"),
                in: context)
            try assertNonemptyMarkdown(read, operation: "read_pptx")
        }
    }

    func testInstalledDocumentRuntimeOCRWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE"] == "1" else {
            throw XCTSkip(
                "set INTATIS_REAL_DOCUMENT_RUNTIME_SMOKE=1 to run the installed document runtime smoke")
        }
        #if canImport(CoreGraphics) && canImport(PDFKit)
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path) else {
            throw XCTSkip("fixed Python document runtime is not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent(
            ".intatis-document-stage-runtime-smoke",
            isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        let input = stage.appendingPathComponent("ocr-source.pdf")
        try makeOCRTextPDF(at: input)
        let runner = DocumentBackendProcessRunner(timeoutSeconds: 300)
        let context = ToolContext(workspaceRoot: workspace, documentBackend: runner)

        let digest = try DocumentInputFile.freeze(
            path: ".intatis-document-stage-runtime-smoke/ocr-source.pdf",
            expectedFormat: .pdf,
            workspace: workspace).identity.sha256
        let observation = try await OCRPDFTool().execute(
            ToolArgs(raw: """
            {"input_path":".intatis-document-stage-runtime-smoke/ocr-source.pdf",
             "expected_source_sha256":"\(digest)"}
            """),
            in: context)
        let observationJSON = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(observation.text.utf8))
        guard case .object(let root) = observationJSON,
              case .object(let result)? = root["result"],
              case .string(let recognized)? = result["markdown"] else {
            XCTFail("OCR observation did not contain result.markdown")
            return
        }
        let normalized = recognized.uppercased().filter { $0.isLetter || $0.isNumber }
        XCTAssertTrue(normalized.contains("INTATISOCR48291"), observation.text)
        #else
        throw XCTSkip("real document runtime smoke requires Apple PDF frameworks")
        #endif
    }

    func testStandardRegistryExposesSplitDocumentReaders() throws {
        let registry = ToolRegistry.standard()
        let names = Set(registry.descriptors().map(\.name))

        XCTAssertTrue([
            "inspect_pdf",
            "read_pdf",
            "read_docx",
            "continue_docx_read",
            "read_pptx",
            "continue_pptx_read",
            "read_xlsx",
            "continue_xlsx_read",
            "read_html",
            "continue_html_read",
            "read_epub",
            "continue_epub_read",
            "ocr_pdf",
            "pdf_render_page",
            "docx_export_pdf",
            "pptx_export_pdf",
            "xlsx_export_pdf",
            "html_export_pdf",
            "docx_create_document",
            "pptx_create_presentation",
            "xlsx_create_workbook",
        ].allSatisfy(names.contains))
        XCTAssertFalse(names.contains("read_document"))
        XCTAssertFalse(names.contains("document_read"))
        XCTAssertFalse(names.contains("edit_pdf_pages"))
        XCTAssertFalse(names.contains("reconstruct_document_image"))
        XCTAssertFalse(names.contains("document_ocr"))
        XCTAssertFalse(names.contains("document_render"))
        XCTAssertFalse(names.contains("document_export_pdf"))
        XCTAssertFalse(names.contains("document_write"))
        XCTAssertEqual(registry.registryVersion, "intatis.standard.v5")
    }

    func testDescriptorsPermissionsAndTouchedPathsAreExact() throws {
        let registry = ToolRegistry.standard()
        XCTAssertEqual(InspectPDFTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(ReadPDFTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(ReadDOCXTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(ContinueDOCXReadTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(OCRPDFTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(PDFRenderPageTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(OCRPDFTool.canonicalPermission, "document.ocr")
        XCTAssertEqual(PDFRenderPageTool.canonicalPermission, "document.render")
        XCTAssertEqual(
            registry.registration(named: "docx_export_pdf")?.canonicalPermission,
            "document.export.pdf")
        XCTAssertEqual(
            registry.registration(named: "docx_add_picture")?.canonicalPermission,
            "document.write")

        let readIntent = ReadDOCXTool().permissionIntent(
            ToolArgs(raw: #"{"path":"report.docx"}"#),
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertTrue(readIntent.isStructuredReadOnlyExecution)
        XCTAssertTrue(readIntent.isReadOnlyWorkspaceCompatible)
        XCTAssertEqual(readIntent.dataEffects, [.read, .execute])
        XCTAssertEqual(readIntent.replayPolicy, .safeToReplay)

        let ocrIntent = OCRPDFTool().permissionIntent(
            ToolArgs(raw: #"{"input_path":"scan.pdf","expected_source_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#),
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(ocrIntent.action, "document.ocr.pdf")
        XCTAssertEqual(ocrIntent.replayPolicy, .doNotReplay)

        let digest = String(repeating: "a", count: 64)
        let renderArgs = ToolArgs(raw: """
        {"input_path":"source.pdf","expected_source_sha256":"\(digest)",
         "page":1,"output_path":"preview.png"}
        """)
        let render = PDFRenderPageTool()
        XCTAssertEqual(render.touchedPaths(renderArgs), ["source.pdf", "preview.png"])
        let renderIntent = render.permissionIntent(
            renderArgs,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(renderIntent.action, "document.render.pdf.page")
        XCTAssertEqual(renderIntent.dataEffects, [.read, .execute, .mutate])
        XCTAssertEqual(renderIntent.risks, [.processExecution, .workspaceMutation])
        XCTAssertEqual(renderIntent.replayPolicy, .doNotReplay)

        let picture = try XCTUnwrap(registry.registration(named: "docx_add_picture"))
        let pictureArgs = ToolArgs(raw: """
        {"input_path":"report.docx","expected_source_sha256":"\(digest)",
         "output_path":"with-image.docx","path":"assets/chart.png"}
        """)
        XCTAssertEqual(
            picture.touchedPaths(pictureArgs),
            ["report.docx", "assets/chart.png", "with-image.docx"])
        let pictureIntent = picture.permissionIntent(
            pictureArgs,
            workspaceRoot: URL(fileURLWithPath: "/workspace"))
        XCTAssertEqual(pictureIntent.action, "document.write.docx.add.picture")
        XCTAssertEqual(
            pictureIntent.resources,
            [
                PermissionResource(kind: .workspacePath, value: "report.docx", access: .readOnly),
                PermissionResource(kind: .workspacePath, value: "assets/chart.png", access: .readOnly),
                PermissionResource(kind: .workspacePath, value: "with-image.docx", access: .readWrite),
            ])

        let htmlExport = try XCTUnwrap(registry.registration(named: "html_export_pdf"))
        let htmlArgs = ToolArgs(raw: """
        {"input_path":"site/index.html","expected_source_sha256":"\(digest)",
         "local_asset_paths":["site/logo.png"],"output_path":"site/index.pdf"}
        """)
        XCTAssertEqual(
            htmlExport.touchedPaths(htmlArgs),
            ["site/index.html", "site/logo.png", "site/index.pdf"])
        XCTAssertEqual(
            htmlExport.permissionIntent(
                htmlArgs,
                workspaceRoot: URL(fileURLWithPath: "/workspace")).action,
            "document.export.html.pdf")
    }


    func testReadPDFReturnsTypedOCRRequiredForImageOnlyPDF() async throws {
        #if canImport(CoreGraphics) && canImport(PDFKit)
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("scan.pdf")
        try makeImageOnlyPDF(at: input)

        do {
            _ = try await ReadPDFTool().execute(
                ToolArgs(raw: #"{"path":"scan.pdf"}"#),
                in: ToolContext(workspaceRoot: workspace))
            XCTFail("image-only PDF should require explicit OCR")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .ocrRequired)
        }
        #else
        throw XCTSkip("PDFKit integration requires Apple PDF frameworks")
        #endif
    }

    func testInspectPDFReturnsHostIdentityUsableByExplicitOCRContract() async throws {
        #if canImport(CoreGraphics) && canImport(PDFKit)
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("scan.pdf")
        try makeImageOnlyPDF(at: input)

        let observation = try await InspectPDFTool().execute(
            ToolArgs(raw: #"{"path":"scan.pdf"}"#),
            in: ToolContext(workspaceRoot: workspace))
        let payload = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(observation.text.utf8))
        guard case .object(let fields) = payload,
              case .string(let sourceSHA256)? = fields["source_sha256"],
              case .number(let sourceByteCount)? = fields["source_byte_count"],
              case .number(let pageCount)? = fields["page_count"],
              case .bool(true)? = fields["requires_ocr"] else {
            return XCTFail("inspect_pdf did not return the OCR identity bridge")
        }
        XCTAssertEqual(sourceSHA256.count, 64)
        XCTAssertGreaterThan(sourceByteCount, 0)
        XCTAssertEqual(pageCount, 1)
        XCTAssertNoThrow(try OCRPDFTool().validateArguments(ToolArgs(raw: """
        {"input_path":"scan.pdf","expected_source_sha256":"\(sourceSHA256)"}
        """)))
        #else
        throw XCTSkip("PDFKit integration requires Apple PDF frameworks")
        #endif
    }

    func testPDFRenderCommitsOnePNGWithoutLeakingStageDirectory() async throws {
        #if canImport(CoreGraphics) && canImport(PDFKit)
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("source.pdf")
        try makeImageOnlyPDF(at: input)
        let digest = try DocumentInputFile.freeze(
            path: "source.pdf",
            expectedFormat: .pdf,
            workspace: workspace).identity.sha256

        let observation = try await PDFRenderPageTool().execute(
            ToolArgs(raw: """
            {"input_path":"source.pdf","expected_source_sha256":"\(digest)",
             "page":1,"output_path":"preview.png"}
            """),
            in: ToolContext(workspaceRoot: workspace))

        XCTAssertEqual(observation.changedFiles, ["preview.png"])
        XCTAssertTrue(fileManager.fileExists(
            atPath: workspace.appendingPathComponent("preview.png").path))
        let rootChildren = try fileManager.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(rootChildren.contains { $0.hasPrefix(".intatis-document-stage-") })
        #else
        throw XCTSkip("PDFKit integration requires Apple PDF frameworks")
        #endif
    }

    func testDocumentReaderMapsFixedBackendMissingEnvelopeToTypedFailure() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try Data("not parsed by the fake".utf8).write(
            to: workspace.appendingPathComponent("report.docx"))
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: #"{"schema_version":1,"ok":false,"code":"backend_missing","summary":"private path","engine_versions":{},"warnings":[]}"#,
            stderr: "",
            exitCode: 0))

        do {
            _ = try await ReadDOCXTool().execute(
                ToolArgs(raw: #"{"path":"report.docx"}"#),
                in: ToolContext(workspaceRoot: workspace, documentBackend: backend))
            XCTFail("missing backend should fail")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .backendMissing)
            XCTAssertFalse(error.summary.contains("private path"))
        }
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testDocumentReaderPropagatesBackendTruncation() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        try Data("not parsed by the fake".utf8).write(
            to: workspace.appendingPathComponent("report.docx"))
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: #"{"schema_version":1,"ok":true,"engine_versions":{},"result":{"format":"docx","markdown":"bounded","truncated":true,"navigation":{"source_element_count":4,"next":{"element":2,"character_offset":0},"landmarks":[{"kind":"section","title":"Second","element":2}],"landmarks_truncated":false}},"warnings":[]}"#,
            stderr: "",
            exitCode: 0))

        let observation = try await ReadDOCXTool().execute(
            ToolArgs(raw: #"{"path":"report.docx"}"#),
            in: ToolContext(workspaceRoot: workspace, documentBackend: backend))
        XCTAssertTrue(observation.truncated)
        XCTAssertTrue(observation.text.contains(#""truncated":true"#), observation.text)
        XCTAssertTrue(observation.text.contains(#""next_cursor":"#), observation.text)
        XCTAssertTrue(observation.text.contains(#""source_sha256":"#), observation.text)
    }

    func testInstalledDoclingReaderReturnsSourceBoundContinuationAndLandmarkCursors() async throws {
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path) else {
            throw XCTSkip("fixed Docling runtime is not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("navigation.html")
        try Data("""
        <html><body>
        <h1>Alpha</h1><p>11111111111111111111</p>
        <h2>Beta</h2><p>22222222222222222222</p>
        </body></html>
        """.utf8).write(to: input)
        let context = ToolContext(
            workspaceRoot: workspace,
            documentBackend: DocumentBackendProcessRunner(timeoutSeconds: 300))

        let first = try await ReadHTMLTool().execute(
            ToolArgs(raw: #"{"path":"navigation.html","maxCharacters":12}"#),
            in: context)
        let firstJSON = try JSONDecoder().decode(JSONValue.self, from: Data(first.text.utf8))
        guard case .object(let firstRoot) = firstJSON,
              case .object(let firstResult)? = firstRoot["result"],
              case .string(let sourceSHA256)? = firstResult["source_sha256"],
              case .object(let navigation)? = firstResult["navigation"],
              case .string(let nextCursor)? = navigation["next_cursor"],
              case .array(let landmarks)? = navigation["landmarks"] else {
            return XCTFail("initial Docling read did not return its identity/navigation envelope")
        }
        XCTAssertEqual(sourceSHA256.count, 64)
        XCTAssertTrue(first.truncated)

        let continued = try await ContinueHTMLReadTool().execute(
            ToolArgs(raw: "{\"path\":\"navigation.html\",\"cursor\":\"\(nextCursor)\",\"maxCharacters\":10}"),
            in: context)
        XCTAssertTrue(continued.text.contains("1111111111"), continued.text)

        let betaCursor = try XCTUnwrap(landmarks.compactMap { value -> String? in
            guard case .object(let landmark) = value,
                  case .string(let title)? = landmark["title"],
                  title.contains("Beta"),
                  case .string(let cursor)? = landmark["cursor"] else { return nil }
            return cursor
        }.first)
        let jumped = try await ContinueHTMLReadTool().execute(
            ToolArgs(raw: "{\"path\":\"navigation.html\",\"cursor\":\"\(betaCursor)\",\"maxCharacters\":100}"),
            in: context)
        XCTAssertTrue(jumped.text.contains("Beta"), jumped.text)
        XCTAssertTrue(jumped.text.contains("22222222222222222222"), jumped.text)

        try Data("<html><body>changed</body></html>".utf8).write(to: input)
        do {
            _ = try await ContinueHTMLReadTool().execute(
                ToolArgs(raw: "{\"path\":\"navigation.html\",\"cursor\":\"\(nextCursor)\"}"),
                in: context)
            XCTFail("a cursor must not continue against changed source bytes")
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, .outputConflict)
        }
    }

    func testExactExportAndWritePrecommitConflictsDoNotClobberOrInvokeBackend() async throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source.html")
        try Data("<html><body>source</body></html>".utf8).write(to: source)
        let digest = try DocumentInputFile.freeze(
            path: "source.html",
            expectedFormat: .html,
            workspace: workspace).identity.sha256
        let originalPDF = Data("existing-pdf".utf8)
        let originalDOCX = Data("existing-docx".utf8)
        let pdfOutput = workspace.appendingPathComponent("output.pdf")
        let docxOutput = workspace.appendingPathComponent("output.docx")
        try originalPDF.write(to: pdfOutput)
        try originalDOCX.write(to: docxOutput)
        let backend = RecordingDocumentBackendRunner(result: ShellResult(
            stdout: "",
            stderr: "unexpected invocation",
            exitCode: 99))
        let context = ToolContext(workspaceRoot: workspace, documentBackend: backend)
        let registry = ToolRegistry.standard()
        let htmlExport = try XCTUnwrap(registry.registration(named: "html_export_pdf"))
        let docxCreate = try XCTUnwrap(registry.registration(named: "docx_create_document"))

        await assertDocumentError(.outputConflict) {
            _ = try await htmlExport.execute(
                ToolArgs(raw: """
                {"input_path":"source.html","expected_source_sha256":"\(digest)",
                 "output_path":"output.pdf"}
                """),
                in: context)
        }
        await assertDocumentError(.outputConflict) {
            _ = try await docxCreate.execute(
                ToolArgs(raw: #"{"output_path":"output.docx"}"#),
                in: context)
        }

        XCTAssertEqual(try Data(contentsOf: pdfOutput), originalPDF)
        XCTAssertEqual(try Data(contentsOf: docxOutput), originalDOCX)
        let invocationCount = await backend.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testDocumentProcessLeaseNarrowsBroadWorkspaceAuthorityToReviewedInputAndStage() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("source.docx")
        try Data("input".utf8).write(to: input)
        let outputDirectory = workspace.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        let stage = outputDirectory.appendingPathComponent(
            ".intatis-document-stage-test",
            isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        let durable = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])

        let narrowed = try documentProcessLease(
            durable,
            workspace: workspace,
            reviewedReadablePaths: ["source.docx"],
            reviewedWritablePaths: ["out/result.pdf"],
            internalWritablePaths: ["out/.intatis-document-stage-test"])

        XCTAssertEqual(narrowed.access, .readWrite)
        XCTAssertEqual(
            Set(narrowed.allowedPathRules.map(\.pattern)),
            ["source.docx", "out/.intatis-document-stage-test"])
        XCTAssertFalse(narrowed.allowedPathRules.contains { $0.pattern == "." })
        XCTAssertGreaterThan(
            DocumentBackendProcessRunner.maximumGeneratedFileBytes,
            8 * 1_024 * 1_024)
        XCTAssertEqual(
            DocumentBackendProcessRunner.maximumResidentBytes,
            2 * 1_024 * 1_024 * 1_024)

        #if os(macOS)
        let profile = try macOSSandboxProfile(
            workspace: workspace,
            runtime: fileManager.temporaryDirectory,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: narrowed,
            forcedReadOnlyWorkspaceRoots: [input],
            networkAccess: .denied)
        XCTAssertTrue(profile.contains("source\\\\.docx"))
        XCTAssertTrue(profile.contains("intatis-document-stage-test"))
        XCTAssertTrue(profile.contains("(deny file-write* (subpath \""))
        XCTAssertTrue(profile.contains("(deny network*)"))
        #endif
    }

    func testDocumentBackendStopsWhenProcessTreeExceedsResidentMemoryBudget() async throws {
        #if os(macOS) || os(Linux)
        guard let runtime = intatisDocumentRuntimeRoot(),
              fileManager.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/python3").path) else {
            throw XCTSkip("fixed Python document runtime is not installed")
        }
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let runner = DocumentBackendProcessRunner(
            timeoutSeconds: 10,
            maximumResidentBytes: 8 * 1_024 * 1_024)
        let invocation = DocumentBackendInvocation(
            executable: .pythonRuntime,
            arguments: [
                "-I", "-B", "-c",
                "import time; payload = bytearray(64 * 1024 * 1024); time.sleep(5)",
            ],
            environment: [:],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])

        do {
            _ = try await runner.run(invocation, cwd: workspace)
            XCTFail("resident-memory limit should stop the document process")
        } catch let error as IntatisError {
            guard case .io(let message) = error else {
                return XCTFail("unexpected resident-memory error: \(error)")
            }
            XCTAssertTrue(message.contains("resident-memory budget"), message)
        }
        #else
        throw XCTSkip("managed document processes are unavailable on this platform")
        #endif
    }

    func testDocumentProcessLeaseRejectsLiteralPathThatWouldBecomeAGlob() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let durable = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])

        XCTAssertThrowsError(try documentProcessLease(
            durable,
            workspace: workspace,
            reviewedReadablePaths: ["report?.docx"],
            reviewedWritablePaths: [],
            internalWritablePaths: []))
    }

    func testDocumentVersionProbeCanDenyAllWorkspaceAccess() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let durable = WorkspaceLease(
            rootPath: canonicalWorkspace.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: ".")],
            deniedPatterns: [])

        let narrowed = try documentProcessLease(
            durable,
            workspace: canonicalWorkspace,
            reviewedReadablePaths: [],
            reviewedWritablePaths: [],
            internalWritablePaths: [])

        XCTAssertTrue(narrowed.allowedPathRules.isEmpty)
        XCTAssertNoThrow(try effectiveWorkspaceLease(
            narrowed,
            workspace: canonicalWorkspace,
            allowEmptyPathRules: true))
        XCTAssertThrowsError(try effectiveWorkspaceLease(
            narrowed,
            workspace: canonicalWorkspace))

        #if os(macOS)
        let profile = try macOSSandboxProfile(
            workspace: canonicalWorkspace,
            runtime: fileManager.temporaryDirectory,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: narrowed,
            networkAccess: .denied)
        XCTAssertTrue(profile.contains("(deny file-read-data file-map-executable file-write*"))
        XCTAssertTrue(profile.contains("(deny network*)"))
        #endif
    }

    #if os(macOS)
    func testLibreOfficeSandboxAllowsOnlyInvocationPrivateUnixSocket() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let socketRoot = URL(
            fileURLWithPath: "/private/tmp/intatis-lo-0123456789ab",
            isDirectory: true)
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly,
            allowedPathRules: [],
            deniedPatterns: [])

        let profile = try macOSSandboxProfile(
            workspace: workspace,
            runtime: fileManager.temporaryDirectory,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: lease,
            processCompatibility: .libreOfficeHeadless,
            libreOfficeSocketRoot: socketRoot,
            networkAccess: .denied)

        XCTAssertTrue(profile.contains(#"(subpath "/private/tmp/intatis-lo-0123456789ab")"#))
        XCTAssertTrue(profile.contains("(local unix-socket (path-regex"))
        XCTAssertTrue(profile.contains("(remote unix-socket (path-regex"))
        XCTAssertTrue(profile.contains("/OSL_PIPE_[^/]+$"))
        XCTAssertTrue(profile.contains("(deny network* (local ip) (remote ip))"))
        XCTAssertFalse(profile.contains("(allow network*)"))
    }
    #endif

    func testDocumentGeneratedOutputBudgetCountsAggregateFilesAndEntries() throws {
        let workspace = try makeWorkspace()
        defer { try? fileManager.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("generated", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data(repeating: 0x41, count: 4_096).write(
            to: stage.appendingPathComponent("one.bin"))
        try Data(repeating: 0x42, count: 4_096).write(
            to: stage.appendingPathComponent("two.bin"))
        try fileManager.createDirectory(
            at: stage.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: false)

        XCTAssertFalse(documentGeneratedOutputExceedsBudget(
            roots: [stage],
            maximumBytes: 16_384,
            maximumEntries: 3))
        XCTAssertTrue(documentGeneratedOutputExceedsBudget(
            roots: [stage],
            maximumBytes: 6_000,
            maximumEntries: 3))
        XCTAssertTrue(documentGeneratedOutputExceedsBudget(
            roots: [stage],
            maximumBytes: 16_384,
            maximumEntries: 2))
    }

    private func makeWorkspace() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "intatis-document-tool-integration-\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func assertNonemptyMarkdown(
        _ observation: ToolObservation,
        operation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(observation.text.utf8))
        guard case .object(let root) = value,
              root["operation"] == .string(operation),
              case .object(let result)? = root["result"],
              case .string(let markdown)? = result["markdown"] else {
            return XCTFail("missing bounded Markdown result", file: file, line: line)
        }
        XCTAssertGreaterThan(markdown.trimmingCharacters(in: .whitespacesAndNewlines).count, 20)
        XCTAssertFalse(markdown.contains("data:image/"), "reader must not return embedded image data")
    }

    private func assertDocumentError(
        _ expected: DocumentToolErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected.rawValue)", file: file, line: line)
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, expected, error.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    #if canImport(CoreGraphics) && canImport(PDFKit)
    private func makeOCRTextPDF(at url: URL) throws {
        let width = 2_400
        let height = 800
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 3)
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica-Bold" as CFString, 180, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "INTATIS OCR 48291",
            attributes: attributes))
        bitmap.textPosition = CGPoint(x: 120, y: 300)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage(),
              let consumer = CGDataConsumer(url: url as CFURL) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 4)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 200)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 5)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    private func makeImageOnlyPDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 144, height: 96)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "DocumentToolsIntegrationTests", code: 2)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 12, y: 12, width: 120, height: 72))
        context.endPDFPage()
        context.closePDF()
    }
    #endif
}
