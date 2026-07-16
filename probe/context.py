"""Capture WiFi and thermal context with every record.

Best-effort: returns nulls where a reading is unavailable (e.g. on dev
hardware) so a measurement is never blocked by missing context.
"""
from __future__ import annotations

import subprocess

WIFI_IFACE = "wlan0"


def _cpu_temp_c() -> float | None:
    try:
        raw = open("/sys/class/thermal/thermal_zone0/temp").read().strip()
        return round(int(raw) / 1000, 1)
    except OSError:
        return None


def _iw(*args: str) -> str:
    try:
        return subprocess.run(
            ["iw", "dev", WIFI_IFACE, *args],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except OSError:
        return ""


def _wifi() -> dict[str, object | None]:
    rssi = channel = ssid = bssid = None
    # `iw dev wlan0 link` ->
    #   Connected to 11:22:33:44:55:66 (on wlan0)
    #           SSID: eduroam
    #           signal: -52 dBm
    for line in _iw("link").splitlines():
        s = line.strip()
        if "signal:" in s:
            try:
                rssi = float(s.split()[1])
            except (ValueError, IndexError):
                pass
        elif s.startswith("Connected to"):
            parts = s.split()
            if len(parts) >= 3:
                bssid = parts[2]
        elif s.startswith("SSID:"):
            ssid = s.split("SSID:", 1)[1].strip() or None
    # `iw dev wlan0 info` -> "channel 36 (5180 MHz), width: 80 MHz, ..."
    for line in _iw("info").splitlines():
        if line.strip().startswith("channel"):
            try:
                channel = int(line.split()[1])
            except (ValueError, IndexError):
                pass
    return {"wifi_channel": channel, "rssi_dbm": rssi, "ssid": ssid, "bssid": bssid}


def snapshot() -> dict[str, object | None]:
    return {**_wifi(), "cpu_temp_c": _cpu_temp_c()}
