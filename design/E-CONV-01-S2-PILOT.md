# E-CONV-01 — reconvergence after a single link failure (S2 pilot)

**Date:** 2026-09-15
**Fabric:** S2 on `gpufab-s11-fabric` — 106 switches, 3728 derived underlay sessions
**Scope:** S2 pilot only. **S1 was not touched**, on instruction.
**Script:** `gpufab-platform/tests/experiments/e-conv-01.sh` (+ `-probe.sh`), `d0aae0a`

---

## 1. The question

Does control-plane reconvergence scale with fabric size, or is it bound by the
BGP timers? This is **one point** — 106 switches. The scaling question needs a
second point on S1 and that is not part of this run.

## 2. Result

Two independent runs of the same deterministically-chosen link
(`dc1-ba-core001 Ethernet0 → dc1-pod001-bk-p1-spine01`, peer `10.128.10.216`):

| observable | run 1 | run 2 |
|---|---|---|
| near-end peer left Established | *invalid — see §4* | **0.54 s** |
| fabric settled at 3726 | 43.26 s | **42.92 s** |
| full recovery after restore | 9.04 s | **9.17 s** |
| fabric after | 3728/3728, 0 unreadable | 3728/3728, 0 unreadable |

Sweep resolution: **1.82 s**, so the settle figures are not an artefact of coarse
polling.

## 3. What it says

**The failure direction is timer-bound, not size-bound.** The near end notices in
**0.54 s** — that is a link-down event, not a protocol timeout. The fabric does
not settle for another ~42 s, which is the far end ageing out its session on the
hold timer (the leaves carry `timers 10 30`). The ~42 s is therefore a property
of the timer configuration, not of having 106 switches, and would not be expected
to grow with fabric size.

**Recovery is event-driven and an order of magnitude faster**: 9.1 s from
interface-up to the full derived total, because session establishment is
triggered rather than waited out.

**The asymmetry is the finding worth carrying forward** — failure ~42 s, recovery
~9 s, on the same link. Anything that budgets convergence from the recovery
number will be wrong by 4-5x in the direction that matters.

**What this does NOT establish.** One link, one topology position (core↔pod
spine), one fabric size, one timer configuration. It is a pilot: it shows the
method produces a stable, reproducible number, and it gives the S2 point. Whether
42 s is size-invariant is a hypothesis this run is consistent with and does not
prove — that needs the S1 point, or a timer sweep on S2.

## 4. Two measurement defects, both caught by the experiment's own controls

**The oracle mismatch, caught before any fault was applied.** The first control
run reported a baseline of **3760** against a derived **3728** and VOIDed. The
sweep was summing every address family while `bgp_peer_series` derives the ipv4
underlay only — the 32-session difference was exactly the EVPN layer. The control
refused to measure reconvergence against an oracle that describes a different
quantity. Had it proceeded, every delta would have been computed from a total
that never matched its own expectation.

**The two-clock subtraction, caught after the first live run.** It reported
`peer left Established after -2.99 s` — a detection preceding its own cause. The
fault was timestamped on the *host* and the detection inside the *switch VM*, and
the two clocks are not synchronised. The shutdown and the detection loop now run
in a single switch-local session, and the driver now VOIDs a negative detection
outright rather than printing it as a result. The settle and recovery numbers
were never affected: both their endpoints are host-side.

That the first number was *implausible* is what made it cheap to catch. A clock
skew of a few seconds in the other direction would have produced a plausible
detection time and been believed.

## 5. Safety, as executed

One interface, one switch, restored by an EXIT trap on every path. `config save`
was never run, so the fault could not survive a reload. Verified after both runs:
interface up, peer Established, fabric at 3728/3728 with 0 unreadable, no probe
process left behind.

`admit-s2` was deliberately **not** re-run afterwards: its S1 leg reads the other
fabric, and S1 was out of scope. The experiment's own post-gate — the S2 probe
against `expected.py` — is what confirms the fabric was left as it was found.
