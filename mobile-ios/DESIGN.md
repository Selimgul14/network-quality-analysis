# Design

How the requirements in `REQUIREMENTS.md` are met. Written before any
code.

## 1. The claim this design exists to support

A phone and a Raspberry Pi are different instruments. If the phone
computed its own verdict, any disagreement between them would be
untraceable: a difference in the network, a difference in the thresholds,
or a difference in two implementations of the same idea, with no way to
tell which.

So the phone computes no verdict. It produces records in the project's
existing contract, posts them to the existing ingest endpoint, and asks
the existing backend what they mean. `cloud/app/summary.py` scores a
phone exactly as it scores the Pi, because it never learns which one it
is looking at.

That is the whole design in one paragraph, and everything below serves
it.

## 2. Component map

Deliberately a one-to-one mirror of `src/probe/`. The symmetry is the
point: it shows that what makes something a probe in this system is the
contract, not the language or the hardware.

| iOS component | Mirrors | Responsibility |
|---|---|---|
| `Workloads/WebWorkload.swift` | `probe/workloads/web.py` | one measurement, returns metrics or throws |
| `Workloads/VideoWorkload.swift` | `workloads/video.py` | as above |
| `Workloads/DownloadWorkload.swift` | `workloads/download.py` | as above |
| `Workloads/LoadLatWorkload.swift` | `workloads/loadlat.py` | as above |
| `Workloads/BaselineWorkload.swift` | `workloads/baseline.py` | as above |
| `Workloads/PathWorkload.swift` | `workloads/path.py` | hop 1 only (M10) |
| `Net/ICMPPinger.swift` | the `ping` subprocess | ICMP echo over a datagram socket |
| `Net/RouteTable.swift` | `ip route show default` | default gateway discovery |
| `Net/TCPProbe.swift` | `baseline._tcp_ping` | handshake RTT |
| `Endpoints.swift` | `probe/endpoints.py` | cloud and real targets per workload |
| `Record.swift` | the contract | the record type and its encoding |
| `ContractValidator.swift` | `tests/test_contract.py` | refuse to post an invalid record |
| `RunCoordinator.swift` | `probe/scheduler.py` | builds records, sequences the run |
| `Uploader.swift` | `probe/uploader.py` | POST /ingest, retry, order preserved |
| `PendingStore.swift` | `probe/buffer.py` | unsent records, in memory (M9) |
| `NetID.swift` | `probe/netid.py` | truncated hash of the public IP |
| `SummaryClient.swift` | the dashboard's `fetch` | GET /summary, decode the verdict |
| `ContentView.swift` | `dashboard/summary/overview.html` | the one screen |

Every workload conforms to one protocol, mirroring the Python modules'
shared `run(target) -> dict` shape:

```swift
protocol Workload {
    static var name: String { get }          // contract workload value
    func run(target: URL) async throws -> [String: MetricValue]
}
```

Throwing is how a workload reports failure, and `RunCoordinator` turns a
thrown error into an `ok: false` record. That is M8, and it is the same
control flow as `scheduler._record`'s try/except.

## 3. The record

`MetricValue` exists because the contract allows `number` or `string` in
`metrics` (the Pi uses strings for `quality_tier` and the hop identity
labels):

```swift
enum MetricValue: Encodable { case number(Double); case string(String) }
```

Top-level fields map to the contract with explicit `CodingKeys`, so the
snake_case mapping is visible in one place and can be unit tested rather
than relied upon. `context` and `raw_ref` are always null (N8, and the
phone ships no raw payloads). `net_hash` is filled as the Pi fills it.

`ts` is ISO 8601 with a timezone, produced by `ISO8601DateFormatter` with
`.withInternetDateTime` and fractional seconds.

**Nothing is posted before it validates.** `ContractValidator` checks the
eight required keys are present, that `workload` and `endpoint` hold
values from the contract's enums, that every `metrics` value is a number
or a string, and that no unexpected top-level key crept in. A validation
failure is a bug in the app, so it surfaces loudly rather than being
dropped quietly. This is M3, and it means a 422 from the backend should
be impossible rather than merely unlikely.

## 4. Endpoints

`Endpoints.targets(for:)` mirrors `probe/endpoints.py` including its
`REF_PATHS` map, and returns cloud and real only. The `local` family is
absent for application workloads, exactly as it is on the Pi at halls,
where `PROBE_LOCAL_BASE` is empty.

Baseline is different, and follows `scheduler._baseline_targets` exactly:

| Target | endpoint | method |
|---|---|---|
| default gateway | `local` | ICMP |
| `comp702-ref.azurewebsites.net` | `cloud` | TCP handshake, App Service drops ICMP |
| `1.1.1.1`, `8.8.8.8` | `real` | ICMP |
| `www.google.com` | `real` | ICMP |

Matching the Pi's endpoint assignment here is not cosmetic. It is what
lets a phone record and a Pi record be compared without a caveat.

## 5. The workloads

Constants are copied from the Python, not re-chosen. Where a number
differs the measurements stop being comparable, which would defeat the
exercise.

### 5.1 Web

Fresh `WKWebView` per run with `WKWebsiteDataStore.nonPersistent()`, so
the cache is cold on every load the way a freshly launched Chromium's is.
Load the target, wait for `webView(_:didFinish:)`, then evaluate the
identical JavaScript the Pi uses:

```js
JSON.stringify(performance.getEntriesByType('navigation')[0].toJSON())
```

and do the identical arithmetic: `dns_ms` from `domainLookupEnd -
domainLookupStart`, `connect_ms`, `ttfb_ms`, and `load_ms` from
`loadEventEnd - startTime`. 60 second timeout, matching Playwright's.

One platform detail that will otherwise waste an afternoon: a `WKWebView`
outside the view hierarchy can be throttled or suspended by the system.
It is mounted at 1x1 point with near-zero alpha rather than kept
offscreen.

### 5.2 Download

`URLSession` with an **ephemeral** configuration and
`.reloadIgnoringLocalAndRemoteCacheData`. Without both, the second run of
the day reads from cache and reports a throughput figure that describes
flash storage rather than a network. Bytes counted through
`URLSessionDataDelegate`, elapsed measured across the whole transfer,
yielding `throughput_mbps` and `bytes`.

### 5.3 Video

The Pi does not use a real player, and neither does this. It reads the
media's duration and bitrate, then simulates playback over the byte
stream: playback begins once `STARTUP_BUFFER_S` (2.0) seconds of media
are buffered, the buffer drains at 1x wall clock, and any moment it runs
dry is a rebuffer event. `MAX_WATCH_S` is 30.0.

`AVURLAsset` replaces `ffprobe`: `load(.duration)` and the video track's
`estimatedDataRate`, falling back to 2 Mbps exactly as `video.py` does
when the bitrate is unreadable. No `AVPlayer`, no audio session, no
playback.

The simulation loop is a direct port, producing `startup_ms`,
`rebuffer_count`, `rebuffer_ms`, `stream_mbps`, `bitrate_mbps`,
`headroom_x`, and `quality_tier` from the same
`((25, "4K"), (8, "1080p"), (5, "720p"), (3, "480p"))` table.

The browser User-Agent header is sent, for the same reason the Pi sends
it: some CDNs return 403 to non-browser clients.

### 5.4 Bufferbloat

A direct port of `loadlat.py` with its constants unchanged: five idle
handshake RTT samples to 1.1.1.1:443 at 0.2 s spacing, then a saturating
download, one second of TCP ramp-up, then RTT sampled every 0.4 s for
8.0 s. Reports `idle_rtt_ms`, `loaded_rtt_ms`, `bloat_ms`,
`loaded_rtt_max_ms`, `load_mbps`.

Handshake RTT comes from `NWConnection` with `NWParameters.tcp`, timed
from `start()` to the `.ready` state. TCP rather than ICMP for the same
reason the Pi gives: it survives networks that block ping.

### 5.5 Baseline

DNS timing from `getaddrinfo`, mirroring `_dns_ms`. Then ten echoes at
0.2 s spacing, matching `ping_count` and `ping_interval_s`, so loss
quantises identically to the Pi's (the reason those values are what they
are is written up in `meetings/2026-08-problems-and-fixes.md`).

`rtt_ms` is the mean, `loss_pct` is unanswered over sent, and `jitter_ms`
is the population standard deviation. That last choice matters for
comparability: `ping`'s `mdev`, which the Pi parses, is the population
standard deviation, and `_tcp_ping` already uses `pstdev`. Both Pi paths
agree, and this matches both.

ICMP uses a `SOCK_DGRAM`, `IPPROTO_ICMP` socket, which on Darwin needs
neither root nor an entitlement. Two details that are easy to get wrong:
the kernel rewrites the identifier field on a datagram ICMP socket, so
replies are matched on sequence number; and unlike a raw socket the
received buffer starts at the ICMP header, with no IP header to skip.

The cloud reference is probed by TCP handshake instead and reports
`tcp_mode: 1`, exactly as `_tcp_ping` does.

### 5.6 The WiFi link (M10)

The reason this is required rather than optional is traced in M10. In
short: only web, video, email and download set `endpoint_has_data`, so no
baseline record can resolve the `wifi_link` segment. The segment comes
from `_first_hop_rtt`, which reads a `path` record.

Three steps:

**Discover the gateway.** iOS has no API for it. The route table is read
with `sysctl` over `CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS,
RTF_GATEWAY`, and the returned buffer is walked as a sequence of
`rt_msghdr` records, each followed by sockaddrs selected by the
`rtm_addrs` bitmask, every sockaddr advanced by its own `sa_len` rounded
up to a four byte boundary. The wanted entry is the one whose destination
is `0.0.0.0` and whose flags carry `RTF_GATEWAY | RTF_UP`. The gateway
address is cached for 300 seconds, as `baseline.gateway_ip` caches it.

This is the fiddliest code in the app and the likeliest to overrun. It is
also, usefully, the easiest to test: the parser takes a `Data` buffer, so
a captured route dump becomes a fixture and the whole thing is unit
tested with no device and no network.

**Ping it.** The same ICMP path as 5.5, posted as a `baseline` record
with `endpoint: "local"`, matching the Pi's convention.

**Post the path record.** A second record, `workload: "path"`,
`endpoint: "local"`, whose metrics contain exactly one key:
`first_hop_rtt_ms`. Hop 1 is the router reached over the air, which is
what the contract documents the field to mean. `hops` is omitted rather
than set to 1, which would assert something false about the path.

If discovery fails, both records are posted with `ok: false` and the
error (M8). `_first_hop_rtt` ignores records that are not ok, so the
segment correctly falls back to `no_data` rather than being given a
number that was never measured.

**The local network permission trap.** Since iOS 14, sending to a LAN
address requires user consent, prompted on first attempt and gated by
`NSLocalNetworkUsageDescription` in Info.plist. If consent is refused,
packets to the gateway are discarded silently: no error, no reply, and
the app measures 100% loss to a router that is working perfectly.

That is a false attribution of exactly the kind this project exists to
prevent, so it is handled explicitly. If the gateway shows 100% loss
while any off-site target is reachable, the app says the permission is
the likely cause rather than reporting a dead WiFi link. The irony is
worth a sentence in the dissertation: the measurement tool needed the
same distinction internally that it sells to its users.

## 6. Running

One tap, one `run_id` (matching `run_heavy`), workloads sequential,
saturating ones last, with a two second settle between them so one
workload's transfer is not still draining while the next measures.

```
baseline (targets in parallel, as scheduler.run_baseline does)
  -> path / gateway            [M10]
  -> web    (cloud, real)
  -> video  (cloud, real)
  -> download (cloud, real)    [saturating]
  -> loadlat (real)            [saturating, deliberately last]
```

`loadlat` runs last because it needs a quiet link to measure idle RTT
before it loads one, and because it is the most disruptive thing the app
does.

Expected duration is 60 to 90 seconds, which is a long time to hold a
screen. Each row updates as it completes, so the wait shows progress
rather than a spinner.

Records are handed to `PendingStore` as they are produced and uploaded
during the run, so a run interrupted half way has already delivered its
first half.

## 7. Upload

`Uploader` mirrors `uploader.py`: POST to `/ingest` with the bearer
token, 201 is success, a `duplicate` response is also success, and on a
transport failure it stops draining and keeps the remaining records
rather than skipping past them, preserving order.

Retry is exponential backoff at 1, 2, 4, 8 seconds, capped, plus a retry
when the app returns to the foreground. The pending count is on screen
throughout (M9). Records live in memory only; surviving a relaunch is
MS1.

## 8. Reading the verdict back

`GET /summary?site=<the app's site>&hours=1&at=<run completion, ISO 8601>`.

Two notes on that URL. The dashboard endpoints sit behind HTTP Basic
(user `wifi`), not the bearer token, so the app carries two credentials
for two different purposes. And `at` is the time-travel parameter added
on 20 August: anchoring the window on the run's completion guarantees the
run's own records fall inside it rather than depending on wall-clock luck
at the moment the request lands. The phone is the second use case for a
feature built for the outage replay, which is worth a line in Chapter 3.

The response is decoded into only the fields the screen shows, leniently,
so a backend that grows a field does not break the app.

**The thin sample.** A run yields one sample per workload and endpoint,
so every median in the response rests on a single number, and
`summary.py` has no notion of a sample too thin to judge. Changing that
would mean touching the backend (C1), and it would be the wrong fix
anyway. The app already knows exactly how many records it posted, so it
captions the verdict with that count and says a single run is indicative
rather than settled. Disclosure, not cleverness: the same discipline as
the availability fix, which is that a number should say what it rests on.

## 9. The screen

One view, top to bottom: a site field showing `phone-` as a fixed prefix
so the user types only the suffix; a Run button, disabled while a run is
in flight or while the site is empty (M5); a row per workload and
endpoint that fills in as the run proceeds; the verdict card, which is
the health score, the headline sentence, three segment lights and the
per-workload values against their thresholds; the sample-count caption;
and a pending-upload count when anything is unsent.

The verdict card deliberately echoes `overview.html`, so the two can be
put side by side in the dissertation showing the same verdict from the
same backend through two clients.

## 10. Error handling

| Situation | Behaviour |
|---|---|
| A workload throws | `ok: false` record with the error string, run continues (M8) |
| Gateway discovery fails | both M10 records posted `ok: false`; segment reads `no_data`, not a guess |
| Gateway 100% loss, off-site fine | flag the local network permission as the likely cause, do not report a dead link |
| Upload fails | record stays pending, backoff retry, count on screen |
| Summary fetch fails | "measurements posted, verdict unavailable" plus retry; never a fabricated verdict |
| Site field empty | Run disabled; there is no default and no "unlabelled" path (C2) |
| Contract validation fails | loud in-app error; this is an app bug, not a network condition |

## 11. Configuration and secrets

`Secrets.xcconfig`, gitignored (C5), surfaced through Info.plist and read
at runtime: ingest token, dashboard Basic credentials, API host, cloud
reference host, real targets, probe id. `Secrets.xcconfig.example` is
committed with the shape and no values, mirroring `.env.example`.

Three platform details, all of which cost time when discovered late:

- **`//` starts a comment in an xcconfig file**, so a stored `https://…`
  silently truncates to `https:`. Bare hosts are stored and the scheme is
  added in Swift.
- **App Transport Security blocks cleartext HTTP.** The real download
  target is `http://ipv4.download.thinkbroadband.com/50MB.zip`, so an
  `NSExceptionDomains` entry for that host is required or the download
  workload fails on every run for a reason that looks like a network
  fault.
- **`NSLocalNetworkUsageDescription`** is required for section 5.6.

## 12. Testing

Following the project convention that each workload module has a test,
and written alongside the code rather than after it.

Pure and unit tested, no device and no network needed:

| Under test | Why it is the valuable one |
|---|---|
| `RouteTableParser.defaultGateway(from: Data)` | the riskiest code in the app, made testable by taking a buffer; a captured route dump is the fixture |
| `VideoSimulator` | synthetic chunk and timestamp pairs assert startup, rebuffer count and rebuffer duration, mirroring the Pi's logic exactly |
| `PingStats.summarise` | mean, population stdev and loss from a fixed RTT array, including the all-lost case |
| `NavigationTiming.metrics(from:)` | a captured timing dictionary maps to the same four numbers `web.py` produces |
| `Record` encoding and `ContractValidator` | the encoded JSON has exactly the contract's keys; invalid records are rejected |
| `Endpoints.targets(for:)` | cloud and real present, local absent, correct reference paths |

The network-touching code stays a thin wrapper around these, so what
cannot be unit tested is small enough to verify by hand. Integration is a
real run against the live endpoints, logged in `RUNS.md` per C3.

## 13. Project setup

Xcode project, SwiftUI lifecycle, iOS 17 deployment target, Swift
concurrency throughout. No third-party packages (N10): Foundation,
Network, WebKit, AVFoundation, CryptoKit, SwiftUI. Free Apple ID
sideloading, so the build expires weekly (C7).

## 14. What this gives the dissertation

- **Chapter 2**: the two-tier probe architecture, and the observation
  that a second probe class dropped in without a single schema change,
  which is a claim about the contract rather than about the app.
- **Chapter 3**: the parity table, the platform limits, and the local
  network permission trap as a problem encountered. The `?at=` reuse.
- **Chapter 4**: a phone verdict and a Pi verdict side by side, from one
  scoring implementation.
- **Chapter 6**: distribution, per-device credentials in place of a
  shared token, and the ethics re-approval any of it would need.
- **CA2 Q&A**: a live answer to "how does this scale past one Pi".

## 15. Risks, and what gets cut first

Ordered. C6 caps the whole thing at three days, and the dissertation
outranks every line of it.

| Risk | Response |
|---|---|
| Route table parsing overruns | Hard half-day cap. Past it, M10 is cut and "WiFi link: not measured" is reported with the reason written up. |
| Local network permission denied or flaky | Detected and reported per section 5.6; does not block the other five workloads. |
| `estimatedDataRate` unavailable for the media | Same 2 Mbps fallback as `video.py`. |
| `WKWebView` throttled and timing out | Mount in the hierarchy per 5.1; failing that, the web workload is cut before anything else. |
| ATS or xcconfig surprises | Anticipated in section 11; if a target cannot be reached, it posts `ok: false` rather than blocking the run. |
| The app eats the dissertation | Stop. The design, the parity table and the ethics analysis are worth writing whether or not the code runs. |

**Never cut**, because they are the claims rather than the features:
contract validity (M3), data separation (M5, C2), and the verdict coming
from the server (M6).

## 16. Rough shape of the three days

| Day | Work |
|---|---|
| 1 | Project skeleton, config, `Record` and validator with tests, `Endpoints`, `Uploader`, download and TCP baseline. Ends with a real record accepted by the live `/ingest`. |
| 2 | Web, the video simulation, bufferbloat, then route table discovery, ICMP and the M10 records. |
| 3 | `SummaryClient`, the screen, error handling, an on-device run, the airplane-mode test, `RUNS.md`, and screenshots for the dissertation. |

## 17. As built, 21 August 2026

The logic layer is complete and tested; the app target is not started.
Where the code departed from the design above, it is recorded here rather
than by editing the design, so the reasoning stays visible.

### Structural change: a package plus a thin app

Section 13 assumed a single Xcode project. In practice everything
measurable went into a SwiftPM package, `WiFiProbeKit`, with the app
reduced to a SwiftUI shell over it. The reason is testability: a package
builds and tests from the command line on macOS, so all 77 tests run
without driving a simulator. The component map in section 2 is otherwise
unchanged, file for file.

### Deviations, and why

| Change | Reason |
|---|---|
| `VideoSimulator` gained an `endedAt` parameter | The first port took the transfer's end as the last chunk's arrival, so a stall still in progress when the media ran out contributed zero. `video.py` measures elapsed after its loop returns and does count it. Found by writing the test, not by reading the code. |
| The uploader treats 401, 403 and 422 as permanent | `uploader.py` breaks on any HTTP error and retries forever. Right for a 503; wrong for a 422, which means the record broke the contract and no amount of retrying will fix it. Rejections are set aside and counted so they surface as the app bug they are. |
| The M10 path record reuses the gateway RTT from the baseline pass | Section 5.6 described discovering, pinging, then posting. Pinging the router twice in one run would double the load for no extra information, so the `path` record takes the RTT the baseline leg already measured. |
| `baselineRunner` and the web view's host are injectable | Both reach the network or the view hierarchy. Injecting them lets the whole run sequence be tested with no network at all, which is what makes the 12 coordinator tests possible. |
| The gateway falls back from ICMP to TCP | Section 5.6 assumed the router would answer echo requests, and it does: a campus router answers ICMP echo and always did (address confirmed correct, permission granted). What looked like a silent router was a client-side bug: a `SOCK_DGRAM` ICMP socket on Darwin returns the IPv4 header ahead of the ICMP one, and `ICMPPinger.parseReply` was reading the type byte at offset 0 instead of skipping it, so it manufactured 100% loss on every real reply (fixed in Task 1). Rungs 2 and 3 are kept regardless, since a router that answers nothing at all is a real case: confirmed 24 August 2026 on a different network (10.224.7.x), where echo, a TTL=1 probe, and all four candidate TCP ports returned nothing. A TCP **refusal** is still a round trip, since an RST comes from the host's own stack, so the port does not need to be open: the router only has to answer something. |
| A refusal is trusted only from an on-link address | Found while testing the above, and it is the more important half. Connecting to 192.0.2.1 (TEST-NET-1, reserved and unrouted) returned `ECONNREFUSED` in 4.8 ms: the local stack refused it and nothing left the device. Without the guard that would have been recorded as a round trip to a host that does not exist. A gateway is on-link by definition, so `LocalSubnet` checks the target shares a subnet with one of our own interfaces before a refusal counts. |
| The app names the measurement method and asserts no cause | The first version told the user their local network permission was off. Two causes are indistinguishable from the phone (refused permission, and a router that ignores everything by design), so it now reports which method worked, or that none did, and lists both possibilities without picking one. |
| `liveRunner` switches exhaustively over `Workload` | Not a design change, a deliberate echo of the bug in `scheduler._record`, where a `default` fallback silently ran the baseline module for `path`, so `mtr` never executed on any network. A missing case here is a compile error. |

### What the tests actually cover

77 tests, 2 skipped. The valuable ones are the ones the design predicted
would be: `RouteTable` parses a real 12,884-byte route dump captured from
a Mac and returns the gateway `netstat` agrees with, with truncation and
garbage cases that would otherwise loop or read past the end; the video
simulator is driven by synthetic chunk timings; and the coordinator is
tested with every network call stubbed, asserting the full eleven-pair
workload and endpoint matrix, one shared `run_id`, and that every record
validates against the contract before it can be posted.

The two skips are the live ICMP tests. Development happened on a network
that filters ICMP for the system `ping` as much as for this code, so no
real echo reply has ever been parsed. The checksum test is the meaningful
stand-in, since it verifies to zero exactly as a receiver checks, but M10
stays unproven until it runs on a phone.

### Remaining

The Xcode app target: `Info.plist` with
`NSLocalNetworkUsageDescription` and the ATS exception for the cleartext
download target, the `Secrets.xcconfig` wiring, and the single screen of
section 9. Then the first record into the live database, and the
definition of done in `REQUIREMENTS.md`.
