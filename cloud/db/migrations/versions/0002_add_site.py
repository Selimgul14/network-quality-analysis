"""Add the site (deployment/network label) column.

Nullable so existing records stay valid; indexed for filtering the
dashboard by network/location.

Revision ID: 0002
Revises: 0001
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("measurement", sa.Column("site", sa.String(), nullable=True))
    op.create_index("ix_measurement_site", "measurement", ["site"])


def downgrade() -> None:
    op.drop_index("ix_measurement_site", table_name="measurement")
    op.drop_column("measurement", "site")
