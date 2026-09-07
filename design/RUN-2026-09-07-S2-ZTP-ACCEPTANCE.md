# RUN 2026-09-07 — S2 (1024 GPUs) accepted through the ZTP unit path

Immutable record. Host `gpufab-a4-01` (disposable, n2-highmem-64, us-central1-a,
8h TTL), profile `s2-1024.yaml`, management relocated by c12 to 172.28.0.0/22.

**S1 was not touched.** Every command addressed `gpufab-a4-01`. No S1 host was
contacted; the frozen pins are unchanged.

## What was built

    258 devices, 106 switches, 3 lifecycle units, 3 ZTP servers
    dc1-pod001  124 devices   ztp 172.28.0.4
    dc1-pod002  124 devices   ztp 172.28.1.4
    core         10 devices   ztp 172.28.2.252   <- relocated, see below

`c12 --ztp` (new mode) skipped the interim push configurer entirely and served
instead, so the switches self-provisioned from the rendered artifacts — the same
product path that produced S1's EVPN, which is what the 2026-09-06 run did not
use.

## Self-provisioning

    dc1-pod001  48/48
    dc1-pod002  48/48
    core        10/10
    ------------------
    total      106/106 config_db fetched

and the host's own networking stayed reachable throughout (`net=OK` on every
poll) — the thing that killed the first attempt.

## Acceptance, on the boxes

`t93` (served tree, all three units, render time): **7 passed, 0 failed**,
negative control fires (10 dangling references detected when identity_guard.sh
is removed).

`t92` per unit, after convergence:

    dc1-pod001   15 passed  0 failed
    dc1-pod002   15 passed  0 failed
    core          1 passed  0 failed  1 skipped — NOT APPLICABLE (carries no VTEPs)

Per pod:

    on-box EVPN tables vs rendered artifact   equal on 3/3 sampled VTEPs
    EVPN peerings configured                  10   (0/0 fails here by construction)
    EVPN peerings established                 10 / 10
    VTEPs with NO EVPN peerings at all        0
    remote VTEPs per VTEP                     matches its EVPN domain exactly
    tenant dataplane                          gpu0001 -> gpu0002 forwards
    negative control                          a corrupted VXLAN_TUNNEL IS detected

## Convergence is not a defect, and was not reported as one

The first measurement, taken ~1 minute after the last switch fetched its
config, showed 7/10 and 9/10 peerings established and two VTEPs one remote VTEP
short. Twelve minutes later both pods were 15/15. The partial state was recorded
as measured and re-measured rather than explained away — and the assertions that
caught it are per-device, which is what makes "2 of 3 established" legible
instead of hiding inside a fabric-wide total.

## What this run establishes

* D6 is closed at S2 scale, not only on a micro fixture.
* Multi-unit ZTP serving works: three units, three subnets, three servers, no
  cross-contamination, every declared address answering.
* D9's fix holds at the scale that broke the host without it.
* The core shard's relocated management address (.252) is served and used end
  to end — the collision fix is not merely derivable, it is in production use
  here.

## What it does NOT establish

* **Cross-VTEP forwarding across pods.** The model puts each pod's VTEPs in
  their own EVPN domain (its transits are the pod frontend spines, not the
  core), so no cross-pod overlay path exists in this topology to test. The
  tenant check is within-unit by necessity, not by omission.
* **Repeatability.** One run. D8 (a VTEP whose FRR lacked the EVPN
  address-family despite correct config_db) did not recur here, and one clean
  run does not establish that it will not.
* **The push path.** `--ztp` skips it. Nothing here says the interim push
  configurer now produces EVPN; it is simply not the path used.
* **Sampling.** t92 sampled 3-4 VTEPs per unit, not all 106 switches.

## Two things that had to be repaired mid-run, both mine

* `stage00 rc=100` — the GCE image's `cloud-sdk` apt repo failed its GPG check,
  so stage 00 aborted before creating the venv, and the driver PRINTED the
  non-zero rc and carried on. The first serve attempt then failed all three
  renders ("served tree has no device directory to ask for") because
  `serve.sh` runs the renderer with `$VENV/python`. Repaired by disabling the
  broken repo and rebuilding the venv with `--system-site-packages`; serving
  then returned 3/3.
* A `sleep 3` in `serve.sh`'s self-test is not enough for the server container
  to install dnsmasq and answer, so its own self-test printed `http DOWN` for
  units that were fine. The bounded retry added earlier reported all three as
  `OK`. The self-test's message remains misleading and is worth fixing.
