# Next session: closing out the app

Two tasks remain before the iOS work is done. Both need the phone in
hand, which is why they are parked rather than finished. Everything else
is built, tested and committed.

State at the pause (24 August 2026): 141 tests passing (1 skipped), the
app builds and runs on a real iPhone, records reach the live backend, and
the verdict comes back from the server. The app is now three tabs (Now,
History, Trends) plus Settings, with runs kept on the device across
launches, and the pending-upload queue survives the app being killed
(MS1). The app redesign branch is merged into `main`.

---

## 1. The interruption test (definition of done, item 6)

The one behaviour the 18 August outage taught this project to care about,
and currently proven only against a stub. It is worth doing properly
because it is the phone-side version of the bug that made the health
score read "excellent" during a real outage.

**Steps**

1. Run with a label like `interrupt`.
2. Wait about 20 seconds, until `web` or `video` has ticked over.
3. Turn airplane mode **on**, and leave it on through the rest of the
   workload sequence. Do not restore it yet. `RunCoordinator` calls
   `uploader.drain(store)` after the baseline and gateway group, and
   again after every application workload, so a mid-run outage that is
   lifted before the sequence ends can drain itself before anyone looks
   and the queue may already be empty by the time the screen is checked.
   Restoring early hides the exact thing this test exists to show.
4. Turn airplane mode **off** as soon as every row in "What it is doing"
   shows a checkmark or a red X, with none still spinning, that is, the
   moment the workload sequence itself finishes. Do not wait for the
   headline below the dial to say "Reading the verdict": by the time
   that text appears, `RunViewModel.run()` has already made its one
   extra attempt to flush anything still queued ("anything still queued
   is retried before the verdict is read"), and nothing retries it again
   automatically after that, so restoring only once you see that text is
   one retry too late, and the count will sit stuck non-zero instead of
   clearing. Restoring as soon as the steps finish gives WiFi a couple of
   seconds to reassociate before that retry and before the verdict fetch
   both need it. Restore too late in the other direction and you
   reproduce the failure this step used to warn about, before this
   rewrite: the verdict fetch itself goes out while still offline, throws,
   the verdict stays unread, and the headline falls back to "Measured"
   with the interesting part hidden behind a connection error.

**What should happen**

| Expected | What it proves |
|---|---|
| Some rows go red with an error beneath them | M8: failed runs became records rather than being skipped |
| "Waiting to upload" appears on the Now screen while offline, stays non-zero, then clears once connectivity returns | M9: nothing was dropped while the network was gone, and the count is watched live rather than sampled once (R6, Task 11) |
| The verdict reports **under 100% of tasks completed** | Availability seeing a phone outage the way it now sees the Pi's |

**A healthy score with no availability warning despite red rows is a
bug**, and the same class as the one the outage replay exposed on the
server. Report it rather than working around it.

As a second pass, kill the app outright (swipe it away, not just
background it) while "Waiting to upload" is non-zero, then relaunch with
airplane mode still on. "Waiting to upload" should appear on the Now
screen as soon as it opens, without starting a new run: relaunch also
tries a drain on its own, so with airplane mode still on the count
should hold rather than clear. Then restore connectivity and confirm it
drains from there. MS1 means the queue survives the kill; if the count
does not appear at launch or does not drain once connectivity is back,
the persistent buffer is not doing what it claims.

## 2. Screenshots for Chapter 4

After a clean run, capture on the phone:

- the Now screen showing its verdict,
- `RunDetailView` for that run (History tab), and
- Safari at `/overview?site=phone-<label>&hours=1`.

Same score, same headline, same three lights, from one scoring
implementation through two unrelated clients, plus the on-device detail
view that backs it up. That set of images carries the whole two-tier
argument, and it is far easier to take while the app is fresh on the
device than to recreate later.

---

## Open questions

- **`phone-smoke-test`**: one row written from the dev Mac on 21 August to
  prove the backend accepts this client's JSON (see `RUNS.md`). Delete it
  or leave it? There is no delete endpoint, so removing it means SQL
  against Postgres. Still unresolved.

## Not in scope, and deliberately

MS3 background runs, MS4 SSID labelling, the fixed-probe overlay on the
Trends chart (designed, deferred inside Task 10 because it is the only
part of the tab that needs signal and credentials). None of these earn a
mark. C6's cap is now a stopping condition rather than a day count: the
app is finished when the three tabs work and the WiFi link is measured,
and both hold. After the two tasks above, attention goes to **fault
injection (build step 7)**, which is the last piece of project work
blocking Chapter 4.

## Also still open, outside this folder

- **`.env.local` is committed** to the `src` repo and holds
  `PROBE_INGEST_TOKEN` and `API_INGEST_TOKEN`. They are the localhost dev
  values, not the live ones (`.env` holds those and is correctly
  ignored), so the exposure is limited, but it ships inside the CA3 code
  ZIP. Worth cleaning up.
- **No probe self-monitoring.** The gap that let the 17-18 August SD-card
  failure run unnoticed for 24 hours.
