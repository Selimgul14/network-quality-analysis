# Constraints

Binding rules for the iOS work. These exist because the rest of the
project is finished, deployed and collecting the data that Chapter 4 of
the dissertation is built on. The app is an addition. It is not allowed
to put any of that at risk.

Read this before `REQUIREMENTS.md`, and before writing a line of code.

## C1. Nothing outside this folder may be modified

The only writable path is `src/mobile-ios/`.

Protected, read-only for the duration of this work:

| Path | Why it is protected |
|---|---|
| `src/contracts/measurement.schema.json` | The contract is the source of truth for the probe, the backend and both dashboards. Changing it invalidates 385k stored records. |
| `src/probe/**` | Running unattended at the halls site. A bad commit that reaches the Pi stops the deployment. |
| `src/cloud/**` | Live on Azure. A redeploy that fails takes the ingest endpoint down and the probe starts buffering. |
| `src/dashboard/**` | Live, and the subject of the CA2 video that has already been submitted. |
| `src/infra/**` | Deployed Azure resources. |
| `src/tests/**` | The 49 passing tests are cited in the CA2 video. |
| `../dissertation/**`, `../CLAUDE.md` | Written up separately, once the app exists and there is something true to say about it. **Relaxed by explicit request on 21 August 2026**: both were updated to record this work. Still off limits for anything beyond describing the mobile app. |

**If a change outside this folder appears necessary, stop and raise it.
Do not make it.** The design was chosen specifically so that no such
change is needed. If one turns out to be needed anyway, that is new
information about the design and it deserves a conversation, not a quiet
edit.

Verification: `git status` inside `src/` must show changes only under
`src/mobile-ios/`. Check this before every commit.

### C1 exceptions granted

**21 August 2026, the site filter.** Adding a second probe class exposed a
flaw that predated it: `dashboard/summary/overview.html` requested
`/summary` with no `site` parameter, and the Grafana dashboard had no
site filter either, so both averaged every deployment in the database
into one figure. That was already wrong while the Pi alone reported under
`true student`, home and eduroam labels. With a phone reporting too it
became a single health score spanning two devices on two networks, which
describes nothing real.

Authorised and changed:

- `dashboard/summary/overview.html`: reads `?site=`, passes it to
  `/summary`, gains a network picker fed from `/sites`, and labels an
  unscoped view "all networks combined" in red rather than presenting a
  blend as a verdict.
- `dashboard/grafana/dashboards/wifi-timeseries.json`: a `site` template
  variable, and all ten panel queries filtered by it. Rows predating the
  site column are folded into `unlabelled` by `coalesce` so they are not
  silently dropped from an `IN` list.

Neither touches the probe, the contract, the backend or the attribution
logic. `pytest` still passes (53 passed, 1 skipped). **Both need a
redeploy to take effect:** `src/infra/deploy.sh api grafana`.

This is worth a paragraph in the dissertation. It is the fourth time in
this project that the data was right and the presentation was not, after
the quantised loss panel, the bucket size and the gap-spanning line.

### Known items deliberately deferred rather than done

- A `probe_id` filter on `GET /summary` and `GET /measurements`. It would
  be tidy, and it is a ten-line change mirroring the existing `site`
  filter, but it is not needed: because every phone run carries its own
  `site` label, `?site=<phone site>` already scopes a query to phone data
  alone. Deferred until after CA3, if ever.
- A `device` field in `context`. The contract sets
  `additionalProperties: false` on `context`, so this would be a schema
  change. Not worth it. The device goes in `probe_id` instead.

## C2. Phone data must never mix with the deployment dataset

Chapter 4 analyses roughly 385k records collected at the halls site under
`site = "true student"` since late July. Phone records land in the same
`measurement` hypertable, because they go through the same `/ingest`.
Separation is therefore by column value, not by physical storage, and it
has to be enforced by the app rather than hoped for.

Rules:

1. Every phone record sets `site` to a label starting `phone-`, for
   example `phone-halls-room`, `phone-library`, `phone-costa-bold-st`.
   The prefix is added by the app and is not user-editable.
2. Every phone record sets `probe_id` to `iphone<model>-<owner>`, for
   example `iphone13-selim`. Never `pi-` anything.
3. The app refuses to run at all if the site field is empty. There is no
   default, no fallback and no "unlabelled" path. An unlabelled phone
   record is the one outcome that would be hard to unpick later.
4. Any CA3 analysis query filters explicitly, either to the Pi sites by
   name or with `site NOT LIKE 'phone-%'`. Do not rely on an unfiltered
   query happening to be correct.

Accepted cosmetic consequence: `GET /sites` lists every distinct site, so
phone labels will appear in the dashboard's network picker alongside the
real deployments. That is visible in a screenshot but harmless, and the
`phone-` prefix makes it self-explanatory to a marker.

## C3. The app must not perturb the Pi's measurements

This is the contamination risk that matters most, and it is easy to miss.

The download workload pulls tens of megabytes and the bufferbloat workload
deliberately saturates the uplink. Running either on the same network the
Pi is measuring will inflate the Pi's loss, latency-under-load and
throughput figures for that window. The Pi cannot tell the difference
between a congested network and a phone in the same room congesting it.

Rules:

1. Do not run the app on the halls network while the Pi is collecting
   there, unless the run is deliberate and recorded.
2. If a run on that network is unavoidable, note the exact start and end
   timestamps in `RUNS.md` so those windows can be excluded from, or at
   least annotated in, the Chapter 4 analysis.
3. Prefer a different network for development and testing.

This one is worth a paragraph in the dissertation on its own. A
measurement tool that changes what it measures is a real methodological
point, and it sits alongside the three presentation bugs already written
up in `meetings/2026-08-problems-and-fixes.md`.

## C4. Ethics: the category must not change

The project is approved as **Data Category B, Participant Category 0**:
anonymous network telemetry, no human participants, the probe measures
only traffic it generated itself.

An app that only ever runs on the student's own phone, measuring the
student's own traffic, keeps that unchanged. It is the same probe with a
different enclosure.

An app that other people install does not. Their network, their location
and their usage pattern would be data derived from a participant, and
that needs re-approval before a single record is collected.

Therefore:

1. Single user only. The app is not given to anyone else, not by
   TestFlight, not by ad-hoc build, not by App Store.
2. Distribution is written about as future work, with the ethics
   requirement stated as part of it. It is not attempted.
3. The real-world targets are third-party services. The public test file
   at `ipv4.download.thinkbroadband.com` is a courtesy, not an
   entitlement. Manual, on-demand runs only. No timer, no loop, no
   background schedule that could hammer it. The Pi already moved to an
   hourly transfer cadence for exactly this reason.

## C5. Credentials

The ingest bearer token is a static shared secret. Embedding it in an app
binary means anyone who extracts the IPA can write to the database. For
one sideloaded build on one phone that is an acceptable draft-quality
tradeoff, and it will be stated as such in the write-up rather than
glossed over.

Rules:

1. The token never appears in a committed file. It goes in a gitignored
   local config that the build reads.
2. No screenshot, demo recording or dissertation figure shows it.
3. The write-up names this as the concrete blocker to distribution, and
   names the fix: per-device credentials or a token-exchange endpoint.

`CLAUDE.md` already flags that the Postgres password, ingest token and
dashboard password are all dev-grade and were pasted in chat. Rotating
them is a separate pre-existing task and is not in scope here.

### C6. The dissertation outranks this work

The three working day cap was lifted on 23 August 2026 at the user's
explicit instruction. It is replaced by a stopping condition rather than
a number:

> The app is finished when the three tabs work and the WiFi link is
> measured. Nothing beyond that is built before the dissertation is
> written.

CA3 is due 11 September 2026 and Chapter 4 is not written. The sequencing
agreed on 23 August is app, then fault injection, then writing, which
puts two build tasks in front of a 50 page document. Writing therefore
proceeds in parallel rather than afterwards.

## C7. Platform limits are accepted, not worked around

Running under a free Apple ID on a personal device:

- The build expires after seven days. Re-install before any demo or
  recording. Put it in the calendar.
- No Access WiFi Information entitlement, so `NEHotspotNetwork` cannot
  give SSID or BSSID. The site label is typed by hand. Do not attempt to
  obtain these through private API.
- No public API exists for signal strength on iOS at all, at any account
  tier. `rssi_dbm` is simply unavailable, and so are `wifi_channel` and
  `cpu_temp_c`. These stay null and the absence is reported in the
  write-up as a finding about the platform.
- Background execution is opportunistic. The phone can never match the
  Pi's 10-second baseline cadence. The app is a spot check by
  construction, and the design says so rather than pretending otherwise.

## C8. The contract is authoritative and read-only

`measurement.schema.json` decides what a record looks like. If a phone
metric does not fit the contract, the metric is dropped, not the contract
widened. The existing `metrics` object already allows arbitrary numeric
and string keys, so in practice this only binds the top-level fields and
`context`.

Any record the app produces must validate against the schema before it is
posted. Validate locally rather than discovering it from a 422.
