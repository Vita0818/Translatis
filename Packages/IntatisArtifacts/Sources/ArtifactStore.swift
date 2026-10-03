import Foundation
import IntatisCore

/// File-backed artifact store. Blobs live under `<root>/blobs/`, the index in
/// `<root>/index.json`. Actor isolation protects one instance; a stable flock
/// sidecar serializes index read/merge/write across instances and processes.
public actor ArtifactStore {
    private let root: URL
    private let indexURL: URL
    private let indexLockURL: URL
    private var index: [ArtifactID: ArtifactRef]

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonicalRoot = try DurableOwnerOnlyFile.validateOwnedDirectory(at: root)
        let requestedBlobs = canonicalRoot.appendingPathComponent("blobs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: requestedBlobs,
                withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Existing leaves are accepted only after the no-follow directory
            // validation below; a symlink also lands here and is then rejected.
        }
        let canonicalBlobs = try DurableOwnerOnlyFile.validateOwnedDirectory(at: requestedBlobs)
        guard canonicalBlobs.deletingLastPathComponent().standardizedFileURL.path
                == canonicalRoot.standardizedFileURL.path else {
            throw IntatisError.io("artifact blobs directory is outside the store root")
        }

        self.root = canonicalRoot
        self.indexURL = canonicalRoot.appendingPathComponent("index.json")
        self.indexLockURL = canonicalRoot.appendingPathComponent(".artifact-index.lock")
        self.index = try Self.loadIndex(from: self.indexURL, root: canonicalRoot)
    }

    @discardableResult
    public func add(kind: ArtifactKind,
                    mime: String,
                    data: Data,
                    ext: String,
                    producedBy: String? = nil,
                    prompt: String? = nil) throws -> ArtifactRef {
        let id = ArtifactID.new()
        let safeExt = Self.safeFileExtension(ext)
        let filename = "\(id.rawValue).\(safeExt)"
        let ref = ArtifactRef(id: id, kind: kind, mime: mime,
                              path: "blobs/\(filename)", producedBy: producedBy, prompt: prompt)
        let blobURL = try Self.validatedBlobURL(for: ref, root: root)
        try writeBlob(data, to: blobURL)
        return try mergeAndPersist(ref)
    }

    @discardableResult
    public func addAttachment(name: String, data: Data, mime: String) throws -> ArtifactRef {
        try add(kind: .fileAttachment, mime: mime, data: data, ext: Self.fileExtension(of: name))
    }

    public func ref(for id: ArtifactID) -> ArtifactRef? { index[id] }

    public func data(for id: ArtifactID) throws -> Data {
        guard let ref = index[id] else { throw IntatisError.notFound("artifact \(id)") }
        let blobURL = try Self.validatedBlobURL(for: ref, root: root)
        guard let data = try Self.readArtifactFile(
            from: blobURL) else {
            throw IntatisError.notFound("artifact \(id)")
        }
        return data
    }

    /// Reads one artifact through the same no-follow, owner-only, single-link
    /// boundary as `data(for:)`, while enforcing the byte ceiling before the
    /// file can be accumulated in memory.
    public func data(
        for id: ArtifactID,
        maximumBytes: Int
    ) throws -> Data {
        guard let ref = index[id] else {
            throw IntatisError.notFound("artifact \(id)")
        }
        let blobURL = try Self.validatedBlobURL(
            for: ref,
            root: root)
        guard let data = try DurableOwnerOnlyFile.read(
            from: blobURL,
            maximumBytes: maximumBytes) else {
            throw IntatisError.notFound("artifact \(id)")
        }
        return data
    }

    public func list() -> [ArtifactRef] {
        index.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Absolute on-disk URL for an artifact. `nonisolated` because `root` is immutable.
    public nonisolated func absoluteURL(for ref: ArtifactRef) -> URL {
        root.appendingPathComponent(ref.path)
    }

    // MARK: - Private

    private func writeBlob(_ data: Data, to url: URL) throws {
        var writeReturned = false
        do {
            try DurableOwnerOnlyFile.writeAtomically(
                data,
                to: url,
                temporaryPrefix: ".artifact-blob-")
            writeReturned = true
            guard try DurableOwnerOnlyFile.read(from: url) == data else {
                throw DurableOwnerOnlyFileError.commitUncertain
            }
        } catch {
            // A post-rename failure cannot be treated as a clean rollback. Read
            // the installed leaf so this instance reconciles observable disk
            // state before surfacing the uncertainty to its caller.
            if error as? DurableOwnerOnlyFileError == .commitUncertain || writeReturned {
                _ = try? DurableOwnerOnlyFile.read(from: url)
                throw DurableOwnerOnlyFileError.commitUncertain
            }
            throw error
        }
    }

    private func mergeAndPersist(_ ref: ArtifactRef) throws -> ArtifactRef {
        try DurableOwnerOnlyFile.withExclusiveLock(at: indexLockURL) {
            // Always reload while holding the cross-process lock. The actor's
            // cached index may predate a write from another store instance.
            var merged = try Self.loadIndex(from: indexURL, root: root)
            merged[ref.id] = ref
            let refs = Self.sortedRefs(in: merged)
            let encoded = try Self.makeEncoder().encode(refs)
            // ISO-8601 encoding intentionally canonicalizes Date precision.
            // Compare and return the exact persisted representation rather
            // than the pre-encoding in-memory value.
            let canonicalMerged = try Self.decodeIndex(encoded, root: root)
            var writeReturned = false

            do {
                try DurableOwnerOnlyFile.writeAtomically(
                    encoded,
                    to: indexURL,
                    temporaryPrefix: ".artifact-index-")
                writeReturned = true
                let verified = try Self.loadIndex(from: indexURL, root: root)
                guard verified == canonicalMerged,
                      let installedRef = verified[ref.id] else {
                    throw DurableOwnerOnlyFileError.commitUncertain
                }
                index = verified
                return installedRef
            } catch {
                // Do not restore an in-memory snapshot: rename may already have
                // committed. Re-read the canonical leaf under the same lock and
                // make this actor reflect whatever is actually visible on disk.
                if let reconciled = try? Self.loadIndex(from: indexURL, root: root) {
                    index = reconciled
                }
                if error as? DurableOwnerOnlyFileError == .commitUncertain || writeReturned {
                    throw DurableOwnerOnlyFileError.commitUncertain
                }
                throw error
            }
        }
    }

    private static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension
    }

    /// Artifact extensions are presentation metadata, never paths. Only short
    /// ASCII alphanumeric suffixes are retained; everything else becomes
    /// `bin`, so `/`, `..`, Unicode separators, and shell punctuation cannot
    /// influence the blob location.
    private static func safeFileExtension(_ value: String) -> String {
        let candidate = value.lowercased()
        guard !candidate.isEmpty,
              candidate.utf8.count <= 16,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value) || (97...122).contains(value)
              }) else {
            return "bin"
        }
        return candidate
    }

    private static func loadIndex(
        from indexURL: URL,
        root: URL
    ) throws -> [ArtifactID: ArtifactRef] {
        guard let data = try readArtifactFile(from: indexURL) else {
            return [:]
        }
        return try decodeIndex(data, root: root)
    }

    private static func readArtifactFile(from url: URL) throws -> Data? {
        do {
            return try DurableOwnerOnlyFile.read(from: url)
        } catch let error as DurableOwnerOnlyFileError where error == .unsafeFile {
            // Historical ArtifactStore used Data.write(.atomic), commonly
            // leaving 0644 leaves. Adoption is explicit and limited to the
            // fixed index path or a validated blob path chosen by this store.
            try DurableOwnerOnlyFile.adoptLegacyReadOnlyFile(at: url)
            return try DurableOwnerOnlyFile.read(from: url)
        }
    }

    private static func decodeIndex(
        _ data: Data,
        root: URL
    ) throws -> [ArtifactID: ArtifactRef] {
        let refs: [ArtifactRef]
        do {
            refs = try makeDecoder().decode([ArtifactRef].self, from: data)
        } catch {
            throw IntatisError.io("artifact index is invalid: \(error.localizedDescription)")
        }

        var result: [ArtifactID: ArtifactRef] = [:]
        for ref in refs {
            guard result[ref.id] == nil else {
                throw IntatisError.io("artifact index contains a duplicate id")
            }
            _ = try validatedBlobURL(for: ref, root: root)
            result[ref.id] = ref
        }
        return result
    }

    private static func validatedBlobURL(
        for ref: ArtifactRef,
        root: URL
    ) throws -> URL {
        let components = ref.path.split(
            separator: "/",
            omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "blobs",
              !components[1].isEmpty,
              components[1] != ".",
              components[1] != "..",
              components[1].hasPrefix(Substring(ref.id.rawValue + ".")) else {
            throw IntatisError.io("artifact index contains an unsafe blob path")
        }
        let filename = String(components[1])
        let expectedPrefix = ref.id.rawValue + "."
        let suffix = String(filename.dropFirst(expectedPrefix.count))
        guard filename == expectedPrefix + suffix,
              suffix == safeFileExtension(suffix) else {
            throw IntatisError.io("artifact index contains an unsafe blob path")
        }
        let expectedBlobs = root
            .appendingPathComponent("blobs", isDirectory: true)
            .standardizedFileURL
        let liveBlobs = expectedBlobs.resolvingSymlinksInPath().standardizedFileURL
        guard liveBlobs.path == expectedBlobs.path else {
            throw IntatisError.io("artifact blobs directory identity changed")
        }
        let candidate = expectedBlobs.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == expectedBlobs.path else {
            throw IntatisError.io("artifact index contains an unsafe blob path")
        }
        return candidate
    }

    private static func sortedRefs(
        in index: [ArtifactID: ArtifactRef]
    ) -> [ArtifactRef] {
        index.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
