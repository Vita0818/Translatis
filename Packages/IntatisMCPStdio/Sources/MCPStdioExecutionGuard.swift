import Foundation
import IntatisMCP
import IntatisMCPStdioGuard
import IntatisProtocol

enum MCPStdioExecutionGuardPlan: Sendable {
    case macOSInitialExecOnly
    case linuxPtraceSeccomp(
        primary: MCPStdioExecutableIdentity,
        helpers: [MCPStdioExecutableIdentity])
}

struct MCPStdioExecutableIdentity: Equatable, Sendable {
    let canonicalPath: String
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: UInt64

    init(_ source: MCPLaunchFileIdentity) {
        canonicalPath = source.canonicalPath
        deviceID = source.deviceID
        fileID = source.fileID
        byteCount = source.byteCount
    }
}

/// Compiles the process-creation half of a local stdio authority.
///
/// Filesystem/network confinement alone cannot prove which image a server
/// executes next. macOS therefore grants exactly one exec transition, from
/// the root-owned `sandbox-exec` wrapper to the primary image, and denies
/// process creation. Linux requires both bwrap and a ptrace+seccomp guard:
/// seccomp prevents group/namespace escape and default child creation, while
/// ptrace validates every successful exec stop before the new image runs.
/// Exact-network pointer arguments are inspected only after PTRACE_INTERRUPT
/// freezes every generation tracee. `connect` itself uses a pidfd-duplicated
/// socket plus a host-owned exact sockaddr; the tracee syscall is skipped and
/// receives the emulated result, so pointer mutation cannot redirect it.
enum MCPStdioExecutionGuard {
    static func compile(
        ticket: MCPAuthorizedStdioLaunchTicket
    ) throws -> MCPStdioExecutionGuardPlan {
        try verifyExactLaunchClosure(ticket)
        let allHelperFiles =
            ticket.request.configuration.helperArtifacts
                .flatMap(\.files)
        let helpers = allHelperFiles.filter {
            $0.role == .helper
        }
        guard helpers.count == allHelperFiles.count,
              Set(helpers.map(\.canonicalPath)).count
                == helpers.count,
              Set(ticket.request.configuration.launchArtifact.files
                    .map(\.canonicalPath))
                .isDisjoint(with:
                    Set(helpers.map(\.canonicalPath))) else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        #if os(macOS)
        // Seatbelt has no public, host-usable primitive that both permits a
        // helper fork and proves the child cannot call setsid before exec.
        // Never silently weaken descendant cleanup for helper authorities.
        guard ticket.request.configuration.helperArtifacts.isEmpty else {
            throw MCPManagedPipeError
                .descendantExecutionGuardUnavailable
        }
        return .macOSInitialExecOnly
        #elseif os(Linux)
        guard intatis_mcp_stdio_execution_guard_probe() == 1 else {
            throw MCPManagedPipeError
                .descendantExecutionGuardUnavailable
        }
        guard let executable =
                ticket.request.configuration.launchArtifact.files.first(
                    where: { $0.role == .executable })
        else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        return .linuxPtraceSeccomp(
            primary: MCPStdioExecutableIdentity(executable),
            helpers: helpers.map(MCPStdioExecutableIdentity.init))
        #else
        throw MCPManagedPipeError.localStdioUnsupported
        #endif
    }

    /// Repeats the complete content/metadata/no-follow verification after the
    /// sandbox plan has been prepared and immediately before process creation.
    /// Linux additionally checks the exec-stop inode against this same tuple.
    static func verifyImmediatelyBeforeSpawn(
        _ ticket: MCPAuthorizedStdioLaunchTicket
    ) throws {
        try verifyExactLaunchClosure(ticket)
    }

    #if os(macOS)
    static func macOSInitialExecRule(
        wrapperPath: String,
        executablePath: String
    ) -> String {
        """
        (with-filter
          (process-path "\(seatbeltLiteral(wrapperPath))")
          (allow process-exec
            (literal "\(seatbeltLiteral(executablePath))")))
        (deny process-fork)
        """
    }
    #endif

    static func linuxRequirementsSatisfied(
        bubblewrapAvailable: Bool,
        executionGuardAvailable: Bool
    ) -> Bool {
        bubblewrapAvailable && executionGuardAvailable
    }

    static func linuxKernelGuardAvailable() -> Bool {
        #if os(Linux)
        return intatis_mcp_stdio_execution_guard_probe() == 1
        #else
        return false
        #endif
    }

    private static func verifyExactLaunchClosure(
        _ ticket: MCPAuthorizedStdioLaunchTicket
    ) throws {
        try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(
            ticket.request.configuration.launchArtifact)
        for helper in ticket.request.configuration.helperArtifacts {
            try MCPLaunchArtifactIdentityVerifier.verifyBeforeLaunch(helper)
        }
    }

    private static func seatbeltLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
