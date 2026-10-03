import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisTools

#if canImport(Darwin)
import Darwin
#endif

#if canImport(PDFKit) && canImport(AppKit)
import AppKit
import PDFKit
#endif

private struct FakeShell: ShellRunner {
    let result: ShellResult
    func run(_ command: String, cwd: URL) async throws -> ShellResult { result }
}

private actor FakeTectonicDocumentBackend: DocumentBackendRunner {
    func run(_ invocation: DocumentBackendInvocation, cwd: URL) async throws -> ShellResult {
        guard invocation.executable == .tectonic else {
            return ShellResult(stdout: "", stderr: "unexpected backend", exitCode: 2)
        }
        if invocation.arguments == ["--version"] {
            return ShellResult(stdout: "tectonic 0.15.0\n", stderr: "", exitCode: 0)
        }
        guard let outputIndex = invocation.arguments.firstIndex(of: "--outdir"),
              invocation.arguments.indices.contains(outputIndex + 1),
              let inputPath = invocation.arguments.last else {
            return ShellResult(stdout: "", stderr: "unexpected arguments", exitCode: 2)
        }
        let input = URL(fileURLWithPath: inputPath)
        let output = URL(
            fileURLWithPath: invocation.arguments[outputIndex + 1],
            isDirectory: true)
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: output)
        return ShellResult(stdout: "compiled\n", stderr: "", exitCode: 0)
    }
}

private actor InternalToolDrainProbe {
    private var closes = 0
    func close() -> Bool {
        closes += 1
        return false
    }
    func count() -> Int { closes }
}

private actor ShellResultQueue {
    private var results: [ShellResult]

    init(_ results: [ShellResult]) {
        self.results = results
    }

    func next() throws -> ShellResult {
        guard results.isEmpty == false else {
            throw IntatisError.io("no fake shell results remain")
        }
        return results.removeFirst()
    }
}

private struct SequenceShell: ShellRunner {
    let queue: ShellResultQueue

    init(_ results: [ShellResult]) {
        self.queue = ShellResultQueue(results)
    }

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        try await queue.next()
    }
}

private actor CommandRecorder {
    private var commands: [String] = []

    func record(_ command: String) {
        commands.append(command)
    }

    func all() -> [String] {
        commands
    }
}

private struct RecordingShell: ShellRunner {
    let recorder: CommandRecorder
    let result: ShellResult

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        await recorder.record(command)
        return result
    }
}

private actor AsyncBarrier {
    private let expected: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func wait() async {
        arrivals += 1
        if arrivals >= expected {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct BarrierShell: ShellRunner {
    let barrier: AsyncBarrier
    let result: ShellResult

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        await barrier.wait()
        return result
    }
}

private actor ShellOverlapState {
    private var activeCount = 0
    private var callCount = 0
    private var didOverlap = false

    func enter() -> Int {
        activeCount += 1
        callCount += 1
        if activeCount > 1 {
            didOverlap = true
        }
        return callCount
    }

    func leave() {
        activeCount -= 1
    }

    func overlapped() -> Bool {
        didOverlap
    }
}

private struct OverlapDetectingShell: ShellRunner {
    let state: ShellOverlapState

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        let index = await state.enter()
        do {
            try await Task.sleep(nanoseconds: 100_000_000)
            let url = index == 1 ? "https://example.com/one" : "https://example.com/two"
            let title = index == 1 ? "One" : "Two"
            let stdout = """
            {"action":"navigate","profile":"shared","backend":"cdp","backendDetail":"edge","url":"\(url)","title":"\(title)","text":"\(title) marker","links":[]}
            """
            await state.leave()
            return ShellResult(stdout: stdout, stderr: "", exitCode: 0)
        } catch {
            await state.leave()
            throw error
        }
    }
}

private struct FakeGit: GitService {
    let statusText: String
    let diffText: String
    var stagedDiffText: String = "staged-diff"
    var branchText: String = "current: main\nbranches:\n* main"
    var infoText: String = "root: /tmp/repo\nbranch: main\nhead: abc123\nhasChanges: false\nremotes:\n(none)"
    var commitsText: String = "abc123\tIntatis\t2026-01-01\tInitial"
    var worktreeText: String = "worktree /tmp/repo\nHEAD abc123\nbranch refs/heads/main"
    var remotesText: String = "origin\thttps://github.com/example/repo.git (fetch)\norigin\thttps://github.com/example/repo.git (push)"
    func status(workspace: URL) async throws -> String { statusText }
    func diff(workspace: URL) async throws -> String { diffText }
    func stagedDiff(workspace: URL) async throws -> String { stagedDiffText }
    func repositoryInfo(workspace: URL) async throws -> String { infoText }
    func recentCommits(limit: Int, workspace: URL) async throws -> String { "\(commitsText)\nlimit=\(limit)" }
    func diffAgainst(base: String, workspace: URL) async throws -> String { "diff against \(base)" }
    func branchInfo(workspace: URL) async throws -> String { branchText }
    func createBranch(name: String, startPoint: String?, workspace: URL) async throws -> String {
        "created branch \(name)\(startPoint.map { " from \($0)" } ?? "")"
    }
    func stage(paths: [String], workspace: URL) async throws -> String {
        "staged \(paths.joined(separator: ","))"
    }
    func unstage(paths: [String], workspace: URL) async throws -> String {
        "unstaged \(paths.joined(separator: ","))"
    }
    func commit(message: String, workspace: URL) async throws -> String {
        "committed \(message)"
    }
    func applyPatch(diff: String, reverse: Bool, checkOnly: Bool, cached: Bool, workspace: URL) async throws -> GitPatchResult {
        GitPatchResult(
            text: "patch reverse=\(reverse) check=\(checkOnly) cached=\(cached)",
            changedFiles: ["a.swift"],
            diff: diff)
    }
    func worktrees(workspace: URL) async throws -> String { worktreeText }
    func createWorktree(name: String, startPoint: String?, branch: String?, workspace: URL) async throws -> String {
        "created worktree \(name) start=\(startPoint ?? "HEAD") branch=\(branch ?? "detached")"
    }
    func removeWorktree(name: String, force: Bool, workspace: URL) async throws -> String {
        "removed worktree \(name) force=\(force)"
    }
    func remotes(workspace: URL) async throws -> String { remotesText }
    func fetch(remote: String, branch: String?, prune: Bool, workspace: URL) async throws -> String {
        "fetched \(remote) branch=\(branch ?? "all") prune=\(prune)"
    }
    func pullFastForward(remote: String, branch: String, workspace: URL) async throws -> String {
        "pulled \(remote)/\(branch) --ff-only"
    }
    func push(remote: String, branch: String, setUpstream: Bool, workspace: URL) async throws -> String {
        "pushed \(branch) to \(remote) setUpstream=\(setUpstream)"
    }
    func switchBranch(name: String, workspace: URL) async throws -> String {
        "switched to \(name)"
    }
}

private struct FakeImageGenerator: ImageGenerationToolService {
    func generateImage(prompt: String,
                       size: String,
                       count: Int,
                       outputPath: String,
                       workspaceRoot: URL) async throws -> ToolObservation {
        let url = try PathConfinement.resolve(outputPath, within: workspaceRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake-image".utf8).write(to: url)
        return ToolObservation(text: "generated fake image: \(outputPath)", changedFiles: [outputPath])
    }

    func editImage(image: Data,
                   filename: String,
                   mime: String,
                   prompt: String,
                   outputPath: String,
                   workspaceRoot: URL) async throws -> ToolObservation {
        let url = try PathConfinement.resolve(outputPath, within: workspaceRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("fake-edited-image".utf8).write(to: url)
        return ToolObservation(
            text: "edited \(filename) (\(mime), \(image.count) bytes) with \(prompt)",
            changedFiles: [outputPath])
    }
}

final class IntatisToolsTests: XCTestCase {
    func testCheckedInternalToolCloseFailsAndRemainsSingleFlight() async {
        let probe = InternalToolDrainProbe()
        let lease = HostToolRegistryAugmentationLease(
            registry: ToolRegistry([]),
            close: { await probe.close() })

        do {
            try await lease.closeRequiringDrain()
            XCTFail("a failed internal resource drain must not become success")
        } catch let error as IntatisError {
            guard case .io(let message) = error else {
                return XCTFail("unexpected checked-close error: \(error)")
            }
            XCTAssertTrue(message.contains("did not drain"))
        } catch {
            XCTFail("unexpected checked-close error type: \(error)")
        }
        let repeated = await lease.close()
        let closes = await probe.count()
        XCTAssertFalse(repeated)
        XCTAssertEqual(closes, 1)
    }


    private func tempWorkspace() throws -> URL {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return ws
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func browserPayload(from command: String) throws -> [String: Any] {
        let marker = "INTATIS_BROWSER_ARGS='"
        guard let markerRange = command.range(of: marker) else {
            throw IntatisError.decoding("missing browser args payload")
        }
        let payloadStart = markerRange.upperBound
        guard let payloadEnd = command[payloadStart...].firstIndex(of: "'") else {
            throw IntatisError.decoding("unterminated browser args payload")
        }
        let encoded = String(command[payloadStart..<payloadEnd])
        guard let data = Data(base64Encoded: encoded),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntatisError.decoding("browser args payload is not JSON")
        }
        return object
    }

    #if canImport(PDFKit) && canImport(AppKit)
    private func makeBlankPDF(pageCount: Int, at url: URL) throws {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 72, height: 72))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 72, height: 72)).fill()
            image.unlockFocus()
            guard let page = PDFPage(image: image) else {
                throw IntatisError.io("could not create test PDF page \(index)")
            }
            document.insert(page, at: index)
        }
        guard document.write(to: url) else {
            throw IntatisError.io("could not write test PDF")
        }
    }
    #endif

    #if canImport(Darwin)
    private func freeLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw IntatisError.io("could not create loopback socket")
        }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw IntatisError.io("could not bind loopback socket")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw IntatisError.io("could not inspect loopback socket")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func python3Executable() -> String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func gitExecutable() -> String? {
        [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func startStaticHTTPServer(directory: URL, port: Int) throws -> Process {
        guard let python = python3Executable() else {
            throw IntatisError.io("python3 is required for the real browser persistence smoke")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-m", "http.server", "\(port)",
            "--bind", "127.0.0.1",
            "--directory", directory.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    private func waitForHTTPServer(port: Int, path: String = "/login.html") async throws {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntatisError.io("local browser smoke server did not start")
    }
    #endif

    // MARK: Path confinement

    func testPathConfinement() throws {
        let root = URL(fileURLWithPath: "/ws")
        XCTAssertNoThrow(try PathConfinement.resolve("src/a.swift", within: root))
        XCTAssertEqual(try PathConfinement.resolve("a/../b.txt", within: root).path, "/ws/b.txt")
        XCTAssertThrowsError(try PathConfinement.resolve("../etc/passwd", within: root))
        XCTAssertThrowsError(try PathConfinement.resolve("/etc/passwd", within: root))
        XCTAssertThrowsError(try PathConfinement.resolve("../ws2/x", within: root))
        XCTAssertFalse(PathConfinement.isWithin("../x", root: root))
    }

    // MARK: Unified diff

    func testUnifiedDiffParseAndApply() throws {
        let diff = [
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@ -1,3 +1,3 @@",
            " line1",
            "-line2",
            "+CHANGED",
            " line3",
        ].joined(separator: "\n")

        let patches = UnifiedDiff.parse(diff)
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].path, "file.txt")

        let updated = try UnifiedDiff.apply(content: "line1\nline2\nline3", hunks: patches[0].hunks)
        XCTAssertEqual(updated, "line1\nCHANGED\nline3")
    }

    func testUnifiedDiffRejectsNonMatchingHunk() {
        let hunk = UnifiedDiff.Hunk(oldLines: ["nope"], newLines: ["x"])
        XCTAssertThrowsError(try UnifiedDiff.apply(content: "a\nb", hunks: [hunk]))
    }

    // MARK: Git status parse

    func testGitStatusParse() {
        let porcelain = " M src/a.swift\n?? new.txt\nA  added.kt\n"
        let entries = GitStatus.parse(porcelain)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].x, Character(" "))
        XCTAssertEqual(entries[0].y, Character("M"))
        XCTAssertEqual(entries[0].path, "src/a.swift")
        XCTAssertEqual(entries[1].path, "new.txt")
        XCTAssertEqual(entries[2].path, "added.kt")
    }

    // MARK: File tools

    func testFileToolsReadWriteListSearch() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        _ = try await WriteFileTool().execute(ToolArgs(raw: #"{"path":"src/a.txt","content":"hello world"}"#), in: ctx)
        let read = try await ReadFileTool().execute(ToolArgs(raw: #"{"path":"src/a.txt"}"#), in: ctx)
        XCTAssertEqual(read.text, "hello world")

        let list = try await ListFilesTool().execute(ToolArgs(raw: #"{"path":"src"}"#), in: ctx)
        XCTAssertTrue(list.text.contains("a.txt"))

        let search = try await SearchTextTool().execute(ToolArgs(raw: #"{"query":"hello","path":"."}"#), in: ctx)
        XCTAssertTrue(search.text.contains("a.txt"))

        do {
            _ = try await ReadFileTool().execute(ToolArgs(raw: #"{"path":"../escape"}"#), in: ctx)
            XCTFail("path confinement should have rejected the read")
        } catch {
            // expected
        }
    }

    func testApplyPatchToolEditsFile() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        _ = try await WriteFileTool().execute(ToolArgs(raw: #"{"path":"f.txt","content":"a\nb\nc"}"#), in: ctx)

        let diff = ["--- a/f.txt", "+++ b/f.txt", "@@ -1,3 +1,3 @@", " a", "-b", "+B", " c"].joined(separator: "\n")
        let argsData = try JSONSerialization.data(withJSONObject: ["diff": diff])
        let obs = try await ApplyPatchTool().execute(ToolArgs(raw: String(decoding: argsData, as: UTF8.self)), in: ctx)
        XCTAssertEqual(obs.changedFiles, ["f.txt"])

        let read = try await ReadFileTool().execute(ToolArgs(raw: #"{"path":"f.txt"}"#), in: ctx)
        XCTAssertEqual(read.text, "a\nB\nc")
    }

    func testOrdinaryFileToolsCannotBypassManagedKnowledgePublication()
        async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let store = ws.appendingPathComponent("knowledge", isDirectory: true)
        let snapshots = store.appendingPathComponent(
            ".intatis-rag-snapshots",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshots,
            withIntermediateDirectories: true)
        let pointer = store.appendingPathComponent(".intatis-rag-store.json")
        let snapshotFile = snapshots.appendingPathComponent("profile.json")
        try Data("pointer-original".utf8).write(to: pointer)
        try Data("snapshot-original".utf8).write(to: snapshotFile)

        // Even a legacy/decoded lease with an empty deny list cannot remove
        // the host-owned publication floor at the executor boundary.
        let context = ToolContext(
            workspaceRoot: ws,
            workspaceLease: WorkspaceLease(
                rootPath: ws.path,
                access: .readWrite,
                deniedPatterns: []))

        do {
            _ = try await ReadFileTool().execute(
                ToolArgs(raw: #"{"path":"knowledge/.intatis-rag-store.json"}"#),
                in: context)
            XCTFail("read_file unexpectedly read the Knowledge pointer")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "denied by the workspace lease"),
                "\(error)")
        }

        do {
            _ = try await ListFilesTool().execute(
                ToolArgs(raw: #"{"path":"knowledge/.intatis-rag-snapshots"}"#),
                in: context)
            XCTFail("list_files unexpectedly traversed Knowledge snapshots")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "denied by the workspace lease"),
                "\(error)")
        }

        do {
            _ = try await SearchTextTool().execute(
                ToolArgs(raw: #"{"query":"snapshot","path":"knowledge/.intatis-rag-snapshots"}"#),
                in: context)
            XCTFail("search_text unexpectedly traversed Knowledge snapshots")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "denied by the workspace lease"),
                "\(error)")
        }

        do {
            _ = try await WriteFileTool().execute(
                ToolArgs(raw: #"{"path":"knowledge/.intatis-rag-store.json","content":"changed"}"#),
                in: context)
            XCTFail("write_file unexpectedly modified the Knowledge pointer")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "denied by the workspace lease"),
                "\(error)")
        }

        let diff = [
            "--- a/knowledge/.intatis-rag-snapshots/profile.json",
            "+++ b/knowledge/.intatis-rag-snapshots/profile.json",
            "@@ -1 +1 @@",
            "-snapshot-original",
            "+changed",
        ].joined(separator: "\n")
        let patchData = try JSONSerialization.data(withJSONObject: [
            "diff": diff,
        ])
        do {
            _ = try await ApplyPatchTool().execute(
                ToolArgs(raw: String(decoding: patchData, as: UTF8.self)),
                in: context)
            XCTFail("apply_patch unexpectedly modified a Knowledge snapshot")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "denied by the workspace lease"),
                "\(error)")
        }

        XCTAssertEqual(try String(contentsOf: pointer), "pointer-original")
        XCTAssertEqual(try String(contentsOf: snapshotFile), "snapshot-original")
    }

    // MARK: Shell + git tools (injected fakes)

    func testRunShellUsesInjectedRunner() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "hi", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))
        let obs = try await RunShellTool().execute(ToolArgs(raw: #"{"command":"echo hi"}"#), in: ctx)
        XCTAssertTrue(obs.text.contains("hi"))
        XCTAssertTrue(obs.text.contains("[exit 0]"))
    }

    func testToolContextSeparatesRawAndStructuredProcessShells() throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let production = ToolContext(workspaceRoot: ws)
        XCTAssertTrue(production.shell is ProcessShellRunner)
        XCTAssertTrue(production.structuredShell is StructuredProcessShellRunner)
        XCTAssertTrue(production.networkStructuredShell is StructuredProcessShellRunner)
        XCTAssertTrue(production.browserBackend is BrowserBackendProcessRunner)

        let fake = FakeShell(result: ShellResult(stdout: "ok", stderr: "", exitCode: 0))
        let injected = ToolContext(workspaceRoot: ws, shell: fake)
        XCTAssertTrue(injected.shell is FakeShell)
        XCTAssertTrue(injected.structuredShell is FakeShell)
        XCTAssertTrue(injected.networkStructuredShell is FakeShell)
        XCTAssertTrue(injected.browserBackend is InjectedShellBrowserBackendRunner)

        let customStructured = ToolContext(
            workspaceRoot: ws,
            structuredShell: fake,
            networkStructuredShell: fake)
        XCTAssertTrue(customStructured.structuredShell is FakeShell)
        XCTAssertTrue(customStructured.networkStructuredShell is FakeShell)
        XCTAssertTrue(customStructured.browserBackend is BrowserBackendProcessRunner)
    }

    func testStructuredProcessShellRunnerStillSupportsToolBackendCommands() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let result = try await StructuredProcessShellRunner(timeoutSeconds: 5).run(
            "printf structured-backend",
            cwd: ws)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "structured-backend")
    }

    #if canImport(Darwin)
    func testStructuredProcessShellRunnerUsesSanitizedEnvironmentAndWorkspaceLease() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("ordinary-marker".utf8).write(to: ws.appendingPathComponent("ordinary.txt"))
        try Data("env-secret-marker".utf8).write(to: ws.appendingPathComponent(".env"))
        try Data("root-secret-marker".utf8).write(to: ws.appendingPathComponent("secret-note.txt"))
        try Data("root-key-marker".utf8).write(to: ws.appendingPathComponent("api-key.txt"))
        let secretDir = ws.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        try Data("token-secret-marker".utf8).write(to: secretDir.appendingPathComponent("api-token.txt"))
        try FileManager.default.createSymbolicLink(
            at: ws.appendingPathComponent("ordinary-link"),
            withDestinationURL: ws.appendingPathComponent(".env"))

        setenv("INTATIS_HOST_SECRET_MARKER", "host-secret-marker", 1)
        defer { unsetenv("INTATIS_HOST_SECRET_MARKER") }
        let runner = StructuredProcessShellRunner(timeoutSeconds: 5)

        let ordinary = try await runner.run("/bin/cat ordinary.txt; printf '|%s' \"$INTATIS_HOST_SECRET_MARKER\"", cwd: ws)
        XCTAssertEqual(ordinary.exitCode, 0, ordinary.stderr)
        XCTAssertEqual(ordinary.stdout, "ordinary-marker|")

        for path in [".env", "secret-note.txt", "api-key.txt", "nested/api-token.txt", "ordinary-link"] {
            let denied = try await runner.run("/bin/cat '\(path)'", cwd: ws)
            XCTAssertNotEqual(denied.exitCode, 0, "lease unexpectedly allowed \(path)")
            XCTAssertFalse(denied.stdout.contains("secret-marker"), denied.stdout)
            XCTAssertFalse(denied.stderr.contains("secret-marker"), denied.stderr)
        }
        let deniedWrite = try await runner.run("printf changed > .env", cwd: ws)
        XCTAssertNotEqual(deniedWrite.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent(".env")), "env-secret-marker")
    }

    func testStructuredProcessShellRunnerEnforcesAllowedRulesAndReadOnly() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let allowedDir = ws.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)
        try Data("allowed-marker".utf8).write(to: allowedDir.appendingPathComponent("file.txt"))
        try Data("blocked-marker".utf8).write(to: ws.appendingPathComponent("blocked.txt"))
        let lease = WorkspaceLease(
            rootPath: ws.path,
            access: .readOnly,
            allowedPathRules: [PathRule(pattern: "allowed/**")],
            deniedPatterns: [])
        let runner = StructuredProcessShellRunner(timeoutSeconds: 5, workspaceLease: lease)

        let allowed = try await runner.run("/bin/cat allowed/file.txt", cwd: ws)
        XCTAssertEqual(allowed.exitCode, 0, allowed.stderr)
        XCTAssertEqual(allowed.stdout, "allowed-marker")
        let blocked = try await runner.run("/bin/cat blocked.txt", cwd: ws)
        XCTAssertNotEqual(blocked.exitCode, 0)
        XCTAssertFalse(blocked.stdout.contains("blocked-marker"))
        let write = try await runner.run("printf changed > allowed/new.txt", cwd: ws)
        XCTAssertNotEqual(write.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: allowedDir.appendingPathComponent("new.txt").path))
    }

    func testBrowserBackendProcessRunnerUsesSanitizedEnvironment() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        setenv("INTATIS_BROWSER_HOST_SECRET_MARKER", "host-secret-marker", 1)
        defer { unsetenv("INTATIS_BROWSER_HOST_SECRET_MARKER") }

        let invocation = BrowserBackendInvocation(
            javaScript: #"process.stdout.write(`${process.env.INTATIS_BROWSER_HOST_SECRET_MARKER || ""}|${process.env.INTATIS_BROWSER_PROCESS_BOUNDARY || ""}`);"#,
            encodedArguments: Data("{}".utf8).base64EncodedString(),
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        let result = try await BrowserBackendProcessRunner(timeoutSeconds: 5).run(
            invocation,
            cwd: ws)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "|1")
    }

    func testBrowserBackendProcessRunnerRejectsWorkspaceRootReplacement() async throws {
        let ws = try tempWorkspace()
        let reviewed = ws.deletingLastPathComponent()
            .appendingPathComponent("\(ws.lastPathComponent)-browser-reviewed")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: reviewed)
        }
        let lease = WorkspaceLease(rootPath: ws.path, access: .readWrite, deniedPatterns: [])
        let runner = BrowserBackendProcessRunner(timeoutSeconds: 5, workspaceLease: lease)
        let invocation = BrowserBackendInvocation(
            javaScript: #"process.stdout.write("should-not-run");"#,
            encodedArguments: Data("{}".utf8).base64EncodedString(),
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])
        try FileManager.default.moveItem(at: ws, to: reviewed)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        do {
            _ = try await runner.run(invocation, cwd: ws)
            XCTFail("replacement directory unexpectedly retained reviewed browser authority")
        } catch {
            XCTAssertTrue(String(describing: error).contains("root identity changed"), "\(error)")
        }
    }

    func testBrowserBackendProcessRunnerBoundsFloodedOutput() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let outputLimit = 64 * 1_024
        let invocation = BrowserBackendInvocation(
            javaScript: """
            const chunk = "x".repeat(16 * 1024);
            for (let index = 0; index < 128; index += 1) {
              process.stdout.write(chunk);
              process.stderr.write(chunk);
            }
            process.stdout.write("\\n{\\"finished\\":true}\\n");
            process.stderr.write("\\nfinished-stderr\\n");
            """,
            encodedArguments: Data("{}".utf8).base64EncodedString(),
            readableWorkspacePaths: [],
            writableWorkspacePaths: [])

        let result = try await BrowserBackendProcessRunner(
            timeoutSeconds: 10,
            maximumOutputBytes: outputLimit
        ).run(invocation, cwd: ws)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertLessThan(result.stdout.utf8.count, outputLimit + 256)
        XCTAssertLessThan(result.stderr.utf8.count, outputLimit + 256)
        XCTAssertTrue(result.stdout.contains("output bytes omitted"))
        XCTAssertTrue(result.stderr.contains("output bytes omitted"))
        XCTAssertTrue(result.stdout.contains(#"{"finished":true}"#))
        XCTAssertTrue(result.stderr.contains("finished-stderr"))
    }

    func testBrowserBackendProcessRunnerRejectsDeniedDeclaredPathBeforeSpawn() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("blocked-marker".utf8)
            .write(to: ws.appendingPathComponent("denied.txt"))
        let executionMarker = ws.appendingPathComponent("browser-executed.txt")
        let script = """
        const fs = require("fs");
        fs.writeFileSync(\(String(reflecting: executionMarker.path)), "executed");
        """
        let lease = WorkspaceLease(
            rootPath: ws.path,
            access: .readWrite,
            deniedPatterns: ["denied.txt"])
        let invocation = BrowserBackendInvocation(
            javaScript: script,
            encodedArguments: Data("{}".utf8).base64EncodedString(),
            readableWorkspacePaths: [ws.appendingPathComponent("denied.txt").path],
            writableWorkspacePaths: [])

        do {
            _ = try await BrowserBackendProcessRunner(
                timeoutSeconds: 5,
                workspaceLease: lease
            ).run(invocation, cwd: ws)
            XCTFail("denied declared path unexpectedly reached the browser process")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("denied by the workspace lease"),
                "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: executionMarker.path))
    }

    func testManagedProcessRejectsWorkspaceRootReplacementAfterLeaseReview() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        let reviewed = ws.deletingLastPathComponent().appendingPathComponent("\(ws.lastPathComponent)-reviewed")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: reviewed)
        }
        let lease = WorkspaceLease(rootPath: ws.path, access: .readWrite, deniedPatterns: [])
        let runner = StructuredProcessShellRunner(timeoutSeconds: 5, workspaceLease: lease)
        try FileManager.default.moveItem(at: ws, to: reviewed)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data("replacement-marker".utf8).write(to: ws.appendingPathComponent("replacement.txt"))
        do {
            _ = try await runner.run("/bin/cat replacement.txt", cwd: ws)
            XCTFail("replacement directory unexpectedly retained reviewed lease authority")
        } catch {
            XCTAssertTrue(String(describing: error).contains("root identity changed"), "\(error)")
        }
        try FileManager.default.removeItem(at: ws)
        try FileManager.default.createSymbolicLink(at: ws, withDestinationURL: reviewed)
        do {
            _ = try await runner.run("/bin/cat ordinary.txt", cwd: ws)
            XCTFail("symlink replacement unexpectedly retained reviewed lease authority")
        } catch {
            XCTAssertTrue(String(describing: error).contains("root identity changed")
                || String(describing: error).contains("root does not match"), "\(error)")
        }
    }

    func testStructuredProcessShellNetworkAuthorityIsSeparated() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        guard python3Executable() != nil,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/nc") else {
            throw XCTSkip("python3 and nc are required for the network confinement smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let site = ws.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: site.appendingPathComponent("probe.txt"))
        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer { if server.isRunning { server.terminate() } }
        try await waitForHTTPServer(port: port, path: "/probe.txt")

        let command = "/usr/bin/nc -z -w 1 127.0.0.1 \(port)"
        let denied = try await StructuredProcessShellRunner(timeoutSeconds: 5).run(command, cwd: ws)
        XCTAssertNotEqual(denied.exitCode, 0)
        let allowed = try await StructuredProcessShellRunner(timeoutSeconds: 5, allowsNetwork: true).run(command, cwd: ws)
        XCTAssertEqual(allowed.exitCode, 0, allowed.stderr)
    }

    func testManagedProcessCleansFastBackgroundProcessGroup() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let result = try await StructuredProcessShellRunner(timeoutSeconds: 5).run(
            "/bin/sleep 30 & printf '%s' \"$!\" > background.pid",
            cwd: ws)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let pid = try XCTUnwrap(Int32(String(contentsOf: ws.appendingPathComponent("background.pid"))))
        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "fast background helper survived leader reap")
    }

    func testManagedProcessCancellationKillsDoubleForkedDescendant() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("Perl and the workspace sandbox are required")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let program = """
        use strict;
        use warnings;
        use POSIX qw(setsid);
        my $first = fork();
        die "first fork failed" unless defined $first;
        if ($first > 0) { waitpid($first, 0); exit 0; }
        setsid() or die "setsid failed";
        my $second = fork();
        die "second fork failed" unless defined $second;
        if ($second > 0) { select(undef, undef, undef, 0.20); exit 0; }
        open(my $handle, '>', 'daemon.pid') or die "pid file failed";
        print $handle $$;
        close($handle);
        sleep 30;
        """
        try Data(program.utf8).write(to: ws.appendingPathComponent("daemon.pl"))
        let task = Task {
            try await StructuredProcessShellRunner(
                timeoutSeconds: 30,
                terminationGraceSeconds: 0.1).run("/usr/bin/perl daemon.pl; /bin/sleep 30", cwd: ws)
        }
        let pidFile = ws.appendingPathComponent("daemon.pid")
        let createdDeadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: pidFile.path) == false, Date() < createdDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let daemonPID = try XCTUnwrap(Int32((try? String(contentsOf: pidFile)) ?? ""))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled managed process unexpectedly completed")
        } catch is CancellationError {
            // expected
        }
        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(daemonPID, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(Darwin.kill(daemonPID, 0), -1, "double-forked descendant survived cancellation")
    }
    #endif

    func testProcessShellRunnerAllowsWorkspaceReadWrite() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let result = try await ProcessShellRunner(timeoutSeconds: 5).run(
            "printf 'inside-marker' > result.txt; /bin/cat result.txt",
            cwd: ws)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "inside-marker")
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("result.txt")), "inside-marker")
    }

    func testProcessShellRunnerDeniesWorkspaceExternalFile() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        let outside = ws.deletingLastPathComponent()
            .appendingPathComponent("intatis-outside-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside-secret-marker".utf8).write(to: outside)

        let result = try await ProcessShellRunner(timeoutSeconds: 5).run(
            "/bin/cat '\(outside.path)'",
            cwd: ws)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains("outside-secret-marker"), result.stdout)
        XCTAssertFalse(result.stderr.contains("outside-secret-marker"), result.stderr)

        let symlink = ws.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let symlinkResult = try await ProcessShellRunner(timeoutSeconds: 5).run(
            "/bin/cat outside-link",
            cwd: ws)
        XCTAssertNotEqual(symlinkResult.exitCode, 0)
        XCTAssertFalse(symlinkResult.stdout.contains("outside-secret-marker"), symlinkResult.stdout)

        let escapedWrite = ws.deletingLastPathComponent()
            .appendingPathComponent("intatis-escaped-write-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: escapedWrite) }
        let writeResult = try await ProcessShellRunner(timeoutSeconds: 5).run(
            "printf escaped > '\(escapedWrite.path)'",
            cwd: ws)
        XCTAssertNotEqual(writeResult.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedWrite.path))
    }

    #if canImport(Darwin)
    func testProcessShellRunnerDeniesNetworkByDefault() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        guard python3Executable() != nil,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/nc") else {
            throw XCTSkip("python3 and nc are required for the network confinement smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let site = ws.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: site.appendingPathComponent("probe.txt"))
        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning { server.terminate() }
        }
        try await waitForHTTPServer(port: port, path: "/probe.txt")

        let result = try await ProcessShellRunner(timeoutSeconds: 5).run(
            "/usr/bin/nc -z -w 1 127.0.0.1 \(port)",
            cwd: ws)

        XCTAssertNotEqual(result.exitCode, 0, "sandboxed raw shell unexpectedly reached loopback")
    }
    #endif

    func testProcessShellRunnerCancellationKillsProcessGroupPromptly() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let runner = ProcessShellRunner(timeoutSeconds: 30, terminationGraceSeconds: 0.1)
        let task = Task {
            try await runner.run(
                "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > child.pid; wait",
                cwd: ws)
        }
        let pidFile = ws.appendingPathComponent("child.pid")
        let pidDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < pidDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        let childPID = Int32((try? String(contentsOf: pidFile)) ?? "")

        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled raw shell unexpectedly completed")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2.5)

        #if canImport(Darwin)
        if let childPID {
            let deadline = Date().addingTimeInterval(1)
            while Darwin.kill(childPID, 0) == 0, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(Darwin.kill(childPID, 0), -1, "child process survived cancellation")
        }
        #endif
    }

    func testProcessShellRunnerTimeoutIsBounded() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let started = Date()

        do {
            _ = try await ProcessShellRunner(
                timeoutSeconds: 0.2,
                terminationGraceSeconds: 0.1).run("/bin/sleep 30", cwd: ws)
            XCTFail("timed out raw shell unexpectedly completed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testProcessShellRunnerLargeStdoutAndStderrDoNotDeadlock() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let command = """
        i=0
        while [ "$i" -lt 12000 ]; do
          printf 'stdout-0123456789012345678901234567890123456789\\n'
          printf 'stderr-0123456789012345678901234567890123456789\\n' >&2
          i=$((i + 1))
        done
        """

        let result = try await ProcessShellRunner(timeoutSeconds: 10).run(command, cwd: ws)

        XCTAssertEqual(result.exitCode, 0, String(result.stderr.suffix(500)))
        XCTAssertGreaterThan(result.stdout.utf8.count, 500_000)
        XCTAssertGreaterThan(result.stderr.utf8.count, 500_000)
        XCTAssertTrue(result.stdout.contains("stdout-0123456789"))
        XCTAssertTrue(result.stderr.contains("stderr-0123456789"))
    }

    func testWebFetchLocalHTTPAndTruncation() async throws {
        #if canImport(Darwin)
        guard python3Executable() != nil else {
            throw XCTSkip("python3 is required for the web_fetch local HTTP smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let site = ws.appendingPathComponent("fetch-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("fetch-marker body that should be truncated".utf8)
            .write(to: site.appendingPathComponent("fetch.txt"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/fetch.txt")

        let obs = try await WebFetchTool().execute(
            ToolArgs(raw: #"{"url":"http://127.0.0.1:\#(port)/fetch.txt","maxCharacters":12}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(obs.text.contains("status: 200"), obs.text)
        XCTAssertTrue(obs.text.contains("fetch-marker"), obs.text)
        XCTAssertFalse(obs.text.contains("body that should be truncated"), obs.text)
        XCTAssertTrue(obs.truncated)
        #else
        throw XCTSkip("web_fetch local HTTP smoke requires Darwin test helpers")
        #endif
    }

    func testWebFetchRejectsNonHTTPURL() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        do {
            _ = try await WebFetchTool().execute(
                ToolArgs(raw: #"{"url":"file:///etc/passwd"}"#),
                in: ToolContext(workspaceRoot: ws))
            XCTFail("web_fetch should reject non-HTTP URLs")
        } catch {
            XCTAssertTrue(String(describing: error).contains("http(s)"), "\(error)")
        }
    }

    func testGitToolsUseInjectedService() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: " M a.swift\n?? b\n", diffText: "diffbody"))
        let status = try await GitStatusTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertTrue(status.text.contains("a.swift"))
        let diff = try await GitDiffTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertEqual(diff.text, "diffbody")
        let staged = try await GitStagedDiffTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertEqual(staged.text, "staged-diff")
        let info = try await GitInfoTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertTrue(info.text.contains("branch: main"))
        let commits = try await GitRecentCommitsTool().execute(ToolArgs(raw: #"{"limit":3}"#), in: ctx)
        XCTAssertTrue(commits.text.contains("limit=3"))
        let baseDiff = try await GitDiffBaseTool().execute(ToolArgs(raw: #"{"base":"main"}"#), in: ctx)
        XCTAssertEqual(baseDiff.text, "diff against main")
        let branch = try await GitBranchTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertTrue(branch.text.contains("current: main"))
        let create = try await GitCreateBranchTool().execute(ToolArgs(raw: #"{"name":"feature/git-control","startPoint":"HEAD"}"#), in: ctx)
        XCTAssertTrue(create.text.contains("feature/git-control"))
        let stage = try await GitStageTool().execute(ToolArgs(raw: #"{"paths":["a.swift","sub/b.txt"]}"#), in: ctx)
        XCTAssertEqual(stage.changedFiles, ["a.swift", "sub/b.txt"])
        XCTAssertTrue(stage.text.contains("staged a.swift,sub/b.txt"))
        let unstage = try await GitUnstageTool().execute(ToolArgs(raw: #"{"paths":["a.swift"]}"#), in: ctx)
        XCTAssertEqual(unstage.changedFiles, ["a.swift"])
        let commit = try await GitCommitTool().execute(ToolArgs(raw: #"{"message":"Add git controls"}"#), in: ctx)
        XCTAssertTrue(commit.text.contains("Add git controls"))
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -old
        +new
        """
        let checkArgs = ToolArgs(raw: try jsonString(["diff": patch, "reverse": true]))
        let check = try await GitApplyPatchCheckTool().execute(checkArgs, in: ctx)
        XCTAssertTrue(check.text.contains("check=true"))
        let apply = try await GitApplyPatchTool().execute(ToolArgs(raw: try jsonString(["diff": patch])), in: ctx)
        XCTAssertEqual(apply.changedFiles, ["a.swift"])
        XCTAssertEqual(apply.diff, patch)
        let stagePatch = try await GitStagePatchTool().execute(ToolArgs(raw: try jsonString(["diff": patch])), in: ctx)
        XCTAssertEqual(stagePatch.changedFiles, ["a.swift"])
        XCTAssertNil(stagePatch.diff)
        let unstagePatch = try await GitUnstagePatchTool().execute(ToolArgs(raw: try jsonString(["diff": patch])), in: ctx)
        XCTAssertEqual(unstagePatch.changedFiles, ["a.swift"])
        let revertPatch = try await GitRevertPatchTool().execute(
            ToolArgs(raw: try jsonString(["diff": patch, "confirmRevert": true])),
            in: ctx)
        XCTAssertEqual(revertPatch.changedFiles, ["a.swift"])
        XCTAssertEqual(revertPatch.diff, patch)
        let worktrees = try await GitWorktreeListTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertTrue(worktrees.text.contains("worktree"))
        let createdWorktree = try await GitWorktreeCreateTool().execute(
            ToolArgs(raw: #"{"name":"task-1","startPoint":"HEAD"}"#),
            in: ctx)
        XCTAssertTrue(createdWorktree.text.contains("task-1"))
        let removedWorktree = try await GitWorktreeRemoveTool().execute(
            ToolArgs(raw: #"{"name":"task-1","confirmName":"task-1","force":true}"#),
            in: ctx)
        XCTAssertTrue(removedWorktree.text.contains("force=true"))
        let remotes = try await GitRemotesTool().execute(ToolArgs(raw: "{}"), in: ctx)
        XCTAssertTrue(remotes.text.contains("origin"))
        let fetched = try await GitFetchTool().execute(
            ToolArgs(raw: #"{"remote":"origin","branch":"main","prune":true}"#),
            in: ctx)
        XCTAssertTrue(fetched.text.contains("prune=true"))
        let pulled = try await GitPullFastForwardTool().execute(
            ToolArgs(raw: #"{"remote":"origin","branch":"main","confirmRemote":"origin","confirmBranch":"main"}"#),
            in: ctx)
        XCTAssertTrue(pulled.text.contains("--ff-only"))
        let pushed = try await GitPushTool().execute(
            ToolArgs(raw: #"{"remote":"origin","branch":"main","confirmRemote":"origin","confirmBranch":"main","setUpstream":true}"#),
            in: ctx)
        XCTAssertTrue(pushed.text.contains("setUpstream=true"))
        let switched = try await GitSwitchBranchTool().execute(
            ToolArgs(raw: #"{"branch":"feature/git-control","confirmBranch":"feature/git-control"}"#),
            in: ctx)
        XCTAssertTrue(switched.text.contains("feature/git-control"))
    }

    func testGitStageRejectsEscapingPathBeforeBackend() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await GitStageTool().execute(ToolArgs(raw: #"{"paths":["../outside.txt"]}"#), in: ctx)
            XCTFail("escaping git stage path should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("path escapes workspace"), "\(error)")
        }
    }

    func testGitCreateBranchRejectsUnsafeBranchName() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await GitCreateBranchTool().execute(ToolArgs(raw: #"{"name":"bad..branch"}"#), in: ctx)
            XCTFail("unsafe branch name should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("branch name"), "\(error)")
        }
    }

    func testGitPatchRejectsEscapingPathBeforeBackend() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))
        let patch = """
        diff --git a/../outside.txt b/../outside.txt
        --- a/../outside.txt
        +++ b/../outside.txt
        @@ -1 +1 @@
        -old
        +new
        """

        do {
            _ = try await GitApplyPatchTool().execute(ToolArgs(raw: try jsonString(["diff": patch])), in: ctx)
            XCTFail("escaping git patch path should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("path escapes workspace"), "\(error)")
        }
    }

    func testGitPatchPermissionPathsHandleQuotedDiffGitHeaders() throws {
        let patch = """
        diff --git "a/hello world.txt" "b/hello world.txt"
        new file mode 100644
        """

        let paths = GitApplyPatchTool().touchedPaths(ToolArgs(raw: try jsonString(["diff": patch])))
        XCTAssertEqual(paths, ["hello world.txt"])
    }

    func testGitRevertPatchRequiresExplicitConfirmation() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -old
        +new
        """

        do {
            _ = try await GitRevertPatchTool().execute(
                ToolArgs(raw: try jsonString(["diff": patch, "confirmRevert": false])),
                in: ctx)
            XCTFail("git_revert_patch should require confirmation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("confirmRevert"), "\(error)")
        }
    }

    func testGitWorktreeToolsRejectUnsafeNameAndMismatchedConfirmation() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await GitWorktreeCreateTool().execute(ToolArgs(raw: #"{"name":"../bad"}"#), in: ctx)
            XCTFail("unsafe worktree name should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("worktree name"), "\(error)")
        }

        do {
            _ = try await GitWorktreeRemoveTool().execute(
                ToolArgs(raw: #"{"name":"task-1","confirmName":"task-2"}"#),
                in: ctx)
            XCTFail("worktree removal should require exact confirmation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("confirmName"), "\(error)")
        }
    }

    func testGitRemoteToolsRejectUnsafeRemoteAndMismatchedConfirmation() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await GitFetchTool().execute(ToolArgs(raw: #"{"remote":"https://github.com/example/repo.git"}"#), in: ctx)
            XCTFail("git_fetch should reject URL remotes")
        } catch {
            XCTAssertTrue(String(describing: error).contains("remote"), "\(error)")
        }

        do {
            _ = try await GitPushTool().execute(
                ToolArgs(raw: #"{"remote":"origin","branch":"main","confirmRemote":"upstream","confirmBranch":"main"}"#),
                in: ctx)
            XCTFail("git_push should require exact remote confirmation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("confirmation"), "\(error)")
        }

        do {
            _ = try await GitSwitchBranchTool().execute(
                ToolArgs(raw: #"{"branch":"main","confirmBranch":"feature"}"#),
                in: ctx)
            XCTFail("git_switch should require exact branch confirmation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("confirmBranch"), "\(error)")
        }
    }

    func testGitCommitRejectsStagedSensitivePath() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "A  .env\n", diffText: ""))

        do {
            _ = try await GitCommitTool().execute(ToolArgs(raw: #"{"message":"Commit secret"}"#), in: ctx)
            XCTFail("commit should reject staged sensitive paths")
        } catch {
            XCTAssertTrue(String(describing: error).contains("staged sensitive path"), "\(error)")
        }
    }

    #if canImport(Darwin)
    func testProcessGitServiceRejectsExternalDiffWithoutExecutingIt() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox, let git = gitExecutable() else {
            throw XCTSkip("git and the workspace sandbox are required")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let setupLease = WorkspaceLease(rootPath: ws.path, access: .readWrite, deniedPatterns: [])
        let shell = StructuredProcessShellRunner(timeoutSeconds: 10, workspaceLease: setupLease)
        let initialized = try await shell.run(
            "'\(git)' init; '\(git)' config diff.external ./external-diff.sh",
            cwd: ws)
        XCTAssertEqual(initialized.exitCode, 0, initialized.stderr)
        let script = ws.appendingPathComponent("external-diff.sh")
        try Data("#!/bin/sh\nprintf executed > external-diff-ran\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        do {
            _ = try await ProcessGitService(workspaceLease: setupLease).diff(workspace: ws)
            XCTFail("unsafe external diff config should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("disabled executable hooks/filters"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("external-diff-ran").path))

        let outsideConfig = ws.deletingLastPathComponent().appendingPathComponent("intatis-included-\(UUID().uuidString).gitconfig")
        defer { try? FileManager.default.removeItem(at: outsideConfig) }
        try Data("[diff]\n\texternal = ./external-diff.sh\n".utf8).write(to: outsideConfig)
        let includeSetup = try await shell.run(
            "'\(git)' config --unset diff.external; '\(git)' config 'includeIf.gitdir:/**.path' '\(outsideConfig.path)'",
            cwd: ws)
        XCTAssertEqual(includeSetup.exitCode, 0, includeSetup.stderr)
        do {
            _ = try await ProcessGitService(workspaceLease: setupLease).status(workspace: ws)
            XCTFail("includeIf config should be rejected before Git reads an external config")
        } catch {
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.lowercased().contains("includeif"), rendered)
            XCTAssertFalse(rendered.contains(outsideConfig.path), rendered)
        }
    }

    func testProcessGitServiceAuditsWorktreeConfigAndRejectsSymlink() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox, let git = gitExecutable() else {
            throw XCTSkip("git and the workspace sandbox are required")
        }
        let ws = try tempWorkspace()
        let outside = ws.deletingLastPathComponent().appendingPathComponent("intatis-config-worktree-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: outside)
        }
        let lease = WorkspaceLease(rootPath: ws.path, access: .readWrite, deniedPatterns: [])
        let shell = StructuredProcessShellRunner(timeoutSeconds: 10, workspaceLease: lease)
        let setup = try await shell.run("'\(git)' init", cwd: ws)
        XCTAssertEqual(setup.exitCode, 0, setup.stderr)
        let worktreeConfig = ws.appendingPathComponent(".git/config.worktree")
        try Data("[filter \"owned\"]\n\tprocess = ./untrusted-filter\n".utf8).write(to: worktreeConfig)
        do {
            _ = try await ProcessGitService(workspaceLease: lease).status(workspace: ws)
            XCTFail("dangerous config.worktree should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("filter.owned.process"), "\(error)")
        }
        try FileManager.default.removeItem(at: worktreeConfig)
        try Data("[core]\n\tbare = false\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: worktreeConfig, withDestinationURL: outside)
        do {
            _ = try await ProcessGitService(workspaceLease: lease).status(workspace: ws)
            XCTFail("config.worktree symlink should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("symlinks are not allowed"), "\(error)")
        }
    }

    func testProcessGitServiceHonorsReadOnlyAndDeniedLeaseData() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox, let git = gitExecutable() else {
            throw XCTSkip("git and the workspace sandbox are required")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let setupLease = WorkspaceLease(rootPath: ws.path, access: .readWrite, deniedPatterns: [])
        let shell = StructuredProcessShellRunner(timeoutSeconds: 10, workspaceLease: setupLease)
        try Data("base\n".utf8).write(to: ws.appendingPathComponent("ordinary.txt"))
        try Data("initial-secret\n".utf8).write(to: ws.appendingPathComponent(".env"))
        let setup = try await shell.run(
            "'\(git)' init; '\(git)' config user.email intatis@example.invalid; '\(git)' config user.name Intatis; '\(git)' add ordinary.txt .env; '\(git)' commit -m base",
            cwd: ws)
        XCTAssertEqual(setup.exitCode, 0, setup.stderr)

        try Data("ordinary change\n".utf8).write(to: ws.appendingPathComponent("ordinary.txt"))
        let readOnly = WorkspaceLease(rootPath: ws.path, access: .readOnly, deniedPatterns: [])
        do {
            _ = try await ProcessGitService(workspaceLease: readOnly).stage(paths: ["ordinary.txt"], workspace: ws)
            XCTFail("read-only Git service unexpectedly wrote the index")
        } catch {
            XCTAssertTrue(String(describing: error).contains("failed") || String(describing: error).contains("denied"), "\(error)")
        }

        try Data("new-secret-marker\n".utf8).write(to: ws.appendingPathComponent(".env"))
        let deniedLease = WorkspaceLease(rootPath: ws.path, access: .readOnly)
        do {
            let output = try await ProcessGitService(workspaceLease: deniedLease).diff(workspace: ws)
            XCTAssertFalse(output.contains("new-secret-marker"), output)
        } catch {
            XCTAssertFalse(String(describing: error).contains("new-secret-marker"), "\(error)")
        }
    }
    #endif

    func testProcessGitServiceStagesAndCommitsTempRepoWhenGitAvailable() async throws {
        #if canImport(Darwin)
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_GIT_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_GIT_SMOKE=1 to run the real ProcessGitService smoke")
        }
        guard gitExecutable() != nil else {
            throw XCTSkip("git is required for the ProcessGitService smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let shell = StructuredProcessShellRunner()
        _ = try await shell.run("git init", cwd: ws)
        _ = try await shell.run("git config user.email intatis@example.invalid", cwd: ws)
        _ = try await shell.run("git config user.name 'Intatis Test'", cwd: ws)
        try Data("hello\n".utf8).write(to: ws.appendingPathComponent("hello.txt"))

        let git = ProcessGitService()
        let status = try await git.status(workspace: ws)
        XCTAssertTrue(status.contains("?? hello.txt"), status)
        _ = try await git.stage(paths: ["hello.txt"], workspace: ws)
        let staged = try await git.stagedDiff(workspace: ws)
        XCTAssertTrue(staged.contains("+hello"), staged)
        let commitOutput = try await git.commit(message: "Add hello", workspace: ws)
        XCTAssertTrue(commitOutput.contains("Add hello") || commitOutput.contains("files changed"), commitOutput)
        let info = try await git.repositoryInfo(workspace: ws)
        XCTAssertTrue(info.contains("branch:"), info)
        let commits = try await git.recentCommits(limit: 1, workspace: ws)
        XCTAssertTrue(commits.contains("Add hello"), commits)
        let clean = try await GitStatusTool().execute(
            ToolArgs(raw: "{}"),
            in: ToolContext(workspaceRoot: ws, git: git))
        XCTAssertEqual(clean.text, "clean")

        let patchSource = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: patchSource) }
        _ = try await shell.run("git init", cwd: patchSource)
        _ = try await shell.run("git config user.email intatis@example.invalid", cwd: patchSource)
        _ = try await shell.run("git config user.name 'Intatis Test'", cwd: patchSource)
        try Data("hello\n".utf8).write(to: patchSource.appendingPathComponent("hello.txt"))
        _ = try await shell.run("git add hello.txt", cwd: patchSource)
        _ = try await shell.run("git commit -m base", cwd: patchSource)
        try Data("hello\nfrom patch\n".utf8).write(to: patchSource.appendingPathComponent("hello.txt"))
        let patch = try await git.diff(workspace: patchSource)
        XCTAssertTrue(patch.contains("+from patch"), patch)
        let patchCheck = try await git.applyPatch(diff: patch,
                                                  reverse: false,
                                                  checkOnly: true,
                                                  cached: false,
                                                  workspace: ws)
        XCTAssertTrue(patchCheck.text.contains("patch applies cleanly"), patchCheck.text)
        _ = try await git.applyPatch(diff: patch,
                                     reverse: false,
                                     checkOnly: false,
                                     cached: false,
                                     workspace: ws)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("hello.txt")), "hello\nfrom patch\n")
        _ = try await git.applyPatch(diff: patch,
                                     reverse: true,
                                     checkOnly: false,
                                     cached: false,
                                     workspace: ws)
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("hello.txt")), "hello\n")
        let cleanAfterRevert = try await git.status(workspace: ws)
        XCTAssertTrue(cleanAfterRevert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cleanAfterRevert)

        let worktrees = try await git.worktrees(workspace: ws)
        XCTAssertTrue(worktrees.contains(ws.path), worktrees)
        let createWorktree = try await git.createWorktree(name: "task-1",
                                                          startPoint: "HEAD",
                                                          branch: nil,
                                                          workspace: ws)
        XCTAssertTrue(createWorktree.contains("task-1") || createWorktree.contains("HEAD"), createWorktree)
        let worktreeURL = ws.appendingPathComponent(".intatis/git-worktrees/task-1", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreeURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let worktreeInfo = try await git.repositoryInfo(workspace: worktreeURL)
        XCTAssertTrue(worktreeInfo.contains("/.intatis/git-worktrees/task-1"), worktreeInfo)
        let removeWorktree = try await git.removeWorktree(name: "task-1", force: false, workspace: ws)
        XCTAssertTrue(removeWorktree.contains("task-1") || removeWorktree.contains("removed"), removeWorktree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeURL.path))
        #else
        throw XCTSkip("ProcessGitService smoke requires Darwin")
        #endif
    }

    // MARK: Document/media tools

    func testCompileLatexUsesInjectedFixedBackendAndReportsPDF() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data(#"\documentclass{article}\begin{document}Hi\end{document}"#.utf8)
            .write(to: ws.appendingPathComponent("main.tex"))
        let ctx = ToolContext(
            workspaceRoot: ws,
            documentBackend: FakeTectonicDocumentBackend(),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await CompileLaTeXTool().execute(
            ToolArgs(raw: #"{"inputPath":"main.tex","outputDir":"build"}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["build/main.pdf"])
        XCTAssertTrue(obs.text.contains(#""operation":"compile_latex""#))
        XCTAssertTrue(obs.text.contains(#""tectonic":"0.15.0""#))
    }

    #if canImport(Darwin)
    func testCompileLatexUsesOnlyTectonicAndDisablesShellEscape() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox,
              let runtime = intatisDocumentRuntimeRoot(),
              FileManager.default.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/tectonic").path) else {
            throw XCTSkip("the fixed Tectonic runtime and workspace sandbox are required")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(
            at: ws.appendingPathComponent("build"),
            withIntermediateDirectories: false)
        try Data(#"system("printf rc > latexmkrc-ran");"#.utf8)
            .write(to: ws.appendingPathComponent(".latexmkrc"))
        let source = #"""
        \documentclass{article}
        \begin{document}
        \immediate\write18{touch shell-escape-ran}
        Hardened compile
        \end{document}
        """#
        try Data(source.utf8).write(to: ws.appendingPathComponent("main.tex"))

        let observation = try await CompileLaTeXTool().execute(
            ToolArgs(raw: #"{"inputPath":"main.tex","outputDir":"build"}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertEqual(observation.changedFiles, ["build/main.pdf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("latexmkrc-ran").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("shell-escape-ran").path))
    }

    func testCompileLatexCannotReadOutsideWorkspace() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox,
              let runtime = intatisDocumentRuntimeRoot(),
              FileManager.default.isExecutableFile(
                  atPath: runtime.appendingPathComponent("bin/tectonic").path) else {
            throw XCTSkip("the fixed Tectonic runtime and workspace sandbox are required")
        }
        let ws = try tempWorkspace()
        let outside = ws.deletingLastPathComponent().appendingPathComponent("intatis-tex-outside-\(UUID().uuidString).tex")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("\\typeout{OUTSIDE-DATA-MARKER}\nOutside data\n".utf8).write(to: outside)
        let source = """
        \\documentclass{article}
        \\begin{document}
        \\input{\(outside.path)}
        \\end{document}
        """
        try Data(source.utf8).write(to: ws.appendingPathComponent("main.tex"))
        try FileManager.default.createDirectory(
            at: ws.appendingPathComponent("build"),
            withIntermediateDirectories: false)

        do {
            _ = try await CompileLaTeXTool().execute(
                ToolArgs(raw: #"{"inputPath":"main.tex","outputDir":"build"}"#),
                in: ToolContext(workspaceRoot: ws))
            XCTFail("TeX unexpectedly read an outside-workspace input")
        } catch {
            XCTAssertFalse(String(describing: error).contains("OUTSIDE-DATA-MARKER"), "\(error)")
        }
    }
    #endif

    func testDocumentToolDescriptionsDefineNonOverlappingSelectionContract() {
        let pdf = ReadPDFTool.descriptor.description
        XCTAssertTrue(pdf.contains("never performs OCR"))
        XCTAssertTrue(pdf.contains("ocr_pdf"))

        let readers = [
            ReadDOCXTool.descriptor,
            ReadPPTXTool.descriptor,
            ReadXLSXTool.descriptor,
            ReadHTMLTool.descriptor,
            ReadEPUBTool.descriptor,
        ]
        for reader in readers {
            XCTAssertTrue(reader.description.contains("fixed local Docling"), reader.name)
            XCTAssertTrue(reader.description.contains("no fallback"), reader.name)
        }

        let ocr = OCRPDFTool.descriptor.description
        XCTAssertTrue(ocr.contains("Docling DocumentConverter"))
        XCTAssertTrue(ocr.contains("pinned Tesseract"))

        let render = PDFRenderPageTool.descriptor.description
        XCTAssertTrue(render.contains("exactly one page"))
        XCTAssertTrue(render.contains("PDFPage.draw"))

        let registry = ToolRegistry.standard()
        let export = registry.registration(named: "docx_export_pdf")?.descriptor.description ?? ""
        XCTAssertTrue(export.contains("writer_pdf_Export"))
        XCTAssertTrue(export.contains("no format or backend selection"))

        let write = registry.registration(named: "docx_add_paragraph")?.descriptor.description ?? ""
        XCTAssertTrue(write.contains("Document.add_paragraph"))
        XCTAssertTrue(write.contains("no operations array"))
    }

    func testGenerateImageUsesInjectedService() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws, imageGenerator: FakeImageGenerator())

        let obs = try await GenerateImageTool().execute(
            ToolArgs(raw: #"{"prompt":"clean document icon","outputPath":"art/icon.png","size":"512x512","count":1}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["art/icon.png"])
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("art/icon.png"), encoding: .utf8), "fake-image")
    }

    func testEditImageUsesInjectedService() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let input = ws.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
            .write(to: input)
        let ctx = ToolContext(workspaceRoot: ws, imageGenerator: FakeImageGenerator())

        let observation = try await EditImageTool().execute(
            ToolArgs(raw: #"{"imagePath":"source.png","prompt":"make the sky warmer","outputPath":"art/edited.png"}"#),
            in: ctx)

        XCTAssertEqual(observation.changedFiles, ["art/edited.png"])
        XCTAssertEqual(
            try String(contentsOf: ws.appendingPathComponent("art/edited.png"), encoding: .utf8),
            "fake-edited-image")
    }

    func testEditImageRejectsSameInputAndOutputBeforeCallingService() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let input = ws.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
            .write(to: input)

        do {
            _ = try await EditImageTool().execute(
                ToolArgs(raw: #"{"imagePath":"source.png","prompt":"change it","outputPath":"source.png"}"#),
                in: ToolContext(workspaceRoot: ws, imageGenerator: FakeImageGenerator()))
            XCTFail("same input and output path should be rejected")
        } catch let error as ToolExecutionRejectedWithoutSideEffect {
            XCTAssertEqual(error.code, "edit_image_same_path")
        }
        XCTAssertEqual(try Data(contentsOf: input),
                       Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]))
    }

    func testEditImagePermissionIntentSeparatesReadAndWritePaths() {
        let intent = EditImageTool().permissionIntent(
            ToolArgs(raw: #"{"imagePath":"source.webp","prompt":"change it","outputPath":"result.png"}"#),
            workspaceRoot: URL(fileURLWithPath: "/workspace"))

        XCTAssertEqual(intent.action, "media.edit")
        XCTAssertEqual(intent.dataEffects, [.read, .mutate, .network])
        XCTAssertEqual(intent.replayPolicy, .doNotReplay)
        XCTAssertEqual(intent.resources, [
            PermissionResource(kind: .workspacePath,
                               value: "source.webp",
                               access: .readOnly),
            PermissionResource(kind: .workspacePath,
                               value: "result.png",
                               access: .readWrite),
        ])
    }

    // MARK: Network/browser tools

    func testBrowserNavigateUsesPersistentProfileStateAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"navigate","profile":"work","url":"https://example.com/","title":"Example Domain","text":"Example page text","links":[{"text":"More information","href":"https://iana.org/domains/example"}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","channel":"chromium","headless":true}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("title: Example Domain"))
        XCTAssertTrue(obs.text.contains("Persistent browser profile: .intatis/browser/profiles/work"))
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
        let stateData = try Data(contentsOf: stateURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/")
    }

    func testBrowserOutputReportsInteractiveElementsForForms() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = ##"{"action":"navigate","profile":"work","url":"https://example.com/form","title":"Task Form","text":"Ready to submit","links":[],"elements":[{"role":"textbox","name":"Email","selector":"#email","tag":"input","type":"email","placeholder":"name@example.com","disabled":false},{"role":"combobox","name":"Priority","selector":"#priority","tag":"select","options":["Low","High"]},{"role":"button","name":"Submit request","selector":"#submit","tag":"button"}]}"##
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/form","profile":"work","channel":"chromium","headless":true}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("interactive elements:"), obs.text)
        XCTAssertTrue(obs.text.contains(#"textbox "Email" selector=#email type=email"#), obs.text)
        XCTAssertTrue(obs.text.contains(#"combobox "Priority" selector=#priority options=[Low, High]"#), obs.text)
        XCTAssertTrue(obs.text.contains(#"button "Submit request" selector=#submit"#), obs.text)
    }

    func testBrowserNavigateFallsBackToCDPWhenPlaywrightMissing() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let fallbackStdout = #"{"action":"navigate","profile":"work","backend":"cdp","backendDetail":"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge","url":"https://example.com/","title":"Example Domain","text":"Example page text","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: SequenceShell([
                ShellResult(stdout: "", stderr: "playwright is not installed or not resolvable by Node.", exitCode: 127),
                ShellResult(stdout: fallbackStdout, stderr: "", exitCode: 0),
            ]),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","channel":"msedge","headless":true}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("backend: cdp"))
        XCTAssertTrue(obs.text.contains("Microsoft Edge"))
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let stateData = try Data(contentsOf: stateURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["title"] as? String, "Example Domain")
    }

    func testBrowserHandoffUsesHeadedPersistentProfileAndRecordsHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"handoff","profile":"login","backend":"playwright","backendDetail":"playwright","url":"https://example.com/account","title":"Account","text":"signed in marker","links":[]}"#
        let recorder = CommandRecorder()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(
                recorder: recorder,
                result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserHandoffTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/account","profile":"login","channel":"msedge","handoffSeconds":2,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: handoff"))
        XCTAssertTrue(obs.text.contains("signed in marker"))
        XCTAssertTrue(obs.text.contains("Persistent browser profile: .intatis/browser/profiles/login"))
        let commands = await recorder.all()
        let payload = try browserPayload(from: try XCTUnwrap(commands.first))
        XCTAssertEqual(payload["action"] as? String, "handoff")
        XCTAssertEqual(payload["headless"] as? Bool, false)
        XCTAssertEqual(payload["handoffTimeoutMillis"] as? Int, 2000)
        XCTAssertEqual(payload["profile"] as? String, "login")
        XCTAssertEqual(payload["channel"] as? String, "msedge")

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/login.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/account")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""action":"handoff""#))
        XCTAssertTrue(history.contains(#""profile":"login""#))
    }

    func testBrowserConcurrentProfilesKeepSeparateStateAndHistoryMetadata() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let barrier = AsyncBarrier(expected: 2)
        let stdoutA = #"{"action":"navigate","profile":"profile-a","backend":"cdp","backendDetail":"edge","url":"https://example.com/a","title":"Profile A","text":"profile a marker","links":[]}"#
        let stdoutB = #"{"action":"navigate","profile":"profile-b","backend":"cdp","backendDetail":"edge","url":"https://example.com/b","title":"Profile B","text":"profile b marker","links":[]}"#
        let ctxA = ToolContext(
            workspaceRoot: ws,
            shell: BarrierShell(barrier: barrier, result: ShellResult(stdout: stdoutA, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))
        let ctxB = ToolContext(
            workspaceRoot: ws,
            shell: BarrierShell(barrier: barrier, result: ShellResult(stdout: stdoutB, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        async let first = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/a","profile":"profile-a","channel":"msedge","headless":true}"#),
            in: ctxA)
        async let second = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/b","profile":"profile-b","channel":"msedge","headless":true}"#),
            in: ctxB)
        let (obsA, obsB) = try await (first, second)

        XCTAssertTrue(obsA.text.contains("profile a marker"), obsA.text)
        XCTAssertTrue(obsB.text.contains("profile b marker"), obsB.text)

        let stateAURL = ws.appendingPathComponent(".intatis/browser/state/profile-a.json")
        let stateBURL = ws.appendingPathComponent(".intatis/browser/state/profile-b.json")
        let stateAData = try Data(contentsOf: stateAURL)
        let stateBData = try Data(contentsOf: stateBURL)
        let stateA = try XCTUnwrap(JSONSerialization.jsonObject(with: stateAData) as? [String: Any])
        let stateB = try XCTUnwrap(JSONSerialization.jsonObject(with: stateBData) as? [String: Any])
        XCTAssertEqual(stateA["title"] as? String, "Profile A")
        XCTAssertEqual(stateB["title"] as? String, "Profile B")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""profile":"profile-a""#), historyText)
        XCTAssertTrue(historyText.contains(#""profile":"profile-b""#), historyText)
        let entries = try historyText.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        }
        XCTAssertTrue(entries.contains { $0["profile"] == "profile-a" && $0["url"] == "https://example.com/a" })
        XCTAssertTrue(entries.contains { $0["profile"] == "profile-b" && $0["url"] == "https://example.com/b" })
    }

    func testBrowserCommandsForSameProfileAreSerialized() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let state = ShellOverlapState()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: OverlapDetectingShell(state: state),
            git: FakeGit(statusText: "", diffText: ""))

        async let first = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/one","profile":"shared","channel":"msedge","headless":true}"#),
            in: ctx)
        async let second = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/two","profile":"shared","channel":"msedge","headless":true}"#),
            in: ctx)
        let (obsOne, obsTwo) = try await (first, second)

        let didOverlap = await state.overlapped()
        XCTAssertFalse(didOverlap)
        XCTAssertTrue(obsOne.text.contains("marker"), obsOne.text)
        XCTAssertTrue(obsTwo.text.contains("marker"), obsTwo.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertEqual(historyText.split(separator: "\n").count, 2)
        XCTAssertTrue(historyText.contains(#""profile":"shared""#), historyText)
    }

    func testRealBrowserBackendSmokeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser backend smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("backend: cdp") || obs.text.contains("backend: playwright"))
        XCTAssertTrue(obs.text.contains("Example Domain"))
        XCTAssertTrue(obs.text.contains("Persistent browser profile: .intatis/browser/profiles/smoke"))
    }

    func testRealCDPBrowserIgnoresStaleDevToolsActivePortWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the stale DevToolsActivePort smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let diagnostics = try await BrowserDiagnosticsTool().execute(
            ToolArgs(raw: #"{"profile":"stale-port-smoke","channel":"msedge"}"#),
            in: ToolContext(workspaceRoot: ws))
        if diagnostics.text.contains("playwright available: yes") {
            throw XCTSkip("stale DevToolsActivePort smoke requires the CDP fallback")
        }

        let site = ws.appendingPathComponent("stale-port-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("""
        <!doctype html>
        <title>Stale Port Smoke</title>
        <body>fresh CDP browser marker</body>
        """.utf8).write(to: site.appendingPathComponent("index.html"))
        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/index.html")

        let profileDirectory = ws
            .appendingPathComponent(".intatis/browser/profiles/stale-port-smoke", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true)
        let activePortFile = profileDirectory.appendingPathComponent("DevToolsActivePort")
        try Data("1\n/devtools/browser/forged-stale-endpoint\n".utf8)
            .write(to: activePortFile)

        let observation = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"http://127.0.0.1:\#(port)/index.html","profile":"stale-port-smoke","channel":"msedge","headless":true,"waitMillis":250,"maxCharacters":2000}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(observation.text.contains("backend: cdp"), observation.text)
        XCTAssertTrue(observation.text.contains("fresh CDP browser marker"), observation.text)
        if FileManager.default.fileExists(atPath: activePortFile.path) {
            let current = try String(contentsOf: activePortFile, encoding: .utf8)
            XCTAssertNotEqual(current.split(whereSeparator: \.isNewline).first, "1")
        }
        #else
        throw XCTSkip("real CDP browser smoke requires Darwin")
        #endif
    }

    func testRealBrowserSearchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser search smoke")
        }
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws)

        let obs = try await BrowserSearchTool().execute(
            ToolArgs(raw: #"{"query":"site:example.com example domain","engine":"duckduckgo","profile":"search-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":4000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: search"), obs.text)
        XCTAssertTrue(obs.text.contains("duckduckgo.com"), obs.text)
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"search-smoke""#), history)
        XCTAssertTrue(history.contains(#""action":"search""#), history)
        XCTAssertTrue(history.contains("duckduckgo.com"), history)
    }

    func testRealBrowserHandoffWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_HANDOFF_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_HANDOFF_SMOKE=1 to run the headed browser handoff smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("handoff-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let pageHTML = """
        <!doctype html>
        <title>Intatis Handoff</title>
        <body>handoff marker ready</body>
        """
        try Data(pageHTML.utf8).write(to: site.appendingPathComponent("handoff.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/handoff.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let obs = try await BrowserHandoffTool().execute(
            ToolArgs(raw: #"{"url":"http://127.0.0.1:\#(port)/handoff.html","profile":"handoff-smoke","channel":"msedge","handoffSeconds":1,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: handoff"), obs.text)
        XCTAssertTrue(obs.text.contains("handoff marker ready"), obs.text)
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"handoff""#), historyText)
        #else
        throw XCTSkip("headed browser handoff smoke requires Darwin")
        #endif
    }

    func testRealBrowserProfilePersistsCookieLocalStorageAndHistoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser profile persistence smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let loginHTML = """
        <!doctype html>
        <title>Intatis Login Set</title>
        <body>pending</body>
        <script>
        document.cookie = "intatis_login=present; Max-Age=3600; path=/; SameSite=Lax";
        localStorage.setItem("intatisLocalLogin", "present");
        document.body.innerText = "login marker set";
        </script>
        """
        let stateHTML = """
        <!doctype html>
        <title>Intatis Login State</title>
        <body>pending</body>
        <script>
        document.body.innerText = "cookie=" + document.cookie + "\\nlocal=" + localStorage.getItem("intatisLocalLogin");
        </script>
        """
        try Data(loginHTML.utf8).write(to: site.appendingPathComponent("login.html"))
        try Data(stateHTML.utf8).write(to: site.appendingPathComponent("state.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port)

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/login.html","profile":"session-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        let obs = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/state.html","profile":"session-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("cookie=intatis_login=present"), obs.text)
        XCTAssertTrue(obs.text.contains("local=present"), obs.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains("/login.html"))
        XCTAssertTrue(historyText.contains("/state.html"))
        #else
        throw XCTSkip("real browser profile persistence smoke requires Darwin")
        #endif
    }

    func testRealBrowserBackForwardWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser back/forward smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("history-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let oneHTML = """
        <!doctype html>
        <title>Intatis History One</title>
        <body>history page one marker</body>
        """
        let twoHTML = """
        <!doctype html>
        <title>Intatis History Two</title>
        <body>history page two marker</body>
        """
        try Data(oneHTML.utf8).write(to: site.appendingPathComponent("one.html"))
        try Data(twoHTML.utf8).write(to: site.appendingPathComponent("two.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/one.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/one.html","profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/two.html","profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)

        let back = try await BrowserBackTool().execute(
            ToolArgs(raw: #"{"profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)
        XCTAssertTrue(back.text.contains("browser action: back"), back.text)
        XCTAssertTrue(back.text.contains("history page one marker"), back.text)

        let forward = try await BrowserForwardTool().execute(
            ToolArgs(raw: #"{"profile":"history-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)
        XCTAssertTrue(forward.text.contains("browser action: forward"), forward.text)
        XCTAssertTrue(forward.text.contains("history page two marker"), forward.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"back""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"forward""#), historyText)
        #else
        throw XCTSkip("real browser back/forward smoke requires Darwin")
        #endif
    }

    func testRealBrowserProfilesRemainIsolatedWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser profile isolation smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("isolation-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let profileHTML = """
        <!doctype html>
        <title>Intatis Profile Isolation</title>
        <body>pending</body>
        <script>
        const params = new URLSearchParams(window.location.search);
        const marker = params.get("marker");
        if (marker) {
          document.cookie = "intatis_profile_marker=" + marker + "; Max-Age=3600; path=/; SameSite=Lax";
          localStorage.setItem("intatisProfileMarker", marker);
        }
        document.body.innerText = "cookie=" + document.cookie + "\\nlocal=" + localStorage.getItem("intatisProfileMarker");
        </script>
        """
        try Data(profileHTML.utf8).write(to: site.appendingPathComponent("profile.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/profile.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html?marker=profile-a-marker","profile":"isolation-a","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html?marker=profile-b-marker","profile":"isolation-b","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        let obsA = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html","profile":"isolation-a","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)
        let obsB = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/profile.html","profile":"isolation-b","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"#),
            in: ctx)

        XCTAssertTrue(obsA.text.contains("intatis_profile_marker=profile-a-marker"), obsA.text)
        XCTAssertTrue(obsA.text.contains("local=profile-a-marker"), obsA.text)
        XCTAssertFalse(obsA.text.contains("profile-b-marker"), obsA.text)
        XCTAssertTrue(obsB.text.contains("intatis_profile_marker=profile-b-marker"), obsB.text)
        XCTAssertTrue(obsB.text.contains("local=profile-b-marker"), obsB.text)
        XCTAssertFalse(obsB.text.contains("profile-a-marker"), obsB.text)

        let historyA = try await BrowserHistoryTool().execute(
            ToolArgs(raw: #"{"profile":"isolation-a","limit":10}"#),
            in: ctx)
        let historyB = try await BrowserHistoryTool().execute(
            ToolArgs(raw: #"{"profile":"isolation-b","limit":10}"#),
            in: ctx)
        XCTAssertTrue(historyA.text.contains("[isolation-a]"), historyA.text)
        XCTAssertFalse(historyA.text.contains("[isolation-b]"), historyA.text)
        XCTAssertTrue(historyB.text.contains("[isolation-b]"), historyB.text)
        XCTAssertFalse(historyB.text.contains("[isolation-a]"), historyB.text)
        #else
        throw XCTSkip("real browser profile isolation smoke requires Darwin")
        #endif
    }

    func testRealBrowserDifferentProfilesCanLaunchConcurrentlyWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_CONCURRENCY_SMOKE=1 to run the real browser concurrent profile smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("concurrent-profile-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }

        let pageA = """
        <!doctype html>
        <title>Intatis Concurrent A</title>
        <body>
        <h1>Concurrent profile A</h1>
        <p>concurrent profile A marker</p>
        </body>
        """
        let pageB = """
        <!doctype html>
        <title>Intatis Concurrent B</title>
        <body>
        <h1>Concurrent profile B</h1>
        <p>concurrent profile B marker</p>
        </body>
        """
        try Data(pageA.utf8).write(to: site.appendingPathComponent("a.html"))
        try Data(pageB.utf8).write(to: site.appendingPathComponent("b.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/a.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        async let first = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/a.html","profile":"concurrent-a","channel":"msedge","headless":true,"waitMillis":750,"maxCharacters":2000}"#),
            in: ctx)
        async let second = BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/b.html","profile":"concurrent-b","channel":"msedge","headless":true,"waitMillis":750,"maxCharacters":2000}"#),
            in: ctx)
        let (obsA, obsB) = try await (first, second)

        XCTAssertTrue(obsA.text.contains("concurrent profile A marker"), obsA.text)
        XCTAssertTrue(obsB.text.contains("concurrent profile B marker"), obsB.text)

        let stateAURL = ws.appendingPathComponent(".intatis/browser/state/concurrent-a.json")
        let stateBURL = ws.appendingPathComponent(".intatis/browser/state/concurrent-b.json")
        let stateA = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateAURL)) as? [String: Any])
        let stateB = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateBURL)) as? [String: Any])
        XCTAssertEqual(stateA["profile"] as? String, "concurrent-a")
        XCTAssertEqual(stateB["profile"] as? String, "concurrent-b")
        XCTAssertTrue((stateA["url"] as? String)?.hasSuffix("/a.html") == true, "\(stateA)")
        XCTAssertTrue((stateB["url"] as? String)?.hasSuffix("/b.html") == true, "\(stateB)")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""profile":"concurrent-a""#), historyText)
        XCTAssertTrue(historyText.contains(#""profile":"concurrent-b""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"navigate""#), historyText)
        #else
        throw XCTSkip("real browser concurrent profile smoke requires Darwin")
        #endif
    }

    func testRealBrowserUploadDownloadWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser upload/download smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let uploadDir = ws.appendingPathComponent("upload", isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        try Data("upload-body".utf8).write(to: uploadDir.appendingPathComponent("report.txt"))

        let formHTML = """
        <!doctype html>
        <title>Intatis Upload Download</title>
        <body>
        <label for="file">Upload file</label>
        <input id="file" type="file">
        <pre id="status">waiting</pre>
        <a id="download" href="#" download="report.txt">Download report</a>
        <script>
        const blob = new Blob(["download-body-secret"], { type: "text/plain" });
        document.getElementById("download").href = URL.createObjectURL(blob);
        document.getElementById("file").addEventListener("change", () => {
          const file = document.getElementById("file").files[0];
          document.getElementById("status").innerText = file ? "uploaded " + file.name : "no file";
        });
        </script>
        </body>
        """
        let site = ws.appendingPathComponent("upload-download-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data(formHTML.utf8).write(to: site.appendingPathComponent("index.html"))
        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/index.html")
        let pageURL = "http://127.0.0.1:\(port)/index.html"
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/io-smoke.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statePayload: [String: String] = [
            "profile": "io-smoke",
            "url": pageURL,
            "title": "Intatis Upload Download",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let stateData = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
        try stateData.write(to: stateURL, options: .atomic)

        let ctx = ToolContext(workspaceRoot: ws)

        let upload = try await BrowserUploadFileTool().execute(
            ToolArgs(raw: ##"{"selector":"#file","filePath":"upload/report.txt","profile":"io-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        XCTAssertTrue(upload.text.contains("uploaded files:"), upload.text)
        XCTAssertTrue(upload.text.contains("upload/report.txt"), upload.text)
        XCTAssertTrue(upload.text.contains("uploaded report.txt"), upload.text)

        let download = try await BrowserDownloadTool().execute(
            ToolArgs(raw: ##"{"selector":"#download","profile":"io-smoke","channel":"msedge","headless":true,"downloadTimeoutMillis":10000,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        let changed = try XCTUnwrap(download.changedFiles)
        XCTAssertEqual(changed.count, 1)
        let downloadedPath = changed[0]
        XCTAssertTrue(downloadedPath.hasPrefix(".intatis/browser/downloads/io-smoke/"), downloadedPath)
        XCTAssertTrue(downloadedPath.hasSuffix(".txt"), downloadedPath)
        XCTAssertTrue(download.text.contains("downloads:"), download.text)

        let downloadedURL = try PathConfinement.resolve(downloadedPath, within: ws)
        XCTAssertEqual(try String(contentsOf: downloadedURL, encoding: .utf8), "download-body-secret")

        let listed = try await BrowserDownloadsTool().execute(
            ToolArgs(raw: #"{"profile":"io-smoke","limit":10}"#),
            in: ctx)

        XCTAssertTrue(listed.text.contains("browser downloads: 1 file"), listed.text)
        XCTAssertTrue(listed.text.contains(".intatis/browser/downloads/io-smoke/"), listed.text)
        XCTAssertFalse(listed.text.contains("download-body-secret"), listed.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"upload""#))
        XCTAssertTrue(historyText.contains(#""action":"download""#))
        #else
        throw XCTSkip("real browser upload/download smoke requires Darwin")
        #endif
    }

    func testRealBrowserSelectAndPressKeyWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser select/press smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let formHTML = """
        <!doctype html>
        <title>Intatis Select Press</title>
        <body>
        <label for="color">Color</label>
        <select id="color">
          <option value="red">Red</option>
          <option value="blue">Blue</option>
        </select>
        <input id="q" value="ready">
        <pre id="status">waiting</pre>
        <script>
        const status = document.getElementById("status");
        document.getElementById("color").addEventListener("change", (event) => {
          status.innerText = "color=" + event.target.value;
        });
        document.getElementById("q").addEventListener("keydown", (event) => {
          if (event.key === "Enter") status.innerText = "pressed Enter value=" + event.target.value;
        });
        </script>
        </body>
        """
        let site = ws.appendingPathComponent("select-press-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data(formHTML.utf8).write(to: site.appendingPathComponent("index.html"))
        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/index.html")
        let pageURL = "http://127.0.0.1:\(port)/index.html"
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/form-smoke.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statePayload: [String: String] = [
            "profile": "form-smoke",
            "url": pageURL,
            "title": "Intatis Select Press",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let stateData = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
        try stateData.write(to: stateURL, options: .atomic)

        let ctx = ToolContext(workspaceRoot: ws)

        let select = try await BrowserSelectOptionTool().execute(
            ToolArgs(raw: ##"{"selector":"#color","optionValue":"blue","profile":"form-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(select.text.contains("color=blue"), select.text)
        XCTAssertTrue(select.text.contains("interactive elements:"), select.text)
        XCTAssertTrue(select.text.contains(#"combobox "Color" selector=#color"#), select.text)
        XCTAssertTrue(select.text.contains("options=[Red, Blue]"), select.text)

        let press = try await BrowserPressKeyTool().execute(
            ToolArgs(raw: ##"{"selector":"#q","key":"Enter","profile":"form-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(press.text.contains("pressed Enter value=ready"), press.text)
        XCTAssertTrue(press.text.contains("textbox selector=#q"), press.text)
        #else
        throw XCTSkip("real browser select/press smoke requires Darwin")
        #endif
    }

    func testRealBrowserSubmitWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser submit smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("submit-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let formHTML = """
        <!doctype html>
        <title>Intatis Submit Form</title>
        <body>
        <form id="request" method="get" action="/submitted.html">
          <label for="q">Request</label>
          <input id="q" name="q" value="ready-submit-marker">
          <button id="submit" type="submit">Send request</button>
        </form>
        </body>
        """
        let submittedHTML = """
        <!doctype html>
        <title>Intatis Submit Result</title>
        <body>submitted marker reached</body>
        """
        try Data(formHTML.utf8).write(to: site.appendingPathComponent("form.html"))
        try Data(submittedHTML.utf8).write(to: site.appendingPathComponent("submitted.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/form.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/form.html","profile":"submit-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)

        let submit = try await BrowserSubmitTool().execute(
            ToolArgs(raw: ##"{"selector":"#submit","profile":"submit-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        XCTAssertTrue(submit.text.contains("browser action: submit"), submit.text)
        XCTAssertTrue(submit.text.contains("submitted marker reached"), submit.text)
        XCTAssertTrue(submit.text.contains("/submitted.html"), submit.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"submit""#), historyText)
        XCTAssertTrue(historyText.contains("/submitted.html"), historyText)
        #else
        throw XCTSkip("real browser submit smoke requires Darwin")
        #endif
    }

    func testRealBrowserPopupNewPageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser popup/new-page smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("popup-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        let indexHTML = """
        <!doctype html>
        <title>Intatis Popup Source</title>
        <body>
        <a id="open" href="/popup.html" target="_blank" rel="noopener">Open popup page</a>
        </body>
        """
        let popupHTML = """
        <!doctype html>
        <title>Intatis Popup Result</title>
        <body>popup page marker reached</body>
        """
        try Data(indexHTML.utf8).write(to: site.appendingPathComponent("index.html"))
        try Data(popupHTML.utf8).write(to: site.appendingPathComponent("popup.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/index.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/index.html","profile":"popup-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":2000}"#),
            in: ctx)

        let click = try await BrowserClickTool().execute(
            ToolArgs(raw: ##"{"selector":"#open","profile":"popup-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)

        XCTAssertTrue(click.text.contains("browser action: click"), click.text)
        XCTAssertTrue(click.text.contains("popup page marker reached"), click.text)
        XCTAssertTrue(click.text.contains("selected new page:"), click.text)
        XCTAssertTrue(click.text.contains("/popup.html"), click.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"click""#), historyText)
        XCTAssertTrue(historyText.contains("/popup.html"), historyText)
        #else
        throw XCTSkip("real browser popup/new-page smoke requires Darwin")
        #endif
    }

    func testRealBrowserScrollAndWaitWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser scroll/wait smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()

        let site = ws.appendingPathComponent("scroll-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let pageHTML = """
        <!doctype html>
        <title>Intatis Scroll Wait</title>
        <style>
        body { min-height: 2400px; font-family: sans-serif; }
        #status { margin-top: 1600px; }
        </style>
        <body>
        <p>top marker</p>
        <pre id="status">waiting</pre>
        <script>
        window.addEventListener("scroll", () => {
          if (window.scrollY > 300) document.getElementById("status").innerText = "scrolled marker";
        });
        setTimeout(() => {
          document.getElementById("status").innerText += " loaded later";
        }, 500);
        </script>
        </body>
        """
        try Data(pageHTML.utf8).write(to: site.appendingPathComponent("scroll.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/scroll.html")

        let pageURL = "http://127.0.0.1:\(port)/scroll.html"
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/scroll-smoke.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statePayload: [String: String] = [
            "profile": "scroll-smoke",
            "url": pageURL,
            "title": "Intatis Scroll Wait",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let stateData = try JSONSerialization.data(withJSONObject: statePayload, options: [.prettyPrinted, .sortedKeys])
        try stateData.write(to: stateURL, options: .atomic)

        let ctx = ToolContext(workspaceRoot: ws)

        let scroll = try await BrowserScrollTool().execute(
            ToolArgs(raw: ##"{"direction":"down","amount":900,"profile":"scroll-smoke","channel":"msedge","headless":true,"waitMillis":1000,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(scroll.text.contains("scrolled marker") || scroll.text.contains("loaded later"), scroll.text)

        let waited = try await BrowserWaitTool().execute(
            ToolArgs(raw: ##"{"text":"loaded later","profile":"scroll-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":100,"maxCharacters":2000}"##),
            in: ctx)
        XCTAssertTrue(waited.text.contains("loaded later"), waited.text)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"scroll""#))
        XCTAssertTrue(historyText.contains(#""action":"wait""#))
        #else
        throw XCTSkip("real browser scroll/wait smoke requires Darwin")
        #endif
    }

    func testRealBrowserDynamicFeedAndOnlineTaskWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTATIS_REAL_BROWSER_SMOKE"] == "1" else {
            throw XCTSkip("set INTATIS_REAL_BROWSER_SMOKE=1 to run the real browser dynamic feed/task smoke")
        }

        #if canImport(Darwin)
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let site = ws.appendingPathComponent("feed-task-site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)

        let feedHTML = """
        <!doctype html>
        <title>Intatis Social Feed Smoke</title>
        <style>
        body { margin: 0; min-height: 2200px; font-family: sans-serif; }
        header { position: sticky; top: 0; padding: 16px; background: white; border-bottom: 1px solid #d0d7de; }
        main { max-width: 720px; padding: 24px; }
        article { padding: 18px 0; border-bottom: 1px solid #d0d7de; }
        #new-posts { margin-top: 780px; padding: 18px; background: #f6f8fa; }
        </style>
        <body>
        <header>
          <h1>Social Feed</h1>
          <a id="task-link" href="/task.html">Open task</a>
        </header>
        <main>
          <section aria-label="Timeline">
            <h2>Timeline</h2>
            <article>Alice posted Launch update</article>
            <article>Ben posted Support handoff</article>
            <button id="load-more" type="button">Load more</button>
            <section id="new-posts" hidden>
              <article>Cara posted Incident review</article>
              <a href="/task.html">Convert to task</a>
            </section>
          </section>
        </main>
        <script>
        const newPosts = document.getElementById("new-posts");
        function revealNewPosts() {
          newPosts.hidden = false;
        }
        window.addEventListener("scroll", () => {
          if (window.scrollY > 300) revealNewPosts();
        });
        document.getElementById("load-more").addEventListener("click", revealNewPosts);
        setTimeout(revealNewPosts, 1500);
        </script>
        </body>
        """
        let taskHTML = """
        <!doctype html>
        <title>Intatis Online Task</title>
        <body>
        <h1>Online Task</h1>
        <form id="task-form" method="get" action="/done.html">
          <label for="request">Request</label>
          <input id="request" name="request" autocomplete="off">
          <button id="submit-task" type="submit">Submit task</button>
        </form>
        <script>
        document.getElementById("task-form").addEventListener("submit", (event) => {
          event.preventDefault();
          window.location.href = "/done.html";
        });
        </script>
        </body>
        """
        let doneHTML = """
        <!doctype html>
        <title>Intatis Task Done</title>
        <body>Task completed. Reference 77.</body>
        """
        try Data(feedHTML.utf8).write(to: site.appendingPathComponent("feed.html"))
        try Data(taskHTML.utf8).write(to: site.appendingPathComponent("task.html"))
        try Data(doneHTML.utf8).write(to: site.appendingPathComponent("done.html"))

        let port = try freeLoopbackPort()
        let server = try startStaticHTTPServer(directory: site, port: port)
        defer {
            if server.isRunning {
                server.terminate()
            }
        }
        try await waitForHTTPServer(port: port, path: "/feed.html")

        let ctx = ToolContext(workspaceRoot: ws)
        let baseURL = "http://127.0.0.1:\(port)"

        let navigate = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"\#(baseURL)/feed.html","profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":3000}"#),
            in: ctx)
        XCTAssertTrue(navigate.text.contains("Social Feed"), navigate.text)
        XCTAssertTrue(navigate.text.contains("Timeline"), navigate.text)
        XCTAssertTrue(navigate.text.contains("Alice posted Launch update"), navigate.text)

        let scroll = try await BrowserScrollTool().execute(
            ToolArgs(raw: ##"{"direction":"down","amount":1200,"profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(scroll.text.contains("browser action: scroll"), scroll.text)

        let waited = try await BrowserWaitTool().execute(
            ToolArgs(raw: ##"{"text":"Cara posted Incident review","profile":"feed-task-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":200,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(waited.text.contains("Cara posted Incident review"), waited.text)

        let click = try await BrowserClickTool().execute(
            ToolArgs(raw: ##"{"selector":"#task-link","profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":500,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(click.text.contains("Online Task"), click.text)

        let type = try await BrowserTypeTool().execute(
            ToolArgs(raw: ##"{"selector":"#request","value":"summarize feed","profile":"feed-task-smoke","channel":"msedge","headless":true,"waitMillis":100,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(type.text.contains("browser action: type"), type.text)
        XCTAssertFalse(type.text.contains("summarize feed"), type.text)

        let submit = try await BrowserSubmitTool().execute(
            ToolArgs(raw: ##"{"selector":"#submit-task","profile":"feed-task-smoke","channel":"msedge","headless":true,"timeoutMillis":5000,"waitMillis":500,"maxCharacters":3000}"##),
            in: ctx)
        XCTAssertTrue(submit.text.contains("browser action: submit"), submit.text)
        XCTAssertTrue(submit.text.contains("Task completed. Reference 77."), submit.text)
        XCTAssertTrue(submit.text.contains("/done.html"), submit.text)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/feed-task-smoke.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["profile"] as? String, "feed-task-smoke")
        XCTAssertTrue((state["url"] as? String)?.hasSuffix("/done.html") == true, "\(state)")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""profile":"feed-task-smoke""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"navigate""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"scroll""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"wait""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"click""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"type""#), historyText)
        XCTAssertTrue(historyText.contains(#""action":"submit""#), historyText)
        #else
        throw XCTSkip("real browser dynamic feed/task smoke requires Darwin")
        #endif
    }

    func testBrowserToolRejectsInvalidProfileName() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(workspaceRoot: ws,
                              shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
                              git: FakeGit(statusText: "", diffText: ""))
        do {
            _ = try await BrowserNavigateTool().execute(
                ToolArgs(raw: #"{"url":"https://example.com","profile":"../secret"}"#),
                in: ctx)
            XCTFail("invalid profile should be rejected")
        } catch {
            // expected
        }
    }

    func testBrowserTypeRedactsTypedValueFromObservation() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"type","profile":"work","url":"https://example.com/form","title":"Form","text":"Saved secret-value successfully","links":[{"text":"secret-value result","href":"https://example.com/search?q=secret-value"}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserTypeTool().execute(
            ToolArgs(raw: ##"{"selector":"#q","value":"secret-value","profile":"work"}"##),
            in: ctx)

        XCTAssertFalse(obs.text.contains("secret-value"))
        XCTAssertTrue(obs.text.contains("[redacted input]"))
    }

    func testBrowserTypeRejectsLikelyPasswordTargetBeforeShell() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(
                recorder: recorder,
                result: ShellResult(stdout: #"{"action":"type","profile":"work"}"#, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserTypeTool().execute(
                ToolArgs(raw: ##"{"selector":"input[type=password]","value":"hunter2","profile":"work"}"##),
                in: ctx)
            XCTFail("password targets should be refused before launching the browser backend")
        } catch {
            XCTAssertTrue(String(describing: error).contains("browser_handoff"), "\(error)")
        }
        let commands = await recorder.all()
        XCTAssertTrue(commands.isEmpty)
    }

    func testBrowserTypeRejectsVerificationCodeTargetBeforeShell() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(
                recorder: recorder,
                result: ShellResult(stdout: #"{"action":"type","profile":"work"}"#, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserTypeTool().execute(
                ToolArgs(raw: ##"{"role":"textbox","name":"Verification code","value":"123456","profile":"work"}"##),
                in: ctx)
            XCTFail("verification code targets should be refused before launching the browser backend")
        } catch {
            XCTAssertTrue(String(describing: error).contains("browser_handoff"), "\(error)")
        }
        let commands = await recorder.all()
        XCTAssertTrue(commands.isEmpty)
    }

    func testBrowserSubmitReportsPageTextPayloadAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let stdout = #"{"action":"submit","profile":"work","url":"https://example.com/result","title":"Result","text":"Form submitted","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: RecordingShell(recorder: recorder, result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserSubmitTool().execute(
            ToolArgs(raw: #"{"profile":"work","timeoutMillis":2000}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: submit"))
        XCTAssertTrue(obs.text.contains("Form submitted"))
        let commands = await recorder.all()
        XCTAssertEqual(commands.count, 1)
        let payload = try browserPayload(from: commands[0])
        XCTAssertEqual(payload["action"] as? String, "submit")
        XCTAssertEqual(payload["profile"] as? String, "work")
        XCTAssertEqual(payload["timeoutMillis"] as? Int, 2000)
        XCTAssertNil(payload["selector"])
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"submit""#))
    }

    func testBrowserClickReportsAndPersistsOpenedPage() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"click","profile":"work","backend":"playwright","url":"https://example.com/popup","title":"Popup","text":"Popup ready","links":[],"openedPage":{"url":"https://example.com/popup","title":"Popup"},"pageCount":2}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserClickTool().execute(
            ToolArgs(raw: ##"{"selector":"#open","profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("selected new page: Popup - https://example.com/popup"), obs.text)
        XCTAssertTrue(obs.text.contains("open pages observed: 2"), obs.text)
        XCTAssertTrue(obs.text.contains("Popup ready"), obs.text)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/popup")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let historyText = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(historyText.contains(#""action":"click""#), historyText)
        XCTAssertTrue(historyText.contains(#""url":"https:\/\/example.com\/popup""#), historyText)
    }

    func testBrowserSelectOptionReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"select","profile":"work","url":"https://example.com/form","title":"Form","text":"Selected Blue","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserSelectOptionTool().execute(
            ToolArgs(raw: ##"{"selector":"#color","optionLabel":"Blue","profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: select"))
        XCTAssertTrue(obs.text.contains("Selected Blue"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"select""#))
    }

    func testBrowserPressKeyCanTargetElementAndReportsHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"press","profile":"work","url":"https://example.com/form","title":"Form","text":"Submitted","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserPressKeyTool().execute(
            ToolArgs(raw: ##"{"selector":"#q","key":"Enter","profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: press"))
        XCTAssertTrue(obs.text.contains("Submitted"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"press""#))
    }

    func testBrowserPressKeyRejectsControlCharacters() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserPressKeyTool().execute(
                ToolArgs(raw: #"{"key":"En\nter"}"#),
                in: ctx)
            XCTFail("control characters should be rejected")
        } catch {
            // expected
        }
    }

    func testBrowserScrollReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"scroll","profile":"work","url":"https://example.com/feed","title":"Feed","text":"Older feed item loaded","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserScrollTool().execute(
            ToolArgs(raw: ##"{"direction":"down","amount":1200,"profile":"work"}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: scroll"))
        XCTAssertTrue(obs.text.contains("Older feed item loaded"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"scroll""#))
    }

    func testBrowserScrollRejectsZeroDelta() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: "", stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserScrollTool().execute(
                ToolArgs(raw: #"{"deltaX":0,"deltaY":0}"#),
                in: ctx)
            XCTFail("zero scroll delta should be rejected")
        } catch {
            // expected
        }
    }

    func testBrowserWaitReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"wait","profile":"work","url":"https://example.com/app","title":"App","text":"Async panel loaded","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserWaitTool().execute(
            ToolArgs(raw: ##"{"text":"Async panel","profile":"work","timeoutMillis":3000}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: wait"))
        XCTAssertTrue(obs.text.contains("Async panel loaded"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"wait""#))
    }

    func testBrowserReloadReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"reload","profile":"work","url":"https://example.com/feed","title":"Feed","text":"Feed refreshed","links":[]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserReloadTool().execute(
            ToolArgs(raw: ##"{"profile":"work","ignoreCache":true,"waitMillis":100}"##),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: reload"))
        XCTAssertTrue(obs.text.contains("Feed refreshed"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"reload""#))
    }

    func testBrowserBackForwardReportsPageTextAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let shell = SequenceShell([
            ShellResult(stdout: #"{"action":"navigate","profile":"work","url":"https://example.com/one","title":"One","text":"First page","links":[]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"action":"navigate","profile":"work","url":"https://example.com/two","title":"Two","text":"Second page","links":[]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"action":"back","profile":"work","url":"https://example.com/one","title":"One","text":"First page again","links":[]}"#, stderr: "", exitCode: 0),
            ShellResult(stdout: #"{"action":"forward","profile":"work","url":"https://example.com/two","title":"Two","text":"Second page again","links":[]}"#, stderr: "", exitCode: 0),
        ])
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: shell,
            git: FakeGit(statusText: "", diffText: ""))

        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/one","profile":"work","waitMillis":0}"#),
            in: ctx)
        _ = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com/two","profile":"work","waitMillis":0}"#),
            in: ctx)

        let back = try await BrowserBackTool().execute(
            ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
            in: ctx)
        XCTAssertTrue(back.text.contains("browser action: back"))
        XCTAssertTrue(back.text.contains("https://example.com/one"))
        XCTAssertTrue(back.text.contains("First page again"))

        let forward = try await BrowserForwardTool().execute(
            ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
            in: ctx)
        XCTAssertTrue(forward.text.contains("browser action: forward"))
        XCTAssertTrue(forward.text.contains("https://example.com/two"))
        XCTAssertTrue(forward.text.contains("Second page again"))

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""action":"back""#))
        XCTAssertTrue(history.contains(#""action":"forward""#))

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["navigationIndex"] as? Int, 1)
        let stack = (state["navigationStack"] as? [Any])?.compactMap { $0 as? String }
        XCTAssertEqual(stack, ["https://example.com/one", "https://example.com/two"])
    }

    func testBrowserSnapshotRejectsForgedStateURLBeforeBackendAndAllowsHTTPURLs() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        func writeStateURL(_ value: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["url": value])
            try data.write(to: stateURL, options: .atomic)
        }

        let recorder = CommandRecorder()
        let backend = RecordingShell(
            recorder: recorder,
            result: ShellResult(
                stdout: #"{"action":"snapshot","profile":"work","backend":"fake","url":"https://example.com/snapshot","title":"Snapshot","text":"safe persisted URL marker","links":[]}"#,
                stderr: "",
                exitCode: 0))
        let context = ToolContext(
            workspaceRoot: ws,
            shell: backend,
            browserBackendShell: backend,
            git: FakeGit(statusText: "", diffText: ""))

        try writeStateURL("file:///etc/passwd")
        do {
            _ = try await BrowserSnapshotTool().execute(
                ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
                in: context)
            XCTFail("forged file URL unexpectedly reached the browser backend")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("URL must be http(s) with a host"),
                message)
        }
        let commandsAfterForgedState = await recorder.all()
        XCTAssertTrue(commandsAfterForgedState.isEmpty)

        for allowedURL in [
            "http://example.com/from-state",
            "https://example.com/from-state",
        ] {
            try writeStateURL(allowedURL)
            let observation = try await BrowserSnapshotTool().execute(
                ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
                in: context)
            XCTAssertTrue(
                observation.text.contains("safe persisted URL marker"),
                observation.text)
        }
        let commandsAfterAllowedStates = await recorder.all()
        XCTAssertEqual(commandsAfterAllowedStates.count, 2)
    }

    func testBrowserHistoryNavigationRejectsForgedTargetsBeforeBackendAndAllowsHTTPURLs() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        func writeNavigationState(stack: [String], index: Int) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "url": stack[index],
                "navigationStack": stack,
                "navigationIndex": index,
            ])
            try data.write(to: stateURL, options: .atomic)
        }

        let recorder = CommandRecorder()
        let backBackend = RecordingShell(
            recorder: recorder,
            result: ShellResult(
                stdout: #"{"action":"back","profile":"work","backend":"fake","url":"http://example.com/one","title":"One","text":"safe back marker","links":[]}"#,
                stderr: "",
                exitCode: 0))
        let forwardBackend = RecordingShell(
            recorder: recorder,
            result: ShellResult(
                stdout: #"{"action":"forward","profile":"work","backend":"fake","url":"https://example.com/two","title":"Two","text":"safe forward marker","links":[]}"#,
                stderr: "",
                exitCode: 0))
        let backContext = ToolContext(
            workspaceRoot: ws,
            shell: backBackend,
            browserBackendShell: backBackend,
            git: FakeGit(statusText: "", diffText: ""))
        let forwardContext = ToolContext(
            workspaceRoot: ws,
            shell: forwardBackend,
            browserBackendShell: forwardBackend,
            git: FakeGit(statusText: "", diffText: ""))

        try writeNavigationState(
            stack: ["file:///etc/passwd", "https://example.com/current"],
            index: 1)
        do {
            _ = try await BrowserBackTool().execute(
                ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
                in: backContext)
            XCTFail("forged back target unexpectedly reached the browser backend")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("URL must be http(s) with a host")
                    || message.contains("no previous browser history entry"),
                message)
        }
        let commandsAfterForgedBack = await recorder.all()
        XCTAssertTrue(commandsAfterForgedBack.isEmpty)

        try writeNavigationState(
            stack: ["https://example.com/current", "file:///etc/passwd"],
            index: 0)
        do {
            _ = try await BrowserForwardTool().execute(
                ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
                in: forwardContext)
            XCTFail("forged forward target unexpectedly reached the browser backend")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("URL must be http(s) with a host")
                    || message.contains("no next browser history entry"),
                message)
        }
        let commandsAfterForgedForward = await recorder.all()
        XCTAssertTrue(commandsAfterForgedForward.isEmpty)

        let safeStack = [
            "http://example.com/one",
            "https://example.com/two",
        ]
        try writeNavigationState(stack: safeStack, index: 1)
        let back = try await BrowserBackTool().execute(
            ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
            in: backContext)
        XCTAssertTrue(back.text.contains("safe back marker"), back.text)

        try writeNavigationState(stack: safeStack, index: 0)
        let forward = try await BrowserForwardTool().execute(
            ToolArgs(raw: #"{"profile":"work","waitMillis":0}"#),
            in: forwardContext)
        XCTAssertTrue(forward.text.contains("safe forward marker"), forward.text)

        let commands = await recorder.all()
        XCTAssertEqual(commands.count, 2)
        let backPayload = try browserPayload(from: commands[0])
        let forwardPayload = try browserPayload(from: commands[1])
        XCTAssertEqual(backPayload["action"] as? String, "back")
        XCTAssertEqual(backPayload["url"] as? String, safeStack[0])
        XCTAssertEqual(forwardPayload["action"] as? String, "forward")
        XCTAssertEqual(forwardPayload["url"] as? String, safeStack[1])
    }

    func testBrowserDiagnosticsReportsBackendAvailability() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"diagnostics","nodeVersion":"v26.3.0","platform":"darwin","arch":"arm64","channel":"chromium","profile":"work","profileDir":"/tmp/profile","downloadsDir":"/tmp/downloads","stateFile":"/tmp/state.json","historyFile":"/tmp/history.jsonl","playwrightAvailable":false,"checkedLocations":["node resolution: playwright","/opt/homebrew/lib/node_modules/playwright"],"nodeWebSocketAvailable":true,"cdpAvailable":true,"cdpExecutable":"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge","browserApps":{"chrome":true,"edge":false}}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserDiagnosticsTool().execute(
            ToolArgs(raw: #"{"profile":"work","channel":"chromium"}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("node: v26.3.0"))
        XCTAssertTrue(obs.text.contains("playwright available: no"))
        XCTAssertTrue(obs.text.contains("node WebSocket available: yes"))
        XCTAssertTrue(obs.text.contains("cdp fallback available: yes"))
        XCTAssertTrue(obs.text.contains("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"))
        XCTAssertTrue(obs.text.contains("/opt/homebrew/lib/node_modules/playwright"))
    }

    func testBrowserActionsUseDedicatedBrowserBackendRunner() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let wrongRunner = FakeShell(result: ShellResult(
            stdout: "",
            stderr: "generic structured runner used",
            exitCode: 91))
        let browserRunner = FakeShell(result: ShellResult(
            stdout: #"{"action":"navigate","profile":"work","backend":"fake","url":"https://example.com","title":"Example","text":"network runner marker","links":[]}"#,
            stderr: "",
            exitCode: 0))
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: wrongRunner,
            structuredShell: wrongRunner,
            networkStructuredShell: wrongRunner,
            browserBackendShell: browserRunner,
            git: FakeGit(statusText: "", diffText: ""))

        let observation = try await BrowserNavigateTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","waitMillis":0}"#),
            in: ctx)

        XCTAssertTrue(observation.text.contains("network runner marker"), observation.text)
        XCTAssertFalse(observation.text.contains("generic structured runner used"), observation.text)
    }

    func testCDPNewPageFallbackValidatesReturnedWebSocketEndpointBeforeConnect() async throws {
        guard let nodePath = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Node.js is required for the CDP page-target contract test")
        }

        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let recorder = CommandRecorder()
        let missingBackend = RecordingShell(
            recorder: recorder,
            result: ShellResult(
                stdout: "",
                stderr: "playwright is not installed or not resolvable by Node",
                exitCode: 1))
        let context = ToolContext(
            workspaceRoot: ws,
            shell: missingBackend,
            browserBackendShell: missingBackend,
            git: FakeGit(statusText: "", diffText: ""))

        do {
            _ = try await BrowserNavigateTool().execute(
                ToolArgs(raw: #"{"url":"https://example.com","profile":"new-page-contract","waitMillis":0}"#),
                in: context)
            XCTFail("double missing backend unexpectedly completed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("browser backend failed"),
                "\(error)")
        }

        let commands = await recorder.all()
        XCTAssertEqual(commands.count, 2)
        guard commands.count == 2 else { return }
        let cdpCommand = commands[1]
        guard let functionStart = cdpCommand.range(
            of: "async function pageTarget(port) {"),
              let functionEnd = cdpCommand.range(
                of: "class CDPClient",
                range: functionStart.upperBound..<cdpCommand.endIndex) else {
            return XCTFail("could not extract the CDP pageTarget implementation")
        }
        let pageTargetSource = String(
            cdpCommand[functionStart.lowerBound..<functionEnd.lowerBound])
        XCTAssertTrue(pageTargetSource.contains("/json/new?about:blank"))

        let forgedEndpoint =
            "ws://198.51.100.77:43123/devtools/page/forged-external-target"
        let harness = """
        const validationCalls = [];
        async function listPageTargets(_) { return []; }
        async function fetchJSON(_, __) {
          return {
            id: "forged-target",
            type: "page",
            webSocketDebuggerUrl: \(String(reflecting: forgedEndpoint))
          };
        }
        function validatedLoopbackWebSocketURL(raw, port, expectedPath) {
          validationCalls.push({ raw, port, expectedPath: expectedPath || null });
          throw new Error("forged non-loopback WebSocket endpoint rejected");
        }
        \(pageTargetSource)
        (async () => {
          let accepted = false;
          let error = "";
          try {
            await pageTarget(43123);
            accepted = true;
          } catch (caught) {
            error = String(caught && caught.message ? caught.message : caught);
          }
          process.stdout.write(JSON.stringify({ accepted, error, validationCalls }));
        })().catch((error) => {
          process.stderr.write(String(error && error.stack ? error.stack : error));
          process.exit(1);
        });
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["-e", harness]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, stderrText)
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stdoutData) as? [String: Any])
        XCTAssertEqual(result["accepted"] as? Bool, false)
        XCTAssertTrue(
            (result["error"] as? String)?
                .contains("forged non-loopback WebSocket endpoint rejected") == true,
            "\(result)")
        let validationCalls = try XCTUnwrap(
            result["validationCalls"] as? [[String: Any]])
        XCTAssertEqual(validationCalls.count, 1)
        XCTAssertEqual(validationCalls.first?["raw"] as? String, forgedEndpoint)
        XCTAssertEqual(validationCalls.first?["port"] as? Int, 43_123)
    }

    func testBrowserExecutionDeclaresAllManagedPaths() throws {
        let paths = BrowserNavigateTool().touchedPaths(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work"}"#))
        XCTAssertEqual(Set(paths), Set([
            ".intatis/browser/profiles/work",
            ".intatis/browser/downloads/work",
            ".intatis/browser/state/work.json",
            ".intatis/browser/history.jsonl",
        ]))
    }

    func testBrowserExecutionRejectsReadOnlyLeaseBeforeCreatingState() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let lease = WorkspaceLease(
            rootPath: ws.path,
            access: .readOnly,
            deniedPatterns: [])
        let backend = FakeShell(result: ShellResult(
            stdout: #"{"action":"navigate","profile":"work","url":"https://example.com"}"#,
            stderr: "",
            exitCode: 0))
        let context = ToolContext(
            workspaceRoot: ws,
            workspaceLease: lease,
            shell: backend,
            browserBackendShell: backend)

        do {
            _ = try await BrowserNavigateTool().execute(
                ToolArgs(raw: #"{"url":"https://example.com","profile":"work","waitMillis":0}"#),
                in: context)
            XCTFail("read-only lease unexpectedly allowed browser state writes")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("read-write workspace lease"),
                "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ws.appendingPathComponent(".intatis").path))
    }

    func testBrowserExecutionRejectsNarrowOrDeniedManagedPathsBeforeCreatingState() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let backend = FakeShell(result: ShellResult(
            stdout: #"{"action":"navigate","profile":"work","url":"https://example.com"}"#,
            stderr: "",
            exitCode: 0))
        let narrowLease = WorkspaceLease(
            rootPath: ws.path,
            access: .readWrite,
            allowedPathRules: [
                PathRule(pattern: ".intatis/browser/profiles/**"),
            ],
            deniedPatterns: [])
        let narrowContext = ToolContext(
            workspaceRoot: ws,
            workspaceLease: narrowLease,
            shell: backend,
            browserBackendShell: backend)
        do {
            _ = try await BrowserNavigateTool().execute(
                ToolArgs(raw: #"{"url":"https://example.com","profile":"work","waitMillis":0}"#),
                in: narrowContext)
            XCTFail("narrow lease unexpectedly allowed all browser state paths")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("outside the workspace lease allow-list"),
                "\(error)")
        }

        let deniedLease = WorkspaceLease(
            rootPath: ws.path,
            access: .readWrite,
            deniedPatterns: ["state"])
        let deniedContext = ToolContext(
            workspaceRoot: ws,
            workspaceLease: deniedLease,
            shell: backend,
            browserBackendShell: backend)
        do {
            _ = try await BrowserNavigateTool().execute(
                ToolArgs(raw: #"{"url":"https://example.com","profile":"work","waitMillis":0}"#),
                in: deniedContext)
            XCTFail("denied state path unexpectedly reached the browser backend")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("denied by the workspace lease"),
                "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ws.appendingPathComponent(".intatis").path))
    }

    #if canImport(Darwin)
    func testBrowserDiagnosticsIgnoresWorkspacePlaywrightModule() async throws {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace shell sandbox backend is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/node")
                || FileManager.default.isExecutableFile(atPath: "/usr/bin/node") else {
            throw XCTSkip("Node.js is required for the browser module confinement smoke")
        }
        let ws = try tempWorkspace()
        let outside = ws.deletingLastPathComponent().appendingPathComponent("intatis-node-outside-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: outside)
            unsetenv("INTATIS_NODE_HOST_MARKER")
        }
        try Data("outside-node-marker".utf8).write(to: outside)
        setenv("INTATIS_NODE_HOST_MARKER", "host-node-marker", 1)
        let module = ws.appendingPathComponent("node_modules/playwright", isDirectory: true)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let maliciousModule = """
        const fs = require('fs');
        let outside = 'unreadable';
        try { outside = fs.readFileSync('\(outside.path)', 'utf8'); } catch (_) {}
        fs.writeFileSync('workspace-playwright-loaded', `${process.env.INTATIS_NODE_HOST_MARKER || ''}|${outside}`);
        module.exports = { chromium: {} };
        """
        try Data(maliciousModule.utf8)
            .write(to: module.appendingPathComponent("index.js"))
        try Data(#"{"name":"playwright","main":"index.js"}"#.utf8)
            .write(to: module.appendingPathComponent("package.json"))

        let observation = try await BrowserDiagnosticsTool().execute(
            ToolArgs(raw: #"{"profile":"work","channel":"chromium"}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("workspace-playwright-loaded").path))
        XCTAssertFalse(observation.text.contains(ws.appendingPathComponent("node_modules").path), observation.text)
        XCTAssertTrue(observation.text.contains("/opt/homebrew/lib/node_modules/playwright"), observation.text)
    }
    #endif

    func testBrowserProfilesListsMetadataWithoutReadingProfileDatabaseContents() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let cookieFile = ws.appendingPathComponent(".intatis/browser/profiles/work/Default/Cookies")
        try FileManager.default.createDirectory(at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret-cookie-token".utf8).write(to: cookieFile)
        let activeMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/DevToolsActivePort")
        let lockMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/SingletonLock")
        try Data("active-marker-secret".utf8).write(to: activeMarkerFile)
        try Data("lock-marker-secret".utf8).write(to: lockMarkerFile)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = """
        {
          "profile": "work",
          "url": "https://example.com/account",
          "title": "Work Portal",
          "updatedAt": "2026-07-07T03:00:00Z",
          "navigationStack": ["https://example.com/login", "https://example.com/account"],
          "navigationIndex": 1
        }
        """
        try Data(state.utf8).write(to: stateURL)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let history = [
            #"{"ts":"2026-07-07T02:00:00Z","profile":"work","action":"navigate","url":"https://example.com/login","title":"Login"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"navigate","url":"https://example.com/account","title":"Work Portal"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: historyURL)

        let downloadURL = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        try FileManager.default.createDirectory(at: downloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download-secret-body".utf8).write(to: downloadURL)

        let obs = try await BrowserProfilesTool().execute(
            ToolArgs(raw: #"{"profile":"work","limit":10,"includeProfileSize":true}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(obs.text.contains("browser profiles: 1 profile"))
        XCTAssertTrue(obs.text.contains("profile filter: work"))
        XCTAssertTrue(obs.text.contains("metadata only:"))
        XCTAssertTrue(obs.text.contains("title: Work Portal"))
        XCTAssertTrue(obs.text.contains("url: https://example.com/account"))
        XCTAssertTrue(obs.text.contains("navigation: 2 entries, index 1"))
        XCTAssertTrue(obs.text.contains("history entries: 2"))
        XCTAssertTrue(obs.text.contains("runtime markers: active browser marker present; profile lock marker present"))
        XCTAssertTrue(obs.text.contains("latest history: 2026-07-07T03:00:00Z navigate - Work Portal - https://example.com/account"))
        XCTAssertTrue(obs.text.contains("downloads: 1 file"))
        XCTAssertTrue(obs.text.contains("profile dir: .intatis/browser/profiles/work (present;"))
        XCTAssertTrue(obs.text.contains("state file: .intatis/browser/state/work.json (present)"))
        XCTAssertFalse(obs.text.contains("secret-cookie-token"))
        XCTAssertFalse(obs.text.contains("active-marker-secret"))
        XCTAssertFalse(obs.text.contains("lock-marker-secret"))
        XCTAssertFalse(obs.text.contains("DevToolsActivePort"))
        XCTAssertFalse(obs.text.contains("SingletonLock"))
        XCTAssertFalse(obs.text.contains("download-secret-body"))
        XCTAssertFalse(obs.text.contains("Default/Cookies"))
    }

    func testBrowserProfileDeleteRequiresConfirmationAndOnlyDeletesTargetProfile() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }

        let workCookieFile = ws.appendingPathComponent(".intatis/browser/profiles/work/Default/Cookies")
        let personalCookieFile = ws.appendingPathComponent(".intatis/browser/profiles/personal/Default/Cookies")
        try FileManager.default.createDirectory(at: workCookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalCookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret-cookie-token".utf8).write(to: workCookieFile)
        try Data("personal-cookie-token".utf8).write(to: personalCookieFile)
        let activeMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/DevToolsActivePort")
        let lockMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/SingletonLock")
        try Data("active-marker-secret".utf8).write(to: activeMarkerFile)
        try Data("lock-marker-secret".utf8).write(to: lockMarkerFile)

        let workStateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let personalStateURL = ws.appendingPathComponent(".intatis/browser/state/personal.json")
        try FileManager.default.createDirectory(at: workStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"profile":"work","url":"https://example.com/work"}"#.utf8).write(to: workStateURL)
        try Data(#"{"profile":"personal","url":"https://example.com/personal"}"#.utf8).write(to: personalStateURL)

        let workDownload = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        let personalDownload = ws.appendingPathComponent(".intatis/browser/downloads/personal/keep.pdf")
        try FileManager.default.createDirectory(at: workDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download-secret-body".utf8).write(to: workDownload)
        try Data("personal-download-body".utf8).write(to: personalDownload)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let history = [
            #"{"ts":"2026-07-07T01:00:00Z","profile":"work","action":"navigate","url":"https://example.com/work","title":"Work"}"#,
            #"{"ts":"2026-07-07T02:00:00Z","profile":"personal","action":"navigate","url":"https://example.com/personal","title":"Personal"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"download","url":"https://example.com/report","title":"Report"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: historyURL)

        do {
            _ = try await BrowserProfileDeleteTool().execute(
                ToolArgs(raw: #"{"profile":"work","confirmProfile":"personal"}"#),
                in: ToolContext(workspaceRoot: ws))
            XCTFail("expected browser profile delete to require exact confirmation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("confirmProfile"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workCookieFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDownload.path))

        let obs = try await BrowserProfileDeleteTool().execute(
            ToolArgs(raw: #"{"profile":"work","confirmProfile":"work"}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(obs.text.contains("browser profile deleted: work"))
        XCTAssertTrue(obs.text.contains("profile runtime markers: present before delete (active browser marker present; profile lock marker present"))
        XCTAssertTrue(obs.text.contains("removed profile data: yes (.intatis/browser/profiles/work)"))
        XCTAssertTrue(obs.text.contains("removed state file: yes (.intatis/browser/state/work.json)"))
        XCTAssertTrue(obs.text.contains("removed downloads: yes (.intatis/browser/downloads/work)"))
        XCTAssertTrue(obs.text.contains("removed history entries: 2"))
        XCTAssertTrue(obs.text.contains("kept history entries: 1"))
        XCTAssertFalse(obs.text.contains("secret-cookie-token"))
        XCTAssertFalse(obs.text.contains("active-marker-secret"))
        XCTAssertFalse(obs.text.contains("lock-marker-secret"))
        XCTAssertFalse(obs.text.contains("DevToolsActivePort"))
        XCTAssertFalse(obs.text.contains("SingletonLock"))
        XCTAssertFalse(obs.text.contains("download-secret-body"))
        XCTAssertFalse(obs.text.contains("Default/Cookies"))
        XCTAssertFalse(obs.text.contains("report.pdf"))
        XCTAssertEqual(obs.changedFiles, [
            ".intatis/browser/profiles/work",
            ".intatis/browser/state/work.json",
            ".intatis/browser/downloads/work",
            ".intatis/browser/history.jsonl",
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: workCookieFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workStateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDownload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalCookieFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalDownload.path))

        let remainingHistory = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(remainingHistory.contains(#""profile":"work""#))
        XCTAssertTrue(remainingHistory.contains(#""profile":"personal""#))
    }

    func testBrowserHistoryReadsRecentMetadataOnly() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"ts":"2026-07-07T01:00:00Z","profile":"default","action":"navigate","url":"https://example.com","title":"Example"}"#,
            #"{"ts":"2026-07-07T02:00:00Z","profile":"work","action":"search","url":"https://duckduckgo.com/?q=test","title":"Search"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"screenshot","url":"https://example.com","title":"Example","screenshotPath":"shots/page.png"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: historyURL)
        let ctx = ToolContext(workspaceRoot: ws)

        let obs = try await BrowserHistoryTool().execute(
            ToolArgs(raw: #"{"profile":"work","limit":1}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser history: 1 entry"))
        XCTAssertTrue(obs.text.contains("screenshot - Example - https://example.com - screenshot: shots/page.png"))
        XCTAssertFalse(obs.text.contains("duckduckgo"))
        XCTAssertFalse(obs.text.contains("profileDir"))
    }

    func testBrowserSearchReportsResultTextLinksAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"search","profile":"research","backend":"cdp","backendDetail":"edge","url":"https://duckduckgo.com/?q=Intatis%20agent","title":"Intatis agent at DuckDuckGo","text":"Search results for Intatis agent","links":[{"text":"Intatis project","href":"https://example.com/intatis"}],"elements":[{"role":"textbox","name":"Search","selector":"input[name=q]","tag":"input","type":"search"}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserSearchTool().execute(
            ToolArgs(raw: #"{"query":"Intatis agent","engine":"duckduckgo","profile":"research","channel":"msedge","waitMillis":100}"#),
            in: ctx)

        XCTAssertTrue(obs.text.contains("browser action: search"), obs.text)
        XCTAssertTrue(obs.text.contains("title: Intatis agent at DuckDuckGo"), obs.text)
        XCTAssertTrue(obs.text.contains("Intatis project - https://example.com/intatis"), obs.text)
        XCTAssertTrue(obs.text.contains(#"textbox "Search" selector=input[name=q] type=search"#), obs.text)
        XCTAssertTrue(obs.text.contains("Search results for Intatis agent"), obs.text)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/research.json")
        let stateData = try Data(contentsOf: stateURL)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://duckduckgo.com/?q=Intatis%20agent")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"research""#), history)
        XCTAssertTrue(history.contains(#""action":"search""#), history)
        XCTAssertTrue(history.contains("duckduckgo.com"), history)
    }

    func testBrowserScreenshotReportsChangedPNGAndHistory() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"screenshot","profile":"work","url":"https://example.com/","title":"Example Domain","text":"Example page text","links":[],"screenshotPath":"screens/page.png"}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserScreenshotTool().execute(
            ToolArgs(raw: #"{"url":"https://example.com","profile":"work","outputPath":"screens/page.png","fullPage":true}"#),
            in: ctx)

        XCTAssertEqual(obs.changedFiles, ["screens/page.png"])
        XCTAssertTrue(obs.text.contains("screenshot: screens/page.png"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
    }

    func testBrowserUploadFileUsesWorkspaceFileAndReportsRelativePath() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("upload"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: ws.appendingPathComponent("upload/report.txt"))
        let stdout = #"{"action":"upload","profile":"work","url":"https://example.com/form","title":"Upload","text":"Ready","links":[],"uploadedFiles":["upload/report.txt"]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let obs = try await BrowserUploadFileTool().execute(
            ToolArgs(raw: #"{"selector":"input[type=file]","filePath":"upload/report.txt","profile":"work"}"#),
            in: ctx)

        XCTAssertNil(obs.changedFiles)
        XCTAssertTrue(obs.text.contains("uploaded files:"))
        XCTAssertTrue(obs.text.contains("upload/report.txt"))
        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        XCTAssertTrue(try String(contentsOf: historyURL, encoding: .utf8).contains(#""action":"upload""#))
    }

    func testBrowserDownloadReportsChangedFileAndDownloadsListMetadataOnly() async throws {
        let ws = try tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let stdout = #"{"action":"download","profile":"work","url":"https://example.com/files","title":"Files","text":"Downloaded","links":[],"downloads":[{"filename":"report.pdf","path":".intatis/browser/downloads/work/report.pdf","url":"https://example.com/report.pdf","bytes":7}]}"#
        let ctx = ToolContext(
            workspaceRoot: ws,
            shell: FakeShell(result: ShellResult(stdout: stdout, stderr: "", exitCode: 0)),
            git: FakeGit(statusText: "", diffText: ""))

        let download = try await BrowserDownloadTool().execute(
            ToolArgs(raw: #"{"text":"Download report","profile":"work","downloadTimeoutMillis":1000}"#),
            in: ctx)

        XCTAssertEqual(download.changedFiles, [".intatis/browser/downloads/work/report.pdf"])
        XCTAssertTrue(download.text.contains("downloads:"))
        XCTAssertTrue(download.text.contains("report.pdf -> .intatis/browser/downloads/work/report.pdf"))

        let downloadedFile = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        try FileManager.default.createDirectory(at: downloadedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1".utf8).write(to: downloadedFile)

        let listed = try await BrowserDownloadsTool().execute(
            ToolArgs(raw: #"{"profile":"work","limit":10}"#),
            in: ToolContext(workspaceRoot: ws))

        XCTAssertTrue(listed.text.contains("browser downloads: 1 file"))
        XCTAssertTrue(listed.text.contains(".intatis/browser/downloads/work/report.pdf"))
        XCTAssertFalse(listed.text.contains("%PDF-1"))
    }

    // MARK: Registry

    func testStandardRegistry() {
        let reg = ToolRegistry.standard()
        XCTAssertEqual(reg.registryVersion, "intatis.standard.v5")
        XCTAssertEqual(reg.descriptors().count, 103)
        XCTAssertNotNil(reg.tool(named: "read_file"))
        XCTAssertNotNil(reg.tool(named: "apply_patch"))
        XCTAssertNil(reg.tool(named: "run_shell"))
        XCTAssertNotNil(reg.tool(named: "git_status"))
        XCTAssertNotNil(reg.tool(named: "git_diff"))
        XCTAssertNotNil(reg.tool(named: "git_diff_staged"))
        XCTAssertNotNil(reg.tool(named: "git_info"))
        XCTAssertNotNil(reg.tool(named: "git_recent_commits"))
        XCTAssertNotNil(reg.tool(named: "git_diff_base"))
        XCTAssertNotNil(reg.tool(named: "git_branch"))
        XCTAssertNotNil(reg.tool(named: "git_create_branch"))
        XCTAssertNotNil(reg.tool(named: "git_stage"))
        XCTAssertNotNil(reg.tool(named: "git_unstage"))
        XCTAssertNotNil(reg.tool(named: "git_commit"))
        XCTAssertNotNil(reg.tool(named: "git_apply_patch_check"))
        XCTAssertNotNil(reg.tool(named: "git_apply_patch"))
        XCTAssertNotNil(reg.tool(named: "git_stage_patch"))
        XCTAssertNotNil(reg.tool(named: "git_unstage_patch"))
        XCTAssertNotNil(reg.tool(named: "git_revert_patch"))
        XCTAssertNotNil(reg.tool(named: "git_worktree_list"))
        XCTAssertNotNil(reg.tool(named: "git_worktree_create"))
        XCTAssertNotNil(reg.tool(named: "git_worktree_remove"))
        XCTAssertNotNil(reg.tool(named: "git_remotes"))
        XCTAssertNotNil(reg.tool(named: "git_fetch"))
        XCTAssertNotNil(reg.tool(named: "git_pull_ff"))
        XCTAssertNotNil(reg.tool(named: "git_push"))
        XCTAssertNotNil(reg.tool(named: "git_switch"))
        XCTAssertNotNil(reg.tool(named: "inspect_pdf"))
        XCTAssertNotNil(reg.tool(named: "read_pdf"))
        XCTAssertNotNil(reg.tool(named: "read_docx"))
        XCTAssertNotNil(reg.tool(named: "continue_docx_read"))
        XCTAssertNotNil(reg.tool(named: "read_pptx"))
        XCTAssertNotNil(reg.tool(named: "continue_pptx_read"))
        XCTAssertNotNil(reg.tool(named: "read_xlsx"))
        XCTAssertNotNil(reg.tool(named: "continue_xlsx_read"))
        XCTAssertNotNil(reg.tool(named: "read_html"))
        XCTAssertNotNil(reg.tool(named: "continue_html_read"))
        XCTAssertNotNil(reg.tool(named: "read_epub"))
        XCTAssertNotNil(reg.tool(named: "continue_epub_read"))
        XCTAssertNil(reg.tool(named: "document_read"))
        XCTAssertNotNil(reg.tool(named: "ocr_pdf"))
        XCTAssertNotNil(reg.tool(named: "pdf_render_page"))
        XCTAssertNotNil(reg.tool(named: "docx_export_pdf"))
        XCTAssertNotNil(reg.tool(named: "pptx_export_pdf"))
        XCTAssertNotNil(reg.tool(named: "xlsx_export_pdf"))
        XCTAssertNotNil(reg.tool(named: "html_export_pdf"))
        XCTAssertNotNil(reg.tool(named: "docx_create_document"))
        XCTAssertNotNil(reg.tool(named: "pptx_create_presentation"))
        XCTAssertNotNil(reg.tool(named: "xlsx_create_workbook"))
        XCTAssertNil(reg.tool(named: "document_ocr"))
        XCTAssertNil(reg.tool(named: "document_render"))
        XCTAssertNil(reg.tool(named: "document_export_pdf"))
        XCTAssertNil(reg.tool(named: "document_write"))
        XCTAssertNil(reg.tool(named: "read_document"))
        XCTAssertNil(reg.tool(named: "edit_pdf_pages"))
        XCTAssertNil(reg.tool(named: "reconstruct_document_image"))
        XCTAssertNotNil(reg.tool(named: "compile_latex"))
        XCTAssertNotNil(reg.tool(named: "generate_image"))
        XCTAssertNotNil(reg.tool(named: "edit_image"))
        XCTAssertNotNil(reg.tool(named: "web_fetch"))
        XCTAssertNotNil(reg.tool(named: "browser_diagnostics"))
        XCTAssertNotNil(reg.tool(named: "browser_profiles"))
        XCTAssertNotNil(reg.tool(named: "browser_profile_delete"))
        XCTAssertNotNil(reg.tool(named: "browser_history"))
        XCTAssertNotNil(reg.tool(named: "browser_navigate"))
        XCTAssertNotNil(reg.tool(named: "browser_snapshot"))
        XCTAssertNotNil(reg.tool(named: "browser_handoff"))
        XCTAssertNotNil(reg.tool(named: "browser_reload"))
        XCTAssertNotNil(reg.tool(named: "browser_back"))
        XCTAssertNotNil(reg.tool(named: "browser_forward"))
        XCTAssertNotNil(reg.tool(named: "browser_click"))
        XCTAssertNotNil(reg.tool(named: "browser_type"))
        XCTAssertNotNil(reg.tool(named: "browser_submit"))
        XCTAssertNotNil(reg.tool(named: "browser_select_option"))
        XCTAssertNotNil(reg.tool(named: "browser_press_key"))
        XCTAssertNotNil(reg.tool(named: "browser_scroll"))
        XCTAssertNotNil(reg.tool(named: "browser_wait"))
        XCTAssertNotNil(reg.tool(named: "browser_screenshot"))
        XCTAssertNotNil(reg.tool(named: "browser_upload_file"))
        XCTAssertNotNil(reg.tool(named: "browser_download"))
        XCTAssertNotNil(reg.tool(named: "browser_downloads"))
        XCTAssertNotNil(reg.tool(named: "browser_search"))
        XCTAssertNotNil(reg.tool(named: "rename_session"))
        XCTAssertNil(reg.tool(named: "nonexistent"))
        XCTAssertEqual(ReadFileTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(WriteFileTool.descriptor.sideEffect, .write)
        XCTAssertEqual(RunShellTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(GitStageTool.descriptor.sideEffect, .write)
        XCTAssertEqual(GitCommitTool.descriptor.sideEffect, .write)
        XCTAssertEqual(GitApplyPatchCheckTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(GitApplyPatchTool.descriptor.sideEffect, .write)
        XCTAssertEqual(GitStagePatchTool.descriptor.sideEffect, .write)
        XCTAssertEqual(GitUnstagePatchTool.descriptor.sideEffect, .write)
        XCTAssertEqual(GitRevertPatchTool.descriptor.sideEffect, .destructive)
        XCTAssertEqual(GitWorktreeCreateTool.descriptor.sideEffect, .write)
        XCTAssertEqual(GitWorktreeRemoveTool.descriptor.sideEffect, .destructive)
        XCTAssertEqual(GitRemotesTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(GitFetchTool.descriptor.sideEffect, .write)
        XCTAssertTrue(GitFetchTool().risksNetwork(ToolArgs(raw: "{}")))
        XCTAssertEqual(GitPullFastForwardTool.descriptor.sideEffect, .write)
        XCTAssertTrue(GitPullFastForwardTool().risksNetwork(ToolArgs(raw: "{}")))
        XCTAssertEqual(GitPushTool.descriptor.sideEffect, .destructive)
        XCTAssertTrue(GitPushTool().risksNetwork(ToolArgs(raw: "{}")))
        XCTAssertEqual(GitSwitchBranchTool.descriptor.sideEffect, .destructive)
        XCTAssertEqual(GenerateImageTool.descriptor.sideEffect, .write)
        XCTAssertEqual(EditImageTool.descriptor.sideEffect, .write)
        XCTAssertEqual(WebFetchTool.descriptor.sideEffect, .network)
        XCTAssertEqual(BrowserNavigateTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserProfilesTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(BrowserProfileDeleteTool.descriptor.sideEffect, .destructive)
        XCTAssertEqual(BrowserHistoryTool.descriptor.sideEffect, .readOnly)
        XCTAssertEqual(BrowserHandoffTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserReloadTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserBackTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserForwardTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserSubmitTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserSelectOptionTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserPressKeyTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserScrollTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserWaitTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserScreenshotTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserUploadFileTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserDownloadTool.descriptor.sideEffect, .exec)
        XCTAssertEqual(BrowserDownloadsTool.descriptor.sideEffect, .readOnly)
    }

    func testPermissionIntentsDescribeConcreteActionResourcesAndReplay() {
        let root = URL(fileURLWithPath: "/workspace")
        let write = WriteFileTool().permissionIntent(
            ToolArgs(raw: #"{"path":"Sources/App.swift","content":"hello"}"#),
            workspaceRoot: root)
        XCTAssertEqual(write.action, "filesystem.write")
        XCTAssertEqual(write.dataEffects, [.mutate])
        XCTAssertEqual(write.metadata["byteCount"], .number(5))
        XCTAssertEqual(write.resources.first?.kind, .workspacePath)
        XCTAssertEqual(write.resources.first?.access, .readWrite)
        XCTAssertEqual(write.replayPolicy, .doNotReplay)

        let git = GitFetchTool().permissionIntent(
            ToolArgs(raw: #"{"remote":"origin","branch":"main","prune":false}"#),
            workspaceRoot: root)
        XCTAssertEqual(git.action, "git.fetch")
        XCTAssertTrue(git.resources.contains { $0.kind == .git && $0.value == root.path })
        XCTAssertTrue(git.dataEffects.contains(.network))

        let browser = BrowserNavigateTool().permissionIntent(
            ToolArgs(raw: #"{"url":"https://example.com"}"#),
            workspaceRoot: root)
        XCTAssertEqual(browser.action, "browser.navigate")
        XCTAssertTrue(browser.resources.contains {
            $0.kind == .url && $0.value == "https://example.com"
        })
    }
}
