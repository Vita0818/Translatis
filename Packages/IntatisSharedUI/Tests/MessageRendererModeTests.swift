import XCTest
@testable import IntatisSharedUI

final class MessageRendererModeTests: XCTestCase {
    func testDefaultsToMicrosoftWhenNoPreferenceExistsAfterCutover() {
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: nil,
                arguments: ["Intatis"]),
            .microsoft)
    }

    func testPersistedPlainSafeModeIsPreserved() {
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: IntatisMessageRendererMode.plainSafe.rawValue,
                arguments: ["Intatis"]),
            .plainSafe)
    }

    func testLaunchArgumentsOverridePersistedPreference() {
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: IntatisMessageRendererMode.microsoft.rawValue,
                arguments: ["Intatis", IntatisMessageRendererMode.plainSafeLaunchArgument]),
            .plainSafe)
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: IntatisMessageRendererMode.plainSafe.rawValue,
                arguments: ["Intatis", IntatisMessageRendererMode.microsoftLaunchArgument]),
            .microsoft)
    }

    func testPlainSafeWinsContradictoryLaunchArguments() {
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: nil,
                arguments: [
                    "Intatis",
                    IntatisMessageRendererMode.microsoftLaunchArgument,
                    IntatisMessageRendererMode.plainSafeLaunchArgument,
                ]),
            .plainSafe)
    }

    func testUnknownPersistedValueFailsToPlainSafe() {
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: "future-value",
                arguments: ["Intatis"]),
            .plainSafe)
    }

    func testLegacyRichPreferenceAndLaunchArgumentMigrateToMicrosoft() {
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: "rich",
                arguments: ["Intatis"]),
            .microsoft)
        XCTAssertEqual(
            IntatisMessageRendererMode.resolve(
                persistedRawValue: IntatisMessageRendererMode.plainSafe.rawValue,
                arguments: ["Intatis", IntatisMessageRendererMode.legacyRichLaunchArgument]),
            .microsoft)
    }

    func testPlainSafeRenderPlanPreservesRawTextAndLineEndings() {
        let raw = "  **first**\r\n| a | b |\r`$code$`\n公式 $x_i$ 与 \\$29.99  "
        let plan = IntatisMessageRenderPlan.resolve(
            rawText: raw,
            isComplete: true,
            policyIsRich: true,
            rendererMode: .plainSafe)

        XCTAssertEqual(plan.displayText, raw)
        XCTAssertEqual(Data(plan.displayText.utf8), Data(raw.utf8))
        XCTAssertFalse(plan.usesRichRenderer)
    }

    func testEmptyStreamingRenderPlanUsesPlaceholderWithoutRichWork() {
        let plan = IntatisMessageRenderPlan.resolve(
            rawText: "",
            isComplete: false,
            policyIsRich: true,
            rendererMode: .plainSafe)

        XCTAssertEqual(plan.displayText, "…")
        XCTAssertFalse(plan.usesRichRenderer)
    }

    func testCompletedEmptyMessageRemainsByteExactEmptyText() {
        let plan = IntatisMessageRenderPlan.resolve(
            rawText: "",
            isComplete: true,
            policyIsRich: true,
            rendererMode: .plainSafe)

        XCTAssertEqual(plan.displayText, "")
        XCTAssertFalse(plan.usesRichRenderer)
    }

    func testRichModeRoutesEligibleMessagesToRichRenderer() {
        let plan = IntatisMessageRenderPlan.resolve(
            rawText: "**assistant source**",
            isComplete: true,
            policyIsRich: true,
            rendererMode: .microsoft)

        XCTAssertEqual(plan.displayText, "**assistant source**")
        XCTAssertTrue(plan.usesRichRenderer)
        XCTAssertTrue(plan.acceptsRichDocument(rawText: "**assistant source**"))
        XCTAssertFalse(plan.acceptsRichDocument(rawText: "**older snapshot**"))
    }

    func testRolePolicyCanAlwaysForcePlainRendering() {
        let plan = IntatisMessageRenderPlan.resolve(
            rawText: "**user source**",
            isComplete: true,
            policyIsRich: false,
            rendererMode: .microsoft)

        XCTAssertEqual(plan.displayText, "**user source**")
        XCTAssertFalse(plan.usesRichRenderer)
    }
}
