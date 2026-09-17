# Reconvergence vs fabric size — S1 (48 switches) against S2 (106)

**Date:** 2026-09-17
**Scripts:** `e-conv-03.sh` (S2), `e-conv-04.sh` (S1), shared probe `e-conv-02-probe.sh`, `link_intersection.py` — `6093e31`

---

## 1. What was held constant

The comparison is only worth as much as its controls, so these were held
identical and each was **verified**, not assumed:

| held constant | how |
|---|---|
| link identity | re-derived by `link_intersection.py` on both runs; E-CONV-04 **refuses** unless it yields the link E-CONV-03 measured |
| device names | `dc1-pod001-bk-p1-r1-leaf01` ↔ `dc1-pod001-bk-p1-spine02` in both |
| port | `Ethernet248` in both, resolved from the kernel on each box |
| underlay peers | `10.128.10.63` / `10.128.10.62` — **identical in both fabrics** |
| link role | pod-internal leaf↔spine (this is why the core link was abandoned: S1 has no core tier) |
| timers | negotiated 30000/10000 ms at both ends of both fabrics, untouched (`DO_SWEEP=0`) |
| fault mechanism, polling, clocks | the same probe binary, same 3 s sweep, same single-clock discipline |
| oracle | each fabric's own `expected.py` derivation — 1464 for S1, 3728 for S2 |

Only the management addresses differ (172.20 vs 172.28), which is c12's
deliberate relocation and does not touch the data path.

**What varies: fabric size.** 48 switches / 1464 derived sessions against
106 switches / 3728 — a **2.2× ratio**.

## 2. Results

| | S1 (48 switches) | S2 (106 switches) |
|---|---|---|
| near-end transition (s) | 0.61 / 0.55 / 0.52 | 0.57 / 0.43 / 0.43 |
| far-end transition (s) | 30.07 / 28.99 / 28.82 | 22.11 / 29.97 / 29.75 |
| fabric settle (s) | 36.99 / 35.91 / 36.91 | 28.63 / 36.94 / 36.42 |
| recovery (s) | 7.41 / 6.95 / 6.69 | 6.96 / 7.02 / 6.87 |
| settle − far (s) | 6.92 / 6.92 / 8.09 | 6.52 / 6.97 / 6.67 |
| baseline / after | 1464 / 1464 | 3728 / 3728 |

## 3. Reading it

**No size effect was detected on any observable.** Every range overlaps:

- **near-end** 0.52–0.61 (S1) vs 0.43–0.57 (S2) — a link-down event on both.
- **recovery** 6.69–7.41 vs 6.87–7.02 — indistinguishable.
- **far-end** 28.82–30.07 vs 22.11–29.97 — both inside the keepalive-phase band
  `[hold − keepalive, hold] = [20, 30] s`. S2's 22.11 s is the low end of that
  band, not a size effect; the hold timer counts from the last received
  keepalive, not from the fault.
- **residual** (settle − far) 6.92–8.09 vs 6.52–6.97. Means 7.31 vs 6.72, a
  0.59 s difference against an S1 spread of 1.17 s.

**State the sensitivity, not just the null.** The settle detector polls at ~3 s
and requires two consecutive stable samples, so **an effect smaller than roughly
1–2 s could not have been seen**. The honest claim is therefore:

> Across a 2.2× change in fabric size, with link role, port identity, peer
> addresses, timers, fault mechanism, polling and clocks held constant, **no
> reconvergence difference above ~1–2 s was detected** on this link.

That is a bound, not a proof of exact invariance. A size effect that is small,
or that appears only at much larger scale, is not excluded by three trials each.

**Combined with E-CONV-02**, the decomposition now stands on two fabrics:

    reconvergence  =  hold timer (negotiated, 1:1 — E-CONV-02)
                   +  ~6.5-7.5 s residual, of which up to ~3.5 s is the detector
                   +  no detected size term over 48 -> 106 switches

## 4. What is still not established

- **Larger scale.** 2.2× is a modest ratio. The profiles go to s3-4096,
  s4-10240, s5-32768; nothing here speaks to those.
- **Composition of the residual.** Still not separated into detector versus
  route propagation. Needs a finer settle detector, not more trials.
- **Other link roles.** Leaf↔spine and core↔spine; not leaf↔leaf, not a spine
  failure, not a device failure as opposed to a link failure.
- **The keepalive-phase model.** It fits eight trials across three experiments
  and predicts the observed band, but has not been tested by controlling the
  phase deliberately.
- **Anything about failure modes other than a clean admin-down.** A cable pull,
  a crashed daemon, or a slow-failing link may behave differently.

## 5. Safety, as executed

Both fabrics: one interface, one switch, EXIT-trap restore, `config save` never
run, no timer touched. Verified after each run — the faulted interface up, the
peer Established, the fabric at its own derived total with 0 unreadable, and the
running-config `timers 10 30` intact at both ends.

Admission after: **S2 `admit-s2: ADMIT`** (with S1 leg ADMIT), **S1
`admit-experiment.sh: ADMIT`**. Both fabrics remain experiment-admitted.
