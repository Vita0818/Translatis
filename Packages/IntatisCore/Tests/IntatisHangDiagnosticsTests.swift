import Foundation
import XCTest
@testable import IntatisCore

final class IntatisHangDiagnosticsTests: XCTestCase {
    func testHeartbeatKeepsOnePendingPingAndEmitsThresholdsOnce() {
        let configuration = IntatisMainThreadHeartbeatConfiguration(
            warningAfterNanoseconds: 500_000_000,
            incidentAfterNanoseconds: 2_000_000_000,
            incidentCooldownNanoseconds: 3_000_000_000)
        var heartbeat = IntatisMainThreadHeartbeatStateMachine(
            configuration: configuration)

        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 1_000_000_000),
            [.enqueuePing(generation: 1)])
        XCTAssertTrue(heartbeat.hasPendingPing)
        XCTAssertEqual(heartbeat.tick(atNanoseconds: 1_250_000_000), [])
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 1_500_000_000),
            [.warning(delayMilliseconds: 500)])
        XCTAssertEqual(heartbeat.tick(atNanoseconds: 2_000_000_000), [])
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 3_000_000_000),
            [.incident(delayMilliseconds: 2_000)])
        XCTAssertEqual(heartbeat.tick(atNanoseconds: 3_250_000_000), [])

        heartbeat.acknowledge(generation: 999)
        XCTAssertTrue(heartbeat.hasPendingPing)
        heartbeat.acknowledge(generation: 1)
        XCTAssertFalse(heartbeat.hasPendingPing)
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 3_500_000_000),
            [.enqueuePing(generation: 2)])
    }

    func testHeartbeatSuppressionDropsPendingAndResumesFresh() {
        var heartbeat = IntatisMainThreadHeartbeatStateMachine()
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 0),
            [.enqueuePing(generation: 1)])

        heartbeat.setSuppressed(true)
        XCTAssertFalse(heartbeat.hasPendingPing)
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 10_000_000_000),
            [])

        heartbeat.setSuppressed(false)
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 20_000_000_000),
            [.enqueuePing(generation: 2)])
        heartbeat.terminate()
        XCTAssertFalse(heartbeat.hasPendingPing)
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 40_000_000_000),
            [])
    }

    func testHeartbeatIncidentCooldownAppliesAcrossPingGenerations() {
        let configuration = IntatisMainThreadHeartbeatConfiguration(
            warningAfterNanoseconds: 10,
            incidentAfterNanoseconds: 20,
            incidentCooldownNanoseconds: 100)
        var heartbeat = IntatisMainThreadHeartbeatStateMachine(
            configuration: configuration)

        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 0),
            [.enqueuePing(generation: 1)])
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 20),
            [
                .warning(delayMilliseconds: 0),
                .incident(delayMilliseconds: 0),
            ])
        heartbeat.acknowledge(generation: 1)

        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 30),
            [.enqueuePing(generation: 2)])
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 60),
            [.warning(delayMilliseconds: 0)])
        XCTAssertEqual(heartbeat.tick(atNanoseconds: 119), [])
        XCTAssertEqual(
            heartbeat.tick(atNanoseconds: 120),
            [.incident(delayMilliseconds: 0)])
    }

    func testPerformanceMetricsAreNumericAndAggregated() {
        let diagnostics = IntatisPerformanceDiagnostics()
        diagnostics.increment(.projectionBatches)
        diagnostics.increment(.projectionEnvelopes, by: 500)
        diagnostics.recordScrollRequest(
            reason: .liveContent,
            outcome: .requested)
        diagnostics.recordScrollRequest(
            reason: .liveContent,
            outcome: .cancelled)

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.value(for: .projectionBatches), 1)
        XCTAssertEqual(snapshot.value(for: .projectionEnvelopes), 500)
        XCTAssertEqual(snapshot.value(for: .scrollRequested), 1)
        XCTAssertEqual(snapshot.value(for: .scrollCancelled), 1)
        XCTAssertNil(snapshot.counters["message"])
    }

    func testCoworkAgentThreadDiagnosticsRemainNumericAndContentFree() {
        let diagnostics = IntatisPerformanceDiagnostics()
        diagnostics.recordCoworkAgentSwitch(
            outcome: .requested,
            generation: 4)
        diagnostics.recordCoworkAgentSwitch(
            outcome: .committed,
            durationNanoseconds: 900,
            generation: 4,
            rowCount: 16)
        diagnostics.recordCoworkAgentSwitch(
            outcome: .stale,
            durationNanoseconds: 100,
            generation: 3)
        diagnostics.recordCoworkAgentPageQuery(
            durationNanoseconds: 800,
            rowCount: 16,
            totalCount: 100_000)
        diagnostics.recordCoworkAgentThreadPublication(rowCount: 16)

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.value(for: .coworkAgentSwitchRequested), 1)
        XCTAssertEqual(snapshot.value(for: .coworkAgentSwitchCommitted), 1)
        XCTAssertEqual(snapshot.value(for: .coworkAgentSwitchStale), 1)
        XCTAssertEqual(snapshot.value(for: .coworkAgentPageQueries), 1)
        XCTAssertEqual(snapshot.value(for: .coworkAgentPageRows), 16)
        XCTAssertEqual(snapshot.value(for: .coworkAgentThreadPublications), 2)
        XCTAssertNil(snapshot.counters["agentID"])
        XCTAssertNil(snapshot.counters["message"])
    }

    func testDurationSummariesUseFixedBucketsAndSaturate() {
        let diagnostics = IntatisPerformanceDiagnostics()
        let samples: [UInt64] = [
            0,
            999_999,
            1_000_000,
            3_999_999,
            4_000_000,
            15_999_999,
            16_000_000,
            49_999_999,
            50_000_000,
            99_999_999,
            100_000_000,
            499_999_999,
            500_000_000,
            1_999_999_999,
            2_000_000_000,
        ]
        for sample in samples {
            diagnostics.recordDuration(
                .markdownParse,
                nanoseconds: sample)
        }

        let aggregate = diagnostics.snapshot().durations.value(
            for: .markdownParse)
        XCTAssertEqual(aggregate.count, UInt64(samples.count))
        XCTAssertEqual(
            aggregate.totalNanoseconds,
            samples.reduce(0, +))
        XCTAssertEqual(aggregate.maximumNanoseconds, 2_000_000_000)
        XCTAssertEqual(
            aggregate.histogram.value(for: .under1Millisecond),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(for: .oneToUnder4Milliseconds),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(for: .fourToUnder16Milliseconds),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(for: .sixteenToUnder50Milliseconds),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(for: .fiftyToUnder100Milliseconds),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(
                for: .oneHundredToUnder500Milliseconds),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(
                for: .fiveHundredToUnder2000Milliseconds),
            2)
        XCTAssertEqual(
            aggregate.histogram.value(for: .atLeast2000Milliseconds),
            1)

        diagnostics.recordDuration(
            .projectionFold,
            nanoseconds: .max)
        diagnostics.recordDuration(
            .projectionFold,
            nanoseconds: 1)
        let saturated = diagnostics.snapshot().durations.value(
            for: .projectionFold)
        XCTAssertEqual(saturated.count, 2)
        XCTAssertEqual(saturated.totalNanoseconds, .max)
        XCTAssertEqual(saturated.maximumNanoseconds, .max)
    }

    func testIntervalDurationRecordsOnceEvenWhenTokenIsCopied() {
        let diagnostics = IntatisPerformanceDiagnostics()
        let token = diagnostics.beginInterval(.markdownQueueWait)
        let copy = token

        diagnostics.endInterval(token)
        diagnostics.endInterval(copy)

        let aggregate = diagnostics.snapshot().durations.value(
            for: .markdownQueueWait)
        XCTAssertEqual(aggregate.count, 1)
        XCTAssertEqual(
            IntatisDiagnosticDurationBucket.allCases.reduce(0) {
                $0 + aggregate.histogram.value(for: $1)
            },
            1)
    }

    func testMetricsSnapshotDecodesLegacyCountersWithoutDurations() throws {
        let legacy = Data(
            #"{"counters":{"projectionBatches":2}}"#.utf8)
        let snapshot = try JSONDecoder().decode(
            IntatisDiagnosticMetricsSnapshot.self,
            from: legacy)

        XCTAssertEqual(snapshot.value(for: .projectionBatches), 2)
        for metric in IntatisDiagnosticDurationMetric.allCases {
            XCTAssertEqual(
                snapshot.durations.value(for: metric).count,
                0)
        }

        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        XCTAssertNotNil(object["durations"])
    }

    func testHangManifestRoundTripCarriesDurationSummaries() throws {
        let diagnostics = IntatisPerformanceDiagnostics()
        diagnostics.recordDuration(
            .markdownPublish,
            nanoseconds: 12_000_000)
        let manifest = IntatisHangDiagnosticManifest(
            source: .mainThreadHeartbeat,
            recordedAt: Date(timeIntervalSince1970: 1),
            processIdentifier: 42,
            mainThreadDelayMilliseconds: 2_000,
            metrics: diagnostics.snapshot())

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(
            IntatisHangDiagnosticManifest.self,
            from: data)
        let publish = try XCTUnwrap(decoded.metrics).durations.value(
            for: .markdownPublish)
        XCTAssertEqual(publish.count, 1)
        XCTAssertEqual(publish.totalNanoseconds, 12_000_000)
        XCTAssertEqual(
            publish.histogram.value(
                for: .fourToUnder16Milliseconds),
            1)
    }

    func testProjectionBatchCountersSealOnceAndFinishOnce() {
        let diagnostics =
            IntatisPerformanceDiagnostics()
        let interval =
            diagnostics.beginProjectionBatch()
        let publication = interval.seal(
            metrics:
                IntatisProjectionBatchMetrics(
                    receivedEnvelopeCount: 17,
                    deltaCount: 15,
                    throughSeq: 42,
                    dirtyMask: 5,
                    foldDurationNanoseconds:
                        900))

        // A copied publication and repeated terminal delivery must not
        // duplicate either counters or the signpost terminal.
        let duplicate = interval.seal(
            metrics:
                IntatisProjectionBatchMetrics(
                    receivedEnvelopeCount: 99,
                    deltaCount: 99,
                    throughSeq: 99,
                    dirtyMask: 99,
                    foldDurationNanoseconds:
                        99))
        publication.finish(
            commitDurationNanoseconds: 700,
            published: true)
        duplicate.finish(
            commitDurationNanoseconds: 800,
            published: false)

        XCTAssertEqual(
            publication.metrics,
            duplicate.metrics)
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(
            snapshot.value(
                for: .projectionBatches),
            1)
        XCTAssertEqual(
            snapshot.value(
                for: .projectionEnvelopes),
            17)
        XCTAssertEqual(
            snapshot.value(
                for: .projectionDeltas),
            15)
        XCTAssertEqual(
            snapshot.durations.value(
                for: .projectionBatch).count,
            1)
        let fold = snapshot.durations.value(for: .projectionFold)
        XCTAssertEqual(fold.count, 1)
        XCTAssertEqual(fold.totalNanoseconds, 900)
        XCTAssertEqual(fold.maximumNanoseconds, 900)
        let commit = snapshot.durations.value(for: .projectionCommit)
        XCTAssertEqual(commit.count, 1)
        XCTAssertEqual(commit.totalNanoseconds, 700)
        XCTAssertEqual(commit.maximumNanoseconds, 700)
    }

    func testCancelledUnsealedProjectionDoesNotInventFoldOrCommit() {
        let diagnostics = IntatisPerformanceDiagnostics()
        diagnostics.beginProjectionBatch().cancel()

        let durations = diagnostics.snapshot().durations
        XCTAssertEqual(durations.value(for: .projectionBatch).count, 1)
        XCTAssertEqual(durations.value(for: .projectionFold).count, 0)
        XCTAssertEqual(durations.value(for: .projectionCommit).count, 0)
    }

    func testSanitizerRemovesPathsURLsAndCredentialShapes() {
        let raw = """
        Path: /Users/example/Projects/Secret/App
        Temp: /private/var/folders/aa/bb/TemporaryItems/file
        URL: https://provider.invalid/v1/chat?token=value
        Authorization: Bearer abcdefghijklmnop
        api_key=sk-supersecretvalue
        """
        let sanitized = IntatisHangDiagnosticTextSanitizer.sanitize(raw)

        XCTAssertFalse(sanitized.contains("/Users/example"))
        XCTAssertFalse(sanitized.contains("/private/var/folders"))
        XCTAssertFalse(sanitized.contains("https://provider.invalid"))
        XCTAssertFalse(sanitized.contains("abcdefghijklmnop"))
        XCTAssertFalse(sanitized.contains("sk-supersecretvalue"))
        XCTAssertTrue(sanitized.contains("[REDACTED"))
    }

    func testHangBundleIsOwnerOnlyAtomicAndBoundedByCount() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent(
            "HangDiagnostics",
            isDirectory: true)
        let store = IntatisHangDiagnosticBundleStore(
            rootURL: root,
            retentionPolicy: .init(
                maximumBundleCount: 2,
                maximumTotalBytes: 1_024 * 1_024))

        for index in 0..<3 {
            let manifest = IntatisHangDiagnosticManifest(
                source: .mainThreadHeartbeat,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                processIdentifier: 42,
                mainThreadDelayMilliseconds: 2_000,
                applicationVersion: "0.12",
                buildVersion: "1",
                metrics: .init(counters: [
                    IntatisDiagnosticCounter.mainThreadIncidents.rawValue:
                        UInt64(index + 1),
                ]))
            _ = try await store.writeBundle(manifest: manifest)
            try await Task.sleep(for: .milliseconds(5))
        }

        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: root.path)
        XCTAssertEqual(
            ((rootAttributes[.posixPermissions] as? NSNumber)?.intValue
                ?? 0) & 0o777,
            0o700)

        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        XCTAssertEqual(children.count, 2)
        for child in children {
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: child.path)
            XCTAssertEqual(
                ((directoryAttributes[.posixPermissions] as? NSNumber)?
                    .intValue ?? 0) & 0o777,
                0o700)
            let manifestURL = child.appendingPathComponent("incident.json")
            let fileAttributes = try FileManager.default.attributesOfItem(
                atPath: manifestURL.path)
            XCTAssertEqual(
                ((fileAttributes[.posixPermissions] as? NSNumber)?
                    .intValue ?? 0) & 0o777,
                0o600)
            XCTAssertNotNil(try DurableOwnerOnlyFile.read(from: manifestURL))
        }

        let latest = try await store.latestManifest(
            processIdentifier: 42,
            recordedAfter: .distantPast)
        XCTAssertEqual(
            latest?.metrics?.value(for: .mainThreadIncidents),
            3)
    }

    func testProductionRetentionIsFiveBundlesAndTwentyMegabytes() {
        XCTAssertEqual(
            IntatisHangDiagnosticRetentionPolicy.production.maximumBundleCount,
            5)
        XCTAssertEqual(
            IntatisHangDiagnosticRetentionPolicy.production.maximumTotalBytes,
            20 * 1_024 * 1_024)
    }

    func testHangBundleRetentionAlsoPrunesByTotalBytes() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent(
            "HangDiagnostics",
            isDirectory: true)
        let store = IntatisHangDiagnosticBundleStore(
            rootURL: root,
            retentionPolicy: .init(
                maximumBundleCount: 10,
                maximumTotalBytes: 2_500))

        for index in 0..<2 {
            let attachment = IntatisHangDiagnosticAttachment.sanitizedText(
                kind: .sample,
                rawData: Data(
                    String(repeating: "\(index)", count: 1_600).utf8),
                maximumBytes: 2_048)
            _ = try await store.writeBundle(
                manifest: .init(
                    source: .externalCapture,
                    recordedAt: Date(
                        timeIntervalSince1970: TimeInterval(index + 1)),
                    processIdentifier: 42),
                attachments: [attachment])
            try await Task.sleep(for: .milliseconds(5))
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        XCTAssertEqual(children.count, 1)
    }

    func testHangBundleSanitizesExternalTextAndLimitsAttachments() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("diagnostics")
        let store = IntatisHangDiagnosticBundleStore(rootURL: root)
        let secret = "Bearer abcdefghijklmnop"
        let path = "/Users/example/Private/workspace"
        let attachment = IntatisHangDiagnosticAttachment.sanitizedText(
            kind: .sample,
            rawData: Data("\(secret)\n\(path)\n".utf8),
            sensitivePaths: ["/Users/example"],
            maximumBytes: 1_024)

        let location = try await store.writeBundle(
            manifest: .init(
                source: .externalCapture,
                recordedAt: Date(),
                processIdentifier: 77,
                capture: .init(
                    sampleSucceeded: true,
                    unifiedLogSucceeded: false,
                    relatedHeartbeatIncidentFound: false)),
            attachments: [attachment])
        let sample = try XCTUnwrap(
            try DurableOwnerOnlyFile.read(
                from: location.directoryURL
                    .appendingPathComponent("sample.txt")))
        let text = try XCTUnwrap(String(data: sample, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(path))
    }

    func testHangBundleRejectsSymlinkRoot() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: target.path)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target)
        let store = IntatisHangDiagnosticBundleStore(rootURL: link)

        do {
            _ = try await store.writeBundle(
                manifest: .init(
                    source: .mainThreadHeartbeat,
                    recordedAt: Date(),
                    processIdentifier: 1,
                    mainThreadDelayMilliseconds: 2_000))
            XCTFail("symlink diagnostic roots must fail closed")
        } catch let error as IntatisHangDiagnosticStoreError {
            XCTAssertEqual(error, .unsafeDirectory)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-hang-diagnostics-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        return url
    }
}
