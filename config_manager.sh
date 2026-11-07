#!/usr/bin/env bash
# ==============================================================================
# プログラム名: config_manager.sh
# 概要:
#   Raspberry Pi の NetworkManager と systemd を対話的に管理する CLI ツール。
#   Wi-Fi 設定（事前登録・優先度変更・ロールバック付き接続・一時固定・削除・スキャン）および
#   機体設定ファイル（cansat_config.env）の更新、ログ確認を行います。
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'
umask 077

readonly SERVICE_NAME='ip-monitor.service'
readonly DEFAULT_CONFIG_PATH="${HOME}/cansat_config.env"
readonly CONNECTIVITY_TEST_HOST='1.1.1.1'
readonly ROLLBACK_WAIT_SECONDS=15

CONFIG_PATH="${CONFIG_PATH:-${DEFAULT_CONFIG_PATH}}"
WIFI_IFACE="${WIFI_IFACE:-}"

print_error() { printf 'エラー: %s\n' "$*" >&2; }
print_info()  { printf '%s\n' "$*"; }

require_commands() {
    local cmd
    for cmd in nmcli sudo python3 awk ping systemctl journalctl ip curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_error "必要なコマンドが見つかりません: ${cmd}"
            return 1
        fi
    done
}

read_config_value() {
    local key="$1"
    [[ -f "$CONFIG_PATH" ]] || return 0
    python3 - "$CONFIG_PATH" "$key" <<'PY'
import re, sys
path, target_key = sys.argv[1], sys.argv[2]
pattern = re.compile(rf'^{re.escape(target_key)}=(?:"?)(.*?)(?:"?)$')
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = pattern.match(line.strip())
            if m:
                sys.stdout.write(m.group(1))
                break
except Exception:
    pass
PY
}

initialize_config() {
    local config_dir
    config_dir="$(dirname -- "$CONFIG_PATH")" || return 1
    mkdir -p -- "$config_dir" || return 1
    [[ -e "$CONFIG_PATH" ]] || : > "$CONFIG_PATH" || return 1
    chmod 600 "$CONFIG_PATH" || return 1
}

# ----------------------------------------------------------------------------
# 汎用 UI・入力ヘルパー
# ----------------------------------------------------------------------------

prompt_priority() {
    local prompt_msg="$1" default_val="$2"
    local -n out_num="$3"
    local input_val=''

    while true; do
        read -r -p "${prompt_msg} [既定: ${default_val}]: " input_val || return 1
        input_val="${input_val:-$default_val}"
        if [[ "$input_val" =~ ^[0-9]+$ ]] && ((input_val >= 0 && input_val <= 100)); then
            out_num="$input_val"
            return 0
        fi
        print_error '0 から 100 の半角整数で入力してください。'
    done
}

prompt_confirm() {
    local answer=''
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

select_from_array() {
    local prompt_msg="$1"
    local -n list_ref="$2" out_result="$3"
    local index choice

    if ((${#list_ref[@]} == 0)); then
        print_info '選択可能な項目がありません。'
        return 2
    fi
    for index in "${!list_ref[@]}"; do
        printf '%d) %s\n' "$((index + 1))" "${list_ref[$index]}"
    done
    printf '0) キャンセルして戻る\n'
    read -r -p "$prompt_msg" choice || return 2
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#list_ref[@]})); then
        out_result="${list_ref[$((choice - 1))]}"
        return 0
    fi
    print_info 'キャンセルしました。'
    return 2
}

wait_for_user() {
    local dummy
    printf '\n'
    read -r -p 'Enterキーを押して戻ります...' dummy || true
}

# ----------------------------------------------------------------------------
# 設定ファイル操作 (Python Atomic Update)
# ----------------------------------------------------------------------------

set_config_value() {
    local key="$1" value="$2"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
    [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]] && return 1

    python3 - "$CONFIG_PATH" "$key" "$value" <<'PY'
import os, re, sys, tempfile
path, key, value = sys.argv[1:]
lines = []
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
replacement = f'{key}="{escaped}"\n'
pattern = re.compile(r"^" + re.escape(key) + r"=")
result, inserted = [], False

for line in lines:
    if pattern.match(line):
        if not inserted:
            result.append(replacement)
            inserted = True
    else:
        result.append(line)

if not inserted:
    result.append(replacement)

folder = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix=".cansat-config-", dir=folder, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(result)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
}

# ----------------------------------------------------------------------------
# ネットワーク & NetworkManager 操作処理
# ----------------------------------------------------------------------------

detect_wifi_interface() {
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'
}

ensure_wifi_interface() {
    if [[ -z "$WIFI_IFACE" ]]; then
        WIFI_IFACE="$(detect_wifi_interface)" || {
            print_error 'Wi-Fiインターフェースが見つかりません。'
            return 1
        }
    fi
}

list_wifi_profiles() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 == "802-11-wireless" {print $1}'
}

get_active_wifi_info() {
    ensure_wifi_interface || return 1
    local name uuid
    name="$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null)" || name=''
    uuid="$(nmcli -g GENERAL.CON-UUID device show "$WIFI_IFACE" 2>/dev/null)" || uuid=''
    [[ "$name" == '--' ]] && name=''
    [[ "$uuid" == '--' ]] && uuid=''
    printf '%s\t%s\n' "$name" "$uuid"
}

check_connectivity() {
    local iface="$1" gateway=''
    if ping -I "$iface" -c 1 -W 2 "$CONNECTIVITY_TEST_HOST" >/dev/null 2>&1; then
        return 0
    fi
    gateway="$(ip route show dev "$iface" 2>/dev/null | awk '/default/ {print $3; exit}')"
    [[ -n "$gateway" ]] && ping -I "$iface" -c 1 -W 2 "$gateway" >/dev/null 2>&1
}

schedule_rollback_watchdog() {
    local prev_uuid="$1" iface="$2" wait_sec="$3"
    [[ -n "$prev_uuid" ]] || return 0

    (
        sleep "$wait_sec"
        if ! check_connectivity "$iface"; then
            printf '\n接続確認に失敗したため、元のWi-Fiへ自動復帰します。\n' >&2
            sudo -n nmcli connection up uuid "$prev_uuid" ifname "$iface" >/dev/null 2>&1 || true
        fi
    ) </dev/null >/dev/null 2>&1 &
}

# ----------------------------------------------------------------------------
# メニュー対応機能
# ----------------------------------------------------------------------------

action_show_status() {
    local -a profiles=()
    local profile priority retries index active_data active_name active_ip

    printf '%s\n' "--- 設定ファイル (${CONFIG_PATH}) ---"
    if [[ -s "$CONFIG_PATH" ]]; then
        awk '/^DISCORD_WEBHOOK=/ { print "DISCORD_WEBHOOK=\"(設定済み・値は非表示)\""; next } { print }' "$CONFIG_PATH"
    else
        print_info '(設定はありません)'
    fi

    printf '%s\n' '' '--- 登録済みWi-Fi一覧 (優先度順) ---'
    mapfile -t profiles < <(list_wifi_profiles)
    if ((${#profiles[@]} == 0)); then
        print_info '登録されているWi-Fiプロファイルはありません。'
    else
        for index in "${!profiles[@]}"; do
            profile="${profiles[$index]}"
            priority="$(nmcli -g connection.autoconnect-priority connection show id "$profile" 2>/dev/null)" || priority='0'
            retries="$(nmcli -g connection.autoconnect-retries connection show id "$profile" 2>/dev/null)" || retries='-1'
            printf '%s\t%s\t%s\n' "${priority:-0}" "${retries:--1}" "$profile"
        done | sort -rn | awk -F '\t' '{printf "優先度 %-3s [再試行: %-2s] %s\n", $1, ($2 == "0" ? "無限" : $2), $3}'
    fi

    printf '%s\n' '' '--- 現在の接続状態 ---'
    if ensure_wifi_interface; then
        active_data="$(get_active_wifi_info)"
        active_name="${active_data%%$'\t'*}"
        printf 'Wi-Fi I/F: %s | 接続SSID: %s\n' "$WIFI_IFACE" "${active_name:-未接続}"
    fi

    active_ip="$(ip -4 -o addr show dev "${WIFI_IFACE:-wlan0}" 2>/dev/null | awk '{split($4, a, "/"); print a[1]}')"
    printf 'Wi-Fi IP: %s\n' "${active_ip:-未割り当て}"
    return 0
}

action_add_wifi() {
    local mode='' target_ssid='' password='' priority='20'
    local active_data prev_uuid existing_uuid existing_type profile_uuid active_name
    local -a scanned_ssids=()

    ensure_wifi_interface || return 1
    printf '%s\n' '--- Wi-Fi追加モード ---' \
        '1) 設定のみ事前登録 (現在の接続を維持・テザリング登録に推奨)' \
        '2) 周囲の電波から選んで登録・接続する' \
        '3) SSIDを手入力して登録・接続する' \
        '0) キャンセルして戻る'
    read -r -p '選択 [0-3]: ' mode || return 2
    [[ "$mode" == '0' || ! "$mode" =~ ^[1-3]$ ]] && { print_info 'キャンセルしました。'; return 2; }

    if [[ "$mode" == '2' ]]; then
        print_info '周囲のWi-Fiをスキャン中...'
        sudo nmcli device wifi rescan ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
        sleep 1
        mapfile -t scanned_ssids < <(nmcli --terse --escape no --fields SSID device wifi list ifname "$WIFI_IFACE" 2>/dev/null | awk 'NF && !seen[$0]++')
        select_from_array '接続する番号を選択: ' scanned_ssids target_ssid || return 2
    else
        read -r -p '追加するWi-FiのSSID (キャンセルは0): ' target_ssid || return 2
        [[ "$target_ssid" == '0' || -z "$target_ssid" ]] && { print_info 'キャンセルしました。'; return 2; }
    fi

    active_data="$(get_active_wifi_info)"
    active_name="${active_data%%$'\t'*}"
    prev_uuid="${active_data##*$'\t'}"

    if [[ "$mode" == '1' && "$target_ssid" == "$active_name" ]]; then
        print_error "「${target_ssid}」は現在接続中です。切断リスク防止のため事前登録はできません。優先度変更をご利用ください。"
        return 1
    fi

    read -r -p 'Wi-Fiパスワード (キャンセルは0): ' password || return 2
    [[ "$password" == '0' ]] && { print_info 'キャンセルしました。'; return 2; }
    [[ -z "$password" ]] && { print_error 'パスワードは空にできません。'; return 2; }

    prompt_priority '自動接続優先度 (0〜100)' '20' priority || return 2

    if [[ "$mode" == '1' ]]; then
        existing_uuid="$(nmcli -g UUID connection show id "$target_ssid" 2>/dev/null | head -n 1)" || existing_uuid=''
        if [[ -n "$existing_uuid" ]]; then
            existing_type="$(nmcli -g connection.type connection show uuid "$existing_uuid" 2>/dev/null)" || existing_type=''
            if [[ "$existing_type" != '802-11-wireless' ]]; then
                print_error '同名のWi-Fi以外のプロファイルが存在するため変更を中止しました。'
                return 1
            fi
            sudo nmcli connection modify uuid "$existing_uuid" \
                connection.interface-name "$WIFI_IFACE" \
                802-11-wireless.ssid "$target_ssid" \
                802-11-wireless-security.key-mgmt wpa-psk \
                802-11-wireless-security.psk "$password" \
                connection.autoconnect yes connection.autoconnect-priority "$priority"
        else
            sudo nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$target_ssid" ssid "$target_ssid" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" \
                connection.autoconnect yes connection.autoconnect-priority "$priority" >/dev/null 2>&1
        fi
        print_info "「${target_ssid}」(優先度: ${priority}) を事前登録しました。現在の接続は維持されています。"
        return 0
    fi

    sudo -v || { print_error 'sudo認証に失敗しました。'; return 1; }
    schedule_rollback_watchdog "$prev_uuid" "$WIFI_IFACE" "$ROLLBACK_WAIT_SECONDS"

    if sudo nmcli device wifi connect "$target_ssid" password "$password" ifname "$WIFI_IFACE" name "$target_ssid"; then
        profile_uuid="$(nmcli -g UUID connection show id "$target_ssid" 2>/dev/null | head -n 1)"
        [[ -n "$profile_uuid" ]] && sudo nmcli connection modify uuid "$profile_uuid" connection.autoconnect-priority "$priority" >/dev/null 2>&1 || true
        print_info "「${target_ssid}」への接続に成功しました。"
        return 0
    else
        print_error '接続に失敗しました。元のWi-Fiへ復帰します。'
        [[ -n "$prev_uuid" ]] && sudo nmcli connection up uuid "$prev_uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
        return 1
    fi
}

action_change_priority() {
    local -a profiles=()
    local selected='' new_prio=''
    mapfile -t profiles < <(list_wifi_profiles)
    select_from_array '優先度を変更するWi-Fiを選択: ' profiles selected || return 2
    prompt_priority '新しい優先度 (0〜100)' '20' new_prio || return 2
    if sudo nmcli connection modify id "$selected" connection.autoconnect-priority "$new_prio"; then
        print_info "「${selected}」の優先度を ${new_prio} に更新しました。"
        return 0
    else
        print_error '優先度の変更に失敗しました。'
        return 1
    fi
}

action_delete_wifi() {
    local -a profiles=()
    local selected=''
    mapfile -t profiles < <(list_wifi_profiles)
    select_from_array '削除するWi-Fiを選択: ' profiles selected || return 2

    if ! prompt_confirm "【確認 1/2】Wi-Fi設定「${selected}」を削除しますか?"; then
        print_info '削除をキャンセルしました。'
        return 2
    fi

    if ! prompt_confirm "【確認 2/2】削除すると再設定が必要になります。本当に削除しますか?"; then
        print_info '削除をキャンセルしました。'
        return 2
    fi

    if sudo nmcli connection delete id "$selected"; then
        print_info "Wi-Fi設定「${selected}」を削除しました。"
        return 0
    else
        print_error 'Wi-Fi設定の削除に失敗しました。'
        return 1
    fi
}

action_connection_test() {
    local -a profiles=()
    local selected='' active_data prev_uuid
    ensure_wifi_interface || return 1
    mapfile -t profiles < <(list_wifi_profiles)
    select_from_array '接続テストするWi-Fiを選択: ' profiles selected || return 2

    sudo -v || { print_error 'sudo認証に失敗しました。'; return 1; }
    active_data="$(get_active_wifi_info)"
    prev_uuid="${active_data##*$'\t'}"
    schedule_rollback_watchdog "$prev_uuid" "$WIFI_IFACE" "$ROLLBACK_WAIT_SECONDS"

    if sudo nmcli connection up id "$selected" ifname "$WIFI_IFACE"; then
        print_info "「${selected}」へ接続しました。${ROLLBACK_WAIT_SECONDS}秒後に疎通を確認します。"
        return 0
    else
        print_error 'Wi-Fiへの接続に失敗しました。'
        [[ -n "$prev_uuid" ]] && sudo nmcli connection up uuid "$prev_uuid" ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 実験用 一時固定・無限再試行機能
# ----------------------------------------------------------------------------

action_lock_current_wifi_temporary() {
    ensure_wifi_interface || return 1
    local active_data active_name active_uuid
    local -a profiles=()
    local profile

    active_data="$(get_active_wifi_info)"
    active_name="${active_data%%$'\t'*}"
    active_uuid="${active_data##*$'\t'}"

    if [[ -z "$active_name" || -z "$active_uuid" ]]; then
        print_error "現在Wi-Fiに接続されていません。固定したいWi-Fiに接続してから実行してください。"
        return 1
    fi

    printf '%s\n' "--- 【実験用】Wi-Fi接続の一時固定 & 無限再試行 ---"
    printf '対象SSID: %s\n' "$active_name"
    printf '【適用される設定 (メモリ上のみ変更・再起動で自動リセット)】\n'
    printf ' 1. 「%s」以外の登録Wi-Fiへの自動接続を一時停止 (他電波への誤乗換防止)\n' "$active_name"
    printf ' 2. 「%s」の優先度を最大 (100) に一時設定\n' "$active_name"
    printf ' 3. 完全切断時の再接続試行を「無制限 (retries 0)」に設定 (上空復帰対策)\n\n'

    if ! prompt_confirm "上記を適用して接続を固定しますか?"; then
        print_info "キャンセルしました。"
        return 2
    fi

    mapfile -t profiles < <(list_wifi_profiles)
    for profile in "${profiles[@]}"; do
        if [[ "$profile" != "$active_name" ]]; then
            sudo nmcli connection modify --temporary id "$profile" connection.autoconnect no >/dev/null 2>&1 || true
        fi
    done

    if sudo nmcli connection modify --temporary id "$active_name" \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        connection.autoconnect-retries 0 >/dev/null 2>&1; then
        print_info "「${active_name}」への接続固定と無限再試行を適用しました。"
        print_info "※ラズパイの電源を切るか再起動すると、自動的に通常設定へ復帰します。"
        return 0
    else
        print_error "設定の適用に失敗しました。"
        return 1
    fi
}

action_unlock_wifi_temporary() {
    print_info "NetworkManager の接続設定を再読み込みし、一時変更を解除します..."
    if sudo nmcli connection reload; then
        print_info "一時固定を解除しました。通常設定に戻りました。"
        return 0
    else
        print_error "設定のリロードに失敗しました。"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 共通・メンテナンス機能
# ----------------------------------------------------------------------------

action_scan_wifi() {
    ensure_wifi_interface || return 1
    printf '%s\n' '--- 周囲のWi-Fi電波をスキャン中 ---'
    sudo nmcli device wifi rescan ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep 1
    nmcli -f IN-USE,SSID,MODE,CHAN,RATE,SIGNAL,SECURITY device wifi list ifname "$WIFI_IFACE"
    printf '\n%s\n' '※ スキャン結果の表示が完了しました。'
    return 0
}

action_set_discord_webhook() {
    local mode='' input_val='' current_val=''
    current_val="$(read_config_value DISCORD_WEBHOOK)"
    printf '%s\n' '--- Discord Webhook 設定 ---'
    printf '現在の設定: %s\n' "$([[ -n "$current_val" ]] && printf '(登録済み)' || printf '(未設定)')"
    printf '1) 新しいURLを入力・変更する\n0) キャンセルして戻る\n'

    read -r -p '選択 [0-1]: ' mode || return 2
    [[ "$mode" != '1' ]] && { print_info 'キャンセルしました。'; return 2; }

    while true; do
        read -r -p 'Discord Webhook URLを入力 (キャンセルは0): ' input_val || return 2
        [[ "$input_val" == '0' ]] && { print_info 'キャンセルしました。'; return 2; }
        [[ "$input_val" =~ ^https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_.-]+/?$ ]] && break
        print_error '形式が正しくありません。再度入力してください。'
    done

    if ! prompt_confirm "このURLに変更しますか?"; then
        print_info '変更をキャンセルしました。'
        return 2
    fi

    set_config_value 'DISCORD_WEBHOOK' "$input_val"
    print_info 'Discord Webhook URLを更新しました。'
    restart_monitor_service
    return 0
}

action_test_discord_notification() {
    local webhook_url device_name payload status
    webhook_url="$(read_config_value DISCORD_WEBHOOK)"
    device_name="$(read_config_value DEVICE_NAME)"
    device_name="${device_name:-CanSat}"

    if [[ -z "$webhook_url" ]]; then
        print_error "Discord Webhook URL が設定されていません。"
        return 1
    fi

    print_info "Discordへテスト通知を送信中..."
    payload="{\"content\":\"[${device_name}] 設定マネージャーからのテスト通信です。通信良好。\"}"
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --header 'Content-Type: application/json' \
        --request POST \
        --data "$payload" \
        "$webhook_url" 2>/dev/null || true)"

    if [[ "$status" == "204" ]]; then
        print_info "Discord への送信に成功しました (HTTP 204)。"
        return 0
    else
        print_error "Discord 送信に失敗しました (HTTPステータス: ${status:-通信エラー})。"
        return 1
    fi
}

action_set_device_name() {
    local mode='' dev_name='' current_name=''
    current_name="$(read_config_value DEVICE_NAME)"
    current_name="${current_name:-未設定}"

    printf '%s\n' '--- 機体名（識別名）の設定 ---'
    printf '現在の機体名: %s\n' "$current_name"
    printf '1) 機体名を変更する\n0) キャンセルして戻る\n'

    read -r -p '選択 [0-1]: ' mode || return 2
    [[ "$mode" != '1' ]] && { print_info 'キャンセルしました。'; return 2; }

    read -r -p '新しい機体名を入力 (例: CanSat-Rover-01, キャンセルは0): ' dev_name || return 2
    [[ "$dev_name" == '0' || -z "$dev_name" ]] && { print_info 'キャンセルしました。'; return 2; }

    if ! prompt_confirm "機体名を「${dev_name}」に変更しますか?"; then
        print_info '変更をキャンセルしました。'
        return 2
    fi

    set_config_value 'DEVICE_NAME' "$dev_name"
    print_info "機体名を「${dev_name}」に更新しました。"
    restart_monitor_service
    return 0
}

action_show_service_status() {
    printf '%s\n' '--- Discord通知サービスの状態 ---'
    systemctl is-active "$SERVICE_NAME" 2>/dev/null | awk '{print "稼働状況: " $0}'
    printf '%s\n' '' '--- 最新のログ (直近10行) ---'
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager
    return 0
}

action_edit_config_file() {
    command -v nano >/dev/null 2>&1 || { print_error 'nano が見つかりません。'; return 1; }
    nano "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    restart_monitor_service
    return 0
}

restart_monitor_service() {
    if sudo systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        print_info "${SERVICE_NAME} を再起動しました。"
    else
        print_error "${SERVICE_NAME} の再起動に失敗しました。"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# メインディスパッチャー
# ----------------------------------------------------------------------------

readonly MENU_ENTRIES=(
    "現在の設定と登録済みWi-Fi一覧を確認:action_show_status"
    "新しいWi-Fiを追加 (事前登録 / スキャン / 手入力):action_add_wifi"
    "Wi-Fiの自動接続優先度を変更:action_change_priority"
    "不要なWi-Fi設定を削除:action_delete_wifi"
    "登録済みWi-Fiへ接続テスト (ロールバック監視付き):action_connection_test"
    "【実験用】現在Wi-Fiに一時固定 (無限再試行・再起動でリセット):action_lock_current_wifi_temporary"
    "【実験用】一時固定を手動解除 (通常モードに戻す):action_unlock_wifi_temporary"
    "周囲のWi-Fi電波をスキャン:action_scan_wifi"
    "Discord Webhook URLを設定・変更:action_set_discord_webhook"
    "Discord通知のテスト送信 (通信確認):action_test_discord_notification"
    "機体名 (識別名) を変更:action_set_device_name"
    "Discord通知サービスの状態・ログを確認:action_show_service_status"
    "設定ファイルを直接編集 (nano):action_edit_config_file"
)

main() {
    require_commands || return 1
    initialize_config || return 1

    local choice idx label handler ret_code

    while true; do
        printf '\n==========================================\n'
        printf ' CanSat ネットワーク & 設定マネージャー\n'
        printf '==========================================\n'
        for idx in "${!MENU_ENTRIES[@]}"; do
            label="${MENU_ENTRIES[$idx]%%:*}"
            printf '%d) %s\n' "$((idx + 1))" "$label"
        done
        printf '0) 終了\n'
        printf '==========================================\n'

        if ! read -r -p "番号を選択してください [0-${#MENU_ENTRIES[@]}]: " choice; then
            printf '\n終了します。\n'
            return 0
        fi

        if [[ "$choice" == '0' ]]; then
            print_info '終了します。'
            return 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#MENU_ENTRIES[@]})); then
            handler="${MENU_ENTRIES[$((choice - 1))]##*:}"
            printf '\n'
            "$handler"
            ret_code=$?
            if ((ret_code != 2)); then
                wait_for_user
            fi
        else
            print_error "0から${#MENU_ENTRIES[@]}の数字を入力してください。"
        fi
    done
}

main "$@"