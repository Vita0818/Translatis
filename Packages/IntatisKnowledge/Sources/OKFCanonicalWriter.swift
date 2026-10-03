import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools
import Yams

/// Host-owned v0.2 writer used at the build boundary. Agent-authored drafts
/// may propose prose and provenance, but path normalization, portable source
/// identity and legacy migration are derived from the authorized bundle tree.
struct OKFCanonicalWriter: Sendable {
    private let reader: OKFReader

    init(reader: OKFReader) {
        self.reader = reader
    }

    func canonicalConcept(
        data: Data,
        relativePath: String,
        draftRoot: URL,
        knownPaths: Set<String>
    ) throws -> Data {
        let concept = try reader.readConcept(
            data: data,
            relativePath: relativePath)
        try reader.validateFootnoteAttribution(concept)
        var frontmatter = concept.frontmatter

        if let stale = concept.staleAfter,
           OKFReader.parseISODateOnly(stale) == nil {
            throw KnowledgeDomainError(
                .okfInvalid,
                "OKF stale_after must use YYYY-MM-DD.")
        }

        if frontmatter["generated"] == nil,
           let timestamp = concept.legacyTimestamp {
            frontmatter["generated"] = .object([
                "at": .string(timestamp),
                "by": .string("process:"
                    + KnowledgeHostIdentity.host.temporaryPrefix(
                        "okf-v02-migration")),
            ])
        }
        frontmatter.removeValue(forKey: "timestamp")

        var sourceEntries: [JSONValue] = []
        var oldToCanonicalID: [String: String] = [:]
        var canonicalResources = Set<String>()
        let rawEntries: [[String: JSONValue]]
        if case .array(let entries)? = concept.frontmatter["sources"] {
            rawEntries = try entries.map { entry in
                guard case .object(let object) = entry else {
                    throw KnowledgeDomainError(
                        .okfInvalid,
                        "Every OKF source must be a mapping.")
                }
                return object
            }
        } else {
            rawEntries = concept.sources.map { source in
                var object: [String: JSONValue] = [
                    "resource": .string(source.resource),
                ]
                if let id = source.id { object["id"] = .string(id) }
                if let title = source.title { object["title"] = .string(title) }
                if let author = source.author { object["author"] = .string(author) }
                if let usageCount = source.usageCount {
                    object["usage_count"] = .number(Double(usageCount))
                }
                if let lastModified = source.lastModified {
                    object["last_modified"] = .string(lastModified)
                }
                return object
            }
        }

        for raw in rawEntries {
            guard case .string(let proposedResource)? = raw["resource"] else {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "Every OKF source requires a string resource.")
            }
            let resolved = try canonicalResource(
                proposedResource,
                relativeTo: relativePath,
                draftRoot: draftRoot,
                knownPaths: knownPaths)
            let resource = resolved.resource
            guard canonicalResources.insert(resource).inserted else {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "One concept contains duplicate canonical source resources.")
            }
            let sourceID = Self.canonicalSourceID(resource: resource)
            if case .string(let oldID)? = raw["id"], !oldID.isEmpty {
                guard oldToCanonicalID.updateValue(
                    sourceID,
                    forKey: oldID) == nil else {
                    throw KnowledgeDomainError(
                        .okfInvalid,
                        "One concept contains duplicate proposed source IDs.")
                }
            }
            var canonical = raw
            canonical["id"] = .string(sourceID)
            canonical["resource"] = .string(resource)
            if canonical["title"] == nil,
               let title = resolved.descriptorTitle {
                canonical["title"] = .string(title)
            }
            try rejectPrivateSourceMetadata(
                canonical,
                draftRoot: draftRoot)
            sourceEntries.append(.object(canonical))
        }
        if !sourceEntries.isEmpty {
            frontmatter["sources"] = .array(sourceEntries.sorted {
                Self.sourceResource($0) < Self.sourceResource($1)
            })
        } else {
            frontmatter.removeValue(forKey: "sources")
        }
        if !concept.verifications.isEmpty {
            frontmatter["verified"] = .array(concept.verifications.map {
                .object([
                    "at": .string($0.at),
                    "by": .string($0.by),
                ])
            })
        }

        var body = Self.removingLegacyCitations(from: concept.body)
        for (oldID, sourceID) in oldToCanonicalID.sorted(by: {
            $0.key.count > $1.key.count
        }) {
            body = body.replacingOccurrences(
                of: "[^\(oldID)]",
                with: "[^\(sourceID)]")
        }
        let encoded = try encodeConcept(frontmatter: frontmatter, body: body)
        let canonical = try reader.readConcept(
            data: encoded,
            relativePath: relativePath)
        try reader.validateFootnoteAttribution(canonical)
        return encoded
    }

    func canonicalIndex(
        data: Data,
        relativePath: String
    ) throws -> Data {
        let parsed = try reader.readIndexDocument(
            data: data,
            relativePath: relativePath,
            allowLegacyRootFrontmatter: relativePath == "index.md")
        if relativePath == "index.md" {
            let yaml = "okf_version: \"\(KnowledgeContract.okfVersion)\"\n"
            let value = "---\n\(yaml)---\n\(parsed.body)"
            let result = Data(OKFReader.normalize(value).utf8)
            _ = try reader.readIndexDocument(
                data: result,
                relativePath: relativePath)
            return result
        }
        return Data(parsed.normalizedText.utf8)
    }

    func canonicalLog(
        data: Data,
        relativePath: String
    ) throws -> Data {
        Data(try reader.readLogDocument(
            data: data,
            relativePath: relativePath).normalizedText.utf8)
    }

    static func canonicalSourceID(resource: String) -> String {
        "src_" + String(
            KnowledgeDigest.sha256(
                KnowledgeHostIdentity.schema(
                    "okf-source-id/1") + "\n\(resource)")
                .dropFirst("sha256:".count)
                .prefix(40))
    }

    private func canonicalResource(
        _ proposed: String,
        relativeTo conceptPath: String,
        draftRoot: URL,
        knownPaths: Set<String>
    ) throws -> (resource: String, descriptorTitle: String?) {
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.contains("\\") else {
            throw KnowledgeDomainError(
                .okfInvalid,
                "OKF source resource is not a portable URI or bundle path.")
        }

        if value.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
            options: .regularExpression) != nil {
            guard var components = URLComponents(string: value),
                  let rawScheme = components.scheme else {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "OKF source URI is invalid.")
            }
            let scheme = rawScheme.lowercased()
            if scheme == "file" {
                guard let fileURL = components.url,
                      fileURL.isFileURL else {
                    throw KnowledgeDomainError(
                        .okfInvalid,
                        "OKF file source URI is invalid.")
                }
                let root = draftRoot.standardizedFileURL
                let candidate = fileURL.standardizedFileURL
                guard PathConfinement.isWithin(
                    candidate.path,
                    root: root) else {
                    throw KnowledgeDomainError(
                        .accessDenied,
                        "OKF source path is outside the authorized bundle.")
                }
                let relative = PathConfinement.relativePath(
                    of: candidate,
                    root: root)
                guard knownPaths.contains(relative) else {
                    throw KnowledgeDomainError(
                        .okfInvalid,
                        "OKF source path does not resolve to an immutable bundle file.")
                }
                return ("/\(relative)", nil)
            }
            guard !["data", "javascript"].contains(scheme),
                  components.user == nil,
                  components.password == nil else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "OKF source URI contains a non-portable or credential-bearing identity.")
            }
            components.scheme = scheme
            components.host = components.host?.lowercased()
            if (scheme == "https" && components.port == 443)
                || (scheme == "http" && components.port == 80) {
                components.port = nil
            }
            guard let canonical = components.string,
                  !canonical.isEmpty else {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "OKF source URI could not be canonicalized.")
            }
            return (canonical, nil)
        }

        guard !value.contains("#"), !value.contains("?") else {
            throw KnowledgeDomainError(
                .okfInvalid,
                "Bundle-local OKF source paths cannot contain a fragment or query.")
        }
        var components = value.hasPrefix("/")
            ? []
            : conceptPath.split(separator: "/").dropLast().map(String.init)
        for raw in value.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw)
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw KnowledgeDomainError(
                        .accessDenied,
                        "OKF source path escapes the authorized bundle.")
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        let relative = components.joined(separator: "/")
        if !relative.isEmpty, knownPaths.contains(relative) {
            return ("/\(relative)", nil)
        }

        let explicitlyPathLike = value.hasPrefix("/")
            || value.hasPrefix("./")
            || value.hasPrefix("../")
            || (value.contains("/")
                && !value.contains(where: { $0.isWhitespace }))
        guard !explicitlyPathLike else {
            throw KnowledgeDomainError(
                .okfInvalid,
                "OKF source path does not resolve to an immutable bundle file.")
        }
        let descriptor = OKFReader.normalize(value)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !descriptor.isEmpty,
              descriptor.count <= 2_048,
              !descriptor.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !PermissionReviewTextSanitizer.containsSensitiveMaterial(
                  descriptor) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "OKF scope descriptor is not portable or contains sensitive material.")
        }
        let digest = String(KnowledgeDigest.sha256(
            KnowledgeHostIdentity.schema(
                "okf-scope-resource/1") + "\n\(descriptor)")
            .dropFirst("sha256:".count))
        return ("urn:\(KnowledgeHostIdentity.stem):scope:\(digest)", descriptor)
    }

    private func encodeConcept(
        frontmatter: [String: JSONValue],
        body: String
    ) throws -> Data {
        let encoder = YAMLEncoder()
        encoder.options = .init(
            indent: 2,
            width: -1,
            allowUnicode: true,
            lineBreak: .ln,
            sortKeys: true)
        let yaml = try encoder.encode(JSONValue.object(frontmatter))
        let normalizedYAML = yaml.hasSuffix("\n") ? yaml : yaml + "\n"
        return Data(OKFReader.normalize(
            "---\n\(normalizedYAML)---\n\(body)").utf8)
    }

    private func rejectPrivateSourceMetadata(
        _ object: [String: JSONValue],
        draftRoot: URL
    ) throws {
        let rootPath = draftRoot.standardizedFileURL.path
        var stack = Array(object.values)
        while let value = stack.popLast() {
            switch value {
            case .string(let text):
                var current = text
                // Repeated decoding closes double/multi-encoded private-path
                // bypasses while retaining a fixed CPU/memory bound. Inputs
                // that remain encoded beyond the bound are non-portable and
                // fail closed without echoing their contents.
                for depth in 0...8 {
                    let lower = current.lowercased()
                    let hasPrivatePrefix = lower.contains("/users/")
                        || lower.contains("/home/")
                        || lower.contains("/private/var/folders/")
                        || lower.range(
                            of: #"[a-z]:\\users\\"#,
                            options: .regularExpression) != nil
                    guard !current.contains(rootPath),
                          !lower.contains("file://"),
                          !hasPrivatePrefix,
                          !PermissionReviewTextSanitizer
                            .containsSensitiveMaterial(current) else {
                        throw KnowledgeDomainError(
                            .accessDenied,
                            "OKF source metadata contains a private or sensitive identity.")
                    }
                    guard let decoded = current.removingPercentEncoding,
                          decoded != current else { break }
                    guard depth < 8 else {
                        throw KnowledgeDomainError(
                            .accessDenied,
                            "OKF source metadata uses excessive encoding depth.")
                    }
                    current = decoded
                }
            case .array(let entries):
                stack.append(contentsOf: entries)
            case .object(let entries):
                stack.append(contentsOf: entries.values)
            case .null, .bool, .number:
                break
            }
        }
    }

    private static func sourceResource(_ value: JSONValue) -> String {
        guard case .object(let object) = value,
              case .string(let resource)? = object["resource"] else {
            return ""
        }
        return resource
    }

    private static func removingLegacyCitations(from body: String) -> String {
        let lines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare("# Citations") == .orderedSame
        }) else { return body }
        let end = lines.indices.dropFirst(start + 1).first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("# ")
        }) ?? lines.endIndex
        var retained = lines
        retained.removeSubrange(start..<end)
        while retained.last?.isEmpty == true { retained.removeLast() }
        return retained.joined(separator: "\n") + "\n"
    }
}
