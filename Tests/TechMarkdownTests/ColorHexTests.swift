import XCTest
import SwiftUI
import AppKit
@testable import TechMarkdown

final class ColorHexTests: XCTestCase {

    /// 颜色初始化不崩溃，且能正确解析不同长度的 hex。
    func testColorInitWithHexDoesNotCrash() {
        let colors: [Color] = [
            Color(hex: "#FF5733"),
            Color(hex: "FF5733"),
            Color(hex: "#F53"),
            Color(hex: "F53"),
            Color(hex: "#80FF5733"),
            Color(hex: "invalid"),
            Color(hex: "")
        ]
        XCTAssertEqual(colors.count, 7)
    }

    func testThemeManagerColorsAreNonClear() {
        let theme = ThemeManager()
        let colors: [Color] = [
            theme.backgroundPrimary,
            theme.backgroundSecondary,
            theme.textPrimary,
            theme.accent,
            theme.accentSecondary
        ]
        for color in colors {
            XCTAssertNotNil(color)
        }
    }

    func testLightThemeTextAndAccentMeetReadableContrast() throws {
        let theme = ThemeManager()
        theme.theme = .light
        let background = try XCTUnwrap(NSColor(theme.backgroundSecondary).usingColorSpace(.sRGB))

        for color in [theme.textPrimary, theme.textSecondary, theme.textMuted, theme.accent] {
            let foreground = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            XCTAssertGreaterThanOrEqual(contrastRatio(foreground, background), 4.5)
        }
    }

    func testSelectedControlsKeepReadableContrastInBothThemes() throws {
        let theme = ThemeManager()

        for techTheme in TechTheme.allCases {
            theme.theme = techTheme
            let foreground = try XCTUnwrap(NSColor(theme.controlSelectedForeground).usingColorSpace(.sRGB))
            let background = try XCTUnwrap(NSColor(theme.controlSelectedBackground).usingColorSpace(.sRGB))

            XCTAssertGreaterThanOrEqual(
                contrastRatio(foreground, background),
                4.5,
                "\(techTheme.displayName) 的选中控件文字对比度不足"
            )
        }
    }

    func testTableHeadersKeepReadableContrastInBothThemes() throws {
        let theme = ThemeManager()

        for techTheme in TechTheme.allCases {
            theme.theme = techTheme
            let foreground = try XCTUnwrap(NSColor(theme.tableHeaderForeground).usingColorSpace(.sRGB))
            let background = try XCTUnwrap(NSColor(theme.tableHeaderBackground).usingColorSpace(.sRGB))

            XCTAssertGreaterThanOrEqual(
                contrastRatio(foreground, background),
                4.5,
                "\(techTheme.displayName) 的表头文字对比度不足"
            )
        }
    }

    private func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
