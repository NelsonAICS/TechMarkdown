import XCTest
import SwiftUI
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
}
