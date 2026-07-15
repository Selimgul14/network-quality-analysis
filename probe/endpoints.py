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
    real = {
        "web": settings.real_web,
        "video": settings.real_video,
        "email": settings.real_imap_host,
        # real download: a genuine public test file if set, else reuse cloud
        "download": settings.real_download or settings.cloud_base + REF_PATHS["download"],
    }.get(workload, "")

    # email is IMAP: the nginx reference (local/cloud) can't serve it, so
    # only the real mailbox is a valid target.
    if workload == "email":
        return [Endpoint("real", real)]

    path = REF_PATHS.get(workload, "/")
    eps: list[Endpoint] = []
    # local server may be absent (e.g. Pi on eduroam): skip cleanly rather
    # than record failures against a bare, unreachable path.
    if settings.local_base:
        eps.append(Endpoint("local", settings.local_base + path))
    eps.append(Endpoint("cloud", settings.cloud_base + path))
    eps.append(Endpoint("real", real))
    return eps
