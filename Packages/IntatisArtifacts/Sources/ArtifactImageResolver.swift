import Foundation
import IntatisCore

#if canImport(ImageIO)
import ImageIO
#endif

/// Host-owned limits applied every time durable image bytes are materialized
/// for a model request. The defaults intentionally cover a small P0 image set;
/// callers may provide a narrower policy for a particular route or request.
public struct ArtifactImageValidationPolicy: Equatable, Sendable {
    public var maximumImageCount: Int
    public var maximumImageBytes: Int
    public var maximumTotalBytes: Int
    public var maximumPixelWidth: Int
    public var maximumPixelHeight: Int
    public var maximumPixelCount: Int

    public init(
        maximumImageCount: Int = 8,
        maximumImageBytes: Int = 20 * 1_024 * 1_024,
        maximumTotalBytes: Int = 40 * 1_024 * 1_024,
        maximumPixelWidth: Int = 8_192,
        maximumPixelHeight: Int = 8_192,
        maximumPixelCount: Int = 25_000_000
    ) {
        self.maximumImageCount = maximumImageCount
        self.maximumImageBytes = maximumImageBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
        self.maximumPixelCount = maximumPixelCount
    }

    fileprivate var isValid: Bool {
        maximumImageCount >= 0
            && maximumImageBytes > 0
            && maximumTotalBytes > 0
            && maximumPixelWidth > 0
            && maximumPixelHeight > 0
            && maximumPixelCount > 0
    }
}

/// Request-ready bytes and immutable facts derived from one exact session
/// artifact. This value is deliberately not Codable: model history persists a
/// provider-neutral reference, never these bytes or the generated data URL.
public struct VerifiedArtifactImage: Equatable, Sendable {
    public let artifactID: ArtifactID
    public let mimeType: String
    public let data: Data
    public let byteCount: Int
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        artifactID: ArtifactID,
        mimeType: String,
        data: Data,
        byteCount: Int,
        sha256: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.artifactID = artifactID
        self.mimeType = mimeType
        self.data = data
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Generates provider wire only for the current request. Callers must not
    /// persist this string in EventLog or ArtifactStore metadata.
    public func dataURL() -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

public enum ArtifactImageResolutionError:
    Error,
    Equatable,
    Sendable,
    LocalizedError
{
    case invalidPolicy
    case tooManyImages(maximum: Int, actual: Int)
    case missing(ArtifactID)
    case unsupportedDeclaredMIME(ArtifactID, mimeType: String)
    case mimeMismatch(ArtifactID, declared: String, actual: String?)
    case imageByteLimitExceeded(ArtifactID, maximumBytes: Int)
    case totalByteLimitExceeded(maximumBytes: Int)
    case invalidImage(ArtifactID)
    case dimensionLimitExceeded(
        ArtifactID,
        width: Int,
        height: Int,
        maximumWidth: Int,
        maximumHeight: Int)
    case pixelLimitExceeded(
        ArtifactID,
        width: Int,
        height: Int,
        maximumPixels: Int)
    case decoderUnavailable(ArtifactID)
    case unreadable(ArtifactID, reason: String)

    public var code: String {
        switch self {
        case .invalidPolicy:
            return "image_policy_invalid"
        case .tooManyImages:
            return "image_count_exceeded"
        case .missing:
            return "artifact_missing"
        case .unsupportedDeclaredMIME:
            return "image_type_unsupported"
        case .mimeMismatch:
            return "image_mime_mismatch"
        case .imageByteLimitExceeded:
            return "image_bytes_exceeded"
        case .totalByteLimitExceeded:
            return "image_total_bytes_exceeded"
        case .invalidImage:
            return "image_invalid"
        case .dimensionLimitExceeded:
            return "image_dimensions_exceeded"
        case .pixelLimitExceeded:
            return "image_pixels_exceeded"
        case .decoderUnavailable:
            return "image_decoder_unavailable"
        case .unreadable:
            return "artifact_unreadable"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "The image validation policy is invalid."
        case .tooManyImages(let maximum, let actual):
            return "The request contains \(actual) images; at most \(maximum) are allowed."
        case .missing(let id):
            return "Image artifact \(id.rawValue) is missing from this session."
        case .unsupportedDeclaredMIME(let id, let mimeType):
            return "Image artifact \(id.rawValue) declares unsupported MIME type \(mimeType)."
        case .mimeMismatch(let id, let declared, let actual):
            return "Image artifact \(id.rawValue) declares \(declared), but its bytes are \(actual ?? "not a supported image")."
        case .imageByteLimitExceeded(let id, let maximumBytes):
            return "Image artifact \(id.rawValue) exceeds the \(maximumBytes)-byte per-image limit."
        case .totalByteLimitExceeded(let maximumBytes):
            return "The resolved images exceed the \(maximumBytes)-byte request limit."
        case .invalidImage(let id):
            return "Image artifact \(id.rawValue) could not be decoded as one complete image."
        case .dimensionLimitExceeded(
            let id,
            let width,
            let height,
            let maximumWidth,
            let maximumHeight):
            return "Image artifact \(id.rawValue) is \(width)x\(height), exceeding the \(maximumWidth)x\(maximumHeight) limit."
        case .pixelLimitExceeded(
            let id,
            let width,
            let height,
            let maximumPixels):
            return "Image artifact \(id.rawValue) is \(width)x\(height), exceeding the \(maximumPixels)-pixel limit."
        case .decoderUnavailable(let id):
            return "Image artifact \(id.rawValue) cannot be safely decoded on this platform."
        case .unreadable(let id, let reason):
            return "Image artifact \(id.rawValue) could not be read safely: \(reason)"
        }
    }
}

/// Resolves durable IDs only inside the ArtifactStore instance supplied by the
/// exact session owner. It performs no path lookup, remote fetch, cache, resize,
/// or normalization.
public struct ArtifactImageResolver: Sendable {
    private let store: ArtifactStore
    public let policy: ArtifactImageValidationPolicy

    public init(
        store: ArtifactStore,
        policy: ArtifactImageValidationPolicy = ArtifactImageValidationPolicy()
    ) {
        self.store = store
        self.policy = policy
    }

    public func resolve(_ id: ArtifactID) async throws -> VerifiedArtifactImage {
        guard let result = try await resolve([id]).first else {
            throw ArtifactImageResolutionError.missing(id)
        }
        return result
    }

    public func resolve(
        _ ids: [ArtifactID]
    ) async throws -> [VerifiedArtifactImage] {
        guard policy.isValid else {
            throw ArtifactImageResolutionError.invalidPolicy
        }
        guard ids.count <= policy.maximumImageCount else {
            throw ArtifactImageResolutionError.tooManyImages(
                maximum: policy.maximumImageCount,
                actual: ids.count)
        }

        var result: [VerifiedArtifactImage] = []
        result.reserveCapacity(ids.count)
        var totalBytes = 0
        for id in ids {
            try Task.checkCancellation()
            guard let ref = await store.ref(for: id) else {
                throw ArtifactImageResolutionError.missing(id)
            }
            let declaredMIME = try Self.declaredMIME(
                ref.mime,
                artifactID: id)
            let remainingTotal = policy.maximumTotalBytes - totalBytes
            guard remainingTotal > 0 else {
                throw ArtifactImageResolutionError.totalByteLimitExceeded(
                    maximumBytes: policy.maximumTotalBytes)
            }
            let readLimit = min(
                policy.maximumImageBytes,
                remainingTotal)
            let data: Data
            do {
                data = try await store.data(
                    for: id,
                    maximumBytes: readLimit)
            } catch DurableOwnerOnlyFileError.fileTooLarge {
                if readLimit < policy.maximumImageBytes {
                    throw ArtifactImageResolutionError.totalByteLimitExceeded(
                        maximumBytes: policy.maximumTotalBytes)
                }
                throw ArtifactImageResolutionError.imageByteLimitExceeded(
                    id,
                    maximumBytes: policy.maximumImageBytes)
            } catch let error as IntatisError {
                if case .notFound = error {
                    throw ArtifactImageResolutionError.missing(id)
                }
                throw ArtifactImageResolutionError.unreadable(
                    id,
                    reason: Self.safeReadFailure(error))
            } catch let error as DurableOwnerOnlyFileError {
                throw ArtifactImageResolutionError.unreadable(
                    id,
                    reason: Self.safeReadFailure(error))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ArtifactImageResolutionError.unreadable(
                    id,
                    reason: "artifact read failed")
            }
            try Task.checkCancellation()

            guard !data.isEmpty else {
                throw ArtifactImageResolutionError.invalidImage(id)
            }
            let actualMIME = Self.detectedMIME(in: data)
            guard actualMIME == declaredMIME else {
                throw ArtifactImageResolutionError.mimeMismatch(
                    id,
                    declared: declaredMIME,
                    actual: actualMIME)
            }
            let dimensions = try Self.validateDecodedImage(
                data,
                artifactID: id,
                mimeType: declaredMIME,
                policy: policy)
            let verified = VerifiedArtifactImage(
                artifactID: id,
                mimeType: declaredMIME,
                data: data,
                byteCount: data.count,
                sha256: ArtifactImageSHA256.hexDigest(data),
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height)
            result.append(verified)
            totalBytes += data.count
        }
        return result
    }

    private static func declaredMIME(
        _ raw: String,
        artifactID: ArtifactID
    ) throws -> String {
        let canonical = raw.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        guard raw == canonical,
              canonical == "image/png"
                || canonical == "image/jpeg" else {
            throw ArtifactImageResolutionError.unsupportedDeclaredMIME(
                artifactID,
                mimeType: String(raw.prefix(256)))
        }
        return canonical
    }

    private static func detectedMIME(in data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0...7].elementsEqual([
               0x89, 0x50, 0x4E, 0x47,
               0x0D, 0x0A, 0x1A, 0x0A,
           ]) {
            return "image/png"
        }
        if bytes.count >= 3,
           bytes[0] == 0xFF,
           bytes[1] == 0xD8,
           bytes[2] == 0xFF {
            return "image/jpeg"
        }
        return nil
    }

    private static func validateDecodedImage(
        _ data: Data,
        artifactID: ArtifactID,
        mimeType: String,
        policy: ArtifactImageValidationPolicy
    ) throws -> (width: Int, height: Int) {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              sourceTypeMatchesMIME(sourceType, mimeType: mimeType),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ArtifactImageResolutionError.invalidImage(artifactID)
        }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        guard width > 0, height > 0 else {
            throw ArtifactImageResolutionError.invalidImage(artifactID)
        }
        guard width <= policy.maximumPixelWidth,
              height <= policy.maximumPixelHeight else {
            throw ArtifactImageResolutionError.dimensionLimitExceeded(
                artifactID,
                width: width,
                height: height,
                maximumWidth: policy.maximumPixelWidth,
                maximumHeight: policy.maximumPixelHeight)
        }
        guard width <= policy.maximumPixelCount / height else {
            throw ArtifactImageResolutionError.pixelLimitExceeded(
                artifactID,
                width: width,
                height: height,
                maximumPixels: policy.maximumPixelCount)
        }
        let decodeOptions = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            decodeOptions),
              image.width == width,
              image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ArtifactImageResolutionError.invalidImage(artifactID)
        }
        return (width, height)
        #else
        throw ArtifactImageResolutionError.decoderUnavailable(artifactID)
        #endif
    }

    #if canImport(ImageIO)
    private static func sourceTypeMatchesMIME(
        _ sourceType: String,
        mimeType: String
    ) -> Bool {
        switch mimeType {
        case "image/png":
            return sourceType == "public.png"
        case "image/jpeg":
            return sourceType == "public.jpeg"
                || sourceType == "public.jpg"
        default:
            return false
        }
    }
    #endif

    private static func safeReadFailure(_ error: Error) -> String {
        switch error {
        case DurableOwnerOnlyFileError.unsafeFile:
            return "unsafe owner, mode, link, or file type"
        case DurableOwnerOnlyFileError.readFailed:
            return "owner-only read failed"
        case DurableOwnerOnlyFileError.fileTooLarge:
            return "file exceeds the bounded read limit"
        default:
            return "artifact read failed"
        }
    }
}

/// Small dependency-free SHA-256 used by the Artifact layer. This avoids
/// pulling provider/runtime crypto dependencies into the iOS-safe store target.
private enum ArtifactImageSHA256 {
    private static let constants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
        0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
        0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
        0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
        0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
        0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]

    static func hexDigest(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var digest: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
        ]
        var words = [UInt32](repeating: 0, count: 64)
        for blockStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let offset = blockStart + index * 4
                words[index] =
                    UInt32(message[offset]) << 24
                    | UInt32(message[offset + 1]) << 16
                    | UInt32(message[offset + 2]) << 8
                    | UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18)
                    ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16]
                    &+ s0
                    &+ words[index - 7]
                    &+ s1
            }

            var a = digest[0]
            var b = digest[1]
            var c = digest[2]
            var d = digest[3]
            var e = digest[4]
            var f = digest[5]
            var g = digest[6]
            var h = digest[7]
            for index in 0..<64 {
                let bigSigma1 = rotateRight(e, by: 6)
                    ^ rotateRight(e, by: 11)
                    ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ ((~e) & g)
                let temporary1 = h
                    &+ bigSigma1
                    &+ choose
                    &+ constants[index]
                    &+ words[index]
                let bigSigma0 = rotateRight(a, by: 2)
                    ^ rotateRight(a, by: 13)
                    ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = bigSigma0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }
            digest[0] &+= a
            digest[1] &+= b
            digest[2] &+= c
            digest[3] &+= d
            digest[4] &+= e
            digest[5] &+= f
            digest[6] &+= g
            digest[7] &+= h
        }
        return digest.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(
        _ value: UInt32,
        by count: UInt32
    ) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
