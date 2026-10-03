#if canImport(SwiftUI)
import XCTest
@testable import IntatisSharedUI

final class IntatisTypographyTests: XCTestCase {
    func testJetBrainsMonoIsTheProductEnglishTypography() {
        for role in IntatisTypographyRole.allCases {
            XCTAssertEqual(IntatisTypography.spec(for: role).design, .jetBrainsMono)
        }
    }

    func testSharedTypographyRolesKeepTheCrossPlatformDesignContract() {
        let expected: [IntatisTypographyRole: IntatisTypographySpec] = [
            .brand: IntatisTypographySpec(
                nominalPointSize: 28,
                weight: .semibold,
                design: .jetBrainsMono),
            .largeTitle: IntatisTypographySpec(
                nominalPointSize: 30,
                weight: .semibold,
                design: .jetBrainsMono),
            .title: IntatisTypographySpec(
                nominalPointSize: 20,
                weight: .semibold,
                design: .jetBrainsMono),
            .headline: IntatisTypographySpec(
                nominalPointSize: 16,
                weight: .semibold,
                design: .jetBrainsMono),
            .body: IntatisTypographySpec(
                nominalPointSize: 14,
                weight: .regular,
                design: .jetBrainsMono),
            .caption: IntatisTypographySpec(
                nominalPointSize: 12,
                weight: .medium,
                design: .jetBrainsMono),
            .metadata: IntatisTypographySpec(
                nominalPointSize: 10,
                weight: .medium,
                design: .jetBrainsMono),
            .monospaced: IntatisTypographySpec(
                nominalPointSize: 13,
                weight: .regular,
                design: .jetBrainsMono),
            .chat: IntatisTypographySpec(
                nominalPointSize: 15,
                weight: .regular,
                design: .jetBrainsMono),
        ]

        XCTAssertEqual(Set(expected.keys), Set(IntatisTypographyRole.allCases))
        for role in IntatisTypographyRole.allCases {
            XCTAssertEqual(IntatisTypography.spec(for: role), expected[role])
        }
    }
}
#endif
