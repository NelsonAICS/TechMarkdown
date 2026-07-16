import Foundation

/// 用户历史编辑文件的索引条目
struct FileIndexEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// 文件绝对路径
    var path: String
    /// 所属项目/目录路径
    var projectPath: String?
    /// 文件标题（取首行或文件名）
    var title: String
    /// 内容摘要
    var summary: String
    /// 自动提取的标签（标题、关键词等）
    var tags: [String]
    /// 字数
    var wordCount: Int
    /// 文件最后修改时间
    var lastModified: Date
    /// 最后在本应用打开/保存时间
    var lastOpenedAt: Date
}
