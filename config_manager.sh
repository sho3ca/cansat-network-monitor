#!/usr/bin/env bash
# ==============================================================================
# プログラム名: config_manager.sh
# 概要:
#   CanSat ネットワーク & 機体設定マネージャー。
#   wlan0 の確実な検出、ロールバック保護付きWi-Fi管理、実験用一時固定、
#   設定ファイル管理を視認性の高い階層メニューで提供します。
# ==============================================================================
set -uo pipefail

readonly SERVICE_NAME='ip-monitor.service'
readonly CONFIG_PATH="${CONFIG_PATH:-${HOME}/cansat_config.env}"
readonly ROLLBACK_SEC=15
WIFI_IFACE=""

# --- 共通ユーティリティ ---

get_wifi_iface() {
    if [[ -n "$WIFI_IFACE" ]]; then
        return 0
    fi
    if nmcli -t -f DEVICE dev status 2>/dev/null | grep -qx "wlan0"; then
        WIFI_IFACE="wlan0"
        return 0
    fi
    WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    if [[ -z "$WIFI_IFACE" ]]; then
        echo "エラー: 有効なWi-Fiインターフェースが見つかりません。" >&2
        return 1
    fi
}

list_wifi() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}'
}

get_current_conn() {
    get_wifi_iface || return 1
    nmcli -g GENERAL.CONNECTION,GENERAL.CON-UUID dev show "$WIFI_IFACE" 2>/dev/null | tr '\n' '\t'
}

set_config_env() {
    local key="$1" val="$2"
    touch "$CONFIG_PATH" && chmod 600 "$CONFIG_PATH"
    grep -v "^${key}=" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" 2>/dev/null || true
    echo "${key}=\"${val}\"" >> "${CONFIG_PATH}.tmp"
    mv -f "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

get_config_env() {
    grep "^${1}=" "$CONFIG_PATH" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d '"'
}

check_connectivity() {
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    local gw
    gw="$(ip route show dev "${WIFI_IFACE:-wlan0}" 2>/dev/null | awk '/default/{print $3; exit}')"
    [[ -n "$gw" ]] && ping -c1 -W2 "$gw" >/dev/null 2>&1
}

select_wifi_profile() {
    local -n out_var=$1
    local prompt_msg="$2"
    mapfile -t _profiles < <(list_wifi)
    ((${#_profiles[@]} == 0)) && { echo "登録済みWi-Fiがありません。"; return 2; }
    
    echo -e "\n$prompt_msg"
    for i in "${!_profiles[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${_profiles[$i]}"
    done
    echo "   0) キャンセル"
    read -r -p "番号を選択: " sel
    [[ "$sel" =~ ^[1-9][0-9]*$ ]] && ((sel <= ${#_profiles[@]})) && { out_var="${_profiles[$((sel-1))]}"; return 0; }
    echo "キャンセルしました。"; return 2
}

restart_service() {
    sudo systemctl restart "$SERVICE_NAME" 2>/dev/null && echo "監視サービスを再起動しました。"
}

# --- メインメニュー対応アクション ---

action_status() {
    echo "=== 設定 & 接続状態 ==="
    [[ -s "$CONFIG_PATH" ]] && awk '/^DISCORD_WEBHOOK=/{print "DISCORD_WEBHOOK=\"(設定済み)\""; next} {print}' "$CONFIG_PATH" || echo "(設定なし)"
    echo -e "\n--- 登録済みWi-Fi (優先度順) ---"
    while IFS= read -r p; do
        prio=$(nmcli -g connection.autoconnect-priority connection show id "$p" 2>/dev/null || echo 0)
        printf " %3s  %s\n" "${prio:-0}" "$p"
    done < <(list_wifi) | sort -rn
    
    echo -e "\n--- 現在の通信状態 ---"
    get_wifi_iface && {
        curr=$(get_current_conn)
        echo "接続中SSID : ${curr%%$'\t'*}"
        ip -4 -o addr show dev "$WIFI_IFACE" 2>/dev/null | awk '{split($4, a, "/"); print "IPアドレス : " a[1]}'
    }
}

action_add_wifi() {
    get_wifi_iface || return 1
    echo -e "\n--- Wi-Fi追加モードの選択 ---"
    echo "  1) 事前登録 (現在の接続を維持したまま設定のみ追加)"
    echo "  2) 電波スキャンから選択して接続"
    echo "  3) SSIDを手入力して接続"
    echo "  0) キャンセル"
    read -r -p "選択 [0-3]: " mode
    [[ ! "$mode" =~ ^[1-3]$ ]] && { echo "キャンセルしました。"; return 2; }

    local ssid="" pass="" prio=20
    if [[ "$mode" == "2" ]]; then
        echo "周囲のWi-Fiをスキャン中..."
        sudo nmcli dev wifi rescan ifname "$WIFI_IFACE" 2>/dev/null && sleep 1
        mapfile -t ssids < <(nmcli --terse --fields SSID dev wifi list ifname "$WIFI_IFACE" 2>/dev/null | awk 'NF && !seen[$0]++')
        if ((${#ssids[@]} == 0)); then
            echo "電波が見つかりませんでした。"; return 2
        fi
        echo -e "\n--- 検出されたSSID ---"
        for i in "${!ssids[@]}"; do
            printf "  %2d) %s\n" "$((i+1))" "${ssids[$i]}"
        done
        echo "   0) キャンセル"
        read -r -p "接続する番号を選択: " s_idx
        [[ "$s_idx" =~ ^[1-9][0-9]*$ ]] && ((s_idx <= ${#ssids[@]})) && ssid="${ssids[$((s_idx-1))]}" || { echo "キャンセルしました。"; return 2; }
    else
        read -r -p "SSIDを入力 (キャンセルは0): " ssid
        [[ -z "$ssid" || "$ssid" == "0" ]] && { echo "キャンセルしました。"; return 2; }
    fi

    read -r -p "パスワード (キャンセルは0): " pass
    [[ -z "$pass" || "$pass" == "0" ]] && { echo "キャンセルしました。"; return 2; }

    read -r -p "優先度 (0-100) [既定: 20]: " p_in
    if [[ -n "$p_in" ]]; then
        [[ "$p_in" =~ ^[0-9]+$ ]] && ((p_in >= 0 && p_in <= 100)) && prio="$p_in" || echo "不正な値のため既定値(20)を使用します。"
    fi

    if [[ "$mode" == "1" ]]; then
        sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$ssid" ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" connection.autoconnect yes connection.autoconnect-priority "$prio" >/dev/null 2>&1
        echo "=> 「$ssid」(優先度: $prio) を事前登録しました。"
    else
        curr_uuid="$(get_current_conn | awk -F'\t' '{print $2}')"
        echo "15秒の接続テストを開始します (失敗時は自動復帰)..."
        ( sleep "$ROLLBACK_SEC"
          if ! check_connectivity; then
              echo -e "\n疎通確認失敗のため旧Wi-Fiに復帰します。" >&2
              [[ -n "$curr_uuid" ]] && sudo nmcli connection up uuid "$curr_uuid" >/dev/null 2>&1
          fi ) &
        if sudo nmcli dev wifi connect "$ssid" password "$pass" ifname "$WIFI_IFACE" name "$ssid"; then
            sudo nmcli connection modify id "$ssid" connection.autoconnect-priority "$prio" 2>/dev/null || true
            echo "=> 接続成功。"
        else
            echo "=> 接続失敗。元に戻します。" && return 1
        fi
    fi
}

action_change_priority() {
    local target np
    select_wifi_profile target "--- 優先度を変更するWi-Fiを選択 ---" || return 2
    read -r -p "新しい優先度 (0-100, キャンセルは空Enter): " np
    [[ "$np" =~ ^[0-9]+$ ]] && ((np >= 0 && np <= 100)) && sudo nmcli connection modify id "$target" connection.autoconnect-priority "$np" && echo "=> 更新完了。" || { echo "キャンセルまたは不正な値です。"; return 2; }
}

action_test_conn() {
    local target curr_uuid
    select_wifi_profile target "--- 接続テストするWi-Fiを選択 ---" || return 2
    curr_uuid="$(get_current_conn | awk -F'\t' '{print $2}')"
    echo "「$target」への接続を試みます (15秒応答なしで自動復帰)..."
    ( sleep "$ROLLBACK_SEC"; check_connectivity || [[ -z "$curr_uuid" ]] || sudo nmcli connection up uuid "$curr_uuid" >/dev/null 2>&1 ) &
    sudo nmcli connection up id "$target" ifname "$WIFI_IFACE"
}

# --- システム・詳細設定サブメニュー ---

action_lock_temporary() {
    local curr ssid yn
    curr=$(get_current_conn)
    ssid="${curr%%$'\t'*}"
    [[ -z "$ssid" ]] && { echo "Wi-Fi未接続です。"; return 1; }
    echo "対象: $ssid (他Wi-Fi無効化・無限再試行・優先度100を適用)"
    read -r -p "適用しますか? (再起動で自動リセット) [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { echo "キャンセルしました。"; return 2; }

    while IFS= read -r p; do
        [[ "$p" != "$ssid" ]] && sudo nmcli connection modify --temporary id "$p" connection.autoconnect no 2>/dev/null
    done < <(list_wifi)
    sudo nmcli connection modify --temporary id "$ssid" connection.autoconnect yes connection.autoconnect-priority 100 connection.autoconnect-retries 0 2>/dev/null
    echo "「$ssid」に一時固定しました。"
}

action_unlock_temporary() {
    sudo nmcli connection reload && echo "一時固定を解除し、通常設定に戻しました。"
}

action_scan() {
    get_wifi_iface || return 1
    echo "周囲のWi-Fi電波をスキャン中..."
    sudo nmcli dev wifi rescan ifname "$WIFI_IFACE" 2>/dev/null && sleep 1
    nmcli -f IN-USE,SSID,CHAN,SIGNAL,SECURITY dev wifi list ifname "$WIFI_IFACE"
}

action_delete_wifi() {
    local target yn
    select_wifi_profile target "--- 削除するWi-Fiを選択 ---" || return 2
    read -r -p "「$target」を削除しますか? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && sudo nmcli connection delete id "$target" && echo "=> 削除完了。" || { echo "キャンセルしました。"; return 2; }
}

action_set_webhook() {
    local url yn
    echo -e "\n--- Discord Webhook URL設定 ---"
    echo "  1) 新しいURLを入力・変更"
    echo "  0) キャンセル"
    read -r -p "選択 [0-1]: " sel
    [[ "$sel" != "1" ]] && { echo "キャンセルしました。"; return 2; }

    read -r -p "Webhook URL (キャンセルは0): " url
    [[ -z "$url" || "$url" == "0" ]] && { echo "キャンセルしました。"; return 2; }
    if [[ "$url" =~ ^https://discord\.com/api/webhooks/ ]]; then
        read -r -p "保存してサービスを再起動しますか? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && set_config_env "DISCORD_WEBHOOK" "$url" && restart_service || { echo "キャンセルしました。"; return 2; }
    else
        echo "エラー: Webhook URLの形式が正しくありません。"
    fi
}

action_set_name() {
    local curr n yn
    curr="$(get_config_env "DEVICE_NAME")"
    echo -e "\n--- 機体名 (識別名) 設定 ---"
    echo "現在の機体名: ${curr:-未設定}"
    echo "  1) 機体名を変更"
    echo "  0) キャンセル"
    read -r -p "選択 [0-1]: " sel
    [[ "$sel" != "1" ]] && { echo "キャンセルしました。"; return 2; }

    read -r -p "新しい機体名 (キャンセルは0): " n
    [[ -z "$n" || "$n" == "0" ]] && { echo "キャンセルしました。"; return 2; }
    read -r -p "「$n」に変更しますか? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && set_config_env "DEVICE_NAME" "$n" && restart_service || { echo "キャンセルしました。"; return 2; }
}

submenu_system() {
    local subchoice sub_ret
    while true; do
        echo -e "\n------------------------------------------"
        echo " システム・詳細設定"
        echo "------------------------------------------"
        echo "  1) 【実験用】現在Wi-Fiに一時固定 (再起動でリセット)"
        echo "  2) 【実験用】一時固定解除 (通常モードに戻す)"
        echo "  3) 周囲のWi-Fi電波をスキャン"
        echo "  4) 不要なWi-Fi設定を削除"
        echo "  5) Discord Webhook URLを設定・変更"
        echo "  6) 機体名 (識別名) を変更"
        echo "  7) 監視サービスログ確認 (直近10行)"
        echo "  8) 設定ファイルを直接編集 (nano)"
        echo "  0) メインメニューに戻る"
        echo "------------------------------------------"
        read -r -p "番号を選択 [0-8]: " subchoice
        [[ "$subchoice" == "0" ]] && return 0
        
        case "$subchoice" in
            1) action_lock_temporary; sub_ret=$? ;;
            2) action_unlock_temporary; sub_ret=$? ;;
            3) action_scan; sub_ret=$? ;;
            4) action_delete_wifi; sub_ret=$? ;;
            5) action_set_webhook; sub_ret=$? ;;
            6) action_set_name; sub_ret=$? ;;
            7) journalctl -u "$SERVICE_NAME" -n 10 --no-pager; sub_ret=0 ;;
            8) nano "$CONFIG_PATH"; restart_service; sub_ret=0 ;;
            *) echo "0から8を入力してください。"; sub_ret=2 ;;
        esac
        if ((sub_ret != 2)); then
            read -r -p "Enterで詳細メニューへ戻る..." _dummy
        fi
    done
}

# --- メインループ ---

main() {
    local choice ret_code
    chmod +x "$0" 2>/dev/null || true

    while true; do
        echo ""
        echo "=========================================="
        echo " CanSat ネットワーク & 設定マネージャー"
        echo "=========================================="
        echo "  1) 現在の設定と登録済みWi-Fi一覧を確認"
        echo "  2) 新しいWi-Fiを追加 (事前登録 / スキャン / 手入力)"
        echo "  3) Wi-Fiの自動接続優先度を変更"
        echo "  4) 登録済みWi-Fiへ接続テスト (ロールバック監視付き)"
        echo "  5) システム・詳細設定へ (一時固定 / スキャン / Webhook / 削除等)"
        echo "  0) 終了"
        echo "=========================================="
        read -r -p "番号を選択してください [0-5]: " choice

        [[ "$choice" == "0" ]] && { echo "終了します。"; exit 0; }

        case "$choice" in
            1) action_status; ret_code=$? ;;
            2) action_add_wifi; ret_code=$? ;;
            3) action_change_priority; ret_code=$? ;;
            4) action_test_conn; ret_code=$? ;;
            5) submenu_system; ret_code=2 ;;
            *) echo "0から5の数字を入力してください。"; ret_code=2 ;;
        esac

        if ((ret_code != 2)); then
            read -r -p "Enterでメニューへ戻る..." _dummy
        fi
    done
}

main "$@"
