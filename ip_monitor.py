#!/usr/bin/env python3
"""
【プログラム名】ip_monitor.py
【役割】
  Raspberry PiのIPアドレスとWi-Fi接続を監視し、
  起動時や接続切り替え時にDiscordへWebhook経由で自動通知する。
"""

import socket
import time
import json
import urllib.request
import subprocess
import os
from datetime import datetime

CONFIG_PATH = os.path.expanduser("~/cansat_config.env")

def load_config():
    config = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        config[k.strip()] = v.strip().strip('"').strip("'")
        except Exception:
            pass
    return config

def get_wifi_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        s.close()

    try:
        res = subprocess.run(["ip", "-4", "-o", "addr", "show", "dev", "wlan0"], capture_output=True, text=True, timeout=3)
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                return parts[3].split('/')[0]
    except Exception:
        pass
    return None

def get_current_ssid():
    try:
        res = subprocess.run(
            ["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"],
            capture_output=True,
            text=True,
            timeout=5
        )
        for line in res.stdout.splitlines():
            if line.startswith("yes:"):
                return line.split(":", 1)[1]
    except Exception:
        pass
    return "未接続または不明"

def send_notification(ip, ssid, reason="接続"):
    config = load_config()
    webhook_url = config.get("DISCORD_WEBHOOK")
    device_name = config.get("DEVICE_NAME", socket.gethostname())
    
    if not webhook_url or not webhook_url.startswith("http"):
        return

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
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def main():
    last_state = None
    while True:
        wifi_ip = get_wifi_ip()
        
        if wifi_ip and not wifi_ip.startswith("127."):
            ssid = get_current_ssid()
            current_state = (wifi_ip, ssid)

            if current_state != last_state:
                reason = "起動時接続" if last_state is None else "Wi-Fi接続切り替え"
                send_notification(wifi_ip, ssid, reason)
                last_state = current_state
        else:
            last_state = None

        time.sleep(3)

if __name__ == "__main__":
    main()