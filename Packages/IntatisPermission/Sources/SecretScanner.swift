import Foundation
import IntatisCore
import IntatisProtocol

/// Deterministic detection of sensitive files, secret-bearing content, and
/// protected config — the hard rules that must never depend on a model
/// (ARCHITECTURE.md §6.2, §6.5).
public enum SecretScanner {

    private static let sensitiveBasenames: Set<String> = [
        ".env", ".netrc", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "credentials", ".npmrc", ".pypirc",
    ]
    private static let sensitiveExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks", "asc",
    ]
    private static var sensitiveDirHints: [String] {
        let identityStems = IntatisHostApplication.identity
            .protectedIdentityStems.sorted()
        return [
            "/.ssh/", "/.aws/", "/.gnupg/", "/.gpg/", "secrets/", "/.config/gh/",
            ".config/opencode/", ".local/share/opencode/",
        ] + identityStems.flatMap { stem in
            [".config/\(stem)/", ".local/share/\(stem)/"]
        }
    }

    /// A path that must never be read or written by a tool.
    public static func isSensitivePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        if sensitiveBasenames.contains(base) { return true }
        if base.hasPrefix(".env") { return true }                 // .env, .env.local, .env.production
        if let ext = base.split(separator: ".").last.map(String.init),
           base.contains("."), sensitiveExtensions.contains(ext) { return true }
        let padded = "/" + lower
        for hint in sensitiveDirHints where padded.contains(hint) { return true }
        return false
    }

    /// Content that looks like it carries a secret (used for shell + agent-to-agent forwarding).
    public static func containsSecret(_ text: String) -> Bool {
        let markers = [
            "-----BEGIN", "PRIVATE KEY", "AKIA", "ASIA", "ssh-rsa ",
            "xoxb-", "xoxp-", "ghp_", "github_pat_", "AIza",
        ]
        if markers.contains(where: text.contains) { return true }
        // `sk-` may occur inside ordinary prose such as "ask-user". Require
        // a token boundary and a credential-length suffix before treating an
        // OpenAI-style prefix as secret-bearing.
        return text.range(
            of: #"(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{12,}"#,
            options: .regularExpression) != nil
    }

    private static let protectedBasenames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock",
        "podfile.lock", "gemfile.lock", "package.resolved", "poetry.lock",
    ]
    private static let protectedHints: [String] = [
        ".github/workflows/", ".gitlab-ci", "/dockerfile", "/makefile",
        ".circleci/", "fastlane/", "/ci/",
    ]

    /// Lockfiles / CI / build config: edits must go to the user even in autopilot.
    public static func isProtectedConfigPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        if protectedBasenames.contains(base) { return true }
        let padded = "/" + lower
        for hint in protectedHints where padded.contains(hint) { return true }
        return false
    }
}

/// Heuristics for `run_shell` command strings.
public enum ShellInspector {
    private static let readOnlyAllowlist: Set<String> = [
        "pwd", "ls", "find", "rg", "grep", "cat",
    ]

    public enum ReadOnlyInspection: Equatable, Sendable {
        case allow(String)
        case ask(String)
        case deny(String)
    }

    public static func isDangerous(_ command: String) -> Bool {
        ShellCommandRiskClassifier.isDangerous(command)
    }

    public static func risksNetworkOrInstall(_ command: String) -> Bool {
        ShellCommandRiskClassifier.risksNetworkOrInstall(command)
    }

    public static func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.split(separator: " ").first.map(String.init) else { return false }
        return readOnlyAllowlist.contains(first) && !isDangerous(command)
    }

    public static func inspectReadOnlyCommand(_ command: String, workspaceRoot: URL) -> ReadOnlyInspection {
        if containsShellMetacharacter(command) {
            return .ask("shell metacharacters require user approval")
        }
        guard let argv = parseArgv(command), let executable = argv.first, !executable.contains("/") else {
            return .ask("shell command is not a simple argv form")
        }
        guard readOnlyAllowlist.contains(executable) else {
            return .ask("shell command is not in the read-only allowlist")
        }

        let paths: [String]
        switch executable {
        case "pwd":
            guard argv.count == 1 else { return .ask("pwd arguments require user approval") }
            paths = []
        case "ls":
            let rest = argv.dropFirst()
            let nonOption = rest.filter { !$0.hasPrefix("-") }
            paths = nonOption.isEmpty ? ["."] : Array(nonOption)
        case "cat":
            let rest = Array(argv.dropFirst())
            guard !rest.isEmpty else { return .ask("cat requires explicit file paths") }
            guard !rest.contains(where: { $0.hasPrefix("-") }) else {
                return .ask("cat options require user approval")
            }
            paths = rest
        case "rg", "grep":
            let rest = Array(argv.dropFirst())
            guard !rest.isEmpty else { return .ask("\(executable) requires a pattern") }
            guard !rest.contains(where: { $0.hasPrefix("-") }) else {
                return .ask("\(executable) options require user approval")
            }
            paths = rest.count > 1 ? Array(rest.dropFirst()) : ["."]
        case "find":
            let rest = Array(argv.dropFirst())
            if rest.contains(where: { $0.hasPrefix("-") || $0 == "!" || $0 == "(" || $0 == ")" }) {
                return .ask("find predicates require user approval")
            }
            paths = rest.isEmpty ? ["."] : rest
        default:
            return .ask("shell command is not in the read-only allowlist")
        }

        for path in paths {
            if SecretScanner.isSensitivePath(path) || PathConfinement.isSensitivePath(path) {
                return .deny("touches sensitive path: \(path)")
            }
            do {
                _ = try PathConfinement.resolve(path, within: workspaceRoot)
            } catch {
                return .deny(error.localizedDescription)
            }
        }
        return .allow("simple read-only shell command within workspace")
    }

    private static func containsShellMetacharacter(_ command: String) -> Bool {
        if command.contains("\n") || command.contains("\r") { return true }
        let markers = ["|", ">", "<", ";", "&&", "||", "$", "`", "*", "?", "~", "&"]
        return markers.contains { command.contains($0) }
    }

    private static func parseArgv(_ command: String) -> [String]? {
        var args: [String] = []
        var current = ""
        var quote: Character?

        for ch in command {
            if ch == "\\" { return nil }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    args.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        guard quote == nil else { return nil }
        if !current.isEmpty { args.append(current) }
        return args.isEmpty ? nil : args
    }
}
