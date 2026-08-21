# Run log

Every measurement run made from the phone, so that any window where the
app may have perturbed the Pi's data can be excluded from the Chapter 4
analysis. Required by C3.

Log a row whenever the app runs on a network a Pi is also measuring.
Runs on unrelated networks are worth logging too, since they are the
evidence for the write-up.

| Date (UTC) | Start | End | Network / site label | Pi collecting on this network? | Notes |
|---|---|---|---|---|---|
| 2026-08-21 | ~14:55 | ~15:05 | dev Mac, gateway 10.224.23.254 (not a Pi site) | No | Live integration tests from `LiveNetworkTests`: 25 MiB from the cloud reference plus a 1 MB video. Saturating transfers, so logged per C3. No records were posted to the database. |
| 2026-08-21 | ~16:10 | ~16:12 | dev Mac, gateway 10.224.23.254 (not a Pi site) | No | Live ingest smoke test (`IngestSmokeTest`). **One** record written to the production database: site `phone-smoke-test`, probe `iphone13-selim`, workload baseline/cloud, TCP handshake to the reference host. Accepted 201. Filter it out with `site LIKE 'phone-%'`. |

