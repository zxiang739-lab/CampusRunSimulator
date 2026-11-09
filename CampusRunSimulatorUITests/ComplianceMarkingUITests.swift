import XCTest

/// F65 · 合规标记 / 导航 / 无障碍 UI 测试（AC-C1 / AC-F1 / AC-F7 / AC-F10 / [T11]）。
///
/// 诚实边界：
/// - 本文件是 XCUITest，只有 iOS Simulator / 真机上运行的 App 才能执行；
///   **CI 可选运行（`workflow_dispatch` 的 `runUITests`），本地 Linux 未执行**，不得写成「已通过」；
/// - 深色模式 / 最大动态类型 / Reduce Motion 下的全页面等价、iOS 26 与低版本 Liquid Glass 双路径等价
///   需真机人工验收，见 README「真机验收清单」；本文件只断言标记可见与 VoiceOver 标签存在；
/// - 7 页标记形式按真实 UI 结构区分：
///   · 首页 / 模拟 / 实时运动 / 数据分析 / 历史 / 设置：页面内常驻 `OriginBadge`（文字 + 图标 + VoiceOver）；
///   · 路线规划页：中立路线编辑对象，标记为顶部全站合规声明 + 常驻「导出来源标记」Picker 中的
///     「测试数据 / SIMULATED」「真实记录」文字 + 页内 SIMULATED 导出说明。此处如实标注，不虚构徽标。
final class ComplianceMarkingUITests: XCTestCase {

    private var app: XCUIApplication!

    /// 与 `AppRoute.title`（RootView.swift）一一对应，冻结文案不得在此重定义。
    private let pageTitles: [String] = [
        "首页总览", "地图与路线规划", "运动模拟器", "实时运动",
        "数据分析", "历史记录", "设置"
    ]
    private let primaryTitles: [String] = [
        "首页总览", "地图与路线规划", "运动模拟器", "实时运动"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // 首次启动的强制合规确认：点击真实按钮关闭，后续 7 页才可访问。
        let confirm = app.buttons["我已阅读并确认合规声明"]
        if confirm.waitForExistence(timeout: 8) {
            XCTAssertTrue(confirm.isEnabled, "合规确认按钮必须真实可用")
            confirm.tap()
        }
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - 查询辅助

    /// 任意可访问元素的 label 是否包含指定文字（不依赖颜色、不依赖元素类型）。
    private func anyElementLabelContains(_ text: String) -> Bool {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
        return query.count > 0
    }

    /// 通过顶部「页面导航菜单」真实跳转到目标页，并断言入口不是假按钮。
    private func navigate(to title: String) {
        let menu = app.buttons["打开页面导航菜单"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "顶部页面导航菜单必须存在")
        XCTAssertTrue(menu.isEnabled, "导航菜单必须可交互")
        menu.tap()

        let item = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title))
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8), "\(title) 菜单入口必须存在")
        XCTAssertTrue(item.isEnabled, "\(title) 不得是禁用 / 无动作的假按钮")
        item.tap()

        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(
            navigationBar.waitForExistence(timeout: 8) || anyElementLabelContains(title),
            "点击 \(title) 后必须真实切换到对应页面"
        )
    }

    // MARK: - [T11] 7 页来源标记可见

    func testOriginBadgeOnAllSevenPages() {
        // [T11][AC-C1] 7 个页面均可访问，且每页都有可见的合规 / 来源文字标记。
        for title in pageTitles {
            navigate(to: title)
            let hasSimulated = anyElementLabelContains("SIMULATED")
                || anyElementLabelContains("测试数据")
            let hasReal = anyElementLabelContains("真实记录")
            let hasCompliance = anyElementLabelContains("不作弊")
                || anyElementLabelContains("教学研究")
            XCTAssertTrue(hasSimulated || hasReal || hasCompliance,
                          "\(title) 必须常驻可见的合规 / 来源标记，不得依赖颜色区分")

            if title == "实时运动" {
                XCTAssertTrue(hasReal, "真实记录页必须常驻「真实记录」文字标记")
                XCTAssertTrue(anyElementLabelContains("此页数据来自设备传感器")
                              || hasReal, "真实记录页需说明与测试数据物理隔离")
            } else if title == "地图与路线规划" {
                // 中立路线编辑页：标记来自 Picker 的两种来源文字 + 顶部全站合规声明。
                XCTAssertTrue(hasSimulated && hasReal,
                              "路线规划页「导出来源标记」必须同时列出 SIMULATED 与真实记录")
                XCTAssertTrue(anyElementLabelContains("SIMULATED 标记"),
                              "路线规划页需给出导出标记说明，不得静默导出")
            } else {
                XCTAssertTrue(hasSimulated || hasReal,
                              "\(title) 必须显示具体来源徽标（测试数据 / SIMULATED 或真实记录）")
            }
        }
    }

    // MARK: - [T11] 历史记录不混排

    func testNoMixedOriginList() {
        // [T11][AC-C7] 历史页默认两分区，禁止「全部记录」混排成绩单与转换入口。
        navigate(to: "历史记录")
        XCTAssertTrue(anyElementLabelContains("真实记录"), "必须存在真实记录分区")
        XCTAssertTrue(anyElementLabelContains("测试数据 SIMULATED")
                      || anyElementLabelContains("测试数据 / SIMULATED"),
                      "必须存在测试数据 SIMULATED 分区")
        XCTAssertTrue(anyElementLabelContains("永不混排")
                      || anyElementLabelContains("分别写入"),
                      "必须明确说明两类数据分区且不合并")
        XCTAssertFalse(anyElementLabelContains("全部记录"),
                       "不得提供「全部记录」混排视图")
        XCTAssertFalse(anyElementLabelContains("上传成绩"))
        XCTAssertFalse(anyElementLabelContains("模拟转真实"))
    }

    // MARK: - [T11] VoiceOver 与无障碍标签

    func testAccessibilityLabels() {
        // [T11][AC-C1][AC-F10] 徽标三通道（文字 + 图标 + VoiceOver），导航控件均有可读标签。
        navigate(to: "运动模拟器")
        XCTAssertTrue(anyElementLabelContains("测试数据 SIMULATED"),
                      "OriginBadge 的 VoiceOver 标签必须可读")
        XCTAssertTrue(anyElementLabelContains("SIMULATED"), "可见文字通道必须存在")

        navigate(to: "实时运动")
        XCTAssertTrue(anyElementLabelContains("真实记录"),
                      "真实记录徽标的 VoiceOver 标签必须可读")

        let labeledButtons = [
            "打开页面导航菜单",
            "切换到 首页总览",
            "切换到 地图与路线规划",
            "切换到 运动模拟器",
            "切换到 实时运动",
            "打开更多页面菜单",
            "查看合规声明"
        ]
        for label in labeledButtons {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, "控件 \(label) 必须有无障碍标签且可查询")
            XCTAssertFalse(button.label.isEmpty, "控件 \(label) 的 VoiceOver 标签不得为空")
            XCTAssertTrue(button.isEnabled, "控件 \(label) 不得是不可用的假按钮")
        }
    }

    // MARK: - [T11] 导航与按钮真实生效（无假按钮）

    func testPrimaryTabButtonsNavigate() {
        // [T11][AC-F1] 底部 4 个主入口逐一点击，验证真实切换而非静态占位。
        for title in primaryTitles {
            let button = app.buttons["切换到 \(title)"]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "\(title) 底部入口必须存在")
            XCTAssertTrue(button.isEnabled, "\(title) 底部入口不得被禁用")
            button.tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 8)
                    || anyElementLabelContains(title),
                "点击 \(title) 后必须出现对应页面标题"
            )
            XCTAssertTrue(anyElementLabelContains("不作弊")
                          || anyElementLabelContains("教学研究"),
                          "\(title) 切换后顶部合规声明仍须常驻")
        }

        // 首页的 4 个主入口按钮必须存在且可点击（绑定真实跳转）。
        let home = app.buttons["切换到 首页总览"]
        home.tap()
        for title in ["开始真实跑步", "新建仿真", "路线规划", "历史记录"] {
            let entry = app.buttons[title]
            XCTAssertTrue(entry.waitForExistence(timeout: 8), "首页 \(title) 入口必须存在")
            XCTAssertTrue(entry.isEnabled, "首页 \(title) 不得是无动作的假按钮")
        }
        app.buttons["新建仿真"].tap()
        XCTAssertTrue(
            app.navigationBars["运动模拟器"].waitForExistence(timeout: 8)
                || anyElementLabelContains("运动模拟器"),
            "点击「新建仿真」必须真实进入模拟页"
        )
    }

    // MARK: - [T11] 禁止词与合规按钮扫描

    func testNoForbiddenButtons() {
        // [T11][AC-C5] 全页扫描按钮标签，不得出现上传成绩 / 过检 / 来源转换类动作。
        let forbidden = [
            "上传成绩", "刷成绩", "过检", "有效成绩", "提交成绩",
            "模拟转真实", "转为真实记录", "破解", "绕过反作弊", "伪造定位"
        ]
        for title in pageTitles {
            navigate(to: title)
            for button in app.buttons.allElementsBoundByIndex {
                let label = button.label
                for word in forbidden {
                    XCTAssertFalse(label.contains(word),
                                   "\(title) 出现禁止词按钮：\(word)（label=\(label)）")
                }
            }
            // 顶部全站合规声明在每一页都不得消失。
            XCTAssertTrue(anyElementLabelContains("不作弊")
                          || anyElementLabelContains("教学研究"),
                          "\(title) 顶部合规声明必须常驻")
        }
    }
}
