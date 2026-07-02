"""The measurement schema is valid and a sample record conforms to it."""
import json
from pathlib import Path

import jsonschema

SCHEMA = json.loads((Path(__file__).parents[1] / "contracts" / "measurement.schema.json").read_text())


def test_schema_is_valid():
    jsonschema.Draft202012Validator.check_schema(SCHEMA)


def test_sample_record_validates():
    record = {
        "ts": "2026-07-02T14:58:00+00:00",
        "probe_id": "pi-maple-01",
        "run_id": "abc123",
        "workload": "download",
        "endpoint": "local",
        "target": "http://reference.local/files/testfile.bin",
        "ok": True,
        "error": None,
        "metrics": {"throughput_mbps": 45.3, "bytes": 52428800},
        "context": {"wifi_channel": 36, "rssi_dbm": -52, "cpu_temp_c": 48.1},
        "raw_ref": None,
        "net_hash": None,
    }
    jsonschema.validate(record, SCHEMA)
