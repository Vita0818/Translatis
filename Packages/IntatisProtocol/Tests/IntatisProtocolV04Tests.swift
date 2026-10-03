import XCTest
import IntatisCore
@testable import IntatisProtocol

final class IntatisProtocolV04Tests: XCTestCase {

    private let enc = Envelope.makeEncoder()
    private let dec = Envelope.makeDecoder()

    private func rt(_ env: Envelope, line: UInt = #line) throws {
        XCTAssertEqual(try dec.decode(Envelope.self, from: try enc.encode(env)), env, line: line)
    }

    func testArtifactEventsRoundTrip() throws {
        let s = SessionID(rawValue: "s")
        let id = ArtifactID(rawValue: "art_1")
        try rt(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1), session: s,
            event: .artifactAdded(.init(artifactId: id, kind: "image", mime: "image/png",
                                        path: "/tmp/x.png", producedBy: "image-model", prompt: "a cat"))))
        try rt(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 2), session: s,
            event: .artifactProgress(.init(artifactId: id, progress: 0.5, state: "running"))))
    }

    func testArtifactAddedWireType() throws {
        let env = Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1), session: SessionID(rawValue: "s"),
                           event: .artifactAdded(.init(artifactId: ArtifactID(rawValue: "a"),
                                                       kind: "video", mime: "video/mp4", path: "/p")))
        let json = try JSONSerialization.jsonObject(with: try enc.encode(env)) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "artifact_added")
    }
}
