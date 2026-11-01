# CanSat ネットワーク監視 & 自動通知システム

Raspberry Pi Zero 2 W の起動時やネットワーク切り替え時に、現在の接続先Wi-Fi（SSID）とIPアドレスをDiscordへ自動通知するシステムです。

---

## よく使う操作（日常運用）

SSHログイン後、短縮コマンド `cs`（またはフルパス）を実行してマネージャーを起動します。

```bash
cs
# または: ~/cansat/config_manager.sh
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
git clone [https://github.com/sho3ca/cansat-network-monitor.git](https://github.com/sho3ca/cansat-network-monitor.git) ~/cansat

# 実行権限を付与
chmod +x ~/cansat/*.py ~/cansat/*.sh

# 短縮コマンド（cs）の登録
echo "alias cs='bash ~/cansat/config_manager.sh'" >> ~/.bashrc
source ~/.bashrc
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
| `config_manager.sh` | Wi-Fi追加・優先度変更・削除やDiscord設定を行う対話型ツール | GitHub（共通） |
| `ip_monitor.py` | ネットワーク監視とDiscord通知を実行する常駐スクリプト | GitHub（共通） |
| `.gitignore` | 個人設定ファイルをGit管理から除外する設定 | GitHub（共通） |
| `~/cansat_config.env` | Discord Webhook URLや機体名が保存される個人設定ファイル | 各自のmicroSD内（非公開） |
