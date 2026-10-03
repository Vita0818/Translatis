import Foundation
import IntatisCore
import IntatisProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Managed terminal process sessions

final class BoundedOutputDrain: @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let nextOffset: UInt64
        let truncated: Bool
    }

    private let lock = NSLock()
    private let group = DispatchGroup()
    private let headCapacity: Int
    private let tailCapacity: Int
    private var head: [UInt8] = []
    private var tail: [UInt8]
    private var tailCount = 0
    private var tailWriteIndex = 0
    private var totalBytes: UInt64 = 0
    private var stopRequested = false

    init(readDescriptor: Int32,
         maximumBytes: Int) throws {
        let capacity = max(64 * 1_024, maximumBytes)
        headCapacity = capacity / 2
        tailCapacity = capacity - headCapacity
        tail = [UInt8](repeating: 0, count: tailCapacity)
        try configureNonBlockingTerminalDescriptor(readDescriptor)
        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                systemClose(readDescriptor)
                self?.group.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                guard self?.shouldStop == false else { return }
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    systemRead(
                        readDescriptor,
                        rawBuffer.baseAddress!,
                        rawBuffer.count)
                }
                if count > 0 {
                    self?.append(Array(buffer.prefix(count)))
                    continue
                }
                if count < 0, systemErrno() == EINTR { continue }
                if count < 0,
                   systemErrno() == EAGAIN || systemErrno() == EWOULDBLOCK {
                    usleep(5_000)
                    continue
                }
                // PTY masters commonly report EIO after the slave closes.
                return
            }
        }
    }

    func snapshot(from offset: UInt64,
                  maximumBytes: Int) -> Snapshot {
        lock.lock()
        let total = totalBytes
        let headCopy = Data(head)
        let tailCopy = chronologicalTailData()
        lock.unlock()

        let cursor = min(offset, total)
        let headEnd = UInt64(headCopy.count)
        let tailStart = total - UInt64(tailCopy.count)
        var captured = Data()
        var truncated = false

        if cursor < headEnd {
            captured.append(headCopy[Int(cursor)...])
            if tailStart > headEnd {
                captured.append(Self.omissionMarker(bytes: tailStart - headEnd))
                truncated = true
            }
            if tailCopy.isEmpty == false {
                captured.append(tailCopy)
            }
        } else if cursor < tailStart {
            captured.append(Self.omissionMarker(bytes: tailStart - cursor))
            captured.append(tailCopy)
            truncated = true
        } else if cursor < total {
            captured.append(tailCopy[Int(cursor - tailStart)...])
        }

        let responseLimit = max(4 * 1_024, maximumBytes)
        if captured.count > responseLimit {
            let headBytes = responseLimit / 2
            let tailBytes = responseLimit - headBytes
            let omitted = captured.count - headBytes - tailBytes
            var bounded = Data(captured.prefix(headBytes))
            bounded.append(Self.omissionMarker(bytes: UInt64(omitted)))
            bounded.append(captured.suffix(tailBytes))
            captured = bounded
            truncated = true
        }
        return Snapshot(
            data: captured,
            nextOffset: total,
            truncated: truncated)
    }

    func waitForDrain() {
        if group.wait(timeout: .now() + 2) == .timedOut {
            lock.lock()
            stopRequested = true
            lock.unlock()
            group.wait()
        }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func append(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false else { return }
        lock.lock()
        totalBytes = min(
            UInt64.max,
            totalBytes + UInt64(bytes.count))
        var sourceIndex = 0
        if head.count < headCapacity {
            let count = min(headCapacity - head.count, bytes.count)
            head.append(contentsOf: bytes.prefix(count))
            sourceIndex += count
        }
        while sourceIndex < bytes.count, tailCapacity > 0 {
            let count = min(
                tailCapacity - tailWriteIndex,
                bytes.count - sourceIndex)
            tail.replaceSubrange(
                tailWriteIndex..<(tailWriteIndex + count),
                with: bytes[sourceIndex..<(sourceIndex + count)])
            tailWriteIndex = (tailWriteIndex + count) % tailCapacity
            tailCount = min(tailCapacity, tailCount + count)
            sourceIndex += count
        }
        lock.unlock()
    }

    private func chronologicalTailData() -> Data {
        guard tailCount > 0 else { return Data() }
        if tailCount < tailCapacity {
            return Data(tail.prefix(tailCount))
        }
        var data = Data(tail[tailWriteIndex...])
        if tailWriteIndex > 0 {
            data.append(contentsOf: tail[..<tailWriteIndex])
        }
        return data
    }

    private static func omissionMarker(bytes: UInt64) -> Data {
        Data("\n[... \(bytes) output bytes omitted ...]\n".utf8)
    }
}

/// Ephemeral model of the editable terminal line. The PTY contract only
/// accepts the editing controls represented here; completion, history and
/// arbitrary escape sequences fail closed because their resulting shell line
/// cannot be reconstructed reliably by the permission boundary.
private struct TerminalInputSafetyState {
    var line: [UInt32] = []
}

/// A session-lifetime process supervisor for model-facing development
/// terminals. It deliberately reuses the same WorkspaceLease-to-OS-sandbox
/// compiler and process-group cleanup path as the existing structured runners.
public actor ProcessTerminalSessionManager: TerminalSessionManaging {
    private struct Session {
        let id: String
        let owner: TerminalSessionOwner
        let state: ManagedProcessState
        let stdoutDrain: BoundedOutputDrain
        let stderrDrain: BoundedOutputDrain?
        let runtimeURL: URL
        let startupMarkerURL: URL
        let workspaceRootPath: String
        let sandboxBackend: WorkspaceSandboxBackend
        let usesTTY: Bool
        var stdinDescriptor: Int32?
        var inputClosed: Bool
        var stdoutOffset: UInt64
        var stderrOffset: UInt64
        var redactionValues: [String]
        var inputSafetyState: TerminalInputSafetyState
        var stdoutPending: String
        var stderrPending: String
    }

    private enum StoredCompletion: Sendable {
        case observation(TerminalSessionObservation)
        case sandboxDenied(WorkspaceSandboxDeniedError)
        case failure(IntatisError)

        func resolve() throws -> TerminalSessionObservation {
            switch self {
            case .observation(let observation):
                return observation
            case .sandboxDenied(let error):
                throw error
            case .failure(let error):
                throw error
            }
        }
    }

    private struct CompletionTombstone: Sendable {
        let owner: TerminalSessionOwner
        let completion: StoredCompletion
        let expiresAt: Date
    }

    private let maximumSessions: Int
    private let maximumCapturedBytes: Int
    private let maximumResponseBytes: Int
    private let terminationGraceSeconds: TimeInterval
    private var sessions: [String: Session] = [:]
    private var completionTombstones: [String: CompletionTombstone] = [:]
    private var interactionInFlight: Set<String> = []
    private var workspaceInvalidated: Set<String> = []
    private var lifecycleWatchers: [String: Task<Void, Never>] = [:]
    private var isShutDown = false

    public init(maximumSessions: Int = 32,
                maximumCapturedBytes: Int = 8 * 1_024 * 1_024,
                maximumResponseBytes: Int = 64 * 1_024,
                terminationGraceSeconds: TimeInterval = 0.5) {
        self.maximumSessions = max(1, maximumSessions)
        self.maximumCapturedBytes = max(64 * 1_024, maximumCapturedBytes)
        self.maximumResponseBytes = max(4 * 1_024, maximumResponseBytes)
        self.terminationGraceSeconds = max(0.05, terminationGraceSeconds)
    }

    public func activeSessionCount() -> Int {
        sessions.count
    }

    public func execute(_ request: TerminalExecRequest,
                        owner: TerminalSessionOwner,
                        workspaceLease: WorkspaceLease) async throws -> TerminalSessionObservation {
        guard !isShutDown else {
            throw IntatisError.config("the terminal manager is shut down")
        }
        pruneCompletionTombstones()
        guard sessions.count < maximumSessions else {
            throw IntatisError.io("the terminal session limit (\(maximumSessions)) has been reached")
        }
        guard request.command.isEmpty == false else {
            throw IntatisError.decoding("exec_command requires a non-empty command")
        }
        guard !ShellCommandRiskClassifier.isDangerous(request.command) else {
            throw IntatisError.permissionDenied(
                "dangerous shell command is not allowed")
        }
        guard !ShellCommandRiskClassifier.changesInteractiveInputSemantics(
            request.command) else {
            throw IntatisError.permissionDenied(
                "changing terminal input editing semantics is not allowed")
        }
        guard (250...30_000).contains(request.yieldMilliseconds) else {
            throw IntatisError.decoding("yield_time_ms must be between 250 and 30000")
        }
        guard (1_000...1_800_000).contains(request.timeoutMilliseconds) else {
            throw IntatisError.decoding("timeout_ms must be between 1000 and 1800000")
        }
        guard ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(request.shellPath),
              FileManager.default.isExecutableFile(atPath: request.shellPath) else {
            throw IntatisError.permissionDenied("the requested shell is not available")
        }

        let workspace = try validatedWorkspace(URL(fileURLWithPath: workspaceLease.rootPath))
        let lease = try effectiveWorkspaceLease(
            workspaceLease,
            workspace: workspace,
            mandatoryDeniedPatterns: WorkspaceLease.mandatoryTerminalDeniedPatterns)
        guard lease.rootIdentity == owner.workspaceRootIdentity else {
            throw IntatisError.permissionDenied("terminal owner does not match the workspace lease")
        }
        let workingDirectory = try PathConfinement.resolve(
            request.workingDirectory ?? ".",
            within: workspace)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw IntatisError.notFound("terminal working directory does not exist")
        }

        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                IntatisHostApplication.identity.temporaryPrefix(
                    "terminal-\(UUID().uuidString)"),
                isDirectory: true)
        let home = runtime.appendingPathComponent("home", isDirectory: true)
        let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        } catch {
            throw IntatisError.io("could not create the terminal runtime directory")
        }

        do {
            let session = try launch(
                request,
                owner: owner,
                workspace: workspace,
                workingDirectory: workingDirectory,
                workspaceLease: lease,
                runtime: runtime,
                home: home,
                temporary: temporary)
            sessions[session.id] = session
            startLifecycleWatcher(for: session)
            do {
                return try await observeExclusively(
                    sessionID: session.id,
                    yieldMilliseconds: request.yieldMilliseconds)
            } catch {
                await stopAndDrain(sessionID: session.id)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: runtime)
            throw error
        }
    }

    public func interact(sessionID: String,
                         request: TerminalInteractionRequest,
                         owner: TerminalSessionOwner) async throws -> TerminalSessionObservation {
        guard !isShutDown else {
            throw IntatisError.config("the terminal manager is shut down")
        }
        guard (250...30_000).contains(request.yieldMilliseconds) else {
            throw IntatisError.decoding("yield-time_ms must be between 250 and 30000")
        }
        pruneCompletionTombstones()
        guard var session = sessions[sessionID] else {
            if let tombstone = completionTombstones[sessionID] {
                guard tombstone.owner == owner else {
                    throw IntatisError.permissionDenied(
                        "terminal session belongs to another agent or task")
                }
                completionTombstones.removeValue(forKey: sessionID)
                return try tombstone.completion.resolve()
            }
            throw IntatisError.notFound("terminal session is not active")
        }
        guard session.owner == owner else {
            throw IntatisError.permissionDenied("terminal session belongs to another agent or task")
        }
        guard !interactionInFlight.contains(sessionID) else {
            throw IntatisError.io(
                "another terminal interaction is already in progress for this session")
        }
        guard owner.workspaceRootIdentity.matchesCurrentDirectory(
            rootPath: session.workspaceRootPath) else {
            workspaceInvalidated.insert(sessionID)
            session.state.requestStop(.cancelled)
            await stopAndDrain(sessionID: sessionID)
            throw IntatisError.permissionDenied(
                "terminal workspace root changed; the session was terminated")
        }

        if let characters = request.characters, characters.isEmpty == false {
            guard characters.utf8.count <= 32 * 1_024 else {
                throw IntatisError.decoding("terminal input exceeds 32768 UTF-8 bytes")
            }
            let updatedSafetyState = try terminalInputSafetyState(
                previous: session.inputSafetyState,
                appending: characters)
            let retainedInputBytes = session.redactionValues.reduce(0) {
                $0 + $1.utf8.count
            }
            guard session.redactionValues.count < 64,
                  retainedInputBytes + characters.utf8.count <= 256 * 1_024 else {
                throw IntatisError.io(
                    "terminal input privacy buffer is full; start a fresh command session")
            }
            guard !session.inputClosed, let descriptor = session.stdinDescriptor else {
                throw IntatisError.io("terminal input is already closed")
            }
            // Keep interactive input only in this process' session memory so a
            // delayed echo can still be removed from later poll results. Store
            // it before writing because a nonblocking write may partially
            // succeed before reporting backpressure.
            session.redactionValues.append(characters)
            session.inputSafetyState = updatedSafetyState
            sessions[sessionID] = session
            do {
                try writeAllNonBlocking(Data(characters.utf8), to: descriptor)
            } catch {
                // A nonblocking descriptor may accept a prefix before
                // reporting backpressure. The exact terminal line is then
                // unknowable, so this session must not accept another input.
                session.inputClosed = true
                sessions[sessionID] = session
                session.state.requestStop(.cancelled)
                await stopAndDrain(sessionID: sessionID)
                throw error
            }
        }
        if request.closeInput, !session.inputClosed {
            if session.usesTTY, let descriptor = session.stdinDescriptor {
                do {
                    try writeAllNonBlocking(Data([0x04]), to: descriptor)
                } catch {
                    session.inputClosed = true
                    sessions[sessionID] = session
                    session.state.requestStop(.cancelled)
                    await stopAndDrain(sessionID: sessionID)
                    throw error
                }
            } else if let descriptor = session.stdinDescriptor {
                systemClose(descriptor)
                session.stdinDescriptor = nil
            }
            session.inputClosed = true
            sessions[sessionID] = session
        }
        if request.terminate {
            session.state.requestStop(.cancelled)
        }
        return try await observeExclusively(
            sessionID: sessionID,
            yieldMilliseconds: request.yieldMilliseconds)
    }

    public func terminate(taskID: TaskID, reason _: String) async {
        let matching = sessions.values
            .filter { $0.owner.taskID == taskID }
            .map(\.id)
        for sessionID in matching {
            await stopAndDrain(sessionID: sessionID)
        }
    }

    public func terminateAll(reason _: String) async {
        let active = Array(sessions.keys)
        for sessionID in active {
            await stopAndDrain(sessionID: sessionID)
        }
    }

    public func shutdown(reason: String) async {
        if isShutDown { return }
        isShutDown = true
        await terminateAll(reason: reason)
        lifecycleWatchers.values.forEach { $0.cancel() }
        lifecycleWatchers.removeAll()
        completionTombstones.removeAll()
    }

    private func launch(_ request: TerminalExecRequest,
                        owner: TerminalSessionOwner,
                        workspace: URL,
                        workingDirectory: URL,
                        workspaceLease: WorkspaceLease,
                        runtime: URL,
                        home: URL,
                        temporary: URL) throws -> Session {
        let startupMarker = runtime.appendingPathComponent("command-started")
        guard FileManager.default.createFile(atPath: startupMarker.path, contents: Data()) else {
            throw IntatisError.io("could not create the terminal startup marker")
        }

        var environment = terminalEnvironment(home: home, temporary: temporary)
        environment["SHELL"] = request.shellPath
        environment["TERM"] = request.usesTTY ? "xterm-256color" : "dumb"
        let shellArguments = [request.loginShell ? "-lc" : "-c", request.command]
        let executable = URL(fileURLWithPath: request.shellPath)
        let arguments = shellArguments

        let networkAccess: WorkspaceNetworkAccess = request.allowsNetwork ? .allowed : .denied
        let processSpec: ManagedProcessSpec
        let sandboxBackend: WorkspaceSandboxBackend
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw IntatisError.config(
                "terminal execution is disabled because the macOS workspace sandbox is unavailable")
        }
        let profile = try macOSSandboxProfile(
            workspace: workspace,
            runtime: runtime,
            trustedReadRoots: terminalRuntimeReadRoots(environment: environment),
            writableRoots: [],
            workspaceLease: workspaceLease,
            networkAccess: networkAccess)
        processSpec = ManagedProcessSpec(
            executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile] + managedTerminalExecutionArguments(
                executable: executable,
                arguments: arguments,
                startupMarker: startupMarker),
            environment: environment)
        sandboxBackend = .macOSSandboxExec
        #elseif os(Linux)
        guard let bubblewrap = bubblewrapExecutable() else {
            throw IntatisError.config(
                "terminal execution is disabled because Bubblewrap is unavailable")
        }
        guard workspaceLease.allowedPathRules.count == 1,
              workspaceLease.allowedPathRules[0].pattern == ".",
              workspaceLease.deniedPatterns.isEmpty else {
            throw IntatisError.config(
                "terminal execution is disabled because Bubblewrap cannot enforce this WorkspaceLease path policy")
        }
        processSpec = ManagedProcessSpec(
            executable: bubblewrap,
            arguments: try bubblewrapArguments(
                workspace: workspace,
                runtime: runtime,
                executable: executable,
                arguments: arguments,
                trustedReadRoots: terminalRuntimeReadRoots(environment: environment),
                writableRoots: [],
                workspaceLease: workspaceLease,
                environment: environment,
                networkAccess: networkAccess,
                startupMarker: startupMarker,
                maximumGeneratedFileBytes: maximumCapturedBytes),
            environment: environment)
        sandboxBackend = .bubblewrap
        #else
        throw IntatisError.config("terminal execution is unsupported on this platform")
        #endif

        var childInputDescriptor: Int32 = -1
        var parentInteractionDescriptor: Int32 = -1
        var childOutputDescriptor: Int32 = -1
        var childErrorDescriptor: Int32 = -1
        var parentOutputDescriptor: Int32 = -1
        var parentErrorDescriptor: Int32 = -1
        var stdoutDrain: BoundedOutputDrain?
        var stderrDrain: BoundedOutputDrain?
        var keepParentInteractionDescriptor = false
        defer {
            if childInputDescriptor >= 0 {
                systemClose(childInputDescriptor)
            }
            if childOutputDescriptor >= 0 {
                systemClose(childOutputDescriptor)
            }
            if childErrorDescriptor >= 0 {
                systemClose(childErrorDescriptor)
            }
            if parentOutputDescriptor >= 0 {
                systemClose(parentOutputDescriptor)
            }
            if parentErrorDescriptor >= 0 {
                systemClose(parentErrorDescriptor)
            }
            if !keepParentInteractionDescriptor,
               parentInteractionDescriptor >= 0 {
                systemClose(parentInteractionDescriptor)
            }
        }
        if request.usesTTY {
            #if !os(macOS)
            throw IntatisError.config("PTY mode is currently unavailable on this platform")
            #endif
        } else {
            var pipeDescriptors = [Int32](repeating: -1, count: 2)
            guard systemPipe(&pipeDescriptors) == 0 else {
                throw IntatisError.io("could not create terminal input pipe")
            }
            childInputDescriptor = pipeDescriptors[0]
            parentInteractionDescriptor = pipeDescriptors[1]
            var outputPipe = [Int32](repeating: -1, count: 2)
            guard systemPipe(&outputPipe) == 0 else {
                throw IntatisError.io("could not create terminal output pipe")
            }
            parentOutputDescriptor = outputPipe[0]
            childOutputDescriptor = outputPipe[1]
            var errorPipe = [Int32](repeating: -1, count: 2)
            guard systemPipe(&errorPipe) == 0 else {
                throw IntatisError.io("could not create terminal error pipe")
            }
            parentErrorDescriptor = errorPipe[0]
            childErrorDescriptor = errorPipe[1]
        }
        let pid: Int32
        if request.usesTTY {
            #if os(macOS)
            let spawned = try spawnManagedPTYProcess(
                spec: processSpec,
                cwd: workingDirectory)
            pid = spawned.pid
            parentInteractionDescriptor = spawned.masterDescriptor
            do {
                try configureNonBlockingTerminalDescriptor(
                    parentInteractionDescriptor)
                parentOutputDescriptor = try duplicateDescriptor(
                    parentInteractionDescriptor)
                stdoutDrain = try BoundedOutputDrain(
                    readDescriptor: parentOutputDescriptor,
                    maximumBytes: maximumCapturedBytes)
                parentOutputDescriptor = -1
            } catch {
                killAndReapManagedProcess(pid)
                systemClose(parentInteractionDescriptor)
                parentInteractionDescriptor = -1
                throw error
            }
            #else
            throw IntatisError.config("PTY mode is currently unavailable on this platform")
            #endif
        } else {
            pid = try spawnManagedProcess(
                spec: processSpec,
                cwd: workingDirectory,
                stdinDescriptor: childInputDescriptor,
                stdoutDescriptor: childOutputDescriptor,
                stderrDescriptor: childErrorDescriptor)
            do {
                try configureNonBlockingTerminalDescriptor(
                    parentInteractionDescriptor)
                stdoutDrain = try BoundedOutputDrain(
                    readDescriptor: parentOutputDescriptor,
                    maximumBytes: max(64 * 1_024, maximumCapturedBytes / 2))
                parentOutputDescriptor = -1
                stderrDrain = try BoundedOutputDrain(
                    readDescriptor: parentErrorDescriptor,
                    maximumBytes: max(64 * 1_024, maximumCapturedBytes / 2))
                parentErrorDescriptor = -1
            } catch {
                killAndReapManagedProcess(pid)
                throw error
            }
        }
        guard let stdoutDrain else {
            killAndReapManagedProcess(pid)
            throw IntatisError.io("could not start terminal output supervision")
        }
        let state = ManagedProcessState(terminationGraceSeconds: terminationGraceSeconds)
        state.register(pid: pid)
        state.scheduleTimeout(after: Double(request.timeoutMilliseconds) / 1_000)
        DispatchQueue.global(qos: .utility).async {
            state.processExited(waitAndReap(pid: pid))
        }
        keepParentInteractionDescriptor = true
        return Session(
            id: IDGen.random(prefix: "terminal"),
            owner: owner,
            state: state,
            stdoutDrain: stdoutDrain,
            stderrDrain: stderrDrain,
            runtimeURL: runtime,
            startupMarkerURL: startupMarker,
            workspaceRootPath: workspace.path,
            sandboxBackend: sandboxBackend,
            usesTTY: request.usesTTY,
            stdinDescriptor: parentInteractionDescriptor,
            inputClosed: false,
            stdoutOffset: 0,
            stderrOffset: 0,
            redactionValues: [],
            inputSafetyState: TerminalInputSafetyState(),
            stdoutPending: "",
            stderrPending: "")
    }

    private func observeExclusively(
        sessionID: String,
        yieldMilliseconds: Int
    ) async throws -> TerminalSessionObservation {
        guard interactionInFlight.insert(sessionID).inserted else {
            throw IntatisError.io(
                "another terminal interaction is already in progress for this session")
        }
        defer { interactionInFlight.remove(sessionID) }
        return try await observation(
            sessionID: sessionID,
            yieldMilliseconds: yieldMilliseconds)
    }

    private func startLifecycleWatcher(for session: Session) {
        let sessionID = session.id
        let state = session.state
        let rootPath = session.workspaceRootPath
        let rootIdentity = session.owner.workspaceRootIdentity
        lifecycleWatchers[sessionID] = Task { [weak self] in
            while !Task.isCancelled, state.snapshotOutcome() == nil {
                if !rootIdentity.matchesCurrentDirectory(rootPath: rootPath) {
                    await self?.invalidateWorkspace(sessionID: sessionID)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            while await self?.hasInteractionInFlight(sessionID) == true {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else { return }
            }
            await self?.storeUnobservedCompletion(sessionID: sessionID)
        }
    }

    private func invalidateWorkspace(sessionID: String) {
        guard let session = sessions[sessionID] else { return }
        workspaceInvalidated.insert(sessionID)
        session.state.requestStop(.cancelled)
    }

    private func hasInteractionInFlight(_ sessionID: String) -> Bool {
        interactionInFlight.contains(sessionID)
    }

    private func storeUnobservedCompletion(sessionID: String) {
        guard let owner = sessions[sessionID]?.owner,
              sessions[sessionID]?.state.snapshotOutcome() != nil else {
            lifecycleWatchers.removeValue(forKey: sessionID)
            return
        }
        let completion: StoredCompletion
        do {
            completion = .observation(try finish(sessionID: sessionID))
        } catch let error as WorkspaceSandboxDeniedError {
            completion = .sandboxDenied(error)
        } catch let error as IntatisError {
            completion = .failure(error)
        } catch {
            completion = .failure(.io(error.localizedDescription))
        }
        completionTombstones[sessionID] = CompletionTombstone(
            owner: owner,
            completion: completion,
            expiresAt: Date().addingTimeInterval(300))
        pruneCompletionTombstones()
    }

    private func pruneCompletionTombstones() {
        let now = Date()
        completionTombstones = completionTombstones.filter {
            $0.value.expiresAt > now
        }
        if completionTombstones.count > maximumSessions * 2 {
            let keep = completionTombstones
                .sorted { $0.value.expiresAt > $1.value.expiresAt }
                .prefix(maximumSessions * 2)
            completionTombstones = Dictionary(
                uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private func observation(sessionID: String,
                             yieldMilliseconds: Int) async throws -> TerminalSessionObservation {
        let deadline = Date().addingTimeInterval(
            Double(max(500, yieldMilliseconds)) / 1_000)
        while true {
            try Task.checkCancellation()
            guard let session = sessions[sessionID] else {
                throw IntatisError.notFound("terminal session is not active")
            }
            if session.state.snapshotOutcome() != nil {
                return try finish(sessionID: sessionID)
            }
            let startupConfirmed = !FileManager.default.fileExists(
                atPath: session.startupMarkerURL.path)
            if Date() >= deadline, startupConfirmed {
                return try runningObservation(sessionID: sessionID)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func runningObservation(sessionID: String) throws -> TerminalSessionObservation {
        guard var session = sessions[sessionID] else {
            throw IntatisError.notFound("terminal session is not active")
        }
        let output = collectOutput(session: &session, final: false)
        sessions[sessionID] = session
        return TerminalSessionObservation(
            sessionID: sessionID,
            isRunning: true,
            stdout: output.stdout,
            stderr: output.stderr,
            exitCode: nil,
            truncated: output.truncated)
    }

    private func finish(sessionID: String) throws -> TerminalSessionObservation {
        guard var session = sessions.removeValue(forKey: sessionID),
              let outcome = session.state.snapshotOutcome() else {
            throw IntatisError.notFound("terminal session is not active")
        }
        lifecycleWatchers.removeValue(forKey: sessionID)?.cancel()
        let wasWorkspaceInvalidated = workspaceInvalidated.remove(sessionID) != nil
        // The process supervisor resolves only after the leader is reaped and
        // tracked descendants are gone. At that point both output pipes can be
        // drained to a definite close instead of relying on a fixed delay.
        session.stdoutDrain.waitForDrain()
        session.stderrDrain?.waitForDrain()
        if let descriptor = session.stdinDescriptor {
            systemClose(descriptor)
            session.stdinDescriptor = nil
        }
        let output = collectOutput(session: &session, final: true)
        let markerStillExists = FileManager.default.fileExists(
            atPath: session.startupMarkerURL.path)
        defer { try? FileManager.default.removeItem(at: session.runtimeURL) }
        if wasWorkspaceInvalidated {
            throw IntatisError.permissionDenied(
                "terminal workspace root changed while the command was running")
        }
        if markerStillExists,
           let denial = workspaceSandboxStartupDenial(
                in: ShellResult(
                    stdout: output.stdout,
                    stderr: output.stderr,
                    exitCode: outcome.exitCodeForPresentation),
                backend: session.sandboxBackend,
                managedCommandShimStarted: false) {
            throw denial
        }
        switch outcome {
        case .exited(let status):
            return TerminalSessionObservation(
                sessionID: nil,
                isRunning: false,
                stdout: output.stdout,
                stderr: output.stderr,
                exitCode: Int(status),
                truncated: output.truncated)
        case .cancelled:
            return TerminalSessionObservation(
                sessionID: nil,
                isRunning: false,
                stdout: output.stdout,
                stderr: output.stderr,
                exitCode: nil,
                truncated: output.truncated)
        case .timedOut:
            return TerminalSessionObservation(
                sessionID: nil,
                isRunning: false,
                stdout: output.stdout,
                stderr: output.stderr,
                exitCode: nil,
                timedOut: true,
                truncated: output.truncated)
        case .resourceLimit:
            throw IntatisError.config(
                "terminal process exceeded its runtime resource budget")
        }
    }

    private func collectOutput(
        session: inout Session,
        final: Bool
    ) -> (stdout: String, stderr: String, truncated: Bool) {
        let perStreamLimit = max(2_048, maximumResponseBytes / 2)
        let stdoutSnapshot = session.stdoutDrain.snapshot(
            from: session.stdoutOffset,
            maximumBytes: perStreamLimit)
        let stderrSnapshot = session.stderrDrain?.snapshot(
            from: session.stderrOffset,
            maximumBytes: perStreamLimit)
            ?? BoundedOutputDrain.Snapshot(
                data: Data(),
                nextOffset: session.stderrOffset,
                truncated: false)
        session.stdoutOffset = stdoutSnapshot.nextOffset
        session.stderrOffset = stderrSnapshot.nextOffset
        let stdout = redactedTerminalStream(
            newText: String(decoding: stdoutSnapshot.data, as: UTF8.self),
            pending: session.stdoutPending,
            values: session.redactionValues,
            final: final)
        let stderr = redactedTerminalStream(
            newText: String(decoding: stderrSnapshot.data, as: UTF8.self),
            pending: session.stderrPending,
            values: session.redactionValues,
            final: final)
        session.stdoutPending = stdout.pending
        session.stderrPending = stderr.pending
        return (
            stdout.text,
            stderr.text,
            stdoutSnapshot.truncated
                || stderrSnapshot.truncated
                || stdout.redacted
                || stderr.redacted)
    }

    private func stopAndDrain(sessionID: String) async {
        guard var session = sessions[sessionID] else { return }
        // Keep a PTY master alive while TERM/KILL cleanup runs so the reader
        // can drain the child's final output. A pipe may be closed immediately
        // to unblock a process waiting on EOF.
        if !session.usesTTY, let descriptor = session.stdinDescriptor {
            systemClose(descriptor)
            session.stdinDescriptor = nil
            sessions[sessionID] = session
        }
        session.state.requestStop(.cancelled)
        let deadline = Date().addingTimeInterval(max(2, terminationGraceSeconds + 1))
        while session.state.snapshotOutcome() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if session.state.snapshotOutcome() != nil {
            _ = try? finish(sessionID: sessionID)
        }
    }
}

private extension ManagedProcessOutcome {
    var exitCodeForPresentation: Int {
        switch self {
        case .exited(let status): return Int(status)
        case .cancelled, .timedOut, .resourceLimit: return 1
        }
    }
}

private struct RedactedTerminalStream {
    let text: String
    let pending: String
    let redacted: Bool
}

/// Tracks the editable command line across multiple writes. Permission review
/// intentionally never receives raw stdin, so this host-side guard must retain
/// enough ephemeral state to stop a hard-denied command split across calls.
/// Cursor movement, completion, history and arbitrary escape editing are not
/// forwarded because their result depends on mutable program keymaps. This
/// state is process memory only and is discarded with the session.
private func terminalInputSafetyState(
    previous: TerminalInputSafetyState,
    appending characters: String
) throws -> TerminalInputSafetyState {
    var state = previous
    for scalar in characters.unicodeScalars {
        switch scalar.value {
        case 0x03: // Ctrl-C: discard the line and interrupt the foreground job.
            state.line.removeAll(keepingCapacity: true)
        case 0x08, 0x7F: // Backspace.
            if state.line.isEmpty == false {
                state.line.removeLast()
            }
        case 0x0C: // Ctrl-L: redraw only.
            break
        case 0x0A, 0x0D: // LF / CR submit, unless escaped by a trailing backslash.
            if state.line.last == 0x5C {
                state.line.removeLast()
                try requireSafeTerminalInputLine(state.line)
            } else {
                try requireSafeTerminalInputLine(state.line)
                state.line.removeAll(keepingCapacity: true)
            }
        case 0x00...0x02, 0x04...0x07, 0x09, 0x0B, 0x0E...0x1F:
            throw IntatisError.permissionDenied(
                "unsupported terminal editing, history, completion, or escape control is not allowed")
        default:
            state.line.append(scalar.value)
            guard state.line.count <= 65_536 else {
                throw IntatisError.permissionDenied(
                    "terminal editable input line exceeds the safety limit")
            }
        }
        try requireSafeTerminalInputLine(state.line)
    }
    return state
}

private func requireSafeTerminalInputLine(_ scalars: [UInt32]) throws {
    let line = String(scalars.compactMap(UnicodeScalar.init).map(Character.init))
    if ShellCommandRiskClassifier.isDangerous(line) {
        throw IntatisError.permissionDenied(
            "dangerous interactive shell command is not allowed")
    }
    if ShellCommandRiskClassifier.changesInteractiveInputSemantics(line) {
        throw IntatisError.permissionDenied(
            "changing terminal input editing semantics is not allowed")
    }
}

private func redactedTerminalStream(newText: String,
                                    pending: String,
                                    values: [String],
                                    final: Bool) -> RedactedTerminalStream {
    let combined = pending + newText
    let sanitized = terminalSafeOutput(
        combined,
        redactingEchoesOf: values)
    let maximumCandidateLength = terminalRedactionCandidates(values)
        .map(\.count)
        .max() ?? 0
    let holdCount = final
        ? 0
        : min(
            sanitized.text.count,
            max(0, maximumCandidateLength - 1))
    guard holdCount > 0 else {
        return RedactedTerminalStream(
            text: sanitized.text,
            pending: "",
            redacted: sanitized.redacted)
    }
    let split = sanitized.text.index(
        sanitized.text.endIndex,
        offsetBy: -holdCount)
    return RedactedTerminalStream(
        text: String(sanitized.text[..<split]),
        pending: String(sanitized.text[split...]),
        redacted: sanitized.redacted)
}

private func terminalEnvironment(home: URL, temporary: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys where terminalEnvironmentKeyIsSensitive(key) {
        environment.removeValue(forKey: key)
    }
    for (key, value) in environment where value.contains("\0")
        || value.contains("\n")
        || value.contains("\r") {
        environment.removeValue(forKey: key)
    }
    let fallback = sanitizedProcessEnvironment(home: home, temporary: temporary)
    let inheritedPath = environment["PATH"].map(sanitizedExecutablePath)
    fallback.forEach { environment[$0.key] = $0.value }
    if let inheritedPath, inheritedPath.isEmpty == false {
        environment["PATH"] = inheritedPath
    }
    let xcodeToolchain = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    if FileManager.default.fileExists(atPath: xcodeToolchain) {
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = currentPath.isEmpty
            ? xcodeToolchain
            : xcodeToolchain + ":" + currentPath
    }
    let compilerCache = home
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("compiler-modules", isDirectory: true)
    environment["CLANG_MODULE_CACHE_PATH"] = compilerCache.path
    environment["SWIFT_MODULECACHE_PATH"] = compilerCache.path
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = compilerCache.path
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_ASKPASS"] = "/usr/bin/false"
    environment["SSH_ASKPASS"] = "/usr/bin/false"
    environment["PAGER"] = "cat"
    environment["GIT_PAGER"] = "cat"
    environment[IntatisHostApplication.identity.environmentVariable(
        "MANAGED_TERMINAL")] = "1"
    return environment
}

private func terminalEnvironmentKeyIsSensitive(_ key: String) -> Bool {
    let upper = key.uppercased()
    let fragments = [
        "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY",
        "CREDENTIAL", "PRIVATE_KEY", "COOKIE", "AUTH", "SIGNING",
        "CERTIFICATE", "KEYCHAIN", "PROXY", "DATABASE_URL", "DB_URL",
        "DSN", "JWT", "BEARER", "ACCESS_KEY", "CLIENT_SECRET",
        "SESSION_KEY",
    ]
    if fragments.contains(where: upper.contains) { return true }
    return upper.hasPrefix("AWS_")
        || upper.hasPrefix("AZURE_")
        || upper.hasPrefix("GOOGLE_APPLICATION_")
        || upper.hasPrefix("SSH_")
        || upper.hasPrefix("DYLD_")
        || upper.hasPrefix("XPC_")
        || upper.hasPrefix("BASH_FUNC_")
        || upper.hasPrefix("GIT_CONFIG")
}

private func sanitizedExecutablePath(_ path: String) -> String {
    let entries = path.split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init)
        .filter {
            $0.hasPrefix("/")
                && !$0.contains("\0")
                && !$0.contains("\n")
                && !$0.contains("\r")
        }
    return entries.joined(separator: ":")
}

private func terminalRuntimeReadRoots(environment: [String: String]) -> [URL] {
    var roots = structuredRuntimeReadRoots()
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    let pathEntries = environment["PATH"]?
        .split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init) ?? []
    for entry in pathEntries {
        let canonical = URL(fileURLWithPath: entry)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let path = canonical.path
        if path.hasPrefix("/opt/homebrew/") || path == "/opt/homebrew" {
            roots.append(URL(fileURLWithPath: "/opt/homebrew", isDirectory: true))
        } else if path.hasPrefix("/usr/local/") || path == "/usr/local" {
            roots.append(URL(fileURLWithPath: "/usr/local", isDirectory: true))
        } else if let safeHomeRoot = safeHomeToolRoot(path: path, home: home) {
            roots.append(URL(fileURLWithPath: safeHomeRoot, isDirectory: true))
        }
    }
    var seen: Set<String> = []
    return roots.compactMap {
        let canonical = $0.resolvingSymlinksInPath().standardizedFileURL
        return seen.insert(canonical.path).inserted ? canonical : nil
    }
}

private func safeHomeToolRoot(path: String, home: String) -> String? {
    let prefix = home.hasSuffix("/") ? home : home + "/"
    guard path.hasPrefix(prefix) else { return nil }
    let relative = String(path.dropFirst(prefix.count))
    let components = relative.split(separator: "/").map(String.init)
    guard let first = components.first else { return nil }
    switch first {
    case ".cargo":
        return components.dropFirst().first == "bin" ? prefix + ".cargo/bin" : nil
    case ".rustup":
        return components.dropFirst().first == "toolchains" ? prefix + ".rustup/toolchains" : nil
    case ".volta":
        return components.dropFirst().first == "tools" ? prefix + ".volta/tools" : nil
    case ".pyenv":
        return components.dropFirst().first == "versions" ? prefix + ".pyenv/versions" : nil
    case ".nvm":
        guard components.count >= 5,
              components[1] == "versions",
              components[2] == "node" else { return nil }
        return prefix + components.prefix(4).joined(separator: "/")
    case ".local":
        return components.dropFirst().first == "bin" ? prefix + ".local/bin" : nil
    case ".bun":
        return components.dropFirst().first == "bin" ? prefix + ".bun/bin" : nil
    case "go":
        if components.dropFirst().first == "bin" { return prefix + "go/bin" }
        if components.dropFirst().first == "pkg" { return prefix + "go/pkg" }
        return nil
    default:
        return nil
    }
}

private func writeAllNonBlocking(_ data: Data, to descriptor: Int32) throws {
    var written = 0
    while written < data.count {
        let count: Int = data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return systemWrite(
                descriptor,
                base.advanced(by: written),
                data.count - written)
        }
        if count > 0 {
            written += count
            continue
        }
        if count < 0, systemErrno() == EINTR { continue }
        if count < 0, systemErrno() == EAGAIN || systemErrno() == EWOULDBLOCK {
            throw IntatisError.io(
                "terminal input backpressure accepted \(written) of \(data.count) bytes; do not replay automatically")
        }
        throw IntatisError.io(
            "terminal input failed after \(written) of \(data.count) bytes; do not replay automatically")
    }
}

func configureNonBlockingTerminalDescriptor(
    _ descriptor: Int32
) throws {
    let currentFlags = systemFcntl(descriptor, F_GETFL, 0)
    guard currentFlags >= 0,
          systemFcntl(
            descriptor,
            F_SETFL,
            currentFlags | O_NONBLOCK) == 0 else {
        throw IntatisError.io(
            "could not configure non-blocking terminal input")
    }
}

private func duplicateDescriptor(_ descriptor: Int32) throws -> Int32 {
    #if canImport(Darwin)
    let duplicate = Darwin.dup(descriptor)
    #elseif canImport(Glibc)
    let duplicate = Glibc.dup(descriptor)
    #elseif canImport(Musl)
    let duplicate = Musl.dup(descriptor)
    #else
    let duplicate: Int32 = -1
    #endif
    guard duplicate >= 0 else {
        throw IntatisError.io("could not duplicate terminal output descriptor")
    }
    let descriptorFlags = systemFcntl(duplicate, F_GETFD, 0)
    guard descriptorFlags >= 0,
          systemFcntl(
            duplicate,
            F_SETFD,
            descriptorFlags | FD_CLOEXEC) == 0 else {
        systemClose(duplicate)
        throw IntatisError.io("could not isolate terminal output descriptor")
    }
    return duplicate
}

private func killAndReapManagedProcess(_ pid: Int32) {
    #if canImport(Darwin)
    _ = Darwin.kill(-pid, SIGKILL)
    _ = Darwin.kill(pid, SIGKILL)
    #elseif canImport(Glibc)
    _ = Glibc.kill(-pid, SIGKILL)
    _ = Glibc.kill(pid, SIGKILL)
    #elseif canImport(Musl)
    _ = Musl.kill(-pid, SIGKILL)
    _ = Musl.kill(pid, SIGKILL)
    #endif
    _ = waitAndReap(pid: pid)
}

func systemPipe(_ descriptors: inout [Int32]) -> Int32 {
    descriptors.withUnsafeMutableBufferPointer {
        #if canImport(Darwin)
        Darwin.pipe($0.baseAddress!)
        #elseif canImport(Glibc)
        Glibc.pipe($0.baseAddress!)
        #elseif canImport(Musl)
        Musl.pipe($0.baseAddress!)
        #else
        -1
        #endif
    }
}

func systemFcntl(_ descriptor: Int32,
                 _ command: Int32,
                 _ value: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.fcntl(descriptor, command, value)
    #elseif canImport(Glibc)
    Glibc.fcntl(descriptor, command, value)
    #elseif canImport(Musl)
    Musl.fcntl(descriptor, command, value)
    #else
    -1
    #endif
}

private func systemWrite(_ descriptor: Int32,
                         _ buffer: UnsafeRawPointer,
                         _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
    #elseif canImport(Musl)
    Musl.write(descriptor, buffer, count)
    #else
    -1
    #endif
}

func systemRead(_ descriptor: Int32,
                _ buffer: UnsafeMutableRawPointer,
                _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, count)
    #elseif canImport(Musl)
    Musl.read(descriptor, buffer, count)
    #else
    -1
    #endif
}

func systemClose(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #elseif canImport(Glibc)
    _ = Glibc.close(descriptor)
    #elseif canImport(Musl)
    _ = Musl.close(descriptor)
    #endif
}

func systemErrno() -> Int32 {
    #if canImport(Darwin)
    Darwin.errno
    #elseif canImport(Glibc)
    Glibc.errno
    #elseif canImport(Musl)
    Musl.errno
    #else
    0
    #endif
}

// MARK: - Model-facing tools

public struct ExecCommandTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "exec_command",
        description: "Start a managed development command in the agent workspace. It may return an opaque session ID when the command is still running.",
        sideEffect: .exec,
        parameters: Schema.object([
            "command": Schema.boundedString(minLength: 1, maxLength: 50_000),
            "workdir": Schema.boundedString(minLength: 1, maxLength: 2_048),
            "shell": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("/bin/zsh"),
                    .string("/bin/bash"),
                    .string("/bin/sh"),
                ]),
            ]),
            "login": Schema.boolean,
            "tty": Schema.boolean,
            "network": Schema.boolean,
            "yield-time_ms": Schema.boundedInteger(minimum: 250, maximum: 30_000),
            "timeout_ms": Schema.boundedInteger(minimum: 1_000, maximum: 1_800_000),
        ], required: ["command"]))

    private struct Args: Decodable {
        let command: String
        let workdir: String?
        let shell: String?
        let login: Bool?
        let tty: Bool?
        let network: Bool?
        let yieldTimeMilliseconds: Int?
        let timeoutMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case command, workdir, shell, login, tty, network
            case yieldTimeMilliseconds = "yield-time_ms"
            case timeoutMilliseconds = "timeout_ms"
        }
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).workdir).map { [$0] } ?? []
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool {
        (try? args.decode(Args.self).network) ?? false
    }

    public func permissionIntent(_ args: ToolArgs,
                                 workspaceRoot: URL) -> PermissionIntent {
        guard let value = try? args.decode(Args.self) else {
            return .derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: [],
                risksNetwork: false)
        }
        var effects: Set<PermissionDataEffect> = [.execute]
        var risks: Set<PermissionRisk> = [.processExecution]
        if value.network == true {
            effects.insert(.network)
            risks.insert(.networkAccess)
        }
        return PermissionIntent(
            action: "process.execute",
            resources: [
                PermissionResource(kind: .command, value: value.command),
                PermissionResource(
                    kind: .workspace,
                    value: workspaceRoot.path,
                    access: .readWrite),
            ],
            metadata: [
                "workdir": .string(value.workdir ?? "."),
                "tty": .bool(value.tty ?? false),
                "network": .bool(value.network ?? false),
            ],
            dataEffects: effects,
            risks: risks,
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs,
                        in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let terminal = context.terminal else {
            throw IntatisError.config("this runtime does not own a terminal manager")
        }
        let owner = try terminalOwner(in: context)
        let result = try await terminal.execute(
            TerminalExecRequest(
                command: value.command,
                workingDirectory: value.workdir,
                shellPath: value.shell ?? "/bin/zsh",
                loginShell: value.login ?? true,
                usesTTY: value.tty ?? false,
                allowsNetwork: value.network ?? false,
                yieldMilliseconds: value.yieldTimeMilliseconds ?? 10_000,
                timeoutMilliseconds: value.timeoutMilliseconds ?? 300_000),
            owner: owner,
            workspaceLease: context.workspaceLease)
        return terminalToolObservation(result)
    }
}

public struct WriteStdinTool: Tool {
    private static let authorizationSalt = UUID().uuidString

    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "write_stdin",
        description: "Continue an active managed command by sending input, closing input, requesting termination, or polling for new output.",
        sideEffect: .exec,
        parameters: Schema.object([
            "session_id": Schema.boundedString(minLength: 1, maxLength: 160),
            "chars": Schema.boundedString(maxLength: 32_768),
            "close_stdin": Schema.boolean,
            "terminate": Schema.boolean,
            "yield-time_ms": Schema.boundedInteger(minimum: 250, maximum: 30_000),
        ], required: ["session_id"]))

    private struct Args: Decodable {
        let sessionID: String
        let characters: String?
        let closeInput: Bool?
        let terminate: Bool?
        let yieldTimeMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case characters = "chars"
            case closeInput = "close_stdin"
            case terminate
            case yieldTimeMilliseconds = "yield-time_ms"
        }
    }

    public func permissionIntent(_ args: ToolArgs,
                                 workspaceRoot _: URL) -> PermissionIntent {
        guard let value = try? args.decode(Args.self) else {
            return .derived(
                toolName: Self.descriptor.name,
                sideEffect: Self.descriptor.sideEffect,
                touchedPaths: [],
                risksNetwork: false)
        }
        return PermissionIntent(
            action: "process.interact",
            resources: [
                PermissionResource(kind: .tool, value: value.sessionID),
            ],
            metadata: [
                "byteCount": .number(Double(value.characters?.utf8.count ?? 0)),
                "closeInput": .bool(value.closeInput ?? false),
                "terminate": .bool(value.terminate ?? false),
            ],
            dataEffects: [.execute],
            risks: [.processExecution],
            replayPolicy: .doNotReplay)
    }

    public func permissionActionPreview(_ args: ToolArgs) -> PermissionActionPreview? {
        guard let value = try? args.decode(Args.self) else { return nil }
        return PermissionActionPreview(
            kind: Self.descriptor.name,
            fields: [
                "session_id": value.sessionID,
                "byte_count": String(value.characters?.utf8.count ?? 0),
                "close_stdin": String(value.closeInput ?? false),
                "terminate": String(value.terminate ?? false),
            ])
    }

    /// Never place interactive bytes (which may be a password or confirmation
    /// code) into durable authorization state. A process-random salted digest
    /// still distinguishes same-length inputs during same-stack revalidation
    /// without leaving an offline verifier in EventLog.
    public func authorizationArgumentIdentity(_ args: ToolArgs) -> String {
        guard let value = try? args.decode(Args.self) else {
            return "write-stdin-invalid-v1"
        }
        let inputIdentity = value.characters.map {
            ToolRegistry.authorizationDigest(
                Self.authorizationSalt + "\u{001F}" + $0)
        } ?? "absent"
        return [
            "write-stdin-v2",
            value.sessionID,
            String(value.characters?.utf8.count ?? 0),
            value.characters == nil ? "absent" : "present",
            inputIdentity,
            value.closeInput == true ? "close" : "keep-open",
            value.terminate == true ? "terminate" : "continue",
            String(value.yieldTimeMilliseconds ?? 1_000),
        ].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public func execute(_ args: ToolArgs,
                        in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let terminal = context.terminal else {
            throw IntatisError.config("this runtime does not own a terminal manager")
        }
        let owner = try terminalOwner(in: context)
        let result = try await terminal.interact(
            sessionID: value.sessionID,
            request: TerminalInteractionRequest(
                characters: value.characters,
                closeInput: value.closeInput ?? false,
                terminate: value.terminate ?? false,
                yieldMilliseconds: value.yieldTimeMilliseconds ?? 1_000),
            owner: owner)
        return terminalToolObservation(
            result,
            redactingEchoOf: value.characters)
    }
}

private func terminalOwner(in context: ToolContext) throws -> TerminalSessionOwner {
    guard let authorization = context.authorization,
          let sessionID = authorization.sessionID,
          let agent = authorization.agent,
          let rootIdentity = context.workspaceLease.rootIdentity else {
        throw IntatisError.permissionDenied(
            "terminal execution requires a host-bound session, agent, and workspace identity")
    }
    if let reviewedIdentity = authorization.workspaceRootIdentity,
       reviewedIdentity != rootIdentity {
        throw IntatisError.permissionDenied(
            "terminal workspace identity differs from the reviewed authorization")
    }
    return TerminalSessionOwner(
        sessionID: sessionID,
        agent: agent,
        taskID: authorization.taskID,
        taskAttempt: authorization.attempt,
        workspaceRootIdentity: rootIdentity)
}

private func terminalToolObservation(
    _ result: TerminalSessionObservation,
    redactingEchoOf interactiveInput: String? = nil
) -> ToolObservation {
    let stdout = terminalSafeOutput(
        result.stdout,
        redactingEchoOf: interactiveInput)
    let stderr = terminalSafeOutput(
        result.stderr,
        redactingEchoOf: interactiveInput)
    var sections: [String] = []
    if stdout.text.isEmpty == false {
        sections.append(stdout.text)
    }
    if stderr.text.isEmpty == false {
        sections.append("[stderr]\n" + stderr.text)
    }
    if result.isRunning, let sessionID = result.sessionID {
        sections.append("[running session \(sessionID)]")
    } else if result.timedOut {
        sections.append("[timed out]")
    } else if let exitCode = result.exitCode {
        sections.append("[exit \(exitCode)]")
    } else {
        sections.append("[terminated]")
    }
    return ToolObservation(
        text: sections.joined(separator: sections.count > 1 ? "\n" : ""),
        truncated: result.truncated || stdout.redacted || stderr.redacted)
}

private func terminalSafeOutput(
    _ output: String,
    redactingEchoOf interactiveInput: String?
) -> (text: String, redacted: Bool) {
    terminalSafeOutput(
        output,
        redactingEchoesOf: interactiveInput.map { [$0] } ?? [])
}

private func terminalSafeOutput(
    _ output: String,
    redactingEchoesOf interactiveInputs: [String]
) -> (text: String, redacted: Bool) {
    var text = output
    var redacted = false
    for candidate in terminalRedactionCandidates(interactiveInputs)
        .sorted(by: { $0.utf8.count > $1.utf8.count })
        where text.contains(candidate) {
        text = text.replacingOccurrences(
            of: candidate,
            with: "[interactive input echo redacted]")
        redacted = true
    }
    let sanitized = PermissionReviewTextSanitizer.sanitize(
        text,
        maxCharacters: text.count)
    return (
        sanitized.text,
        redacted || sanitized.redacted || sanitized.truncated)
}

private func terminalRedactionCandidates(_ interactiveInputs: [String]) -> Set<String> {
    var candidates: Set<String> = []
    for interactiveInput in interactiveInputs where interactiveInput.isEmpty == false {
        candidates.insert(interactiveInput)
        candidates.insert(
            interactiveInput.replacingOccurrences(of: "\n", with: "\r\n"))
        let withoutTrailingNewlines = interactiveInput
            .trimmingCharacters(in: .newlines)
        if withoutTrailingNewlines.utf8.count >= 4 {
            candidates.insert(withoutTrailingNewlines)
        }
    }
    candidates.remove("")
    return candidates
}
