# Design: app redesign, and the WiFi-link fix

24 August 2026. Supersedes the UI half of `DESIGN.md`; the contract,
uploader and workload halves of that document still stand.

## Why

Two problems with the app as built.

1. **The WiFi link is never measured.** The app reports "your router did
   not answer" on every network tried so far. This was attributed to the
   campus router ignoring ICMP. That attribution is wrong, see below.
2. **The interface is a debugging tool.** It shows rows reading
   `baseline · local` and `loadlat · cloud`, raw error strings, and a
   method label naming a transport protocol. It is legible to whoever
   wrote it and to nobody else, which is a problem for an app whose
   entire premise is that an ordinary person can point it at a network
   and be told what is wrong.

The fix for the second is not to delete the detail. It is to move it one
tap away, and to give the app somewhere to keep results so a single
reading becomes a record.

## The finding: ICMP replies were being parsed at the wrong offset

`ICMPPinger` reads the ICMP type from byte 0 of the received buffer and
the sequence number from bytes 6 and 7. That is correct on Linux, where a
`SOCK_DGRAM` ICMP socket delivers the ICMP header alone. **Darwin
includes the IP header.** Byte 0 is therefore `0x45`, the version and
IHL nibble of an IPv4 header, never `0`, so the `type == echoReply` guard
rejects every reply and the pinger reports 100% loss against any host.

Verified on the halls network, 24 August 2026, from the development Mac:

| Test | Result |
|---|---|
| `ping -c 3 10.93.0.1` | 3 received, 0.0% loss, avg 5.18 ms |
| `SOCK_DGRAM` ICMP echo to the gateway | 84 bytes returned, `data[0] = 69` |
| Same reply, skipping IHL | `type = 0`, `seq` matches what was sent |
| TTL=1 echo to 1.1.1.1 | ICMP time exceeded from `10.93.0.1` in 3.08 ms |

So the router answers echo, has always answered echo, and the loss was
manufactured by the client. Two records in the project are wrong and must
be corrected rather than quietly edited away:

- The comment at the head of `GatewayProbe.swift` stating that the campus
  gateway "ignores ICMP echo entirely, which is consistent with the
  client isolation already documented for that site". It does not.
- The justification for skipping the live ICMP tests, that "ICMP is
  filtered in this environment". On 24 August the system `ping` reaches
  the gateway with 0% loss from the same machine on the same network, so
  whatever produced the earlier reading, the conclusion drawn from it
  does not hold and the tests should not have been skipped on that
  basis.

This is worth a paragraph in the evaluation chapter. A plausible network
explanation was available, it fitted the site's known behaviour, and it
concealed a client-side bug for three days. It is the same shape as the
constant 20% packet loss that turned out to be a ping deadline, and the
loss panel that turned out to be a quantisation artifact.

## Goals

- The WiFi link is measured on any network whose router answers anything.
- A person who has not read the dissertation can use the app.
- Runs persist on the device and accumulate into something worth looking
  at.
- Every number the app used to show is still reachable, one tap in.
- No third-party dependencies (N10 holds).

## Non-goals

Background or scheduled runs, App Store distribution, automatic SSID
labelling, notifications, multi-user accounts, iPad layout, live
activities. Ethics category (Data B, Participant 0) does not change:
still a single user, still no distribution.

## Architecture

The split stays as it is. `WiFiProbeKit` holds everything testable from
the command line with no simulator: contract, networking, workloads,
storage, aggregation. The app target holds SwiftUI only. Charts use
Swift Charts, a system framework, so N10 is not breached.

New in the kit:

```
WiFiProbeKit/
├── Net/ICMPPinger.swift        ← IHL-aware parse, TTL support, type 11
├── Net/GatewayProbe.swift      ← three-rung ladder, reports which rung
├── Store/RunStore.swift        ← persisted runs, actor
├── Store/StoredRun.swift       ← what a finished run looks like on disk
├── Store/PendingStore.swift    ← moves from memory onto the same store
└── Trends.swift                ← per-site aggregation, median, ranking
```

New in the app:

```
WiFiProbe/
├── RootView.swift              ← TabView shell
├── Now/NowView.swift           ← dial, verdict, lights
├── Now/ScoreDial.swift
├── Now/SitePicker.swift        ← known labels plus "new network"
├── History/HistoryView.swift   ← list, grouped by day, filter chips
├── History/RunDetailView.swift ← today's screen, in full
├── Trends/TrendsView.swift     ← ranked networks
├── Trends/SiteTrendView.swift  ← one network's chart
└── SettingsView.swift
```

### WiFi link: a three-rung ladder

`GatewayProbe.measure` tries, in order, and stops at the first that
answers:

1. **ICMP echo to the gateway.** The normal case, working once the parse
   is fixed. Reported as `ping`.
2. **TTL-limited echo to an off-net address.** The datagram goes out with
   `IP_TTL = 1`; the router decrements it to zero and is obliged by
   RFC 1812 to return ICMP time exceeded, whose source address is the
   router and whose round trip is the WiFi link. This catches routers
   that drop packets addressed to themselves but still route. It is also
   the method `mtr` uses for hop 1 on the Pi, so both probes end up
   measuring the WiFi link the same way, which removes a difference in
   method from the phone-versus-Pi comparison. Reported as
   `first hop, TTL`.
3. **TCP connect or refusal on an on-link address.** Unchanged, including
   the `LocalSubnet` guard that stops a locally generated refusal being
   counted as a round trip. Reported as `TCP`.

`ICMPPinger` gains: an IHL-aware offset, an optional TTL, and acceptance
of type 11 (time exceeded) matched by the sequence number echoed back
inside the quoted original datagram. Sequence matching still stands in
for identifier matching, since the kernel rewrites the identifier on
datagram sockets.

`GatewayCache` is flushed at the start of each run. A five-minute TTL on
a value that changes the moment the phone joins a different network is a
bug waiting for a demo.

When all three rungs fail, the app says which of the three was tried and
what each returned, rather than one paragraph offering two possible
causes. That paragraph exists because the app could not tell the
difference; the ladder mostly removes the ambiguity, and where it
remains, showing the evidence beats guessing.

### Storage

`StoredRun` is one finished run: identity (`run_id`, site, started,
finished), the verdict snapshot as it was displayed (score, quality,
availability, label, headline, three segment states), the headline
numbers (WiFi link RTT and how it was obtained, download Mbps, idle and
loaded RTT, video startup, page load), and every step with its endpoint,
target, outcome and error text.

The verdict is snapshotted rather than refetched. A run reopened in
December must show what it showed in August, and `?at=` on the backend is
not a substitute because the local record is the point.

Storage is one JSON file per run in Application Support plus a small
index file, read and written through an actor. No SQLite and no
SwiftData: a few hundred small records do not need either, and a plain
file store is testable against a temporary directory with no simulator.

`PendingStore` moves onto the same on-disk mechanism. Records queued for
upload then survive the app being killed, which is stretch item MS1
arriving as a consequence rather than as a feature, and it makes the
interruption test meaningful rather than a check of in-memory state.

### Aggregation

`Trends` computes, per site: run count, median score, median download,
median WiFi-link RTT, first and last run, and the segment most often
non-`ok`. Medians rather than means for the same reason the backend uses
them, which is that one failed run should not swing a summary. Pure
functions over `[StoredRun]`, so they are unit-tested directly.

## The three tabs

### Now

**Idle.** The network label at the top as a picker over labels already
used, plus "new network". One button. Under it, if there is a previous
run for this label, a single quiet line: "Last tested 2 hours ago, scored
91".

Replacing the free-text field with a picker is what stops the next
`phone-smoke-test`, and it matters more now that History and Trends are
keyed on the label.

**Running.** The dial becomes a determinate progress ring. Beneath it,
one line of plain text for the current stage ("Checking video", "Testing
download speed"), not eleven rows of `workload · endpoint`. A disclosure
opens the rows for anyone who wants them.

**Done.** Dial with score and band, the headline sentence, three
segment lights with their one-word states, and one link: "See the
numbers". Availability under 100% shows as a warning line, as now. If the
WiFi link could not be measured, that says so here with the ladder's
evidence.

### History

Newest first, grouped by day, with filter chips for each network. Each
row: coloured score badge, network, time, and one distinguishing number
or the failure ("internet down"). Tapping opens `RunDetailView`.

`RunDetailView` is today's `ContentView` content in full: every step with
endpoint, target, metrics and error string, the gateway method, the
upload state, the run id, and the site fingerprint. Nothing is dropped.
This is the screenshot for Chapter 4, and it is what makes simplifying
the Now tab safe rather than lossy.

### Trends

A ranked list of networks by median score, each a labelled bar with its
run count, worst first or best first (best first, so the list reads as a
recommendation). Under it, one sentence about the weakest network naming
the segment most often at fault, built from the aggregation, for example
"home is your weakest network. Its WiFi link is fine at 4.1 ms; the
internet path is what drags it down."

Tapping a network opens its chart: score, download or latency across that
network's runs, selectable. Where the backend has a fixed probe at the
same site, that probe's line is drawn behind the points. The phone's site
label is the Pi's with a `phone-` prefix, so the candidate site name is
recovered by stripping it and checking `/sites`. When there is no match,
the line is simply absent and the chart is still a chart.

## Error handling

Failures stay records, as now: a failed workload is uploaded with
`ok: false` and its error, because the backend's availability figure
counts attempts, and skipping a failure is how a phone would score itself
healthy during an outage.

On screen, an error appears three ways depending on distance from the
user: the Now tab shows a consequence ("video could not be tested"),
`RunDetailView` shows the error string, and the upload queue shows a
count with a retry. Raw error text never appears on the Now tab.

## Testing

New unit tests in the kit:

- ICMP parse against a captured 84-byte reply as a fixture, including a
  header with options so the IHL is not assumed to be 20.
- Type 11 matched to the sequence quoted in the original datagram.
- Ladder order: rung 2 is tried only when rung 1 is silent, rung 3 only
  when both are.
- `RunStore` round trip, ordering, filtering, and survival of a corrupt
  index file.
- `PendingStore` durability across a restart, simulated by making a new
  store over the same directory.
- `Trends` medians, ranking, and the most-common-fault selection,
  including ties and single-run sites.

The live ICMP tests currently skipped are unskipped, since the premise
for skipping them was false.

The existing 89 tests stay green. The UI is kept thin enough that it
needs no tests; anything worth testing belongs in the kit.

## Constraint changes

`CONSTRAINTS.md` C6 currently caps this work at three working days. That
cap is lifted at the user's explicit instruction, 23 August 2026. It is
replaced by a stopping condition rather than a number:

> The app is finished when the three tabs work and the WiFi link is
> measured. Nothing beyond that is built before the dissertation is
> written. The dissertation still outranks this work, and CA3 is due
> 11 September 2026.

C1 is unchanged: work stays inside `src/mobile-ios`, except for
documentation updates to `CLAUDE.md` and `dissertation/plan.md`, which
were already authorised.

## Risks

- **The deadline.** CA3 is 11 September and Chapter 4 is empty. The
  sequencing chosen is app, then fault injection, then writing. That
  puts two build tasks in front of a 50-page document, so writing has to
  proceed in parallel rather than after. This is recorded here so it is
  a decision rather than an accident.
- **TTL time-exceeded on iOS.** Confirmed working on macOS. Darwin
  shares a kernel, so it is expected to behave the same on the phone, but
  it is unproven there until it runs. Rung 1 is expected to carry almost
  every case anyway, and rung 3 already works.
- **Swift Charts** raises no dependency question but does raise a
  deployment-target one; it needs iOS 16, and the app targets iOS 17.
