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

/// 统一的设计系统 Token。
/// 暗色使用低眩光蓝黑，浅色使用高对比度蓝灰；两套主题分别配色，
/// 避免把适合暗色背景的低饱和绿色直接复用到白色背景。
@Observable
final class ThemeManager {
    var theme: TechTheme = .dark
    var editorFontSize: CGFloat = 14
    var previewZoom: CGFloat = 1.0

    // MARK: - Backgrounds
    var backgroundPrimary: Color { theme == .dark ? Color(hex: "#0F172A") : Color(hex: "#F7F9FC") }
    var backgroundSecondary: Color { theme == .dark ? Color(hex: "#1E293B") : Color(hex: "#FFFFFF") }
    var backgroundTertiary: Color { theme == .dark ? Color(hex: "#334155") : Color(hex: "#EDF2F7") }
    var backgroundCode: Color { theme == .dark ? Color(hex: "#0B1221") : Color(hex: "#E9EFF6") }

    // MARK: - Text
    var textPrimary: Color { theme == .dark ? Color(hex: "#F8FAFC") : Color(hex: "#172033") }
    var textSecondary: Color { theme == .dark ? Color(hex: "#CBD5E1") : Color(hex: "#3C4A60") }
    var textMuted: Color { theme == .dark ? Color(hex: "#94A3B8") : Color(hex: "#5D6B80") }

    // MARK: - Accents
    var accent: Color { theme == .dark ? Color(hex: "#7DA481") : Color(hex: "#2563A6") }
    var accentSecondary: Color { theme == .dark ? Color(hex: "#5B88C3") : Color(hex: "#287783") }
    var accentHover: Color { theme == .dark ? Color(hex: "#77C8D1") : Color(hex: "#1D4F86") }

    // MARK: - Interactive Controls
    /// 选中控件使用低饱和表面色，不再直接铺满主强调色。
    var controlSelectedBackground: Color { theme == .dark ? Color(hex: "#263A55") : Color(hex: "#E7F0FA") }
    var controlSelectedForeground: Color { theme == .dark ? Color(hex: "#DCEBFA") : Color(hex: "#174F82") }
    var controlSelectedBorder: Color { theme == .dark ? Color(hex: "#41658D") : Color(hex: "#A9C5E2") }

    // MARK: - Tables
    var tableHeaderBackground: Color { theme == .dark ? Color(hex: "#243349") : Color(hex: "#E8F0F8") }
    var tableHeaderForeground: Color { theme == .dark ? Color(hex: "#E7EEF7") : Color(hex: "#245B8F") }
    var tableRowBackground: Color { theme == .dark ? Color(hex: "#131E2F") : Color(hex: "#FFFFFF") }
    var tableAlternateRowBackground: Color { theme == .dark ? Color(hex: "#172438") : Color(hex: "#F7F9FC") }
    var tableGrid: Color { theme == .dark ? Color(hex: "#3A4B63") : Color(hex: "#CBD7E4") }

    // MARK: - Borders / Dividers
    var border: Color { theme == .dark ? Color(hex: "#334155").opacity(0.6) : Color(hex: "#D4DCE7") }

    // MARK: - Semantic
    var success: Color { theme == .dark ? Color(hex: "#7DA481") : Color(hex: "#237A4B") }
    var error: Color { theme == .dark ? Color(hex: "#E09191") : Color(hex: "#B42318") }
    var warning: Color { theme == .dark ? Color(hex: "#ED5C06") : Color(hex: "#A94B08") }

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
