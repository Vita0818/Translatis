import XCTest
@testable import IntatisTools

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(AppKit) && canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO) && canImport(PDFKit)
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
#endif

final class PDFNativeDocumentServiceTests: XCTestCase {
    private let renderMaximumPagePixels = 40_000_000
    private let renderMaximumTotalPixels = 200_000_000
    private let renderMaximumOutputBytes = 512 * 1_024 * 1_024

    func testReadReturnsNativeTextByPageAndSignalsImageOnlyPDF() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(CoreText) && canImport(PDFKit)
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let textPDF = root.appendingPathComponent("text.pdf")
        try makeTextPDF(pages: ["First native page", "Second native page"], at: textPDF)
        let result = try PDFNativeDocumentService.readNativeText(from: textPDF)

        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.metadata["title"], "Intatis native text fixture")
        XCTAssertEqual(result.pages.map(\.pageNumber), [1, 2])
        XCTAssertTrue(result.pages[0].text.contains("First native page"))
        XCTAssertTrue(result.pages[1].text.contains("Second native page"))
        XCTAssertTrue(result.combinedText.contains("First native page\n\nSecond native page"))
        XCTAssertFalse(result.requiresOCR)
        XCTAssertEqual(result.pagesWithoutExtractableText, [])

        let imageOnlyPDF = root.appendingPathComponent("image-only.pdf")
        try makeGraphicsPDF(pageCount: 1, at: imageOnlyPDF)
        let imageOnlyResult = try PDFNativeDocumentService.readNativeText(from: imageOnlyPDF)
        XCTAssertTrue(imageOnlyResult.requiresOCR)
        XCTAssertEqual(imageOnlyResult.pagesWithoutExtractableText, [1])
        XCTAssertEqual(imageOnlyResult.pages[0].text, "")
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }

    func testReadRejectsSymbolicLinkInput() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(PDFKit)
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.pdf")
        let link = root.appendingPathComponent("linked.pdf")
        try makeGraphicsPDF(pageCount: 1, at: input)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)

        XCTAssertThrowsError(try PDFNativeDocumentService.readNativeText(from: link)) { error in
            guard case PDFNativeDocumentServiceError.unsafeInput(let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("symbolic"), reason)
        }
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }

    func testReadAppliesOneBasedSelectionAndCharacterBudgetIncrementally() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(CoreText) && canImport(PDFKit)
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("text.pdf")
        try makeTextPDF(pages: ["First native page", "Second native page"], at: input)

        let result = try PDFNativeDocumentService.readNativeText(
            from: input,
            pages: [2],
            maximumCharacters: 6)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.pages.map(\.pageNumber), [2])
        XCTAssertEqual(result.pages[0].text, "Second")
        XCTAssertEqual(result.combinedText, "Second")
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.requiresOCR)

        XCTAssertThrowsError(try PDFNativeDocumentService.readNativeText(
            from: input,
            maximumCharacters: PDFNativeDocumentService.maximumNativeTextCharacters + 1)) {
                error in
                XCTAssertEqual(
                    error as? PDFNativeDocumentServiceError,
                    .invalidMaximumCharacters(
                        maximum: PDFNativeDocumentService.maximumNativeTextCharacters))
            }
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }

    func testRenderWritesStablePNGsAndCodableManifestForSelectedPages() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(PDFKit)
        let fixture = try makeVisualVerificationFixture()
        defer {
            if fixture.removeWhenFinished {
                try? FileManager.default.removeItem(at: fixture.root)
            }
        }

        let manifest = try PDFNativeDocumentService.renderPages(
            from: fixture.pdf,
            into: fixture.staging,
            pages: [2, 1, 2],
            box: .mediaBox,
            dpi: 72,
            background: .white,
            includeAnnotations: true,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.sourcePageCount, 2)
        XCTAssertEqual(manifest.pages.map(\.pageNumber), [1, 2])
        XCTAssertEqual(manifest.pages.map(\.fileName), ["page-0001.png", "page-0002.png"])
        XCTAssertEqual(manifest.pages[0].pixelWidth, 144)
        XCTAssertEqual(manifest.pages[0].pixelHeight, 72)
        XCTAssertEqual(manifest.pages[1].pixelWidth, 72)
        XCTAssertEqual(manifest.pages[1].pixelHeight, 144)
        XCTAssertEqual(manifest.pages[1].rotation, 90)

        var expectedTotalPixels = 0
        var expectedTotalBytes = 0
        for page in manifest.pages {
            let imageURL = fixture.staging.appendingPathComponent(page.fileName)
            let pngData = try Data(contentsOf: imageURL)
            XCTAssertEqual(try imageDimensions(at: imageURL).width, page.pixelWidth)
            XCTAssertEqual(try imageDimensions(at: imageURL).height, page.pixelHeight)
            XCTAssertEqual(page.mimeType, "image/png")
            XCTAssertEqual(page.byteCount, pngData.count)
            XCTAssertEqual(page.sha256, sha256Hex(pngData))
            expectedTotalPixels += page.pixelWidth * page.pixelHeight
            expectedTotalBytes += pngData.count
            try assertSingleLinkRegularFile(imageURL)
        }
        XCTAssertEqual(manifest.totalPixelCount, expectedTotalPixels)
        XCTAssertEqual(manifest.totalByteCount, expectedTotalBytes)

        let manifestURL = fixture.staging.appendingPathComponent(
            PDFNativeDocumentService.manifestFileName)
        let manifestData = try Data(contentsOf: manifestURL)
        let decoded = try JSONDecoder().decode(
            PDFNativeRenderManifest.self,
            from: manifestData)
        XCTAssertEqual(decoded, manifest)
        let manifestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifestJSON["total_pixel_count"] as? Int, expectedTotalPixels)
        XCTAssertEqual(manifestJSON["total_byte_count"] as? Int, expectedTotalBytes)
        let encodedPages = try XCTUnwrap(manifestJSON["pages"] as? [[String: Any]])
        XCTAssertEqual(encodedPages.first?["mime_type"] as? String, "image/png")
        XCTAssertNotNil(encodedPages.first?["byte_count"])
        try assertSingleLinkRegularFile(manifestURL)
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }

    func testRenderHonorsCropBoxTransparentBackgroundAndAnnotationToggle() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(PDFKit)
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("annotated.pdf")
        try makeGraphicsPDF(pageCount: 1, at: input, addAnnotation: true)

        let transparentStage = try makePrivateDirectory(
            at: root.appendingPathComponent("transparent"))
        let withoutAnnotations = try PDFNativeDocumentService.renderPages(
            from: input,
            into: transparentStage,
            box: .cropBox,
            dpi: 72,
            background: .transparent,
            includeAnnotations: false,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)
        XCTAssertEqual(withoutAnnotations.pages[0].pixelWidth, 96)
        XCTAssertEqual(withoutAnnotations.pages[0].pixelHeight, 48)
        XCTAssertFalse(withoutAnnotations.includesAnnotations)

        let transparentPNG = transparentStage.appendingPathComponent("page-0001.png")
        let corner = try pixelColor(at: transparentPNG, x: 2, y: 2)
        XCTAssertLessThan(corner.alphaComponent, 0.05)

        let annotatedStage = try makePrivateDirectory(
            at: root.appendingPathComponent("annotated"))
        let withAnnotations = try PDFNativeDocumentService.renderPages(
            from: input,
            into: annotatedStage,
            box: .cropBox,
            dpi: 72,
            background: .transparent,
            includeAnnotations: true,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)
        XCTAssertTrue(withAnnotations.includesAnnotations)
        XCTAssertNotEqual(
            try Data(contentsOf: transparentPNG),
            try Data(contentsOf: annotatedStage.appendingPathComponent("page-0001.png")),
            "PDFPage.displaysAnnotations should affect PDFPage.draw output")

        let whiteStage = try makePrivateDirectory(at: root.appendingPathComponent("white"))
        _ = try PDFNativeDocumentService.renderPages(
            from: input,
            into: whiteStage,
            box: .cropBox,
            dpi: 72,
            background: .white,
            includeAnnotations: false,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)
        let whiteCorner = try pixelColor(
            at: whiteStage.appendingPathComponent("page-0001.png"),
            x: 2,
            y: 2)
        XCTAssertGreaterThan(whiteCorner.alphaComponent, 0.99)
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }

    func testRenderEnforcesPageDPIAndStagingLimitsWithoutClobbering() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(PDFKit)
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.pdf")
        try makeGraphicsPDF(pageCount: 1, at: input)

        let dpiStage = try makePrivateDirectory(at: root.appendingPathComponent("dpi"))
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: dpiStage,
            dpi: PDFNativeDocumentService.maximumDPI + 1,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                guard case PDFNativeDocumentServiceError.invalidDPI = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

        let pageStage = try makePrivateDirectory(at: root.appendingPathComponent("pages"))
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: pageStage,
            pages: Array(repeating: 1, count: PDFNativeDocumentService.maximumRenderedPages + 1),
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                XCTAssertEqual(
                    error as? PDFNativeDocumentServiceError,
                    .tooManyRenderedPages(maximum: PDFNativeDocumentService.maximumRenderedPages))
            }

        let occupiedStage = try makePrivateDirectory(at: root.appendingPathComponent("occupied"))
        let sentinel = occupiedStage.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: occupiedStage,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                XCTAssertEqual(error as? PDFNativeDocumentServiceError, .stagingDirectoryNotEmpty)
            }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")

        let realStage = try makePrivateDirectory(at: root.appendingPathComponent("real-stage"))
        let linkedStage = root.appendingPathComponent("linked-stage")
        try FileManager.default.createSymbolicLink(at: linkedStage, withDestinationURL: realStage)
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: linkedStage,
            maximumPagePixels: renderMaximumPagePixels,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                guard case PDFNativeDocumentServiceError.unsafeStagingDirectory = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }

    func testRenderEnforcesCallerResolvedPixelAndByteBudgets() throws {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(PDFKit)
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.pdf")
        try makeGraphicsPDF(pageCount: 2, at: input)

        let ceilingStage = try makePrivateDirectory(at: root.appendingPathComponent("ceiling"))
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: ceilingStage,
            maximumPagePixels: PDFNativeDocumentService.maximumPixelsPerPage + 1,
            maximumTotalPixels: renderMaximumTotalPixels,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                XCTAssertEqual(
                    error as? PDFNativeDocumentServiceError,
                    .invalidRenderBudget(
                        name: "maximumPagePixels",
                        maximum: PDFNativeDocumentService.maximumPixelsPerPage))
            }

        let pageStage = try makePrivateDirectory(at: root.appendingPathComponent("page"))
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: pageStage,
            pages: [1],
            maximumPagePixels: 10_000,
            maximumTotalPixels: 20_000,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                XCTAssertEqual(
                    error as? PDFNativeDocumentServiceError,
                    .renderedPageTooLarge(
                        pageNumber: 1,
                        maximumPixels: 10_000,
                        maximumDimension: PDFNativeDocumentService.maximumPixelDimension))
            }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pageStage.path), [])

        let totalStage = try makePrivateDirectory(at: root.appendingPathComponent("total"))
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: totalStage,
            maximumPagePixels: 20_000,
            maximumTotalPixels: 30_000,
            maximumOutputBytes: renderMaximumOutputBytes)) { error in
                XCTAssertEqual(
                    error as? PDFNativeDocumentServiceError,
                    .totalPixelBudgetExceeded(maximumPixels: 30_000))
            }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: totalStage.path), [])

        let byteStage = try makePrivateDirectory(at: root.appendingPathComponent("bytes"))
        XCTAssertThrowsError(try PDFNativeDocumentService.renderPages(
            from: input,
            into: byteStage,
            pages: [1],
            maximumPagePixels: 20_000,
            maximumTotalPixels: 20_000,
            maximumOutputBytes: 1)) { error in
                XCTAssertEqual(
                    error as? PDFNativeDocumentServiceError,
                    .outputByteBudgetExceeded(maximumBytes: 1))
            }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: byteStage.path), [])
        #else
        throw XCTSkip("PDFKit native PDF tests require Apple PDF frameworks")
        #endif
    }
}

#if canImport(AppKit) && canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO) && canImport(PDFKit)
private extension PDFNativeDocumentServiceTests {
    struct VisualFixture {
        let root: URL
        let pdf: URL
        let staging: URL
        let removeWhenFinished: Bool
    }

    func makePrivateTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-pdf-native-tests-\(UUID().uuidString)",
            isDirectory: true)
        return try makePrivateDirectory(at: url)
    }

    @discardableResult
    func makePrivateDirectory(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path)
        return url
    }

    func makeVisualVerificationFixture() throws -> VisualFixture {
        let configuredRoot = ProcessInfo.processInfo.environment[
            "INTATIS_PDF_NATIVE_VERIFY_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        let root: URL
        if let configuredRoot {
            root = configuredRoot
            if !FileManager.default.fileExists(atPath: root.path) {
                _ = try makePrivateDirectory(at: root)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path)
        } else {
            root = try makePrivateTemporaryDirectory()
        }
        let input = root.appendingPathComponent("visual-input.pdf")
        let staging = root.appendingPathComponent("render", isDirectory: true)
        if FileManager.default.fileExists(atPath: input.path)
            || FileManager.default.fileExists(atPath: staging.path)
        {
            throw XCTSkip("visual verification directory must be empty")
        }
        try makeGraphicsPDF(pageCount: 2, at: input, rotateSecondPage: true)
        _ = try makePrivateDirectory(at: staging)
        return VisualFixture(
            root: root,
            pdf: input,
            staging: staging,
            removeWhenFinished: configuredRoot == nil)
    }

    func makeTextPDF(pages: [String], at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 240, height: 120)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 1)
        }
        for text in pages {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 18),
                    .foregroundColor: NSColor.black,
                ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 16, y: 70)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(url: url) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 5)
        }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = "Intatis native text fixture"
        document.documentAttributes = attributes
        let rewritten = url.deletingLastPathComponent().appendingPathComponent(
            "metadata-\(UUID().uuidString).pdf")
        guard document.write(to: rewritten) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 6)
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: rewritten, to: url)
    }

    func makeGraphicsPDF(
        pageCount: Int,
        at url: URL,
        rotateSecondPage: Bool = false,
        addAnnotation: Bool = false
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 144, height: 72)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 2)
        }
        for _ in 0..<pageCount {
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: mediaBox,
                kCGPDFContextCropBox: CGRect(x: 24, y: 12, width: 96, height: 48),
            ]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fill(CGRect(x: 48, y: 24, width: 24, height: 24))
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fill(CGRect(x: 108, y: 54, width: 24, height: 12))
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 3)
        }
        for pageIndex in 0..<document.pageCount {
            document.page(at: pageIndex)?.setBounds(
                CGRect(x: 24, y: 12, width: 96, height: 48),
                for: .cropBox)
        }
        if rotateSecondPage, let secondPage = document.page(at: 1) {
            secondPage.rotation = 90
        }
        if addAnnotation {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 76, y: 20, width: 30, height: 24),
                forType: .square,
                withProperties: nil)
            annotation.color = .systemBlue
            let border = PDFBorder()
            border.lineWidth = 6
            annotation.border = border
            page.addAnnotation(annotation)
        }
        let rewritten = url.deletingLastPathComponent().appendingPathComponent(
            "rewritten-\(UUID().uuidString).pdf")
        guard document.write(to: rewritten) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 4)
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: rewritten, to: url)
    }

    func imageDimensions(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 5)
        }
        return (image.width, image.height)
    }

    func pixelColor(at url: URL, x: Int, y: Int) throws -> NSColor {
        guard let representation = NSBitmapImageRep(data: try Data(contentsOf: url)),
              let color = representation.colorAt(x: x, y: y) else {
            throw NSError(domain: "PDFNativeDocumentServiceTests", code: 6)
        }
        return color
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func assertSingleLinkRegularFile(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0, file: file, line: line)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG, file: file, line: line)
        XCTAssertEqual(status.st_nlink, 1, file: file, line: line)
    }
}
#endif
