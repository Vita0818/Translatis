import XCTest
import IntatisCore
@testable import IntatisArtifacts

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

final class ArtifactImageResolverTests: XCTestCase {
    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-image-resolver-\(UUID().uuidString)",
                isDirectory: true)
    }

    #if canImport(ImageIO)
    func testResolveValidPNGReturnsVerifiedFactsAndRequestDataURL() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let png = try makePNG(width: 2, height: 3)
        let ref = try await store.addAttachment(
            name: "pixel.png",
            data: png,
            mime: "image/png")

        let resolved = try await ArtifactImageResolver(store: store)
            .resolve(ref.id)

        XCTAssertEqual(resolved.artifactID, ref.id)
        XCTAssertEqual(resolved.mimeType, "image/png")
        XCTAssertEqual(resolved.data, png)
        XCTAssertEqual(resolved.byteCount, png.count)
        XCTAssertEqual(resolved.pixelWidth, 2)
        XCTAssertEqual(resolved.pixelHeight, 3)
        #if canImport(CryptoKit)
        XCTAssertEqual(
            resolved.sha256,
            SHA256.hash(data: png)
                .map { String(format: "%02x", $0) }
                .joined())
        #endif
        XCTAssertEqual(
            resolved.dataURL(),
            "data:image/png;base64,\(png.base64EncodedString())")
    }

    func testResolveValidJPEGUsesTheSameVerifiedContract() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let jpeg = try makeJPEG(width: 2, height: 1)
        let ref = try await store.addAttachment(
            name: "pixel.jpg",
            data: jpeg,
            mime: "image/jpeg")

        let resolved = try await ArtifactImageResolver(store: store)
            .resolve(ref.id)

        XCTAssertEqual(resolved.mimeType, "image/jpeg")
        XCTAssertEqual(resolved.data, jpeg)
        XCTAssertEqual(resolved.byteCount, jpeg.count)
        XCTAssertEqual(resolved.pixelWidth, 2)
        XCTAssertEqual(resolved.pixelHeight, 1)
    }

    func testResolveEnforcesDimensionAndPixelLimitsBeforeSuccess() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let png = try makePNG(width: 3, height: 2)
        let ref = try await store.addAttachment(
            name: "large.png",
            data: png,
            mime: "image/png")

        let narrow = ArtifactImageResolver(
            store: store,
            policy: ArtifactImageValidationPolicy(
                maximumPixelWidth: 2))
        await XCTAssertThrowsErrorAsync(try await narrow.resolve(ref.id)) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .dimensionLimitExceeded(
                    ref.id,
                    width: 3,
                    height: 2,
                    maximumWidth: 2,
                    maximumHeight: 8_192))
        }

        let lowPixels = ArtifactImageResolver(
            store: store,
            policy: ArtifactImageValidationPolicy(
                maximumPixelCount: 5))
        await XCTAssertThrowsErrorAsync(try await lowPixels.resolve(ref.id)) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .pixelLimitExceeded(
                    ref.id,
                    width: 3,
                    height: 2,
                    maximumPixels: 5))
        }
    }

    func testResolveEnforcesAggregateBytesWithoutReadingPastRemainingBudget() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let png = try makePNG(width: 1, height: 1)
        let first = try await store.addAttachment(
            name: "first.png",
            data: png,
            mime: "image/png")
        let second = try await store.addAttachment(
            name: "second.png",
            data: png,
            mime: "image/png")
        let resolver = ArtifactImageResolver(
            store: store,
            policy: ArtifactImageValidationPolicy(
                maximumTotalBytes: png.count * 2 - 1))

        await XCTAssertThrowsErrorAsync(
            try await resolver.resolve([first.id, second.id])
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .totalByteLimitExceeded(
                    maximumBytes: png.count * 2 - 1))
        }
    }
    #else
    func testResolveWithoutSafeDecoderFailsTypedUnsupported() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let pngSignature = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
        ])
        let ref = try await store.addAttachment(
            name: "image.png",
            data: pngSignature,
            mime: "image/png")

        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(ref.id)
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .decoderUnavailable(ref.id))
        }
    }
    #endif

    func testResolveRejectsDeclaredMIMEThatDoesNotMatchMagic() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let pngBytes = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
        ])
        let ref = try await store.addAttachment(
            name: "wrong.jpg",
            data: pngBytes,
            mime: "image/jpeg")

        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(ref.id)
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .mimeMismatch(
                    ref.id,
                    declared: "image/jpeg",
                    actual: "image/png"))
        }
    }

    func testResolveRejectsTruncatedImageAfterMagicValidation() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let pngSignature = Data([
            0x89, 0x50, 0x4E, 0x47,
            0x0D, 0x0A, 0x1A, 0x0A,
        ])
        let ref = try await store.addAttachment(
            name: "truncated.png",
            data: pngSignature,
            mime: "image/png")

        #if canImport(ImageIO)
        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(ref.id)
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .invalidImage(ref.id))
        }
        #else
        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(ref.id)
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .decoderUnavailable(ref.id))
        }
        #endif
    }

    func testResolveRejectsUnsupportedOrNoncanonicalDeclaredMIME() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(
            name: "image.gif",
            data: Data("GIF89a".utf8),
            mime: "image/gif")

        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(ref.id)
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .unsupportedDeclaredMIME(
                    ref.id,
                    mimeType: "image/gif"))
        }
    }

    func testResolveEnforcesPerImageReadLimit() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let bytes = Data(repeating: 0xA5, count: 4_096)
        let ref = try await store.addAttachment(
            name: "oversized.png",
            data: bytes,
            mime: "image/png")
        let resolver = ArtifactImageResolver(
            store: store,
            policy: ArtifactImageValidationPolicy(
                maximumImageBytes: bytes.count - 1))

        await XCTAssertThrowsErrorAsync(try await resolver.resolve(ref.id)) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .imageByteLimitExceeded(
                    ref.id,
                    maximumBytes: bytes.count - 1))
        }
    }

    func testResolvePreservesOwnerOnlySingleLinkBoundary() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(
            name: "linked.png",
            data: Data(repeating: 0xA5, count: 32),
            mime: "image/png")
        try FileManager.default.linkItem(
            at: root.appendingPathComponent(ref.path),
            to: root.appendingPathComponent("second-link.png"))

        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(ref.id)
        ) {
            guard case .unreadable(let id, _) =
                    $0 as? ArtifactImageResolutionError else {
                return XCTFail("expected typed unreadable error, got \($0)")
            }
            XCTAssertEqual(id, ref.id)
        }
    }

    func testResolveMissingArtifactIsTyped() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let missing = ArtifactID(rawValue: "art_missing_image")

        await XCTAssertThrowsErrorAsync(
            try await ArtifactImageResolver(store: store).resolve(missing)
        ) {
            XCTAssertEqual(
                $0 as? ArtifactImageResolutionError,
                .missing(missing))
        }
    }

    #if canImport(ImageIO)
    private func makePNG(width: Int, height: Int) throws -> Data {
        try makeImage(
            width: width,
            height: height,
            typeIdentifier: "public.png")
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        try makeImage(
            width: width,
            height: height,
            typeIdentifier: "public.jpeg")
    }

    private func makeImage(
        width: Int,
        height: Int,
        typeIdentifier: String
    ) throws -> Data {
        let bytes = Data(
            repeating: 0xFF,
            count: width * height * 4)
        let provider = try XCTUnwrap(
            CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                typeIdentifier as CFString,
                1,
                nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    #endif
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
