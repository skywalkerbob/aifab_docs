# Two-host slice — the acceptance contract, written before the run

**Status:** DESIGN. No implementation authorized by this document.
**Date:** 2026-10-05
**Supersedes for this purpose:** nothing. `MULTI-HOST-FABRIC.md` (rev 9, "NOT
APPROVED, not authorized for implementation") remains the architecture document;
this is the narrower question of what a two-host *acceptance run* must assert and
what has to exist first.

---

## 1. The decision this run makes

| | |
|---|---|
| **DECISION** | does the cross-host transport MECHANISM work — per-link identity, MTU, dataplane, lifecycle — on two hosts? |
| **OBSERVABLE** | every cross-host link's tunnel identity matches the model, on the box; frames at both MTU boundaries; BGP/EVPN established across the boundary; a tenant forward that traverses it; teardown of one host leaving the other untouched |
| **OUTCOME** | PASS → the full five-host S3 build becomes considerable. FAIL → the named leg. VOID → could not be measured; never a pass. |

**Not in scope:** density (settled at 0.625 for one pod on n2-standard-80), the
0.75 bound (S1 calibration), any baseline or pin, and the full five-host build.

## 2. The slice, derived not chosen — and NOT the obvious one

**A 2-pod derivation of s3-4096, pinned to `n2-standard-96`, on two hosts.**
Measured contract:

| | |
|---|---|
| hosts | **2** |
| switch VMs per host | **60** (50 pod + its share of a distributed core) |
| tenant endpoints per host | **118** `frr-host` + 1 head |
| cross-host links | **200** |
| switches total | 120 |
| BGP peer series | 5332 |
| density | **0.625 VM/vCPU** — the already-qualified point |

### Why not the obvious slice

S2-1024 already places as two hosts, so it looked like the free answer. It is
not, and the reason is worth stating because it would have cost a paid run:

    place(s2-1024):  host-pod001  {sonic-vm: 96, frr-host: 150, head: 2}
                     host-core01  {sonic-vm: 10}

**`host-core01` holds no tenant endpoints at all.** Every GPU, CPU and storage
container is on the pod host. A tenant forward therefore *cannot* straddle the
boundary on an S2 pod+core slice — there is nothing on the far side to forward
to — and neither can a VTEP pair, since VTEPs are pod leaves. Such a slice can
prove transport, per-link identity, MTU, the underlay and the EVPN control
plane, but **not** leg 3's cross-host tenant dataplane.

S3 is different because **its core is distributed**: every one of its five hosts
carries 54 switches (pod plus a share of the core) *and* 118 tenant endpoints. A
2-pod derivation therefore gives two hosts that each hold tenant endpoints, core
switches, and both ends of a straddling path — a self-contained fabric with no
dangling uplinks, which is what makes every derived expectation exact.

### Why `n2-standard-96`, and this is the load-bearing part

On `n2-standard-80` the 2-pod slice lands at **60/80 = 0.750 VM/vCPU** — exactly
the bound that has **never** been validated on this family. Running the
transport experiment there would confound two questions: a failure could be the
cross-host path or the untested density, and nothing in the result would
separate them.

`n2-standard-96` puts the same slice at **60/96 = 0.625**, the density already
qualified by the eight-run probe. Density is then held at a proven value and the
only new variable is the transport, which is the whole point of the run.

    n2-standard-80   60/80  = 0.750   AT the unvalidated bound  — rejected
    n2-standard-96   60/96  = 0.625   the qualified point       — chosen
    n2-standard-128  60/128 = 0.469   further inside, more cost — unnecessary

### Generation

Per unit, with `--host` and `--fabric-hosts`, one lab per unit — the existing
`c12` architecture. A shard holding more than one management subnet is refused
outright, measured:

    nodes span 2 mgmt subnets (['172.20.0.0/24', '172.20.1.0/24']) but a
    containerlab topology has one mgmt network — pod mgmt must be routed before
    a host can hold pods from different subnets

That is `MULTI-HOST-FABRIC.md` §3's unresolved management projection. One lab per
unit sidesteps it by construction rather than waiting for it.

The fixture is generated **by script from s3-4096** with every substitution
asserted — `pods.count 5→2`, `addressing.envelope.pods 35→2`, and
`placement.fleet_machine → n2-standard-96` — the same precedent as
`n2probe-1pod.yaml`. A hand-written "equivalent" would make the thing measured
differ from the thing planned.

**A checked assumption:** `_shard()` calls `place(model)` with no `host_vcpu`
while the density path passes one. They agree at every rung because `place()`
derives `host_vcpu` from the model's own `fleet_machine` when it is not given —
one derivation, with an explicit refusal for the RAM-only case. The emitter and
the planner therefore cannot disagree about placement.

## 3. Leg 1 is already PROVEN, host-free — and it found a real defect

Per-link identity is a pure function of R, so it needed no host at all.
`tests/t108-cross-host-vni.sh` (34 assertions) now holds:

* every crossing link at every rung gets a **distinct** VNI (s2 400, s3 800, s4 2000, s5 6800)
* the key is **R's names**, order-independent, so a verifier can recompute it
* the assignment is identical **in a separate process** — two hosts, no coordination
* **both ends agree**: all 200 shared VNIs match between the two generated shards, 0 missing
* every emitted tunnel's VNI equals the value **recomputed independently from R**
* UDP **14789** on every tunnel; each end declares only its own endpoint
* the tunnel endpoints are mirrored (`.30` ↔ `.31`)

**The defect it found.** `_vni()` hashed each link *alone* into a 16,000,000-wide
space. At s3-4096 — 800 links — two of them collided:

    VNI 13598403   dc1-pod001-bk-p1-spine02 <-> dc1-ba-core002
                   dc1-pod003-bk-p1-spine01 <-> dc1-ba-core015

Two point-to-point links on one VNI is a shared broadcast domain across the
substrate: each end receives the other's frames. This is the exact miswiring
`MULTI-HOST-FABRIC.md:663` says a count can never detect — "eight parallel
spine-core links can be cross-connected to each other and every count stays
correct" — and it would have been emitted silently. Nothing had ever emitted a
cross-host link (no caller passes `--host`; no committed artifact carries one),
so the scheme was still free to change.

Fixed by assigning over the **whole** cross-host set: preferred hash, then a
deterministic probe in sorted-key order, and a **refusal** rather than a map with
a duplicate in it. The independence argument in the old docstring — "both ends
must choose the same number without talking to each other, therefore not a
counter" — has a false conclusion: both hosts hold the same R, so any function of
the whole set is computable identically on each.

The key also moved from the clab `eth{N}` rewrite to R's own names, matching what
`_bridge()` already did and for the reason stated at its emission site: *"only
this form can be recomputed from the manifest."* A gate that checks every
tunnel's VNI against the model **is** that verifier, and it could not previously
recompute one without replicating `port_index()`.

Honest limit: s3's collision is gone because the **key** changed, not because the
probe fixed it — no rung now has a hash collision, so the probe is dead code
against real data and is held only by a forced-collision test. That is recorded
in `t108-red.sh` rather than hidden.

## 4. What the other five legs require that does not exist

Two read-only surveys established this. Citations are to the files.

### The gating problem: the verification layer cannot see a second host

`t92`, `admit-s2-probe.sh` and `unit_fingerprint.sh` all derive their device list
from a **locally served** ZTP tree and reach each switch by its **docker-network
management IP**, over `sshpass ssh`. That address is unroutable from another
machine. **No device row carries a host identity anywhere.** Consequences:

* a remote half is not mis-measured, it is **unreachable** — t92 fails closed
  (`unreadable` → `t_zero` fails), which is the right direction and still means
  it cannot measure half the fabric;
* `SAMPLE=4` over `sorted(os.listdir())` with no caller override means all four
  samples can land on **one** host and the gate reports PROVEN having touched one
  side;
* t92's only dataplane assertion is `docker exec` **local**, and a straddling
  pair degrades to `skip` → `REFUSE`.

**The resolution is per-host execution, not routed OOB.** Routed OOB is the
designed answer and `deploy/oob-profile.sh` refuses N>1 ("needs the per-pod
subnet plan (§5.9 sharding), which is unbuilt"). But nothing requires one place
to reach every switch: run the probe **on each host against its own local
switches** and merge, using the model's `place()['assign']` as the device→host
map — which already exists and is already the authority. The existing transport
is already one `gcloud compute ssh <host>` per gate; it needs to loop over hosts
instead of taking a scalar. The merged gate then asserts the totals against the
model **and** that both halves were actually measured, so a one-sided pass is
impossible.

This also makes the cross-host dataplane measurable **on the slice chosen in
§2, and only on that one**: `docker exec` on host A, pinging a **tenant overlay
address** on host B taken from the model. The target is a fabric address, not a
docker management address, so it is routable through the fabric iff the fabric
works — which is the thing under test. On an S2 pod+core slice it would not be
measurable at all, because the core host holds no tenant endpoint to forward to;
that is why §2 does not use the slice that was free.

### Per leg

| leg | what exists | what must be built |
|---|---|---|
| 1. per-link identity, UDP 14789 | **PROVEN host-free** (t108) | an on-box assertion that the live tunnel set matches R per link — `reconcile.py` checks endpoint presence only, never VNI, remote IP or port |
| 2. both MTU boundaries + adjacent failures | `t58-mtu-headroom.sh` asserts only the **local** plane and prints the cross-host deficit | a DF probe. t58 declines one because "the host containers ship busybox ping, which does not honor `-M do`" — the SONiC switches have a full `ping`, which is the way out. No `mtu` key exists in any profile; the 8896/8846/8796 numbers live only in prose |
| 3. cross-host BGP/EVPN dataplane | per-switch BGP/EVPN counting is sound (`admit-s2-probe.sh`) | per-host execution + merge; a straddling tenant forward; host-stratified sampling with an assertion that both hosts were sampled |
| 4. ownership-safe teardown and recovery | a5/a6 prove survivor identity, bridge survival, ledger releasability and **zero-loss forwarding across a release** — all declared "RUNS ON THE DISPOSABLE HOST", all local | `Resource` has **no host field**; ledger lines are `{kind,name}`; identities are host-local (`ifindex`, docker IDs); names are deterministic, so **one shared ledger would refuse its own cleanup** and two separate ledgers give no mutual exclusion. `HostLock` is a local flock and `_LOCK_HELD` is process-local |
| 5. `host_harden.sh --assert` after interfaces exist | the assert already does the right thing **when devices exist**; gate 1c can only check the drop-in file pre-deploy, and says so | call it again post-deploy, per host, when several hundred veths exist. Run 7 logged 425 `systemd-networkd … veth` events, so D9's effect at scale is still unproven |
| 6. honestly bounded convergence timestamps | `_phase_emit` exists, **already carries a `host` field**, and `tools/phases.py` already filters by `--host`; `t16` asserts the instrumentation ran | the **unit path emits nothing** — no timing in `unit_executor.py`, `c12-unit-labs.sh`, `ztp_wait.sh`, `postprovision_gate.sh`. The shape is there; it is not called |

### The slice could not be NAMED, and that is now fixed

`_shard()` built the physical host names from the literal
`f"gpufab-fabric-{i+1:02d}"`, written out twice in one function. `--host` on any
other name **refuses loudly** — `rc=1`, naming the valid hosts, writing nothing
— so this was never a silent failure. The problem is narrower and worse: the
only addressable two-host slice was `gpufab-fabric-01` + `gpufab-fabric-02`, and
**`gpufab-fabric-01` is the live S1 fabric host, RUNNING**. A disposable
cross-host slice could not be named without pointing at production.

Fixed: `--fabric-hosts a,b` names them, derived once, defaulting to today's
values — verified **byte-identical** output for every existing caller. A list
that does not cover the placement is a refusal (devices with nowhere to go), and
so is a duplicate name (two logical hosts on one machine would make a
"cross-host" link local while still calling it cross-host). Both ends still
agree on all 200 VNIs under custom names.

### Substrate — the user's to apply

Absent from terraform entirely, and all three are prerequisites:

* a **second NIC** on the fabric hosts (`terraform/fabric.tf:126` has exactly one `network_interface`)
* a **fabric VPC at MTU 8896**
* a firewall rule allowing **UDP 14789, destination only**, between fabric hosts. Nothing today permits fabric↔fabric UDP; `sims.tf` denies cross-sim udp/icmp outright

`terraform apply` is the user's to run.

## 5. Sequencing — host-free first, then ONE paid run

Everything in stage A is free and must land first, because a paid two-host run
that cannot observe half its fabric measures nothing.

**Stage A — host-free, no instance:**
1. ~~per-link identity + VNI uniqueness~~ — **done** (t108, 34 assertions; t108-red)
2. a device→host map from `place()['assign']`, threaded into the probes
3. per-host probe execution and merge, with a both-halves-measured assertion
4. host-stratified sampling, with the stratification asserted
5. unit-path timing via the existing `_phase_emit`
6. the per-link live-tunnel assertion (VNI, remote, port, both interfaces)
7. a DF-probe instrument driven from a SONiC switch
8. the two-host ownership scope rule — see the open decision below
9. ~~physical host names as a parameter~~ — **done** (`--fabric-hosts`), without
   which the slice cannot be named without using the live S1 host

**Stage B — substrate.** The user applies the second NIC, the fabric VPC and the
UDP 14789 rule. Check the plan for what it **destroys**.

**Stage C — one paid run,** two disposable hosts, all six legs in a single
acceptance script, unconditional verified teardown of **both**.

## 6. Decisions — MADE 2026-10-06, and implemented

Implementation and the strictly additive substrate apply are authorized. Stage C
remains closed.

### 6.1 Ownership: one ledger per host

One existing `Ledger` and `HostLock` per physical host. **No host dimension is
added to the ownership engine** — that would expand the blast radius of the one
component every other check depends on without providing distributed locking,
because the lock is host-local by construction (`ownership.py:231`: an
`fcntl.flock` on a local file, with a process-local `_LOCK_HELD`).

`gpufab-platform/tools/xhost_ownership.py` is the coordinator. Its five
obligations:

1. each host's complete share derived from manifest R — and it **refuses** to
   invent one, because a coordinator that derives "what should be there" itself
   is comparing one guess against another;
2. each host's ledger must **equal** that share exactly;
3. all facts archived, keyed by host;
4. the union must cover R, nothing missing and nothing unexpected;
5. **no cleanup inferred when either host is unreadable** — absent, empty and
   unparseable archives are all `UNREADABLE`, never an empty set.

The verdict is a **leg table**, not a boolean, with the mutual-exclusion leg a
declared constant:

    LOCAL_OWNERSHIP host-a: PROVEN
    LOCAL_OWNERSHIP host-b: PROVEN
    UNION_COVERS_R: PROVEN
    CROSS_HOST_MUTUAL_EXCLUSION: NOT-PROVEN
    OWNERSHIP VERDICT: RED

**There is no code path to GREEN while that constant stands**, and `t110`
asserts it is a constant rather than a condition — because the failure to guard
against is someone relaxing a condition, not deleting a leg. No waiver: Stage C
may prove the transport with this standing, and this RED is what stops that
proof from authorizing a full S3 deployment.

**A measurement that changed this contract.** On the §2 slice the `core` unit
**straddles both hosts** — 8 switches each — while each pod sits wholly on one:

    unit core         -> {host-pod001: 8,   host-pod002: 8}
    unit dc1-pod001   -> {host-pod001: 169}
    unit dc1-pod002   -> {host-pod002: 169}

A containerlab lab cannot span hosts, so that unit becomes one lab per host
carrying the **same name**, and `lab:c12-core` is legitimately claimed on both.
The first version of obligation 4 would have called that a collision. It now
compares against the per-host expectation: a name claimed by **more** hosts than
R places it on is the finding; a name R places on two is not.

### 6.2 MTU: one executable transport policy

`gpufab-network/design/policy/transport.yaml` declares **inputs only**.
`gpufab-platform/tools/transport.py` derives, and **refuses** a catalog that
contains a derived key or omits an input — no defaults, because a default here
is a second source for the value.

    inputs    fabric_vpc_ip_mtu 8896, outer_ip_version 4,
              inner_ethernet_header 14, outer_ipv4_header 20,
              udp_header 8, vxlan_header 8, encapsulation_layers 2,
              udp_destination_port 14789, gcp_subnet_reserved_addresses 4

    derived   vxlan_overhead     = 14+20+8+8 = 50
              cross_host_ip_mtu  = 8896 - 50 = 8846
              tenant_ip_mtu      = 8846 - 50 = 8796

Manifest R carries the derived values per rung. `gen_topology` reads the port
rather than hardcoding it, and `t109` proves no consumer holds a literal — using
the **AST**, because a grep for the number also matches the docstring that
explains the defect.

**The ICMP translation lives in one place.** `ping -s` counts payload, not
packet size, so a probe for IP MTU `M` sends `M-28` (20 IPv4 + 8 ICMP) and its
adjacent failure is `M-27`. The gate therefore locates **8846/8847** and
**8796/8797** instead of a boundary 28 bytes away from the real one. The local
9100 switch-port and 9500 veth MTUs remain measured postconditions, not catalog
promises.

> GCP VPC MTU is the maximum IP packet size and supports values through 8896 —
> https://docs.cloud.google.com/vpc/docs/mtu

### 6.3 Substrate: dedicated, disposable, additive

`gpufab-platform/terraform/stage-c/`, its **own state prefix** in the same
bucket. The existing `google_compute_instance.fabric` is not touched and gains
no NIC; the control VPC is a read-only data source. S1/S2 zero-change is
therefore structural, not a promise — this stack cannot plan a change to a
resource it does not own.

* two `n2-standard-96` hosts, `gpufab-xh-01` / `gpufab-xh-02`, tagged
  `gpufab-xh` only — not `gpufab-fabric`, which carries the live fleet's rules
* `nic0` on the existing control VPC, keeping SSH and external access
* `nic1` on a new `gpufab-fabric-vpc` at MTU 8896 (read from the catalog), with
  `delete_default_routes_on_create`, no external address and no NAT
* ingress UDP **14789**, source the **exact** fabric subnet, `target_tags`
  these hosts only, plus an explicit low-priority deny-all. **No 4789 rule** —
  fabric VXLAN must never cross a host boundary under pod-atomic placement, so
  if it appears there it is a placement bug to find, not traffic to permit
* tunnel addresses are **outputs**, bound into R; the guest interface is
  resolved by its assigned IP, never by a device name like `ens5`

> A GCP firewall rule's port specification **is** the destination port, and
> source-port rules are unsupported — https://docs.cloud.google.com/firewall/docs/firewalls

The source port is also ephemeral — the ECMP entropy hash, measured at
44719/45124/39733 across three packets — so a rule constraining it would drop
traffic intermittently, which is harder to diagnose than dropping it outright.

**`deploy/checks/stage-c-plan.sh` is the apply gate.** It reads the
machine-readable plan and refuses on anything but `create`:

    existing resources changed:   0
    existing resources replaced:  0
    existing resources destroyed: 0

It also VOIDs a plan that creates **nothing** — otherwise "0 changes" reads as
authorization for a run with no substrate. It does not apply, and it does not
run `terraform init`: with the GCS backend that writes state and needs
credentials, which is the operator's step, so it names it instead.

### 6.4 The subnet formula was wrong, and worse than generally

`scale-out-architecture.md` carried `prefix = 32 - ceil(log2(hosts + 3))` with
the comment "network, gw, broadcast". GCP reserves **four** addresses in a
primary IPv4 range — the first two and the last two.

> https://docs.cloud.google.com/vpc/docs/subnets

The undercount is wrong from **five hosts up**, which is exactly S3-4096's
placed-host count: `+3` sizes five hosts into a `/29`, whose 8 addresses leave 4
usable. **The subnet could not have held the fabric it was sized for.** Two,
three and four hosts are unaffected, which is why it survived.

Now `32 - ceil(log2(hosts + 4))` in `transport.py::fabric_subnet_prefix()`,
refusing a prefix that cannot hold the hosts it was asked for, with the
architecture document keeping the explanation and delegating the formula.

## 7. Before the paid run

Stage C stays closed until both:

1. **Stage A green** — the remaining items are the device→host map threaded into
   the probes, per-host execution and merge with a both-halves-measured
   assertion, host-stratified sampling, unit-path convergence timing via the
   existing `_phase_emit`, the per-link live-tunnel assertion, and the DF probe
   driven from a SONiC switch.
2. **containerlab 0.77's `type: vxlan` behaviour measured.** The emitter writes
   a topology-level `type: vxlan` link; both design documents describe
   `containerlab tools vxlan create` with tc redirect, and `vxlan-stitch`
   appears nowhere in any repo. NOT DETERMINED without the installed version.
   The Stage-C hosts are the right place to settle it — before the acceptance
   run, not during it.
