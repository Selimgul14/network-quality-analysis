"""Probe configuration, loaded from environment (see .env.example)."""
from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class ProbeSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="PROBE_", env_file=".env")

    probe_id: str = "pi-dev-01"

    # Backend ingestion
    ingest_url: str = "http://localhost:8000/ingest"
    ingest_token: str = "dev-token-change-me"

    # Endpoint bases. Each workload appends its own path (page, video, file).
    local_base: str = "http://reference.local"
    cloud_base: str = "https://comp702-ref.azurewebsites.net"
    real_web: str = "https://www.bbc.co.uk/news"
    real_video: str = ""  # public video URL for yt-dlp
    real_imap_host: str = ""

    # Cadences (seconds)
    baseline_interval_s: int = 10
    heavy_interval_s: int = 300

    # Local store-and-forward buffer
    buffer_path: str = "probe_buffer.sqlite"

    # Public anchors for baseline probes
    dns_anchors: list[str] = Field(default_factory=lambda: ["1.1.1.1", "8.8.8.8"])


settings = ProbeSettings()
