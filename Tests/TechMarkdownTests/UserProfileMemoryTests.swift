import XCTest
@testable import TechMarkdown

final class UserProfileMemoryTests: XCTestCase {

    func testDefaultProfileHasEmptyFields() {
        let profile = UserProfileMemory.default
        XCTAssertTrue(profile.writingStyle.isEmpty)
        XCTAssertTrue(profile.behaviorNorms.isEmpty)
        XCTAssertTrue(profile.inferredHabits.isEmpty)
        XCTAssertTrue(profile.researchTypes.isEmpty)
        XCTAssertTrue(profile.workHabits.isEmpty)
        XCTAssertTrue(profile.customNotes.isEmpty)
        XCTAssertEqual(profile.updatedAt, Date.distantPast)
    }

    func testPromptSectionIsEmptyForDefaultProfile() {
        let profile = UserProfileMemory.default
        XCTAssertTrue(profile.promptSection.isEmpty)
    }

    func testPromptSectionIncludesAllFilledFields() {
        var profile = UserProfileMemory.default
        profile.writingStyle = "使用中文"
        profile.behaviorNorms = "先给结论"
        profile.inferredHabits = ["喜欢总结"]
        profile.researchTypes = ["技术文档"]
        profile.workHabits = "习惯引用本地文件"
        profile.customNotes = "不要过度道歉"

        let section = profile.promptSection
        XCTAssertTrue(section.contains("写作风格"))
        XCTAssertTrue(section.contains("行为规范"))
        XCTAssertTrue(section.contains("推断习惯"))
        XCTAssertTrue(section.contains("常处理类型"))
        XCTAssertTrue(section.contains("工作习惯"))
        XCTAssertTrue(section.contains("备注"))
    }

    func testPromptSectionOmitsEmptyFields() {
        var profile = UserProfileMemory.default
        profile.writingStyle = "简洁"

        let section = profile.promptSection
        XCTAssertTrue(section.contains("写作风格"))
        XCTAssertFalse(section.contains("行为规范"))
    }
}
