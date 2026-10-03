import Foundation
import IntatisCore
import IntatisProtocol

/// Host-approved Skill roots projected through the pinned App Server's
/// official `skills/extraRoots/set` request.
///
/// Repository `.agents/skills` and the isolated runtime's system Skills remain
/// native Codex discovery concerns. This value reconnects the user's existing
/// `$CODEX_HOME/skills` root, which would otherwise disappear when Intatis
/// launches every session with an isolated `CODEX_HOME`.
public struct CodexRuntimeSkillConfiguration: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let extraRoots: [URL]

    public static let empty = CodexRuntimeSkillConfiguration(
        validatedExtraRoots: [])

    public init(extraRoots: [URL]) throws {
        var roots: [URL] = []
        var seen: Set<String> = []
        for rawRoot in extraRoots {
            guard rawRoot.isFileURL else {
                throw IntatisError.config(
                    "A native Codex Skill extra root must be a local file URL.")
            }
            let root = rawRoot.standardizedFileURL
            let path = root.path
            guard path.hasPrefix("/"),
                  path.count <= 4_096,
                  path.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw IntatisError.config(
                    "A native Codex Skill extra root must be an absolute bounded path.")
            }
            if seen.insert(path).inserted {
                roots.append(root)
            }
        }
        guard roots.count <= 64 else {
            throw IntatisError.config(
                "The native Codex Skill extra-root list exceeds its structural bound.")
        }
        self.init(validatedExtraRoots: roots)
    }

    private init(validatedExtraRoots: [URL]) {
        self.extraRoots = validatedExtraRoots
    }

    /// Reconnects the host user's existing Codex Skill root without sharing
    /// login state, config, rollouts, credentials, or any other CODEX_HOME
    /// content with the isolated App Server process.
    public static func hostUserCodexHome(
        processEnvironment: [String: String] =
            ProcessInfo.processInfo.environment,
        homeDirectory: URL =
            FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Self {
        let rawCodexHome = processEnvironment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome: URL
        if let rawCodexHome, !rawCodexHome.isEmpty {
            let expanded = (rawCodexHome as NSString)
                .expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw IntatisError.config(
                    "The host CODEX_HOME used for native Skill discovery must be absolute.")
            }
            codexHome = URL(
                fileURLWithPath: expanded,
                isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(
                ".codex",
                isDirectory: true)
        }
        return try Self(extraRoots: [
            codexHome.appendingPathComponent(
                "skills",
                isDirectory: true),
        ])
    }

    public var isEmpty: Bool { extraRoots.isEmpty }

    public var description: String {
        "CodexRuntimeSkillConfiguration(extraRoots: \(extraRoots.count))"
    }

    public var debugDescription: String { description }

    var wirePaths: [JSONValue] {
        extraRoots.map { .string($0.path) }
    }
}
