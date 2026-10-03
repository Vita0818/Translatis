#if canImport(SwiftUI)
import Foundation

/// Pure draft composition kept outside the recorder implementation so the
/// behavior is identical on every platform and remains easy to test.
public enum ComposerVoiceDraft {
    public static func appending(
        transcript: String,
        to draft: String
    ) -> String {
        let normalized = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return draft }
        guard !draft.isEmpty else { return normalized }
        if draft.last?.isWhitespace == true {
            return draft + normalized
        }
        return draft + " " + normalized
    }
}

#if canImport(AVFoundation)
import AVFoundation
import Combine
import IntatisCore
import IntatisProviders

// This single-model recorded-file runtime is adapted from the first-party
// Flotis AudioRecorder and VoiceInputController pipeline. Flotis comparison,
// settings, global-hotkey, review, clipboard, and input-method layers are not
// part of the Intatis composer integration.

public enum ComposerVoiceInputPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case transcribing
}

private enum ComposerVoiceInputFailure: Error {
    case transcriptionModelNotConfigured
    case microphoneBusy
    case recordingUnavailable
    case recordingTooLarge
    case emptyTranscript
}

enum ComposerAudioRecorderError: Error {
    case recordingAlreadyInProgress
    case microphonePermissionDenied
    case invalidSampleRate
    case invalidChannelCount
    case recordingCouldNotStart
    case recordingFileUnavailable
}

/// Process-wide arbitration prevents two retained session runtimes from
/// recording the same microphone at once. The lock protects only the opaque
/// owner token; audio and transcript data never pass through this object.
private final class ComposerMicrophoneLease: @unchecked Sendable {
    static let shared = ComposerMicrophoneLease()

    private let lock = NSLock()
    private var owner: UUID?

    private init() {}

    func acquire(for candidate: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil || owner == candidate else { return false }
        owner = candidate
        return true
    }

    func release(for candidate: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard owner == candidate else { return }
        owner = nil
    }
}

/// Bridges the system's callback-only permission API into a cancellation-aware
/// async wait. Permission completion and task cancellation race through one
/// locked terminal value, so the checked continuation is resumed exactly once.
private final class ComposerVoicePermissionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private enum ComposerVoiceTemporaryFiles {
    static var audioPrefix: String {
        IntatisHostApplication.identity.storageName + "-Audio-"
    }
    private static let legacyAudioPrefix = "intatis-voice-input-"
    private static let staleAge: TimeInterval = 24 * 60 * 60

    static func removeStaleAudioFiles() {
        removeStaleFiles(withPrefix: audioPrefix)
        removeStaleFiles(withPrefix: legacyAudioPrefix)
    }

    private static func removeStaleFiles(withPrefix prefix: String) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.standardizedFileURL
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-staleAge)
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            guard file.deletingLastPathComponent().standardizedFileURL
                    == directory,
                  let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .creationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let timestamp = values.contentModificationDate
                    ?? values.creationDate,
                  timestamp < cutoff else {
                continue
            }
            try? manager.removeItem(at: file)
        }
    }
}

enum ComposerAudioRecorderSettings {
    static func m4a(
        sampleRate: Int,
        channels: Int
    ) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey:
                AVAudioQuality.high.rawValue,
        ]
    }

    static func wav(
        sampleRate: Int,
        channels: Int
    ) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}

extension TranscriptionAudioFileFormat {
    func composerRecorderSettings(
        sampleRate: Int,
        channels: Int
    ) -> [String: Any] {
        switch self {
        case .m4a:
            return ComposerAudioRecorderSettings.m4a(
                sampleRate: sampleRate,
                channels: channels)
        case .wav:
            return ComposerAudioRecorderSettings.wav(
                sampleRate: sampleRate,
                channels: channels)
        }
    }
}

/// Flotis-style generation-owned recorder. A cancellation that arrives while
/// permission is pending invalidates the generation, so a late TCC callback
/// cannot start a new recording or retain a temporary file.
private final class ComposerAudioRecorder {
    private let stateLock = NSLock()
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var activeGeneration: UUID?

    func startRecording(
        format: TranscriptionAudioFileFormat = .wav,
        sampleRate: Int = 16_000,
        channels: Int = 1
    ) async throws {
        guard (8_000...48_000).contains(sampleRate) else {
            throw ComposerAudioRecorderError.invalidSampleRate
        }
        guard channels == 1 || channels == 2 else {
            throw ComposerAudioRecorderError.invalidChannelCount
        }
        let generation = UUID()
        let accepted = withStateLock { () -> Bool in
            guard activeGeneration == nil, audioRecorder == nil else {
                return false
            }
            activeGeneration = generation
            return true
        }
        guard accepted else {
            throw ComposerAudioRecorderError.recordingAlreadyInProgress
        }

        let microphoneGranted = await Self.requestMicrophoneAccess()
        guard microphoneGranted else {
            clearGeneration(generation)
            throw ComposerAudioRecorderError.microphonePermissionDenied
        }
        do {
            try Task.checkCancellation()
        } catch {
            clearGeneration(generation)
            throw error
        }
        guard isGenerationActive(generation) else {
            throw CancellationError()
        }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .record,
                mode: .measurement,
                options: .duckOthers)
            try session.setActive(
                true,
                options: .notifyOthersOnDeactivation)
        } catch {
            clearGeneration(generation)
            deactivateAudioSession()
            throw error
        }
        #endif

        guard isGenerationActive(generation) else {
            deactivateAudioSession()
            throw CancellationError()
        }

        ComposerVoiceTemporaryFiles.removeStaleAudioFiles()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(ComposerVoiceTemporaryFiles.audioPrefix)\(UUID().uuidString).\(format.fileExtension)",
                isDirectory: false)
        var recorder: AVAudioRecorder?
        do {
            let value = try AVAudioRecorder(
                url: url,
                settings: format.composerRecorderSettings(
                    sampleRate: sampleRate,
                    channels: channels))
            recorder = value
            guard value.prepareToRecord() else {
                throw ComposerAudioRecorderError.recordingCouldNotStart
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path)
            guard value.record() else {
                throw ComposerAudioRecorderError.recordingCouldNotStart
            }
        } catch {
            recorder?.stop()
            clearGeneration(generation)
            try? FileManager.default.removeItem(at: url)
            deactivateAudioSession()
            throw error
        }

        guard let recorder else {
            clearGeneration(generation)
            try? FileManager.default.removeItem(at: url)
            deactivateAudioSession()
            throw ComposerAudioRecorderError.recordingCouldNotStart
        }
        let stillActive = withStateLock { () -> Bool in
            guard activeGeneration == generation else { return false }
            audioRecorder = recorder
            recordingURL = url
            return true
        }
        guard stillActive else {
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
            deactivateAudioSession()
            throw CancellationError()
        }
    }

    func stopRecording() -> URL? {
        let (recorder, url) = withStateLock {
            let recorder = audioRecorder
            let url = recordingURL
            audioRecorder = nil
            recordingURL = nil
            activeGeneration = nil
            return (recorder, url)
        }
        recorder?.stop()
        deactivateAudioSession()

        guard let url,
              let values = try? url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
              ]),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }
        return url
    }

    func cancelRecording() {
        let (recorder, url) = withStateLock {
            let recorder = audioRecorder
            let url = recordingURL
            audioRecorder = nil
            recordingURL = nil
            activeGeneration = nil
            return (recorder, url)
        }
        recorder?.stop()
        deactivateAudioSession()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isGenerationActive(_ generation: UUID) -> Bool {
        withStateLock { activeGeneration == generation }
    }

    private func clearGeneration(_ generation: UUID) {
        withStateLock {
            if activeGeneration == generation {
                activeGeneration = nil
            }
        }
    }

    private func withStateLock<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try operation()
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let request = ComposerVoicePermissionRequest()
            return await withTaskCancellationHandler {
                if Task.isCancelled { return false }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    request.resolve(allowed)
                }
                return await request.wait()
            } onCancel: {
                request.resolve(false)
            }
        @unknown default:
            return false
        }
    }
}

/// Owns one explicit tap-to-record/tap-to-transcribe composer operation.
/// Recorded audio is a bounded owner-only temporary file. The transcript is
/// returned only to the caller's current draft and is never written to the
/// EventLog or ArtifactStore by this controller.
@MainActor
public final class ComposerVoiceInputController: ObservableObject {
    public static let maximumRecordingDuration: TimeInterval = 120
    public static let maximumAudioByteCount =
        maximumTranscriptionUploadBytes

    @Published public private(set) var phase: ComposerVoiceInputPhase = .idle
    @Published public private(set) var errorText: String?

    private struct FrozenRoute {
        let registry: ProviderRegistry
        let runtime: ConfiguredTranscriptionRuntime
    }

    private let ownerID = UUID()
    private var registry: ProviderRegistry
    private var recorder: ComposerAudioRecorder?
    private var frozenRoute: FrozenRoute?
    private var transitionTask: Task<Void, Never>?
    private var transitionID: UUID?
    private var durationTask: Task<Void, Never>?
    private var ownsMicrophoneLease = false
    private var isShutdown = false

    public init(registry: ProviderRegistry) {
        self.registry = registry
    }

    deinit {
        transitionTask?.cancel()
        durationTask?.cancel()
        recorder?.cancelRecording()
        if ownsMicrophoneLease {
            ComposerMicrophoneLease.shared.release(for: ownerID)
        }
    }

    public var isEngaged: Bool { phase != .idle }
    public var isRecording: Bool { phase == .recording }
    public var showsProgress: Bool {
        phase == .requestingPermission || phase == .transcribing
    }
    public var isToggleDisabled: Bool {
        isShutdown || phase == .requestingPermission || phase == .transcribing
    }

    public var buttonSystemImage: String {
        phase == .recording ? "stop.fill" : "mic.fill"
    }

    public var buttonHelp: String {
        switch phase {
        case .idle:
            return IntatisLocalization.string("Start voice input")
        case .requestingPermission:
            return IntatisLocalization.string("Preparing voice input")
        case .recording:
            return IntatisLocalization.string("Stop and transcribe")
        case .transcribing:
            return IntatisLocalization.string("Transcribing voice input")
        }
    }

    public func updateProviderRegistry(_ registry: ProviderRegistry) {
        guard !isShutdown else { return }
        self.registry = registry
    }

    public func toggle(
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        guard !isShutdown else { return }
        switch phase {
        case .idle:
            beginRecording(onTranscript: onTranscript)
        case .recording:
            finishRecording(onTranscript: onTranscript)
        case .requestingPermission, .transcribing:
            break
        }
    }

    public func shutdown() async {
        guard !isShutdown else {
            if let transitionTask { await transitionTask.value }
            return
        }
        isShutdown = true
        durationTask?.cancel()
        durationTask = nil
        let runningTransition = transitionTask
        runningTransition?.cancel()
        releaseCapture()
        if let runningTransition {
            await runningTransition.value
        }
        releaseCapture()
        transitionTask = nil
        transitionID = nil
        phase = .idle
    }

    private func beginRecording(
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        errorText = nil
        phase = .requestingPermission
        let operationID = UUID()
        let registryAtStart = registry
        transitionID = operationID
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completeTransition(operationID) }
            do {
                guard let runtime = try await registryAtStart
                    .configuredTranscriptionRuntime() else {
                    throw ComposerVoiceInputFailure
                        .transcriptionModelNotConfigured
                }
                try Task.checkCancellation()
                guard ComposerMicrophoneLease.shared.acquire(
                    for: self.ownerID) else {
                    throw ComposerVoiceInputFailure.microphoneBusy
                }
                self.ownsMicrophoneLease = true
                let recorder = ComposerAudioRecorder()
                self.recorder = recorder
                self.frozenRoute = FrozenRoute(
                    registry: registryAtStart,
                    runtime: runtime)
                try await recorder.startRecording(
                    format: runtime.audio.format,
                    sampleRate: runtime.audio.sampleRate,
                    channels: runtime.audio.channels)
                try Task.checkCancellation()
                guard !self.isShutdown,
                      self.transitionID == operationID else {
                    throw CancellationError()
                }

                self.phase = .recording
                let maximumSeconds = runtime.audio
                    .maximumRecordingDurationSeconds.map {
                        max(1, $0 - runtime.audio.stopLeadSeconds)
                    }
                if let maximumSeconds {
                    self.scheduleDurationLimit(
                        seconds: TimeInterval(maximumSeconds),
                        onTranscript: onTranscript)
                }
            } catch {
                self.releaseCapture()
                self.phase = .idle
                self.publish(error)
            }
        }
    }

    private func finishRecording(
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        guard phase == .recording,
              let recorder,
              let route = frozenRoute else {
            releaseCapture()
            phase = .idle
            publish(ComposerVoiceInputFailure.recordingUnavailable)
            return
        }

        durationTask?.cancel()
        durationTask = nil
        guard let fileURL = recorder.stopRecording() else {
            self.recorder = nil
            frozenRoute = nil
            releaseMicrophoneLease()
            phase = .idle
            publish(ComposerAudioRecorderError.recordingFileUnavailable)
            return
        }
        self.recorder = nil
        releaseMicrophoneLease()
        frozenRoute = nil
        phase = .transcribing

        let operationID = UUID()
        transitionID = operationID
        transitionTask = Task { @MainActor [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            defer {
                try? FileManager.default.removeItem(at: fileURL)
                self.completeTransition(operationID)
            }
            do {
                try Self.validateBoundedAudioFile(
                    at: fileURL,
                    maximumBytes: route.runtime.audio.maximumUploadBytes
                        ?? Self.maximumAudioByteCount)
                try Task.checkCancellation()
                let provider = try await route.registry
                    .transcriptionProvider(for: route.runtime.model)
                let transcript = try await provider.transcribeFile(
                    TranscriptionFileRequest(
                        model: route.runtime.model.model,
                        fileURL: fileURL))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !transcript.isEmpty else {
                    throw ComposerVoiceInputFailure.emptyTranscript
                }
                guard !self.isShutdown,
                      self.transitionID == operationID else {
                    throw CancellationError()
                }
                onTranscript(transcript)
                self.errorText = nil
                self.phase = .idle
            } catch {
                self.phase = .idle
                self.publish(error)
            }
        }
    }

    private func scheduleDurationLimit(
        seconds: TimeInterval,
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        durationTask?.cancel()
        durationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.phase == .recording else { return }
            self.finishRecording(onTranscript: onTranscript)
        }
    }

    private func releaseCapture() {
        durationTask?.cancel()
        durationTask = nil
        recorder?.cancelRecording()
        recorder = nil
        releaseMicrophoneLease()
        frozenRoute = nil
    }

    private func releaseMicrophoneLease() {
        guard ownsMicrophoneLease else { return }
        ComposerMicrophoneLease.shared.release(for: ownerID)
        ownsMicrophoneLease = false
    }

    private func completeTransition(_ operationID: UUID) {
        guard transitionID == operationID else { return }
        transitionID = nil
        transitionTask = nil
    }

    private func publish(_ error: Error) {
        guard !isShutdown,
              !IntatisCancellation
                .isCurrentTaskCancellation(error) else { return }
        switch error {
        case ComposerVoiceInputFailure
                .transcriptionModelNotConfigured:
            errorText = IntatisLocalization.string(
                "Configure transcription_model before using voice input.")
        case ComposerVoiceInputFailure.microphoneBusy,
             ComposerAudioRecorderError.recordingAlreadyInProgress:
            errorText = IntatisLocalization.string(
                "The microphone is already being used by another \(IntatisHostApplication.identity.name) session.")
        case ComposerAudioRecorderError.microphonePermissionDenied:
            errorText = IntatisLocalization.string(
                "Microphone access was denied. Enable it in System Settings and try again.")
        case ComposerAudioRecorderError.invalidSampleRate,
             ComposerAudioRecorderError.invalidChannelCount,
             ComposerAudioRecorderError.recordingCouldNotStart,
             ComposerAudioRecorderError.recordingFileUnavailable,
             ComposerVoiceInputFailure.recordingUnavailable:
            errorText = IntatisLocalization.string(
                "Voice recording could not start.")
        case ComposerVoiceInputFailure.recordingTooLarge:
            errorText = IntatisLocalization.string(
                "Voice recording is too large to transcribe.")
        case ComposerVoiceInputFailure.emptyTranscript:
            errorText = IntatisLocalization.string(
                "No speech was detected.")
        default:
            errorText = IntatisLocalization.format(
                "Voice input failed: %@",
                error.localizedDescription)
        }
    }

    private nonisolated static func validateBoundedAudioFile(
        at url: URL,
        maximumBytes: Int
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw ComposerVoiceInputFailure.recordingUnavailable
        }
        guard (values.fileSize ?? 0) <= maximumBytes else {
            throw ComposerVoiceInputFailure.recordingTooLarge
        }
    }
}
#endif
#endif
