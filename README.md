# CanSat ネットワーク監視 & 自動通知システム

Raspberry Pi Zero 2 W の起動時やネットワーク切り替え時に、現在の接続先Wi-Fi（SSID）とIPアドレスをDiscordへ自動通知するシステムです。

---

## よく使う操作（日常運用）

SSH接続後、以下のコマンドで設定マネージャーを起動して各操作を行います。

```bash
~/cansat/config_manager.sh
```

### 主なメニュー操作）
- **現在の設定・接続状態を確認**: `1` を選択
- **Wi-Fiを追加**: `3` を選択（SSIDとパスワードを入力
- **不要なWi-Fiを削除**: `4` を選択（番号を選んで削除）
- **周囲のWi-Fiをスキャン**: `6` を選択（2.4GHzの電波強度を確認）
- **Discordの通知先URLを変更**: `2` を選択

---

## プログラムの最新化（コード更新）

PC側でGitHubの共通コードを更新した場合、ラズパイ側で以下を実行するだけで最新版に同期されます（個人のWi-Fi設定やWebhook URLは保持されます）。

```bash
cd ~/cansat
git pull
sudo systemctl restart ip-monitor.service
```

---

## 初回セットアップ手順（新しいmicroSDカード作成時のみ）

新しい環境や別の機体をセットアップする際、最初に一度だけ実行する手順です。

### 1. リポジトリの取得と認証情報の保存

```bash
# 認証情報をSDカード内に保存（2回目以降のトークン入力を省略）
git config --global credential.helper store

# リポジトリをクローン
git clone [https://github.com/](https://github.com/)<GitHubユーザー名>/cansat-network-monitor.git ~/cansat

# 実行権限を付与
chmod +x ~/cansat/*.py ~/cansat/*.sh
```

### 2. バックグラウンド自動起動（systemd）の登録

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

## ファイル構成と役割

| ファイル名 | 役割 | 管理場所 |
| :--- | :--- | :--- |
| `config_manager.sh` | Wi-Fi追加・削除・スキャンやDiscord設定を行う対話型ツール | GitHub（共通） |
| `ip_monitor.py` | ネットワーク監視とDiscord通知を実行する常駐スクリプト | GitHub（共通） |
| `.gitignore` | 個人設定ファイルをGit管理から除外する設定 | GitHub（共通） |
| `~/cansat_config.env` | Discord Webhook URLや機体名が保存される個人設定ファイル | 各自のmicroSD内（非公開） |
