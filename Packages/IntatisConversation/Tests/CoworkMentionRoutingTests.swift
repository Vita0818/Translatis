import XCTest
import IntatisCore
@testable import IntatisConversation

final class CoworkMentionRoutingTests: XCTestCase {
    private let alpha = AgentID(rawValue: "Alpha")
    private let beta = AgentID(rawValue: "Beta")

    func testKnownMentionRoutesToAgent() {
        let route = CoworkMentionRouter.route(input: "@Beta inspect the file", attachedAgents: [alpha, beta])

        XCTAssertEqual(route.originalInput, "@Beta inspect the file")
        XCTAssertEqual(route.outcome, .send(text: "inspect the file", target: beta))
    }

    func testUnknownMentionReturnsErrorAndKeepsOriginalInput() {
        let route = CoworkMentionRouter.route(input: "@Ghost inspect the file", attachedAgents: [alpha, beta])

        XCTAssertEqual(route.originalInput, "@Ghost inspect the file")
        XCTAssertEqual(route.outcome, .blocked(.unknownMention("Ghost")))
    }

    func testAmbiguousMentionDoesNotChooseSilently() {
        let route = CoworkMentionRouter.route(
            input: "@alpha inspect the file",
            attachedAgents: [AgentID(rawValue: "Alpha"), AgentID(rawValue: "ALPHA")])

        XCTAssertEqual(route.outcome, .blocked(.ambiguousMention(
            "alpha",
            [AgentID(rawValue: "Alpha"), AgentID(rawValue: "ALPHA")])))
    }

    func testNoMentionRoutesOnlyWhenDefaultIsUnambiguous() {
        let single = CoworkMentionRouter.route(input: "inspect the file", attachedAgents: [alpha])
        let multiple = CoworkMentionRouter.route(input: "inspect the file", attachedAgents: [alpha, beta])

        XCTAssertEqual(single.outcome, .send(text: "inspect the file", target: alpha))
        XCTAssertEqual(multiple.outcome, .blocked(.ambiguousDefault([alpha, beta])))
    }

    func testEmptyMentionOrMessageIsBlocked() {
        XCTAssertEqual(
            CoworkMentionRouter.route(input: "@", attachedAgents: [alpha]).outcome,
            .blocked(.emptyMention))
        XCTAssertEqual(
            CoworkMentionRouter.route(input: "@Alpha", attachedAgents: [alpha]).outcome,
            .blocked(.emptyMessage))
        XCTAssertEqual(
            CoworkMentionRouter.route(input: "   ", attachedAgents: [alpha]).outcome,
            .blocked(.emptyMessage))
    }

    func testSubmittedIntentFreezesUnknownButSyntacticallyValidTarget() {
        let route = CoworkMentionRouter.routeSubmittedIntent(
            input: "  @Future_worker-2   inspect the file  ",
            defaultTarget: alpha)

        XCTAssertEqual(route.originalInput, "  @Future_worker-2   inspect the file  ")
        XCTAssertEqual(
            route.outcome,
            .send(
                text: "inspect the file",
                target: AgentID(rawValue: "Future_worker-2")))
    }

    func testSubmittedIntentUsesFrozenDefaultWithoutConsultingRoster() {
        let route = CoworkMentionRouter.routeSubmittedIntent(
            input: "  inspect the file  ",
            defaultTarget: beta)

        XCTAssertEqual(route.outcome, .send(text: "inspect the file", target: beta))
    }

    func testSubmittedIntentRejectsInvalidMentionSyntax() {
        XCTAssertEqual(
            CoworkMentionRouter.routeSubmittedIntent(
                input: "@bad/name inspect",
                defaultTarget: alpha).outcome,
            .blocked(.invalidMention("bad/name")))
        XCTAssertEqual(
            CoworkMentionRouter.routeSubmittedIntent(
                input: "@未来 inspect",
                defaultTarget: alpha).outcome,
            .blocked(.invalidMention("未来")))
        XCTAssertEqual(
            CoworkMentionRouter.routeSubmittedIntent(
                input: "@-starts-with-dash inspect",
                defaultTarget: alpha).outcome,
            .blocked(.invalidMention("-starts-with-dash")))
    }
}
