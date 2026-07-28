"""Probe entry point. Runs under systemd, restarts on failure.

Usage: python -m probe.main
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone

from apscheduler.schedulers.blocking import BlockingScheduler

from .buffer import Buffer
from .config import settings
from .scheduler import run_baseline, run_heavy, run_transfer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("probe")


def main() -> None:
    buffer = Buffer(settings.buffer_path)
    sched = BlockingScheduler(timezone="UTC")
    # next_run_time=now: fire both jobs at startup instead of waiting one
    # full interval, so a fresh probe produces data immediately.
    now = datetime.now(timezone.utc)
    sched.add_job(run_baseline, "interval", seconds=settings.baseline_interval_s,
                  args=[buffer], id="baseline", max_instances=1, next_run_time=now)
    sched.add_job(run_heavy, "interval", seconds=settings.heavy_interval_s,
                  args=[buffer], id="heavy", max_instances=1, next_run_time=now)
    sched.add_job(run_transfer, "interval", seconds=settings.transfer_interval_s,
                  args=[buffer], id="transfer", max_instances=1, next_run_time=now)
    log.info("probe %s starting: baseline %ss, heavy %ss, transfer %ss",
             settings.probe_id, settings.baseline_interval_s,
             settings.heavy_interval_s, settings.transfer_interval_s)
    sched.start()


if __name__ == "__main__":
    main()
