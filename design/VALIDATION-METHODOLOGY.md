# Validation methodology for the cascaded deploy system

Status: **APPROVED 2026-08-23 — building in the rollout order (§8).** Requested
after the staggered-boot prevention passed unit tests + two reviews and still
failed the live cold run — evidence that point-patching + logic-only tests do not
validate this system. The §6 decisions are resolved (below).

Builds on, does not replace: `STABILITY-RETROSPECTIVE.md` §7 (the binding
verification rules — assert the end state on the real system; a check that
measured nothing is a failure), `FIDELITY-VERIFICATION-PLAN.md`, and the
`COLD-RUN-VALIDATION.md` runbook (which becomes L3 below).

## 1. The problem, from this session's evidence

The gpufab deploy is a **cascade**: 25 numbered stages, each depending on the
last, bringing up 48+ SONiC-VS QEMU guests, ZTP, BGP/EVPN, AAA, telemetry. Its
failures are the kind this codebase keeps producing — silent, and surfacing far
from their cause. Three concrete failures this cycle:

- **Unit-green, live-broken.** The staggered boot had `t59` green and two review
  passes. It still failed live: clab 0.77 refuses a second `deploy --node-filter`
  over an existing lab. No workstation test could see that — there is no clab on
  the workstation.
- **Integration bugs found last and most expensively.** The only test that
  exercises real clab/QEMU/BGP is a full cold run: ~40 min, real spend, and it
  **destroys the fabric**. So an integration/version bug costs a 40-minute
  destructive run to discover.
- **One bug per run.** A stage-40 failure means 50–90 never execute, so each
  expensive run reveals a single cascade defect. Discovery is serial.

Root cause: **there is no cheap tier that runs against the real environment.**
Bugs that only appear on a real host had nowhere to be caught but the most
expensive gate. The fix is not more edits — it is a tier that catches
environment/version/integration bugs in minutes.

## 2. The core principle

**Push every class of bug to the CHEAPEST tier that can detect it.** The
clab-0.77 refusal belonged in a 5-minute host test; it was found in a 40-minute
destructive one. Every tier must be able to name what it measured (retrospective
§7), and each tier gates the next — no expensive run until the cheap ones are
green.

## 3. The validation ladder

| Tier | Where / cost | Validates | Cannot see | Status |
|---|---|---|---|---|
| **L0 static/unit** | workstation, seconds | LOGIC (render output, arg parsing, pure predicates) | anything about the real host/clab/NOS | ✅ rich — 63 `tests/t*.sh`, ~31 `verify.sh` phases |
| **L1 micro-integration** | real host, 2–4 nodes, ~5 min | ENVIRONMENT/VERSION/clab/NOS semantics, one primitive at a time | cross-stage cascade, scale | ⚠️ partial — 10 `deploy/checks/c*.sh` exist but are not a gated tier; the clab-boot-semantics check was missing |
| **L2 smoke-scale** | full stage cascade, smallest profile with ≥2 boot waves + every node class, ~10 min | the whole 00→90 CASCADE, cross-stage contracts | the real scale load curve | ❌ missing (s0-64 = 30 switches is usable but not run as a gate) |
| **L3 scale cold run** | s1-512, ~40 min, destructive | scale behavior, real load curve, density (#83) | — (it is the last gate) | ✅ exists (`COLD-RUN-VALIDATION.md`) but currently doing L1/L2's job |

*Scope note (in force now = full-fabric):* L2 = the whole smoke cascade, L3 = the
full s1 cold run, as above. The **per-unit** scopes (L2-unit = one pod; a
shared-tier/attachment tier needing a core-bearing fixture; and the split of L3's
role into non-destructive revision-acceptance vs. periodic cold-rebuild
qualification) are the **gated future** defined in §6a — not a redefinition of these
rows.

### L0 — static/unit (exists; keep, and recognize its ceiling)
Fast logic checks on the workstation. Rich already. The lesson: **L0 green is
necessary, never sufficient** for anything that touches the host. A property that
can only be true or false on a real clab does not belong in L0 — it belongs in L1.

### L1 — micro-integration (the primary gap to close)
A **committed, repeatable** harness that exercises each RISKY host/clab/NOS
primitive in isolation, small-scale, on real clab 0.77 + the real SONiC image:
- clab deploy semantics — a single deploy with `stages/wait-for` gates boot;
  a 2nd `--node-filter` deploy over an existing lab is refused (the bug that bit
  us — now a standing regression check, not a one-off experiment).
- ZTP artifact delivery to one switch.
- BGP session establishment between two switches.
- the #83 stall + `--recover-stalled` cure recovery on one switch.
Each is a few nodes, ~minutes. The 10 existing `c*.sh` checks (BGP-unnumbered,
ZTP-FRR-delivery, substrate-isolation, BFD, EVPN-restart-durability, …) are the
foundation — formalize them into this gated tier and add the missing ones.
**This is the tier whose absence let the staggered-boot bug through.**

### L2 — smoke-scale (missing)
Run the WHOLE stage cascade (00→90) on the smallest profile that still has ≥2
boot waves and every node class (GPU/CPU/storage/mgmt/egress). Catches
cross-stage cascade bugs cheaply. Gate before L3. Candidate: a purpose-built
~6–8-switch smoke profile (fastest), or reuse s0-64 (30 switches).

### L3 — scale cold run (exists; make it a formality)
The full s1-512 cold run + proof matrix (`COLD-RUN-VALIDATION.md`). Its job is
the real load curve and density (#83) at scale — NOT first discovery of
integration bugs. Only run it once L0→L1→L2 are green.

## 4. Cross-cutting mechanisms

**Environment capability probe (committed).** Assert the host's `clab` / `docker`
/ `qemu` VERSIONS and the specific behaviors we depend on — "clab honors
`stages/wait-for` on health", "the SONiC image healthcheck flips healthy", "a 2nd
`--node-filter` deploy is refused". Turns env/version drift into a named failure
at deploy time instead of a mysterious stage crash. This is what would have made
the clab-0.77 assumption explicit and checkable.

**Stage contracts.** Each stage declares and ASSERTS its PREconditions (refuse +
name the cause if unmet) and POSTconditions (the end state it guarantees, on the
box). Localizes failures instead of letting them cascade silently three stages
downstream. Partially present already (stage 00's revision gate, stage 40's
count assert) — formalize into a consistent contract per stage.

## 5. Ladder discipline

- One entry command runs L0 → L1 → L2 in order; each must be green before the
  next; L3 is cleared only when all three pass.
- A tier that gets SKIPPED (no host, missing capability) says so loudly — a
  skipped tier is not a passed tier (§7).
- Worked example: the clab-0.77 boot bug is caught at **L1 in ~5 min** (the
  wait-for micro-test on a real host) instead of **L3 in ~40 min + a destroyed
  fabric**.

## 6. Decisions (APPROVED 2026-08-23)

1. **Where L1/L2 run** → **scratch lab on the fabric host, torn down after each
   run.** No new standing spend; the host already has clab + the SONiC image.
2. **Profiles** → **build purpose-built `micro` (2–4 nodes) + `smoke` (~6–8
   switches, ≥2 waves, all node classes).** Cheap, fast, deterministic — better
   than reusing s0-64 (30 switches) for the fast tiers.
3. **Stage-contract scope** → **high-risk stages first** (40-topology,
   50-configure, 30-seed, 00-bootstrap), then fill in the rest.
4. **Gating strength** → **hard-block L3 unless L1 and L2 are green** in the same
   session. A skipped tier is not a pass.
5. **Env-probe contents** → pin `clab` ≥ 0.77, plus the behaviors we depend on:
   clab honors `stages/wait-for` on `healthy`; the SONiC image exposes a
   healthcheck that flips `healthy`; a 2nd `--node-filter` deploy over an existing
   lab is refused. Version floors for docker/qemu recorded as observed, not gated,
   until one is shown to matter.

## 6a. Relationship to BRINGUP-ARCHITECTURE (amended 2026-08-25)

`BRINGUP-ARCHITECTURE.md` reframes the deploy from a monolithic cold boot to
incremental, per-unit convergence. **What is in force NOW is unchanged:** the L0–L3
ladder in §3 (L2 = the full smoke 00→90 cascade; L3 = the full s1 cold run) stays
authoritative until the BRINGUP §9 prerequisites are met. The following are the
**gated FUTURE** shape of the ladder — they do NOT redefine the current rows:

- **A per-unit L2 scope.** L2-unit validates ONE pod's 00→90 cascade. A pod owns
  its leaves, **spines**, OOB and endpoints (`fabric_model.py:1029,1098`); only the
  DC cores are shared.
- **A new shared-tier / attachment tier.** Validates the DC-core baseline + the
  **core↔pod-spine attachment transaction** (the BRINGUP §3 dependency graph). This
  **requires a core-bearing fixture** — `smoke.yaml` has **zero cores**
  (`:106`) and cannot exercise it; a ≥2-pod, core-bearing profile must be added.
- **Full-fabric acceptance splits into TWO gates** (do not conflate): a
  **non-destructive revision-acceptance** gate — the *currently deployed* fabric
  measured-converged to R, never green while any required unit or shared tier is
  degraded — and a **periodic/release cold-rebuild qualification** (reproducibility,
  boot, density). The cold rebuild is NOT the per-revision gate.

When those land, this doc's §3 table, detailed tiers, gating sequence, and §8
rollout are updated together with explicit scopes; until then they describe the
in-force ladder.

Division of labour: **this ladder solves serial defect discovery** (deterministic
bugs, cheaply); **incremental reconciliation improves recovery + blast radius.**
Both are required — a reconciler does not heal a deterministic defect.

## 7. Non-goals / deferred

- ~~Not a rewrite of the deploy~~ **SUPERSEDED 2026-08-25**: a per-unit deploy
  refactor IS now in scope, per BRINGUP-ARCHITECTURE.md — but gated on its §9
  prerequisites (a proven containerlab unit lifecycle, the SoT delta contract,
  revision-level success semantics). Until those land, the ladder still wraps the
  existing stages.
- Not CI automation of L1/L2/L3 (they need a real host + spend); this defines the
  ladder and the commands, run on demand until a runner is trusted.
- The #140 tenancy model and other fidelity gaps are tracked elsewhere.

## 8. Rollout — progress (updated 2026-08-24)

1. ✅ This doc (framework agreed, `0fee18d`).
2. ✅ L1 clab-boot-semantics test + the staggered-boot redesign, VALIDATED L0+L1
   then landed (platform `78a28c8`/`59bce81`). The redesign — single deploy with
   per-switch `stages.create.wait-for` — was validated at L0 (t59) AND L1 (green
   on real clab 0.77, 62s boot gap measured) BEFORE landing. The methodology
   working: the class of bug that failed the last cold run is now caught in ~5 min.
3. ⬜ Formalize the `c*` checks into the L1 gated tier; add missing primitives.
4. 🔶 `smoke.yaml` LANDED (network `e2cbdc7`): 15 switches / 6 endpoints / 53 BGP,
   all node classes, 5 boot waves — 1/3 of s1-512. **L2 = run the full cascade on
   `smoke` on the sim pair** (the -01 pair; ~15 min, gated spend), the cheap
   pre-flight before the L3 s1-512 restore. Proof matrix as in
   `COLD-RUN-VALIDATION.md`, scaled to smoke (15/15 switches, BGP 53/53, the
   wait-for boot). **Known gap:** smoke carries no EVPN/frr-split block, so it does
   NOT exercise the overlay render path s1-512 uses — a tracked follow-on (add an
   EVPN smoke variant) before L2 is a full L3 proxy. A dedicated L2 runner is
   unnecessary: L2 is `up.sh --profile smoke.yaml` with a cold teardown, same
   mechanism as L3.
5. ⬜ Stage contracts, high-risk stages first.
6. ⬜ The single laddered entry command; wire L3 to require L1/L2 green.
7. ⬜ Restore -01 via the redesign: run L2 (smoke) → if green, L3 (s1-512). Both
   gated on operator go (spend).

Immediate next action: **run L2** (smoke cascade on the -01 pair) — it validates
the #83 fix + the full stage cascade cheaply and clears the expensive L3 restore.
