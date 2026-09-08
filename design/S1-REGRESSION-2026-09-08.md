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

## Proposed repair — NOT RUN

1. **Capture forensics FIRST, because the repair destroys them.** The stale
   addresses are the only surviving evidence of how they got there, and this is
   a second occurrence of an unexplained mechanism. Before deleting anything:
   full `ip -4 addr`, `ip route`, CONFIG_DB, and syslog/intfmgrd around the
   container restart, from both leaves, off the box.
2. `DRY_RUN=1 deploy/repair_kernel_addrs.sh dc1-pod001-fr-leaf01` and the same
   for fr-leaf03 — prints what it would remove, changes nothing. Confirm the
   printed set is exactly the 46 and 45 addresses the artifact does not name.
3. Apply to those two devices ONLY. Surgical deletion of the addresses the
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
