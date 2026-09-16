# E-CONV-03 — the common-link baseline, ready for a size comparison

**Date:** 2026-09-16
**Fabric:** S2 on `gpufab-s11-fabric` — 106 switches, 3728 derived underlay sessions
**Scope:** S2 only. **S1 was read (its topology file) and never run against.**
**Script:** `tests/experiments/e-conv-03.sh`, `link_intersection.py`, `d8234f8`

---

## 1. Why the link moved

E-CONV-02 measured a **core↔pod-spine** link. **S1 carries no core tier**, so
that link has no homologue there. Running the same experiment on S1 against a
different link role would have confounded fabric **size** with topology **role** —
the one thing the comparison exists to separate.

## 2. The link identity is derived, not chosen

`link_intersection.py` compares the topologies the two fabrics **actually run**,
not their profiles — two profiles can render the same names from different
intent. A link matches only if **both ends agree on device name AND interface**;
a pair matching by device but not interface is a different port on the same two
boxes, and port identity is exactly what must be held constant.

    S1 switch-switch links       : 80  (48 switches)
    S2 pod001 switch-switch links: 80  (48 switches)
    identical in both            : 80  — 76 of them leaf-spine

**The entire pod switch layer is common to both fabrics.** Deterministic pick
(lexicographically first, so reruns measure the same link):

    dc1-pod001-bk-p1-r1-leaf01:eth63  <->  dc1-pod001-bk-p1-spine02:eth1

The SONiC interface is resolved **from the kernel on the box** (`Ethernet248`),
not from an `ethNN`→`EthernetN` arithmetic rule that could drift from the image.

## 3. Result — three trials, default timers, method unchanged

Negotiated hold/keepalive 30000/10000 ms at both ends. No timer was touched
(`DO_SWEEP=0`); polling, clocks, and fault mechanism are E-CONV-02's, unchanged.

| trial | near-end (s) | far-end (s) | settle (s) | recovery (s) | settle − far |
|---|---|---|---|---|---|
| hi1 | 0.57 | **22.11** | 28.63 | 6.96 | **6.52** |
| hi2 | 0.43 | 29.97 | 36.94 | 7.02 | **6.97** |
| hi3 | 0.43 | 29.75 | 36.42 | 6.87 | **6.67** |

**The ~6.5 s residual reproduces on a different link position**, independently of
E-CONV-02 (which saw 6.80 s and 6.10 s on the core link). Two link roles, one
residual — it is a property of the fabric-plus-detector, not of the link.

**The far-end spread is explained, not noise.** The hold timer counts from the
**last received keepalive**, not from the fault, so the far end must transition
somewhere in **[hold − keepalive, hold] = [20, 30] s**. All five default-timer
trials across E-CONV-02 and E-CONV-03 fall inside that band, and hi1's 22.11 s is
the low end of it rather than an anomaly. This also retro-explains E-CONV-01's
wider settle spread: coarser polling (5 s vs 3 s) inflated its residual.

## 4. State after

- fabric **3728 / 3728**, 0 unreadable
- `timers 10 30` present in **both** running configs (nothing was changed)
- **`admit-s2: ADMIT`**, with **`S1 ADMISSION: ADMIT`**

## 5. What this is ready for, and what it is not

**Ready:** an S1 run of the **exact same link identity** —
`dc1-pod001-bk-p1-r1-leaf01` ↔ `dc1-pod001-bk-p1-spine02`, same interface, same
method, same default timers — would give the first defensible size comparison:
48 switches against 106, with link role, port identity, timers, fault mechanism,
polling and clocks all held constant. **That run is not authorized and has not
been performed.**

**Not established by this run:**

- **Size-independence.** Still one fabric. This experiment makes the comparison
  *possible*; it does not make it.
- **The composition of the residual.** Up to ~3.5 s of the ~6.5 s is the settle
  detector itself (3 s polling, two consecutive stable samples). The remainder is
  unattributed and is not claimed as route propagation.
- **The keepalive-phase model.** `[hold − keepalive, hold]` fits five trials and
  is a good explanation; it has not been tested by deliberately controlling the
  phase.
