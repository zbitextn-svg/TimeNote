import AppKit
import SwiftUI

// MARK: - 设计 Token

/// 全局视觉规范：浅暖纸色基调 + 琥珀色强调，深色模式自动适配。
enum Theme {
    // 背景层级
    static let canvas = Color(light: Color(hex: "#F8F6F2"), dark: Color(hex: "#1B1A18"))
    static let surface = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#252321"))
    static let surfaceMuted = Color(light: Color(hex: "#F1EDE6"), dark: Color(hex: "#2D2A27"))
    static let hover = Color(light: Color(hex: "#000000").opacity(0.035), dark: Color(hex: "#FFFFFF").opacity(0.045))
    static let hairline = Color(light: Color(hex: "#E7E1D8"), dark: Color(hex: "#38342F"))

    // 文字
    static let textPrimary = Color(light: Color(hex: "#24211D"), dark: Color(hex: "#EDE9E3"))
    static let textSecondary = Color(light: Color(hex: "#7A736A"), dark: Color(hex: "#9C958B"))
    static let textTertiary = Color(light: Color(hex: "#A69E93"), dark: Color(hex: "#6E685F"))

    // 强调色：琥珀
    static let accent = Color(light: Color(hex: "#C9711A"), dark: Color(hex: "#F0A24A"))
    static let accentSoft = Color(light: Color(hex: "#C9711A").opacity(0.12), dark: Color(hex: "#F0A24A").opacity(0.16))
    /// 实心主按钮底色：比强调色略深，保证白字对比度（≥4.5:1）
    static let exportFill = Color(light: Color(hex: "#A9560B"), dark: Color(hex: "#B05C0F"))
    static let success = Color(light: Color(hex: "#3B8A5A"), dark: Color(hex: "#6CC08C"))
    static let danger = Color(light: Color(hex: "#C2453A"), dark: Color(hex: "#F07A6E"))
    /// 录音：红色，与琥珀色区分
    static let recording = Color(light: Color(hex: "#D0392E"), dark: Color(hex: "#FF6F61"))
    /// 录音中按钮的实心底色（白字对比度 ≥4.5:1）
    static let recordingFill = Color(light: Color(hex: "#C0352B"), dark: Color(hex: "#C23A2F"))

    // 尺寸
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    enum Spacing {
        static let pageHorizontal: CGFloat = 24
        static let rowHorizontal: CGFloat = 12
    }

    static let timeFont = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let bodyFont = Font.system(size: 14)
}

// MARK: - Color 辅助

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64

        switch sanitized.count {
        case 6:
            (a, r, g, b) = (255, value >> 16, value >> 8 & 0xFF, value & 0xFF)
        case 8:
            (a, r, g, b) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - 通用小组件

/// 圆角卡片背景：表面色 + 细描边
struct CardBackground: View {
    var radius: CGFloat = Theme.Radius.medium
    var fill: Color = Theme.surface

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

/// 鼠标悬停时显示浅背景的按钮样式（用于图标按钮）
struct HoverIconButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        HoverIconButtonBody(configuration: configuration, tint: tint)
    }

    private struct HoverIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(isHovered || configuration.isPressed ? Theme.hover : Color.clear)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

/// 把文本中与关键词匹配的片段标为强调色
func highlightedText(_ text: String, terms: [String]) -> AttributedString {
    var attributed = AttributedString(text)
    for term in terms where term.isEmpty == false {
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].foregroundColor = Theme.accent
            attributed[range].font = .system(size: 13, weight: .semibold)
            searchStart = range.upperBound
        }
    }
    return attributed
}
