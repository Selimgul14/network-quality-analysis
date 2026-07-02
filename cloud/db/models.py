"""SQLAlchemy model for the measurement hypertable.

The Alembic migration creates the table, then converts it to a Timescale
hypertable:  SELECT create_hypertable('measurement', 'ts');
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Boolean, DateTime, String
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Measurement(Base):
    __tablename__ = "measurement"

    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), primary_key=True)
    probe_id: Mapped[str] = mapped_column(String, primary_key=True)
    run_id: Mapped[str] = mapped_column(String, primary_key=True)
    workload: Mapped[str] = mapped_column(String, primary_key=True)
    endpoint: Mapped[str] = mapped_column(String, primary_key=True)
    target: Mapped[str] = mapped_column(String)
    ok: Mapped[bool] = mapped_column(Boolean)
    error: Mapped[str | None] = mapped_column(String, nullable=True)
    metrics: Mapped[dict] = mapped_column(JSON)
    context: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    raw_ref: Mapped[str | None] = mapped_column(String, nullable=True)
    net_hash: Mapped[str | None] = mapped_column(String, nullable=True)
