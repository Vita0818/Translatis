#if DEBUG && canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisSharedUI
import SwiftUI

private struct PhaseLFixtureRuntimeRecord: Codable, Equatable {
    var sessionID: String
    var state: String
    var ticks: Int
    var starts: Int
    var stopRequests: Int
    var settlements: Int
    var lastStopReason: String?
}

private actor PhaseLFixtureUncooperativeStopBarrier {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitIgnoringCancellation() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private final class PhaseLFixtureRuntime: ObservableObject {
    @Published private(set) var record: PhaseLFixtureRuntimeRecord
    @Published var hangsDuringStop = false

    let key: AppSessionRuntimeKey
    private let fileURL: URL
    private let uncooperativeStopBarrier = PhaseLFixtureUncooperativeStopBarrier()
    private var ticker: Task<Void, Never>?

    init(kind: SessionKind, sessionID: SessionID, root: URL) {
        self.key = AppSessionRuntimeKey(kind: kind, sessionID: sessionID)
        self.fileURL = root.appendingPathComponent("\(sessionID.rawValue).json")
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(PhaseLFixtureRuntimeRecord.self, from: $0) }
        var restored = decoded ?? PhaseLFixtureRuntimeRecord(
            sessionID: sessionID.rawValue,
            state: "stopped",
            ticks: 0,
            starts: 0,
            stopRequests: 0,
            settlements: 0,
            lastStopReason: nil)
        if restored.state == "running" || restored.state == "stopping" {
            restored.state = "interrupted"
        }
        self.record = restored
        persist()
    }

    var isRunning: Bool { record.state == "running" }

    func resume() {
        guard !isRunning else { return }
        record.state = "running"
        record.starts += 1
        persist()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
                guard let self, self.record.state == "running" else { return }
                self.record.ticks += 1
                self.persist()
            }
        }
    }

    func shutdown(reason: String) async {
        guard record.state != "settled" else { return }
        record.stopRequests += 1
        record.state = "stopping"
        record.lastStopReason = reason
        persist()
        ticker?.cancel()
        if let ticker { await ticker.value }
        ticker = nil
        if hangsDuringStop {
            // Intentionally ignore cooperative cancellation. The production
            // bounded shutdown coordinator must still return at its deadline.
            // The actor-owned continuation keeps this task suspended without
            // monopolizing MainActor after the deadline cancels it.
            await uncooperativeStopBarrier.waitIgnoringCancellation()
        }
        record.state = "settled"
        record.settlements += 1
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
private final class PhaseLSessionLifecycleFixtureModel: ObservableObject {
    @Published var selected = "a"
    @Published var showsHistory = false
    let runtimeA: PhaseLFixtureRuntime
    let runtimeB: PhaseLFixtureRuntime
    let root: URL

    init(root: URL, manager: AppSessionRuntimeManager? = nil) {
        let manager = manager ?? AppSessionRuntimeManager.shared
        self.root = root
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let sessionA = SessionID(rawValue: "phase-l-a")
        let keyA = AppSessionRuntimeKey(kind: .chat, sessionID: sessionA)
        runtimeA = manager.validationRuntime(
            key: keyA,
            create: {
                PhaseLFixtureRuntime(kind: .chat, sessionID: sessionA, root: root)
            },
            isBusy: { $0.isRunning },
            shutdown: { runtime, reason in
                await runtime.shutdown(reason: reason)
            })
        let sessionB = SessionID(rawValue: "phase-l-b")
        let keyB = AppSessionRuntimeKey(kind: .code, sessionID: sessionB)
        runtimeB = manager.validationRuntime(
            key: keyB,
            create: {
                PhaseLFixtureRuntime(kind: .code, sessionID: sessionB, root: root)
            },
            isBusy: { $0.isRunning },
            shutdown: { runtime, reason in
                await runtime.shutdown(reason: reason)
            })
    }
}

private extension PhaseLSessionLifecycleFixtureModel {
    static func fixtureRoot() -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-TranslatisPhaseLLifecycleFixtureRoot"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("translatis-phase-l-fixture", isDirectory: true)
    }
}

@MainActor
struct PhaseLSessionLifecycleFixtureView: View {
    @StateObject private var model: PhaseLSessionLifecycleFixtureModel

    init() {
        _model = StateObject(wrappedValue: PhaseLSessionLifecycleFixtureModel(
            root: PhaseLSessionLifecycleFixtureModel.fixtureRoot()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phase L Session Lifecycle")
                .font(IntatisTypography.system(.title2, bold: true))
            Text("App-owned offline runtimes · no provider, EventLog, credential, or workspace access")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
            Text(model.root.path)
                .font(IntatisTypography.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button("Session A") {
                    model.selected = "a"
                    model.showsHistory = false
                }
                .accessibilityIdentifier("phase-l.select.a")
                Button("Session B") {
                    model.selected = "b"
                    model.showsHistory = false
                }
                .accessibilityIdentifier("phase-l.select.b")
                Button("History") { model.showsHistory = true }
                    .accessibilityIdentifier("phase-l.show-history")
            }

            if model.showsHistory {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History only changes presentation")
                        .font(IntatisTypography.system(.headline))
                    PhaseLFixtureRuntimeSummary(runtime: model.runtimeA)
                    PhaseLFixtureRuntimeSummary(runtime: model.runtimeB)
                }
                .accessibilityIdentifier("phase-l.history")
            } else {
                PhaseLFixtureRuntimeCard(
                    runtime: model.selected == "a" ? model.runtimeA : model.runtimeB)
            }

            Divider()
            Text("Process snapshot")
                .font(IntatisTypography.system(.headline))
            PhaseLFixtureRuntimeSummary(runtime: model.runtimeA)
            PhaseLFixtureRuntimeSummary(runtime: model.runtimeB)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 460, alignment: .topLeading)
        .accessibilityIdentifier("phase-l.fixture")
    }

}

@MainActor
private struct PhaseLFixtureRuntimeCard: View {
    @ObservedObject var runtime: PhaseLFixtureRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(runtime.record.sessionID.uppercased())
                .font(IntatisTypography.system(.headline))
            PhaseLFixtureRuntimeSummary(runtime: runtime)
            HStack {
                Button("Explicit Resume") { runtime.resume() }
                    .disabled(runtime.isRunning)
                    .accessibilityIdentifier("phase-l.resume.\(runtime.record.sessionID)")
                Toggle("Hang during quit", isOn: Binding(
                    get: { runtime.hangsDuringStop },
                    set: { runtime.hangsDuringStop = $0 }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("phase-l.hang.\(runtime.record.sessionID)")
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct PhaseLFixtureRuntimeSummary: View {
    @ObservedObject var runtime: PhaseLFixtureRuntime

    var body: some View {
        Text("\(runtime.record.sessionID): state=\(runtime.record.state) ticks=\(runtime.record.ticks) starts=\(runtime.record.starts) stops=\(runtime.record.stopRequests) settled=\(runtime.record.settlements)")
            .font(IntatisTypography.system(.body, design: .monospaced))
            .accessibilityIdentifier("phase-l.summary.\(runtime.record.sessionID)")
    }
}
#endif
