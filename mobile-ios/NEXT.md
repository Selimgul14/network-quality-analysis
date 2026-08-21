# Next session: closing out the app

Two tasks remain before the iOS work is done. Both need the phone in
hand, which is why they are parked rather than finished. Everything else
is built, tested and committed.

State at the pause (21 August 2026): 89 tests passing, the app builds and
runs on a real iPhone, records reach the live backend, and the verdict
comes back from the server. Work sits on branch `mobile-ios-probe`,
commits `cd1aa1f` and `f561b7f`.

---

## 1. The interruption test (definition of done, item 6)

The one behaviour the 18 August outage taught this project to care about,
and currently proven only against a stub. It is worth doing properly
because it is the phone-side version of the bug that made the health
score read "excellent" during a real outage.

**Steps**

1. Run with a label like `interrupt`.
2. Wait about 20 seconds, until `web` or `video` has ticked over.
3. Turn airplane mode **on** for roughly 15 seconds, then **off**.
4. Restore it before the run ends, or the verdict fetch fails too and the
   interesting part is hidden behind a connection error.
5. Let it finish and reassociate.

**What should happen**

| Expected | What it proves |
|---|---|
| Some rows go red with an error beneath them | M8: failed runs became records rather than being skipped |
| "Waiting to upload" goes non-zero, then clears | M9: nothing was dropped while the network was gone |
| The verdict reports **under 100% of tasks completed** | Availability seeing a phone outage the way it now sees the Pi's |

**A healthy score with no availability warning despite red rows is a
bug**, and the same class as the one the outage replay exposed on the
server. Report it rather than working around it.

## 2. Screenshots for Chapter 4

After a clean run, capture on the phone:

- the app showing its verdict, and
- Safari at `/overview?site=phone-<label>&hours=1`.

Same score, same headline, same three lights, from one scoring
implementation through two unrelated clients. That single image carries
the whole two-tier argument, and it is far easier to take while the app
is fresh on the device than to recreate later.

---

## Open questions

- **What did "WiFi link measured by" report on a good run**: `ping`,
  `TCP (router ignores ping)`, or `not measurable here`? It decides
  whether the campus-router limitation goes into Chapter 3 as a finding.
  A managed router that answers neither ICMP nor TCP would mean the WiFi
  link is simply not measurable from a phone there, which is a result
  about managed networks rather than a defect.
- **`phone-smoke-test`**: one row written from the dev Mac on 21 August to
  prove the backend accepts this client's JSON (see `RUNS.md`). Delete it
  or leave it? There is no delete endpoint, so removing it means SQL
  against Postgres.
- **Merge the branch.** `git checkout main && git merge --ff-only
  mobile-ios-probe`. The CA3 deliverable is this tree, so it should not
  sit unmerged.

## Not in scope, and deliberately

MS1 persistent buffer, MS3 background runs, MS4 SSID labelling. All
stretch, none earns a mark, and C6 caps this work at three days against
roughly one used. After the two tasks above, the app is done and
attention goes to **fault injection (build step 7)**, which is the last
piece of project work blocking Chapter 4.

## Also still open, outside this folder

- **`.env.local` is committed** to the `src` repo and holds
  `PROBE_INGEST_TOKEN` and `API_INGEST_TOKEN`. They are the localhost dev
  values, not the live ones (`.env` holds those and is correctly
  ignored), so the exposure is limited, but it ships inside the CA3 code
  ZIP. Worth cleaning up.
- **No probe self-monitoring.** The gap that let the 17-18 August SD-card
  failure run unnoticed for 24 hours.
