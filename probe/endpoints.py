"""The three endpoint families every heavy workload runs against.

Comparing the same workload across local / cloud / real locates the
bottleneck: WiFi link (local slow), upstream path (cloud slow, local ok),
or third-party service (real slow, cloud ok).
"""
from __future__ import annotations

from dataclasses import dataclass

from .config import settings

# Workload-specific paths served by the reference image (local + cloud).
REF_PATHS = {
    "web": "/page/index.html",
    "video": "/media/reference.mp4",
    "download": "/files/testfile.bin",
}


@dataclass(frozen=True)
class Endpoint:
    name: str  # "local" | "cloud" | "real"
    label: str  # concrete target for the record's `target` field


def targets_for(workload: str) -> list[Endpoint]:
    """Return the local, cloud and real targets for a given workload."""
    path = REF_PATHS.get(workload, "/")
    real = {
        "web": settings.real_web,
        "video": settings.real_video,
        "email": settings.real_imap_host,
        "download": settings.cloud_base + path,  # no free real download target; reuse cloud
    }.get(workload, "")
    return [
        Endpoint("local", settings.local_base + path),
        Endpoint("cloud", settings.cloud_base + path),
        Endpoint("real", real),
    ]
