"""Local store-and-forward buffer (SQLite, WAL mode).

Every record is written here first, then the uploader drains it. A short
cloud outage therefore never loses data.
"""
from __future__ import annotations

import json
import sqlite3
from collections.abc import Iterator

_SCHEMA = """
CREATE TABLE IF NOT EXISTS pending (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL
);
"""


class Buffer:
    def __init__(self, path: str) -> None:
        self.conn = sqlite3.connect(path)
        self.conn.execute("PRAGMA journal_mode=WAL;")  # survive interrupted writes
        self.conn.executescript(_SCHEMA)
        self.conn.commit()

    def add(self, record: dict) -> None:
        self.conn.execute("INSERT INTO pending (payload) VALUES (?)", (json.dumps(record),))
        self.conn.commit()

    def take(self, limit: int = 50) -> Iterator[tuple[int, dict]]:
        rows = self.conn.execute(
            "SELECT id, payload FROM pending ORDER BY id LIMIT ?", (limit,)
        ).fetchall()
        for rid, payload in rows:
            yield rid, json.loads(payload)

    def ack(self, ids: list[int]) -> None:
        self.conn.executemany("DELETE FROM pending WHERE id = ?", [(i,) for i in ids])
        self.conn.commit()
