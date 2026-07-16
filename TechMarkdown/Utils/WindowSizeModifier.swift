import SwiftUI
import AppKit

/// 统一配置应用窗口尺寸：初始启动时设置默认大小，并限制最小窗口。
struct WindowSizeModifier: ViewModifier {
    let defaultSize: NSSize
    let minSize: NSSize

    func body(content: Content) -> some View {
        content
            .onAppear {
                DispatchQueue.main.async {
                    configureWindows()
                }
            }
    }

    private func configureWindows() {
        for window in NSApplication.shared.windows {
            // 不调整弹窗、面板等辅助窗口的尺寸
            if window.isSheet || window.styleMask.contains(.utilityWindow) {
                continue
            }
            window.minSize = minSize

            let isTooSmall = window.frame.width < minSize.width || window.frame.height < minSize.height
            guard isTooSmall else { continue }

            let targetFrame = NSRect(origin: .zero, size: defaultSize)
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? targetFrame
            let centered = NSRect(
                x: screenFrame.midX - targetFrame.width / 2,
                y: screenFrame.midY - targetFrame.height / 2,
                width: targetFrame.width,
                height: targetFrame.height
            )
            window.setFrame(centered, display: true, animate: false)
        }
    }
}

extension View {
    func appWindowSize(
        defaultWidth: CGFloat = 1440,
        defaultHeight: CGFloat = 880,
        minWidth: CGFloat = 1100,
        minHeight: CGFloat = 700
    ) -> some View {
        modifier(WindowSizeModifier(
            defaultSize: NSSize(width: defaultWidth, height: defaultHeight),
            minSize: NSSize(width: minWidth, height: minHeight)
        ))
    }
}
