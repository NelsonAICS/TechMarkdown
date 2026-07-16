import Foundation

enum DiffLineType {
    case unchanged
    case added
    case removed
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

func computeLineDiff(oldText: String, newText: String) -> [DiffLine] {
    let oldLines = diffLines(from: oldText)
    let newLines = diffLines(from: newText)
    
    // Simple LCS-based diff
    let m = oldLines.count
    let n = newLines.count
    
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    
    for i in (0..<m).reversed() {
        for j in (0..<n).reversed() {
            if oldLines[i] == newLines[j] {
                dp[i][j] = dp[i+1][j+1] + 1
            } else {
                dp[i][j] = max(dp[i+1][j], dp[i][j+1])
            }
        }
    }
    
    var result: [DiffLine] = []
    var i = 0, j = 0
    var oldNum = 1, newNum = 1
    
    while i < m || j < n {
        if i < m && j < n && oldLines[i] == newLines[j] {
            result.append(DiffLine(type: .unchanged, text: oldLines[i], oldLineNumber: oldNum, newLineNumber: newNum))
            i += 1; j += 1
            oldNum += 1; newNum += 1
        } else if j < n && (i >= m || dp[i][j+1] > dp[i+1][j]) {
            result.append(DiffLine(type: .added, text: newLines[j], oldLineNumber: nil, newLineNumber: newNum))
            j += 1
            newNum += 1
        } else if i < m {
            result.append(DiffLine(type: .removed, text: oldLines[i], oldLineNumber: oldNum, newLineNumber: nil))
            i += 1
            oldNum += 1
        } else {
            break
        }
    }
    
    return result
}

private func diffLines(from text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
}
