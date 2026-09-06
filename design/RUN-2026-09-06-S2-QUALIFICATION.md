# S2 qualification run — 2026-09-06

**IMMUTABLE RUN RECORD.** Measurements from one execution. Not a design document
and not to be revised: a later run gets a later record.

## Verdict

**S2's L3 fabric is qualified. S2 is NOT complete.** The EVPN feature layer was
never applied (D6), so the overlay half of the design is unexercised.

Frozen S1 was untouched throughout and re-verified ADMIT afterwards.

## Contract, fixed BEFORE execution

Expectations were derived from the frozen model with no infrastructure running,
then compared against the run. Nothing was added to the checklist afterwards.

| criterion | derived | measured | |
|---|---|---|---|
| S1 devices absent from S2 | 0 | 0 | PASS |
| S1 device identities changed | 0 | 0 | PASS |
| S1 links absent from S2 | 0 | 0 | PASS |
| S1 interface assignments moved | 0 | 0 | PASS |
| SoT devices | 258 | 258/258 | PASS |
| SoT cables | 3332 | 3332/3332 | PASS |
| BGP peer series established | 3728 | **3728/3728**, 0 unreadable | PASS |
| EVPN peer series | 32 | **0** | **FAIL (D6)** |

Identity comparison covered name, loopback, ASN, mgmt address, role and tier for
all 124 S1 devices, and both interface assignments for all 1466 S1 links.

## Structure

S2 decomposes into three unit labs:

    dc1-pod001    124 devices    identical to the entire running S1 fabric
    dc1-pod002    124 devices    the new pod
    core           10 devices    the new core tier joining them
                  ---
                  258           = the derived total

+134 devices and +1865 links over S1, with every pre-existing device and link
unchanged. That is the answer to "can 512 extend to 1024 without changing the
existing unit": **yes, for topology, addressing, identity and L3.**

## Substrate

One disposable `n2-highmem-64` (64 vCPU, 503 GB) plus its own seeded NetBox.
106 SONiC VS guests at `fidelity: vm`, 264 containers total, 443 of 503 GB used.
Cost profile, measured: ~60 min for all 106 guests to reach healthy, then the
config push, ~3 h wall clock end to end.

The model's default placement asks for 2 × `n2-highmem-32` and reports
`cross_links=200`. At `host_ram_gb=512` placement collapses to ONE host with
`cross_links=0`, which is why this ran single-host and why no multi-host
substrate work was required. See MULTI-HOST-FABRIC.md.

## D6 — the EVPN feature layer is not applied by the unit-lab path

Measured on a frontend leaf (`dc1-pod002-fr-leaf01`, 172.28.1.76):

    VXLAN_TUNNEL           empty
    VLAN                   empty
    l2vpn evpn lines        0
    l2vpn evpn peers        0 / 0 across all 106 switches, 0 unreadable

EVPN is not DOWN — it was never configured. `c12`/`unit_configure` applies base
BGP and interfaces; EVPN activation lives in the monolithic pipeline's
`56-evpn-persist` / `40-evpn-activate`, which the unit path does not run. The
profile does declare it (`features.evpn.fabrics: [frontend]`, `anycast_gw: true`)
and `expected.py` derives 6 VTEPs and 32 EVPN peer series for S2.

This is a DEPLOY-PATH gap, not an S2 design defect — the same shape as D4, where
configuration existed in one pipeline and not the other.

## Two instrument errors, recorded because they cost time

- The monolithic path was tried first and refused immediately: *"nodes span 3
  mgmt subnets but a containerlab topology has one mgmt network"*. S2 carries
  three mgmt /24s (pod001, pod002, core); one lab cannot hold them. The refusal
  was correct and cost 20 seconds rather than a 90-minute failed build.
- The first BGP probe used `docker exec`, which under vrnetlab reaches the
  WRAPPER, not the SONiC guest. It returned "106 unreadable". Because the probe
  refuses to score unreadable as zero, this surfaced as a broken instrument
  instead of a fabric catastrophe. Switches are readable only over SSH to their
  mgmt address.

## Defect status at the close of this run

| | | |
|---|---|---|
| D1 | exporter reads 0 against a converged dataplane | backlog — NOT an S2 gate |
| D2 | stale kernel addresses, re-adding agent unidentified | backlog — NOT an S2 gate |
| D3 | stale `result-fabric.json`; the 2 pinned failures | backlog — NOT an S2 gate |
| D4 | compute nodes carrying transit | **CLOSED** — qualified FAIL 6/6 -> PASS 6/6 on s0-64, promoted |
| D5 | disposable host could not run `deploy.sh` | **CLOSED** — real git checkouts via bundles, promoted |
| D6 | EVPN feature layer unapplied by the unit path | **the sole active S2 blocker** |

The host-config comparison gap — nothing compares a HOST's running config to what
was rendered for it, `t11` covers switches only — remains backlog. It is why D4's
first fix was complete, tested, green and inert.

## S1 untouched — proof

Different host, different mgmt range (`172.28.0.0/22`, relocated to avoid
colliding with the live OOB). After teardown, `tests/admit-experiment.sh`:

    ok  gpufab-ops-01     on the frozen behavioural platform
    ok  gpufab-fabric-01  on the frozen behavioural platform
    ADMISSION: ADMIT

Disposable host deleted; `A4 HOST TEARDOWN: VERIFIED`, independently confirmed
0 instances and 0 disks.

## Next bounded objective

Apply the existing EVPN feature layer through the unit-lab configuration path and
rerun the disposable S2 EVPN acceptance. Do not reopen S1. Do not investigate
unrelated backlog during that work.
