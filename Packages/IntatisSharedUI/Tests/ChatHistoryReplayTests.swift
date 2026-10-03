#if os(macOS)
import Combine
import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
@testable import IntatisSharedUI

private struct ChatHistoryTestSecretResolver: SecretResolver {
    func secret(for ref: KeychainRef) async throws -> String {
        _ = ref
        return "unused"
    }
}

private actor ChatHistoryBuildGate {
    private var didEnter = false
    private var isReleased = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseFirstBuild() async {
        guard !didEnter else { return }
        didEnter = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum ChatHistorySnapshotTestError: LocalizedError {
    case injectedFailure

    var errorDescription: String? {
        "Injected strict history replay failure."
    }
}

private actor ChatHistorySnapshotScript {
    private var shouldFail = true

    func load(from log: EventLog) async throws -> [Envelope] {
        if shouldFail {
            shouldFail = false
            throw ChatHistorySnapshotTestError.injectedFailure
        }
        return try await log.replayChecked()
    }
}

@MainActor
final class ChatHistoryReplayTests: XCTestCase {
    func testCompletedHistoryPublishesOneMessageSnapshotThenLiveEventsIncrementally() async throws {
        let fixture = try makeFixture("single-snapshot")
        defer {
            fixture.viewModel.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let messageID = MessageID(rawValue: "history-message")
        _ = try await fixture.log.append(.userMessage(.init(text: "question")))
        for fragment in ["A", " completed", " historical", " answer."] {
            _ = try await fixture.log.append(.messageDelta(.init(
                messageId: messageID,
                role: .assistant,
                textDelta: fragment)))
        }
        _ = try await fixture.log.append(.messageCompleted(.init(
            messageId: messageID,
            role: .assistant,
            text: "A completed historical answer.")))

        var messagePublications: [[ChatMessageView]] = []
        let observation = fixture.viewModel.$messages
            .dropFirst()
            .sink { messagePublications.append($0) }
        defer { observation.cancel() }

        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.messages.last?.isComplete == true
        }

        XCTAssertEqual(messagePublications.count, 1)
        XCTAssertEqual(fixture.viewModel.messages.map(\.text), [
            "question",
            "A completed historical answer.",
        ])

        let liveID = MessageID(rawValue: "live-message")
        _ = try await fixture.log.append(.messageDelta(.init(
            messageId: liveID,
            role: .assistant,
            textDelta: "live")))
        try await waitUntil {
            fixture.viewModel.messages.last?.id == liveID
                && fixture.viewModel.messages.last?.text == "live"
        }
        XCTAssertEqual(messagePublications.count, 2)

        _ = try await fixture.log.append(.messageCompleted(.init(
            messageId: liveID,
            role: .assistant,
            text: "live complete")))
        try await waitUntil {
            fixture.viewModel.messages.last?.isComplete == true
                && fixture.viewModel.messages.last?.text == "live complete"
        }
        XCTAssertEqual(messagePublications.count, 3)
    }

    func testHistorySnapshotRestoresArtifactsProgressAndStatsTogether() async throws {
        let fixture = try makeFixture("auxiliary-projections")
        defer {
            fixture.viewModel.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let completedArtifact = ArtifactID(rawValue: "artifact-completed")
        let activeArtifact = ArtifactID(rawValue: "artifact-active")
        _ = try await fixture.log.append(.artifactProgress(.init(
            artifactId: completedArtifact,
            progress: 0.5,
            state: "running")))
        _ = try await fixture.log.append(.artifactAdded(.init(
            artifactId: completedArtifact,
            kind: "image",
            mime: "image/png",
            path: "/tmp/history.png",
            prompt: "history")))
        _ = try await fixture.log.append(.artifactProgress(.init(
            artifactId: activeArtifact,
            progress: 0.25,
            state: "running")))
        _ = try await fixture.log.append(.turnStats(.init(
            promptTokens: 20,
            cachedPromptTokens: 5,
            completionTokens: 7,
            totalTokens: 27,
            model: "history-model")))

        var artifactPublications = 0
        var progressPublications = 0
        var statsPublications = 0
        let artifactObservation = fixture.viewModel.$artifacts
            .dropFirst()
            .sink { _ in artifactPublications += 1 }
        let progressObservation = fixture.viewModel.$artifactProgress
            .dropFirst()
            .sink { _ in progressPublications += 1 }
        let statsObservation = fixture.viewModel.$latestTurnStats
            .dropFirst()
            .sink { _ in statsPublications += 1 }
        defer {
            artifactObservation.cancel()
            progressObservation.cancel()
            statsObservation.cancel()
        }

        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.latestTurnStats?.totalTokens == 27
                && fixture.viewModel.artifacts.count == 1
                && fixture.viewModel.artifactProgress.count == 1
        }

        XCTAssertEqual(artifactPublications, 1)
        XCTAssertEqual(progressPublications, 1)
        XCTAssertEqual(statsPublications, 1)
        XCTAssertEqual(fixture.viewModel.artifacts.first?.id, completedArtifact.rawValue)
        XCTAssertEqual(fixture.viewModel.artifactProgress.first?.id, activeArtifact)
        XCTAssertEqual(fixture.viewModel.latestTurnStats?.model, "history-model")
    }

    func testStrictReplayFailurePublishesErrorWithoutStreamingHistoryAndCanRetry() async throws {
        let script = ChatHistorySnapshotScript()
        let fixture = try makeFixture(
            "strict-replay-failure",
            historySnapshotLoader: { log in
                try await script.load(from: log)
            })
        defer {
            fixture.viewModel.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        for index in 0..<128 {
            _ = try await fixture.log.append(
                .userMessage(.init(text: "history-\(index)")))
        }

        var messagePublications = 0
        let observation = fixture.viewModel.$messages
            .dropFirst()
            .sink { _ in messagePublications += 1 }
        defer { observation.cancel() }

        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.errorText?.contains(
                "Injected strict history replay failure.") == true
        }

        XCTAssertTrue(fixture.viewModel.messages.isEmpty)
        XCTAssertEqual(messagePublications, 0)

        _ = try await fixture.log.append(
            .userMessage(.init(text: "appended-after-failure")))
        await Task.yield()
        XCTAssertTrue(fixture.viewModel.messages.isEmpty)
        XCTAssertEqual(messagePublications, 0)

        // The failed subscription releases its slot, so retry does not need
        // to recreate the process-owned session runtime.
        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.messages.count == 129
                && fixture.viewModel.messages.last?.text
                    == "appended-after-failure"
        }

        XCTAssertEqual(messagePublications, 1)
        XCTAssertNil(fixture.viewModel.errorText)
    }

    func testStartBoundaryDoesNotLoseEventAppendedDuringRestore() async throws {
        let gate = ChatHistoryBuildGate()
        let fixture = try makeFixture(
            "restore-boundary",
            beforeHistoryBuild: { await gate.pauseFirstBuild() })
        defer {
            fixture.viewModel.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        for index in 0..<500 {
            _ = try await fixture.log.append(.userMessage(.init(text: "history-\(index)")))
        }

        fixture.viewModel.start()
        await gate.waitUntilEntered()
        _ = try await fixture.log.append(.userMessage(.init(text: "boundary-live")))
        await gate.release()
        try await waitUntil {
            fixture.viewModel.messages.last?.text == "boundary-live"
        }

        XCTAssertEqual(
            fixture.viewModel.messages.filter { $0.text == "boundary-live" }.count,
            1)
        XCTAssertEqual(fixture.viewModel.messages.count, 501)
    }

    func testStopDuringHistoryFoldRejectsStaleSnapshotAndCanRestart() async throws {
        let gate = ChatHistoryBuildGate()
        let fixture = try makeFixture(
            "restore-stop",
            beforeHistoryBuild: { await gate.pauseFirstBuild() })
        defer {
            fixture.viewModel.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        _ = try await fixture.log.append(.userMessage(.init(text: "history")))

        var messagePublications = 0
        let observation = fixture.viewModel.$messages
            .dropFirst()
            .sink { _ in messagePublications += 1 }
        defer { observation.cancel() }

        fixture.viewModel.start()
        await gate.waitUntilEntered()
        fixture.viewModel.stop()
        await gate.release()
        await Task.yield()

        XCTAssertTrue(fixture.viewModel.messages.isEmpty)
        XCTAssertEqual(messagePublications, 0)

        fixture.viewModel.start()
        try await waitUntil {
            fixture.viewModel.messages.first?.text == "history"
        }
        XCTAssertEqual(messagePublications, 1)
    }

    func testShutdownDuringHistoryFoldRejectsStaleSnapshot() async throws {
        let gate = ChatHistoryBuildGate()
        let fixture = try makeFixture(
            "restore-shutdown",
            beforeHistoryBuild: { await gate.pauseFirstBuild() })
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
        }
        _ = try await fixture.log.append(.userMessage(.init(text: "history")))

        var messagePublications = 0
        let observation = fixture.viewModel.$messages
            .dropFirst()
            .sink { _ in messagePublications += 1 }
        defer { observation.cancel() }

        fixture.viewModel.start()
        await gate.waitUntilEntered()
        let shutdown = Task { @MainActor in
            await fixture.viewModel.shutdown(reason: "test")
        }
        await Task.yield()
        await gate.release()
        await shutdown.value

        XCTAssertTrue(fixture.viewModel.messages.isEmpty)
        XCTAssertEqual(messagePublications, 0)
    }

    private func makeFixture(
        _ name: String,
        beforeHistoryBuild: (@Sendable () async -> Void)? = nil,
        historySnapshotLoader: ChatHistorySnapshotLoader? = nil
    ) throws -> (
        root: URL,
        log: EventLog,
        viewModel: ChatViewModel
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-chat-history-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let session = SessionID(rawValue: "sess_\(name)")
        let log = try EventLog(
            session: session,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let config = ProviderConfig(
            endpoints: [],
            models: ResolvedModels(chat: ModelRef(
                endpoint: "unused",
                model: ModelID(rawValue: "unused"))))
        let registry = ProviderRegistry(
            config: config,
            resolver: ChatHistoryTestSecretResolver())
        let builder = ChatHistoryProjectionBuilder(
            beforeBuild: beforeHistoryBuild)
        return (
            root,
            log,
            ChatViewModel(
                log: log,
                registry: registry,
                historyProjectionBuilder: builder,
                historySnapshotLoader:
                    historySnapshotLoader
                        ?? defaultChatHistorySnapshotLoader))
    }

    private func waitUntil(
        attempts: Int = 2_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for ChatViewModel projection")
    }
}
#endif
