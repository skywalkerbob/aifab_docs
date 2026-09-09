# S1 regression 2026-09-08 — D2 recurrence on two frontend leaves

**Status: READ-ONLY INVESTIGATION COMPLETE. S1 NOT MUTATED.** One causal
boundary identified; a repair is proposed below and has not been run.

S1 is no longer experiment-admitted. The code freeze is intact; the RUNTIME has
drifted from its accepted state.

## What the suite measured

`tests/verify.sh --sot 10.10.0.20 --host gpufab-fabric-01 --ops gpufab-ops-01`
— 96 phases, 2457 assertions passed, 25 failed, 10 phases failing.

Accepted 2026-09-05: **1464/1464 BGP, 16/16 EVPN**. Now:

    BGP sessions ESTABLISHED (ipv4 unicast) : 1371, expected 1464   (93 short)
    EVPN sessions ESTABLISHED               :    6, expected 16
    devices with the l2vpn evpn AF up       :    4, expected 5
    switches unreachable                    :    0

`switches unreachable: 0` is what makes this the fabric rather than the probe.
t13 adjudicated 260/260 sessions exporter-vs-device with zero measurement
artifacts, and every down session reports **`uptime=never`** — they did not
flap, they never came up.

## Where

`tests/probes/down_adjacencies.sh` over all 48 switches, 0 unreadable:

    dc1-pod001-fr-leaf03   46        93 ipv4Unicast
    dc1-pod001-fr-leaf01   45         6 l2VpnEvpn
    dc1-pod001-fr-spine02   4        75 Active/never, 16 Connect/never
    dc1-pod001-fr-spine01   4         8 Connect, uptime 2d07-08h

Entirely within pod001's frontend fabric.

## Why — D2, recurring

`t88-kernel-address-truth` over 46 switches, 0 unreachable:

    FAIL dc1-pod001-fr-leaf01: 46 kernel address(es) the artifact does not name
                               — STALE LAYOUT STILL BOUND
    FAIL dc1-pod001-fr-leaf03: 45 kernel address(es) the artifact does not name
    FAIL route to 10.128.0.114 egresses Ethernet36, render assigned Ethernet28
    FAIL route to 10.128.0.152 egresses Ethernet40, render assigned Ethernet32
    FAIL route to 10.128.0.234 egresses Ethernet44, render assigned Ethernet36
    PASS switches missing a rendered address in the kernel: 0

t88 flags **exactly** the two devices carrying the down adjacencies. The egress
is consistently **+8 ports** from the rendered assignment — the pre-rebaseline
layout, still bound, with the kernel choosing it. The spines' 4 sessions each are
the FAR ENDS of these leaves' adjacencies; t88 passes on both spines, so they are
collateral, not independently broken.

The contrast with the unaffected leaf is the proof:

    device                 Ethernet addrs   bgp container   verdict
    dc1-pod001-fr-leaf01              98    Up 2 days       46 stale
    dc1-pod001-fr-leaf03              97    Up 2 days       45 stale
    dc1-pod001-fr-leaf02              52    Up 3 days       clean

leaf02 holds ONE layout; leaf01 and leaf03 hold roughly double — both layouts
bound at once, which is D2's exact description. Host uptime is identical on all
three (3d15h) and the saved config mtime is identical (2026-09-05 08:33), so no
VM rebooted and nothing re-saved. What differs is that the **bgp containers on
precisely the two broken leaves restarted ~2 days ago**, matching the
`Connect 2d07-08h` sessions.

## The causal boundary, and where this stops

**Stale pre-rebaseline addresses remain bound in the kernel on
dc1-pod001-fr-leaf01 and dc1-pod001-fr-leaf03, so BGP OPENs egress the wrong
physical port.** That is one boundary and the investigation stops there.

What is NOT established: what re-created the stale layout. This is the SECOND
occurrence, and `deploy/repair_kernel_addrs.sh`'s own header already recorded the
mechanism as unresolved after the first — "intfmgrd logged EEXIST ~47s AFTER
syncd recreated the interfaces, i.e. something re-added the old addresses and we
have not identified it". A bgp container restart is correlated with this
occurrence; correlation is not the trigger.

## Forensics captured 2026-09-09, BEFORE any repair

Archive: `d2-forensics-20260908T235909Z.tgz` (872 KB, 39 files), pulled off the
box, covering both affected leaves AND the clean control.

**The fault is duplicate (interface, address) BINDINGS, not foreign addresses:**

    leaf01  101 pairs / 55 distinct addrs / 55 named  -> 46 STALE pairs
    leaf03  100 pairs / 55 distinct addrs / 55 named  -> 45 STALE pairs
    leaf02   55 pairs / 55 distinct addrs / 55 named  ->  0   (control)

    10.128.0.115  bound on Ethernet36 AND Ethernet28   artifact names Ethernet28
    10.128.0.153  bound on Ethernet32 AND Ethernet40   artifact names Ethernet32

The same address is bound twice — on the rendered port and on the pre-rebaseline
port 8 higher. The kernel picks a connected route arbitrarily, so the OPEN can
leave the wrong physical port.

**The trigger event**, recovered from `syslog.1` (the live syslog no longer
reaches it): a graceful service-stack restart at **2026-09-06 14:46-14:49** on
both affected leaves and NOT on the clean one — swss daemons stopped by SIGTERM,
then swss/syncd/bgp/teamd all started 14:48:57-14:49:01 with `restarts=0`, while
`database` still dates from the 09-05 deploy. And on the way back up:

    14:49:15.121 ERR  intfmgrd: setIntfIp: '/sbin/ip address add 10.128.10.9/31
                                dev Ethernet0' failed with rc 2
    14:49:15.126 INFO intfmgrd: RTNETLINK answers: File exists

intfmgrd found addresses ALREADY BOUND when it came up.

**A hypothesis raised and REFUTED.** If the saved `/etc/sonic/config_db.json`
held the pre-rebaseline layout, every reload would reintroduce it and the repair
would not survive the next one. It does not: saved and artifact agree on all
three leaves (52 INTERFACE pairs each, identical entries). The repair is
therefore not defeated by a reload replaying a stale saved file.

**Still NOT established** — and this is where the investigation stops — is how
the pre-rebaseline bindings came to be present at 14:49 on 09-06, given they had
been removed on 09-05 and the fabric then measured 1464/1464. The reload is
correlated on both affected leaves and absent on the clean one; the mechanism
that re-created the old layout is not identified.

## Dry-run of the proposed repair — RUN, NOTHING CHANGED

`DRY_RUN=1 deploy/repair_kernel_addrs.sh dc1-pod001-fr-leaf01 dc1-pod001-fr-leaf03`
(host copy byte-identical to the committed one, sha256 1a6d41e684ae841c):

    dc1-pod001-fr-leaf01: kernel=98  rendered=52  NOT-IN-ARTIFACT=46
    dc1-pod001-fr-leaf03: kernel=97  rendered=52  NOT-IN-ARTIFACT=45
                                              total to delete: 91

Four independent measurements agree on the same set: t88 (46/45), the forensic
distillation (46/45 stale pairs), the down-adjacency probe (45+46 sessions on
these leaves, +8 collateral on the spines), and this dry-run.

## Proposed repair — NOT RUN

1. ~~Capture forensics first~~ — DONE, see above. Archive retained off-box.
2. ~~Dry-run~~ — DONE, see above. 91 addresses, matching all other measurements.
3. **Remaining step, NOT run: apply to those two devices ONLY.** Surgical deletion of the addresses the
   artifact does not name — NOT `config reload`, which is what produced the
   state and whose outcome is not understood.

## Scoped verification of the repair

Per device, before and after, and nothing wider:

* `t88` on the two devices: `addresses the render never assigned` 46/45 -> 0,
  and `missing a rendered address` stays 0.
* `ip route get` for the four named neighbours egresses the RENDERED port.
* `down_adjacencies.sh`: the 91 sessions on these two leaves reach Established;
  the spines' 8 collateral sessions follow.
* Fabric totals return to **1464/1464 BGP and 16/16 EVPN**.
* Re-run the affected verify phases (fabric, peer-truth, vtep-truth, anycast-gw,
  mgmt-route) and require the pinned expected-failure set to be unchanged.

## Explicitly out of scope

* The 57-commit distance from main is EXPECTED and is not an upgrade trigger.
  No sync.
* `snmp container restarted (StartedAt moved): observed 0` is **UNKNOWN /
  NOT-MEASURED**, not a pass and not a failure of the thing itself. It does not
  weaken the independently measured routing failure.
* Unrelated backlog is not investigated.
