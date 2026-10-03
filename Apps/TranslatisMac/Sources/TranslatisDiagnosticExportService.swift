#if canImport(AppKit)
import AppKit
import Foundation
import IntatisCore
import IntatisSharedUI

#if canImport(Darwin)
import Darwin
#endif

struct IntatisDiagnosticExportResult: Sendable {
    let archiveFileName: String
    let archiveByteCount: Int
    let collectionErrorCount: Int
}

enum IntatisDiagnosticExportError: Error, LocalizedError {
    case couldNotPrepare
    case archiveFailed(String)
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .couldNotPrepare:
            return "The local diagnostic bundle could not be prepared safely."
        case .archiveFailed(let detail):
            return detail.isEmpty
                ? "The diagnostic ZIP could not be created."
                : "The diagnostic ZIP could not be created: \(detail)"
        case .archiveTooLarge:
            return "The diagnostic ZIP exceeded the 96 MiB safety limit."
        }
    }
}

@MainActor
enum IntatisDiagnosticExportService {
    static func suggestedArchiveName(now: Date = Date()) -> String {
        IntatisHostApplication.identity.storageName
            + "-Diagnostics-\(fileTimestamp(now)).zip"
    }

    static func export(to destinationURL: URL) async throws
        -> IntatisDiagnosticExportResult
    {
        let catalog = AppConfig.providerCatalog
        let library = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let hangRoot = try? IntatisHangDiagnosticBundleStore.defaultRootURL()
        let context = IntatisDiagnosticExportContext(
            generatedAt: Date(),
            destinationURL: destinationURL,
            applicationSupportRoot: AppConfig.appSupportDir(),
            hangDiagnosticsRoot: hangRoot,
            crashReportRoots: [
                library.appendingPathComponent(
                    "Logs/DiagnosticReports",
                    isDirectory: true),
                library.appendingPathComponent(
                    "Logs/DiagnosticReports/Retired",
                    isDirectory: true),
            ],
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String,
            operatingSystemVersion:
                ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            selectedProviderID: catalog.selectedProviderID,
            selectedModelID: catalog.selectedModelID,
            selectedVariantID: catalog.selectedVariantID,
            providerCount: catalog.providers.count,
            modelCount: catalog.providers.reduce(0) { $0 + $1.models.count },
            rendererMode: IntatisMessageRendererMode.resolve(
                persistedRawValue: UserDefaults.standard.string(
                    forKey: IntatisMessageRendererMode.defaultsKey),
                arguments: ProcessInfo.processInfo.arguments).rawValue,
            performanceMetrics: try? JSONEncoder().encode(
                IntatisPerformanceDiagnostics.shared.snapshot()))

        let work = Task.detached(priority: .utility) {
            try IntatisDiagnosticBundleBuilder(context: context).build()
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct IntatisDiagnosticExportContext: Sendable {
    let generatedAt: Date
    let destinationURL: URL
    let applicationSupportRoot: URL
    let hangDiagnosticsRoot: URL?
    let crashReportRoots: [URL]
    let applicationVersion: String?
    let buildVersion: String?
    let operatingSystemVersion: String
    let architecture: String
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let processIdentifier: Int32
    let selectedProviderID: String
    let selectedModelID: String
    let selectedVariantID: String?
    let providerCount: Int
    let modelCount: Int
    let rendererMode: String
    let performanceMetrics: Data?
}

private struct IntatisDiagnosticExportManifest: Codable {
    struct Application: Codable {
        let name: String
        let version: String?
        let build: String?
        let processIdentifier: Int32
        let rendererMode: String
        let selectedProviderID: String
        let selectedModelID: String
        let selectedVariantID: String?
        let providerCount: Int
        let modelCount: Int
    }

    struct System: Codable {
        let operatingSystemVersion: String
        let architecture: String
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    struct Privacy: Codable {
        let remoteUploadPerformed: Bool
        let eventPayloadPolicy: String
        let excludedData: [String]
        let textSanitization: [String]
    }

    struct FileRecord: Codable {
        let relativePath: String
        let kind: String
        let sourceByteCount: Int
        let exportedByteCount: Int
        let truncated: Bool
    }

    struct SessionRecord: Codable {
        let sessionID: String
        let kind: String
        let sourceByteCount: Int
        let exportedByteCount: Int
        let inputLineCount: Int
        let exportedLineCount: Int
        let invalidLineCount: Int
        let redactedValueCount: Int
        let truncated: Bool
    }

    struct CollectionError: Codable {
        let source: String
        let message: String
    }

    let schemaVersion: Int
    let generatedAt: Date
    let application: Application
    let system: System
    let privacy: Privacy
    var files: [FileRecord]
    var sessions: [SessionRecord]
    var collectionErrors: [CollectionError]
}

private struct IntatisDiagnosticBundleBuilder {
    private static let maximumEventBytesPerSession = 8 * 1_024 * 1_024
    private static let maximumTotalEventInputBytes = 64 * 1_024 * 1_024
    private static let maximumSessionCount = 100
    private static let maximumCrashCount = 6
    private static let maximumCrashBytes = 4 * 1_024 * 1_024
    private static let maximumArchiveBytes = 96 * 1_024 * 1_024

    let context: IntatisDiagnosticExportContext
    private let fileManager = FileManager.default

    func build() throws -> IntatisDiagnosticExportResult {
        try Task.checkCancellation()
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            IntatisHostApplication.identity.storageName
                + "-Diagnostic-\(UUID().uuidString)",
            isDirectory: true)
        try createOwnerOnlyDirectory(temporaryRoot)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let bundleName = IntatisHostApplication.identity.storageName
            + "-Diagnostics-\(Self.fileTimestamp(context.generatedAt))"
        let bundleRoot = temporaryRoot.appendingPathComponent(
            bundleName,
            isDirectory: true)
        try createOwnerOnlyDirectory(bundleRoot)

        var manifest = makeManifest()
        try write(
            Data(Self.readme.utf8),
            relativePath: "README.txt",
            kind: "readme",
            sourceByteCount: Self.readme.utf8.count,
            truncated: false,
            bundleRoot: bundleRoot,
            manifest: &manifest)

        if let metrics = context.performanceMetrics {
            do {
                let object = try JSONSerialization.jsonObject(with: metrics)
                let formatted = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys])
                try write(
                    formatted,
                    relativePath: "runtime/performance-metrics.json",
                    kind: "performance_metrics",
                    sourceByteCount: metrics.count,
                    truncated: false,
                    bundleRoot: bundleRoot,
                    manifest: &manifest)
            } catch {
                record(
                    source: "performance_metrics",
                    error: error,
                    manifest: &manifest)
            }
        }

        collectSessions(bundleRoot: bundleRoot, manifest: &manifest)
        collectUnifiedLog(bundleRoot: bundleRoot, manifest: &manifest)
        collectProxyConfiguration(bundleRoot: bundleRoot, manifest: &manifest)
        collectHangDiagnostics(bundleRoot: bundleRoot, manifest: &manifest)
        collectCrashReports(bundleRoot: bundleRoot, manifest: &manifest)

        if !manifest.collectionErrors.isEmpty {
            do {
                let data = try encode(manifest.collectionErrors)
                try write(
                    data,
                    relativePath: "collection-errors.json",
                    kind: "collection_errors",
                    sourceByteCount: data.count,
                    truncated: false,
                    bundleRoot: bundleRoot,
                    manifest: &manifest)
            } catch {
                // The same failures remain present in manifest.json. Do not
                // turn a helpful partial bundle into an all-or-nothing error.
            }
        }

        let manifestData = try encode(manifest)
        try writeOwnerOnly(
            manifestData,
            relativePath: "manifest.json",
            bundleRoot: bundleRoot)

        try Task.checkCancellation()
        let archiveURL = temporaryRoot.appendingPathComponent(
            "\(bundleName).zip")
        let execution = try IntatisDiagnosticFixedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [
                "-c", "-k", "--keepParent", bundleRoot.path, archiveURL.path,
            ],
            timeoutSeconds: 30,
            maximumOutputBytes: 1 * 1_024 * 1_024)
        guard execution.succeeded else {
            let detail = IntatisHangDiagnosticTextSanitizer.sanitize(
                String(decoding: execution.standardError, as: UTF8.self),
                sensitivePaths: sensitivePaths,
                maximumBytes: 1_024)
            throw IntatisDiagnosticExportError.archiveFailed(detail)
        }

        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard archiveData.count <= Self.maximumArchiveBytes else {
            throw IntatisDiagnosticExportError.archiveTooLarge
        }
        try DurableOwnerOnlyFile.writeAtomically(
            archiveData,
            to: context.destinationURL,
            temporaryPrefix: "." + IntatisHostApplication.identity
                .temporaryPrefix("diagnostic-"))
        return IntatisDiagnosticExportResult(
            archiveFileName: context.destinationURL.lastPathComponent,
            archiveByteCount: archiveData.count,
            collectionErrorCount: manifest.collectionErrors.count)
    }

    private func makeManifest() -> IntatisDiagnosticExportManifest {
        IntatisDiagnosticExportManifest(
            schemaVersion: 1,
            generatedAt: context.generatedAt,
            application: .init(
                name: IntatisHostApplication.identity.name,
                version: context.applicationVersion,
                build: context.buildVersion,
                processIdentifier: context.processIdentifier,
                rendererMode: safeIdentifier(context.rendererMode),
                selectedProviderID: safeIdentifier(context.selectedProviderID),
                selectedModelID: safeIdentifier(context.selectedModelID),
                selectedVariantID: context.selectedVariantID.map(safeIdentifier),
                providerCount: context.providerCount,
                modelCount: context.modelCount),
            system: .init(
                operatingSystemVersion: context.operatingSystemVersion,
                architecture: context.architecture,
                localeIdentifier: context.localeIdentifier,
                timeZoneIdentifier: context.timeZoneIdentifier),
            privacy: .init(
                remoteUploadPerformed: false,
                eventPayloadPolicy:
                    "Structural redacted projection; raw events.jsonl is never copied.",
                excludedData: [
                    "raw user and model messages",
                    "raw tool arguments and results",
                    "provider configuration and API credentials",
                    "workspace files and workspace bookmarks",
                    "artifacts and attachments",
                    "browser profiles, cookies, local storage, and history",
                    "Keychain, environment variables, auth files, and secret files",
                ],
                textSanitization: [
                    "HTTP(S) URLs",
                    "personal absolute paths",
                    "email addresses",
                    "common bearer/API/token/private-key shapes",
                    "bounded size with explicit truncation markers",
                ]),
            files: [],
            sessions: [],
            collectionErrors: [])
    }

    private func collectSessions(
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let candidates: [(URL, Date, String)]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: context.applicationSupportRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
                .compactMap { url in
                    let name = url.lastPathComponent
                    guard let kind = sessionKind(for: name),
                          isSafeSessionDirectoryName(name),
                          let values = try? url.resourceValues(forKeys: keys),
                          values.isDirectory == true,
                          values.isSymbolicLink != true else {
                        return nil
                    }
                    return (url, values.contentModificationDate ?? .distantPast, kind)
                }
                .sorted { $0.1 > $1.1 }
        } catch {
            record(source: "session_inventory", error: error, manifest: &manifest)
            return
        }

        if candidates.count > Self.maximumSessionCount {
            manifest.collectionErrors.append(.init(
                source: "session_inventory",
                message: "Only the newest \(Self.maximumSessionCount) sessions were included; \(candidates.count - Self.maximumSessionCount) older sessions were omitted by the bundle limit."))
        }

        var remainingInputBytes = Self.maximumTotalEventInputBytes
        for (directory, _, kind) in candidates.prefix(Self.maximumSessionCount) {
            if Task.isCancelled { return }
            guard remainingInputBytes >= 1_024 else {
                manifest.collectionErrors.append(.init(
                    source: "session_events",
                    message: "Remaining session event logs were omitted after the 64 MiB aggregate input limit."))
                break
            }
            let name = directory.lastPathComponent
            let events = directory.appendingPathComponent("events.jsonl")
            // A session directory may be created before its first durable
            // event. An absent log is therefore an empty session, not a
            // collection failure. If a file does exist, the bounded snapshot
            // reader below still fail-closes on symlinks, hard links, unsafe
            // permissions, ownership changes, and read errors.
            guard fileManager.fileExists(atPath: events.path) else {
                continue
            }
            do {
                let snapshot = try IntatisDiagnosticSnapshotReader.readTail(
                    from: events,
                    maximumBytes: min(
                        Self.maximumEventBytesPerSession,
                        remainingInputBytes))
                remainingInputBytes -= snapshot.data.count
                let redacted = IntatisDiagnosticEventLogRedactor.redact(snapshot)
                let relativePath = "sessions/\(name)/events.redacted.jsonl"
                try write(
                    redacted.data,
                    relativePath: relativePath,
                    kind: "redacted_event_log",
                    sourceByteCount: snapshot.sourceByteCount,
                    truncated: redacted.wasTruncated,
                    bundleRoot: bundleRoot,
                    manifest: &manifest)
                manifest.sessions.append(.init(
                    sessionID: name,
                    kind: kind,
                    sourceByteCount: snapshot.sourceByteCount,
                    exportedByteCount: redacted.data.count,
                    inputLineCount: redacted.inputLineCount,
                    exportedLineCount: redacted.exportedLineCount,
                    invalidLineCount: redacted.invalidLineCount,
                    redactedValueCount: redacted.redactedValueCount,
                    truncated: redacted.wasTruncated))
            } catch {
                record(
                    source: "session:\(name)",
                    error: error,
                    manifest: &manifest)
            }
        }
    }

    private func collectUnifiedLog(
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) {
        guard !Task.isCancelled else { return }
        do {
            let execution = try IntatisDiagnosticFixedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/log"),
                arguments: [
                    "show",
                    "--last", "24h",
                    "--style", "compact",
                    "--info",
                    "--predicate", "process == \"\(ProcessInfo.processInfo.processName)\"",
                ],
                timeoutSeconds: 20,
                maximumOutputBytes: 8 * 1_024 * 1_024)
            guard execution.succeeded else {
                let detail = String(
                    decoding: execution.standardError,
                    as: UTF8.self)
                manifest.collectionErrors.append(.init(
                    source: "unified_log",
                    message: safeDiagnosticMessage(
                        detail.isEmpty
                            ? "macOS log show exited with status \(execution.terminationStatus)."
                            : detail)))
                return
            }
            let raw = execution.standardOutput.isEmpty
                ? Data("[NO MATCHING LOG ENTRIES]\n".utf8)
                : execution.standardOutput
            try writeSanitizedText(
                raw,
                relativePath: "system/unified-log-last-24h.txt",
                kind: "unified_log",
                sourceWasTruncated: execution.standardOutputWasTruncated,
                bundleRoot: bundleRoot,
                manifest: &manifest)
        } catch {
            record(source: "unified_log", error: error, manifest: &manifest)
        }
    }

    private func collectProxyConfiguration(
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) {
        guard !Task.isCancelled else { return }
        do {
            let execution = try IntatisDiagnosticFixedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/scutil"),
                arguments: ["--proxy"],
                timeoutSeconds: 5,
                maximumOutputBytes: 512 * 1_024)
            guard execution.succeeded else {
                manifest.collectionErrors.append(.init(
                    source: "proxy_configuration",
                    message: "scutil exited with status \(execution.terminationStatus)."))
                return
            }
            try writeSanitizedText(
                execution.standardOutput,
                relativePath: "system/proxy-configuration.txt",
                kind: "proxy_configuration",
                sourceWasTruncated: execution.standardOutputWasTruncated,
                bundleRoot: bundleRoot,
                manifest: &manifest)
        } catch {
            record(
                source: "proxy_configuration",
                error: error,
                manifest: &manifest)
        }
    }

    private func collectHangDiagnostics(
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) {
        guard let root = context.hangDiagnosticsRoot else {
            manifest.collectionErrors.append(.init(
                source: "hang_diagnostics",
                message: "The \(IntatisHostApplication.identity.name) hang diagnostics directory could not be resolved."))
            return
        }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
                .filter { url in
                    guard let values = try? url.resourceValues(forKeys: keys) else {
                        return false
                    }
                    return values.isDirectory == true
                        && values.isSymbolicLink != true
                        && isSafeLeafName(url.lastPathComponent)
                }
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: keys)
                        .contentModificationDate) ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: keys)
                        .contentModificationDate) ?? .distantPast
                    return left > right
                }
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                record(source: "hang_diagnostics", error: error, manifest: &manifest)
            }
            return
        }

        let allowed = [
            "incident.json", "sample.txt", "unified-log.txt", "capture-errors.txt",
        ]
        for directory in directories.prefix(5) {
            if Task.isCancelled { return }
            for fileName in allowed {
                let source = directory.appendingPathComponent(fileName)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                do {
                    let snapshot = try IntatisDiagnosticSnapshotReader.readTail(
                        from: source,
                        maximumBytes: 4 * 1_024 * 1_024)
                    try writeSanitizedText(
                        snapshot.data,
                        relativePath:
                            "hang/\(directory.lastPathComponent)/\(fileName)",
                        kind: "hang_diagnostic",
                        sourceByteCount: snapshot.sourceByteCount,
                        sourceWasTruncated: snapshot.wasTruncated,
                        bundleRoot: bundleRoot,
                        manifest: &manifest)
                } catch {
                    record(
                        source: "hang_diagnostic:\(fileName)",
                        error: error,
                        manifest: &manifest)
                }
            }
        }
    }

    private func collectCrashReports(
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var reports: [(URL, Date)] = []
        for root in context.crashReportRoots {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]) else {
                continue
            }
            reports.append(contentsOf: urls.compactMap { url in
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                let identity = IntatisHostApplication.identity
                guard identity.macOSProcessNameCandidates.contains(
                        where: name.hasPrefix),
                      ["ips", "crash"].contains(ext),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    return nil
                }
                return (url, values.contentModificationDate ?? .distantPast)
            })
        }
        reports.sort { $0.1 > $1.1 }

        for (index, report) in reports.prefix(Self.maximumCrashCount).enumerated() {
            if Task.isCancelled { return }
            do {
                let snapshot = try IntatisDiagnosticSnapshotReader.readTail(
                    from: report.0,
                    maximumBytes: Self.maximumCrashBytes)
                let ext = report.0.pathExtension.lowercased()
                try writeSanitizedText(
                    snapshot.data,
                    relativePath: "crashes/crash-\(index + 1).\(ext)",
                    kind: "crash_report",
                    sourceByteCount: snapshot.sourceByteCount,
                    sourceWasTruncated: snapshot.wasTruncated,
                    bundleRoot: bundleRoot,
                    manifest: &manifest)
            } catch {
                record(
                    source: "crash_report:\(index + 1)",
                    error: error,
                    manifest: &manifest)
            }
        }
    }

    private func writeSanitizedText(
        _ rawData: Data,
        relativePath: String,
        kind: String,
        sourceByteCount: Int? = nil,
        sourceWasTruncated: Bool,
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) throws {
        let sanitized = IntatisHangDiagnosticTextSanitizer.sanitize(
            String(decoding: rawData, as: UTF8.self),
            sensitivePaths: sensitivePaths,
            maximumBytes: 8 * 1_024 * 1_024)
        let data = Data(sanitized.utf8)
        try write(
            data,
            relativePath: relativePath,
            kind: kind,
            sourceByteCount: sourceByteCount ?? rawData.count,
            truncated: sourceWasTruncated || sanitized.contains("[TRUNCATED]"),
            bundleRoot: bundleRoot,
            manifest: &manifest)
    }

    private func write(
        _ data: Data,
        relativePath: String,
        kind: String,
        sourceByteCount: Int,
        truncated: Bool,
        bundleRoot: URL,
        manifest: inout IntatisDiagnosticExportManifest
    ) throws {
        try writeOwnerOnly(data, relativePath: relativePath, bundleRoot: bundleRoot)
        manifest.files.append(.init(
            relativePath: relativePath,
            kind: kind,
            sourceByteCount: sourceByteCount,
            exportedByteCount: data.count,
            truncated: truncated))
    }

    private func writeOwnerOnly(
        _ data: Data,
        relativePath: String,
        bundleRoot: URL
    ) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy(isSafeLeafName) else {
            throw IntatisDiagnosticExportError.couldNotPrepare
        }
        var destination = bundleRoot
        for component in components.dropLast() {
            destination.appendPathComponent(component, isDirectory: true)
            try createOwnerOnlyDirectory(destination)
        }
        destination.appendPathComponent(components.last!)
        try DurableOwnerOnlyFile.writeAtomically(data, to: destination)
    }

    private func createOwnerOnlyDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path)
        _ = try DurableOwnerOnlyFile.validateOwnedDirectory(at: url)
    }

    private func record(
        source: String,
        error: Error,
        manifest: inout IntatisDiagnosticExportManifest
    ) {
        manifest.collectionErrors.append(.init(
            source: safeIdentifier(source),
            message: safeDiagnosticMessage(error.localizedDescription)))
    }

    private func safeIdentifier(_ value: String) -> String {
        IntatisHangDiagnosticTextSanitizer.sanitize(
            value,
            sensitivePaths: sensitivePaths,
            maximumBytes: 512)
    }

    private func safeDiagnosticMessage(_ value: String) -> String {
        IntatisHangDiagnosticTextSanitizer.sanitize(
            value,
            sensitivePaths: sensitivePaths,
            maximumBytes: 2_048)
    }

    private var sensitivePaths: [String] {
        [
            context.applicationSupportRoot.path,
            context.hangDiagnosticsRoot?.path,
            context.destinationURL.path,
        ].compactMap { $0 }
    }

    private func sessionKind(for name: String) -> String? {
        if name.hasPrefix("sess_") { return "chat" }
        if name.hasPrefix("code_") { return "code" }
        if name.hasPrefix("cowork_") { return "cowork" }
        return nil
    }

    private func isSafeSessionDirectoryName(_ name: String) -> Bool {
        guard name.utf8.count <= 160,
              sessionKind(for: name) != nil else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "_"
                || $0 == "-"
        }
    }

    private func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && name.utf8.count <= 180
            && !name.contains("/")
            && !name.contains("\\")
            && name.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static var readme: String {
        let name = IntatisHostApplication.identity.name
        return """
    \(name) local diagnostic bundle / \(name) 本地诊断包

    This ZIP was generated only after the user selected Export Diagnostic Logs.
    It was saved to the selected local destination. \(name) did not upload it.

    本 ZIP 仅在用户主动选择“导出诊断日志”后生成，并保存到用户选择的本地位置。
    \(name) 没有上传此文件。

    Included coverage:
    - privacy-redacted structural session event projections
    - \(name) process Unified Log entries from the last 24 hours
    - current macOS proxy configuration
    - performance counters and retained hang diagnostics
    - recent \(name) crash reports
    - manifest.json, including collection failures and every truncation

    Excluded by design:
    - raw user/model message contents and raw tool inputs/results
    - provider configuration, API keys, credentials, and environment variables
    - workspace files, artifacts, attachments, and security-scoped bookmarks
    - browser profiles, cookies, local storage, and browsing history

    Before sharing this ZIP, the user can inspect README.txt and manifest.json.
    """
    }
}

private struct IntatisDiagnosticProcessExecution: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let standardOutputWasTruncated: Bool
    let timedOut: Bool

    var succeeded: Bool {
        terminationStatus == 0 && !timedOut
    }
}

private enum IntatisDiagnosticFixedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> IntatisDiagnosticProcessExecution {
        try Task.checkCancellation()
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
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let output = IntatisDiagnosticBoundedDataBuffer(
            maximumBytes: maximumOutputBytes)
        let errors = IntatisDiagnosticBoundedDataBuffer(
            maximumBytes: min(maximumOutputBytes, 1 * 1_024 * 1_024))
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(outputPipe.fileHandleForReading, into: output)
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(errorPipe.fileHandleForReading, into: errors)
            drains.leave()
        }

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            throw error
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        var timedOut = false
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                break
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            usleep(20_000)
        }
        if process.isRunning {
            let graceDeadline = DispatchTime.now().uptimeNanoseconds
                &+ 1_000_000_000
            while process.isRunning,
                  DispatchTime.now().uptimeNanoseconds < graceDeadline {
                usleep(20_000)
            }
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        drains.wait()
        if Task.isCancelled { throw CancellationError() }
        return IntatisDiagnosticProcessExecution(
            terminationStatus: process.terminationStatus,
            standardOutput: output.snapshot.data,
            standardError: errors.snapshot.data,
            standardOutputWasTruncated: output.snapshot.truncated,
            timedOut: timedOut)
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: IntatisDiagnosticBoundedDataBuffer
    ) {
        while true {
            do {
                guard let data = try handle.read(upToCount: 64 * 1_024),
                      !data.isEmpty else { return }
                buffer.append(data)
            } catch {
                return
            }
        }
    }
}

private final class IntatisDiagnosticBoundedDataBuffer: @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let truncated: Bool
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var truncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(1_024, maximumBytes)
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        if newData.count >= maximumBytes {
            data = Data(newData.suffix(maximumBytes))
            truncated = true
            return
        }
        let overflow = data.count + newData.count - maximumBytes
        if overflow > 0 {
            data.removeFirst(overflow)
            truncated = true
        }
        data.append(newData)
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(data: data, truncated: truncated)
    }
}
#endif
