#if os(macOS)
import XCTest
import IntatisCore
import IntatisConversation
@testable import IntatisSharedUI

@MainActor
final class CoworkAgentThreadPresentationModelTests: XCTestCase {
    func testDefaultsToMainAndRejectsNonSelectableReviewer() async {
        let model = makeImmediateModel()
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()

        XCTAssertEqual(model.selectedAgentID, "main")
        XCTAssertEqual(model.snapshot.agentID.rawValue, "main")

        model.select("permission-reviewer")
        await settle()
        XCTAssertEqual(model.selectedAgentID, "main")

        model.select("worker")
        await settle()
        XCTAssertEqual(model.selectedAgentID, "worker")
        XCTAssertEqual(model.snapshot.items.map(\.id), ["worker-row"])
    }

    func testRapidMainToWorkerToWriterCommitsOnlyWriter() async throws {
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadSnapshot: { agentID in
                let delay: UInt64
                switch agentID.rawValue {
                case "main": delay = 80_000_000
                case "worker": delay = 50_000_000
                default: delay = 0
                }
                try? await Task.sleep(nanoseconds: delay)
                return Self.snapshot(agentID: agentID)
            },
            updates: { _ in AsyncStream { $0.finish() } })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker", "writer"])
        model.select("worker")
        model.select("writer")

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(model.selectedAgentID, "writer")
        XCTAssertEqual(model.snapshot.agentID.rawValue, "writer")
        XCTAssertEqual(model.snapshot.items.map(\.id), ["writer-row"])
    }

    func testHistoricalDetachedSelectionRemainsSelected() async {
        let model = makeImmediateModel()
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        model.select("worker")
        await settle()
        XCTAssertEqual(model.selectedAgentID, "worker")

        model.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        XCTAssertEqual(model.selectedAgentID, "worker")
        XCTAssertEqual(model.snapshot.agentID.rawValue, "worker")
    }

    func testSelectionFallsBackWhenIdentityIsMissingFromHistoricalCatalog() async {
        let model = makeImmediateModel()
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        model.select("worker")
        await settle()

        model.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: ["main"])
        await settle()
        XCTAssertEqual(model.selectedAgentID, "main")
        XCTAssertEqual(model.snapshot.agentID.rawValue, "main")
    }

    func testLargeHistoricalCatalogKeepsDetachedIdentitySelectable() async {
        let model = makeImmediateModel()
        let historicalIDs = ["main"]
            + (0..<512).map { "worker-\($0)" }
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: historicalIDs)
        model.select("worker-0")
        await settle()

        model.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: historicalIDs)
        await settle()

        XCTAssertEqual(model.selectedAgentID, "worker-0")
        XCTAssertEqual(model.snapshot.agentID.rawValue, "worker-0")
        XCTAssertEqual(model.snapshot.items.map(\.id), ["worker-0-row"])
    }

    func testEachAgentRestoresItsCompleteContinuousTranscript() async {
        let recorder = SnapshotRequestRecorder()
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadSnapshot: { agentID in
                recorder.requests.append(agentID.rawValue)
                return Self.snapshot(
                    agentID: agentID,
                    rowCount: 40)
            },
            updates: { _ in AsyncStream { $0.finish() } })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        XCTAssertEqual(model.snapshot.items.count, 40)
        XCTAssertEqual(model.snapshot.items.first?.id, "main-row-0")
        XCTAssertEqual(model.snapshot.items.last?.id, "main-row-39")

        model.select("worker")
        await settle()
        model.select("main")
        await settle()

        XCTAssertEqual(model.snapshot.agentID.rawValue, "main")
        XCTAssertEqual(model.snapshot.items.count, 40)
        XCTAssertEqual(recorder.requests.last, "main")
    }

    func testNonSelectedAgentUpdateDoesNotPublishCurrentTranscript() async {
        let recorder = SnapshotRequestRecorder()
        let source = TestAgentThreadUpdateSource()
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadSnapshot: { agentID in
                recorder.requests.append(agentID.rawValue)
                return Self.snapshot(agentID: agentID)
            },
            updates: { agentID in source.stream(for: agentID) })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        let initialCount = recorder.requests.count

        source.publish(agentID: AgentID(rawValue: "worker"))
        await settle()
        XCTAssertEqual(recorder.requests.count, initialCount)

        source.publish(agentID: AgentID(rawValue: "main"))
        await settle()
        XCTAssertEqual(recorder.requests.count, initialCount + 1)
    }

    func testTwoWindowPresentationModelsKeepIndependentSelections() async {
        let firstWindow = makeImmediateModel()
        let secondWindow = makeImmediateModel()
        firstWindow.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        secondWindow.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()

        firstWindow.select("worker")
        await settle()

        XCTAssertEqual(firstWindow.selectedAgentID, "worker")
        XCTAssertEqual(firstWindow.snapshot.agentID.rawValue, "worker")
        XCTAssertEqual(secondWindow.selectedAgentID, "main")
        XCTAssertEqual(secondWindow.snapshot.agentID.rawValue, "main")
    }

    func testRichRenderingWaitsForStableSelectionDwell() async throws {
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            richRenderingDwell: .milliseconds(30),
            loadSnapshot: { agentID in Self.snapshot(agentID: agentID) },
            updates: { _ in AsyncStream { $0.finish() } })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main", "worker"])
        await settle()
        XCTAssertFalse(model.isRichRenderingEligible)

        model.select("worker")
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertFalse(model.isRichRenderingEligible)
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertTrue(model.isRichRenderingEligible)
        XCTAssertEqual(model.snapshot.agentID.rawValue, "worker")
    }

    func testSelectedAgentUpdateRestartsRichRenderingDwell() async throws {
        let source = TestAgentThreadUpdateSource()
        let model = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            richRenderingDwell: .milliseconds(30),
            loadSnapshot: { agentID in Self.snapshot(agentID: agentID) },
            updates: { agentID in source.stream(for: agentID) })
        model.activate(
            mainAgentID: "main",
            selectableAgentIDs: ["main"])
        try await Task.sleep(nanoseconds: 45_000_000)
        XCTAssertTrue(model.isRichRenderingEligible)

        source.publish(agentID: AgentID(rawValue: "main"))
        await Task.yield()
        XCTAssertFalse(model.isRichRenderingEligible)
        try await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertFalse(model.isRichRenderingEligible)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(model.isRichRenderingEligible)
    }

    private func makeImmediateModel() -> CoworkAgentThreadPresentationModel {
        CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadSnapshot: { agentID in
                Self.snapshot(agentID: agentID)
            },
            updates: { _ in AsyncStream { $0.finish() } })
    }

    private static func snapshot(
        agentID: AgentID,
        rowCount: Int = 1
    ) -> CoworkAgentThreadSnapshot {
        return CoworkAgentThreadSnapshot(
            agentID: agentID,
            items: (0..<rowCount).map { index in
                CodeItem(
                    id: rowCount == 1
                        ? "\(agentID.rawValue)-row"
                        : "\(agentID.rawValue)-row-\(index)",
                    kind: .agent,
                    title: agentID.rawValue,
                    body: "\(agentID.rawValue)-\(index)")
            },
            projectedThroughSeq: 1,
            projectionGeneration: UUID(),
            isAgentWorking: false)
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await Task.yield()
    }
}

@MainActor
private final class SnapshotRequestRecorder {
    var requests: [String] = []
}

@MainActor
private final class TestAgentThreadUpdateSource {
    private var continuations: [
        AgentID: [AsyncStream<CoworkAgentThreadUpdate>.Continuation]
    ] = [:]
    private var revision: UInt64 = 0

    func stream(
        for agentID: AgentID
    ) -> AsyncStream<CoworkAgentThreadUpdate> {
        let pair = AsyncStream<CoworkAgentThreadUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        continuations[agentID, default: []].append(pair.continuation)
        return pair.stream
    }

    func publish(agentID: AgentID) {
        revision &+= 1
        let update = CoworkAgentThreadUpdate(
            agentID: agentID,
            throughSeq: Int(revision),
            revision: revision)
        for continuation in continuations[agentID] ?? [] {
            continuation.yield(update)
        }
    }
}
#endif
