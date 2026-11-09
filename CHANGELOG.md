# 更新日志

本文件记录 CampusRunSimulator 的版本、架构决策摘要与真机验收状态。
所有条目按「时间与事实」书写；**未经真机 / CI 实际验证的项目一律标注「待验收」，不得填写「已通过」**。

---

## v0.1.0 — 初始可编译交付

- 交付日期：2026-01-01
- 交付范围：`docs/03-TaskList.md` T01–T05 全部 74 个文件（F01–F74），分批落盘完成。
- 构建状态：**待 GitHub Actions macOS Runner 实际验证**。本工程源码在 Linux 沙箱生成，
  本地无 Xcode / Swift 工具链，未执行编译、未运行 XCTest、未生成 IPA、未发布 Release；
  最终以 `.github/workflows/ios-build.yml` 的实际运行结果为准。

### 交付内容

**工程与配置（F01–F07，7 个）**
- 手写 Xcode 16 工程 `project.pbxproj`（`objectVersion = 77`、`compatibilityVersion = "Xcode 16"`、
  3 个 `PBXFileSystemSynchronizedRootGroup`、3 个 `PBXNativeTarget`、完整 Debug/Release 配置）；
- shared scheme（含 2 个测试 target）、`Config/App.xcconfig`、`Info.plist`、
  `CampusRunSimulator.entitlements`、`Assets.xcassets`。

**Core / Domain / Persistence / Contracts（F10–F23）**
- `DataOrigin` 不可变双值、三重标记常量与独立 id 空间；`Units` 为量纲唯一实现处；
- `AppConstants` 固定文案 / 容差 / `AppError` 全 15 类状态；`AuditLogger`（日志不写经纬度）；
- 15 类领域实体、SwiftData 双独立容器与迁移计划、层间冻结协议。

**仿真引擎（F24–F31）**
- 6 个主干量（t / s / v(t) / c(t) / h(s) / seed）唯一真值源，确定性 PRNG、
  时间相关有界平滑噪声、6 种速度模型、5 阶段连续过渡；
- Haversine 弧长参数化、海拔误差模型、`L = 60v/c`、I1–I10 独立检查函数；
- `actor DefaultSimulationEngine` 双次构建复现校验，一致性失败**拒绝生成**。

**真实链路 / 数据处理 / 规则 / 导入导出 / 仓库（F32–F44）**
- `CoreLocation` / `CoreMotion` / `HealthKit` 真实封装，`LiveRunRecorder` 精度门限、
  野值剔除、稀疏间隔不插值、`segmentIndex` 分段与恢复检查点；
- `SeriesBuilder` 4 类曲线 + 3 档降采样 + 跨段不连线，`AnalysisBuilder` 报告；
- 规则预设强制 `isHypothetical = true`、三态评估**无分数**、多预设并列对比；
- `GPXCodec`（`XMLParser` 真解析）/ `TabularCodec` / `DataMarker` / `ExportManager` 三重标记；
- `DefaultRunRepository` 双容器物理分域，无 `simulated → real` 转换、无 HK 写入测试数据的路径。

**UI（F45–F59，15 个）**
- F45 单点收敛 Liquid Glass 双路径（iOS 26 官方 API / 低版本 `.regularMaterial` 回退）；
- 7 个页面各由真实 ViewModel 驱动并调用上述服务，无静态占位、无假按钮；
- `ReplayView` / `ReplayController` 真实时间轴、倍速 0.5×–8×、`seek(to:)` 与同时间戳联动；
- 深浅色、动态类型、提高对比度、Reduce Motion、VoiceOver 适配，来源徽标常驻。

**测试 / 样例 / CI / 文档（F60–F74，15 个）**
- 5 个 UnitTest 文件 + 1 个 XCUITest 文件，覆盖 12 类测试（映射见 `README.md`）；
- 3 个真实合法 GPX 样例（闭合环多 `trkseg` / 缺 `ele`+`time` / 仅 `rte`+`wpt`+非法版本探针）；
- 签名双路径 CI（路径 A 未签名 IPA 门禁、路径 B Secrets 驱动已签名 IPA、tag `v*` 自动 Release）；
- `README.md` / `LICENSE`（MIT + 不得用于作弊附加声明）/ 本文件。

### QA 第 1 轮修复（4 项阻断 / 编译缺陷，`docs/05-QA-Report.md`）

- **workflow auto-tag / Release 闭环（P0）**：新增 `auto-tag` job（`needs: [build-test]`，仅 `push main`
  且构建成功时幂等创建轻量 tag `v0.1.0`），`release` job 改为 `needs: [build-test, auto-tag]`、
  用 `always()` + `created == 'true'` 在**同一次 run** 内发布 Release，`tag_name` / `name` 用三元表达式、
  补 `target_commitish: ${{ github.sha }}`、`RELEASE_TAG` 版本常量替换全部 `${GITHUB_REF_NAME}`；
  IPA 仍从同一次 run 的 artifact 获取，防循环 + 幂等避免重复发布，不引入新 Secret。
- **`Glass.interactive` API 归属**：按 Apple 官方签名把 interactive 从 View 修饰链移到 `Glass` 值上
  （先构造 `Glass` 局部常量再传给 `.glassEffect(_:in:)`），两分支同时修正；仍待 Xcode 26 实机编译确认。
- **GPX Fixtures 内联兜底**：F62 新增 3 个与 `Fixtures/*.gpx` 逐字一致的内联常量，
  `loadFixture(_:)` 改为「bundle → `#filePath` → 内联常量」三级兜底，不再因资源未拷贝而 `XCTFail`。
- **签名路径 B 反向覆盖**：路径 B 的 `clean archive` 与 `-exportArchive` 显式追加
  `CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`，覆盖 xcconfig / pbxproj 的全局 `NO`；
  路径 A 保持 `NO` 不变。
- 以上均为**静态文本层修复，本地 Linux 未实机运行 / 未编译 / 未产出 Tag / Release / IPA**；
  是否真正闭环以 GitHub Actions macOS Runner 实际日志为准。本轮真机验收状态不变，仍为「待验收」。

### 架构决策记录（ADR 摘要）

| 编号 | 决策 | 理由与落地位置 |
| --- | --- | --- |
| ADR-1 | **Q1：最低支持 iOS 17.0** | 需 SwiftData / `@Observable` / Swift Charts / MapKit SwiftUI；`IPHONEOS_DEPLOYMENT_TARGET = 17.0`（F01/F03）。 |
| ADR-2 | **双独立 `ModelContainer` 物理分域** | `simulated.store` / `real.store` 独立 URL、独立配置、独立 `sim_` / `real_` id 空间；不启用 iCloud，避免两类数据汇合（F21/F44）。 |
| ADR-3 | **`PBXFileSystemSynchronizedRootGroup`（Xcode 16）** | 手写工程文件需与磁盘目录自动同步，避免逐文件登记 74 条 `PBXFileReference`；`objectVersion = 77`（F01）。 |
| ADR-4 | **签名双路径互斥** | 路径 A 默认产出未签名 IPA，不依赖任何证书；路径 B 仅手动触发且 5 个 Secrets 齐备时运行，Secret 缺失明确跳过、不回退冒充已签名产物（F69/F70/F71）。 |
| ADR-5 | **Liquid Glass 双路径 + 单点收敛** | 全 App 只经 `View.glassCard(role:interactive:)`；iOS 26 用官方 `GlassEffectContainer` / `.glassEffect` / `.glassEffectID` / `.interactive`，低版本用 `.regularMaterial` + `blur` 回退并显示「已启用兼容外观」，功能等价（F45/F47）。 |
| ADR-6 | **App 零第三方依赖** | 仅 Apple 系统 framework；CI 的 `actions/checkout@v4` / `upload-artifact@v4` / `action-gh-release@v2` 是编排工具，不是 App 运行依赖。 |
| ADR-7 | **规则评估三态、无分数** | `RuleEvaluationResult` / `ComparisonTable` 类型系统层面无 score / grade / rank；预设全部标注「示例假设值」，REAL 记录不参与评估（F18/F38/F39）。 |
| ADR-8 | **真实记录与测试数据永不互转** | `dataOrigin` 为不可变 `let`，无 mutating / convert / toReal 方法；HealthKit 仅 `.real`，导出混合来源一律拒绝。 |
| ADR-9 | **本地 Linux 沙箱如实披露** | 无 Xcode 不声称编译通过；编译 / IPA / Release 一律以 macOS Runner 实际结果为准（本文件、README、F71 文件头）。 |

### 真机 / CI 验收记录（留档）

> ⚠️ 以下项目**均未在本地 Linux 沙箱执行**，状态如实填写为「待验收」；
> 通过后须由验收人填写日期、设备型号、iOS 版本与实际结果，不得提前标记「已通过」。

| 验收项 | 编号 | 状态 | 设备 / iOS 版本 | 结果记录 |
| --- | --- | --- | --- | --- |
| Xcode 完整编译 + 单元测试 | V5.1 / V5.2 / [T12] | ⏳ 待 GitHub Actions 验收 | macOS Runner | — |
| 未签名 IPA 真实存在、非空、含 Info.plist | V5.2 | ⏳ 待 GitHub Actions 验收 | macOS Runner | — |
| tag `v*` 触发 Release 成功发布 | V5.4 | ⏳ 待 GitHub Actions 验收 | macOS Runner | — |
| 签名路径 B（5 个 Secrets 齐备）产出已签名 IPA | V5.3 | ⏳ 待手动触发验收 | macOS Runner | — |
| 后台 30 min 连续记录、GPS 遮挡后独立分段 | AC-F5 / [T07] | ⏳ 待真机验收 | — | — |
| HealthKit 授权 + 显式勾选后写入 workout + route | AC-F6 | ⏳ 待真机验收 | — | — |
| iOS 26 与 iOS 17 完整功能用例等价（Liquid Glass 双路径） | AC-F9 | ⏳ 待真机验收 | — | — |
| 深色模式 / 最大动态类型 / Reduce Motion 全页面 | AC-F10 | ⏳ 待真机验收 | — | — |
| 强杀 App 重启后会话 / 路线 / 预设 / 设置完整 | AC-F11 / [T08] | ⏳ 待真机验收 | — | — |
| GPX 真机导入与系统分享面板导出 | AC-F2 / AC-F3 | ⏳ 待真机验收 | — | — |
| XCUITest 7 页标记 / 无假按钮 / 无混排 | [T11] / AC-C1 | ⏳ 待 CI 或模拟器验收 | iOS Simulator | — |
| iOS 26 官方 Liquid Glass API 命名编译验证 | 交付说明 | ⏳ 待 Xcode 26 验收 | Xcode 26 | 若命名有差异，仅需修改 `UI/Theme/GlassModifier.swift` |
| 未签名 IPA 重签名安装 | 安装说明 | ⏳ 由使用者自行确认 | 个人 Apple ID | 本项目不虚构安装成功 |

### 版本更新规范与 Tag 约定

1. 版本号遵循语义化版本 `vMAJOR.MINOR.PATCH`（例：`v0.1.0`）。
2. 推送 `refs/tags/v*` 会触发 `ios-build.yml` 的 `release` job；
   `MARKETING_VERSION` 由 tag 去掉前缀 `v` 解析，`CURRENT_PROJECT_VERSION` 取 `github.run_number`，
   通过 `xcodebuild ... MARKETING_VERSION=... CURRENT_PROJECT_VERSION=...` 覆盖；
   非 tag 构建使用 `0.1.0+run_number`。
3. 每次发布前必须更新本文件：新增版本段落、列出变更、补充 ADR、
   **把已实际完成的真机 / CI 验收项从「待验收」改为「已通过」并附日期与结果**。
4. 禁止在未实际运行的情况下把任何验收项写成「已通过」；禁止虚构签名成功、安装成功、
   上传成绩或第三方平台判定结果。
5. `README.md` 的「12 类测试 → 文件 / 方法 → 验收编号」映射表须与本版本测试文件保持同步。
6. 合规红线（R1–R8）与 `LICENSE` 附加条款不随版本变更放宽；任何放宽均视为破坏性变更，需重新评审。
