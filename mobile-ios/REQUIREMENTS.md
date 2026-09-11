# Requirements

Numbered so the dissertation can reference them. The namespace is **M**
for mobile, deliberately separate from the dissertation's existing R1-R7
and S1-S3 so nothing collides.

Where a constraint and a requirement
disagree, the constraint wins. The design that satisfies these is in
`DESIGN.md`.

## Scope in one sentence

A single-screen iOS app that runs the project's measurement workloads
against its existing endpoints, posts the results to the existing backend
as contract-compliant records, and displays the verdict the backend
computes for them.

## Required

**M1. Run five application workloads on the device.**
Web, video, download, bufferbloat (latency under load) and baseline
(DNS, RTT, jitter, loss). Email is excluded: it needs mailbox
credentials on a phone and measures a mail provider rather than a
network. Full per-hop path is excluded; the single-hop exception is M10.

**M2. Run each workload against the same endpoint families as the Pi.**
The `cloud` reference at `comp702-ref.azurewebsites.net` and the `real`
third-party service, using the same URLs the probe uses. The `local`
endpoint is omitted for the application workloads, exactly as it is on
the Pi at the halls site, since there is no wired reference host there.
Baseline follows the probe's own mapping: the gateway by ICMP as `local`
(M10), the cloud reference host by TCP handshake as `cloud` because it
drops ICMP, and the two anchors plus the CDN by ICMP as `real`.

**M3. Emit records that validate against the existing contract.**
`measurement.schema.json`, unmodified. Every record carries `ts`,
`probe_id`, `run_id`, `workload`, `endpoint`, `target`, `ok` and
`metrics`. Validate before posting rather than learning about it from a
422 response.

**M4. Upload over HTTPS to the existing ingest endpoint.**
`POST /ingest` with the bearer token, unchanged. Treat a `duplicate`
response as success, as the probe's buffer does.

**M5. Identify phone records unambiguously.**
`probe_id` of the form `iphone<model>-<owner>`. `site` supplied by the
user with a `phone-` prefix added by the app. The app refuses to measure
if the site field is empty. `context` is posted as null, because none of
its five fields are obtainable on iOS. See C2 and C7.

**M6. Show the backend's verdict, not one computed on the phone.**
After a run, `GET /summary` scoped to the app's own site and render what
comes back: health score and label, the headline sentence, the three
segment lights, and per-workload values against their thresholds. No
thresholds, no scoring and no attribution logic in Swift. This is the
point of the whole design and is not negotiable for convenience.

**M7. One primary screen, superseded 24 August 2026 by the app redesign
plan.**
The original scope was a single screen: a site label field, a Run
button, per-workload progress, the verdict, and a plain list of what was
posted, explicitly with no tab bar, no settings screen and no history
browser, on the grounds that the web dashboard already covers history and
is already responsive. What was actually built is a three-tab app (Now,
History, Trends) with on-device run storage and a Settings screen: see
M11 for why that
line moved. Now still carries everything M7 originally asked for; it is
one tab of three rather than the whole app.

**M8. Record failures as data, not as nothing.**
A workload that fails posts `ok: false` with the error string and empty
metrics, matching the probe. This matters more than it looks: the
backend's availability calculation counts attempted-and-failed runs, and
a phone that silently skipped a failed workload would score itself
healthy during an outage. That is the exact bug the 18 August outage
exposed on the server side.

**M9. Do not lose records to the network being bad.**
The upload fails precisely when the network is worst, which is when the
measurement matters most. Unsent records are held for the session and
retried, with a visible count of what is still pending. A full
store-and-forward buffer across app launches is MS1, not this.

**M10. Measure the WiFi link.**
Promoted from stretch on 21 August 2026, because without it the app
cannot report on the one segment the project is named after.

Tracing `compute_summary` shows why it is required rather than nice to
have. Only web, video, email and download set `endpoint_has_data`, so a
baseline record alone never resolves the `wifi_link` segment. The segment
is decided by the fallback branch, which reads `first_hop_rtt_ms` from a
`path` record. With no such record the app reports "WiFi link: not
measured" on every single run.

So the app must:

1. Discover the default gateway's address. iOS exposes no API for this;
   it needs a route-table lookup. See `DESIGN.md`.
2. Measure RTT and loss to it by ICMP, posted as a `baseline` record with
   `endpoint: "local"`, matching the probe's convention exactly.
3. Post a second, minimal `path` record carrying `first_hop_rtt_ms` set
   to that RTT, which is what lights the segment up. Hop 1 is the router
   over the air, which is precisely what the field is documented to mean.
   Every other `path` metric is omitted, `hops` included, since claiming
   a one-hop path would be false.

**M11. History and Trends, kept on the device.**
Every finished run is written to an on-device store and stays there:
`HistoryView` lists past runs, `RunDetailView` reopens one with the
full evidence it was saved with, and `TrendsView` ranks the networks the
phone has seen. Satisfied by Tasks 4, 6, 9 and 10 of the app redesign
plan.

## Stretch, in priority order

**MS1. Persistent buffer. Done, delivered by Task 5 of the app redesign
plan.** Records survive the app being closed, giving true parity with
the probe's SQLite buffer. It arrived as a consequence of the run store
built for M11 rather than being built for its own sake: once `RunStore`
(Task 4) proved that a disk-backed store works, `PendingStore` grew the
same `directory: URL?` initialiser
(`Sources/WiFiProbeKit/PendingStore.swift`), so the upload queue now
survives the app being killed too.

**MS2. Promoted to M10 on 21 August 2026.** Number retained rather than
reused so earlier references stay valid.

**MS3. Background runs.** `BGProcessingTask`, fired opportunistically by
the OS. Would give a sparse time series rather than isolated points.
Bounded by C4: no hammering of third-party targets.

**MS4. Automatic site labelling.** `NEHotspotNetwork` SSID and BSSID.
Needs a paid developer account for the entitlement, so out of reach on
the current setup and listed here only for completeness.

## Explicit non-requirements

Stated so they are decisions rather than omissions.

- **N1.** No App Store submission, TestFlight or ad-hoc distribution.
- **N2.** Single user, on one phone. Anything else changes the ethics
  category. See C4.
- **N3.** No email workload.
- **N4.** No traceroute and no per-hop decomposition beyond hop 1. The
  single-hop `path` record of M10 is the whole of it: no TTL walking, no
  `mtr`, no rDNS, no ASN lookup, no hop roles.
- **N5.** No scoring, thresholds or attribution on the device.
- **N6.** No Android, and no cross-platform framework.
- **N7.** No change to the backend, probe, contract, dashboards, infra or
  tests. See C1.
- **N8.** No `rssi_dbm`, `wifi_channel` or `cpu_temp_c`. iOS does not
  expose them at any account tier.
- **N9.** No offline mode. A network measurement tool that cannot reach
  the network has nothing to report and should say so.
- **N10.** No third-party Swift packages. Everything is Foundation,
  Network, WebKit, AVFoundation, CryptoKit and SwiftUI, so the CA3 code
  ZIP stays self-contained and nothing can break from upstream.

## Measurement parity

What each workload becomes on iOS, and which contract fields it fills.
This table is a dissertation figure in waiting: it is the concrete answer
to "can a phone do what the Pi does".

| Workload | Pi implementation | iOS implementation | Contract metrics | Parity |
|---|---|---|---|---|
| `web` | Playwright plus headless Chromium, Navigation Timing API | `WKWebView` plus `evaluateJavaScript` running the same Navigation Timing query, non-persistent data store for a cold cache | `dns_ms`, `connect_ms`, `ttfb_ms`, `load_ms` | Full. Same browser API, same four numbers. |
| `download` | `httpx` streamed byte count over elapsed time | `URLSession` with an ephemeral configuration and cache-defeating policy | `throughput_mbps`, `bytes` | Full. `URLSessionTaskMetrics` also offers a finer per-phase breakdown than `httpx` does, unused for now. |
| `loadlat` | TCP handshake RTT to 1.1.1.1:443, idle then during a saturating download | `NWConnection` handshake timing, same anchor, same sampling cadence | `idle_rtt_ms`, `loaded_rtt_ms`, `bloat_ms`, `loaded_rtt_max_ms`, `load_mbps` | Full. |
| `video` | `ffprobe` for duration and bitrate, then a **simulated** player over the byte stream: playback starts at 2 s buffered, the buffer drains at 1x, a dry buffer is a rebuffer | `AVURLAsset` metadata for duration and `estimatedDataRate`, replacing `ffprobe`, then the identical buffer simulation over `URLSession` bytes | `startup_ms`, `rebuffer_count`, `rebuffer_ms`, `stream_mbps`, `bitrate_mbps`, `headroom_x`, `quality_tier` | Full, and deliberately so. `AVPlayer` was considered and rejected: it would be a different measurement rather than a better one, non-comparable with the Pi, and its access log counts stalls without timing them, so `rebuffer_ms` would be lost. |
| `baseline` | `ping` subprocess, TCP handshakes for ICMP-blocking hosts, `ip route` for the gateway | ICMP through a `SOCK_DGRAM` ICMP socket, which needs no root and no entitlement on Darwin; TCP mode through `NWConnection`; gateway from a `sysctl` route dump | `dns_ms`, `rtt_ms`, `jitter_ms`, `loss_pct`, `tcp_mode` | Full, including the gateway leg, subject to the user granting local network permission. |
| `path` | `mtr --tcp -z -b`: per-hop RTT, loss, rDNS, ASN and role | hop 1 only, from the gateway ping | `first_hop_rtt_ms` only | Partial by design, M10 and N4. Enough to resolve the WiFi-link segment, which is what the field exists for. |
| `email` | `imaplib` | not implemented | `fetch_ms` | Excluded, N3. |
| `context` | `iw` for SSID, BSSID, channel and RSSI; thermal zone for CPU temp | none available | `rssi_dbm`, `wifi_channel`, `cpu_temp_c`, `ssid`, `bssid` | None. Posted as null. See C7 and N8. |
| `net_hash` | truncated SHA-256 of the public IP, cached 10 minutes | same, with `CryptoKit` | `net_hash` | Full. Cheap, and keeps the dashboard's network fingerprint working. |

The `context` row is a result, not a gap to apologise for. A phone is a
worse instrument than a Pi in a specific, describable way, and describing
it is part of the contribution.

## Build status, 24 August 2026

| | Requirement | State |
|---|---|---|
| M1 | Five workloads on the device | Built and tested. Web, video, download and bufferbloat verified against live endpoints; see `README.md` for the numbers. |
| M2 | Same endpoint families as the Pi | Built and tested. |
| M3 | Records validate against the contract | Built. The validator runs before every post, and the coordinator test asserts it for every record a run produces. |
| M4 | Upload to the existing `/ingest` | Built and tested against a stubbed backend. The live token was confirmed to be the one the deployed API accepts. |
| M5 | Unambiguous phone identity | Built and tested: the `phone-` prefix is applied by the app and an empty label is refused. |
| M6 | Show the backend's verdict | Client built. Blocked on `DASH_PASS`, which exists only in Azure App Service settings, so `/summary` currently returns 401 until it is filled in. |
| M7 | One primary screen | Superseded; see M7's own entry above and M11 below. The Now tab still carries everything it originally asked for. |
| M8 | Failures recorded as data | Built and tested. |
| M9 | No records lost to a bad network | Built and tested: an unreachable backend leaves every record pending, and the queue is now watched live on the Now screen rather than sampled once. |
| M10 | Measure the WiFi link | Built and corrected. The 21 August "unproven, development network filters ICMP" reading was itself wrong: the halls router answers ICMP echo in about 3.2 ms and always did. A `SOCK_DGRAM` ICMP socket on Darwin delivers the IPv4 header ahead of the ICMP one, and the app was parsing the reply at the wrong offset, manufacturing 100% loss on every host. Fixed in Task 1 of the app redesign plan. The WiFi link is now measured by a three-rung ladder (ICMP echo, then a TTL-limited probe timing the time-exceeded reply, then TCP connect-or-refusal on an on-link address), and the app reports which rung answered, including the real case where none does (confirmed 24 August on 10.224.7.x). |
| M11 | History and Trends, kept on the device | Built and tested. `HistoryView`, `RunDetailView` and `TrendsView` over an on-device `RunStore`. |

## Definition of done

The app is finished when all of these hold. Anything not on this list is
out of scope by default.

1. A run on a physical iPhone, on a real WiFi network, produces at least
   one record for every workload and endpoint pair in M1, M2 and M10.
2. Every one of those records is accepted by the live `/ingest` with a
   201, having validated locally against the contract first.
3. The records appear in the existing dashboards under the phone's own
   `phone-` prefixed site, and a query scoped to `true student` returns
   none of them.
4. The app displays the verdict from `/summary`, and that verdict matches
   what the web overview page shows for the same site and window. Two
   clients, one scoring implementation, identical answer.
5. All three segment lights resolve. `wifi_link` reports `ok` or
   `suspect` from the M10 record, not `no_data`.
6. A run started and then interrupted, by switching to airplane mode
   part-way, posts `ok: false` records for the affected workloads once
   connectivity returns, and the resulting summary reports reduced
   availability rather than a healthy score.
7. `git status` in `src/` shows changes only under `src/mobile-ios/`.
8. The stopping condition in C6 is met: the three tabs work and the WiFi
   link is measured.

## Resolved design questions

Answered in `DESIGN.md`; recorded here so the reasoning is not lost.

1. **Sequential or parallel workloads?** Sequential, with the saturating
   ones last and a settle gap between them. Parallel would be C3 in
   miniature, the app contending with itself. Baseline targets alone run
   in parallel, as they do on the Pi.
2. **How long is a run?** Roughly 60 to 90 seconds. Per-workload progress
   is shown so the wait is legible rather than dead time.
3. **One `run_id` or several?** One per tap, matching `run_heavy`.
4. **What window does the app request?** One hour, anchored on the run's
   completion with `?at=`, which makes the phone the second use case for
   the time-travel feature added on 20 August.
5. **What about a sample size of one?** Disclosure, not cleverness. The
   app knows exactly how many records it posted, so it captions the
   verdict with that count. No backend change, and it is the same
   discipline as the availability fix: report what the number rests on.
