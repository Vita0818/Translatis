#if canImport(AppKit)
import AppKit
import Foundation
import IntatisCore

/// Process-level owner for the low-overhead main-thread heartbeat.
///
/// The timer runs on a utility queue and never waits synchronously for
/// MainActor. Its pure state machine admits at most one outstanding ping.
/// Application, sleep, sheet/modal and termination notifications suppress
/// known false positives and reset the pending generation.
@MainActor
final class TranslatisMacProcessDiagnostics {
    static let shared = TranslatisMacProcessDiagnostics()

    private enum SuppressionReason: Hashable {
        case inactive
        case sleep
        case sheet
        case knownModal
        case termination
    }

    private let driver: IntatisMainThreadHeartbeatDriver
    private var notificationTokens: [NSObjectProtocol] = []
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var suppressionReasons: Set<SuppressionReason> = []
    private var sheetCount = 0
    private var started = false

    private init() {
        let store: IntatisHangDiagnosticBundleStore?
        if let root = try? IntatisHangDiagnosticBundleStore.defaultRootURL() {
            store = IntatisHangDiagnosticBundleStore(rootURL: root)
        } else {
            store = nil
        }
        driver = IntatisMainThreadHeartbeatDriver(
            store: store,
            applicationVersion:
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String,
            buildVersion:
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion")
                    as? String)
    }

    func start(application: NSApplication) {
        guard !started else { return }
        started = true

        if !application.isActive {
            suppressionReasons.insert(.inactive)
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: application,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setSuppressed(.inactive, active: false)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: application,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setSuppressed(.inactive, active: true)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.willBeginSheetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sheetCount += 1
                self.setSuppressed(.sheet, active: true)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didEndSheetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sheetCount = max(0, self.sheetCount - 1)
                if self.sheetCount == 0 {
                    self.setSuppressed(.sheet, active: false)
                }
            }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setSuppressed(.sleep, active: true)
            }
        })
        workspaceNotificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setSuppressed(.sleep, active: false)
            }
        })

        driver.setSuppressed(!suppressionReasons.isEmpty)
        driver.start { [weak self] generation in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.driver.acknowledge(generation: generation)
            }
        }
    }

    /// Explicit seam for a future product-owned modal that cannot be inferred
    /// from an AppKit sheet or `NSApplication.modalWindow`.
    func setKnownModalPresented(_ presented: Bool) {
        setSuppressed(.knownModal, active: presented)
    }

    func beginTermination() {
        guard !suppressionReasons.contains(.termination) else { return }
        suppressionReasons.insert(.termination)
        driver.terminate()
        removeObservers()
    }

    private func setSuppressed(
        _ reason: SuppressionReason,
        active: Bool
    ) {
        guard !suppressionReasons.contains(.termination) else { return }
        if active {
            suppressionReasons.insert(reason)
        } else {
            suppressionReasons.remove(reason)
        }
        driver.setSuppressed(!suppressionReasons.isEmpty)
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceNotificationTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceNotificationTokens.removeAll()
    }
}

private final class IntatisMainThreadHeartbeatDriver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: IntatisHostApplication.identity.diagnosticSubsystem
            + ".main-thread-heartbeat",
        qos: .utility)
    private let diagnostics = IntatisPerformanceDiagnostics.shared
    private let store: IntatisHangDiagnosticBundleStore?
    private let applicationVersion: String?
    private let buildVersion: String?

    private var state = IntatisMainThreadHeartbeatStateMachine()
    private var timer: DispatchSourceTimer?
    private var mainPing: (@Sendable (UInt64) -> Void)?
    private var started = false

    init(
        store: IntatisHangDiagnosticBundleStore?,
        applicationVersion: String?,
        buildVersion: String?
    ) {
        self.store = store
        self.applicationVersion = applicationVersion
        self.buildVersion = buildVersion
    }

    func start(mainPing: @escaping @Sendable (UInt64) -> Void) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        self.mainPing = mainPing
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lock.unlock()

        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(
                Int(IntatisDiagnosticConstants.heartbeatTickMilliseconds)),
            leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.activate()
    }

    func setSuppressed(_ suppressed: Bool) {
        lock.lock()
        state.setSuppressed(suppressed)
        lock.unlock()
    }

    func acknowledge(generation: UInt64) {
        lock.lock()
        state.acknowledge(generation: generation)
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        state.terminate()
        let timer = self.timer
        self.timer = nil
        mainPing = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let actions = state.tick(atNanoseconds: now)
        let mainPing = self.mainPing
        lock.unlock()

        for action in actions {
            switch action {
            case .enqueuePing(let generation):
                guard let mainPing else { continue }
                DispatchQueue.main.async {
                    mainPing(generation)
                }
            case .warning(let delayMilliseconds):
                diagnostics.recordMainThreadWarning(
                    delayMilliseconds: delayMilliseconds)
            case .incident(let delayMilliseconds):
                diagnostics.recordMainThreadIncident(
                    delayMilliseconds: delayMilliseconds)
                persistIncident(delayMilliseconds: delayMilliseconds)
            }
        }
    }

    private func persistIncident(delayMilliseconds: UInt64) {
        guard let store else { return }
        let manifest = IntatisHangDiagnosticManifest(
            source: .mainThreadHeartbeat,
            recordedAt: Date(),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            mainThreadDelayMilliseconds: delayMilliseconds,
            applicationVersion: applicationVersion,
            buildVersion: buildVersion,
            metrics: diagnostics.snapshot())
        Task(priority: .utility) {
            _ = try? await store.writeBundle(manifest: manifest)
        }
    }
}
#endif
