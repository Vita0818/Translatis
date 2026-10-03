#if canImport(SwiftUI)
import CryptoKit
import CoreText
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Cross-platform typography roles shared by the macOS workbench and iOS Chat.
///
/// App views may scale the nominal point size with `@ScaledMetric`, but should
/// keep the role's weight and design so both platforms retain the same visual
/// voice. JetBrains Mono is the product English family for every role; point
/// size and weight retain hierarchy, while glyphs absent from JetBrains Mono
/// (including Chinese) continue through Apple Core Text fallback.
public enum IntatisTypographyRole: String, CaseIterable, Hashable, Sendable {
    case brand
    case largeTitle
    case title
    case headline
    case body
    case caption
    case metadata
    case monospaced
    case chat
}

public struct IntatisTypographySpec: Equatable, Sendable {
    public enum Design: String, Sendable {
        case jetBrainsMono
    }

    public enum Weight: String, Sendable {
        case regular
        case medium
        case semibold
    }

    public let nominalPointSize: CGFloat
    public let weight: Weight
    public let design: Design

    public init(
        nominalPointSize: CGFloat,
        weight: Weight,
        design: Design
    ) {
        self.nominalPointSize = nominalPointSize
        self.weight = weight
        self.design = design
    }
}

public enum IntatisTypography {
    /// Performs exact resource validation and process-local Core Text
    /// registration for the product English family. It cannot silently fall
    /// back to an installed font or another English family.
    public static func prepareJetBrainsMonoTypography() {
        JetBrainsMonoTypography.prepare()
    }

    /// Root environment font for otherwise unstyled first-party `Text`.
    /// Explicit role fonts are independently routed in `font(for:...)`.
    public static var globalFont: Font {
        system(.body)
    }

    public static func spec(for role: IntatisTypographyRole) -> IntatisTypographySpec {
        switch role {
        case .brand:
            return IntatisTypographySpec(
                nominalPointSize: 28,
                weight: .semibold,
                design: .jetBrainsMono)
        case .largeTitle:
            return IntatisTypographySpec(
                nominalPointSize: 30,
                weight: .semibold,
                design: .jetBrainsMono)
        case .title:
            return IntatisTypographySpec(
                nominalPointSize: 20,
                weight: .semibold,
                design: .jetBrainsMono)
        case .headline:
            return IntatisTypographySpec(
                nominalPointSize: 16,
                weight: .semibold,
                design: .jetBrainsMono)
        case .body:
            return IntatisTypographySpec(
                nominalPointSize: 14,
                weight: .regular,
                design: .jetBrainsMono)
        case .caption:
            return IntatisTypographySpec(
                nominalPointSize: 12,
                weight: .medium,
                design: .jetBrainsMono)
        case .metadata:
            return IntatisTypographySpec(
                nominalPointSize: 10,
                weight: .medium,
                design: .jetBrainsMono)
        case .monospaced:
            return IntatisTypographySpec(
                nominalPointSize: 13,
                weight: .regular,
                design: .jetBrainsMono)
        case .chat:
            return IntatisTypographySpec(
                nominalPointSize: 15,
                weight: .regular,
                design: .jetBrainsMono)
        }
    }

    public static func font(
        for role: IntatisTypographyRole,
        size: CGFloat? = nil,
        weight: Font.Weight? = nil
    ) -> Font {
        let spec = spec(for: role)
        let resolvedSize = size ?? spec.nominalPointSize
        let resolvedWeight = weight ?? spec.weight.swiftUIWeight
        return JetBrainsMonoTypography.font(
            fixedSize: resolvedSize,
            weight: resolvedWeight)
    }

    /// JetBrains-Mono equivalent of `Font.system(size:weight:design:)`.
    /// `design` is retained so existing semantic call sites preserve their
    /// shape while the product family remains unified.
    public static func system(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design _: Font.Design = .default
    ) -> Font {
        return JetBrainsMonoTypography.font(
            fixedSize: size,
            weight: weight)
    }

    /// JetBrains-Mono equivalent of `Font.system(_:design:)`, with optional
    /// explicit weight used by existing semantic-font call sites.
    public static func system(
        _ style: Font.TextStyle,
        design _: Font.Design = .default,
        weight: Font.Weight? = nil,
        bold: Bool = false,
        monospacedDigits _: Bool = false
    ) -> Font {
        return JetBrainsMonoTypography.font(
            size: semanticPointSize(for: style),
            relativeTo: style,
            weight: bold ? .bold : weight ?? defaultWeight(for: style))
    }

    public static func brand(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .brand, size: size, weight: weight)
    }

    public static func largeTitle(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .largeTitle, size: size, weight: weight)
    }

    public static func title(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .title, size: size, weight: weight)
    }

    public static func headline(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .headline, size: size, weight: weight)
    }

    public static func body(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .body, size: size, weight: weight)
    }

    public static func caption(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .caption, size: size, weight: weight)
    }

    public static func metadata(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .metadata, size: size, weight: weight)
    }

    public static func mono(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .monospaced, size: size, weight: weight)
    }

    public static func chat(
        _ size: CGFloat? = nil,
        _ weight: Font.Weight? = nil
    ) -> Font {
        font(for: .chat, size: size, weight: weight)
    }

    #if canImport(AppKit)
    static func jetBrainsMonoPlatformFont(
        size: CGFloat,
        weight: Font.Weight,
        italic: Bool = false
    ) -> NSFont {
        JetBrainsMonoTypography.platformFont(
            size: size,
            weight: weight,
            italic: italic)
    }
    #elseif canImport(UIKit)
    static func jetBrainsMonoPlatformFont(
        size: CGFloat,
        weight: Font.Weight,
        italic: Bool = false
    ) -> UIFont {
        JetBrainsMonoTypography.platformFont(
            size: size,
            weight: weight,
            italic: italic)
    }
    #endif

    private static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    private static func semanticPointSize(for style: Font.TextStyle) -> CGFloat {
        #if os(iOS)
        if style == .largeTitle { return 34 }
        if style == .title { return 28 }
        if style == .title2 { return 22 }
        if style == .title3 { return 20 }
        if style == .headline { return 17 }
        if style == .body { return 17 }
        if style == .callout { return 16 }
        if style == .subheadline { return 15 }
        if style == .footnote { return 13 }
        if style == .caption { return 12 }
        if style == .caption2 { return 11 }
        #else
        if style == .largeTitle { return 26 }
        if style == .title { return 22 }
        if style == .title2 { return 17 }
        if style == .title3 { return 15 }
        if style == .headline { return 13 }
        if style == .body { return 13 }
        if style == .callout { return 12 }
        if style == .subheadline { return 11 }
        if style == .footnote { return 10 }
        if style == .caption { return 11 }
        if style == .caption2 { return 10 }
        #endif
        return spec(for: .body).nominalPointSize
    }
}

struct IntatisJetBrainsMonoResource: Equatable, Sendable {
    let resourceName: String
    let sha256: String
    let postScriptNames: Set<String>
}

private enum JetBrainsMonoTypography {
    static let resources: [IntatisJetBrainsMonoResource] = [
        IntatisJetBrainsMonoResource(
            resourceName: "JetBrainsMono[wght]",
            sha256: "662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016",
            postScriptNames: Set([
                "JetBrainsMono-Regular_Thin",
                "JetBrainsMono-Regular_ExtraLight",
                "JetBrainsMono-Regular_Light",
                "JetBrainsMono-Regular",
                "JetBrainsMono-Regular_Medium",
                "JetBrainsMono-Regular_SemiBold",
                "JetBrainsMono-Regular_Bold",
                "JetBrainsMono-Regular_ExtraBold",
            ])),
        IntatisJetBrainsMonoResource(
            resourceName: "JetBrainsMono-Italic[wght]",
            sha256: "f115aaa12113718c02ce72864fe6823b87241bc23d3e44cf1220155f861063f2",
            postScriptNames: Set([
                "JetBrainsMono-Italic_Thin-Italic",
                "JetBrainsMono-Italic_ExtraLight-Italic",
                "JetBrainsMono-Italic_Light-Italic",
                "JetBrainsMono-Italic",
                "JetBrainsMono-Italic_Medium-Italic",
                "JetBrainsMono-Italic_SemiBold-Italic",
                "JetBrainsMono-Italic_Bold-Italic",
                "JetBrainsMono-Italic_ExtraBold-Italic",
            ])),
    ]

    private static let registrationResult: Result<Void, Error> = Result {
        var resourceURLsByName: [String: URL] = [:]
        for resource in resources {
            guard let url = Bundle.module.url(
                forResource: resource.resourceName,
                withExtension: "ttf") else {
                throw RegistrationError.missingResource(resource.resourceName)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualHash == resource.sha256 else {
                throw RegistrationError.hashMismatch(
                    resource: resource.resourceName,
                    expected: resource.sha256,
                    actual: actualHash)
            }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
                url as CFURL) as? [CTFontDescriptor] else {
                throw RegistrationError.unreadableFont(resource.resourceName)
            }
            let names = Set(descriptors.compactMap { descriptor in
                CTFontDescriptorCopyAttribute(
                    descriptor,
                    kCTFontNameAttribute) as? String
            })
            guard names == resource.postScriptNames else {
                throw RegistrationError.descriptorMismatch(
                    resource: resource.resourceName,
                    expected: resource.postScriptNames,
                    actual: names)
            }
            var unmanagedError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &unmanagedError) else {
                let reason = unmanagedError?
                    .takeRetainedValue()
                    .localizedDescription ?? "unknown Core Text error"
                throw RegistrationError.registrationFailed(
                    resource: resource.resourceName,
                    reason: reason)
            }
            for name in names {
                resourceURLsByName[name] = url
            }
        }

        for (name, expectedURL) in resourceURLsByName {
            let font = CTFontCreateWithName(name as CFString, 15, nil)
            guard CTFontCopyPostScriptName(font) as String == name,
                  let resolvedURL = CTFontCopyAttribute(
                    font,
                    kCTFontURLAttribute) as? URL,
                  canonical(resolvedURL) == canonical(expectedURL) else {
                throw RegistrationError.resolutionMismatch(name)
            }
        }
    }

    static func prepare() {
        switch registrationResult {
        case .success:
            return
        case let .failure(error):
            preconditionFailure(
                "JetBrains Mono typography could not start: \(error.localizedDescription)")
        }
    }

    static func font(
        fixedSize: CGFloat,
        weight: Font.Weight,
        italic: Bool = false
    ) -> Font {
        prepare()
        return .custom(
            postScriptName(weight: weight, italic: italic),
            fixedSize: fixedSize)
    }

    static func font(
        size: CGFloat,
        relativeTo style: Font.TextStyle,
        weight: Font.Weight,
        italic: Bool = false
    ) -> Font {
        prepare()
        return .custom(
            postScriptName(weight: weight, italic: italic),
            size: size,
            relativeTo: style)
    }

    #if canImport(AppKit)
    static func platformFont(
        size: CGFloat,
        weight: Font.Weight,
        italic: Bool
    ) -> NSFont {
        prepare()
        let name = postScriptName(weight: weight, italic: italic)
        guard let font = NSFont(name: name, size: size) else {
            preconditionFailure(
                "JetBrains Mono typography could not resolve \(name)")
        }
        return font
    }
    #elseif canImport(UIKit)
    static func platformFont(
        size: CGFloat,
        weight: Font.Weight,
        italic: Bool
    ) -> UIFont {
        prepare()
        let name = postScriptName(weight: weight, italic: italic)
        guard let font = UIFont(name: name, size: size) else {
            preconditionFailure(
                "JetBrains Mono typography could not resolve \(name)")
        }
        return font
    }
    #endif

    private static func postScriptName(
        weight: Font.Weight,
        italic: Bool
    ) -> String {
        let suffix: String
        if weight == .ultraLight || weight == .thin {
            suffix = "Thin"
        } else if weight == .light {
            suffix = "Light"
        } else if weight == .medium {
            suffix = "Medium"
        } else if weight == .semibold {
            suffix = "SemiBold"
        } else if weight == .bold {
            suffix = "Bold"
        } else if weight == .heavy || weight == .black {
            suffix = "ExtraBold"
        } else {
            suffix = "Regular"
        }

        if italic {
            return suffix == "Regular"
                ? "JetBrainsMono-Italic"
                : "JetBrainsMono-Italic_\(suffix)-Italic"
        }
        return suffix == "Regular"
            ? "JetBrainsMono-Regular"
            : "JetBrainsMono-Regular_\(suffix)"
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private enum RegistrationError: LocalizedError {
    case missingResource(String)
    case unreadableFont(String)
    case hashMismatch(resource: String, expected: String, actual: String)
    case descriptorMismatch(resource: String, expected: Set<String>, actual: Set<String>)
    case registrationFailed(resource: String, reason: String)
    case resolutionMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(resource):
            return "missing bundled resource \(resource).ttf"
        case let .unreadableFont(resource):
            return "Core Text could not read \(resource).ttf"
        case let .hashMismatch(resource, expected, actual):
            return "\(resource).ttf hash mismatch (expected \(expected), got \(actual))"
        case let .descriptorMismatch(resource, expected, actual):
            return "\(resource).ttf descriptor mismatch (expected \(expected.sorted()), got \(actual.sorted()))"
        case let .registrationFailed(resource, reason):
            return "Core Text rejected \(resource).ttf: \(reason)"
        case let .resolutionMismatch(name):
            return "Core Text resolved \(name) outside the bundled product resource"
        }
    }
}

private extension IntatisTypographySpec.Weight {
    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        }
    }
}
#endif
