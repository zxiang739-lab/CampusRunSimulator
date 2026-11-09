#!/usr/bin/env bash
# F70 · 签名路径 A（默认主路径）：构建「未签名 IPA」。
#
# 执行语义：本脚本在 CI 里用 `bash ci/scripts/build_unsigned_ipa.sh` 调用，
# 不强依赖可执行位（chmod）；本地也可 `chmod +x` 后直接运行。
# 由 GitHub Actions 的 build-test job 调用；只在 macOS Runner + Xcode 下可用。
#
# 诚实声明：未签名 IPA 无法直接安装到未越狱 iPhone，需使用个人 Apple ID
# 经 AltStore / Sideloadly 重签名，或改用签名路径 B（Secrets 驱动）。
# 本脚本只保证「IPA 文件真实存在且非空且内含 Info.plist」，不宣称可安装、不宣称已签名。

set -euo pipefail

# MARK: - 路径与常量

readonly PROJECT="CampusRunSimulator.xcodeproj"
readonly SCHEME="CampusRunSimulator"
readonly CONFIGURATION="Release"
readonly ARCHIVE_PATH="build/CampusRunSimulator.xcarchive"
readonly APP_PATH="${ARCHIVE_PATH}/Products/Applications/CampusRunSimulator.app"
readonly PAYLOAD_DIR="build/Payload"
readonly IPA_PATH="build/CampusRunSimulator-unsigned.ipa"
readonly BUILD_LOG="build/xcodebuild_archive.log"

# 版本覆盖：由 F71 从 tag / github.run_number 注入；未注入时由 xcconfig 默认值决定。
MARKETING_VERSION="${MARKETING_VERSION:-}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-}"

# MARK: - 失败诊断（set -x 输出详细上下文，然后 exit 1）

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    set +e
    set -x
    echo "==================== 构建失败诊断 ====================" >&2
    echo "失败行号: ${line_no}；退出码: ${exit_code}" >&2
    echo "Xcode 版本:" >&2
    xcodebuild -version >&2 || true
    echo "工程 / scheme 列表:" >&2
    xcodebuild -list -project "${PROJECT}" >&2 || true
    echo "build 目录内容:" >&2
    ls -laR build >&2 || true
    echo "xcodebuild 日志末尾 120 行:" >&2
    tail -n 120 "${BUILD_LOG}" >&2 || true
    echo "====================================================" >&2
    exit 1
}
trap 'on_error ${LINENO}' ERR

# MARK: - 前置检查

echo "[F70] 开始构建未签名 IPA（签名路径 A）"
xcodebuild -version
mkdir -p build

if [[ ! -d "${PROJECT}" ]]; then
    echo "错误：未找到 ${PROJECT}，请在仓库根目录执行本脚本" >&2
    exit 1
fi

# 组装版本覆盖参数（数组写法避免空参数破坏 set -u）。
version_overrides=()
if [[ -n "${MARKETING_VERSION}" ]]; then
    version_overrides+=("MARKETING_VERSION=${MARKETING_VERSION}")
fi
if [[ -n "${CURRENT_PROJECT_VERSION}" ]]; then
    version_overrides+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")
fi
if (( ${#version_overrides[@]} > 0 )); then
    echo "[F70] 版本覆盖参数: ${version_overrides[*]}"
fi

# MARK: - 1) archive（关闭签名，不请求任何证书 / 描述文件）

echo "[F70] 1/5 xcodebuild clean archive（CODE_SIGNING_ALLOWED=NO）"
# 不加 -quiet，保留完整 stdout 便于 CI 排查；同时 tee 一份日志供失败步骤 cat。
set -o pipefail
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    "${version_overrides[@]}" \
    clean archive 2>&1 | tee "${BUILD_LOG}"

# MARK: - 2) 校验 .app 产物

echo "[F70] 2/5 校验 .app 产物"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "错误：archive 成功但未找到 ${APP_PATH}" >&2
    exit 1
fi
if [[ ! -s "${APP_PATH}/Info.plist" ]]; then
    echo "错误：${APP_PATH}/Info.plist 不存在或为空" >&2
    exit 1
fi
plutil -lint "${APP_PATH}/Info.plist"

# MARK: - 3) 组装 Payload 并打包 IPA

echo "[F70] 3/5 组装 Payload 并 zip 打包"
rm -rf "${PAYLOAD_DIR}" "${IPA_PATH}"
mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"
(
    cd build
    zip -qry CampusRunSimulator-unsigned.ipa Payload
)

# MARK: - 4) 门禁：IPA 真实存在且非空

echo "[F70] 4/5 IPA 存在且非空门禁"
if ! test -s "${IPA_PATH}"; then
    echo "错误：${IPA_PATH} 不存在或为空，判定构建失败" >&2
    exit 1
fi
ls -lh "${IPA_PATH}"

# MARK: - 5) 二次校验：IPA 内必须含 Payload/CampusRunSimulator.app/Info.plist

echo "[F70] 5/5 unzip -l 二次校验 IPA 内容"
if ! unzip -l "${IPA_PATH}" | grep -q 'Payload/CampusRunSimulator.app/Info.plist'; then
    echo "错误：IPA 内缺少 Payload/CampusRunSimulator.app/Info.plist" >&2
    unzip -l "${IPA_PATH}" >&2 || true
    exit 1
fi
unzip -l "${IPA_PATH}" | grep 'Payload/CampusRunSimulator.app/Info.plist'

echo "[F70] 完成：未签名 IPA 已生成并通过双重门禁 -> ${IPA_PATH}"
echo "[F70] 注意：该 IPA 未签名，不可直接安装到未越狱设备；安装方式见 README.md"
