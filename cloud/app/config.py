"""Backend configuration, loaded from environment / App Service settings."""
from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="API_", env_file=".env")

    ingest_token: str = "dev-token-change-me"
    database_url: str = "postgresql+psycopg://wifi:wifi@localhost:5432/wifi"
    blob_conn_str: str = ""  # Azure Blob connection string; empty disables raw upload


settings = Settings()
