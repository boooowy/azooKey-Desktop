# 開発版 azooKey のインストール手順

この pkg は、この fork を試してもらうための開発版です。
Apple の公証を受けていないので、初回だけ macOS に開くのを許可する手順があります。

## 必要な環境

- macOS 15 以降
- 管理者パスワード (インストール時に聞かれます)

## インストール

1. 受け取った `azooKey-dev-<日付>-<コミット>.pkg` をダブルクリックします。
2. 「開発元を確認できないため開けません」などと表示されたら、「完了」または「OK」で閉じます。
3. システム設定を開き、「プライバシーとセキュリティ」を選びます。
4. 下のほうにある「"azooKey-dev-….pkg" は…」の横の「このまま開く」を押し、パスワードを入力します。
5. インストーラの案内に沿ってインストールします。
6. macOS からログアウトして、ログインし直します。
7. システム設定の「キーボード」で、入力ソースの「編集」を押します。
8. 「+」を押し、「日本語」から azooKey を選んで追加します。
9. メニューバーの入力メニューから azooKey を選びます。

## 新しい版に入れ替える

新しい pkg を受け取ったら、同じ手順でインストールします。
入力ソースの追加も、ログアウトもしなくてかまいません。
インストール中に動いている azooKey が止まり、次に入力するときに新しい版が起動します。
新しい版にならないときは、ログアウトしてログインし直してください。

## アンインストール

1. 入力ソースから azooKey を削除します。
2. ターミナルで次を実行します。

```bash
launchctl bootout "gui/$(id -u)/dev.boooowy.inputmethod.azooKeyMac.ConverterServer" 2>/dev/null || true
sudo rm -rf "/Library/Input Methods/azooKeyMac.app"
sudo rm -f /Library/LaunchAgents/dev.boooowy.inputmethod.azooKeyMac.ConverterServer.plist
rm -f ~/Library/LaunchAgents/dev.boooowy.inputmethod.azooKeyMac.ConverterServer.plist
sudo pkgutil --forget dev.boooowy.inputmethod.azooKeyMac 2>/dev/null || true
```

3. ログアウトして、ログインし直します。

## 困ったとき

- **入力ソースに azooKey が出てこない。** ログアウトしてログインし直してから、もう一度探してください。
- **変換候補が出ない。** 変換サーバーのログを確認して、配布した人に送ってください。

```bash
cat /tmp/dev.boooowy.inputmethod.azooKeyMac.ConverterServer.stderr.log
```

- **公式版の azooKey と並べて使う。** 公式版とは別のアプリとして入ります。入力ソースにはどちらも azooKey と表示されるので、使うほうだけを残してください。
