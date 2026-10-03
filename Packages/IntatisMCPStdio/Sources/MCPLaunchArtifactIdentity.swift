#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCPStdio requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisProtocol

#if canImport(Security)
import Security
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct MCPLaunchArtifactInput: Equatable, Sendable {
    public let role: MCPLaunchFileRole
    public let path: String

    public init(role: MCPLaunchFileRole, path: String) {
        self.role = role
        self.path = path
    }
}

public enum MCPLaunchArtifactVerificationStage: String, Sendable {
    case isolatedTest
    case beforeSave
    case beforeLaunch
}

/// Captures and verifies the exact executable/interpreter/script/package
/// closure with the same no-follow algorithm at Test, save, and launch.
public enum MCPLaunchArtifactIdentityVerifier {
    /// Captures the complete primary launch closure for a persisted production
    /// server revision. The resulting identity is rechecked by
    /// `verifyBeforeSave` and `verifyBeforeLaunch`; no production caller needs
    /// to route through a test-named API.
    public static func captureBeforeSave(
        _ inputs: [MCPLaunchArtifactInput]
    ) throws -> LaunchArtifactIdentity {
        try capture(inputs, requiresExecutable: true)
    }

    /// Captures one or more exact helper images for a persisted production
    /// server revision. Every input must have the helper role.
    public static func captureHelpersBeforeSave(
        _ inputs: [MCPLaunchArtifactInput]
    ) throws -> LaunchArtifactIdentity {
        guard inputs.allSatisfy({ $0.role == .helper }) else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        return try capture(inputs, requiresExecutable: false)
    }

    /// Isolated Test uses the identical capture algorithm as production save.
    public static func captureForTest(
        _ inputs: [MCPLaunchArtifactInput]
    ) throws -> LaunchArtifactIdentity {
        try captureBeforeSave(inputs)
    }

    /// Isolated helper Test uses the identical production helper algorithm.
    public static func captureHelperForTest(
        _ inputs: [MCPLaunchArtifactInput]
    ) throws -> LaunchArtifactIdentity {
        try captureHelpersBeforeSave(inputs)
    }

    public static func verifyBeforeSave(
        _ expected: LaunchArtifactIdentity
    ) throws {
        try verify(expected, stage: .beforeSave)
    }

    public static func verifyBeforeLaunch(
        _ expected: LaunchArtifactIdentity
    ) throws {
        try verify(expected, stage: .beforeLaunch)
    }

    public static func verify(
        _ expected: LaunchArtifactIdentity,
        stage: MCPLaunchArtifactVerificationStage
    ) throws {
        let inputs = expected.files.map {
            MCPLaunchArtifactInput(
                role: $0.role,
                path: $0.resolvedSymlinkPath ?? $0.canonicalPath)
        }
        let executableCount = expected.files.filter {
            $0.role == .executable
        }.count
        guard executableCount <= 1 else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        let actual = try capture(
            inputs,
            requiresExecutable: executableCount == 1)
        guard actual == expected else {
            throw MCPManagedPipeError.launchArtifactChanged(stage.rawValue)
        }
    }

    private static func capture(
        _ inputs: [MCPLaunchArtifactInput],
        requiresExecutable: Bool
    ) throws -> LaunchArtifactIdentity {
        guard !inputs.isEmpty,
              inputs.count <= 256,
              inputs.filter({ $0.role == .executable }).count
                == (requiresExecutable ? 1 : 0) else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }

        var seenRolesAndPaths: Set<String> = []
        let files = try inputs.map { input -> MCPLaunchFileIdentity in
            let identity = try captureFile(input)
            guard seenRolesAndPaths.insert(
                "\(identity.role.rawValue)\u{1f}\(identity.canonicalPath)"
            ).inserted else {
                throw MCPManagedPipeError.invalidLaunchArtifact
            }
            return identity
        }
        let fingerprint = digest(
            files.flatMap { file in
                [
                    file.role.rawValue,
                    file.canonicalPath,
                    file.fileType,
                    String(file.ownerID),
                    String(file.mode),
                    String(file.deviceID),
                    String(file.fileID),
                    String(file.byteCount),
                    file.sha256,
                    file.resolvedSymlinkPath ?? "",
                    file.codeSignatureSummary ?? "",
                ]
            })
        return LaunchArtifactIdentity(
            files: files,
            fingerprint: fingerprint)
    }

    private static func captureFile(
        _ input: MCPLaunchArtifactInput
    ) throws -> MCPLaunchFileIdentity {
        guard input.path.hasPrefix("/"),
              !input.path.contains("\0") else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        let original = URL(fileURLWithPath: input.path)
            .standardizedFileURL.path
        let canonical = try canonicalPath(original)

        var metadata = stat()
        let descriptor = open(canonical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MCPManagedPipeError.launchArtifactUnreadable(canonical)
        }
        defer { _ = close(descriptor) }
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        if [.executable, .interpreter, .helper].contains(input.role) {
            guard metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
                throw MCPManagedPipeError.launchArtifactNotExecutable(canonical)
            }
        }

        let fileDigest = try hash(descriptor: descriptor)
        return MCPLaunchFileIdentity(
            role: input.role,
            canonicalPath: canonical,
            fileType: "regular",
            ownerID: UInt64(metadata.st_uid),
            mode: UInt32(metadata.st_mode),
            deviceID: UInt64(metadata.st_dev),
            fileID: UInt64(metadata.st_ino),
            byteCount: UInt64(max(0, metadata.st_size)),
            sha256: fileDigest,
            // Formal launch always uses `canonicalPath`, never this alias.
            // Retaining the standardized path that had to be resolved lets
            // the same verifier detect a later symlink swap at save/connect.
            resolvedSymlinkPath: original == canonical ? nil : original,
            codeSignatureSummary: codeSignatureSummary(path: canonical))
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw MCPManagedPipeError.launchArtifactUnreadable(path)
        }
        defer { free(resolved) }
        let value = String(cString: resolved)
        guard value.hasPrefix("/") else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func hash(descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw MCPManagedPipeError.launchArtifactUnreadable("descriptor")
        }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = bytes.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPManagedPipeError.launchArtifactUnreadable("descriptor")
            }
            hasher.update(data: Data(bytes.prefix(count)))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func digest(_ values: [String]) -> String {
        var framed = Data()
        for value in values {
            let data = Data(value.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(data)
        }
        return SHA256.hash(data: framed)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func codeSignatureSummary(path: String) -> String? {
        #if canImport(Security) && os(macOS)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            SecCSFlags(),
            &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return nil
        }
        let validity = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil)
        var information: CFDictionary?
        _ = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information)
        let dictionary = information as? [String: Any]
        let team = dictionary?[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = dictionary?[kSecCodeInfoIdentifier as String] as? String
        let status = validity == errSecSuccess ? "valid" : "invalid"
        let fields = [
            "signature=\(status)",
            team.map { "team=\($0)" },
            identifier.map { "identifier=\($0)" },
        ].compactMap { $0 }
        guard fields.count > 1 || validity == errSecSuccess else { return nil }
        return fields.joined(separator: ";")
        #else
        return nil
        #endif
    }
}
