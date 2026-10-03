import Foundation
import XCTest
@testable import IntatisCodexRuntime

final class CodexRuntimeSkillTests: XCTestCase {
    func testCoworkSkillIsInstalledAsOwnerOnlyCodexSkill() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)

        try storage.prepare()
        try storage.installCoworkSkill()

        let skill = storage.skillsURL
            .appendingPathComponent("cowork-agent-orchestration")
            .appendingPathComponent("SKILL.md")
        let reference = skill.deletingLastPathComponent()
            .appendingPathComponent("references", isDirectory: true)
            .appendingPathComponent("model-routing.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertTrue(text.contains("Codex native V2 subagents"))
        XCTAssertTrue(text.contains("host-approved agent_type"))
        XCTAssertTrue(text.contains("workspace presets"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.path))
        for url in [skill, reference] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path)
            XCTAssertEqual(
                (attributes[.posixPermissions] as? NSNumber)?.intValue,
                0o600)
        }
    }
}
