# S1 rebaseline window, 2026-09-05 — STOPPED CLOSED, frontend will not converge

**Status: stopped closed. The `rrev` fix IS LANDED (`gpufab-network` main
`c9c6b83`) and it worked — the render succeeds and 46 switches carry config that
matches intent. What remains RED is convergence: BGP 1387/1464 and EVPN 8/16,
with the entire shortfall in the FRONTEND fabric. Nothing is being retried.**

The sections below are in chronological order; the last one is the current
state.

Read this before touching `gpufab-fabric-01`, `gpufab-ops-01`, or
`render_fabric_ztp.py`.

## What was authorized

Adopt the corrected port allocator, rebaseline S1 once, and rebuild. Acceptance
required exact SoT/model identity, 1466 cables, 1464/1464 BGP, 16/16 EVPN,
3/3 VTEPs, configuration verification, and the new frozen t76 baseline.

## What actually happened

| step | outcome |
|---|---|
| Disk snapshots (3) | OK — 7.3 / 5.8 / 14.3 GB, all READY |
| GATE 4 quiesce | OK — 5 destructive units closed, rebuild unit masked, masked-start refusal PROVEN |
| GATE 5 backup | OK — `pg_restore --list` 2100 TOC entries, 8/8 artifacts checksum-matched off-host |
| Push `64dfe1b` | OK — allocator + baselines + tests, one atomic refspec |
| SoT reset | OK — 6002 objects deleted, reconciling exactly to 1466+3024+124+1388 |
| resume (window closed) | OK — rebuild unit restored BYTE-IDENTICAL (sha `0ea199fa…`, inode 6395) |
| Rebuild `20260905T065823-467c-64dfe1b` | **head rc=0, fabric rc=1** |

**The allocator itself is vindicated.** Stage 00 moved the host from `a14f566`
to `64dfe1b`, the reseed ran under the corrected allocator, and stage 30's own
gate measured `SoT verified: 124/124 devices, 1466/1466 cables, 0 without
primary_ip4`. Stage 48 then reconciled the booted fabric against that SoT and
reported the wiring and the record agree in both directions. 124 containerlab
nodes are up (48 SONiC + 75 hosts + 1 head).

## The defect — mine, and not the allocator's

Stage `50-ztp-provision` died with:

    File "…/tools/render_fabric_ztp.py", line 1780, in main
      "render": rrev})
    NameError: name 'rrev' is not defined

`0f985a3` ("extract render_bundle from the canonical loop") moved
`rrev = render_revision.render_revision()` into `render_bundle()` (def @1382) and
left three USES behind in `main()` (def @1480) — the `_provenance.json` write and
two prints, at 1780/1783/1784.

It fires at main()'s LAST step, after all 48 artifacts have rendered. The stage
failed SAFE: staged tree preserved, served tree untouched.

**Why nothing caught it:** t84 calls `render_bundle()` directly and asserts on the
bundle. main()'s tail is reached only by a real render against a live NetBox. The
extraction was verified at the seam it created, not at the seam it left behind.
This is the project's own pattern: reading finds design defects; only running
finds the ones that matter.

Measured with pyflakes: 5 `undefined name 'rrev'` hits on the pre-fix file, none
on the fixed one, and **no other undefined name anywhere in either repo's
`tools/`** — so those three uses were the extraction's only casualties.

## The consequential part: 48 switches took stale config

The served tree `/opt/gpufab/ztp-srv` still holds artifacts rendered
**2026-09-02 under the LEGACY allocator** (`_provenance.json`: `captured_at
2026-09-02T11:24:36`, fingerprint `d4fc6984f814b88c`, 48 artifacts). The render
failing left it correctly untouched — but the fabric had just been re-cabled
under the CORRECTED allocator, and these switches run the `-ztp` image and boot
into ZTP discovery.

Measured on the box: **581 HTTP lines since 07:00 and all 48 distinct switches
fetched `config_db.json`** from that stale tree. Legacy port assignments against
new cabling — the same silent class as the 32-port PORT table that cost 178 BGP
sessions.

`gpufab-ztp-oob` was therefore STOPPED (0 fetches after; verified). This is
"stop closed", not recovery: it halts propagation of known-wrong config.

## Current state

- **SoT** — correct and verified under the new allocator. Do not reseed.
- **Fabric** — 124 nodes up, cabled per the new map, reconciled against the SoT.
- **Switches** — provisioned from the stale legacy tree. Known-wrong, to be
  overwritten by a correct re-render. No acceptance figure should be trusted
  until then.
- **ZTP server** — stopped, deliberately.
- **Automation** — `gpufab-bot`, `gpufab-relay`, `gpufab-runner` all `inactive`
  (measured). NOTE: the deploy RESTARTED them via `bot/setup_automation.sh` — a
  path outside `deploy/*.sh`, which an earlier grep of only `deploy/` and
  `roles/` missed. They were re-closed. The bot ran `dry_run=True` for ~7 minutes
  and its journal shows no remediation action.
- **Backups** — 3 disk snapshots + the GATE 5 SoT dump, all validated, untouched.

## Recommended resumption (NOT executed — needs authorization)

The SoT and the cabling are already correct, so a full rebuild is not required:

1. Push `c9c6b83` (`render-rrev-fix`) to `gpufab-network` main.
2. Re-close `gpufab-bot`/`gpufab-relay`/`gpufab-runner` AFTER the deploy, not
   before — they come back with `setup_automation.sh`.
3. Re-run the fabric role from the failed stage: `deploy.sh --from 50-ztp-provision`.
4. Restart `gpufab-ztp-oob` so the freshly rendered tree is the one served.
5. Then the full acceptance gate.

Add a static undefined-name gate (pyflakes over both `tools/` trees) to the
suite. It reproduces this defect in milliseconds and would have caught it before
the window opened.


---

# Resume attempt (authorized) — fix landed, gate RED on frontend convergence

`c9c6b83` (the `rrev` fix) was pushed to `gpufab-network` main, stage 00 pulled it
onto `gpufab-fabric-01`, and the fabric role was resumed with
`deploy.sh --from 50-ztp-provision`.

**The render fix worked.** Stage 50 rendered, swapped the tree, recreated
`gpufab-ztp-oob`, and pushed config: **38 switches reloaded+VERIFIED, 8 already
in sync, 0 VERIFY-FAILED, 75 hosts configured**. No NameError.

**It then failed at its convergence gate**: `fabric: 1387/1464 sessions
Established (waited 602s)` -> `[FAIL] config-push backfill failed`. That message
is misleading — the switches DO have routing config; the gate is about
convergence, and `60-auth` / `98-spot-rebuild` never ran as a result.

## Gate result

    BGP sessions ESTABLISHED      1387   expected 1464
    EVPN sessions ESTABLISHED        8   expected 16

Green and worth recording: `t02-sot 8/0`, `t11-config-applied 11/0` (what is ON
the box equals what was rendered FOR it), `t43-topology-truth 45/0`,
`t57-reachability 12/0`, `t38-vxlan 27/0`, `t50-evpn-durability 82/0`, and
**`t76-s1-baseline 15/0` — the new frozen baseline holds against the live
fabric.** The allocator and the rebaseline are not in question.

## The shortfall is ENTIRELY frontend, and it is stuck

    dc1-pod001-fr-leaf01    43/51        dc1-pod001-bk-p2-*      34/34, 16/16  OK
    dc1-pod001-fr-leaf02    15/52        dc1-pod001-st-leaf*     48/48, 50/50  OK
    dc1-pod001-fr-leaf03    23/51        dc1-pod001-st-spine*    3/3           OK
    dc1-pod001-fr-spine01    1/3
    dc1-pod001-fr-spine02    1/3

83 of the frontend's 160 expected series. 160-83 = 77 = exactly 1464-1387.
Backend (1152) and storage (152) are fully established. EVPN 8/16 is the same
frontend half.

FOUR independent suites (t03, t13, t41, t44) read 1387 at different points across
the gate's run, so this is STUCK, not still converging.

**Do not read the exporter here.** It reported `gpufab_bgp_peer_up up=0
down=1464` and `mgmt_reachable 0/48` while the boxes were at 1387 and the mgmt
IPs answered ping. The on-box reads are the truth; the exporter is broken
(plausibly because `60-auth` never ran) and is itself a defect to chase.

## Also outstanding

`gpufab-ops-01` is drifted: `render_fabric_ztp.py` differs from git, and network
and docs are each 1 commit behind. Stage 00 was run on the FABRIC host only.
Harmless for this render (`OOB_MODE=local` renders fabric-side) but it must be
synced before anything trusts that host.

## State

SoT correct; cabling correct and reconciled; 46 switches configured with config
matching intent; frontend BGP/EVPN will not converge; `60-auth` and
`98-spot-rebuild` never ran. Automation (`bot`/`relay`/`runner`) closed. Backups
untouched and restorable.

**Stopped closed. No further action taken.**

---

# ROOT CAUSE (2026-09-05) — stale kernel addresses on the three frontend leaves

**Not the allocator. Not the in-sync skip. A failed cleanup BELOW CONFIG_DB.**

`fr-leaf01/02/03` came out of their config reload holding BOTH the pre- and
post-rebaseline interface->IP layouts in the kernel at once:

    Ethernet28   10.128.10.192/31  10.128.0.35/31    <- stale uplink + real downlink
    Ethernet252  10.128.10.192/31                    <- the CORRECT uplink
    Ethernet200  10.128.9.169/31                     <- not in CONFIG_DB at all

    ip route get 10.128.10.193  ->  dev Ethernet28   (a GPU port)
    CONFIG_DB and the artifact  ->      Ethernet252   (the spine uplink)

44 of 54 addressed interfaces held two addresses. The kernel picks a connected
route arbitrarily, so a session establishes IF AND ONLY IF it happens to pick the
correct copy — which is why the counts were RAGGED (43/51, 15/52, 23/51) instead
of all-or-nothing, and why the 8 missing EVPN sessions ride the 77 missing
underlay ones. Route selection predicts BGP state exactly, peer by peer.

**Blast radius, measured across all 46 comparable switches:** exactly three.

    dc1-pod001-fr-leaf01  46 extra addresses
    dc1-pod001-fr-leaf02  45
    dc1-pod001-fr-leaf03  45
    every other switch     0        0 unreachable, 0 rendered-but-missing

**The control that exonerates the allocator:** `bk-p2-r8-leaf01` underwent an
IDENTICAL remap (`Ethernet0|10.128.10.180` -> `Ethernet252|10.128.10.180`, in its
syslog) and came out clean. The rendered artifacts are correct and CONFIG_DB
matches them byte-for-byte on every device checked (104 keys, 0 box-only, 0
render-only). The allocator change is the OCCASION — it is what made old and new
differ, so a failure to remove the old became visible — not the defect.

`intfmgrd` logged EEXIST ~47s AFTER syncd recreated the interfaces, on precisely
the bindings common to both layouts, i.e. the old addresses were already back:

    08:35:49 setIntfIp: '/sbin/ip address "add" "10.128.10.1/31" dev "Ethernet0"' failed rc 2

`bk-p2-r8-leaf01`: zero such failures. **Why the stale addresses reappear on
exactly those three leaves is UNRESOLVED** — push procedure, artifact write times
and container restart times are indistinguishable across frontend, backend and
storage.

## Why every check was green, and honest

`t11-config-applied`, `interim_deploy`'s read-back, and stage 48 compare
CONFIG_DB to the artifact, or wiring to the SoT. The defect is a SUPERSET living
in the netlink layer below anything they describe. Nothing measured the kernel.

`tests/t88-kernel-address-truth.sh` now does (HELD on branch
`kernel-address-truth`, `8e5c1f9`). It asserts set equality in BOTH directions —
an address on the box the artifact does not name is a FAILURE, not an ignored
extra — plus `ip route get <neighbour>` egressing the render-assigned port.
Proven to discriminate: `fr-leaf02` 6 passed/5 failed, `bk-p2-r8-leaf01` and
`st-leaf02` 9 passed/0 failed, full sweep 183/11 naming exactly the three.

## Recommended fix — NOT APPLIED

1. On `fr-leaf01/02/03` ONLY: flush the kernel addresses and re-apply from
   CONFIG_DB, then confirm with `ip route get <peer>` before believing it.
   **Do not touch the spines — they are correct.**
2. Land t88 so this cannot recur silently.
3. Open a separate item for the unresolved re-adding agent, and for the broken
   exporter (`60-auth` never ran).

---

# REPAIRED — all acceptance criteria met (2026-09-05)

`deploy/repair_kernel_addrs.sh` removed the addresses the artifact does not name
on `fr-leaf01/02/03` ONLY (46 / 45 / 45). Surgical rather than a second `config
reload`: a reload is what PRODUCED the state and its outcome is not understood,
so repeating it hoping for a different result is not a repair. Delete set is
(kernel MINUS artifact), so a rendered address cannot be removed by construction;
the tool re-measures afterwards and asserts the end state rather than the rc.

Verified by t88, not by the tool's own claim: `fr-leaf01/02/03` each **9 passed,
0 failed**, including the `ip route get` egress predictor. On-box BGP immediately
after: fr-leaf01 54/54, fr-leaf02 56/56, fr-leaf03 54/54, fr-spine01 6/6,
fr-spine02 6/6.

## Acceptance — ALL MET

    exact SoT <-> model identity   t02-sot 8/0
    cables                         1466
    BGP                            1464/1464
    EVPN                           16/16 Established AND Exchanging
    VTEPs                          3/3
    configuration verification     t11-config-applied 11/0
    new frozen t76 baseline        t76-s1-baseline 15/0

Every previously-red suite recovered: t03 14/3 -> 17/0, t13 10/1 -> 11/0,
t39 63/2 -> 65/0, t44 29/2 -> 31/0, t41 85/1 -> 86/0. Gate: 9 failed phases -> 4.

## The 4 remaining phases are BOOKKEEPING, not fabric health

- `deploy-results` / `roles-head` — `result-fabric.json` is STALE, still naming
  the 06:58 run, and one stage has no artifact. The fabric role never completed
  end to end because stage 50 aborted at its convergence gate; `60-auth` and
  `98-spot-rebuild` have still never run. The fabric is converged; the ROLE has
  not recorded a clean finish.
- `provenance` / `host-pull` — SELF-INFLICTED. `repair_kernel_addrs.sh` was
  copied onto the fabric host while unpushed, and 4 docs commits were pushed that
  the hosts have not pulled.

To close them: land `t88` and `repair_kernel_addrs.sh`, sync both hosts, then run
`deploy.sh --from 60-auth` so the role writes a clean result. None of that
changes fabric state.
