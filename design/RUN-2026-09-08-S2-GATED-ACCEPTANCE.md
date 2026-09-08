# RUN 2026-09-08 — S2 accepted through c12 --ztp with the post-provision gate

Immutable record. One disposable host (`gpufab-a4-01`, n2-highmem-64), profile
`s2-1024.yaml`, management relocated once to 172.28.0.0/22 and that single
relocation used by BOTH the NetBox seed and c12 — so the fabric's addresses and
the SoT's cannot drift apart.

**S1 was not touched.** Every command addressed the disposable host.

## What is new since the 2026-09-07 S2 run

* The source of truth is **NetBox**, not the profile. The earlier S2 acceptance
  proved profile -> ZTP -> box; this one is the product path.
* `c12 --ztp` now ends in a **synchronous post-provision gate** whose verdict is
  the run's verdict.

## The gate, as it ran

    ==    post-provision gate: units dc1-pod001 dc1-pod002 core
    ==    1/3 waiting for ZTP success on manifest R's device set
    ..    waiting for ZTP SUCCESS on 106 device(s) from manifest R
    ..    ZTP SUCCESS 100/106  pending 5  failed 0  unreadable 1
    ..    ZTP SUCCESS 106/106  pending 0  failed 0  unreadable 0
    ==    2/3 reconciling the EVPN address family (once)
    ..    speakers  : 10
    ..    correct   : 10  dc1-pod001-fr-leaf01 … dc1-pod002-fr-spine02
    ..    repaired  : 0
    ..    FAILED    : 0
    ==    3/3 t92 postconditions
    ..    t92 dc1-pod001   15 passed  0 failed
    ..    t92 dc1-pod002   15 passed  0 failed
    ..    t92 core          1 passed  0 failed  1 skipped (no VTEPs — NOT APPLICABLE)
    ..    POST-PROVISION GATE: PASS
      c12 VERDICT: OK

The first poll is the point: **100/106 with one device unreadable**. The gate
waited rather than proceeding on a partial set, which is the whole difference
between "the switches fetched their config" and "ZTP succeeded". A fetch count
would have read 106/106 and moved on.

Scope came from manifest R (`<unit>.plan.json`), not from listing the served
directory. Identities are reported, not counts.

## The former in-ZTP guard was NOT exercised

It no longer exists. A ZTP plugin section placed after `01-configdb-json` cannot
fetch its own plugin — applying the config moves eth0 into the `mgmt` VRF while
ZTP's downloader stays in the default one — and with `halt-on-failure` it put a
fabric into a 300s retry loop. **The protection is this gate: reconciliation
plus its measured postcondition.** Nothing here should be read as evidence for
the removed section.

Note that the reconciler reported **0 repaired** on this run. That is the
expected shape: D8 is an intermittent race, and a clean run does not exercise
the repair path. The repair is evidenced separately, on 2026-09-07, where a
speaker was deliberately put into the D8 state and repaired to a converged
overlay.

## Two defects this run found, both mine

* **The NetBox credential never reached the renderer.** Every unit refused with
  `403 Forbidden: Authentication credentials were not provided`.
  `deploy/lib.sh:153` already states the rule (NETBOX_TOKEN falls back to
  `$SECRETS/netbox_token`), but serve.sh does not source lib.sh so nothing in
  the c12 chain applied it. The refusal was correct and its *diagnosis* was not:
  "NetBox is not usable" blamed a healthy SoT for a caller's omission. Now the
  token is taken by the same rule, and `--sot netbox` with no token anywhere
  refuses before making a request that cannot succeed.
* **c12 cannot be re-run over an existing ledger.** A second run acquires rather
  than adopts, so it fails against its own previous resources. The supported
  path is `--recover` then a clean deploy, which is what this acceptance did.

## What this run does NOT establish

* **The repair path.** 0 repaired here; see the 2026-09-07 record.
* **A unit rebuild.** `--deploy-unit` scoping and the untouched-unit proof are
  covered host-free by t95; no rebuild was run at S2 scale.
* **Repeatability.** One run.
* **Sampling.** t92 samples VTEPs per unit; it does not read all 106 switches.
