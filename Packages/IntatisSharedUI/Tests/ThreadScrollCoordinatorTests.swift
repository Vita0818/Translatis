#if os(macOS)
import IntatisCore
import XCTest
@testable import IntatisSharedUI

@MainActor
final class ThreadScrollCoordinatorTests: XCTestCase {
    private let codeA = IntatisThreadPresentationScope(
        kind: "code",
        sessionID: "code-a")
    private let codeB = IntatisThreadPresentationScope(
        kind: "code",
        sessionID: "code-b")
    private let coworkA = IntatisThreadPresentationScope(
        kind: "cowork",
        sessionID: "cowork-a")

    func testScopeAndBottomAnchorAreSessionSpecific() {
        XCTAssertNotEqual(codeA, codeB)
        XCTAssertNotEqual(codeA, coworkA)
        XCTAssertNotEqual(
            IntatisThreadBottomAnchorID(scope: codeA),
            IntatisThreadBottomAnchorID(scope: codeB))
    }

    func testBottomVisibilityDoesNotUseGeometryPreferences() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surfaces = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            surfaces.contains("IntatisThreadViewportFramesPreferenceKey"))

        for filename in ["CodeViews.swift", "CoworkViews.swift"] {
            let source = try String(
                contentsOf: packageRoot
                    .appendingPathComponent("Sources")
                    .appendingPathComponent(filename),
                encoding: .utf8)
            XCTAssertTrue(
                source.contains(".onScrollVisibilityChange(threshold: 0.99)"),
                filename)
            XCTAssertFalse(source.contains("onPreferenceChange("), filename)
            XCTAssertFalse(source.contains("frame(in: .global)"), filename)
        }
    }

    func testScopeChangeCancelsPendingRequest() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollRequest] = []
        coordinator.activate(scope: codeA)
        coordinator.request(scope: codeA, reason: .liveUpdate) {
            executed.append($0)
        }

        coordinator.activate(scope: codeB)
        await drainMainActor()

        XCTAssertTrue(executed.isEmpty)
        XCTAssertEqual(coordinator.activeScope, codeB)
        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(coordinator.cancellationCount, 1)
    }

    func testLazyEntrySuspendsRichUntilRawBottomAnchorIsVisible() async {
        let coordinator = IntatisThreadScrollCoordinator()

        XCTAssertEqual(
            coordinator.effectiveViewportAdmission(
                for: codeA,
                defersUntilInitialRestore: true),
            .suspended(generation: 1))

        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        guard case let .suspended(entryGeneration) =
                coordinator.viewportAdmission else {
            return XCTFail("lazy entry must start raw-only")
        }

        var admissionInsideExecutor: IntatisMessageViewportAdmission?
        coordinator.request(scope: codeA, reason: .initialRestore) { _ in
            admissionInsideExecutor = coordinator.viewportAdmission
        }
        await drainMainActor()

        XCTAssertEqual(
            admissionInsideExecutor,
            .suspended(generation: entryGeneration))
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .suspended(generation: entryGeneration))
        coordinator.observeBottomAnchorVisibility(
            true,
            scope: codeA)
        guard case let .idleDwell(dwellGeneration) =
                coordinator.viewportAdmission else {
            return XCTFail(
                "rich work must dwell after bottom anchor confirms restore")
        }
        XCTAssertGreaterThan(dwellGeneration, entryGeneration)
    }

    func testEagerEntryKeepsImmediateRichAdmission() async {
        let coordinator = IntatisThreadScrollCoordinator()

        XCTAssertEqual(
            coordinator.effectiveViewportAdmission(
                for: codeA,
                defersUntilInitialRestore: false),
            .immediate)
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: false)
        XCTAssertEqual(coordinator.viewportAdmission, .immediate)

        var admissionInsideExecutor: IntatisMessageViewportAdmission?
        coordinator.request(scope: codeA, reason: .initialRestore) { _ in
            admissionInsideExecutor = coordinator.viewportAdmission
        }
        await drainMainActor()

        XCTAssertEqual(admissionInsideExecutor, .immediate)
        XCTAssertEqual(coordinator.viewportAdmission, .immediate)
    }

    func testCompletionCanReplaceInitialRestoreWithoutLeavingRichSuspended() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollReason] = []
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)

        coordinator.request(scope: codeA, reason: .initialRestore) {
            executed.append($0.reason)
        }
        coordinator.request(scope: codeA, reason: .completion) {
            XCTAssertEqual(
                coordinator.viewportAdmission,
                .suspended(generation: 1))
            executed.append($0.reason)
        }
        await drainMainActor()

        XCTAssertEqual(executed, [.completion])
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .suspended(generation: 1))
        coordinator.observeBottomAnchorVisibility(
            true,
            scope: codeA)
        guard case .idleDwell = coordinator.viewportAdmission else {
            return XCTFail(
                "replacement placement needs one bottom confirmation")
        }
    }

    func testRapidABARestoreOnlyFinalScopeCanReleaseRichAdmission() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executedScopes: [IntatisThreadPresentationScope] = []

        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        coordinator.request(scope: codeA, reason: .initialRestore) {
            executedScopes.append($0.scope)
        }

        coordinator.activate(
            scope: codeB,
            defersRichUntilInitialRestore: true)
        coordinator.request(scope: codeB, reason: .initialRestore) {
            executedScopes.append($0.scope)
        }

        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        coordinator.request(scope: codeA, reason: .initialRestore) {
            XCTAssertEqual(
                coordinator.viewportAdmission,
                .suspended(generation: 3))
            executedScopes.append($0.scope)
        }
        await drainMainActor()

        XCTAssertEqual(executedScopes, [codeA])
        XCTAssertEqual(coordinator.activeScope, codeA)
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .suspended(generation: 3))
        coordinator.observeBottomAnchorVisibility(
            true,
            scope: codeA)
        guard case let .idleDwell(generation) =
                coordinator.viewportAdmission else {
            return XCTFail("final A restore must release only final A")
        }
        XCTAssertEqual(generation, 4)
    }

    func testUserInteractionCancelsPendingEntryRestoreBeforeRichDwell() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executions = 0
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        coordinator.request(scope: codeA, reason: .initialRestore) { _ in
            executions += 1
        }

        coordinator.userInteractionDidBegin(scope: codeA)
        coordinator.observeGeometry(
            false,
            contentHeight: 2_000,
            scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)
        await drainMainActor()

        XCTAssertEqual(executions, 0)
        XCTAssertEqual(coordinator.followState, .detachedByUser)
        guard case .idleDwell = coordinator.viewportAdmission else {
            return XCTFail("the user's idle dwell must replace entry admission")
        }
    }

    func testLazyEntryDoesNotReleaseWithoutVisibleBottomAnchor() async {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        coordinator.request(scope: codeA, reason: .initialRestore) { _ in }
        await drainMainActor()

        coordinator.observeGeometry(
            false,
            contentHeight: 2_000,
            scope: codeA)
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .suspended(generation: 1))

        coordinator.observeBottomAnchorVisibility(true, scope: codeA)
        guard case .idleDwell = coordinator.viewportAdmission else {
            return XCTFail("only a visible bottom anchor may release rich")
        }
    }

    func testLazyEntryAcceptsPostRestoreBottomScrollGeometry() async {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)

        coordinator.request(scope: codeA, reason: .initialRestore) { _ in }
        await drainMainActor()
        coordinator.observeGeometry(
            true,
            contentHeight: 2_000,
            scope: codeA)

        guard case .idleDwell = coordinator.viewportAdmission else {
            return XCTFail(
                "post-restore bottom scroll geometry must release rich")
        }
    }

    func testLazyEntryRejectsStalePreRestoreBottomScrollGeometry() async {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        coordinator.observeGeometry(
            true,
            contentHeight: 2_000,
            scope: codeA)

        coordinator.request(scope: codeA, reason: .initialRestore) { _ in }
        await drainMainActor()
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .suspended(generation: 1))

        coordinator.observeGeometry(
            true,
            contentHeight: 2_000,
            scope: codeA)
        guard case .idleDwell = coordinator.viewportAdmission else {
            return XCTFail(
                "only geometry newer than the restore execution may release rich")
        }
    }

    func testLateRichCommitCannotCrossScopeOrABAActivation() async throws {
        let coordinator = IntatisThreadScrollCoordinator()
        var executions: [IntatisThreadPresentationScope] = []

        coordinator.activate(scope: codeA)
        let firstA = try XCTUnwrap(coordinator.richSettleSource)
        coordinator.installScrollExecutor(scope: codeA) {
            executions.append($0.scope)
        }
        coordinator.observeGeometry(
            true,
            contentHeight: 1_000,
            scope: codeA)

        coordinator.activate(scope: codeB)
        let sourceB = try XCTUnwrap(coordinator.richSettleSource)
        coordinator.installScrollExecutor(scope: codeB) {
            executions.append($0.scope)
        }
        coordinator.observeGeometry(
            true,
            contentHeight: 1_000,
            scope: codeB)

        coordinator.richDocumentDidCommit(
            token: richToken("late-a"),
            source: firstA)
        try await Task.sleep(for: .milliseconds(180))
        await drainMainActor()
        XCTAssertTrue(executions.isEmpty)

        coordinator.activate(scope: codeA)
        let secondA = try XCTUnwrap(coordinator.richSettleSource)
        XCTAssertNotEqual(firstA, secondA)
        coordinator.installScrollExecutor(scope: codeA) {
            executions.append($0.scope)
        }
        coordinator.observeGeometry(
            true,
            contentHeight: 1_000,
            scope: codeA)

        coordinator.richDocumentDidCommit(
            token: richToken("stale-first-a"),
            source: firstA)
        try await Task.sleep(for: .milliseconds(180))
        await drainMainActor()
        XCTAssertTrue(executions.isEmpty)

        coordinator.richDocumentDidCommit(
            token: richToken("current-a"),
            source: secondA)
        try await Task.sleep(for: .milliseconds(180))
        await drainMainActor()
        XCTAssertEqual(executions, [codeA])
        XCTAssertNotEqual(sourceB, secondA)
    }

    func testFiveHundredUpdatesUseFixedWindowLeadingTrailingCadence() {
        var model = IntatisThreadScrollCadenceModel()
        var executed: [IntatisThreadScrollRequest] = []
        let step: UInt64 = 2_000_000

        for index in 0..<500 {
            let now = UInt64(index) * step
            fireDueRequests(
                model: &model,
                through: now,
                executed: &executed)
            _ = model.submit(
                request(
                    generation: UInt64(index + 1),
                    reason: .liveUpdate),
                nowNanoseconds: now)
        }
        fireDueRequests(
            model: &model,
            through: 1_100_000_000,
            executed: &executed)

        XCTAssertFalse(executed.isEmpty)
        XCTAssertEqual(executed.first?.generation, 1)
        XCTAssertEqual(executed.last?.generation, 500)
        XCTAssertLessThanOrEqual(executed.count, 11)
        XCTAssertNil(model.executorRequest)
        XCTAssertNil(model.pendingRequest)
    }

    func testCadenceDeadlineIsNotResetByEveryUpdate() {
        var model = IntatisThreadScrollCadenceModel()
        _ = model.submit(
            request(generation: 1, reason: .liveUpdate),
            nowNanoseconds: 0)
        let first = model.fire(nowNanoseconds: 0)
        XCTAssertEqual(first?.request.generation, 1)

        for generation in 2...100 {
            _ = model.submit(
                request(
                    generation: UInt64(generation),
                    reason: .liveUpdate),
                nowNanoseconds: UInt64(generation) * 500_000)
        }

        XCTAssertEqual(
            model.executorDeadlineNanoseconds,
            IntatisThreadScrollCadenceModel.intervalNanoseconds)
        XCTAssertEqual(
            model.fire(nowNanoseconds: 99_999_999),
            nil)
        XCTAssertEqual(
            model.fire(nowNanoseconds: 100_000_000)?.request.generation,
            100)
    }

    func testCadenceOwnsOneExecutorRequestAndAtMostOnePendingLatest() {
        var model = IntatisThreadScrollCadenceModel()
        var maximumPending = 0

        for generation in 1...500 {
            _ = model.submit(
                request(
                    generation: UInt64(generation),
                    reason: .liveUpdate),
                nowNanoseconds: 0)
            maximumPending = max(maximumPending, model.pendingCount)
        }

        XCTAssertEqual(maximumPending, 1)
        XCTAssertEqual(model.executorRequest?.generation, 1)
        XCTAssertEqual(model.pendingRequest?.generation, 500)
        XCTAssertEqual(model.outstandingRequests.count, 2)

        XCTAssertEqual(
            model.fire(nowNanoseconds: 0)?.request.generation,
            1)
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.executorRequest?.generation, 500)
        XCTAssertEqual(
            model.fire(
                nowNanoseconds:
                    IntatisThreadScrollCadenceModel.intervalNanoseconds)?
                .request.generation,
            500)
        XCTAssertNil(model.executorRequest)
        XCTAssertNil(model.pendingRequest)
    }

    func testCompletionFlushesPendingLiveUpdateOnNextWake() {
        var model = IntatisThreadScrollCadenceModel()
        _ = model.submit(
            request(generation: 1, reason: .liveUpdate),
            nowNanoseconds: 0)
        _ = model.submit(
            request(generation: 2, reason: .liveUpdate),
            nowNanoseconds: 10_000_000)
        _ = model.submit(
            request(generation: 3, reason: .completion),
            nowNanoseconds: 20_000_000)

        let fire = model.fire(nowNanoseconds: 20_000_000)
        XCTAssertEqual(fire?.request.reason, .completion)
        XCTAssertEqual(fire?.request.generation, 3)
        XCTAssertFalse(fire?.request.animated ?? true)
        XCTAssertNil(model.pendingRequest)
    }

    func testTenThousandGeometryObservationsNeverExecuteScroll() async {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(scope: codeA)

        for index in 0..<10_000 {
            coordinator.observeGeometry(
                index.isMultiple(of: 2),
                contentHeight: CGFloat(1_000 + index),
                scope: codeA)
        }
        await drainMainActor()

        XCTAssertEqual(coordinator.geometryObservationCount, 10_000)
        XCTAssertEqual(coordinator.executionCount, 0)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testTenThousandProductionGeometryCallbacksCoalesceToLatestObservation() async {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(scope: codeA)
        coordinator.userInteractionDidBegin(scope: codeA)

        for index in 0..<10_000 {
            coordinator.enqueueGeometryObservation(
                index.isMultiple(of: 2),
                contentHeight: CGFloat(1_000 + index),
                scope: codeA)
        }

        XCTAssertEqual(coordinator.geometryObservationCount, 0)
        coordinator.userInteractionDidEnd(scope: codeA)
        await drainMainActor()

        XCTAssertEqual(coordinator.geometryObservationCount, 1)
        XCTAssertEqual(coordinator.followState, .detachedByUser)
        XCTAssertEqual(coordinator.executionCount, 0)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testInteractionStateDetachesAndJumpExplicitlyRestoresFollowing() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollReason] = []
        coordinator.activate(scope: codeA)

        coordinator.userInteractionDidBegin(scope: codeA)
        XCTAssertEqual(coordinator.viewportAdmission, .immediate)
        XCTAssertEqual(coordinator.followState, .gestureSuspended)
        coordinator.observeGeometry(
            false,
            contentHeight: 2_000,
            scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)

        XCTAssertEqual(coordinator.followState, .detachedByUser)
        XCTAssertEqual(coordinator.viewportAdmission, .immediate)
        XCTAssertNil(coordinator.request(
            scope: codeA,
            reason: .liveUpdate
        ) { executed.append($0.reason) })

        coordinator.jumpToLatest(scope: codeA) {
            executed.append($0.reason)
        }
        await drainMainActor()

        XCTAssertEqual(coordinator.followState, .followingBottom)
        XCTAssertEqual(executed, [.jumpToLatest])
    }

    func testSettledLazyAdmissionDoesNotChurnDuringInteraction() async {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(
            scope: codeA,
            defersRichUntilInitialRestore: true)
        coordinator.request(scope: codeA, reason: .initialRestore) { _ in }
        await drainMainActor()
        coordinator.observeBottomAnchorVisibility(true, scope: codeA)
        guard case let .idleDwell(generation) =
                coordinator.viewportAdmission else {
            return XCTFail("entry must establish one stable lazy dwell epoch")
        }

        coordinator.userInteractionDidBegin(scope: codeA)
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .idleDwell(generation: generation))
        coordinator.observeGeometry(
            false,
            contentHeight: 2_000,
            scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)
        XCTAssertEqual(
            coordinator.viewportAdmission,
            .idleDwell(generation: generation))
    }

    func testReturningToBottomDuringNewGestureRestoresFollowing() {
        let coordinator = IntatisThreadScrollCoordinator()
        coordinator.activate(scope: codeA)
        coordinator.userInteractionDidBegin(scope: codeA)
        coordinator.observeGeometry(
            false,
            contentHeight: 2_000,
            scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)
        XCTAssertEqual(coordinator.followState, .detachedByUser)

        coordinator.userInteractionDidBegin(scope: codeA)
        coordinator.observeGeometry(
            true,
            contentHeight: 2_000,
            scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)
        XCTAssertEqual(coordinator.followState, .followingBottom)
    }

    func testInitialRestoreAndCompletionAreBothUnanimated() async {
        let coordinator = IntatisThreadScrollCoordinator()
        var executed: [IntatisThreadScrollRequest] = []
        coordinator.activate(scope: codeA)
        coordinator.request(scope: codeA, reason: .initialRestore) {
            executed.append($0)
        }
        await drainMainActor()
        coordinator.request(scope: codeA, reason: .completion) {
            executed.append($0)
        }
        await drainMainActor()

        XCTAssertEqual(executed.map(\.reason), [.initialRestore, .completion])
        XCTAssertEqual(executed.map(\.animated), [false, false])
    }

    func testWindowLocalCoordinatorsDoNotCancelEachOther() async {
        let firstWindow = IntatisThreadScrollCoordinator()
        let secondWindow = IntatisThreadScrollCoordinator()
        var firstExecutions = 0
        var secondExecutions = 0
        firstWindow.activate(scope: codeA)
        secondWindow.activate(scope: codeA)

        firstWindow.request(scope: codeA, reason: .liveUpdate) { _ in
            firstExecutions += 1
        }
        secondWindow.request(scope: codeA, reason: .liveUpdate) { _ in
            secondExecutions += 1
        }
        firstWindow.deactivate(scope: codeA)
        await drainMainActor()

        XCTAssertEqual(firstExecutions, 0)
        XCTAssertEqual(secondExecutions, 1)
    }

    func testGeometryUsesToleranceAndIgnoresSubpixelHeightJitter() {
        let atBottom = IntatisThreadScrollGeometry.measure(
            contentOffsetY: 476,
            containerHeight: 500,
            bottomInset: 0,
            contentHeight: 1_000)
        XCTAssertTrue(atBottom.isAtBottom)

        let previous = IntatisThreadScrollGeometry(
            isAtBottom: true,
            contentHeight: 1_000)
        let jitter = IntatisThreadScrollGeometry(
            isAtBottom: false,
            contentHeight: 1_000.5)
        let materialGrowth = IntatisThreadScrollGeometry(
            isAtBottom: false,
            contentHeight: 1_002)
        XCTAssertFalse(jitter.hasMaterialHeightChange(from: previous))
        XCTAssertTrue(materialGrowth.hasMaterialHeightChange(from: previous))
        XCTAssertEqual(previous, IntatisThreadScrollGeometry(
            isAtBottom: true,
            contentHeight: 9_999))
        XCTAssertNotEqual(previous, materialGrowth)
    }

    func testProductionGeometryCallbacksAreObservationOnly() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for filename in ["CodeViews.swift", "CoworkViews.swift"] {
            let source = try String(
                contentsOf: packageRoot
                    .appendingPathComponent("Sources")
                    .appendingPathComponent(filename),
                encoding: .utf8)
            let start = try XCTUnwrap(
                source.range(of: ".onScrollGeometryChange("))
            let end = try XCTUnwrap(source.range(
                of: ".onScrollPhaseChange",
                range: start.upperBound..<source.endIndex))
            let callback = source[start.lowerBound..<end.lowerBound]

            XCTAssertTrue(
                callback.contains("enqueueGeometryObservation("),
                filename)
            XCTAssertFalse(callback.contains("observeGeometry("), filename)
            XCTAssertFalse(callback.contains("requestScroll("), filename)
            XCTAssertFalse(
                callback.contains("richHeightCorrection"),
                filename)
            XCTAssertFalse(callback.contains("Task {"), filename)
        }
    }

    func testMacRichTranscriptSurfacesUseContinuousViewportBoundedStacks()
        throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = [
            packageRoot.appendingPathComponent("Sources/CodeViews.swift"),
            packageRoot.appendingPathComponent("Sources/CoworkViews.swift"),
            repoRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/TranslatisChatScreen.swift"),
        ]

        for sourceURL in sources {
            let source = try String(
                contentsOf: sourceURL,
                encoding: .utf8)
            XCTAssertTrue(
                source.contains("IntatisContinuousThreadStack("),
                sourceURL.lastPathComponent)
            XCTAssertFalse(
                source.contains("IntatisThreadHistoryPager("),
                sourceURL.lastPathComponent)
            XCTAssertFalse(
                source.contains("requestedUpperBound"),
                sourceURL.lastPathComponent)
            XCTAssertFalse(
                source.contains("onShowEarlier"),
                sourceURL.lastPathComponent)
        }

        let surfaceSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        XCTAssertTrue(surfaceSource.contains("LazyVStack("))
        XCTAssertTrue(surfaceSource.contains(
            "maximumActiveRichRows = 16"))
        XCTAssertTrue(surfaceSource.contains(
            "onScrollVisibilityChange(threshold: 0.01)"))
    }

    func testRichSettleClosesBeforeReturningSingleSettlement() {
        var model = IntatisThreadRichSettleModel()
        let token = IntatisThreadRichSettleToken.finalDocument(
            messageID: "message",
            contentUTF8Count: 100,
            contentHash: 7,
            appearance: "light",
            typography: "large",
            configurationRevision: 3)

        XCTAssertEqual(
            model.open(
                token: token,
                contentHeight: 1_000,
                nowNanoseconds: 0),
            .wait(untilNanoseconds: 100_000_000))
        model.observe(
            contentHeight: 1_000.5,
            nowNanoseconds: 50_000_000)
        XCTAssertEqual(
            model.check(nowNanoseconds: 100_000_000),
            .settled(token: token))
        XCTAssertNil(model.epoch)
        XCTAssertEqual(
            model.check(nowNanoseconds: 200_000_000),
            .inactive)
        XCTAssertEqual(
            model.open(
                token: token,
                contentHeight: 1_100,
                nowNanoseconds: 300_000_000),
            .inactive)
    }

    func testRichSettleWaitsForQuietButHonorsHardCap() {
        var model = IntatisThreadRichSettleModel()
        let token = IntatisThreadRichSettleToken.width(900_000)
        _ = model.open(
            token: token,
            contentHeight: 1_000,
            nowNanoseconds: 0)

        for time: UInt64 in [90_000_000, 180_000_000, 270_000_000,
                             360_000_000, 450_000_000] {
            model.observe(
                contentHeight: CGFloat(1_000 + time / 1_000_000),
                nowNanoseconds: time)
            if time < 450_000_000 {
                guard case .wait = model.check(
                    nowNanoseconds: time + 10_000_000) else {
                    return XCTFail("material changes must extend quiet wait")
                }
            }
        }

        XCTAssertEqual(
            model.check(nowNanoseconds: 500_000_000),
            .settled(token: token))
        XCTAssertNil(model.epoch)
    }

    func testStaleWidthCallbackCannotReplaceCurrentScopeExecutor() async throws {
        let coordinator = IntatisThreadScrollCoordinator()
        var currentScopeExecutions = 0
        var staleScopeExecutions = 0
        coordinator.activate(scope: codeA)
        coordinator.installScrollExecutor(scope: codeA) { _ in
            currentScopeExecutions += 1
        }

        coordinator.openWidthSettleEpoch(
            scope: codeB,
            width: 720
        ) { _ in
            staleScopeExecutions += 1
        }
        let source = try XCTUnwrap(coordinator.richSettleSource)
        coordinator.richDocumentDidCommit(
            token: .finalDocument(
                messageID: "current",
                contentUTF8Count: 10,
                contentHash: 7,
                appearance: "light",
                typography: "large",
                configurationRevision: 3),
            source: source)

        try await Task.sleep(for: .milliseconds(180))
        await drainMainActor()
        XCTAssertEqual(currentScopeExecutions, 1)
        XCTAssertEqual(staleScopeExecutions, 0)
    }

    func testScrollDiagnosticReasonsPreserveSemanticSource() {
        XCTAssertEqual(
            IntatisThreadScrollReason.initialRestore.diagnosticReason.rawValue,
            IntatisScrollDiagnosticReason.initialRestore.rawValue)
        XCTAssertEqual(
            IntatisThreadScrollReason.liveUpdate.diagnosticReason.rawValue,
            IntatisScrollDiagnosticReason.liveContent.rawValue)
        XCTAssertEqual(
            IntatisThreadScrollReason.completion.diagnosticReason.rawValue,
            IntatisScrollDiagnosticReason.completion.rawValue)
        XCTAssertEqual(
            IntatisThreadScrollReason.richHeightCorrection
                .diagnosticReason.rawValue,
            IntatisScrollDiagnosticReason.richSettle.rawValue)
        XCTAssertEqual(
            IntatisThreadScrollReason.jumpToLatest.diagnosticReason.rawValue,
            IntatisScrollDiagnosticReason.manualJump.rawValue)
    }

    func testScrollDiagnosticsAggregateEveryOutcomeWithoutGeometryNoise() async {
        let diagnostics = IntatisPerformanceDiagnostics()
        let coordinator = IntatisThreadScrollCoordinator(
            performanceDiagnostics: diagnostics)
        coordinator.activate(scope: codeA)

        coordinator.request(
            scope: codeA,
            reason: .initialRestore
        ) { _ in }
        await drainMainActor()

        coordinator.userInteractionDidBegin(scope: codeA)
        coordinator.observeGeometry(
            false,
            contentHeight: 2_000,
            scope: codeA)
        coordinator.userInteractionDidEnd(scope: codeA)
        XCTAssertNil(coordinator.request(
            scope: codeA,
            reason: .liveUpdate
        ) { _ in })
        XCTAssertNil(coordinator.request(
            scope: codeB,
            reason: .completion
        ) { _ in })

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.value(for: .scrollRequested), 1)
        XCTAssertEqual(snapshot.value(for: .scrollExecuted), 1)
        XCTAssertEqual(snapshot.value(for: .scrollCancelled), 1)
        XCTAssertEqual(snapshot.value(for: .scrollStale), 1)

        for index in 0..<1_000 {
            coordinator.observeGeometry(
                index.isMultiple(of: 2),
                contentHeight: CGFloat(2_000 + index),
                scope: codeA)
        }
        XCTAssertEqual(diagnostics.snapshot(), snapshot)
    }

    private func request(
        generation: UInt64,
        reason: IntatisThreadScrollReason
    ) -> IntatisThreadScrollRequest {
        IntatisThreadScrollRequest(
            scope: codeA,
            generation: generation,
            reason: reason,
            animated: false,
            wasBottomFollowing: true)
    }

    private func richToken(_ messageID: String)
        -> IntatisThreadRichSettleToken {
        .finalDocument(
            messageID: messageID,
            contentUTF8Count: 10,
            contentHash: 7,
            appearance: "light",
            typography: "large",
            configurationRevision: 3)
    }

    private func fireDueRequests(
        model: inout IntatisThreadScrollCadenceModel,
        through now: UInt64,
        executed: inout [IntatisThreadScrollRequest]
    ) {
        while let deadline = model.executorDeadlineNanoseconds,
              deadline <= now {
            guard let fire = model.fire(nowNanoseconds: deadline) else {
                XCTFail("scheduled deadline must fire")
                return
            }
            executed.append(fire.request)
        }
    }

    private func drainMainActor() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}
#endif
