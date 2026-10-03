import Foundation
import IntatisCore
import IntatisProtocol
#if os(macOS)
import IntatisPTYLauncher
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private var hostToolIdentity: IntatisHostApplicationIdentity {
    IntatisHostApplication.identity
}

private var hostDocumentStagePrefix: String {
    "." + hostToolIdentity.temporaryPrefix("document-stage-")
}

private var hostLibreOfficeSocketPrefix: String {
    hostToolIdentity.temporaryPrefix("lo-")
}

private var hostGitWorktreesRelativeRoot: String {
    hostToolIdentity.hiddenWorkspaceDirectoryName + "/git-worktrees"
}

// MARK: - Shell

enum WorkspaceNetworkAccess {
    case denied
    case allowed
}

enum WorkspaceSandboxBackend: Sendable {
    case macOSSandboxExec
    case bubblewrap
}

enum WorkspaceProcessCompatibility: Sendable, Equatable {
    case none
    case libreOfficeHeadless
}

/// Recognizes only diagnostics emitted by the sandbox wrapper while it is
/// setting up the isolation boundary. A command that merely exits non-zero or
/// prints an unqualified "Operation not permitted" is intentionally not
/// classified: once the target process may have started, the result is an
/// ordinary runtime failure with no safe retry inference.
func workspaceSandboxStartupDenial(
    in result: ShellResult,
    backend: WorkspaceSandboxBackend,
    managedCommandShimStarted: Bool
) -> WorkspaceSandboxDeniedError? {
    guard result.exitCode != 0,
          managedCommandShimStarted == false else { return nil }
    let lines = result.stderr.split(whereSeparator: { $0.isNewline }).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    switch backend {
    case .macOSSandboxExec:
        let denied = lines.contains { line in
            let isWrapperDiagnostic = line.hasPrefix("sandbox-exec:")
                || line.hasPrefix("/usr/bin/sandbox-exec:")
            return isWrapperDiagnostic
                && line.contains("sandbox_apply:")
                && (line.contains("operation not permitted")
                    || line.contains("permission denied"))
        }
        return denied
            ? WorkspaceSandboxDeniedError(
                reason: "macOS workspace sandbox denied process startup")
            : nil

    case .bubblewrap:
        let denied = lines.contains { line in
            let isWrapperDiagnostic = line.hasPrefix("bwrap:")
                || line.hasPrefix("/usr/bin/bwrap:")
                || line.hasPrefix("/bin/bwrap:")
            return isWrapperDiagnostic
                && (line.contains("operation not permitted")
                    || line.contains("permission denied")
                    || line.contains("no permissions to create"))
        }
        return denied
            ? WorkspaceSandboxDeniedError(
                reason: "Bubblewrap workspace sandbox denied process startup")
            : nil
    }
}

/// Runs model-authored raw shell commands inside an OS-enforced workspace
/// envelope. The production registry does not expose this tool, but the runner
/// itself remains fail-closed for compatibility and regression tests.
public struct ProcessShellRunner: ShellRunner {
    public static var supportsWorkspaceSandbox: Bool {
        #if os(macOS)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
        #elseif os(Linux)
        bubblewrapExecutable() != nil
        #else
        false
        #endif
    }

    private let timeoutSeconds: TimeInterval
    private let terminationGraceSeconds: TimeInterval
    private let maximumOutputBytes: Int
    private let workspaceLease: WorkspaceLease?

    public init(timeoutSeconds: TimeInterval = 300,
                terminationGraceSeconds: TimeInterval = 0.5,
                maximumOutputBytes: Int = 8 * 1_024 * 1_024,
                workspaceLease: WorkspaceLease? = nil) {
        self.timeoutSeconds = max(0.05, timeoutSeconds)
        self.terminationGraceSeconds = max(0.05, terminationGraceSeconds)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
        self.workspaceLease = workspaceLease
    }

    func scoped(to lease: WorkspaceLease) -> ProcessShellRunner {
        ProcessShellRunner(
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumOutputBytes: maximumOutputBytes,
            workspaceLease: lease)
    }

    public func run(_ command: String, cwd: URL) async throws -> ShellResult {
        try await runWorkspaceProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            cwd: cwd,
            networkAccess: .denied,
            trustedReadRoots: [],
            writableRoots: [],
            workspaceLease: workspaceLease,
            environment: [:],
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumGeneratedFileBytes: maximumOutputBytes,
            maximumOutputBytes: maximumOutputBytes)
    }
}

/// Structured process backend used by document and browser wrappers. It uses
/// the same workspace allow-list and managed process lifecycle as raw shell,
/// never inherits the host environment, and denies network unless the caller
/// holds the dedicated network runner from `ToolContext`.
struct StructuredProcessShellRunner: ShellRunner {
    private let timeoutSeconds: TimeInterval
    private let terminationGraceSeconds: TimeInterval
    private let maximumOutputBytes: Int
    private let networkAccess: WorkspaceNetworkAccess
    private let workspaceLease: WorkspaceLease?

    init(timeoutSeconds: TimeInterval = 300,
         terminationGraceSeconds: TimeInterval = 0.5,
         maximumOutputBytes: Int = 8 * 1_024 * 1_024,
         allowsNetwork: Bool = false,
         workspaceLease: WorkspaceLease? = nil) {
        self.timeoutSeconds = max(0.05, timeoutSeconds)
        self.terminationGraceSeconds = max(0.05, terminationGraceSeconds)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
        self.networkAccess = allowsNetwork ? .allowed : .denied
        self.workspaceLease = workspaceLease
    }

    func scoped(to lease: WorkspaceLease) -> StructuredProcessShellRunner {
        StructuredProcessShellRunner(
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumOutputBytes: maximumOutputBytes,
            allowsNetwork: networkAccess == .allowed,
            workspaceLease: lease)
    }

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        try await runWorkspaceProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            cwd: cwd,
            networkAccess: networkAccess,
            trustedReadRoots: structuredRuntimeReadRoots(),
            writableRoots: [],
            workspaceLease: workspaceLease,
            environment: [:],
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumGeneratedFileBytes: maximumOutputBytes,
            maximumOutputBytes: maximumOutputBytes)
    }
}

/// Fixed, no-command-string boundary for document runtimes. The small shell
/// shim used by `runWorkspaceProcess` only marks successful sandbox startup;
/// backend arguments are passed as positional argv and are never evaluated as
/// shell source.
struct DocumentBackendProcessRunner: DocumentBackendRunner {
    /// Independent from the bounded stdout/stderr capture. A legitimate
    /// document may be much larger than its diagnostic output, while an
    /// unbounded backend must not be able to grow one file until disk
    /// exhaustion before staged-output validation runs.
    static let maximumGeneratedFileBytes = 1_024 * 1_024 * 1_024
    static let maximumGeneratedTotalBytes = 1_024 * 1_024 * 1_024
    static let maximumGeneratedEntries = 100_000
    static let maximumResidentBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    private let timeoutSeconds: TimeInterval
    private let terminationGraceSeconds: TimeInterval
    private let maximumOutputBytes: Int
    private let maximumResidentBytes: UInt64
    private let workspaceLease: WorkspaceLease?

    init(timeoutSeconds: TimeInterval = 300,
         terminationGraceSeconds: TimeInterval = 0.5,
         maximumOutputBytes: Int = 8 * 1_024 * 1_024,
         maximumResidentBytes: UInt64 = Self.maximumResidentBytes,
         workspaceLease: WorkspaceLease? = nil) {
        self.timeoutSeconds = max(0.05, timeoutSeconds)
        self.terminationGraceSeconds = max(0.05, terminationGraceSeconds)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
        self.maximumResidentBytes = max(1, maximumResidentBytes)
        self.workspaceLease = workspaceLease
    }

    func run(_ invocation: DocumentBackendInvocation,
             cwd: URL) async throws -> ShellResult {
        #if os(macOS) || os(Linux)
        let workspace = try validatedWorkspace(cwd)
        let reviewedLease = try validateManagedWorkspaceAccess(
            readablePaths: invocation.readableWorkspacePaths,
            writablePaths: invocation.writableWorkspacePaths,
            cwd: workspace,
            workspaceLease: workspaceLease,
            subject: "document")
        let processLease = try documentProcessLease(
            reviewedLease,
            workspace: workspace,
            reviewedReadablePaths: invocation.readableWorkspacePaths,
            reviewedWritablePaths: invocation.writableWorkspacePaths,
            internalWritablePaths: invocation.internalWritableWorkspacePaths)
        let reviewedReadOnlyRoots = try invocation.readableWorkspacePaths.map {
            try PathConfinement.resolve($0, within: workspace)
        }
        let internalReadOnlyRoots = try documentInternalReadOnlyRoots(
            invocation.internalReadOnlyWorkspacePaths,
            internalWritablePaths: invocation.internalWritableWorkspacePaths,
            workspace: workspace)
        let generatedOutputRoots = try invocation.internalWritableWorkspacePaths.map {
            try PathConfinement.resolve($0, within: workspace)
        }
        try validateDocumentBackendArguments(invocation)
        let backendEnvironment = try fixedDocumentBackendEnvironment(invocation)
        return try await runWorkspaceProcess(
            executable: try trustedDocumentExecutable(invocation.executable),
            arguments: invocation.arguments,
            cwd: workspace,
            // Fixed document invocations carry absolute input/output paths.
            // Launching at `/` lets libraries call getcwd() without granting
            // file-read-data on every ancestor of a user workspace.
            managedWorkingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            processCompatibility: invocation.executable == .libreOffice
                ? .libreOfficeHeadless
                : .none,
            networkAccess: .denied,
            trustedReadRoots: structuredRuntimeReadRoots(),
            writableRoots: [],
            workspaceLease: processLease,
            allowEmptyWorkspaceAccess: processLease.allowedPathRules.isEmpty,
            forcedReadOnlyWorkspaceRoots: reviewedReadOnlyRoots + internalReadOnlyRoots,
            environment: backendEnvironment,
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumGeneratedFileBytes: Self.maximumGeneratedFileBytes,
            maximumOutputBytes: maximumOutputBytes,
            generatedOutputRoots: generatedOutputRoots,
            maximumGeneratedTotalBytes: Self.maximumGeneratedTotalBytes,
            maximumGeneratedEntries: Self.maximumGeneratedEntries,
            maximumResidentBytes: maximumResidentBytes)
        #else
        throw IntatisError.config(
            "document backend execution is unavailable on this platform")
        #endif
    }
}

/// Process boundary for the trusted browser program generated by
/// `BrowserTools`.
///
/// This type accepts only `BrowserBackendInvocation`: it directly launches a
/// fixed Node program and cannot run a model-authored shell string. It
/// revalidates the exact root and invocation access plan immediately before
/// spawn, uses a sanitized environment, and reuses the managed
/// timeout/cancellation/process-tree/output lifecycle below.
///
/// The Node/browser process is deliberately not wrapped in the generic macOS
/// Seatbelt profile. Chromium renderer helpers must initialize Chromium's own
/// stricter per-process sandbox; macOS rejects that second initialization with
/// `forbidden-sandbox-reinit` when an outer sandbox-exec profile is inherited.
/// Passing `--no-sandbox` would make the browser run but remove the stronger
/// renderer boundary, so Intatis instead preserves Chromium's native sandbox
/// and constrains the fixed broker at its typed invocation boundary.
///
/// Linux keeps the existing Bubblewrap boundary and fails closed when bwrap is
/// unavailable.
struct BrowserBackendProcessRunner: BrowserBackendRunner {
    private let timeoutSeconds: TimeInterval
    private let terminationGraceSeconds: TimeInterval
    private let maximumOutputBytes: Int
    private let workspaceLease: WorkspaceLease?

    init(timeoutSeconds: TimeInterval = 300,
         terminationGraceSeconds: TimeInterval = 0.5,
         maximumOutputBytes: Int = 8 * 1_024 * 1_024,
         workspaceLease: WorkspaceLease? = nil) {
        self.timeoutSeconds = max(0.05, timeoutSeconds)
        self.terminationGraceSeconds = max(0.05, terminationGraceSeconds)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
        self.workspaceLease = workspaceLease
    }

    func scoped(to lease: WorkspaceLease) -> BrowserBackendProcessRunner {
        BrowserBackendProcessRunner(
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumOutputBytes: maximumOutputBytes,
            workspaceLease: lease)
    }

    func run(_ invocation: BrowserBackendInvocation,
             cwd: URL) async throws -> ShellResult {
        #if os(macOS)
        return try await runMacOSBrowserBackendProcess(
            invocation: invocation,
            cwd: cwd,
            workspaceLease: workspaceLease,
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumOutputBytes: maximumOutputBytes)
        #elseif os(Linux)
        return try await InjectedShellBrowserBackendRunner(
            shell: StructuredProcessShellRunner(
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            maximumOutputBytes: maximumOutputBytes,
            allowsNetwork: true,
            workspaceLease: workspaceLease)
        ).run(invocation, cwd: cwd)
        #else
        throw IntatisError.config(
            "browser process execution is unavailable on this platform")
        #endif
    }
}

#if os(macOS) || os(Linux)
struct ManagedProcessSpec {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
}

enum ManagedProcessOutcome: Sendable {
    case exited(Int32)
    case cancelled
    case timedOut
    case resourceLimit(ManagedProcessResourceLimit)
}

enum ManagedProcessResourceLimit: Sendable {
    case generatedOutput
    case residentMemory
}

enum ManagedProcessStopReason: Sendable {
    case cancelled
    case timedOut
    case resourceLimit(ManagedProcessResourceLimit)

    var outcome: ManagedProcessOutcome {
        switch self {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .resourceLimit(let limit): return .resourceLimit(limit)
        }
    }
}

final class ManagedProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let descendantTrackerGroup = DispatchGroup()
    private let terminationGraceSeconds: TimeInterval
    private var processID: Int32?
    private var trackedDescendants: Set<Int32> = []
    private var trackingStopped = false
    private var stopReason: ManagedProcessStopReason?
    private var outcome: ManagedProcessOutcome?
    private var continuation: CheckedContinuation<ManagedProcessOutcome, Never>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var resourceMonitorWorkItem: DispatchWorkItem?
    private var residentMemoryMonitorWorkItem: DispatchWorkItem?

    init(terminationGraceSeconds: TimeInterval) {
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    func register(pid: Int32) {
        lock.lock()
        processID = pid
        let pendingStop = stopReason
        lock.unlock()
        startDescendantTracking(root: pid)
        if pendingStop != nil {
            terminateRegisteredProcess()
        }
    }

    func scheduleTimeout(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.requestStop(.timedOut) }
        lock.lock()
        if outcome == nil {
            timeoutWorkItem = item
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        } else {
            lock.unlock()
        }
    }

    func scheduleGeneratedOutputLimit(
        roots: [URL],
        maximumBytes: UInt64,
        maximumEntries: Int
    ) {
        guard roots.isEmpty == false, maximumBytes > 0, maximumEntries > 0 else {
            return
        }
        let item = DispatchWorkItem { [weak self] in
            while let self, self.shouldMonitorResources {
                if documentGeneratedOutputExceedsBudget(
                    roots: roots,
                    maximumBytes: maximumBytes,
                    maximumEntries: maximumEntries) {
                    self.requestStop(.resourceLimit(.generatedOutput))
                    return
                }
                usleep(20_000)
            }
        }
        lock.lock()
        if outcome == nil {
            resourceMonitorWorkItem = item
            lock.unlock()
            DispatchQueue.global(qos: .utility).async(execute: item)
        } else {
            lock.unlock()
        }
    }

    func scheduleResidentMemoryLimit(maximumBytes: UInt64) {
        guard maximumBytes > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            while let self, self.shouldMonitorResources {
                self.lock.lock()
                let root = self.processID
                self.lock.unlock()
                if let root,
                   managedProcessResidentMemoryExceedsBudget(
                       root: root,
                       maximumBytes: maximumBytes) {
                    self.requestStop(.resourceLimit(.residentMemory))
                    return
                }
                usleep(20_000)
            }
        }
        lock.lock()
        if outcome == nil {
            residentMemoryMonitorWorkItem = item
            lock.unlock()
            DispatchQueue.global(qos: .utility).async(execute: item)
        } else {
            lock.unlock()
        }
    }

    private var shouldMonitorResources: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome == nil && trackingStopped == false
    }

    func requestStop(_ reason: ManagedProcessStopReason) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        if stopReason == nil {
            stopReason = reason
        }
        let hasProcess = processID != nil
        lock.unlock()
        if hasProcess {
            terminateRegisteredProcess()
        }
    }

    func processExited(_ status: Int32) {
        lock.lock()
        let resolved = stopReason?.outcome ?? .exited(status)
        let leader = processID
        processID = nil
        trackingStopped = true
        lock.unlock()
        _ = descendantTrackerGroup.wait(timeout: .now() + 0.10)
        lock.lock()
        let descendants = trackedDescendants
        lock.unlock()
        // A successful helper is not allowed to leave background work behind.
        signalProcessGroupAndDescendants(root: leader, descendants: descendants, value: SIGKILL)
        if let leader {
            waitForProcessGroupToEmpty(leader: leader, descendants: descendants)
        }
        resolve(resolved)
    }

    func wait() async -> ManagedProcessOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func snapshotOutcome() -> ManagedProcessOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    private func terminateRegisteredProcess() {
        lock.lock()
        guard outcome == nil, let pid = processID, let reason = stopReason else {
            lock.unlock()
            return
        }
        let grace = terminationGraceSeconds
        let descendants = trackedDescendants
        lock.unlock()

        signalProcessGroupAndDescendants(root: pid, descendants: descendants, value: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = self.outcome == nil && self.processID == pid
            self.lock.unlock()
            if stillRunning {
                self.refreshTrackedDescendants(root: pid)
                self.lock.lock()
                let descendants = self.trackedDescendants
                self.lock.unlock()
                signalProcessGroupAndDescendants(root: pid, descendants: descendants, value: SIGKILL)
            }
        }
        _ = reason // resolution happens only after waitpid reaps the leader
    }

    private func resolve(_ resolved: ManagedProcessOutcome) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = resolved
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        resourceMonitorWorkItem?.cancel()
        resourceMonitorWorkItem = nil
        residentMemoryMonitorWorkItem?.cancel()
        residentMemoryMonitorWorkItem = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: resolved)
    }

    private func startDescendantTracking(root: Int32) {
        #if canImport(Darwin)
        let trackerGroup = descendantTrackerGroup
        trackerGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { trackerGroup.leave() }
            guard let self else { return }
            while true {
                self.refreshTrackedDescendants(root: root)
                self.lock.lock()
                let shouldStop = self.trackingStopped || self.processID != root
                self.lock.unlock()
                if shouldStop { return }
                usleep(5_000)
            }
        }
        #else
        _ = root
        #endif
    }

    private func refreshTrackedDescendants(root: Int32) {
        #if canImport(Darwin)
        let discovered = Set(darwinDescendants(of: root))
        lock.lock()
        trackedDescendants.formUnion(discovered)
        lock.unlock()
        #else
        _ = root
        #endif
    }
}

func validatedWorkspace(_ cwd: URL) throws -> URL {
    let workspace = cwd.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw IntatisError.io("shell workspace does not exist or is not a directory")
    }
    return workspace
}

func effectiveWorkspaceLease(_ candidate: WorkspaceLease?,
                             workspace: URL,
                             mandatoryDeniedPatterns: [String] = [],
                             allowEmptyPathRules: Bool = false) throws -> WorkspaceLease {
    var lease = candidate ?? WorkspaceLease(rootPath: workspace.path, access: .readWrite)
    var seenDeniedPatterns = Set(lease.deniedPatterns)
    for pattern in mandatoryDeniedPatterns where seenDeniedPatterns.insert(pattern).inserted {
        lease.deniedPatterns.append(pattern)
    }
    let leaseRoot = URL(fileURLWithPath: lease.rootPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard leaseRoot.path == workspace.path else {
        throw IntatisError.permissionDenied("workspace lease root does not match the managed process workspace")
    }
    guard let rootIdentity = lease.rootIdentity else {
        throw IntatisError.permissionDenied("workspace lease is missing its reviewed root identity")
    }
    guard rootIdentity.canonicalPath == leaseRoot.path,
          rootIdentity.matchesCurrentDirectory(rootPath: lease.rootPath),
          rootIdentity.matchesCurrentDirectory(rootPath: workspace.path) else {
        throw IntatisError.permissionDenied("workspace lease root identity changed after review")
    }
    guard allowEmptyPathRules || lease.allowedPathRules.isEmpty == false else {
        throw IntatisError.permissionDenied("workspace lease process allow-list is empty")
    }
    for pattern in lease.allowedPathRules.map(\.pattern) + lease.deniedPatterns {
        let normalized = pattern.replacingOccurrences(of: "\\", with: "/")
        guard normalized.isEmpty == false,
              normalized.hasPrefix("/") == false,
              normalized.split(separator: "/").contains("..") == false,
              normalized.contains("\0") == false,
              normalized.contains("\n") == false,
              normalized.contains("\r") == false else {
            throw IntatisError.permissionDenied("workspace lease contains an unsafe process path rule")
        }
    }
    return lease
}

@discardableResult
func validateManagedWorkspaceAccess(
    readablePaths: [String],
    writablePaths: [String],
    cwd: URL,
    workspaceLease: WorkspaceLease?,
    subject: String
) throws -> WorkspaceLease {
    let workspace = try validatedWorkspace(cwd)
    let lease = try effectiveWorkspaceLease(
        workspaceLease,
        workspace: workspace,
        mandatoryDeniedPatterns:
            WorkspaceLease.mandatoryManagedStoreDeniedPatterns)
    if writablePaths.isEmpty == false, lease.access != .readWrite {
        throw IntatisError.permissionDenied(
            "\(subject) execution requires a read-write workspace lease")
    }

    for rawPath in readablePaths + writablePaths {
        let resolved = try PathConfinement.resolve(rawPath, within: workspace)
        let relative = PathConfinement.relativePath(of: resolved, root: workspace)
        if lease.deniedPatterns.contains(where: {
            workspaceLeasePath(relative, matches: $0, caseInsensitive: true)
        }) {
            throw IntatisError.permissionDenied(
                "\(subject) path is denied by the workspace lease: \(relative)")
        }
        let allowed = lease.allowedPathRules.contains { rule in
            rule.pattern == "."
                || workspaceLeasePath(relative, matches: rule.pattern)
        }
        if allowed == false {
            throw IntatisError.permissionDenied(
                "\(subject) path is outside the workspace lease allow-list: \(relative)")
        }
    }
    return lease
}

@discardableResult
func validateBrowserWorkspaceAccess(
    readablePaths: [String],
    writablePaths: [String],
    cwd: URL,
    workspaceLease: WorkspaceLease?
) throws -> WorkspaceLease {
    try validateManagedWorkspaceAccess(
        readablePaths: readablePaths,
        writablePaths: writablePaths,
        cwd: cwd,
        workspaceLease: workspaceLease,
        subject: "browser")
}

/// Derives an invocation-only lease from the already validated durable lease.
/// The external parser receives only the reviewed input files plus a
/// host-created staging directory. In particular, a durable read-write lease
/// containing `.` is never handed unchanged to the document sandbox.
func documentProcessLease(
    _ reviewedLease: WorkspaceLease,
    workspace: URL,
    reviewedReadablePaths: [String],
    reviewedWritablePaths: [String],
    internalWritablePaths: [String]
) throws -> WorkspaceLease {
    if internalWritablePaths.isEmpty == false,
       reviewedLease.access != .readWrite {
        throw IntatisError.permissionDenied(
            "document staging requires a read-write workspace lease")
    }
    let reviewedParents = try reviewedWritablePaths.map {
        try PathConfinement.resolve($0, within: workspace)
            .deletingLastPathComponent()
            .standardizedFileURL.path
    }
    guard internalWritablePaths.isEmpty || reviewedParents.isEmpty == false else {
        throw IntatisError.permissionDenied(
            "document staging is not bound to a reviewed destination")
    }

    var processLease = reviewedLease
    processLease.access = internalWritablePaths.isEmpty ? .readOnly : .readWrite
    processLease.allowedPathRules = []
    var patterns = Set<String>()

    for rawPath in reviewedReadablePaths {
        let resolved = try PathConfinement.resolve(rawPath, within: workspace)
        let relative = try exactDocumentProcessPath(
            resolved,
            workspace: workspace)
        if patterns.insert(relative).inserted {
            processLease.allowedPathRules.append(PathRule(pattern: relative))
        }
    }
    for rawPath in internalWritablePaths {
        let resolved = try PathConfinement.resolve(rawPath, within: workspace)
        guard resolved.lastPathComponent.hasPrefix(
            hostDocumentStagePrefix) else {
            throw IntatisError.permissionDenied(
                "document backend received an invalid internal staging path")
        }
        let parent = resolved.deletingLastPathComponent().standardizedFileURL.path
        guard reviewedParents.contains(parent) else {
            throw IntatisError.permissionDenied(
                "document staging path is not a sibling of a reviewed destination")
        }
        let relative = try exactDocumentProcessPath(
            resolved,
            workspace: workspace)
        if reviewedLease.deniedPatterns.contains(where: {
            workspaceLeasePath(relative, matches: $0, caseInsensitive: true)
        }) {
            throw IntatisError.permissionDenied(
                "document staging path is denied by the workspace lease")
        }
        if patterns.insert(relative).inserted {
            processLease.allowedPathRules.append(PathRule(pattern: relative))
        }
    }
    return processLease
}

private func exactDocumentProcessPath(
    _ resolved: URL,
    workspace: URL
) throws -> String {
    let relative = PathConfinement.relativePath(of: resolved, root: workspace)
    // PathRule is a glob-shaped durable type. Document invocations need an
    // exact path, so fail closed instead of accidentally widening a literal
    // filename containing its two wildcard characters.
    guard relative.isEmpty == false,
          relative != ".",
          relative.contains("*") == false,
          relative.contains("?") == false else {
        throw IntatisError.permissionDenied(
            "document backend path cannot be represented as an exact process rule")
    }
    return relative
}

private func documentInternalReadOnlyRoots(
    _ rawPaths: [String],
    internalWritablePaths: [String],
    workspace: URL
) throws -> [URL] {
    guard rawPaths.isEmpty == false else { return [] }
    let stages = try internalWritablePaths.map {
        try PathConfinement.resolve($0, within: workspace)
            .standardizedFileURL
    }
    guard stages.isEmpty == false else {
        throw IntatisError.permissionDenied(
            "document internal read-only path is not bound to a staging root")
    }
    return try rawPaths.map { rawPath in
        let resolved = try PathConfinement.resolve(rawPath, within: workspace)
            .standardizedFileURL
        guard stages.contains(where: { stage in
            resolved.path != stage.path
                && PathConfinement.isWithin(resolved.path, root: stage)
        }) else {
            throw IntatisError.permissionDenied(
                "document internal read-only path is outside its staging root")
        }
        return resolved
    }
}

private func validateDocumentBackendArguments(
    _ invocation: DocumentBackendInvocation
) throws {
    guard invocation.arguments.allSatisfy({ !$0.contains("\0") }),
          invocation.environment.keys.allSatisfy({ key in
              !key.contains("\0")
                  && key.range(
                      of: #"^[A-Z][A-Z0-9_]{0,63}$"#,
                      options: .regularExpression) != nil
          }),
          invocation.environment.values.allSatisfy({ !$0.contains("\0") }) else {
        throw IntatisError.config("document backend invocation contains an unsafe argv or environment value")
    }
    let allowedEnvironment = Set([
        hostToolIdentity.environmentVariable("DOCUMENT_REQUEST"),
        hostToolIdentity.environmentVariable("DOCUMENT_OPERATION"),
        "PYTHONHASHSEED",
    ])
    guard Set(invocation.environment.keys).isSubset(of: allowedEnvironment) else {
        throw IntatisError.config(
            "document backend invocation requested a non-allowlisted environment key")
    }
}

private func fixedDocumentBackendEnvironment(
    _ invocation: DocumentBackendInvocation
) throws -> [String: String] {
    var environment = invocation.environment
    guard let runtime = intatisDocumentRuntimeRoot() else {
        throw IntatisError.config("fixed document runtime root is unavailable")
    }
    if invocation.executable == .pythonRuntime {
        let pythonHome = runtime
            .appendingPathComponent("python/Python.framework/Versions/3.11", isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: pythonHome.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue,
              PathConfinement.isWithin(pythonHome.path, root: runtime) else {
            throw IntatisError.config("fixed CPython home is unavailable")
        }
        environment["PYTHONHOME"] = pythonHome.path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }
    guard invocation.executable == .tectonic else { return environment }
    let cache = runtime
        .appendingPathComponent("share/tectonic/cache", isDirectory: true)
        .standardizedFileURL
    let values = try? cache.resourceValues(forKeys: [
        .isDirectoryKey,
        .isSymbolicLinkKey,
    ])
    guard values?.isDirectory == true,
          values?.isSymbolicLink != true,
          PathConfinement.isWithin(cache.path, root: runtime) else {
        throw IntatisError.config("fixed Tectonic offline cache is unavailable")
    }
    environment["TECTONIC_CACHE_DIR"] = cache.path
    return environment
}

private func trustedDocumentExecutable(
    _ executable: DocumentBackendExecutable
) throws -> URL {
    let runtime = intatisDocumentRuntimeRoot()
    let path: String?
    switch executable {
    case .pythonRuntime:
        path = runtime?.appendingPathComponent("bin/python3").path
    case .libreOffice:
        #if os(macOS)
        path = intatisLibreOfficeRuntimeAppURL()?
            .appendingPathComponent("Contents/MacOS/soffice", isDirectory: false)
            .path
        #else
        path = "/usr/bin/libreoffice"
        #endif
    case .tectonic:
        path = runtime?.appendingPathComponent("bin/tectonic").path
    }
    guard let path,
          FileManager.default.isExecutableFile(atPath: path) else {
        throw IntatisError.config(
            "document backend is unavailable at its fixed runtime path: \(executable.rawValue)")
    }
    return URL(fileURLWithPath: path)
}

private func workspaceLeasePath(_ path: String,
                                matches pattern: String,
                                caseInsensitive: Bool = false) -> Bool {
    let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
    let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
    if normalizedPattern.contains("/") == false {
        return normalizedPath.split(separator: "/").contains {
            workspaceLeaseGlob(
                String($0),
                matches: normalizedPattern,
                caseInsensitive: caseInsensitive)
        }
    }
    return workspaceLeaseGlob(
        normalizedPath,
        matches: normalizedPattern,
        caseInsensitive: caseInsensitive)
}

private func workspaceLeaseGlob(_ value: String,
                                matches pattern: String,
                                caseInsensitive: Bool) -> Bool {
    var expression = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
        let character = pattern[index]
        if character == "*" {
            let next = pattern.index(after: index)
            if next < pattern.endIndex, pattern[next] == "*" {
                let afterStars = pattern.index(after: next)
                if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
                    expression += "(?:.*/)?"
                    index = pattern.index(after: afterStars)
                } else {
                    expression += ".*"
                    index = afterStars
                }
                continue
            }
            expression += "[^/]*"
        } else if character == "?" {
            expression += "[^/]"
        } else {
            expression += NSRegularExpression.escapedPattern(for: String(character))
        }
        index = pattern.index(after: index)
    }
    expression += "$"
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(
        pattern: expression,
        options: options) else { return false }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range) != nil
}

private func runWorkspaceProcess(executable: URL,
                                 arguments: [String],
                                 cwd: URL,
                                 managedWorkingDirectory: URL? = nil,
                                 processCompatibility: WorkspaceProcessCompatibility = .none,
                                 networkAccess: WorkspaceNetworkAccess,
                                 trustedReadRoots: [URL],
                                 writableRoots: [URL],
                                 workspaceLease: WorkspaceLease?,
                                 allowEmptyWorkspaceAccess: Bool = false,
                                 forcedReadOnlyWorkspaceRoots: [URL] = [],
                                 environment: [String: String],
                                 timeoutSeconds: TimeInterval,
                                 terminationGraceSeconds: TimeInterval,
                                 maximumGeneratedFileBytes: Int?,
                                 maximumOutputBytes: Int,
                                 generatedOutputRoots: [URL] = [],
                                 maximumGeneratedTotalBytes: Int? = nil,
                                 maximumGeneratedEntries: Int = 100_000,
                                 maximumResidentBytes: UInt64? = nil) async throws -> ShellResult {
    let workspace = try validatedWorkspace(cwd)
    let requestedWorkingDirectory: URL?
    if let managedWorkingDirectory {
        let resolved = managedWorkingDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == "/" else {
            throw IntatisError.config(
                "managed process working-directory override must be the filesystem root")
        }
        requestedWorkingDirectory = resolved
    } else {
        requestedWorkingDirectory = nil
    }
    let lease = try effectiveWorkspaceLease(
        workspaceLease,
        workspace: workspace,
        allowEmptyPathRules: allowEmptyWorkspaceAccess)
    let runtime = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            hostToolIdentity.temporaryPrefix(
                "process-\(UUID().uuidString)"),
            isDirectory: true)
    let home = runtime.appendingPathComponent("home", isDirectory: true)
    let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: runtime) }
    #if os(macOS)
    let libreOfficeSocketRoot: URL?
    if processCompatibility == .libreOfficeHeadless {
        libreOfficeSocketRoot = try createLibreOfficeSocketRoot()
    } else {
        libreOfficeSocketRoot = nil
    }
    defer {
        if let libreOfficeSocketRoot {
            try? FileManager.default.removeItem(at: libreOfficeSocketRoot)
        }
    }
    #endif
    let processWorkingDirectory: URL
    if processCompatibility == .libreOfficeHeadless {
        // Keep incidental bootstrap and temporary writes in the private managed
        // runtime instead of the reviewed workspace or filesystem root.
        processWorkingDirectory = temporary
    } else {
        processWorkingDirectory = requestedWorkingDirectory ?? workspace
    }
    let startupMarkerURL = runtime.appendingPathComponent(
        "command-shim-started-\(UUID().uuidString)")
    guard FileManager.default.createFile(
        atPath: startupMarkerURL.path,
        contents: Data()) else {
        throw IntatisError.io("could not create managed process startup marker")
    }
    let startupMarkerHandle = try FileHandle(forReadingFrom: startupMarkerURL)
    defer { try? startupMarkerHandle.close() }
    let markerDescriptor = startupMarkerHandle.fileDescriptor
    let markerFlags = fcntl(markerDescriptor, F_GETFD)
    guard markerFlags >= 0,
          fcntl(markerDescriptor, F_SETFD, markerFlags | FD_CLOEXEC) == 0 else {
        throw IntatisError.io("could not protect managed process startup marker")
    }

    var sanitized = sanitizedProcessEnvironment(home: home, temporary: temporary)
    environment.forEach { sanitized[$0.key] = $0.value }
    if processCompatibility == .libreOfficeHeadless {
        // AppKit consults CoreFoundation's resolved home directory even when
        // HOME is isolated. Keep spelling, input-method, and preference probes
        // inside the same per-invocation runtime instead of the real user home.
        sanitized["CFFIXED_USER_HOME"] = home.path
    }
    let processSpec: ManagedProcessSpec
    let sandboxBackend: WorkspaceSandboxBackend
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
        throw IntatisError.config("process execution is disabled because the macOS workspace sandbox is unavailable")
    }
    let profile = try macOSSandboxProfile(
        workspace: workspace,
        runtime: runtime,
        trustedReadRoots: trustedReadRoots,
        writableRoots: writableRoots,
        workspaceLease: lease,
        forcedReadOnlyWorkspaceRoots: forcedReadOnlyWorkspaceRoots,
        processCompatibility: processCompatibility,
        libreOfficeSocketRoot: libreOfficeSocketRoot,
        networkAccess: networkAccess)
    let processArguments: [String]
    if let libreOfficeSocketRoot {
        // OSL_SOCKET_PATH is a LibreOffice bootstrap variable, not a process
        // environment variable. Its AF_UNIX path must also remain shorter than
        // sockaddr_un.sun_path after LibreOffice appends OSL_PIPE_*.
        processArguments = [
            "-env:OSL_SOCKET_PATH=\(libreOfficeSocketRoot.path)",
        ] + arguments
    } else {
        processArguments = arguments
    }
    processSpec = ManagedProcessSpec(
        executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
        arguments: ["-p", profile] + limitedExecutionArguments(
            executable: executable,
            arguments: processArguments,
            startupMarker: startupMarkerURL,
            maximumGeneratedFileBytes: maximumGeneratedFileBytes),
        environment: sanitized)
    sandboxBackend = .macOSSandboxExec
    #elseif os(Linux)
    guard let bubblewrap = bubblewrapExecutable() else {
        throw IntatisError.config("process execution is disabled because Bubblewrap is unavailable; install bwrap")
    }
    let wholeWorkspacePolicy = lease.allowedPathRules.count == 1
        && lease.allowedPathRules[0].pattern == "."
        && lease.deniedPatterns.isEmpty
    let exactPathPolicy = lease.allowedPathRules.allSatisfy {
        $0.pattern != "."
            && $0.pattern.contains("*") == false
            && $0.pattern.contains("?") == false
    }
    guard wholeWorkspacePolicy || exactPathPolicy else {
        throw IntatisError.config(
            "process execution is disabled on Linux because Bubblewrap cannot enforce this WorkspaceLease glob policy without a race")
    }
    processSpec = ManagedProcessSpec(
        executable: bubblewrap,
        arguments: try bubblewrapArguments(
            workspace: workspace,
            runtime: runtime,
            executable: executable,
            arguments: arguments,
            trustedReadRoots: trustedReadRoots,
            writableRoots: writableRoots,
            workspaceLease: lease,
            forcedReadOnlyWorkspaceRoots: forcedReadOnlyWorkspaceRoots,
            environment: sanitized,
            networkAccess: networkAccess,
            startupMarker: startupMarkerURL,
            maximumGeneratedFileBytes: maximumGeneratedFileBytes),
        environment: sanitized)
    sandboxBackend = .bubblewrap
    #endif
    let result = try await runManagedProcess(
        spec: processSpec,
        cwd: processWorkingDirectory,
        timeoutSeconds: timeoutSeconds,
        terminationGraceSeconds: terminationGraceSeconds,
        maximumOutputBytes: maximumOutputBytes,
        generatedOutputRoots: [runtime] + generatedOutputRoots,
        maximumGeneratedTotalBytes: maximumGeneratedTotalBytes,
        maximumGeneratedEntries: maximumGeneratedEntries,
        maximumResidentBytes: maximumResidentBytes)
    let managedCommandShimStarted: Bool
    do {
        try startupMarkerHandle.seek(toOffset: 0)
        managedCommandShimStarted = try startupMarkerHandle.read(upToCount: 2) == Data([0x31])
    } catch {
        // Marker inspection is evidence, not an execution prerequisite. If it
        // cannot be read, conservatively assume the target may have started.
        managedCommandShimStarted = true
    }
    if let denial = workspaceSandboxStartupDenial(
        in: result,
        backend: sandboxBackend,
        managedCommandShimStarted: managedCommandShimStarted
    ) {
        throw denial
    }
    return result
}

#if os(macOS)
private func runMacOSBrowserBackendProcess(
    invocation: BrowserBackendInvocation,
    cwd: URL,
    workspaceLease: WorkspaceLease?,
    timeoutSeconds: TimeInterval,
    terminationGraceSeconds: TimeInterval,
    maximumOutputBytes: Int
) async throws -> ShellResult {
    let workspace = try validatedWorkspace(cwd)
    _ = try validateBrowserWorkspaceAccess(
        readablePaths: invocation.readableWorkspacePaths,
        writablePaths: invocation.writableWorkspacePaths,
        cwd: workspace,
        workspaceLease: workspaceLease)
    let browserRuntime = try trustedBrowserRuntime()

    let runtime = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            hostToolIdentity.temporaryPrefix(
                "browser-process-\(UUID().uuidString)"),
            isDirectory: true)
    let home = runtime.appendingPathComponent("home", isDirectory: true)
    let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: runtime.path)
    defer { try? FileManager.default.removeItem(at: runtime) }

    let script = runtime.appendingPathComponent("browser-backend.js")
    guard FileManager.default.createFile(
        atPath: script.path,
        contents: Data(invocation.javaScript.utf8),
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
        throw IntatisError.io("could not create the managed browser program")
    }

    var environment = sanitizedProcessEnvironment(home: home, temporary: temporary)
    // Chromium resolves its macOS application-support directory through
    // CoreFoundation rather than HOME. Keep crash/reporting state inside the
    // same invocation-owned temporary boundary as the Playwright profile.
    environment["CFFIXED_USER_HOME"] = home.path
    environment[hostToolIdentity.environmentVariable("BROWSER_ARGS")] =
        invocation.encodedArguments
    environment[hostToolIdentity.environmentVariable(
        "BROWSER_PROCESS_BOUNDARY")] = "1"
    if let runtimeRoot = browserRuntime.runtimeRoot {
        environment[hostToolIdentity.environmentVariable(
            "BROWSER_RUNTIME_ROOT")] = runtimeRoot.path
        environment[hostToolIdentity.environmentVariable(
            "BROWSER_RUNTIME_CLOSED")] = "1"
    }
    return try await runManagedProcess(
        spec: ManagedProcessSpec(
            executable: browserRuntime.node,
            arguments: [script.path],
            environment: environment),
        cwd: workspace,
        timeoutSeconds: timeoutSeconds,
        terminationGraceSeconds: terminationGraceSeconds,
        maximumOutputBytes: maximumOutputBytes)
}

private struct TrustedBrowserRuntime {
    let node: URL
    let runtimeRoot: URL?
}

private func trustedBrowserRuntime() throws -> TrustedBrowserRuntime {
    if let bundled = intatisBundledBrowserRuntimeRoot() {
        return TrustedBrowserRuntime(
            node: bundled
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("node", isDirectory: false),
            runtimeRoot: bundled)
    }
    if intatisRequiresBundledBrowserRuntime() {
        throw IntatisError.config(
            "the fixed browser runtime is missing from this \(hostToolIdentity.name) app; reinstall the complete v0.66 app bundle")
    }
    for path in [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ] where FileManager.default.isExecutableFile(atPath: path) {
        return TrustedBrowserRuntime(
            node: URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            runtimeRoot: nil)
    }
    throw IntatisError.config(
        "node is not installed in a trusted system location; install Node.js to use \(hostToolIdentity.name) browser tools")
}
#endif

private struct ManagedOutputPipe {
    let writeDescriptor: Int32
    let drain: BoundedOutputDrain
}

private func makeManagedOutputPipe(maximumBytes: Int) throws -> ManagedOutputPipe {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard systemPipe(&descriptors) == 0 else {
        throw IntatisError.io("could not create bounded process output pipe")
    }
    let readDescriptor = descriptors[0]
    let writeDescriptor = descriptors[1]
    do {
        for descriptor in descriptors {
            let flags = systemFcntl(descriptor, F_GETFD, 0)
            guard flags >= 0,
                  systemFcntl(
                    descriptor,
                    F_SETFD,
                    flags | FD_CLOEXEC) == 0 else {
                throw IntatisError.io(
                    "could not isolate bounded process output pipe")
            }
        }
        return ManagedOutputPipe(
            writeDescriptor: writeDescriptor,
            drain: try BoundedOutputDrain(
                readDescriptor: readDescriptor,
                maximumBytes: maximumBytes))
    } catch {
        systemClose(readDescriptor)
        systemClose(writeDescriptor)
        throw error
    }
}

private func runManagedProcess(spec: ManagedProcessSpec,
                               cwd: URL,
                               timeoutSeconds: TimeInterval,
                               terminationGraceSeconds: TimeInterval,
                               maximumOutputBytes: Int,
                               generatedOutputRoots: [URL] = [],
                               maximumGeneratedTotalBytes: Int? = nil,
                               maximumGeneratedEntries: Int = 100_000,
                               maximumResidentBytes: UInt64? = nil) async throws -> ShellResult {
    let stdoutPipe = try makeManagedOutputPipe(maximumBytes: maximumOutputBytes)
    let stderrPipe: ManagedOutputPipe
    do {
        stderrPipe = try makeManagedOutputPipe(maximumBytes: maximumOutputBytes)
    } catch {
        systemClose(stdoutPipe.writeDescriptor)
        stdoutPipe.drain.waitForDrain()
        throw error
    }
    var stdoutWriteOpen = true
    var stderrWriteOpen = true
    defer {
        if stdoutWriteOpen { systemClose(stdoutPipe.writeDescriptor) }
        if stderrWriteOpen { systemClose(stderrPipe.writeDescriptor) }
    }
    let state = ManagedProcessState(terminationGraceSeconds: terminationGraceSeconds)

    let outcome: ManagedProcessOutcome
    do {
        outcome = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let pid = try spawnManagedProcess(
                spec: spec,
                cwd: cwd,
                stdoutDescriptor: stdoutPipe.writeDescriptor,
                stderrDescriptor: stderrPipe.writeDescriptor)
            systemClose(stdoutPipe.writeDescriptor)
            stdoutWriteOpen = false
            systemClose(stderrPipe.writeDescriptor)
            stderrWriteOpen = false
            state.register(pid: pid)
            state.scheduleTimeout(after: timeoutSeconds)
            if let maximumGeneratedTotalBytes {
                state.scheduleGeneratedOutputLimit(
                    roots: generatedOutputRoots,
                    maximumBytes: UInt64(maximumGeneratedTotalBytes),
                    maximumEntries: maximumGeneratedEntries)
            }
            if let maximumResidentBytes {
                state.scheduleResidentMemoryLimit(maximumBytes: maximumResidentBytes)
            }
            DispatchQueue.global(qos: .utility).async {
                state.processExited(waitAndReap(pid: pid))
            }
            return await state.wait()
        } onCancel: {
            state.requestStop(.cancelled)
        }
    } catch {
        if stdoutWriteOpen {
            systemClose(stdoutPipe.writeDescriptor)
            stdoutWriteOpen = false
        }
        if stderrWriteOpen {
            systemClose(stderrPipe.writeDescriptor)
            stderrWriteOpen = false
        }
        stdoutPipe.drain.waitForDrain()
        stderrPipe.drain.waitForDrain()
        throw error
    }

    stdoutPipe.drain.waitForDrain()
    stderrPipe.drain.waitForDrain()
    let stdout = stdoutPipe.drain.snapshot(
        from: 0,
        maximumBytes: maximumOutputBytes)
    let stderr = stderrPipe.drain.snapshot(
        from: 0,
        maximumBytes: maximumOutputBytes)
    let stdoutText = String(decoding: stdout.data, as: UTF8.self)
    let stderrText = String(decoding: stderr.data, as: UTF8.self)

    switch outcome {
    case .exited(let status):
        if let maximumGeneratedTotalBytes,
           documentGeneratedOutputExceedsBudget(
               roots: generatedOutputRoots,
               maximumBytes: UInt64(maximumGeneratedTotalBytes),
               maximumEntries: maximumGeneratedEntries) {
            throw IntatisError.io(
                "document backend exceeded its generated output budget")
        }
        return ShellResult(stdout: stdoutText,
                           stderr: stderrText,
                           exitCode: Int(status))
    case .cancelled:
        throw CancellationError()
    case .timedOut:
        throw IntatisError.io("shell command timed out after \(timeoutSeconds.formattedForError)s")
    case .resourceLimit(.generatedOutput):
        throw IntatisError.io("document backend exceeded its generated output budget")
    case .resourceLimit(.residentMemory):
        throw IntatisError.io("document backend exceeded its resident-memory budget")
    }
}

private func signalProcessGroupAndDescendants(root: Int32?, descendants: Set<Int32>, value: Int32) {
    #if canImport(Darwin)
    var targets = descendants
    if let root {
        targets.formUnion(darwinDescendants(of: root))
    }
    for descendant in targets.sorted(by: >) {
        _ = Darwin.kill(descendant, value)
    }
    if let root { _ = Darwin.kill(-root, value) }
    #elseif canImport(Glibc) || canImport(Musl)
    for descendant in descendants { _ = kill(descendant, value) }
    if let root { _ = kill(-root, value) }
    #endif
}

private func waitForProcessGroupToEmpty(leader: Int32, descendants: Set<Int32>) {
    let deadline = Date().addingTimeInterval(0.25)
    while Date() < deadline {
        #if canImport(Darwin)
        let groupExists = Darwin.kill(-leader, 0) == 0 || errno == EPERM
        let descendantExists = descendants.contains { Darwin.kill($0, 0) == 0 || errno == EPERM }
        #elseif canImport(Glibc) || canImport(Musl)
        let groupExists = kill(-leader, 0) == 0 || errno == EPERM
        let descendantExists = descendants.contains { kill($0, 0) == 0 || errno == EPERM }
        #else
        let groupExists = false
        let descendantExists = false
        #endif
        if groupExists == false, descendantExists == false { return }
        signalProcessGroupAndDescendants(root: leader, descendants: descendants, value: SIGKILL)
        usleep(10_000)
    }
}

/// Bounds aggregate logical/allocated output while a fixed document backend is
/// running. It never follows symlinks and treats unreadable or single-link
/// violations as over-budget so the process is stopped fail closed.
func documentGeneratedOutputExceedsBudget(
    roots: [URL],
    maximumBytes: UInt64,
    maximumEntries: Int
) -> Bool {
    var totalBytes: UInt64 = 0
    var entryCount = 0
    var seenRoots = Set<String>()

    func account(_ url: URL, enumerator: FileManager.DirectoryEnumerator?) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return errno != ENOENT }
        let kind = status.st_mode & S_IFMT
        if kind == S_IFLNK {
            enumerator?.skipDescendants()
            return true
        }
        entryCount += 1
        guard entryCount <= maximumEntries else { return true }
        if kind == S_IFDIR { return false }
        guard kind == S_IFREG, status.st_nlink == 1, status.st_size >= 0 else {
            return true
        }
        let logical = UInt64(status.st_size)
        let allocated = status.st_blocks > 0
            ? UInt64(status.st_blocks) * 512
            : 0
        let contribution = max(logical, allocated)
        guard contribution <= maximumBytes,
              totalBytes <= maximumBytes - contribution else {
            return true
        }
        totalBytes += contribution
        return false
    }

    for rawRoot in roots {
        let root = rawRoot.standardizedFileURL
        guard seenRoots.insert(root.path).inserted else { continue }
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0 else {
            if errno == ENOENT { continue }
            return true
        }
        let rootKind = rootStatus.st_mode & S_IFMT
        if rootKind == S_IFLNK { return true }
        if rootKind != S_IFDIR {
            if account(root, enumerator: nil) { return true }
            continue
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []) else {
            return true
        }
        while let value = enumerator.nextObject() as? URL {
            if account(value, enumerator: enumerator) { return true }
        }
    }
    return false
}

/// Bounds the aggregate resident set of the managed process group. Shared
/// pages can be counted in more than one process, which is intentionally
/// conservative for an untrusted document. Processes that disappear between
/// enumeration and inspection are ignored because process-tree cleanup still
/// waits for and reaps the leader.
private func managedProcessResidentMemoryExceedsBudget(
    root: Int32,
    maximumBytes: UInt64
) -> Bool {
    guard maximumBytes > 0 else { return true }

    func exceeds(_ total: inout UInt64, adding value: UInt64) -> Bool {
        if value > maximumBytes || total > maximumBytes - value {
            return true
        }
        total += value
        return total > maximumBytes
    }

    #if canImport(Darwin)
    var total: UInt64 = 0
    let processIDs = Set([root] + darwinDescendants(of: root))
    for processID in processIDs {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.size
        let actualSize = proc_pidinfo(
            processID,
            PROC_PIDTASKINFO,
            0,
            &info,
            Int32(expectedSize))
        guard Int(actualSize) == expectedSize else { continue }
        if exceeds(&total, adding: UInt64(info.pti_resident_size)) {
            return true
        }
    }
    return false
    #elseif canImport(Glibc) || canImport(Musl)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
        return true
    }
    let rawPageSize = sysconf(Int32(_SC_PAGESIZE))
    guard rawPageSize > 0 else { return true }
    let pageSize = UInt64(rawPageSize)
    var total: UInt64 = 0
    for name in names where !name.isEmpty && name.allSatisfy(\.isNumber) {
        guard let statText = try? String(
            contentsOfFile: "/proc/\(name)/stat",
            encoding: .utf8),
              let closingParenthesis = statText.lastIndex(of: ")") else { continue }
        let suffixStart = statText.index(after: closingParenthesis)
        let fields = statText[suffixStart...].split(whereSeparator: \.isWhitespace)
        // fields starts at proc(5) field 3 (state); pgrp is field 5 and
        // resident pages is field 24.
        guard fields.count > 21,
              let processGroup = Int32(fields[2]),
              processGroup == root,
              let residentPages = Int64(fields[21]),
              residentPages > 0 else { continue }
        let pages = UInt64(residentPages)
        if pages > UInt64.max / pageSize
            || exceeds(&total, adding: pages * pageSize) {
            return true
        }
    }
    return false
    #else
    _ = root
    return true
    #endif
}

#if canImport(Darwin)
private func darwinDescendants(of root: pid_t) -> [pid_t] {
    var pending = [root]
    var visited: Set<pid_t> = [root]
    var descendants: [pid_t] = []
    while let parent = pending.popLast(), visited.count < 4_096 {
        var children = [pid_t](repeating: 0, count: 512)
        let count = proc_listchildpids(
            parent,
            &children,
            Int32(children.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { continue }
        for child in children.prefix(min(Int(count), children.count)) where child > 0 {
            if visited.insert(child).inserted {
                descendants.append(child)
                pending.append(child)
            }
        }
    }
    return descendants
}
#endif

private extension TimeInterval {
    var formattedForError: String {
        if rounded() == self { return String(Int(self)) }
        return String(format: "%.2f", self)
    }
}

func sanitizedProcessEnvironment(home: URL, temporary: URL) -> [String: String] {
    [
        "HOME": home.path,
        "TMPDIR": temporary.path + "/",
        "TEMP": temporary.path,
        "TMP": temporary.path,
        "XDG_CONFIG_HOME": home.appendingPathComponent(".config", isDirectory: true).path,
        "XDG_CACHE_HOME": home.appendingPathComponent(".cache", isDirectory: true).path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Library/TeX/texbin",
        "LANG": "C",
        "LC_ALL": "C",
        "USER": hostToolIdentity.fileNameStem,
        "LOGNAME": hostToolIdentity.fileNameStem,
        "NO_COLOR": "1",
        hostToolIdentity.environmentVariable("PROCESS_SANDBOX"): "1",
    ]
}

func limitedExecutionArguments(executable: URL,
                               arguments: [String],
                               startupMarker: URL,
                               maximumGeneratedFileBytes: Int?) -> [String] {
    let limitCommand: String
    if let maximumGeneratedFileBytes {
        let blocks = max(2, maximumGeneratedFileBytes / 512)
        limitCommand = "ulimit -f \(blocks) 2>/dev/null; "
    } else {
        limitCommand = ""
    }
    return [
        "/bin/sh", "-c",
        "marker=$1; shift; printf 1 > \"$marker\" || exit 125; rm -f -- \"$marker\" || exit 125; \(limitCommand)exec \"$@\"",
        hostToolIdentity.temporaryPrefix("managed"),
        startupMarker.path, executable.path,
    ] + arguments
}

func managedTerminalExecutionArguments(executable: URL,
                                       arguments: [String],
                                       startupMarker: URL) -> [String] {
    [
        "/bin/sh", "-c",
        "marker=$1; shift; printf 1 > \"$marker\" || exit 125; rm -f -- \"$marker\" || exit 125; exec \"$@\"",
        hostToolIdentity.temporaryPrefix("managed-terminal"),
        startupMarker.path, executable.path,
    ] + arguments
}

func structuredRuntimeReadRoots() -> [URL] {
    var roots = [
        "/opt/homebrew",
        "/usr/local",
        "/Library/TeX",
        "/Library/Java",
        "/Library/Frameworks/Python.framework",
        "/Applications/Google Chrome.app",
        "/Applications/Microsoft Edge.app",
        "/Applications/Chromium.app",
        "/Applications/Xcode.app",
        "/Library/Developer/CommandLineTools",
    ].filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    if let documentRuntime = intatisDocumentRuntimeRoot(),
       FileManager.default.fileExists(atPath: documentRuntime.path) {
        roots.append(documentRuntime)
    }
    if let browserRuntime = intatisBrowserRuntimeRoot(),
       FileManager.default.fileExists(atPath: browserRuntime.path) {
        roots.append(browserRuntime)
    }
    return roots
}

func intatisRequiresBundledBrowserRuntime(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
) -> Bool {
    bundleIdentifier.map(
        hostToolIdentity.macOSBundleIdentifierCandidates.contains)
        ?? false
}

/// Shipping IntatisMac resolves Node, Playwright, and Chromium exclusively
/// from the current architecture's sealed runtime root. CLI/debug hosts may
/// retain their existing explicitly installed development runtime, but that
/// path can never satisfy the App distribution contract.
func intatisBrowserRuntimeRoot() -> URL? {
    let bundled = intatisBundledBrowserRuntimeRoot()
    return selectBrowserRuntimeRoot(
        bundledRoot: bundled,
        requiresBundledRuntime: intatisRequiresBundledBrowserRuntime())
}

func selectBrowserRuntimeRoot(
    bundledRoot: URL?,
    requiresBundledRuntime: Bool
) -> URL? {
    if requiresBundledRuntime {
        return bundledRoot
    }
    return bundledRoot
}

func intatisBundledBrowserRuntimeRoot() -> URL? {
    #if os(macOS)
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    return nil
    #endif
    guard let resources = Bundle.main.resourceURL else { return nil }
    let root = resources
        .appendingPathComponent("BrowserRuntime", isDirectory: true)
        .appendingPathComponent(architecture, isDirectory: true)
    let requiredFiles = [
        "runtime-manifest.json",
        "bin/node",
        "node_modules/playwright/package.json",
        "node_modules/playwright-core/package.json",
        "chromium/Chromium.app/Contents/MacOS/Chromium",
    ]
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          requiredFiles.allSatisfy({ relativePath in
              FileManager.default.fileExists(
                  atPath: root.appendingPathComponent(relativePath).path)
          }),
          FileManager.default.isExecutableFile(
              atPath: root.appendingPathComponent("bin/node").path),
          FileManager.default.isExecutableFile(
              atPath: root
                  .appendingPathComponent("chromium/Chromium.app/Contents/MacOS/Chromium")
                  .path) else {
        return nil
    }
    return root.resolvingSymlinksInPath().standardizedFileURL
    #else
    return nil
    #endif
}

/// Production apps resolve the architecture-specific, signed runtime embedded
/// by the release pipeline. CLI/debug builds retain the historical
/// user-managed location as a development fallback; Intatis never installs
/// into or mutates that directory while running a tool.
func intatisDocumentRuntimeRoot() -> URL? {
    let bundled = intatisBundledDocumentRuntimeRoot()
    #if os(macOS)
    let userManaged = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask).first.map {
            $0.appendingPathComponent(
                hostToolIdentity.storageName,
                isDirectory: true)
                .appendingPathComponent("document-runtime", isDirectory: true)
        }
    return selectDocumentRuntimeRoot(
        bundledRoot: bundled,
        userManagedRoot: userManaged,
        requiresBundledRuntime: Bundle.main.bundleIdentifier.map(
            hostToolIdentity.macOSBundleIdentifierCandidates.contains)
            ?? false)
    #elseif os(Linux)
    let userManaged = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share", isDirectory: true)
        .appendingPathComponent(
            hostToolIdentity.fileNameStem,
            isDirectory: true)
        .appendingPathComponent("document-runtime", isDirectory: true)
    return selectDocumentRuntimeRoot(
        bundledRoot: bundled,
        userManagedRoot: userManaged,
        requiresBundledRuntime: false)
    #else
    return nil
    #endif
}

func selectDocumentRuntimeRoot(
    bundledRoot: URL?,
    userManagedRoot: URL?,
    requiresBundledRuntime: Bool
) -> URL? {
    if requiresBundledRuntime {
        return bundledRoot
    }
    return bundledRoot ?? userManagedRoot
}

func intatisBundledDocumentRuntimeRoot() -> URL? {
    #if os(macOS)
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    return nil
    #endif
    guard let resources = Bundle.main.resourceURL else { return nil }
    let root = resources
        .appendingPathComponent("DocumentRuntime", isDirectory: true)
        .appendingPathComponent(architecture, isDirectory: true)
    let manifest = root.appendingPathComponent("runtime-manifest.json", isDirectory: false)
    let python = root.appendingPathComponent("bin/python3", isDirectory: false)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          FileManager.default.fileExists(atPath: manifest.path),
          FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
    return root.resolvingSymlinksInPath().standardizedFileURL
    #else
    return nil
    #endif
}

#if os(macOS)
func intatisLibreOfficeRuntimeAppURL() -> URL? {
    intatisDocumentRuntimeRoot()?
        .appendingPathComponent("libreoffice", isDirectory: true)
        .appendingPathComponent("26.8.0.0.beta1", isDirectory: true)
        .appendingPathComponent("LibreOffice.app", isDirectory: true)
}
#endif

#if os(macOS)
func macOSSandboxProfile(workspace: URL,
                         runtime: URL,
                         trustedReadRoots: [URL],
                         writableRoots: [URL],
                         workspaceLease: WorkspaceLease,
                         forcedReadOnlyWorkspaceRoots: [URL] = [],
                         processCompatibility: WorkspaceProcessCompatibility = .none,
                         libreOfficeSocketRoot: URL? = nil,
                         networkAccess: WorkspaceNetworkAccess) throws -> String {
    let validatedLibreOfficeSocketRoot: URL?
    switch (processCompatibility, libreOfficeSocketRoot) {
    case (.none, nil):
        validatedLibreOfficeSocketRoot = nil
    case (.libreOfficeHeadless, .some(let socketRoot)):
        let resolved = socketRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonical = URL(
            fileURLWithPath: canonicalMacOSPath(resolved.path),
            isDirectory: true)
        let name = canonical.lastPathComponent
        let prefix = hostLibreOfficeSocketPrefix
        let suffix = String(name.dropFirst(prefix.count))
        let hasExpectedParent = canonical.deletingLastPathComponent().path == "/private/tmp"
        let hasExpectedPrefix = name.hasPrefix(prefix)
        let hasExpectedSuffixLength = suffix.count == 12
        let hasLowercaseHexSuffix = suffix.allSatisfy {
            $0.isHexDigit && ($0.isLetter == false || $0.isLowercase)
        }
        guard hasExpectedParent,
              hasExpectedPrefix,
              hasExpectedSuffixLength,
              hasLowercaseHexSuffix else {
            throw IntatisError.config(
                "LibreOffice socket root must be an invocation-private short path "
                    + "(parent=\(canonical.deletingLastPathComponent().path), name=\(name))")
        }
        validatedLibreOfficeSocketRoot = canonical
    default:
        throw IntatisError.config(
            "LibreOffice socket root does not match the process compatibility mode")
    }
    let baseReadRoots = [
        "/System", "/usr", "/bin", "/sbin",
        "/Library/Apple", "/Library/Frameworks", "/Library/Fonts",
        "/private/var/db/timezone", "/private/var/select",
        "/private/etc/ssl", "/private/etc/pki",
    ].filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    let compatibilityReadRoots: [URL]
    switch processCompatibility {
    case .none:
        compatibilityReadRoots = []
    case .libreOfficeHeadless:
        let userEncoding = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".CFUserTextEncoding")
        let userCacheRoot = runtime
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("C", isDirectory: true)
        compatibilityReadRoots = [
            userEncoding,
            userCacheRoot.appendingPathComponent("com.apple.IntlDataCache.le"),
            userCacheRoot.appendingPathComponent("com.apple.IntlDataCache.le.kbdx"),
            URL(fileURLWithPath: "/private/var/db/.AppleSetupDone"),
            URL(fileURLWithPath: "/private/var/db/eligibilityd/eligibility.plist"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    let readRoots = canonicalUniqueURLs(
        [workspace, runtime] + baseReadRoots + trustedReadRoots + writableRoots
            + compatibilityReadRoots
            + (validatedLibreOfficeSocketRoot.map { [$0] } ?? []))
    let writeRoots = canonicalUniqueURLs(
        [workspace, runtime] + writableRoots
            + (validatedLibreOfficeSocketRoot.map { [$0] } ?? []))
    let compatibilityDirectoryTraversalRoots: [URL]
    switch processCompatibility {
    case .none:
        compatibilityDirectoryTraversalRoots = []
    case .libreOfficeHeadless:
        // LibreOffice asks CoreServices to enumerate each directory component
        // while resolving its isolated profile, temporary directory, and the
        // reviewed workspace root. Keep that exceptional directory-data read
        // to ancestors of those two host-owned roots only.
        compatibilityDirectoryTraversalRoots = canonicalUniqueURLs([workspace, runtime])
    }
    let protectedZones = canonicalUniquePaths([
        NSHomeDirectory(), "/Users", "/Volumes", "/Network",
        "/private/tmp", "/private/var/folders", "/private/var/root", "/private/etc",
        "/Library/Keychains", "/System/Volumes/Data/Users",
        "/System/Volumes/Data/private", "/System/Volumes/Data/Volumes",
    ])
    let exceptions = readRoots.map {
        "(require-not (subpath \"\(sandboxLiteral($0.path))\"))"
    } + compatibilityDirectoryTraversalRoots.map {
        "(require-not (path-ancestors \"\(sandboxLiteral($0.path))\"))"
    }
    let protectedExceptions = exceptions.joined(separator: "\n                ")
    let protectedRules = protectedZones.map { zone in
        """
        (deny file-read-data file-map-executable
          (require-all
            (subpath "\(sandboxLiteral(zone))")
            \(protectedExceptions)))
        """
    }.joined(separator: "\n")
    let readRules = readRoots.map { "(subpath \"\(sandboxLiteral($0.path))\")" }.joined(separator: "\n          ")
    let ancestorRules = readRoots.map { "(path-ancestors \"\(sandboxLiteral($0.path))\")" }.joined(separator: "\n          ")
    let writeRules = writeRoots.map { "(subpath \"\(sandboxLiteral($0.path))\")" }.joined(separator: "\n          ")
    let workspaceRoot = canonicalMacOSPath(workspace.path)
    let allowsWholeWorkspace = workspaceLease.allowedPathRules.contains {
        $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines) == "."
    }
    let allowedRegexes = try workspaceLease.allowedPathRules.compactMap {
        try seatbeltPathRegex(pattern: $0.pattern, workspaceRoot: workspaceRoot)
    }
    let compatibilityWorkspaceRootExceptions = processCompatibility == .libreOfficeHeadless
        ? [
            "(require-not (literal \"\(sandboxLiteral(workspaceRoot))\"))",
            "(require-not (path-ancestors \"\(sandboxLiteral(workspaceRoot))\"))",
        ]
        : []
    let outsideAllowRule: String
    if allowsWholeWorkspace {
        outsideAllowRule = ""
    } else if allowedRegexes.isEmpty {
        if compatibilityWorkspaceRootExceptions.isEmpty == false {
            let compatibilityExceptions = compatibilityWorkspaceRootExceptions.joined(
                separator: "\n                ")
            outsideAllowRule = """
            (deny file-read-data file-map-executable file-write*
              (require-all
                (subpath "\(sandboxLiteral(workspaceRoot))")
                \(compatibilityExceptions)))
            """
        } else {
            outsideAllowRule = """
            (deny file-read-data file-map-executable file-write*
              (subpath "\(sandboxLiteral(workspaceRoot))"))
            """
        }
    } else {
        var outsideAllowExceptions = allowedRegexes.map {
            "(require-not (regex \"\(sandboxLiteral($0))\"))"
        }
        outsideAllowExceptions.append(contentsOf: compatibilityWorkspaceRootExceptions)
        let requireNotAllowed = outsideAllowExceptions.joined(separator: "\n            ")
        outsideAllowRule = """
        (deny file-read-data file-map-executable file-write*
          (require-all
            (subpath "\(sandboxLiteral(workspaceRoot))")
            \(requireNotAllowed)))
        """
    }
    let deniedRules = try workspaceLease.deniedPatterns.compactMap {
        try seatbeltPathRegex(
            pattern: $0,
            workspaceRoot: workspaceRoot,
            caseInsensitivePattern: true)
    }.map {
        "(deny file-read-data file-map-executable file-write* (regex \"\(sandboxLiteral($0))\"))"
    }.joined(separator: "\n")
    let readOnlyRules: String
    if workspaceLease.access == .readOnly {
        readOnlyRules = canonicalUniqueURLs([workspace] + writableRoots).map {
            "(deny file-write* (subpath \"\(sandboxLiteral($0.path))\"))"
        }.joined(separator: "\n")
    } else {
        readOnlyRules = ""
    }
    let forcedReadOnlyRules = canonicalUniqueURLs(forcedReadOnlyWorkspaceRoots).map {
        "(deny file-write* (subpath \"\(sandboxLiteral($0.path))\"))"
    }.joined(separator: "\n")
    let compatibilityRules: String
    switch processCompatibility {
    case .none:
        compatibilityRules = ""
    case .libreOfficeHeadless:
        // The macOS LibreOffice binary initializes a minimal AppKit shell even
        // with `--headless`, and CoreServices enumerates directory components
        // while resolving the host-owned workspace/runtime roots. The broader
        // file, network, process, staging, and argv restrictions remain those
        // of the document sandbox.
        let traversalRules = compatibilityDirectoryTraversalRoots.map {
            "(path-ancestors \"\(sandboxLiteral($0.path))\")"
        }.joined(separator: "\n          ")
        let intlDataCache = runtime
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("C/com.apple.IntlDataCache.le")
        let intlDataCachePath = canonicalMacOSPath(intlDataCache.path)
        guard let libreOfficeApp = intatisLibreOfficeRuntimeAppURL() else {
            throw IntatisError.config(
                "LibreOffice document runtime location is unavailable")
        }
        compatibilityRules = """
        (allow user-preference-read)
        (allow file-read-data
          (literal "\(sandboxLiteral(workspaceRoot))")
          \(traversalRules))
        (allow file-write-data
          (literal "\(sandboxLiteral(intlDataCachePath))"))
        (allow file-issue-extension
          (literal "\(sandboxLiteral(libreOfficeApp.path))"))
        (allow iokit-open-user-client
          (iokit-user-client-class "IOSurfaceRootUserClient"))
        (allow mach-lookup
          (global-name "com.apple.DiskArbitration.diskarbitrationd")
          (global-name "com.apple.MenuBarAgent.systemservices")
          (global-name "com.apple.CARenderServer")
          (global-name "com.apple.CoreServices.coreservicesd")
          (global-name "com.apple.SystemConfiguration.configd")
          (global-name "com.apple.appkit.restoration_storage")
          (global-name "com.apple.coreservices.appleevents")
          (global-name "com.apple.coreservices.launchservicesd")
          (global-name "com.apple.distributed_notifications@Uv3")
          (global-name "com.apple.dock.server")
          (global-name "com.apple.lsd.mapdb")
          (global-name "com.apple.pasteboard.1")
          (global-name "com.apple.pbs.fetch_services")
          (global-name "com.apple.tccd")
          (global-name "com.apple.tccd.system")
          (global-name "com.apple.touchbarserver.mig")
          (global-name "com.apple.window_proxies")
          (global-name "com.apple.windowmanager.server")
          (global-name "com.apple.windowserver.active"))
        """
    }
    let networkRule: String
    switch (networkAccess, processCompatibility) {
    case (.allowed, _):
        networkRule = "(allow network*)"
    case (.denied, .none):
        networkRule = "(deny network*)"
    case (.denied, .libreOfficeHeadless):
        guard let validatedLibreOfficeSocketRoot else {
            throw IntatisError.config("LibreOffice socket root is unavailable")
        }
        let localSocketRoot = canonicalMacOSPath(validatedLibreOfficeSocketRoot.path)
        let socketPathRegex = "^\(NSRegularExpression.escapedPattern(for: localSocketRoot))/OSL_PIPE_[^/]+$"
        // LibreOffice's SingleOffice "pipe" is an AF_UNIX stream socket.
        // Permit only its invocation-private socket path; IP networking stays
        // explicitly denied and the default-deny profile covers every other
        // Unix socket not admitted here.
        networkRule = """
        (allow network-bind network-inbound
          (local unix-socket (path-regex "\(sandboxLiteral(socketPathRegex))")))
        (allow network-outbound
          (remote unix-socket (path-regex "\(sandboxLiteral(socketPathRegex))")))
        (deny network* (local ip) (remote ip))
        """
    }
    return """
    (version 1)
    (deny default)
    (import "system.sb")
    (allow process-exec)
    (allow process-fork)
    (allow signal (target same-sandbox))
    (allow process-info* (target same-sandbox))
    \(compatibilityRules)
    (allow file-read* file-write* file-ioctl (literal "/dev/tty"))
    (allow file-ioctl (regex "^/dev/ttys[0-9a-f]+$"))
    (allow file-read* \(readRules))
    (allow file-read-metadata file-test-existence \(ancestorRules))
    (allow file-write* \(writeRules))
    \(protectedRules)
    \(outsideAllowRule)
    \(deniedRules)
    \(readOnlyRules)
    \(forcedReadOnlyRules)
    \(networkRule)
    """
}

private func seatbeltPathRegex(pattern rawPattern: String,
                               workspaceRoot: String,
                               caseInsensitivePattern: Bool = false) throws -> String? {
    var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\", with: "/")
    while pattern.hasPrefix("./") { pattern.removeFirst(2) }
    if pattern == "." {
        return "^\(NSRegularExpression.escapedPattern(for: workspaceRoot))(/.*)?$"
    }
    guard pattern.isEmpty == false,
          pattern.hasPrefix("/") == false,
          pattern.split(separator: "/").contains("..") == false else {
        throw IntatisError.permissionDenied("workspace lease contains an unsafe process path rule")
    }
    let root = NSRegularExpression.escapedPattern(for: workspaceRoot)
    let componentPattern = pattern.contains("/") == false
    let relative = globRegularExpression(
        pattern,
        caseInsensitiveLiterals: caseInsensitivePattern)
    if componentPattern {
        return "^\(root)(/[^/]*)*/\(relative)(/.*)?$"
    }
    return "^\(root)/\(relative)(/.*)?$"
}

private func globRegularExpression(
    _ pattern: String,
    caseInsensitiveLiterals: Bool = false
) -> String {
    var result = ""
    var index = pattern.startIndex
    while index < pattern.endIndex {
        let character = pattern[index]
        if character == "*" {
            let next = pattern.index(after: index)
            if next < pattern.endIndex, pattern[next] == "*" {
                let afterDoubleStar = pattern.index(after: next)
                if afterDoubleStar < pattern.endIndex, pattern[afterDoubleStar] == "/" {
                    // `**/name` includes both root-level `name` and any nested
                    // path, matching the WorkspaceLease glob contract.
                    result += "(.*/)?"
                    index = pattern.index(after: afterDoubleStar)
                } else {
                    result += ".*"
                    index = afterDoubleStar
                }
            } else {
                result += "[^/]*"
                index = next
            }
        } else if character == "?" {
            result += "[^/]"
            index = pattern.index(after: index)
        } else {
            let literal = String(character)
            if caseInsensitiveLiterals,
               let scalar = literal.unicodeScalars.first,
               literal.unicodeScalars.count == 1,
               ((scalar.value >= 65 && scalar.value <= 90)
                   || (scalar.value >= 97 && scalar.value <= 122)) {
                result += "[\(literal.lowercased())\(literal.uppercased())]"
            } else {
                result += NSRegularExpression.escapedPattern(for: literal)
            }
            index = pattern.index(after: index)
        }
    }
    return result
}

private func canonicalUniquePaths(_ paths: [String]) -> [String] {
    Array(Set(paths.map { canonicalMacOSPath(URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path) })).sorted()
}

private func sandboxLiteral(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}

private func canonicalMacOSPath(_ path: String) -> String {
    for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
        return "/private" + path
    }
    return path
}

private func createLibreOfficeSocketRoot() throws -> URL {
    let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    let suffix = UUID().uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
        .prefix(12)
    let root = parent.appendingPathComponent(
        hostLibreOfficeSocketPrefix + suffix,
        isDirectory: true)
    do {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    } catch {
        throw IntatisError.io("could not create LibreOffice socket root")
    }
    var status = stat()
    guard lstat(root.path, &status) == 0,
          status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          status.st_uid == geteuid(),
          status.st_mode & mode_t(0o7777) == mode_t(0o700) else {
        try? FileManager.default.removeItem(at: root)
        throw IntatisError.permissionDenied(
            "LibreOffice socket root did not preserve its private identity")
    }
    return root
}
#endif

private func canonicalUniqueURLs(_ urls: [URL]) -> [URL] {
    var seen: Set<String> = []
    return urls.compactMap { url in
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        #if os(macOS)
        path = canonicalMacOSPath(path)
        #endif
        guard seen.insert(path).inserted else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }.sorted { $0.path < $1.path }
}

#if os(Linux)
func bubblewrapExecutable() -> URL? {
    ["/usr/bin/bwrap", "/bin/bwrap"]
        .first(where: FileManager.default.isExecutableFile(atPath:))
        .map { URL(fileURLWithPath: $0) }
}

func bubblewrapArguments(workspace: URL,
                         runtime: URL,
                         executable: URL,
                         arguments: [String],
                         trustedReadRoots: [URL],
                         writableRoots: [URL],
                         workspaceLease: WorkspaceLease,
                         forcedReadOnlyWorkspaceRoots: [URL] = [],
                         environment: [String: String],
                         networkAccess: WorkspaceNetworkAccess,
                         startupMarker: URL,
                         maximumGeneratedFileBytes: Int?) throws -> [String] {
    let baseRoots = ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc/ssl", "/etc/pki",
                     "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf"]
        .filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    var readRoots = canonicalUniqueURLs(baseRoots + trustedReadRoots)
    var writeRoots = canonicalUniqueURLs([runtime])
    var exactReadRoots: [URL] = []
    var exactWriteRoots: [URL] = []
    let allowsWholeWorkspace = workspaceLease.allowedPathRules.count == 1
        && workspaceLease.allowedPathRules[0].pattern == "."
        && workspaceLease.deniedPatterns.isEmpty
    if allowsWholeWorkspace {
        if workspaceLease.access == .readOnly {
            readRoots = canonicalUniqueURLs(readRoots + [workspace] + writableRoots)
        } else {
            writeRoots = canonicalUniqueURLs(writeRoots + [workspace] + writableRoots)
        }
    } else {
        let exactRoots = try workspaceLease.allowedPathRules.map { rule in
            try PathConfinement.resolve(rule.pattern, within: workspace)
        }
        if workspaceLease.access == .readOnly {
            exactReadRoots = canonicalUniqueURLs(exactRoots)
            readRoots = canonicalUniqueURLs(readRoots + writableRoots)
        } else {
            exactWriteRoots = canonicalUniqueURLs(exactRoots)
            writeRoots = canonicalUniqueURLs(writeRoots + writableRoots)
        }
    }
    let forcedReadOnlyRoots = canonicalUniqueURLs(forcedReadOnlyWorkspaceRoots)
    var result = ["--die-with-parent", "--new-session", "--unshare-all"]
    result.append(networkAccess == .allowed ? "--share-net" : "--unshare-net")
    result.append(contentsOf: ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--clearenv"])
    var madeDirectories: Set<String> = ["/"]
    func addParents(of path: String) {
        var current = URL(fileURLWithPath: path).deletingLastPathComponent()
        var pending: [String] = []
        while current.path != "/", madeDirectories.contains(current.path) == false {
            pending.append(current.path)
            current.deleteLastPathComponent()
        }
        for parent in pending.reversed() where madeDirectories.insert(parent).inserted {
            result.append(contentsOf: ["--dir", parent])
        }
    }
    if allowsWholeWorkspace == false {
        addParents(of: workspace.path + "/"
            + hostToolIdentity.hiddenWorkspaceDirectoryName
            + "-placeholder")
        if madeDirectories.insert(workspace.path).inserted {
            result.append(contentsOf: ["--dir", workspace.path])
        }
    }
    for root in readRoots {
        addParents(of: root.path)
        result.append(contentsOf: ["--ro-bind", root.path, root.path])
    }
    for root in writeRoots {
        addParents(of: root.path)
        result.append(contentsOf: ["--bind", root.path, root.path])
    }
    for root in exactWriteRoots {
        addParents(of: root.path)
        result.append(contentsOf: ["--bind", root.path, root.path])
    }
    for root in exactReadRoots {
        addParents(of: root.path)
        result.append(contentsOf: ["--ro-bind", root.path, root.path])
    }
    // Overlay reviewed inputs and validator inputs read-only after any parent
    // staging directory bind. Mount order makes the narrower read-only bind
    // authoritative inside an otherwise writable stage.
    for root in forcedReadOnlyRoots {
        addParents(of: root.path)
        result.append(contentsOf: ["--ro-bind", root.path, root.path])
    }
    for key in environment.keys.sorted() {
        result.append(contentsOf: ["--setenv", key, environment[key] ?? ""])
    }
    result.append(contentsOf: ["--chdir", workspace.path, "--"])
    result.append(contentsOf: limitedExecutionArguments(
        executable: executable,
        arguments: arguments,
        startupMarker: startupMarker,
        maximumGeneratedFileBytes: maximumGeneratedFileBytes))
    return result
}
#elseif !os(macOS)
func bubblewrapExecutable() -> URL? { nil }
#endif

func spawnManagedProcess(spec: ManagedProcessSpec,
                         cwd: URL,
                         stdinDescriptor: Int32? = nil,
                         stdoutDescriptor: Int32,
                         stderrDescriptor: Int32) throws -> Int32 {
    #if canImport(Darwin)
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    #else
    var actions = posix_spawn_file_actions_t()
    var attributes = posix_spawnattr_t()
    #endif
    guard posix_spawn_file_actions_init(&actions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        throw IntatisError.io("could not initialize managed process attributes")
    }
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
    let ownedNullDescriptor: Int32?
    let resolvedStdinDescriptor: Int32
    if let stdinDescriptor {
        ownedNullDescriptor = nil
        resolvedStdinDescriptor = stdinDescriptor
    } else {
        let descriptor = open("/dev/null", O_RDONLY)
        guard descriptor >= 0 else { throw IntatisError.io("could not open null stdin") }
        ownedNullDescriptor = descriptor
        resolvedStdinDescriptor = descriptor
    }
    defer {
        if let ownedNullDescriptor { close(ownedNullDescriptor) }
    }
    guard posix_spawn_file_actions_adddup2(
        &actions,
        resolvedStdinDescriptor,
        STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(
            &actions,
            stdoutDescriptor,
            STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(
            &actions,
            stderrDescriptor,
            STDERR_FILENO) == 0 else {
        throw IntatisError.io("could not configure managed process file descriptors")
    }
    #if os(macOS)
    guard posix_spawn_file_actions_addchdir(&actions, cwd.path) == 0 else {
        throw IntatisError.io("could not confine managed process working directory")
    }
    #endif
    var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    #if os(macOS)
    flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    for value in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE, SIGCHLD] {
        sigaddset(&defaultSignals, value)
    }
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else {
        throw IntatisError.io("could not configure managed process isolation")
    }

    var pid: pid_t = 0
    let argv = [spec.executable.path] + spec.arguments
    let envp = spec.environment.keys.sorted().map { "\($0)=\(spec.environment[$0] ?? "")" }
    let result: Int32 = withMutableCStrings(argv) { argvPointer in
        withMutableCStrings(envp) { envPointer in
            posix_spawn(&pid, spec.executable.path, &actions, &attributes, argvPointer, envPointer)
        }
    }
    guard result == 0 else {
        throw IntatisError.io("managed process launch failed: \(String(cString: strerror(result)))")
    }
    guard getpgid(pid) == pid else {
        _ = kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        throw IntatisError.io("managed process did not start in an isolated process group")
    }
    return pid
}

#if os(macOS)
struct ManagedPTYSpawn {
    let pid: Int32
    let masterDescriptor: Int32
}

/// `forkpty` establishes a new session and controlling terminal before
/// returning in the child. The child then immediately enters the same
/// sandbox-exec command used by the pipe backend.
func spawnManagedPTYProcess(spec: ManagedProcessSpec,
                            cwd: URL,
                            rows: UInt16 = 24,
                            columns: UInt16 = 100) throws -> ManagedPTYSpawn {
    let argv = [spec.executable.path] + spec.arguments
    let envp = spec.environment.keys.sorted().map {
        "\($0)=\(spec.environment[$0] ?? "")"
    }
    var spawned = IntatisPTYSpawnResult(
        pid: -1,
        master_fd: -1,
        error_stage: Int32(INTATIS_PTY_STAGE_NONE),
        error_number: 0)
    let result: Int32 = withMutableCStrings(argv) { argvPointer in
        withMutableCStrings(envp) { envPointer in
            intatis_spawn_managed_pty(
                spec.executable.path,
                argvPointer,
                envPointer,
                cwd.path,
                rows,
                columns,
                &spawned)
        }
    }
    guard result == 0, spawned.pid > 0, spawned.master_fd >= 0 else {
        let stage: String
        switch spawned.error_stage {
        case Int32(INTATIS_PTY_STAGE_CHDIR):
            stage = "working-directory setup"
        case Int32(INTATIS_PTY_STAGE_EXEC):
            stage = "sandbox wrapper exec"
        default:
            stage = "PTY setup"
        }
        let errorNumber = spawned.error_number != 0
            ? spawned.error_number
            : result
        throw IntatisError.io(
            "managed PTY process \(stage) failed: \(String(cString: strerror(errorNumber)))")
    }
    return ManagedPTYSpawn(
        pid: spawned.pid,
        masterDescriptor: spawned.master_fd)
}
#endif

private func withMutableCStrings<Result>(_ strings: [String],
                                         _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.dropLast().forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}

func waitAndReap(pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    return 128 + signal
}
#endif

public struct RunShellTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "run_shell",
        description: "Run a shell command in the workspace directory.",
        sideEffect: .exec,
        parameters: Schema.object(["command": Schema.nonEmptyString], required: ["command"])
    )
    struct Args: Decodable { let command: String }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let result = try await context.shell.run(a.command, cwd: context.workspaceRoot)
        var out = result.stdout
        if !result.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + "[stderr]\n" + result.stderr }
        out += "\n[exit \(result.exitCode)]"
        return ToolObservation(text: out)
    }
}

// MARK: - Git

public enum GitStatus {
    public struct Entry: Equatable, Sendable {
        public let x: Character   // index status
        public let y: Character   // worktree status
        public let path: String
        public init(x: Character, y: Character, path: String) {
            self.x = x; self.y = y; self.path = path
        }
    }

    /// Parse `git status --porcelain=v1` output (`XY <path>` per line).
    public static func parse(_ porcelain: String) -> [Entry] {
        porcelain.split(separator: "\n", omittingEmptySubsequences: true).compactMap { sub in
            let line = String(sub)
            guard line.count >= 4 else { return nil }
            let chars = Array(line)
            return Entry(x: chars[0], y: chars[1], path: String(line.dropFirst(3)))
        }
    }
}

private struct GitWorkspaceLayout {
    let workspace: URL
    let additionalWritableRoots: [URL]
    let configURLs: [URL]
    let metadataRoots: [URL]
}

private func gitWorkspaceLayout(_ workspace: URL) throws -> GitWorkspaceLayout {
    let root = try validatedWorkspace(workspace)
    let dotGit = root.appendingPathComponent(".git", isDirectory: false)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
        throw IntatisError.permissionDenied("git repository metadata must be inside the agent workspace")
    }
    let dotGitValues = try dotGit.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard dotGitValues.isSymbolicLink != true else {
        throw IntatisError.permissionDenied("git metadata symlink escapes are not allowed")
    }
    if isDirectory.boolValue {
        let resolved = dotGit.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved == root.path || resolved.hasPrefix(prefix) else {
            throw IntatisError.permissionDenied("git metadata directory escapes the agent workspace")
        }
        return GitWorkspaceLayout(
            workspace: root,
            additionalWritableRoots: [],
            configURLs: [
                root.appendingPathComponent(".git/config"),
                root.appendingPathComponent(".git/config.worktree"),
            ],
            metadataRoots: [root.appendingPathComponent(".git", isDirectory: true)])
    }

    let data = try Data(contentsOf: dotGit, options: [.mappedIfSafe])
    guard data.count <= 4_096,
          let text = String(data: data, encoding: .utf8),
          let firstLine = text.split(whereSeparator: { $0.isNewline }).first else {
        throw IntatisError.permissionDenied("git worktree metadata pointer is invalid")
    }
    let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.lowercased().hasPrefix("gitdir:") else {
        throw IntatisError.permissionDenied("git worktree metadata pointer is invalid")
    }
    let rawTarget = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard rawTarget.isEmpty == false else {
        throw IntatisError.permissionDenied("git worktree metadata pointer is invalid")
    }
    let targetInput = rawTarget.hasPrefix("/")
        ? URL(fileURLWithPath: rawTarget)
        : dotGit.deletingLastPathComponent().appendingPathComponent(rawTarget)
    let target = targetInput.resolvingSymlinksInPath().standardizedFileURL
    let marker = "/.git/worktrees/"
    guard let markerRange = target.path.range(of: marker, options: .backwards) else {
        throw IntatisError.permissionDenied("git worktree metadata must stay under the owning workspace repository")
    }
    let ownerPath = String(target.path[..<markerRange.lowerBound])
    let worktreeSuffix = String(target.path[markerRange.upperBound...])
    guard worktreeSuffix.isEmpty == false,
          worktreeSuffix.contains("/") == false,
          worktreeSuffix != ".",
          worktreeSuffix != ".." else {
        throw IntatisError.permissionDenied("git worktree metadata pointer is invalid")
    }
    let owner = URL(fileURLWithPath: ownerPath).resolvingSymlinksInPath().standardizedFileURL
    let expectedWorkspace = owner
        .appendingPathComponent(
            hostToolIdentity.hiddenWorkspaceDirectoryName,
            isDirectory: true)
        .appendingPathComponent("git-worktrees", isDirectory: true)
        .appendingPathComponent(worktreeSuffix, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard expectedWorkspace.path == root.path else {
        throw IntatisError.permissionDenied(
            "git linked worktree must use \(hostGitWorktreesRelativeRoot) under its owning workspace")
    }
    let ownerMetadata = owner.appendingPathComponent(".git", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    let expectedTargetPrefix = ownerMetadata
        .appendingPathComponent("worktrees", isDirectory: true)
        .appendingPathComponent(worktreeSuffix, isDirectory: true)
        .path
    guard target.path == expectedTargetPrefix || target.path.hasPrefix(expectedTargetPrefix + "/") else {
        throw IntatisError.permissionDenied("git worktree metadata pointer does not match its owning workspace")
    }
    return GitWorkspaceLayout(
        workspace: root,
        additionalWritableRoots: [ownerMetadata],
        configURLs: [
            ownerMetadata.appendingPathComponent("config"),
            target.appendingPathComponent("config.worktree"),
        ],
        metadataRoots: [ownerMetadata, target])
}

private func gitExecutable() -> URL? {
    #if os(macOS)
    let candidates = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/usr/bin/git",
    ]
    #elseif os(Linux)
    let candidates = ["/usr/bin/git", "/bin/git"]
    #else
    let candidates: [String] = []
    #endif
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
        .map { URL(fileURLWithPath: $0) }
}

private func gitRuntimeReadRoots() -> [URL] {
    [
        "/Library/Developer/CommandLineTools",
        "/Applications/Xcode.app",
    ].filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}

private func gitEnvironment() -> [String: String] {
    [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false",
        "GIT_SSH_COMMAND": "/usr/bin/ssh -F /dev/null -oBatchMode=yes -oClearAllForwardings=yes",
        "GIT_PAGER": "cat",
        "PAGER": "cat",
        "GIT_EDITOR": "/usr/bin/false",
        "GIT_SEQUENCE_EDITOR": "/usr/bin/false",
        "GIT_MERGE_AUTOEDIT": "no",
        "GIT_ALLOW_PROTOCOL": "https:http:ssh:git:file",
    ]
}

/// Spawns `git` directly with argument arrays. A future sandbox build can
/// replace this with a libgit2-backed `GitService` implementation.
public struct ProcessGitService: GitService {
    private let commandTimeoutSeconds: TimeInterval = 5
    private let remoteCommandTimeoutSeconds: TimeInterval = 60
    private let workspaceLease: WorkspaceLease?

    public init(runner _: ShellRunner = ProcessShellRunner(),
                workspaceLease: WorkspaceLease? = nil) {
        self.workspaceLease = workspaceLease
    }

    func scoped(to lease: WorkspaceLease) -> ProcessGitService {
        ProcessGitService(workspaceLease: lease)
    }

    public func status(workspace: URL) async throws -> String {
        try await runGit(["status", "--porcelain=v1"], workspace: workspace).stdout
    }

    public func diff(workspace: URL) async throws -> String {
        try await runGit(["diff", "--no-ext-diff"], workspace: workspace).stdout
    }

    public func stagedDiff(workspace: URL) async throws -> String {
        try await runGit(["diff", "--no-ext-diff", "--staged"], workspace: workspace).stdout
    }

    public func repositoryInfo(workspace: URL) async throws -> String {
        let root = try await runGit(["rev-parse", "--show-toplevel"], workspace: workspace).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try await runGit(["branch", "--show-current"], workspace: workspace).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = await optionalGitOutput(["rev-parse", "--short=12", "HEAD"], workspace: workspace) ?? "(unborn)"
        let defaultBranch = await defaultBranch(workspace: workspace)
        let remotes = await optionalGitOutput(["remote", "-v"], workspace: workspace) ?? ""
        let statusText = try await status(workspace: workspace)
        let hasChanges = GitStatus.parse(statusText).isEmpty ? "false" : "true"
        return [
            "root: \(root)",
            "branch: \(branch.isEmpty ? "(detached HEAD)" : branch)",
            "head: \(head)",
            "defaultBranch: \(defaultBranch ?? "(unknown)")",
            "hasChanges: \(hasChanges)",
            "remotes:",
            remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(none)" : sanitizeGitOutput(remotes.trimmingCharacters(in: .whitespacesAndNewlines)),
        ].joined(separator: "\n")
    }

    public func recentCommits(limit: Int, workspace: URL) async throws -> String {
        let bounded = max(1, min(limit, 50))
        let result = try await runGit([
            "log",
            "-n", "\(bounded)",
            "--pretty=format:%h%x09%an%x09%ad%x09%s",
            "--date=short",
        ], workspace: workspace, checked: false)
        if result.exitCode != 0 {
            return "(no commits)"
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no commits)" : text
    }

    public func diffAgainst(base: String, workspace: URL) async throws -> String {
        try await runGit(["diff", "--no-ext-diff", base, "--"], workspace: workspace).stdout
    }

    public func branchInfo(workspace: URL) async throws -> String {
        let current = try await runGit(["branch", "--show-current"], workspace: workspace).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = try await runGit(["branch", "--list"], workspace: workspace).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentText = current.isEmpty ? "(detached HEAD)" : current
        return "current: \(currentText)\nbranches:\n\(branches.isEmpty ? "(none)" : branches)"
    }

    public func createBranch(name: String, startPoint: String?, workspace: URL) async throws -> String {
        var args = ["branch", name]
        if let startPoint, !startPoint.isEmpty {
            args.append(startPoint)
        }
        let result = try await runGit(args, workspace: workspace)
        return summarize(result, fallback: "created branch \(name)")
    }

    public func stage(paths: [String], workspace: URL) async throws -> String {
        let result = try await runGit(["add", "--"] + paths, workspace: workspace)
        return summarize(result, fallback: "staged \(paths.count) path(s)")
    }

    public func unstage(paths: [String], workspace: URL) async throws -> String {
        let result = try await runGit(["restore", "--staged", "--"] + paths, workspace: workspace)
        return summarize(result, fallback: "unstaged \(paths.count) path(s)")
    }

    public func commit(message: String, workspace: URL) async throws -> String {
        let result = try await runGit(["commit", "--no-gpg-sign", "-m", message], workspace: workspace)
        return summarize(result, fallback: "commit created")
    }

    public func applyPatch(diff: String,
                           reverse: Bool,
                           checkOnly: Bool,
                           cached: Bool,
                           workspace: URL) async throws -> GitPatchResult {
        let changedFiles = try GitToolInput.normalizedPatchPaths(diff, workspace: workspace)
        let patchDirectory = workspace
            .appendingPathComponent(
                hostToolIdentity.hiddenWorkspaceDirectoryName,
                isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: patchDirectory, withIntermediateDirectories: true)
        let patchURL = patchDirectory.appendingPathComponent("git-\(UUID().uuidString).patch")
        try diff.write(to: patchURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: patchURL) }

        if reverse && !checkOnly && !cached {
            try? await stageExistingPatchPaths(changedFiles, workspace: workspace)
        }

        var args = ["apply"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        if checkOnly {
            args.append("--check")
        } else if !cached {
            args.append("--3way")
        }
        args.append(patchURL.path)
        let result = try await runGit(args, workspace: workspace)
        let action: String
        if checkOnly {
            action = "patch applies cleanly"
        } else if cached && reverse {
            action = "unstaged patch"
        } else if cached {
            action = "staged patch"
        } else if reverse {
            action = "reverted patch"
        } else {
            action = "applied patch"
        }
        return GitPatchResult(
            text: summarize(result, fallback: "\(action) touching \(changedFiles.count) path(s)"),
            changedFiles: changedFiles,
            diff: diff)
    }

    public func worktrees(workspace: URL) async throws -> String {
        let result = try await runGit(["worktree", "list", "--porcelain"], workspace: workspace)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no worktrees)" : text
    }

    public func createWorktree(name: String, startPoint: String?, branch: String?, workspace: URL) async throws -> String {
        let safeName = try GitToolInput.worktreeName(name)
        let directory = workspace
            .appendingPathComponent(
                hostToolIdentity.hiddenWorkspaceDirectoryName,
                isDirectory: true)
            .appendingPathComponent("git-worktrees", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var args = ["worktree", "add"]
        if let branch, !branch.isEmpty {
            args.append(contentsOf: ["-b", branch])
        } else {
            args.append("--detach")
        }
        args.append(directory.path)
        if let startPoint, !startPoint.isEmpty {
            args.append(startPoint)
        }
        let result = try await runGit(args, workspace: workspace)
        return summarize(result, fallback: "created worktree \(safeName)")
    }

    public func removeWorktree(name: String, force: Bool, workspace: URL) async throws -> String {
        let safeName = try GitToolInput.worktreeName(name)
        let directory = workspace
            .appendingPathComponent(
                hostToolIdentity.hiddenWorkspaceDirectoryName,
                isDirectory: true)
            .appendingPathComponent("git-worktrees", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(directory.path)
        let result = try await runGit(args, workspace: workspace)
        return summarize(result, fallback: "removed worktree \(safeName)")
    }

    public func remotes(workspace: URL) async throws -> String {
        let result = try await runGit(["remote", "-v"], workspace: workspace)
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no remotes)" : sanitizeGitOutput(text)
    }

    public func fetch(remote: String, branch: String?, prune: Bool, workspace: URL) async throws -> String {
        let safeRemote = try GitToolInput.remoteName(remote)
        try await ensureRemoteExists(safeRemote, workspace: workspace)
        var args = ["fetch"]
        if prune {
            args.append("--prune")
        }
        args.append(safeRemote)
        if let branch, !branch.isEmpty {
            args.append(try GitToolInput.branchName(branch))
        }
        let result = try await runGit(args,
                                      workspace: workspace,
                                      timeoutSeconds: remoteCommandTimeoutSeconds,
                                      allowsNetwork: true)
        return summarize(result, fallback: "fetched \(safeRemote)\(branch.map { "/\($0)" } ?? "")")
    }

    public func pullFastForward(remote: String, branch: String, workspace: URL) async throws -> String {
        let safeRemote = try GitToolInput.remoteName(remote)
        let safeBranch = try GitToolInput.branchName(branch)
        try await ensureRemoteExists(safeRemote, workspace: workspace)
        try await ensureCleanWorktree(workspace: workspace, operation: "git_pull_ff")
        let current = try await currentBranch(workspace: workspace)
        guard current == safeBranch else {
            throw IntatisError.permissionDenied("git_pull_ff branch must match current branch (\(current))")
        }
        let result = try await runGit(["pull", "--ff-only", safeRemote, safeBranch],
                                      workspace: workspace,
                                      timeoutSeconds: remoteCommandTimeoutSeconds,
                                      allowsNetwork: true)
        return summarize(result, fallback: "fast-forward pulled \(safeRemote)/\(safeBranch)")
    }

    public func push(remote: String, branch: String, setUpstream: Bool, workspace: URL) async throws -> String {
        let safeRemote = try GitToolInput.remoteName(remote)
        let safeBranch = try GitToolInput.branchName(branch)
        try await ensureRemoteExists(safeRemote, workspace: workspace)
        let current = try await currentBranch(workspace: workspace)
        guard current == safeBranch else {
            throw IntatisError.permissionDenied("git_push branch must match current branch (\(current))")
        }
        var args = ["push"]
        if setUpstream {
            args.append("-u")
        }
        args.append(contentsOf: [safeRemote, safeBranch])
        let result = try await runGit(args,
                                      workspace: workspace,
                                      timeoutSeconds: remoteCommandTimeoutSeconds,
                                      allowsNetwork: true)
        return summarize(result, fallback: "pushed \(safeBranch) to \(safeRemote)")
    }

    public func switchBranch(name: String, workspace: URL) async throws -> String {
        let branch = try GitToolInput.branchName(name)
        try await ensureCleanWorktree(workspace: workspace, operation: "git_switch")
        let result = try await runGit(["switch", branch], workspace: workspace)
        return summarize(result, fallback: "switched to \(branch)")
    }

    private func stageExistingPatchPaths(_ paths: [String], workspace: URL) async throws {
        var existing: [String] = []
        for path in paths {
            let url = workspace.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                existing.append(path)
            }
        }
        guard !existing.isEmpty else { return }
        _ = try await runGit(["add", "--"] + existing, workspace: workspace, checked: false)
    }

    private func runGit(_ args: [String],
                        workspace: URL,
                        checked: Bool = true,
                        timeoutSeconds: TimeInterval? = nil,
                        allowsNetwork: Bool = false) async throws -> ShellResult {
        try await validateRepository(workspace: workspace)
        try await validateRepositoryConfiguration(workspace: workspace)
        return try await runRawGit(gitConfigArgs() + args,
                                   workspace: workspace,
                                   checked: checked,
                                   timeoutSeconds: timeoutSeconds ?? commandTimeoutSeconds,
                                   allowsNetwork: allowsNetwork)
    }

    private func validateRepository(workspace: URL) async throws {
        let workspaceURL = workspace.resolvingSymlinksInPath().standardizedFileURL
        let workspacePath = workspaceURL.path
        let root = try await runRawGit(["rev-parse", "--show-toplevel"], workspace: workspace, checked: true, timeoutSeconds: commandTimeoutSeconds)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let repoRoot = URL(fileURLWithPath: root)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard repoRoot == workspacePath else {
            throw IntatisError.permissionDenied("git repository root must match the agent workspace root")
        }

        let gitDirText = try await runRawGit(["rev-parse", "--git-dir"], workspace: workspace, checked: true, timeoutSeconds: commandTimeoutSeconds)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirInput = gitDirText.hasPrefix("/")
            ? URL(fileURLWithPath: gitDirText)
            : workspaceURL.appendingPathComponent(gitDirText)
        let gitDir = gitDirInput.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        if gitDir == workspacePath || gitDir.hasPrefix(prefix) {
            return
        }

        let dotGit = workspaceURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw IntatisError.permissionDenied("git metadata directory escapes the agent workspace")
        }

        let commonDirText = try await runRawGit(["rev-parse", "--git-common-dir"], workspace: workspace, checked: true, timeoutSeconds: commandTimeoutSeconds)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDirInput = commonDirText.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirText)
            : workspaceURL.appendingPathComponent(commonDirText)
        let commonDir = commonDirInput.resolvingSymlinksInPath().standardizedFileURL.path
        let worktreePrefix = URL(fileURLWithPath: commonDir)
            .appendingPathComponent("worktrees", isDirectory: true)
            .path + "/"
        let ownerRoot = URL(fileURLWithPath: commonDir).deletingLastPathComponent().path
        let ownerPrefix = ownerRoot.hasSuffix("/") ? ownerRoot : ownerRoot + "/"
        guard gitDir.hasPrefix(worktreePrefix),
              workspacePath == ownerRoot || workspacePath.hasPrefix(ownerPrefix) else {
            throw IntatisError.permissionDenied("git worktree metadata must stay under the owning workspace repository")
        }
    }

    private func gitConfigArgs() -> [String] {
        [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "diff.external=",
            "-c", "interactive.diffFilter=",
            "-c", "core.pager=cat",
        ]
    }

    private func validateRepositoryConfiguration(workspace: URL) async throws {
        let result = try await runRawGit(
            gitConfigArgs() + ["config", "--local", "--name-only", "--list"],
            workspace: workspace,
            checked: false,
            timeoutSeconds: commandTimeoutSeconds)
        guard result.exitCode == 0 else {
            throw IntatisError.permissionDenied("git repository config could not be inspected safely")
        }
        let names = result.stdout.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isUnsafeGitConfigKey)
        guard names.isEmpty else {
            throw IntatisError.permissionDenied(
                "git repository config contains disabled executable hooks/filters: \(names.joined(separator: ", "))")
        }
    }

    private func validateRepositoryConfigFile(_ layout: GitWorkspaceLayout) throws {
        for configURL in layout.configURLs {
            var entry = stat()
            if lstat(configURL.path, &entry) != 0 {
                if errno == ENOENT { continue }
                throw IntatisError.permissionDenied("git repository config could not be inspected safely")
            }
            guard (entry.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                throw IntatisError.permissionDenied("git repository config symlinks are not allowed")
            }
            let resolved = configURL.resolvingSymlinksInPath().standardizedFileURL
            let isConfined = layout.metadataRoots.contains { root in
                let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
                return resolved.path == canonicalRoot || resolved.path.hasPrefix(canonicalRoot + "/")
            }
            guard isConfined else {
                throw IntatisError.permissionDenied("git repository config escapes approved metadata roots")
            }
            let byteCount = Int(entry.st_size)
            guard byteCount >= 0, byteCount <= 1_048_576 else {
                throw IntatisError.permissionDenied("git repository config is too large to inspect safely")
            }
            let data = try Data(contentsOf: configURL, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                throw IntatisError.permissionDenied("git repository config is not valid UTF-8")
            }
            var section = ""
            var unsafe: [String] = []
            for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                if line.hasPrefix("["), line.hasSuffix("]") {
                    let body = line.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                    let base = body.prefix { $0 != " " && $0 != "\t" && $0 != "\"" }.lowercased()
                    let quoted = body.split(separator: "\"", omittingEmptySubsequences: false)
                    if quoted.count >= 3 {
                        section = base + "." + quoted[1].lowercased()
                    } else {
                        section = base
                    }
                    continue
                }
                let key = line.prefix { $0 != "=" && $0 != " " && $0 != "\t" }.lowercased()
                guard key.isEmpty == false, section.isEmpty == false else { continue }
                let fullKey = section + "." + key
                if isUnsafeGitConfigKey(fullKey) { unsafe.append(fullKey) }
            }
            guard unsafe.isEmpty else {
                throw IntatisError.permissionDenied(
                    "git repository config contains disabled executable hooks/filters: \(Array(Set(unsafe)).sorted().joined(separator: ", "))")
            }
        }
    }

    private func isUnsafeGitConfigKey(_ rawKey: String) -> Bool {
        let key = rawKey.lowercased()
        if key.hasPrefix("include.") || key.hasPrefix("includeif.") { return true }
        if [
            "core.hookspath", "core.fsmonitor", "core.sshcommand", "core.gitproxy",
            "core.attributesfile", "core.excludesfile", "diff.external",
        ].contains(key) { return true }
        let components = key.split(separator: ".").map(String.init)
        guard let first = components.first, let last = components.last else { return false }
        switch first {
        case "diff": return ["command", "textconv"].contains(last)
        case "filter": return ["clean", "smudge", "process"].contains(last)
        case "merge": return last == "driver"
        case "credential": return last == "helper"
        case "gpg": return last == "program"
        case "remote": return ["uploadpack", "receivepack", "proxy"].contains(last)
        case "http": return ["cookiefile", "sslcert", "sslkey"].contains(last)
        default: return false
        }
    }

    private func runRawGit(_ args: [String],
                           workspace: URL,
                           checked: Bool,
                           timeoutSeconds: TimeInterval,
                           allowsNetwork: Bool = false) async throws -> ShellResult {
        #if os(macOS) || os(Linux)
        let command = args.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? args.first ?? "command"
        let layout = try gitWorkspaceLayout(workspace)
        try validateRepositoryConfigFile(layout)
        guard let executable = gitExecutable() else {
            throw IntatisError.config("git is unavailable in a trusted fixed runtime path")
        }
        let result = try await runWorkspaceProcess(
            executable: executable,
            arguments: args,
            cwd: layout.workspace,
            networkAccess: allowsNetwork ? .allowed : .denied,
            trustedReadRoots: gitRuntimeReadRoots(),
            writableRoots: layout.additionalWritableRoots,
            workspaceLease: workspaceLease,
            environment: gitEnvironment(),
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: 0.5,
            maximumGeneratedFileBytes: 8 * 1_024 * 1_024,
            maximumOutputBytes: 8 * 1_024 * 1_024)
        if checked, result.exitCode != 0 {
            let message = summarize(result, fallback: "exit \(result.exitCode)")
            let renderedArgs = args.joined(separator: " ")
            throw IntatisError.io("git \(command) failed (\(renderedArgs)): \(message)")
        }
        return result
        #else
        throw IntatisError.io("git execution is unavailable on this platform")
        #endif
    }

    private func optionalGitOutput(_ args: [String], workspace: URL) async -> String? {
        guard let result = try? await runGit(args, workspace: workspace, checked: false),
              result.exitCode == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func defaultBranch(workspace: URL) async -> String? {
        if let remoteHead = await optionalGitOutput(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], workspace: workspace) {
            return remoteHead.replacingOccurrences(of: "origin/", with: "")
        }
        for candidate in ["main", "master", "trunk"] {
            let result = try? await runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], workspace: workspace, checked: false)
            if result?.exitCode == 0 {
                return candidate
            }
        }
        return nil
    }

    private func summarize(_ result: ShellResult, fallback: String) -> String {
        let combined = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return combined.isEmpty ? fallback : String(sanitizeGitOutput(combined).prefix(12_000))
    }

    private func remoteNames(workspace: URL) async throws -> Set<String> {
        let output = try await runGit(["remote"], workspace: workspace)
            .stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(output)
    }

    private func ensureRemoteExists(_ remote: String, workspace: URL) async throws {
        guard try await remoteNames(workspace: workspace).contains(remote) else {
            throw IntatisError.decoding("git remote is not configured: \(remote)")
        }
    }

    private func currentBranch(workspace: URL) async throws -> String {
        let current = try await runGit(["branch", "--show-current"], workspace: workspace)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            throw IntatisError.permissionDenied("git operation requires a checked-out local branch")
        }
        return current
    }

    private func ensureCleanWorktree(workspace: URL, operation: String) async throws {
        let statusText = try await status(workspace: workspace)
        guard GitStatus.parse(statusText).isEmpty else {
            throw IntatisError.permissionDenied("\(operation) requires a clean working tree")
        }
    }

    private func sanitizeGitOutput(_ text: String) -> String {
        var output = text
        let replacements = [
            (#"://[^/\s]+@"#, "://***@"),
            (#"ghp_[A-Za-z0-9_]+"#, "ghp_***"),
            (#"github_pat_[A-Za-z0-9_]+"#, "github_pat_***"),
            (#"glpat-[A-Za-z0-9_-]+"#, "glpat-***"),
        ]
        for (pattern, replacement) in replacements {
            while let range = output.range(of: pattern, options: .regularExpression) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }
}

private enum GitToolInput {
    static func normalizedPaths(_ paths: [String], workspace: URL) throws -> [String] {
        guard !paths.isEmpty else {
            throw IntatisError.decoding("git paths must not be empty")
        }
        return try paths.map { rawPath in
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw IntatisError.decoding("git paths must not contain empty entries")
            }
            let url = try PathConfinement.resolve(path, within: workspace)
            return PathConfinement.relativePath(of: url, root: workspace)
        }
    }

    static func branchName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw IntatisError.decoding("branch name must not be empty")
        }
        guard name.count <= 255 else {
            throw IntatisError.decoding("branch name is too long")
        }
        let forbidden = ["..", "@{", "\\", "~", "^", ":", "?", "*", "[", "\n", "\r", "\t"]
        guard !forbidden.contains(where: { name.contains($0) }),
              !name.hasPrefix("-"),
              !name.hasPrefix("/"),
              !name.hasSuffix("/"),
              !name.hasSuffix("."),
              !name.contains("//"),
              name != "@" else {
            throw IntatisError.decoding("branch name contains characters Git refs cannot safely use")
        }
        return name
    }

    static func remoteName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw IntatisError.decoding("remote name must not be empty")
        }
        guard name.count <= 80 else {
            throw IntatisError.decoding("remote name is too long")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !name.hasPrefix("-"),
              !name.hasPrefix("."),
              !name.contains("..") else {
            throw IntatisError.decoding("remote must be a configured remote name, not a URL or refspec")
        }
        return name
    }

    static func optionalRef(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= 255,
              !value.hasPrefix("-"),
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("\t") else {
            throw IntatisError.decoding("git start point is not a safe ref")
        }
        return value
    }

    static func requiredRef(_ raw: String) throws -> String {
        guard let value = try optionalRef(raw) else {
            throw IntatisError.decoding("git ref must not be empty")
        }
        return value
    }

    static func boundedLimit(_ raw: Int?) -> Int {
        max(1, min(raw ?? 10, 50))
    }

    static func worktreeName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw IntatisError.decoding("worktree name must not be empty")
        }
        guard name.count <= 80 else {
            throw IntatisError.decoding("worktree name is too long")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !name.hasPrefix("."),
              !name.hasPrefix("-"),
              !name.contains("..") else {
            throw IntatisError.decoding("worktree name must be a simple safe directory name")
        }
        return name
    }

    static func normalizedPatchPaths(_ diff: String, workspace: URL) throws -> [String] {
        let rawPaths = try patchPaths(diff)
        return try normalizedPaths(rawPaths, workspace: workspace)
    }

    static func patchPathsForPermission(_ diff: String) -> [String] {
        (try? patchPaths(diff)) ?? ["."]
    }

    private static func patchPaths(_ diff: String) throws -> [String] {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntatisError.decoding("git patch must not be empty")
        }
        var result: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            guard let path = normalizePatchPath(raw), !seen.contains(path) else { return }
            seen.insert(path)
            result.append(path)
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                append(String(line.dropFirst(4)))
            } else if line.hasPrefix("diff --git ") {
                let rest = String(line.dropFirst("diff --git ".count))
                let tokens = diffGitPathTokens(rest)
                if tokens.count >= 2 {
                    append(tokens[0])
                    append(tokens[1])
                }
            }
        }

        guard !result.isEmpty else {
            throw IntatisError.decoding("git patch does not expose any changed paths")
        }
        return result
    }

    private static func diffGitPathTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var escaping = false

        for scalar in text.unicodeScalars {
            let ch = Character(scalar)
            if escaping {
                current.unicodeScalars.append(scalar)
                escaping = false
                continue
            }
            if inQuote && ch == "\\" {
                escaping = true
                continue
            }
            if ch == "\"" {
                inQuote.toggle()
                continue
            }
            if !inQuote && CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func normalizePatchPath(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tab = value.firstIndex(of: "\t") {
            value = String(value[..<tab])
        }
        if value == "/dev/null" { return nil }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value.removeFirst()
            value.removeLast()
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value.isEmpty ? nil : value
    }
}

public struct GitStatusTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_status",
        description: "Show working-tree status (porcelain).",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let porcelain = try await context.git.status(workspace: context.workspaceRoot)
        let entries = GitStatus.parse(porcelain)
        if entries.isEmpty { return ToolObservation(text: "clean") }
        let lines = entries.map { "\($0.x)\($0.y) \($0.path)" }
        return ToolObservation(text: lines.joined(separator: "\n"))
    }
}

public struct GitDiffTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_diff",
        description: "Show unstaged changes as a unified diff.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let diff = try await context.git.diff(workspace: context.workspaceRoot)
        let limit = 200_000
        let truncated = diff.utf8.count > limit
        let text = truncated ? String(diff.prefix(limit)) : diff
        return ToolObservation(text: text.isEmpty ? "(no changes)" : text, truncated: truncated, diff: diff)
    }
}

public struct GitStagedDiffTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_diff_staged",
        description: "Show staged changes as a unified diff.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let diff = try await context.git.stagedDiff(workspace: context.workspaceRoot)
        let limit = 200_000
        let truncated = diff.utf8.count > limit
        let text = truncated ? String(diff.prefix(limit)) : diff
        return ToolObservation(text: text.isEmpty ? "(no staged changes)" : text, truncated: truncated, diff: diff)
    }
}

public struct GitInfoTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_info",
        description: "Show repository metadata: root, branch, HEAD, default branch, change state, and remotes.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: try await context.git.repositoryInfo(workspace: context.workspaceRoot))
    }
}

public struct GitRecentCommitsTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_recent_commits",
        description: "Show recent local commits as short hash, author, date, and subject.",
        sideEffect: .readOnly,
        parameters: Schema.object([
            "limit": Schema.boundedInteger(minimum: 1, maximum: 50),
        ], required: [])
    )

    struct Args: Decodable { let limit: Int? }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let limit = GitToolInput.boundedLimit(a.limit)
        return ToolObservation(text: try await context.git.recentCommits(limit: limit, workspace: context.workspaceRoot))
    }
}

public struct GitDiffBaseTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_diff_base",
        description: "Show the workspace diff against a safe Git base ref such as main or origin/main.",
        sideEffect: .readOnly,
        parameters: Schema.object([
            "base": Schema.boundedString(minLength: 1, maxLength: 255),
        ], required: ["base"])
    )

    struct Args: Decodable { let base: String }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let base = try GitToolInput.requiredRef(a.base)
        let diff = try await context.git.diffAgainst(base: base, workspace: context.workspaceRoot)
        let limit = 200_000
        let truncated = diff.utf8.count > limit
        let text = truncated ? String(diff.prefix(limit)) : diff
        return ToolObservation(text: text.isEmpty ? "(no changes against \(base))" : text,
                               truncated: truncated,
                               diff: diff)
    }
}

public struct GitBranchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_branch",
        description: "Show current branch and local branches.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: try await context.git.branchInfo(workspace: context.workspaceRoot))
    }
}

public struct GitCreateBranchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_create_branch",
        description: "Create a local branch without switching branches.",
        sideEffect: .write,
        parameters: Schema.object([
            "name": Schema.boundedString(minLength: 1, maxLength: 255),
            "startPoint": Schema.boundedString(minLength: 1, maxLength: 255),
        ], required: ["name"])
    )

    struct Args: Decodable { let name: String; let startPoint: String? }

    public func touchedPaths(_ args: ToolArgs) -> [String] { [".git"] }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let name = try GitToolInput.branchName(a.name)
        let startPoint = try GitToolInput.optionalRef(a.startPoint)
        let output = try await context.git.createBranch(name: name, startPoint: startPoint, workspace: context.workspaceRoot)
        return ToolObservation(text: output)
    }
}

public struct GitStageTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_stage",
        description: "Stage workspace-confined paths in the Git index.",
        sideEffect: .write,
        parameters: Schema.object([
            "paths": .object([
                "type": .string("array"),
                "items": Schema.nonEmptyString,
                "minItems": .number(1),
            ]),
        ], required: ["paths"])
    )

    struct Args: Decodable { let paths: [String] }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return [".git/index"] + (decoded?.paths ?? [])
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let paths = try GitToolInput.normalizedPaths(a.paths, workspace: context.workspaceRoot)
        let output = try await context.git.stage(paths: paths, workspace: context.workspaceRoot)
        return ToolObservation(text: output, changedFiles: paths)
    }
}

public struct GitUnstageTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_unstage",
        description: "Remove workspace-confined paths from the Git index without changing working-tree files.",
        sideEffect: .write,
        parameters: Schema.object([
            "paths": .object([
                "type": .string("array"),
                "items": Schema.nonEmptyString,
                "minItems": .number(1),
            ]),
        ], required: ["paths"])
    )

    struct Args: Decodable { let paths: [String] }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return [".git/index"] + (decoded?.paths ?? [])
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let paths = try GitToolInput.normalizedPaths(a.paths, workspace: context.workspaceRoot)
        let output = try await context.git.unstage(paths: paths, workspace: context.workspaceRoot)
        return ToolObservation(text: output, changedFiles: paths)
    }
}

public struct GitCommitTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_commit",
        description: "Create a local commit from the staged index. Hooks and GPG signing are disabled for agent safety.",
        sideEffect: .write,
        parameters: Schema.object([
            "message": Schema.boundedString(minLength: 1, maxLength: 4_000),
        ], required: ["message"])
    )

    struct Args: Decodable { let message: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] { [".git"] }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let message = a.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw IntatisError.decoding("commit message must not be empty")
        }
        let stagedEntries = GitStatus.parse(try await context.git.status(workspace: context.workspaceRoot))
            .filter { $0.x != " " && $0.x != "?" }
        if let sensitive = stagedEntries.first(where: { PathConfinement.isSensitivePath($0.path) }) {
            throw IntatisError.permissionDenied("refusing to commit staged sensitive path: \(sensitive.path)")
        }
        let output = try await context.git.commit(message: message, workspace: context.workspaceRoot)
        return ToolObservation(text: output)
    }
}

public struct GitApplyPatchCheckTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_apply_patch_check",
        description: "Validate whether a unified diff can be applied by Git without changing the workspace.",
        sideEffect: .readOnly,
        parameters: Schema.object([
            "diff": Schema.boundedString(minLength: 1, maxLength: 500_000),
            "reverse": Schema.boolean,
        ], required: ["diff"])
    )

    struct Args: Decodable { let diff: String; let reverse: Bool? }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return decoded.map { GitToolInput.patchPathsForPermission($0.diff) } ?? ["."]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try GitToolInput.normalizedPatchPaths(a.diff, workspace: context.workspaceRoot)
        let result = try await context.git.applyPatch(diff: a.diff,
                                                       reverse: a.reverse ?? false,
                                                       checkOnly: true,
                                                       cached: false,
                                                       workspace: context.workspaceRoot)
        return ToolObservation(text: result.text)
    }
}

public struct GitApplyPatchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_apply_patch",
        description: "Apply a unified diff to the working tree through git apply --3way.",
        sideEffect: .write,
        parameters: Schema.object([
            "diff": Schema.boundedString(minLength: 1, maxLength: 500_000),
        ], required: ["diff"])
    )

    struct Args: Decodable { let diff: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return decoded.map { GitToolInput.patchPathsForPermission($0.diff) } ?? ["."]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try GitToolInput.normalizedPatchPaths(a.diff, workspace: context.workspaceRoot)
        let result = try await context.git.applyPatch(diff: a.diff,
                                                       reverse: false,
                                                       checkOnly: false,
                                                       cached: false,
                                                       workspace: context.workspaceRoot)
        return ToolObservation(text: result.text, diff: result.diff, changedFiles: result.changedFiles)
    }
}

public struct GitStagePatchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_stage_patch",
        description: "Stage a provided unified diff hunk in the Git index without changing working-tree files.",
        sideEffect: .write,
        parameters: Schema.object([
            "diff": Schema.boundedString(minLength: 1, maxLength: 500_000),
        ], required: ["diff"])
    )

    struct Args: Decodable { let diff: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return [".git/index"] + (decoded.map { GitToolInput.patchPathsForPermission($0.diff) } ?? ["."])
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try GitToolInput.normalizedPatchPaths(a.diff, workspace: context.workspaceRoot)
        let result = try await context.git.applyPatch(diff: a.diff,
                                                       reverse: false,
                                                       checkOnly: false,
                                                       cached: true,
                                                       workspace: context.workspaceRoot)
        return ToolObservation(text: result.text, changedFiles: result.changedFiles)
    }
}

public struct GitUnstagePatchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_unstage_patch",
        description: "Reverse a provided unified diff hunk out of the Git index without changing working-tree files.",
        sideEffect: .write,
        parameters: Schema.object([
            "diff": Schema.boundedString(minLength: 1, maxLength: 500_000),
        ], required: ["diff"])
    )

    struct Args: Decodable { let diff: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return [".git/index"] + (decoded.map { GitToolInput.patchPathsForPermission($0.diff) } ?? ["."])
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try GitToolInput.normalizedPatchPaths(a.diff, workspace: context.workspaceRoot)
        let result = try await context.git.applyPatch(diff: a.diff,
                                                       reverse: true,
                                                       checkOnly: false,
                                                       cached: true,
                                                       workspace: context.workspaceRoot)
        return ToolObservation(text: result.text, changedFiles: result.changedFiles)
    }
}

public struct GitRevertPatchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_revert_patch",
        description: "Destructively reverse a provided unified diff from the working tree through git apply -R --3way.",
        sideEffect: .destructive,
        parameters: Schema.object([
            "diff": Schema.boundedString(minLength: 1, maxLength: 500_000),
            "confirmRevert": Schema.boolean,
        ], required: ["diff", "confirmRevert"])
    )

    struct Args: Decodable { let diff: String; let confirmRevert: Bool }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        return decoded.map { GitToolInput.patchPathsForPermission($0.diff) } ?? ["."]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        guard a.confirmRevert else {
            throw IntatisError.permissionDenied("git_revert_patch requires confirmRevert=true")
        }
        _ = try GitToolInput.normalizedPatchPaths(a.diff, workspace: context.workspaceRoot)
        let result = try await context.git.applyPatch(diff: a.diff,
                                                       reverse: true,
                                                       checkOnly: false,
                                                       cached: false,
                                                       workspace: context.workspaceRoot)
        return ToolObservation(text: result.text, diff: result.diff, changedFiles: result.changedFiles)
    }
}

public struct GitWorktreeListTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_worktree_list",
        description: "List Git worktrees for the current repository.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: try await context.git.worktrees(workspace: context.workspaceRoot))
    }
}

public struct GitWorktreeCreateTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_worktree_create",
        description: "Create a workspace-contained managed Git worktree under \(hostGitWorktreesRelativeRoot). Defaults to detached HEAD.",
        sideEffect: .write,
        parameters: Schema.object([
            "name": Schema.boundedString(minLength: 1, maxLength: 80),
            "startPoint": Schema.boundedString(minLength: 1, maxLength: 255),
            "branch": Schema.boundedString(minLength: 1, maxLength: 255),
        ], required: ["name"])
    )

    struct Args: Decodable { let name: String; let startPoint: String?; let branch: String? }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        let name = (try? decoded.map { try GitToolInput.worktreeName($0.name) }) ?? "unknown"
        return [".git", hostGitWorktreesRelativeRoot + "/" + name]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let name = try GitToolInput.worktreeName(a.name)
        let startPoint = try GitToolInput.optionalRef(a.startPoint)
        let branch = try a.branch.map { try GitToolInput.branchName($0) }
        let output = try await context.git.createWorktree(name: name,
                                                          startPoint: startPoint,
                                                          branch: branch,
                                                          workspace: context.workspaceRoot)
        return ToolObservation(
            text: output,
            changedFiles: [hostGitWorktreesRelativeRoot + "/" + name])
    }
}

public struct GitWorktreeRemoveTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_worktree_remove",
        description: "Destructively remove a managed worktree under \(hostGitWorktreesRelativeRoot) after exact name confirmation.",
        sideEffect: .destructive,
        parameters: Schema.object([
            "name": Schema.boundedString(minLength: 1, maxLength: 80),
            "confirmName": Schema.boundedString(minLength: 1, maxLength: 80),
            "force": Schema.boolean,
        ], required: ["name", "confirmName"])
    )

    struct Args: Decodable { let name: String; let confirmName: String; let force: Bool? }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        let decoded = try? args.decode(Args.self)
        let name = (try? decoded.map { try GitToolInput.worktreeName($0.name) }) ?? "unknown"
        return [".git", hostGitWorktreesRelativeRoot + "/" + name]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let name = try GitToolInput.worktreeName(a.name)
        let confirmName = try GitToolInput.worktreeName(a.confirmName)
        guard name == confirmName else {
            throw IntatisError.permissionDenied("git_worktree_remove confirmName must match name")
        }
        let output = try await context.git.removeWorktree(name: name,
                                                          force: a.force ?? false,
                                                          workspace: context.workspaceRoot)
        return ToolObservation(
            text: output,
            changedFiles: [hostGitWorktreesRelativeRoot + "/" + name])
    }
}

public struct GitRemotesTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_remotes",
        description: "List configured Git remotes with credentials redacted.",
        sideEffect: .readOnly,
        parameters: Schema.object([:], required: [])
    )

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        ToolObservation(text: try await context.git.remotes(workspace: context.workspaceRoot))
    }
}

public struct GitFetchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_fetch",
        description: "Fetch from a configured Git remote name. Does not accept remote URLs.",
        sideEffect: .write,
        parameters: Schema.object([
            "remote": Schema.boundedString(minLength: 1, maxLength: 80),
            "branch": Schema.boundedString(minLength: 1, maxLength: 255),
            "prune": Schema.boolean,
        ], required: ["remote"])
    )

    struct Args: Decodable { let remote: String; let branch: String?; let prune: Bool? }

    public func touchedPaths(_ args: ToolArgs) -> [String] { [".git"] }
    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let remote = try GitToolInput.remoteName(a.remote)
        let branch = try a.branch.map { try GitToolInput.branchName($0) }
        let output = try await context.git.fetch(remote: remote,
                                                 branch: branch,
                                                 prune: a.prune ?? false,
                                                 workspace: context.workspaceRoot)
        return ToolObservation(text: output)
    }
}

public struct GitPullFastForwardTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_pull_ff",
        description: "Fast-forward pull the current clean branch from a configured remote. Requires exact remote and branch confirmation.",
        sideEffect: .write,
        parameters: Schema.object([
            "remote": Schema.boundedString(minLength: 1, maxLength: 80),
            "branch": Schema.boundedString(minLength: 1, maxLength: 255),
            "confirmRemote": Schema.boundedString(minLength: 1, maxLength: 80),
            "confirmBranch": Schema.boundedString(minLength: 1, maxLength: 255),
        ], required: ["remote", "branch", "confirmRemote", "confirmBranch"])
    )

    struct Args: Decodable {
        let remote: String
        let branch: String
        let confirmRemote: String
        let confirmBranch: String
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] { [".", ".git"] }
    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let remote = try GitToolInput.remoteName(a.remote)
        let branch = try GitToolInput.branchName(a.branch)
        let confirmRemote = try GitToolInput.remoteName(a.confirmRemote)
        let confirmBranch = try GitToolInput.branchName(a.confirmBranch)
        guard remote == confirmRemote, branch == confirmBranch else {
            throw IntatisError.permissionDenied("git_pull_ff confirmation must match remote and branch")
        }
        let output = try await context.git.pullFastForward(remote: remote,
                                                           branch: branch,
                                                           workspace: context.workspaceRoot)
        return ToolObservation(text: output, changedFiles: ["."])
    }
}

public struct GitPushTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_push",
        description: "Push the current branch to a configured Git remote. Force push and URL remotes are not supported.",
        sideEffect: .destructive,
        parameters: Schema.object([
            "remote": Schema.boundedString(minLength: 1, maxLength: 80),
            "branch": Schema.boundedString(minLength: 1, maxLength: 255),
            "setUpstream": Schema.boolean,
            "confirmRemote": Schema.boundedString(minLength: 1, maxLength: 80),
            "confirmBranch": Schema.boundedString(minLength: 1, maxLength: 255),
        ], required: ["remote", "branch", "confirmRemote", "confirmBranch"])
    )

    struct Args: Decodable {
        let remote: String
        let branch: String
        let setUpstream: Bool?
        let confirmRemote: String
        let confirmBranch: String
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] { [".git"] }
    public func risksNetwork(_ args: ToolArgs) -> Bool { true }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let remote = try GitToolInput.remoteName(a.remote)
        let branch = try GitToolInput.branchName(a.branch)
        let confirmRemote = try GitToolInput.remoteName(a.confirmRemote)
        let confirmBranch = try GitToolInput.branchName(a.confirmBranch)
        guard remote == confirmRemote, branch == confirmBranch else {
            throw IntatisError.permissionDenied("git_push confirmation must match remote and branch")
        }
        let output = try await context.git.push(remote: remote,
                                                branch: branch,
                                                setUpstream: a.setUpstream ?? false,
                                                workspace: context.workspaceRoot)
        return ToolObservation(text: output)
    }
}

public struct GitSwitchBranchTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "git_switch",
        description: "Switch to an existing local branch only when the working tree is clean. Requires exact branch confirmation.",
        sideEffect: .destructive,
        parameters: Schema.object([
            "branch": Schema.boundedString(minLength: 1, maxLength: 255),
            "confirmBranch": Schema.boundedString(minLength: 1, maxLength: 255),
        ], required: ["branch", "confirmBranch"])
    )

    struct Args: Decodable { let branch: String; let confirmBranch: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] { [".", ".git"] }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let branch = try GitToolInput.branchName(a.branch)
        let confirmBranch = try GitToolInput.branchName(a.confirmBranch)
        guard branch == confirmBranch else {
            throw IntatisError.permissionDenied("git_switch confirmBranch must match branch")
        }
        let output = try await context.git.switchBranch(name: branch, workspace: context.workspaceRoot)
        return ToolObservation(text: output, changedFiles: ["."])
    }
}
