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

---

# ADDENDUM — S2 + EVPN attempt, same day: LOST to a substrate limit (D7)

The D6 fix was carried onto a fresh disposable host and the run reached the
config push before the HOST's own networking failed. **No EVPN measurement was
obtained.** D6 remains unproven at integration; it is not disproven either.

## What was established before the loss

    reset            984 stale objects cleared
    seed             14150 objects — 106 switches, 152 hosts, 3332 links
                     SoT verified 258/258 devices, 3332/3332 cables   GATE-PASS
    boot             106/106 SONiC guests healthy
    D6 delivery      44 manifest.json written under the push's artifact root
                     (ZERO existed on the previous run — the fix demonstrably works
                     as far as delivery goes)

## D7 — networkd-dispatcher does not scale to S2's interface count

S2's 3332 links mean ~6664 veth interfaces. Measured from the serial console:
**highest ifindex 8141, and 1652 "reloading interface list" storms.**

    networkd-dispatcher: ERROR: Unknown interface index 7013 seen even after reload
                         WARNING: Unknown index 6566 seen, reloading interface list
                         (a new PID per event, hundreds per second)

It reloads its ENTIRE interface list on every netlink event and spawns a process
each time. At this interface count it never converges. It starved the host's own
networking: `169.254.169.254` (link-local metadata) became `network is
unreachable` at 18:26:37 and sshd stopped answering, while the instance stayed
RUNNING. Not OOM (memory held at 443/503 GB), not neighbour-table overflow, not
conntrack exhaustion — all three checked and absent.

The previous S2 run survived this marginally; this one, with the D6 fix adding
per-device artifact writes and more SSH sessions, crossed the line.

**This is a HOST-side service, not a fabric component.** `networkd-dispatcher` is
not required by containerlab, SONiC or the deploy. The obvious mitigation —
untested — is to mask it on the qualification host before deploying at S2 scale.
That is a one-line host provisioning change, NOT a fabric or platform change.

## Cost and disposition

~2h20m on one disposable host, deleted; A4 HOST TEARDOWN VERIFIED, independently
confirmed 0 instances / 0 disks. Frozen S1 untouched throughout — different host,
different mgmt range, never contacted.

Three of my own errors cost ~15 minutes before the real run started, all caught
by gates rather than by damage: an unquoted heredoc emptied NETBOX_URL (the stage
REFUSED rather than defaulting to loopback), the same heredoc emptied PROFILE so
the seed built s0-64 (the gate caught 43/43 against an expected 258/258), and the
fix for both was to stop generating scripts with unquoted heredocs and pass
values as arguments instead.

## Status

    D6   fix built, host-free proven (t90 5/0, RED without it). Integration
         evidence NOT obtained. Still the sole blocker to a COMPLETE S2.
    D7   NEW. networkd-dispatcher storms at ~6664 veths and kills host
         networking. Blocks any S2-scale vm-fidelity run until mitigated.

S2 at L3 remains qualified from the earlier run (3728/3728). Nothing about that
result is affected by this attempt.

---

# ADDENDUM 2 — 2026-09-07: D7 PROVEN, D6 REFUTED as a plumbing problem

Full S2 run on a disposable `n2-highmem-64` with both fixes carried. Host deleted;
teardown verified. Frozen S1 untouched.

## Result

    c12 VERDICT: OK      rc=0, 254 device(s) configured, ~2h15m deploy
    BGP                  3728 / 3728 established, 0 unreadable
    EVPN                 0 / 0                      STILL ZERO

## D7 — PROVEN

Masking `networkd-dispatcher` at provision time held. The host survived the entire
deploy where the previous attempt lost its networking at 66 minutes. The readiness
marker refuses unless the mask is confirmed, so this cannot silently regress.
BGP 3728/3728 shows the mask broke nothing.

## D6 — the fix was necessary but NOT sufficient, and the diagnosis was incomplete

The artifacts were delivered correctly. Measured on `dc1-pod002-fr-leaf03`:

    artifact manifest declares   VLAN, VLAN_INTERFACE, VXLAN_EVPN_NVO,
                                 VXLAN_TUNNEL, VXLAN_TUNNEL_MAP
    artifact config_db           1 VXLAN_TUNNEL entry
    ON THE BOX                   VXLAN_TUNNEL empty, VLAN empty,
                                 l2vpn evpn lines 0

And the push is not broken -- it applies what it builds:

    box BGP_NEIGHBOR   51 entries
    box INTERFACE     104 entries

**ROOT CAUSE, corrected.** `deploy_switch` builds the config it pushes from its
OWN intent derivation -- interfaces, loopbacks, BGP neighbours -- and pushes that.
The rendered artifact is consulted only for the SKIP and VERIFY decisions
(`artifact_config_for()`, as ownership()'s docstring states), NEVER as a source of
config. So the artifact's feature tables cannot land through this path no matter
how correctly they are delivered. Delivering the manifest changes what may be
REMOVED (the drop floor); it does not change what is WRITTEN.

This is the SAME second-derivation shape as D4, one level up: the render and the
push each derive device config independently, and the push's derivation has no
concept of the EVPN feature layer.

## Why this stops here

Closing D6 now requires ONE OF:

  a) `deploy_switch` merging the rendered artifact's feature tables into what it
     pushes -- a change to how config is applied for EVERY device in EVERY fabric;
  b) the unit path serving artifacts over ZTP and letting switches self-provision
     -- which is how S1 obtained EVPN, and what deploy.sh calls "the real product
     path".

Both are design decisions with real blast radius, not plumbing. The agreed scope
was to invoke the existing EVPN layer, not to change how configuration is applied,
so this stops and reports rather than pushing through.

**The delivered-artifact change is not wrong and is not harmful** (BGP unaffected
at 3728/3728), but it does NOT close D6 and must not be promoted as though it
does.

## Status

    D6  OPEN. Diagnosis corrected: not a delivery gap, a derivation gap. Still
        the sole blocker to a COMPLETE S2. Needs a design decision (a) or (b).
    D7  CLOSED pending promotion -- proven on this run.

S2 at L3 remains qualified: 258/258 devices, 3332/3332 cables, 3728/3728 BGP.
