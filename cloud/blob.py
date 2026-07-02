"""Upload large raw payloads (e.g. full traceroute JSON) to Blob Storage.

Only the returned key is stored in Postgres (Measurement.raw_ref).
"""
from __future__ import annotations

from cloud.app.config import settings

CONTAINER = "raw-payloads"


def upload_raw(key: str, data: bytes) -> str | None:
    """Upload data under key; return the key, or None when Blob is not
    configured (local dev without Azure)."""
    if not settings.blob_conn_str:
        return None

    # Imported lazily so local dev works without the Azure SDK configured.
    from azure.storage.blob import BlobServiceClient

    service = BlobServiceClient.from_connection_string(settings.blob_conn_str)
    container = service.get_container_client(CONTAINER)
    if not container.exists():
        container.create_container()
    container.upload_blob(name=key, data=data, overwrite=True)
    return key
