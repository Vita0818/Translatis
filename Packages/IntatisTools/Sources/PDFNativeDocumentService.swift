import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisTools PDF rendering requires CryptoKit or swift-crypto")
#endif

#if canImport(Darwin)
import Darwin
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(PDFKit)
import PDFKit
#endif

enum PDFNativePageBox: String, Codable, CaseIterable, Sendable {
    case mediaBox
    case cropBox
}

enum PDFNativeRenderBackground: String, Codable, CaseIterable, Sendable {
    case white
    case transparent
}

struct PDFNativeTextPage: Codable, Equatable, Sendable {
    let pageNumber: Int
    let text: String
    let hasExtractableText: Bool
}

struct PDFNativeTextReadResult: Codable, Equatable, Sendable {
    let pageCount: Int
    let metadata: [String: String]
    let pages: [PDFNativeTextPage]
    let combinedText: String

    /// True only when a non-empty PDF has no extractable native text on any
    /// page. Pages with no text are also reported individually so a caller can
    /// warn about mixed native/scanned documents without treating an ordinary
    /// blank page as proof that the whole document requires OCR.
    let requiresOCR: Bool
    let pagesWithoutExtractableText: [Int]
    let truncated: Bool
}

struct PDFNativeRenderedPage: Codable, Equatable, Sendable {
    let pageNumber: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let box: PDFNativePageBox
    let rotation: Int
    let fileName: String
    let mimeType: String
    let sha256: String
    let byteCount: Int

    enum CodingKeys: String, CodingKey {
        case pageNumber, pixelWidth, pixelHeight, box, rotation, fileName, sha256
        case mimeType = "mime_type"
        case byteCount = "byte_count"
    }
}

struct PDFNativeRenderManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourcePageCount: Int
    let dpi: Double
    let background: PDFNativeRenderBackground
    let includesAnnotations: Bool
    let pages: [PDFNativeRenderedPage]
    let totalPixelCount: Int
    let totalByteCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sourcePageCount, dpi, background, includesAnnotations, pages
        case totalPixelCount = "total_pixel_count"
        case totalByteCount = "total_byte_count"
    }

    init(
        sourcePageCount: Int,
        dpi: Double,
        background: PDFNativeRenderBackground,
        includesAnnotations: Bool,
        pages: [PDFNativeRenderedPage],
        totalPixelCount: Int,
        totalByteCount: Int
    ) {
        self.schemaVersion = 1
        self.sourcePageCount = sourcePageCount
        self.dpi = dpi
        self.background = background
        self.includesAnnotations = includesAnnotations
        self.pages = pages
        self.totalPixelCount = totalPixelCount
        self.totalByteCount = totalByteCount
    }
}

enum PDFNativeDocumentServiceError: Error, Equatable, Sendable {
    case unavailable
    case unsafeInput(String)
    case inputTooLarge(maximumBytes: UInt64)
    case inputChangedWhileReading
    case cannotOpenPDF
    case lockedPDF
    case tooManySourcePages(maximum: Int)
    case invalidMaximumCharacters(maximum: Int)
    case invalidPageNumber(Int)
    case tooManyRenderedPages(maximum: Int)
    case invalidDPI(minimum: Double, maximum: Double)
    case invalidRenderBudget(name: String, maximum: Int)
    case invalidPageGeometry(pageNumber: Int)
    case renderedPageTooLarge(pageNumber: Int, maximumPixels: Int, maximumDimension: Int)
    case totalPixelBudgetExceeded(maximumPixels: Int)
    case outputByteBudgetExceeded(maximumBytes: Int)
    case unsafeStagingDirectory(String)
    case stagingDirectoryNotEmpty
    case stagingDirectoryChanged
    case outputAlreadyExists(String)
    case bitmapCreationFailed(pageNumber: Int)
    case pngEncodingFailed(pageNumber: Int)
    case outputWriteFailed(String)
}

extension PDFNativeDocumentServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "native PDF reading and rendering require PDFKit, CoreGraphics, and ImageIO"
        case .unsafeInput(let reason):
            return "unsafe PDF input: \(reason)"
        case .inputTooLarge(let maximumBytes):
            return "PDF input exceeds the \(maximumBytes)-byte limit"
        case .inputChangedWhileReading:
            return "PDF input changed while it was being frozen"
        case .cannotOpenPDF:
            return "PDFKit could not open the input as a PDF"
        case .lockedPDF:
            return "the PDF is locked and no password was supplied"
        case .tooManySourcePages(let maximum):
            return "PDF exceeds the \(maximum)-page source limit"
        case .invalidMaximumCharacters(let maximum):
            return "maximumCharacters must be positive and no greater than \(maximum)"
        case .invalidPageNumber(let pageNumber):
            return "page \(pageNumber) is outside the PDF"
        case .tooManyRenderedPages(let maximum):
            return "a render request may contain at most \(maximum) pages"
        case .invalidDPI(let minimum, let maximum):
            return "DPI must be finite and between \(minimum) and \(maximum)"
        case .invalidRenderBudget(let name, let maximum):
            return "\(name) must be positive and no greater than the hard ceiling \(maximum)"
        case .invalidPageGeometry(let pageNumber):
            return "page \(pageNumber) has invalid PDF box geometry"
        case .renderedPageTooLarge(let pageNumber, let maximumPixels, let maximumDimension):
            return "page \(pageNumber) exceeds the render limits of \(maximumPixels) pixels and \(maximumDimension) pixels per dimension"
        case .totalPixelBudgetExceeded(let maximumPixels):
            return "selected PDF pages exceed the \(maximumPixels)-pixel total render budget"
        case .outputByteBudgetExceeded(let maximumBytes):
            return "rendered PDF bundle exceeds the \(maximumBytes)-byte output budget"
        case .unsafeStagingDirectory(let reason):
            return "unsafe PDF render staging directory: \(reason)"
        case .stagingDirectoryNotEmpty:
            return "PDF render staging directory must be empty"
        case .stagingDirectoryChanged:
            return "PDF render staging directory changed during rendering"
        case .outputAlreadyExists(let fileName):
            return "PDF render output already exists: \(fileName)"
        case .bitmapCreationFailed(let pageNumber):
            return "could not create the bitmap for PDF page \(pageNumber)"
        case .pngEncodingFailed(let pageNumber):
            return "could not encode PDF page \(pageNumber) as PNG"
        case .outputWriteFailed(let fileName):
            return "could not safely write PDF render output \(fileName)"
        }
    }
}

/// Native, read-only PDF operations. This type intentionally has no API that
/// writes to a PDF or changes its pages, boxes, annotations, or content.
enum PDFNativeDocumentService {
    static let maximumInputBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumSourcePages = 10_000
    static let maximumNativeTextCharacters = 500_000
    static let maximumRenderedPages = 200
    static let minimumDPI = 36.0
    static let maximumDPI = 600.0
    static let maximumPixelsPerPage = 100_000_000
    static let maximumTotalPixels = 1_000_000_000
    static let maximumOutputBytes = 2_147_483_648
    static let maximumPixelDimension = 20_000
    static let manifestFileName = "manifest.json"

    static func readNativeText(
        from inputURL: URL,
        pages requestedPages: [Int]? = nil,
        maximumCharacters: Int = 200_000
    ) throws -> PDFNativeTextReadResult {
        #if canImport(PDFKit) && canImport(Darwin)
        guard maximumCharacters > 0,
              maximumCharacters <= maximumNativeTextCharacters else {
            throw PDFNativeDocumentServiceError.invalidMaximumCharacters(
                maximum: maximumNativeTextCharacters)
        }
        let document = try loadDocument(from: inputURL)
        let selectedPages = try normalizedReadPageSelection(
            requestedPages,
            pageCount: document.pageCount)
        var pages: [PDFNativeTextPage] = []
        pages.reserveCapacity(selectedPages.count)
        var pagesWithoutText: [Int] = []
        var combinedText = ""
        var usedCharacters = 0
        var truncated = false
        var foundExtractableText = false

        for (selectionIndex, pageNumber) in selectedPages.enumerated() {
            try Task<Never, Never>.checkCancellation()
            let text = (document.page(at: pageNumber - 1)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasText = !text.isEmpty
            foundExtractableText = foundExtractableText || hasText
            if !hasText {
                pagesWithoutText.append(pageNumber)
                pages.append(PDFNativeTextPage(
                    pageNumber: pageNumber,
                    text: "",
                    hasExtractableText: false))
                continue
            }

            let separator = combinedText.isEmpty ? "" : "\n\n"
            let separatorCount = separator.count
            guard usedCharacters + separatorCount < maximumCharacters else {
                truncated = true
                break
            }
            let remaining = maximumCharacters - usedCharacters - separatorCount
            let retainedText = String(text.prefix(remaining))
            combinedText += separator + retainedText
            usedCharacters += separatorCount + retainedText.count
            pages.append(PDFNativeTextPage(
                pageNumber: pageNumber,
                text: retainedText,
                hasExtractableText: hasText))
            if retainedText.count < text.count
                || (usedCharacters == maximumCharacters
                    && selectionIndex + 1 < selectedPages.count)
            {
                truncated = true
                break
            }
        }

        return PDFNativeTextReadResult(
            pageCount: document.pageCount,
            metadata: basicMetadata(from: document),
            pages: pages,
            combinedText: combinedText,
            requiresOCR: !selectedPages.isEmpty && !foundExtractableText,
            pagesWithoutExtractableText: pagesWithoutText,
            truncated: truncated)
        #else
        throw PDFNativeDocumentServiceError.unavailable
        #endif
    }

    #if canImport(PDFKit)
    private static func basicMetadata(from document: PDFDocument) -> [String: String] {
        let attributes = document.documentAttributes ?? [:]
        var metadata: [String: String] = [:]
        let stringFields: [(String, PDFDocumentAttribute)] = [
            ("title", .titleAttribute),
            ("author", .authorAttribute),
            ("subject", .subjectAttribute),
            ("creator", .creatorAttribute),
            ("producer", .producerAttribute),
        ]
        for (name, key) in stringFields {
            if let value = attributes[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadata[name] = value
            }
        }
        let dateFields: [(String, PDFDocumentAttribute)] = [
            ("creation_date", .creationDateAttribute),
            ("modification_date", .modificationDateAttribute),
        ]
        let formatter = ISO8601DateFormatter()
        for (name, key) in dateFields {
            if let value = attributes[key] as? Date {
                metadata[name] = formatter.string(from: value)
            }
        }
        if let values = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String],
           !values.isEmpty {
            metadata["keywords"] = values.joined(separator: ", ")
        } else if let value = attributes[PDFDocumentAttribute.keywordsAttribute] as? String,
                  !value.isEmpty {
            metadata["keywords"] = value
        }
        return metadata
    }
    #endif

    /// Draws one one-based PDF page through one PDFKit `PDFPage.draw` call and
    /// returns the encoded PNG bytes. Output staging and atomic commit remain
    /// the caller's responsibility.
    static func renderPagePNG(
        from inputURL: URL,
        pageNumber: Int,
        box: PDFNativePageBox = .cropBox,
        dpi: Double = 144,
        background: PDFNativeRenderBackground = .white,
        includeAnnotations: Bool = true,
        maximumPagePixels: Int,
        maximumOutputBytes: Int
    ) throws -> Data {
        #if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(Darwin)
        guard dpi.isFinite, dpi >= minimumDPI, dpi <= maximumDPI else {
            throw PDFNativeDocumentServiceError.invalidDPI(
                minimum: minimumDPI,
                maximum: maximumDPI)
        }
        try validateRenderBudget(
            maximumPagePixels,
            name: "maximumPagePixels",
            ceiling: Self.maximumPixelsPerPage)
        try validateRenderBudget(
            maximumOutputBytes,
            name: "maximumOutputBytes",
            ceiling: Self.maximumOutputBytes)
        let document = try loadDocument(from: inputURL)
        guard pageNumber >= 1,
              pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else {
            throw PDFNativeDocumentServiceError.invalidPageNumber(pageNumber)
        }
        try Task<Never, Never>.checkCancellation()
        let geometry = try renderGeometry(
            page: page,
            pageNumber: pageNumber,
            box: box,
            dpi: dpi,
            maximumPagePixels: maximumPagePixels)
        let rendered = try render(
            page: page,
            pageNumber: pageNumber,
            box: box,
            geometry: geometry,
            background: background,
            includeAnnotations: includeAnnotations)
        guard rendered.pngData.count <= maximumOutputBytes else {
            throw PDFNativeDocumentServiceError.outputByteBudgetExceeded(
                maximumBytes: maximumOutputBytes)
        }
        try Task<Never, Never>.checkCancellation()
        return rendered.pngData
        #else
        throw PDFNativeDocumentServiceError.unavailable
        #endif
    }

    /// Renders pages into an already-created, private staging directory. The
    /// caller owns committing or discarding that directory as one artifact.
    /// Page numbers are one-based; nil selects all pages. Explicit selections
    /// are de-duplicated and sorted to make output naming deterministic.
    static func renderPages(
        from inputURL: URL,
        into stagingDirectory: URL,
        pages requestedPages: [Int]? = nil,
        box: PDFNativePageBox = .cropBox,
        dpi: Double = 144,
        background: PDFNativeRenderBackground = .white,
        includeAnnotations: Bool = true,
        maximumPagePixels: Int,
        maximumTotalPixels: Int,
        maximumOutputBytes: Int
    ) throws -> PDFNativeRenderManifest {
        #if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(Darwin)
        guard dpi.isFinite, dpi >= minimumDPI, dpi <= maximumDPI else {
            throw PDFNativeDocumentServiceError.invalidDPI(
                minimum: minimumDPI,
                maximum: maximumDPI)
        }
        try validateRenderBudget(
            maximumPagePixels,
            name: "maximumPagePixels",
            ceiling: Self.maximumPixelsPerPage)
        try validateRenderBudget(
            maximumTotalPixels,
            name: "maximumTotalPixels",
            ceiling: Self.maximumTotalPixels)
        try validateRenderBudget(
            maximumOutputBytes,
            name: "maximumOutputBytes",
            ceiling: Self.maximumOutputBytes)

        let document = try loadDocument(from: inputURL)
        let selectedPages = try normalizedPageSelection(
            requestedPages,
            pageCount: document.pageCount)
        var plannedGeometry: [Int: RenderGeometry] = [:]
        plannedGeometry.reserveCapacity(selectedPages.count)
        var plannedTotalPixels = 0
        for pageNumber in selectedPages {
            try Task<Never, Never>.checkCancellation()
            guard let page = document.page(at: pageNumber - 1) else {
                throw PDFNativeDocumentServiceError.invalidPageNumber(pageNumber)
            }
            let geometry = try renderGeometry(
                page: page,
                pageNumber: pageNumber,
                box: box,
                dpi: dpi,
                maximumPagePixels: maximumPagePixels)
            let (nextTotalPixels, overflow) = plannedTotalPixels
                .addingReportingOverflow(geometry.pixelCount)
            guard !overflow, nextTotalPixels <= maximumTotalPixels else {
                throw PDFNativeDocumentServiceError.totalPixelBudgetExceeded(
                    maximumPixels: maximumTotalPixels)
            }
            plannedTotalPixels = nextTotalPixels
            plannedGeometry[pageNumber] = geometry
        }
        let staging = try openEmptyStagingDirectory(stagingDirectory)
        defer { _ = close(staging.descriptor) }

        var createdFileNames: [String] = []
        do {
            var renderedPages: [PDFNativeRenderedPage] = []
            renderedPages.reserveCapacity(selectedPages.count)
            var totalPixelCount = 0
            var totalByteCount = 0

            for pageNumber in selectedPages {
                try Task<Never, Never>.checkCancellation()
                guard let page = document.page(at: pageNumber - 1),
                      let geometry = plannedGeometry[pageNumber] else {
                    throw PDFNativeDocumentServiceError.invalidPageNumber(pageNumber)
                }
                let (nextTotalPixels, pixelOverflow) = totalPixelCount
                    .addingReportingOverflow(geometry.pixelCount)
                guard !pixelOverflow, nextTotalPixels <= maximumTotalPixels else {
                    throw PDFNativeDocumentServiceError.totalPixelBudgetExceeded(
                        maximumPixels: maximumTotalPixels)
                }
                let rendered = try render(
                    page: page,
                    pageNumber: pageNumber,
                    box: box,
                    geometry: geometry,
                    background: background,
                    includeAnnotations: includeAnnotations)
                try Task<Never, Never>.checkCancellation()
                let byteCount = rendered.pngData.count
                let (nextTotalBytes, byteOverflow) = totalByteCount
                    .addingReportingOverflow(byteCount)
                guard !byteOverflow, nextTotalBytes <= maximumOutputBytes else {
                    throw PDFNativeDocumentServiceError.outputByteBudgetExceeded(
                        maximumBytes: maximumOutputBytes)
                }
                let fileName = String(format: "page-%04d.png", pageNumber)
                try writeExclusive(
                    rendered.pngData,
                    named: fileName,
                    in: staging.descriptor)
                createdFileNames.append(fileName)
                totalPixelCount = nextTotalPixels
                totalByteCount = nextTotalBytes
                renderedPages.append(PDFNativeRenderedPage(
                    pageNumber: pageNumber,
                    pixelWidth: geometry.pixelWidth,
                    pixelHeight: geometry.pixelHeight,
                    box: box,
                    rotation: normalizedRotation(page.rotation),
                    fileName: fileName,
                    mimeType: "image/png",
                    sha256: sha256Hex(rendered.pngData),
                    byteCount: byteCount))
            }

            try Task<Never, Never>.checkCancellation()
            let manifest = PDFNativeRenderManifest(
                sourcePageCount: document.pageCount,
                dpi: dpi,
                background: background,
                includesAnnotations: includeAnnotations,
                pages: renderedPages,
                totalPixelCount: totalPixelCount,
                totalByteCount: totalByteCount)
            let manifestData = try encodeManifest(manifest)
            let (bundleByteCount, manifestOverflow) = totalByteCount
                .addingReportingOverflow(manifestData.count)
            guard !manifestOverflow, bundleByteCount <= maximumOutputBytes else {
                throw PDFNativeDocumentServiceError.outputByteBudgetExceeded(
                    maximumBytes: maximumOutputBytes)
            }
            try writeExclusive(
                manifestData,
                named: manifestFileName,
                in: staging.descriptor)
            createdFileNames.append(manifestFileName)
            guard fsync(staging.descriptor) == 0 else {
                throw PDFNativeDocumentServiceError.outputWriteFailed(manifestFileName)
            }
            try verifyDirectoryIdentity(staging, at: stagingDirectory)
            return manifest
        } catch {
            for fileName in createdFileNames.reversed() {
                _ = fileName.withCString { unlinkat(staging.descriptor, $0, 0) }
            }
            _ = fsync(staging.descriptor)
            throw error
        }
        #else
        throw PDFNativeDocumentServiceError.unavailable
        #endif
    }
}

#if canImport(PDFKit) && canImport(Darwin)
private extension PDFNativeDocumentService {
    struct FrozenInputIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationSeconds: Int
        let modificationNanoseconds: Int

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = UInt64(status.st_size)
            modificationSeconds = Int(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int(status.st_mtimespec.tv_nsec)
        }
    }

    static func loadDocument(from inputURL: URL) throws -> PDFDocument {
        guard inputURL.isFileURL else {
            throw PDFNativeDocumentServiceError.unsafeInput("input must be a local file URL")
        }

        var pathStatus = stat()
        guard lstat(inputURL.path, &pathStatus) == 0 else {
            throw PDFNativeDocumentServiceError.unsafeInput("input does not exist")
        }
        guard (pathStatus.st_mode & S_IFMT) != S_IFLNK else {
            throw PDFNativeDocumentServiceError.unsafeInput("symbolic links are not allowed")
        }

        let descriptor = open(inputURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PDFNativeDocumentServiceError.unsafeInput("input could not be opened without following links")
        }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw PDFNativeDocumentServiceError.unsafeInput("input must be a single-link regular file")
        }
        guard before.st_dev == pathStatus.st_dev,
              before.st_ino == pathStatus.st_ino else {
            throw PDFNativeDocumentServiceError.inputChangedWhileReading
        }
        let identity = FrozenInputIdentity(before)
        guard identity.size <= maximumInputBytes else {
            throw PDFNativeDocumentServiceError.inputTooLarge(maximumBytes: maximumInputBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(identity.size))
        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return read(descriptor, baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PDFNativeDocumentServiceError.unsafeInput("input could not be read")
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              FrozenInputIdentity(after) == identity else {
            throw PDFNativeDocumentServiceError.inputChangedWhileReading
        }
        guard let document = PDFDocument(data: data) else {
            throw PDFNativeDocumentServiceError.cannotOpenPDF
        }
        guard !document.isLocked else {
            throw PDFNativeDocumentServiceError.lockedPDF
        }
        guard document.pageCount <= maximumSourcePages else {
            throw PDFNativeDocumentServiceError.tooManySourcePages(maximum: maximumSourcePages)
        }
        return document
    }

    static func normalizedPageSelection(
        _ requestedPages: [Int]?,
        pageCount: Int
    ) throws -> [Int] {
        guard let requestedPages else {
            guard pageCount <= maximumRenderedPages else {
                throw PDFNativeDocumentServiceError.tooManyRenderedPages(
                    maximum: maximumRenderedPages)
            }
            return pageCount > 0 ? Array(1...pageCount) : []
        }
        guard requestedPages.count <= maximumRenderedPages else {
            throw PDFNativeDocumentServiceError.tooManyRenderedPages(
                maximum: maximumRenderedPages)
        }
        var unique = Set<Int>()
        for pageNumber in requestedPages {
            guard pageNumber >= 1, pageNumber <= pageCount else {
                throw PDFNativeDocumentServiceError.invalidPageNumber(pageNumber)
            }
            unique.insert(pageNumber)
        }
        return unique.sorted()
    }

    static func normalizedReadPageSelection(
        _ requestedPages: [Int]?,
        pageCount: Int
    ) throws -> [Int] {
        guard let requestedPages else {
            return pageCount > 0 ? Array(1...pageCount) : []
        }
        var unique = Set<Int>()
        for pageNumber in requestedPages {
            guard pageNumber >= 1, pageNumber <= pageCount else {
                throw PDFNativeDocumentServiceError.invalidPageNumber(pageNumber)
            }
            unique.insert(pageNumber)
        }
        return unique.sorted()
    }
}
#endif

#if canImport(PDFKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(Darwin)
private extension PDFNativePageBox {
    var pdfDisplayBox: PDFDisplayBox {
        switch self {
        case .mediaBox: return .mediaBox
        case .cropBox: return .cropBox
        }
    }
}

private extension PDFNativeDocumentService {
    struct OpenStagingDirectory {
        let descriptor: Int32
        let device: UInt64
        let inode: UInt64
    }

    struct RenderedPNG {
        let pngData: Data
    }

    struct RenderGeometry {
        let pixelWidth: Int
        let pixelHeight: Int
        let pixelCount: Int
        let displayWidth: CGFloat
        let displayHeight: CGFloat
    }

    static func validateRenderBudget(
        _ value: Int,
        name: String,
        ceiling: Int
    ) throws {
        guard value > 0, value <= ceiling else {
            throw PDFNativeDocumentServiceError.invalidRenderBudget(
                name: name,
                maximum: ceiling)
        }
    }

    static func renderGeometry(
        page: PDFPage,
        pageNumber: Int,
        box: PDFNativePageBox,
        dpi: Double,
        maximumPagePixels: Int
    ) throws -> RenderGeometry {
        let bounds = page.bounds(for: box.pdfDisplayBox).standardized
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            throw PDFNativeDocumentServiceError.invalidPageGeometry(pageNumber: pageNumber)
        }

        let rotation = normalizedRotation(page.rotation)
        let displayWidth = rotation == 90 || rotation == 270 ? bounds.height : bounds.width
        let displayHeight = rotation == 90 || rotation == 270 ? bounds.width : bounds.height
        let pixelsPerPoint = dpi / 72
        let rawWidth = Double(displayWidth) * pixelsPerPoint
        let rawHeight = Double(displayHeight) * pixelsPerPoint
        guard rawWidth.isFinite,
              rawHeight.isFinite,
              rawWidth > 0,
              rawHeight > 0,
              rawWidth <= Double(Int.max),
              rawHeight <= Double(Int.max) else {
            throw PDFNativeDocumentServiceError.invalidPageGeometry(pageNumber: pageNumber)
        }
        let pixelWidth = Int(rawWidth.rounded(.up))
        let pixelHeight = Int(rawHeight.rounded(.up))
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow,
              pixelWidth <= maximumPixelDimension,
              pixelHeight <= maximumPixelDimension,
              pixelCount <= maximumPagePixels else {
            throw PDFNativeDocumentServiceError.renderedPageTooLarge(
                pageNumber: pageNumber,
                maximumPixels: maximumPagePixels,
                maximumDimension: maximumPixelDimension)
        }
        return RenderGeometry(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pixelCount: pixelCount,
            displayWidth: displayWidth,
            displayHeight: displayHeight)
    }

    static func render(
        page: PDFPage,
        pageNumber: Int,
        box: PDFNativePageBox,
        geometry: RenderGeometry,
        background: PDFNativeRenderBackground,
        includeAnnotations: Bool
    ) throws -> RenderedPNG {
        let pixelWidth = geometry.pixelWidth
        let pixelHeight = geometry.pixelHeight

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw PDFNativeDocumentServiceError.bitmapCreationFailed(pageNumber: pageNumber)
        }

        let outputRect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        switch background {
        case .white:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(outputRect)
        case .transparent:
            context.clear(outputRect)
        }
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.saveGState()
        context.scaleBy(
            x: CGFloat(pixelWidth) / geometry.displayWidth,
            y: CGFloat(pixelHeight) / geometry.displayHeight)
        let previousDisplaysAnnotations = page.displaysAnnotations
        page.displaysAnnotations = includeAnnotations
        page.draw(with: box.pdfDisplayBox, to: context)
        page.displaysAnnotations = previousDisplaysAnnotations
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw PDFNativeDocumentServiceError.bitmapCreationFailed(pageNumber: pageNumber)
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.png" as CFString,
            1,
            nil)
        else {
            throw PDFNativeDocumentServiceError.pngEncodingFailed(pageNumber: pageNumber)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PDFNativeDocumentServiceError.pngEncodingFailed(pageNumber: pageNumber)
        }
        return RenderedPNG(
            pngData: mutableData as Data)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedRotation(_ rotation: Int) -> Int {
        let remainder = rotation % 360
        return remainder >= 0 ? remainder : remainder + 360
    }

    static func openEmptyStagingDirectory(
        _ url: URL
    ) throws -> OpenStagingDirectory {
        guard url.isFileURL else {
            throw PDFNativeDocumentServiceError.unsafeStagingDirectory(
                "staging must be a local file URL")
        }
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw PDFNativeDocumentServiceError.unsafeStagingDirectory(
                "staging must be an existing directory and not a symbolic link")
        }
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw PDFNativeDocumentServiceError.unsafeStagingDirectory(
                "staging could not be opened without following links")
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_dev == pathStatus.st_dev,
              status.st_ino == pathStatus.st_ino,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            _ = close(descriptor)
            throw PDFNativeDocumentServiceError.unsafeStagingDirectory(
                "staging must remain an owner-private directory")
        }
        do {
            guard try directoryIsEmpty(descriptor) else {
                _ = close(descriptor)
                throw PDFNativeDocumentServiceError.stagingDirectoryNotEmpty
            }
        } catch {
            _ = close(descriptor)
            throw error
        }
        return OpenStagingDirectory(
            descriptor: descriptor,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino))
    }

    static func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = close(duplicate) }
            throw PDFNativeDocumentServiceError.unsafeStagingDirectory(
                "staging contents could not be inspected")
        }
        defer { _ = closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                return false
            }
        }
        return true
    }

    static func verifyDirectoryIdentity(
        _ expected: OpenStagingDirectory,
        at url: URL
    ) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              UInt64(status.st_dev) == expected.device,
              UInt64(status.st_ino) == expected.inode else {
            throw PDFNativeDocumentServiceError.stagingDirectoryChanged
        }
    }

    static func encodeManifest(_ manifest: PDFNativeRenderManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        return data
    }

    static func writeExclusive(
        _ data: Data,
        named fileName: String,
        in directoryDescriptor: Int32
    ) throws {
        let descriptor = fileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST || errno == ELOOP {
                throw PDFNativeDocumentServiceError.outputAlreadyExists(fileName)
            }
            throw PDFNativeDocumentServiceError.outputWriteFailed(fileName)
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove {
                _ = fileName.withCString { unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw PDFNativeDocumentServiceError.outputWriteFailed(fileName)
                    }
                    guard count > 0 else {
                        throw PDFNativeDocumentServiceError.outputWriteFailed(fileName)
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw PDFNativeDocumentServiceError.outputWriteFailed(fileName)
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  status.st_uid == geteuid(),
                  UInt64(status.st_size) == UInt64(data.count) else {
                throw PDFNativeDocumentServiceError.outputWriteFailed(fileName)
            }
            shouldRemove = false
        } catch {
            throw error
        }
    }
}
#endif
