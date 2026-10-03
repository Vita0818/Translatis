import Foundation
import IntatisCore
import IntatisProtocol

/// A minimal unified-diff parser + applier. It applies each hunk by locating the
/// hunk's old block (context + removed lines) verbatim in the file and replacing
/// it with the new block (context + added lines). If the old block is not found
/// exactly, the patch is rejected — never applied partially or with fuzz.
public enum UnifiedDiff {

    public struct Hunk: Equatable {
        public var oldLines: [String]
        public var newLines: [String]
    }

    public struct FilePatch: Equatable {
        public var path: String
        public var hunks: [Hunk]
    }

    public static func parse(_ diff: String) -> [FilePatch] {
        var files: [FilePatch] = []
        var currentPath: String?
        var hunks: [Hunk] = []
        var oldL: [String] = []
        var newL: [String] = []
        var inHunk = false

        func closeHunk() {
            if inHunk {
                hunks.append(Hunk(oldLines: oldL, newLines: newL))
                oldL = []; newL = []; inHunk = false
            }
        }
        func closeFile() {
            closeHunk()
            if let p = currentPath { files.append(FilePatch(path: p, hunks: hunks)) }
            hunks = []; currentPath = nil
        }

        for sub in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            if line.hasPrefix("--- ") {
                closeFile()
            } else if line.hasPrefix("+++ ") {
                var p = String(line.dropFirst(4))
                if p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
                currentPath = p
            } else if line.hasPrefix("@@") {
                closeHunk()
                inHunk = true
            } else if inHunk {
                if line.hasPrefix("+") {
                    newL.append(String(line.dropFirst()))
                } else if line.hasPrefix("-") {
                    oldL.append(String(line.dropFirst()))
                } else if line.hasPrefix(" ") {
                    let c = String(line.dropFirst())
                    oldL.append(c); newL.append(c)
                } else if line.isEmpty {
                    oldL.append(""); newL.append("")
                }
                // any other leading char ends nothing; ignored
            }
        }
        closeFile()
        return files
    }

    public static func apply(content: String, hunks: [Hunk]) throws -> String {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        for hunk in hunks {
            if hunk.oldLines.isEmpty {
                lines.append(contentsOf: hunk.newLines)
                continue
            }
            guard let range = firstRange(of: hunk.oldLines, in: lines) else {
                throw IntatisError.io("patch hunk did not match file content")
            }
            lines.replaceSubrange(range, with: hunk.newLines)
        }
        return lines.joined(separator: "\n")
    }

    static func firstRange(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle {
                return start..<(start + needle.count)
            }
        }
        return nil
    }
}

// MARK: - apply_patch tool

public struct ApplyPatchTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "filesystem.edit"
    public static let descriptor = ToolDescriptor(
        name: "apply_patch",
        description: "Apply a unified diff to files within the workspace.",
        sideEffect: .write,
        parameters: Schema.object(["diff": Schema.nonEmptyString], required: ["diff"])
    )
    struct Args: Decodable { let diff: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        guard let a = try? args.decode(Args.self) else { return [] }
        return UnifiedDiff.parse(a.diff).map { $0.path }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "filesystem.patch",
            resources: touchedPaths(args).map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readWrite)
            },
            metadata: [
                "operation": .string("apply_unified_diff"),
                "diffCharacterCount": .number(Double(value?.diff.count ?? 0)),
            ],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let patches = UnifiedDiff.parse(a.diff)
        guard !patches.isEmpty else { throw IntatisError.io("no file sections found in diff") }
        _ = try validateManagedWorkspaceAccess(
            readablePaths: patches.map(\.path),
            writablePaths: patches.map(\.path),
            cwd: context.workspaceRoot,
            workspaceLease: context.workspaceLease,
            subject: "apply_patch")

        var changed: [String] = []
        for patch in patches {
            let url = try PathConfinement.resolve(patch.path, within: context.workspaceRoot)
            let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = try UnifiedDiff.apply(content: original, hunks: patch.hunks)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: url, options: .atomic)
            changed.append(patch.path)
        }
        return ToolObservation(text: "applied patch to: \(changed.joined(separator: ", "))",
                               diff: a.diff, changedFiles: changed)
    }
}
