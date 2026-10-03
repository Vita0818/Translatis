import Foundation
import IntatisCore
import XCTest
@testable import TranslatisCLI

final class HangDiagnosticsCommandTests: XCTestCase {
    func testParserRequiresExactPIDAndResolvesRelativeOutput() throws {
        let current = URL(fileURLWithPath: "/tmp/translatis-diagnostics-test")
        let options = try CLIDiagnoseHangOptions.parse(
            ["--pid", "4321", "--output", "captures"][...],
            currentDirectoryURL: current)

        XCTAssertEqual(options.processIdentifier, 4321)
        XCTAssertEqual(
            options.outputParentURL?.path,
            current.appendingPathComponent("captures").standardizedFileURL.path)
        XCTAssertThrowsError(
            try CLIDiagnoseHangOptions.parse(["--pid", "0"][...]))
        XCTAssertThrowsError(
            try CLIDiagnoseHangOptions.parse(["--pid", "4321", "--extra"][...]))
        XCTAssertThrowsError(
            try CLIDiagnoseHangOptions.parse(["--output", "/tmp"][...]))
    }

    func testProcessValidationRequiresCurrentUserExactExecutableAndBundle() {
        let valid = CLIIntatisProcessIdentity(
            processIdentifier: 42,
            ownerUserIdentifier: 501,
            executableName: "TranslatisMac",
            bundleIdentifier: "com.Vita0818.TranslatisMac")
        XCTAssertNoThrow(try CLIIntatisProcessValidator.validate(
            valid,
            currentUserIdentifier: 501))

        XCTAssertThrowsError(try CLIIntatisProcessValidator.validate(
            .init(
                processIdentifier: 42,
                ownerUserIdentifier: 502,
                executableName: "TranslatisMac",
                bundleIdentifier: "com.Vita0818.TranslatisMac"),
            currentUserIdentifier: 501)) {
                XCTAssertEqual(
                    $0 as? CLIDiagnoseHangError,
                    .targetNotOwnedByCurrentUser)
            }
        XCTAssertThrowsError(try CLIIntatisProcessValidator.validate(
            .init(
                processIdentifier: 42,
                ownerUserIdentifier: 501,
                executableName: "TranslatisMac-copy",
                bundleIdentifier: "com.Vita0818.TranslatisMac"),
            currentUserIdentifier: 501)) {
                XCTAssertEqual(
                    $0 as? CLIDiagnoseHangError,
                    .targetIsNotIntatis)
            }
        XCTAssertThrowsError(try CLIIntatisProcessValidator.validate(
            .init(
                processIdentifier: 42,
                ownerUserIdentifier: 501,
                executableName: "TranslatisMac",
                bundleIdentifier: "example.not-translatis"),
            currentUserIdentifier: 501)) {
                XCTAssertEqual(
                    $0 as? CLIDiagnoseHangError,
                    .targetIsNotIntatis)
            }
    }

    func testCaptureUsesExactSampleAndFiveMinuteLogAndSanitizesOutput()
        async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let defaultRoot = parent.appendingPathComponent("default")
        let explicitParent = parent.appendingPathComponent("selected")
        let now = Date(timeIntervalSince1970: 10_000)

        let recentStore = IntatisHangDiagnosticBundleStore(
            rootURL: defaultRoot)
        _ = try await recentStore.writeBundle(
            manifest: .init(
                source: .mainThreadHeartbeat,
                recordedAt: now.addingTimeInterval(-30),
                processIdentifier: 4321,
                mainThreadDelayMilliseconds: 2_250,
                applicationVersion: "0.12",
                buildVersion: "7",
                metrics: .init(counters: [
                    IntatisDiagnosticCounter.mainThreadIncidents.rawValue: 1,
                ])))

        let runner = RecordingHangCaptureRunner()
        let report = try await captureIntatisHang(
            options: .init(
                processIdentifier: 4321,
                outputParentURL: explicitParent),
            inspector: FixedProcessInspector(
                identity: .init(
                    processIdentifier: 4321,
                    ownerUserIdentifier: 501,
                    executableName: "TranslatisMac",
                    bundleIdentifier: "com.Vita0818.TranslatisMac")),
            runner: runner,
            now: now,
            currentUserIdentifier: 501,
            defaultRootURL: defaultRoot)

        XCTAssertTrue(report.sampleSucceeded)
        XCTAssertTrue(report.unifiedLogSucceeded)
        let invocations = runner.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].executableURL.path, "/usr/bin/sample")
        XCTAssertEqual(invocations[0].arguments, ["4321", "10", "1"])
        XCTAssertEqual(invocations[0].timeoutSeconds, 15)
        XCTAssertEqual(invocations[1].executableURL.path, "/usr/bin/log")
        XCTAssertEqual(
            invocations[1].arguments,
            [
                "show",
                "--last",
                "5m",
                "--style",
                "compact",
                "--predicate",
                "processIdentifier == 4321 AND subsystem == \"com.Vita0818.Intatis\"",
            ])

        let bundle = explicitParent
            .appendingPathComponent("Translatis-HangDiagnostics")
            .appendingPathComponent(report.bundleDisplayName)
        let sampleData = try XCTUnwrap(try DurableOwnerOnlyFile.read(
            from: bundle.appendingPathComponent("sample.txt")))
        let sampleText = try XCTUnwrap(
            String(data: sampleData, encoding: .utf8))
        XCTAssertFalse(sampleText.contains("/Users/example"))
        XCTAssertFalse(sampleText.contains("abcdefghijklmnop"))
        XCTAssertFalse(sampleText.contains("https://provider.invalid"))

        let manifestData = try XCTUnwrap(try DurableOwnerOnlyFile.read(
            from: bundle.appendingPathComponent("incident.json")))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            IntatisHangDiagnosticManifest.self,
            from: manifestData)
        XCTAssertEqual(manifest.source, .externalCapture)
        XCTAssertEqual(manifest.mainThreadDelayMilliseconds, 2_250)
        XCTAssertEqual(
            manifest.metrics?.value(for: .mainThreadIncidents),
            1)
        XCTAssertEqual(
            manifest.capture,
            .init(
                sampleSucceeded: true,
                unifiedLogSucceeded: true,
                relatedHeartbeatIncidentFound: true))
    }

    func testFailedSampleStillWritesBoundedBundleAndReturnsFailure()
        async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let defaultRoot = parent.appendingPathComponent("default")
        let runner = RecordingHangCaptureRunner(sampleStatus: 1)

        let report = try await captureIntatisHang(
            options: .init(
                processIdentifier: 123,
                outputParentURL: nil),
            inspector: FixedProcessInspector(
                identity: .init(
                    processIdentifier: 123,
                    ownerUserIdentifier: 501,
                    executableName: "TranslatisMac",
                    bundleIdentifier: "com.Vita0818.TranslatisMac")),
            runner: runner,
            now: Date(timeIntervalSince1970: 20_000),
            currentUserIdentifier: 501,
            defaultRootURL: defaultRoot)

        XCTAssertFalse(report.sampleSucceeded)
        XCTAssertTrue(report.unifiedLogSucceeded)
        let bundle = defaultRoot.appendingPathComponent(
            report.bundleDisplayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("incident.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("capture-errors.txt").path))
    }

    func testSampleLaunchFailureStillRunsLogAndWritesBundle() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let defaultRoot = parent.appendingPathComponent("default")
        let runner = RecordingHangCaptureRunner(throwSample: true)

        let report = try await captureIntatisHang(
            options: .init(
                processIdentifier: 123,
                outputParentURL: nil),
            inspector: FixedProcessInspector(
                identity: .init(
                    processIdentifier: 123,
                    ownerUserIdentifier: 501,
                    executableName: "TranslatisMac",
                    bundleIdentifier: "com.Vita0818.TranslatisMac")),
            runner: runner,
            now: Date(timeIntervalSince1970: 20_001),
            currentUserIdentifier: 501,
            defaultRootURL: defaultRoot)

        XCTAssertFalse(report.sampleSucceeded)
        XCTAssertTrue(report.unifiedLogSucceeded)
        XCTAssertEqual(runner.invocations.count, 2)
        let bundle = defaultRoot.appendingPathComponent(
            report.bundleDisplayName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("incident.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("capture-errors.txt").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "translatis-cli-hang-tests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        return url
    }
}

private struct FixedProcessInspector: CLIIntatisProcessInspecting {
    let identity: CLIIntatisProcessIdentity

    func inspect(
        processIdentifier: Int32
    ) throws -> CLIIntatisProcessIdentity {
        XCTAssertEqual(processIdentifier, identity.processIdentifier)
        return identity
    }
}

private final class RecordingHangCaptureRunner:
    CLIHangCaptureRunning, @unchecked Sendable
{
    struct Invocation: Equatable {
        let executableURL: URL
        let arguments: [String]
        let timeoutSeconds: TimeInterval
    }

    private let lock = NSLock()
    private var storedInvocations: [Invocation] = []
    private let sampleStatus: Int32
    private let throwSample: Bool

    init(
        sampleStatus: Int32 = 0,
        throwSample: Bool = false
    ) {
        self.sampleStatus = sampleStatus
        self.throwSample = throwSample
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocations
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> CLIHangCaptureExecution {
        lock.lock()
        storedInvocations.append(.init(
            executableURL: executableURL,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds))
        lock.unlock()

        if executableURL.lastPathComponent == "sample" {
            if throwSample {
                throw RecordingHangCaptureError.launchFailed
            }
            return CLIHangCaptureExecution(
                terminationStatus: sampleStatus,
                standardOutput: Data("""
                Path: /Users/example/Private/TranslatisMac
                URL: https://provider.invalid/v1
                Authorization: Bearer abcdefghijklmnop
                Thread 0: main
                """.utf8),
                standardError: sampleStatus == 0
                    ? Data()
                    : Data("sample permission denied".utf8),
                timedOut: false)
        }
        return CLIHangCaptureExecution(
            terminationStatus: 0,
            standardOutput: Data(
                "main_thread_incident delay_ms=2250\n".utf8),
            standardError: Data(),
            timedOut: false)
    }
}

private enum RecordingHangCaptureError: Error {
    case launchFailed
}
