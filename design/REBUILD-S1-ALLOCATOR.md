# S1 rebuild — adopting the corrected port allocator

**Status: prepared, NOT landed.** Everything below is committed on the branch
`allocator-rebaseline` in `gpufab-platform` and is deliberately held off `main`.

## Why there is a compatibility break at all

`fabric_model._port_namer` documents a two-block scheme — downlinks allocated
upward from port 0, uplinks downward from the last port, both ranked by peer name
— whose stated purpose is that adding devices cannot move existing ports. Its
docstring credits it with fixing S0 → S1's 154 moved links and the
`Duplicate termination found` seed failure that followed.

**It never ran.** `by_name` holds `as_seed_topology`'s records, which carry `role`
and not `tier`, so `TIER_RANK.get(t, 3)` ranked every device 3, `theirs < mine`
was never true, and every link was classified a downlink. The two blocks were
never two. The documentation promised behaviour the code never provided, and the
running fabric was cabled under the scheme that was actually in force.

Adopting the corrected allocator therefore re-cables S1 once. There is no
compatibility-preserving variant: pinning S1 to the legacy scheme and using the
corrected one from S2 leaves the rungs on different schemes, so the 70 links
still differ. This is one intentional break, taken deliberately, rather than a
safety scheme that is documented, relied upon and inert.

## Prepared before the window (all green)

| # | | evidence |
|---|---|---|
| 1 | `tier` carried into every allocator record; missing or unknown tier REFUSES, no fallback rank | `t08` exercises both refusals — nothing else can, because no profile emits a switch without a tier |
| 2 | `t08` covers **every** adjacent rung, each boundary pinned for equality | 5/5 pairs, 20 figures compared |
| 3 | S1 → S2 proven additive | 0 link changes, 0 mgmt, 0 loopback, 0 ASN, 0 devices lost |
| 4 | baselines rebaselined deliberately, legacy retained, diff asserted | see below |
| 5 | render / configuration conformance against the new map | t84–t87 green; ladder 505/0 |
| 6 | landing held to the window | branch only; `main` still RED at 70 and still frozen on the legacy map |

### The reviewed diff, now asserted (not merely recorded)

    s1-512      rows 1590 -> 1590    links gone 0, added 0
                devices missing 0, extra 0
                interface assignments moved            1234
                loopback / ASN / mgmt rows             byte-identical

    micro-2pod  rows 272 -> 272      links gone 0, added 0
                interface assignments moved             190
                loopback / ASN / mgmt rows             byte-identical

No endpoint, IP, subnet, loopback or ASN moves in either map. **Only interface
assignments change.** `s1-512.legacy.map` and `micro-2pod.legacy.map` are
retained beside the new ones so the break stays reviewable, and `t76`/`t77`
assert the difference is exactly the reviewed one — a regenerated golden nobody
compared would freeze whatever the code emitted, including a second defect
introduced in the same edit.

### Rung boundaries, pinned

    s0 -> s1     125 links                          historical; S0 is not deployed
    s1 -> s2       0 everything                     THE ACTIVE MILESTONE
    s2 -> s3     636 links, 180 mgmt, 222 lo, 166 asn   declared envelope boundary
    s3 -> s4    1840 links, 0 addresses             port space is not reserved
    s4 -> s5    4576 links, 0 addresses             same cause

S1 is **not** widened to the S5 envelope. S2 → S3 is a declared, tested migration
boundary rather than a defect to fix now: crossing it is a migration, and S3 is
not approved scope.

S3 → S4's cause is worth carrying forward separately — the envelope reserves
ADDRESS space, while port rank is taken over the ACTUAL peer set, so a different
node mix per pod moves switch ports while every address holds. Measured: a GPU's
`bmc0` moving `Ethernet96` → `Ethernet72`.

### Collateral: measured, not assumed

The whole workstation suite was run on `main` and on the branch and the verdicts
compared per test. **54 tests both sides. Exactly three verdicts moved, and they
are the three that were changed on purpose:**

    t08-addressing     25 passed 1 failed  ->  31 passed 0 failed
    t76-s1-baseline     7 passed           ->  15 passed
    t77-micro-fixture  22 passed           ->  26 passed

    suite rc                     main 1    ->  branch 0
    total assertions          main 1652    ->  branch 1670

The other 51 are identical. t76 and t77 gain assertions rather than change them
because the rebaseline checks are NEW — and t08 gains six because the rung sweep
now covers boundaries that were previously not compared at all.

An unchanged verdict only means something if the test ran, so the map/model
consumers were checked individually for a non-zero assertion count: t06 15, t09
74, t14 25, t26 45, t43 38, t46 19, t72 17, t80 15, t84 24, t85 17 — all
identical across the two arms.

**Six consumers are host-bound and CANNOT be checked before the window:** t03
(fabric), t13 (BGP peer truth), t38 (VXLAN), t39 (VTEP truth), t56 (forwarding),
t57 (reachability matrix). That is the residual risk, and it is exactly what the
acceptance below exercises — which is why the acceptance is the gate and the
host-free green is only permission to open the window.

## The window

1. Land the branch: allocator, baselines and tests together, in one push, so
   automation never observes a model that disagrees with the running fabric.
2. Reset / reseed the SoT. The seed must be against an EMPTY NetBox — a re-seed
   over the existing one meets cables that already exist, which is the
   `Duplicate termination found` failure the allocator's own docstring names.
3. Rebuild S1 once.

## Acceptance — all of it, or the window does not close

- exact SoT ↔ model identity
- **1,466** cables
- **1,464 / 1,464** BGP
- **16 / 16** EVPN
- **3 / 3** VTEPs
- configuration verification
- the new frozen `t76` baseline

Only after that green result may S2 generation be treated as additive.

## If it is not adopted

`main` stays honest: `t08` RED at 70 with the cause named, and `t76` green
proving the live legacy map is still frozen. That is a truthful state to sit in —
it is what made this decision reviewable — but every future rung renumbers, and
the two-block scheme keeps promising a protection it does not provide.
