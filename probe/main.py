"""Probe entry point. Runs under systemd, restarts on failure.

Usage: python -m probe.main
"""
from __future__ import annotations

import logging

from apscheduler.schedulers.blocking import BlockingScheduler

from .buffer import Buffer
from .config import settings
from .scheduler import run_baseline, run_heavy

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("probe")


def main() -> None:
    buffer = Buffer(settings.buffer_path)
    sched = BlockingScheduler(timezone="UTC")
    sched.add_job(run_baseline, "interval", seconds=settings.baseline_interval_s,
                  args=[buffer], id="baseline", max_instances=1)
    sched.add_job(run_heavy, "interval", seconds=settings.heavy_interval_s,
                  args=[buffer], id="heavy", max_instances=1)
    log.info("probe %s starting: baseline %ss, heavy %ss",
             settings.probe_id, settings.baseline_interval_s, settings.heavy_interval_s)
    sched.start()


if __name__ == "__main__":
    main()
