import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Host-owned cache for deterministic validation receipts. Receipts never
/// live inside the bundle and never replace a snapshot identity check; callers
/// may use a matching, unexpired receipt only after re-opening the exact root.
public struct KnowledgeValidationReceiptStore: Sendable {
    public let root: URL

    private struct PurgeTombstone: Codable, Equatable {
        let schema: String
        let storeID: String
        let snapshotID: String
    }

    private var registryLockURL: URL {
        root.appendingPathComponent(".receipt-registry.lock", isDirectory: false)
    }

    public init(root: URL) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            guard chmod(root.path, 0o700) == 0 else {
                throw KnowledgeDomainError(.unsafeStorage, "Validation receipt directory permissions could not be secured.")
            }
            #endif
        }
        self.root = try DurableOwnerOnlyFile.validateOwnedDirectory(at: root)
    }

    public func makeReceipt(
        for snapshot: KnowledgeValidatedSnapshot,
        storeID: String,
        validatedAt: String,
        expiresAt: String? = nil
    ) throws -> KnowledgeValidationReceipt {
        let validatedDate = ISO8601DateFormatter().date(from: validatedAt)
        let expiryDate = expiresAt.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        guard snapshot.report.semanticVerdict,
              snapshot.profile.bundle.id == storeID,
              validatedDate != nil,
              expiresAt == nil || expiryDate != nil,
              expiryDate.map({ $0 > validatedDate! }) ?? true else {
            throw KnowledgeDomainError(.integrityFailed, "A validation receipt can only represent an exact valid snapshot and bounded date-time.")
        }
        let diagnosticsDigest = try KnowledgeDigest.canonical(
            snapshot.report.diagnostics)
        return KnowledgeValidationReceipt(
            schema: KnowledgeContract.validationSchema,
            storeID: storeID,
            snapshotID: snapshot.profile.retrievalSnapshot.id,
            snapshotRevision: snapshot.profile.retrievalSnapshot.revision,
            bundleRevision: snapshot.profile.bundle.revision,
            profileVersion: snapshot.profile.profileVersion,
            validator: .init(
                identity: KnowledgeContract.validatorIdentity,
                version: KnowledgeContract.validatorVersion),
            backendRegistryDigest: snapshot.backendRegistryDigest,
            rootIdentity: .init(
                deviceID: snapshot.rootIdentity.deviceID,
                fileID: snapshot.rootIdentity.fileID,
                canonicalPathDigest: KnowledgeDigest.sha256(
                    snapshot.rootIdentity.canonicalPath)),
            contentSealDigest: snapshot.contentSealDigest,
            semanticVerdict: snapshot.report.diagnostics.contains(where: {
                $0.severity == .warning
            }) ? "valid_with_warnings" : "valid",
            diagnosticsDigest: diagnosticsDigest,
            validatedAt: validatedAt,
            expiresAt: expiresAt)
    }

    public func write(_ receipt: KnowledgeValidationReceipt) throws {
        try validateShape(receipt)
        let data = try KnowledgeJSON.encode(receipt, pretty: true)
        do {
            try DurableOwnerOnlyFile.withExclusiveLock(at: registryLockURL) {
                if try hasPurgeTombstone(
                    storeID: receipt.storeID,
                    snapshotID: receipt.snapshotID) {
                    throw KnowledgeDomainError(
                        .accessDenied,
                        "Validation receipt scope was permanently revoked by urgent purge.")
                }
                try DurableOwnerOnlyFile.writeAtomically(
                    data,
                    to: root.appendingPathComponent(fileName(for: receipt)),
                    temporaryPrefix: ".knowledge-receipt-")
            }
        } catch let error as DurableOwnerOnlyFileError {
            throw KnowledgeDomainError(
                error == .commitUncertain ? .revisionChanged : .unsafeStorage,
                retryable: error == .commitUncertain,
                "Validation receipt could not be committed safely.")
        }
    }

    public func read(
        storeID: String,
        snapshotID: String,
        snapshotRevision: String,
        snapshotRoot: URL,
        backendRegistry: KnowledgeBackendRegistry,
        at evaluationDate: String
    ) throws -> KnowledgeValidationReceipt? {
        guard let identity = WorkspaceRootIdentity.capture(rootPath: snapshotRoot.path),
              let date = ISO8601DateFormatter().date(from: evaluationDate) else {
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt root or evaluation date is invalid.")
        }
        let key = KnowledgeValidationReceipt(
            schema: KnowledgeContract.validationSchema,
            storeID: storeID,
            snapshotID: snapshotID,
            snapshotRevision: snapshotRevision,
            bundleRevision: snapshotRevision,
            profileVersion: KnowledgeContract.profileVersion,
            validator: .init(identity: KnowledgeContract.validatorIdentity, version: KnowledgeContract.validatorVersion),
            backendRegistryDigest: backendRegistry.digest,
            rootIdentity: .init(deviceID: 0, fileID: 0, canonicalPathDigest: KnowledgeDigest.sha256("placeholder")),
            contentSealDigest: KnowledgeDigest.sha256("placeholder"),
            semanticVerdict: "valid",
            diagnosticsDigest: KnowledgeDigest.sha256(Data()),
            validatedAt: evaluationDate,
            expiresAt: nil)
        let url = root.appendingPathComponent(fileName(for: key))
        return try DurableOwnerOnlyFile.withExclusiveLock(at: registryLockURL) {
            if try hasPurgeTombstone(
                storeID: storeID,
                snapshotID: snapshotID) {
                return nil
            }
            guard let data = try DurableOwnerOnlyFile.read(from: url) else { return nil }
            guard data.count <= 64 * 1_024 else {
                throw KnowledgeDomainError(.unsafeStorage, "Validation receipt exceeds its byte limit.")
            }
            let receipt: KnowledgeValidationReceipt
            do {
                receipt = try decodeReceipt(data)
            } catch {
                throw KnowledgeDomainError(.integrityFailed, "Validation receipt could not be decoded.")
            }
            try validateShape(receipt)
            guard let currentContentSeal = try? KnowledgeSecureFileSystem()
                .snapshotSealDigest(root: snapshotRoot) else {
                return nil
            }
            guard receipt.storeID == storeID,
                  receipt.snapshotID == snapshotID,
                  receipt.snapshotRevision == snapshotRevision,
                  receipt.backendRegistryDigest == backendRegistry.digest,
                  receipt.rootIdentity.deviceID == identity.deviceID,
                  receipt.rootIdentity.fileID == identity.fileID,
                  receipt.rootIdentity.canonicalPathDigest
                    == KnowledgeDigest.sha256(identity.canonicalPath),
                  receipt.contentSealDigest == currentContentSeal,
                  ["valid", "valid_with_warnings"].contains(
                      receipt.semanticVerdict) else {
                return nil
            }
            guard let receiptValidatedDate = ISO8601DateFormatter().date(
                from: receipt.validatedAt),
                  date >= receiptValidatedDate else {
                return nil
            }
            if let expires = receipt.expiresAt,
               let expiryDate = ISO8601DateFormatter().date(from: expires),
               date >= expiryDate {
                return nil
            }
            return receipt
        }
    }

    /// Removes host-side receipts for an exact store, optionally narrowed to
    /// explicit snapshot IDs. Urgent purge sets `preventRepublication`; under
    /// the same registry-wide owner-only flock it durably installs exact
    /// snapshot tombstones before removing receipts. Later writes and reads
    /// then fail closed instead of racing stale receipt re-publication.
    @discardableResult
    public func invalidate(
        storeID: String,
        snapshotIDs: Set<String>? = nil,
        preventRepublication: Bool = false
    ) throws -> Int {
        guard KnowledgeStoreIdentifier.isValidStoreID(storeID),
              snapshotIDs?.allSatisfy(KnowledgeStoreIdentifier.isValidSnapshotID) ?? true,
              !preventRepublication || snapshotIDs?.isEmpty == false else {
            throw KnowledgeDomainError(.profileInvalid, "Validation receipt invalidation scope is invalid.")
        }
        return try DurableOwnerOnlyFile.withExclusiveLock(at: registryLockURL) {
            var changedRegistry = false
            if preventRepublication, let snapshotIDs {
                for snapshotID in snapshotIDs.sorted() {
                    if try hasPurgeTombstone(
                        storeID: storeID,
                        snapshotID: snapshotID) {
                        continue
                    }
                    let tombstone = PurgeTombstone(
                        schema: KnowledgeHostIdentity.schema(
                            "knowledge-receipt-purge/1"),
                        storeID: storeID,
                        snapshotID: snapshotID)
                    do {
                        try DurableOwnerOnlyFile.writeAtomically(
                            try KnowledgeJSON.encode(tombstone, pretty: true),
                            to: purgeTombstoneURL(
                                storeID: storeID,
                                snapshotID: snapshotID),
                            temporaryPrefix: ".knowledge-purge-tmp-")
                    } catch let error as DurableOwnerOnlyFileError {
                        throw KnowledgeDomainError(
                            error == .commitUncertain
                                ? .revisionChanged
                                : .unsafeStorage,
                            retryable: error == .commitUncertain,
                            "Validation receipt purge tombstone could not be committed safely.")
                    }
                    changedRegistry = true
                }
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [])
            var removed = 0
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if name == registryLockURL.lastPathComponent { continue }
                if name.hasPrefix(".knowledge-purge-tmp-") {
                    try removeOwnerOnlyLeaf(child)
                    changedRegistry = true
                    continue
                }
                if name.range(
                    of: #"^\.knowledge-purge-[0-9a-f]{64}\.json$"#,
                    options: .regularExpression) != nil {
                    try validatePurgeTombstone(at: child)
                    continue
                }
                if name.hasPrefix(".knowledge-receipt-"), name.hasSuffix(".tmp") {
                    // A crash-left temporary was never a committed receipt.
                    // It contains receipt metadata only, but urgent cleanup
                    // removes it under the same registry writer lock.
                    try removeOwnerOnlyLeaf(child)
                    changedRegistry = true
                    continue
                }
                guard name.range(
                    of: #"^[0-9a-f]{64}\.json$"#,
                    options: .regularExpression) != nil else {
                    throw KnowledgeDomainError(.unsafeStorage, "Validation receipt registry contains an unexpected entry.")
                }
                guard let data = try DurableOwnerOnlyFile.read(from: child) else { continue }
                guard data.count <= 64 * 1_024 else {
                    throw KnowledgeDomainError(.unsafeStorage, "Validation receipt exceeds its byte limit.")
                }
                let receipt: KnowledgeValidationReceipt
                do {
                    receipt = try decodeReceipt(data)
                    try validateShape(receipt)
                } catch {
                    // A malformed receipt can never authorize a mount, but its
                    // provenance cannot be guessed. Fail closed for manual
                    // inspection instead of deleting an unrelated file.
                    throw KnowledgeDomainError(.integrityFailed, "Validation receipt registry contains an invalid receipt.")
                }
                guard receipt.storeID == storeID,
                      snapshotIDs?.contains(receipt.snapshotID) ?? true else {
                    continue
                }
                try removeOwnerOnlyLeaf(child)
                removed += 1
                changedRegistry = true
            }
            if changedRegistry {
                try synchronizeRoot()
            }
            return removed
        }
    }

    private func validateShape(_ receipt: KnowledgeValidationReceipt) throws {
        let validatedDate = ISO8601DateFormatter().date(
            from: receipt.validatedAt)
        let expiryDate = receipt.expiresAt.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        guard receipt.schema == KnowledgeContract.validationSchema,
              receipt.storeID.range(of: #"^kb_[A-Za-z0-9._-]{1,125}$"#, options: .regularExpression) != nil,
              receipt.snapshotID.range(of: #"^snap_[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              KnowledgeDigest.isValid(receipt.snapshotRevision),
              KnowledgeDigest.isValid(receipt.bundleRevision),
              receipt.profileVersion == KnowledgeContract.profileVersion,
              receipt.validator.identity == KnowledgeContract.validatorIdentity,
              receipt.validator.version == KnowledgeContract.validatorVersion,
              KnowledgeDigest.isValid(receipt.backendRegistryDigest),
              KnowledgeDigest.isValid(receipt.rootIdentity.canonicalPathDigest),
              KnowledgeDigest.isValid(receipt.contentSealDigest),
              ["valid", "valid_with_warnings"].contains(
                  receipt.semanticVerdict),
              KnowledgeDigest.isValid(receipt.diagnosticsDigest),
              validatedDate != nil,
              receipt.expiresAt == nil || expiryDate != nil,
              expiryDate.map({ $0 > validatedDate! }) ?? true else {
            throw KnowledgeDomainError(.integrityFailed, "Validation receipt shape is invalid.")
        }
    }

    /// Acronym-bearing Swift properties such as `snapshotID` do not roundtrip
    /// through Foundation's generic `convertFromSnakeCase` strategy
    /// (`snapshot_id` becomes `snapshotId`). Receipt bytes therefore use this
    /// small strict decoder rather than silently accepting a producer-specific
    /// key transform.
    private func decodeReceipt(_ data: Data) throws -> KnowledgeValidationReceipt {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KnowledgeDomainError(.integrityFailed, "Validation receipt root is invalid.")
        }
        let required: Set<String> = [
            "schema", "store_id", "snapshot_id", "snapshot_revision",
            "bundle_revision", "profile_version", "validator",
            "backend_registry_digest", "root_identity", "semantic_verdict",
            "content_seal_digest", "diagnostics_digest", "validated_at",
        ]
        let allowed = required.union(["expires_at"])
        guard required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: allowed),
              let schema = object["schema"] as? String,
              let storeID = object["store_id"] as? String,
              let snapshotID = object["snapshot_id"] as? String,
              let snapshotRevision = object["snapshot_revision"] as? String,
              let bundleRevision = object["bundle_revision"] as? String,
              let profileVersion = object["profile_version"] as? String,
              let validatorObject = object["validator"] as? [String: Any],
              Set(validatorObject.keys) == Set(["identity", "version"]),
              let validatorIdentity = validatorObject["identity"] as? String,
              let validatorVersion = validatorObject["version"] as? String,
              let backendRegistryDigest = object["backend_registry_digest"] as? String,
              let rootObject = object["root_identity"] as? [String: Any],
              Set(rootObject.keys) == Set([
                "device_id", "file_id", "canonical_path_digest",
              ]),
              let deviceID = rootObject["device_id"] as? NSNumber,
              let fileID = rootObject["file_id"] as? NSNumber,
              String(cString: deviceID.objCType) != "c",
              String(cString: fileID.objCType) != "c",
              deviceID.doubleValue >= 0,
              fileID.doubleValue >= 0,
              deviceID.doubleValue.rounded(.towardZero) == deviceID.doubleValue,
              fileID.doubleValue.rounded(.towardZero) == fileID.doubleValue,
              let canonicalPathDigest = rootObject["canonical_path_digest"] as? String,
              let contentSealDigest = object["content_seal_digest"] as? String,
              let semanticVerdict = object["semantic_verdict"] as? String,
              let diagnosticsDigest = object["diagnostics_digest"] as? String,
              let validatedAt = object["validated_at"] as? String else {
            throw KnowledgeDomainError(.integrityFailed, "Validation receipt fields are invalid.")
        }
        let expiresAt: String?
        if let value = object["expires_at"] {
            guard let string = value as? String else {
                throw KnowledgeDomainError(.integrityFailed, "Validation receipt expiry is invalid.")
            }
            expiresAt = string
        } else {
            expiresAt = nil
        }
        return KnowledgeValidationReceipt(
            schema: schema,
            storeID: storeID,
            snapshotID: snapshotID,
            snapshotRevision: snapshotRevision,
            bundleRevision: bundleRevision,
            profileVersion: profileVersion,
            validator: .init(
                identity: validatorIdentity,
                version: validatorVersion),
            backendRegistryDigest: backendRegistryDigest,
            rootIdentity: .init(
                deviceID: deviceID.uint64Value,
                fileID: fileID.uint64Value,
                canonicalPathDigest: canonicalPathDigest),
            contentSealDigest: contentSealDigest,
            semanticVerdict: semanticVerdict,
            diagnosticsDigest: diagnosticsDigest,
            validatedAt: validatedAt,
            expiresAt: expiresAt)
    }

    private func fileName(for receipt: KnowledgeValidationReceipt) -> String {
        let key = [
            receipt.storeID,
            receipt.snapshotID,
            receipt.snapshotRevision,
            KnowledgeContract.validatorVersion,
        ].joined(separator: "\n")
        return KnowledgeDigest.sha256(key)
            .replacingOccurrences(of: "sha256:", with: "") + ".json"
    }

    private func purgeTombstoneURL(
        storeID: String,
        snapshotID: String
    ) -> URL {
        let key = KnowledgeHostIdentity.schema(
            "knowledge-receipt-purge/1")
            + "\n\(storeID)\n\(snapshotID)"
        let digest = KnowledgeDigest.sha256(key)
            .replacingOccurrences(of: "sha256:", with: "")
        return root.appendingPathComponent(
            ".knowledge-purge-\(digest).json",
            isDirectory: false)
    }

    private func hasPurgeTombstone(
        storeID: String,
        snapshotID: String
    ) throws -> Bool {
        let url = purgeTombstoneURL(
            storeID: storeID,
            snapshotID: snapshotID)
        guard let data = try DurableOwnerOnlyFile.read(from: url) else {
            return false
        }
        try validatePurgeTombstone(
            data,
            expectedStoreID: storeID,
            expectedSnapshotID: snapshotID,
            fileName: url.lastPathComponent)
        return true
    }

    private func validatePurgeTombstone(at url: URL) throws {
        guard let data = try DurableOwnerOnlyFile.read(from: url) else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Validation receipt purge tombstone changed during registry validation.")
        }
        let tombstone: PurgeTombstone
        do {
            tombstone = try KnowledgeJSON.decode(
                PurgeTombstone.self,
                from: data)
        } catch {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Validation receipt purge tombstone is invalid.")
        }
        try validatePurgeTombstone(
            data,
            expectedStoreID: tombstone.storeID,
            expectedSnapshotID: tombstone.snapshotID,
            fileName: url.lastPathComponent)
    }

    private func validatePurgeTombstone(
        _ data: Data,
        expectedStoreID: String,
        expectedSnapshotID: String,
        fileName: String
    ) throws {
        guard data.count <= 4 * 1_024,
              KnowledgeStoreIdentifier.isValidStoreID(expectedStoreID),
              KnowledgeStoreIdentifier.isValidSnapshotID(expectedSnapshotID) else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Validation receipt purge tombstone is invalid.")
        }
        let expected = PurgeTombstone(
            schema: KnowledgeHostIdentity.schema(
                "knowledge-receipt-purge/1"),
            storeID: expectedStoreID,
            snapshotID: expectedSnapshotID)
        let decoded: PurgeTombstone
        do {
            decoded = try KnowledgeJSON.decode(PurgeTombstone.self, from: data)
        } catch {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Validation receipt purge tombstone is invalid.")
        }
        guard decoded == expected,
              fileName == purgeTombstoneURL(
                storeID: expectedStoreID,
                snapshotID: expectedSnapshotID).lastPathComponent else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Validation receipt purge tombstone identity is invalid.")
        }
    }

    private func removeOwnerOnlyLeaf(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt leaf could not be opened safely.")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var installed = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(url.path, &installed) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              (opened.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO))
                == (S_IRUSR | S_IWUSR),
              opened.st_dev == installed.st_dev,
              opened.st_ino == installed.st_ino,
              unlink(url.path) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt leaf could not be removed safely.")
        }
    }

    private func synchronizeRoot() throws {
        let descriptor = open(root.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Validation receipt registry could not be synchronized.")
        }
        let result = fsync(descriptor)
        _ = close(descriptor)
        guard result == 0 else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Validation receipt invalidation durability is uncertain.")
        }
    }
}
