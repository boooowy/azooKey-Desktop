#!/bin/sh
set -eu

swift_configuration=debug
if [ "${CONFIGURATION}" = "Release" ]; then
    swift_configuration=release
fi

# Swift 6.4 以降の既定の build system (swiftbuild) は、実行ファイルの
# LC_BUILD_VERSION に SDK version として deployment target (13.0) を記録する。
# macOS はこの SDK version を見て Metal の既定言語バージョンを 3.0 にするため、
# llama.cpp が実行時にコンパイルする shader から bf16 kernel が消え、
# ggml_metal_init が存在しない kernel を読み込もうとして abort する。
# native build system は実際の SDK version を記録するので、こちらを明示する。
swift build --package-path "${SRCROOT}/Core" --product ConverterServer -c "${swift_configuration}" --build-system native

server_source="${SRCROOT}/Core/.build/${swift_configuration}/ConverterServer"
server_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/ConverterServer"
server_destination="${server_directory}/ConverterServer"
server_build_directory="${SRCROOT}/Core/.build/${swift_configuration}"
mkdir -p "${server_directory}"
cp "${server_source}" "${server_destination}"

# SwiftPM の Bundle.module は、実行時に Bundle.main.bundleURL 直下を最初に探し、
# 見つからない場合はビルド時の絶対パスへフォールバックする。Helperを独立した
# Contents/Helpers配下のdirectoryに置くと、そのdirectoryがBundle.mainになるため、
# resource bundleも同じ場所に置ける。app bundle root直下はcodesignで許可されない。
for resource_bundle in "${server_build_directory}"/*.bundle; do
    if [ -d "${resource_bundle}" ]; then
        resource_bundle_name="$(basename "${resource_bundle}")"
        embedded_resource_bundle="${server_directory}/${resource_bundle_name}"
        rm -rf "${embedded_resource_bundle}"
        ditto "${resource_bundle}" "${embedded_resource_bundle}"
        # 古いcommand-line SwiftPM buildが生成するflatなbundleはInfo.plistを持たないため、
        # archiveのcodesignが正規のresource bundleとして検証できるよう補う。
        # Swift 6.4以降はContents/Info.plistを持つbundleを生成するので、そこに足すと
        # bundle rootにsealされないファイルが残りcodesign --verifyが失敗する。
        if [ ! -f "${embedded_resource_bundle}/Info.plist" ] && [ ! -f "${embedded_resource_bundle}/Contents/Info.plist" ]; then
            cp "${SRCROOT}/Tools/ConverterServerResourceBundleInfo.plist" "${embedded_resource_bundle}/Info.plist"
        fi
    fi
done

if ! otool -l "${server_destination}" | grep -q "@executable_path/../../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../../Frameworks" "${server_destination}"
fi

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    server_identifier="${PRODUCT_BUNDLE_IDENTIFIER}.ConverterServer"
    # ConverterServerも学習データや個人化モデルをApp Groupから読む。entitlementなしで
    # Group Containersを直接参照すると、macOSが「ほかのアプリのデータ」と判定して
    # ファイルごとのアクセス確認を表示するため、埋め込みHelperにも同じGroupを付与する。
    codesign \
        --force \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --identifier "${server_identifier}" \
        --options runtime \
        --entitlements "${SRCROOT}/azooKeyMac/ConverterServer.entitlements" \
        --timestamp=none \
        "${server_destination}"
    codesign --verify --strict "${server_destination}"

    for resource_bundle in "${server_directory}"/*.bundle; do
        if [ -d "${resource_bundle}" ]; then
            codesign \
                --force \
                --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
                --timestamp=none \
                "${resource_bundle}"
            codesign --verify --strict "${resource_bundle}"
        fi
    done
fi
