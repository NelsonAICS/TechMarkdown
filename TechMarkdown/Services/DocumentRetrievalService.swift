import Foundation
import Combine
import UniformTypeIdentifiers
import PDFKit

/// 文档分片
struct DocumentChunk: Identifiable, Codable {
    var id = UUID()
    let path: String
    let content: String
    let startLine: Int
    let endLine: Int
}

/// 检索结果
struct RetrievalResult: Identifiable {
    let id = UUID()
    let path: String
    let score: Double
    let snippet: String
    let chunk: DocumentChunk?
}

enum DocumentRetrievalError: Error, LocalizedError {
    case unsupportedType(String)
    case extractionFailed(String)
    case invalidPath
    
    var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return "不支持的文件类型: \(ext)"
        case .extractionFailed(let msg):
            return "文档解析失败: \(msg)"
        case .invalidPath:
            return "无效路径"
        }
    }
}

/// 项目文档解析、分块与本地检索服务
///
/// 支持：
/// - 文本/Markdown/代码文件直接读取
/// - PDF 通过 pypdf 解析
/// - DOCX 通过 python-docx 解析
/// - 本地 TF-IDF 倒排索引 + 关键词混合检索
final class DocumentRetrievalService {
    static let shared = DocumentRetrievalService()
    
    private let queue = DispatchQueue(label: "com.techmarkdown.document-retrieval", qos: .userInitiated)
    private let indexLock = NSLock()
    
    /// path -> chunks
    private var chunkIndex: [String: [DocumentChunk]] = [:]
    /// term -> [path: tf-idf weight]
    private var invertedIndex: [String: [String: Double]] = [:]
    /// 文档向量（TF-IDF）
    private var documentVectors: [String: [String: Double]] = [:]
    /// 总文档数，用于 IDF
    private var totalDocumentCount: Int = 0
    /// 是否正在构建索引
    @Published private(set) var isIndexing: Bool = false
    
    private init() {}
    
    // MARK: - 文本提取
    
    /// 根据文件扩展名提取纯文本
    func extractText(from path: String, maxLength: Int = 100_000) async throws -> String {
        let url = URL(fileURLWithPath: path)
        
        return try await ProjectManager.shared.accessAsync(url) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DocumentRetrievalError.invalidPath
            }
            
            let ext = url.pathExtension.lowercased()
            let contentType = UTType(filenameExtension: ext)
            
            let raw: String
            switch ext {
            case "pdf":
                raw = try await extractPDFText(from: url)
            case "docx", "doc":
                raw = try await extractDOCXText(from: url)
            default:
                // 文本、Markdown、代码等直接读取
                if let type = contentType, type.conforms(to: .plainText) || type.conforms(to: .sourceCode) {
                    raw = try await ProjectManager.shared.readFile(at: path, maxLength: maxLength * 2)
                } else {
                    raw = try await ProjectManager.shared.readFile(at: path, maxLength: maxLength * 2)
                }
            }
            
            let cleaned = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return String(cleaned.prefix(maxLength))
        }
    }
    
    private func extractPDFText(from url: URL) async throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentRetrievalError.extractionFailed("无法解析 PDF")
        }
        var parts: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let text = page.string ?? ""
            parts.append("--- Page \(i + 1) ---\n\(text)")
        }
        return parts.joined(separator: "\n\n")
    }
    
    private func extractDOCXText(from url: URL) async throws -> String {
        let documentType: NSAttributedString.DocumentType
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "doc":
            documentType = .docFormat
        case "docx":
            documentType = .officeOpenXML
        default:
            documentType = .officeOpenXML
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType
        ]
        let attributed = try NSAttributedString(
            url: url,
            options: options,
            documentAttributes: nil
        )
        return attributed.string
    }
    
    // MARK: - 分块
    
    /// 将文本按行号分块，默认每块最多 1000 字符，重叠 100 字符
    func chunk(text: String, path: String, chunkSize: Int = 1000, overlap: Int = 100) -> [DocumentChunk] {
        let lines = text.components(separatedBy: .newlines)
        var chunks: [DocumentChunk] = []
        var currentLines: [String] = []
        var currentLength = 0
        var startLine = 1
        
        func flush(endLine: Int) {
            guard !currentLines.isEmpty else { return }
            let content = currentLines.joined(separator: "\n")
            chunks.append(DocumentChunk(
                path: path,
                content: content,
                startLine: startLine,
                endLine: endLine
            ))
        }
        
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if currentLength + line.count > chunkSize && !currentLines.isEmpty {
                flush(endLine: lineNumber - 1)
                // 保留重叠行
                var overlapLines: [String] = []
                var overlapLength = 0
                for previousLine in currentLines.reversed() {
                    if overlapLength + previousLine.count > overlap { break }
                    overlapLines.insert(previousLine, at: 0)
                    overlapLength += previousLine.count + 1
                }
                currentLines = overlapLines
                currentLength = overlapLength
                startLine = lineNumber - currentLines.count
            }
            currentLines.append(line)
            currentLength += line.count + 1
        }
        
        flush(endLine: lines.count)
        return chunks.isEmpty ? [DocumentChunk(path: path, content: text, startLine: 1, endLine: max(1, lines.count))] : chunks
    }
    
    // MARK: - 索引
    
    /// 索引指定项目的所有可读文件
    func indexProject(_ project: Project) async {
        await indexProjects([project])
    }
    
    /// 索引多个项目
    func indexProjects(_ projects: [Project]) async {
        await MainActor.run { isIndexing = true }
        defer { Task { @MainActor in isIndexing = false } }
        
        var indexedResults: [(String, [DocumentChunk])] = []
        
        await withTaskGroup(of: (String, [DocumentChunk]).self) { group in
            for project in projects {
                let files = ProjectManager.shared.listFiles(in: project, maxDepth: 2)
                    .filter { !$0.isDirectory && isIndexable($0) }
                for file in files {
                    group.addTask {
                        do {
                            let text = try await self.extractText(from: file.path, maxLength: 200_000)
                            let chunks = self.chunk(text: text, path: file.path)
                            return (file.path, chunks)
                        } catch {
                            return (file.path, [])
                        }
                    }
                }
            }
            
            for await result in group {
                indexedResults.append(result)
            }
        }
        
        let newChunkIndex: [String: [DocumentChunk]] = indexedResults.reduce(into: [:]) { dict, pair in
            if !pair.1.isEmpty { dict[pair.0] = pair.1 }
        }
        
        queue.async {
            self.indexLock.lock()
            defer { self.indexLock.unlock() }
            self.chunkIndex = newChunkIndex
            self.buildTFIDF()
        }
    }
    
    /// 重新构建所有已加载项目的索引
    func indexAllProjects() async {
        let projects = ProjectManager.shared.listProjects()
        await indexProjects(projects)
    }
    
    /// 如果索引为空，则在后台构建一次索引
    func ensureIndexed() async {
        guard !isIndexing, isIndexEmpty else { return }
        await indexAllProjects()
    }
    
    private var isIndexEmpty: Bool {
        indexLock.lock()
        defer { indexLock.unlock() }
        return chunkIndex.isEmpty
    }
    
    private func isIndexable(_ file: ProjectFile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        let indexableExtensions: Set<String> = [
            "md", "markdown", "txt", "swift", "py", "js", "ts", "jsx", "tsx",
            "json", "yaml", "yml", "xml", "html", "css", "scss", "sh", "bash",
            "zsh", "c", "cpp", "h", "hpp", "rs", "go", "java", "kt", "rb",
            "php", "sql", "csv", "log", "pdf", "docx", "doc"
        ]
        if indexableExtensions.contains(ext) { return true }
        if let type = file.contentType {
            return type.conforms(to: .plainText) || type.conforms(to: .sourceCode)
        }
        return false
    }
    
    private func buildTFIDF() {
        var documentFreq: [String: Int] = [:]
        var termFreqByDoc: [String: [String: Double]] = [:]
        
        for (path, chunks) in chunkIndex {
            var tf: [String: Double] = [:]
            for chunk in chunks {
                let terms = tokenize(chunk.content)
                for term in terms {
                    tf[term, default: 0] += 1
                }
            }
            // 归一化词频
            let maxFreq = tf.values.max() ?? 1
            for term in tf.keys {
                tf[term] = tf[term]! / maxFreq
            }
            termFreqByDoc[path] = tf
            
            for term in Set(tf.keys) {
                documentFreq[term, default: 0] += 1
            }
        }
        
        let totalDocs = max(termFreqByDoc.count, 1)
        var idf: [String: Double] = [:]
        var invIndex: [String: [String: Double]] = [:]
        var docVectors: [String: [String: Double]] = [:]
        
        for (term, df) in documentFreq {
            idf[term] = log(Double(totalDocs) / (Double(df) + 1)) + 1
        }
        
        for (path, tf) in termFreqByDoc {
            var vector: [String: Double] = [:]
            for (term, freq) in tf {
                let weight = freq * (idf[term] ?? 0)
                vector[term] = weight
                invIndex[term, default: [:]][path] = weight
            }
            docVectors[path] = vector
        }
        
        self.invertedIndex = invIndex
        self.documentVectors = docVectors
        self.totalDocumentCount = totalDocs
    }
    
    // MARK: - 检索
    
    /// 基于 TF-IDF 的混合检索。返回按相关度排序的结果。
    func search(query: String, topK: Int = 5) -> [RetrievalResult] {
        indexLock.lock()
        defer { indexLock.unlock() }
        
        let queryTerms = tokenize(query)
        if queryTerms.isEmpty { return [] }
        
        var scores: [String: Double] = [:]
        
        // 1. 关键词命中奖励
        for term in queryTerms {
            let matchingDocs = invertedIndex[term] ?? [:]
            for (path, weight) in matchingDocs {
                scores[path, default: 0] += weight * 0.5
            }
            // 模糊前缀匹配
            for (indexedTerm, docs) in invertedIndex where indexedTerm.hasPrefix(term) && indexedTerm != term {
                for (path, weight) in docs {
                    scores[path, default: 0] += weight * 0.25
                }
            }
        }
        
        // 2. 余弦相似度
        let queryVector = buildQueryVector(terms: queryTerms)
        for (path, docVector) in documentVectors {
            let similarity = cosineSimilarity(queryVector, docVector)
            scores[path, default: 0] += similarity
        }
        
        // 3. 生成结果摘要
        let sorted = scores.sorted { $0.value > $1.value }.prefix(topK)
        return sorted.map { path, score in
            let snippet = bestSnippet(for: path, queryTerms: queryTerms)
            return RetrievalResult(
                path: path,
                score: score,
                snippet: snippet,
                chunk: nil
            )
        }
    }
    
    private func buildQueryVector(terms: [String]) -> [String: Double] {
        var freq: [String: Double] = [:]
        for term in terms {
            freq[term, default: 0] += 1
        }
        let maxFreq = freq.values.max() ?? 1
        var vector: [String: Double] = [:]
        for (term, count) in freq {
            let tf = count / maxFreq
            let idfValue = log(Double(totalDocumentCount) / (Double(invertedIndex[term]?.count ?? 0) + 1)) + 1
            vector[term] = tf * idfValue
        }
        return vector
    }
    
    private func cosineSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        
        for (term, value) in a {
            dot += value * (b[term] ?? 0)
            normA += value * value
        }
        for value in b.values {
            normB += value * value
        }
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
    
    private func bestSnippet(for path: String, queryTerms: [String]) -> String {
        guard let chunks = chunkIndex[path] else { return "" }
        // 优先返回包含最多查询词的 chunk
        let best = chunks.max { a, b in
            let countA = queryTerms.filter { a.content.lowercased().contains($0) }.count
            let countB = queryTerms.filter { b.content.lowercased().contains($0) }.count
            return countA < countB
        }
        return String(best?.content.prefix(500) ?? "")
    }
    
    // MARK: - 分词
    
    private func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let pattern = "[^a-z0-9\\u4e00-\\u9fa5]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let nsRange = NSRange(lowered.startIndex..., in: lowered)
        let matches = regex.matches(in: lowered, options: [], range: nsRange)
        var terms: [String] = []
        var index = lowered.startIndex
        for match in matches {
            guard let range = Range(match.range, in: lowered) else { continue }
            if range.lowerBound > index {
                let term = String(lowered[index..<range.lowerBound])
                if term.count > 1 { terms.append(term) }
            }
            index = range.upperBound
        }
        if index < lowered.endIndex {
            let term = String(lowered[index..<lowered.endIndex])
            if term.count > 1 { terms.append(term) }
        }
        return terms
    }
}
