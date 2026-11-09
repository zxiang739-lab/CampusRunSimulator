import Foundation
import SwiftUI
import UIKit

// MARK: - 数值卡片（F48 / §B.12）

/// 单个指标卡片：数值 + 单位 + 说明 + 来源徽标（两类数据永不混排）。
/// 所有卡片都通过 F45 唯一入口 `glassCard(role:interactive:)` 使用玻璃材质。
public struct MetricCard: View {
    @Environment(\.colorScheme) private var colorScheme

    public let title: String
    public let value: String
    public let unit: String
    public let detail: String
    public let origin: DataOrigin?

    public init(
        title: String,
        value: String,
        unit: String = "",
        detail: String = "",
        origin: DataOrigin? = nil
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
        self.origin = origin
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                Spacer(minLength: 2)
                if let origin {
                    OriginBadge(origin, style: .compact)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var text = "\(title)：\(value) \(unit)"
        if !detail.isEmpty { text += "，\(detail)" }
        if let origin { text += "，\(origin.accessibilityLabel)" }
        return text
    }
}

// MARK: - 空态（真实引导动作，非静态占位）

/// 分别给真实 / 模拟两个分区的空态；`action` 绑定真实跳转或真实开始动作。
public struct EmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let origin: DataOrigin
    public let title: String
    public let message: String
    public let actionTitle: String
    public let action: () -> Void
    public let secondaryTitle: String?
    public let secondaryAction: (() -> Void)?

    public init(
        origin: DataOrigin,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.origin = origin
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: origin == .simulated ? "testtube.2" : "figure.run")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 2)
                OriginBadge(origin, style: .full)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(title: actionTitle, symbol: "arrow.right.circle.fill", style: .prominent) {
                action()
            }
            if let secondaryTitle, let secondaryAction {
                ActionButton(title: secondaryTitle, symbol: "questionmark.circle", style: .bordered) {
                    secondaryAction()
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .glassCard(role: .card, interactive: false)
    }
}

// MARK: - 错误态（AppError → 文案 + 可操作出口）

/// §B.13.3 的 15 类错误态统一出口；错误态下来源徽标不得消失。
public struct ErrorStateView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let origin: DataOrigin
    public let error: Error
    public let primaryTitle: String
    public let primaryAction: () -> Void
    public let secondaryTitle: String?
    public let secondaryAction: (() -> Void)?

    public init(
        origin: DataOrigin,
        error: Error,
        primaryTitle: String = "重试",
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.origin = origin
        self.error = error
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("当前操作未完成")
                    .font(.headline)
                Spacer(minLength: 2)
                OriginBadge(origin, style: .compact)
            }
            Text(error.localizedDescription)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion = recoverySuggestion, !suggestion.isEmpty {
                Text(suggestion)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: primaryTitle, symbol: "arrow.clockwise", style: .prominent) {
                    primaryAction()
                }
                if let secondaryTitle, let secondaryAction {
                    ActionButton(title: secondaryTitle, symbol: "gearshape", style: .bordered) {
                        secondaryAction()
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .glassCard(role: .card, interactive: false)
    }

    private var recoverySuggestion: String? {
        (error as? AppError)?.recoverySuggestion
            ?? (error as? LocalizedError)?.recoverySuggestion
    }
}

// MARK: - 合规横幅（常驻，绑定真实动作）

public struct ComplianceBanner: View {
    public let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(AppConstants.complianceStatement)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button {
                action()
            } label: {
                Label("详情", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(AccessibilityLabels.complianceDetails)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: false)
    }
}

// MARK: - 统一动作按钮（永远绑定真实闭包，无空 action）

public enum ActionButtonStyle: String, Sendable, CaseIterable {
    case prominent
    case bordered
    case destructive
}

public struct ActionButton: View {
    public let title: String
    public let symbol: String
    public let style: ActionButtonStyle
    public let isDisabled: Bool
    public let action: () -> Void

    public init(
        title: String,
        symbol: String = "arrow.right",
        style: ActionButtonStyle = .bordered,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(role: style == .destructive ? .destructive : nil) {
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .modifier(ActionButtonStyleModifier(style: style))
        .disabled(isDisabled)
        .accessibilityLabel(Text(title))
    }
}

/// 把 `ActionButtonStyle` 落到 SwiftUI 原生 ButtonStyle 上，避免 `some ButtonStyle` 分支类型不一致。
private struct ActionButtonStyleModifier: ViewModifier {
    let style: ActionButtonStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .prominent:
            content.buttonStyle(.borderedProminent)
        case .bordered:
            content.buttonStyle(.bordered)
        case .destructive:
            content.buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}

// MARK: - 系统分享面板（真实 UIActivityViewController，无网络上传）

/// 导出文件经 `ExportedFile.writeToTemporaryDirectory()` 落到本地临时目录后由系统分享面板交给用户；
/// App 自身不发起任何网络请求，不写入第三方平台。
public struct ShareSheet: UIViewControllerRepresentable {
    public let items: [Any]
    public let onDismiss: (() -> Void)?

    public init(items: [Any], onDismiss: (() -> Void)? = nil) {
        self.items = items
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss?()
        }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // 系统分享面板内容在构造时确定，无需增量更新。
    }
}
