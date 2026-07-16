import Foundation

/// 用户画像记忆模型
/// 保存从用户协作过程中推断出的写作风格、行为规范、习惯、研究类型与工作模式。
struct UserProfileMemory: Codable {
    /// 写作风格：语言、语气、格式偏好（如“使用中文，简洁，代码块用 Swift”）
    var writingStyle: String
    /// 行为规范：希望 AI 如何回应（如“先给出结论再展开”“不要过度道歉”）
    var behaviorNorms: String
    /// 推断出的习惯标签（如“偏好总结”“喜欢分点列出”）
    var inferredHabits: [String]
    /// 常处理的研究/项目类型（如“技术文档”“学术论文”“产品需求”）
    var researchTypes: [String]
    /// 工作习惯：时段、流程、协作方式等
    var workHabits: String
    /// 自定义备注，AI 或用户均可补充
    var customNotes: String
    /// 最后更新时间
    var updatedAt: Date

    static var `default`: UserProfileMemory {
        UserProfileMemory(
            writingStyle: "",
            behaviorNorms: "",
            inferredHabits: [],
            researchTypes: [],
            workHabits: "",
            customNotes: "",
            updatedAt: Date.distantPast
        )
    }
}

extension UserProfileMemory {
    /// 生成适合注入 system prompt 的文本段落
    var promptSection: String {
        var parts: [String] = []
        if !writingStyle.isEmpty {
            parts.append("写作风格：\(writingStyle)")
        }
        if !behaviorNorms.isEmpty {
            parts.append("行为规范：\(behaviorNorms)")
        }
        if !inferredHabits.isEmpty {
            parts.append("推断习惯：\(inferredHabits.joined(separator: "；"))")
        }
        if !researchTypes.isEmpty {
            parts.append("常处理类型：\(researchTypes.joined(separator: "、"))")
        }
        if !workHabits.isEmpty {
            parts.append("工作习惯：\(workHabits)")
        }
        if !customNotes.isEmpty {
            parts.append("备注：\(customNotes)")
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n")
    }
}
