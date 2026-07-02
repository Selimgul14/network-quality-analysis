"""Upload large raw payloads (e.g. full traceroute JSON) to Blob Storage.

Only the returned key is stored in Postgres (Measurement.raw_ref).
"""
from __future__ import annotations


def upload_raw(key: str, data: bytes) -> str | None:
    # TODO: use azure-storage-blob with API_BLOB_CONN_STR; return the key,
    # or None when blob storage is not configured (local dev).
    raise NotImplementedError("blob upload: implement with azure-storage-blob")
