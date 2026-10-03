import Foundation
import IntatisCore

#if canImport(AppKit)
import AppKit
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum CLIDiagnoseHangError: Error, LocalizedError, Equatable {
    case unsupportedPlatform
    case usage
    case invalidProcessIdentifier
    case targetNotRunning
    case targetNotOwnedByCurrentUser
    case targetIsNotIntatis
    case sampleFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "hang diagnosis is available only on macOS"
        case .usage:
            return "usage: \(IntatisHostApplication.identity.commandName) diagnose-hang --pid <pid> [--output <directory>]"
        case .invalidProcessIdentifier:
            return "the target process identifier is invalid"
        case .targetNotRunning:
            return "the target process is not running"
        case .targetNotOwnedByCurrentUser:
            return "the target process is not owned by the current user"
        case .targetIsNotIntatis:
            return "the target process is not the \(IntatisHostApplication.identity.name) macOS application"
        case .sampleFailed:
            return "the hang bundle was saved, but macOS sample capture failed"
        }
    }
}

struct CLIDiagnoseHangOptions: Equatable {
    let processIdentifier: Int32
    let outputParentURL: URL?

    static func parse(
        _ arguments: ArraySlice<String>,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
    ) throws -> Self {
        let values = Array(arguments)
        var processIdentifier: Int32?
        var outputParentURL: URL?
        var index = 0
        while index < values.count {
            switch values[index] {
            case "--pid":
                guard processIdentifier == nil,
                      values.indices.contains(index + 1),
                      let parsed = Int32(values[index + 1]),
                      parsed > 1 else {
                    throw CLIDiagnoseHangError.invalidProcessIdentifier
                }
                processIdentifier = parsed
                index += 2
            case "--output":
                guard outputParentURL == nil,
                      values.indices.contains(index + 1),
                      !values[index + 1].isEmpty else {
                    throw CLIDiagnoseHangError.usage
                }
                let raw = values[index + 1]
                let url: URL
                if raw.hasPrefix("/") {
                    url = URL(fileURLWithPath: raw, isDirectory: true)
                } else {
                    url = currentDirectoryURL.appendingPathComponent(
                        raw,
                        isDirectory: true)
                }
                outputParentURL = url.standardizedFileURL
                index += 2
            default:
                throw CLIDiagnoseHangError.usage
            }
        }
        guard let processIdentifier else {
            throw CLIDiagnoseHangError.usage
        }
        return Self(
            processIdentifier: processIdentifier,
            outputParentURL: outputParentURL)
    }
}

struct CLIIntatisProcessIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let ownerUserIdentifier: UInt32
    let executableName: String
    let bundleIdentifier: String?
}

protocol CLIIntatisProcessInspecting: Sendable {
    func inspect(processIdentifier: Int32) throws -> CLIIntatisProcessIdentity
}

enum CLIIntatisProcessValidator {
    static func validate(
        _ identity: CLIIntatisProcessIdentity,
        currentUserIdentifier: UInt32
    ) throws {
        guard identity.ownerUserIdentifier == currentUserIdentifier else {
            throw CLIDiagnoseHangError.targetNotOwnedByCurrentUser
        }
        let hostIdentity = IntatisHostApplication.identity
        guard hostIdentity.macOSProcessNameCandidates.contains(
                identity.executableName),
              let bundleIdentifier = identity.bundleIdentifier,
              hostIdentity.macOSBundleIdentifierCandidates.contains(
                bundleIdentifier) else {
            throw CLIDiagnoseHangError.targetIsNotIntatis
        }
    }
}

struct CLIHangCaptureExecution: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool

    var succeeded: Bool {
        terminationStatus == 0 && !timedOut
    }
}

protocol CLIHangCaptureRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> CLIHangCaptureExecution
}

struct CLIHangCaptureReport: Equatable, Sendable {
    let bundleDisplayName: String
    let sampleSucceeded: Bool
    let unifiedLogSucceeded: Bool
}

func runDiagnoseHangCommand(
    _ arguments: ArraySlice<String>
) async throws {
    let options = try CLIDiagnoseHangOptions.parse(arguments)
    #if os(macOS)
    let report = try await captureIntatisHang(
        options: options,
        inspector: CLIMacIntatisProcessInspector(),
        runner: CLIProcessHangCaptureRunner())
    out("Hang bundle saved: \(report.bundleDisplayName)\n")
    out("sample: \(report.sampleSucceeded ? "captured" : "failed") · unified log: \(report.unifiedLogSucceeded ? "captured" : "failed")\n")
    if !report.sampleSucceeded {
        throw CLIDiagnoseHangError.sampleFailed
    }
    #else
    _ = options
    throw CLIDiagnoseHangError.unsupportedPlatform
    #endif
}

func captureIntatisHang(
    options: CLIDiagnoseHangOptions,
    inspector: any CLIIntatisProcessInspecting,
    runner: any CLIHangCaptureRunning,
    now: Date = Date(),
    currentUserIdentifier: UInt32 = currentEffectiveUserIdentifier(),
    defaultRootURL: URL? = nil
) async throws -> CLIHangCaptureReport {
    let identity = try inspector.inspect(
        processIdentifier: options.processIdentifier)
    try CLIIntatisProcessValidator.validate(
        identity,
        currentUserIdentifier: currentUserIdentifier)

    let resolvedDefaultRoot: URL
    if let defaultRootURL {
        resolvedDefaultRoot = defaultRootURL
    } else {
        resolvedDefaultRoot =
            try IntatisHangDiagnosticBundleStore.defaultRootURL()
    }
    let recentStore = IntatisHangDiagnosticBundleStore(
        rootURL: resolvedDefaultRoot)
    let recentIncident = try? await recentStore.latestManifest(
        processIdentifier: options.processIdentifier,
        recordedAfter: now.addingTimeInterval(-300))

    let sample = runHangCapture(
        runner: runner,
        executableURL: URL(fileURLWithPath: "/usr/bin/sample"),
        arguments: [
            String(options.processIdentifier),
            "10",
            "1",
        ],
        timeoutSeconds: 15)
    let unifiedLog = runHangCapture(
        runner: runner,
        executableURL: URL(fileURLWithPath: "/usr/bin/log"),
        arguments: [
            "show",
            "--last",
            "5m",
            "--style",
            "compact",
            "--predicate",
            "processIdentifier == \(options.processIdentifier) AND subsystem == \"\(IntatisDiagnosticConstants.subsystem)\"",
        ],
        timeoutSeconds: 15)

    let outputRoot: URL
    if let outputParentURL = options.outputParentURL {
        outputRoot = outputParentURL.appendingPathComponent(
            IntatisHostApplication.identity.storageName
                + "-HangDiagnostics",
            isDirectory: true)
    } else {
        outputRoot = resolvedDefaultRoot
    }
    let store = IntatisHangDiagnosticBundleStore(rootURL: outputRoot)
    let sensitivePaths = [
        outputRoot.path,
        options.outputParentURL?.path,
    ].compactMap { $0 }
    var attachments: [IntatisHangDiagnosticAttachment] = []
    if !sample.standardOutput.isEmpty {
        attachments.append(.sanitizedText(
            kind: .sample,
            rawData: sample.standardOutput,
            sensitivePaths: sensitivePaths))
    }
    if !unifiedLog.standardOutput.isEmpty {
        attachments.append(.sanitizedText(
            kind: .unifiedLog,
            rawData: unifiedLog.standardOutput,
            sensitivePaths: sensitivePaths))
    }

    let errors = captureErrorSummary(
        sample: sample,
        unifiedLog: unifiedLog)
    if !errors.isEmpty {
        attachments.append(.sanitizedText(
            kind: .captureErrors,
            rawData: Data(errors.utf8),
            sensitivePaths: sensitivePaths,
            maximumBytes: 256 * 1_024))
    }

    let manifest = IntatisHangDiagnosticManifest(
        source: .externalCapture,
        recordedAt: now,
        processIdentifier: options.processIdentifier,
        mainThreadDelayMilliseconds:
            recentIncident?.mainThreadDelayMilliseconds,
        applicationVersion: recentIncident?.applicationVersion,
        buildVersion: recentIncident?.buildVersion,
        metrics: recentIncident?.metrics,
        capture: .init(
            sampleSucceeded: sample.succeeded,
            unifiedLogSucceeded: unifiedLog.succeeded,
            relatedHeartbeatIncidentFound: recentIncident != nil))
    let location = try await store.writeBundle(
        manifest: manifest,
        attachments: attachments)
    return CLIHangCaptureReport(
        bundleDisplayName: location.displayName,
        sampleSucceeded: sample.succeeded,
        unifiedLogSucceeded: unifiedLog.succeeded)
}

private func runHangCapture(
    runner: any CLIHangCaptureRunning,
    executableURL: URL,
    arguments: [String],
    timeoutSeconds: TimeInterval
) -> CLIHangCaptureExecution {
    do {
        return try runner.run(
            executableURL: executableURL,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds)
    } catch {
        return CLIHangCaptureExecution(
            terminationStatus: 126,
            standardOutput: Data(),
            standardError: Data(
                "capture launch failed: \(error.localizedDescription)".utf8),
            timedOut: false)
    }
}

private func captureErrorSummary(
    sample: CLIHangCaptureExecution,
    unifiedLog: CLIHangCaptureExecution
) -> String {
    var lines: [String] = []
    if !sample.succeeded {
        lines.append(
            "sample status=\(sample.terminationStatus) timeout=\(sample.timedOut)")
        if !sample.standardError.isEmpty {
            lines.append(String(
                decoding: sample.standardError.prefix(64 * 1_024),
                as: UTF8.self))
        }
    }
    if !unifiedLog.succeeded {
        lines.append(
            "unified-log status=\(unifiedLog.terminationStatus) timeout=\(unifiedLog.timedOut)")
        if !unifiedLog.standardError.isEmpty {
            lines.append(String(
                decoding: unifiedLog.standardError.prefix(64 * 1_024),
                as: UTF8.self))
        }
    }
    return lines.joined(separator: "\n")
}

func currentEffectiveUserIdentifier() -> UInt32 {
    #if canImport(Darwin)
    return UInt32(Darwin.geteuid())
    #elseif canImport(Glibc)
    return UInt32(Glibc.geteuid())
    #elseif canImport(Musl)
    return UInt32(Musl.geteuid())
    #else
    return 0
    #endif
}

#if os(macOS)
private struct CLIMacIntatisProcessInspector: CLIIntatisProcessInspecting {
    func inspect(
        processIdentifier: Int32
    ) throws -> CLIIntatisProcessIdentity {
        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier),
              !application.isTerminated else {
            throw CLIDiagnoseHangError.targetNotRunning
        }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize))
        guard result == expectedSize else {
            throw CLIDiagnoseHangError.targetNotRunning
        }
        return CLIIntatisProcessIdentity(
            processIdentifier: processIdentifier,
            ownerUserIdentifier: info.pbi_uid,
            executableName:
                application.executableURL?.lastPathComponent ?? "",
            bundleIdentifier: application.bundleIdentifier)
    }
}
#endif

private final class CLIProcessHangCaptureRunner:
    CLIHangCaptureRunning, @unchecked Sendable
{
    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> CLIHangCaptureExecution {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = CLIBoundedPipeCollector(
            maximumBytes: 10 * 1_024 * 1_024)
        let errorCollector = CLIBoundedPipeCollector(
            maximumBytes: 512 * 1_024)
        outputCollector.attach(to: outputPipe.fileHandleForReading)
        errorCollector.attach(to: errorPipe.fileHandleForReading)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }
        do {
            try process.run()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            outputCollector.cancel()
            errorCollector.cancel()
            throw error
        }

        let timeout = max(1, min(timeoutSeconds, 30))
        let timedOut = terminated.wait(
            timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut,
               process.isRunning {
                _ = killCaptureProcess(process.processIdentifier)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }

        if process.isRunning {
            outputCollector.cancel()
            errorCollector.cancel()
        } else {
            outputCollector.finish()
            errorCollector.finish()
        }
        return CLIHangCaptureExecution(
            terminationStatus:
                process.isRunning ? 124 : process.terminationStatus,
            standardOutput: outputCollector.data,
            standardError: errorCollector.data,
            timedOut: timedOut)
    }
}

@discardableResult
private func killCaptureProcess(_ processIdentifier: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.kill(processIdentifier, SIGKILL)
    #elseif canImport(Glibc)
    return Glibc.kill(processIdentifier, SIGKILL)
    #elseif canImport(Musl)
    return Musl.kill(processIdentifier, SIGKILL)
    #else
    return -1
    #endif
}

private final class CLIBoundedPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var collected = Data()
    private weak var handle: FileHandle?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func attach(to handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            let available = readable.availableData
            guard !available.isEmpty else { return }
            self?.append(available)
        }
    }

    func finish() {
        guard let handle else { return }
        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            append(remaining)
        }
        try? handle.close()
    }

    func cancel() {
        guard let handle else { return }
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard collected.count < maximumBytes else { return }
        collected.append(
            data.prefix(maximumBytes - collected.count))
    }
}
