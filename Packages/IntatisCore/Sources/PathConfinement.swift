import Foundation

/// Workspace path confinement (ARCHITECTURE.md §3.7 invariant). Lives in Core so
/// both Tools (to enforce at execution) and Permission (to deny escapes at the
/// gate) can use it without depending on each other. `..` traversal, symlink
/// escapes, and absolute paths that escape the workspace root are rejected.
public enum PathConfinement {

    /// Resolve a (possibly relative) path against `root`, rejecting escapes.
    public static func resolve(_ path: String, within root: URL) throws -> URL {
        if isSensitivePath(path) {
            throw IntatisError.permissionDenied("sensitive path is not allowed: \(path)")
        }

        let rootCanonical = canonicalURLAllowingMissing(root)
        let candidateInput: URL
        if path.hasPrefix("~") {
            candidateInput = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if path.hasPrefix("/") {
            candidateInput = URL(fileURLWithPath: path)
        } else {
            candidateInput = rootCanonical.appendingPathComponent(path)
        }
        let candidate = canonicalURLAllowingMissing(candidateInput)
        try requireInside(candidate, root: rootCanonical, original: path)
        return candidate
    }

    /// Canonicalize an existing directory, rejecting sensitive locations. Used for
    /// workspace attachment before any agent receives that directory as its root.
    public static func canonicalExistingDirectory(_ url: URL) throws -> URL {
        let expanded = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
        let canonical = canonicalURLAllowingMissing(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDir), isDir.boolValue else {
            throw IntatisError.notFound("workspace is not an existing directory: \(url.path)")
        }
        if isSensitivePath(canonical.path) {
            throw IntatisError.permissionDenied("sensitive workspace is not allowed: \(canonical.path)")
        }
        return canonical
    }

    public static func isWithin(_ path: String, root: URL) -> Bool {
        (try? resolve(path, within: root)) != nil
    }

    /// Path of `url` relative to `root` (for display), or the full path if outside.
    public static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = canonicalURLAllowingMissing(root).path
        let p = canonicalURLAllowingMissing(url).path
        if p == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
    }

    /// Shared conservative sensitive-path detector for final enforcement. The
    /// Permission package has a richer scanner; this one keeps Tools protected even
    /// if a caller bypasses the permission gate.
    public static func isSensitivePath(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let lower = expanded.replacingOccurrences(of: "\\", with: "/").lowercased()
        let components = lower.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let base = components.last else { return false }

        if base == ".env" || base.hasPrefix(".env.") { return true }
        // Repository config can activate hooks, filters, merge drivers,
        // credential helpers, or external diff commands. Model-facing generic
        // file/patch tools must not mutate it while a structured Git operation
        // is validating and using the repository. ProcessGitService has its own
        // read-only preflight and fixed command surface.
        if components.contains(".git"), (base == "config" || base == "config.worktree") {
            return true
        }
        if isAgentConfigSecretPath(components: components, base: base) { return true }
        if [".ssh", ".aws", ".gnupg", ".gpg"].contains(where: { components.contains($0) }) { return true }
        if components.contains("secrets") || components.contains("keychains") { return true }
        if base == ".netrc" || base == ".pgpass" || base == ".npmrc" || base == ".pypirc" { return true }
        if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(base) { return true }
        if base.contains("token") || base.contains("secret") || base.contains("credential") { return true }
        if base.contains("keychain") { return true }
        if base.contains("certificate") || base.contains("cert") { return true }
        if let ext = base.split(separator: ".").last.map(String.init),
           base.contains("."),
           ["pem", "key", "p12", "pfx", "keystore", "jks", "asc"].contains(ext) {
            return true
        }
        return false
    }

    private static func isAgentConfigSecretPath(components: [String], base: String) -> Bool {
        let identity = IntatisHostApplication.identity
        let protectedOwners = identity.protectedIdentityStems
            .union(["opencode"])
        if base == "auth.json",
           components.contains(".local"),
           components.contains("share"),
           components.contains(where: protectedOwners.contains) {
            return true
        }

        let configBasenames = Set([
            "opencode.json", "opencode.jsonc",
            identity.configurationFileName,
            identity.configurationJSONCFileName,
            IntatisHostApplicationIdentity.intatis.configurationFileName,
            IntatisHostApplicationIdentity.intatis.configurationJSONCFileName,
            "config.json", "config.jsonc",
        ])
        guard configBasenames.contains(base),
              let configIndex = components.firstIndex(of: ".config"),
              components.indices.contains(configIndex + 1) else {
            return false
        }
        let owner = components[configIndex + 1]
        return protectedOwners.contains(owner)
    }

    private static func requireInside(_ candidate: URL, root: URL, original: String) throws {
        let rootPath = root.path
        let candidatePath = candidate.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath == rootPath || candidatePath.hasPrefix(prefix) else {
            throw IntatisError.permissionDenied("path escapes workspace: \(original)")
        }
    }

    private static func canonicalURLAllowingMissing(_ url: URL) -> URL {
        var probe = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath).standardizedFileURL
        var missing: [String] = []
        let fm = FileManager.default

        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            missing.insert(probe.lastPathComponent, at: 0)
            probe = parent
        }

        var canonical = probe.resolvingSymlinksInPath().standardizedFileURL
        for component in missing {
            canonical.appendPathComponent(component)
        }
        return canonical.standardizedFileURL
    }
}
