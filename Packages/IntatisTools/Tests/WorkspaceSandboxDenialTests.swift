import XCTest
@testable import IntatisTools

final class WorkspaceSandboxDenialTests: XCTestCase {
    func testMacOSSandboxApplyDenialIsClassified() throws {
        let result = ShellResult(
            stdout: "",
            stderr: "sandbox-exec: sandbox_apply: Operation not permitted\n",
            exitCode: 71)

        let denial = try XCTUnwrap(workspaceSandboxStartupDenial(
            in: result,
            backend: .macOSSandboxExec,
            managedCommandShimStarted: false))

        XCTAssertEqual(
            denial.reason,
            "macOS workspace sandbox denied process startup")
    }

    func testBubblewrapSetupDenialIsClassified() throws {
        let result = ShellResult(
            stdout: "",
            stderr: "bwrap: Creating new namespace failed: Operation not permitted\n",
            exitCode: 1)

        let denial = try XCTUnwrap(workspaceSandboxStartupDenial(
            in: result,
            backend: .bubblewrap,
            managedCommandShimStarted: false))

        XCTAssertEqual(
            denial.reason,
            "Bubblewrap workspace sandbox denied process startup")
    }

    func testOrdinaryNonzeroResultsAreNotClassifiedAsSandboxDenials() {
        let ordinaryFailures = [
            ShellResult(
                stdout: "",
                stderr: "/bin/cat: private.txt: Operation not permitted\n",
                exitCode: 1),
            ShellResult(
                stdout: "",
                stderr: "permission denied\n",
                exitCode: 126),
            ShellResult(
                stdout: "",
                stderr: "sandbox-exec: profile syntax error near line 1\n",
                exitCode: 65),
            ShellResult(
                stdout: "sandbox-exec: sandbox_apply: Operation not permitted\n",
                stderr: "",
                exitCode: 1),
            ShellResult(stdout: "", stderr: "command failed\n", exitCode: 2),
        ]

        for result in ordinaryFailures {
            XCTAssertNil(workspaceSandboxStartupDenial(
                in: result,
                backend: .macOSSandboxExec,
                managedCommandShimStarted: false))
            XCTAssertNil(workspaceSandboxStartupDenial(
                in: result,
                backend: .bubblewrap,
                managedCommandShimStarted: false))
        }
    }

    func testWrapperLikeDiagnosticAfterCommandShimStartIsNotClassified() {
        let result = ShellResult(
            stdout: "",
            stderr: "sandbox-exec: sandbox_apply: Operation not permitted\n",
            exitCode: 71)

        XCTAssertNil(workspaceSandboxStartupDenial(
            in: result,
            backend: .macOSSandboxExec,
            managedCommandShimStarted: true))
    }

    func testManagedTargetCannotSpoofSandboxStartupDenial() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace process sandbox unavailable")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-sandbox-denial-spoof-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try await ProcessShellRunner(timeoutSeconds: 5).run(
            "printf 'sandbox-exec: sandbox_apply: Operation not permitted\\n' >&2; exit 71",
            cwd: workspace)

        XCTAssertEqual(result.exitCode, 71)
        XCTAssertEqual(
            result.stderr,
            "sandbox-exec: sandbox_apply: Operation not permitted\n")
    }

    func testSuccessfulExitIsNeverClassified() {
        let result = ShellResult(
            stdout: "",
            stderr: "sandbox-exec: sandbox_apply: Operation not permitted\n",
            exitCode: 0)

        XCTAssertNil(workspaceSandboxStartupDenial(
            in: result,
            backend: .macOSSandboxExec,
            managedCommandShimStarted: false))
    }
}
