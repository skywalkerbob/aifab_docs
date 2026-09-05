# S1 rebaseline window, 2026-09-05 — STOPPED CLOSED at stage 50

**Status: the rebuild FAILED and the window is stopped closed. Nothing is being
retried. The fix exists and is HELD, unpushed, on `gpufab-network` branch
`render-rrev-fix` (`c9c6b83`).**

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
