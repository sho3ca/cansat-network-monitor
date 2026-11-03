# CanSat ネットワーク監視 & 自動通知システム

Raspberry Pi Zero 2 W の起動時やネットワーク切り替え時に、現在の接続先Wi-Fi（SSID）とIPアドレスをDiscordへ自動通知するシステム  
現場でのテザリング接続の自動化や、緊急用のPC直接接続（USB OTG）にも対応　　
'cansat'としてリポジトリをクローン

---

## 🚀 初回セットアップ（ワンライナー導入）

新しいmicroSDカードを作成した際や新規機体では、ターミナルで以下の1行を実行するだけで全設定が完了する

```bash
git clone https://github.com/sho3ca/cansat-network-monitor.git ~/cansat && bash ~/cansat/setup.sh && source ~/.bashrc
```

### `setup.sh` が自動で実行する内容:
1. スクリプト類（`.sh`, `.py`）への実行権限付与
2. 環境変数設定ファイル（`~/cansat_config.env`）の初期化
3. 短縮コマンド（`cs`, `cs-update`）の `~/.bashrc` への登録
4. 常駐バックグラウンド監視サービス（`ip-monitor.service`）の登録・即時起動
5. PC直結用 USB OTG（有線LANエミュレーション / `dwc2`, `g_ether`, `usb0`）の自動構成

> **注記:** USB OTG（PC直結）をハードウェアレベルで有効化するため、初回セットアップ完了後は一度 `sudo reboot` で再起動するように

---

## 🥫 主な操作

SSHログイン後、短縮コマンド `cs` を入力してマネージャーを起動

```bash
cs
# エイリアス未反映の場合: bash ~/cansat/config_manager.sh
```

### 主なメニュー操作
- **現在の設定・接続状態を確認する**: `1` を選択（優先度順のWi-Fi一覧とIPを表示）
- **Discordの通知先URLを変更する**: `2` を選択
- **新しいWi-Fiを追加する**: `3` を選択
  - **安全登録**: 現在のSSH接続を切らずに事前登録（テザリング追加に推奨）
  - **スキャン選択**: 周囲の電波を検索して番号選択で接続（15秒ロールバック保護付き）
- **Wi-Fiの優先度を変更する**: `4` を選択（テザリング最優先化などの調整）
- **不要なWi-Fi設定を削除する**: `5` を選択（接続失敗した設定の整理）
- **指定Wi-Fiへ手動接続テストする**: `6` を選択（失敗時ロールバック保護付き）
- **周囲のWi-Fi電波をスキャンする**: `7` を選択（2.4GHzの電波強度を確認）
- **機体名（識別名）を変更する**: `8` を選択
- **通知サービスの稼働ログを確認する**: `9` を選択（通知不達時のデバッグ）
- **設定ファイルを直接編集する**: `10` を選択（`nano ~/cansat_config.env`）

---

## 🔌 PC直接接続（USB OTG / 非常用アクセス）

Wi-Fi環境がない屋外やネットワークトラブル時でも、microUSBケーブル1本でPCと直接通信できる

1. Raspberry Pi Zero 2 W の **内側USBポート（データ通信用）** とPCをmicroUSBケーブルで接続する
2. PC側のターミナル（PowerShell / コマンドプロンプト等）から以下で接続する:
   ```bash
   ssh pi@cansat.local
   # または
   ssh pi@raspberrypi.local
   ```
※ Wi-Fiの電波状況に関係なく、有線LANエミュレーション経由ログイン可能

---

## 🔄 プログラムの最新化（コード更新）

PC側でGitHubの共通コードを更新した場合、ラズパイ側で以下を実行するだけで最新版に同期される（個人のWi-Fi設定やWebhook URL、エイリアス設定は保持される）

```bash
cs-update
```
※ 手動で実行する場合:
```bash
(cd ~/cansat && git pull) && sudo systemctl restart ip-monitor.service
```

---

## 💡 便利コマンド集

SSH接続中のターミナルで役立つコマンド群

### 1. 登録済みエイリアスの確認
`~/.bashrc` に設定が正しく入っているか確認できる

```bash
grep "alias cs" ~/.bashrc
```

### 2. 常駐サービスの動作ログリアルタイム確認
通知がDiscordに届かない場合、リアルタイムで何が起きているかを確認できる

```bash
journalctl -u ip-monitor.service -f
# （終了時は Ctrl + C）
```

---

## 📁 ファイル構成と役割

| ファイル名 | 役割 | 管理場所 |
| :--- | :--- | :--- |
| `setup.sh` | 環境構築・サービス登録・USB OTG設定を一括実行するインストーラー | GitHub（共通） |
| `config_manager.sh` | Wi-Fi追加・優先度変更・削除やDiscord設定を行う対話型ツール | GitHub（共通） |
| `ip_monitor.py` | ネットワーク監視とDiscord通知を実行する常駐スクリプト（2秒周期監視） | GitHub（共通） |
| `.gitignore` | 個人設定ファイルをGit管理から除外する設定 | GitHub（共通） |
| `~/cansat_config.env` | Discord Webhook URLや機体名が保存される個人設定ファイル | 各自のmicroSD内（非公開） |
| `~/.bashrc` | `cs` などの短縮コマンド（エイリアス）が保存される設定 | 各自のOS環境内（非公開） |
