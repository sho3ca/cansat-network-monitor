#!/bin/bash
# ==============================================================================
# 【プログラム名】config_manager.sh
# 【役割】
#    Raspberry Piのネットワーク設定（Wi-Fi追加/削除/優先度変更/スキャン/接続切替）および
#    個人用設定ファイル（~/cansat_config.env）の管理を対話的に行うCLIツール。
# ==============================================================================

CONFIG_PATH="$HOME/cansat_config.env"
[ ! -f "$CONFIG_PATH" ] && touch "$CONFIG_PATH"

show_menu() {
    echo ""
    echo "=========================================="
    echo " CanSat ネットワーク & 設定マネージャー"
    echo "=========================================="
    echo "1)  現在の設定と登録済みWi-Fi一覧を確認する"
    echo "2)  Discord Webhook URLを設定・変更する"
    echo "3)  新しいWi-Fiを追加する（安全登録・スキャン選択対応）"
    echo "4)  Wi-Fiの優先度（優先順位）を変更する"
    echo "5)  不要なWi-Fi設定を削除する"
    echo "6)  指定したWi-Fiへ手動接続テストする（ロールバック付き）"
    echo "7)  周囲のWi-Fi電波をスキャンする"
    echo "8)  機体名（識別名）を変更する"
    echo "9)  Discord通知サービスの稼働状態・ログを確認する"
    echo "10) 設定ファイルを直接編集する (nano)"
    echo "0)  終了"
    echo "=========================================="
    read -p "番号を選択してください [0-10]: " choice
}

while true; do
    show_menu
    case $choice in
        1)
            echo ""
            echo "--- 設定ファイルの内容 ($CONFIG_PATH) ---"
            cat "$CONFIG_PATH"
            echo ""
            echo "--- 登録済みWi-Fi一覧（優先度が高い順） ---"
            nmcli -f NAME,AUTOCONNECT-PRIORITY,TYPE connection show | grep wifi | sort -k2 -nr
            echo ""
            echo "--- 現在の接続状態 ---"
            nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2 | awk '{print "接続中SSID: "$0}'
            hostname -I | awk '{print "現在IP: "$1}'
            ;;
        2)
            echo ""
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
            echo ""
            echo "--- Wi-Fi追加モードの選択 ---"
            echo "1) 今すぐ接続を切らずに【設定だけ事前登録】する（★テザリング追加に最も安全）"
            echo "2) 周囲の電波をスキャンして【一覧から選んで登録・接続】する"
            echo "3) SSIDを手入力して登録・接続を試みる"
            read -p "選択 [1-3] (キャンセルは0): " add_mode

            target_ssid=""
            if [ "$add_mode" = "1" ] || [ "$add_mode" = "3" ]; then
                read -p "追加するWi-FiのSSID: " target_ssid
            elif [ "$add_mode" = "2" ]; then
                echo "周囲のWi-Fiをスキャン中..."
                sudo nmcli dev wifi rescan > /dev/null 2>&1
                mapfile -t scanned_ssids < <(nmcli -t -f SSID dev wifi list | grep -v '^$' | awk '!seen[$0]++')
                if [ ${#scanned_ssids[@]} -eq 0 ]; then
                    echo "周囲に電波が見つかりませんでした。スマホのテザリング画面を開いた状態で再試行してください。"
                    continue
                fi
                echo "--- 検出されたSSID ---"
                for i in "${!scanned_ssids[@]}"; do
                    echo "$((i+1))) ${scanned_ssids[$i]}"
                done
                read -p "接続する番号を選択: " sel_num
                if [[ "$sel_num" =~ ^[0-9]+$ ]] && [ "$sel_num" -ge 1 ] && [ "$sel_num" -le "${#scanned_ssids[@]}" ]; then
                    target_ssid="${scanned_ssids[$((sel_num-1))]}"
                else
                    echo "=> キャンセルしました。"
                    continue
                fi
            else
                continue
            fi

            [ -z "$target_ssid" ] && echo "SSIDが空です。" && continue

            read -s -p "Wi-Fiパスワード: " pass
            echo ""
            read -p "自動接続優先度 (例: 自宅=10, 優先したいテザリング=20) [デフォルト: 20]: " prio
            prio=${prio:-20}

            # 既存同名プロファイルのクリーンアップ
            sudo nmcli connection delete id "$target_ssid" > /dev/null 2>&1

            if [ "$add_mode" = "1" ]; then
                # 【安全策】現在の接続を一切切断せず、NetworkManagerプロファイルのみ追加
                if sudo nmcli connection add type wifi ifname wlan0 con-name "$target_ssid" ssid "$target_ssid" \
                    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" connection.autoconnect-priority "$prio" connection.autoconnect yes; then
                    echo "=> 成功: 「$target_ssid」(優先度: $prio) を事前登録しました。"
                    echo "   ※ 現在のSSH接続は維持されています。テザリング圏内に入り次第、自動接続されます。"
                else
                    echo "=> エラー: プロファイルの作成に失敗しました。"
                fi
            else
                # 【接続試行】切断時に直前のWi-Fiへ戻すロールバック保護付き
                current_wifi=$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2)
                echo "15秒の接続テストを開始します（失敗時は自動で「$current_wifi」へ復帰します）..."
                
                (
                    sleep 15
                    if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 2 192.168.0.1 >/dev/null 2>&1; then
                        [ -n "$current_wifi" ] && sudo nmcli connection up "$current_wifi" >/dev/null 2>&1
                    fi
                ) &

                if sudo nmcli dev wifi connect "$target_ssid" password "$pass" ifname wlan0 name "$target_ssid"; then
                    sudo nmcli connection modify "$target_ssid" connection.autoconnect-priority "$prio"
                    sudo nmcli connection modify "$target_ssid" connection.autoconnect yes
                    echo "=> 成功: 「$target_ssid」への接続に成功しました。"
                else
                    echo "=> 接続に失敗したため、元の設定を保持しました。"
                fi
            fi
            ;;
        4)
            echo ""
            echo "--- 優先度を変更するWi-Fiを選択 ---"
            mapfile -t wifi_list < <(nmcli -t -f NAME,TYPE connection show | grep ':802-11-wireless$' | cut -d: -f1)
            if [ ${#wifi_list[@]} -eq 0 ]; then
                echo "登録されているWi-Fiプロファイルはありません。"
            else
                for i in "${!wifi_list[@]}"; do
                    current_prio=$(nmcli -g connection.autoconnect-priority connection show "${wifi_list[$i]}" 2>/dev/null)
                    echo "$((i+1))) ${wifi_list[$i]} (現在の優先度: ${current_prio:-0})"
                done
                read -p "番号を選択してください (キャンセルは0): " prio_num
                if [[ "$prio_num" =~ ^[0-9]+$ ]] && [ "$prio_num" -ge 1 ] && [ "$prio_num" -le "${#wifi_list[@]}" ]; then
                    target_wifi="${wifi_list[$((prio_num-1))]}"
                    read -p "新しい優先度を入力 (数値が大きいほど優先 / 例: 自宅=10, テザリング=20): " new_prio
                    if [[ "$new_prio" =~ ^-?[0-9]+$ ]]; then
                        sudo nmcli connection modify "$target_wifi" connection.autoconnect-priority "$new_prio"
                        echo "=> 「$target_wifi」の優先度を $new_prio に更新しました。"
                    else
                        echo "エラー: 半角数字を入力してください。"
                    fi
                else
                    echo "=> キャンセルしました。"
                fi
            fi
            ;;
        5)
            echo ""
            echo "--- 削除可能なWi-Fi一覧 ---"
            mapfile -t wifi_list < <(nmcli -t -f NAME,TYPE connection show | grep ':802-11-wireless$' | cut -d: -f1)
            if [ ${#wifi_list[@]} -eq 0 ]; then
                echo "登録されているWi-Fiプロファイルはありません。"
            else
                for i in "${!wifi_list[@]}"; do
                    echo "$((i+1))) ${wifi_list[$i]}"
                done
                read -p "削除したいWi-Fiの番号を入力 (キャンセルは0): " del_num
                if [[ "$del_num" =~ ^[0-9]+$ ]] && [ "$del_num" -ge 1 ] && [ "$del_num" -le "${#wifi_list[@]}" ]; then
                    target_name="${wifi_list[$((del_num-1))]}"
                    sudo nmcli connection delete "$target_name"
                    echo "=> Wi-Fi設定「$target_name」を削除しました。"
                else
                    echo "=> 削除をキャンセルしました。"
                fi
            fi
            ;;
        6)
            echo ""
            echo "--- 接続テスト可能なWi-Fi一覧 ---"
            mapfile -t wifi_conns < <(nmcli -t -f NAME,TYPE connection show | grep ':802-11-wireless$' | cut -d: -f1)
            for i in "${!wifi_conns[@]}"; do
                echo "$((i+1))) ${wifi_conns[$i]}"
            done
            read -p "接続テストしたい番号を入力: " conn_num
            if [[ "$conn_num" =~ ^[0-9]+$ ]] && [ "$conn_num" -ge 1 ] && [ "$conn_num" -le "${#wifi_conns[@]}" ]; then
                selected_conn="${wifi_conns[$((conn_num-1))]}"
                current_wifi=$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2)
                echo "「$selected_conn」への接続を試みます（15秒応答なしで「$current_wifi」へロールバック）..."
                
                (
                    sleep 15
                    if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 2 192.168.0.1 >/dev/null 2>&1; then
                        [ -n "$current_wifi" ] && sudo nmcli connection up "$current_wifi" >/dev/null 2>&1
                    fi
                ) &
                sudo nmcli connection up "$selected_conn"
            else
                echo "無効な番号です。"
            fi
            ;;
        7)
            echo ""
            echo "周囲のWi-Fi電波をスキャン中..."
            sudo nmcli dev wifi rescan > /dev/null 2>&1
            sudo nmcli -f IN-USE,SSID,MODE,CHAN,RATE,SIGNAL,SECURITY dev wifi list
            ;;
        8)
            echo ""
            read -p "機体名を入力 (例: CanSat-Rover-01): " dev_name
            sed -i '/^DEVICE_NAME=/d' "$CONFIG_PATH"
            echo "DEVICE_NAME=\"$dev_name\"" >> "$CONFIG_PATH"
            echo "=> 機体名を「$dev_name」に更新しました。"
            sudo systemctl restart ip-monitor.service > /dev/null 2>&1
            ;;
        9)
            echo ""
            echo "--- サービス状態 ---"
            systemctl is-active ip-monitor.service | awk '{print "稼働状況: "$0}'
            echo ""
            echo "--- 最新のログ（直近10行） ---"
            journalctl -u ip-monitor.service -n 10 --no-pager
            ;;
        10)
            nano "$CONFIG_PATH"
            sudo systemctl restart ip-monitor.service > /dev/null 2>&1
            ;;
        0)
            echo "終了します。"
            exit 0
            ;;
        *)
            echo "0から10の数字を入力してください。"
            ;;
    esac
done
