"""Probe configuration, loaded from environment (see .env.example)."""
from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class ProbeSettings(BaseSettings):
    # extra="ignore": .env also holds API_* keys for the backend
    model_config = SettingsConfigDict(env_prefix="PROBE_", env_file=".env", extra="ignore")

    probe_id: str = "pi-dev-01"
    # Deployment label (network/location) stamped on every record. Set per
    # deployment, e.g. PROBE_SITE=liverpool-eduroam-library. Empty -> null.
    site: str = ""

    # Backend ingestion
    ingest_url: str = "http://localhost:8000/ingest"
    ingest_token: str = "dev-token-change-me"

    # Endpoint bases. Each workload appends its own path (page, video, file).
    local_base: str = "http://reference.local"
    cloud_base: str = "https://comp702-ref.azurewebsites.net"
    real_web: str = "https://www.bbc.co.uk/news"
    real_video: str = ""  # public video URL (direct media or yt-dlp page)
    real_download: str = ""  # public test file; empty reuses the cloud endpoint
    real_imap_host: str = ""
    real_imap_user: str = ""
    real_imap_pass: str = ""

    # Cadences (seconds)
    baseline_interval_s: int = 10
    heavy_interval_s: int = 300
    # Bandwidth-heavy workloads (download, latency-under-load) run on their
    # own slower cadence: at 5 min they would move ~15-20 GB/day, which
    # risks a fair-use throttle and hammers the public test file.
    transfer_interval_s: int = 3600

    # Local store-and-forward buffer
    buffer_path: str = "probe_buffer.sqlite"

    # Public anchors for baseline probes
    dns_anchors: list[str] = Field(default_factory=lambda: ["1.1.1.1", "8.8.8.8"])

    # Extra baseline destination classes, so loss can be compared across
    # them (gateway loss = WiFi link; one distant target = that path).
    baseline_gateway: bool = True  # ping the default gateway (WiFi-link leg)
    baseline_cloud: bool = True    # TCP-ping the cloud reference host
    baseline_cdn: str = "www.google.com"  # large anycast CDN; empty disables

    # mtr in TCP mode gets per-hop data on networks that block ICMP echo.
    mtr_tcp: bool = True
    mtr_port: int = 443


settings = ProbeSettings()
