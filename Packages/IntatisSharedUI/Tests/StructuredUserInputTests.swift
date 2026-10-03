#if os(macOS)
import Foundation
import XCTest
@testable import IntatisSharedUI

final class StructuredUserInputTests: XCTestCase {
    func testDraftRequiresOneAnswerForEveryQuestion() {
        let presentation = fixturePresentation()
        var draft = IntatisUserInputDraft()

        draft.setSelection(.option("Compact"), for: "density")
        XCTAssertNil(draft.submission(for: presentation))

        draft.setSelection(.other, for: "delivery")
        draft.setOtherAnswer("  Inline above the composer  ", for: "delivery")

        XCTAssertEqual(
            draft.submission(for: presentation),
            IntatisUserInputSubmission(
                requestID: "request-1",
                answers: [
                    "density": ["Compact"],
                    "delivery": ["Inline above the composer"],
                ]))
    }

    func testDraftRejectsUnknownOptionAndEmptyOtherAnswer() {
        let presentation = fixturePresentation()
        var draft = IntatisUserInputDraft()

        draft.setSelection(.option("Unknown"), for: "density")
        draft.setSelection(.option("Panel"), for: "delivery")
        XCTAssertNil(draft.submission(for: presentation))

        draft.setSelection(.option("Compact"), for: "density")
        draft.setSelection(.other, for: "delivery")
        draft.setOtherAnswer("  \n", for: "delivery")
        XCTAssertNil(draft.submission(for: presentation))
    }

    func testViewUsesNativeNumberedListWithoutRadioControlsOrMaterial()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StructuredUserInput.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("List(selection:"))
        XCTAssertTrue(source.contains(".listStyle(.plain)"))
        XCTAssertTrue(source.contains("Text(description)"))
        XCTAssertTrue(source.contains(".font(.caption2)"))
        XCTAssertFalse(source.contains("info.circle"))
        XCTAssertTrue(source.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(source.contains(
            ".keyboardShortcut(.return, modifiers: .command)"))
        XCTAssertFalse(source.contains("Picker("))
        XCTAssertFalse(source.contains(".radioGroup"))
        XCTAssertFalse(source.contains(".intatisSubtleContentSurface"))
        XCTAssertFalse(source.contains(".regularMaterial"))
        XCTAssertFalse(source.contains("需要你的选择"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains(
            "needs your choice"))
    }

    private func fixturePresentation() -> IntatisUserInputPresentation {
        IntatisUserInputPresentation(
            id: "request-1",
            requesterName: "Research",
            questions: [
                IntatisUserInputQuestionPresentation(
                    id: "density",
                    question: "How compact should it be?",
                    options: [
                        IntatisUserInputOptionPresentation(
                            label: "Compact",
                            description: "Uses the least vertical space."),
                        IntatisUserInputOptionPresentation(
                            label: "Comfortable",
                            description: "Adds more breathing room."),
                    ],
                    allowsOther: true),
                IntatisUserInputQuestionPresentation(
                    id: "delivery",
                    question: "Where should it appear?",
                    options: [
                        IntatisUserInputOptionPresentation(
                            label: "Panel",
                            description: "Appears above the composer."),
                        IntatisUserInputOptionPresentation(
                            label: "Sheet",
                            description: "Appears in a modal sheet."),
                    ],
                    allowsOther: true),
            ])
    }
}
#endif
