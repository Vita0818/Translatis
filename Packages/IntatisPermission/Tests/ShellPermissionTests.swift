import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisPermission

final class ShellPermissionTests: XCTestCase {
    private let gate = DeterministicPolicyGate()

    private func tempWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func result(_ command: String, root: URL) -> GateResult {
        let data = try! JSONSerialization.data(withJSONObject: ["command": command])
        let raw = String(decoding: data, as: UTF8.self)
        let call = ToolCallContext(toolName: "run_shell", sideEffect: .exec,
                                   touchedPaths: [], risksNetwork: false, rawArgs: raw)
        let ctx = PermissionContext(workspaceRoot: root, profile: .reviewed, allowsShell: true)
        return gate.evaluate(call, ctx)
    }

    private func interactionResult(_ characters: String, root: URL) -> GateResult {
        let data = try! JSONSerialization.data(withJSONObject: [
            "session_id": "terminal_policy_test",
            "chars": characters,
        ])
        let raw = String(decoding: data, as: UTF8.self)
        let call = ToolCallContext(
            toolName: "write_stdin",
            sideEffect: .exec,
            touchedPaths: [],
            risksNetwork: false,
            rawArgs: raw)
        let ctx = PermissionContext(
            workspaceRoot: root,
            profile: .reviewed,
            allowsShell: true)
        return gate.evaluate(call, ctx)
    }

    private func assertNotAllow(_ command: String, root: URL, file: StaticString = #filePath, line: UInt = #line) {
        if case .allow = result(command, root: root) {
            XCTFail("command must not auto-allow: \(command)", file: file, line: line)
        }
    }

    private func assertDeny(_ command: String, root: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case .deny = result(command, root: root) else {
            return XCTFail("command must deny: \(command)", file: file, line: line)
        }
    }

    func testSimpleCatMayAutoAllowWhenConfined() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("readme".utf8).write(to: root.appendingPathComponent("README.md"))

        switch result("cat README.md", root: root) {
        case .allow, .ask:
            break
        case .deny:
            XCTFail("confined cat should be allow or ask")
        case .pass:
            XCTFail("run_shell must not pass to reviewer by default")
        }
    }

    func testCatTraversalDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertDeny("cat ../secret", root: root)
    }

    func testCatSSHDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertDeny("cat ~/.ssh/id_rsa", root: root)
    }

    func testCatEnvDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertDeny("cat .env", root: root)
    }

    func testEchoRedirectNotAutoAllowed() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertNotAllow("echo x > file", root: root)
    }

    func testPipeNotAutoAllowed() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertNotAllow("cat file | pbcopy", root: root)
    }

    func testRgSSHDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertDeny("rg TOKEN ~/.ssh", root: root)
    }

    func testLsRootNotAutoAllowed() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertNotAllow("ls /", root: root)
    }

    func testRmRfDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertDeny("rm -rf build", root: root)
    }

    func testSudoDenied() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertDeny("sudo ls", root: root)
    }

    func testGitPushNotAutoAllowed() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertNotAllow("git push", root: root)
    }

    func testCurlNotAutoAllowed() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        assertNotAllow("curl https://example.test", root: root)
    }

    func testInteractiveShellInputCannotBypassDangerousCommandDeny() throws {
        let root = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .deny = interactionResult("rm -rf .\n", root: root) else {
            return XCTFail("write_stdin must inspect command-shaped input")
        }
    }
}
