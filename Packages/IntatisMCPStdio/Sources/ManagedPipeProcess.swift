import Foundation
import IntatisCore
import IntatisMCP
import IntatisMCPStdioGuard
import IntatisProtocol
import Logging
import MCP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum MCPManagedPipeError: Error, Equatable, LocalizedError, Sendable {
    case authorizationBindingMismatch
    case authorizationExpired
    case resolvedEnvironmentMismatch
    case invalidLaunchArtifact
    case launchArtifactUnreadable(String)
    case launchArtifactNotExecutable(String)
    case launchArtifactChanged(String)
    case workspaceIdentityChanged
    case workspaceUnavailable
    case ambiguousTestWorkspaceRoot
    case workspacePolicyUnsupported
    case workingDirectoryOutsideLease
    case workingDirectoryUnavailable
    case localStdioUnsupported
    case sandboxUnavailable
    case descendantExecutionGuardUnavailable
    case descendantExecutionPolicyViolation
    case exactNetworkPolicyUnavailable
    case exactNetworkPolicyViolation
    case invalidNetworkOrigin
    case processLaunchFailed(String)
    case processGroupIsolationFailed
    case pipeSetupFailed
    case transportNotConnected
    case transportClosed
    case outboundFrameTooLarge
    case outboundFrameInvalid
    case partialWriteUncertain
    case writeTimedOut
    case inboundFrameTooLarge
    case inboundFrameInvalid
    case partialFrameAtEOF
    case frameQueueOverflow
    case stderrLimitExceeded
    case stdoutReadFailed
    case stderrReadFailed

    public var errorDescription: String? {
        switch self {
        case .authorizationBindingMismatch:
            return "MCP stdio launch authorization does not match the exact authority"
        case .authorizationExpired:
            return "MCP stdio launch authorization expired before process start"
        case .resolvedEnvironmentMismatch:
            return "resolved MCP environment does not match the authorized references"
        case .invalidLaunchArtifact:
            return "MCP launch artifact identity is invalid"
        case .launchArtifactUnreadable:
            return "an MCP launch artifact cannot be read safely"
        case .launchArtifactNotExecutable:
            return "an MCP launch artifact is not executable"
        case .launchArtifactChanged(let stage):
            return "MCP launch artifact changed at \(stage)"
        case .workspaceIdentityChanged:
            return "the MCP workspace identity changed"
        case .workspaceUnavailable:
            return "the MCP workspace is unavailable"
        case .ambiguousTestWorkspaceRoot:
            return "the MCP Test launch has multiple script/package roots; configure one explicit working directory"
        case .workspacePolicyUnsupported:
            return "the host cannot prove the requested MCP workspace policy"
        case .workingDirectoryOutsideLease:
            return "the MCP working directory is outside the workspace lease"
        case .workingDirectoryUnavailable:
            return "the MCP working directory is unavailable"
        case .localStdioUnsupported:
            return "local MCP stdio is unsupported on this platform"
        case .sandboxUnavailable:
            return "the required local MCP process sandbox is unavailable"
        case .descendantExecutionGuardUnavailable:
            return "the host cannot prove the MCP descendant execution policy"
        case .descendantExecutionPolicyViolation:
            return "the MCP process attempted an unauthorized descendant execution"
        case .exactNetworkPolicyUnavailable:
            return "the host cannot prove the requested exact MCP network allow-list"
        case .exactNetworkPolicyViolation:
            return "the MCP process attempted to bypass its exact network allow-list"
        case .invalidNetworkOrigin:
            return "the MCP network allow-list contains an invalid origin"
        case .processLaunchFailed(let reason):
            return "managed MCP process launch failed: \(reason)"
        case .processGroupIsolationFailed:
            return "managed MCP process did not enter an isolated process group"
        case .pipeSetupFailed:
            return "managed MCP pipe setup failed"
        case .transportNotConnected:
            return "managed MCP transport is not connected"
        case .transportClosed:
            return "managed MCP transport is closed"
        case .outboundFrameTooLarge:
            return "outbound MCP frame exceeds the configured limit"
        case .outboundFrameInvalid:
            return "outbound MCP frame is not one complete JSON-RPC value"
        case .partialWriteUncertain:
            return "MCP pipe accepted only part of a frame; generation retired"
        case .writeTimedOut:
            return "MCP pipe write timed out; generation retired"
        case .inboundFrameTooLarge:
            return "inbound MCP frame exceeds the configured limit"
        case .inboundFrameInvalid:
            return "inbound MCP frame is malformed"
        case .partialFrameAtEOF:
            return "MCP stdout closed with an incomplete frame"
        case .frameQueueOverflow:
            return "MCP inbound frame queue overflowed"
        case .stderrLimitExceeded:
            return "MCP stderr exceeded the hostile-output limit"
        case .stdoutReadFailed:
            return "managed MCP stdout read failed"
        case .stderrReadFailed:
            return "managed MCP stderr read failed"
        }
    }
}

public struct MCPManagedPipeLimits: Equatable, Sendable {
    public let maximumFrameBytes: Int
    public let maximumQueuedFrames: Int
    public let maximumStderrRetainedBytes: Int
    public let maximumStderrTotalBytes: UInt64
    public let maximumDiagnosticEntries: Int
    public let writeTimeoutMilliseconds: Int
    public let terminationGraceMilliseconds: Int
    public let killDrainMilliseconds: Int

    public init(
        maximumFrameBytes: Int = 4 * 1_024 * 1_024,
        maximumQueuedFrames: Int = 64,
        maximumStderrRetainedBytes: Int = 64 * 1_024,
        maximumStderrTotalBytes: UInt64 = 16 * 1_024 * 1_024,
        maximumDiagnosticEntries: Int = 128,
        writeTimeoutMilliseconds: Int = 10_000,
        terminationGraceMilliseconds: Int = 500,
        killDrainMilliseconds: Int = 2_000
    ) {
        self.maximumFrameBytes = min(
            max(maximumFrameBytes, 1_024),
            64 * 1_024 * 1_024)
        self.maximumQueuedFrames = min(max(maximumQueuedFrames, 1), 4_096)
        self.maximumStderrRetainedBytes = min(
            max(maximumStderrRetainedBytes, 1_024),
            4 * 1_024 * 1_024)
        self.maximumStderrTotalBytes = min(
            max(maximumStderrTotalBytes, 64 * 1_024),
            1_024 * 1_024 * 1_024)
        self.maximumDiagnosticEntries = min(
            max(maximumDiagnosticEntries, 1),
            4_096)
        self.writeTimeoutMilliseconds = min(
            max(writeTimeoutMilliseconds, 100),
            120_000)
        self.terminationGraceMilliseconds = min(
            max(terminationGraceMilliseconds, 50),
            30_000)
        self.killDrainMilliseconds = min(
            max(killDrainMilliseconds, 100),
            30_000)
    }
}

public struct MCPStdioDiagnosticsSnapshot: Equatable, Sendable {
    public let entries: [String]
    public let totalBytes: UInt64
    public let truncated: Bool
    public let terminalError: String?

    public init(
        entries: [String],
        totalBytes: UInt64,
        truncated: Bool,
        terminalError: String?
    ) {
        self.entries = entries
        self.totalBytes = totalBytes
        self.truncated = truncated
        self.terminalError = terminalError
    }
}

/// A real newline-framed MCP stdio transport and process owner.
///
/// The only constructor requires a host-minted launch ticket. Launch uses
/// posix_spawn directly (never Process or `/bin/sh -c`), an isolated process
/// group, three independent pipes, and a platform sandbox wrapper. All reader
/// and lifecycle tasks are retained and awaited during disconnect.
public actor ManagedPipeProcess: Transport {
    public nonisolated let logger: Logger

    private let limits: MCPManagedPipeLimits
    private let ticket: MCPAuthorizedStdioLaunchTicket
    private let runtimeDirectory: URL
    private let processID: pid_t
    private let networkGateway: MCPStdioExactNetworkGateway?
    private let executionGuard:
        MCPStdioExecutionGuardOwner?
    private var stdinDescriptor: Int32
    private var stdoutDescriptor: Int32
    private var stderrDescriptor: Int32
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation:
        AsyncThrowingStream<Data, Error>.Continuation

    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var failureCleanupTask: Task<Void, Never>?
    private var stdoutPending = Data()
    private var stderrRetained = Data()
    private var stderrTotalBytes: UInt64 = 0
    private var stderrTruncated = false
    private var exitStatus: Int32?
    private var processGroupRetired = false
    private var connected = false
    private var stopping = false
    private var disconnected = false
    private var terminalError: MCPManagedPipeError?
    private var cleanupFinished = false

    private init(
        ticket: MCPAuthorizedStdioLaunchTicket,
        limits: MCPManagedPipeLimits,
        runtimeDirectory: URL,
        processID: pid_t,
        stdinDescriptor: Int32,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        executionGuard: MCPStdioExecutionGuardOwner?,
        networkGateway: MCPStdioExactNetworkGateway?
    ) {
        self.ticket = ticket
        self.limits = limits
        self.runtimeDirectory = runtimeDirectory
        self.processID = processID
        self.networkGateway = networkGateway
        self.stdinDescriptor = stdinDescriptor
        self.stdoutDescriptor = stdoutDescriptor
        self.stderrDescriptor = stderrDescriptor
        self.executionGuard = executionGuard
        self.logger = Logger(
            label: IntatisHostApplication.identity.keychainService(
                "mcp.stdio.\(ticket.request.authority.server.serverID.rawValue)"))

        var continuation:
            AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(limits.maximumQueuedFrames)
        ) {
            continuation = $0
        }
        self.messageContinuation = continuation
    }

    public static func launch(
        ticket: MCPAuthorizedStdioLaunchTicket,
        limits: MCPManagedPipeLimits = .init(),
        now: Date = Date()
    ) async throws -> ManagedPipeProcess {
        guard ticket.authorization.expiresAt > now else {
            throw MCPManagedPipeError.authorizationExpired
        }
        guard ticket.authorization.authorityFingerprint
                == ticket.request.authority.fingerprint,
              ticket.authorization.launchArtifactFingerprint
                == ticket.request.configuration.launchArtifact.fingerprint,
              ticket.authorization.workspaceLeaseID
                == ticket.request.workspaceLease.id,
              ticket.request.workspaceLease.rootIdentity?
                .matchesCurrentDirectory(
                    rootPath: ticket.request.workspaceLease.rootPath) == true else {
            throw MCPManagedPipeError.authorizationBindingMismatch
        }

        try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(
            ticket.request.configuration.launchArtifact)
        for helper in ticket.request.configuration.helperArtifacts {
            try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(helper)
        }
        let plan = try MCPStdioSandboxCompiler.compile(ticket: ticket)
        try MCPStdioExecutionGuard.verifyImmediatelyBeforeSpawn(ticket)

        do {
            let spawned = try spawnManagedPipeProcess(plan: plan)
            let process = ManagedPipeProcess(
                ticket: ticket,
                limits: limits,
                runtimeDirectory: plan.runtimeDirectory,
                processID: spawned.processID,
                stdinDescriptor: spawned.stdinDescriptor,
                stdoutDescriptor: spawned.stdoutDescriptor,
                stderrDescriptor: spawned.stderrDescriptor,
                executionGuard: spawned.executionGuard,
                networkGateway: plan.networkGateway
            )
            await process.startOwnedTasks()
            return process
        } catch {
            plan.networkGateway?.stop()
            try? FileManager.default.removeItem(at: plan.runtimeDirectory)
            throw error
        }
    }

    public func connect() async throws {
        guard !disconnected, terminalError == nil else {
            throw terminalError ?? MCPManagedPipeError.transportClosed
        }
        guard exitStatus == nil else {
            throw MCPManagedPipeError.transportClosed
        }
        connected = true
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }

    public func send(_ data: Data) async throws {
        guard connected, !stopping, !disconnected else {
            throw MCPManagedPipeError.transportNotConnected
        }
        guard data.count <= limits.maximumFrameBytes else {
            await failGeneration(.outboundFrameTooLarge)
            throw MCPManagedPipeError.outboundFrameTooLarge
        }
        guard Self.isValidJSONRPCFrame(data) else {
            await failGeneration(.outboundFrameInvalid)
            throw MCPManagedPipeError.outboundFrameInvalid
        }

        var frame = data
        frame.append(0x0A)
        var offset = 0
        let deadline = Date().addingTimeInterval(
            Double(limits.writeTimeoutMilliseconds) / 1_000)
        while offset < frame.count {
            if Task.isCancelled || stopping || disconnected {
                let error: MCPManagedPipeError = offset == 0
                    ? .transportClosed
                    : .partialWriteUncertain
                if offset > 0 { await failGeneration(error) }
                throw error
            }
            let written = frame.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return write(
                    stdinDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if Date() >= deadline {
                    await failGeneration(
                        offset == 0 ? .writeTimedOut : .partialWriteUncertain)
                    throw offset == 0
                        ? MCPManagedPipeError.writeTimedOut
                        : MCPManagedPipeError.partialWriteUncertain
                }
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            await failGeneration(
                offset == 0 ? .transportClosed : .partialWriteUncertain)
            throw offset == 0
                ? MCPManagedPipeError.transportClosed
                : MCPManagedPipeError.partialWriteUncertain
        }
    }

    public func diagnostics() -> MCPStdioDiagnosticsSnapshot {
        let text = Self.sanitizeDiagnostic(
            String(decoding: stderrRetained, as: UTF8.self),
            redactionValues: ticket.resolvedSecretEnvironmentValues
                + (networkGateway?.diagnosticRedactionValues ?? []))
        let lines = text.split(
            omittingEmptySubsequences: true,
            whereSeparator: \.isNewline)
        let entries = lines.suffix(limits.maximumDiagnosticEntries).map {
            String($0.prefix(2_048))
        }
        return MCPStdioDiagnosticsSnapshot(
            entries: entries,
            totalBytes: stderrTotalBytes,
            truncated: stderrTruncated
                || lines.count > limits.maximumDiagnosticEntries,
            terminalError: terminalError?.errorDescription)
    }

    /// Installs generation-local gateway credentials in the session-owned
    /// in-memory output redactor without exposing them through public
    /// diagnostics or durable state.
    func registerGatewayDiagnosticRedactionValues(
        with registrar: any MCPSecretRedactionRegistering
    ) {
        networkGateway?
            .registerDiagnosticRedactionValues(
                with: registrar)
    }

    public func isRunning() -> Bool {
        exitStatus == nil || ownedProcessGroupIsAlive()
    }

    public func disconnect() async {
        if let failureCleanupTask {
            await failureCleanupTask.value
            return
        }
        if disconnected {
            await awaitIOAndLifecycleTasks()
            return
        }
        stopping = true
        connected = false
        closeDescriptor(&stdinDescriptor)

        await waitForOwnedProcessTree(
            milliseconds: limits.terminationGraceMilliseconds)
        if isRunning() {
            signalOwnedProcessGroup(SIGTERM)
            await waitForOwnedProcessTree(
                milliseconds: limits.terminationGraceMilliseconds)
        }
        if isRunning() {
            signalOwnedProcessGroup(SIGKILL)
            await waitForOwnedProcessTree(
                milliseconds: limits.killDrainMilliseconds)
        }

        disconnected = true
        closeDescriptor(&stdoutDescriptor)
        closeDescriptor(&stderrDescriptor)
        stdoutTask?.cancel()
        stderrTask?.cancel()
        lifecycleTask?.cancel()
        if terminalError == nil {
            messageContinuation.finish()
        } else {
            messageContinuation.finish(throwing: terminalError)
        }
        await awaitIOAndLifecycleTasks()
        cleanupRuntime()
    }

    private func startOwnedTasks() {
        guard stdoutTask == nil, stderrTask == nil, lifecycleTask == nil else {
            return
        }
        stdoutTask = Task { [weak self] in
            await self?.stdoutReadLoop()
        }
        stderrTask = Task { [weak self] in
            await self?.stderrReadLoop()
        }
        lifecycleTask = Task { [weak self] in
            await self?.processLifecycleLoop()
        }
    }

    private func stdoutReadLoop() async {
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while !Task.isCancelled, stdoutDescriptor >= 0 {
            let count = buffer.withUnsafeMutableBytes {
                read(stdoutDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                stdoutPending.append(contentsOf: buffer.prefix(count))
                guard await consumeFrames() else { return }
                continue
            }
            if count == 0 {
                if !stdoutPending.isEmpty {
                    await failGeneration(.partialFrameAtEOF)
                } else if !stopping, terminalError == nil {
                    messageContinuation.finish()
                }
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            if !stopping {
                await failGeneration(.stdoutReadFailed)
            }
            return
        }
    }

    private func consumeFrames() async -> Bool {
        while let newline = stdoutPending.firstIndex(of: 0x0A) {
            var frame = Data(stdoutPending[..<newline])
            stdoutPending.removeSubrange(...newline)
            if frame.last == 0x0D { frame.removeLast() }
            if frame.isEmpty { continue }
            guard frame.count <= limits.maximumFrameBytes else {
                await failGeneration(.inboundFrameTooLarge)
                return false
            }
            guard Self.isValidJSONRPCFrame(frame) else {
                await failGeneration(.inboundFrameInvalid)
                return false
            }
            switch messageContinuation.yield(frame) {
            case .enqueued:
                break
            case .dropped:
                await failGeneration(.frameQueueOverflow)
                return false
            case .terminated:
                return false
            @unknown default:
                await failGeneration(.frameQueueOverflow)
                return false
            }
        }
        if stdoutPending.count > limits.maximumFrameBytes {
            await failGeneration(.inboundFrameTooLarge)
            return false
        }
        return true
    }

    private func stderrReadLoop() async {
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while !Task.isCancelled, stderrDescriptor >= 0 {
            let count = buffer.withUnsafeMutableBytes {
                read(stderrDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                stderrTotalBytes += UInt64(count)
                appendStderr(Data(buffer.prefix(count)))
                if stderrTotalBytes > limits.maximumStderrTotalBytes {
                    await failGeneration(.stderrLimitExceeded)
                    return
                }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            if !stopping {
                await failGeneration(.stderrReadFailed)
            }
            return
        }
    }

    private func appendStderr(_ data: Data) {
        if data.count >= limits.maximumStderrRetainedBytes {
            stderrRetained = Data(
                data.suffix(limits.maximumStderrRetainedBytes))
            stderrTruncated = true
            return
        }
        let overflow = stderrRetained.count + data.count
            - limits.maximumStderrRetainedBytes
        if overflow > 0 {
            stderrRetained.removeFirst(overflow)
            stderrTruncated = true
        }
        stderrRetained.append(data)
    }

    private func processLifecycleLoop() async {
        while !Task.isCancelled {
            #if os(Linux)
            if let executionGuard {
                let observation = executionGuard.poll()
                if observation.networkViolation,
                   terminalError == nil {
                    await failGeneration(
                        .exactNetworkPolicyViolation)
                } else if observation.violation,
                   terminalError == nil {
                    await failGeneration(
                        .descendantExecutionPolicyViolation)
                }
                if observation.targetExited,
                   exitStatus == nil {
                    exitStatus = observation.targetExitStatus
                    closeDescriptor(&stdinDescriptor)
                    if !stopping, terminalError == nil {
                        await failGeneration(.transportClosed)
                    }
                }
                if observation.allTraceesExited {
                    if exitStatus == nil {
                        exitStatus = -1
                        closeDescriptor(&stdinDescriptor)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            #endif
            guard exitStatus == nil else { return }
            var status: Int32 = 0
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID {
                let signal = status & 0x7f
                exitStatus = signal == 0
                    ? (status >> 8) & 0xff
                    : 128 + signal
                closeDescriptor(&stdinDescriptor)
                return
            }
            if result < 0, errno != EINTR {
                // ECHILD means another owner violated the process contract.
                // Retire without signaling a potentially reused PID.
                exitStatus = -1
                if !stopping {
                    await failGeneration(.transportClosed)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func failGeneration(_ error: MCPManagedPipeError) async {
        guard terminalError == nil else { return }
        terminalError = error
        connected = false
        stopping = true
        messageContinuation.finish(throwing: error)
        closeDescriptor(&stdinDescriptor)
        if exitStatus == nil {
            signalOwnedProcessGroup(SIGTERM)
        }
        failureCleanupTask = Task { [weak self] in
            await self?.finishFailureCleanup()
        }
    }

    private func finishFailureCleanup() async {
        await waitForOwnedProcessTree(
            milliseconds: limits.terminationGraceMilliseconds)
        if isRunning() {
            signalOwnedProcessGroup(SIGKILL)
            await waitForOwnedProcessTree(
                milliseconds: limits.killDrainMilliseconds)
        }
        disconnected = true
        closeDescriptor(&stdoutDescriptor)
        closeDescriptor(&stderrDescriptor)
        stdoutTask?.cancel()
        stderrTask?.cancel()
        lifecycleTask?.cancel()
        await awaitIOAndLifecycleTasks()
        cleanupRuntime()
    }

    private func signalOwnedProcessGroup(_ signal: Int32) {
        if !processGroupRetired,
           kill(-processID, signal) < 0,
           errno == ESRCH {
            processGroupRetired = true
        }
        // Exact PID signaling is redundant while the process remains the
        // group leader and is a required cleanup backstop if a hostile image
        // attempts session/group manipulation.
        _ = kill(processID, signal)
    }

    private func ownedProcessGroupIsAlive() -> Bool {
        guard !processGroupRetired else { return false }
        if kill(-processID, 0) == 0 || errno == EPERM {
            return true
        }
        if errno == ESRCH {
            processGroupRetired = true
            return false
        }
        // An unexpected kernel query failure is not proof of cleanup.
        return true
    }

    private func waitForOwnedProcessTree(milliseconds: Int) async {
        let deadline = Date().addingTimeInterval(
            Double(max(1, milliseconds)) / 1_000)
        while (exitStatus == nil || ownedProcessGroupIsAlive()),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func awaitIOAndLifecycleTasks() async {
        _ = await stdoutTask?.value
        _ = await stderrTask?.value
        _ = await lifecycleTask?.value
        stdoutTask = nil
        stderrTask = nil
        lifecycleTask = nil
    }

    private func cleanupRuntime() {
        guard !cleanupFinished else { return }
        cleanupFinished = true
        networkGateway?.stop()
        try? FileManager.default.removeItem(at: runtimeDirectory)
    }

    private func closeDescriptor(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        _ = close(descriptor)
        descriptor = -1
    }

    private static func isValidJSONRPCFrame(_ data: Data) -> Bool {
        guard !data.isEmpty,
              !data.contains(0),
              let value = try? JSONSerialization.jsonObject(
                with: data,
                options: []) else {
            return false
        }
        if let object = value as? [String: Any] {
            return object["jsonrpc"] as? String == "2.0"
        }
        if let batch = value as? [[String: Any]], !batch.isEmpty {
            return batch.allSatisfy {
                $0["jsonrpc"] as? String == "2.0"
            }
        }
        return false
    }

    private static func sanitizeDiagnostic(
        _ raw: String,
        redactionValues: [String]
    ) -> String {
        var result = raw
            .replacingOccurrences(of: "\0", with: "")
        for value in redactionValues
        where value.utf8.count >= 4 {
            result = result.replacingOccurrences(
                of: value,
                with: "[REDACTED]")
        }
        let patterns = [
            #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(token|secret|password|passwd|authorization|api[_-]?key|credential)\b\s*[:=]\s*[^\s,;]+"#,
            #"(?i)([?&](token|secret|password|key|code)=)[^&#\s]+"#,
            #"(?i)://[^/\s:@]+:[^/\s@]+@"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern) else {
                continue
            }
            let range = NSRange(
                result.startIndex..<result.endIndex,
                in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[REDACTED]")
        }
        return result
    }
}

private struct MCPSpawnedPipeProcess {
    let processID: pid_t
    let stdinDescriptor: Int32
    let stdoutDescriptor: Int32
    let stderrDescriptor: Int32
    let executionGuard: MCPStdioExecutionGuardOwner?
}

private func spawnManagedPipeProcess(
    plan: MCPStdioSandboxPlan
) throws -> MCPSpawnedPipeProcess {
    guard secureSystemWrapper(plan.wrapperExecutable) else {
        throw MCPManagedPipeError.sandboxUnavailable
    }
    #if os(Linux)
    return try spawnLinuxGuardedPipeProcess(plan: plan)
    #else

    var stdinPipe: [Int32] = [-1, -1]
    var stdoutPipe: [Int32] = [-1, -1]
    var stderrPipe: [Int32] = [-1, -1]
    guard pipe(&stdinPipe) == 0,
          pipe(&stdoutPipe) == 0,
          pipe(&stderrPipe) == 0 else {
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.pipeSetupFailed
    }

    #if canImport(Darwin)
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    #else
    var actions = posix_spawn_file_actions_t()
    var attributes = posix_spawnattr_t()
    #endif
    guard posix_spawn_file_actions_init(&actions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.pipeSetupFailed
    }
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    let actionResult = [
        posix_spawn_file_actions_adddup2(
            &actions, stdinPipe[0], STDIN_FILENO),
        posix_spawn_file_actions_adddup2(
            &actions, stdoutPipe[1], STDOUT_FILENO),
        posix_spawn_file_actions_adddup2(
            &actions, stderrPipe[1], STDERR_FILENO),
        posix_spawn_file_actions_addclose(&actions, stdinPipe[1]),
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
    ]
    guard actionResult.allSatisfy({ $0 == 0 }) else {
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.pipeSetupFailed
    }
    #if os(macOS)
    guard posix_spawn_file_actions_addchdir(
        &actions,
        plan.workingDirectory) == 0 else {
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.pipeSetupFailed
    }
    #endif

    var flags = Int16(
        POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_SETSIGDEF)
    #if os(macOS)
    flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    for signal in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE, SIGCHLD] {
        sigaddset(&defaultSignals, signal)
    }
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
          posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals) == 0 else {
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.pipeSetupFailed
    }

    let argv = [plan.wrapperExecutable] + plan.wrapperArguments
    let envp = plan.environment.keys.sorted().map {
        "\($0)=\(plan.environment[$0] ?? "")"
    }
    var pid: pid_t = 0
    let spawnResult: Int32 = withMutableCStrings(argv) { argvPointer in
        withMutableCStrings(envp) { envPointer in
            posix_spawn(
                &pid,
                plan.wrapperExecutable,
                &actions,
                &attributes,
                argvPointer,
                envPointer)
        }
    }

    _ = close(stdinPipe[0])
    stdinPipe[0] = -1
    _ = close(stdoutPipe[1])
    stdoutPipe[1] = -1
    _ = close(stderrPipe[1])
    stderrPipe[1] = -1
    guard spawnResult == 0 else {
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.processLaunchFailed(
            String(cString: strerror(spawnResult)))
    }

    guard getpgid(pid) == pid else {
        _ = kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw MCPManagedPipeError.processGroupIsolationFailed
    }
    do {
        try setNonBlocking(stdinPipe[1])
        try setNonBlocking(stdoutPipe[0])
        try setNonBlocking(stderrPipe[0])
        #if os(macOS)
        guard fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
            throw MCPManagedPipeError.pipeSetupFailed
        }
        #endif
    } catch {
        _ = kill(-pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        closePipe(&stdinPipe)
        closePipe(&stdoutPipe)
        closePipe(&stderrPipe)
        throw error
    }
    return MCPSpawnedPipeProcess(
        processID: pid,
        stdinDescriptor: stdinPipe[1],
        stdoutDescriptor: stdoutPipe[0],
        stderrDescriptor: stderrPipe[0],
        executionGuard: nil)
    #endif
}

#if os(Linux)
private struct MCPStdioLinuxGuardObservation {
    let targetExited: Bool
    let targetExitStatus: Int32
    let allTraceesExited: Bool
    let violation: Bool
    let networkViolation: Bool
}

private final class MCPStdioExecutionGuardOwner:
    @unchecked Sendable
{
    private var pointer: OpaquePointer?

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    func poll() -> MCPStdioLinuxGuardObservation {
        guard let pointer else {
            return MCPStdioLinuxGuardObservation(
                targetExited: true,
                targetExitStatus: -1,
                allTraceesExited: true,
                violation: true,
                networkViolation: false)
        }
        var result = intatis_mcp_stdio_guard_poll_result_t()
        let status = intatis_mcp_stdio_guard_poll(
            pointer,
            &result)
        return MCPStdioLinuxGuardObservation(
            targetExited: result.target_exited != 0,
            targetExitStatus:
                Int32(result.target_exit_status),
            allTraceesExited:
                result.all_tracees_exited != 0,
            violation:
                result.violation != 0
                    || status
                    == INTATIS_MCP_STDIO_GUARD_POLICY_VIOLATION,
            networkViolation:
                result.network_violation != 0)
    }

    deinit {
        if let pointer {
            intatis_mcp_stdio_guard_destroy(pointer)
            self.pointer = nil
        }
    }
}

private func spawnLinuxGuardedPipeProcess(
    plan: MCPStdioSandboxPlan
) throws -> MCPSpawnedPipeProcess {
    guard case .linuxPtraceSeccomp(let primary, let helpers) =
            plan.executionGuard,
          plan.wrapperArguments
            .containsConsecutiveValues("--seccomp", "3") else {
        throw MCPManagedPipeError
            .descendantExecutionGuardUnavailable
    }
    let argv = [plan.wrapperExecutable] + plan.wrapperArguments
    let envp = plan.environment.keys.sorted().map {
        "\($0)=\(plan.environment[$0] ?? "")"
    }
    var primaryIdentity =
        intatis_mcp_stdio_exec_identity_t()
    primaryIdentity.device_id = primary.deviceID
    primaryIdentity.file_id = primary.fileID
    primaryIdentity.byte_count = primary.byteCount

    var helperIdentities = helpers.map { helper in
        var value = intatis_mcp_stdio_exec_identity_t()
        value.device_id = helper.deviceID
        value.file_id = helper.fileID
        value.byte_count = helper.byteCount
        return value
    }
    let primaryPath = strdup(primary.canonicalPath)
    let helperPaths = helpers.map { strdup($0.canonicalPath) }
    guard let primaryPath,
          helperPaths.allSatisfy({ $0 != nil }) else {
        free(primaryPath)
        helperPaths.forEach { free($0) }
        throw MCPManagedPipeError.pipeSetupFailed
    }
    defer {
        free(primaryPath)
        helperPaths.forEach { free($0) }
    }
    primaryIdentity.canonical_path =
        UnsafePointer(primaryPath)
    for index in helperIdentities.indices {
        helperIdentities[index].canonical_path =
            UnsafePointer(helperPaths[index]!)
    }

    var result =
        intatis_mcp_stdio_guard_spawn_result_t()
    var networkPolicy =
        intatis_mcp_stdio_network_policy_t()
    if let gateway = plan.networkGateway {
        networkPolicy.mode =
            Int32(
                INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY)
        networkPolicy.gateway_ipv4_network_order =
            inet_addr("127.0.0.1")
        networkPolicy.gateway_port_host_order =
            gateway.port
    } else {
        networkPolicy.mode =
            Int32(
                INTATIS_MCP_STDIO_NETWORK_DENIED)
    }
    let status: Int32 = withMutableCStrings(argv) {
        argvPointer in
        withMutableCStrings(envp) { envPointer in
            plan.wrapperExecutable.withCString {
                wrapperPointer in
                plan.workingDirectory.withCString {
                    workingDirectoryPointer in
                    plan.runtimeDirectory.path.withCString {
                        runtimePointer in
                        withUnsafePointer(
                            to: &primaryIdentity
                        ) { primaryPointer in
                            helperIdentities
                                .withUnsafeMutableBufferPointer {
                                    helperPointer in
                                    withUnsafePointer(
                                        to: &networkPolicy
                                    ) { networkPointer in
                                        intatis_mcp_stdio_guard_spawn(
                                            wrapperPointer,
                                            argvPointer,
                                            envPointer,
                                            workingDirectoryPointer,
                                            runtimePointer,
                                            primaryPointer,
                                            helperPointer.baseAddress,
                                            helperPointer.count,
                                            networkPointer,
                                            &result)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }
    guard status == INTATIS_MCP_STDIO_GUARD_OK,
          result.process_id > 0,
          result.stdin_descriptor >= 0,
          result.stdout_descriptor >= 0,
          result.stderr_descriptor >= 0,
          let guardPointer = result.guard else {
        for descriptor in [
            result.stdin_descriptor,
            result.stdout_descriptor,
            result.stderr_descriptor,
        ] where descriptor >= 0 {
            _ = close(descriptor)
        }
        if let guardPointer = result.guard {
            intatis_mcp_stdio_guard_destroy(guardPointer)
        }
        if status == INTATIS_MCP_STDIO_GUARD_UNAVAILABLE
            || status
                == INTATIS_MCP_STDIO_GUARD_TRACE_FAILED {
            throw MCPManagedPipeError
                .descendantExecutionGuardUnavailable
        }
        let reason = result.error_number == 0
            ? "linux execution guard rejected launch"
            : String(cString: strerror(result.error_number))
        throw MCPManagedPipeError.processLaunchFailed(reason)
    }
    return MCPSpawnedPipeProcess(
        processID: result.process_id,
        stdinDescriptor: result.stdin_descriptor,
        stdoutDescriptor: result.stdout_descriptor,
        stderrDescriptor: result.stderr_descriptor,
        executionGuard:
            MCPStdioExecutionGuardOwner(
                pointer: guardPointer))
}
#else
private final class MCPStdioExecutionGuardOwner:
    @unchecked Sendable
{}
#endif

private func secureSystemWrapper(_ path: String) -> Bool {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == 0,
          metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
          metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
        return false
    }
    return true
}

private func setNonBlocking(_ descriptor: Int32) throws {
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    let statusFlags = fcntl(descriptor, F_GETFL)
    guard descriptorFlags >= 0,
          statusFlags >= 0,
          fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
          fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
        throw MCPManagedPipeError.pipeSetupFailed
    }
}

private func closePipe(_ descriptors: inout [Int32]) {
    for index in descriptors.indices where descriptors[index] >= 0 {
        _ = close(descriptors[index])
        descriptors[index] = -1
    }
}

private func withMutableCStrings<Result>(
    _ strings: [String],
    _ body: (
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map {
        strdup($0)
    }
    pointers.append(nil)
    defer {
        for pointer in pointers.dropLast() {
            free(pointer)
        }
    }
    return pointers.withUnsafeMutableBufferPointer {
        body($0.baseAddress!)
    }
}

private extension Array where Element == String {
    func containsConsecutiveValues(
        _ first: String,
        _ second: String
    ) -> Bool {
        guard count >= 2 else { return false }
        return indices.dropLast().contains {
            self[$0] == first
                && self[index(after: $0)] == second
        }
    }
}

/// Cold-start reconciliation deliberately has no "kill historical PID" API.
/// A saved PID is never proof of ownership after process restart.
public enum MCPStdioCrashReconciliationPolicy {
    public static let maySignalHistoricalProcessIdentifier = false
}
