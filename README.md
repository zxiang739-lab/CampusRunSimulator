# CampusRunSimulator · 校园跑运动仿真与数据分析（iOS 17+）

一个**教学研究 / 个人自用 / 数据分析**用的原生 iOS App：在 App 内用独立数据源生成可复现的
仿真跑步轨迹，同时用设备传感器记录真实跑步。两类数据在 UI、文件、持久化三个层面严格分离。

---

> ## ⚠️ 合规声明（请先阅读）
>
> **本 App 为教学研究 / 个人自用 / 数据分析工具，不作弊。**
>
> - 不破解、不逆向、不注入、不篡改任何第三方 App；
> - 不伪造第三方服务器数据，不绕过平台反作弊机制或身份验证机制；
> - **不把模拟记录冒充真实运动成绩**，不向任何第三方平台上传、提交成绩；
> - 所有仿真数据在界面与导出文件中明确标记为「**测试数据 / SIMULATED**」，并与真实运动记录
>   **物理分域**（两个独立 SwiftData `ModelContainer`、两套独立 id 空间）；
> - 仿真是 App 内独立数据源，**不修改系统级定位、不向其他 App 注入虚拟定位**；
> - 规则配置模块全部为「**示例假设值**」，不内置、不宣称任何学校或平台的真实规则；
>   评估结果为「通过 / 不通过 / 数据不足」三态，**不产生分数或成绩**；
> - 测试数据**永不写入健康 App**（HealthKit 仅 `.real` 且需结束页逐次显式勾选）；
> - 不存在 `simulated → real` 的转换、复制或导出入口；不存在网络上传成绩的代码路径。
>
> 详见 `docs/01-Research-and-PRD.md` §0 合规红线、§B.11 数据隔离设计，以及 `LICENSE` 附加条款。
> 未经证实的第三方检测机制一律标注为推测，不作事实陈述；引用来源见该文档**附录 A**。

---

## 1. 项目定位与边界

| 是 | 不是 |
| --- | --- |
| 本地可复现的运动数据生成与数学一致性研究 | 任何平台 / 学校的成绩申报或打卡工具 |
| 真实跑步记录（GPS + 运动传感器）与数据分析 | 定位模拟器、虚拟定位注入器 |
| 用户自建「假设规则」的对比实验（三态、无分数） | 第三方反作弊规则的实现或复刻 |
| GPX / CSV / JSON 本地导入导出与轨迹回放 | 向第三方服务器提交数据的客户端 |

App **零第三方依赖**（无 Swift Package / CocoaPods / Carthage）；仅使用 Apple 系统框架。

## 2. 功能清单

| 模块 | 能力 |
| --- | --- |
| ① 首页总览 | 真实 / 模拟数据分别统计、4 个主入口真实跳转、最近记录、合规声明常驻、权限异常横幅、空态引导 |
| ② 地图与路线规划 | MapKit 真实地图；点选 / 拖点 / 撤销 / 重做 / 保存 / 复制 / 路线类型 / GPX 导入导出 / 海拔剖面 / 版本历史；长度、方向、坡度、海拔真实计算 |
| ③ 运动模拟器 | 6 种速度模型、5 阶段、种子、采样率、噪声、坡度影响全参数可编辑；预览、I1–I10 校验、失败拒绝生成、模板持久化、按假设规则预评估、生成后进入回放 |
| ④ 实时运动（真实记录） | 权限自检、真实实时数值与地图、开始 / 暂停 / 继续 / 结束、HealthKit 写入默认关闭且需勾选、GPS 中断提示；**不含任何仿真入口或虚拟定位** |
| ⑤ 数据分析 | 4 类曲线（速度 / 配速 / 步频 / 海拔）、时间 / 距离轴切换、区间统计、I1–I10 与数据质量报告、假设规则评估（固定免责声明）、导出、回放到时间点 |
| ⑥ 历史记录 | 默认「真实记录 / 测试数据 SIMULATED」两分区，**禁止「全部记录」混排**；筛选 / 搜索 / 排序、详情→回放 / 分析 / 导出 / 删除、批量删除、路线版本与预设列表、存储占用、脏数据归入「未分类」 |
| ⑦ 设置 | 权限状态、单位、外观、仿真默认值、分别清除两类数据、高程来源开关、预设 CRUD、关于 / 合规 / 引用来源、版本号与 Liquid Glass 状态 |
| 轨迹回放 | 地图动态轨迹 + 实时数值 + 曲线 + 常驻来源徽标；播放 / 暂停 / 继续 / 快进 / 倍速 0.5×–8× / 拖动定位全部真实生效 |
| 导入导出 | GPX 1.1（`XMLParser` 真解析）、CSV、JSON；**三重标记**：① 文件名 `SIMULATED_` / `REAL_` ② 文件内 metadata / 首行 / 顶层 ③ UI 徽标元数据，缺一即拒绝导出；混合来源一律拒绝 |
| 合规与持久化 | 双独立 `ModelContainer`（`simulated.store` / `real.store`）、`sim_` / `real_` id 空间、审计日志（不含经纬度）、恢复检查点 |

## 3. 环境与工具要求

| 项 | 要求 |
| --- | --- |
| 开发机 | macOS 14/15+，Xcode 16+ |
| 推荐 | **Xcode 26 / iOS 26 SDK**：启用官方 Liquid Glass API；Xcode 16 会自动走 F45 的材质回退路径，显示「已启用兼容外观」，**功能等价、不禁用功能** |
| 部署目标 | **iOS 17.0+**（ADR-1） |
| 语言 / 并发 | Swift 5，`SWIFT_STRICT_CONCURRENCY = complete` |
| 系统框架 | SwiftUI、SwiftData、Swift Charts、MapKit、CoreLocation、CoreMotion、HealthKit、Foundation、OSLog、UIKit、XCTest / XCUITest |
| 第三方依赖 | **无**；CI 中的 `actions/checkout@v4`、`actions/upload-artifact@v4`、`actions/download-artifact@v4`、`softprops/action-gh-release@v2` 是 GitHub Actions 编排工具，不是 App 运行依赖 |

## 4. 目录结构（74 个文件，F01–F74）

```
CampusRunSimulator/
├── CampusRunSimulator.xcodeproj/          # F01–F02 工程文件 + shared scheme
│   └── xcshareddata/xcschemes/
├── Config/App.xcconfig                   # F03 全工程构建设置唯一来源
├── CampusRunSimulator/
│   ├── App/                              # F08 @main 入口、AppDelegate、双容器注入
│   ├── RootView.swift                    # F09 AppRoute / TabView / 玻璃顶栏底栏
│   ├── Resources/                        # F04–F07 Info.plist / entitlements / Assets
│   ├── Core/                             # F10–F13 DataOrigin / Units / AppConstants / AuditLogger
│   ├── Models/
│   │   ├── Domain/                       # F14–F19 15 类领域实体
│   │   └── Persistence/                  # F20–F21 SwiftData 模型 + 双容器工厂
│   ├── Contracts/                        # F22–F23 冻结协议
│   ├── Modules/
│   │   ├── SimulationEngine/             # F24–F31 数学核心 / I1–I10 / actor 引擎
│   │   ├── LocationAndSensors/           # F32–F35 真实定位 / 运动 / HealthKit / 记录编排
│   │   ├── DataProcessing/               # F36–F37 曲线与报告
│   │   ├── Rules/                        # F38–F39 预设校验与三态评估
│   │   ├── ImportExport/                 # F40–F43 三重标记 / GPX / CSV / JSON / 导出管理
│   │   └── Repository/                   # F44 双域仓库
│   └── UI/
│       ├── Theme/                        # F45–F47 玻璃双路径 / 来源徽标 / 主题与服务装配
│       ├── Components/                   # F48–F50 卡片 / 地图 / 图表
│       ├── Replay/                       # F51–F52 回放视图与控制器
│       └── Pages/                        # F53–F59 七个页面
├── CampusRunSimulatorTests/              # F60–F64 单元测试 + Fixtures/（F66–F68）
├── CampusRunSimulatorUITests/            # F65 XCUITest
├── ci/                                   # F69 ExportOptions.plist、F70 未签名 IPA 脚本
│   └── scripts/
├── .github/workflows/ios-build.yml       # F71 CI 编译 / 测试 / 双签名路径 / Release
├── docs/                                 # 上游 PRD / 架构 / 任务列表（不在 74 文件计数内）
├── README.md / LICENSE / CHANGELOG.md    # F72–F74
```

## 5. 本地构建、测试与导出

```bash
# 0) 确认工程与 scheme
xcodebuild -version
xcodebuild -list -project CampusRunSimulator.xcodeproj

# 1) 编译门禁（模拟器 SDK，关闭签名）
xcodebuild -project CampusRunSimulator.xcodeproj \
  -scheme CampusRunSimulator -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO clean build

# 2) 单元测试（F60–F64：纯逻辑 + in-memory SwiftData，不需要真机）
xcodebuild test -project CampusRunSimulator.xcodeproj \
  -scheme CampusRunSimulator -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CampusRunSimulatorTests

# 3) UI 测试（F65，可选；需 iOS Simulator / 真机）
xcodebuild test -project CampusRunSimulator.xcodeproj \
  -scheme CampusRunSimulator -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CampusRunSimulatorUITests

# 4) 生成未签名 IPA（签名路径 A，F70）
MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=1 \
  bash ci/scripts/build_unsigned_ipa.sh
# 产物：build/CampusRunSimulator-unsigned.ipa
# 脚本内部强制：test -s 门禁 + unzip -l | grep Payload/CampusRunSimulator.app/Info.plist

# 5) 导出 GPX / CSV / JSON
#    在 App 内「历史记录」或「数据分析」页选择单条记录 → 选择格式 → 系统分享面板。
#    导出文件带 SIMULATED_ / REAL_ 前缀与文件内标记，只写入本地临时目录，不联网。
```

`ci/scripts/build_unsigned_ipa.sh` 在 CI 里用 `bash` 调用，**不依赖可执行位**（本地也可 `chmod +x`）。
脚本以 `set -euo pipefail` 运行，失败时 `set -x` 输出 Xcode 版本、工程列表、build 目录与日志末尾并 `exit 1`。

## 6. CI 复现（`.github/workflows/ios-build.yml`）

| 触发 | 行为 |
| --- | --- |
| `push` 到 `main` | 编译门禁 + 单元测试 + 生成未签名 IPA + 上传 artifact；**首次成功构建后由 `auto-tag` job 幂等创建轻量 tag `v0.1.0`，并在同一次 run 内创建 GitHub Release、上传真实 IPA** |
| `pull_request` | 编译门禁 + 单元测试 + 生成未签名 IPA + 上传 artifact（不创建 tag / Release） |
| `push` tag `v*` | 上述全部 + 下载 IPA artifact + 打包源码 zip + 创建 GitHub Release |
| `workflow_dispatch` | 可选 `signingMode=unsigned\|signed`、`runUITests`、`exportMethod` |

> **Release 闭环机制（QA 第 1 轮修复）**：`GITHUB_TOKEN` 推送的 tag 按 GitHub 官方规定**不会**触发新的
> workflow run，因此不能依赖「推 tag → 二次触发 release」。本 workflow 采用方案 A：`auto-tag` job
> （`needs: [build-test]`，仅 `push` 且 `refs/heads/main` 且构建成功时运行）用 `git rev-parse -q --verify
> refs/tags/v0.1.0` 做幂等判断；tag 不存在则 `git tag v0.1.0 "${GITHUB_SHA}"` + `git push`，输出
> `created=true`。`release` job（`needs: [build-test, auto-tag]`）据此在**同一次 run** 内发布 Release，
> IPA 由 `actions/download-artifact@v4` 从同一次 run 获取，保留 `test -s` + `unzip -l` 双门禁；
> `tag_name` / `name` 用 `github.ref_name || needs.auto-tag.outputs.tag` 三元表达式，并显式传
> `target_commitish: ${{ github.sha }}` 防止 tag 落到默认分支最新 commit。防循环：GITHUB_TOKEN 推 tag
> 不触发新 run + `auto-tag.if` 限定 main + release 不推任何 git 对象；幂等：`created == 'true'` 才发布，
> 避免每次 push main 重复覆盖同一 Release。**不引入任何新 Secret**（仅默认 `GITHUB_TOKEN`）。
> `RELEASE_BODY` / Release name / 状态摘要统一使用 `RELEASE_TAG` 版本常量，不再用 `${GITHUB_REF_NAME}`
> （否则 main 触发会输出 "main" 而非 "v0.1.0"）。

**12 步完整流程（路径 A，job `build-test`，`runs-on: macos-15`）**

1. `actions/checkout@v4` 检出源码；
2. 动态选择最高可用 Xcode（`ls -d /Applications/Xcode_*.app | sort -V | tail -1`，可用仓库变量 `XCODE_VERSION` 固定）→ `sudo xcode-select -s` → `xcodebuild -version` / `xcrun simctl list devices available` 日志；
3. `plutil -lint` 校验 `Info.plist` / `CampusRunSimulator.entitlements` / `ci/ExportOptions.plist`；
4. 合规静态扫描：无 `URLSession` / 上传成绩栈、无 `simulated→real` 转换实现、无禁止动作标识、无硬编码证书（排除 `docs/` 与否定式免责声明）；
5. 解析版本：tag → `MARKETING_VERSION`；`CURRENT_PROJECT_VERSION = github.run_number`（非 tag 用 `0.1.0`）；
6. `xcodebuild -sdk iphonesimulator ... clean build` 编译门禁（不加 `-quiet`，`tee` 保留完整日志）；
7. `xcodebuild test ... -only-testing:CampusRunSimulatorTests -resultBundlePath build/TestResults.xcresult`；
8. 可选 `runUITests` 时运行 `CampusRunSimulatorUITests`；
9. `bash ci/scripts/build_unsigned_ipa.sh` 生成未签名 IPA；
10. `test -s` + `unzip -l | grep Payload/CampusRunSimulator.app/Info.plist` 双重门禁，失败即 `exit 1`；
11. `actions/upload-artifact@v4` 上传 IPA（`if-no-files-found: error`）；`if: failure()` 步骤 `cat` 全部日志；
12. `auto-tag` job（仅 `push main` 且构建成功）幂等创建 `v0.1.0` 轻量 tag；`release` job（tag `v*` 或
    本次 run 首次 auto-tag 成功）在同一次 run 内下载 IPA artifact → 打包源码 zip → 拼接 CHANGELOG
    生成 Release 说明 → `softprops/action-gh-release@v2` 发布（IPA + 源码 zip，`generate_release_notes: true`、
    `target_commitish: ${{ github.sha }}`）。共 4 个 job：`build-test` / `signed-ipa` / `auto-tag` / `release`。

**路径 B（job `signed-ipa`，与路径 A 互斥）**：仅 `inputs.signingMode == 'signed'` 时运行，需 5 个 Secrets：
`CERTIFICATE_P12_BASE64`、`CERTIFICATE_PASSWORD`、`PROVISIONING_PROFILE_BASE64`、`TEAM_ID`、`KEYCHAIN_PASSWORD`。
流程为：检查 Secrets → 临时 keychain（`runner.temp`）导入 P12 → 安装 `.mobileprovision` →
用 `PlistBuddy` 把占位符注入 `ci/ExportOptions.plist` 的**临时副本** → `archive` → `xcodebuild -exportArchive`
→ `test -s` 门禁 → 上传 artifact → `if: always()` 清理临时凭证。
**签名开关覆盖（QA 第 1 轮修复）**：`App.xcconfig` 与 pbxproj 8 份 `XCBuildConfiguration` 把
`CODE_SIGNING_ALLOWED/REQUIRED = NO` 写死；命令行实参优先级高于 xcconfig / pbxproj，故路径 B 的
`clean archive` 与 `-exportArchive` **都显式追加 `CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`**，
否则 archive 仍无签名、`-exportArchive` 必然失败。路径 A（`clean build` / F70 脚本）保持 `NO` 不变。
**Secret 缺失时明确跳过并输出原因，绝不回退到未签名产物冒充已签名 IPA；证书 / 私钥绝不写入仓库。**
`ci/ExportOptions.plist` 只含 `${TEAM_ID}` 等占位值，不含真实证书、私钥或已废弃的 `compileBitcode`。

> CI 只证明「编译成功 / 单测通过 / IPA 真实存在且非空 / Release 发布成功」，
> **不证明 IPA 可安装到真机、不虚构签名成功或安装成功**。

## 7. 未签名 IPA 安装说明（如实）

`build/CampusRunSimulator-unsigned.ipa` 由 `CODE_SIGNING_ALLOWED=NO` archive 后组装 `Payload/` 打包，
**未签名，无法直接安装到未越狱的 iPhone**。可选方式：

1. 使用 **AltStore / Sideloadly** 等工具，以个人 Apple ID 在本地重新签名后安装（个人证书有效期与
   设备安装数量限制由 Apple 决定，需使用者自行确认）；
2. 配置有效的 Apple Developer 证书与描述文件，使用**签名路径 B**（`workflow_dispatch` →
   `signingMode=signed`，并配置 5 个 Secrets）产出已签名 IPA。

签名状态、证书有效性、设备是否可安装，**均由使用者自行确认**；本项目不虚构签名成功、不虚构安装成功，
也不提供任何绕过签名校验的手段。

## 8. 权限清单

| 权限 / 能力 | `Info.plist` 键 | 用途 | 何时使用 |
| --- | --- | --- | --- |
| 使用期间 / 始终定位 | `NSLocationWhenInUseUsageDescription`、`NSLocationAlwaysAndWhenInUseUsageDescription` | 真实跑步的 GPS 轨迹 | **仅「实时运动」页开始真实记录时**申请；仿真功能不申请后台定位 |
| 后台定位 | `UIBackgroundModes = [location]` | 真实记录后台连续轨迹 | 仅真实记录；真机 30 min 后台为人工验收项 |
| 运动与健身 | `NSMotionUsageDescription` | 步频 / 步数 / 相对海拔（字段缺失时按「不可用」处理，不臆造） | 真实记录 |
| 健康数据读取 | `NSHealthShareUsageDescription` | 读取授权状态；隐私语义下不可判定时按「无数据」呈现 | 设置页 / 真实记录页 |
| 健康数据写入 | `NSHealthUpdateUsageDescription` | 写入 workout + route | **仅 `.real` 且结束页显式勾选**（默认关闭）；测试数据永不写入 |
| HealthKit 后台 delivery | entitlement `com.apple.developer.healthkit.background-delivery` | 后台健康数据读取 | 模拟器不支持，需真机验收 |

## 9. 12 类测试 → 文件 / 方法 → 验收编号映射表

| 编号 | 测试类别 | 测试文件 / 主要方法 | 验收编号 | 执行环境 |
| --- | --- | --- | --- | --- |
| [T01] | GPS 轨迹连续性 | F60 `testTrackPointContinuity`、`testSameSeedReproducesByteIdentical`；F61 `testAllInvariantsPass`（I1/I10） | AC-D5 / AC-D6 / AC-D7 | iOS Simulator / CI |
| [T02] | 距离计算准确性 | F60 `testDistanceAccuracy`、`testUnitConversions`；F62 `testGPXRoundTrip`（坐标往返） | AC-D1 / AC-D3 | iOS Simulator / CI |
| [T03] | 步频与步幅一致性（`L=60v/c`、`ΣΔsteps·L=ΣΔd`） | F60 `testStrideDerivedFromSpeedAndCadence`；F61 I7 注入矛盾 | AC-D2 | iOS Simulator / CI |
| [T04] | 配速计算 | F60 `testPaceCalculation`、`testUnitConversions` | AC-D1 | iOS Simulator / CI |
| [T05] | 海拔变化（gain/loss 死区、上下坡） | F60 `testElevationGainLossDeadband`；F61 I8 注入矛盾 | AC-D4 | iOS Simulator / CI |
| [T06] | 长时间运动模拟（≥30 min / 1800+ 点，含耗时与内存断言） | F60 `testLongRunPerformance`（1801 帧）；F61 `testGenerationRefusedOnFailure` | AC-D7 / AC-D8 | iOS Simulator / CI |
| [T07] | 后台运行（配置常量与自动暂停回调逻辑） | F60 `testBackgroundConfigurationConstants`（`UIBackgroundModes` / 权限文案 / `backgroundPaused` / `.paused` 点） | AC-F5（**真机 30 min 部分需人工验收**） | 纯逻辑在 CI；真机人工补充 |
| [T08] | 定位中断恢复（`TrackFilter` gap→`segmentIndex`、跨段不连线、`RecoveryCheckpoint` 序列化 / 恢复、稀疏间隔不插值） | F64 `testTrackFilterGapCreatesNewSegment`、`testCheckpointSerializationAndRestore`、`testSparseIntervalNotInterpolated`；F62 `testSampleLoopMarkersAndMultiSegment`（多 `trkseg`） | AC-F5 / AC-F11 / AC-F2 | iOS Simulator / CI；强杀重启需真机人工 |
| [T09] | GPX 导入导出往返（含 F66–F68 三个样例） | F62 `testGPXRoundTrip`、`testJSONRoundTrip`、`testCSVExportColumnsAndMarkers`、`testAllThreeMarkersPresent`、`testMissingEleDoesNotFabricate`、`testOnlyRteCompatible`、`testInvalidVersionRejected`、`testSampleLoopMarkersAndMultiSegment`、`testMixedOriginExportRejected`、`testUnclassifiedJSONIsRejected` | AC-C2 / AC-F2 / AC-F3 / AC-C7 | iOS Simulator / CI |
| [T10] | SwiftData 存储（in-memory 双域隔离、CRUD、持久化等价、无转换 / 无 HK 写入路径） | F64 `testSeparateStores`、`testIDSpacesDisjoint`、`testCRUDInMemoryContainers`、`testDirtyDataIsolatedAsUnclassified`、`testOriginImmutable`、`testDuplicatePreservesOrigin`、`testNoSimulatedToRealConversionPath`、`testNoHealthKitWriteFromSimulated` | AC-C3 / AC-C7 / AC-F11 | iOS Simulator / CI |
| [T11] | UI 交互（7 页标记可见、VoiceOver 标签、无混排、无假按钮） | F65 `testOriginBadgeOnAllSevenPages`、`testNoMixedOriginList`、`testAccessibilityLabels`、`testPrimaryTabButtonsNavigate`、`testNoForbiddenButtons`；补充 F63 规则三态测试（`testThreeStateOnly` 等，AC-C6 / AC-F8） | AC-C1 / AC-C5 / AC-C6 / AC-C7 / AC-F1 / AC-F8 / AC-F10 | **XCUITest：CI 可选 / 需模拟器**，本地 Linux 未执行 |
| [T12] | Xcode 完整编译 | F71 `build-test` job：`xcodebuild clean build` + `xcodebuild test` + archive + IPA `test -s` 门禁 | V5.1 / V5.2 | **仅 GitHub Actions macOS Runner** |

> 补充映射：F63 `RuleEvaluatorTests` 7 个方法覆盖 AC-C6（假设值 + 免责 + 三态无分数）
> 与 AC-F8（多预设对比 / JSON 导入导出）；F61 覆盖 AC-D7（I1–I10 与拒绝生成）。
> 完整 AC 编号 → 任务 / 文件矩阵见 `docs/03-TaskList.md` §5。

**测试边界（诚实声明）**

- 单元测试只验证纯逻辑与 in-memory 数据层，**不初始化** `CLLocationManager` / `HKHealthStore` / `CMAltimeter`；
  SwiftData 统一使用 `ModelContainerFactory.makeInMemoryPair()` / `makeInMemory()`；
- Tests 中的定位 / 运动提供者为纯内存 `AsyncStream` 桩（F64），不发起系统定位；
- Fixtures 采用三级兜底（QA 第 1 轮修复）：① `Bundle(for:)` / test bundle ② `#filePath` 相对源码目录
  ③ 与 `Fixtures/*.gpx` **逐字一致的内联常量**（F62 `inlineLoopGPX` / `inlineMissingEleGPX` /
  `inlineOnlyRteGPX`）。iOS Simulator 独立文件系统无法访问 macOS 主机 `#filePath`，且 Xcode 16 同步根组
  不保证把 `.gpx`（非标准扩展名）拷入 test bundle，故第三级保证 [T09] 在任意 CI 环境都能执行，
  `loadFixture(_:)` 不再因资源未拷贝而 `XCTFail`；F60 `loadInfoPlist()` 首级 `Bundle.main` 不受影响。
  文件内容仍保留在 `Fixtures/` 供真机导入与人工核对，内联常量与文件逐字一致；
- 真机 30 min 后台、HealthKit 真机写入、iOS 26 与低版本双路径等价、深色 / 动态类型 /
  Reduce Motion 全页面、XCUITest 全流程、GPX 真机导入均**需真机 / CI 验收，本地 Linux 未执行**，
  见下方「真机验收清单」与 `CHANGELOG.md` 验收记录留档。

## 10. 真机验收清单（待验收，不得提前标记「已通过」）

| 项目 | 验收编号 | 状态 |
| --- | --- | --- |
| 后台 30 min 连续记录、GPS 遮挡后独立 segment、跨段不连线 | AC-F5 | ⏳ 待真机验收 |
| HealthKit 授权 + 显式勾选后写入 workout + route；拒绝 / 未勾选时不写入且不崩溃 | AC-F6 | ⏳ 待真机验收 |
| iOS 26 与 iOS 17 各跑一遍完整功能用例，功能等价、无功能缺失 | AC-F9 | ⏳ 待双版本真机验收 |
| 深色模式 / 最大动态类型 / Reduce Motion 全页面，SIMULATED 标记不截断 | AC-F10 | ⏳ 待真机验收 |
| 强杀 App 后重启，会话 / 路线 / 预设 / 设置完整；写入中断可恢复 | AC-F11 | ⏳ 待真机验收 |
| GPX 真机导入、系统分享面板导出 | AC-F2 / AC-F3 | ⏳ 待真机验收 |
| XCUITest 全流程（7 页标记 / 无假按钮 / 无混排） | [T11] | ⏳ 待 CI 或模拟器验收 |
| 未签名 IPA 重签名安装 / 签名路径 B 已签名 IPA | 安装说明 | ⏳ 由使用者自行确认 |

## 11. 诚实披露的限制与本地已执行校验

### 11.1 限制（必须如实告知）

1. **本工程源码在 Linux 沙箱生成，本地无 `swiftc` / `swift` / Xcode / iOS Simulator**：
   无法编译、无法运行 XCTest / XCUITest、无法 archive、无法生成 IPA、无法发布 Release。
2. **最终验收以 GitHub Actions macOS Runner 实际运行结果为准**：编译成功、单元测试通过、
   IPA 真实存在且非空、Release 成功发布，均以 `ios-build.yml` 的 run 日志与 artifact 为准。
3. **iOS 26 官方 Liquid Glass API 命名需在 macOS Runner（Xcode 26）上编译验证**；
   若 `GlassEffectContainer` / `.glassEffect` / `.glassEffectID` 命名与 SDK 有差异，
   **仅需修改 `CampusRunSimulator/UI/Theme/GlassModifier.swift`**（F45 单点收敛），其余 73 个文件不受影响；
   Xcode 16 会自动走 `#if compiler(>=6.2)` 的材质回退路径。
   QA 第 1 轮已按 Apple 官方签名修正：`interactive` 是 `Glass.interactive(Bool) -> Glass`（作用在 Glass 值上），
   不存在 `View.interactive(_:)`；官方路径已改为先构造 `Glass` 局部常量再传给 `.glassEffect(_:in:)`，
   两个分支都从 View 链移除 interactive 修饰符。**该修正仍需 Xcode 26 实机编译最终确认。**
4. **Release 闭环与 Fixtures / 签名修复（QA 第 1 轮）均为静态文本层修复**：
   `auto-tag` job 幂等创建 `v0.1.0` tag 并在同一次 run 内发布 Release、路径 B 命令行显式
   `CODE_SIGNING_ALLOWED=YES` 反向覆盖、F62 三个 GPX 内联兜底——三者本地 Linux **均未实机运行**，
   是否真正产出 Tag / Release / 可签名 IPA / 通过单测，仍以 GitHub Actions macOS Runner 实际日志为准。
5. CI 首次失败时应依据 `xcodebuild` 日志修正 F01/F02/F03 工程配置，**不得回头修改 PRD 或放宽合规约束**。
6. 未签名 IPA 不可直接安装；签名状态与安装结果由使用者自行确认（见第 7 节）。
7. 规则预设全部为「示例假设值」，非任何平台或学校的真实规则；评估不产生分数、不上传成绩。
8. 引用来源与检索缺口见 `docs/01-Research-and-PRD.md` **附录 A / 附录 B**。

### 11.2 本地 Linux 上真实执行过的校验（唯一可比编译验证的项目）

```bash
bash -n ci/scripts/build_unsigned_ipa.sh                         # F70 脚本语法
python3 -c "import xml.dom.minidom; ..."                        # F66–F68 三个 GPX 的 XML 合法性
python3 -c "import plistlib; ..."                               # F04/F05/F69 三个 plist 合法性
python3 -c "import yaml; ..." 或键名 / 缩进抽查                    # F71 workflow YAML 基本结构
python3 静态扫描                                                  # 74 文件数量、无 TODO / 占位、无硬编码证书
# —— QA 第 1 轮修复追加（本轮本地真实执行）——
python3 -c "import yaml; yaml.safe_load(...)"                   # 4 job / auto-tag.outputs / target_commitish / 无残留 GITHUB_REF_NAME
grep 'CODE_SIGNING_ALLOWED=YES' .github/workflows/ios-build.yml # 路径 B archive + exportArchive 两处
grep -vF '.interactive(interactive)' .../GlassModifier.swift    # 已无 View 链式写法
python3 逐字比对 .../CodecTests.swift 内联常量 vs Fixtures/*.gpx # 3 个常量与文件字节一致
```

> 这些校验只覆盖「文本 / 语法 / 结构」层面，**不等价于 Swift 编译或 XCTest 运行**；
> 实际执行结果与命令见交付批次回复，最终结论以 macOS Runner 为准。

## 12. 许可证

MIT + 附加合规声明（「不得用于作弊、不得用于绕过第三方平台监测」等），见 `LICENSE`。
版本记录、ADR 摘要与真机验收留档见 `CHANGELOG.md`。

---

**引用来源**：全部真实联网检索所得的 Apple 官方文档、学校公开规则与数学 / 标准资料，
统一索引于 `docs/01-Research-and-PRD.md` 附录 A；检索缺口如实记录于附录 B。
