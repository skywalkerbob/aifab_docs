# Engineering challenges — what was hard to build, and how each was settled

**Date:** 2026-10-08

This is the companion to `STABILITY-RETROSPECTIVE.md`, and the distinction
between them matters.

That document is about **defects** — why 84% of ~88 tracked issues were
correctness or verification gaps, why they recurred, and the binding rules that
came out of it. It is the *cost* record.

This document is about the **problems**: what was genuinely difficult to make
work, independent of anything that went wrong on the way. The defect register is
evidence that these were hard; it is not a list of them. Read this one for
orientation — what the system has to do and why that is not easy. Read the
retrospective for the rules you are obliged to follow.

Each section states what was hard, how it was settled, and the measurement that
says so. Where something is still unsettled it says that instead.

---

## 1. Running a real NOS at fabric scale on commodity VMs

The simulator runs **SONiC as a genuine network OS**, not a model of one. That
decision is the root of most of the difficulty: a real SONiC instance is a QEMU
guest, so every simulated switch is a VM inside a container, and the fabric's
size is bounded by how many guests a cloud host will carry.

What that requires, concretely:

* **Nested virtualisation on GCE** — Intel-only, explicitly enabled
  (`advanced_machine_features`), with `/dev/kvm` usable by root *inside* the
  container. An early probe tested it as the SSH user and concluded wrongly;
  containerlab runs as root, and that is the identity that matters.
* **A boot storm.** Each guest takes ~150s. Fifty start at once.
* **Memory and CPU headroom** for the hypervisor alongside the guests.
* **Kernel limits that only bite at scale** — the ARP neighbour table and
  inotify watches are both sized for an ordinary host, not for 169 containers
  across 2306 links.

**Settled as a measured bound, not a guess.** The density ceiling is
`max_vm_per_vcpu`, calibrated from real fabrics:

    S1   48 VMs /  64 vCPU = 0.75   proven GOOD   (1464/1464 BGP)
    S2  106 VMs / 128 vCPU = 0.83   proven GOOD   (3728/3728 BGP, EVPN 32/32)
    S2  106 VMs /  64 vCPU = 1.66   proven FATAL
    S3   50 VMs /  80 vCPU = 0.625  proven GOOD   (2266/2266 BGP, no swap)

The bound stays at the conservative S1 figure; the cost of that conservatism is
recorded in `gpufab-platform/tools/gcp_catalog.yaml` rather than hidden. Note
what the 0.625 point does **not** establish: a measurement inside a bound says
nothing about where the bound is, so 0.75 still rests on S1 alone and the
0.625–0.75 region is unprobed on the N2 family.

## 2. Deriving a whole fabric from one model

A rung declares intent — pods, rails, planes, switch models, ASNs, addressing.
From that single declaration must come, consistently:

* the containerlab topology and every link in it,
* per-device configuration,
* host placement and machine sizing,
* management addressing,
* **and the expected counts the verification compares against.**

The last one is the hard requirement, and it is a design constraint rather than
a convenience: the oracle must be able to **disagree with what was just built**.
That rules out computing expectations from the artifact, which is the obvious
and wrong way to make a test pass.

**Settled by making `fabric_model` + `expected.py` the single authority.** Every
count a check asserts is derived from the profile through the model, never from
the thing under test and never by hand. It is why "2266 configured, 2266
established" is a statement about the fabric rather than about itself.

The same rule applied to transport framing: the substrate MTU chain
(8896 → 8846 → 8796), the encapsulation overhead and the VXLAN port are derived
from declared inputs in `design/policy/transport.yaml` and carried in manifest
R, because a gate asserting 8846 from a literal would be comparing a box
against a number from a document.

## 3. Switches that provision themselves

Switches are not configured by push. They **fetch their own configuration** at
boot: DHCP option 67 points at an HTTP server, which serves a per-device
`config_db.json`. That is how real fabrics are built, and it is why the
simulator uses it.

Two structural problems come with it:

* **The server must live inside the network it serves.** The ZTP server attaches
  to the lab's own management bridge — which does not exist until the lab is
  deployed. The ordering is therefore forced, not preferred: the executor
  creates the network, then serving happens. Getting that backwards produces
  `network ... not found` after a complete and correct render.
* **A switch cannot fetch anything after it is configured.** Applying the
  config moves management into a VRF, so the device loses the path it arrived
  by. Anything a switch needs must be in the artifact it already has.

**Settled** by serving per unit with the ordering enforced, and by moving
post-configuration work (EVPN activation) out of ZTP entirely into a reconcile
step that runs from the host. Proven on a real fabric: 106/106 switches
self-provisioned, 15/15 per-pod acceptance.

## 4. Owning emulation resources with no coordinator

Resource names are **deterministic by design** — a bridge name is derived from
the link so that both ends agree without communicating. That property is
load-bearing for the fabric and hostile to ownership: a name no longer
identifies *who made the thing*.

Meanwhile several runs and agents share a host, there is no distributed lock,
and a teardown that deletes by name will cheerfully remove a stranger's
container that happens to answer to it.

**Settled** with an ownership engine (`tools/ownership.py`):

* an **append-only, fsync'd ledger** — a ledger lost to a crash is a set of
  resources you own and cannot find;
* a **non-blocking host flock**, so a second transaction refuses rather than
  interleaving;
* **identity-based delete authorisation** — the recorded identity
  (`ifindex`/`mac`, docker ID, container set) must still match, so a deletion
  can prove it is removing the thing this run created;
* a **tristate** in which `UNREADABLE` is never `ABSENT`. "We could not ask" and
  "it is not there" are different findings, and conflating them is how a
  coordinator reports a clean teardown for a host it never reached.

**Still unsettled, deliberately.** Per-host ledgers give no cross-host mutual
exclusion: nothing orders two hosts' transactions and nothing reconciles their
ledgers into one answer about whether a fabric is owned. A shared ledger is not
the alternative — deterministic names plus host-local identities mean a shared
ledger would make each host see the other's objects as "ledgered but gone", and
refuse its own cleanup. So the limitation is **declared as a standing RED**
(`tools/xhost_ownership.py`) with no waiver, and it is what prevents a
successful two-host transport proof from authorizing a full S3 build.

## 5. A fabric too large to express as one topology

A containerlab topology has exactly **one** management network. A multi-pod
fabric spans several management subnets, so generation refuses outright:

    nodes span 2 mgmt subnets but a containerlab topology has one mgmt network

This is not a limitation to work around; it reshaped the architecture. The
project moved from a monolithic cold boot to **one lab per logical unit** — a
pod, or the core tier — each deployed, configured, verified and torn down
independently.

What that bought: per-unit rebuild without touching neighbours, incremental
bring-up instead of all-or-nothing, and a blast radius small enough to
experiment in. What it cost: ownership has to be exact (§4), because units share
bridges, and a partial teardown that removed "its" bridges would cut a running
neighbour's links.

## 6. Carrying a switch link between two machines

Above one host, a point-to-point link between two switches has its ends on
different machines. Carrying it requires a substrate tunnel, and four separate
things have to be right at once:

* **Separation of layers.** The substrate rides UDP **14789** between fabric
  hosts; the *simulated* fabric's own VXLAN rides **4789** between simulated
  switch loopbacks. Using one port for both would put the thing being emulated
  and the thing doing the emulating on the same number, where no capture,
  counter or firewall rule could separate them. The firewall opens 14789 only —
  fabric VXLAN appearing on the substrate is a placement bug to find, not
  traffic to permit.
* **Agreement without coordination.** Both hosts must choose the same VNI for a
  link while generating independently. A per-link hash achieves that and
  **collides**: at s3-4096's 800 links, two hashed to the same VNI, which is a
  shared broadcast domain across the substrate rather than a degraded link. The
  resolution is that both hosts hold the same model, so the identity is derived
  from the *whole* link set — preferred hash, then a deterministic probe — with
  a refusal rather than a duplicate.
* **An MTU budget for double encapsulation.** 8896 on the VPC, less 50 bytes for
  the substrate tunnel, less 50 again for the tenant overlay. And because `ping
  -s` counts payload rather than packet size, a boundary probe must send
  `M - 28`, or it locates a boundary 28 bytes from the real one.
* **Per-link verification.** Counts cannot detect miswiring where parallel links
  exist: eight parallel spine↔core links can be cross-connected to each other
  and every count stays correct. The gate must check every tunnel's VNI, remote
  and port against the model.

**Proven host-free:** 800 distinct VNIs at s3, identical across processes, both
generated shards agreeing on all 200 shared links, each declaring only its own
endpoint. **Not yet proven on hardware** — that is the two-host acceptance run,
and it is gated on the remaining work in §7 plus containerlab 0.77's actual
`type: vxlan` behaviour, which is undetermined.

## 7. Verification that is capable of failing

Asserting that a 3728-session fabric is correct means reading BGP and EVPN state
**per switch, on the box**, summing it, and comparing against a model-derived
figure — then proving the comparison can fail at all. `t92` corrupts a
`VXLAN_TUNNEL` entry and requires detection; without that negative control, a
comparison that always agrees is indistinguishable from one that cannot
disagree.

Then the second-order problem: **the tests themselves need testing.** Mutation
harnesses reintroduce each defect into a copy of the tree and require the suite
to go red *on the named assertion*. That caught four blind assertions in one
week — greps matching the comment that explains the defect, a count threshold
gone stale when a fourth fact map appeared, an expected failure message that was
actually a success label — and one mutation that **hung** rather than failing,
which an unbounded harness would have turned into a stalled suite.

Current state: 83 phases, 2717 assertions, all host-free phases green.

**The reach problem is open.** The verification layer finds switches by their
docker-network management IP, which is unroutable from another machine, and no
device row carries a host identity. A gate can therefore report PROVEN having
measured one side of a two-host fabric. The intended resolution is per-host
execution and merge keyed on the model's own placement, with a
both-halves-measured assertion — not routed OOB, which is unbuilt for N>1.

## 8. Fitting the ladder into real cloud capacity

A constraint rather than a bug, and one that shapes every rung:

* **M2 quota is zero** in every region checked; M3 caps at 128 vCPU per
  instance. Neither fact is discoverable from a price list.
* **Pods are atomic** — a pod cannot be split across hosts — so a rung's host
  count is `ceil(pods / pods-per-host)` and a pod that does not fit forces a
  larger machine, not a smaller slice.
* Spot eligibility, disk type and regional availability all differ by family.

**Settled** by deriving each rung's machine from the density bound and the
catalog, and checking quota before provisioning. The same arithmetic produced
the two-host slice's machine choice: on `n2-standard-80` the slice sits at
exactly 0.750 — the unvalidated bound — so a failure would be unattributable
between transport and density; `n2-standard-96` puts it at the qualified 0.625
and isolates the variable under test.

## 9. Operating safely alongside a live fabric

Experiments share a project, a zone and a host naming scheme with fabrics that
are admitted and running. Three concrete hazards, all met:

* **Address collision.** The test fixture's management range is the live
  fabric's OOB bridge subnet, and `docker network create` refuses the overlap —
  correctly. Launchers derive a *relocated* profile rather than editing the
  fixture, whose map is frozen by a test.
* **Name collision.** Deterministic host naming meant the only addressable
  two-host slice included `gpufab-fabric-01`, which is the live S1 host. Host
  names are now a parameter, defaulting to today's values.
* **Destruction on an ambiguous signal.** An automatic rebuild once fired on
  "BGP below threshold" while a fabric was still converging and reached
  `containerlab destroy` on 124 live nodes. Automatic action now requires an
  unambiguous signal; anything else reports and stops. New infrastructure gets
  its own terraform state so that "touches nothing existing" is structural
  rather than promised, and an apply is gated on a plan showing
  `0 changed / 0 replaced / 0 destroyed`.

---

## What makes this project specifically hard

Every one of the above would be ordinary engineering if failures were loud. They
are not. A wrong port table renders cleanly, is served, is accepted by the
device, and passes a rendered-vs-applied comparison — while 178 BGP sessions
quietly fail to establish. A fabric that was never deployed reports a complete
run. A host that has lost its own networking looks like a host with nothing to
say.

That is why the engineering effort here is weighted so heavily toward
**detection** rather than repair, and why the rules in
`STABILITY-RETROSPECTIVE.md` §7 are binding rather than advisory. The
through-line of both documents is the same sentence: distrust every green result
until you can name what it measured and confirm that thing is the outcome, on
the real system.
