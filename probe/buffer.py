"""Local store-and-forward buffer (SQLite, WAL mode).

Every record is written here first, then the uploader drains it. A short
cloud outage therefore never loses data.

APScheduler runs jobs in worker threads, so the connection is opened with
check_same_thread=False and guarded by a lock (SQLite connections are not
thread-safe by themselves).
"""
from __future__ import annotations

import json
import sqlite3
import threading
from collections.abc import Iterator

_SCHEMA = """
CREATE TABLE IF NOT EXISTS pending (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL
);
"""


class Buffer:
    def __init__(self, path: str) -> None:
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        self.conn.execute("PRAGMA journal_mode=WAL;")  # survive interrupted writes
        self.conn.executescript(_SCHEMA)
        self.conn.commit()

    def add(self, record: dict) -> None:
        with self._lock:
            self.conn.execute("INSERT INTO pending (payload) VALUES (?)", (json.dumps(record),))
            self.conn.commit()

    def take(self, limit: int = 50) -> Iterator[tuple[int, dict]]:
        with self._lock:
            rows = self.conn.execute(
                "SELECT id, payload FROM pending ORDER BY id LIMIT ?", (limit,)
            ).fetchall()
        for rid, payload in rows:
            yield rid, json.loads(payload)

    def ack(self, ids: list[int]) -> None:
        with self._lock:
            self.conn.executemany("DELETE FROM pending WHERE id = ?", [(i,) for i in ids])
            self.conn.commit()
