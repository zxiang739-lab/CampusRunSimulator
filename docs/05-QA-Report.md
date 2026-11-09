# 05 · QA 独立质量审查报告（第 1 轮）

> 审查人：严过关（Yan）｜QA 工程师｜SOP 第 4 阶段（最后一环）
> 项目：Campus Run Simulator（iOS 原生校园跑运动仿真 App）
> 审查对象：`/workspace/CampusRunSimulator/` 全部落盘交付物 + `docs/` 上游文档
> 审查方式：**独立静态核查**，所有结论由本报告记录的命令 / 脚本实测得出，未采用工程师自查结论
> 报告日期：2026-11-09

---

## 0. 审查环境与诚实边界（先声明，避免误读）

### 0.1 环境实测证据

```bash
$ uname -a
Linux da6e78bb42bb 6.6.117-45.11.3.tl4.x86_64 #1 SMP Thu Jun 18 20:26:53 CST 2026 x86_64 GNU/Linux
$ for t in xcodebuild swiftc swift xcrun simctl; do command -v "$t" || echo NOT\ FOUND; done
xcodebuild -> NOT FOUND    swiftc -> NOT FOUND    swift -> NOT FOUND
xcrun      -> NOT FOUND    simctl -> NOT FOUND
```

### 0.2 能力边界（本报告的效力上限）

当前沙箱为 **Ubuntu 22.04 / Linux，无 Xcode、无 swiftc、无 xcodebuild、无 iOS Simulator**。因此：

| 事项 | 本环境能否执行 |
| --- | --- |
| `xcodebuild` 编译 / 链接 / 类型检查 | ❌ 无法执行 |
| XCTest 单元测试（F60–F64） | ❌ 无法执行 |
| XCUITest UI 测试（F65） | ❌ 无法执行 |
| 真机后台 30 min / HealthKit / iOS 26 双路径 | ❌ 无法执行 |
| IPA 生成 / 签名 / 侧载安装 | ❌ 无法执行 |
| GitHub Actions workflow 运行 | ❌ 无法执行 |
| 静态核查、语法/格式解析、符号与引用比对、脚本 `bash -n` | ✅ 可执行 |

**本报告中所有 `PASS` 均仅表示「静态检查 / 本地格式与引用校验通过」，绝不代表编译通过、测试通过、构建成功或 IPA 可用。** 报告刻意未给出任何「通过率」「构建成功」「用例全绿」类表述。

> **测试通过率：`N/A（本环境未执行，最终以 GitHub Actions 为准）`**

### 0.3 职责边界

本轮 QA **未修改任何 App 源码、`project.pbxproj`、`.xcscheme`、`.xcconfig`、CI workflow、脚本或资源文件**；仅新增本审查报告 `docs/05-QA-Report.md`（`docs/` 不计入 74 文件交付口径）。所有缺陷均以「证据 + 修复建议」形式报出，交由主理人转工程师处理。

---

## 1. 测试执行状态表（12 类逐项）

静态清点基线：6 个测试文件、**49 个 `func test...` 测试方法**、**481 次 `XCTAssert*` 调用**（脚本逐文件统计，见附录命令 C16）。CI 侧 `build-test` job 含 `clean build` / `xcodebuild test` / F70 `archive` 三步（`.github/workflows/ios-build.yml:159-209`）。

| # | 测试类别 | 覆盖位置（静态清点） | 本环境是否执行 | 结果 | 性质判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | 轨迹连续性 | F60 `testTrackPointContinuity`（`SimulationEngineTests.swift:58`）、`testLongRunPerformance` 时间戳断言（`:243-245`）、F61 I1–I10 | ❌ 未执行 | 未执行 | **逻辑层覆盖**；断言存在，运行时结果未知 |
| 2 | 距离准确性 | F60 `testDistanceAccuracy`（`:91`）、F61 不变量校验 | ❌ 未执行 | 未执行 | **逻辑层覆盖** |
| 3 | 步频步幅一致性 | F60 `testStrideDerivedFromSpeedAndCadence`（`:127`）、F61 I7（`L=60v/c`） | ❌ 未执行 | 未执行 | **逻辑层覆盖** |
| 4 | 配速 | F60 `testPaceCalculation`（`:158`）、`testUnitConversions`（`:354`） | ❌ 未执行 | 未执行 | **逻辑层覆盖** |
| 5 | 海拔 | F60 `testElevationGainLossDeadband`（`:189`）、F62 `testMissingEleDoesNotFabricate`（`CodecTests.swift:344`） | ❌ 未执行 | 未执行 | **逻辑层覆盖**（真机气压计 / CMAltimeter 不在覆盖内） |
| 6 | 长时间模拟 | F60 `testLongRunPerformance`（`:214`，1800 s / 1 Hz = 1801 帧 + 耗时 <20 s + 内存 <20 MB） | ❌ 未执行 | 未执行 | **逻辑层覆盖（纯计算）**；测试自身注释写明「真机内存峰值仍需 Instruments 人工验收」（`:242`） |
| 7 | 后台 | F60 `testBackgroundConfigurationConstants`（`:251`，仅校验 `UIBackgroundModes` / 5 个用途描述 / `backgroundPaused` 常量 / `isPaused` 标记） | ❌ 未执行 | 未执行 | **仅常量与纯逻辑覆盖**；测试注释明确「真机后台 30 min 连续记录 AC-F5 需人工验收，本地 Linux 未执行」（`:252-253`）→ **必须真机** |
| 8 | 中断恢复 | F64 `testTrackFilterGapCreatesNewSegment`（`RepositoryIsolationTests.swift:360`）、`testCheckpointSerializationAndRestore`（`:442`）、`testSparseIntervalNotInterpolated`（`:511`） | ❌ 未执行 | 未执行 | **逻辑层覆盖（checkpoint 序列化/还原、segment 新建）**；**强杀后进程级恢复必须真机** |
| 9 | GPX 往返 | F62 `testGPXRoundTrip`（`:106`）、`testJSONRoundTrip`（`:155`）、`testCSVExportColumnsAndMarkers`（`:186`）、`testSampleLoopMarkersAndMultiSegment`（`:317`）、`testOnlyRteCompatible`（`:370`）、`testInvalidVersionRejected`（`:382`） | ❌ 未执行 | 未执行 | **逻辑层覆盖**；**系统文件面板 GPX 真机导入必须人工**（另见风险 R3：Fixtures 资源链路） |
| 10 | SwiftData | F64 `testSeparateStores`（`:103`）、`testCRUDInMemoryContainers`（`:143`）、`testIDSpacesDisjoint`（`:122`）、`testOriginImmutable`（`:238`） | ❌ 未执行 | 未执行 | **逻辑层覆盖（in-memory 容器）**；持久化磁盘容器 / 迁移必须真机或 CI |
| 11 | UI 交互 | F65 `testOriginBadgeOnAllSevenPages`（`:76`）、`testNoMixedOriginList`（`:107`）、`testAccessibilityLabels`（`:125`）、`testPrimaryTabButtonsNavigate`（`:155`）、`testNoForbiddenButtons`（`:190`） | ❌ 未执行 | 未执行 | **XCUITest**；CI 中默认关闭（`ios-build.yml:191` `if: workflow_dispatch && inputs.runUITests`）→ **必须 CI 手动开启或人工** |
| 12 | Xcode 编译 | CI `xcodebuild ... clean build`（`:159-173`）、`xcodebuild test`（`:175-188`）、F70 `archive`（脚本 `:79-90`）；scheme 含 3 个 BuildActionEntry + 2 个 TestableReference | ❌ 未执行 | 未执行 | **仅能在 macOS Runner / CI 执行**；本环境无编译器 |

**汇总：12 类全部「本环境未执行」。** 静态层面 12 类均可找到对应断言或 CI 步骤，但其中 **#7 后台、#8 强杀恢复、#10 持久化、#11 UI、#12 编译、#5 真机海拔、#9 真机导入** 的性质决定其不能由逻辑层用例替代。

> **测试通过率：`N/A（本环境未执行，最终以 GitHub Actions 为准）`**

---

## 2. 静态核查结果表

| 项 | 核查内容 | 结论 | 实际执行的命令 / 脚本 | 证据（行号 / 计数） |
| --- | --- | --- | --- | --- |
| A1-1 | 74 文件齐全性、路径精确性 | **PASS** | Python 正则从 `docs/02-Architecture.md` §2.2 表格提取 `\| F\d{2} \| \`path\` \|`，与 `os.walk` 实际文件集做差集 | F01–F74 连续无缺失/重复；期望 74 = 实际 74（排除 `docs/` 5 个上游文档）；**精确路径匹配 74/74** |
| A1-2 | 多余 / 空文件 | **PASS** | 同上差集 + `find . -type f -size 0` | 多余 0、缺失 0、零字节 0；工作区文件总数 79 = 74 交付 + 5 docs |
| A1-3 | Swift 规模口径 | **PASS** | `find . -name '*.swift' \| wc -l`、`xargs cat \| wc -l` | 58 个 Swift 文件 / 22,230 行，与任务书一致 |
| A2-1 | pbxproj 24 位 hex ID 定义/引用 | **PASS** | Python 逐行区分「定义行 ID」与「全部引用 token」 | 定义对象 **41**、唯一 ID **41**、**悬空引用 0**、孤立定义 0 |
| A2-2 | 对象计数 | **PASS** | Python `isa` 计数 | PBXNativeTarget **3**、PBXFileSystemSynchronizedRootGroup **3**、ExceptionSet **3**、Sources/Frameworks/Resources BuildPhase 各 3（共 9）、XCConfigurationList **4**、XCBuildConfiguration **8**、`baseConfigurationReference` **8** |
| A2-3 | 关键键 | **PASS** | Python 正则 | `objectVersion=77` ✓；`compatibilityVersion="Xcode 16"` ✓；`preferredProjectObjectVersion=77` ✓；`rootObject=1A…0001` 有定义 ✓；`INFOPLIST_FILE` 2 处（App Debug/Release）、`GENERATE_INFOPLIST_FILE` 6 处（App=NO×2、Tests=YES×4）、`CODE_SIGN_ENTITLEMENTS` 2 处（值一致） |
| A2-4 | 同步根组例外 | **PASS（配置层面）** | Read pbxproj `:56-116` | `2B…0001.membershipExceptions = ("Resources/Info.plist", "Resources/CampusRunSimulator.entitlements")`；`Assets.xcassets` 未被排除（保留编译）✓；G_TEST / G_UITEST 例外为空（见风险 R3） |
| A2-5 | shared scheme 一致性 | **PASS** | Python XML 解析 + 逐项比对 pbxproj | 3 个 `BuildableReference` 的 `BlueprintIdentifier` = `3A…0001/0002/0003`，`BlueprintName` = 3 个 target `name`，`BuildableName` = 3 个 `PBXFileReference.path`，全部一一对应；`TestAction` 含 2 个 `TestableReference`（UnitTests + UITests）；`ArchiveAction buildConfiguration=Release`；`allowLocationSimulation="NO"` |
| A3-1 | 括号/圆括号/方括号/引号平衡 | **PASS** | Python 逐文件词法状态机（跳过 `//`、`/* */` 含嵌套、`"..."`、`"""..."""`，带栈匹配） | 58/58 文件，异常文件 0、异常项 0 |
| A3-2 | `import` 系统框架 iOS 17 可用性 | **PASS** | `grep -rhoE '^import \w+'` 去重计数 | 14 个框架：Foundation(53)、SwiftUI(17)、Observation(9)、SwiftData(8)、XCTest(6)、MapKit(6)、UIKit(5)、CoreLocation(3)、UniformTypeIdentifiers(2)、QuartzCore/OSLog/HealthKit/CoreMotion/Charts(各 1)。**全部为 Apple 系统框架且 iOS 17 可用**（Observation / SwiftData / MapKit SwiftUI `Map` 均 iOS 17 起）；无第三方 import |
| A3-3 | 占位/危险代码 | **PASS（1 处需说明）** | grep + Python 空函数体正则 | `TODO`/`FIXME` **0**、`fatalError()` **0**、`XCTAssertTrue(true)` **0**、`precondition/assert(false)` **0**；空函数体命中 7 处，经 Read `RepositoryIsolationTests.swift:561-586` 人工甄别，全部是 `StubLocationProvider` / `StubMotionProvider` 的**合法测试桩空实现**，非缺陷 |
| A4-1 | 类型定义与疑似未定义符号 | **PASS（确证缺失 0）** | Python：提取 `struct\|class\|enum\|protocol\|actor\|extension\|typealias` 定义 → 剥离注释/字符串后扫大写标识符 → 系统类型白名单过滤 | 唯一类型名 **241**、定义/extension 条目 **247**；疑似符号 67 个，人工甄别全部为系统框架类型（`Stepper`/`GridItem`/`JSONSerialization`/`HKWorkoutBuilder`/`SpatialTapGesture`…）、import 名、`I1`–`I10` 枚举 case、泛型占位（`Self`/`Content`/`Type`/`ID`）；**确证缺失 0** |
| A4-2 | 测试引用的自定义 API | **PASS** | Python：6 个测试文件引用的大写标识符 ∩ 定义集合 | 测试引用 **63 个**项目自定义类型，**全部有对应定义**；剩余 8 个「疑似」为 `Any`/`I5`/`I7`/`JSONDecoder`/`JSONEncoder`/`ModelContext`/`NSPredicate`/`Type`，均为系统类型或泛型 → **确证缺失 0**（任务书所称「29 个 API」为其中关键子集，已含在内） |
| A4-3 | 7 页面无参构造 ↔ RootView | **PASS** | grep `init(` / `struct X: View` / RootView 构造调用 | 7 个页面 struct 各自含 `public init() {}`（`HomeView:27`、`RoutePlanningView:55`、`SimulationView:66`、`LiveRunView:57`、`AnalyticsView:45`、`HistoryView:55`、`SettingsView:166`）；`RootView.swift:133/141/146/151/334-346` 均为无参构造 `XxxView()` → 一致 |
| A4-4 | F45 玻璃入口唯一 | **PASS** | Python 全仓扫描 | `func glassCard` 定义 **1** 次（`GlassModifier.swift:172`）；`.glassEffect(` 仅 2 处且均在 `GlassModifier.swift:101,107`；`GlassEffectContainer` 仅 `:97`；全仓 `glassCard(` 调用 **72** 处，无第二入口 |
| A5-1 | Shell 语法 | **PASS** | `bash -n ci/scripts/build_unsigned_ipa.sh` | exit 0 |
| A5-2 | plist 解析 | **PASS** | Python `plistlib.load` | `Info.plist` 23 键、`CampusRunSimulator.entitlements` 2 键（healthkit + background-delivery）、`ci/ExportOptions.plist` 10 键，均可解析 |
| A5-3 | 3 个 GPX XML 解析 | **PASS** | Python `xml.etree.ElementTree` | `SIMULATED_sample_loop.gpx`：GPX 1.1 命名空间、trk 1 / trkseg 2 / trkpt 8 / ele 9 / wpt 1；`sample_missing_ele.gpx`：trkpt 6 / **ele 0**；`sample_only_rte.gpx`：**trk 0** / rte 1 / rtept 5 / wpt 2。三份均合法且与 F66–F68 设计一致 |
| A5-4 | workflow YAML 解析 | **PASS** | Python `yaml.safe_load`（PyYAML 6.0.3） | 顶层键 `name / on / permissions / concurrency / env / jobs`；`on` 被 PyYAML 1.1 解析为 `True`（已知 YAML 1.1 行为，非文件错误）；jobs = `build-test, signed-ipa, release`；`permissions: contents: write` |
| A6-1 | 网络上传成绩 | **PASS** | `grep -RInE 'URLSession\|URLRequest\|uploadTask\|dataTask(\|NSURLConnection' --include='*.swift'` | **0 处**；`ExportManager` 无网络上传方法 |
| A6-2 | `simulated→real` 转换路径 | **PASS** | grep 转换函数 / 赋值 | 无 `toReal\|convertToReal\|makeReal\|promoteToReal\|convertOrigin`；`self.dataOrigin = .real` 仅 2 处（`SensorContracts.swift:32,82`，初始化器强制 REAL，合法）；`DataMarker.swift:128` 三元式经 Read 确认为「校验文件名不得带**另一来源**前缀」，非转换逻辑 |
| A6-3 | 硬编码证书/私钥/Profile | **PASS** | `grep -RInE -e '-----BEGIN (CERTIFICATE\|…PRIVATE KEY)-----'`（修正 `-e` 后重跑） | **0 处**；`ci/ExportOptions.plist:19/21/25/29` 全为 `${…}` 占位符；`.p12`/`.mobileprovision` 仅出现在 workflow 的 `runner.temp` 运行时路径与注释中 |
| A6-4 | HealthKitService.write 的 `guard .real` | **PASS** | grep + Read `HealthKitService.swift:104-129` | `write(session:routePoints:)` 函数体首条语句即 `guard session.dataOrigin == .real else { throw AppError.simulatedWriteForbidden }`（`:107-115`）；另有 `routePoints.allSatisfy { $0.dataOrigin == .real }` 二次守卫（`:120`） |
| A6-5 | RuleEvaluator 的 `guard .simulated` | **PASS** | grep `RuleEvaluator.swift:92-106` | `evaluate` 前置 `guard session.dataOrigin == .simulated`（`:97`）；并对每个 preset `guard preset.isHypothetical, preset.dataOrigin == .simulated`（`:105`） |
| A6-6 | 规则结果无 score 字段 | **PASS** | Read `Reports.swift:135-159` | `RuleEvaluationResult` 9 个字段：`presetId / displayName / sessionId / dataOrigin / conditionResults / overallOutcome / disclaimer / notice / evaluatedAt`，**无 score**；F63 `testNoScoreInResult`（`:140`）用 `Mirror` 反射断言 |
| A6-7 | 三重标记齐全 | **PASS** | grep `DataMarker.swift` | `fileName`(`:67`) / `metadataBlock`(`:72`) / `firstLineComment`(`:91`) / `jsonTopLevel`(`:106`) / `verifyFileName`+`verifyMarkers`(`:123,135`) 齐备；`MarkerMetadata` 含 `dataOrigin / isHypothetical / disclaimer / generator / schemaVersion` 及 `hasCompleteUIBadge` |
| A6-8 | 「全部记录」混排成绩单 | **PASS** | grep `全部记录\|allRecords\|混排` | 仅出现**禁止性**文案与 `AppError.mixedOriginExportForbidden`；`HistoryView.swift:22,147,379,484`、`AnalyticsView.swift:360,713` 明确「默认两分区、禁止全部记录混排」；导出侧 `GPXCodec:54`、`TabularCodec:50,96,150,167`、`ExportManager:101-103` 混合来源直接抛错 |
| A7 | 12 类测试覆盖 | **PASS（静态存在性）** | 逐文件 `grep '^\s*func test'` + `XCTAssert*` 计数 + workflow 步骤比对 | 49 个测试方法 / 481 次断言；详见第 1 节。**注意：静态存在 ≠ 执行通过** |

---

## 3. 编译风险清单（任务 B · 本报告最高价值产出）

> 分级定义：**阻断编译** = 编译器必然/条件性报错；**功能缺陷** = 能编译但产物或链路不符合预期；**优化建议** = 需 Xcode 实机验证或工程一致性改进。
> 全部条目的「文件:行号」均为本次实测定位。

### 3.1 【阻断编译】

#### R1 · Liquid Glass `.interactive(_:)` 的 API 归属错误 — 条件性阻断（Xcode 26 / Swift 6.2 下必现）

- **文件:行号**：`CampusRunSimulator/UI/Theme/GlassModifier.swift:102`、`:109`
- **具体依据**：
  - 代码为 `.glassEffect(.regular, in: Capsule()).interactive(interactive)`，即把 `interactive` 当作 **View 修饰符**链式作用于 `some View`。
  - Apple 官方文档核实（`https://developer.apple.com/documentation/swiftui/glass`）：`Glass` 结构体的 Instance Methods 为 `func interactive(Bool) -> Glass` 与 `func tint(Color?) -> Glass`，静态属性为 `.regular / .clear / .identity`；**不存在 `View.interactive(_:)` 修饰符**。`glassEffect(_:in:)` 文档（`https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)`）与官方示例一致写作 `.glassEffect(.regular.interactive())` / `.glassEffect(.regular.tint(.orange).interactive())`。
  - 因此 `.interactive(interactive)` 作用在 `some View` 上会触发 `Value of type 'some View' has no member 'interactive'`（或类似）编译错误。
  - 触发条件：`GlassModifier.swift:84` 的 `#if compiler(>=6.2)` 在 **Xcode 26（Swift 6.2）** 为真（Swift 版本对应实测：Xcode 16.0→Swift 6.0、16.3→6.1、16.4→6.1.2；Xcode 26.0→Swift 6.2，来源 `swiftly.dev/swift-versions`），此段才参与编译；Xcode 16 全系为假、整段被排除，故**不会**在 Xcode 16 SDK 下报错。
  - **CI 恰好会选中 Xcode 26**：`.github/workflows/ios-build.yml:77` 用 `ls -d /Applications/Xcode_*.app | sort -V | tail -1` 主动选择 Runner 上**最高**版本 Xcode；`macos-15` image 若已含 Xcode 26，R1 立即触发，`clean build`（`:159`）失败 → 后续测试 / IPA / Release 全链路中断。
- **其余 3 个 API 名称核实为正确**：`GlassEffectContainer(spacing:)`（官方 `init(spacing: CGFloat?, content:)`，`GlassModifier.swift:97` ✓）、`.glassEffect(.regular, in: Capsule())`（官方 `nonisolated func glassEffect(_ glass: Glass = .regular, in shape: some Shape) -> some View`，`:101,107` ✓）、`.glassEffectID(role.rawValue, in: glassNamespace)`（官方 `func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID)`，`@Namespace` wrappedValue 即 `Namespace.ID`，`:108` ✓）。
- **修复建议**：把两处改为把 `interactive` 作用在 `Glass` 值上，并从 View 链上移除：
  ```swift
  content
      .padding(role.spacing)
      .glassEffect(.regular.interactive(interactive), in: Capsule())
      // reduceMotion 分支另加 .transition(.opacity)
  ```
  非 reduceMotion 分支同理；`interactive` 参数可保留 `Bool`。同时建议在 `README`/CI 增加 Xcode 26 一次真实编译验证（本环境无法执行）。

#### R2 · `@available(iOS 26, *)` × `#if compiler(>=6.2)` 组合是否导致 Xcode 16 编译失败 — **结论：不会（设计正确，予以确认）**

- **文件:行号**：`GlassModifier.swift:84-115`（`#if` 包裹 `GlassEffectPath`）、`:87`、`:173-181`（调用点同被 `#if` 包裹）、`:186-193`、`:188`；`AppTheme.swift:87`（`if #available(iOS 26, *)` 运行时检查）
- **依据**：全仓 `@available` / `#available` 仅 5 处（grep 实测），iOS 26 符号全部位于 `#if compiler(>=6.2)` 条件编译块内；Swift 条件编译块在条件为假时不参与类型检查。Xcode 16（Swift 6.0/6.1）下该块整体被排除，只保留 `FallbackGlassPath`，因此 **Xcode 16 SDK 下不会因 iOS 26 专用 API 报错，也不会出现「未加 @available 的 iOS 18/26 专用 API 散落」**。
- **但需明确责任的转移**：保护是「编译期跳过」，不是「API 正确」。真正的风险被推到 Xcode 26（见 R1）。另外 Apple 社区已指出 `#if compiler(>=6.2)` 是拿编译器版本当 SDK 版本的近似替代（Swift Forums / Ole Begemann 讨论），若未来出现「Swift 6.2 编译器 + 旧 iOS SDK」的组合，该近似会失效——属长期维护风险，非本次阻断。

### 3.2 【功能缺陷】

#### R3 · F62 的 3 个 GPX Fixtures 资源链路未闭环，可能导致 CI 单元测试整体失败

- **文件:行号**：`CampusRunSimulatorTests/CodecTests.swift:81-101`（`loadFixture`）；`CampusRunSimulator.xcodeproj/project.pbxproj:65-70`（G_TEST 的 `2B…0002`，`membershipExceptions = ()` 为空）、`:288-294`（`PBXResourcesBuildPhase.files = ()` 为空）；`.github/workflows/ios-build.yml:175-188`（`-only-testing:CampusRunSimulatorTests`）
- **具体依据**：
  - `loadFixture` 三级定位：① `Bundle(for: CodecTests.self).url(forResource:)` ② 同 bundle `subdirectory: "Fixtures"` ③ `#filePath` 删两级 + `CampusRunSimulatorTests/Fixtures/<name>.gpx`（`:91-96`），任一 `FileManager.fileExists` 失败即 `XCTFail`（`:100`）。
  - ① ② 成立的前提是 3 个 `.gpx` 被拷入 test bundle。但 pbxproj 中 G_TEST 的 exception set `membershipExceptions` 为空、`PBXResourcesBuildPhase.files = ()` 为空（同步根组模式按设计如此，架构 §1.7.3 声称「Xcode 16 同步组会把非源码文件自动 copy 进 test bundle」）——**该行为无法静态证明**，`.gpx` 属非标准资源扩展名，Xcode 16 是否自动纳入 Copy Bundle Resources 需实机验证。
  - ③ 兜底在 **`xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 16'`** 下大概率失效：`#filePath` 是**编译机 macOS 绝对路径**字面量，而单元测试进程运行在 **iOS Simulator 的独立文件系统**中，无法访问 macOS 主机路径（`/Users/runner/...`）；`FileManager.fileExists` 将返回 false。
  - 一旦 ①② 未生效，`CodecTests` 中依赖 fixture 的 `testSampleLoopMarkersAndMultiSegment` / `testMissingEleDoesNotFabricate` / `testOnlyRteCompatible` / `testGPXRoundTrip` 等至少 4 个用例会 `XCTFail` → `xcodebuild test` 非零退出 → `build-test` job 失败 → 未签名 IPA artifact 不上传 → Release 链路全断。
  - 对照：`SimulationEngineTests.swift:370-395` 的 `loadInfoPlist` 首级取 `Bundle.main`（`TEST_HOST` 已配置，宿主 App bundle 内必有 Info.plist），该测试不受影响；风险仅集中在 F62 的 `.gpx`。
- **修复建议**（三选一，建议同时做 a + c）：
  a. 在 `project.pbxproj` 中为 `2B…0002`（及 G_UITEST）显式把 3 个 `.gpx` 加入该 target 的 `PBXResourcesBuildPhase.files`（`PBXBuildFile` + `PBXFileReference`），或改用 Xcode 16 同步组的 `PBXFileSystemSynchronizedBuildFileExceptionSet` 正确声明资源归属；不要依赖「自动识别未知扩展名」。
  b. 把 3 份 fixture 内容内嵌为 Swift 字符串常量 / Base64（测试自包含，彻底摆脱 bundle 资源与 `#filePath`）。
  c. 在 CI `xcodebuild test` 之前增加一步校验 test bundle 内确实含 `.gpx`（例如 `find DerivedData -name '*.gpx' -path '*CampusRunSimulatorTests*'`），失败即早停并给出明确诊断，避免以「测试失败」形式隐性暴露。

#### R4 · 签名路径 B 的 `archive` 未覆盖全局 `CODE_SIGNING_ALLOWED=NO`，产出很可能仍是未签名 archive

- **文件:行号**：`Config/App.xcconfig:21-22`、`CampusRunSimulator.xcodeproj/project.pbxproj:405-406 / 442-443 / 478-479 / 514-515 / 547-548 / 581-582`（8 份 XCBuildConfiguration 全部 `CODE_SIGNING_ALLOWED = NO; CODE_SIGNING_REQUIRED = NO;`）；`.github/workflows/ios-build.yml:378-395`（路径 B `archive` 步骤名却写「正常签名，不关闭 CODE_SIGNING_ALLOWED」）
- **具体依据**：路径 B 的 `xcodebuild ... clean archive` 只传 `CODE_SIGN_STYLE=Manual`、`DEVELOPMENT_TEAM`、`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`（`:390-394`），**没有任何 `CODE_SIGNING_ALLOWED=YES` / `CODE_SIGNING_REQUIRED=YES` 覆盖**。由于 xcconfig 与 8 份 target/project 配置均把签名关闭写死，命令行未覆盖时该值保持 `NO`，仅指定 Manual 签名样式与 Team 无法开启签名；随后的 `xcodebuild -exportArchive`（`:397-405`）将因 archive 无签名而失败，或产出与路径 A 无实质差别的产物——与 workflow 第 8 行「绝不回退到未签名产物冒充已签名 IPA」的承诺相悖。
  （对照：路径 A 的 `clean build`（`:170`）与 F70 脚本（`:85-88`）都显式传 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""`，唯独路径 B 遗漏反向覆盖。）
- **修复建议**：路径 B 的 `archive` 与 `-exportArchive` 均显式追加 `CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`；或把全局 `NO` 从 xcconfig/pbxproj 中移除，改由两条路径各自在命令行注入（路径 A 仍传 NO、路径 B 传 YES），避免「默认关闭」污染已签名路径。同时把步骤名改为与实参一致。

#### R5 · `GITHUB_TOKEN` 推送的 tag 不会触发新 workflow run — 直接约束任务 C 的修复方案

- **依据**（`docs.github.com` 官方，已联网核实）：「使用仓库的 `GITHUB_TOKEN` 执行任务时，`GITHUB_TOKEN` 触发的事件（`workflow_dispatch` / `repository_dispatch` 除外）**不会创建新的工作流运行**……这可以防止意外创建递归工作流程运行。」
- **影响**：任务书建议方向中「auto-tag job 用 `GITHUB_TOKEN` 推 tag → `tag push` 事件再触发 `release` job」这一环，在**默认 `GITHUB_TOKEN` 下不成立**：tag 会被创建，但 `on.push.tags: ['v*']` 不会被触发，`release` job 仍不会执行。这不是推测，而是 GitHub 平台既定行为。
- **修复方向**：见第 4 节方案 A（**同一次 run 内闭环 release**，不依赖二次触发）或方案 A′（改用 PAT / GitHub App 安装令牌推送 tag）。

### 3.3 【优化建议 / 需 Xcode 实机验证】

| 编号 | 风险 | 文件:行号 | 依据与建议 |
| --- | --- | --- | --- |
| R6 | UITests target 缺 `TEST_HOST` / `BUNDLE_LOADER` | `project.pbxproj:542-607`（`6A…0007/0008`）；架构 `docs/02-Architecture.md:299` | UnitTests 有 `TEST_HOST`(`:503,536`)/`BUNDLE_LOADER`/`TEST_TARGET_NAME`/`GENERATE_INFOPLIST_FILE=YES`（配置完整，`@testable import` 可用）；UITests 仅有 `TEST_TARGET_NAME = CampusRunSimulator` + `PBXTargetDependency`(`:222-224`) + `PBXContainerItemProxy`(`:17-23`)。**UI test bundle 按 Apple 规范本就不需要 TEST_HOST/BUNDLE_LOADER**（独立进程经 `XCUIApplication()` 启动宿主 App），故此条**不判为缺陷**；但架构 §1.7.5 把两类测试混写为「测试 target 额外」属文档表述歧义，建议澄清，并在 Xcode 上实机确认 UI test 能启动 App。 |
| R7 | SwiftData 关系反向推断歧义 | `PersistedModels.swift:36,179`（`@Relationship(deleteRule: .cascade)`）、10 个 `@Model` 类 | 多 `@Model` 互引时 SwiftData 可能出现 inverse 推断歧义（编译 warning 或运行时 `SwiftData` 崩溃）。本环境无法编译/运行；建议在 CI `xcodebuild test` 后检查日志中的 SwiftData 警告，并在真机跑一次 `makePersistent()` 双容器落盘。 |
| R8 | CI Xcode 动态选择稳健性 | `.github/workflows/ios-build.yml:77`（`sort -V`）、`:82-85`（变量覆盖） | ① `sort -V` 为 GNU coreutils 选项，macOS BSD `sort` 是否完整支持需 Runner 实机验证；建议改为 `ls -d ... | sort -t_ -k2,2V` 前先探测，或直接用 `xcode-select -p` + 白名单。② 当仓库变量 `XCODE_VERSION` 设为不存在版本时，`:83` 直接拼路径并 `xcode-select -s`，未 `test -d` 校验，会给出难以定位的失败；建议加 `[[ -d "${XCODE_APP}" ]] || exit 1`。③ 与 R1 联动：选到 Xcode 26 即触发 Liquid Glass 路径，建议 CI 明确固定已验证的 Xcode 版本。 |
| R9 | F70 在 macOS `/bin/bash` 3.2 下的空数组展开 | `ci/scripts/build_unsigned_ipa.sh:63-72, 89` | `set -u` 下 `"${version_overrides[@]}"` 对空数组在 bash 3.2 有 `unbound variable` 的历史行为差异；CI 注入了 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 通常非空，但本地直跑脚本时可能触发。建议改为 `if (( ${#version_overrides[@]} )); then … "${version_overrides[@]}" …; else …; fi` 两分支，或 `xcodebuild ... ${version_overrides[@]+"${version_overrides[@]}"}`。 |
| R10 | 同步根组内 `Info.plist` 例外处理 | `project.pbxproj:56-64`、`Config/App.xcconfig:20`、`project.pbxproj:414-415 / 450-451` | 配置层面**正确**：`membershipExceptions` 明确排除 `Resources/Info.plist` 与 `.entitlements`（避免被当资源复制/重复拷贝），`GENERATE_INFOPLIST_FILE = NO` 与 `INFOPLIST_FILE` 在 App Debug/Release 成对出现，`Assets.xcassets` 保留在同步组内由 `PBXResourcesBuildPhase` 编入 asset catalog，`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 与 F07 对应。但 Xcode 16 同步组对 `INFOPLIST_FILE` 指向文件是否还有隐式处理、以及 `.xcassets/Contents.json` 是否被单独 copy，**需 Xcode 16 实机验证**（本环境不能替代）。 |
| R11 | `PRODUCT_BUNDLE_IDENTIFIER` 与架构示例不一致 | `Config/App.xcconfig:16`、`project.pbxproj:423,458` = `com.campusrun.simulator`；`docs/02-Architecture.md:286` 示例 `edu.research.campusrun.simulator` | 工程内部一致：workflow `:370` 的 `provisioningProfiles:com.campusrun.simulator` 与 pbxproj 匹配 ✓，非缺陷。架构自称「示例值」，建议在 §1.7.5 加注「以 xcconfig 实际值为准」，避免后续按示例填 profile 键导致签名失败。 |
| R12 | 并发模型静态粗检结论 | 全仓：7 个 `actor`、`await` 198 次、`Task {` 66 处、`async` 104 处、`@MainActor` 多处（`RootView.swift:107`、`ReplayController.swift:10`、7 页 ViewModel 等） | 抽查测试与业务调用（如 `RepositoryIsolationTests.swift:147-194` 的 `await repository.save/fetch/points`、`SimulationEngineTests.swift:232` 的 `await engine.preview`）**均带 `await`**；`AsyncStream.makeStream` 的 `yield`/`finish` 配对出现（`LocationProvider.swift:52-57,75-76,138-139,173,179`；`MotionProvider.swift:43-50,117,200`），`withCheckedThrowingContinuation` 在 HealthKitService 中均有 `resume`（`:34,57,199,225,240,254,269,283`）。`SWIFT_VERSION=5.0` + `SWIFT_STRICT_CONCURRENCY=complete` 下 Swift 5 模式并发违规多为 warning 而非 error，故不判阻断；**仍需 Xcode 实机确认 `Sendable` 一致性与 `@MainActor` 隔离**。 |
| R13 | MapKit SwiftUI / Swift Charts / SwiftData API 名称与 iOS 17 可用性 | `RouteMapView.swift:38,69,70,72,175`；`Charts.swift:87,92,98,105,116,305,308,313,319`；`PersistedModels.swift:13,15,36` | 静态核对：`Map` / `MapReader` / `MapPolyline` / `MapCameraPosition` / `MapStyle`（iOS 17+）、`Chart` / `LineMark` / `AreaMark` / `RuleMark`（Charts iOS 16+）、`@Model` / `@Attribute(.unique)` / `@Relationship`（SwiftData iOS 17+）**名称均为官方且部署目标 iOS 17 内可用**，未发现未加门控的 iOS 18/26 专用 API 散落（全仓 `@available`/`#available` 仅 5 处，见 R2）。`SpatialTapGesture`（`RouteMapView.swift:86`）为 iOS 17 引入，建议实机确认可用性。 |

---

## 4. GitHub 交付链路结论（任务 C）

### 4.1 判定：**P0 阻断交付缺陷**

> **在「仅推送代码到 `main`、无任何人工打 tag、无任何外部触发」的前提下，本 workflow 不能自动产出 `v*` Tag，不能创建 GitHub Release，也不能上传真实 IPA。**

### 4.2 证据链（全部为实测）

1. `on.push` 同时声明 `branches: [main]` 与 `tags: ['v*']`（`.github/workflows/ios-build.yml:17-20`）——`tags` 是**被动触发器**，必须已有 tag 被 push 才会触发，不会凭空造 tag。
2. `release` job 的准入条件是 `if: ${{ startsWith(github.ref, 'refs/tags/v') }}`（`:454`）。仅 push main 时 `github.ref = refs/heads/main` → 条件为 **false** → `release` job 及其全部步骤（下载 IPA artifact、打包源码、生成说明、`softprops/action-gh-release` 上传 IPA）被跳过。
3. 全 workflow **没有任何创建 / 推送 tag 的执行步骤**：`grep -nE 'git tag|git push|push --tags|gh release create|create_tag'` 仅命中 5 处，全部是「读取」而非「写入」——`:147,321` 从 `GITHUB_REF` 解析版本号、`:454` 判断 tag 前缀、`:523` 把已有 `github.ref_name` 传给 `tag_name`。无 `git tag`、无 `git push --tags`、无 auto-tag Action。
4. 主理人可用的 GitHub MCP 工具集（`create_repository` / `push_files` / `create_or_update_file` / `create_branch` / `get_tag` / `list_tags` / `list_releases` / `get_release_by_tag` / `get_latest_release`）**不含创建 git tag、创建 Release、触发 `workflow_dispatch`**；`gh` CLI 在本沙箱未登录。因此「由外部补一个 tag」这条退路在现有工具链下也走不通。
5. 结论：`build-test` 会成功产出未签名 IPA 并上传 artifact（`upload-artifact@v4`，`:219-225`，`retention-days: 14`），但 **artifact 只停留在 Actions 临时存储，14 天后过期**；仓库永远没有 `v*` Tag，永远没有 Release，外部拿不到 IPA。
6. 附带确认（非缺陷）：`release` job 的 `needs: [build-test]`（`:455`）、`actions/download-artifact@v4` 的 `name: CampusRunSimulator-unsigned-ipa`（`:468`）与 `upload-artifact` 的 `name: ${{ env.ARTIFACT_NAME }}`（`:222`，`env.ARTIFACT_NAME = CampusRunSimulator-unsigned-ipa`，`:55`）**完全一致，同一 run 内 artifact 传递链路本身是通的**；`permissions: contents: write`（`:44-45` 顶层、`:457-458` job 级）齐全；`softprops/action-gh-release@v2` + `GITHUB_TOKEN`（`:520-533`）齐全。**缺的只是「触发条件」这一环**。

### 4.3 修复方案 A（推荐）：新增 `auto-tag` job，并在**同一次 run 内**闭环 `release`

> 关键点：因 R5（GitHub 官方限制），**不能依赖「推 tag → 触发新 run → release」**，必须让 `release` 直接挂在 `auto-tag` 之后、用 `needs` 与 outputs 传递 tag 名；`GITHUB_TOKEN` 推 tag 不触发二次 run 反而成为天然的防循环保障。

```yaml
  # ===== 新增 job：首次成功构建后创建轻量 tag v0.1.0 =====
  auto-tag:
    name: 首次成功构建后创建 v0.1.0 轻量 tag
    needs: [build-test]
    # 触发条件：仅 main 分支的 push 且构建成功。
    # 防循环①：tag push 时 github.ref = refs/tags/*，不满足本条件；
    # 防循环②：GITHUB_TOKEN 推 tag 按 GitHub 官方规定不会创建新 run。
    if: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.build-test.result == 'success' }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    outputs:
      tag: ${{ steps.mk.outputs.tag }}
      created: ${{ steps.mk.outputs.created }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0                       # 必须：否则 git rev-parse 查不到远端已有 tag
          token: ${{ secrets.GITHUB_TOKEN }}
      - name: 幂等判断 → 创建并推送轻量 tag
        id: mk
        env:
          TAG_NAME: v0.1.0
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          echo "tag=${TAG_NAME}" >> "$GITHUB_OUTPUT"
          # 幂等：tag 已存在则直接跳过，绝不重复推送 / 移动 tag
          if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null; then
            echo "created=false" >> "$GITHUB_OUTPUT"
            echo "::notice::tag ${TAG_NAME} 已存在，幂等跳过"
            exit 0
          fi
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag "${TAG_NAME}" "${GITHUB_SHA}"      # 轻量 tag，精确指向本次构建的 commit
          git push origin "refs/tags/${TAG_NAME}"
          echo "created=true" >> "$GITHUB_OUTPUT"

  # ===== 改造既有 release job =====
  release:
    name: 发布 GitHub Release
    needs: [build-test, auto-tag]
    # 两条合法入口：① 人工/外部 push 的 v* tag；② 本次 run 内 auto-tag 首次创建成功
    if: >-
      ${{ always() &&
          needs.build-test.result == 'success' &&
          (startsWith(github.ref, 'refs/tags/v') ||
           (github.ref == 'refs/heads/main' && needs.auto-tag.outputs.created == 'true')) }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      # …保留原有 checkout / download-artifact / test -s / 打包源码 / RELEASE_BODY 生成…
      # 注意：把 RELEASE_BODY / name 里的 ${GITHUB_REF_NAME} 改为下方 TAG 常量，
      #       否则 main 分支触发时会输出 "main" 而非 "v0.1.0"。
      - name: 创建 GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ startsWith(github.ref, 'refs/tags/v') && github.ref_name || needs.auto-tag.outputs.tag }}
          target_commitish: ${{ github.sha }}     # 防止 tag 落到默认分支最新 commit 而非本次构建 commit
          name: CampusRunSimulator ${{ startsWith(github.ref, 'refs/tags/v') && github.ref_name || needs.auto-tag.outputs.tag }} (build ${{ github.run_number }})
          body_path: release-assets/RELEASE_BODY.md
          files: |
            release-assets/CampusRunSimulator-unsigned.ipa
            release-assets/CampusRunSimulator-source.zip
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**方案 A 的要点说明**

| 要求 | 落地方式 |
| --- | --- |
| **job 依赖** | `build-test → auto-tag → release`；`release.needs = [build-test, auto-tag]`，IPA artifact 由 `actions/download-artifact@v4` 从**同一 run** 获取（已验证名称一致），无需二次 run |
| **触发条件** | `auto-tag` 仅 `push` + `refs/heads/main` + `needs.build-test.result == 'success'`；`release` 放宽为「tag push **或** 本次 run 内 auto-tag 首次创建」 |
| **防循环** | ① `GITHUB_TOKEN` 推 tag 按 GitHub 官方规定**不会**创建新 workflow run（R5）；② `auto-tag.if` 限定 `refs/heads/main`，即便将来换成 PAT 触发二次 run，`github.ref = refs/tags/v0.1.0` 也不会再次进入 auto-tag；③ `release` 不推任何 git 对象，不产生新事件 |
| **幂等判断** | `git rev-parse -q --verify "refs/tags/v0.1.0"` + `created` output；`release.if` 追加 `needs.auto-tag.outputs.created == 'true'`，避免**每次 push main 都重复发布/覆盖同一 Release**、反复通知 watchers |
| **`[skip ci]`** | 轻量 tag 无 message，无法承载 `[skip ci]`；本方案以「`if` 条件 + 幂等 + GITHUB_TOKEN 不触发」三重机制替代，语义更可靠。若改用附注 tag，可在 tag message 中写 `[skip ci]` 作为第四重保险（GitHub 仅对 commit message 生效，tag 场景不可依赖） |
| **`permissions` / checkout** | `contents: write`（顶层已有，job 内重申）；`fetch-depth: 0` 必须，否则幂等检查与 `git push` 会失败 |
| **Release 拿同一次构建的 IPA** | `release` 与 `build-test` 同 run，`download-artifact@v4` 默认取当前 run 的 `CampusRunSimulator-unsigned-ipa`；`test -s` + `unzip -l` 双重门禁（`:471-482`）保持不变 |
| **`target_commitish`** | 必须显式传 `${{ github.sha }}`。`softprops/action-gh-release` 在 tag 不存在时由 GitHub Releases API 隐式创建 tag，**默认落在仓库默认分支最新 commit**（已有公开 issue 记录 tag 落错分支导致 provenance 错乱），不传会造成「tag 指向的 commit ≠ 构建 IPA 的 commit」 |
| **版本号** | 首版固定 `v0.1.0`（与 `MARKETING_VERSION` 默认 `0.1.0`、`CHANGELOG.md ## v0.1.0` 一致）；后续迭代可改为从 `CHANGELOG.md` 顶部或 `github.run_number` 生成递增版本，并同步 F71 的版本解析步骤（`:143-157`） |

**方案 A′（备选，若坚持「tag push 事件触发 release」语义）**：把 `auto-tag` 中 `actions/checkout` 与 `git push` 的凭据改为 **PAT（`secrets.RELEASE_PAT`，`repo` 权限）或 GitHub App 安装访问令牌**，则 push tag **会**触发新的 workflow run，`on.push.tags: ['v*']` 生效，由该次 run 的 `release` job（保持原 `if: startsWith(...)`）发布。代价：需要主理人在仓库配置额外 Secret（当前 MCP 工具集不含 Secret 管理，需人工在 GitHub 网页完成）；且第二次 run 会**再次执行 `build-test` 全量编译**，IPA artifact 来自第二次 run（与首次构建的 commit 相同但产物重新生成），CI 耗时翻倍；必须配合 `created == 'true'` 幂等与 tag 事件过滤，否则仍可能循环。**综合评估：方案 A 更省事、更稳、无需新 Secret，推荐优先采用。**

### 4.4 替代方案 B 评估：`release` job 直接在 `push main` 时用 `softprops/action-gh-release` + `tag_name: v0.1.0`（不预存 tag）

**结论：技术上可行，改动更小，但有明确副作用，作为「快速兜底」可用，不宜作为长期方案。**

- **可行性依据**：GitHub Releases API 在 `tag_name` 指定的 tag 不存在时会**自动创建该轻量 tag**（指向 `target_commitish`，缺省为仓库默认分支）。`softprops/action-gh-release` 支持 `tag_name` 与 `target_commitish` 两个输入（已核实其 README）。因此可以不新增 `auto-tag` job，只要把 `release.if` 从 `startsWith(github.ref, 'refs/tags/v')` 放宽为 `github.ref == 'refs/heads/main'`，并显式给 `tag_name: v0.1.0` + `target_commitish: ${{ github.sha }}`，即可在同一次 run 内创建 Tag + Release 并上传 IPA。
- **副作用 / 必须同时处理**：
  1. **幂等缺失**：每次 push main 都会尝试创建同一个 `v0.1.0` Release；第二次起 action 会复用/覆盖已有 Release 与同名 asset（`overwrite_files` 默认 true），造成 Release 历史被覆盖、watchers 反复收到通知。必须加 `created` 式判断：先 `gh release view v0.1.0`（或 `list_releases` / `get_release_by_tag`）存在则跳过。
  2. **`github.ref_name` 语义错乱**：现有 `RELEASE_BODY.md` 生成（`:497`）、Release `name`（`:524`）、状态摘要（`:539`）都用 `${GITHUB_REF_NAME}`，在 main 分支下会输出 `main` 而不是 `v0.1.0`；需全部改为版本常量。
  3. **`if` 必须放宽**：保留原 `startsWith` 则本方案根本不执行（正是当前 P0 缺陷）。
  4. **tag 落点漂移**：不传 `target_commitish: ${{ github.sha }}` 时，隐式创建的 tag 落在**默认分支最新 commit**，可能与本次构建 commit 不一致（若期间有新 push）。
  5. **触发语义重复**：由 API 创建的 tag 不会产生 `push tag` 事件（优点：天然无循环；缺点：`on.push.tags: ['v*']` 与 `:147,321` 的版本号解析分支对自动路径永远是死代码，易误导后续维护者）。
  6. **版本不可递进**：硬编码 `v0.1.0` 会被所有后续 push 复用，无法发布 `v0.1.1`；需要额外版本策略（读 `CHANGELOG.md` / `github.run_number`）。
  7. 现有 `release.needs: [build-test]` 与 artifact 下载链路可原样保留 ✓，`permissions: contents: write` 与 `GITHUB_TOKEN` 已齐全 ✓。

---

## 5. 智能路由判定

> ## `QA_ROUTE: Engineer`

**理由**：本轮发现的问题**不是测试代码笔误或文档排版问题，而是源码 / 工程配置 / CI 编排的功能性缺陷**，需回工程师修复，QA 无法自行闭环：

1. `GlassModifier.swift:102,109` 的 `.interactive` API 归属错误 —— **源码缺陷**（R1，Xcode 26 下阻断编译）；
2. F62 GPX Fixtures 未显式进入 test bundle、`#filePath` 兜底在模拟器内失效 —— **工程配置 + 测试资源链路缺陷**（R3，阻断 CI 单测）；
3. 签名路径 B 未覆盖全局 `CODE_SIGNING_ALLOWED=NO` —— **CI 编排缺陷**（R4）；
4. workflow 无 auto-tag，`release` job 永不可达 —— **P0 阻断交付缺陷**（第 4 节）。

按 QA 智能路由规则：「断言/预期符合 PRD 与设计，但实现无法满足 → 源码 Bug → 送 Engineer」。本轮全部为静态判定，未执行任何测试，故不存在「测试代码自身断言写错」的情形，不路由 `QA`；存在上述确证缺陷，不路由 `NoOne`。

**建议主理人转交工程师的修复优先级**：P0 交付链路（第 4 节方案 A）→ R1（Xcode 26 编译）→ R3（CI 单测资源）→ R4（路径 B 签名）→ R6–R13（实机验证与优化）。修复完成后可发起**第 2 轮 QA 回归**（最多 2 轮，本轮为第 1 轮）。

---

## 6. 真机 / CI 待验收项清单（本环境一律未执行）

| # | 待验收项 | 为什么静态核查不能替代 | 建议验收方式 |
| --- | --- | --- | --- |
| 1 | 后台连续记录 30 min（AC-F5） | `testBackgroundConfigurationConstants` 只校验 plist 常量与 `isPaused` 标记，无真实 `CLLocationManager` 后台回调 | 真机锁屏 / 切后台 30 min，检查轨迹不中断、`UIBackgroundModes=location` 生效、自动暂停回调 |
| 2 | HealthKit 真机写入（AC-F6） | `guard .real` 是静态代码守卫，HK 授权/写入/后台 delivery 需系统能力 | 真机勾选写入后检查「健康」App 中 workout 与 route；确认 SIMULATED 永不写入 |
| 3 | iOS 26 与低版本功能等价（AC-F9） | 双路径由 `#if compiler(>=6.2)` 分流，本环境两种 SDK 都无 | iOS 26 真机（官方 Liquid Glass）+ iOS 17 真机（材质回退），逐页比对控件集合、frame、无障碍标签 |
| 4 | XCUITest 全流程（F65） | CI 默认关闭（`ios-build.yml:191`），且模拟器 UI 自动化本环境不可跑 | CI `workflow_dispatch` 置 `runUITests=true`，或本地 Xcode 跑 5 个用例 |
| 5 | GPX 真机导入 | F62 是 `Data(contentsOf:)` 逻辑层往返，非系统文件面板 | 真机经「文件」App / 系统分享面板导入 GPX，验证缺 `ele`/仅 `rte`/非法版本分级提示 |
| 6 | 强杀后恢复（进程级） | F64 `testCheckpointSerializationAndRestore` 只验证对象序列化 | 真机记录中强杀 App → 重启 → 检查 `recoveryCheckpoint()` 恢复且 `segmentIndex` 正确、跨段不连线 |
| 7 | IPA 侧载安装 | F70 只保证 `test -s` 与 `unzip -l Info.plist`，workflow 自身声明「不证明可安装」（`:14-15`） | AltStore / Sideloadly 用个人 Apple ID 重签名后安装；路径 B 用有效证书 + 描述文件验证签名 IPA |
| 8 | 首次 GitHub Actions 全链路 | 本环境无 macOS Runner | 推送 main 后确认：`clean build` → `test` → F70 IPA → auto-tag → Release 含真实 IPA（修复第 4 节后） |
| 9 | Xcode 26 官方 Liquid Glass 编译 | R1 需 Xcode 26 SDK 才能暴露 | 在 Xcode 26 上执行一次 `clean build`，确认 4 个官方 API 名称与修饰符顺序 |
| 10 | SwiftData 双容器磁盘持久化 / 迁移 | F64 用 `makeInMemory()` | 真机跑 `makePersistent()`，检查 `simulatedStore` / `realStore` 独立 URL 与 `SchemaV1` 迁移 |

---

## 7. 遗留问题与免责说明

1. **本报告未执行任何编译、单元测试、UI 测试、真机测试、IPA 生成或 GitHub Actions 运行**；第 1 节 12 类均为「未执行」，第 2 节所有 `PASS` 仅指静态 / 格式 / 引用校验通过。任何「已通过测试」「构建成功」「测试通过率 X%」的表述都不属于本报告。
2. **静态核查的固有盲区**：括号平衡脚本为词法级粗检（跳过注释与字符串，字符串插值内的括号统一忽略），不含 Swift 语法/类型/重载解析；符号引用核查为「大写标识符 + 白名单」启发式，系统框架类型与项目同名类型可能互相掩盖；`确证缺失 0` 只表示「在本次脚本口径下未发现」，**不等于编译期无未定义符号**。
3. **需 Xcode 实机验证而未验证的点**（已在第 3.3 节逐条标注）：Xcode 16 同步组对 `.gpx` / `Info.plist` / `.xcassets` 的实际 build phase 归属、`TEST_HOST` 在 UI test 的表现、SwiftData 关系推断、macOS BSD `sort -V`、bash 3.2 空数组、`SpatialTapGesture` 可用性、Xcode 26 下 Liquid Glass 4 个 API 的编译结果。
4. **联网核实部分**：R1 的 API 归属基于 Apple Developer Documentation（`developer.apple.com/documentation/swiftui/glass`、`.../view/glasseffect(_:in:)`、`.../view/glassEffectID(_:in:)`、`.../glasseffectcontainer`）；Swift 版本与 Xcode 对应基于 `swiftly.dev/swift-versions`；R5 基于 GitHub 官方文档「触发工作流程 / 自动令牌身份验证」；方案 B 基于 `softprops/action-gh-release` README 与公开 issue。**若 Apple 后续 SDK 调整 API，以实机 Xcode 26 编译结果为准**；本报告已如实标注「需 Xcode 26 实机验证」，未把「查不到」写成「不正确」。
5. **未修改任何上游文件**：本轮未改动 `docs/02-Architecture.md` 等上游文档，也未修正其中发现的表述歧义（R6、R11）——按职责边界，此类改动留给主理人 / 工程师统一处理，避免影响 74 文件对照基准。本报告为 `docs/` 下新增文件，不计入 74 交付口径。
6. **轮次控制**：本轮为第 1 轮 QA。若主理人转交工程师修复后发起第 2 轮回归，QA 只做一轮回归；若第 2 轮仍有未解决项，将按 SOP 以「Known Issues」形式结案，不再进入第 3 轮。

---

## 附录 · 本轮实际执行过的校验命令 / 脚本清单

| 编号 | 命令 / 脚本 | 用途 |
| --- | --- | --- |
| C01 | `uname -a`；`for t in xcodebuild swiftc swift xcrun simctl; do command -v "$t"; done` | 环境硬约束取证 |
| C02 | `find . -type f -not -path './.git/*' -printf '%s\t%p\n' \| sort -k2`；`find . -type f -size 0` | 全量文件清单 / 空文件 |
| C03 | `grep -nE '^#{1,4} ' docs/02-Architecture.md` / `docs/01-Research-and-PRD.md` | 定位 §2.1 / §2.2 / §1.7 / §1.8 / §1.9 / §7 基准 |
| C04 | `find . -name '*.swift' \| wc -l`；`find . -name '*.swift' -print0 \| xargs -0 cat \| wc -l` | 58 文件 / 22,230 行口径 |
| C05 | Python：`re.findall(r'^\|\s*(F\d{2})\s*\|\s*`([^`]+)`\s*\|', arch, re.M)` 与 `os.walk` 实际文件集做差集 | A1 74 文件齐全性 |
| C06 | Python：pbxproj 定义行正则 `^\s*([0-9A-F]{24})\s*(/\*.*?\*/\s*)?=\s*\{` + 全 token 引用统计 + `isa` 计数 + 关键键正则 | A2 ID 悬空引用 / 对象计数 / 关键键 |
| C07 | Python：逐文件词法状态机（`//` / 嵌套 `/* */` / `"..."` / `"""..."""`）+ 括号栈匹配 | A3-1 58 文件平衡检查 |
| C08 | `grep -RInE 'TODO\|FIXME\|fatalError(\|XCTAssertTrue(true)\|@available\|#if compiler\|iOS 26\|GlassEffectContainer\|glassEffect\|glassEffectID\|interactive' --include='*.swift' .` | A3-3 / B 关键词扫描 |
| C09 | Python：`code_only()` 剥离注释/字符串 → 提取 `struct/class/enum/protocol/actor/extension/typealias` 定义 → 大写标识符 ∩ 系统白名单 | A4 疑似未定义符号 |
| C10 | Python：测试文件自定义类型交集、7 页 `init(`/`struct X: View` 比对、全仓 `glassCard`/`.glassEffect`/`GlassEffectContainer` 计数 | A4-2/3/4 |
| C11 | `bash -n ci/scripts/build_unsigned_ipa.sh` | A5-1 |
| C12 | Python `plistlib.load` × 3 | A5-2 plist |
| C13 | Python `xml.etree.ElementTree.parse` × 3（含 GPX 1.1 命名空间元素计数） | A5-3 GPX |
| C14 | Python `yaml.safe_load`（PyYAML 6.0.3） | A5-4 workflow YAML |
| C15 | `grep -RInE` 系列：网络栈 / 来源转换 / PEM 证书（修正 `-e`）/ `guard .real` / `guard .simulated` / `RuleEvaluationResult` / 混排 / import 框架 / Fixtures 读取 / actor-@MainActor-AsyncStream-Sendable / MapKit-Charts-SwiftData 符号 / `CODE_SIGNING_*` / `git tag\|git push` | A6 合规红线 + B 取证 |
| C16 | Python：逐测试文件 `len(re.findall(r'^\s*func test', s, re.M))` 与 `XCTAssert[A-Za-z]*\(` 计数 | A7 49 方法 / 481 断言 |
| C17 | Read：`project.pbxproj` 全文、`CampusRunSimulator.xcscheme` 全文、`Config/App.xcconfig`、`GlassModifier.swift` 全文、`.github/workflows/ios-build.yml` 全文、`build_unsigned_ipa.sh` 全文、`CodecTests.swift:78-102`、`SimulationEngineTests.swift:210-291`、`RepositoryIsolationTests.swift:540-586`、`DataMarker.swift:120-140` | 人工甄别误报、确认上下文 |
| C18 | WebSearch / WebFetch（Apple Developer Documentation、docs.github.com、swiftly.dev、softprops README） | R1 API 归属、R2 Swift 版本对应、R5 GITHUB_TOKEN 限制、方案 B 可行性 |

---

*报告结束 · 第 1 轮 QA · 路由 `Engineer` · 测试通过率 `N/A（本环境未执行，最终以 GitHub Actions 为准）`*

---

## 8. 第 2 轮回归验证（QA 最终轮）

> 审查人：严过关（Yan）｜QA 工程师｜SOP 第 4 阶段 · **最多 2 轮中的第 2 轮（最后一轮）**
> 触发：主理人转交工程师修复第 1 轮 4 个阻断项，工程师回报 `QA_FIX_DONE / IS_PASS: YES`
> 审查原则：**不采信工程师自查结论，全部证据由 QA 本轮独立重跑**（本节命令编号 C19–C30 见 8.8）
> 报告日期：2026-11-09

### 8.0 轮次、环境与诚实边界

```bash
$ uname -srm
Linux 6.6.117-45.11.3.tl4.x86_64
$ for t in xcodebuild swiftc xcrun simctl; do command -v "$t" || echo NOT\ FOUND; done
xcodebuild / swiftc / xcrun / simctl -> NOT FOUND
```

本环境仍为 **Ubuntu Linux，无 Xcode、无 swiftc、无 iOS Simulator**。因此**编译、XCTest 单元测试、XCUITest UI 测试、真机后台测试、IPA 生成、GitHub Actions workflow 运行、GitHub Release 发布，本轮一律未执行**。本节所有 `PASS` 仅表示「静态 / 格式 / 引用 / 结构化配置复核通过」，**绝不代表编译通过、测试通过、构建成功或 Release 发布成功**。

> **测试通过率：`N/A（本环境未执行，最终以 GitHub Actions macOS Runner 实际结果为准）`**
>
> **最终验收仍以 GitHub Actions 实际构建成功 + IPA 真实存在 + Release 成功发布为准，本环境无法替代。**

本轮 QA **未修改任何 App 源码、工程配置（`project.pbxproj` / `.xcscheme` / `.xcconfig`）、CI workflow 或脚本**；仅在 `docs/05-QA-Report.md` 末尾追加本章（第 1 轮全文保留未覆盖）。

### 8.1 改动范围与越界检查（任务 C）

仓库**非 git 仓库**（`git rev-parse --is-inside-work-tree` 失败），故改用 **文件 mtime** 做独立取证：以第 1 轮报告落盘时间 `2026-11-09 09:55:26` 为界，`find . -newermt '2026-11-09 09:55:27'` 输出**恰好 5 个文件**，与工程师声称范围完全一致：

| # | 文件 | mtime | 大小变化 |
| --- | --- | --- | --- |
| 1 | `.github/workflows/ios-build.yml` | 10:14:04 | 25,344 → 30,207 B |
| 2 | `CampusRunSimulator/UI/Theme/GlassModifier.swift` | 10:18:07 | 7,394 → 8,058 B |
| 3 | `CampusRunSimulatorTests/CodecTests.swift` | 10:23:45 | 24,553 → 37,994 B |
| 4 | `README.md` | 10:31:14 | 22,923 → 27,083 B |
| 5 | `CHANGELOG.md` | 10:31:38 | 8,549 → 10,162 B |

**未授权文件 mtime 复核（全部未变）**：`docs/05-QA-Report.md` = `09:55:26`；`project.pbxproj` = `00:57:12`；`CampusRunSimulator.xcscheme` = `00:57:30`；`Config/App.xcconfig` = `00:57:38`；`ci/scripts/build_unsigned_ipa.sh` = `07:49:33`；`ci/ExportOptions.plist` = `07:49:03`；`Resources/Info.plist` = `01:39:12`；`Fixtures/SIMULATED_sample_loop.gpx` = `07:46:17`；`SimulationEngineTests.swift` = `07:58:51`；`HealthKitService.swift` = `03:13:07`。其余 52 个 Swift 源码、2 个 Fixtures、UITests 等 mtime 均 ≤ `08:55:43`。

**规模口径**：交付文件 **74**（排除 `docs/`）、零字节文件 **0**、Swift 文件 **58**、Swift 行数 **22,523**（较第 1 轮 +293 行，与新增 3 个内联 GPX 常量 + GlassModifier 局部重构吻合）。

**文档诚实性**（`grep -nEi '编译通过|测试通过|构建成功|已通过|IS_PASS|100%'`）：`README.md` / `CHANGELOG.md` 中相关命中全部为**禁止性表述**——`README.md:256`「真机验收清单（待验收，不得提前标记『已通过』）」、`:275`「最终验收以 GitHub Actions macOS Runner 实际运行结果为准」、`CHANGELOG.md:4`「未经真机 / CI 实际验证的项目一律标注『待验收』，不得填写『已通过』」、`:84` ADR-9「无 Xcode 不声称编译通过」、`:116`「禁止在未实际运行的情况下把任何验收项写成『已通过』」。**未发现虚构测试结果或构建成功表述 → PASS**。

### 8.2 4 项修复复核表（任务 A）

| 项 | 第 1 轮缺陷 | 本轮结论 | 核心证据（文件:行号 / 命令输出） |
| --- | --- | --- | --- |
| **R1** | `GlassModifier.swift:102,109` 把 `Glass.interactive` 误用为 View 链式修饰符，Xcode 26 下必编译失败 | **PASS** | 剥离注释/字符串后代码中 `.interactive(` 仅 **1** 处（`:103` 的 `.regular.interactive()`，作用于 `Glass` 值）；View 链 `.glassEffect(...).interactive(` **0** 处；`let glass: Glass = interactive ? .regular.interactive() : .regular`（`:103`）；`.glassEffect(glass, in: Capsule())` **2** 处（`:108,113`，两分支均改）；`glassEffectID` 保留（`:114`）；`#if compiler(>=6.2)` ×3 / `#endif` ×3 配对、`@available(iOS 26, *)` ×2（`:90,193`）、`if #available`（`:179`）完整 |
| **R3** | F62 的 3 个 GPX Fixtures 未显式入 test bundle，`#filePath` 兜底在 iOS Simulator 内失效 | **PASS** | 3 个内联常量 `inlineLoopGPX/inlineMissingEleGPX/inlineOnlyRteGPX`（`:118,270,315`）与 `Fixtures/*.gpx` **逐字一致**（strip 后全 True，长度差 1 为尾随换行，常量末尾 `+ "\n"` 补齐）；XML 元素计数与磁盘文件完全一致；三级兜底 bundle → `#filePath` → `inlineFixture`（`:87-112`）；函数体 `XCTFail` **0** 次；未知名 `throw FixtureLookupError.unknownFixture(name)`（`:111`），枚举定义存在（`:381-388`），**不静默吞掉** |
| **R4** | 签名路径 B 未覆盖全局 `CODE_SIGNING_ALLOWED=NO` | **PASS** | 路径 B `archive`（`:403-404`）与 `-exportArchive`（`:420-421`）**均**含 `CODE_SIGNING_ALLOWED=YES` + `CODE_SIGNING_REQUIRED=YES`；步骤名对齐（`:388,411`）；路径 A 三处 `NO` 不变（`:180,195,211`）+ F70 脚本 `NO`（`:85-86`，mtime 未变）；`App.xcconfig:21-22` 与 pbxproj 12 处 `NO` 保留；优先级说明写入 workflow 头（`:10-12`）、两步骤内（`:395-396,415`）及 `README.md:186-188` |
| **P0** | workflow 无 auto-tag，仅 push main 时 `release.if` 永为 false，永不产出 v* Tag / Release / IPA | **PASS** | `yaml.safe_load` 解析出 **4 个 job**：`build-test / signed-ipa / auto-tag / release`；详见 8.2.4 |

#### 8.2.1 R1 详细证据（升级词法剥离后精确核验）

```text
代码中 .interactive( 命中: 1
  L103: .interactive() : .regular          ← Glass 值 .regular.interactive()
View 链 .glassEffect(...).interactive( 命中: 0
let glass: Glass = ... .regular.interactive() 存在: True
.glassEffect(glass, in: Capsule()) 次数: 2      ← 两分支均改
glassEffectID 次数: 1
#if compiler(>=6.2) 次数: 3   #endif 次数: 3   @available(iOS 26, *) 次数: 2
```

全仓 `grep -RInE '\.interactive\s*\(' --include='*.swift'` 仅命中 `GlassModifier.swift` 的 3 行注释（`:8,9,100`）与代码 `:103`，**无其他文件残留 View 链式调用**。与第 1 轮核实的 Apple 官方签名一致：`Glass.interactive(Bool) -> Glass` 是 `Glass` 值上的实例方法，官方示例写作 `.glassEffect(.regular.interactive(), in:)`；当前 `let glass: Glass = interactive ? .regular.interactive() : .regular` + `.glassEffect(glass, in: Capsule())` 为正确等价写法。**注意：Xcode 26 真实编译仍未执行（见 8.4-L2）**。

#### 8.2.2 R3 详细证据（逐字 + XML 语义比对）

| Fixture | 内联常量 | 逐字一致 | trk | trkseg | trkpt | ele | time | rte | rtept | wpt | 关键语义 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F66 `SIMULATED_sample_loop.gpx` | `inlineLoopGPX:118` | **True** | 1 | **2** | 8 | 9 | 8 | 0 | 0 | 1 | `SIMULATED` 11 次、`<crs:dataOrigin>simulated</...>` 存在、三重标记齐备 |
| F67 `sample_missing_ele.gpx` | `inlineMissingEleGPX:270` | **True** | 1 | 1 | 6 | **0** | 5 | 0 | 0 | 0 | 缺 `<ele>`、部分缺 `<time>` → 不得臆造 |
| F68 `sample_only_rte.gpx` | `inlineOnlyRteGPX:315` | **True** | **0** | 0 | 0 | 7 | 0 | 1 | 5 | 2 | 仅 `<rte>/<wpt>`，含 `<crs:illegalVersionSample>9.9</...>` 非法版本探针 |

三组计数与磁盘 `Fixtures/*.gpx` 的 `ElementTree` 解析结果**逐一相等**。`inlineFixture(named:)`（`:371-377`）映射 3 个名字、`default: return nil`；`loadFixture` 顺序为 `Bundle(for:)` → `Bundle(subdirectory:"Fixtures")` → `#filePath` → 内联常量（`:90-109`），命中即返回真实字节，未命中且名字未知时 `throw`（`:111`），**无静默返回空数据**。

**额外语法核验（不臆测的重要一环）**：`CodecTests.swift:674` 的 `String(data: loadFixture("sample_only_rte"), encoding: .utf8)` 未带 `try`，初看疑似编译阻断。本轮联网核实 Apple 官方文档 `XCTUnwrap(_:_:file:line:)` 签名为 `func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, ...) throws -> T`，且 Swift Forums 实例 `try typedThrowWithAutoclosure(typedThrow()) // ✅` 证明 `@autoclosure () throws` 参数内的 throwing 调用可由**外层** `try XCTUnwrap(...)` 覆盖，无需内层 `try` → **该写法合法，不判为阻断**。其余 3 个调用点（`:607,634,660`）均显式带 `try`。因本环境无编译器，此结论仍列入 8.4-L5 由 Xcode 实机最终确认。

#### 8.2.3 R4 详细证据

```text
workflow CODE_SIGNING 出现:
  :180  CODE_SIGNING_ALLOWED=NO   ← 路径 A clean build（未变）
  :195  CODE_SIGNING_ALLOWED=NO   ← 路径 A xcodebuild test（未变）
  :211  CODE_SIGNING_ALLOWED=NO   ← 路径 A UI test（未变）
  :403  CODE_SIGNING_ALLOWED=YES  ┐
  :404  CODE_SIGNING_REQUIRED=YES ┘ 路径 B archive
  :420  CODE_SIGNING_ALLOWED=YES  ┐
  :421  CODE_SIGNING_REQUIRED=YES ┘ 路径 B -exportArchive
F70 脚本 :85-86 仍 NO（mtime 07:49:33 未变）
App.xcconfig :21-22 仍 NO；pbxproj 含 12 行 NO（保留）
优先级注释: workflow :10-12 / :395-396 / :415；README :186-188
```

**表述不精确（非缺陷，列为 8.4-L8）**：注释与 README 称「pbxproj 8 份 `XCBuildConfiguration` 把签名写死为 NO」，实测含该键的是 **6 份 target 级**配置（project 级 2 份无此键）。该表述沿用第 1 轮 R4 的措辞，不影响「命令行实参优先级高于 xcconfig/pbxproj」的结论，也不影响功能。按职责边界，QA 本轮**不修改** CI 注释。

#### 8.2.4 P0 详细证据（`yaml.safe_load` 结构化解析）

| 检查项 | 实测结果 | 结论 |
| --- | --- | --- |
| 4 个 job 与依赖 | `build-test`(无 needs) / `signed-ipa`(无 needs) / `auto-tag`: `needs:[build-test]` / `release`: `needs:[build-test, auto-tag]` | PASS |
| `auto-tag.if` | `${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.build-test.result == 'success' }}`（`:479`） | PASS |
| `auto-tag.outputs` | `tag: ${{ steps.mk.outputs.tag }}`、`created: ${{ steps.mk.outputs.created }}`（`:483-485`） | PASS |
| `fetch-depth: 0` | `actions/checkout@v4` `with: {fetch-depth: 0, token: ${{ secrets.GITHUB_TOKEN }}}`（`:488-491`） | PASS |
| 幂等 | `git rev-parse -q --verify "refs/tags/v0.1.0"` → 已存在则 `created=false` + `exit 0`（`:500-504`） | PASS |
| 轻量 tag 指向本次构建 commit | `git tag v0.1.0 "${GITHUB_SHA}"`（`:507`）；`git push origin refs/tags/v0.1.0`（`:508`） | PASS |
| `release.if` 双入口 + `always()` | `always() && needs.build-test.result == 'success' && (startsWith(github.ref,'refs/tags/v') || (github.ref=='refs/heads/main' && needs.auto-tag.outputs.created == 'true'))`（`:519-523`） | PASS |
| auto-tag 被 skip 时 release 仍可拉起 | tag push 事件下 `auto-tag.if` 为 false → 被 skip；`release.if` 的 `always()` 使 job 仍评估，且 `startsWith(github.ref,'refs/tags/v')` 为 true 短路，`needs.auto-tag.outputs.created` 为空也不影响 | PASS |
| `tag_name` / `name` 三元 | `startsWith(github.ref,'refs/tags/v') && github.ref_name || needs.auto-tag.outputs.tag`（`:596,598`） | PASS |
| `target_commitish` | `${{ github.sha }}`（`:597`），与 `git tag` 的 `${GITHUB_SHA}` 同为本次 run 的 commit SHA → **一致** | PASS |
| `download-artifact` 同一次 run | `name: CampusRunSimulator-unsigned-ipa`（`:540`）↔ `upload-artifact` `name: ${{ env.ARTIFACT_NAME }}`（`:232`，`env.ARTIFACT_NAME` = `CampusRunSimulator-unsigned-ipa`，`:65`）；无 `run-id` 跨 run 引用 → 同 run 传递 | PASS |
| Release `files` | `CampusRunSimulator-unsigned.ipa` + `CampusRunSimulator-source.zip`（`:603-605`）；前置 `test -s` + `unzip -l Info.plist` 双门禁（`:543-555`） | PASS |
| `GITHUB_REF_NAME` 残留 | **全文 0 处**；release 段改用 job 级 `env.RELEASE_TAG`（`:527-530`），被 `:570,613,614` 复用 | PASS |
| 未引入新 Secret | 全 workflow Secret 集合 = `CERTIFICATE_P12_BASE64 / CERTIFICATE_PASSWORD / GITHUB_TOKEN / KEYCHAIN_PASSWORD / PROVISIONING_PROFILE_BASE64 / TEAM_ID`，与第 1 轮一致，仅用默认 `GITHUB_TOKEN` 打 tag | PASS |
| job 级 `permissions: contents: write` | `auto-tag`（`:481-482`）、`release`（`:525-526`）均有；顶层（`:44-45`）亦有 | PASS |
| 防循环与幂等注释 | `:16-18`（GITHUB_TOKEN 推 tag 不触发新 run）、`:469-475`（三重防循环 + 幂等 + 不引入新 Secret）、`:512-515`（同 run 内闭环） | PASS |
| 无循环触发路径 | PR 事件 / workflow_dispatch：既非 tag ref 也非 `main` + `created=='true'` → `release` skip；signed 模式下 `build-test` 被 skip → `needs.build-test.result != 'success'` → `release` skip | PASS |

### 8.3 回归静态核查表（任务 B · 确认修复未引入回归）

| 项 | 结论 | 命令 / 脚本 | 证据 |
| --- | --- | --- | --- |
| 括号/圆括号/方括号/引号平衡 | **PASS** | 升级版 Python 词法状态机（新增支持 `#"""` raw 多行字符串、raw 单行字符串、嵌套块注释）+ 栈匹配，逐文件 | **58/58 文件，异常文件 0、异常项 0**（升级扫描器是必要的：新增 3 个 raw 多行 GPX 常量含大量 `"` / `<` / `>`，旧扫描器会误报） |
| `TODO` / `FIXME` / `fatalError()` / `XCTAssertTrue(true)` / `assert(false)` | **PASS** | grep + Python 逐行 | 全部 **0 处** |
| pbxproj 24 位 hex ID 悬空引用 | **PASS** | Python 定义/引用集合差 | 定义 **41**、唯一 ID **41**、悬空引用 **无**、孤立定义 **无** |
| `bash -n ci/scripts/build_unsigned_ipa.sh` | **PASS** | `bash -n` | exit 0 |
| plist / GPX / YAML 解析 | **PASS** | `plistlib` ×3、`ElementTree` ×3、`yaml.safe_load` | Info.plist 23 键 / entitlements 2 键 / ExportOptions 10 键；3 个 GPX 均 GPX 1.1 合法；workflow YAML 解析出 4 job、`permissions: contents: write` |
| 74 文件 / 空文件 / 规模 | **PASS** | `find` | 交付 74、零字节 0、Swift 58 / 22,523 行 |
| 合规红线：网络上传栈 | **PASS** | `grep -RInE 'URLSession\|URLRequest\|uploadTask\|dataTask(\|NSURLConnection'` | **0 处** |
| 合规红线：`simulated→real` 转换 | **PASS** | Python 正则 + 人工甄别 | 5 处命中全部位于 `RepositoryIsolationTests.swift:84-85` 的**测试禁止词字符串数组**（`"func toReal"`, `"func convertToReal"` …），非真实函数实现 → 无转换路径 |
| 合规红线：硬编码 PEM 私钥 | **PASS** | 正则 | **0 处** |
| 合规红线：HealthKit `guard .real` / RuleEvaluator `guard .simulated` | **PASS** | Python 子串检查 | 均 `True`（`HealthKitService.swift:107`、`RuleEvaluator.swift:97`） |
| 合规红线：规则结果无 score | **PASS** | Python 截取 `RuleEvaluationResult` 结构体 | 含 `score` = `False`（9 字段不含分数） |
| 合规红线：三重标记 / 禁止混排 | **PASS** | 第 1 轮 A6-7/A6-8 结论复核（相关文件 mtime 未变） | 相关源码与 Fixtures 均未被本轮改动 |
| 文档诚实性 | **PASS** | grep 虚假通过表述 | 见 8.1，无虚构测试结果 |

### 8.4 遗留问题清单（第 2 轮结案）

> **本轮无确证「阻断交付」的遗留项**：4 项阻断修复已全部静态复核 PASS，交付链路在配置层已闭环。
> 以下均为**不阻断静态交付**、但**需真机 / CI 最终验证或人工处理**的事项；按 SOP 第 2 轮为最后一轮，不再进入第 3 轮。

| 编号 | 遗留问题 | 是否阻断交付 | 处理方 / 时机 |
| --- | --- | --- | --- |
| L1 | 编译、XCTest、XCUITest、IPA、Release 在本环境**一律未执行** | 否（环境限制） | GitHub Actions macOS Runner 首次运行 |
| L2 | Xcode 26 下 Liquid Glass 4 个官方 API 的真实编译结果（R1 已按官方签名修正，但 `#if compiler(>=6.2)` 分支从未被编译器解析） | 否（静态已修正） | Xcode 26 实机 `clean build`；若 SDK 命名再变，按 F45 单点收敛修改 |
| L3 | CI `ios-build.yml:77` `ls -d /Applications/Xcode_*.app \| sort -V \| tail -1` 选最高 Xcode；BSD `sort -V` 可用性、仓库变量路径未 `test -d` 校验（第 1 轮 R8） | 否（优化） | 首次 CI 运行观察；建议固定已验证 Xcode 版本 |
| L4 | F62 的 `.gpx` 是否真被 Xcode 16 同步根组拷入 test bundle 仍未证实（`membershipExceptions` 为空） | 否（内联兜底已使测试不依赖资源拷贝） | 首次 CI `xcodebuild test` 观察；若要保留 bundle 路径，需显式 `PBXResourcesBuildPhase.files` |
| L5 | `CodecTests.swift:674` 的 `@autoclosure () throws` + 外层 `try` 语法（本轮已按 Apple 文档与 Swift Forums 实例判定合法） | 否（判定合法） | Xcode 首次编译最终确认；若报 `call can throw`，在最内层补 `try` 即可 |
| L6 | 签名路径 B 的 5 个 Secrets 从未配置/验证；且路径 B 产出的已签名 IPA 不进入 Release（设计如此） | 否（路径 B 可选） | 人工在 GitHub 配置 Secrets 后手动 `workflow_dispatch` 验证 |
| L7 | `auto-tag` 固定 `v0.1.0`，多次 push main 后不会发布新版本；`:157-158,331-332` 的 tag 版本号解析分支对自动路径为死代码 | 否（首版交付成立） | 后续迭代引入版本递进策略（CHANGELOG / `github.run_number`） |
| L8 | workflow `:11` 与 `README.md:186` 称「pbxproj 8 份 XCBuildConfiguration 写死 NO」，实为 6 份 target 级（project 级 2 份无此键） | 否（表述不精确） | 文档/注释措辞修正；不影响命令行覆盖结论，QA 本轮按边界未改 CI |
| L9 | 第 1 轮 R6/R7/R10/R12/R13 待实机项：UITests `TEST_HOST`、SwiftData 关系推断、同步根组 `Info.plist` 例外与 `.xcassets`、`SpatialTapGesture`、Swift 6 `complete` 并发告警 | 否 | Xcode 16 / 26 实机编译 + 真机运行 |
| L10 | 第 6 节 10 项真机 / CI 待验收（后台 30 min、HealthKit 真机写入、iOS 26 与低版本等价、XCUITest 全流程、GPX 真机导入、强杀恢复、IPA 侧载、首次 Actions 全链路、Xcode 26 玻璃编译、磁盘双容器迁移） | 否 | 人工 / CI，见 8.6 |

**遗留问题数：10 条；其中阻断交付 0 条、需真机/CI 或人工处理的非阻断项 10 条。**

### 8.5 最终智能路由判定

> ## `QA_ROUTE: NoOne`

**理由**：

1. **4 项阻断修复逐项独立复核全部 PASS**（R1 / R3 / R4 / P0），证据见 8.2 各小节，均为本轮重跑所得，未采用工程师 `IS_PASS: YES`。
2. **无新增阻断**：回归静态核查（8.3）全绿；升级词法扫描确认新增 raw 字符串未破坏 58 文件平衡；pbxproj 零悬空引用；plist/GPX/YAML/bash 全解析通过；合规红线全部保持。
3. **无越界改动**（8.1）：仅 5 个声称范围内的文件变更，`docs/05-QA-Report.md`、pbxproj、xcscheme、xcconfig、F70、Fixtures、其余 52 个 Swift 源码 mtime 全部未变。
4. **第 1 轮 P0 交付链路在配置层已闭环**：`build-test → auto-tag → release` 同 run 内依赖、幂等、防循环、artifact 传递、`target_commitish` 一致性均已核实；R5（GITHUB_TOKEN 推 tag 不触发新 run）已通过「同 run 内 release」绕开。
5. 按 QA 智能路由规则：「测试代码问题自行修、源码/工程 Bug 回工程师」——本轮**未发现需要工程师再处理的确证缺陷**；剩余 10 条遗留均不阻断静态交付，且属真机 / CI 最终验证范畴，不构成回工程师的理由。
6. **SOP 轮次上限**：本轮为第 2 轮（最后一轮），按规则以本报告结案，不进入第 3 轮。

> **重要限定**：`NoOne` 仅表示「静态与配置层面的质量审查已闭环、无需再回工程师」，**不等于编译通过、测试通过或交付成功**。
> **最终验收仍以 GitHub Actions 实际构建成功 + IPA 真实存在 + Release 成功发布为准，本环境无法替代。**
> **测试通过率：`N/A（本环境未执行，最终以 GitHub Actions macOS Runner 实际结果为准）`**

### 8.6 真机 / CI 待验收项（沿用第 6 节，本轮重申，均未执行）

1. 后台连续记录 30 min（AC-F5，真机锁屏 / 切后台）
2. HealthKit 真机写入（AC-F6，含「SIMULATED 永不写入」验证）
3. iOS 26 与 iOS 17 功能等价（AC-F9，双路径控件集合 / frame / 无障碍标签逐页比对）
4. XCUITest 全流程（F65 五个用例；CI 默认关闭，需 `workflow_dispatch` 置 `runUITests=true`）
5. GPX 真机导入（系统文件面板 / 分享面板，缺 ele / 仅 rte / 非法版本分级提示）
6. 强杀后进程级恢复（checkpoint / `segmentIndex` / 跨段不连线）
7. IPA 侧载安装（AltStore / Sideloadly 重签名；未签名 IPA 本身不可直接安装）
8. **首次 GitHub Actions 全链路验收**：`clean build` → `xcodebuild test` → F70 `test -s` + `unzip -l` → `upload-artifact` → `auto-tag` 创建 `v0.1.0` → `release` 发布 Release 且 asset 含真实 IPA + 源码 zip → 核对 tag 指向本次构建 commit
9. Xcode 26 官方 Liquid Glass 编译（4 个 API 名称与修饰符顺序）
10. SwiftData 双容器磁盘持久化 / `SchemaV1` 迁移真机验证

### 8.7 免责声明

1. 本轮**未执行**任何 `xcodebuild` 编译、XCTest / XCUITest、真机测试、IPA 生成、GitHub Actions workflow、GitHub Release 发布。8.2/8.3 的所有 `PASS` 仅为静态 / 格式 / 引用 / 结构化配置复核结论；本报告不含任何通过率、构建成功或用例全绿的表述。
2. 静态核查的固有盲区不变：词法扫描为粗检（已升级支持 raw 字符串，但不做 Swift 语法 / 类型 / 重载解析）；符号引用核查为启发式；「无新增阻断」仅表示「在本轮脚本口径下未发现」，**不能替代编译器**。
3. 4 项修复的**运行期正确性**（Liquid Glass 在 Xcode 26 上真能编译、`auto-tag` 真能推 tag、`softprops` 真能创建 Release、路径 B 真能产出已签名 IPA、内联 GPX 真能被 XCTest 读取）**全部未在实机验证**，以 GitHub Actions 首次实际运行结果为准。
4. 本轮联网核实仅用于两处语法/平台判定：Apple Developer Documentation（`XCTUnwrap` 的 `@autoclosure () throws -> T?` 签名）与 Swift Forums（autoclosure 内 throwing 调用可由外层 `try` 覆盖）；其余结论均来自本地脚本与文件读取。
5. 本轮 QA 未修改任何 App 源码、工程配置、CI workflow 或脚本；仅追加本章。第 1 轮全文（§0–§7 及附录）完整保留。
6. **轮次控制**：第 1 轮 `Engineer` → 工程师修复 → 第 2 轮（本轮）`NoOne` 结案。若首次 GitHub Actions 运行暴露任何编译 / 测试 / 交付失败，属**新事实**，应由主理人按新缺陷流程另行处置，不在本 SOP 两轮回归范围内。

### 8.8 本轮新增证据命令 / 脚本清单（C19–C30）

| 编号 | 命令 / 脚本 | 用途 |
| --- | --- | --- |
| C19 | `uname -srm`；`command -v xcodebuild swiftc xcrun simctl`；`git rev-parse --is-inside-work-tree` | 环境硬约束 / 非 git 仓库取证 |
| C20 | `find . -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS\t%s\t%p\n' \| sort -r`；`find . -newermt '2026-11-09 09:55:27'`；`stat -c '%y'` ×10 | C 越界改动 mtime 取证 |
| C21 | `grep -nE 'interactive\|glassEffect\|GlassEffectContainer\|glassEffectID\|let glass\|Glass' GlassModifier.swift`；`grep -RInE '\.interactive\s*\(' --include='*.swift' .` | R1 初筛 |
| C22 | Python 注释/字符串（含 `#"""` raw）剥离 + 精确统计 `.interactive(` / `.glassEffect(...).interactive(` / `let glass: Glass` / `#if`×`#endif` / `@available` | R1 精确核验 |
| C23 | `grep -nE 'CODE_SIGNING_(ALLOWED\|REQUIRED)\|CODE_SIGN_STYLE\|DEVELOPMENT_TEAM' ios-build.yml`；`sed -n '158,215p' / '388,425p'`；`grep -nE 'CODE_SIGNING' F70 / xcconfig / pbxproj`；`grep -nEi '优先级\|覆盖\|override\|命令行\|xcconfig'` | R4 路径 A/B 与优先级注释 |
| C24 | `python3 - <<'PY' … yaml.safe_load … PY`：jobs / needs / if / outputs / permissions / steps.with / run 脚本 / `GITHUB_REF_NAME` 残留 / Secret 集合 / 关键字符串计数 | P0 结构化解析 |
| C25 | `grep -nE 'RELEASE_TAG\|GITHUB_REF_NAME\|GITHUB_REF\|ref_name'`；`grep -nEi '防循环\|幂等\|skip ci\|GITHUB_TOKEN\|轻量 tag\|target_commitish\|created'`；`grep -nE '^  (build-test\|signed-ipa\|auto-tag\|release):'`；`grep -nE 'ARTIFACT_NAME:\|name:.*unsigned-ipa\|uses: actions/(upload\|download)-artifact'` | P0 常量 / 注释 / artifact 一致性 |
| C26 | Read `.github/workflows/ios-build.yml:468-617`（auto-tag 与 release 全文） | P0 人工复核 |
| C27 | Python 提取 `#"""\n(.*?)\n"""#` ×3、与 `Fixtures/*.gpx` `strip` 后逐字比对 + `difflib`、`ElementTree` 元素计数、内联常量 XML 解析、非法 version 探针 | R3 逐字 + XML 语义比对 |
| C28 | `grep -RInE 'FixtureLookupError\|unknownFixture'`；`sed -n '87,112p' / '655,694p' CodecTests.swift`；`grep -nE 'loadFixture\('`；`grep -nE 'inlineLoopGPX\|inlineMissingEleGPX\|inlineOnlyRteGPX\|static func inlineFixture\|#"""'` | R3 三级兜底 / 未知名报错 / `:674` 上下文 |
| C29 | Python 升级词法状态机（普通/多行/raw 字符串、嵌套块注释）+ 58 文件括号栈匹配；TODO/FIXME/fatalError/XCTAssertTrue(true)；pbxproj ID 集合差；`plistlib`×3 / `ElementTree`×3 / `yaml.safe_load`；合规红线正则 | B 回归静态核查 |
| C30 | `bash -n ci/scripts/build_unsigned_ipa.sh`；`find` 74/0/58/22,523；`grep -nEi '编译通过\|测试通过\|构建成功\|已通过\|IS_PASS\|100%'` README/CHANGELOG；`grep -nEi 'QA\|auto-tag\|CODE_SIGNING_ALLOWED\|Fixtures\|内联\|兜底\|Glass'` README/CHANGELOG；WebSearch ×2（Apple `XCTUnwrap` 签名、Swift autoclosure/try 规则）、WebSearch ×1（swiftly.dev / softprops 沿用第 1 轮） | B 格式 / C 文档诚实性 / 语法核实 |

---

*第 2 轮（最终轮）回归验证结束 · 路由 `NoOne` · 4 项修复全部 PASS · 遗留 10 条（阻断交付 0 条）· 测试通过率 `N/A（本环境未执行，最终以 GitHub Actions macOS Runner 实际结果为准）` · 最终验收仍以 GitHub Actions 实际构建成功 + IPA 真实存在 + Release 成功发布为准，本环境无法替代*
