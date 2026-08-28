# Cold-run validation — capturing the live proofs

Prepared 2026-08-22. This is the runbook for the next cold scale build, whose job
is to LIVE-validate the hardening landed this cycle. Everything it validates is
already unit-tested workstation-side; the cold run confirms the parts that can
only be seen on a real fabric. Trigger it when ready — it costs a full fabric
bring-up (~40 min) on the running `-01` pair.

## Pre-flight — checked 2026-08-22 (all GREEN)

| Prereq | State |
|---|---|
| All hardening on `origin/main` | ✓ network `4ad3aa2`, platform `dba0521`, docs `08bee09` |
| The `-01` pair is up | ✓ `gpufab-ops-01` + `gpufab-fabric-01` RUNNING, us-central1-a (fabric = n2-highmem-64) |
| Static IPs preserved | ✓ ops `136.116.85.135`, fabric `34.133.242.225` |
| Runner-mint credential | ✓ `gh` logged in as `skywalkerbob`, **has repo admin** — a registration token minted successfully (so `up.sh`'s driver-mint will work) |

Operator must still confirm before triggering:
- Your workstation IP is in `var.admin_cidrs` (SSH + dashboards whitelist).
- gcloud is pointed at project `ai-agent-461123`.
- `gpufab-gh-token` (relay/PR PAT) is in Secret Manager (unchanged from before).

## Trigger

From the workstation checkout (== `origin/main`, clean):

    tools/up.sh --ops gpufab-ops-01 --fabric gpufab-fabric-01 \
      --profile gpufab-network/design/profiles/scale/s1-512.yaml --sync

- `--sync` ships THIS checkout (== `origin/main`) by tar+scp and sets
  `GPUFAB_NO_RESET=1`, so the hosts run exactly the reviewed code. Deterministic —
  use this for the first clean validation.
- `s1-512` is the scale profile that exercises density (48 SONiC-VS switches,
  1464 BGP sessions) — the load level where #83 appears.
- **COLD boot matters.** The staggered-boot and reconcile-reuse proofs only fire
  on a FRESH containerlab bring-up. If the lab is already up, tear it down first
  (`sudo containerlab destroy` on the fabric host, or the deploy's teardown) so
  stage 40 does a real batched cold boot; a warm reconcile skips the staggered
  path.
- Optional follow-up run WITHOUT `--sync` additionally exercises stage-00 fetching
  `origin/main` via the deploy keys (its fail-closed path is unit-proven by t60).

## Proof matrix — what to capture, and the PASS vs FAIL signature

Evidence lands in: the role logs `/var/log/gpufab-{head,fabric}.log` on the hosts;
the phase log (`PHASE_LOG`, JSONL — `verify.bgp`, `verify.recover`,
`clab-staggered-boot`, `clab-reconcile`); the result files
`/opt/gpufab/logs/result-{head,fabric}.json`; and `journalctl` for the runner.

| # | Proof | Where | PASS signature | FAIL signature → meaning |
|---|---|---|---|---|
| 1 | **Staggered boot / load gate** (#83 prevention) | stage 40 log; phase `clab-staggered-boot` | `staggered boot: 48 SONiC VMs, batch=8, gate 1-min load<=64`, then per batch `host 1-min load X <= 64 — proceeding` | host load never approaches ~113; a `could not measure host load … refusing to launch … blind` = load unreadable (fail-closed, correct) |
| 2 | **Reconcile REUSE guard** (#83 — the live-only question) | stage 40 log | `reconcile REUSE OK: all 48 running switches kept their boot identity … clab did not reboot/recreate them` | `the reconcile REBOOTED or RECREATED running switch(es)` → **clab restarts nodes on reconcile → the staggered approach needs rework** (this is the one outcome the whole guard exists to surface) |
| 3 | **Full node set up** | stage 40 log | `staggered boot: 48/48 SONiC-VM containers running` | `staggered boot brought up X of 48 … never started` → a dropped node or a stall |
| 4 | **Cure engages iff a residual stall** (#83) | phase `verify.recover`; stage 50 log | either `stall-recovery attempt K …` then `converged after recovery`, OR no recovery line at all (no residual stall) — both are passes | `nothing to recover — no unreadable device is in the #83 give-up state` while short → a stall the swss-only gate did not match (capture the box's `systemctl show swss -p Result`) |
| 5 | **BGP convergence, authoritative** | phase `verify.bgp`; or run on the fabric host `interim_deploy.py --verify-only` | `fabric: 1464/1464 sessions Established` (denominator from expected.py, so #81-proof) | `BGP did NOT converge: X/1464 … N device(s) short` + the per-device shortfall |
| 6 | **Runner: driver mints** (S1) | `up.sh` stdout | `runner token: refreshed in Secret Manager (gpufab-network, ~1h TTL)` | `could not mint … needs repo admin` (pre-flight says this won't happen) |
| 7 | **Runner: registered to the right sim/repo** (S2/S3 + end-state) | stage 90 log; `journalctl -u gpufab-runner` | `registering as sim-<id>` then the service active; NO `degrade github-runner` | FAIL `runner config … does not name repo … and 'gpufab-<sim>'` → wrong repo/stale config |
| 8 | **#140 isolation (report-only today)** | `t57-reachability-matrix.sh`; a box check | t57 asserts the OOB-loopback block; VLAN200→`Vrf_prov` present on a VTEP leaf (`sonic-db-cli CONFIG_DB keys 'VRF|*'`) | n/a — item-2 host→mgmt-bridge is still REPORT (see issue #140); this run captures the state, does not gate it |

## Capture, after the run

    # from the workstation
    gcloud compute ssh gpufab-fabric-01 --zone us-central1-a --tunnel-through-iap --command '
      echo "== reuse guard =="; grep "REUSE OK\|REBOOTED or RECREATED" /var/log/gpufab-fabric.log | tail -3
      echo "== staggered boot =="; grep "staggered boot:\|1-min load" /var/log/gpufab-fabric.log | tail -8
      echo "== cure =="; grep "stall-recovery" /var/log/gpufab-fabric.log | tail -5
      echo "== bgp =="; grep "fabric: .*sessions Established" /var/log/gpufab-fabric.log | tail -1
      echo "== runner =="; sudo systemctl is-active gpufab-runner; grep "registering as\|REUSE OK" /var/log/gpufab-fabric.log | tail -2 '
    # authoritative BGP (verify-only, zero mutation):
    #   cd /opt/gpufab/gpufab-network && sudo /opt/gpufab-venv/bin/python tools/interim_deploy.py --verify-only

Record the six/eight signatures against this matrix; a captured PASS on #2 (reuse)
and #5 (1464/1464) is the headline result. Update
`gpufab-docs/design/DEPLOY-HARDENING-83.md` "Still open" once #2 is confirmed
green on the box.
