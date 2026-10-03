// Validation-only macOS process watchdog for the Translatis renderer fixture.
//
// Build (does not launch any app):
//   xcrun swiftc -O -module-cache-path /private/tmp/translatis-renderer-watchdog-module-cache \
//     scripts/RendererValidationWatchdog.swift \
//     -o /private/tmp/translatis-renderer-validation-watchdog
//
// The `run` command intentionally accepts a Translatis validation app plus a
// closed set of fixture options. It is not a general-purpose process runner.

#if os(macOS)
import CryptoKit
import Darwin
import Foundation

private let mib: UInt64 = 1_048_576
private let watchdogLockPath = "/private/tmp/com.Vita0818.Translatis.renderer-validation-watchdog.lock"
private let expectedBundleIdentifier = "com.Vita0818.TranslatisMac"
private let expectedFixtureSHA256 = "fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1"
private let validationExecutableMarker = Data("Translatis renderer fixture".utf8)

private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private enum WatchdogFailure: Error, CustomStringConvertible {
    case usage(String)
    case preflight(String)
    case launch(String)
    case telemetry(String)
    case evidence(String)

    var description: String {
        switch self {
        case .usage(let message), .preflight(let message), .launch(let message),
             .telemetry(let message), .evidence(let message):
            return message
        }
    }
}

private enum Outcome: String, Codable {
    case passed
    case wallLimit = "wall_limit"
    case rssLimit = "rss_limit"
    case footprintLimit = "footprint_limit"
    case memoryPlateauLimit = "memory_plateau_limit"
    case rollingCPULimit = "rolling_cpu_limit"
    case absoluteCPULimit = "absolute_cpu_limit"
    case instanceLimit = "instance_limit"
    case telemetryFailure = "telemetry_failure"
    case fixtureContractFailure = "fixture_contract_failure"
    case runtimeLogFailure = "runtime_log_failure"
    case unexpectedExit = "unexpected_exit"
    case interrupted
    case cleanupFailure = "cleanup_failure"
}

private struct Limits: Encodable {
    let observationSeconds: Double
    let hardWallSeconds: Double
    let rssBytes: UInt64
    let footprintBytes: UInt64
    let rollingCPUPercent: Double
    let rollingCPUWindowSeconds: Double
    let cpuGraceSeconds: Double
    let absoluteCPUSeconds: Double
    let termGraceSeconds: Double
    let killGraceSeconds: Double
    let minimumExpectedRuntimeSeconds: Double
    let plateauWarmupSeconds: Double?
    let plateauWindowSeconds: Double?
    let maximumRSSGrowthBytes: UInt64?
    let maximumFootprintGrowthBytes: UInt64?

    init(
        observationSeconds: Double,
        hardWallSeconds: Double,
        rssBytes: UInt64,
        footprintBytes: UInt64,
        rollingCPUPercent: Double,
        rollingCPUWindowSeconds: Double,
        cpuGraceSeconds: Double,
        absoluteCPUSeconds: Double,
        termGraceSeconds: Double,
        killGraceSeconds: Double,
        minimumExpectedRuntimeSeconds: Double,
        plateauWarmupSeconds: Double? = nil,
        plateauWindowSeconds: Double? = nil,
        maximumRSSGrowthBytes: UInt64? = nil,
        maximumFootprintGrowthBytes: UInt64? = nil
    ) {
        self.observationSeconds = observationSeconds
        self.hardWallSeconds = hardWallSeconds
        self.rssBytes = rssBytes
        self.footprintBytes = footprintBytes
        self.rollingCPUPercent = rollingCPUPercent
        self.rollingCPUWindowSeconds = rollingCPUWindowSeconds
        self.cpuGraceSeconds = cpuGraceSeconds
        self.absoluteCPUSeconds = absoluteCPUSeconds
        self.termGraceSeconds = termGraceSeconds
        self.killGraceSeconds = killGraceSeconds
        self.minimumExpectedRuntimeSeconds = minimumExpectedRuntimeSeconds
        self.plateauWarmupSeconds = plateauWarmupSeconds
        self.plateauWindowSeconds = plateauWindowSeconds
        self.maximumRSSGrowthBytes = maximumRSSGrowthBytes
        self.maximumFootprintGrowthBytes = maximumFootprintGrowthBytes
    }
}

private enum ContainmentProfile: String, Encodable {
    case minimal
    case isolation
    case computerUse = "computer-use"
    case replaySmoke = "replay-smoke"
    case soak

    var limits: Limits {
        switch self {
        case .minimal:
            return Limits(
                observationSeconds: 15,
                hardWallSeconds: 20,
                rssBytes: 256 * mib,
                footprintBytes: 256 * mib,
                rollingCPUPercent: 80,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 12,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 12)
        case .isolation:
            return Limits(
                observationSeconds: 20,
                hardWallSeconds: 25,
                rssBytes: 384 * mib,
                footprintBytes: 384 * mib,
                rollingCPUPercent: 150,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 30,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 16)
        case .computerUse:
            return Limits(
                observationSeconds: 45,
                hardWallSeconds: 50,
                rssBytes: 384 * mib,
                footprintBytes: 384 * mib,
                rollingCPUPercent: 150,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 60,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 36)
        case .replaySmoke:
            return Limits(
                observationSeconds: 30,
                hardWallSeconds: 35,
                rssBytes: 512 * mib,
                footprintBytes: 512 * mib,
                rollingCPUPercent: 200,
                rollingCPUWindowSeconds: 3,
                cpuGraceSeconds: 2,
                absoluteCPUSeconds: 50,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 24)
        case .soak:
            return Limits(
                observationSeconds: 180,
                hardWallSeconds: 188,
                rssBytes: 768 * mib,
                footprintBytes: 768 * mib,
                rollingCPUPercent: 300,
                rollingCPUWindowSeconds: 5,
                cpuGraceSeconds: 5,
                absoluteCPUSeconds: 480,
                termGraceSeconds: 0.5,
                killGraceSeconds: 2,
                minimumExpectedRuntimeSeconds: 170,
                plateauWarmupSeconds: 60,
                plateauWindowSeconds: 30,
                maximumRSSGrowthBytes: 64 * mib,
                maximumFootprintGrowthBytes: 64 * mib)
        }
    }
}

private enum FixtureStage: String, Encodable {
    case minimal
    case table
    case codeSelection = "code-selection"
    case mathOne = "math-one"
    case mathThirtyTwo = "math-thirty-two"
    case mathStructure = "math-structure"
    case mathHistory = "math-history"
    case mathStream = "math-stream"
    case streamReplacement = "stream-replacement"
    case incidentReplay = "incident-replay"
    case heartbeatStall = "heartbeat-stall"
    case threadBurst = "thread-burst"
    case fullStatic = "full-static"

    func accepts(_ profile: ContainmentProfile) -> Bool {
        switch (self, profile) {
        case (.minimal, .minimal): true
        case (.table, .isolation), (.codeSelection, .isolation),
             (.mathOne, .isolation), (.mathThirtyTwo, .isolation),
             (.mathStructure, .isolation), (.mathHistory, .isolation),
             (.mathStream, .isolation),
             (.streamReplacement, .isolation),
             (.heartbeatStall, .isolation),
             (.fullStatic, .isolation): true
        case (.mathOne, .computerUse), (.mathThirtyTwo, .computerUse),
             (.mathStructure, .computerUse), (.mathHistory, .computerUse),
             (.mathStream, .computerUse): true
        case (.incidentReplay, .replaySmoke): true
        case (.threadBurst, .soak): true
        default: false
        }
    }

    var requiresMachineResult: Bool {
        self == .threadBurst || self == .heartbeatStall
    }

    var minimumCompletedCycles: UInt64 {
        self == .threadBurst ? 20 : 0
    }
}

private enum RendererMode: String, Encodable {
    case microsoft
    case plainSafe

    var launchArgument: String {
        switch self {
        case .microsoft: "-IntatisMicrosoftMarkdownMessages"
        case .plainSafe: "-IntatisPlainSafeMessages"
        }
    }
}

private enum MathMode: String, Encodable {
    case disabled
    case singleDollar = "single-dollar"

    var launchArgument: String? {
        switch self {
        case .disabled: "-IntatisDisableSingleDollarMath"
        case .singleDollar: nil
        }
    }
}

private enum Appearance: String, Encodable {
    case light
    case dark

    var launchArgument: String {
        switch self {
        case .light: "-TranslatisAppearanceLight"
        case .dark: "-TranslatisAppearanceDark"
        }
    }
}

private struct RunConfiguration {
    let appPath: String
    let expectedAppSHA256: String
    let fixturePath: String
    let outputPath: String
    let stage: FixtureStage
    let renderer: RendererMode
    let mathMode: MathMode
    let appearance: Appearance
    let profile: ContainmentProfile
}

private struct ProcessIdentity: Encodable {
    let pid: Int32
    let name: String
    let path: String?
    let startSeconds: UInt64?
    let startMicroseconds: UInt64?
}

private struct GroupMetrics {
    let pids: [Int32]
    let rssBytes: UInt64
    let footprintBytes: UInt64
    let cpuNanoseconds: UInt64
}

private struct SampleRecord: Encodable {
    let schema = "translatis.renderer-watchdog.sample.v1"
    let sequence: Int
    let elapsedSeconds: Double
    let processGroupID: Int32
    let pids: [Int32]
    let rssBytes: UInt64
    let footprintBytes: UInt64
    let totalCPUNanoseconds: UInt64
    let rollingCPUPercent: Double?
}

private struct EventRecord: Encodable {
    let schema = "translatis.renderer-watchdog.event.v1"
    let sequence: Int
    let elapsedSeconds: Double
    let kind: String
    let detail: String
}

private struct Manifest: Encodable {
    let schema = "translatis.renderer-watchdog.manifest.v4"
    let createdAt: String
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let appPath: String
    let executablePath: String
    let executableSHA256: String
    let bundleIdentifier: String
    let bundleVersion: String
    let fixturePath: String
    let fixtureSHA256: String
    let stage: FixtureStage
    let renderer: RendererMode
    let mathMode: MathMode
    let appearance: Appearance
    let profile: ContainmentProfile
    let limits: Limits
    let containmentOnly: Bool
    let memoryPlateauRequired: Bool
    let fixtureResultRequired: Bool
    let minimumCompletedCycles: UInt64
}

private struct ResultRecord: Encodable {
    let schema = "translatis.renderer-watchdog.result.v1"
    var outcome: Outcome
    var detail: String
    let elapsedSeconds: Double
    let childPID: Int32
    let processGroupID: Int32
    let childExitCode: Int32?
    let childTerminationSignal: Int32?
    let peakRSSBytes: UInt64
    let peakFootprintBytes: UInt64
    let peakRollingCPUPercent: Double
    let memoryPlateau: MemoryPlateauRecord?
    let usedSIGTERM: Bool
    let usedSIGKILL: Bool
    let residualGroupPIDs: [Int32]
    let residualRendererProcesses: [ProcessIdentity]
    let cleanupVerifiedTwice: Bool
    var fixtureResult: FixtureMachineResult? = nil
    var runtimeLogAudit: RuntimeLogAuditRecord? = nil

    var passed: Bool { outcome == .passed }
}

private struct RuntimeLogAuditRecord: Encodable {
    let schema = "translatis.renderer-watchdog.runtime-log-audit.v1"
    let startedAt: String
    let endedAt: String
    let swiftUIMultipleUpdatesPerFrameCount: Int
    let mainThreadIncidentCount: Int
    let appKitInvalidGeometryCount: Int
}

private struct FixtureMachineResult: Codable {
    static let currentSchema =
        "translatis.renderer-fixture.result.v1"

    let schema: String
    let stage: String
    let state: String
    let processID: Int32
    let sequence: UInt64
    let finalized: Bool
    let completedCycles: UInt64
    let exactDeltaCount: UInt64
    let exactMessageCount: UInt64
    let sessionSwitchCount: UInt64
    let heartbeatBlockCount: UInt64
    let heartbeatBlockDurationNanoseconds: UInt64
    let failureCode: UInt64
}

private struct MemoryPlateauRecord: Encodable {
    let baselineStartSeconds: Double
    let baselineEndSeconds: Double
    let tailStartSeconds: Double
    let tailEndSeconds: Double
    let baselineRSSBytes: UInt64
    let tailRSSBytes: UInt64
    let rssGrowthBytes: Int64
    let baselineFootprintBytes: UInt64
    let tailFootprintBytes: UInt64
    let footprintGrowthBytes: Int64
    let maximumRSSGrowthBytes: UInt64
    let maximumFootprintGrowthBytes: UInt64
    let passed: Bool
}

private final class AdvisoryLock {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchdogFailure.preflight("cannot open owner-only watchdog lock: errno \(errno)")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            throw WatchdogFailure.preflight("cannot secure watchdog lock permissions: errno \(errno)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw WatchdogFailure.preflight("another renderer watchdog already owns the validation lock")
        }
        _ = ftruncate(descriptor, 0)
        let owner = "pid=\(getpid())\n"
        owner.withCString { pointer in
            _ = write(descriptor, pointer, strlen(pointer))
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private final class EvidenceWriter {
    let outputURL: URL
    private let eventHandle: FileHandle
    private let sampleHandle: FileHandle
    private let encoder: JSONEncoder
    private var eventSequence = 0

    init(outputPath: String) throws {
        let fileManager = FileManager.default
        outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw WatchdogFailure.preflight("refusing to reuse existing evidence directory: \(outputURL.path)")
        }
        do {
            try fileManager.createDirectory(
                at: outputURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputURL.path)
        } catch {
            throw WatchdogFailure.evidence("cannot create evidence directory: \(error.localizedDescription)")
        }

        eventHandle = try Self.createFile(at: outputURL.appendingPathComponent("events.jsonl"))
        sampleHandle = try Self.createFile(at: outputURL.appendingPathComponent("samples.jsonl"))
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        try? eventHandle.close()
        try? sampleHandle.close()
    }

    func writeManifest(_ manifest: Manifest) throws {
        try writeJSON(manifest, fileName: "manifest.json")
    }

    func writeResult(_ result: ResultRecord) throws {
        try writeJSON(result, fileName: "result.json")
    }

    func event(kind: String, detail: String, elapsedSeconds: Double) throws {
        eventSequence += 1
        try append(
            EventRecord(
                sequence: eventSequence,
                elapsedSeconds: elapsedSeconds,
                kind: kind,
                detail: detail),
            to: eventHandle)
    }

    func sample(_ record: SampleRecord) throws {
        try append(record, to: sampleHandle)
    }

    func consoleFileDescriptor() throws -> Int32 {
        let path = outputURL.appendingPathComponent("app-console.log").path
        let descriptor = open(
            path,
            O_CREAT | O_EXCL | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchdogFailure.evidence("cannot create app-console.log: errno \(errno)")
        }
        return descriptor
    }

    private func writeJSON<T: Encodable>(_ value: T, fileName: String) throws {
        let url = outputURL.appendingPathComponent(fileName)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw WatchdogFailure.evidence("cannot write \(fileName): \(error.localizedDescription)")
        }
    }

    private func append<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        do {
            var data = try encoder.encode(value)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw WatchdogFailure.evidence("cannot append watchdog evidence: \(error.localizedDescription)")
        }
    }

    private static func createFile(at url: URL) throws -> FileHandle {
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw WatchdogFailure.evidence("cannot create \(url.lastPathComponent): errno \(errno)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

private struct SpawnedProcess {
    let pid: pid_t
    let processGroupID: pid_t
    let identity: ProcessIdentity
}

private struct MonitorSpecification {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let familyNames: Set<String>
    let excludedPIDs: Set<pid_t>
    let limits: Limits
    let maximumFamilyInstances: Int
    let injectedTelemetryFailureSample: Int?
}

private struct CPUPoint {
    let elapsedSeconds: Double
    let cpuNanoseconds: UInt64
}

private struct MemoryPoint {
    let elapsedSeconds: Double
    let rssBytes: UInt64
    let footprintBytes: UInt64
}

private struct CleanupResult {
    let usedSIGTERM: Bool
    let usedSIGKILL: Bool
    let residualGroupPIDs: [pid_t]
    let residualRendererProcesses: [ProcessIdentity]
    let verifiedTwice: Bool
}

private var receivedSignal: sig_atomic_t = 0

private func signalHandler(_ signalNumber: Int32) {
    receivedSignal = signalNumber
}

private func installSignalHandlers() {
    _ = signal(SIGINT, signalHandler)
    _ = signal(SIGTERM, signalHandler)
    _ = signal(SIGHUP, signalHandler)
}

private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

private func sha256(path: String) throws -> String {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    } catch {
        throw WatchdogFailure.preflight("cannot hash \(path): \(error.localizedDescription)")
    }
}

private func allPIDs() throws -> [pid_t] {
    let estimatedCount = proc_listallpids(nil, 0)
    guard estimatedCount >= 0 else {
        throw WatchdogFailure.telemetry("proc_listallpids size query failed: errno \(errno)")
    }
    var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
    let count = pids.withUnsafeMutableBytes { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    guard count >= 0 else {
        throw WatchdogFailure.telemetry("proc_listallpids failed: errno \(errno)")
    }
    return Array(pids.prefix(Int(count))).filter { $0 > 0 }
}

private func processPath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = buffer.withUnsafeMutableBytes { rawBuffer in
        proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
    }
    guard length > 0 else { return nil }
    return canonicalPath(String(cString: buffer))
}

private func processName(pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = buffer.withUnsafeMutableBytes { rawBuffer in
        proc_name(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
    }
    if length > 0 {
        return String(cString: buffer)
    }
    return processPath(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unavailable"
}

private func processStart(pid: pid_t) -> (UInt64, UInt64)? {
    var info = proc_bsdinfo()
    let copied = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            UnsafeMutableRawPointer(pointer),
            Int32(MemoryLayout<proc_bsdinfo>.size))
    }
    guard copied == MemoryLayout<proc_bsdinfo>.size else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
}

private func identity(pid: pid_t) -> ProcessIdentity {
    let start = processStart(pid: pid)
    return ProcessIdentity(
        pid: pid,
        name: processName(pid: pid),
        path: processPath(pid: pid),
        startSeconds: start?.0,
        startMicroseconds: start?.1)
}

private func isFamilyMember(_ identity: ProcessIdentity, familyNames: Set<String>) -> Bool {
    let pathName = identity.path.map { URL(fileURLWithPath: $0).lastPathComponent }
    let candidates = [identity.name, pathName].compactMap { $0 }
    return candidates.contains { candidate in
        familyNames.contains(candidate)
            || candidate.hasPrefix("TranslatisRendererValidation")
            || candidate.hasPrefix("TranslatisRenderer")
    }
}

private func rendererProcesses(
    familyNames: Set<String>,
    excluding excludedPIDs: Set<pid_t>
) throws -> [ProcessIdentity] {
    try allPIDs()
        .filter { !excludedPIDs.contains($0) }
        .map(identity(pid:))
        .filter { isFamilyMember($0, familyNames: familyNames) }
        .sorted { $0.pid < $1.pid }
}

private func groupPIDs(_ processGroupID: pid_t) throws -> [pid_t] {
    let estimatedCount = proc_listpgrppids(processGroupID, nil, 0)
    guard estimatedCount >= 0 else {
        throw WatchdogFailure.telemetry("proc_listpgrppids size query failed: errno \(errno)")
    }
    guard estimatedCount > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 16)
    let count = pids.withUnsafeMutableBytes { buffer in
        proc_listpgrppids(processGroupID, buffer.baseAddress, Int32(buffer.count))
    }
    guard count >= 0 else {
        throw WatchdogFailure.telemetry("proc_listpgrppids failed: errno \(errno)")
    }
    return Array(pids.prefix(Int(count))).filter { $0 > 0 }
}

private func groupMetrics(_ processGroupID: pid_t) throws -> GroupMetrics {
    let pids = try groupPIDs(processGroupID)
    var rss: UInt64 = 0
    var footprint: UInt64 = 0
    var cpu: UInt64 = 0
    var sampledPIDs: [pid_t] = []

    for pid in pids {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            // Darwin imports `rusage_info_t *` as a pointer to an optional raw
            // pointer even though the API writes the selected rusage struct
            // directly into the supplied storage. Rebind the struct storage;
            // passing `&rawPointer` would give libproc only one pointer-sized
            // stack slot and corrupt the caller's stack.
            UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                .withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
        }
        if result != 0 {
            if kill(pid, 0) != 0, errno == ESRCH {
                continue
            }
            throw WatchdogFailure.telemetry("proc_pid_rusage failed for live pid \(pid): errno \(errno)")
        }
        sampledPIDs.append(pid)
        rss = rss.addingReportingOverflow(usage.ri_resident_size).partialValue
        footprint = footprint.addingReportingOverflow(usage.ri_phys_footprint).partialValue
        // proc_pid_rusage reports CPU in Mach absolute-time ticks on macOS.
        // Convert before applying limits or labeling the evidence as ns.
        let processCPUTicks = usage.ri_user_time
            .addingReportingOverflow(usage.ri_system_time).partialValue
        let processCPU = processCPUTicks
            .multipliedReportingOverflow(by: UInt64(machTimebase.numer)).partialValue
            / UInt64(machTimebase.denom)
        cpu = cpu.addingReportingOverflow(processCPU).partialValue
    }

    return GroupMetrics(
        pids: sampledPIDs.sorted(),
        rssBytes: rss,
        footprintBytes: footprint,
        cpuNanoseconds: cpu)
}

private func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> R
) rethrows -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return try pointers.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

private func spawnSuspended(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    consoleDescriptor: Int32
) throws -> SpawnedProcess {
    var attributes: posix_spawnattr_t?
    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0,
          posix_spawn_file_actions_init(&fileActions) == 0
    else {
        throw WatchdogFailure.launch("cannot initialize posix_spawn state")
    }
    defer {
        _ = posix_spawnattr_destroy(&attributes)
        _ = posix_spawn_file_actions_destroy(&fileActions)
    }

    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
        throw WatchdogFailure.launch("cannot configure suspended process group")
    }

    let nullDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard nullDescriptor >= 0 else {
        throw WatchdogFailure.launch("cannot open /dev/null: errno \(errno)")
    }
    defer { close(nullDescriptor) }

    guard posix_spawn_file_actions_adddup2(&fileActions, nullDescriptor, STDIN_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&fileActions, consoleDescriptor, STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&fileActions, consoleDescriptor, STDERR_FILENO) == 0
    else {
        throw WatchdogFailure.launch("cannot configure child standard streams")
    }

    let argumentStrings = [executablePath] + arguments
    let environmentStrings = environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    var childPID: pid_t = 0
    let spawnStatus = withCStringArray(argumentStrings) { argumentPointers in
        withCStringArray(environmentStrings) { environmentPointers in
            executablePath.withCString { executablePointer in
                posix_spawn(
                    &childPID,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers)
            }
        }
    }
    guard spawnStatus == 0 else {
        throw WatchdogFailure.launch("posix_spawn failed: errno \(spawnStatus)")
    }

    let processGroupID = getpgid(childPID)
    guard processGroupID == childPID else {
        _ = kill(childPID, SIGKILL)
        throw WatchdogFailure.launch(
            "child did not receive an isolated process group (pid \(childPID), pgid \(processGroupID))")
    }
    let childIdentity = identity(pid: childPID)
    guard childIdentity.path == canonicalPath(executablePath),
          childIdentity.startSeconds != nil
    else {
        _ = killpg(processGroupID, SIGKILL)
        throw WatchdogFailure.launch("cannot prove suspended child path/start identity")
    }
    return SpawnedProcess(pid: childPID, processGroupID: processGroupID, identity: childIdentity)
}

private func decodeWaitStatus(_ status: Int32) -> (exitCode: Int32?, signal: Int32?) {
    let signalNumber = status & 0x7f
    if signalNumber == 0 {
        return ((status >> 8) & 0xff, nil)
    }
    if signalNumber != 0x7f {
        return (nil, signalNumber)
    }
    return (nil, nil)
}

private func reapIfExited(_ pid: pid_t) -> (didExit: Bool, status: Int32) {
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    return (result == pid, status)
}

/// Covers the narrow normal-exit race where the first nonblocking `waitpid`
/// observes a live child, but libproc can no longer resolve that child a few
/// microseconds later. Only an exact reap of this watchdog's own PID can turn
/// the telemetry failure into a terminal child result. A live child, PID reuse,
/// or persistent telemetry failure therefore still fails closed.
private func reapIfExitedAfterTelemetryFailure(
    _ pid: pid_t,
    maximumAttempts: Int = 26,
    retryMicroseconds: useconds_t = 10_000,
    reap: (pid_t) -> (didExit: Bool, status: Int32) = reapIfExited
) -> (didExit: Bool, status: Int32) {
    let attempts = max(1, min(maximumAttempts, 26))
    for attempt in 0..<attempts {
        let observation = reap(pid)
        if observation.didExit {
            return observation
        }
        if attempt + 1 < attempts, retryMicroseconds > 0 {
            usleep(retryMicroseconds)
        }
    }
    return (false, 0)
}

private func monotonicSeconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

private func average(_ values: [UInt64]) -> UInt64? {
    guard !values.isEmpty else { return nil }
    let total = values.reduce(0.0) { $0 + Double($1) }
    return UInt64(total / Double(values.count))
}

private func memoryPlateau(
    points: [MemoryPoint],
    elapsedSeconds: Double,
    limits: Limits
) -> MemoryPlateauRecord? {
    guard let warmup = limits.plateauWarmupSeconds,
          let window = limits.plateauWindowSeconds,
          let maximumRSSGrowth = limits.maximumRSSGrowthBytes,
          let maximumFootprintGrowth = limits.maximumFootprintGrowthBytes,
          window > 0,
          elapsedSeconds >= warmup + (window * 2)
    else {
        return nil
    }

    let baselineStart = warmup
    let baselineEnd = warmup + window
    let tailEnd = elapsedSeconds
    let tailStart = tailEnd - window
    let baseline = points.filter {
        $0.elapsedSeconds >= baselineStart && $0.elapsedSeconds <= baselineEnd
    }
    let tail = points.filter {
        $0.elapsedSeconds >= tailStart && $0.elapsedSeconds <= tailEnd
    }
    guard let baselineRSS = average(baseline.map(\.rssBytes)),
          let tailRSS = average(tail.map(\.rssBytes)),
          let baselineFootprint = average(baseline.map(\.footprintBytes)),
          let tailFootprint = average(tail.map(\.footprintBytes))
    else {
        return nil
    }

    let rssGrowth = Int64(clamping: tailRSS) - Int64(clamping: baselineRSS)
    let footprintGrowth =
        Int64(clamping: tailFootprint) - Int64(clamping: baselineFootprint)
    let passed = rssGrowth <= Int64(clamping: maximumRSSGrowth)
        && footprintGrowth <= Int64(clamping: maximumFootprintGrowth)
    return MemoryPlateauRecord(
        baselineStartSeconds: baselineStart,
        baselineEndSeconds: baselineEnd,
        tailStartSeconds: tailStart,
        tailEndSeconds: tailEnd,
        baselineRSSBytes: baselineRSS,
        tailRSSBytes: tailRSS,
        rssGrowthBytes: rssGrowth,
        baselineFootprintBytes: baselineFootprint,
        tailFootprintBytes: tailFootprint,
        footprintGrowthBytes: footprintGrowth,
        maximumRSSGrowthBytes: maximumRSSGrowth,
        maximumFootprintGrowthBytes: maximumFootprintGrowth,
        passed: passed)
}

private func waitForEmptyGroup(_ processGroupID: pid_t, timeoutSeconds: Double) -> [pid_t] {
    let start = DispatchTime.now().uptimeNanoseconds
    var lastPIDs: [pid_t] = []
    repeat {
        lastPIDs = (try? groupPIDs(processGroupID)) ?? []
        if lastPIDs.isEmpty { return [] }
        usleep(50_000)
    } while monotonicSeconds(since: start) < timeoutSeconds
    return lastPIDs
}

private func verifyCleanupTwice(
    processGroupID: pid_t,
    familyNames: Set<String>,
    excludedPIDs: Set<pid_t>
) -> (Bool, [pid_t], [ProcessIdentity]) {
    var finalGroup: [pid_t] = []
    var finalFamily: [ProcessIdentity] = []
    for index in 0..<2 {
        finalGroup = (try? groupPIDs(processGroupID)) ?? [processGroupID]
        finalFamily = (try? rendererProcesses(
            familyNames: familyNames,
            excluding: excludedPIDs)) ?? [ProcessIdentity(
                pid: -1,
                name: "telemetry-failed",
                path: nil,
                startSeconds: nil,
                startMicroseconds: nil)]
        guard finalGroup.isEmpty, finalFamily.isEmpty else {
            return (false, finalGroup, finalFamily)
        }
        if index == 0 { usleep(100_000) }
    }
    return (true, finalGroup, finalFamily)
}

private func cleanup(
    process: SpawnedProcess,
    familyNames: Set<String>,
    excludedPIDs: Set<pid_t>,
    limits: Limits,
    sendTermination: Bool
) -> CleanupResult {
    var usedSIGTERM = false
    var usedSIGKILL = false

    let groupIsEmpty = (try? groupPIDs(process.processGroupID).isEmpty) ?? false
    if sendTermination, !groupIsEmpty {
        usedSIGTERM = killpg(process.processGroupID, SIGTERM) == 0
    }

    var residualGroup = waitForEmptyGroup(
        process.processGroupID,
        timeoutSeconds: limits.termGraceSeconds)
    if !residualGroup.isEmpty {
        usedSIGKILL = killpg(process.processGroupID, SIGKILL) == 0
        residualGroup = waitForEmptyGroup(
            process.processGroupID,
            timeoutSeconds: limits.killGraceSeconds)
    }

    var waitStatus: Int32 = 0
    _ = waitpid(process.pid, &waitStatus, WNOHANG)
    let verification = verifyCleanupTwice(
        processGroupID: process.processGroupID,
        familyNames: familyNames,
        excludedPIDs: excludedPIDs)
    return CleanupResult(
        usedSIGTERM: usedSIGTERM,
        usedSIGKILL: usedSIGKILL,
        residualGroupPIDs: verification.1,
        residualRendererProcesses: verification.2,
        verifiedTwice: verification.0)
}

private func runMonitor(
    specification: MonitorSpecification,
    writer: EvidenceWriter
) throws -> ResultRecord {
    let existing = try rendererProcesses(
        familyNames: specification.familyNames,
        excluding: specification.excludedPIDs)
    guard existing.isEmpty else {
        throw WatchdogFailure.preflight(
            "refusing to launch while renderer-family processes already exist: \(existing.map(\.pid))")
    }

    let consoleDescriptor = try writer.consoleFileDescriptor()
    defer { close(consoleDescriptor) }
    let process = try spawnSuspended(
        executablePath: specification.executablePath,
        arguments: specification.arguments,
        environment: specification.environment,
        consoleDescriptor: consoleDescriptor)
    let start = DispatchTime.now().uptimeNanoseconds
    try writer.event(
        kind: "spawned_suspended",
        detail: "pid=\(process.pid) pgid=\(process.processGroupID)",
        elapsedSeconds: 0)

    var processIsReaped = false
    var waitStatus: Int32 = 0
    var outcome: Outcome = .unexpectedExit
    var detail = "monitor ended without a terminal reason"
    var peakRSS: UInt64 = 0
    var peakFootprint: UInt64 = 0
    var peakRollingCPU = 0.0
    var cpuPoints: [CPUPoint] = []
    var memoryPoints: [MemoryPoint] = []
    var plateauRecord: MemoryPlateauRecord?
    var sampleSequence = 0

    let familyAfterSpawn = try rendererProcesses(
        familyNames: specification.familyNames,
        excluding: specification.excludedPIDs)
    guard familyAfterSpawn.count <= specification.maximumFamilyInstances,
          familyAfterSpawn.contains(where: { $0.pid == process.pid })
    else {
        let cleanupResult = cleanup(
            process: process,
            familyNames: specification.familyNames,
            excludedPIDs: specification.excludedPIDs,
            limits: specification.limits,
            sendTermination: true)
        return ResultRecord(
            outcome: cleanupResult.verifiedTwice ? .instanceLimit : .cleanupFailure,
            detail: "single-instance proof failed before resume",
            elapsedSeconds: monotonicSeconds(since: start),
            childPID: process.pid,
            processGroupID: process.processGroupID,
            childExitCode: nil,
            childTerminationSignal: nil,
            peakRSSBytes: 0,
            peakFootprintBytes: 0,
            peakRollingCPUPercent: 0,
            memoryPlateau: nil,
            usedSIGTERM: cleanupResult.usedSIGTERM,
            usedSIGKILL: cleanupResult.usedSIGKILL,
            residualGroupPIDs: cleanupResult.residualGroupPIDs,
            residualRendererProcesses: cleanupResult.residualRendererProcesses,
            cleanupVerifiedTwice: cleanupResult.verifiedTwice)
    }

    guard kill(process.pid, SIGCONT) == 0 else {
        throw WatchdogFailure.launch("cannot resume suspended child: errno \(errno)")
    }
    try writer.event(kind: "resumed", detail: "child resumed", elapsedSeconds: 0)

    monitorLoop: while true {
        let elapsed = monotonicSeconds(since: start)
        if receivedSignal != 0 {
            outcome = .interrupted
            detail = "watchdog received signal \(receivedSignal)"
            break monitorLoop
        }

        var rawStatus: Int32 = 0
        let waitResult = waitpid(process.pid, &rawStatus, WNOHANG)
        if waitResult == process.pid {
            processIsReaped = true
            waitStatus = rawStatus
            let decoded = decodeWaitStatus(rawStatus)
            if decoded.exitCode == 0,
               elapsed >= specification.limits.minimumExpectedRuntimeSeconds {
                outcome = .passed
                detail = "fixture exited cleanly after its planned observation window"
            } else {
                outcome = .unexpectedExit
                detail = "child exited before/without the planned clean observation contract"
            }
            break monitorLoop
        }
        if waitResult < 0, errno != EINTR {
            outcome = .telemetryFailure
            detail = "waitpid failed: errno \(errno)"
            break monitorLoop
        }

        if elapsed >= specification.limits.hardWallSeconds {
            outcome = .wallLimit
            detail = "child exceeded hard wall \(specification.limits.hardWallSeconds)s"
            break monitorLoop
        }

        sampleSequence += 1
        if specification.injectedTelemetryFailureSample == sampleSequence {
            outcome = .telemetryFailure
            detail = "injected telemetry failure at sample \(sampleSequence)"
            break monitorLoop
        }

        do {
            let currentIdentity = identity(pid: process.pid)
            guard currentIdentity.path == process.identity.path,
                  currentIdentity.startSeconds == process.identity.startSeconds,
                  currentIdentity.startMicroseconds == process.identity.startMicroseconds,
                  getpgid(process.pid) == process.processGroupID
            else {
                throw WatchdogFailure.telemetry("leader identity/path/PGID changed")
            }

            let family = try rendererProcesses(
                familyNames: specification.familyNames,
                excluding: specification.excludedPIDs)
            guard family.count <= specification.maximumFamilyInstances,
                  family.contains(where: { $0.pid == process.pid })
            else {
                outcome = .instanceLimit
                detail = "renderer-family instance count changed to \(family.count)"
                break monitorLoop
            }

            let metrics = try groupMetrics(process.processGroupID)
            guard metrics.pids.contains(process.pid) else {
                throw WatchdogFailure.telemetry("leader missing from its process-group sample")
            }
            peakRSS = max(peakRSS, metrics.rssBytes)
            peakFootprint = max(peakFootprint, metrics.footprintBytes)
            if specification.limits.plateauWarmupSeconds != nil {
                memoryPoints.append(MemoryPoint(
                    elapsedSeconds: elapsed,
                    rssBytes: metrics.rssBytes,
                    footprintBytes: metrics.footprintBytes))
            }

            cpuPoints.append(CPUPoint(elapsedSeconds: elapsed, cpuNanoseconds: metrics.cpuNanoseconds))
            cpuPoints.removeAll {
                elapsed - $0.elapsedSeconds > specification.limits.rollingCPUWindowSeconds
            }
            var rollingCPU: Double?
            if elapsed >= specification.limits.cpuGraceSeconds,
               let first = cpuPoints.first,
               let last = cpuPoints.last,
               last.elapsedSeconds - first.elapsedSeconds
                   >= specification.limits.rollingCPUWindowSeconds * 0.8,
               last.cpuNanoseconds >= first.cpuNanoseconds {
                let cpuSeconds = Double(last.cpuNanoseconds - first.cpuNanoseconds) / 1_000_000_000
                let wallSeconds = last.elapsedSeconds - first.elapsedSeconds
                rollingCPU = cpuSeconds / wallSeconds * 100
                peakRollingCPU = max(peakRollingCPU, rollingCPU ?? 0)
            }

            try writer.sample(SampleRecord(
                sequence: sampleSequence,
                elapsedSeconds: elapsed,
                processGroupID: process.processGroupID,
                pids: metrics.pids,
                rssBytes: metrics.rssBytes,
                footprintBytes: metrics.footprintBytes,
                totalCPUNanoseconds: metrics.cpuNanoseconds,
                rollingCPUPercent: rollingCPU))

            if metrics.rssBytes > specification.limits.rssBytes {
                outcome = .rssLimit
                detail = "group RSS exceeded \(specification.limits.rssBytes) bytes"
                break monitorLoop
            }
            if metrics.footprintBytes > specification.limits.footprintBytes {
                outcome = .footprintLimit
                detail = "group physical footprint exceeded \(specification.limits.footprintBytes) bytes"
                break monitorLoop
            }
            if let rollingCPU,
               rollingCPU > specification.limits.rollingCPUPercent {
                outcome = .rollingCPULimit
                detail = "rolling CPU exceeded \(specification.limits.rollingCPUPercent)%"
                break monitorLoop
            }
            if Double(metrics.cpuNanoseconds) / 1_000_000_000
                > specification.limits.absoluteCPUSeconds {
                outcome = .absoluteCPULimit
                detail = "absolute CPU exceeded \(specification.limits.absoluteCPUSeconds)s"
                break monitorLoop
            }
        } catch {
            // The leader can exit after the nonblocking waitpid check above
            // but before one of the libproc samples. Only an exact child reap
            // proves that this is the normal terminal race; a live child or a
            // reused/unrelated PID remains a fail-closed telemetry error.
            let reaped = reapIfExitedAfterTelemetryFailure(
                process.pid)
            if reaped.didExit {
                processIsReaped = true
                waitStatus = reaped.status
                let decoded = decodeWaitStatus(
                    reaped.status)
                if decoded.exitCode == 0,
                   elapsed
                    >= specification.limits
                        .minimumExpectedRuntimeSeconds
                {
                    outcome = .passed
                    detail =
                        "fixture exited cleanly after its planned observation window"
                } else {
                    outcome = .unexpectedExit
                    detail =
                        "child exited before/without the planned clean observation contract"
                }
            } else {
                outcome = .telemetryFailure
                detail = String(describing: error)
            }
            break monitorLoop
        }

        usleep(100_000)
    }

    let elapsed = monotonicSeconds(since: start)
    if outcome == .passed,
       specification.limits.plateauWarmupSeconds != nil {
        plateauRecord = memoryPlateau(
            points: memoryPoints,
            elapsedSeconds: elapsed,
            limits: specification.limits)
        if let plateauRecord {
            try writer.event(
                kind: "memory_plateau",
                detail: plateauRecord.passed
                    ? "baseline and tail windows remained within configured growth limits"
                    : "baseline-to-tail memory growth exceeded configured limits",
                elapsedSeconds: elapsed)
            if !plateauRecord.passed {
                outcome = .memoryPlateauLimit
                detail = "baseline-to-tail memory growth exceeded the configured 64 MiB limits"
            }
        } else {
            outcome = .telemetryFailure
            detail = "memory plateau could not be computed from the configured observation windows"
            try writer.event(
                kind: "memory_plateau",
                detail: detail,
                elapsedSeconds: elapsed)
        }
    }
    try writer.event(kind: "terminal_reason", detail: "\(outcome.rawValue): \(detail)", elapsedSeconds: elapsed)
    let cleanupResult = cleanup(
        process: process,
        familyNames: specification.familyNames,
        excludedPIDs: specification.excludedPIDs,
        limits: specification.limits,
        sendTermination: outcome != .passed)

    if !processIsReaped {
        let reaped = reapIfExited(process.pid)
        if reaped.didExit {
            waitStatus = reaped.status
        }
    }
    let decoded = decodeWaitStatus(waitStatus)
    let finalOutcome = cleanupResult.verifiedTwice ? outcome : .cleanupFailure
    try writer.event(
        kind: "cleanup",
        detail: cleanupResult.verifiedTwice
            ? "process group and renderer family verified empty twice"
            : "cleanup residual remained",
        elapsedSeconds: monotonicSeconds(since: start))

    return ResultRecord(
        outcome: finalOutcome,
        detail: detail,
        elapsedSeconds: elapsed,
        childPID: process.pid,
        processGroupID: process.processGroupID,
        childExitCode: decoded.exitCode,
        childTerminationSignal: decoded.signal,
        peakRSSBytes: peakRSS,
        peakFootprintBytes: peakFootprint,
        peakRollingCPUPercent: peakRollingCPU,
        memoryPlateau: plateauRecord,
        usedSIGTERM: cleanupResult.usedSIGTERM,
        usedSIGKILL: cleanupResult.usedSIGKILL,
        residualGroupPIDs: cleanupResult.residualGroupPIDs,
        residualRendererProcesses: cleanupResult.residualRendererProcesses,
        cleanupVerifiedTwice: cleanupResult.verifiedTwice)
}

private func validationEnvironment() -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    let allowedKeys = [
        "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_CTYPE",
        "__CF_USER_TEXT_ENCODING",
    ]
    var environment: [String: String] = [:]
    for key in allowedKeys {
        if let value = inherited[key] { environment[key] = value }
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["NSUnbufferedIO"] = "YES"
    environment["TRANSLATIS_RENDERER_WATCHDOG"] = "1"
    return environment
}

private func validateFixtureMachineResult(
    _ result: FixtureMachineResult,
    stage: FixtureStage,
    expectedProcessID: Int32
) throws {
    guard result.schema
        == FixtureMachineResult.currentSchema
    else {
        throw WatchdogFailure.evidence(
            "fixture result schema mismatch")
    }
    guard result.stage == stage.rawValue,
          result.processID == expectedProcessID,
          result.sequence > 0,
          result.sequence <= 1_000_000,
          result.finalized,
          result.state == "passed",
          result.failureCode == 0,
          result.completedCycles <= 1_000_000,
          result.sessionSwitchCount <= 1_000_000
    else {
        throw WatchdogFailure.evidence(
            "fixture result identity/final-state contract failed")
    }

    switch stage {
    case .threadBurst:
        guard result.completedCycles
                >= stage.minimumCompletedCycles,
              result.exactDeltaCount == 1_249,
              result.exactMessageCount == 17,
              result.sessionSwitchCount >= 2,
              result.heartbeatBlockCount == 0,
              result.heartbeatBlockDurationNanoseconds
                == 0
        else {
            throw WatchdogFailure.evidence(
                "thread-burst fixture result did not prove the minimum exact completed cycles")
        }
    case .heartbeatStall:
        guard result.completedCycles == 0,
              result.exactDeltaCount == 0,
              result.exactMessageCount == 0,
              result.sessionSwitchCount == 0,
              result.heartbeatBlockCount == 1,
              (2_000_000_000...5_000_000_000)
                .contains(
                    result
                        .heartbeatBlockDurationNanoseconds)
        else {
            throw WatchdogFailure.evidence(
                "heartbeat fixture result did not prove one intentional >=2s completed block")
        }
    default:
        throw WatchdogFailure.evidence(
            "fixture result is not defined for this stage")
    }
}

private func readAndValidateFixtureMachineResult(
    at url: URL,
    stage: FixtureStage,
    expectedProcessID: Int32
) throws -> FixtureMachineResult {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw WatchdogFailure.evidence(
            "required fixture result is missing")
    }
    guard (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          (metadata.st_mode & 0o7777) == 0o600,
          metadata.st_nlink == 1,
          metadata.st_size > 0,
          metadata.st_size <= 4_096
    else {
        throw WatchdogFailure.evidence(
            "fixture result ownership/type/mode/size contract failed")
    }
    let data: Data
    do {
        data = try Data(
            contentsOf: url,
            options: [.mappedIfSafe])
    } catch {
        throw WatchdogFailure.evidence(
            "fixture result could not be read")
    }
    let result: FixtureMachineResult
    do {
        result = try JSONDecoder().decode(
            FixtureMachineResult.self,
            from: data)
    } catch {
        throw WatchdogFailure.evidence(
            "fixture result is malformed")
    }
    try validateFixtureMachineResult(
        result,
        stage: stage,
        expectedProcessID: expectedProcessID)
    return result
}

private func runtimeLogTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    // `log show --start/--end` documents and accepts second precision with
    // `%Y-%m-%d %H:%M:%S%z`. Supplying fractional seconds exits 64, which
    // must not turn an otherwise valid run into an un-actionable audit error.
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
    return formatter.string(from: date)
}

private func occurrenceCount(
    of needle: String,
    in haystack: String
) -> Int {
    guard !needle.isEmpty else { return 0 }
    return max(
        0,
        haystack.components(
            separatedBy: needle).count - 1)
}

private func runtimeLogAuditRecord(
    output: String,
    startedAt: Date,
    endedAt: Date
) -> RuntimeLogAuditRecord {
    RuntimeLogAuditRecord(
        startedAt:
            ISO8601DateFormatter().string(
                from: startedAt),
        endedAt:
            ISO8601DateFormatter().string(
                from: endedAt),
        swiftUIMultipleUpdatesPerFrameCount:
            occurrenceCount(
                of: "tried to update multiple times per frame",
                in: output),
        mainThreadIncidentCount:
            occurrenceCount(
                of: "main_thread_incident",
                in: output),
        appKitInvalidGeometryCount:
            occurrenceCount(
                of: "Invalid view geometry",
                in: output))
}

private func auditRuntimeLogs(
    processID: Int32,
    startedAt: Date,
    endedAt: Date
) throws -> RuntimeLogAuditRecord {
    // Give logd a bounded interval to make the child's terminal records
    // queryable. Command failure or oversized output remains fail-closed.
    usleep(500_000)
    let process = Process()
    process.executableURL =
        URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
        "show",
        "--start",
        runtimeLogTimestamp(
            startedAt.addingTimeInterval(-1)),
        "--end",
        runtimeLogTimestamp(
            endedAt.addingTimeInterval(1)),
        "--style",
        "compact",
        "--info",
        "--debug",
        "--no-signpost",
        "--no-loss",
        "--predicate",
        """
        processIdentifier == \(processID) AND \
        (composedMessage CONTAINS[c] "multiple times per frame" OR \
        composedMessage CONTAINS[c] "main_thread_incident" OR \
        composedMessage CONTAINS[c] "Invalid view geometry")
        """,
    ]
    process.environment = validationEnvironment()
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
    } catch {
        throw WatchdogFailure.evidence(
            "runtime log audit could not launch: \(error)")
    }
    let data =
        output.fileHandleForReading
            .readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit,
          process.terminationStatus == 0 else {
        throw WatchdogFailure.evidence(
            "runtime log audit command failed with status \(process.terminationStatus)")
    }
    guard data.count <= Int(mib),
          let text = String(data: data, encoding: .utf8) else {
        throw WatchdogFailure.evidence(
            "runtime log audit output was oversized or invalid UTF-8")
    }
    return runtimeLogAuditRecord(
        output: text,
        startedAt: startedAt,
        endedAt: endedAt)
}

private func validateRuntimeLogAudit(
    _ audit: RuntimeLogAuditRecord,
    stage: FixtureStage
) throws {
    guard audit.swiftUIMultipleUpdatesPerFrameCount == 0 else {
        throw WatchdogFailure.evidence(
            "runtime log audit found \(audit.swiftUIMultipleUpdatesPerFrameCount) multiple-updates-per-frame fault(s)")
    }
    switch stage {
    case .heartbeatStall:
        guard audit.mainThreadIncidentCount == 1 else {
            throw WatchdogFailure.evidence(
                "heartbeat fixture must produce exactly one main-thread incident; observed \(audit.mainThreadIncidentCount)")
        }
    default:
        guard audit.mainThreadIncidentCount == 0 else {
            throw WatchdogFailure.evidence(
                "runtime log audit found \(audit.mainThreadIncidentCount) unexpected main-thread incident(s)")
        }
    }
}

private func validateApp(_ configuration: RunConfiguration) throws -> (String, Manifest) {
    let appPath = canonicalPath(configuration.appPath)
    let fixturePath = canonicalPath(configuration.fixturePath)
    guard appPath.hasSuffix(".app"),
          FileManager.default.fileExists(atPath: appPath),
          let bundle = Bundle(path: appPath),
          let executableURL = bundle.executableURL
    else {
        throw WatchdogFailure.preflight("validation app bundle/executable is missing")
    }
    guard bundle.bundleIdentifier == expectedBundleIdentifier else {
        throw WatchdogFailure.preflight(
            "unexpected bundle identifier: \(bundle.bundleIdentifier ?? "missing")")
    }
    let executablePath = canonicalPath(executableURL.path)
    guard URL(fileURLWithPath: executablePath).lastPathComponent == "TranslatisMac" else {
        throw WatchdogFailure.preflight("unexpected validation executable name")
    }
    let executableHash = try sha256(path: executablePath)
    guard executableHash == configuration.expectedAppSHA256 else {
        throw WatchdogFailure.preflight("validation executable SHA-256 mismatch")
    }
    let executableData = try Data(
        contentsOf: URL(fileURLWithPath: executablePath),
        options: [.mappedIfSafe])
    guard executableData.range(of: validationExecutableMarker) != nil else {
        throw WatchdogFailure.preflight(
            "validation fixture marker is absent; refusing to launch a normal Translatis build")
    }
    let fixtureHash = try sha256(path: fixturePath)
    guard fixtureHash == expectedFixtureSHA256 else {
        throw WatchdogFailure.preflight("sanitized fixture SHA-256 mismatch")
    }

    let manifest = Manifest(
        createdAt: ISO8601DateFormatter().string(from: Date()),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        appPath: appPath,
        executablePath: executablePath,
        executableSHA256: executableHash,
        bundleIdentifier: bundle.bundleIdentifier ?? "missing",
        bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "missing",
        fixturePath: fixturePath,
        fixtureSHA256: fixtureHash,
        stage: configuration.stage,
        renderer: configuration.renderer,
        mathMode: configuration.mathMode,
        appearance: configuration.appearance,
        profile: configuration.profile,
        limits: configuration.profile.limits,
        containmentOnly: configuration.profile != .soak,
        memoryPlateauRequired: configuration.profile == .soak,
        fixtureResultRequired:
            configuration.stage.requiresMachineResult,
        minimumCompletedCycles:
            configuration.stage.minimumCompletedCycles)
    return (executablePath, manifest)
}

private func parseRunConfiguration(_ arguments: [String]) throws -> RunConfiguration {
    var values: [String: String] = [:]
    var sawApproval = false
    let valueFlags = Set([
        "--app", "--expected-app-sha256", "--fixture", "--output", "--stage", "--renderer",
        "--math", "--appearance", "--profile",
    ])
    var index = 2
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--user-approved-gui" {
            guard !sawApproval else { throw WatchdogFailure.usage("duplicate --user-approved-gui") }
            sawApproval = true
            index += 1
            continue
        }
        guard valueFlags.contains(argument), arguments.indices.contains(index + 1) else {
            throw WatchdogFailure.usage("unknown or valueless run argument: \(argument)")
        }
        guard values[argument] == nil else {
            throw WatchdogFailure.usage("duplicate run argument: \(argument)")
        }
        values[argument] = arguments[index + 1]
        index += 2
    }

    guard sawApproval else {
        throw WatchdogFailure.preflight(
            "run requires --user-approved-gui after the user explicitly approves this GUI launch")
    }
    func required(_ flag: String) throws -> String {
        guard let value = values[flag], !value.isEmpty else {
            throw WatchdogFailure.usage("missing \(flag)")
        }
        return value
    }
    guard let stage = FixtureStage(rawValue: try required("--stage")),
          let renderer = RendererMode(rawValue: try required("--renderer")),
          let mathMode = MathMode(rawValue: try required("--math")),
          let appearance = Appearance(rawValue: try required("--appearance")),
          let profile = ContainmentProfile(rawValue: try required("--profile"))
    else {
        throw WatchdogFailure.usage("invalid stage/renderer/math/appearance/profile")
    }
    guard stage.accepts(profile) else {
        throw WatchdogFailure.preflight("profile \(profile.rawValue) is not valid for stage \(stage.rawValue)")
    }
    let expectedAppSHA256 = try required("--expected-app-sha256").lowercased()
    let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
    guard expectedAppSHA256.count == 64,
          expectedAppSHA256.unicodeScalars.allSatisfy(hexDigits.contains)
    else {
        throw WatchdogFailure.usage(
            "--expected-app-sha256 must be 64 lowercase or uppercase hex digits")
    }
    return RunConfiguration(
        appPath: try required("--app"),
        expectedAppSHA256: expectedAppSHA256,
        fixturePath: try required("--fixture"),
        outputPath: try required("--output"),
        stage: stage,
        renderer: renderer,
        mathMode: mathMode,
        appearance: appearance,
        profile: profile)
}

private func runValidation(_ arguments: [String]) throws -> Int32 {
    let configuration = try parseRunConfiguration(arguments)
    let lock = try AdvisoryLock(path: watchdogLockPath)
    defer { withExtendedLifetime(lock) {} }
    let writer = try EvidenceWriter(outputPath: configuration.outputPath)
    let validated = try validateApp(configuration)
    try writer.writeManifest(validated.1)
    try writer.event(kind: "preflight", detail: "bundle, fixture, lock, and telemetry prerequisites passed", elapsedSeconds: 0)

    let limits = configuration.profile.limits
    let fixtureResultURL =
        writer.outputURL
            .appendingPathComponent(
                "fixture-result.json")
    guard !FileManager.default.fileExists(
        atPath: fixtureResultURL.path)
    else {
        throw WatchdogFailure.evidence(
            "fixture result path unexpectedly exists before launch")
    }
    var launchArguments = [
        "-TranslatisRendererFixture",
        configuration.renderer.launchArgument,
        configuration.appearance.launchArgument,
        "-TranslatisRendererFixtureStage",
        configuration.stage.rawValue,
        "-TranslatisRendererIncidentFixture",
        canonicalPath(configuration.fixturePath),
        "-TranslatisRendererFixtureAutoExitSeconds",
        String(format: "%.3f", limits.observationSeconds),
        "-TranslatisRendererFixtureResultPath",
        fixtureResultURL.path,
    ]
    if let mathLaunchArgument = configuration.mathMode.launchArgument {
        launchArguments.append(mathLaunchArgument)
    }
    let runtimeStartedAt = Date()
    var result = try runMonitor(
        specification: MonitorSpecification(
            executablePath: validated.0,
            arguments: launchArguments,
            environment: validationEnvironment(),
            familyNames: ["TranslatisMac", "TranslatisRendererValidation"],
            excludedPIDs: [getpid()],
            limits: limits,
            maximumFamilyInstances: 1,
            injectedTelemetryFailureSample: nil),
        writer: writer)
    let runtimeEndedAt = Date()
    if result.passed,
       configuration.stage.requiresMachineResult {
        do {
            let fixtureResult =
                try readAndValidateFixtureMachineResult(
                    at: fixtureResultURL,
                    stage: configuration.stage,
                    expectedProcessID: result.childPID)
            result.fixtureResult = fixtureResult
            try writer.event(
                kind: "fixture_contract",
                detail:
                    "finalized result accepted; completedCycles=\(fixtureResult.completedCycles) exactDeltas=\(fixtureResult.exactDeltaCount) exactMessages=\(fixtureResult.exactMessageCount) heartbeatBlocks=\(fixtureResult.heartbeatBlockCount)",
                elapsedSeconds:
                    result.elapsedSeconds)
        } catch {
            result.outcome =
                .fixtureContractFailure
            result.detail = String(
                describing: error)
            try writer.event(
                kind: "fixture_contract",
                detail:
                    "fail-closed: \(result.detail)",
                elapsedSeconds:
                    result.elapsedSeconds)
        }
    }
    if result.passed {
        do {
            let audit = try auditRuntimeLogs(
                processID: result.childPID,
                startedAt: runtimeStartedAt,
                endedAt: runtimeEndedAt)
            try validateRuntimeLogAudit(
                audit,
                stage: configuration.stage)
            result.runtimeLogAudit = audit
            try writer.event(
                kind: "runtime_log_audit",
                detail:
                    "multipleUpdatesPerFrame=\(audit.swiftUIMultipleUpdatesPerFrameCount) mainThreadIncidents=\(audit.mainThreadIncidentCount) appKitInvalidGeometry=\(audit.appKitInvalidGeometryCount)",
                elapsedSeconds:
                    result.elapsedSeconds)
        } catch {
            result.outcome =
                .runtimeLogFailure
            result.detail =
                String(describing: error)
            try writer.event(
                kind: "runtime_log_audit",
                detail:
                    "fail-closed: \(result.detail)",
                elapsedSeconds:
                    result.elapsedSeconds)
        }
    }
    try writer.writeResult(result)
    print("WATCHDOG_RESULT=\(result.outcome.rawValue) OUTPUT=\(writer.outputURL.path)")
    return result.passed ? 0 : 70
}

private func selfExecutablePath() throws -> String {
    guard let path = processPath(pid: getpid()) else {
        throw WatchdogFailure.preflight("cannot resolve watchdog executable path")
    }
    return path
}

private func selfTestLimits(
    hardWall: Double = 2,
    rssMiB: UInt64 = 512,
    footprintMiB: UInt64 = 512,
    rollingCPU: Double = 500,
    cpuWindow: Double = 0.3,
    grace: Double = 0.1,
    absoluteCPU: Double = 10,
    minimumRuntime: Double = 0
) -> Limits {
    Limits(
        observationSeconds: max(0, hardWall - 0.25),
        hardWallSeconds: hardWall,
        rssBytes: rssMiB * mib,
        footprintBytes: footprintMiB * mib,
        rollingCPUPercent: rollingCPU,
        rollingCPUWindowSeconds: cpuWindow,
        cpuGraceSeconds: grace,
        absoluteCPUSeconds: absoluteCPU,
        termGraceSeconds: 0.2,
        killGraceSeconds: 1,
        minimumExpectedRuntimeSeconds: minimumRuntime)
}

private struct SelfTestCaseResult: Encodable {
    let name: String
    let expected: [Outcome]
    let actual: Outcome
    let cleanupVerifiedTwice: Bool
    let passed: Bool
}

private struct SelfTestSummary: Encodable {
    let schema = "translatis.renderer-watchdog.self-test.v1"
    let cases: [SelfTestCaseResult]
    let allPassed: Bool
}

private func runSelfTestCase(
    name: String,
    childMode: String,
    expected: [Outcome],
    limits: Limits,
    maximumFamilyInstances: Int = 1,
    injectedTelemetryFailureSample: Int? = nil,
    rootOutput: URL,
    executablePath: String
) throws -> SelfTestCaseResult {
    let writer = try EvidenceWriter(outputPath: rootOutput.appendingPathComponent(name).path)
    let result = try runMonitor(
        specification: MonitorSpecification(
            executablePath: executablePath,
            arguments: ["--self-test-child", childMode],
            environment: validationEnvironment(),
            familyNames: [URL(fileURLWithPath: executablePath).lastPathComponent],
            excludedPIDs: [getpid()],
            limits: limits,
            maximumFamilyInstances: maximumFamilyInstances,
            injectedTelemetryFailureSample: injectedTelemetryFailureSample),
        writer: writer)
    try writer.writeResult(result)
    let passed = expected.contains(result.outcome) && result.cleanupVerifiedTwice
    return SelfTestCaseResult(
        name: name,
        expected: expected,
        actual: result.outcome,
        cleanupVerifiedTwice: result.cleanupVerifiedTwice,
        passed: passed)
}

private func writeSelfTestSummary(_ summary: SelfTestSummary, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(summary)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func validateClosedSetSelfTestContracts() throws {
    let isolatedMathStages: [FixtureStage] = [
        .mathOne,
        .mathThirtyTwo,
        .mathStructure,
        .mathHistory,
        .mathStream,
    ]
    guard isolatedMathStages.allSatisfy({ $0.accepts(.isolation) }),
          isolatedMathStages.allSatisfy({ $0.accepts(.computerUse) }),
          isolatedMathStages.allSatisfy({ !$0.accepts(.minimal) }),
          isolatedMathStages.allSatisfy({ !$0.accepts(.replaySmoke) }),
          isolatedMathStages.allSatisfy({ !$0.accepts(.soak) }),
          FixtureStage.threadBurst.accepts(.soak),
          !FixtureStage.threadBurst.accepts(.replaySmoke),
          FixtureStage.heartbeatStall.accepts(.isolation),
          FixtureStage.mathStructure.rawValue == "math-structure",
          FixtureStage.mathHistory.rawValue == "math-history",
          MathMode.disabled.launchArgument == "-IntatisDisableSingleDollarMath",
          MathMode.singleDollar.launchArgument == nil
    else {
        throw WatchdogFailure.preflight(
            "closed-set math validation contracts failed self-test")
    }

    let soakLimits = ContainmentProfile.soak.limits
    let stablePoints = [
        MemoryPoint(elapsedSeconds: 60, rssBytes: 100 * mib, footprintBytes: 110 * mib),
        MemoryPoint(elapsedSeconds: 75, rssBytes: 101 * mib, footprintBytes: 111 * mib),
        MemoryPoint(elapsedSeconds: 90, rssBytes: 100 * mib, footprintBytes: 110 * mib),
        MemoryPoint(elapsedSeconds: 150, rssBytes: 108 * mib, footprintBytes: 119 * mib),
        MemoryPoint(elapsedSeconds: 165, rssBytes: 109 * mib, footprintBytes: 120 * mib),
        MemoryPoint(elapsedSeconds: 180, rssBytes: 108 * mib, footprintBytes: 119 * mib),
    ]
    let growingPoints = stablePoints.prefix(3) + [
        MemoryPoint(elapsedSeconds: 150, rssBytes: 180 * mib, footprintBytes: 190 * mib),
        MemoryPoint(elapsedSeconds: 165, rssBytes: 181 * mib, footprintBytes: 191 * mib),
        MemoryPoint(elapsedSeconds: 180, rssBytes: 182 * mib, footprintBytes: 192 * mib),
    ]
    guard memoryPlateau(
        points: stablePoints,
        elapsedSeconds: 180,
        limits: soakLimits)?.passed == true,
        memoryPlateau(
            points: Array(growingPoints),
            elapsedSeconds: 180,
            limits: soakLimits)?.passed == false
    else {
        throw WatchdogFailure.preflight(
            "memory plateau validation contracts failed self-test")
    }

    func threadResult(
        cycles: UInt64,
        sessionSwitches: UInt64 = 2,
        finalized: Bool = true,
        state: String = "passed",
        failureCode: UInt64 = 0
    ) -> FixtureMachineResult {
        FixtureMachineResult(
            schema:
                FixtureMachineResult.currentSchema,
            stage: FixtureStage.threadBurst.rawValue,
            state: state,
            processID: 42,
            sequence: 3,
            finalized: finalized,
            completedCycles: cycles,
            exactDeltaCount: 1_249,
            exactMessageCount: 17,
            sessionSwitchCount: sessionSwitches,
            heartbeatBlockCount: 0,
            heartbeatBlockDurationNanoseconds: 0,
            failureCode: failureCode)
    }
    func rejected(
        _ result: FixtureMachineResult,
        stage: FixtureStage
    ) -> Bool {
        do {
            try validateFixtureMachineResult(
                result,
                stage: stage,
                expectedProcessID: 42)
            return false
        } catch {
            return true
        }
    }
    let validThread = threadResult(cycles: 20)
    let validHeartbeat = FixtureMachineResult(
        schema:
            FixtureMachineResult.currentSchema,
        stage: FixtureStage.heartbeatStall.rawValue,
        state: "passed",
        processID: 42,
        sequence: 3,
        finalized: true,
        completedCycles: 0,
        exactDeltaCount: 0,
        exactMessageCount: 0,
        sessionSwitchCount: 0,
        heartbeatBlockCount: 1,
        heartbeatBlockDurationNanoseconds:
            2_250_000_000,
        failureCode: 0)
    do {
        try validateFixtureMachineResult(
            validThread,
            stage: .threadBurst,
            expectedProcessID: 42)
        try validateFixtureMachineResult(
            validHeartbeat,
            stage: .heartbeatStall,
            expectedProcessID: 42)
    } catch {
        throw WatchdogFailure.preflight(
            "valid fixture result contracts failed self-test")
    }
    guard rejected(
        threadResult(cycles: 19),
        stage: .threadBurst),
        rejected(
            threadResult(
                cycles: 20,
                sessionSwitches: 1),
            stage: .threadBurst),
        rejected(
            threadResult(
                cycles: 20,
                finalized: false),
            stage: .threadBurst),
        rejected(
            threadResult(
                cycles: 20,
                state: "failed",
                failureCode: 3),
            stage: .threadBurst),
        rejected(
            FixtureMachineResult(
                schema:
                    FixtureMachineResult.currentSchema,
                stage:
                    FixtureStage.heartbeatStall.rawValue,
                state: "passed",
                processID: 42,
                sequence: 3,
                finalized: true,
                completedCycles: 0,
                exactDeltaCount: 0,
                exactMessageCount: 0,
                sessionSwitchCount: 0,
                heartbeatBlockCount: 1,
                heartbeatBlockDurationNanoseconds:
                    1_999_999_999,
                failureCode: 0),
            stage: .heartbeatStall)
    else {
        throw WatchdogFailure.preflight(
            "fixture result fail-closed contracts failed self-test")
    }

    let auditStart = Date(
        timeIntervalSince1970: 1_000)
    let auditEnd = Date(
        timeIntervalSince1970: 1_010)
    guard runtimeLogTimestamp(auditStart)
        == "1970-01-01 00:16:40+0000"
    else {
        throw WatchdogFailure.preflight(
            "runtime log timestamp contract failed self-test")
    }
    let quietAudit =
        runtimeLogAuditRecord(
            output:
                "Timestamp               Ty Process[PID:TID]\n",
            startedAt: auditStart,
            endedAt: auditEnd)
    let faultAudit =
        runtimeLogAuditRecord(
            output:
                """
                <OnScrollGeometryChange Modifier> tried to update multiple times per frame.
                main_thread_incident delay_ms=2001
                Invalid view geometry: width is negative.
                """,
            startedAt: auditStart,
            endedAt: auditEnd)
    do {
        try validateRuntimeLogAudit(
            quietAudit,
            stage: .threadBurst)
    } catch {
        throw WatchdogFailure.preflight(
            "quiet runtime log audit failed self-test")
    }
    guard faultAudit
            .swiftUIMultipleUpdatesPerFrameCount == 1,
          faultAudit.mainThreadIncidentCount == 1,
          faultAudit.appKitInvalidGeometryCount == 1,
          ({
              do {
                  try validateRuntimeLogAudit(
                      faultAudit,
                      stage: .threadBurst)
                  return false
              } catch {
                  return true
              }
          })(),
          ({
              do {
                  try validateRuntimeLogAudit(
                      quietAudit,
                      stage: .heartbeatStall)
                  return false
              } catch {
                  return true
              }
          })()
    else {
        throw WatchdogFailure.preflight(
            "runtime log audit fail-closed contracts failed self-test")
    }
    let expectedHeartbeatAudit =
        runtimeLogAuditRecord(
            output:
                "main_thread_incident delay_ms=2250\n",
            startedAt: auditStart,
            endedAt: auditEnd)
    do {
        try validateRuntimeLogAudit(
            expectedHeartbeatAudit,
            stage: .heartbeatStall)
    } catch {
        throw WatchdogFailure.preflight(
            "expected heartbeat runtime log audit failed self-test")
    }
}

private func validateFixtureResultFileSelfTest(
    rootOutput: URL
) throws {
    let directory =
        rootOutput.appendingPathComponent(
            "fixture-result-contract")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])

    let valid = FixtureMachineResult(
        schema:
            FixtureMachineResult.currentSchema,
        stage: FixtureStage.threadBurst.rawValue,
        state: "passed",
        processID: 42,
        sequence: 4,
        finalized: true,
        completedCycles: 20,
        exactDeltaCount: 1_249,
        exactMessageCount: 17,
        sessionSwitchCount: 2,
        heartbeatBlockCount: 0,
        heartbeatBlockDurationNanoseconds: 0,
        failureCode: 0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .sortedKeys,
        .withoutEscapingSlashes,
    ]

    func write(
        _ data: Data,
        name: String,
        mode: Int
    ) throws -> URL {
        let url =
            directory.appendingPathComponent(name)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [
                .posixPermissions: mode,
            ])
        else {
            throw WatchdogFailure.preflight(
                "fixture result file self-test could not create input")
        }
        return url
    }

    let validURL = try write(
        try encoder.encode(valid),
        name: "valid.json",
        mode: 0o600)
    do {
        _ = try readAndValidateFixtureMachineResult(
            at: validURL,
            stage: .threadBurst,
            expectedProcessID: 42)
    } catch {
        throw WatchdogFailure.preflight(
            "valid fixture result file failed self-test")
    }

    let missingURL =
        directory.appendingPathComponent(
            "missing.json")
    let malformedURL = try write(
        Data("{".utf8),
        name: "malformed.json",
        mode: 0o600)
    let broadModeURL = try write(
        try encoder.encode(valid),
        name: "broad-mode.json",
        mode: 0o644)
    func rejected(_ url: URL) -> Bool {
        do {
            _ = try readAndValidateFixtureMachineResult(
                at: url,
                stage: .threadBurst,
                expectedProcessID: 42)
            return false
        } catch {
            return true
        }
    }
    guard rejected(missingURL),
          rejected(malformedURL),
          rejected(broadModeURL)
    else {
        throw WatchdogFailure.preflight(
            "missing/malformed/insecure fixture result was accepted in self-test")
    }
}

private func validatePostWaitpidExitRaceSelfTest() throws {
    var delayedReapCalls = 0
    let delayedReap =
        reapIfExitedAfterTelemetryFailure(
            42,
            maximumAttempts: 4,
            retryMicroseconds: 0,
            reap: { pid in
                guard pid == 42 else {
                    return (false, 0)
                }
                delayedReapCalls += 1
                return delayedReapCalls == 3
                    ? (true, 0)
                    : (false, 0)
            })
    guard delayedReap.didExit,
          delayedReap.status == 0,
          delayedReapCalls == 3
    else {
        throw WatchdogFailure.preflight(
            "post-waitpid normal-exit race was not claimed by an exact delayed reap")
    }

    var liveChildCalls = 0
    let liveChild =
        reapIfExitedAfterTelemetryFailure(
            42,
            maximumAttempts: 4,
            retryMicroseconds: 0,
            reap: { _ in
                liveChildCalls += 1
                return (false, 0)
            })
    guard !liveChild.didExit,
          liveChildCalls == 4
    else {
        throw WatchdogFailure.preflight(
            "live child telemetry failure did not remain fail-closed")
    }
}

private func runSelfTests(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 4, arguments[2] == "--output" else {
        throw WatchdogFailure.usage("usage: watchdog self-test --output NEW_DIRECTORY")
    }
    let lock = try AdvisoryLock(path: watchdogLockPath)
    try validateClosedSetSelfTestContracts()
    print(
        "SELF_TEST=runtime-log-contract EXPECTED=quiet-or-one-intentional-heartbeat ACTUAL=quiet-or-one-intentional-heartbeat PASS=true")
    let outputURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw WatchdogFailure.preflight("refusing to reuse self-test output directory")
    }
    try FileManager.default.createDirectory(
        at: outputURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    try validateFixtureResultFileSelfTest(
        rootOutput: outputURL)
    print(
        "SELF_TEST=fixture-result-contract EXPECTED=valid-only ACTUAL=valid-only PASS=true")
    try validatePostWaitpidExitRaceSelfTest()
    print(
        "SELF_TEST=post-waitpid-exit-race EXPECTED=exact-reap-only ACTUAL=exact-reap-only PASS=true")
    let executablePath = try selfExecutablePath()
    let cases: [(String, String, [Outcome], Limits, Int, Int?)] = [
        ("clean-exit", "short", [.passed], selfTestLimits(hardWall: 2, minimumRuntime: 0.2), 1, nil),
        ("wall-fuse", "sleep", [.wallLimit], selfTestLimits(hardWall: 0.6), 1, nil),
        ("memory-fuse", "memory", [.rssLimit, .footprintLimit], selfTestLimits(hardWall: 3, rssMiB: 96, footprintMiB: 160), 1, nil),
        ("cpu-fuse", "cpu", [.rollingCPULimit], selfTestLimits(
            hardWall: 3,
            rollingCPU: 20,
            cpuWindow: 1), 1, nil),
        ("group-kill", "group", [.wallLimit], selfTestLimits(hardWall: 0.8), 2, nil),
        ("exit-seven", "exit7", [.unexpectedExit], selfTestLimits(hardWall: 2), 1, nil),
        ("telemetry-fail-closed", "sleep", [.telemetryFailure], selfTestLimits(hardWall: 2), 1, 3),
    ]
    var results: [SelfTestCaseResult] = []
    for testCase in cases {
        let result = try runSelfTestCase(
            name: testCase.0,
            childMode: testCase.1,
            expected: testCase.2,
            limits: testCase.3,
            maximumFamilyInstances: testCase.4,
            injectedTelemetryFailureSample: testCase.5,
            rootOutput: outputURL,
            executablePath: executablePath)
        results.append(result)
        print("SELF_TEST=\(result.name) EXPECTED=\(result.expected.map(\.rawValue).joined(separator: ",")) ACTUAL=\(result.actual.rawValue) PASS=\(result.passed)")
    }

    // A second lock contender must fail before it can spawn any target.
    let lockWriter = try EvidenceWriter(outputPath: outputURL.appendingPathComponent("lock-contention").path)
    let lockResult = try runMonitor(
        specification: MonitorSpecification(
            executablePath: executablePath,
            arguments: ["--self-test-child", "lock", watchdogLockPath],
            environment: validationEnvironment(),
            familyNames: [URL(fileURLWithPath: executablePath).lastPathComponent],
            excludedPIDs: [getpid()],
            limits: selfTestLimits(hardWall: 2),
            maximumFamilyInstances: 1,
            injectedTelemetryFailureSample: nil),
        writer: lockWriter)
    try lockWriter.writeResult(lockResult)
    let lockCase = SelfTestCaseResult(
        name: "lock-contention",
        expected: [.unexpectedExit],
        actual: lockResult.outcome,
        cleanupVerifiedTwice: lockResult.cleanupVerifiedTwice,
        passed: lockResult.outcome == .unexpectedExit
            && lockResult.childExitCode == 9
            && lockResult.cleanupVerifiedTwice)
    results.append(lockCase)
    print("SELF_TEST=lock-contention EXPECTED=exit9 ACTUAL=\(lockResult.childExitCode.map(String.init) ?? "signal") PASS=\(lockCase.passed)")

    let summary = SelfTestSummary(cases: results, allPassed: results.allSatisfy(\.passed))
    try writeSelfTestSummary(summary, at: outputURL.appendingPathComponent("self-test-result.json"))
    withExtendedLifetime(lock) {}
    return summary.allPassed ? 0 : 70
}

private func spawnSelfTestGrandchild() -> pid_t {
    guard let executablePath = try? selfExecutablePath() else { return -1 }
    var childPID: pid_t = 0
    let arguments = [executablePath, "--self-test-child", "ignore-term"]
    let environment = validationEnvironment().map { "\($0.key)=\($0.value)" }.sorted()
    let status = withCStringArray(arguments) { argumentPointers in
        withCStringArray(environment) { environmentPointers in
            executablePath.withCString { executablePointer in
                posix_spawn(
                    &childPID,
                    executablePointer,
                    nil,
                    nil,
                    argumentPointers,
                    environmentPointers)
            }
        }
    }
    return status == 0 ? childPID : -1
}

private func runSelfTestChild(_ arguments: [String]) -> Never {
    guard arguments.count >= 3 else { exit(64) }
    switch arguments[2] {
    case "short":
        usleep(300_000)
        exit(0)
    case "sleep":
        sleep(10)
        exit(0)
    case "memory":
        let byteCount = 256 * Int(mib)
        guard let pointer = mmap(
            nil,
            byteCount,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0), pointer != MAP_FAILED
        else { exit(8) }
        var checksum: UInt64 = 0
        for offset in stride(from: 0, to: byteCount, by: 4_096) {
            let value = UInt64(offset + 1)
            pointer.advanced(by: offset).storeBytes(of: value, as: UInt64.self)
            checksum &+= value
        }
        withUnsafeBytes(of: &checksum) { bytes in
            _ = write(STDOUT_FILENO, bytes.baseAddress, bytes.count)
        }
        while true {
            var observed: UInt64 = 0
            for offset in stride(from: 0, to: byteCount, by: 4_096) {
                observed &+= pointer.advanced(by: offset).load(as: UInt64.self)
            }
            checksum = observed
            usleep(100_000)
        }
    case "cpu":
        while true { _ = getpid() }
    case "group":
        guard spawnSelfTestGrandchild() > 0 else { exit(8) }
        sleep(10)
        exit(0)
    case "ignore-term":
        _ = signal(SIGTERM, SIG_IGN)
        while true { sleep(1) }
    case "exit7":
        exit(7)
    case "lock":
        guard arguments.count == 4 else { exit(64) }
        let descriptor = open(arguments[3], O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { exit(8) }
        let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        close(descriptor)
        exit(acquired ? 0 : 9)
    default:
        exit(64)
    }
}

private func printUsage() {
    let usage = """
    Usage:
      watchdog self-test --output NEW_DIRECTORY
      watchdog run --user-approved-gui \\
        --app VALIDATION.app --expected-app-sha256 SHA256 \\
        --fixture incident-1249-sanitized-v1.json \\
        --output NEW_DIRECTORY --stage STAGE --renderer microsoft|plainSafe \\
        --math disabled|single-dollar --appearance light|dark \\
        --profile minimal|isolation|computer-use|replay-smoke|soak

    The run command only accepts a hash-pinned Translatis validation build.
    A soak run enforces its own 180-second memory-plateau gate, but one run does
    not replace the repeated, Instruments-backed release validation matrix.
    """
    FileHandle.standardError.write(Data((usage + "\n").utf8))
}

private func main() -> Int32 {
    installSignalHandlers()
    let arguments = CommandLine.arguments
    if arguments.count >= 2, arguments[1] == "--self-test-child" {
        runSelfTestChild(arguments)
    }
    do {
        guard arguments.count >= 2 else {
            throw WatchdogFailure.usage("missing command")
        }
        switch arguments[1] {
        case "run":
            return try runValidation(arguments)
        case "self-test":
            return try runSelfTests(arguments)
        default:
            throw WatchdogFailure.usage("unknown command: \(arguments[1])")
        }
    } catch {
        FileHandle.standardError.write(Data(("watchdog error: \(error)\n").utf8))
        printUsage()
        return error is WatchdogFailure ? 64 : 70
    }
}

exit(main())
#else
import Foundation
FileHandle.standardError.write(Data("RendererValidationWatchdog requires macOS.\n".utf8))
exit(64)
#endif
