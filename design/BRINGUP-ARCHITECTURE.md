# Fabric bring-up architecture: incremental convergence, not a monolithic cold boot

Status: **DIRECTION APPROVED, CONTRACT NOT YET — do not implement.** The
operational model (incremental reconciliation, unit-at-a-time, self-healing) is
right. This revision (2026-08-25) tightens it into a contract after review found
it removed hard guarantees without defining replacements. Six prerequisites (§9)
must be specified and, where noted, PROVEN before any build.

Companion to `VALIDATION-METHODOLOGY.md` (how we test); its §6a amendment landed
alongside this doc, so the two are reconciled. The **currently approved** ladder
(L0–L3 over the existing stages) remains authoritative and in force; the
**per-unit** ladder + deploy refactor described here are the **gated future**,
unlocked only when the §9 prerequisites are satisfied.

## 1. The problem — and the correct causal split

We repeatedly ran a full cold boot (48–512 switches) as one operation and it
failed, each time somewhere new (staggered-boot/clab, SoT reset, ZTP shrink, the
ZTP opt-67 race, a duplicate test number, the s1-512 SoT gate misread). But those
are **two different problems, and the model only fixes one of them:**

- **Serial DETERMINISTIC defects** — the clab batch-2 refusal, the ZTP `args`
  placement, the SoT gate counting `has_primary_ip` (21 vs 124), the 32-short
  seed, the duplicate `t35`. These are correctness bugs. **A reconciler does NOT
  heal them** — re-running an incorrect count, seed, or clab op just fails again.
  The fix for these is the **validation ladder** (find them cheaply, one-per-run →
  many-per-run) plus fixing them. This is orthogonal to bring-up architecture.
- **Reliability of the CONJUNCTION** — a full cold boot is the logical AND of ~25
  stages × 48 concurrent VMs, so even with every deterministic bug fixed, its
  success is the *product* of every stage and every VM, and it fails on the whole
  if any one flakes (a race, a slow boot, a transient). **This** is what the
  bring-up model must fix, via recovery and blast-radius containment.

So: **the ladder solves serial defect discovery; incremental reconciliation
improves recovery and blast radius. Both are required; neither substitutes for the
other.** The earlier draft over-claimed that reconciliation would fix the whole
list — it will not fix the deterministic defects.

## 2. Three things we have been treating as one

- **Real fidelity — keep.** The redis Lua stall under CPU starvation is genuine
  SONiC behaviour worth reproducing.
- **Emulation artifacts — the MODEL is wrong.** The ZTP opt-67 race exists only
  because containerlab puts every switch's management on one shared L2 bridge with
  no relay. The #83 boot herd is 48 QEMU guests booting at once on one host. Both
  are one-host/one-bridge artifacts. (But see §4-P3: fixing the bridge fixes the
  ZTP race, NOT the boot herd — those are independent.)
- **Self-inflicted process** — the monolithic all-or-nothing build, resetting and
  reseeding the SoT to change the fabric, booting everything at once.

## 3. How real fabrics are brought up — with the shared tier made explicit

Incremental, unit-at-a-time; convergent/self-healing; durable delta-edited SoT.
**But a pod is NOT a fully isolated atom, and the design must not pretend it is.**
The ownership boundary, measured in `fabric_model.py` (NOT assumed): a pod owns
**all** its pod-local switches — leaves, **spines** (spines live in `pod["sw"]`,
`:1029,1098`), and OOB — plus its endpoints. The **only** shared tier is the **DC
cores**, which connect to every pod's spines (`:1096-1106`) and are distributed across
pod hosts round-robin (`:1211`). So the coupling is narrow and specific: adding/removing a pod
changes the **core↔pod-spine** links and the cores' config, and a bad *core* change
can break existing pods. (NVIDIA's SU model is modular deployment; larger fabrics
still have a shared DC-core tier — it does not imply complete pod isolation.
smoke.yaml has **zero cores** (`:106`), so smoke is a single-pod / no-shared-tier
case and cannot exercise the shared tier at all — a **core-bearing fixture** is
required, see VALIDATION-METHODOLOGY §6a.)

The real structure is a **dependency graph**, not a flat set of units:

    SHARED-TIER BASELINE  (the DC CORES converged at revision R)
        └─> POD ATTACHMENT TRANSACTION  (the core↔pod-spine delta + core config, at R)
                └─> POD VALIDATION  (the pod — leaves, spines, OOB, endpoints —
                                     converges + is validated at R)

**Ownership:** a pod owns every pod-local switch (incl. spines + OOB) and endpoint;
the shared tier owns only the DC cores; the attachment is the **core↔pod-spine
delta**. Shared-tier (core) changes have a larger blast radius than a pod attach
and get their **own explicit acceptance gate**.

## 4. The four pillars — as contracts

**Pillar 1 — the SCALABLE UNIT is the bring-up atom, WITHIN the dependency graph
of §3.** A pod is the unit for its leaves, spines, OOB and endpoints; only the DC
cores are a separate shared tier with their own convergence and acceptance. A pod
that fails to converge is retried or quarantined **in isolation of other pods** —
but never in isolation of the shared core tier it attaches to. Prerequisite: a real
containerlab unit lifecycle (§9.3) — **this does not exist today**.

**Pillar 2 — convergent, self-healing provisioning, WITH revision-level success
semantics.** The reconcile loop (desired-state → observe-on-box → act → repeat)
**continues after a unit fails** — that is the recovery/blast-radius win. But
success is defined at the level of a **requested fabric revision**, not per unit:

> **Continue reconciling after a unit failure, but never report the requested
> fabric revision complete while any required unit or shared dependency is
> degraded.**

Concretely:
- The run's authoritative result stays **incomplete / non-zero** until **every
  required unit AND every shared tier** has converged **at the same desired
  revision**.
- **Quarantine** (proceeding with a unit excluded) requires **explicit, recorded
  operator acceptance** — it never silently turns a partial topology into success.
- This **preserves** the one hard guarantee the monolithic fatal gate gave us —
  no silent partial success — while adding recovery. It does not weaken it.

**Pillar 3 — fix the emulation management/DHCP model (ZTP race only), keep the
boot-herd pacing.** A per-node ingress mgmt path fixes ZTP **identity** (DHCP
delivery); it does **nothing** for QEMU CPU concurrency. The `stages.create.
wait-for` staggered boot is the actual **boot-herd** prevention and **stays** until
per-unit scheduling demonstrably supersedes it. And the DHCP fix is not "option-82
makes misdelivery impossible" — RFC 3046 makes circuit-id an agent-local
identifier the server *may* use for policy. A single per-pod bridge does **not**
yield a unique per-port circuit-id. We need a **unique per-node ingress circuit**
(per-node bridge, an emulated access-switch port, or an explicit relay mapping),
AND the **on-box identity guard stays MANDATORY** — deterministic delivery plus
verify-the-received-identity-on-the-box, defense in depth. (§9.5)

**Pillar 4 — incremental SoT, as a mutation contract (not "add/remove").** Today
`seed.py` skips existing devices rather than reconciling changed fields (`:360`),
skips a cable when either endpoint is already cabled, and its only removal path is
a global reset (`:534`) — insufficient for safe incremental change. Pillar 4 must
define, before use: **pod-scoped plan/apply** (compute + show the delta, then
apply); the **locked field-level ownership model** from `scale-out-architecture.md`
(`:1600-1604`) — **seeded fields reconciled from policy; operator-owned NetBox
fields and operational overrides (e.g. maintenance state) NEVER overwritten by a
seed; additive and non-destructive except under an explicit `--reset`** (this is a
locked decision, reused verbatim, not re-opened); **additive-before-destructive
ordering**; **drain/removal semantics** (safely remove a pod); **revision stamping**
(every object tagged with the desired revision R, see §9.2); **partial-failure
recovery** (resume a half-applied delta); **rollback** (revert a bad delta); and an
**idempotency gate** (re-applying a converged delta is a *measured* no-op).
"Add/remove operations" alone does not eliminate the transition-failure class.
(`scale-out-architecture.md` also already specifies the incremental per-pod render
and DHCP-relay-per-host this builds on — §4-P3 / §6.)

## 5. What is KEPT (a re-frame, not a rewrite from zero)

SoT-driven per-device render; **"assert the end-state on the real box, never the
mechanism"** (more important here — "converged" must be measured); the validation
ladder (amended per §8); the recovery primitives (cure, guard, retry — become the
reconcile spine, but do not replace the ladder for deterministic defects); the
scalable-unit structure in `fabric_model`.

## 6. The concrete delta (what changes)

- `up.sh`/`deploy.sh`: linear all-or-nothing → per-unit reconcile driver **that
  still enforces revision-level completion (§4-P2)**.
- `roles/fabric.sh` fatal SoT/BGP gate → per-unit convergence + retry, **with the
  authoritative run incomplete until all units + shared tiers converge at R**.
- ZTP: shared mgmt bridge → per-node ingress circuit **plus** the mandatory guard.
- Seed: reset+reseed → the §4-P4 mutation contract.
- The staggered boot (`wait-for`) **stays** as boot-herd prevention.
- **Two distinct full-fabric gates — do not conflate them** (a cold rebuild per
  revision would re-impose the destructive monolith this architecture removes):
  - **Non-destructive full-fabric revision acceptance** — prove the *currently
    deployed* fabric has converged to R by measuring the running boxes and shared
    tier (no rebuild). This is the per-revision gate that §4-P2 enforces.
  - **Periodic / release L3 cold-rebuild qualification** — a from-scratch cold boot
    proves *reproducibility, boot behaviour, and density*. It does NOT prove an
    incremental R−1→R transition and is NOT run per revision.

## 7. Honest status of the causal argument

The §1 list is *mostly deterministic defects the ladder is for*; the reliability
model earns its keep on the **races and blast radius**, not on those bugs. Do not
sell the pivot as "this makes the cold boot reliable" — sell it as "this contains
blast radius and recovers from flakes; the ladder + fixes handle the deterministic
defects; together the fabric becomes reliably build-able one unit at a time."

## 8. Relationship to VALIDATION-METHODOLOGY.md (amendment landed)

The companion §6a amendment landed alongside this doc; the two are reconciled, not
in conflict. The split of authority:
- **In force now:** the existing L0–L3 ladder over the existing stages (the
  currently-approved model). This does not change until §9 is satisfied.
- **Gated future** (this doc): L2 gains an explicit **per-unit** scope (one pod's
  cascade); a **shared-tier / pod-attachment** tier validates the §3 graph and
  requires a **core-bearing fixture** (smoke has zero cores and cannot cover it);
  and full-fabric acceptance splits into the **two gates** of §6 — *non-destructive
  revision acceptance* (the per-revision gate) and *periodic cold-rebuild
  qualification* (reproducibility/density). Deploy-refactor moves from non-goal to
  in-scope, gated on §9.

## 9. Prerequisites before ANY implementation (the contract to add)

1. **Per-unit and shared-tier dependency/state models** — the §3 graph made
   concrete: what a pod owns, what the shared tier owns, the attach transaction,
   and the separate shared-tier acceptance gate.
2. **Revision-level success semantics, and R as a frozen manifest** — §4-P2
   formalized. R must be an **identifiable immutable object**, not a vague "desired
   revision": a **frozen deployment manifest** binding {scope + the required unit
   set, the SoT snapshot/fingerprint, the renderer + code revision, and the accepted
   quarantines}. Define **supersession**: when R+1 arrives mid-run — queue it,
   preempt, or converge R then R+1 — so a reconcile never chases a moving target.
   The run is complete only at full convergence to *that* manifest; quarantine
   requires explicit, recorded acceptance.
3. **A PROVEN containerlab unit lifecycle** — the hardest gap, **unsolved today**.
   Stage 40 destroys the whole lab (`40-topology.sh:61`) then one full deploy
   because clab refuses a second filtered deploy (`:153`, the bug that motivated
   this). The new driver **cannot** deploy pod 2 after pod 1 with that mechanism.
   Choose and **validate (an L1 spike)** exactly one substrate: separate labs per
   pod/shared-tier (and how inter-lab links are wired), a proven non-destructive
   full-lab reconcile, or a lower-level (below-clab) lifecycle manager. No build
   until one is demonstrated.
4. **A scoped SoT delta/rollback contract** — §4-P4 in full (plan/apply, field
   ownership, ordering, drain, revision stamp, partial-failure recovery, rollback,
   idempotency gate).
5. **Exact DHCP circuit-identity mechanics** — §4-P3: the unique per-node ingress
   mechanism, and the guard kept mandatory until identity is verified on-box.
6. **A reconciled L0–L3 methodology** — §8, landed as a companion amendment.

## 10. Non-goals / honest caveats

- This session's cold-boot hardening was largely **deterministic-defect** work
  (ladder's domain) plus recovery primitives; not wasted, but not the reliability
  answer by itself.
- Real failure modes (redis stall) stay — the point of a simulator.
- This is a multi-session redesign gated on §9, not a patch.
- The through-line: **a datacenter is brought up one scalable unit at a time
  against a durable source of truth, each unit converging and self-healing — but
  the requested fabric revision is never reported complete while any required unit
  or shared tier is degraded.**
