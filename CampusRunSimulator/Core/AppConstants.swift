import Foundation

/// 全局常量、固定文案、审计格式与错误类型的单一来源（F12 / §7.6 / §7.7 / §7.10 / §7.11）。
public enum AppConstants {
    // MARK: 时间轴与采样率（§7.4）
    public static let defaultSampleRateHz: Double = 1.0
    public static let maxTrackPoints: Int = 200_000
    public static let maxPointIntervalSeconds: TimeInterval = 3

    // MARK: 数值容差与门限（§7.11）
    public static let toleranceVelocity: Double = 0.005
    public static let tolerancePace: Double = 0.005
    public static let toleranceStride: Double = 0.005
    public static let toleranceStepDistance: Double = 0.01
    public static let toleranceDistance: Double = 0.005
    public static let elevationDeadbandMeters: Double = 2.0
    public static let accuracyGateMeters: Double = 50
    public static let haversineEarthRadiusM: Double = 6_371_000

    // MARK: 身份与 schema
    public static let schemaVersion: String = "1.0"
    public static let generator: String = "CampusRunSimulator"
    public static let documentSource: String = "user_defined"
    public static let bundleIdentifier: String = "com.campusrun.simulator"

    // MARK: OSLog 审计通道（§7.10；subsystem 与 PRODUCT_BUNDLE_IDENTIFIER 一致）
    public static let logSubsystem: String = "com.campusrun.simulator"
    public static let logCategorySimulation: String = "simulation"
    public static let logCategorySensor: String = "sensor"
    public static let logCategoryHealthKit: String = "healthkit"
    public static let logCategoryExport: String = "export"
    public static let logCategoryRepository: String = "repository"
    public static let logCategoryCompliance: String = "compliance"

    // MARK: 持久化 / 审计辅助
    public static let globalSettingsID: String = "global_settings"
    public static let globalPermissionStateID: String = "global_permission_state"
    public static let maxRecentAuditEvents: Int = 200
    public static let maxRulePresetsInComparison: Int = 4
    public static let gpxExtensionNamespacePrefix: String = "crs:"
    public static let gpxSchemaVersion: String = "1.1"

    // MARK: 固定文案（§7.6，全部为简体中文，禁止「成绩 / 达标 / 过检 / 上传」类断言）
    /// 规则页免责声明（固定文案，评估页与导出文件内必须展示）。
    public static let disclaimer: String =
        "以下均为示例假设值，非任何平台真实规则，仅供本地模拟研究；本评估不产生、不上传任何成绩。"
    /// 与 `disclaimer` 同源，供规则预设字段引用。
    public static let ruleDisclaimer: String = disclaimer

    /// 全站合规声明（首页与设置页引用同一来源）。
    public static let complianceStatement: String =
        "本 App 为教学研究 / 个人自用 / 数据分析工具，不作弊"

    /// 仿真页页脚固定文案。
    public static let simulationFooter: String =
        "本数据由 App 内独立数据源生成，不代表真实运动，不上传任何第三方平台，不写入健康数据"

    /// 评估结论固定文案。
    public static let ruleEvaluationNotice: String =
        "本结果为基于用户自定义假设参数的本地模拟评估，非任何平台判定，不产生、不上传任何成绩"

    /// 低版本系统 Liquid Glass 回退提示。
    public static let liquidGlassFallbackNotice: String =
        "当前系统不支持，已启用兼容外观"

    /// 真实记录页提示。
    public static let realPageNotice: String =
        "此页数据来自设备传感器，与测试数据物理隔离"

    /// 评估对象标注。
    public static let evaluationObjectLabel: String = "评估对象：测试数据 / SIMULATED"

    /// 混合导出守卫提示。
    public static let singleOriginExportNotice: String =
        "一次导出只含单一来源，测试数据与真实记录不可混合导出"

    /// 三重标记缺失提示。
    public static let missingMarkerNotice: String =
        "缺少来源标记，导出已被拒绝"

    /// 脏数据分区名称（绝不默认显示为真实记录）。
    public static let unclassifiedSectionName: String = "未分类"

    /// 首次启动合规确认的 8 条红线摘要（§0.1 R1–R8）。
    public static let complianceRedLines: [String] = [
        "本项目是「教学研究 / 个人自用 / 数据分析」工具",
        "严禁破解任何第三方 App",
        "严禁伪造第三方服务器数据",
        "严禁绕过平台反作弊或身份验证机制",
        "严禁把模拟记录冒充真实运动成绩",
        "所有仿真数据必须在 UI 与导出文件中明确标记为「测试数据 / SIMULATED」，并与真实运动记录物理区分",
        "不得把未经证实的第三方检测规则当作事实陈述；所有推测必须显式标注",
        "虚拟轨迹仿真必须是 App 内独立数据源，不得修改系统级定位、不得伪装第三方平台的真实定位"
    ]

    /// 每秒步数上限（护栏，防止非法采样率）。
    public static let maximumSampleRateHz: Double = 100
}

/// GPX 导入缺失字段枚举（AppError 关联值；GPXImportResult.missingFields 亦使用）。
/// 定义在 Core，避免与 F41 GPXCodec 重复定义。
public enum GPXMissingField: String, Codable, Sendable, CaseIterable {
    case elevation = "ele"
    case time
    case track = "trk"
    case version

    /// 面向用户的中文说明。
    public var localizedDescription: String {
        switch self {
        case .elevation: return "缺少海拔 <ele> 字段（不臆造，按不可用处理）"
        case .time: return "缺少时间戳 <time> 字段（不插值）"
        case .track: return "缺少 <trk> 轨迹段（可能仅含 <rte>/<wpt>）"
        case .version: return "GPX 版本号非法或缺失"
        }
    }
}

/// 全 App 错误类型（§7.7 / §B.13.3 全部 15 类状态）。
/// 每个 case 都有明确中文文案与可操作出口；错误态下来源徽标不得隐藏。
public enum AppError: Error, LocalizedError, Sendable {
    // 仿真
    case parameterConflict(reason: String)
    case invariantFailed([InvariantID])
    case tooManyPoints(requested: Int, limit: Int)
    case strideDeviationFromReference(Double)
    case seedMissing
    // 真实记录
    case locationNotAuthorized
    case preciseLocationDisabled
    case gpsSignalWeak
    case backgroundPaused
    case motionSensorUnavailable(field: String)
    case healthKitUnavailable
    case healthKitNotAuthorized
    case healthKitWriteFailed(reason: String)
    case simulatedWriteForbidden
    case backgroundDeliveryUnsupported
    // 编解码 / 导出
    case gpxInvalidVersion(String)
    case gpxMissingField(GPXMissingField)
    case gpxOnlyRte
    case exportFailed(reason: String)
    case storageInsufficient
    case mixedOriginExportForbidden
    case missingOriginMarker
    case unclassifiedDataIsolated
    // 规则 / 设置
    case ruleParameterConflict(field: String)
    case ruleHypotheticalViolation
    case externalElevationNotEnabled
    case externalElevationConsentRequired
    case persistenceMigrationFailed

    /// 面向用户的错误文案。
    public var errorDescription: String? {
        switch self {
        case .parameterConflict(let reason):
            return "仿真参数冲突：\(reason)"
        case .invariantFailed(let ids):
            let list = ids.map(\.rawValue).joined(separator: "、")
            return "一致性校验未通过（\(list)），已拒绝生成"
        case .tooManyPoints(let requested, let limit):
            return "请求生成 \(requested) 个采样点，超过上限 \(limit) 个"
        case .strideDeviationFromReference(let ratio):
            return String(format: "步幅反算值与参考值偏差 %.2f%%，请检查步频或速度参数", ratio * 100)
        case .seedMissing:
            return "缺少随机种子，无法保证可复现"
        case .locationNotAuthorized:
            return "未获得定位授权，无法开始真实记录"
        case .preciseLocationDisabled:
            return "精确位置已关闭，轨迹精度将受限并标注低精度"
        case .gpsSignalWeak:
            return "GPS 信号弱或长时间无更新，已标注信号中断段"
        case .backgroundPaused:
            return "后台定位被系统暂停，恢复后将新建分段且不连线"
        case .motionSensorUnavailable(let field):
            return "传感器「\(field)」不可用，该字段按「不可用」处理，不臆造"
        case .healthKitUnavailable:
            return "健康数据当前不可用"
        case .healthKitNotAuthorized:
            return "未获得健康数据写入授权，已跳过写入"
        case .healthKitWriteFailed(let reason):
            return "写入健康 App 失败：\(reason)"
        case .simulatedWriteForbidden:
            return "合规守卫：测试数据 / SIMULATED 永不写入健康 App"
        case .backgroundDeliveryUnsupported:
            return "后台健康数据读取在模拟器上不可用，请在真机验收"
        case .gpxInvalidVersion(let version):
            return "GPX 版本「\(version)」非法，仅支持 GPX 1.1"
        case .gpxMissingField(let field):
            return field.localizedDescription
        case .gpxOnlyRte:
            return "文件仅含 <rte>/<wpt> 路线点，可作为路线导入，不作为运动轨迹"
        case .exportFailed(let reason):
            return "导出失败：\(reason)"
        case .storageInsufficient:
            return "设备存储空间不足，请清理后重试"
        case .mixedOriginExportForbidden:
            return AppConstants.singleOriginExportNotice
        case .missingOriginMarker:
            return AppConstants.missingMarkerNotice
        case .unclassifiedDataIsolated:
            return "检测到缺少来源标记的数据，已隔离为「未分类」，不会当作真实记录"
        case .ruleParameterConflict(let field):
            return "规则预设字段「\(field)」存在参数冲突，请修正"
        case .ruleHypotheticalViolation:
            return "规则预设必须标记 isHypothetical=true（示例假设值）"
        case .externalElevationNotEnabled:
            return "第三方高程服务未启用或不可用，请改用自定义海拔或 GPX 剖面"
        case .externalElevationConsentRequired:
            return "外部高程服务需联网，请先确认将发送的坐标范围"
        case .persistenceMigrationFailed:
            return "本地数据迁移失败，已切换到内存模式，数据不会被合并"
        }
    }

    /// 可操作出口（错误态视图按此文案绑定真实动作）。
    public var recoverySuggestion: String? {
        switch self {
        case .parameterConflict:
            return "返回修改时长 / 速度 / 路线长度后重新生成"
        case .invariantFailed:
            return "返回修改参数，或查看高亮的不变量编号"
        case .tooManyPoints:
            return "降低采样率或缩短时长"
        case .strideDeviationFromReference:
            return "调整目标步频或参考步幅"
        case .seedMissing:
            return "使用固定种子或允许引擎生成并持久化种子"
        case .locationNotAuthorized, .preciseLocationDisabled:
            return "前往系统设置开启定位 / 精确位置，或继续使用仿真功能"
        case .gpsSignalWeak:
            return "继续等待信号，或结束并保存已有分段"
        case .backgroundPaused:
            return "继续记录，中断段将单独分段"
        case .motionSensorUnavailable:
            return "在设置中关闭该字段采集，仍可记录 GPS 轨迹"
        case .healthKitUnavailable, .healthKitNotAuthorized:
            return "重试或跳过写入，不影响记录本身"
        case .healthKitWriteFailed:
            return "重试或跳过写入，不静默重试"
        case .simulatedWriteForbidden:
            return "仅可对真实记录勾选健康 App 写入"
        case .backgroundDeliveryUnsupported:
            return "在真机进行后台读取验收"
        case .gpxInvalidVersion, .gpxMissingField, .gpxOnlyRte:
            return "仍导入可用部分或取消；缺失字段不会被臆造"
        case .exportFailed:
            return "换一种格式重试"
        case .storageInsufficient:
            return "清理设备空间或分别清除两类历史数据"
        case .mixedOriginExportForbidden:
            return "按来源分区分别选择记录后导出"
        case .missingOriginMarker:
            return "使用 App 内导出入口重新生成带三重标记的文件"
        case .unclassifiedDataIsolated:
            return "在历史记录「未分类」分区手动归档或删除"
        case .ruleParameterConflict:
            return "修正冲突字段（如最快配速不得大于最慢配速）"
        case .ruleHypotheticalViolation:
            return "仅导入标记 isHypothetical=true 的用户自建预设"
        case .externalElevationNotEnabled:
            return "在设置中把高程来源切换为自定义或 GPX"
        case .externalElevationConsentRequired:
            return "同意联网提示或取消"
        case .persistenceMigrationFailed:
            return "重启 App 或分别清除两类数据后重试"
        }
    }

    /// 稳定的错误码（写入审计日志，日志不含经纬度）。
    public var resultCode: String {
        switch self {
        case .parameterConflict: return "E_PARAMETER_CONFLICT"
        case .invariantFailed: return "E_INVARIANT_FAILED"
        case .tooManyPoints: return "E_TOO_MANY_POINTS"
        case .strideDeviationFromReference: return "E_STRIDE_DEVIATION"
        case .seedMissing: return "E_SEED_MISSING"
        case .locationNotAuthorized: return "E_LOCATION_NOT_AUTHORIZED"
        case .preciseLocationDisabled: return "E_PRECISE_LOCATION_DISABLED"
        case .gpsSignalWeak: return "E_GPS_WEAK"
        case .backgroundPaused: return "E_BACKGROUND_PAUSED"
        case .motionSensorUnavailable: return "E_MOTION_UNAVAILABLE"
        case .healthKitUnavailable: return "E_HEALTHKIT_UNAVAILABLE"
        case .healthKitNotAuthorized: return "E_HEALTHKIT_NOT_AUTHORIZED"
        case .healthKitWriteFailed: return "E_HEALTHKIT_WRITE_FAILED"
        case .simulatedWriteForbidden: return "E_SIMULATED_WRITE_FORBIDDEN"
        case .backgroundDeliveryUnsupported: return "E_BACKGROUND_DELIVERY_UNSUPPORTED"
        case .gpxInvalidVersion: return "E_GPX_INVALID_VERSION"
        case .gpxMissingField: return "E_GPX_MISSING_FIELD"
        case .gpxOnlyRte: return "E_GPX_ONLY_RTE"
        case .exportFailed: return "E_EXPORT_FAILED"
        case .storageInsufficient: return "E_STORAGE_INSUFFICIENT"
        case .mixedOriginExportForbidden: return "E_MIXED_ORIGIN_FORBIDDEN"
        case .missingOriginMarker: return "E_MISSING_ORIGIN_MARKER"
        case .unclassifiedDataIsolated: return "E_UNCLASSIFIED_ISOLATED"
        case .ruleParameterConflict: return "E_RULE_PARAMETER_CONFLICT"
        case .ruleHypotheticalViolation: return "E_RULE_HYPOTHETICAL_VIOLATION"
        case .externalElevationNotEnabled: return "E_EXTERNAL_ELEVATION_DISABLED"
        case .externalElevationConsentRequired: return "E_EXTERNAL_ELEVATION_CONSENT"
        case .persistenceMigrationFailed: return "E_PERSISTENCE_MIGRATION_FAILED"
        }
    }
}
