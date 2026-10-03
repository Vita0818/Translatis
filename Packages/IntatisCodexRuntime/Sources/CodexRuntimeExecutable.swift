import Foundation
import IntatisCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum CodexRuntimeExecutable {
    /// The exact audited upstream release plus Intatis's request-owned
    /// Responses `provider` passthrough and strict-route shape patch set.
    public static let pinnedVersion = "0.145.0-intatis.4"
    /// Exact checked-in Rust patch identity. Runtime records bind this in
    /// addition to the human-readable version so two development builds with
    /// the same version string can never resume each other's thread state.
    public static let pinnedDerivationID =
        "0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285"

    public static func locate(
        override: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> URL {
        let hostIdentity = IntatisHostApplication.identity
        let requiresBundledRuntime =
            bundle.bundleIdentifier.map(
                hostIdentity.macOSBundleIdentifierCandidates.contains)
                ?? false
        if let override {
            guard !requiresBundledRuntime else {
                throw CodexRuntimeError.executableUnavailable
            }
            let normalized = override.standardizedFileURL
                .resolvingSymlinksInPath()
            guard fileManager.isExecutableFile(
                atPath: normalized.path) else {
                throw CodexRuntimeError.executableUnavailable
            }
            return normalized
        }
        if let configured = environment[
            hostIdentity.environmentVariable("CODEX_RUNTIME")]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !configured.isEmpty {
            guard !requiresBundledRuntime else {
                throw CodexRuntimeError.executableUnavailable
            }
            let normalized = URL(fileURLWithPath: configured)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard fileManager.isExecutableFile(
                atPath: normalized.path) else {
                throw CodexRuntimeError.executableUnavailable
            }
            return normalized
        }

        var candidates: [URL] = []
        #if arch(arm64)
        let bundledArchitecture: String? = "arm64"
        #elseif arch(x86_64)
        let bundledArchitecture: String? = "x86_64"
        #else
        let bundledArchitecture: String? = nil
        #endif
        if !requiresBundledRuntime,
           let bundled = bundle.url(forAuxiliaryExecutable: "codex") {
            candidates.append(bundled)
        }
        if let resources = bundle.resourceURL,
           let bundledArchitecture {
            let root = resources
                .appendingPathComponent("CodexRuntime", isDirectory: true)
                .appendingPathComponent(bundledArchitecture, isDirectory: true)
            let manifest = root.appendingPathComponent(
                "runtime-manifest.json",
                isDirectory: false)
            if !requiresBundledRuntime
                || fileManager.fileExists(atPath: manifest.path) {
                candidates.append(root.appendingPathComponent("codex"))
            }
        }

        if requiresBundledRuntime {
            for candidate in candidates {
                let normalized = candidate.standardizedFileURL
                    .resolvingSymlinksInPath()
                if fileManager.isExecutableFile(atPath: normalized.path) {
                    return normalized
                }
            }
            throw CodexRuntimeError.executableUnavailable
        }

        candidates.append(contentsOf: [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".local/bin/\(hostIdentity.fileNameStem)-codex"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ])
        for directory in (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true) {
            let directoryURL = URL(
                fileURLWithPath: String(directory),
                isDirectory: true)
            candidates.append(
                directoryURL.appendingPathComponent(
                    hostIdentity.fileNameStem + "-codex"))
            candidates.append(
                directoryURL.appendingPathComponent("codex"))
        }

        var seen: Set<String> = []
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL
                .resolvingSymlinksInPath()
            guard seen.insert(normalized.path).inserted,
                  fileManager.isExecutableFile(atPath: normalized.path) else {
                continue
            }
            return normalized
        }
        throw CodexRuntimeError.executableUnavailable
    }

    public static func verifiedVersion(
        at executableURL: URL,
        expectedVersion: String = pinnedVersion,
        expectedDerivationID: String = pinnedDerivationID
    ) throws -> String {
        try verifiedVersion(
            at: executableURL,
            expectedVersion: expectedVersion,
            expectedDerivationID: expectedDerivationID,
            timeoutSeconds: 5)
    }

    static func verifiedVersion(
        at executableURL: URL,
        expectedVersion: String,
        expectedDerivationID: String = pinnedDerivationID,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        guard timeoutSeconds.isFinite,
              timeoutSeconds > 0 else {
            throw CodexRuntimeError.requestTimedOut("codex --version")
        }
        let output = try executableOutput(
            at: executableURL,
            arguments: ["--version"],
            operation: "codex --version",
            timeoutSeconds: timeoutSeconds)

        let tokens = output
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let actual = tokens.last, !actual.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "the runtime did not report a version")
        }
        guard actual == expectedVersion else {
            throw CodexRuntimeError.incompatibleRuntime(
                expected: expectedVersion,
                actual: actual)
        }

        let derivationOutput = try executableOutput(
            at: executableURL,
            arguments: ["--intatis-derivation-id"],
            operation: "codex --intatis-derivation-id",
            timeoutSeconds: timeoutSeconds)
        let derivationTokens = derivationOutput
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard derivationTokens.count == 1,
              let actualDerivationID = derivationTokens.first,
              !actualDerivationID.isEmpty else {
            throw CodexRuntimeError.malformedProtocol(
                "the runtime did not report one derivation identity")
        }
        guard actualDerivationID == expectedDerivationID else {
            throw CodexRuntimeError.incompatibleRuntimeDerivation(
                expected: expectedDerivationID,
                actual: actualDerivationID)
        }
        return actual
    }

    private static func executableOutput(
        at executableURL: URL,
        arguments: [String],
        operation: String,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw CodexRuntimeError.processLaunchFailed(
                error.localizedDescription)
        }
        if !waitForExit(
            process,
            until: Date().addingTimeInterval(timeoutSeconds)) {
            process.terminate()
            if !waitForExit(
                process,
                until: Date().addingTimeInterval(0.25)) {
                forceTerminate(process)
                _ = waitForExit(
                    process,
                    until: Date().addingTimeInterval(1))
            }
            throw CodexRuntimeError.requestTimedOut(operation)
        }
        process.waitUntilExit()

        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        let diagnostic = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CodexRuntimeError.processTerminated(
                process.terminationStatus,
                boundedDiagnostic(diagnostic))
        }

        return output
    }

    private static func waitForExit(
        _ process: Process,
        until deadline: Date
    ) -> Bool {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private static func forceTerminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(pid, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(pid, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(pid, SIGKILL)
        #else
        process.terminate()
        #endif
    }

    static func boundedDiagnostic(_ value: String, limit: Int = 2_048) -> String {
        let normalized = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}
