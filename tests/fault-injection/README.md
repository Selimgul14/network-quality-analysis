# Fault injection (build step 7)

Break the network in a known way, and check the tool blames the segment
that was actually broken. This is what validates the project's central
claim: that comparing the same task across three endpoints locates a
fault rather than merely reporting a number.

The expectations in `analyse.py` were written **before** any scenario was
run. That ordering is the point. A tool graded against expectations
invented afterwards proves nothing.

## Why this still matters after the real outage

The uplink failure of 18 August (23:23 to 00:03 UTC) already demonstrated
attribution on an unplanned fault, and that is stronger evidence than
anything staged. But it was one fault of one kind: a total, binary loss
of the uplink. Fault injection covers what nature did not supply:

- a link that is **degraded rather than dead** (delay, loss, a throughput
  cap), which is the harder case,
- a fault confined to **one segment while the others stay healthy**,
  which is what the three-way comparison exists to separate,
- **repeatability**, so a marker can see the same result twice.

Scenario 07 deliberately reproduces the real outage, which turns the
18 August diagnosis from an anecdote into something demonstrable on
demand.

## Before you start

On the Pi:

```
sudo modprobe sch_netem && echo netem ok      # kernel module present
tc -V                                          # iproute2 installed
ip route show default                          # gateway discoverable
```

**Console access.** Scenario 07 drops every packet that is not headed for
the gateway, which includes SSH from outside the subnet. Run the matrix
at the Pi's console (HDMI and keyboard), or over the laptop hotspot where
your Mac is on the same subnet. Every scenario also arms a watchdog that
clears the impairment after 25 minutes, so nothing can be left broken.

**Data hygiene.** Each scenario relabels the probe with
`PROBE_SITE=faultinj-NN`, so its records land under their own site and the
production `true student` dataset stays clean. `clear` restores the empty
label, at which point the probe self-labels by SSID again.

## The run

Roughly two hours end to end. Work through it in order.

```
cd /opt/probe/tests/fault-injection

sudo ./inject.sh fast          # heavy workloads every 60 s for the test window
```

Then for each scenario `NN` in 01 through 08:

```
sudo ./inject.sh run NN        # apply, relabel, restart the probe
# wait 15 minutes
sudo ./inject.sh clear         # remove impairment, restore the label
```

Fifteen minutes at the fast cadence gives 12 to 15 heavy runs, which is
enough for a stable median. Wait two minutes after `clear` before
starting the next scenario, so the probe settles.

When the matrix is finished:

```
sudo ./inject.sh normal        # production cadence back
sudo ./inject.sh status        # confirm nothing is left applied
```

Then from any machine:

```
python3 analyse.py --password <dashboard-password> --markdown
```

## What each scenario tests

| # | Injected | Expected verdict | What it proves |
|---|---|---|---|
| 01 | nothing | `good`, no cause | The tool does not invent faults. Without this the others prove nothing |
| 02 | +80 ms on all egress | `wifi_link` | Delay on the local leg is attributed locally; hop 1 RTT should rise by about the injected amount |
| 03 | 5% loss on all egress | `wifi_link` | Loss at the gateway is the signature of a bad link |
| 04 | inbound capped at 5 Mbit | `wifi_link` | Throughput collapsing on every endpoint at once is local, not remote |
| 05 | +150 ms to everything **except** the gateway | `internet_path`, WiFi link stays `ok` | **The key test.** The gateway answers fast while the world slows, so the link must be exonerated. This is the case a single-endpoint tool cannot distinguish |
| 06 | +400 ms to the real services only | `third_party`, cloud stays `ok` | The controlled cloud reference is untouched, so only the third party can be at fault |
| 07 | all off-site traffic dropped | `down`, "Your WiFi is fine, but the internet connection is down" | Reproduces the real outage on demand |
| 08 | 20 Mbit inbound with a 500 ms queue | `bloat_ms` rises sharply | Bufferbloat is visible even though idle latency is unchanged, which is exactly why idle latency alone misleads |

## What to capture while you are there

Screenshots are much easier to take now than to recreate later.

- Scenario 05 and 07: the `/overview` page mid-scenario. These two carry
  the attribution argument visually.
- Scenario 02: the path panel, showing hop 1 inflated while later hops
  are unchanged.
- Scenario 08: the bufferbloat readout, idle versus loaded.
- Scenario 07: the `Waiting to upload` behaviour. The probe cannot reach
  Azure during it, so records queue in the SQLite buffer and drain
  afterwards. That is requirement R6 demonstrated, and it is worth a
  sentence in the evaluation chapter.

## Reading the results

`analyse.py` prints one row per scenario: what was injected, what the
tool said, and pass or fail. `--markdown` emits the table ready for the
dissertation.

**A failure is a result, not a disaster.** If scenario 06 cannot be
attributed cleanly because BBC News resolves to a CDN with rotating
addresses, that is a genuine limitation of destination-based attribution
and belongs in the write-up. Report it rather than tuning the test until
it passes.

## If something goes wrong

```
sudo ./inject.sh clear         # removes every qdisc and the ifb device
sudo tc qdisc del dev wlan0 root      # by hand, if the script itself fails
sudo tc qdisc del dev wlan0 ingress
sudo ip link del ifb0
```

Impairment lives only in the kernel's traffic-control layer. A reboot
clears everything, and nothing is written to the network configuration.
The only persistent changes are in `/opt/probe/.env` (the site label and
the cadences), which `clear` and `normal` restore.
