import SwiftUI
import UIKit

// MARK: - 来源徽标（F46 / R6 / §B.11.1）

/// 徽标样式：`compact` 只显示短文字 + 图标，`full` 显示完整来源文字。
public enum BadgeStyle: String, Codable, Sendable, CaseIterable {
    case compact
    case full

    public var localizedDescription: String {
        switch self {
        case .compact: return "紧凑"
        case .full: return "完整"
        }
    }
}

/// **合规常驻标记**：文字 + SF Symbol 图标 + `.accessibilityLabel` 三通道，
/// 不依赖颜色区分；置于玻璃 / 材质层之上（`zIndex` 更高），高对比、不被模糊遮挡；
/// 错误态 / 空态 / 加载态下都不得消失。
///
/// `RootView` 使用 `OriginBadge(.simulated, style: .full)`；其余页面可用默认 `.full`。
public struct OriginBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let origin: DataOrigin
    private let style: BadgeStyle

    public init(_ origin: DataOrigin, style: BadgeStyle = .full) {
        self.origin = origin
        self.style = style
    }

    /// 文字通道：完整文案或短文案，任何动态类型下都不截断。
    private var visibleText: String {
        switch style {
        case .full: return origin.displayText
        case .compact:
            return origin == .simulated ? "SIMULATED" : "真实"
        }
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: origin.symbolName)
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(visibleText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // 不透明底层：确保置于玻璃/材质之上时不被模糊弱化。
        .background(Capsule().fill(backgroundColor))
        .overlay {
            Capsule().strokeBorder(borderColor, lineWidth: differentiateWithoutColor ? 2 : 1)
        }
        .foregroundStyle(foregroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(origin.accessibilityLabel))
        .accessibilityHint(Text(origin == .simulated
            ? "此页数据为 App 内生成的测试数据，不代表真实运动"
            : "此页数据来自设备传感器，与测试数据物理隔离"))
        // z-order 高于玻璃 / 材质层，错误态同样置顶。
        .zIndex(100)
    }

    private var backgroundColor: Color {
        switch origin {
        case .simulated:
            return colorScheme == .dark
                ? Color.purple.opacity(0.92)
                : Color.purple.opacity(0.16)
        case .real:
            return colorScheme == .dark
                ? Color.green.opacity(0.90)
                : Color.green.opacity(0.16)
        }
    }

    private var foregroundColor: Color {
        switch origin {
        case .simulated:
            return colorScheme == .dark ? .white : Color.purple.shade(0.7)
        case .real:
            return colorScheme == .dark ? .white : Color.green.shade(0.7)
        }
    }

    private var borderColor: Color {
        switch origin {
        case .simulated: return Color.purple
        case .real: return Color.green
        }
    }
}

// MARK: - 颜色深浅适配辅助（仅本文件使用）

private extension Color {
    /// 通过 `UIColor` 的混合得到较深的同色系文字色，保证浅色模式下的高对比度。
    func shade(_ ratio: CGFloat) -> Color {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .primary
        }
        return Color(
            red: Double(red * ratio),
            green: Double(green * ratio),
            blue: Double(blue * ratio),
            opacity: Double(alpha)
        )
    }
}
