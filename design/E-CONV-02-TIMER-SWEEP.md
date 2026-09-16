# E-CONV-02 — reconvergence settling tracks the negotiated hold (S2)

**Date:** 2026-09-16
**Fabric:** S2 on `gpufab-s11-fabric` — 106 switches, 3728 derived underlay sessions
**Scope:** S2 only. **S1 was not touched and remains unauthorized for this line of work.**
**Script:** `gpufab-platform/tests/experiments/e-conv-02.sh` (+ `-probe.sh`), `b6b5144`

---

## 1. What this settles

E-CONV-01 measured a ~36–43 s fabric settle against a configured 30 s hold and
could only say that was *consistent with* timer domination. Moving the timer
separates the two components.

**The timer conclusion is established for this fabric and link.** Settling shifted
**21.70 s for a 21 s hold reduction** — 1:1 — and the far-end peer transition
tracks the negotiated hold directly.

**A fixed residual of ~6.1–6.8 s remains, and it does not scale with the hold.**
It is therefore a separate additive term, not part of the timer.

## 2. Measurements

Negotiated timers, read from **both boxes** (never inferred from the config line,
because hold is negotiated in the OPEN and a live session keeps the old value
until it restarts):

| | near `dc1-ba-core001` | far `dc1-pod001-bk-p1-spine01` |
|---|---|---|
| before | 30000 / 10000 ms, Established | 30000 / 10000 ms, Established |
| after set `timers 3 9` | **9000 / 3000 ms**, Established | **9000 / 3000 ms**, Established |
| restored | 30000 / 10000 ms, Established | 30000 / 10000 ms, Established |

Four trials on the same link (`dc1-ba-core001 Ethernet0 → dc1-pod001-bk-p1-spine01`):

| trial | negotiated hold | near-end (s) | far-end (s) | fabric settle (s) | recovery (s) |
|---|---|---|---|---|---|
| hi1 | 30 s | 0.48 | 30.45 | 37.19 | 7.03 |
| hi2 | 30 s | 0.55 | 29.65 | 36.42 | 6.92 |
| lo1 | 9 s | 0.45 | 8.89 | 15.47 | 7.01 |
| lo2 | 9 s | 0.49 | 7.95 | 14.73 | 7.18 |

| | hold 30 s | hold 9 s |
|---|---|---|
| far-end transition | **30.05 s** | **8.42 s** |
| fabric settle | **36.80 s** | **15.10 s** |
| residual above hold | **6.80 s** | **6.10 s** |

## 3. Reading it

**The far end is the hold timer, measured directly.** 30.05 s at a 30 s hold and
8.42 s at a 9 s hold. The far end never sees a link-down event — only the
absence of keepalives — so it ages the session out. That is the bulk of the wait.

**The near end is a link-down event and is hold-independent**: 0.45–0.55 s across
all four trials, unchanged by a 3.3x change in hold.

**The residual is fixed, ~6.5 s.** 6.80 s at hold 30 and 6.10 s at hold 9 — it
does not scale, so it is not timer. It is the gap between the far end declaring
the peer down and the fabric-wide count settling, and it has two parts that this
experiment does **not** separate:

- **measurement overhead**, which is real and bounded: the settle sweep polls at
  ~1.7 s and requires two consecutive stable samples, so up to ~3.5 s of the
  residual is the detector, not the fabric;
- **whatever remains** — plausibly route withdrawal and reprogramming across the
  fabric, but this run does not measure it separately and the claim is not made.

So the honest decomposition is: **hold time + up to ~3.5 s detector + a few
seconds of unattributed fabric work.** Narrowing the last term needs a finer
settle detector, not another timer point.

**Recovery is hold-independent** at 6.9–7.2 s, consistent with establishment
being triggered rather than waited out.

## 4. Comparability with E-CONV-01

E-CONV-01 polled the settle sweep every 5 s; E-CONV-02 polls every 3 s. Its
settle figures (36.5–43.3 s) are therefore **not directly comparable** to
E-CONV-02's (36.4–37.2 s at the same hold), and its recovery figures
(8.8–9.2 s vs 6.9–7.2 s) differ for the same reason. The E-CONV-02 numbers are
the better ones: more trials, finer polling, and the far-end transition measured
rather than inferred.

## 5. What is still NOT established

- **Size-independence.** Still one fabric size, 106 switches. Nothing here
  addresses it, and the S1 point is not authorized.
- **One link, one topology position** (core↔pod spine). A leaf↔spine or an
  intra-pod link may behave differently.
- **The composition of the residual**, as above.
- **Two hold values**, not a curve. 1:1 over a single 21 s step is strong but is
  two points.

## 6. Safety, as executed

One interface and one adjacency's **per-neighbour** timers — never the
peer-group. `config save` was never run, so neither the fault nor the timer
change could survive a reload. An EXIT trap restores both on every path.

Restore proven in three independent places rather than assumed:

1. negotiated hold back to **30000 ms at both ends**, both Established;
2. `timers 10 30` present in **both** running configs (`restored_cfg_near 1`,
   `restored_cfg_far 1`);
3. fabric at **3728/3728**, 0 unreadable.

`admit-s2` was then re-run and returned **ADMIT** with **S1 ADMISSION: ADMIT**.
