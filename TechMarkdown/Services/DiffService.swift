import Foundation

enum DiffOperation: Equatable {
    case equal(oldRange: Range<Int>, newRange: Range<Int>)
    case delete(oldRange: Range<Int>)
    case insert(at: Int, newRange: Range<Int>)
    case replace(oldRange: Range<Int>, newRange: Range<Int>)
}

/// 行级文本差异服务，用于将 AI 修改建议拆分为可独立应用/弃用的 hunk。
enum DiffService {
    static func computeHunks(original: String, suggested: String) -> [EditHunk] {
        let oldLines = original.isEmpty ? [] : original.components(separatedBy: .newlines)
        let newLines = suggested.isEmpty ? [] : suggested.components(separatedBy: .newlines)

        if oldLines.isEmpty && newLines.isEmpty { return [] }
        if oldLines.isEmpty {
            return [EditHunk(oldStart: 1, oldLines: [], newLines: newLines)]
        }
        if newLines.isEmpty {
            return [EditHunk(oldStart: 1, oldLines: oldLines, newLines: [])]
        }

        let operations = myersDiff(old: oldLines, new: newLines)
        return operations.compactMap { op -> EditHunk? in
            switch op {
            case .equal:
                return nil
            case .delete(let oldRange):
                return EditHunk(
                    oldStart: oldRange.lowerBound + 1,
                    oldLines: Array(oldLines[oldRange]),
                    newLines: []
                )
            case .insert(let at, let newRange):
                return EditHunk(
                    oldStart: at + 1,
                    oldLines: [],
                    newLines: Array(newLines[newRange])
                )
            case .replace(let oldRange, let newRange):
                return EditHunk(
                    oldStart: oldRange.lowerBound + 1,
                    oldLines: Array(oldLines[oldRange]),
                    newLines: Array(newLines[newRange])
                )
            }
        }
    }

    /// 将选中的 hunk 应用到原文本上。未选中的 hunk 保持原样。
    static func applySelectedHunks(original: String, hunks: [EditHunk], selectedIDs: Set<UUID>) -> String {
        var lines = original.isEmpty ? [] : original.components(separatedBy: .newlines)
        let selected = hunks.filter { selectedIDs.contains($0.id) }.sorted { $0.oldStart > $1.oldStart }
        for hunk in selected {
            let start = hunk.oldStart - 1
            let end = start + hunk.oldLines.count
            guard start >= 0, start <= lines.count else { continue }
            lines.replaceSubrange(start..<min(end, lines.count), with: hunk.newLines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Myers 差分算法

    private struct Snake: Equatable {
        let x1, y1, x2, y2: Int
    }

    private static func myersDiff<T: Equatable>(old: [T], new: [T]) -> [DiffOperation] {
        let n = old.count
        let m = new.count

        // 边界情况
        if n == 0 && m == 0 { return [] }
        if n == 0 { return [.insert(at: 0, newRange: 0..<m)] }
        if m == 0 { return [.delete(oldRange: 0..<n)] }

        let maxD = (n + m + 1) / 2 + 1
        var v: [Int: Int] = [1: 0]
        var trace: [[Int: Int]] = []

        var finalD: Int? = nil

        for d in 0..<maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d {
                    x = v[k + 1] ?? 0
                } else if k == d {
                    x = (v[k - 1] ?? 0) + 1
                } else {
                    let left = v[k - 1] ?? -1
                    let right = v[k + 1] ?? -1
                    x = left < right ? right : left + 1
                }
                var y = x - k
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }
                v[k] = x
                if x >= n && y >= m {
                    finalD = d
                    break
                }
            }
            if finalD != nil { break }
        }

        guard let dEnd = finalD, dEnd > 0 else {
            // 完全相同
            if n > 0 {
                return [.equal(oldRange: 0..<n, newRange: 0..<m)]
            }
            return []
        }

        var snakes: [Snake] = []
        var x = n
        var y = m
        for d in stride(from: dEnd, through: 1, by: -1) {
            let currentV = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d {
                prevK = k + 1
            } else if k == d {
                prevK = k - 1
            } else {
                let left = currentV[k - 1] ?? -1
                let right = currentV[k + 1] ?? -1
                prevK = left < right ? k + 1 : k - 1
            }
            let prevX = currentV[prevK] ?? 0
            let prevY = prevX - prevK
            let snakeStartX = prevK < k ? prevX + 1 : prevX
            let snakeStartY = prevK < k ? prevY : prevY + 1
            snakes.append(Snake(x1: snakeStartX, y1: snakeStartY, x2: x, y2: y))
            x = prevX
            y = prevY
        }
        // 收尾：d=0 的蛇形对角线（最长公共前缀）
        snakes.append(Snake(x1: 0, y1: 0, x2: x, y2: y))
        snakes.reverse()

        return operations(from: snakes, n: n, m: m)
    }

    private static func operations(from snakes: [Snake], n: Int, m: Int) -> [DiffOperation] {
        var ops: [DiffOperation] = []
        var x = 0
        var y = 0

        for snake in snakes {
            let oldAdvance = snake.x1 - x
            let newAdvance = snake.y1 - y
            if oldAdvance > 0 || newAdvance > 0 {
                if oldAdvance > 0 && newAdvance > 0 {
                    ops.append(.replace(oldRange: x..<snake.x1, newRange: y..<snake.y1))
                } else if oldAdvance > 0 {
                    ops.append(.delete(oldRange: x..<snake.x1))
                } else {
                    ops.append(.insert(at: x, newRange: y..<snake.y1))
                }
            }

            if snake.x2 > snake.x1 {
                ops.append(.equal(oldRange: snake.x1..<snake.x2, newRange: snake.y1..<snake.y2))
            }

            x = snake.x2
            y = snake.y2
        }

        // 将相邻的 delete + insert 合并为 replace
        var merged: [DiffOperation] = []
        var i = 0
        while i < ops.count {
            let op = ops[i]
            if case .delete(let oldRange) = op,
               i + 1 < ops.count,
               case .insert(let at, let newRange) = ops[i + 1],
               at == oldRange.upperBound {
                merged.append(.replace(oldRange: oldRange, newRange: newRange))
                i += 2
            } else {
                merged.append(op)
                i += 1
            }
        }

        return merged
    }
}
