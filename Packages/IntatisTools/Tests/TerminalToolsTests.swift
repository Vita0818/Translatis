import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TerminalToolsTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-terminal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func owner(workspace: URL,
                       agent: String = "terminal-test",
                       taskID: TaskID? = nil) throws -> TerminalSessionOwner {
        TerminalSessionOwner(
            sessionID: SessionID.new(),
            agent: AgentID(rawValue: agent),
            taskID: taskID,
            workspaceRootIdentity: try XCTUnwrap(
                WorkspaceRootIdentity.capture(rootPath: workspace.path)))
    }

    private func manager(
        maximumCapturedBytes: Int = 256 * 1_024,
        maximumResponseBytes: Int = 8 * 1_024
    ) throws -> ProcessTerminalSessionManager {
        guard ProcessShellRunner.supportsWorkspaceSandbox else {
            throw XCTSkip("workspace process sandbox is unavailable")
        }
        let manager = ProcessTerminalSessionManager(
            maximumSessions: 4,
            maximumCapturedBytes: maximumCapturedBytes,
            maximumResponseBytes: maximumResponseBytes,
            terminationGraceSeconds: 0.1)
        addTeardownBlock {
            await manager.shutdown(reason: "test teardown")
        }
        return manager
    }

    func testManagedTerminalRunsInRequestedWorkingDirectory() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let child = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let result = try await manager.execute(
            TerminalExecRequest(
                command: "printf '%s' \"$PWD\"; printf ready > terminal.txt",
                workingDirectory: "Sources",
                loginShell: false,
                yieldMilliseconds: 1_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertFalse(result.isRunning)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(
            URL(fileURLWithPath: result.stdout).standardizedFileURL.path,
            child.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(
            try String(contentsOf: child.appendingPathComponent("terminal.txt"), encoding: .utf8),
            "ready")
    }

    func testManagedTerminalContinuesAndAcceptsInput() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "IFS= read -r value; printf 'received:%s' \"$value\"",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)
        XCTAssertTrue(started.isRunning)

        let completed = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(
                characters: "hello terminal\n",
                yieldMilliseconds: 2_000),
            owner: owner)

        XCTAssertFalse(completed.isRunning)
        XCTAssertEqual(completed.exitCode, 0, completed.stderr)
        XCTAssertTrue(completed.stdout.contains("received:"), completed.stdout)
        XCTAssertFalse(completed.stdout.contains("hello terminal"), completed.stdout)
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    func testManagedTerminalRejectsDangerousCommandSplitAcrossInputCalls() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "while IFS= read -r line; do printf 'line:%s\\n' \"$line\"; done",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)

        _ = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(
                characters: "r",
                yieldMilliseconds: 250),
            owner: owner)
        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(
                    characters: "m -rf -- Sources\n",
                    yieldMilliseconds: 250),
                owner: owner)
            XCTFail("split dangerous command unexpectedly reached the terminal")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("dangerous interactive shell command"),
                "\(error)")
        }
        await manager.terminateAll(reason: "split-input test complete")
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    #if canImport(Darwin)
    func testManagedTerminalTTYRejectsCursorEditingBeforeDangerousCommand() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "exec /bin/zsh -f",
                loginShell: false,
                usesTTY: true,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)

        _ = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(
                characters: "m -rf -- INTATIS_NONEXISTENT_TARGET",
                yieldMilliseconds: 250),
            owner: owner)
        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(
                    characters: "\u{1}",
                    yieldMilliseconds: 250),
                owner: owner)
            XCTFail("cursor-edit control unexpectedly reached zsh")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("unsupported terminal editing"),
                "\(error)")
        }
        await manager.terminateAll(reason: "cursor-edit test complete")
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    func testManagedTerminalTTYRejectsUntrackedEscapeEditing() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let started = try await manager.execute(
            TerminalExecRequest(
                command: "exec /bin/zsh -f",
                loginShell: false,
                usesTTY: true,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)

        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(
                    characters: "\u{1B}[D",
                    yieldMilliseconds: 250),
                owner: owner)
            XCTFail("untracked terminal escape editing unexpectedly reached zsh")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("unsupported terminal editing"),
                "\(error)")
        }
        await manager.terminateAll(reason: "escape-edit test complete")
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    func testManagedTerminalTTYRejectsInputKeymapMutation() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let started = try await manager.execute(
            TerminalExecRequest(
                command: "exec /bin/zsh -f",
                loginShell: false,
                usesTTY: true,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)

        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(
                    characters: "bindkey -v\n",
                    yieldMilliseconds: 250),
                owner: owner)
            XCTFail("terminal input keymap mutation unexpectedly reached zsh")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("changing terminal input editing semantics"),
                "\(error)")
        }
        await manager.terminateAll(reason: "keymap test complete")
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    func testManagedTerminalTTYProvidesRealTerminalFileDescriptors() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let result = try await manager.execute(
            TerminalExecRequest(
                command: """
                if [ -t 0 ]; then printf 'stdin=yes '; else printf 'stdin=no '; fi
                if [ -t 1 ]; then printf 'stdout=yes '; else printf 'stdout=no '; fi
                if ( : </dev/tty ) 2>/dev/null; then
                    printf 'controlling=yes'
                else
                    printf 'controlling=no'
                fi
                """,
                loginShell: false,
                usesTTY: true,
                yieldMilliseconds: 2_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertFalse(result.isRunning)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("stdin=yes"), result.stdout)
        XCTAssertTrue(result.stdout.contains("stdout=yes"), result.stdout)
        XCTAssertTrue(result.stdout.contains("controlling=yes"), result.stdout)
    }

    func testManagedTerminalTTYAcceptsInputAcrossCalls() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "IFS= read -r value; printf 'tty-received:%s' \"$value\"",
                loginShell: false,
                usesTTY: true,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)

        let completed = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(
                characters: "hello pty\n",
                yieldMilliseconds: 2_000),
            owner: owner)

        XCTAssertFalse(completed.isRunning)
        XCTAssertEqual(completed.exitCode, 0, completed.stderr)
        XCTAssertTrue(completed.stdout.contains("tty-received:"), completed.stdout)
        XCTAssertFalse(completed.stdout.contains("hello pty"), completed.stdout)
    }

    func testManagedTerminalTTYControlCReachesForegroundProcess() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "trap 'printf interrupted; exit 0' INT; while :; do /bin/sleep 1; done",
                loginShell: false,
                usesTTY: true,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)

        let completed = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(
                characters: "\u{3}",
                yieldMilliseconds: 2_000),
            owner: owner)

        XCTAssertFalse(completed.isRunning)
        XCTAssertEqual(completed.exitCode, 0, completed.stderr)
        XCTAssertTrue(completed.stdout.contains("interrupted"), completed.stdout)
    }
    #endif

    func testManagedTerminalPreservesToolchainPathButFiltersSecretEnvironment() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)
        setenv("INTATIS_TERMINAL_TEST_TOKEN", "must-not-reach-child", 1)
        setenv("DATABASE_URL", "postgres://must-not-reach-child", 1)
        defer {
            unsetenv("INTATIS_TERMINAL_TEST_TOKEN")
            unsetenv("DATABASE_URL")
        }

        let result = try await manager.execute(
            TerminalExecRequest(
                command: """
                if [ -z "$INTATIS_TERMINAL_TEST_TOKEN" ] && [ -z "$DATABASE_URL" ]; then
                    printf 'environment-filtered\n'
                else
                    printf 'environment-present\n'
                fi
                command -v swift
                swift --version
                """,
                loginShell: false,
                yieldMilliseconds: 5_000,
                timeoutMilliseconds: 15_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("environment-filtered"), result.stdout)
        XCTAssertFalse(result.stdout.contains("environment-present"), result.stdout)
        XCTAssertFalse(result.stdout.contains("must-not-reach-child"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Swift version"), result.stdout)
    }

    func testManagedTerminalRejectsAnotherOwner() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let started = try await manager.execute(
            TerminalExecRequest(
                command: "/bin/sleep 5",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 10_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)
        let foreignOwner = TerminalSessionOwner(
            sessionID: owner.sessionID,
            agent: AgentID(rawValue: "another-agent"),
            taskID: owner.taskID,
            workspaceRootIdentity: owner.workspaceRootIdentity)

        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(yieldMilliseconds: 250),
                owner: foreignOwner)
            XCTFail("another agent unexpectedly controlled the terminal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("another agent or task"), "\(error)")
        }
        await manager.terminateAll(reason: "owner test complete")
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    func testManagedTerminalTimeoutRemovesBackgroundDescendants() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let childPIDURL = workspace.appendingPathComponent("terminal-child.pid")

        let result = try await manager.execute(
            TerminalExecRequest(
                command: "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > terminal-child.pid; wait \"$child\"",
                loginShell: false,
                yieldMilliseconds: 3_000,
                timeoutMilliseconds: 1_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.isRunning)
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        let deadline = Date().addingTimeInterval(1)
        while processExists(childPID), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(processExists(childPID), "background child \(childPID) survived terminal timeout")
        let remainingSessions = await manager.activeSessionCount()
        XCTAssertEqual(remainingSessions, 0)
    }

    func testManagedTerminalWorkspaceDenyPatternBlocksContent() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("terminal-secret-marker".utf8)
            .write(to: workspace.appendingPathComponent(".env"))
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let result = try await manager.execute(
            TerminalExecRequest(
                command: "/bin/cat .env",
                loginShell: false,
                yieldMilliseconds: 1_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains("terminal-secret-marker"), result.stdout)
        XCTAssertFalse(result.stderr.contains("terminal-secret-marker"), result.stderr)
    }

    func testManagedTerminalDefaultLeaseBlocksAllRepresentativeCredentialPaths() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixtures = [
            (".pgpass", "PGPASS_PLAIN_MARKER"),
            (".npmrc", "NPMRC_PLAIN_MARKER"),
            (".aws/credentials", "AWS_PLAIN_MARKER"),
            (".config/gh/hosts.yml", "GH_CONFIG_PLAIN_MARKER"),
            (".git/config", "GIT_CONFIG_PLAIN_MARKER"),
        ]
        for (relativePath, marker) in fixtures {
            let file = workspace.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: file)
        }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let result = try await manager.execute(
            TerminalExecRequest(
                command: """
                for file in .pgpass .npmrc .aws/credentials .config/gh/hosts.yml .git/config; do
                    /bin/cat "$file" 2>/dev/null || true
                done
                """,
                loginShell: false,
                yieldMilliseconds: 1_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        for (_, marker) in fixtures {
            XCTAssertFalse(result.stdout.contains(marker), result.stdout)
        }
    }

    func testManagedTerminalCannotRemoveCredentialFloorAndMatchesPathCase() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixtures = [
            (".PGPASS", "UPPER_PGPASS_MARKER"),
            (".ENV.LOCAL", "UPPER_ENV_MARKER"),
            ("API-TOKEN.TXT", "UPPER_TOKEN_MARKER"),
            (".AWS/CREDENTIALS", "UPPER_AWS_MARKER"),
        ]
        for (relativePath, marker) in fixtures {
            let file = workspace.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: file)
        }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])

        let result = try await manager.execute(
            TerminalExecRequest(
                command: """
                for file in .PGPASS .ENV.LOCAL API-TOKEN.TXT .AWS/CREDENTIALS; do
                    /bin/cat "$file" 2>/dev/null || true
                done
                """,
                loginShell: false,
                yieldMilliseconds: 1_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        for (_, marker) in fixtures {
            XCTAssertFalse(result.stdout.contains(marker), result.stdout)
        }
    }

    func testManagedTerminalCannotMutateKnowledgePublicationWithEmptyDenyList()
        async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = workspace.appendingPathComponent("knowledge", isDirectory: true)
        let snapshots = store.appendingPathComponent(
            ".intatis-rag-snapshots",
            isDirectory: true)
        let host = store.appendingPathComponent(
            ".intatis-rag-host",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshots,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: host,
            withIntermediateDirectories: true)
        let pointer = store.appendingPathComponent(".intatis-rag-store.json")
        let profile = snapshots.appendingPathComponent("profile.json")
        try Data("pointer-original".utf8).write(to: pointer)
        try Data("snapshot-original".utf8).write(to: profile)
        try Data("host-original".utf8).write(
            to: host.appendingPathComponent("store.lock"))

        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite,
            deniedPatterns: [])
        let result = try await manager.execute(
            TerminalExecRequest(
                command: """
                printf changed > knowledge/.intatis-rag-store.json 2>/dev/null || true
                printf changed > knowledge/.intatis-rag-snapshots/profile.json 2>/dev/null || true
                printf changed > knowledge/.intatis-rag-host/store.lock 2>/dev/null || true
                """,
                loginShell: false,
                yieldMilliseconds: 1_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(
            try String(contentsOf: pointer, encoding: .utf8),
            "pointer-original")
        XCTAssertEqual(
            try String(contentsOf: profile, encoding: .utf8),
            "snapshot-original")
        XCTAssertEqual(
            try String(
                contentsOf: host.appendingPathComponent("store.lock"),
                encoding: .utf8),
            "host-original")
    }

    func testManagedTerminalDoesNotLimitBuildArtifactFileSize() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let result = try await manager.execute(
            TerminalExecRequest(
                command: """
                /usr/bin/head -c 12582912 /dev/zero > large-build-artifact.bin
                /usr/bin/stat -f %z large-build-artifact.bin
                """,
                loginShell: false,
                yieldMilliseconds: 3_000,
                timeoutMilliseconds: 10_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("12582912"), result.stdout)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: workspace.appendingPathComponent("large-build-artifact.bin").path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 12 * 1_024 * 1_024)
    }

    func testManagedTerminalKeepsNewestOutputAfterCaptureLimit() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager(
            maximumCapturedBytes: 64 * 1_024,
            maximumResponseBytes: 8 * 1_024)
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let result = try await manager.execute(
            TerminalExecRequest(
                command: "/usr/bin/yes 0123456789 | /usr/bin/head -c 300000; printf '\\nFINAL_TAIL_MARKER\\n'",
                loginShell: false,
                yieldMilliseconds: 3_000,
                timeoutMilliseconds: 10_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.stdout.contains("output bytes omitted"), result.stdout)
        XCTAssertTrue(result.stdout.contains("FINAL_TAIL_MARKER"), result.stdout)
    }

    func testManagedTerminalRedactsDelayedInputOnLaterPoll() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)
        let secret = "482913"

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "IFS= read -r value; /bin/sleep 1; printf 'later:%s' \"$value\"",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)
        let accepted = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(
                characters: secret + "\n",
                yieldMilliseconds: 250),
            owner: owner)
        XCTAssertTrue(accepted.isRunning)

        let completed = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(yieldMilliseconds: 2_000),
            owner: owner)
        XCTAssertFalse(completed.isRunning)
        XCTAssertTrue(completed.stdout.contains("later:"), completed.stdout)
        XCTAssertFalse(completed.stdout.contains(secret), completed.stdout)
    }

    func testExitedUnpolledSessionIsFinalizedAndCanBeCollectedOnce() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "/bin/sleep 0.8; printf late-result",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let activeAfterExit = await manager.activeSessionCount()
        XCTAssertEqual(activeAfterExit, 0)
        let completed = try await manager.interact(
            sessionID: sessionID,
            request: TerminalInteractionRequest(yieldMilliseconds: 250),
            owner: owner)
        XCTAssertEqual(completed.exitCode, 0)
        XCTAssertTrue(completed.stdout.contains("late-result"), completed.stdout)
        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(yieldMilliseconds: 250),
                owner: owner)
            XCTFail("a completed session result was returned more than once")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not active"), "\(error)")
        }
    }

    func testWorkspaceReplacementTerminatesPersistentSession() async throws {
        let workspace = try workspace()
        let moved = workspace
            .deletingLastPathComponent()
            .appendingPathComponent(workspace.lastPathComponent + "-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: moved)
        }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "/bin/sleep 10",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 20_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)
        try FileManager.default.moveItem(at: workspace, to: moved)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)

        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(yieldMilliseconds: 250),
                owner: owner)
            XCTFail("a replaced workspace unexpectedly retained terminal authority")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("workspace root changed"),
                "\(error)")
        }
        let deadline = Date().addingTimeInterval(2)
        while await manager.activeSessionCount() != 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let activeAfterReplacement = await manager.activeSessionCount()
        XCTAssertEqual(activeAfterReplacement, 0)
    }

    func testWorkspaceReplacementAutoFinalizesWithoutAnotherPoll() async throws {
        let workspace = try workspace()
        let moved = workspace
            .deletingLastPathComponent()
            .appendingPathComponent(workspace.lastPathComponent + "-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: moved)
        }
        let manager = try manager()
        let owner = try owner(workspace: workspace, taskID: TaskID.new())
        let lease = WorkspaceLease(
            taskID: owner.taskID,
            rootPath: workspace.path,
            access: .readWrite)

        let started = try await manager.execute(
            TerminalExecRequest(
                command: "trap '' TERM; while :; do /bin/sleep 1; done",
                loginShell: false,
                yieldMilliseconds: 250,
                timeoutMilliseconds: 20_000),
            owner: owner,
            workspaceLease: lease)
        let sessionID = try XCTUnwrap(started.sessionID)
        try FileManager.default.moveItem(at: workspace, to: moved)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)

        let deadline = Date().addingTimeInterval(3)
        while await manager.activeSessionCount() != 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let activeAfterReplacement = await manager.activeSessionCount()
        XCTAssertEqual(activeAfterReplacement, 0)
        do {
            _ = try await manager.interact(
                sessionID: sessionID,
                request: TerminalInteractionRequest(yieldMilliseconds: 250),
                owner: owner)
            XCTFail("workspace-invalidated terminal unexpectedly returned success")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("workspace root changed"),
                "\(error)")
        }
    }

    #if os(macOS)
    func testManagedTerminalCannotSignalTheUnsandboxedHostProcess() async throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = try manager()
        let owner = try owner(workspace: workspace)
        let lease = WorkspaceLease(rootPath: workspace.path, access: .readWrite)
        let hostPID = ProcessInfo.processInfo.processIdentifier

        let result = try await manager.execute(
            TerminalExecRequest(
                command: "/bin/kill -0 \(hostPID)",
                loginShell: false,
                yieldMilliseconds: 1_000,
                timeoutMilliseconds: 5_000),
            owner: owner,
            workspaceLease: lease)

        XCTAssertNotEqual(result.exitCode, 0)
    }
    #endif

    func testWriteStdinAuthorizationIdentityDoesNotContainInteractiveBytes() {
        let secret = "123456"
        let tool = WriteStdinTool()
        let identity = tool.authorizationArgumentIdentity(ToolArgs(
            raw: #"{"session_id":"terminal_1","chars":"123456","yield-time_ms":1000}"#))

        XCTAssertFalse(identity.contains(secret))
        XCTAssertTrue(identity.contains("terminal_1"))
        XCTAssertTrue(identity.contains("present"))
        let sameLengthDifferentInput = tool.authorizationArgumentIdentity(ToolArgs(
            raw: #"{"session_id":"terminal_1","chars":"654321","yield-time_ms":1000}"#))
        XCTAssertNotEqual(identity, sameLengthDifferentInput)
    }

    func testTerminalToolsAreOptInForStandardRegistry() {
        let ordinary = ToolRegistry.standard()
        XCTAssertNil(ordinary.tool(named: "exec_command"))
        XCTAssertNil(ordinary.tool(named: "write_stdin"))

        let terminal = ToolRegistry.standard(includesTerminal: true)
        XCTAssertNotNil(terminal.tool(named: "exec_command"))
        XCTAssertNotNil(terminal.tool(named: "write_stdin"))
        XCTAssertNil(terminal.tool(named: "run_shell"))
    }

    func testTerminalSchemasUseTheInteractiveYieldArgumentName() throws {
        let expected = "yield" + "-time_ms"
        let accidentalUnderscore = "yield" + "_time_ms"
        for descriptor in [ExecCommandTool.descriptor, WriteStdinTool.descriptor] {
            guard case .object(let schema) = descriptor.parameters,
                  case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(descriptor.name) has no object schema")
            }
            XCTAssertNotNil(properties[expected], descriptor.name)
            XCTAssertNil(properties[accidentalUnderscore], descriptor.name)
        }
    }

    private func processExists(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        Darwin.kill(pid, 0) == 0 || Darwin.errno == EPERM
        #elseif canImport(Glibc)
        Glibc.kill(pid, 0) == 0 || Glibc.errno == EPERM
        #else
        false
        #endif
    }
}
