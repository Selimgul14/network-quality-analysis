"""A failed workload still produces a schema-shaped record (ok=False)."""
import json
from pathlib import Path

import jsonschema

from probe.scheduler import _record

SCHEMA = json.loads((Path(__file__).parents[1] / "contracts" / "measurement.schema.json").read_text())


def test_failed_run_is_valid_record():
    # web workload is a NotImplementedError stub, so this exercises the
    # failure path: the record is still valid and marked not ok.
    rec = _record("web", "local", "http://reference.local/page/index.html", "run1")
    assert rec["ok"] is False
    assert rec["error"]
    jsonschema.validate(rec, SCHEMA)
