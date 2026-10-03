import Foundation
import IntatisCore
import IntatisProtocol
@testable import IntatisTools
import XCTest

private actor FixedBackendRecordingRunner: DocumentBackendRunner {
    private var values: [DocumentBackendInvocation] = []

    func run(
        _ invocation: DocumentBackendInvocation,
        cwd: URL
    ) async throws -> ShellResult {
        values.append(invocation)
        if invocation.executable == .tectonic,
           invocation.arguments == ["--version"] {
            return ShellResult(stdout: "tectonic 0.15.0\n", stderr: "", exitCode: 0)
        }
        if invocation.executable == .libreOffice,
           invocation.arguments == ["--version"] {
            return ShellResult(
                stdout: "LibreOfficeDev 26.8.0.0.beta1 test-build\n",
                stderr: "",
                exitCode: 0)
        }
        if invocation.executable == .tectonic,
           let outputIndex = invocation.arguments.firstIndex(of: "--outdir"),
           invocation.arguments.indices.contains(outputIndex + 1),
           let inputPath = invocation.arguments.last {
            let outputDirectory = URL(
                fileURLWithPath: invocation.arguments[outputIndex + 1],
                isDirectory: true)
            let input = URL(fileURLWithPath: inputPath)
            let output = outputDirectory
                .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("pdf")
            try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: output)
            return ShellResult(stdout: "compiled\n", stderr: "", exitCode: 0)
        }
        guard invocation.executable == .libreOffice,
              let convertIndex = invocation.arguments.firstIndex(of: "--convert-to"),
              invocation.arguments.indices.contains(convertIndex + 1),
              let outputIndex = invocation.arguments.firstIndex(of: "--outdir"),
              invocation.arguments.indices.contains(outputIndex + 1),
              let inputPath = invocation.arguments.last else {
            return ShellResult(stdout: "", stderr: "unsupported invocation", exitCode: 2)
        }
        let outputDirectory = URL(
            fileURLWithPath: invocation.arguments[outputIndex + 1],
            isDirectory: true)
        let input = URL(fileURLWithPath: inputPath)
        let format = invocation.arguments[convertIndex + 1]
        if format.hasPrefix("xlsx:") {
            try FileManager.default.copyItem(
                at: input,
                to: outputDirectory.appendingPathComponent(input.lastPathComponent))
        } else if format.hasPrefix("pdf:") {
            let output = outputDirectory
                .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("pdf")
            try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: output)
        } else {
            return ShellResult(stdout: "", stderr: "unsupported format", exitCode: 2)
        }
        return ShellResult(stdout: "converted\n", stderr: "", exitCode: 0)
    }

    func invocations() -> [DocumentBackendInvocation] {
        values
    }
}

final class DocumentFixedBackendsTests: XCTestCase {
    func testLibreOfficePreviewForcesVerifiedStagedInputReadOnly() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let input = stage.appendingPathComponent("report.docx")
        try Data("docx fixture".utf8).write(to: input)
        let preview = stage.appendingPathComponent("preview.pdf")
        let runner = FixedBackendRecordingRunner()

        _ = try await LibreOfficeDocumentBackend.exportDOCXPDF(
            actualInput: input,
            reviewedInputPath: "report.docx",
            stagedPDF: preview,
            reviewedOutputPath: "result.docx",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[1].internalReadOnlyWorkspacePaths, [input.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        let profile = stage.appendingPathComponent(
            "libreoffice-profile/user/registrymodifications.xcu")
        let configuration = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(configuration.contains("DisableMacrosExecution"))
        XCTAssertTrue(configuration.contains("DisableActiveContent"))
    }

    func testLibreOfficeExportKeepsExternalInputOnReviewedReadPath() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let input = workspace.appendingPathComponent("report.docx")
        try Data("docx fixture".utf8).write(to: input)
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let preview = stage.appendingPathComponent("preview.pdf")
        let runner = FixedBackendRecordingRunner()

        _ = try await LibreOfficeDocumentBackend.exportDOCXPDF(
            actualInput: input,
            reviewedInputPath: "report.docx",
            stagedPDF: preview,
            reviewedOutputPath: "result.pdf",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[1].readableWorkspacePaths, ["report.docx"])
        XCTAssertTrue(invocations[1].internalReadOnlyWorkspacePaths.isEmpty)
    }

    func testXLSXExportUsesOnlyTheFixedCalcPDFFilter() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let input = stage.appendingPathComponent("source.xlsx")
        let preview = stage.appendingPathComponent("preview.pdf")
        try Data("xlsx fixture".utf8).write(to: input)
        let runner = FixedBackendRecordingRunner()

        _ = try await LibreOfficeDocumentBackend.exportXLSXPDF(
            actualInput: input,
            reviewedInputPath: "source.xlsx",
            stagedPDF: preview,
            reviewedOutputPath: "result.pdf",
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertTrue(invocations.allSatisfy { $0.executable == .libreOffice })
        guard let convertIndex = invocations[1].arguments.firstIndex(of: "--convert-to") else {
            return XCTFail("missing LibreOffice conversion filter")
        }
        XCTAssertEqual(invocations[1].arguments[convertIndex + 1], "pdf:calc_pdf_Export")
        XCTAssertEqual(invocations[1].internalReadOnlyWorkspacePaths, [input.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        let profile = stage.appendingPathComponent(
            "libreoffice-profile/user/registrymodifications.xcu")
        let configuration = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(configuration.contains("MacroSecurityLevel"))
        XCTAssertTrue(configuration.contains("DisablePythonRuntime"))
    }

    func testCompileLaTeXUsesOnlyFixedTectonicArguments() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("\\documentclass{article}\\begin{document}ok\\end{document}".utf8)
            .write(to: workspace.appendingPathComponent("main.tex"))
        let runner = FixedBackendRecordingRunner()

        let observation = try await CompileLaTeXTool().execute(
            ToolArgs(raw: #"{"inputPath":"main.tex"}"#),
            in: ToolContext(workspaceRoot: workspace, documentBackend: runner))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].executable, .tectonic)
        XCTAssertEqual(invocations[0].arguments, ["--version"])
        XCTAssertEqual(invocations[1].executable, .tectonic)
        XCTAssertEqual(invocations[1].arguments.prefix(2), ["--untrusted", "--only-cached"])
        XCTAssertTrue(invocations[1].arguments.contains("--outdir"))
        XCTAssertFalse(invocations[1].arguments.contains("latexmk"))
        XCTAssertFalse(invocations[1].arguments.contains("xelatex"))
        XCTAssertFalse(invocations[1].arguments.contains("pdflatex"))
        XCTAssertTrue(observation.text.contains(#""tectonic":"0.15.0""#))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("main.pdf").path))
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-fixed-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        return workspace
    }
}
