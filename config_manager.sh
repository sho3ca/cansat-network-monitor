#!/usr/bin/env bash
# ==============================================================================
# プログラム名: config_manager.sh
# 概要:
#   CanSat 運用現場における NetworkManager (Wi-Fi) および機体設定の対話型管理 CLI。
#
# 主な機能・設計方針:
#   1. Wi-Fi 管理:
#      - 事前登録モード (SSH 接続を切断せずに遠征用テザリング等を登録)
#      - 自動接続優先度 (0〜100) の変更および不要設定の削除
#      - 15秒ロールバック保護付きの接続テスト (閉域網スマホ親機の GW 判定を含む)
#   2. 実験用 一時固定モード:
#      - nmcli --temporary を使用し、対象 Wi-Fi 以外の自動接続をメモリ上でのみ無効化
#      - autoconnect-retries 0 (無限再試行) と最優先度 (100) を適用 (上空投下復帰対策)
#      - ディスクを変更しないため、ラズパイの電源 OFF または再起動で自動的に通常状態へ復元
#   3. 機体設定 & Discord 連携:
#      - ~/cansat_config.env のアトミック更新 (特殊文字による破損を防止)
#      - Webhook 設定、テスト通知送信、ip-monitor.service の状態確認
#   4. 操作性 (UX):
#      - 0 入力またはキャンセル時は確認待ち (Enter) をスキップして即座にメニュー復帰
# ==============================================================================set -uo pipefail

readonly SERVICE_NAME='ip-monitor.service'
readonly CONFIG_PATH="${CONFIG_PATH:-${HOME}/cansat_config.env}"
readonly ROLLBACK_SEC=15
WIFI_IFACE=""

# --- 共通ユーティリティ ---
get_wifi_iface() {
    [[ -z "$WIFI_IFACE" ]] && WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    [[ -z "$WIFI_IFACE" ]] && { echo "エラー: Wi-Fiインターフェースが見つかりません。" >&2; return 1; }
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

# 外部1.1.1.1 またはローカルゲートウェイ（閉域テザリング親機）への疎通確認
check_connectivity() {
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    local gw
    gw="$(ip route show dev "${WIFI_IFACE:-wlan0}" 2>/dev/null | awk '/default/{print $3; exit}')"
    [[ -n "$gw" ]] && ping -c1 -W2 "$gw" >/dev/null 2>&1
}

# リスト選択（0入力時は戻り値 2 で即時キャンセル）
select_wifi_profile() {
    local -n out_var=$1
    local prompt_msg="$2"
    mapfile -t _profiles < <(list_wifi)
    ((${#_profiles[@]} == 0)) && { echo "登録済みWi-Fiがありません。"; return 2; }
    
    echo "$prompt_msg"
    for i in "${!_profiles[@]}"; do echo "$((i+1))) ${_profiles[$i]}"; done
    echo "0) キャンセル"
    read -r -p "番号を選択: " sel
    [[ "$sel" =~ ^[1-9][0-9]*$ ]] && ((sel <= ${#_profiles[@]})) && { out_var="${_profiles[$((sel-1))]}"; return 0; }
    echo "キャンセルしました。"; return 2
}

restart_service() {
    sudo systemctl restart "$SERVICE_NAME" 2>/dev/null && echo "監視サービスを再起動しました。"
}

# --- メニュー機能 ---
action_status() {
    echo "=== 設定 & 接続状態 ==="
    [[ -s "$CONFIG_PATH" ]] && awk '/^DISCORD_WEBHOOK=/{print "DISCORD_WEBHOOK=\"(設定済み)\""; next} {print}' "$CONFIG_PATH" || echo "(設定なし)"
    echo -e "\n--- 登録済みWi-Fi (優先度順) ---"
    while IFS= read -r p; do
        prio=$(nmcli -g connection.autoconnect-priority connection show id "$p" 2>/dev/null || echo 0)
        retries=$(nmcli -g connection.autoconnect-retries connection show id "$p" 2>/dev/null || echo -1)
        printf "%-3s [再試行: %-2s] %s\n" "${prio:-0}" "$([ "$retries" = "0" ] && echo '無限' || echo "$retries")" "$p"
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
    echo "1) 事前登録 (現在の接続を維持)  2) 電波スキャンから接続  3) SSID手入力  0) キャンセル"
    read -r -p "選択 [0-3]: " mode
    [[ ! "$mode" =~ ^[1-3]$ ]] && { echo "キャンセルしました。"; return 2; }

    local ssid="" pass="" prio=20
    if [[ "$mode" == "2" ]]; then
        echo "スキャン中..." && sudo nmcli dev wifi rescan ifname "$WIFI_IFACE" 2>/dev/null && sleep 1
        mapfile -t ssids < <(nmcli --terse --fields SSID dev wifi list ifname "$WIFI_IFACE" 2>/dev/null | awk 'NF && !seen[$0]++')
        for i in "${!ssids[@]}"; do echo "$((i+1))) ${ssids[$i]}"; done
        echo "0) キャンセル"; read -r -p "選択: " s_idx
        [[ "$s_idx" =~ ^[1-9][0-9]*$ ]] && ((s_idx <= ${#ssids[@]})) && ssid="${ssids[$((s_idx-1))]}" || { echo "キャンセルしました。"; return 2; }
    else
        read -r -p "SSIDを入力 (キャンセルは0): " ssid
        [[ -z "$ssid" || "$ssid" == "0" ]] && { echo "キャンセルしました。"; return 2; }
    fi

    read -r -p "パスワード (キャンセルは0): " pass
    [[ -z "$pass" || "$pass" == "0" ]] && { echo "キャンセルしました。"; return 2; }

    read -r -p "優先度 (0-100) [既定 20]: " p_in
    if [[ -n "$p_in" ]]; then
        [[ "$p_in" =~ ^[0-9]+$ ]] && ((p_in >= 0 && p_in <= 100)) && prio="$p_in" || echo "不正な値のため既定値(20)を使用します。"
    fi

    if [[ "$mode" == "1" ]]; then
        sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$ssid" ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" connection.autoconnect yes connection.autoconnect-priority "$prio" >/dev/null 2>&1
        echo "「$ssid」を事前登録しました。"
    else
        curr_uuid="$(get_current_conn | awk -F'\t' '{print $2}')"
        ( sleep "$ROLLBACK_SEC"
          if ! check_connectivity; then
              echo -e "\n疎通確認失敗のため旧Wi-Fiに復帰します。" >&2
              [[ -n "$curr_uuid" ]] && sudo nmcli connection up uuid "$curr_uuid" >/dev/null 2>&1
          fi ) &
        if sudo nmcli dev wifi connect "$ssid" password "$pass" ifname "$WIFI_IFACE" name "$ssid"; then
            sudo nmcli connection modify id "$ssid" connection.autoconnect-priority "$prio" 2>/dev/null || true
            echo "接続成功。"
        else
            echo "接続失敗。元に戻します。" && return 1
        fi
    fi
}

action_change_priority() {
    local target np
    select_wifi_profile target "優先度を変更するWi-Fiを選択:" || return 2
    read -r -p "新しい優先度 (0-100, キャンセルは空Enter): " np
    [[ "$np" =~ ^[0-9]+$ ]] && ((np >= 0 && np <= 100)) && sudo nmcli connection modify id "$target" connection.autoconnect-priority "$np" && echo "更新完了。" || { echo "キャンセルまたは不正な値です。"; return 2; }
}

action_delete_wifi() {
    local target yn
    select_wifi_profile target "削除するWi-Fiを選択:" || return 2
    read -r -p "「$target」を削除しますか? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && sudo nmcli connection delete id "$target" && echo "削除完了。" || { echo "キャンセルしました。"; return 2; }
}

action_test_conn() {
    local target curr_uuid
    select_wifi_profile target "接続テストするWi-Fiを選択:" || return 2
    curr_uuid="$(get_current_conn | awk -F'\t' '{print $2}')"
    ( sleep "$ROLLBACK_SEC"; check_connectivity || [[ -z "$curr_uuid" ]] || sudo nmcli connection up uuid "$curr_uuid" >/dev/null 2>&1 ) &
    sudo nmcli connection up id "$target" ifname "$WIFI_IFACE"
}

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
    sudo nmcli dev wifi rescan ifname "$WIFI_IFACE" 2>/dev/null && sleep 1
    nmcli -f IN-USE,SSID,CHAN,SIGNAL,SECURITY dev wifi list ifname "$WIFI_IFACE"
}

action_set_webhook() {
    local url yn
    echo "1) 新しいURLを入力・変更  0) キャンセル"
    read -r -p "選択 [0-1]: " sel
    [[ "$sel" != "1" ]] && { echo "キャンセルしました。"; return 2; }

    read -r -p "Discord Webhook URLを入力 (キャンセルは0): " url
    [[ -z "$url" || "$url" == "0" ]] && { echo "キャンセルしました。"; return 2; }
    if [[ "$url" =~ ^https://discord\.com/api/webhooks/ ]]; then
        read -r -p "保存してサービスを再起動しますか? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && set_config_env "DISCORD_WEBHOOK" "$url" && restart_service || { echo "キャンセルしました。"; return 2; }
    else
        echo "エラー: Webhook URLの形式が正しくありません。"
    fi
}

action_test_webhook() {
    local url name code
    url=$(get_config_env "DISCORD_WEBHOOK")
    name=$(get_config_env "DEVICE_NAME"); name="${name:-CanSat}"
    [[ -z "$url" ]] && { echo "Webhook未設定です。"; return 1; }
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d "{\"content\":\"[${name}] テスト通知成功\"}" "$url")
    [ "$code" = "204" ] && echo "送信成功 (204)" || echo "送信失敗 ($code)"
}

action_set_name() {
    local curr n yn
    curr="$(get_config_env "DEVICE_NAME")"
    echo "現在の機体名: ${curr:-未設定}"
    echo "1) 機体名を変更  0) キャンセル"
    read -r -p "選択 [0-1]: " sel
    [[ "$sel" != "1" ]] && { echo "キャンセルしました。"; return 2; }

    read -r -p "新しい機体名 (キャンセルは0): " n
    [[ -z "$n" || "$n" == "0" ]] && { echo "キャンセルしました。"; return 2; }
    read -r -p "「$n」に変更しますか? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && set_config_env "DEVICE_NAME" "$n" && restart_service || { echo "キャンセルしました。"; return 2; }
}

# --- メインループ ---
readonly MENU=(
    "状態確認:action_status"
    "Wi-Fi追加 (事前登録/接続):action_add_wifi"
    "優先度変更:action_change_priority"
    "Wi-Fi削除:action_delete_wifi"
    "接続テスト (ロールバック付):action_test_conn"
    "【実験用】現在Wi-Fiに一時固定 (再起動でリセット):action_lock_temporary"
    "【実験用】一時固定解除:action_unlock_temporary"
    "電波スキャン:action_scan"
    "Webhook URL設定:action_set_webhook"
    "Discord通知テスト:action_test_webhook"
    "機体名変更:action_set_name"
    "サービスログ確認:journalctl -u $SERVICE_NAME -n 10 --no-pager"
)

while true; do
    echo -e "\n=== CanSat ネットワーク管理 ==="
    for i in "${!MENU[@]}"; do printf "%2d) %s\n" "$((i+1))" "${MENU[$i]%%:*}"; done
    echo " 0) 終了"
    read -r -p "選択 [0-${#MENU[@]}]: " c
    [[ "$c" == "0" ]] && exit 0
    if [[ "$c" =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#MENU[@]})); then
        echo ""
        ${MENU[$((c-1))]##*:}
        ret_code=$?
        if ((ret_code != 2)); then
            read -r -p "Enterでメニューへ戻る..." _dummy
        fi
    fi
done