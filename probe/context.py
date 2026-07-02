"""Capture WiFi and thermal context with every record.

Best-effort: returns nulls where a reading is unavailable (e.g. on dev
hardware) so a measurement is never blocked by missing context.
"""
from __future__ import annotations

import subprocess


def _cpu_temp_c() -> float | None:
    try:
        raw = open("/sys/class/thermal/thermal_zone0/temp").read().strip()
        return round(int(raw) / 1000, 1)
    except OSError:
        return None


def _wifi() -> dict[str, object | None]:
    # TODO: parse `iw dev wlan0 link` for channel + signal (RSSI).
    try:
        out = subprocess.run(["iw", "dev", "wlan0", "link"], capture_output=True, text=True).stdout
        rssi = next((float(l.split()[1]) for l in out.splitlines() if "signal" in l), None)
    except (OSError, ValueError, IndexError):
        rssi = None
    return {"wifi_channel": None, "rssi_dbm": rssi}


def snapshot() -> dict[str, object | None]:
    return {**_wifi(), "cpu_temp_c": _cpu_temp_c()}
