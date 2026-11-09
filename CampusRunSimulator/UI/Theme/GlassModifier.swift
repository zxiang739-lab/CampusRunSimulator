import SwiftUI

// MARK: - 玻璃系统重构说明（v0.1.4）

// 之前版本启用过 iOS 26 官方 Liquid Glass（GlassEffectContainer / .glassEffect / glassEffectID）。
// 真实设备上出现「进入 App 后整体卡死、无法点击、非常卡」的硬故障：重复的 glassEffectID（固定角色名）
// 让全 App 同名玻璃元素共用同一 ID，SwiftUI 在玻璃形变/合并阶段反复 reconcile 这些重名 ID，主线程空转。
//
// 由于本地 Linux 环境无法运行 Xcode 26 真机或模拟器验证官方 API 的实际行为，工程上以「稳定性第一」为准则，
// 现将玻璃系统重构为**全版本统一、纯系统材质**实现：`.regularMaterial` + 圆角 + 描边 + 阴影。
// 视觉仍是玻璃质感，且：
//   - 不掉帧（无 GlassEffectContainer 采样层叠加）；
//   - 不吞触摸（`.background` 永远位于内容之下，不参与命中测试）；
//   - 不依赖任何未经验证的实验性 API。
// 所有调用方 API（`glassCard(role:interactive:)`）保持不变，无一处调用点需要改动。

// MARK: - 玻璃角色（F45 / §1.6）

/// 玻璃材质使用角色。节制地用于悬浮控制条、回放控件、卡片容器、按钮组。
public enum GlassRole: String, Codable, Sendable, CaseIterable {
    case card
    case controlBar
    case buttonGroup
    case floating

    /// 统一圆角。
    public var cornerRadius: CGFloat {
        switch self {
        case .card: return 18
        case .controlBar: return 24
        case .buttonGroup: return 22
        case .floating: return 28
        }
    }

    /// 统一内边距与容器 spacing。
    public var spacing: CGFloat {
        switch self {
        case .card: return 12
        case .controlBar: return 10
        case .buttonGroup: return 8
        case .floating: return 14
        }
    }

    public var localizedDescription: String {
        switch self {
        case .card: return "数据卡片"
        case .controlBar: return "控制条"
        case .buttonGroup: return "按钮组"
        case .floating: return "悬浮面板"
        }
    }

    /// 无障碍提示。
    public var accessibilityHint: String {
        "\(localizedDescription)容器，包含可操作控件"
    }
}

// MARK: - 全 App 唯一入口

public extension View {
    /// **全 App 唯一玻璃入口**：所有页面只能通过 `glassCard` 使用玻璃质感，
    /// 不得直接调用底层材质 API。实现为全版本统一的系统材质（稳定、不掉帧、不吞触摸）。
    @ViewBuilder
    func glassCard(role: GlassRole, interactive: Bool) -> some View {
        MaterialGlassCard(role: role, interactive: interactive) {
            self
        }
    }
}

// MARK: - 系统材质玻璃卡片（全版本统一实现）

/// 用 `.regularMaterial` + 圆角 + 描边 + 阴影呈现玻璃质感。
/// 关键安全点：玻璃只作为 `.background`（位于内容之下，不参与命中测试），
/// 因此绝不会拦截按钮/列表的触摸事件。
private struct MaterialGlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let role: GlassRole
    let interactive: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        // 稳定 API（iOS 15+）：`.background(.regularMaterial, in:)` 把材质垫在内容之下（不参与命中测试），
        // 描边用 `.overlay` 沿圆角勾勒在内容之上。玻璃永远在底层，绝不拦截触摸。
        content()
            .padding(role.spacing)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .shadow(
                color: shadowColor,
                radius: interactive ? 8 : 6,
                x: 0,
                y: interactive ? 4 : 2
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text(role.accessibilityHint))
    }

    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.10)
    }

    private var shadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.55)
            : Color.black.opacity(0.14)
    }
}
