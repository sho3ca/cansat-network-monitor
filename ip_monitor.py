#!/usr/bin/env python3
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
        except Exception as e:
            print(f"Config load error: {e}")
    return config

def get_current_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = None
    finally:
        s.close()
    return ip

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
        f"📡 **Raspberry Pi ネットワーク通知**\n"
        f"- **機体名**: `{device_name}`\n"
        f"- **状態**: `{reason}`\n"
        f"- **接続先Wi-Fi**: `{ssid}`\n"
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
    except Exception as e:
        print(f"送信失敗: {e}")

def main():
    last_ip, last_ssid = None, None
    while True:
        current_ip = get_current_ip()
        if current_ip and not current_ip.startswith("127."):
            current_ssid = get_current_ssid()
            if (current_ip != last_ip) or (current_ssid != last_ssid):
                reason = "起動時接続" if last_ip is None else "ネットワーク切り替え"
                send_notification(current_ip, current_ssid, reason)
                last_ip = current_ip
                last_ssid = current_ssid
        else:
            last_ip, last_ssid = None, None
        time.sleep(5)

if __name__ == "__main__":
    main()
