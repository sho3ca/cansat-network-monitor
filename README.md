# CanSat ネットワーク監視 & 自動通知システム

Raspberry Pi Zero 2 W の起動時やネットワーク切り替え時に、現在の接続先Wi-Fi（SSID）とIPアドレスをDiscordへ自動通知するシステム

---

## 🥫 主な操作

SSHログイン後、短縮コマンド `cs` を入力してマネージャーを起動

```bash
cs
# エイリアス未設定の場合: bash ~/cansat/config_manager.sh
```

### 主なメニュー操作
- **現在の設定・接続状態を確認する**: `1` を選択（優先度順のWi-Fi一覧とIPを表示）
- **Discordの通知先URLを変更する**: `2` を選択
- **新しいWi-Fiを追加する**: `3` を選択（SSID・パスワード・優先度を入力）
- **Wi-Fiの優先度を変更する**: `4` を選択（テザリング最優先化などの調整）
- **不要なWi-Fi設定を削除する**: `5` を選択（接続失敗した設定の整理）
- **指定Wi-Fiへ手動接続テストする**: `6` を選択（その場で切り替え試行）
- **周囲のWi-Fi電波をスキャンする**: `7` を選択（2.4GHzの電波強度を確認）
- **機体名（識別名）を変更する**: `8` を選択
- **通知サービスの稼働ログを確認する**: `9` を選択（通知不達時のデバッグ）

---

## 🔄 プログラムの最新化（コード更新）

PC側でGitHubの共通コードを更新した場合、ラズパイ側で以下を実行するだけで最新版に同期される（個人のWi-Fi設定やWebhook URL、エイリアス設定は保持される）。

```bash
cd ~/cansat
git pull
sudo systemctl restart ip-monitor.service
```
以下のように一回でつなげて実行も可能

```bash
(cd ~/cansat && git pull) && sudo systemctl restart ip-monitor.service
```
---

## 🛠 初回セットアップ手順（新しいmicroSDカード作成時）

新しいmicroSDカードを作成した際、最初に一度だけ実行する手順

### 1. リポジトリ取得と実行権限の付与

```bash
# 認証情報をSDカード内に保存（2回目以降のトークン入力を省略）
git config --global credential.helper store

# リポジトリをクローン
git clone [https://github.com/sho3ca/cansat-network-monitor.git](https://github.com/sho3ca/cansat-network-monitor.git) ~/cansat

# 実行権限を付与
chmod +x ~/cansat/*.py ~/cansat/*.sh
```

### 2. 短縮コマンド（エイリアス）の登録（任意）

どこからでも `cs` と打つだけでマネージャーが起動できるように設定できる（`git pull` しても消去されない）。

```bash
echo "alias cs='bash ~/cansat/config_manager.sh'" >> ~/.bashrc
source ~/.bashrc
```

### 3. バックグラウンド自動起動（systemd）の登録

OS起動時に自動でIP監視スクリプトが動くようサービス登録する

```bash
sudo bash -c 'cat << "EOF" > /etc/systemd/system/ip-monitor.service
[Unit]
Description=CanSat IP Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
ExecStart=/usr/bin/python3 /home/pi/cansat/ip_monitor.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

sudo systemctl daemon-reload
sudo systemctl enable ip-monitor.service
sudo systemctl start ip-monitor.service
```

---

## 💡 便利コマンド集

SSH接続中のターミナル（PowerShell経由等）で実行すると役立つコマンド群

### 1. コード更新＆サービス再起動の一括短縮コマンド（`cs-update`）
`cs-update`と打つだけで `git pull` とサービスの再起動を完了させたい場合は追加

```bash
echo "alias cs-update='cd ~/cansat && git pull && sudo systemctl restart ip-monitor.service && cd -'" >> ~/.bashrc
source ~/.bashrc
```
* 登録後は **`cs-update`** と打つだけで自動アップデートが完了する

### 2. 登録済みエイリアスの確認
`~/.bashrc` に設定が正しく入っているか確認できる

```bash
grep "alias cs" ~/.bashrc
```

### 3. 常駐サービスの動作ログリアルタイム確認
通知がDiscordに届かない場合、リアルタイムで何が起きているかを確認できる

```bash
journalctl -u ip-monitor.service -f
# （終了時は Ctrl + C）
```

---

## 📁 ファイル構成と役割

| ファイル名 | 役割 | 管理場所 |
| :--- | :--- | :--- |
| `config_manager.sh` | Wi-Fi追加・優先度変更・削除やDiscord設定を行う対話型ツール | GitHub（共通） |
| `ip_monitor.py` | ネットワーク監視とDiscord通知を実行する常駐スクリプト | GitHub（共通） |
| `.gitignore` | 個人設定ファイルをGit管理から除外する設定 | GitHub（共通） |
| `~/cansat_config.env` | Discord Webhook URLや機体名が保存される個人設定ファイル | 各自のmicroSD内（非公開） |
| `~/.bashrc` | `cs` などの短縮コマンド（エイリアス）が保存される設定 | 各自のOS環境内（非公開） |
