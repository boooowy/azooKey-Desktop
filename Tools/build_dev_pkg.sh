#!/bin/bash
# 社内などで試してもらうための pkg を作る。
#
# pkgbuild.sh は Developer ID の証明書と公証が前提だが、これは Xcode の署名設定
# (Apple Development / Personal Team でよい) のまま作る。公証していないので、
# 受け取った人は初回だけシステム設定で開くのを許可する必要がある。
# 受け取る人向けの手順は docs/dev-pkg-install.md。
#
# 使い方: ./Tools/build_dev_pkg.sh [--ignore-lint]
set -euo pipefail

IGNORE_LINT=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ignore-lint) IGNORE_LINT=true ;;
        *) echo "Unknown parameter passed: $1" >&2; exit 1 ;;
    esac
    shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT_NAME="azooKeyMac"
PKG_IDENTIFIER="dev.boooowy.inputmethod.azooKeyMac"
WORK_DIR="./build/dev-pkg"
ARCHIVE_PATH="${WORK_DIR}/archive.xcarchive"
ROOT_PATH="${WORK_DIR}/root"
SCRIPTS_PATH="${WORK_DIR}/scripts"
# distribution.xml がこの名前の pkg を参照している
COMPONENT_PKG="${WORK_DIR}/azooKey-tmp.pkg"

# どの版を配ったか分かるように、日付とコミットを名前に入れる
VERSION_LABEL="$(date +%Y%m%d)-$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    VERSION_LABEL="${VERSION_LABEL}-dirty"
fi
OUTPUT_PKG="./build/azooKey-dev-${VERSION_LABEL}.pkg"

if [ "${IGNORE_LINT}" = false ]; then
    if ! command -v swiftlint &> /dev/null; then
        echo "swiftlint could not be found. Install it with \`brew install swiftlint\`, or rerun with --ignore-lint." >&2
        exit 1
    fi
    swiftlint --fix --format
    swiftlint --quiet --strict
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${ROOT_PATH}" "${SCRIPTS_PATH}"

# 1. Archive (install.sh と同じ署名設定を使う)
xcodebuild_args=(
    -project "${PROJECT_NAME}.xcodeproj"
    -scheme "${PROJECT_NAME}"
    -configuration Release
    -destination "generic/platform=macOS"
    clean archive
    -archivePath "${ARCHIVE_PATH}"
)
if command -v xcpretty &> /dev/null; then
    xcodebuild "${xcodebuild_args[@]}" | xcpretty
else
    xcodebuild "${xcodebuild_args[@]}"
fi

APP_PATH="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
    echo "App not found in archive: ${APP_PATH}" >&2
    exit 1
fi
if [ ! -x "${APP_PATH}/Contents/Helpers/ConverterServer/ConverterServer" ]; then
    echo "ConverterServer not found in app: ${APP_PATH}" >&2
    exit 1
fi
codesign --verify --deep --strict "${APP_PATH}"

# 2. pkg の中身とインストール後スクリプトを用意する (pkgbuild.sh と同じ構成)
ditto "${APP_PATH}" "${ROOT_PATH}/${PROJECT_NAME}.app"
cp ./pkg-scripts/postinstall "${SCRIPTS_PATH}/postinstall"
cp ./Tools/write_converter_server_launch_agent.sh "${SCRIPTS_PATH}/write_converter_server_launch_agent.sh"
chmod +x "${SCRIPTS_PATH}/postinstall" "${SCRIPTS_PATH}/write_converter_server_launch_agent.sh"

# 3. pkg を作る。署名と公証はしない
pkgbuild --root "${ROOT_PATH}" \
         --scripts "${SCRIPTS_PATH}" \
         --component-plist ./pkg.plist \
         --identifier "${PKG_IDENTIFIER}" \
         --version 0 \
         --install-location "/Library/Input Methods" \
         "${COMPONENT_PKG}"

productbuild --distribution ./distribution.xml \
             --package-path "${WORK_DIR}" \
             "${OUTPUT_PKG}"

rm -f "${COMPONENT_PKG}"

echo "Created ${OUTPUT_PKG}"
