import Foundation
import SwiftUI

// MARK: - 图形化组件（v0.1.7）
//
// 目标：把「报告式」的密集文字与 Stepper 列表，换成一眼能看懂的大图形卡片。
// 全部组件只做展示与点击，不持有业务状态，不改动任何数据通路。
// 所有卡片仍走 F45 唯一入口 `glassCard(role:interactive:)`，不新增材质实现。

// MARK: 环形进度

/// 环形进度：外圈背景轨道 + 渐变前景弧 + 中心大数字。
/// `progress` 会被钳制到 0...1；`NaN` 视为 0，避免绘图崩溃。
public struct RingProgressView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let progress: Double
    public let centerValue: String
    public let centerUnit: String
    public let caption: String
    public let tint: Color

    public init(
        progress: Double,
        centerValue: String,
        centerUnit: String = "",
        caption: String = "",
        tint: Color = .accentColor
    ) {
        self.progress = progress
        self.centerValue = centerValue
        self.centerUnit = centerUnit
        self.caption = caption
        self.tint = tint
    }

    private var clampedProgress: Double {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09), lineWidth: 14)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint, tint.opacity(0.75)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: clampedProgress)

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(centerValue)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !centerUnit.isEmpty {
                        Text(centerUnit)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(18)
        }
        .frame(width: 148, height: 148)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(caption) \(centerValue) \(centerUnit)"))
    }
}

// MARK: 渐变主操作卡片

/// 一屏最大的那个按钮：整块渐变卡片，大图标 + 标题 + 副标题 + 箭头。
/// 点击后执行真实动作（跳转 / 开始记录），无静态占位。
public struct HeroActionCard: View {
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let colors: [Color]
    public let isEnabled: Bool
    public let action: () -> Void

    public init(
        title: String,
        subtitle: String,
        symbol: String,
        colors: [Color],
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.colors = colors
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.22), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(AppTheme.Spacing.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: colors.first?.opacity(0.35) ?? .clear, radius: 12, x: 0, y: 6)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text("\(title)，\(subtitle)"))
    }
}

// MARK: 指标小方块

/// 图标 + 大数字 + 短标签。用于一屏扫读，替代成段的文字说明。
public struct StatChip: View {
    @Environment(\.colorScheme) private var colorScheme

    public let symbol: String
    public let value: String
    public let unit: String
    public let label: String
    public let tint: Color

    public init(symbol: String, value: String, unit: String = "", label: String, tint: Color = .accentColor) {
        self.symbol = symbol
        self.value = value
        self.unit = unit
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label)：\(value) \(unit)"))
    }
}

// MARK: 胶囊小入口

/// 图标 + 文字的小胶囊入口，用于「历史 / 分析 / 路线」这类次级入口。
public struct PillEntry: View {
    @Environment(\.colorScheme) private var colorScheme

    public let symbol: String
    public let title: String
    public let action: () -> Void

    public init(symbol: String, title: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                .regularMaterial,
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppTheme.Colors.cardStroke(colorScheme), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

// MARK: 步骤指示

/// 轻量步骤条：把「选路线 → 调参数 → 生成」这类流程图形化，减少文字解释。
public struct StepIndicator: View {
    public let steps: [String]
    public let current: Int

    public init(steps: [String], current: Int) {
        self.steps = steps
        self.current = current
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { pair in
                let index = pair.offset
                let text = pair.element
                let isActive = index == current
                let isDone = index < current
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(isActive || isDone ? Color.accentColor : Color.primary.opacity(0.12))
                            .frame(width: 18, height: 18)
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isActive ? .white : .secondary)
                        }
                    }
                    Text(text)
                        .font(.caption2.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("步骤 \(current + 1) / \(steps.count)：\(steps.indices.contains(current) ? steps[current] : "")"))
    }
}

// MARK: 隐私提示

/// 隐私提示条：明确告知地图不显示实时位置、数据不外传。
/// 图标 + 单行文字，不使用颜色作为唯一信息通道。
public struct PrivacyNote: View {
    @Environment(\.colorScheme) private var colorScheme

    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "location.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: 区块标题

/// 统一的区块标题：可选图标 + 标题 + 右侧附加说明。
public struct SectionTitle: View {
    @Environment(\.colorScheme) private var colorScheme

    public let title: String
    public let symbol: String?

    public init(_ title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
            Spacer(minLength: 0)
        }
    }
}
