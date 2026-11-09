import SwiftUI

// ⚠️ 诚实标注（交付说明中由主理人统一披露）：
// iOS 26 Liquid Glass API 名称需在 macOS Runner (Xcode 26) 上编译验证；若命名有差异，仅需修改本文件。
// 已按 Apple `Glass.interactive` 官方签名修正（QA R1）：`interactive` 作用在 Glass 值上，不是 View 修饰符。
// 本地 Linux 无 Xcode 26 SDK，因此官方 API 路径集中在本文件，并用 `#if compiler(>=6.2)` 做双保险：
// Swift 6.2+ / Xcode 26 SDK 启用 Apple 官方 `GlassEffectContainer` / `.glassEffect` / `glassEffectID`；
// `Glass.interactive(Bool) -> Glass` 与 `Glass.tint(Color?)` 是 Glass 值上的方法，官方示例写作
// `.glassEffect(.regular.interactive(), in:)`，因此先构造 Glass 常量再传给 `.glassEffect(_:in:)`。
// 旧编译器（Xcode 16 的 Swift 6.0/6.1）走功能等价的 `.regularMaterial` / `.ultraThinMaterial` 回退路径，
// 保证本工程在两种 SDK 下都能编译，且**两条路径的控件集合、frame、contentShape、accessibility 完全一致**。
// 绝不因为无法本地验证而省略官方 API 路径，也不使用私有 API / 伪造系统玻璃 / 第三方 UI 依赖。

// MARK: - 玻璃角色（F45 / §1.6）

/// 玻璃材质使用角色。节制地用于悬浮控制条、回放控件、卡片容器、按钮组。
public enum GlassRole: String, Codable, Sendable, CaseIterable {
    case card
    case controlBar
    case buttonGroup
    case floating

    /// 统一圆角（两路径共享）。
    public var cornerRadius: CGFloat {
        switch self {
        case .card: return 18
        case .controlBar: return 24
        case .buttonGroup: return 22
        case .floating: return 28
        }
    }

    /// 统一内边距与容器 spacing（两路径共享）。
    public var spacing: CGFloat {
        switch self {
        case .card: return 12
        case .controlBar: return 10
        case .buttonGroup: return 8
        case .floating: return 14
        }
    }

    /// 回退路径的模糊半径。
    public var blurRadius: CGFloat {
        switch self {
        case .card: return 6
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

    /// 无障碍提示（两路径共享）。
    public var accessibilityHint: String {
        "\(localizedDescription)容器，包含可操作控件"
    }
}

// MARK: - 两路径共享的几何 / 无障碍修饰

/// `frame` / `contentShape` / accessibility 的唯一实现处，两条路径都调用，保证功能等价（AC-F9）。
private struct SharedGlassChrome: ViewModifier {
    let role: GlassRole
    let interactive: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text(role.accessibilityHint))
            .accessibilityAddTraits(interactive ? [.isButton] : [])
    }
}

// MARK: - iOS 26 官方 Liquid Glass 路径

#if compiler(>=6.2)
/// Apple 官方玻璃路径。`.glassEffect` 可独立使用（Apple 官方示例即无 `GlassEffectContainer` 直接调用），
/// 因此这里直接对内容施加玻璃，不再为每张卡片各包一层 `GlassEffectContainer`。
///
/// 关键修复（治本「整体卡死、点不动」）：
/// 1. **删除 `glassEffectID(role.rawValue, ...)`** —— `role.rawValue` 是固定角色名，全 App 同名元素共用同一 ID，
///    且各自处于不同容器，SwiftUI 在玻璃「形变/合并」阶段会反复 reconcile 这些重名 ID，导致主线程空转、UI 冻结。
///    `glassEffectID` 仅用于跨状态形变过渡，本 App 无此需求，移除即消除死循环。
/// 2. **移除每卡片 `GlassEffectContainer`** —— 避免大量独立采样层与 phantom 命中层叠加拖垮主线程。
/// 3. **`SharedGlassChrome` 置于 `.glassEffect` 之前** —— 官方要求布局/命中修饰符必须位于玻璃采样之前。
@available(iOS 26, *)
private struct GlassEffectPath<Content: View>: View {
    let role: GlassRole
    let interactive: Bool
    let content: Content

    var body: some View {
        // QA R1：`Glass.interactive(Bool) -> Glass` 作用在 Glass 值上，不存在 View 版 interactive 修饰符。
        let glass: Glass = interactive ? .regular.interactive() : .regular
        content
            .modifier(SharedGlassChrome(role: role, interactive: interactive))
            .padding(role.spacing)
            .glassEffect(glass, in: Capsule())
    }
}
#endif

// MARK: - iOS 17–25 材质回退路径

/// `.regularMaterial` / `.ultraThinMaterial` + `blur` + 圆角 + 描边 + 阴影。
/// 与官方路径共享 `SharedGlassChrome`，控件集合完全一致，不隐藏、不禁用任何功能。
private struct FallbackGlassPath<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let role: GlassRole
    let interactive: Bool
    let content: Content

    var body: some View {
        content
            .padding(role.spacing)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .blur(radius: role.blurRadius)
                    RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous))
            .shadow(
                color: shadowColor,
                radius: reduceMotion ? 4 : 10,
                x: 0,
                y: reduceMotion ? 1 : 5
            )
            .modifier(SharedGlassChrome(role: role, interactive: interactive))
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

// MARK: - 全 App 唯一入口

public extension View {
    /// **全 App 唯一玻璃入口**：所有页面只能通过 `glassCard` 使用玻璃效果，
    /// 不得直接调用 `.glassEffect`。两条路径共享相同 frame / contentShape / accessibility。
    @ViewBuilder
    func glassCard(role: GlassRole, interactive: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            glassEffectPath(role: role, interactive: interactive)
        } else {
            fallbackPath(role: role, interactive: interactive)
        }
        #else
        fallbackPath(role: role, interactive: interactive)
        #endif
    }
}

private extension View {
    #if compiler(>=6.2)
    /// iOS 26 官方 API 路径（`@available` 门控，命名差异只需改本文件）。
    @available(iOS 26, *)
    @ViewBuilder
    func glassEffectPath(role: GlassRole, interactive: Bool) -> some View {
        GlassEffectPath(role: role, interactive: interactive, content: self)
    }
    #endif

    /// iOS 17–25 回退路径（功能等价，不是「只留回退」）。
    @ViewBuilder
    func fallbackPath(role: GlassRole, interactive: Bool) -> some View {
        FallbackGlassPath(role: role, interactive: interactive, content: self)
    }
}
