# mobile-ios: phone as a second probe class

An iOS draft that runs the project's measurement workloads on a phone and
reports them through the existing cloud backend, unchanged.

**Status (24 August 2026): builds and runs. 141 tests passing (1
skipped), the iOS app launches in the simulator and on a physical iPhone,
and the live backend has accepted a record from this client. The app is
now three tabs (Now, History, Trends) plus Settings, with runs kept on
the device, and the WiFi link is measured for real: see Known gaps.**

## Why this exists

The Raspberry Pi probe costs around GBP 100 and has to be plugged in and
left somewhere. That works for an operator (a hotel, a cafe, a student
residence measuring its own network) but it cannot be handed to everyone.
The supervisor asked, on 21 August 2026, what a mobile app would look
like. This folder is the answer, built as a draft rather than a product,
because CA3 is due on 11 September 2026 and carries 70% of the module.

The argument is not that a phone replaces the Pi. It is that the two are
different probe classes over one contract:

| | Pi probe | Phone probe |
|---|---|---|
| Who runs it | site operator | any end user |
| Cost | ~GBP 100 | none, they own it |
| Cadence | continuous, 10 s baseline | on demand, a spot check |
| Strength | longitudinal depth at one point | spatial and network breadth |
| Weakness | one location, capital cost | no background continuity, fewer sensors |

Both post the same `measurement.schema.json` records to the same
`POST /ingest`, and both are scored by the same `cloud/app/summary.py`.
That last point is the whole claim: any difference in verdict between a
phone and the Pi is a difference in the network, not a difference in two
implementations of the scoring.

## Where this lands in CA3

- Chapter 2 (Design): a section on the two-tier probe architecture and
  what the contract had to already get right for a second probe class to
  drop in without a schema change.
- Chapter 3 (Implementation): the iOS measurement mapping, and what the
  platform refuses to give you.
- Chapter 6 (Future Work): distribution, per-device credentials, and the
  ethics re-approval that real distribution would need.
- CA2 Q&A: a live demo answering "how would you scale this past one Pi".

## Build state

| Piece | State |
|---|---|
| `WiFiProbeKit` package: contract, config, endpoints | built, tested |
| ICMP pinger, TTL-limited probe, TCP probe, gateway ladder, route table, HTTP streamer, net hash | built, tested; ICMP now confirmed against a real reply (see below) |
| Workloads: web, video, download, bufferbloat, baseline, path (M10) | built, tested |
| Pending store (survives the app being killed, MS1), uploader, run coordinator, summary client | built, tested |
| Run store, per-site trend ranking | built, tested |
| iOS app: three tabs (Now, History, Trends) plus Settings | built; launches in the simulator and on a physical iPhone |
| A record accepted by the live `/ingest` | **done**, 201 from the deployed API |
| A full run from a physical iPhone | done for the app itself; the interruption test and Chapter 4 screenshots are still parked in `NEXT.md` |

Toolchain: Swift 6.2.3, Xcode 26.2, iOS 17 deployment target, no
third-party packages (N10).

```
cd WiFiProbeKit && swift test        # 141 tests, 1 skipped, no device needed

xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The Xcode project is hand-written rather than generated, since no project
generator was installed and adding one seemed worse than 300 lines of
`project.pbxproj`. `WiFiProbe/App.xcconfig` is committed and holds empty
defaults, then optionally includes the gitignored `Secrets.xcconfig`, so
the project builds on a machine with no secrets and `AppConfig` reports
which key is missing instead of failing obscurely.

Everything measurable lives in a SwiftPM package rather than the app
target, so it builds and tests from the command line on macOS. The app is
a thin SwiftUI shell over it. That split was not in the original design;
it was adopted so the logic could be tested at all without driving a
simulator.

### Live numbers from the integration tests, 21 August

Run from a dev Mac, and reassuringly close to the Pi's own figures:

| Measurement | Phone code | Pi (see `../../CLAUDE.md`) |
|---|---|---|
| Cloud reference RTT | 36.75 ms, 0% loss | 34.5 ms to Azure Oslo |
| Download | 56.54 Mbps over 26,214,400 bytes | 55-65 Mbps |
| Idle TCP RTT to 1.1.1.1 | 13.95 ms | ~13.3 ms |
| Video | startup 114 ms, 0 rebuffers, headroom 68.65x, tier 4K | same seven metrics |

### Known gaps

- **The WiFi link was never measured, and the network was never the
  reason.** The 21 August "campus router ignores ICMP, unproven until it
  runs on a phone" reading was wrong. Verified on the halls network,
  24 August 2026: the router answers ICMP echo in about 3.2 ms, and
  always did. What looked like silence was a client-side parsing bug in
  `ICMPPinger.parseReply`: a `SOCK_DGRAM` ICMP socket on Darwin returns
  the IPv4 header ahead of the ICMP one, and the old code read the type
  byte at offset 0 instead of skipping that header, so it rejected every
  real reply and manufactured 100% loss on every host, on every network,
  including the working one. Fixed in Task 1 of the app redesign plan
  (see `specs/2026-08-24-app-redesign-plan.md`).
- **The WiFi link is now measured by a three-rung ladder**
  (`GatewayProbe.swift`): ICMP echo first; if that gets nothing, a
  TTL-limited probe whose time-exceeded reply times the first hop, the
  same method `mtr` uses for hop 1 on the Pi; if that also gets nothing,
  TCP connect-or-refusal on an on-link candidate address. The app reports
  which rung answered, so a result is never silently guessed at.
- **A router that answers nothing at all is a real case, not a
  hypothetical one.** Confirmed 24 August 2026 on a different network
  (10.224.7.x): echo, the TTL-limited probe, and all four candidate TCP
  ports each returned nothing. The ladder exists for exactly this, and
  reports "none" rather than inventing a number.
- **`DASH_PASS` is empty** in `Secrets.xcconfig`. It exists only in Azure
  App Service settings. Until it is filled, `GET /summary` returns 401
  and M6 cannot be demonstrated.

### The three tabs

- **Now** is the original one-screen design (M1-M6, M8-M10): pick a
  network, run it, see the score, the headline and the three segment
  lights. It also shows "Waiting to upload" whenever the pending queue is
  non-zero, kept live by a background watch rather than a single sample
  (see the controller ruling recorded against Task 11 in
  `specs/2026-08-24-app-redesign-plan.md`).
- **History** lists every run kept on the device; tapping one opens
  `RunDetailView`, the full evidence a run was saved with, including the
  WiFi-link ladder's attempts.
- **Trends** ranks the networks the phone has seen by median score, with
  a per-site chart over score, download and latency (`SiteTrendView`).
- **Settings** (reached from the gear icon on Now) shows the probe id,
  how many runs are kept, the pending-upload count, the site prefix, and
  a destructive "delete all local runs" action that is explicit about
  only touching the phone's own copy: uploaded records stay on the
  server, since there is no delete endpoint.

## Documents

Read in this order. Both are binding, not background.

1. `CONSTRAINTS.md` — what must not be touched, and why. Read first.
2. `REQUIREMENTS.md`: numbered requirements M1-M11, stretch, explicit
   non-requirements, the measurement parity table, and the definition of
   done.
3. `DESIGN.md` — how the requirements are met, plus an as-built section
   recording where the code departed from it.
4. `RUNS.md` — log of every run made from the phone, required by C3.

## Decisions already taken

Settled during the brainstorming session on 21 August 2026:

| Decision | Choice | Reasoning |
|---|---|---|
| Role of the app | Phone acts as a probe, not a viewer | The dashboards are already responsive, so a viewer app adds nothing. A probe answers the actual question. |
| Where scoring happens | Server side, in the existing `summary.py` | One implementation of the thresholds, attribution and health score. Reimplementing them in Swift would let the two drift and would kill the comparability claim. |
| Workloads | Five: web, video, download, bufferbloat, baseline | Covers the full health weighting including video at 0.35, so a phone score is comparable to a Pi score rather than a renormalised subset. |
| Language | Swift and SwiftUI, native | Every measurement is a platform API. Flutter would mean writing the same Swift and then a Dart channel layer on top of it. |
| Device | Own iPhone, free Apple ID | Sideload from Xcode. Real phone WiFi, 7-day expiry, no entitlements. |
| Record identity | `probe_id` carries the device, `context` stays null | Avoids widening the contract, which forbids extra `context` keys. The phone cannot fill `rssi_dbm`, `wifi_channel` or `cpu_temp_c` anyway. |
| Data separation | Distinct `site` per run, `phone-` prefixed | Keeps phone records out of the `true student` deployment dataset that Chapter 4 depends on. |
| WiFi link | Gateway RTT promoted from stretch to required (M10) | Reading `summary.py` showed the segment resolves only from a `path` record's `first_hop_rtt_ms`. Without it the app would report "WiFi link: not measured" every run, which is no answer at all from a WiFi tool. |
| Video method | Port the Pi's simulated player, not `AVPlayer` | `video.py` simulates playback over the byte stream rather than using a real player. `AVPlayer` would be a different measurement, not a better one, non-comparable with the Pi, and its access log counts stalls without timing them, losing `rebuffer_ms`. |

Rejected: `AVPlayer` for the video workload (see above), on-device
scoring (duplicated logic), a read-only viewer app
(adds nothing over the responsive web pages), a standalone app that never
uploads (abandons objective 3), Flutter and React Native (platform-channel
overhead for zero gain on an iOS-only draft), and Android (no time).
