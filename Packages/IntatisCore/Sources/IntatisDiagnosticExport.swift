import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A bounded, read-only snapshot used by the user-initiated diagnostic export.
/// The source file is never modified and a leaf symlink or hard link is never
/// followed. Legacy application logs may be owner-readable (for example 0644),
/// but group/other writable files are rejected.
public struct IntatisDiagnosticFileSnapshot: Equatable, Sendable {
    public let data: Data
    public let sourceByteCount: Int
    public let wasTruncated: Bool

    public init(
        data: Data,
        sourceByteCount: Int,
        wasTruncated: Bool
    ) {
        self.data = data
        self.sourceByteCount = sourceByteCount
        self.wasTruncated = wasTruncated
    }
}

public enum IntatisDiagnosticSnapshotError:
    Error, LocalizedError, Equatable, Sendable
{
    case unsafeFile
    case readFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeFile:
            return "The diagnostic source is not a safe owned regular file."
        case .readFailed:
            return "The diagnostic source could not be read."
        }
    }
}

public enum IntatisDiagnosticSnapshotReader {
    public static let maximumSupportedBytes = 8 * 1_024 * 1_024

    public static func readTail(
        from url: URL,
        maximumBytes: Int = maximumSupportedBytes
    ) throws -> IntatisDiagnosticFileSnapshot {
        let limit = max(1_024, min(maximumBytes, maximumSupportedBytes))
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw IntatisDiagnosticSnapshotError.unsafeFile
            }
            throw IntatisDiagnosticSnapshotError.readFailed
        }
        defer { _ = close(descriptor) }

        guard let initial = safeReadableStatus(for: descriptor) else {
            throw IntatisDiagnosticSnapshotError.unsafeFile
        }
        let sourceByteCount = initial.st_size > 0
            ? min(Int64(Int.max), Int64(initial.st_size))
            : 0
        let sourceCount = Int(sourceByteCount)
        let offset = max(0, sourceCount - limit)
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
            throw IntatisDiagnosticSnapshotError.readFailed
        }

        var result = Data()
        result.reserveCapacity(min(limit, sourceCount))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, limit))
        while result.count < limit {
            let requestCount = min(buffer.count, limit - result.count)
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Darwin.read(descriptor, base, requestCount)
                #elseif canImport(Glibc)
                return Glibc.read(descriptor, base, requestCount)
                #elseif canImport(Musl)
                return Musl.read(descriptor, base, requestCount)
                #else
                return -1
                #endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw IntatisDiagnosticSnapshotError.readFailed
            }
            result.append(contentsOf: buffer.prefix(count))
        }

        guard let final = safeReadableStatus(for: descriptor),
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino else {
            throw IntatisDiagnosticSnapshotError.unsafeFile
        }
        return IntatisDiagnosticFileSnapshot(
            data: result,
            sourceByteCount: sourceCount,
            wasTruncated: offset > 0)
    }

    private static func safeReadableStatus(for descriptor: Int32) -> stat? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return nil
        }
        let permissions = status.st_mode
            & (S_IRWXU | S_IRWXG | S_IRWXO)
        guard (permissions & S_IRUSR) != 0,
              (permissions & (S_IWGRP | S_IWOTH)) == 0,
              (permissions & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0 else {
            return nil
        }
        return status
    }
}

public struct IntatisDiagnosticRedactedEventLog: Equatable, Sendable {
    public let data: Data
    public let inputLineCount: Int
    public let exportedLineCount: Int
    public let invalidLineCount: Int
    public let redactedValueCount: Int
    public let wasTruncated: Bool
}

/// Produces a diagnostic-only structural projection of an EventLog snapshot.
/// It intentionally does not decode protocol payload types: preserving only a
/// small allow-list of diagnostic strings keeps unknown/future events useful
/// without turning the export into a second transcript or secret store.
public enum IntatisDiagnosticEventLogRedactor {
    private static let maximumDepth = 12
    private static let maximumObjectFields = 256
    private static let maximumArrayElements = 128

    public static func redact(
        _ snapshot: IntatisDiagnosticFileSnapshot,
        maximumOutputBytes: Int = 8 * 1_024 * 1_024
    ) -> IntatisDiagnosticRedactedEventLog {
        let outputLimit = max(
            1_024,
            min(maximumOutputBytes, 8 * 1_024 * 1_024))
        let lines = completeLines(
            in: snapshot.data,
            droppedLeadingBytes: snapshot.wasTruncated)
        var records: [Data] = []
        records.reserveCapacity(lines.count)
        var invalidLineCount = 0
        var redactedValueCount = 0

        for line in lines {
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let envelope = object as? [String: Any],
                  let redacted = redactEnvelope(
                    envelope,
                    redactedValueCount: &redactedValueCount),
                  let encoded = try? JSONSerialization.data(
                    withJSONObject: redacted,
                    options: [.sortedKeys]) else {
                invalidLineCount += 1
                continue
            }
            records.append(encoded)
        }

        // Keep the most recent complete events when a bounded export cannot
        // contain every redacted record. This is the portion most likely to
        // explain the problem for which the user is generating the bundle.
        var selected: [Data] = []
        var selectedBytes = 0
        for record in records.reversed() {
            let required = record.count + 1
            guard required <= outputLimit - selectedBytes else { break }
            selected.append(record)
            selectedBytes += required
        }
        selected.reverse()

        var output = Data()
        output.reserveCapacity(selectedBytes)
        for record in selected {
            output.append(record)
            output.append(0x0A)
        }
        return IntatisDiagnosticRedactedEventLog(
            data: output,
            inputLineCount: lines.count,
            exportedLineCount: selected.count,
            invalidLineCount: invalidLineCount,
            redactedValueCount: redactedValueCount,
            wasTruncated: snapshot.wasTruncated || selected.count < records.count)
    }

    private static func completeLines(
        in data: Data,
        droppedLeadingBytes: Bool
    ) -> [Data] {
        var parts = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: true).map(Data.init)
        if droppedLeadingBytes, !parts.isEmpty {
            // The read began at an arbitrary byte offset. Even when the first
            // fragment happens to parse, it is not proven to be a whole line.
            parts.removeFirst()
        }
        return parts
    }

    private static func redactEnvelope(
        _ envelope: [String: Any],
        redactedValueCount: inout Int
    ) -> [String: Any]? {
        var output: [String: Any] = [:]
        for key in ["seq", "v"] {
            if let value = envelope[key] as? NSNumber {
                output[key] = value
            }
        }
        for key in ["ts", "session", "type"] {
            guard let value = envelope[key] as? String else { continue }
            output[key] = IntatisHangDiagnosticTextSanitizer.sanitize(
                value,
                maximumBytes: 1_024)
        }
        if let payload = envelope["payload"] {
            output["payload"] = redactValue(
                payload,
                key: "payload",
                depth: 0,
                redactedValueCount: &redactedValueCount)
        }
        return output.isEmpty ? nil : output
    }

    private static func redactValue(
        _ value: Any,
        key: String?,
        depth: Int,
        redactedValueCount: inout Int
    ) -> Any {
        let normalizedKey = normalize(key ?? "")
        if isSecretKey(normalizedKey) {
            redactedValueCount += 1
            return "[REDACTED_SECRET]"
        }
        if isPathKey(normalizedKey) {
            redactedValueCount += 1
            return "[REDACTED_PATH]"
        }
        if isURLKey(normalizedKey) {
            redactedValueCount += 1
            return "[REDACTED_URL]"
        }
        if isContentKey(normalizedKey) {
            redactedValueCount += 1
            return redactionMetadata(for: value)
        }
        guard depth < maximumDepth else {
            redactedValueCount += 1
            return ["redacted": true, "reason": "depth_limit"]
        }

        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            let keys = dictionary.keys.sorted()
            for (index, originalKey) in keys.prefix(maximumObjectFields).enumerated() {
                let safeKey = safeObjectKey(originalKey, index: index)
                output[safeKey] = redactValue(
                    dictionary[originalKey] as Any,
                    key: originalKey,
                    depth: depth + 1,
                    redactedValueCount: &redactedValueCount)
            }
            if keys.count > maximumObjectFields {
                output["diagnostic_fields_omitted"] =
                    keys.count - maximumObjectFields
            }
            return output
        }
        if let array = value as? [Any] {
            let values = array.suffix(maximumArrayElements).map {
                redactValue(
                    $0,
                    key: key,
                    depth: depth + 1,
                    redactedValueCount: &redactedValueCount)
            }
            if array.count > maximumArrayElements {
                redactedValueCount += array.count - maximumArrayElements
            }
            return values
        }
        if let string = value as? String {
            if isSafeDiagnosticStringKey(normalizedKey) {
                let sanitized = IntatisHangDiagnosticTextSanitizer.sanitize(
                    string,
                    maximumBytes: 2_048)
                if sanitized != string { redactedValueCount += 1 }
                return sanitized
            }
            redactedValueCount += 1
            return redactionMetadata(for: string)
        }
        if value is NSNumber || value is NSNull {
            return value
        }
        redactedValueCount += 1
        return ["redacted": true, "kind": "unsupported"]
    }

    private static func redactionMetadata(for value: Any) -> [String: Any] {
        if let string = value as? String {
            return [
                "redacted": true,
                "kind": "text",
                "characterCount": string.count,
            ]
        }
        if let array = value as? [Any] {
            return [
                "redacted": true,
                "kind": "array",
                "elementCount": array.count,
            ]
        }
        if let dictionary = value as? [String: Any] {
            return [
                "redacted": true,
                "kind": "object",
                "fieldCount": dictionary.count,
            ]
        }
        return ["redacted": true]
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let markers = [
            "apikey", "authorization", "bearer", "cookie", "credential",
            "header", "password", "privatekey", "refreshtoken", "secret",
            "sessiontoken", "accesstoken", "mcpsessionid",
        ]
        return markers.contains { key.contains($0) }
    }

    private static func isPathKey(_ key: String) -> Bool {
        key.contains("path")
            || key.contains("directory")
            || key.contains("workspace")
            || key == "file"
            || key == "filename"
    }

    private static func isURLKey(_ key: String) -> Bool {
        key.contains("url")
            || key.contains("uri")
            || key.contains("endpoint")
            || key == "origin"
            || key == "host"
    }

    private static func isContentKey(_ key: String) -> Bool {
        let exact = Set([
            "args", "arguments", "body", "chars", "clipboard", "command",
            "content", "delta", "description", "diff", "displayname",
            "input", "messages", "objective", "output", "patch", "prompt",
            "query", "report", "response", "result", "summary", "text",
            "textdelta", "title", "transcript",
        ])
        return exact.contains(key)
    }

    private static func isSafeDiagnosticStringKey(_ key: String) -> Bool {
        let exact = Set([
            "access", "action", "advice", "approvalmode", "code",
            "decision", "effectdisposition", "error", "errorcode", "failure",
            "failurecode", "finishreason", "kind", "message", "mode",
            "model", "modelid", "outcome", "provider", "providerid", "reason",
            "requestedaccess", "risk", "role", "sideeffect", "source", "state",
            "status", "tool", "toolname", "type", "variantid", "wireformat",
        ])
        return exact.contains(key) || (key.hasSuffix("id") && !isSecretKey(key))
    }

    private static func safeObjectKey(_ key: String, index: Int) -> String {
        guard !key.isEmpty,
              key.utf8.count <= 64,
              key.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "_"
                      || scalar == "-"
                      || scalar == "."
              }) else {
            return "redacted_field_\(index)"
        }
        return key
    }
}
