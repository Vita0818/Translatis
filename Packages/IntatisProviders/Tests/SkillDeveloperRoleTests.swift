import XCTest
import IntatisProtocol
@testable import IntatisProviders

final class SkillDeveloperRoleTests: XCTestCase {
    func testChatCompletionsPreservesDeveloperInstructionRole() {
        XCTAssertEqual(
            OpenAIWireProvider.messageJSON(
                .developer("bounded skill catalog")),
            .object([
                "role": .string("developer"),
                "content": .string("bounded skill catalog"),
            ]))
    }

    func testResponsesPreservesDeveloperInstructionRole() {
        let item = AgentInputItem.message(
            role: .developer,
            content: "bounded skill catalog",
            images: [])

        XCTAssertEqual(
            OpenAIWireProvider.responsesInputJSON(item),
            .object([
                "type": .string("message"),
                "role": .string("developer"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string("bounded skill catalog"),
                    ]),
                ]),
            ]))
    }
}
