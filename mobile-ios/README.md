# WiFiProbe: the phone as a second probe class

An iOS client that runs the same measurement workloads as the Raspberry
Pi probe and reports them through the same backend, unchanged. It is not
a dashboard for the Pi's data; it is a second instrument that speaks the
same data contract.

**Status:** builds and runs on a physical iPhone (iOS 17+). 141 unit
tests in the `WiFiProbeKit` package, 1 skipped. The live backend accepts
its records. Swift 6, SwiftUI, no third-party packages.

## Why it exists

The Pi costs around GBP 100 and has to be left plugged in. That suits a
site operator (a hotel, a cafe, a student residence measuring its own
network) but cannot be handed to everyone. A phone can.

| | Pi probe | Phone probe |
|---|---|---|
| Who runs it | site operator | any end user |
| Cadence | continuous, 10 s baseline | on demand, a spot check |
| Strength | longitudinal depth at one point | spatial breadth: carry it to where the WiFi is poor |
| Weakness | one location, capital cost | no background continuity, fewer sensors |

Both post the same `measurement.schema.json` records to the same
`POST /ingest`, and both are scored by the same `cloud/app/summary.py`.
That removes one source of disagreement between the two instruments,
the analysis. It does not remove the other: the instruments themselves
differ. Section 4.4.1 of the dissertation puts the two side by side on
the same network in the same hour and shows where they agree (verdict,
controlled reference) and where they do not (wireless-link delay, page
load, bufferbloat), and why.

## What it measures

The five workloads are ports of the Python originals, with constants
copied rather than re-chosen so the numbers stay comparable:

- **Web**: a fresh, cache-less `WKWebView` loads the target and the same
  Navigation Timing JavaScript the Pi's Chromium runs is evaluated, so
  both report the browser's own figures.
- **Video**: the Pi's simulated player, ported line for line (startup
  delay, rebuffers, delivery rate, headroom, quality tier).
- **Download** and **bufferbloat** (latency under load): `URLSession`
  streaming with TCP-handshake timing to a public anchor before and
  during the transfer.
- **Baseline**: ICMP echo over a datagram socket, or a TCP handshake
  where the target drops ICMP, to the same destination classes as the Pi.
- **The WiFi link**: iOS has no traceroute and no gateway API, so the
  route table is read via `sysctl` and the gateway is measured by a
  three-rung ladder: ICMP echo, then a TTL-limited probe timed by the
  first hop's *time exceeded* reply (the method `mtr` uses for hop 1),
  then a TCP connect-or-refusal to an on-link address. The app reports
  which rung answered, and says so when none does.

Email is omitted; the server-side score renormalises the remaining
weights.

## The bug worth knowing about

For three days the app reported 100% packet loss to every router on
every network, which was read as routers refusing echo requests. The
routers were answering in about three milliseconds. On Darwin a
`SOCK_DGRAM` ICMP socket delivers the IPv4 header *ahead of* the ICMP
header, and the parser was reading the reply type at offset zero. Sound
data, a wrong parsing assumption, and a fabricated impairment
indistinguishable from a network fault. It is one of seven such
artefacts recorded in the dissertation, and the reason the WiFi-link
ladder exists.

## Layout

```
mobile-ios/
├── WiFiProbeKit/            Swift package: everything measurable, testable from the CLI
│   ├── Sources/WiFiProbeKit/
│   │   ├── Contract/        Record model, validator (mirrors measurement.schema.json)
│   │   ├── Net/             ICMP pinger, TCP probe, gateway ladder, route table, streamer
│   │   ├── Workloads/       web, video simulator, transfer, baseline, navigation timing
│   │   ├── Store/           on-device run history
│   │   ├── PendingStore.swift   upload queue that survives the app being killed
│   │   ├── Uploader.swift       retries; 401/403/422 are permanent, not retried
│   │   ├── RunCoordinator.swift one run = all workloads, three endpoints, one summary
│   │   └── SummaryClient.swift  reads the verdict back from /summary
│   └── Tests/               141 tests, no device needed
├── WiFiProbe/               thin SwiftUI shell: Now, History, Trends, Settings
├── WiFiProbe.xcodeproj
├── App.xcconfig             committed; empty defaults
├── Secrets.xcconfig.example copy to Secrets.xcconfig (gitignored) and fill in
├── REQUIREMENTS.md          numbered requirements and the parity table
├── DESIGN.md                how they are met, plus an as-built section
└── RUNS.md                  log of every run made from the phone
```

The package-plus-shell split was adopted so the logic could be tested
without driving a simulator.

## Build

```
cd WiFiProbeKit && swift test        # no device needed

cp Secrets.xcconfig.example Secrets.xcconfig   # then fill in the hosts and token
xcodebuild -project WiFiProbe.xcodeproj -scheme WiFiProbe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Notes that will otherwise cost an afternoon:

- `//` starts a comment in an xcconfig file, so hosts are stored without
  the scheme and the scheme is added in code.
- App Transport Security blocks cleartext HTTP; the real download target
  is served over HTTP, so an ATS exception is declared for it.
- `NSLocalNetworkUsageDescription` is required for the gateway ladder.
- A `WKWebView` outside the view hierarchy can be throttled; it is
  mounted at 1x1 point rather than kept offscreen.

## Data separation

Every record the app posts carries a forced `phone-` site prefix, so
phone runs never mix with a Pi's deployment dataset. `RUNS.md` logs every
run for the same reason.

## Design decisions

| Decision | Choice | Reasoning |
|---|---|---|
| Role of the app | probe, not viewer | the dashboards are already responsive; a viewer adds nothing |
| Where scoring happens | server side | one implementation of thresholds and attribution; no drift |
| Language | Swift and SwiftUI | every measurement is a platform API |
| Video method | port the simulated player, not `AVPlayer` | `AVPlayer` would be a different measurement, not a better one |
| Record identity | `probe_id` carries the device; `context` stays null | the phone cannot fill RSSI, channel or CPU temperature |
