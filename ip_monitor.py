#!/usr/bin/env python3
# ==============================================================================
# プログラム名: ip_monitor.py
# 概要:
#   Raspberry Pi の wlan0 インターフェースを監視し、Wi-Fi 接続・切替時および
#   IP アドレス取得時に Discord Webhook へ自動通知を行うバックグラウンドデーモン。
#
# 主な仕様・設計方針:
#   - 監視対象: wlan0 (Wi-Fi) の IPv4 アドレスおよび NetworkManager のアクティブ SSID
#   - バタつき防止: 電波境界での接続瞬断による通知乱射を防ぐため、15秒のクールダウンを適用
#   - 閉域網対応: 外部インターネット不通時（山間部テザリング等）でもローカル IP を確実に取得
#   - ログ出力: 例外・HTTP エラー・設定不整合時は標準エラー出力へ記録 (systemd journal 連携)
#   - 設定参照: ~/cansat_config.env から DISCORD_WEBHOOK および DEVICE_NAME を読み込み
# ==============================================================================

import sys
import time
import json
import urllib.request
import urllib.error
import subprocess
import os
from datetime import datetime

CONFIG_PATH = os.path.expanduser("~/cansat_config.env")
COOLDOWN_SECONDS = 15  # 同一状態の連続通知を抑止する最小間隔

def log_err(msg):
    sys.stderr.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    sys.stderr.flush()

def load_config():
    config = {}
    if not os.path.exists(CONFIG_PATH):
        return config
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    config[k.strip()] = v.strip().strip('"').strip("'")
    except Exception as e:
        log_err(f"設定ファイル読み込み失敗 ({CONFIG_PATH}): {e}")
    return config

def get_wlan_ip(ifname="wlan0"):
    """wlan0インターフェースに割り当てられたIPv4アドレスを直接取得"""
    try:
        res = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "dev", ifname],
            capture_output=True, text=True, timeout=2
        )
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                return parts[3].split('/')[0]
    except Exception as e:
        log_err(f"IP取得失敗 ({ifname}): {e}")
    return None

def get_current_ssid():
    try:
        res = subprocess.run(
            ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"],
            capture_output=True, text=True, timeout=3
        )
        for line in res.stdout.splitlines():
            if line.startswith("yes:"):
                return line.split(":", 1)[1]
    except Exception as e:
        log_err(f"SSID取得失敗: {e}")
    return "未接続または不明"

def send_notification(ip, ssid, reason):
    config = load_config()
    webhook_url = config.get("DISCORD_WEBHOOK")
    device_name = config.get("DEVICE_NAME", os.uname().nodename)

    if not webhook_url or not webhook_url.startswith("http"):
        log_err("Discord Webhook URLが未設定または無効です")
        return False

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    message = (
        "📡 **Raspberry Pi ネットワーク通知**\n"
        f"- **機体名**: `{device_name}`\n"
        f"- **状態**: `{reason}`\n"
        f"- **接続SSID**: `{ssid}`\n"
        f"- **IPアドレス**: `{ip}`\n"
        f"- **接続コマンド**: `ssh pi@{ip}`\n"
        f"- **時刻**: `{now_str}`"
    )

    req = urllib.request.Request(
        webhook_url,
        data=json.dumps({"content": message}).encode("utf-8"),
        headers={"User-Agent": "CanSat-Monitor", "Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status == 204:
                return True
            log_err(f"Discord通知応答ステータス異常: HTTP {resp.status}")
    except urllib.error.HTTPError as e:
        log_err(f"Discord通知HTTPエラー: {e.code} - {e.reason}")
    except Exception as e:
        log_err(f"Discord通信例外: {e}")
    return False

def main():
    last_state = None
    last_sent_time = 0

    while True:
        ip = get_wlan_ip("wlan0")

        if ip and not ip.startswith("127."):
            ssid = get_current_ssid()
            current_state = (ip, ssid)
            now = time.time()

            # 状態変化があり、かつ前回の送信から一定時間経過しているか（バタつき抑止）
            if current_state != last_state:
                if (now - last_sent_time) > COOLDOWN_SECONDS:
                    reason = "起動時接続" if last_state is None else "Wi-Fi接続切り替え"
                    if send_notification(ip, ssid, reason):
                        last_state = current_state
                        last_sent_time = now
        else:
            # 切断状態になった場合は状態をリセット（再接続時に即座に通知できるよう準備）
            if last_state is not None:
                last_state = None

        time.sleep(3)

if __name__ == "__main__":
    main()