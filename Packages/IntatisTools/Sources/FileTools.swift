import Foundation
import IntatisCore
import IntatisProtocol

// MARK: - read_file

public struct ReadFileTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "read_file",
        description: "Read a UTF-8 text file within the workspace.",
        sideEffect: .readOnly,
        parameters: Schema.object(["path": Schema.nonEmptyString, "maxBytes": Schema.boundedInteger(minimum: 1)], required: ["path"])
    )
    struct Args: Decodable { let path: String; let maxBytes: Int? }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).path).map { [$0] } ?? []
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try validateManagedWorkspaceAccess(
            readablePaths: [a.path],
            writablePaths: [],
            cwd: context.workspaceRoot,
            workspaceLease: context.workspaceLease,
            subject: "read_file")
        let url = try PathConfinement.resolve(a.path, within: context.workspaceRoot)
        let data = try Data(contentsOf: url)
        let limit = a.maxBytes ?? 100_000
        let truncated = data.count > limit
        let slice = truncated ? data.prefix(limit) : data
        return ToolObservation(text: String(decoding: slice, as: UTF8.self), truncated: truncated)
    }
}

// MARK: - list_files

public struct ListFilesTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "list_files",
        description: "List entries of a directory within the workspace.",
        sideEffect: .readOnly,
        parameters: Schema.object(["path": Schema.nonEmptyString], required: [])
    )
    struct Args: Decodable { let path: String? }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        [((try? args.decode(Args.self))?.path) ?? "."]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try? args.decode(Args.self)
        let path = a?.path ?? "."
        _ = try validateManagedWorkspaceAccess(
            readablePaths: [path],
            writablePaths: [],
            cwd: context.workspaceRoot,
            workspaceLease: context.workspaceLease,
            subject: "list_files")
        let dir = try PathConfinement.resolve(path, within: context.workspaceRoot)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let lines = names.map { name -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
            return isDir.boolValue ? "\(name)/" : name
        }
        return ToolObservation(text: lines.joined(separator: "\n"))
    }
}

// MARK: - search_text

public struct SearchTextTool: Tool {
    public init() {}
    public static let descriptor = ToolDescriptor(
        name: "search_text",
        description: "Search for a literal substring in text files under a workspace path.",
        sideEffect: .readOnly,
        parameters: Schema.object(["query": Schema.nonEmptyString, "path": Schema.nonEmptyString], required: ["query"])
    )
    struct Args: Decodable { let query: String; let path: String? }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        [((try? args.decode(Args.self))?.path) ?? "."]
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        let path = a.path ?? "."
        _ = try validateManagedWorkspaceAccess(
            readablePaths: [path],
            writablePaths: [],
            cwd: context.workspaceRoot,
            workspaceLease: context.workspaceLease,
            subject: "search_text")
        let base = try PathConfinement.resolve(path, within: context.workspaceRoot)
        let maxMatches = 200
        var matches: [String] = []

        let enumerator = FileManager.default.enumerator(at: base,
                                                        includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            if matches.count >= maxMatches { break }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let text = try? String(contentsOf: item, encoding: .utf8) else { continue } // skip binary
            let rel = PathConfinement.relativePath(of: item, root: context.workspaceRoot)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains(a.query) {
                    matches.append("\(rel):\(i + 1): \(line)")
                    if matches.count >= maxMatches { break }
                }
            }
        }
        let truncated = matches.count >= maxMatches
        let body = matches.isEmpty ? "(no matches)" : matches.joined(separator: "\n")
        return ToolObservation(text: body, truncated: truncated)
    }
}

// MARK: - write_file

public struct WriteFileTool: Tool {
    public init() {}
    public static let canonicalPermission: String? = "filesystem.edit"
    public static let descriptor = ToolDescriptor(
        name: "write_file",
        description: "Write (create or overwrite) a UTF-8 text file within the workspace.",
        sideEffect: .write,
        parameters: Schema.object(["path": Schema.nonEmptyString, "content": Schema.string], required: ["path", "content"])
    )
    struct Args: Decodable { let path: String; let content: String }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        (try? args.decode(Args.self).path).map { [$0] } ?? []
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "filesystem.write",
            resources: touchedPaths(args).map {
                PermissionResource(kind: .workspacePath, value: $0, access: .readWrite)
            },
            metadata: [
                "operation": .string("create_or_overwrite"),
                "byteCount": .number(Double(value?.content.utf8.count ?? 0)),
            ],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let a = try args.decode(Args.self)
        _ = try validateManagedWorkspaceAccess(
            readablePaths: [],
            writablePaths: [a.path],
            cwd: context.workspaceRoot,
            workspaceLease: context.workspaceLease,
            subject: "write_file")
        let url = try PathConfinement.resolve(a.path, within: context.workspaceRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(a.content.utf8)
        try data.write(to: url, options: .atomic)
        return ToolObservation(text: "wrote \(data.count) bytes to \(a.path)", changedFiles: [a.path])
    }
}
