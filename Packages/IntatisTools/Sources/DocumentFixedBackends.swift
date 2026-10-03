import Foundation
import IntatisCore
import IntatisProtocol

enum LibreOfficeDocumentBackend {
    static let expectedProductName = "LibreOfficeDev"
    static let expectedVersion = "26.8.0.0.beta1"

    static func exportDOCXPDF(
        actualInput: URL,
        reviewedInputPath: String,
        stagedPDF: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        try await exportPDF(
            actualInput: actualInput,
            reviewedInputPath: reviewedInputPath,
            stagedPDF: stagedPDF,
            reviewedOutputPath: reviewedOutputPath,
            exportFilter: "pdf:writer_pdf_Export",
            in: context)
    }

    static func exportPPTXPDF(
        actualInput: URL,
        reviewedInputPath: String,
        stagedPDF: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        try await exportPDF(
            actualInput: actualInput,
            reviewedInputPath: reviewedInputPath,
            stagedPDF: stagedPDF,
            reviewedOutputPath: reviewedOutputPath,
            exportFilter: "pdf:impress_pdf_Export",
            in: context)
    }

    static func exportXLSXPDF(
        actualInput: URL,
        reviewedInputPath: String,
        stagedPDF: URL,
        reviewedOutputPath: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        try await exportPDF(
            actualInput: actualInput,
            reviewedInputPath: reviewedInputPath,
            stagedPDF: stagedPDF,
            reviewedOutputPath: reviewedOutputPath,
            exportFilter: "pdf:calc_pdf_Export",
            in: context)
    }

    private static func exportPDF(
        actualInput: URL,
        reviewedInputPath: String,
        stagedPDF: URL,
        reviewedOutputPath: String,
        exportFilter: String,
        in context: ToolContext
    ) async throws -> [String: String] {
        let version = try await requireVersion(in: context)
        let stageRoot = stagedPDF.deletingLastPathComponent()
        let outputDirectory = stageRoot.appendingPathComponent("libreoffice-output", isDirectory: true)
        let profileDirectory = stageRoot.appendingPathComponent("libreoffice-profile", isDirectory: true)
        try createPrivateBackendDirectory(outputDirectory)
        try prepareSafeLibreOfficeProfile(profileDirectory)
        let profileArgument = "-env:UserInstallation=\(profileDirectory.absoluteString)"
        let inputIsInternal = actualInput.path != stageRoot.path
            && PathConfinement.isWithin(actualInput.path, root: stageRoot)
        let invocation = DocumentBackendInvocation(
            executable: .libreOffice,
            arguments: [
                "--headless",
                "--nologo",
                "--nodefault",
                "--nofirststartwizard",
                "--nolockcheck",
                "--norestore",
                profileArgument,
                "--convert-to", exportFilter,
                "--outdir", outputDirectory.path,
                actualInput.path,
            ],
            readableWorkspacePaths: [reviewedInputPath],
            writableWorkspacePaths: [reviewedOutputPath],
            internalWritableWorkspacePaths: [stageRoot.path],
            internalReadOnlyWorkspacePaths: inputIsInternal ? [actualInput.path] : [])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendFailed, "LibreOffice PDF export failed")
        }
        let candidates = try safeRegularFiles(in: outputDirectory).filter {
            $0.pathExtension.lowercased() == "pdf"
        }
        guard candidates.count == 1,
              FileManager.default.fileExists(atPath: stagedPDF.path) == false else {
            throw DocumentToolError(.validationFailed, "LibreOffice did not produce exactly one PDF")
        }
        do {
            try FileManager.default.moveItem(at: candidates[0], to: stagedPDF)
        } catch {
            throw DocumentToolError(.backendFailed, "LibreOffice PDF output could not be staged")
        }
        return ["libreoffice": version]
    }

    private static func requireVersion(in context: ToolContext) async throws -> String {
        let invocation = DocumentBackendInvocation(
            executable: .libreOffice,
            arguments: ["--version"],
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let result = try await run(invocation, in: context)
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendMissing, "LibreOffice is unavailable")
        }
        let firstLine = result.stdout.split(whereSeparator: { $0.isNewline }).first.map(String.init)
            ?? result.stderr.split(whereSeparator: { $0.isNewline }).first.map(String.init)
            ?? ""
        let versionFields = firstLine.split(whereSeparator: { $0.isWhitespace })
        guard versionFields.count >= 2,
              versionFields[0] == Substring(expectedProductName),
              versionFields[1] == Substring(expectedVersion) else {
            throw DocumentToolError(.backendVersionMismatch, "LibreOffice version does not match the fixed manifest")
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
                throw DocumentToolError(.backendMissing, "LibreOffice is unavailable at its fixed path")
            }
            throw DocumentToolError(.backendFailed, "LibreOffice could not be started")
        } catch {
            throw DocumentToolError(.backendFailed, "LibreOffice could not be started")
        }
    }

}

private func prepareSafeLibreOfficeProfile(_ profile: URL) throws {
    try createPrivateBackendDirectory(profile)
    let user = profile.appendingPathComponent("user", isDirectory: true)
    try createPrivateBackendDirectory(user)
    let configuration = user.appendingPathComponent("registrymodifications.xcu")
    let xml = #"""
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
    <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
    <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="DisableActiveContent" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="DisablePythonRuntime" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="DisableOLEAutomation" oor:op="fuse"><value>true</value></prop>
    <prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop>
  </item>
</oor:items>
"""#
    do {
        try Data(xml.utf8).write(to: configuration, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: configuration.path)
    } catch {
        throw DocumentToolError(
            .backendFailed,
            "LibreOffice safe profile could not be prepared")
    }
}

private func createPrivateBackendDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw DocumentToolError(.validationFailed, "backend staging path is not a directory")
        }
    } else {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path)
}

private func safeRegularFiles(in directory: URL) throws -> [URL] {
    let values = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    return try values.filter { url in
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isSymbolicLink != true else {
            throw DocumentToolError(.validationFailed, "backend output contains a symlink")
        }
        return properties.isRegularFile == true
    }
}

private extension JSONEncoder {
    static var sortedFixedBackendEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
