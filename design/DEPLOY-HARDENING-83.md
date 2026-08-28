# Deploy hardening for the #83 density stall

Status: **CURE + PREVENTION BOTH LANDED on origin/main, 2026-08-20.** Cure:
reviewed (round 1 + adversarial + doc), gate confirmed on live evidence, narrowed
to swss-only. Prevention (staggered boot): landed WITH an on-box reconcile-reuse
guard (adversarially reviewed) so the one live-only fact — that clab's reconcile
reuses rather than reboots the running switches — becomes an unmissable pass/fail
on the next cold build instead of a silent risk. All unit-tested green.

Live state at decision time: gpufab-fabric-01 is at **1464/1464 BGP sessions
Established** (authoritative, expected.py-derived; `--verify-only`, 5s, exit 0) —
the 76.8% degraded state has fully self-healed, so there is nothing to recover
live. The cure ships as a build-time safety net for the next stall, not a repair.

## Review round 1 — six findings, all fixed

The first cut had six correctness defects (found in review); all are fixed and
covered by tests:

1. **S1 — primary path missed the cure.** `deploy.sh` defaults `USE_ZTP=1` →
   `50-ztp-provision.sh`, which did NOT pass `--recover-stalled` (only
   `50-configure.sh` did). Fix: shared `lib.sh:recover_stalled_flag` (validates
   `GPUFAB_RECOVER_STALLED` as exactly `0|1`), used by BOTH stages.
2. **S1 — fresh census result discarded.** If devices self-healed between the
   timed-out verify and the recovery census, `acted` was empty and the loop broke
   keeping the stale non-empty `short` — failing a converged fabric. Fix: `main()`
   recomputes `short`/`_est` from `census_now` before recovery; passes if full.
3. **S2 — recovery could re-stampede CPU.** `max(workers,8)` could restart 24
   swss at once on the CPU-starved host. Fix: `--recover-workers` (default 2),
   restarts in waves with a settle + fresh census between them.
4. **S2 — a partial probe could authorize a restart.** A truncated probe carrying
   one `failed start-limit-hit` line was read as stalled. Fix: `_probe_stall`
   fails closed — `probe-error` unless rc==0 AND all units parsed.
5. **S2 — "census decides" wasn't always true.** If every restart command
   returned non-zero, `main()` saw no action and skipped re-verify. Fix:
   `recover_stalled` returns `(acted, attempted, skipped)`; `main()` re-verifies
   whenever anything was ATTEMPTED.
6. **S3 — reverify-timeout knob lost through sudo.** Fix: `--recover-reverify-timeout`
   (and `--recover-workers`) are CLI flags, not env vars.

## Why

The #83 density stall is a fidelity ceiling, not a bug in the fabric: ~48
SONiC-VS VMs booting at once on a 64-vCPU host saturate CPU (load ~113); a
switch's redis hits a Lua-script stall; SONiC's RedisReply *aborts* on BUSY, so
supervisor tears down `swss`+`bgp`; the containers try to restart but systemd's
`StartLimitBurst` trips ("Start request repeated too quickly") so auto-restart
**gives up** — the switch never self-heals, its BGP sessions stay down, and the
build fails on a fabric that one targeted `systemctl restart swss` would bring
back. This is what left the -01 fabric sitting at ~76.8% BGP.

Two independent changes, land separately:

1. **Cure** — targeted, bounded, non-destructive recovery of already-stalled
   switches during the convergence gate. Spans gpufab-network (the
   `interim_deploy.py` implementation + tests) and gpufab-platform (the stage
   wiring: `lib.sh:recover_stalled_flag`, `50-configure.sh`,
   `50-ztp-provision.sh`, `nos_catalog.yaml`).
2. **Prevention** (gpufab-platform only) — stagger the containerlab boot so the
   CPU thundering herd never reaches the stall threshold.

## Review round 2 — adversarial (safety confirmed; one effectiveness gate)

An independent adversarial pass over the round-1 code (tests 30/30) could not
construct any input driving the cure toward a wrong or destructive action —
every failure path fails **safe** (skip, report, fail the build). Verified to
hold: non-destructive, unambiguous signal, end-state-on-the-box, bounded,
slow-but-healthy protected, default-off byte-identical, primary path wired,
`--verify-only --recover-stalled` reaches the cure. Findings:

- **Finding 1 (the rollout gate) — RESOLVED on live evidence 2026-08-20.** A
  read-only probe of gpufab-fabric-01 (48 switches) settled it:
  - The limiter is shipped **ON**, not zeroed: swss/bgp carry
    `StartLimitIntervalSec=1200`, `StartLimitBurst=3`, `Restart=always`. The
    `70-telemetry.sh` `StartLimitIntervalSec=0` worry does NOT apply to the image
    units. Unit names are plain `swss`/`bgp` (not `bgp@0`) — the probe matches.
  - **swss DOES reach `failed`+`start-limit-hit`** — journal-confirmed on leaf01
    ("Start request repeated too quickly" → "Failed with result
    'start-limit-hit'"), 17/48 switches during the rebuild bring-up. The gate
    signature is REAL and REACHABLE. Cure confirmed EFFECTIVE for swss.
  - **bgp NEVER reaches `start-limit-hit` (0/48)** — every bgp failure terminates
    `Result=exit-code`, stays at/below burst, and `Restart=always` self-heals it.
    Per the binding rule (never act on an ambiguous signal), `exit-code` is not a
    give-up marker and is NOT a trigger.
  - **Action taken:** narrowed `_probe_stall` to **swss-only** — `stalled` iff
    swss is `failed`+`start-limit-hit`. Removed the unobserved `bgp=start-limit-hit`
    trigger (dead code that implied bgp give-up was handled). The action still
    `reset-failed`s + restarts swss, which pulls bgp/syncd/teamd back through the
    service graph. Test `test_config_landed.py` gains a case proving bgp
    start-limit-hit + healthy swss classifies `other`, never restarted.
  - The fabric had **already self-healed** by probe time (46/48 established, the 2
    others are OOB switches with no fabric BGP; 0 unreadable) — the 76.8% is gone,
    so there is nothing to recover live. The cure ships as a build-time safety net
    for the next stall, not an immediate repair.
  - Nuance for a future reader: swss also terminated `timeout` on 4/48; that is a
    transient on the way to (not a substitute for) `start-limit-hit`, so it is
    deliberately NOT a trigger. Only the one confirmed terminal give-up string is.
- **Finding 2 (low, fails safe).** If the host is still CPU-starved at recovery
  time the 30s probe SSH may time out → box skipped → cure inert, never mis-acts.
  Recovery runs only after the 600s converge timeout, by when the herd is over.
- **Finding 3 (fixed).** The final "did not converge" line now reports true total
  elapsed (`time.time() - _t0v`), not a stale `_waited`, on every break path.

## The cure — `gpufab-network/tools/interim_deploy.py`

`converge()` is deliberately passive (it waits and reports, never acts) because
this project reached `containerlab destroy` on 124 live nodes by auto-acting on
an ambiguous "BGP below threshold" signal. The cure does **not** change that. It
adds a separate, explicitly-named, opt-in step:

- `_probe_stall(node)` — one SSH read of the switch's systemd state; classifies
  `stalled` / `recovering` / `unreachable` / `probe-error` / `other`. Only
  **`swss` = failed AND Result = `start-limit-hit`** (the mechanical give-up
  marker) counts as `stalled` — SWSS-ONLY, on live evidence (see Finding 1: bgp
  never reaches this state on the image). A truncated/non-zero probe is
  `probe-error` (fails closed), never `stalled`. This is the unambiguous signal.
- `recover_stalled(targets, census, restart_workers, settle)` — for each device
  that is UNREADABLE in the census **and** `stalled`, runs
  `sudo systemctl reset-failed swss bgp syncd teamd && sudo systemctl restart swss`
  (swss pulls bgp/syncd/teamd back through SONiC's service graph). A per-device
  service restart — never a destroy — issued in low-concurrency waves (default 2)
  with a settle + fresh census between them, so repairing a CPU-starvation stall
  does not re-create it. Returns `(acted, attempted, skipped)`: `attempted` (a
  restart was sent, rc-independent) is what the caller re-verifies on, so a
  restart whose SSH dropped is still re-checked against the box.
- `main()` — after `verify()` fails, if `--recover-stalled` (and not
  `--no-wait`): up to `--recover-attempts` (default 2) rounds of
  {fresh census → recover_stalled → **re-verify on the box**}. The census, not
  the restart's exit code, decides success. A device still short after the
  bound is reported and fails the build, exactly as before.

Safety, against the binding verification rules:
- Unambiguous signal (`start-limit-hit`), never "sessions low".
- Non-destructive (service restart), never `containerlab destroy`.
- End state asserted on the box (fresh census), never the restart rc.
- Bounded (≤ `--recover-attempts` restarts per device).
- Default-off in the tool; the deploy stage opts in.

Tests: `tools/test_config_landed.py` (`recover_stalled()` block) — probe
classification (all five classes: stalled, recovering, unreachable, probe-error,
other), acts only on the swss give-up signature (bgp start-limit-hit + healthy
swss classifies `other`, never restarted), action is `reset-failed ; restart
swss` and NEVER destructive, readable devices untouched, restart-failure reported
not counted recovered. All green locally.

## The stages — `50-ztp-provision.sh` (primary) and `50-configure.sh`

BOTH pass `--recover-stalled` by default (that is the hardening), via the shared
`deploy/lib.sh:recover_stalled_flag`. Wiring only `50-configure.sh` would have
missed the PRIMARY unattended path: `deploy.sh` defaults `USE_ZTP=1`, which runs
`50-ztp-provision.sh`, not `50-configure.sh`. Kill switch:
`GPUFAB_RECOVER_STALLED=0` (validated as exactly `0|1`) restores wait/report-only.
Read pre-`sudo` and passed as a flag, the same reason `--workers` is (sudo strips
the env). `tests/t48-push-knob-reachable.sh` asserts both stages pass both flag
arrays, inspecting the continuation-joined argv (not a physical line).

## Reviews — COMPLETE (2026-08-20)

- **Round 1** (correctness) — 6 findings, all fixed + test-covered: primary path
  missed the cure; fresh census result discarded; recovery could re-stampede CPU;
  partial probe could authorise a restart; "census decides" broke on non-zero rc;
  sudo-stripped knobs. See "Review round 1" above.
- **Adversarial** — could not construct any input driving the cure to a wrong or
  destructive action; every failure path fails safe. All guards verified. One
  effectiveness gate (Finding 1) → RESOLVED on live evidence, gate narrowed to
  swss-only. See "Review round 2" above.
- **Doc review** — corrected stale prose (this section and the cure section) to
  match the narrowed swss-only gate, the `(acted, attempted, skipped)` return,
  both-stage opt-in, and current rollout state.

## Landed (2026-08-20)

All on `origin/main`, `skywalkerbob <charleslong2010@protonmail.com>`, separate
commits by refspec (CLAUDE.md §5). Suite green: t48 26/0/0, t59 28/0/1, t60 19/0/0;
network `test_config_landed.py` 0 failures.

**Cure** (5 commits):
- gpufab-network `7d39b56` `interim_deploy.py` (source), `4ad3aa2` tests
- gpufab-platform `a8a9ecd` `lib.sh:recover_stalled_flag` + `50-configure.sh` +
  `50-ztp-provision.sh` + `nos_catalog.yaml`, `6870488` `t48`
- gpufab-docs `9c3498a` this doc

**Prevention** (2 commits): gpufab-platform `7b2f64f` `40-topology.sh` + `lib.sh`
(staggered boot + reconcile-reuse guard), `a6144c0` `t59` + `verify.sh`.

**Stage-00 revision gate** (separate deferred item A8/#129, landed same session, 2
commits): gpufab-platform `65b3fa2` `00-bootstrap.sh` (FAIL on an unreachable
pinned revision), `61952e4` `t60` + `verify.sh`.

Fabric state at land time: **fabric-01 self-healed to 1464/1464** BGP sessions
(authoritative expected.py count, `--verify-only`, exit 0). Nothing to recover
live; both changes are build-time safety nets for the next cold build.

## Still open

- **Host sync**: the fabric hosts have NOT been re-synced (tar+scp) with these
  commits — they carry the cure/prevention only after the next sync. Deferred
  deliberately (fabric healthy, no urgency); do it before/at the next build.
- **Live confirmation on the next cold build**: (a) the reconcile-reuse guard
  passes green (clab reuses) vs fails red (reboots → staggered approach needs
  rework); (b) the load gate holds host load below the stall point under real
  QEMU boots; (c) the cure engages only if a residual stall occurs. The guard
  makes that build trustworthy; it does not replace it.

## Traps for a fresh reader

- Hosts cannot `git pull` — checkouts are updated by tar+scp; host-side
  `git status` is not a drift signal (only `t01-provenance.sh` is).
- `git archive` ships mode 644 — exec bits are set at deploy time.
- `converge()` is passive ON PURPOSE. Do not "simplify" the cure back into it.
- Never widen the recovery signal from `start-limit-hit` toward "BGP low", and
  never let the action become anything that removes/rebuilds a node.
