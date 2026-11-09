# 更新日志

本文件记录 CampusRunSimulator 的版本、架构决策摘要与真机验收状态。
所有条目按「时间与事实」书写；**未经真机 / CI 实际验证的项目一律标注「待验收」，不得填写「已通过」**。

---

## v0.1.1（未发布 / 待 CI 验证）

- 日期：2026-11-09（工作副本，**尚未推送、尚未触发 CI**）
- 依据：v0.1.0 未签名 IPA 侧载真机运行反馈（2 个缺陷）
- 状态：**待 GitHub Actions 重新构建验证**；本地 Linux 无 Xcode / actool，无法本地编译或验证 asset catalog 产物。

### 修复内容

1. **修复首次启动合规确认页点击「我已阅读并确认」后无法关闭（阻塞进入 App，P0 体验阻断）**
   - `ComplianceConfirmationView` 新增 `onConfirm: () -> Void` 回调，主按钮动作改为「置确认标记 + 调用回调」；
   - `RootView` 的 `fullScreenCover` 传入 `onConfirm: { showComplianceSheet = false }`；
   - `RootView.body` 追加 `.onChange(of: complianceConfirmed)` 作为双保险，任意路径把确认标记置为 true
     都会关闭全屏页；
   - 保留 `.interactiveDismissDisabled(true)`（首次必须显式确认，属合规要求），并在按钮下方补充说明
     「确认后即可进入 App，本次确认会被记住，不再重复弹出。」
   - 根因：按钮只写入 `@AppStorage("campusrun.complianceConfirmed")`，从未把控制 `fullScreenCover` 的
     `showComplianceSheet` 置为 false，叠加下滑关闭被禁用 → 用户卡死在合规页。
2. **补齐 1024×1024 AppIcon 并修正 `Contents.json`，修复桌面图标空白与 `Assets.car` 缺失**
   - 新增 `CampusRunSimulator/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
     （**1024×1024、RGB 模式、无 alpha 通道**，130,275 字节）；`Contents.json` 补 `"filename" : "AppIcon-1024.png"`；
   - 根因（双重）：AppIcon set 内只有 `Contents.json`、**零张像素图**，且 `images[0]` 缺 `filename` 字段 →
     `actool` 不产出 `Assets.car` → asset catalog 未进 bundle，于是 IPA 内只有
     `CampusRunSimulator` / `Info.plist` / `PkgInfo` 三个文件，桌面图标空白；
   - 项目侧无需改动：`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 已在 pbxproj 的 Debug/Release 两处存在，
     同步根组仅排除 `Resources/Info.plist` 与 `Resources/CampusRunSimulator.entitlements`，
     `Assets.xcassets` 会被自动纳入 Resources 阶段。
3. **版本编排：升级至 `MARKETING_VERSION = 0.1.1` / `CURRENT_PROJECT_VERSION = 2`，auto-tag 改为从
   `Config/App.xcconfig` 动态解析 tag 名，消除硬编码**
   - `Config/App.xcconfig`：`MARKETING_VERSION` 0.1.0 → **0.1.1**，`CURRENT_PROJECT_VERSION` 1 → **2**；
   - `project.pbxproj`：6 处 `MARKETING_VERSION = 0.1.1;`、6 处 `CURRENT_PROJECT_VERSION = 2;`
     （3 个 target × Debug/Release），仅改数值，未动 ID / 结构 / 其他键；
   - `ios-build.yml`：`auto-tag` 的 `id: mk` 改为
     `VER=$(awk -F'=' '/^MARKETING_VERSION/{gsub(/[ \t]/,"",$2);print $2}' Config/App.xcconfig)`
     → `TAG="v${VER}"`，两处「解析版本号」步骤的非 tag 分支同样改为从 xcconfig 读取（并校验非空）；
     workflow 内**已不存在任何写死的版本字面量**（`grep 'v0\.1\.0'` 结果为 0）；
   - 效果：以后升级版本只需改 `Config/App.xcconfig`，编译 / IPA / tag / Release 全链路自动跟随，
     不会因 tag 名被写死而导致 `created=false`、Release 被跳过。
   - 根因：旧 workflow 在 `auto-tag` 中写死 `v0.1.0`，而 `v0.1.0` 已存在 →
     `git rev-parse --verify refs/tags/v0.1.0` 命中 → `created=false` → `release` job 被跳过，
     新 IPA 永远进不了 Release，用户下载到的仍是旧包。

### 待验证（不得提前标记「已通过」）

- 需新的 CI run 确认：`actool` 真实产出 `Assets.car`，IPA 解包后包含 `Assets.car` 与 AppIcon 资源；
- 需真机侧载确认：首次启动点击确认后可进入 App 且不再重复弹出；桌面图标正常显示；
- 其余真机验收项（后台 30 min、HealthKit 写入、XCUITest 全流程、签名路径 B、iOS 17 功能等价）
  状态不变，仍为「待验收」。

---

## v0.1.0 — 初始可编译交付

- 交付日期：2026-01-01
- 交付范围：`docs/03-TaskList.md` T01–T05 全部 74 个文件（F01–F74），分批落盘完成。
- 构建状态：✅ **已由 GitHub Actions 在 macOS Runner 上用 Xcode 26.3 真实构建通过**
  （run `42561578021`，44 tests 0 failures，未签名 IPA 1,351,848 字节，`v0.1.0` tag 与 Release 均已发布）。
  本工程源码在 Linux 沙箱生成，本地无 Xcode / Swift 工具链，未在本地编译；
  全部编译 / 测试 / IPA / Release 结论均来自上述真实 run，详见下方「构建与发布」与 `README.md` §0。

### 构建与发布（GitHub Actions 实测）

> 以下为一次真实 `push main` 触发的完整成功 run 的结果，非本地推断、非预估。

| 项目 | 实测结果 |
| --- | --- |
| 构建日期 | 2026-11-09 |
| 仓库（public） | <https://github.com/zxiang739-lab/CampusRunSimulator> |
| Actions run | `42561578021`（触发事件 `push` → 分支 `main`） |
| 构建工具链 | Xcode **26.3** / iOS **26.2** Simulator（macOS Runner） |
| 编译门禁 | ✅ `xcodebuild -sdk iphonesimulator clean build` 通过 |
| 模拟器预热 | ✅ `simctl boot` + `simctl bootstatus -b` 通过（后续步骤使用解析出的具体 UDID） |
| 单元测试 | ✅ **44 tests, 0 failures（0 unexpected）** |
| 未签名 IPA（路径 A） | ✅ **1,351,848 字节（约 1.29 MB）**；`test -s` + `unzip -l` 双重门禁通过 |
| IPA 内部结构 | `Payload/CampusRunSimulator.app/CampusRunSimulator`（3,436,256 字节）、`Info.plist`、`PkgInfo` |
| Tag | ✅ `v0.1.0`（`auto-tag` job 幂等创建的轻量 tag，指向该次构建 commit） |
| Release | ✅ <https://github.com/zxiang739-lab/CampusRunSimulator/releases/tag/v0.1.0> |
| Release 资产 ① | `CampusRunSimulator-unsigned.ipa` — 1,351,848 字节 |
| Release 资产 ② | `CampusRunSimulator-source.zip` — 482,410 字节 |
| 签名状态 | **未签名 IPA（路径 A）**；路径 B（已签名）因未配置 5 个 Secrets **未执行**，属如实状态 |

步骤链全部 ✓：编译门禁 → 预热模拟器 → 单元测试 → 构建未签名 IPA →
IPA `test -s` + `unzip -l` 双重门禁 → 上传 artifact → `auto-tag` → `release`。

**能证明**：在 Xcode 26.3 / iOS 26.2 SDK 上可编译、单元测试真实通过、IPA 真实存在且非空、
tag 与 Release 真实发布，产物可下载后自行校验。
**不能证明**：IPA 可安装到未越狱真机、已签名路径 B 可用、真机传感器 / HealthKit 行为正确、
XCUITest 全流程通过、iOS 17 低版本功能等价。

**真机验收项待人工执行**（状态保持「待验收」，见 README §10 与本文件「真机 / CI 验收记录」）：

- 后台 30 min 真实连续记录、GPS 遮挡后独立 segment（AC-F5 / [T07]）；
- HealthKit 真机授权 + 显式勾选后写入 workout + route（AC-F6）；
- XCUITest 全流程（[T11]，仅 `workflow_dispatch` + `runUITests=true` 开启，本次 run 未执行）；
- 签名路径 B 已签名 IPA（需 5 个 Secrets 齐备并手动触发，当前未配置）；
- iOS 17 等低版本功能等价（AC-F9，CI 仅在 iOS 26.2 模拟器上运行）。

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
- 上述修复已随 run `42561578021` 在 Xcode 26.3 上真实构建验证：`auto-tag` 幂等创建 `v0.1.0` 并在
  同一次 run 内发布 Release（已实测成立）；GPX Fixtures 三级兜底使 44 个单元测试全部通过；
  官方 Liquid Glass 路径编译通过。**路径 B 的 `CODE_SIGNING_ALLOWED=YES` 反向覆盖仍未经验证**——
  未配置 5 个 Secrets，该 job 从未执行。本轮真机验收状态不变，仍为「待验收」。

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

> ⚠️ 以下项目**均未在本地 Linux 沙箱执行**。CI 项已由 run `42561578021` 实测通过并填写结果
> （2026-11-09，Xcode 26.3 / iOS 26.2 Simulator）；**真机项一律保持「待验收」**，
> 通过后须由验收人填写日期、设备型号、iOS 版本与实际结果，不得提前标记「已通过」。

| 验收项 | 编号 | 状态 | 设备 / iOS 版本 | 结果记录 |
| --- | --- | --- | --- | --- |
| Xcode 完整编译 + 单元测试 | V5.1 / V5.2 / [T12] | ✅ 已通过（CI 实测） | macOS Runner / Xcode 26.3 | 2026-11-09 run `42561578021`；编译门禁 ✓，44 tests 0 failures（0 unexpected） |
| 未签名 IPA 真实存在、非空、含 Info.plist | V5.2 | ✅ 已通过（CI 实测） | macOS Runner / Xcode 26.3 | 1,351,848 字节；`test -s` + `unzip -l` 双重门禁 ✓；内部含 `Info.plist` / `PkgInfo` / 主二进制 3,436,256 字节 |
| tag `v*` / `auto-tag` 触发 Release 成功发布 | V5.4 | ✅ 已通过（CI 实测） | macOS Runner | 轻量 tag `v0.1.0` 幂等创建；Release 资产 = IPA 1,351,848 字节 + 源码 zip 482,410 字节 |
| 签名路径 B（5 个 Secrets 齐备）产出已签名 IPA | V5.3 | ⏳ 待手动触发验收（当前未配置 Secrets，未执行） | macOS Runner | — |
| 后台 30 min 连续记录、GPS 遮挡后独立分段 | AC-F5 / [T07] | ⏳ 待真机验收 | — | — |
| HealthKit 授权 + 显式勾选后写入 workout + route | AC-F6 | ⏳ 待真机验收 | — | — |
| iOS 26 与 iOS 17 完整功能用例等价（Liquid Glass 双路径） | AC-F9 | ⏳ 待真机验收（CI 仅覆盖 iOS 26.2 Simulator） | — | — |
| 深色模式 / 最大动态类型 / Reduce Motion 全页面 | AC-F10 | ⏳ 待真机验收 | — | — |
| 强杀 App 重启后会话 / 路线 / 预设 / 设置完整 | AC-F11 / [T08] | ⏳ 待真机验收 | — | — |
| GPX 真机导入与系统分享面板导出 | AC-F2 / AC-F3 | ⏳ 待真机验收 | — | — |
| XCUITest 7 页标记 / 无假按钮 / 无混排 | [T11] / AC-C1 | ⏳ 待手动触发验收（`workflow_dispatch` + `runUITests=true`；本次 run 未执行） | iOS Simulator | — |
| iOS 26 官方 Liquid Glass API 命名编译验证 | 交付说明 | ✅ 已通过（CI 实测） | Xcode 26.3 | `GlassEffectContainer` / `.glassEffect(_:in:)` / `.glassEffectID(_:in:)` / `Glass.interactive(Bool)` 均编译通过 |
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
