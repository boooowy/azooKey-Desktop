#!/bin/sh
# インストール済みの azooKey (install.sh と pkg のどちらで入れたものも) を消す。
#
# 上書きインストールならこれは要らない。pkg のインストール後スクリプトが
# 動いている azooKey を止めるので、ログアウトしなくても新しい版になる。
# 入れ直しても直らないときや、きれいな状態から試したいときに使う。
#
# 使い方: ./Tools/uninstall_azookey.sh
set -eu

service_name="dev.boooowy.inputmethod.azooKeyMac.ConverterServer"
pkg_identifier="dev.boooowy.inputmethod.azooKeyMac"
app_path="/Library/Input Methods/azooKeyMac.app"
system_agent_path="/Library/LaunchAgents/${service_name}.plist"
user_agent_path="${HOME}/Library/LaunchAgents/${service_name}.plist"

# 変換サーバーと入力メソッドを止める
launchctl bootout "gui/$(id -u)/${service_name}" >/dev/null 2>&1 || true
pkill -x azooKeyMac >/dev/null 2>&1 || true
pkill -x ConverterServer >/dev/null 2>&1 || true

# アプリと変換サーバーの登録を消す。pkg と install.sh で登録先が違うので両方消す
sudo rm -rf "${app_path}"
sudo rm -f "${system_agent_path}"
rm -f "${user_agent_path}"

# pkg のインストール記録を消す (install.sh だけで入れた場合は記録がない)
sudo pkgutil --forget "${pkg_identifier}" >/dev/null 2>&1 || true

echo "Removed azooKey."
echo "Input source settings are kept. Install the pkg again to use azooKey."
