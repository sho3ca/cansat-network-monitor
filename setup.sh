#!/bin/bash
# ==============================================================================
# 【プログラム名】setup.sh
# 【役割】
#    CanSatネットワーク監視システム & PC直結USB環境の全自動一括インストーラー。
# ==============================================================================

set -e

REPO_DIR="$HOME/cansat"
CONFIG_FILE="$HOME/cansat_config.env"
SERVICE_FILE="/etc/systemd/system/ip-monitor.service"

echo "=========================================="
echo " 🚀 CanSat 環境セットアップを開始します"
echo "=========================================="

# 1. 実行権限の付与
echo "[1/5] スクリプトの実行権限を付与中..."
chmod +x "$REPO_DIR"/*.sh "$REPO_DIR"/*.py 2>/dev/null || true

# 2. 設定ファイルの初期化（存在しない場合のみ生成）
echo "[2/5] 設定ファイル (~/cansat_config.env) の初期化中..."
if [ ! -f "$CONFIG_FILE" ]; then
    touch "$CONFIG_FILE"
    echo "# CanSat Local Environment Configuration" > "$CONFIG_FILE"
    echo "DEVICE_NAME=\"CanSat-Rover\"" >> "$CONFIG_FILE"
    echo "DISCORD_WEBHOOK=\"\"" >> "$CONFIG_FILE"
fi

# 3. エイリアス（短縮コマンド）の自動登録
echo "[3/5] 短縮コマンド (cs, cs-update) を ~/.bashrc に登録中..."
sed -i '/alias cs=/d' "$HOME/.bashrc"
sed -i '/alias cs-update=/d' "$HOME/.bashrc"

cat << 'BASHRC_EOF' >> "$HOME/.bashrc"
alias cs='bash ~/cansat/config_manager.sh'
alias cs-update='(cd ~/cansat && git pull) && sudo systemctl restart ip-monitor.service'
BASHRC_EOF

# 4. 常駐サービス (ip-monitor.service) の作成と起動
echo "[4/5] バックグラウンド監視サービスを登録・起動中..."
sudo bash -c "cat << 'SERVICE_EOF' > $SERVICE_FILE
[Unit]
Description=CanSat IP Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
ExecStart=/usr/bin/python3 $REPO_DIR/ip_monitor.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF"

sudo systemctl daemon-reload
sudo systemctl enable ip-monitor.service >/dev/null 2>&1
sudo systemctl restart ip-monitor.service

# 5. PC直結用 USB OTG（有線LANエミュレーション）の設定
echo "[5/5] PC直結用 USB OTG イーサネットを設定中..."
BOOT_CONFIG="/boot/firmware/config.txt"
[ ! -f "$BOOT_CONFIG" ] && BOOT_CONFIG="/boot/config.txt"

if ! grep -q "dtoverlay=dwc2" "$BOOT_CONFIG"; then
    echo "dtoverlay=dwc2" | sudo tee -a "$BOOT_CONFIG" >/dev/null
fi

if ! grep -q "^g_ether" /etc/modules 2>/dev/null; then
    echo "g_ether" | sudo tee -a /etc/modules >/dev/null
fi

# USBインターフェース用のlink-localプロファイル作成
sudo nmcli connection delete "USB-OTG" >/dev/null 2>&1 || true
sudo nmcli connection add type ethernet ifname usb0 con-name "USB-OTG" ipv4.method link-local >/dev/null 2>&1 || true

echo ""
echo "=========================================================="
echo " ✅ セットアップがすべて正常に完了しました！"
echo "----------------------------------------------------------"
echo " 1. 'cs' と入力して Wi-Fi や Discord Webhook を設定してください。"
echo " 2. USB OTG（PC直結）を有効化するため、一度再起動を推奨します:"
echo "    sudo reboot"
echo "=========================================================="
