"""Create the measurement table and convert it to a Timescale hypertable.

Revision ID: 0001
Revises: None
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "measurement",
        sa.Column("ts", sa.DateTime(timezone=True), nullable=False),
        sa.Column("probe_id", sa.String(), nullable=False),
        sa.Column("run_id", sa.String(), nullable=False),
        sa.Column("workload", sa.String(), nullable=False),
        sa.Column("endpoint", sa.String(), nullable=False),
        sa.Column("target", sa.String(), nullable=False),
        sa.Column("ok", sa.Boolean(), nullable=False),
        sa.Column("error", sa.String(), nullable=True),
        sa.Column("metrics", sa.JSON(), nullable=False),
        sa.Column("context", sa.JSON(), nullable=True),
        sa.Column("raw_ref", sa.String(), nullable=True),
        sa.Column("net_hash", sa.String(), nullable=True),
        # ts first: Timescale requires the partition column in the PK.
        sa.PrimaryKeyConstraint("ts", "probe_id", "run_id", "workload", "endpoint"),
    )
    op.create_index("ix_measurement_workload_endpoint", "measurement", ["workload", "endpoint"])

    # Hypertable conversion is Postgres/Timescale only; skip on other dialects
    # (unit tests run against SQLite).
    if op.get_bind().dialect.name == "postgresql":
        op.execute("CREATE EXTENSION IF NOT EXISTS timescaledb")
        op.execute("SELECT create_hypertable('measurement', 'ts')")


def downgrade() -> None:
    op.drop_index("ix_measurement_workload_endpoint", table_name="measurement")
    op.drop_table("measurement")
