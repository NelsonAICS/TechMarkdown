import XCTest
import SwiftUI
import AppKit
@testable import TechMarkdown

final class LaunchScreenRenderingTests: XCTestCase {
    @MainActor
    func testLaunchScreenRendersAtDefaultWindowSize() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set TECHMARKDOWN_SNAPSHOT_PATH to generate a launch-screen snapshot.")
        }

        let now = Date()
        let files = (0..<6).map { index in
            FileIndexEntry(
                id: UUID(),
                path: "/Users/demo/Documents/Research/note-\(index).md",
                projectPath: "/Users/demo/Documents/Research",
                title: ["项目阅读指南", "数据流与记忆系统", "实验结果整理", "论文参考规划", "模块映射说明", "发布检查清单"][index],
                summary: "这是一段用于验证启动页排版、层级和文字清晰度的文档摘要。",
                tags: ["示例"],
                wordCount: 420 + index * 137,
                lastModified: now.addingTimeInterval(Double(-index * 1800)),
                lastOpenedAt: now.addingTimeInterval(Double(-index * 1800))
            )
        }
        let projects = [
            Project(
                name: "TechMarkdown",
                url: URL(fileURLWithPath: "/Users/demo/TechMarkdown"),
                rootURL: URL(fileURLWithPath: "/Users/demo/TechMarkdown")
            ),
            Project(
                name: "论文资料",
                url: URL(fileURLWithPath: "/Users/demo/Research"),
                rootURL: URL(fileURLWithPath: "/Users/demo/Research")
            )
        ]

        let rootView = LaunchScreenView(
            recentFiles: files,
            recentProjects: projects,
            onOpenRecent: { _ in },
            onOpenRecentProject: { _ in },
            onNewMarkdown: {},
            onNewLaTeX: {},
            onNewHTML: {},
            onOpenFile: {},
            onOpenFolder: {},
            onClearRecent: {}
        )
        .environment(ThemeManager())
        .frame(width: 980, height: 720)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, 10_000)
    }

    @MainActor
    func testAnnotationWorkspaceRendersAtSidebarSize() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TECHMARKDOWN_ANNOTATION_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set TECHMARKDOWN_ANNOTATION_SNAPSHOT_PATH to generate an annotation snapshot.")
        }

        let path = "/tmp/techmarkdown-annotation-snapshot.md"
        AnnotationService.shared.annotations(for: path).forEach {
            AnnotationService.shared.deleteAnnotation(id: $0.id, for: path)
        }
        let text = """
        # 实验计划

        这一段需要补充数据来源和判断依据。

        结论部分需要与前文保持一致。
        """
        let first = AnnotationService.shared.addAnnotation(
            "请补充数据来源，并说明样本筛选标准。",
            selectedText: "补充数据来源和判断依据",
            context: "这一段需要补充数据来源和判断依据。",
            rangeSnapshot: AnnotationRangeSnapshot(
                startLine: 3,
                startColumn: 5,
                endLine: 3,
                endColumn: 16
            ),
            for: path
        )
        _ = AnnotationService.shared.addAnnotation(
            "全文检查术语一致性。",
            for: path
        )
        defer {
            AnnotationService.shared.annotations(for: path).forEach {
                AnnotationService.shared.deleteAnnotation(id: $0.id, for: path)
            }
        }

        let state = DocumentState()
        state.text = text
        state.currentFileURL = URL(fileURLWithPath: path)
        let theme = ThemeManager()
        let agent = AIAgent()
        let rootView = AISidebarView(
            agent: agent,
            documentText: .constant(text),
            themeManager: theme
        )
        .environment(theme)
        .environmentObject(state)
        .frame(width: 400, height: 720)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 720)
        hostingView.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .focusAnnotation, object: first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Unable to create bitmap representation.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Unable to encode snapshot as PNG.")
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(pngData.count, 10_000)
    }
}
