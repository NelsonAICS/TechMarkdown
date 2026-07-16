import SwiftUI

enum TechTheme: String, CaseIterable, Identifiable {
    case dark = "dark"
    case light = "light"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return "科技暗色"
        case .light: return "极简亮色"
        }
    }

    var icon: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }
}

/// 统一的设计系统 Token
/// 基于 ui-ux-pro-max 生成的科技简约暗色主题：
/// 背景 #0F172A，文字 #F8FAFC，主色琥珀 #F59E0B，辅色紫罗兰 #8B5CF6
@Observable
final class ThemeManager {
    var theme: TechTheme = .dark
    var editorFontSize: CGFloat = 14
    var previewZoom: CGFloat = 1.0

    // MARK: - Backgrounds
    var backgroundPrimary: Color { theme == .dark ? Color(hex: "#0F172A") : Color(hex: "#FFFFFF") }
    var backgroundSecondary: Color { theme == .dark ? Color(hex: "#1E293B") : Color(hex: "#F8FAFC") }
    var backgroundTertiary: Color { theme == .dark ? Color(hex: "#334155") : Color(hex: "#F1F5F9") }
    var backgroundCode: Color { theme == .dark ? Color(hex: "#0B1221") : Color(hex: "#F1F5F9") }

    // MARK: - Text
    var textPrimary: Color { theme == .dark ? Color(hex: "#F8FAFC") : Color(hex: "#0F172A") }
    var textSecondary: Color { theme == .dark ? Color(hex: "#CBD5E1") : Color(hex: "#334155") }
    var textMuted: Color { theme == .dark ? Color(hex: "#94A3B8") : Color(hex: "#64748B") }

    // MARK: - Accents
    var accent: Color { Color(hex: "#7DA481") }
    var accentSecondary: Color { Color(hex: "#5B88C3") }
    var accentHover: Color { Color(hex: "#77C8D1") }

    // MARK: - Borders / Dividers
    var border: Color { theme == .dark ? Color(hex: "#334155").opacity(0.6) : Color(hex: "#E2E8F0") }

    // MARK: - Semantic
    var success: Color { Color(hex: "#7DA481") }
    var error: Color { Color(hex: "#E09191") }
    var warning: Color { Color(hex: "#ED5C06") }

    // MARK: - Annotation
    /// Nature 配图风格批注高亮色：柔和暖金
    var annotationHighlight: Color { Color(hex: "#DFCB91") }
    /// 批注激活/悬停强调色：柔和珊瑚
    var annotationActive: Color { Color(hex: "#E09191") }

    func toggleTheme() {
        theme = (theme == .dark) ? .light : .dark
    }

    func applyZoom(_ delta: CGFloat) {
        previewZoom = max(0.5, min(3.0, previewZoom + delta))
    }

    func resetZoom() {
        previewZoom = 1.0
    }
}
