import XCTest
@testable import AgentHub

final class SkillModelsTests: XCTestCase {
    private func skill(_ name: String, _ summary: String = "", triggers: [String] = []) -> Skill {
        Skill(name: name, summary: summary, instructions: "", triggers: triggers)
    }

    func testDesignSkillsGetDesignModelsFirst() {
        let names = SkillModels.suggestions(for: [skill("UI UX Designer", "Design from zero or improve an existing design")])
            .map(\.name)
        XCTAssertEqual(Array(names.prefix(2)), ["Frontend Design Expert 8B", "Qwen3.5 9B"])
        XCTAssertTrue(names.contains("STARK-WEB 12B"))
    }

    func testCodingSkillsGetDeepSeek() {
        let names = SkillModels.suggestions(for: [skill("Code Review", "Review a diff", triggers: ["refactor"])]).map(\.name)
        XCTAssertTrue(names.contains("DeepSeek V4 Flash"))
        XCTAssertFalse(names.contains("FLUX.2 klein 4B"))
    }

    func testImageSkillsGetFlux() {
        let names = SkillModels.suggestions(for: [skill("Brand Designer", "Logo and visual style")]).map(\.name)
        XCTAssertTrue(names.contains("FLUX.2 klein 4B"))
    }

    func testUnrelatedSkillsGetNothing() {
        XCTAssertTrue(SkillModels.suggestions(for: [skill("Release Notes", "Write the changelog")]).isEmpty)
        XCTAssertTrue(SkillModels.suggestions(for: []).isEmpty)
    }

    func testWholeWordsOnly() {
        // "build" contains "ui", and "guide" contains "ui": neither is a design skill.
        XCTAssertFalse(SkillModels.uses(for: skill("Build guide")).contains(.design))
    }

    func testSourcesPointAtRealEntries() {
        let cloudIDs = Set(AIModel.cloudCatalog.map(\.id))
        for model in SkillModels.all {
            switch model.source {
            case .ollama(let ref):
                XCTAssertTrue(ref.hasPrefix("hf.co/") && ref.hasSuffix(":Q4_K_M"), ref)
                XCTAssertGreaterThan(model.sizeBytes, 0, ref)
            case .cloud(let id):
                XCTAssertTrue(cloudIDs.contains(id), "\(id) is in the cloud catalog")
            case .hub:
                XCTAssertEqual(model.sizeBytes, 0)
            }
        }
    }
}
