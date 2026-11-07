# CanSat ネットワーク監視 & 自動通知システム
(最終更新日: 2026年11月8日)

Raspberry Pi Zero 2 W の起動時やネットワーク切り替え時に、現在の接続先Wi-Fi（SSID）とIPアドレスをDiscordへ自動通知するシステム
現場でのテザリング接続の自動化、上空実験用の一時Wi-Fiロック機能、緊急用のPC直接接続（USB OTG）にも対応

---

## 🚀 初回セットアップ（ワンライナー導入）

新しいmicroSDカードを作成した際や新規機体では、ターミナルで以下の1行を実行するだけで全設定が完了する

```bash
git clone https://github.com/sho3ca/cansat-network-monitor.git ~/cansat && bash ~/cansat/setup.sh && source ~/.bashrc
```

### setup.sh が自動で実行する内容:
1. スクリプト類（.sh, .py）への実行権限付与
2. 環境変数設定ファイル（~/cansat_config.env）の初期化
3. 短縮コマンド（cs, cs-update）の ~/.bashrc への登録
4. 常駐バックグラウンド監視サービス（ip-monitor.service）の登録・即時起動
5. PC直結用 USB OTG（有線LANエミュレーション / dwc2, g_ether, usb0）の自動構成

> **注記:** USB OTG（PC直結）をハードウェアレベルで有効化するため、初回セットアップ完了後は一度 sudo reboot で再起動すること

---

## 🥫 主な操作

SSHログイン後、短縮コマンド cs を入力してマネージャーを起動する

```bash
cs  # エイリアス未反映の場合: bash ~/cansat/config_manager.sh
```
※各プロンプトでは 0 を入力することで、即座にキャンセルしてメニューへ戻ることができる。

### 【メインメニュー】
- **1) 現在の設定と登録済みWi-Fi一覧を確認**: 優先度順のWi-Fi一覧と現在のIP・接続SSIDを表示（通常時の再試行回数表示を隠し、視認性を向上）
- **2) 新しいWi-Fiを追加**:
  - *事前登録*: 現在の接続を切らずに設定のみ追加（現場でのテザリング追加に推奨）
  - *スキャン選択 / 手入力*: 接続を試行。失敗時は15秒で元のWi-Fiに自動復帰（ロールバック保護付き）
- **3) Wi-Fiの自動接続優先度を変更**: 0〜100の数値で優先順位を調整（数値が大きいほど優先）
- **4) 登録済みWi-Fiへ接続テスト**: 指定Wi-Fiへの切り替えテスト（15秒応答なしで自動復帰。閉域網スマホテザリングでも誤切断を防ぐゲートウェイ判定搭載）
- **5) システム・詳細設定へ**: サブメニューへ移動する
- **0) 終了**

### 【システム・詳細設定 (サブメニュー)】
- **1) 【実験用】現在Wi-Fiに一時固定**: 上空投下時などに他のWi-Fiへ勝手にローミングしないよう、現在のSSIDを「優先度100・無限再試行」でメモリ上のみロックする（ディスクを書き換えないため、再起動で自動リセットされる）
- **2) 【実験用】一時固定解除**: 手動で一時ロックを解除し、通常の自動接続設定に戻す
- **3) 周囲のWi-Fi電波をスキャン**: 2.4GHzの電波強度や周辺SSIDを確認
- **4) 不要なWi-Fi設定を削除**: 接続失敗したプロファイル等の整理
- **5) Discord Webhook URLを設定・変更**: 自動通知の送信先URLを登録
- **6) 機体名 (識別名) を変更**: 機体名を変更し、Discord通知に反映
- **7) 監視サービスログ確認**: 通知不達時などのデバッグ用に、直近10行のシステムログを確認
- **8) 設定ファイルを直接編集 (nano)**: ~/cansat_config.env をエディタで直接開く
- **0) メインメニューに戻る**

---

## 🔌 PC直接接続（USB OTG / 非常用アクセス）

Wi-Fi環境がない屋外やネットワークトラブル時でも、microUSBケーブル1本でPCと直接通信できる

1. Raspberry Pi Zero 2 W の **内側USBポート（データ通信用）** とPCをmicroUSBケーブルで接続する
2. PC側のターミナル（PowerShell / コマンドプロンプト等）から以下で接続する:
```bash
ssh pi@cansat.local  # または ssh pi@raspberrypi.local
```
※ Wi-Fiの電波状況に関係なく、有線LANエミュレーション経由でログイン可能

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

## ⚠️ ローカルの変更を破棄して完全同期する（強制リセット）

ラズパイ側で誤ってファイルを書き換えてしまったり、コンフリクト等でうまく更新できない場合は、ローカルの変更をすべて破棄してGitHub（リモート）の最新状態へ強制的に同期させることができる（これやっとけば大体どうにかなる）

※ 他のディレクトリからクローンした別リポジトリや、ホーム直下の設定ファイル（~/cansat_config.env）には一切影響しない

```bash
cd ~/cansat

# 1. ローカルの未追跡ファイルや手動変更を完全に消去
git reset --hard HEAD
git clean -fd

# 2. GitHubの最新情報を取得
git fetch origin main

# 3. リモートの最新状態に合わせて強制上書き一致
git reset --hard origin/main

# 4. 実行権限を再付与し、監視サービスを再起動
chmod +x setup.sh config_manager.sh ip_monitor.py
sudo systemctl restart ip-monitor.service
```
---

## 💡 便利コマンド集

SSH接続中のターミナルで役立つコマンド群。

### 1. 登録済みエイリアスの確認
~/.bashrc に設定が正しく入っているか確認できる。
```bash
grep "alias cs" ~/.bashrc
```

### 2. 常駐サービスの動作ログリアルタイム確認
通知がDiscordに届かない場合、リアルタイムで何が起きているかを確認できる。
```bash
journalctl -u ip-monitor.service -f  # （終了時は Ctrl + C）
```
---

## 📁 ファイル構成と役割

| ファイル名 | 役割 | 管理場所 |
| --- | --- | --- |
| setup.sh | 環境構築・サービス登録・USB OTG設定を一括実行するインストーラー | GitHub（共通） |
| config_manager.sh | 階層メニューによるWi-Fi管理や一時ロックを行う対話型CLIツール | GitHub（共通） |
| ip_monitor.py | ネットワーク監視とDiscord通知を実行する常駐スクリプト (バタつき防止の15秒クールダウン対応) | GitHub（共通） |
| DESIGN_DECISIONS.md | 本ツールのアーキテクチャ設計・非採用機能に関する判断ドキュメント | GitHub（共通） |
| .gitignore | 個人設定ファイルをGit管理から除外する設定 | GitHub（共通） |
| ~/cansat_config.env | Discord Webhook URLや機体名が保存される個人設定ファイル | 各自のmicroSD内（非公開） |
| ~/.bashrc | cs などの短縮コマンド（エイリアス）が保存される設定 | 各自のOS環境内（非公開） |
