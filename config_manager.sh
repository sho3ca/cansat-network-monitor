#!/bin/bash
# ==============================================================================
# 【プログラム名】config_manager.sh
# 【役割】
#   各個人のmicroSDカード内に閉じた個別設定（Discord URL、Wi-Fi情報、機体名）を、
#   PowerShell等のターミナル上で対話的に確認・追加・変更するためのCLIマネージャー。
#
# 【動作仕様】
#   1. 設定ファイル（~/cansat_config.env）の作成・読み書きを行う。
#   2. メニュー番号[1-6]で各操作を実行：
#      [1] 現在の設定値およびNetworkManager登録済みWi-Fiの一覧表示
#      [2] Discord Webhook URLの安全な更新とサービスの再起動
#      [3] 新規Wi-Fiプロファイル（自宅やテザリング）の優先度付き登録
#      [4] 機体識別名（DEVICE_NAME）の変更
#      [5] nanoエディタによる設定ファイルの直接編集
#      [6] スクリプトの終了
# ==============================================================================

CONFIG_PATH="$HOME/cansat_config.env"
[ ! -f "$CONFIG_PATH" ] && touch "$CONFIG_PATH"

show_menu() {
    echo ""
    echo "=========================================="
    echo " CanSat 個人設定マネージャー"
    echo "=========================================="
    echo "1) 現在の設定を確認する"
    echo "2) Discord Webhook URLを設定・変更する"
    echo "3) 新しいWi-Fiを追加する（自宅やテザリング）"
    echo "4) 機体名（識別名）を変更する"
    echo "5) 設定を直接テキストエディタで編集する (nano)"
    echo "6) 終了"
    echo "=========================================="
    read -p "番号を選択してください [1-6]: " choice
}

while true; do
    show_menu
    case $choice in
        1)
            echo "--- 現在の設定 ($CONFIG_PATH) ---"
            cat "$CONFIG_PATH"
            echo "-----------------------------------"
            echo "--- 登録済みWi-Fi一覧 ---"
            nmcli -f NAME,TYPE,AUTOCONNECT-PRIORITY connection show | grep wifi
            ;;
        2)
            read -p "DiscordのWebhook URLを入力: " url
            if [[ "$url" =~ ^https://discord\.com/api/webhooks/ ]]; then
                sed -i '/^DISCORD_WEBHOOK=/d' "$CONFIG_PATH"
                echo "DISCORD_WEBHOOK=\"$url\"" >> "$CONFIG_PATH"
                echo "=> Discord URLを更新しました。"
                sudo systemctl restart ip-monitor.service > /dev/null 2>&1
            else
                echo "エラー: 有効なWebhook URLではありません。"
            fi
            ;;
        3)
            read -p "追加するWi-FiのSSID: " ssid
            read -s -p "Wi-Fiパスワード: " pass
            echo ""
            read -p "自動接続優先度 (標準は10、優先したい接続は20): " prio
            prio=${prio:-10}
            
            sudo nmcli connection delete "$ssid" > /dev/null 2>&1
            sudo nmcli connection add type wifi ifname wlan0 con-name "$ssid" \
              ssid "$ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" \
              connection.autoconnect-priority "$prio"
            echo "=> Wi-Fi「$ssid」(優先度: $prio) を登録しました。"
            ;;
        4)
            read -p "機体名を入力 (例: Rover-01): " dev_name
            sed -i '/^DEVICE_NAME=/d' "$CONFIG_PATH"
            echo "DEVICE_NAME=\"$dev_name\"" >> "$CONFIG_PATH"
            echo "=> 機体名を「$dev_name」に更新しました。"
            sudo systemctl restart ip-monitor.service > /dev/null 2>&1
            ;;
        5)
            nano "$CONFIG_PATH"
            sudo systemctl restart ip-monitor.service > /dev/null 2>&1
            ;;
        6)
            echo "終了します。"
            exit 0
            ;;
        *)
            echo "1から6の数字を入力してください。"
            ;;
    esac
done
