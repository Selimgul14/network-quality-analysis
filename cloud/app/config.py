"""Backend configuration, loaded from environment / App Service settings."""
from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # extra="ignore": .env also holds PROBE_* keys for the probe
    model_config = SettingsConfigDict(env_prefix="API_", env_file=".env", extra="ignore")

    ingest_token: str = "dev-token-change-me"
    database_url: str = "postgresql+psycopg://wifi:wifi@localhost:5432/wifi"
    blob_conn_str: str = ""  # Azure Blob connection string; empty disables raw upload

    # HTTP Basic auth for the dashboard-facing endpoints (/, /summary,
    # /measurements). Empty password disables auth (local dev only;
    # always set both in the cloud).
    dash_user: str = "wifi"
    dash_pass: str = ""


settings = Settings()
