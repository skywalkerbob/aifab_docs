# gpufab scale-out architecture — simulating multi-DC GPU fabrics with no design ceiling

**Status:** design, 2026-07-25. Supersedes the single-host scaling assumptions in
`gpufab-sim-design.md` §2 (simulation platform) and §8 (customization & scaling).
Endpoint and fabric reference models live in `network-automation-design.md` §2;
this document defers to them and generalises them (§2.2). The existing sim is the
**reference pod** of this architecture, not a thing to be replaced.

**Scope:** one continuous ladder from today's 64 GPUs to ~1.5M (§8). Near-term
*execution* is the single-DC rungs S0–S5 (64 → 33,040) — a single DC is the first
real physical limit, and everything before S6 is reachable without a second site.
The geographic rungs S6–S8 (multi-DC → multi-region → multi-country) are part of
the same ladder rather than a separate project, because past ~32K GPUs a fabric
grows by adding sites, not by inflating one. Full `vm` fidelity is the default at
every rung; the cheaper tiers exist to keep scale affordable, never to replace
fidelity.

---

## 1. The problem with the current design

The current sim runs 64 GPUs and 30 switches on one VM, at 148/148 BGP. It is
correct and it works. It also cannot grow, and the reason is worth stating
precisely, because it is the same mistake in three forms:

| form | example | ceiling it imposes |
|---|---|---|
| a fixed **scalar** where there should be a **dimension** | `BOUNDS["dgx_count"] = (1, 9)` | 72 GPUs |
| a **flat namespace** where there should be a **hierarchy** | mgmt `172.20.0.0/24`; p2p /31s carved from /24s | 253 switches; 15 DGX |
| a **singleton** where there should be a **shard** | one clab file, one NetBox, one ZTP server, one exporter, one render process | one host; ~59 switch VMs |

None of these are capacity limits. They are *modelling* limits: numbers that were
written down once, in a place where a dimension belonged. `dgx_count ≤ 9` is not
a statement about hardware — its own comment says it exists because the mgmt
block is `.101–.109`.

**The design rule for everything below: scale is a parameter, never a design
point.** If a number appears in a schema, it must be a dimension of a recursive
model, an allocation from a sized pool, or a shard count — never a constant.

---

## 2. Topology model: recursive containment

Replace the flat `{dgx_count, backend{rails, planes, spines_per_plane}, frontend,
storage}` with a model whose levels are data, not schema:

```
world
└── country[]            addressing / policy / sovereignty boundary
    └── region[]         geography. Inter-region RTT is REAL, not emulated.
        └── dc[]         own ASN block, own control plane, own SoT shard
            └── pod[]    leaf+spine group + its attached nodes. Failure domain.
                ├── tier[]          leaf | spine | core | (any future level)
                │   └── device[]
                └── node_class[]    gpu | cpu | storage | head | (any future kind)
                    └── node[]
```

Each geographic level is a **routing and failure boundary**, not a label: a DC
summarises its pods, a region summarises its DCs, a country summarises its
regions. That is what keeps the routing table finite (§3.1) and what makes
"lose a DC" or "lose a region" a drill you can actually run.

Two properties matter more than the specific levels:

- **It is recursive.** Adding a super-spine layer, a region-of-regions, or a
  third DC tier is *data*, not a schema migration. The current 2-tier fabric is
  this model with one region, one DC, and pods that contain only `leaf` + `spine`.
- **Multi-DC falls out.** A multi-DC fabric is a list of DCs plus DCI links. It
  is not a special case, so it needs no special code.

`dgx_count` disappears as a top-level field, and it takes two ceilings with it:
the numeric cap, and the assumption that a cluster contains exactly one kind of
node. GPU count becomes `Σ(node_class.count × node_class.gpus)` over the classes
that actually carry GPUs — derived, never declared, therefore never bounded, and
never inflated by nodes that have no GPUs in them.

### 2.1 Building blocks: node classes and fabrics

A real cluster is not GPU nodes and one fabric. Both sets below are **open**:
adding an `inference` class or a `dci` fabric is data, not a schema change.

**Node classes** — what attaches to the fabric:

| class | what it is | GPUs | notes |
|---|---|---|---|
| `gpu` | GPU compute (DGX B300) | 8 | rail-optimised: one NIC per GPU per plane |
| `cpu` | CPU compute — preprocessing, data loading, general batch | 0 | conventional ToR attach, not rail-optimised |
| `storage` | storage controllers (DDN / Lustre / NFS stand-in) | 0 | dual-attached to the storage fabric |
| `head` | login + scheduler (Slurm controller) | 0 | user-facing; needs frontend redundancy |
| `mgmt` | infrastructure: SoT, telemetry, ZTP/DHCP, CI runner | 0 | lives on OOB + frontend |
| `external` | the simulated **outside** — client reaching in, upstream advertising a default | 0 | attaches only to `border` (§2.4) |

**Fabrics** — each is an independent leaf/spine (or leaf/spine/core) structure
with its own oversubscription, addressing, and failure domain:

| fabric | direction | carries | shape |
|---|---|---|---|
| `backend` | **east-west** | GPU↔GPU collectives | rail-optimised, `rails × planes`, the large one |
| `storage` | **east-west** | node↔storage | conventional leaf/spine |
| `frontend` | **north-south** | job control, general traffic, ingress | leaf/spine **+ border** (§2.4) |
| `oob` | management | console, ZTP/DHCP, BMC | flat, out-of-band |

**Attachment is a matrix, not a constant.** Which class lands on which fabric,
and with how many NICs, is per-profile data:

| class | `backend` | `frontend` | `storage` | `oob` |
|---|---|---|---|---|
| `gpu` | `rails × planes` (16) | 1 | 1 | 1 |
| `cpu` | — | 2 | 1 | 1 |
| `storage` | — | 1 | 2 | 1 |
| `head` | — | 2 | 1 | 1 |
| `mgmt` | — | 1 | — | 1 |

Two consequences worth stating, because they are where this gets got wrong:

- **Port accounting must span every class.** A leaf's budget is
  `Σ(attached NICs from all classes) + uplinks ≤ model port count`. Sizing the
  backend leaves against GPU nodes alone, then discovering CPU and storage nodes
  need ports on the same switches, is the classic way a fabric design fails
  late. The structural check counts all of them.
- **The classes scale independently.** CPU:GPU ratio is a workload property
  (data-loading-heavy pipelines want far more CPU nodes per GPU node than
  synthetic benchmarks do), so it is a per-profile dimension, never a fixed
  ratio baked into the model.

### 2.2 Platform catalog: the accelerator model determines attachment

The table above shows a `gpu` node with 16 backend NICs. That is **DGX B300
specifically**, and writing it as a constant would rebuild the `dgx_count`
mistake one level down. Accelerator platforms differ in GPU count, NIC count,
NIC speed, and — most consequentially — in the size of their **scale-up domain**.

A `node_catalog.yaml` describes platforms exactly as `switch_catalog.yaml`
describes switches; a node class names a `model` and inherits its interfaces:

| platform | GPUs / unit | unit | scale-up fabric | scale-up domain | backend NICs |
|---|---|---|---|---|---|
| DGX H100 | 8 | node | NVLink 4 | 8 GPUs (node) | 8 × 400G (CX-7) |
| DGX H200 | 8 | node | NVLink 4 | 8 GPUs (node) | 8 × 400G (CX-7) |
| DGX B200 | 8 | node | NVLink 5 | 8 GPUs (node) | 8 × 800G (CX-8) |
| DGX B300 | 8 | node | NVLink 5 | 8 GPUs (node) | 16 × 400G (CX-8 dual-port) |
| **GB200/GB300 NVL72** | **72** | **rack** | NVLink 5 + 9 switch trays | **72 GPUs (rack)** | per-tray, config-dependent |
| AMD MI300X / MI325X | 8 | node | Infinity Fabric | 8 GPUs (node) | 8 × 400G |
| AMD rack-scale (Helios class) | rack | rack | UALink / Ultra Ethernet | rack | config-dependent |

**Scale-up and scale-out are different networks and the model must not conflate
them.** The four fabrics in §2.1 are all *scale-out*: routed, BGP-speaking,
Ethernet. A scale-up domain — NVLink, Infinity Fabric, UALink — is
memory-semantic, has no BGP and no IP routing, and is bounded by a node or a
rack. It is a distinct fabric *type*, not another leaf/spine.

**Why this changes fabric sizing rather than being cosmetic:** traffic inside a
scale-up domain never reaches a leaf switch. An 8-GPU HGX node puts all
cross-node collective traffic onto the Ethernet fabric. An NVL72 rack keeps
**72 GPUs' worth of collectives on NVLink** and only exits to Ethernet for
rack-to-rack traffic. Same GPU count, very different scale-out fabric
requirement. Sizing an NVL72 deployment with an 8-GPU node's traffic assumptions
over-builds the fabric dramatically; sizing an HGX deployment with NVL72
assumptions under-builds it. **The unit that attaches to the fabric is the
scale-up domain, not the GPU** — for NVL72 that unit is a rack.

Consequences for the model:

- `node_class.model` selects from the catalog; NIC counts and the attachment
  matrix are *derived from the platform*, never written per profile.
- A profile may mix platforms — real fleets are heterogeneous, with H100 racks
  beside B300 racks — so a pod holds node classes of several models.
- GPU count stays derived: `Σ(class.count × catalog[class.model].gpus)`.
- Rack-unit platforms (NVL72, AMD rack-scale) introduce a `rack` level between
  pod and node. Consistent with §2, that is a containment level in the recursive
  model — data, not a schema change.
- The scale-up domain is modelled for **topology and traffic-locality accounting**.
  Simulating NVLink itself is out of scope and is recorded as a fidelity limit:
  there is no NVLink emulation here, only the knowledge of which GPUs share a
  domain and therefore never appear on the Ethernet fabric.

### 2.3 The geography IS the latency model

Map the hierarchy onto real cloud geography and every inter-site RTT becomes a
physical property of the substrate instead of a number injected with `tc netem`:

| model level | substrate | real RTT |
|---|---|---|
| pod → pod, same DC | hosts in one GCP zone | < 0.5 ms |
| DC → DC, same region | zones within a GCP region | ~0.5–1 ms |
| region → region, same country | GCP regions in one country | ~30 ms |
| country → country | GCP regions across continents | ~100–250 ms |

This matters because every interesting multi-site question — BGP convergence
across DCI, route aggregation at a boundary, failover timing, collective
behaviour over a WAN — is latency-sensitive, and emulated latency is the part
people get wrong. Here nobody emulates it: the sim inherits it.

It also means latency realism costs nothing to add. DCI links ride the same VXLAN
mechanism as intra-DC cross-host links; only the endpoints are further apart.

### 2.4 Traffic domains and how the fabric is reached

The four fabrics above are not peers: they carry traffic in different
*directions*, and a datacentre is defined as much by how you get into it as by
what runs inside it. An earlier revision of this document named `frontend` as
"north-south" and then modelled it as leaf + spine + a single-active SVI gateway
— **a gateway connected to nothing.** The fabric labelled north-south had no
north. Every device in the sim was reachable exactly one way: from the host, over
the OOB bridge.

That collapses a distinction real operators depend on.

**Three domains, and they are not interchangeable:**

| domain | fabrics | what moves | failure looks like |
|---|---|---|---|
| **east-west** | `backend`, `storage` | GPU↔GPU collectives, node↔storage | a job slows or stalls; nothing becomes unreachable |
| **north-south** | `frontend` → `border` → outside | job submission, results, ingress/egress | the cluster is unreachable but keeps computing |
| **management** | `oob` | console, ZTP, BMC, telemetry | you lose visibility and control, not the workload |

**There are exactly two ways in, and that is the point.** Operators reach the
fabric **out-of-band**; users and workloads reach it **through the border**.
Neither path substitutes for the other, and the separation *is* the security
property — not a deployment detail. A sim that cannot demonstrate it cannot be
used to reason about it.

**What the model gains:**

- **A `border` tier on the frontend fabric.** Where north-south actually
  terminates, and the natural home for the policy a real border carries: route
  filtering inward, ACLs, NAT, and the default route the fabric learns. Without
  it there is nowhere to express any of that.
- **An `external` node class.** The simulated outside — a client that reaches a
  GPU node *through* the border, and an upstream advertising a default route
  inward. It attaches **only** to `border`, which is what makes the access model
  structural rather than a convention.

Note that `external` + `border` is the same mechanism S6's DCI needs — a fabric
reaching something that is not itself. Building it here is not throwaway work;
it is the first instance of a pattern the geographic rungs reuse.

**Why this earns its place beyond realism.** Today every fabric is a private
island, so failure drills are indistinguishable: "lose the storage fabric" and
"lose the frontend fabric" produce identical observations, because nothing
depended on either. With a border and an external peer, the asymmetry becomes
measurable — losing a spine degrades east-west, losing the border severs
north-south while collectives continue, and losing OOB blinds the operator while
the workload is unaffected. **Three different failures that currently look the
same.**

**Traffic generation must cover both directions.** `railstorm` exercises
east-west today. A north-south generator (external client → border → frontend →
GPU node) is its counterpart, and the pair is what makes the drills above
observable rather than theoretical.

**Where it lands: S1.** This is the same shape of change as node classes —
new roles, new attachment rows, a seeder that understands them — and S1 is
already reworking exactly that. Deferring it would mean touching the same code
twice.

### 2.5 The substrate is invisible to the simulation

The GCP VPC (`10.10.0.0/24`) is this sim's **physical layer** — the fiber between
fabric hosts. It carries simulated frames; it is not addressable *by* them, in
the same way a real DGX cannot ping the conduit its cable runs through.

Stated as an invariant, and it is **symmetric** — a one-directional reading of
it is how the second half stays broken:

> Anything crossing between the simulated environment and the GCP VPC must
> traverse a **simulated gateway/firewall**, in either direction — *unless* it is
> physical/local access within the sim datacenter, and the only thing that
> qualifies is the **OOB management console**.

Which decomposes into two rules with different mechanisms:

| direction | rule | why |
|---|---|---|
| **sim → substrate** | denied; the border is the sole sanctioned egress | a device that can reach the VPC can reach the SoT, and exhibits behaviour the real fabric does not have |
| **substrate → sim data plane** | denied; must arrive through the border | otherwise "north-south" is a fiction — traffic entering by a path no simulated device can see, inspect or deny |
| **substrate → sim OOB console** | **allowed** | this models an operator physically present in the datacenter with a console cable. It is not a network path into the fabric; it is the one thing that is *supposed* to bypass the network |

The third row is what keeps the other two honest. Isolation that also severs
management is not isolation, it is an outage — and a check that only tested the
outbound direction would have scored that as a pass. So the console must be
*proved reachable* at the same time the data plane is proved unreachable.

The inbound direction is tested **from the fabric host** deliberately: that is
the most privileged position available, sharing a kernel with every simulated
device. Unreachable from there means unreachable from anywhere on the substrate.

This was not true when first checked. `c3-substrate-isolation.sh` found **6 of 6
switches** reaching the fabric host, the **GCP metadata endpoint**, and **NetBox
over HTTP**. The path:

```
switch 172.20.0.12 → default gw 172.20.0.1 (host OOB bridge)
                   → ip_forward=1, FORWARD policy ACCEPT
                   → POSTROUTING MASQUERADE -s 172.20.0.0/24
                   → arrives as 10.10.0.10 — the HOST's address
```

The last hop is the one that matters. Masqueraded, a switch inherits the fabric
host's `gpufab-sim` network tag, so the cloud firewall admits it to the SoT. **A
simulated device was borrowing the identity of the machine simulating it**, and
no firewall rule could have caught it: by the time the firewall sees the packet,
it genuinely *is* from the fabric host. The block has to sit before the NAT
rewrite hides the origin, which is what stage `45-isolation` does.

**Three things this protects, in descending order of how much they matter:**

1. **Fidelity.** A behaviour that depends on reaching the substrate is not a
   behaviour the real fabric has. It passes here and fails there — the sim
   certifies the wrong thing.
2. **Blast radius.** A sim node that reaches `10.10.0.20` reaches the source of
   truth, which is the one component the whole GitOps loop trusts.
3. **Addressing.** The loopback supernet `10.0.0.0/8` *contains* `10.10.0.0/24`.
   Allocation tops out at `10.1.162.52` at S5, so nothing collides today — but
   the ranges are disjoint by not having grown far enough, not by construction.

**Not an airgap — a border.** A real DC does reach the outside; it reaches it
through an edge firewall where every north-south flow is visible, attributable
and deniable. Transparent NAT is the opposite: egress no simulated device can
see, inspect or deny, so any north-south policy tested against it tests nothing.
Hence default-deny, with the §2.4 border nodes as the only sanctioned egress
(`BORDER_IPS`). Until the border tier lands that list is empty, which yields
full isolation — the right default, because an unpoliced hole is worse than no
hole.

**The one thing reachable with no border deployed is the OOB management console,
inbound.** That is not an exception to the model, it *is* the model: it
represents an operator physically present in the datacenter with a console
cable, which is exactly what a fabric host is. So the rules are directional —
`sim → substrate` denied, `substrate → sim OOB` untouched — and conntrack keeps
the two distinguishable. Without the stateful rule the filter is over-broad: a
reply from `172.20.0.12` to the ops host matches "sim → substrate" byte for byte,
exactly as an unsolicited packet would.

**Observability obeys the same rule: pull over the console, never push from the
sim.** The exporter and logship SSH *inward* over the OOB bridge and pull; the
fabric host then serves `:9101` to Prometheus over the substrate. The
measurement leaves via the *host*, never via the sim's own network — so
telemetry does not become the egress hole that the rest of this section closes.
Verified on the live fabric: a switch's only connections are BGP inside the
simulated fabric plus inbound console SSH, and its only configured server is
TACACS at a simulated address. Re-counted across all 48 switches on
`gpufab-s4-fabric` 2026-07-27: **no `SYSLOG_SERVER` table and no `NTP_SERVER`
table exists on any of them**, so TACACS really is the only outbound client the
fabric has — which is what makes the management VRF a one-line migration rather
than a project. No syslog, NTP, SNMP-trap, DNS or telemetry dial-out.

#### 2.5.1 "Denied" has two meanings, and only one of them is right here

There are two ways a destination can be unreachable, they are not
interchangeable, and the sim was doing neither:

| model | what the device sees | when it is correct |
|---|---|---|
| **doesn't exist** | no route; the device's own stack answers `Network is unreachable` | the **substrate** — a real switch has no route to the fiber it runs over |
| **firewall denies** | packet reaches a real edge device, which permits or rejects by policy | the **outside world**, reached through the DC edge |

What was actually happening was a third thing, and it was worse than either:

```
ip route get 10.10.0.20  ->  via 172.20.0.1 dev eth0
ip route get 1.1.1.1     ->  via 172.20.0.1 dev eth0
```

The substrate was a perfectly ordinary routable destination; the packet **left
the switch**, and was silently dropped by `iptables` on the host. So "denied" was
being enforced by a layer the simulation cannot see, inspect, or be tested
against — the substrate policing the sim, which is the same boundary violation as
§2.5 in reverse.

And it left via **`eth0`, the management interface**. North-south egress was
riding the out-of-band management network, which is precisely what an OOB network
exists *not* to do. One field caused it: `gwaddr` on `MGMT_INTERFACE` installs a
default route out `eth0`.

The first fix was to **remove `gwaddr`**, so that no default route existed
anywhere and the substrate became unreachable for want of a route. That bought
the property, and it cost more than it looked like it did.

**The mechanism is now a management VRF, and the property is stronger for it.**
`MGMT_VRF_CONFIG` (`mgmtVrfEnabled`) makes SONiC enslave `eth0` to an L3 master
VRF named `mgmt`, move its rules to `lookup mgmt`, and install `gwaddr`'s default
route in **table 5000**. So the gateway exists — and the main routing table,
which is the only one data-plane traffic consults, still holds no default and no
route to the substrate:

```
ip route show default                 ->  (empty)
ip route show table 5000 default      ->  default via 172.20.0.1 dev eth0
ip route get 10.10.0.20               ->  Network is unreachable
```

The isolation invariant therefore changes shape but not strength. It used to
read *"no gateway exists"*; it now reads **"the gateway is in a routing table
data-plane traffic never consults"**. Three reasons that is the better statement
of the same rule:

1. **It is a property you can ask about.** "No default route anywhere" is an
   absence: nothing distinguishes a correctly isolated switch from one whose
   management is merely broken, and any later feature that adds a route breaks
   it silently. `ip route show default` versus `ip route show table 5000` is a
   *pair* of observations, and each one fails differently — which is why `t17`
   asserts both, and why asserting only the first would pass on a switch with no
   route to anything.
2. **The old form did not validate.** `sonic-mgmt-interface.yang` carries a
   `must` condition requiring `gwaddr` to be present and of the same address
   family as the interface address. Measured on `gpufab-s4-fabric` 2026-07-27:
   **all 48 served artifacts failed `config reload`'s own YANG validation**, so
   ZTP could not provision a single blank switch, fleet-wide. Removing `gwaddr`
   had quietly made the ZTP path inoperative and left the whole fabric standing
   on the config-push backfill. Re-adding it inside a VRF repairs ZTP as a side
   effect: 48/48 artifacts validate, and a switch driven through `config ztp
   run` provisions from the rendered artifact — `ZTP Status: SUCCESS`, source
   `dhcp-opt67 (eth0)` — coming up with the VRF enabled and the substrate
   unreachable.
3. **It is what S2 needs anyway.** When pod mgmt subnets are routed so ZTP and
   TACACS can centralise, a switch needs off-subnet management reachability —
   i.e. a default route. It now has one, in a table the data plane cannot select
   from.

**Confinement, not removal — and the distinction is load-bearing.** A packet
*explicitly* placed in the mgmt VRF does reach the substrate:
`ip vrf exec mgmt curl http://10.10.0.20:8000/` succeeds. That is the intended
semantics of a management VRF, and it is why every assertion above is written
against the **default VRF**. Anything that legitimately crosses must now name
the VRF to do so, which makes the crossing explicit and enumerable instead of
implicit: today that is exactly one thing, `vrf=mgmt` on the TACACS server.

**Inbound management is unaffected**, which is not obvious and was measured
rather than assumed. `sshd` binds in the default VRF while connections arrive on
a VRF-enslaved link; `net.ipv4.tcp_l3mdev_accept=1` — which SONiC sets
regardless of whether a VRF is configured — is what lets that socket accept
them. Measured across containerlab's tap/passthrough path with the VRF up, on a
backend leaf carrying 34 established sessions: 10/10 ssh, 5/5 scp, and `vtysh`
reads for the exporter, with all 34 sessions still Established afterwards.

Host `iptables` is demoted to a backstop either way, and if it ever fires that is
now a bug in the sim's own policy rather than the mechanism.

**What had to be taught to source from the VRF: one thing.** The client that
dials *out* gets no help from `tcp_l3mdev_accept`, so `TACPLUS_SERVER` carries
`vrf=mgmt` (`hostcfgd` renders it into `/etc/tacplus_nss.conf` as `,vrf=mgmt`).
A fabric-wide census of all 48 switches found **no `SYSLOG_SERVER` and no
`NTP_SERVER` table** to migrate — the earlier note that "TACACS, syslog and NTP
all have to source from the mgmt VRF" was written when this was hypothetical and
overstated the work by two thirds.

#### 2.5.2 The gateway is virtual, so its egress must be anchored to a real address

The border being "the only way out" is not enforceable while the border is
addressless. The original leak is the proof: escaping traffic was `MASQUERADE`d
into the fabric host's identity and arrived at the SoT *as* `10.10.0.30`,
indistinguishable from the host's own traffic. No cloud firewall rule could have
caught it, because at the point the firewall saw the packet it genuinely was
from the host.

So the gateway needs its own substrate address — **a GCP VPC internal IP, on the
border's outside interface**, distinct from the host's:

- an **alias IP range** on the fabric host NIC (`10.10.0.128/29`, say), reserved
  for gateways and never used by the host itself;
- the border node's **outside** interface takes one of those addresses; its
  **inside** interface is an ordinary simulated link into the border tier;
- **no MASQUERADE** for it — it egresses as itself, so north-south traffic is
  attributable at the substrate and can carry its own cloud firewall rules;
- everything else remains routeless, per §2.5.1.

That single address is the demarcation: the one place where sim addressing
becomes substrate addressing. It is capturable, policy-able, and nameable in a
diagram — which is what §2.5.1's rendering requirement is about.

#### 2.5.3 The fabric view must be LAYERED, not one diagram

A single diagram has a ceiling, which is the one property this architecture is
supposed not to have. Measured against the ladder:

| rung | elements (devices + links) | single diagram |
|---|---|---|
| S0 | 268 | fine |
| **S1** | **1,590** | **already sluggish** |
| S2 | 3,590 | sluggish |
| S3 | 13,395 | unusable |
| S4 | 33,076 | unusable |
| S5 | 105,986 | will not render |

It breaks at S1 — the next rung, not a distant one.

**The layers are the containment hierarchy (§2), not a UI invention.**
`region → dc → pod → tier → device`. A level of detail IS a level of that
hierarchy: the DC view shows pods, the pod view shows tiers and real devices,
the device view shows ports and neighbours. The drill path already exists in the
data; the renderer just has to stop ignoring it.

**Edges aggregate above the device level.** Between two pods, one edge labelled
`512 links · 8 planes` — not 512 lines. This is what makes the view ceiling-free
by the same argument as everything else here: the number of things drawn is
bounded by the LEVEL, not by the size of the fabric. A view whose cost grows
with the fabric is a view with a maximum fabric.

**Aggregation belongs in the projection, server-side.** The tempting shortcut is
to ship every element and let the browser cull. At S5 that is a multi-tens-of-MB
JSON body before the browser has drawn anything, so the ceiling merely moves
from the renderer to the transport. `build()` takes a level and a scope and
aggregates BEFORE serialising.

**The pod is the right aggregation unit** because it is already atomic for
placement (§5). That makes the DC view double as a host-placement view — which
pod sits on which fabric host, and which links cross a host boundary. That is
the view an operator actually wants when a spot host is preempted, and it comes
free from choosing the aggregation unit correctly.

**The threshold is automatic, not a toggle.** Render real devices below ~1,500
elements, aggregate above. S0 then renders exactly as it does today and S5 shows
35 pods, with nobody choosing and nobody able to accidentally ask for the
unrenderable.

This is also where **north-south egress** belongs (§2.5.2): "traffic leaves this
datacenter" is a DC-level statement, so the border and the external node class
are drawn on the DC view rather than lost among ten thousand leaf ports.

#### 2.5.4 The egress point must be VISIBLE in the topology

Isolation only became meaningful once the border was the sole sanctioned exit —
which means the border is now load-bearing, and anything load-bearing that
cannot be seen will eventually be assumed. The topology view must therefore
render the north-south exit explicitly:

- the **border/edge device(s)** as their own tier, visually distinct from leaf
  and spine — they are the only devices with a path off the fabric;
- the **external node class** beyond them (§2.4), so the "north" in north-south
  is a drawn thing rather than an implied one;
- the **egress path itself**, styled apart from east-west links, because those
  two carry different traffic for different reasons and an operator reading the
  diagram is usually asking which one they are looking at.

And the case that matters most: **when there is NO border, the view must say so.**
Today `BORDER_IPS` is empty and the fabric is fully isolated — which is correct
— but an un-drawn egress and a non-existent egress are the same picture. A
fabric that has lost its border by misconfiguration would render identically to
one that never had one, and the difference is the entire north-south story. The
view should carry an explicit "no egress configured" state, in the same spirit
as every other check here that counts results rather than trusting silence.

This is the rendering counterpart of §4.1: the diagram is a projection of the
SoT, so the border appears there because it is a device in NetBox with a role,
not because the renderer special-cases it.

**Two chains, because there are two paths.** `DOCKER-USER` (reached from
`FORWARD`) covers sim → *other* substrate hosts. Traffic to an address the
fabric host itself holds is local delivery via `INPUT` and never traverses
`FORWARD` — after the first fix, switches still pinged `10.10.0.10`. The
substrate machine was visible from inside the simulation precisely because it
was the machine running it.

A further trap worth recording: containerlab installs `-i <sim-bridge> -j ACCEPT`
into `DOCKER-USER` on every deploy, pre-authorising exactly the direction being
denied. Rules appended below it are installed, counted, reported — and never
evaluated. Position, not presence, is the mechanism; the stage re-asserts its
rules above containerlab's on each run, and probes reachability afterwards
rather than trusting the insert.

---

## 3. Addressing: hierarchical, derived, and mostly eliminated

Flat address spaces are the hardest ceiling to remove later, because rendered
configs and reservations depend on them. Three changes:

**BGP unnumbered for all fabric p2p.** This is the single largest unlock. It
deletes the `/24` p2p allocator and its `(R-1)·2D + (D-1)·2 + 1 ≤ 254` guard
outright — the check that caps the current design at 15 DGX. There is no p2p
address space to exhaust because there are no p2p addresses. FRR and SONiC both
support it, and it is what large fabrics actually run.

**Everything else derived from a sized supernet**, by position in the hierarchy:

| space | allocation | why it cannot run out |
|---|---|---|
| loopback / router-id | `f(fabric, dc, pod, index)` from a configurable supernet (default a /8) | 16.7M addresses; supernet is config |
| mgmt | one subnet **per pod**, **sized to that pod**, routed | prefix is derived from pod device count |
| ASN | per-DC block from 4-byte ASN space | 4.2 billion |

> **Implementation status: done.** All three rows are implemented. p2p is
> unnumbered — **checkpoint C2 verified on the VS image**: an unnumbered session
> reached Established and an IPv4 prefix installed via an `fe80::` next-hop over
> a link with no address on it (`deploy/checks/c2-bgp-unnumbered.sh`). Loopbacks
> and ASNs are allocated positionally on `(fabric, dc, pod, index)` with derived
> field widths, so every boundary aggregates; mgmt remains one sized subnet per
> pod plus one per DC for cores. Measured at S5: **6,726 loopbacks flat versus
> ~198 in a leaf's RIB** once summarised — a 34x reduction.

The mgmt change is what removes the 253-switch cap, and it removes it *by making
the sim more realistic*: per-pod subnets with a **DHCP relay** per host pointing
at the DC's ZTP server is how real datacenters do zero-touch. A single stretched
L2 domain of 18,000 switches would be both unbuildable and unlike production.

### 3.1 Summarisation is the real reason addressing is hierarchical

Not running out of addresses is the obvious benefit and the lesser one. The
structural benefit is that **hierarchical addressing is what makes route
summarisation possible**, and summarisation is what keeps the routing table
finite as geography is added.

A 529K-GPU fabric (§8, S7) has roughly **108,000 loopbacks**. Allocated flat —
or allocated hierarchically but *aggregated nowhere* — every switch in every DC
carries ~87,000 routes in its RIB. That is not a memory problem in the sim
(where a `frr` node will hold it fine); it is a **fidelity** problem, because a
real Spectrum-4 has finite route-table capacity and real operators spend their
time on exactly this. A sim that silently carries a global flat RIB is
simulating a fabric nobody can build.

Allocated along the hierarchy, each boundary aggregates. **The fabric is part of
the key, not just the geography** — §2.1 states that each fabric has its own
addressing and failure domain, and that is only true if backend, frontend,
storage and OOB draw from separate, individually summarisable blocks:

```
        supernet 10.0.0.0/8
        10 . [ fabric | dc ] . [ pod ] . [ index ]

fabric  10.<F·64>.0.0/10      backend / frontend / storage / oob — one block each
dc      10.<F·64+D>.0.0/16    region sees one prefix per DC, per fabric
pod     10.<F·64+D>.<P>.0/24  leaf holds its own pod, plus summaries
```

A leaf then carries its pod's prefixes plus a handful of summaries and a default
— tens of routes rather than the ~108,000 a flat allocation would put in every
RIB. Losing a fabric's block, or a DC's, is also a single withdrawn summary
rather than thousands of individual withdrawals, which is what makes "lose a DC"
converge in a way worth measuring.

**The field widths are derived, not fixed.** Writing `fabric:2 | dc:6 | pod:8 |
index:8` into the allocator would be a new set of constants — precisely what §1
forbids — and it would cap the design at 64 DCs and 256 pods. Each field is
sized from the topology it must hold (`ceil(log2())` of the actual fabric, DC,
pod and per-pod device counts), the total is validated against the supernet, and
an overflow reports which field ran out and which supernet to widen. The layout
above is the *default worked example* at S5 scale, not the schema.

Two details that fall out and are easy to miss:

- **Nodes need loopbacks too.** GPU, storage and head nodes speak BGP (§2.2's
  reference model is BGP-to-the-host, 16 sessions per endpoint), so they need
  router-ids from the same scheme. The `index` field must therefore be sized for
  switches **plus** nodes in a pod, not switches alone — at S5 that is ~56
  switches against ~136 nodes, so sizing on switches would undershoot by 3×.
- **OOB gets a block but no summarisation peer.** The OOB fabric is reached over
  the substrate rather than the emulated fabric (§5.5), so its block exists for
  addressing consistency and never appears in a fabric RIB.

A leaf ends up holding its pod's prefixes plus a handful of summaries and a
default — tens of routes, not tens of thousands. **Testing that the
summarisation holds, and that it fails safe when a boundary is misconfigured, is
one of the main things the multi-site rungs exist to exercise.**

### 3.2 What is actually allocated today, and what is missing

Stated plainly so the gap is not mistaken for a description of behaviour:

| space | scheme | status | aggregates? |
|---|---|---|---|
| p2p | none — unnumbered | **done**, C2 verified on hardware image | n/a |
| loopback | `f(fabric, dc, pod, index)`, derived widths | **done** | **yes** — pod / DC / fabric |
| ASN | per-DC contiguous block | **done** | matchable by policy |
| mgmt, per pod | sized subnet per pod | **done** | not yet aligned into a per-DC block |
| fabric separation | one block per fabric | **done** — /24 each at S0, /17 at S5 | **yes** |

Verified by construction rather than assertion: across all ten stage profiles at
three fidelities, **zero duplicate loopbacks and zero devices falling outside
their own pod summary**.

Two bugs the uniqueness check caught, both worth recording:

- A 144-switch DC core tier overflowed an index field sized only from per-pod
  device counts, producing 16 duplicate loopbacks. As duplicate router-ids that
  would have surfaced as an unstable fabric, not an addressing fault.
- `offset()` shifted without bounds-checking, so an oversized field bled silently
  into its neighbour instead of failing. Every field is now validated and an
  overflow names the field and its width. **A silent wrap is the worst available
  failure mode** in an allocator — it converts a sizing bug into a correctness
  bug somewhere else entirely.

One item remains: per-pod mgmt subnets are sized correctly but carved
sequentially, so they do not yet aggregate at the DC boundary. Sized-per-pod is
necessary but not sufficient.

**The per-pod prefix must be derived, not fixed.** An early draft of this
document said "one `/24` per pod". A prototype disproved it within an hour: a pod
of 48 leaves + 16 spines + 195 GPU hosts is 259 devices and overflows a `/24`,
and the allocator failed with a bare `StopIteration`. A constant `/24` is the
same flat-namespace mistake as `172.20.0.0/24`, merely moved down a level.
`mgmt_prefix_len` is therefore a **floor**, and each pod's subnet is sized from
its own device count. This is the rule generalised: *any constant in an
allocator is a ceiling waiting to be discovered.*

---

## 4. Fidelity as a per-device attribute

The reason 500K GPUs looks impossible is the assumption that every switch must
be a 4 GB SONiC VM. Measured costs per switch instance:

Figures below are S7 (§8.1) regenerated from the current model — **528,640 GPUs
across 16 DCs, 31,456 switches** — not the earlier backend-only estimate:

| fidelity | RAM/switch | 31,456 switches | hosts | 8h drill, spot |
|---|---|---|---|---|
| `vm` — SONiC VM, real ZTP, real boot, config_db, SAI | 4 GB | 122.9 TB | 560 | $3,270 |
| `container` — SONiC container, no ZTP service | 1 GB | 30.7 TB | 144 | $841 |
| `frr` — FRR BGP speaker, topologically exact | 50 MB | **1.5 TB** | **16** | **$93** |

`fidelity` becomes a device attribute assigned by policy per pod or per DC.

### 4.1 The rendering contract the tiers actually need

An earlier draft said all three backends "consume the same rendered config".
They cannot: the renderer emits SONiC `config_db.json`, and a bare FRR speaker
has no config_db — it wants `frr.conf`. Left unstated, this hole would surface
at the moment `frr` fidelity was first tried at scale.

What is shared is **intent**, not the artifact. The render pipeline must produce
a **canonical intent document** per device — interfaces, addressing, BGP peers
and policy, MTU, VLANs — from which per-backend adapters emit:

| backend | artifact | consumed by |
|---|---|---|
| `vm` | `config_db.json` (+ ZTP `ztp.json`) | SONiC VM, via real ZTP |
| `container` | `config_db.json` | SONiC container, config-push |
| `frr` | `frr.conf` / `vtysh` | FRR speaker |

Two requirements follow, and neither is optional:

- **Parity tests.** The same intent, rendered through two adapters, must produce
  BGP sessions and route tables that agree. Without this, the claim that `frr`
  is "the same code path" for convergence is an assertion rather than a
  measured property — and the entire cost argument for tiering rests on it.
- **Intent is the GitOps artifact.** What lands in the repo and gets reviewed is
  the canonical intent; per-backend artifacts are build outputs. Otherwise the
  same fabric produces different diffs depending on which fidelity it was last
  rendered at, and review becomes meaningless.

**This contradicts the pipeline as currently designed, and the contradiction has
to be resolved rather than left standing.** `network-automation-design.md` §6
commits `rendered/<device>/config_db.json`, gates PRs that touch `rendered/**`,
and deploys those merged artifacts. This document says the reviewed object is
canonical intent and `config_db.json` is a build output. Both cannot be true.

The end-to-end contract, stated once:

| stage | artifact | committed? | reviewed? |
|---|---|---|---|
| SoT → render | **canonical intent**, per device | **yes** | **yes** — this is the diff a human reads |
| intent → adapter | `config_db.json` / `frr.conf` | yes, but as a **build output** alongside its intent | no — checked by CI, not read |
| adapter → device | the artifact ZTP serves and config-push applies | — | — |

Three properties this requires:

- **Deterministic adapters, versioned.** The same intent plus the same adapter
  version must produce a byte-identical artifact, or the committed build output
  is not verifiable and CI cannot tell an adapter change from an intent change.
  The adapter version belongs in the commit.
- **Provenance on every artifact** — which intent revision and which adapter
  version produced it. This is also what makes the stale-render check of
  `network-automation-design.md` §6 enforceable.
- **One artifact per device per backend**, and ZTP and config-push consume the
  *same* one. A device provisioned by ZTP and later config-pushed must converge
  on identical bytes, otherwise drift-check reports differences that are really
  path differences.

Migration: keep committing `config_db.json` (nothing breaks), add the intent
document beside it, move the required review gate onto the intent, and demote the
artifact check to CI-generated verification. Until that lands, the artifact
remains the reviewed object and this section describes the target, not the
current pipeline.

#### 4.1.1 Hardware tables come from the SoT, never from a captured artifact

**Any table in a rendered config that describes the device's own hardware must
be derived from the SoT. A snapshot of one machine is a statement about that
machine, and nothing else.**

The rule earns its place. `config_db.json` is rendered by overlaying derived
tables onto `design/base/vs_base_config_db.json`, which is a dump taken from one
running SONiC VS instance. A dump contains that instance's `PORT` table —
Force10-S6000, 32 ports — and for three fabric builds every device inherited it,
including the 64-port leaves the switch catalog models. So `config_db` carried
two tables describing how many ports the device had, from two different origins:

| table | origin | says |
|---|---|---|
| `INTERFACE` | the SoT — NetBox interfaces and their addresses | 64 ports |
| `PORT` | a snapshot of a different machine | 32 ports |

SONiC creates netdevs from `PORT`, so every interface above `Ethernet124`
rendered, applied, and then had no netdev, no address and no BGP session. **178
of 1464 sessions across three independently built fabrics**, and no stage
reported a problem — the render wrote it, ZTP served it, `config reload` took
it, and the rendered-vs-applied check compared `BGP_NEIGHBOR` on both sides and
found them equal, because they *were* equal. A port that does not exist is not
an error anywhere in the pipeline. It is only ever visible as an absence.

Two corollaries, both learned the same way:

- **One origin beats two agreeing origins.** Selecting the right port table per
  model fixes the instance; it leaves two tables that must be kept consistent by
  care. `PORT` is now built from the same SoT interface list `INTERFACE` is
  built from, so they cannot disagree — the attributes the SoT does not model
  (`lanes`, `speed`, `index`, `alias`) are joined in from the HWSKU port set by
  port *name*. The catalog became the cross-check; the SoT is the origin.
- **Disagreement is fatal, not a warning.** If the SoT and the catalog disagree
  about a device's hardware, one of them is stale and the renderer cannot know
  which — so it refuses. Truncating to what fits is exactly how a 64-port leaf
  became a 32-port one, and a config that is quietly smaller than the hardware
  it configures applies perfectly cleanly.

The same audit found the identical shape twice more in the same snapshot, both
now closed: `DEVICE_METADATA.mac` (every VS ships the same base MAC, and
inheriting it gives every switch the same IPv6 link-local — 82 of 249 sessions
could not come up), and `DEVICE_METADATA.bgp_asn` (the captured machine's 65001,
surviving onto any device the SoT gives no ASN). What remains in the snapshot
and is *not* hardware — `FEATURE`, `LOGGER`, `VERSIONS`, `FLEX_COUNTER_TABLE` —
describes the image it was captured from, and carries the same staleness risk
one level down.

The critical point about `frr`: **SONiC's BGP daemon is FRR.** An FRR node
running the rendered BGP config is not a low-fidelity approximation of SONiC's
control plane — it is the same code path. For convergence, route scale, and ECMP
at 500K, it is near-exact. What it does not give you is ZTP, config_db, or
swss/orchagent behaviour — which is exactly why fidelity is per-device: you spend
VM fidelity where the question demands it (one pod, for ZTP and boot drills) and
FRR everywhere the question is "does BGP converge at this scale".

This is what makes the architecture have no ceiling. Cost scales with
*fidelity × devices*, and fidelity is a knob.

---

#### 4.1.2 Provenance must cover the TRANSFORM, not only the input

**A rendered artifact must record which CODE produced it, alongside which SoT it
came from. Identical input through changed code is a staleness that no input
fingerprint can see, by construction.**

`sot_revision.py` fingerprints the SoT — device and cable material plus NetBox's
changelog high-water mark — and every render stamps it into `_provenance.json`.
Drift-check compares stamped against live to decide whether a render is stale.
That covers the INPUT and stops there, and the day §4.1.1's fix landed the other
half was measured directly. Two fabric hosts, both running `s1-512`, read
read-only within the hour:

| | `gpufab-s3-fabric` | `gpufab-s4-fabric` |
|---|---|---|
| stamped SoT fingerprint | `5c0d184d7ee65c49` | `5c0d184d7ee65c49` |
| stamped devices / cables | 124 / 1466 | 124 / 1466 |
| `sot_revision.is_current` | current | current |
| served `PORT` rows, all 48 switches | 64 | **32** |
| `render_fabric_ztp.py` on disk | pre-fix | **post-fix** |

The SoT stamps are byte-identical because the SoT genuinely did not change. The
served artifacts are not: `expected.py --key max_ports_per_switch` puts the
busiest switch in `s1-512` at **52 ports**, so every one of s4's 48 devices was
being handed a config asserting hardware that stops at port 32 — §4.1.1's bug,
still being served, on a host that already had the fix sitting on its disk. A
renderer fix that does not propagate is the same failure with a longer fuse, and
nothing in the pipeline could state it: the input fingerprint reported *current*,
correctly, on its own terms.

So `gpufab-network/tools/render_revision.py` fingerprints the transform and the
renderer stamps it beside the SoT revision. Four decisions in it generalise:

- **Content hash, not a git SHA.** Hosts hold no git credential; their checkouts
  are frozen at the clone commit and correct `main` content is applied over the
  top by tar, so `git rev-parse HEAD` on a host names a commit whose content is
  not what is on disk. It is wrong in both directions — it moves for a docs-only
  commit that changes no output, and does not move for an edit made in place that
  does. Hashing the bytes that were actually read needs no `.git`, no network and
  no credential, and is the only claim that survives a fleet that cannot pull.

  It proved the point within the hour, by accident. Mid-deploy the workstation
  fingerprint went to `6275f425…` against the fabric host's `33ceaf7e…`, naming
  one differing file: `interim_deploy.py`, which another agent was part-way
  through editing and had not committed. **No commit id could have shown that,
  because there was no commit** — and an uncommitted edit to a file the renderer
  imports is precisely the state in which someone renders a fabric by mistake.
- **No list of files.** A hardcoded set that silently stops covering a new data
  file is the same defect class being closed. Code is the transitive
  *module-scope* import closure of the render entry point; data is *whole
  directories* by glob. Both grow by themselves. The one judgement is module
  scope: a module-scope import runs unconditionally, a function-scope import was
  made conditional on purpose, and following those too would pull in
  `fabric_model.py` — touched by 25 of 185 commits and executed by no render —
  which would report every fabric on earth as stale until nobody read the check.
- **Over-inclusion is the safe direction.** Being wrong that way costs a
  re-render that emits identical bytes. Being wrong the other way costs 178 BGP
  sessions.
- **Absence is data, and measuring nothing is never agreement.** A file that
  vanishes takes its name out of the hashed material, so a deletion cannot pass
  as unchanged; a file expected and unreadable contributes an explicit `MISSING`
  line. If *nothing* resolves the fingerprint is null, never the hash of an empty
  set — a hash over nothing is a stable, valid-looking value that two equally
  broken checkers would agree on.

The corollary for how code reaches a host: **sync from `git archive HEAD`, never
from the working tree.** The same day, the tarball built for the s3 fabric host
was cut from HEAD minutes before another agent's in-progress `interim_deploy.py`
appeared in that shared checkout, so the host received the committed version
rather than a half-finished edit. A working tree is a shared, mutable staging
area with no atomicity: syncing from it ships whatever anyone happens to be
midway through, and the fingerprint that lands on the host then describes a
state that exists nowhere else and can never be reproduced.

The general rule this is an instance of: **a provenance record that names only
the input is a claim about half the pipeline.** Any stage that transforms — a
renderer, a compiler, a template, a projection — has to name its own version in
its output, or the only detector of a stale artifact is a human who happens to
remember that the code moved.

---

### 4.2 The fabric view, as built

The renderer is a **projection of the SoT**, served per request by
`portal/topoview_service.py` and computed by `portal/gen_topoview.build()`. It is
not a file. A generated `topology.json` would be a second copy of the truth, and
a stale diagram is indistinguishable from a current one — the worst possible
place to keep a cached copy, because the error is invisible by construction.

**Freshness without cost.** Rebuilding per request measured 10.7s, and NetBox was
not the cause: one render issued **311 API requests**, because pynetbox
dereferences each cable's terminations lazily and the cable loop is an N+1. The
fix is a cache keyed on NetBox's changelog high-water mark — a 47ms probe — so a
payload is reused only when the SoT's own change counter is identical. That is
**not a TTL**: a TTL serves something that may already be wrong and hopes nobody
notices. Keying on the change counter makes a stale payload impossible, and the
response reports `reused` and `change_key` so it is visible rather than assumed.
Result: 10.5s → 35ms.

**Levels.** See §2.5.3. `build(level, scope)` implements the full hierarchy —
`region → dc → pod → tier → device` — and `auto` walks UP from `device` until the
element count fits under 1,500. `scope` narrows the SET rather than zooming the
picture: a level that still carries every element has saved nothing. Measured,
per rung:

| rung | flat | auto picks | drawn |
|---|---|---|---|
| S0 | 268 | device | 51 nodes + 225 edges |
| S1 | 1,590 | tier | 13 + 16 |
| S2 | 3,590 | pod | 6 + 6 |
| S3 | 13,395 | pod | 9 + 15 |
| S4 | 33,076 | pod | 15 + 33 |
| 3-DC | 40,185 | dc | 4 + 0 |

One rule produces all of it, with a single qualification that is the hierarchy
asserting itself rather than a special case: **a level is skipped when the view
spans more than one unit of the level above it.** A tier is a within-pod object,
so a multi-pod tier view draws ~12 units per pod — 420 at S5 — which is strictly
worse than 35 pods and is not what §2.5.3 means by "the DC view shows pods". A
pod is a within-DC object for the same reason: 15 pods from 3 DCs is an
undifferentiated cloud when the answer wanted is "three datacenters, pick one".

**The DC core tier is a unit at pod level.** Pods in this topology never touch
each other — they meet at the DC core — and a core switch belongs to no pod. The
first implementation dropped every device without a key at the current level, so
the S3 pod view drew five disconnected boxes and **zero edges**: the entire point
of the level, absent, in a payload that otherwise looked perfect. The core tier
now aggregates into its own unit per fabric, which is what it is.

**Drilling is symmetric.** The projection ships `view.path`, so the breadcrumb
reads `all › dc1 › pod003 › backend leaf` with every segment clickable. Before
that the only way back was "all" — the view could descend four levels and only
return to the top. The drill target travels in the data (`node.drill`), and it
asks for `auto`, because the right level inside a unit depends on what is in it.

**Verified by looking, and only by looking.** Three separate failures in this
feature produced JSON with the right node count, the right labels and the right
totals, and a picture that was wrong or empty:

- aggregate nodes carried no `layer`, the page places at `y = layer * 190`, and
  `Number(undefined) * 190` is `NaN` — nothing drew at all, and `fit()` then
  framed the one node that still had a position, so the S3 pod view rendered as
  a blank canvas with a giant "no egress configured" marker on it;
- a revision of that fix dropped `icon` from the emitted aggregate data — every
  unit drew as an invisible box with a floating label;
- the aggregated stats line reported the scope's 865 devices beside a picture of
  five boxes.

`gen_topoview.py --profile <yaml>` derives the view from a profile instead of
NetBox, through the same `build()` the service calls, which is what makes these
scales reachable without deploying them — and is what made the failures visible.
`tests/t09-topoview.sh` asserts the counts (reduction per level, inter-unit edges
present, every device covered by some unit, every drawn node carrying a numeric
layer); the picture still has to be looked at.

**Icons carry tier.** Devices are drawn as inline SVG rack equipment rather than
geometric shapes, with the tier in the SILHOUETTE, not in a detail that must be
counted: a modular chassis with vertical line cards for core, 2U for spine, 1U
for leaf, 8 accelerator bays for a DGX, drive bays for storage. An earlier
version gave all three switch tiers the same box with 3/2/1 port rows, and at
64px the eye does not count rows.

Vendoring a stock icon set was the alternative and loses the subject: those
supply generic router/switch/firewall, whereas the object worth showing here is
a DGX B300 as 8 bays feeding 8 rails across 2 planes. Inline SVG also keeps the
page self-contained, which matters because the console is served from the ops
host to a browser with no guaranteed route to any CDN.

**The isolation boundary is always drawn — present or absent.** Today it reads
*"no egress configured — fabric is fully isolated"*, which is the truth: no
border device exists in the SoT and `BORDER_IPS` is empty. Drawing that
explicitly is the entire point of §2.5.4. It is pinned outside the layout and
locked, because the boundary is not a device in the topology, it is the edge of
it, and letting the layout place it among the leaves says the opposite.

**A verification note that generalises.** The icons were checked by rendering
through a browser engine, not ImageMagick. IM's SVG renderer ignores
`stop-opacity` and drew every chassis black — which would have been a confident
and completely wrong conclusion about the artwork, and would have led to
"fixing" a colour scheme that was already correct. Verify with the engine that
will actually run the thing, not the one that is convenient.

---

## 5. Placement is a separate concern from topology

Topology says what exists. Placement says where it runs. Keeping them separate is
what lets the same topology run on 1 host or 300.

- A placement function maps `device → host`, defaulting to **pod-aligned**.
- **A pod is atomic**: it is never split across hosts, so the hot east-west path
  (host↔leaf, leaf↔spine) stays on local veth. Only spine↔core and DCI cross
  hosts, so the traffic that matters never pays VXLAN encapsulation or MTU cost.
- **But pods are bin-packed.** Atomic does not mean one-pod-per-host. If a pod
  costs less than a host, several share one. This distinction is load-bearing:
  with one-pod-per-host, host count is `#pods` regardless of fidelity, so
  choosing `frr` buys emptier hosts rather than fewer — which would defeat the
  entire point of tiering. Packed, a 33,040-GPU fabric is 35 hosts at `vm`,
  9 at `container`, 1 at `frr`.
- Host count is **derived** from packing. Nobody declares a host count.
- A pod that exceeds one host is a structural error naming its three knobs
  (shrink the template, bigger host, lower fidelity) — never a silent split.

### 5.2 At `vm` fidelity, the emulation host bounds pod size

Deriving the ladder against the complete four-fabric model surfaced a constraint
the backend-only prototype had hidden: **a 251 GB host holds at most ~960 GPUs
worth of pod at `vm` fidelity.** Beyond that the pod's switch count (backend
leaves and spines, plus frontend, storage and OOB switches, at 4 GB each)
exceeds one host, and pod atomicity forbids splitting it.

This is worth stating plainly because it inverts the usual direction of
influence. In a real fabric, pod size is a *network design* decision — how many
leaves a spine layer serves. Here, at `vm` fidelity, it is also bounded by the
emulation substrate, and pod count in the ladder is therefore **derived from
what fits a host**, not chosen. S5's 35 pods are a consequence of that division,
not a design intent.

The three honest responses, in the order they should be considered:

1. **Lower the fidelity of pods that are not under test.** At `container` the
   same fabric packs ~4× denser, at `frr` ~80×. This is the intended use of
   tiering and it makes the constraint mostly disappear.
2. **Use larger emulation hosts.** The bound scales linearly with host RAM.
3. **Split a pod across hosts** — available, but it costs the property that
   made pods atomic: host↔leaf or leaf↔spine links would cross a tunnel and
   pay the reduced cross-host MTU (§5.1). Only worth it for a pod that must run
   at `vm` fidelity *and* exceeds any available host.

If a deployment's real pods are larger than a host can hold and full fidelity is
required throughout, that is a genuine substrate limit and should be recorded as
one rather than worked around silently.

### 5.3 Host sizing: prefer small, widely-available machines

Large VMs are the least available machines a cloud sells. A single
`n2-standard-64` request failed with a **GCP stockout** during this project's own
reboot drill, which is a poor foundation for a fabric that wants tens of hosts.
Emulation hosts here are **RAM-bound, not CPU-bound** — measured steady-state is
~0.25 cores per switch VM — so the high-core machine types are the wrong shape
and the wrong price.

**The `vm`-fidelity floor is set by rail-optimisation, not by preference.** A GPU
node touches *every* rail leaf, so the rail leaves of a pod cannot be split
across hosts without that node's links crossing a tunnel. The smallest
8-rail × 2-plane pod is therefore an indivisible unit:

| smallest pod shape | switches | host RAM needed at `vm` |
|---|---|---|
| full (frontend 2+2, storage 2+2) | 30 | **~132 GB** |
| leaf-only frontend + storage | 26 | ~116 GB |
| leaf-only + 1 spine per plane | 24 | ~108 GB |

Dropping the frontend/storage spine layer is legitimate for a small pod — with
two frontend leaves there is nothing for a spine tier to aggregate.

Total hosts and spot cost per rung, `vm` fidelity:

| machine | RAM | $/hr spot | S3 (4,120) | S4 (10,296) | S5 (33,040) |
|---|---|---|---|---|---|
| `n2-highmem-16` | 128 GB | 0.37 | 11 hosts / $4 | 24 / $9 | 76 / $28 |
| `n2-standard-48` | 192 GB | 0.82 | 8 / $7 | 18 / $15 | 55 / $45 |
| **`n2-highmem-32`** | **256 GB** | **0.74** | **5 / $4** | **11 / $8** | **34 / $25** |
| `n2-standard-64` | 256 GB | 1.09 | 5 / $5 | 11 / $12 | 34 / $37 |

Two conclusions:

- **Default to `n2-highmem-32`.** Identical RAM and identical host count to
  `n2-standard-64` at every rung, **~32% cheaper**, and a 32-core machine is
  markedly easier to schedule than a 64-core one. There is no case for the
  64-core type in this workload — it buys cores that measurement says go unused.
- **`n2-highmem-16` is the accessibility floor.** With leaf-only frontend and
  storage it runs full `vm` fidelity at 256 GPUs per pod, costs about the same in
  total, and 16-core machines are available essentially everywhere — the best
  answer when stockouts, quota, or a smaller cloud account are the binding
  constraint. `n2-standard-48` is strictly dominated and should not be used.

One caveat that argues against going smaller still: switch-VM **boot** is
CPU-heavy even though steady state is not (30 switch VMs took 13.5 min on 64
cores). Fewer cores lengthens bring-up roughly proportionally, so a 16-core host
trades rebuild time for availability. That is usually the right trade for a lab
and the wrong one for a demo.

### 5.4 One small stateful head, N identical stateless fabric hosts

The fleet is **two kinds of machine, and only two**:

| | head / master | fabric host |
|---|---|---|
| runs | SoT, TSDB, dashboards, ZTP/DHCP, TACACS, console, CI runner, orchestrator | pods only — switches and nodes |
| emulates | **nothing** | everything |
| state | **durable** (NetBox DB, Prometheus TSDB, runner workspace) | **none** |
| purchase | on-demand, always on | **spot / preemptible** |
| count | exactly 1 per DC | N, all identical |
| scales with | total device count | pod count |

**How big is the head?** The model's estimate is `n2-standard-8` (32 GB) across
the single-DC ladder — 16 GB of usage at 64 GPUs, 23 GB at 33,040. **Treat that
as a starting point to be measured against, not a property of the design.** An
earlier draft asserted the head "stays small permanently"; that claim was not
supported. The estimator sizes NetBox and Prometheus from device and
scrape-target counts alone and ignores everything that actually drives the two:

- **NetBox**: interface and cable rows, not device rows. S5 is 6,720 devices but
  ~500K interfaces and ~99K links; working-set and index size track the former.
- **Prometheus**: series *cardinality* (per-port and per-BGP-peer series across
  1,966 switches), retention window, and query concurrency — none of which is a
  function of target count.
- **Disk**: unmodelled entirely, and at S5 retention is the likely first limit.

So the head is sized by **capacity gates measured at each rung**, not by formula:
SoT p95 write and query latency under render load, Prometheus ingestion rate and
head-block size at the chosen retention, and render wall-clock. If a gate fails,
the head grows or the service shards — and §6 already moves SoT partitioning to
S6 for a reason. What the design *does* guarantee is that the head never emulates
anything, so it does not grow with GPU count directly.

**Losing the head is worse than "changes stop".** An earlier draft said that;
it is wrong. The head owns DHCP, TACACS+, telemetry, the console, remediation and
the GitOps runner, so its loss means no ZTP for a booting switch, switch logins
degraded to `local`, no dashboards or alerting, no closed-loop remediation, and
no config pipeline. The existing fabric keeps forwarding — that much was right —
but the sim stops being operable. It is therefore a **single point of failure
that must be treated as one**: its state (NetBox database, Prometheus TSDB,
runner workspace) needs scheduled backup with a tested restore, and the recovery
objective should be stated per rung. HA for the head is out of scope at S0–S5 and
should be revisited at S6, where per-DC heads make the failure domain smaller
anyway.

**Why the split earns its keep**, in order of weight:

1. **State.** The head's data is durable and the fabric hosts' is not. That
   asymmetry is what makes the fleet **spot-eligible**: a preempted fabric host
   is redeployed from the SoT and loses nothing. At S5 that is $25.90/hr on spot
   against $73.50 on-demand — a **65% saving** available only because the
   stateful part was separated out.
2. **Interchangeability.** Fabric hosts are identical, so scaling out is "add
   another host exactly like the others" with no first-host special case in
   deploy, telemetry or log shipping.
3. **Failure domains.** Losing the head stops *changes*, not the fabric. Losing
   a fabric host costs one pod, not the control plane.
4. **Growth curves.** Conflating them means over-provisioning one to satisfy the
   other — the current single-VM sim is exactly that, a 256 GB machine sized for
   emulation that also happens to carry NetBox.

**Core switches must be spread round-robin, not first-fit.** Cores are not atomic
with anything, so packing them into leftover pod-host capacity is free — but
first-fit piles them all onto host 1, which quietly recreates the snowflake this
section exists to prevent (at S2: 230 GB against 206 GB, and losing host 1 would
take the whole core tier and disconnect every other pod). Spread evenly, host RAM
variance across the fleet is **0 GB at every rung**.

#### Deploy stages by role

The head being a real deploy target — not just a box on a diagram — means the
stage set splits. Three stages legitimately run on **both** roles:

| role | stages |
|---|---|
| **head** | `00-bootstrap` `20-services` `30-seed` `70-telemetry` `80-portal` `85-console` `90-automation` `95-logship` |
| **fabric** | `00-bootstrap` `10-images` `40-topology` `50-configure` / `50-ztp-provision` `60-auth` `70-telemetry` `95-logship` |

- `00-bootstrap` — every host bootstraps itself.
- `70-telemetry` — the head takes Prometheus/Grafana/Alertmanager; **each fabric
  host runs its own exporter**, because one process cannot SSH-poll a fleet
  (§6). This is the federation split, and it is why the stage appears twice.
- `95-logship` — each host ships its own logs; the sink already namespaces by
  instance id.
- `40-topology` — a fabric host deploys **only its own pods**, never the whole
  topology. This is the change that makes the stage set multi-host at all.
- `50-ztp-provision` / `60-auth` — the head serves ZTP/DHCP and runs the TACACS+
  server centrally; fabric hosts carry the DHCP **relay** and provision their own
  switches.

Each stage profile declares its targets, so sizing is not implicit:

```yaml
placement:
  fleet_machine: n2-highmem-32   # 256 GB, stateless, identical
  fleet_ram_gb: 256
  fleet_spot: true               # preempt-safe: redeploys from the SoT
  head_machine: n2-standard-8    # 32 GB, stateful, always on
  head_ram_gb: 32
  head_spot: false
```

The model reads `fleet_ram_gb` when packing, so a profile that changes machine
type re-derives its own pod and host counts rather than silently keeping numbers
sized for a different box.

#### 5.4.1 What the split actually looks like, once built

The table above is the design. This is what it became, and the differences are
worth recording because most of them were only visible once a *second* host
existed.

**The role is a filter over one stage list, not a second deploy path.**
`deploy.sh` takes `ROLE=head|fabric` and drops the stages the role does not own.
Membership comes from `fabric_model.py`'s `STAGE_ROLES` rather than a list
restated in bash — a second copy is a copy that drifts, and drift here means a
host silently skipping a stage it needed. Order stays in `deploy.sh`: order is a
deploy concern (observability before fabric), membership is a model concern.
With `ROLE` unset the historical single-host path is byte-identical, which is
what lets the old sim keep running untouched as a reference.

**The read side of the split was one variable.** Every consumer — `seed`,
`render`, `gen_topology`, `render_fabric_ztp`, `gen_topoview`, `drift`, the bot —
already resolved NetBox from `NETBOX_URL` and merely *defaulted* to localhost. So
pointing a fabric host at a remote SoT needed an export, not a refactor. Two
things genuinely had to change: `setup_netbox` bound `127.0.0.1`, and the deploy
driver had no notion of a role.

**Bind the SoT to the VPC address, not `0.0.0.0`.** Both are private — the
`gpufab-vpc` carries exactly three firewall rules and `tcp:8000` is admitted only
from tagged fabric hosts — but `0.0.0.0` also listens on the external NIC, which
leaves the source of truth one firewall edit from public with nothing at the
socket to stop it. The firewall should be the second line of defence, not the
only one.

**The fleet is `count`-based.** S1 is one host, S2 two, S4 eleven: same terraform
block, different integer, addresses derived (`10.10.0.30`, `.31`, …) so
Prometheus targets and VXLAN endpoints can be computed rather than discovered.

**Sizing was measured, not estimated.** On the live 30-switch fabric a SONiC VS
costs **4.00 GB RSS and 0.15 cores** at steady state. So `vm` fidelity is
RAM-bound, not CPU-bound: `n2-highmem-32` (32 vCPU / 256 GB) carries S1's 48
switches at 192 GB, where `n2-standard-32` — identical cores, 128 GB — would not.
Sizing this tier by core count is the intuitive mistake.

**What the second host exposed.** Every one of these was invisible while there
was only one machine, and each reported success while doing nothing:

| found | why host 1 never showed it |
|---|---|
| `fabric.tf`/`ops.tf` had no `service_account`, so both new VMs were anonymous callers to GCS | `main.tf` has carried one since day one |
| the image cache reported "miss" when it meant "I could not look" (401), sending stage 10 off to compile SONiC for hours | host 1 had the image already |
| stage 10 built the non-ZTP image first — a long build of something the ZTP path never boots | both images predated the split |
| stage 70 started a full Prometheus/Grafana **on the fabric host**, a rival dashboard that shows only itself and still dies with the fabric it watches | there was only ever one host to run it on |
| `as_seed_topology` and `seed.py` disagreed on their contract, and nothing produced interface names at all | the two had never been run together |

The last one is the general lesson: **a contract with one implementation on each
side and no test between them is not a contract.** It surfaced as a `KeyError`
partway through populating a live NetBox.

**Deploy the low rung first on new infrastructure.** S0 (64 GPUs) is 30 switches
— the same count as the reference fabric — so it is an exact diff target and a
~20 minute cycle rather than an hour. Every defect above was found at S0. At S1
they would have been the same defects, an hour deeper.

**Operational notes that cost a cycle each.** A ~30 minute bring-up must not be
tied to the SSH connection that started it (`setsid nohup`, log to a file, poll
the file) — the first attempt died to `SIGHUP` at zero containers and reported
exit code 0. And `sudo cmd > /var/log/x` opens the file as the *calling* user, so
the redirect has to happen inside the privileged shell.

### 5.5 How the hosts talk to each other

Three planes, routinely conflated. Only one of them is the emulated fabric.

**Plane 1 — substrate: the real VPC.** Every host VM on `gpufab-subnet`
(`10.10.0.0/24` today). Real routed IP; everything below rides it. This also
carries all *control* traffic directly, unencapsulated: head→fabric SSH for
deploy, fabric→head Prometheus federation (the head scrapes each host's
exporter), DHCP relay unicast, log shipping, and the relay's calls out to GitHub.

**Plane 2 — emulated fabric wires: VXLAN on a dedicated overlay network.** A
cross-host switch↔switch link becomes a VXLAN tunnel (UDP 14789), tc-redirected
onto the containerlab-created `host:` interface. One VNI per link. These tunnels
ride a **separate high-MTU VPC on the fabric hosts' second NIC**, not the control
network — see "Separate the overlay from the control plane" below. Because pod-atomic
placement keeps every intra-pod link on local veth, only spine↔core and DCI
appear here, and the count per host stays roughly flat as the fabric grows:

| rung | hosts | cross-host links | tunnels on the busiest host |
|---|---|---|---|
| S2 | 2 | 192 | 192 |
| S3 | 5 | 768 | 309 |
| S4 | 11 | 1,920 | 354 |
| S5 | 35 | 6,528 | **390** |

That flatness is the placement design paying off: 35 hosts and 33,040 GPUs still
means only ~390 tunnels on any one host. These links carry the reduced 8846-byte
MTU of §5.1; every link that matters for GPU collectives stays local.

**Plane 3 — emulated management (OOB).** Each pod's mgmt subnet lives on a docker
bridge on its own fabric host. The question is what needs to reach it from
off-host, and the role split of §5.4 shrinks that answer to almost nothing: the
exporter polls only local switches, and config-push runs on the host that owns
the switches. **The one remaining cross-host need is ZTP** — a booting switch
fetches its config over HTTP after the DHCP relay hands it a URL.

**Correction: an earlier draft claimed ZTP was the only cross-host need and
preferred a host-local OOB with just an HTTP responder. That is wrong, and it
would have broken the fabric in four ways.** The head owns services that must
reach, or be reached by, switch management addresses:

| flow | direction | breaks under host-local OOB? |
|---|---|---|
| TACACS+ authentication | switch → head | **yes** — every switch login fails over to `local` |
| console / ttyd per-device terminal | head → switch | **yes** — the console cannot open a session |
| remediation bot actuators | head → switch | **yes** — closed-loop remediation stops |
| ZTP config fetch | switch → head | localisable |
| DHCP address assignment | switch → relay → head | relay is host-local; the head is still required |

The last row matters for the claim that a localised responder buys
head-independent reprovisioning: it does not. A blank switch still needs the
head-hosted DHCP service to get an address at all, so localising only the HTTP
artifact fetch removes none of the head dependency.

**Therefore: route the pod management subnets.** Each fabric host runs
`--can-ip-forward` with a VPC static route per pod subnet pointing at it. This
adds per-pod routing state to the substrate, which is the cost, and it is the
same thing a real datacentre does with its management network.

A host-local variant remains *possible*, but only as a full local control-plane
footprint — per-host TACACS replica or authenticating proxy, per-host console
agent, per-host remediation actuator, and a DHCP replica — not an HTTP responder
alone. That is a materially larger commitment (replicated auth state, split-brain
remediation) and should be taken only if substrate routing turns out to be the
binding constraint. An HTTP cache on each fabric host is still worth having to
cut ZTP fan-in on the head, but it is an optimisation, not an isolation boundary.

#### Separate the overlay from the control plane at the substrate

Planes 1 and 2 have opposite requirements. Control traffic — SSH, Prometheus
federation, DHCP relay, log shipping — is happy at a 1460 MTU and needs egress to
the internet. The VXLAN overlay wants the largest MTU the substrate can give and
needs no external reachability at all. Putting both on one VPC forces a
compromise on each.

**Primary approach: a dedicated fabric VPC, and dual-NIC fabric hosts.**

| | `nic0` — control | `nic1` — fabric overlay |
|---|---|---|
| network | `gpufab-vpc` (existing) | **`gpufab-fabric-vpc`** (new) |
| MTU | 1460 (unchanged) | **8896** |
| carries | SSH, Prometheus, DHCP relay, logship, GitHub | **VXLAN only** (UDP 14789) |
| external access | egress via Cloud NAT | **none — internal only** |
| subnet | `10.10.0.0/24` | **derived** from placed host count, per region (see below) |

> **CORRECTION (#100), 2026-08.** The `8896` above is a PROPOSAL — the
> `gpufab-fabric-vpc` does not exist. The running sim has ONE 1460 VPC on a single
> NIC; `addressing.yaml`'s old 9214/9000 was read by nothing. The overlay-cannot-fit
> claim relayed elsewhere was arithmetically wrong twice and misattributed: the
> measured port MTU is **9100** (not 9000), and subtracting the substrate 50 bytes
> ONCE gives `8896 − 50 = 8846` wire, `− 50` overlay `= 8796`, against a 9100 port —
> **304 short**; with NO overlay at all it is already **254 short**. So this is a
> pre-existing MTU deficit that VXLAN merely made visible, not a VXLAN problem. It
> does **not bind today**: placement is pod-atomic and every cross-host link at every
> rung is `core-spine`, so VTEP (frontend-leaf) traffic rides local veths at 9500.
> The deficit is LATENT — it would bite only a real multi-host deployment carrying
> 9000-byte RoCE across the 1460 substrate. Headroom is now measured by
> `tests/t58-mtu-headroom.sh` rather than asserted from a figure in no code.

Four reasons this beats raising the MTU on the existing VPC:

- **Nothing existing changes.** `gpufab-vpc` keeps its MTU, so the running sim
  never needs the restart an MTU change would force. New fabric hosts are created
  with both NICs from the start.
- **The overlay gets its own failure and tuning domain.** The fabric VPC can be
  changed freely later without touching anything the control plane depends on —
  the same separation-of-concerns argument as the head/fleet split (§5.4),
  applied one layer down.
- **It is a security reduction.** The fabric VPC needs *no* ingress and *no*
  egress; it is pure internal transport between fabric hosts.
- **The head needs only one NIC.** It emulates nothing, therefore terminates no
  VXLAN — so dual-NIC is a fabric-host property, not a fleet-wide one.

**Creating the tunnels correctly** — an earlier draft gave a command that would
not have worked. Four details, each of which silently produces no working link:

```
containerlab tools vxlan create \
    --link  <clab-created host iface>   # REQUIRED: what tc-redirects into the tunnel
    --dev   <guest iface, e.g. ens5>    # the LINUX device name, not the GCP NIC name
    --remote <peer overlay address> \
    --id    <vni> \
    --dst-port 14789                    # clab's default; see the note below
```

- `--link` is not optional. Without it nothing is redirected and the tunnel
  carries no fabric traffic.
- `--dev` takes the **guest** interface name. GCP's `nic1` is an API-side label;
  inside the instance it is `ens5` or similar, and must be resolved at deploy
  time rather than assumed.
- `--dst-port` — **SETTLED 2026-09-03 by packet capture: the substrate uses
  14789**, containerlab's default. An earlier draft here said 4789 while
  `gen_topology.py:472` emitted 14789; left mismatched, every tunnel is dropped
  by the firewall.

  Measured in two network namespaces: the configured `dstport` is exactly what
  lands on the wire (`> 10.99.0.2.14789` / `> 10.99.0.2.4789`), so either works
  and the tie-break is operational. The deciding fact is that the EMULATED fabric
  already uses 4789 — the frontend-leaf VTEP artifact declares no `dst_port`, so
  SONiC takes the IANA default. Using 4789 for the substrate too would put the
  thing being emulated and the thing doing the emulating on one port, where no
  capture or firewall rule could separate them.

  Also measured: the SOURCE port is ephemeral and varies per flow (VXLAN's ECMP
  entropy hash), so the firewall must match DESTINATION only. A rule constraining
  source port drops traffic intermittently, which is worse than dropping it
  outright.
- **Tunnels are unidirectional.** Each cross-host link needs the command run on
  *both* endpoints with the VNI and port matching; creating one side yields a
  link that appears configured and passes nothing.

Reference: <https://containerlab.dev/cmd/tools/vxlan/create/>.

Binding `--dev` to the overlay interface is what keeps overlay traffic off the
control path.

**Alternative, if a single network is preferred:** raise `gpufab-vpc` to MTU
8896. Verified safe from a blast-radius standpoint — `gpufab-vpc` currently holds
exactly one instance (`gpufab-sim-01`); every other workload in the project sits
on `default`, `polychat-*`, `blockchain-prod` or `mw-airgap`, so no non-sim VM is
affected. The cost is that the change is per-VPC and instances pick it up only on
restart, so the live sim must be bounced.

**Fallback, if neither:** accept a 1410-byte inner MTU on cross-host links and
record it as a fidelity limit. Because GPU collectives stay intra-pod on local
veth at 9214 (§5.1), the loss is confined to spine↔core and DCI — the
oversubscribed paths — but jumbo-frame behaviour then cannot be tested across
pods at all.

#### Overlay subnet sizing is derived, and it is per region

An earlier draft fixed the fabric subnet at `/22`. That is a constant in an
allocator — the exact thing §1 forbids — and it fails inside the ladder: S8 needs
**1,776** `vm`-fidelity fabric hosts against a `/22`'s 1,022 usable addresses.

**GCP subnet ranges are regional**, so a multi-region deployment does not get one
big range: each region needs its own non-overlapping block. The prefix for a
region is therefore derived from the hosts actually placed in it:

```
prefix(region) = 32 - ceil(log2(placed_hosts(region) + 3))   # +3: network, gw, broadcast
```

carved from a supernet wide enough for every region, with the allocation
validated for overlap across both NICs' networks. Same rule as the pod management
subnets (§3): sized to what it holds, never a fixed width.

References: [GCP subnets](https://docs.cloud.google.com/vpc/docs/subnets),
[multiple network interfaces](https://docs.cloud.google.com/vpc/docs/create-use-multiple-interfaces).

#### Substrate prerequisites

Checked against the live project; **none are currently in place**:

| requirement | today | needed |
|---|---|---|
| fabric VPC | does not exist | create at **MTU 8896**; subnet prefix derived per region |
| VXLAN firewall | only `tcp:22`, on `gpufab-vpc` | allow **UDP 14789**, **dst only**, within the fabric subnet (settled by packet capture; the source port is ephemeral, so a rule matching it drops traffic intermittently) |
| fabric-host NICs | single-NIC | **dual-NIC**, assigned at instance creation |
| IP forwarding | `canIpForward: False` | required **only if** plane-3 option 1 is chosen |
| control subnet size | `/24` = 254 usable | fine to S5 (35 hosts); a `/22`+ before S8 |

Cross-host links use containerlab `host:`-style interfaces stitched with
`containerlab tools vxlan create` (tc redirect), riding a dedicated high-MTU
overlay network on the fabric hosts' second NIC (§5.5). Without that — on the
default 1460 control network — every cross-host link is capped at 1410 bytes.

### 5.1 Cross-host MTU is a real fidelity gap, not a solved problem

An 8896-MTU overlay network does **not** make cross-host links transparent, and
an earlier draft implied it did. The reference fabric runs **host MTU 9000, fabric
MTU 9214** (`network-automation-design.md` §"Frontend VLANs"). GCP's maximum
VPC MTU is 8896, and VXLAN encapsulation costs a further ~50 bytes:

```
   9214  fabric MTU the design calls for
   9000  host MTU
   8896  GCP VPC maximum (the overlay VPC)  <-- already below host MTU
 - ~50   VXLAN overhead
 = 8846  largest frame that actually survives a cross-host link
```

**A production-sized 9000-byte frame cannot traverse a pod boundary.** This is
inherent to the substrate, not a configuration error, and it must be stated
rather than discovered. Consequences and the honest options:

- **Intra-pod links are unaffected** — they are local veth and carry 9214. Since
  placement keeps host↔leaf and leaf↔spine inside a pod (§5), the GPU
  collectives that actually care about jumbo frames never cross a tunnel. This
  is the main reason pod-atomic placement is worth its constraints.
- **Cross-pod paths must be declared reduced-MTU.** Spine↔core and DCI links run
  at 8846. The sim must set this explicitly and exercise **PMTUD / MSS clamping**
  on those paths, because a real fabric with an MTU discontinuity behaves badly
  in ways worth simulating — silent blackholing of large flows is a classic
  production failure.
- **Record it as a known fidelity limit.** Anything measuring end-to-end
  cross-pod throughput at production frame sizes is measuring the substrate, not
  the fabric.
- **Or escape the substrate**: bare-metal hosts, or a provider permitting a
  ≥9264 underlay, would close the gap. That is a substrate choice, not a design
  change, and nothing else in this architecture depends on it.

---

### 5.6 One ops host per SIM — isolation, not filtering

**The requirement.** Different people run different simulations, and a user of
one must not see another's dashboards. That is a tenancy boundary, not a display
preference.

**Why the current arrangement fails it.** Today there is one Grafana on one ops
host, federating every fabric host. A `fabric_host` template variable lets you
*filter* to one fabric — but filtering is a dropdown, not a boundary: every user
sees every sim in the list, any user can switch to any of them, and one
Prometheus holds all of their data. It also produces numbers that are actively
misleading. An unscoped panel summed two unrelated simulators into a single
"477 BGP sessions", which is not wrong so much as meaningless, and nothing on
screen said two systems had been added together.

**The decision: one ops host per sim.** A sim is `1 ops host + N fabric hosts`,
and the ops host carries that sim's NetBox, Prometheus, Grafana, Alertmanager and
console.

**"Nothing is shared" was the intent, and it overstated the implementation** —
corrected here because a security claim nobody has tested is worse than an
acknowledged gap: someone will build on it. What sims actually get today is
**service separation, not a security boundary**. See §5.8 for the precise line.

| approach | isolation | why not |
|---|---|---|
| Grafana orgs/teams, per-sim folders | in-app RBAC | one Prometheus still holds every sim's data; a misconfigured query or a datasource permission slip crosses the boundary |
| per-sim Grafana container, shared ops host | good | still one blast radius: one host, one Prometheus TSDB, one failure takes every sim's observability |
| **one ops host per sim** | **strongest** | costs a VM per sim |

The third is the honest match for what the head already is. §5.4 defines the
head as the machine holding **durable, sim-specific state** — the SoT and the
TSDB. That state is exactly what must not be shared, so co-tenanting it was
always at odds with the split's own argument.

**The sim id becomes first-class.** It exists today only as a by-product of
`95-logship`, which mints one to namespace log uploads. Under this decision the
sim id names the ops host, appears in the console title, labels every metric via
`gpufab_sim_info`, and is what a URL identifies. **The URL is the identity** —
which is what makes isolation observable rather than asserted.

**Structural consequences, including the ones that cost something:**

- `ops.tf` becomes `count`-based like `fabric.tf`. A sim is provisioned as a
  unit: one head, N fabric hosts, its own VPC firewall tags.
- **Cross-sim comparison is lost.** You can no longer put two sims on one
  dashboard. That is a real cost and it is the point — the comparison that was
  possible was also the accident that produced 477. Comparing sims becomes an
  explicit act (query two endpoints), not an accidental sum.
- **VM count grows with sims, not just with scale**: `sims × (1 + N)`. The head
  is deliberately small (§5.4) precisely so this is affordable.
- §5.4 says the head is "exactly 1 per DC". That becomes **1 per sim per DC**:
  a multi-DC sim still gets per-DC heads at S6 for failure-domain reasons, and
  the isolation boundary is the SIM, which may contain several.
- The existing reference sim (`gpufab-sim-01`) is already this shape — a
  self-contained monolith with its own NetBox and its own Grafana. It is the
  pattern, not the exception.

**What this does NOT solve.** Two sims still share a GCP project, a VPC and the
substrate. Isolation here is of *observability and intent*, not of the
underlying infrastructure — a preempted host or an exhausted quota still crosses
sims. §2.5's substrate rules are unaffected: the simulated fabrics could not see
each other before this change and cannot after it.

---

## 6. No singleton services

Every service shards along the hierarchy. Nothing is global except aggregation.

**On SoT ownership:** NetBox remains **the source of truth** — that is a locked
decision, not something this document reopens. Seed-as-code is the *bootstrap*
input that populates NetBox; it is not a competing authority. An earlier draft
called NetBox "a projection of seed-as-code", which inverts the relationship and
would make an operator's NetBox edit something a later seed run could silently
overwrite. The correct rule is **field-level ownership**: seeded fields are
reconciled from policy, operator-owned fields (and operational overrides such as
maintenance state) are never overwritten by a seed, and the seeder is additive
and non-destructive except under an explicit `--reset`.

| service | today | sharded |
|---|---|---|
| SoT (NetBox) | one instance, all devices | partitioned per DC at S6; within a DC, scale by read replicas + incremental render (see S5) |
| render | one process, `0.67 s/device` measured | sharded by pod, parallel workers, **incremental** (changed devices only) |
| ZTP | one dnsmasq + http | one server per DC, DHCP **relay** per host |
| telemetry | one exporter SSH-polling every switch | one exporter per host; Prometheus federation / remote-write |
| control plane | on the sim host | dedicated per DC + one global aggregator |

### 6.1 The SoT and render pipeline are the real 500K blockers

This deserves emphasis because it is counter-intuitive: at `frr` fidelity, 500K
GPUs needs **4 hosts and $35 a drill**. The emulation is cheap. What is not cheap:

- NetBox at **81K devices, 2.29M interfaces, 792K cables** — a database scaling
  project in itself.
- Render at **3.4 hours serial** (extrapolated from the measured 0.67 s/device).
- **31,456 rendered artifacts** per sim in the GitOps repo at S7.

These costs are per-device and do **not** shrink with fidelity. Sharding and
incrementalising the render pipeline is therefore the highest-value work for
large scale, ahead of any emulation-host spend.

---

## 7. Scaling law

What this architecture makes O(what):

| quantity | grows as | bounded by |
|---|---|---|
| emulation hosts | `Σ fidelity_cost / host_capacity` | cloud quota, not design |
| cross-host tunnels | spine↔core + DCI only | partition quality, not size |
| render wall-clock | `devices / workers` | worker count, a parameter |
| control planes | `#DC` | number of DCs, a dimension |
| p2p addresses | **0** | unnumbered — nothing to exhaust |
| mgmt addresses | `Σ pod_size` | pods are a dimension; prefixes are derived |
| sites | `#country × #region × #dc` | all three are dimensions |
| routes in a leaf RIB | **~constant** | summarisation at each boundary (§3.1) |

No row is a constant. That is the whole objective.

---

## 8. The staged plan: one ceiling per rung

Scope for now is **a single DC** — the first real physical limit. Multi-DC stays
in the model (§2.1) so it costs nothing to reach later, but no rung below
requires it.

Each rung removes **exactly one** named ceiling. That is deliberate: a stage that
removes two is a stage whose failure you cannot attribute. Every rung is
independently shippable, independently verifiable, and useful even if the next is
never built. Counts below are derived from the model, not estimated.

Counts below are derived from the **complete** model — four fabrics, dual-plane
rail-optimised backend, all five node classes, NIC counts from the platform
catalog. The model reproduces the reference inventory of
`network-automation-design.md` §2.3 exactly (30 switches, 92 host links, 43
inter-switch on the 4-DGX profile), and **S0 reproduces today's live sim at 30
switches**. That agreement is the gate these figures passed before being used.

An earlier revision of this table came from a backend-only, single-plane
prototype and **understated switches by roughly 50%** (S5 read 1,344 against a
true 1,966). Those figures are superseded.

| stage | GPUs | pods | switches | nodes | links | hosts `vm`/`cont`/`frr` | ceiling removed |
|---|---|---|---|---|---|---|---|
| **S0** | 64 | 1 | 30 | 13 | 225 | 1 / 1 / 1 | *baseline — today's sim* |
| **S1** | 512 | 1 | 48 | 76 | 1,466 | 1 / 1 / 1 | `dgx_count ≤ 9` + the `/24` p2p allocator |
| **S2** | 1,024 | 2 | 106 | 152 | 3,332 | 2 / 1 / 1 | single-host / one-clab-file singleton |
| **S3** | 4,120 | 5 | 269 | 595 | 12,530 | 5 / 2 / 1 | 2-tier schema + `/24` mgmt (253 devices) |
| **S4** | 10,296 | 11 | 620 | 1,485 | 30,965 | 11 / 3 / 1 | serial render + singleton telemetry |
| **S5** | 33,040 | 35 | 1,966 | 4,760 | 99,260 | 35 / 9 / 1 | SoT capacity within one DC (not sharding — see below) |

**S1 — 512 GPUs, one host.** BGP unnumbered + hierarchical loopbacks. Kills both
addressing ceilings. 8× the GPUs on hardware already owned, no new
infrastructure: the cheapest real win available, and pure software.

This is also the rung where `dgx_count` is replaced by **node classes** (§2.2),
because it is the same field: `dgx_count` is simultaneously a numeric cap and an
assertion that a cluster contains one kind of node. S1 lands `gpu`, `cpu`,
`storage`, `head` and `mgmt` classes with the attachment matrix, so CPU and
storage nodes are counted in the leaf port budget from the first rung rather
than discovered against a fabric already sized without them.

**S2 — 1,024 GPUs, two pods, two hosts.**
Placement, VXLAN stitch, DHCP relay, the dedicated 8896-MTU fabric VPC, and reduced-MTU
cross-pod paths (§5.1).

S2 must be **two pods**, not one. An earlier draft specified a single 1,024-GPU
pod and claimed it would "deliberately run on two hosts" — which the model
contradicts: pods are atomic (§5), so a one-pod fabric places onto exactly one
host no matter how many are available, and S2 would have exercised no VXLAN, no
relay, and no cross-host MTU at all. The rung would have silently validated
nothing. Two pods of 512 GPUs make the spine↔core path genuinely cross a host
boundary, which is the entire purpose of the rung.

The general rule this exposes: **a rung that tests cross-host behaviour must
contain at least two placement units.** Worth checking against every future
stage.

**S3 — 4,096 GPUs, pods appear.** The structural rung: third tier, per-pod
mgmt subnets sized to the pod. After this, growth is `+1 pod` forever, with no
further re-architecture.

**S4 — 10,248 GPUs.** Render sharding (serial render is 3.4 h at scale) plus
per-host exporters and Prometheus federation. One exporter cannot SSH-poll 392
switches.

**S5 — 33,040 GPUs.** SoT *capacity* within a single DC. Note this rung's
ceiling is deliberately not "shard NetBox": S0–S5 are single-DC and the only
partition key offered in §6 is per-DC, so sharding here would shard into one
piece and remove nothing. What actually binds at 33,040 GPUs in one DC is
**query and write throughput against one NetBox**. S5 is 6,720 devices and nodes
— modest — but ~500K interfaces and ~99K links, and it is the interface and cable
rows that drive index size, bulk-import time and pagination cost, not the device
count. (An earlier draft said "~100K devices"; ~100K is the *link* count.) True SoT partitioning has a real key only
once a second DC exists, so it lands at **S6**.

### 8.0a Host sizing must count nodes, not just switches

Measured on `gpufab-fabric-01` carrying S0, against the estimate this document
and `fabric.tf` were both built on:

| | assumed | measured |
|---|---|---|
| SONiC VS RSS | 4.00 GB | **4.12 GB** (30 VMs, 120.6 GB) |
| host node RSS | *not counted* | **0.34 GB** (container, not VM) |
| S1 total | 48 x 4.00 = 192 GB | 48 x 4.12 + 76 x 0.34 = **224 GB** |
| on a 251 GB host | "headroom" | **89%** |

The per-VM estimate was very nearly right. What was wrong is what the estimate
was applied to: **switch VMs only**. The host nodes — 76 of them at S1, 152 at
S2 — are containers rather than QEMU guests, so a sizing model that reasoned in
VMs could not see them at all. They are cheap individually and decisive in
aggregate.

89% is not headroom on a fabric that takes about an hour to converge. It is one
page-cache spike from the OOM killer choosing a switch at random, mid-deploy,
and the resulting failure looks like a flaky switch rather than a full host.

The correction is `n2-highmem-64` (512 GB), which puts S1 at 44%. The extra
cores are waste at 0.15 cores/VM; RAM is the entire constraint. Revised ladder:

| rung | switch VMs | host nodes | RAM | fits |
|---|---|---|---|---|
| S0 | 30 | 13 | 128 GB | highmem-32 |
| S1 | 48 | 76 | 224 GB | **highmem-64** |
| S2 | 106 | 152 | 488 GB | highmem-64 at 95% — needs 2 hosts |
| S3 | 270 | 595 | 1315 GB | 3+ hosts |

**This is what makes multi-host real rather than theoretical.** S2 is the first
rung that cannot fit any single machine, and `fabric_host_count = 2` alone does
not produce a fabric — it produces two disconnected half-fabrics. There is no
VXLAN stitching between hosts today; `fabric.tf` derives deterministic host
addresses *in anticipation* of it (`network_ip = cidrhost(..., 30 + count.index)`,
"so the inter-host VXLAN endpoints can be derived rather than discovered") but
nothing consumes them. Sharding a topology across hosts is unbuilt work, and
§8's "S2 = 2 hosts, S4 = 11" assumes it exists.

So the ceiling on this rung is not the ladder's arithmetic. It is that the
singleton called out in the table at the top of this document — *one clab file,
one host* — is still a singleton, and S2 is where that stops being survivable.

#### 5.6.1 Making `ops.tf` countable is a state migration, not an edit

The obvious implementation — put `count` on `google_compute_instance.ops` the
way `fabric.tf` already has it — is a trap, and worth writing down before
someone reaches for it.

Terraform identifies a resource by its **address**. Adding `count` renames
`google_compute_instance.ops` to `google_compute_instance.ops[0]`, and terraform
does not read that as the same machine under a new name. It reads it as one
resource destroyed and another created. The ops host is the one machine in this
design that is *not* stateless (§5.4): it holds NetBox, which is the SoT, and
Prometheus, which is the entire history. Destroying it to add a `count` meta-
argument loses both.

This is sharpened by timing: the machine-type correction in §8.0a asks for a
`terraform apply`. Had `ops.tf` been made countable first, that routine apply
would have silently included the destruction of the SoT — and a plan reading
`1 to add, 1 to destroy` looks unremarkable next to a legitimate instance
replacement.

The migration is `terraform state mv google_compute_instance.ops \
'google_compute_instance.ops[0]'` (and the matching `google_compute_address`)
BEFORE the plan is run, after which the address matches and terraform sees no
change at all. Verify with a plan showing **0 to destroy** — never with a plan
that merely looks reasonable.

The general rule this belongs to: **check `terraform plan` for what it
destroys, not for whether it resembles the change you intended.** The three
in-place updates in the §8.0a apply were verified this way, which is how the
`ops.tf` hazard was noticed before it was created rather than after.

#### 5.6.2 The isolation boundary was already breached — by a shell default

Isolation is not only a property of what the ops host *serves*. It is equally a
property of what every fabric host *reaches for*, and on 2026-07-26 that half was
broken across the whole fleet.

Stage 98 installs `gpufab-rebuild`, the unit that repopulates a preempted fabric
host from its SoT. It generates the script from a **quoted** heredoc, so this
line was written into the file verbatim rather than expanded at install time:

    SOT="${NETBOX_URL:-http://10.10.0.20:8000}"

Under systemd there is no `NETBOX_URL` — the unit carried no `Environment=` at
all — so the default won on every boot. `10.10.0.20` is **sim 2's** ops host.
Measured on `gpufab-s4-fabric`, whose SoT is `10.10.0.41`:

    systemctl show gpufab-rebuild.service -p Environment   ->  Environment=
    resolved SoT in that environment                       ->  http://10.10.0.20:8000

Every fabric host in the fleet would therefore have rebuilt itself from sim 2's
NetBox regardless of which sim it belonged to. That is precisely the boundary
§5.6 exists to draw, crossed by a shell parameter default.

**Why it was invisible.** Every sim is seeded from the same profile, so both
NetBoxes answer `200` and both report **124 devices**. The rebuild's own guard —
"can I read the SoT, and does it hold a plausible device count?" — passes against
the wrong sim exactly as convincingly as against the right one. There is no
device count, no HTTP status and no reachability probe that distinguishes them.
Only *identity* does, and nothing compared identities.

It also survived because it was tested in the wrong environment. Every
install-time check ran as the deploy user in a login shell, where `NETBOX_URL`
*is* set and the default never fires. The wrong value existed only in a context
no test ever entered. Stage 70 got the identical expression right on the same
host purely by accident of quoting — its heredoc is unquoted — so
`gpufab-exporter.service` carried `NETBOX_URL=http://10.10.0.41:8000` while
`gpufab-rebuild.service` carried nothing. **Two units, one host, two different
answers to "where is my SoT", and no check compared them.**

**The general rule.** *A value that must differ per sim must never have a
cross-sim default.* A default is a guess, and a guess that happens to name a
real, reachable, plausible-looking peer is worse than no value at all: absence
fails loudly on the first boot, whereas a wrong default silently rebuilds one
tenant's fabric from another tenant's intent. Where such a value is needed,
resolve it once at install time, **prove** it (authenticated `200` *and*
non-empty), bake it in, and assert it afterwards by reading back what the
runtime actually loaded — not the variable the installer hoped it wrote.
`tests/t12-recovery-units.sh` does this from the runtime side, including
resolving the script's own `SOT=` line under `env -i`, and additionally fails on
*any* NetBox address in the script that is not this sim's — because the failure
mode is not a missing address but someone else's.

### 8.0 S5 does not currently wire, and that is a real finding

`tests/t06-static` derives every profile and assigns **real interface names**
from the platform catalog. Doing so surfaced something the model's own
validation could not: three rungs were declared with cores that cannot be
cabled.

| rung | declared backend cores | actually needed | status |
|---|---|---|---|
| S3 | 15 | **16** | fixed — derives at 270 switches |
| S4 | 33 | **39** | fixed — derives at 626 switches |
| S5 | 105 | **248**, and then the core mgmt pool is exhausted | **blocked** |

The mechanism is the same in each case: the backend core fans out to every
spine, so core port demand grows with spine count, and at the declared counts
the busiest core needed 65 ports against the SN5600's 64. `derive()` was happy
throughout — it allocates addresses, not ports — so this was invisible until an
allocator existed that had to name a physical interface for every link.

**S5 is different in kind, and should not be fixed by raising the number.** 248
core switches of 64 ports each is not a core tier, it is an admission that the
topology is wrong: a 2-tier core built from 64-port switches cannot fan out to
S5's spine count, and past ~248 the core management subnet runs out as well. The
honest options are a **denser core platform**, a **3-tier core**, or accepting
that a single DC tops out below 33K GPUs — which is itself a defensible answer
and arguably the most realistic one, since §8.1 already grows by adding sites
rather than inflating one.

That decision is deferred deliberately rather than papered over. Until it is
made, **the S5 row in the table below describes a fabric that cannot be built**,
and the static suite fails on it by design rather than skipping it — a skipped
check would restore exactly the silence that hid it.

The general lesson, which is the reason the port allocator earns its keep:
**validation that never allocates a physical resource cannot detect a physical
impossibility.** The model checked that every address fits. Nothing checked that
every cable had a socket to land in.

### 8.1 Geographic rungs: how the target is actually reached

One DC does not hold 500K GPUs — not here and not in the real world. Past S5 the
fabric grows by **adding sites**, not by inflating one, which is also the only
honest way to model deployments at that size. Each geographic rung takes the
S5 DC as its unit and removes one more ceiling.

| stage | scope | DCs | GPUs | switches | `vm` / `cont` / `frr` | ceiling removed |
|---|---|---|---|---|---|---|
| **S6** | 4 DCs, one region | 4 | 132,160 | 7,864 | 140 / 36 / 4 | single-DC control plane + SoT sharding (per-DC key finally exists) |
| **S7** | 4 regions × 4 DCs, one country | 16 | **528,640** | 31,456 | 560 / 144 / 16 | latency-blind tooling; flat control-plane federation |
| **S8** | 3 countries × 4 regions | 48 | 1,585,920 | 94,368 | 1680 / 432 / 48 | single addressing/policy domain |

**S6 — multi-DC, one region (~131K).** The first rung where a DC is not the
world. Introduces DCI links, inter-DC eBGP, per-DC ASN blocks, and DC-boundary
route summarisation. Control plane goes from one instance to one **per DC** plus
an aggregator. Real inter-zone RTT (~0.5–1 ms) arrives free.

**S7 — multi-region, one country (~524K).** This is the target rung. The new
ceiling is **latency-blind tooling**: today's deploy orchestrator, exporters and
ControlPersist SSH all assume sub-millisecond RTT, and every per-device
round-trip silently becomes ~30 ms. Anything sequential over N devices stops
being viable and has to become fan-out. Also forces regional summarisation and
makes "lose a region" a runnable drill.

**S8 — multi-country (~1.5M).** Headroom rung, included to prove the model does
not stop. Adds sovereignty boundaries: per-country address blocks and policy,
global route policy, and intercontinental convergence at 100–250 ms. Control
plane becomes hierarchical — global over regional over per-DC — because flat
federation does not survive this many sites.

Note the `frr` column: **S7's 529K GPUs is 16 hosts at `frr` fidelity**. The
geography, the summarisation, and the convergence behaviour are all fully
exercised there. `vm` fidelity is then spent deliberately — one DC of the fabric
at a time — where ZTP and boot behaviour are the question.

### 8.2 Fidelity is orthogonal to the ladder

Fidelity is not a rung. Every stage runs at any fidelity off the same rendered
config, so *how big* and *what it costs* are independent choices. `vm` is the
default at every rung — S0–S4 are all affordable at full fidelity (10K GPUs = 8
hosts, ~$9.81/hr spot). `frr` exists so that a scale question never becomes a
budget question: S5 is 35 hosts at `vm` and 1 at `frr`, same topology.

### 8.3 What "no ceiling" means in practice

Pushed past S5, the model does not refuse a number — it names a structural
conflict and the knobs that resolve it:

> `pod dc1-pod001 needs 262 GB but a host offers 239 GB. Shrink the pod template,
> use a bigger host, or lower fidelity — a pod must not be split across hosts.`

Contrast `dgx_count ≤ 9`, which explains nothing and can only be resolved by
editing source. That is the whole difference this architecture buys.

---

## 9. Static analysis: verifying a render before anything boots

### 9.1 Why this is not optional at the target scale

Every check this system currently trusts requires a **running fabric**. The
tests in `gpufab-platform/tests/` assert against live BGP sessions, live
`config_db` reads, live `iptables` state. That is the right instinct — a check
that reads files rather than running state is how this project shipped "unnumbered
deploy complete: 249/249" while every switch was still numbered — but it has a
ceiling built into it: **you cannot test a fabric you cannot boot.**

§8.0a puts numbers on that ceiling. S1 needs 48 switch VMs and 224 GB. S3 needs
270 and 1.3 TB across seven hosts, and S5 cannot be cabled at all. The ladder
runs out long before the 200–500K GPU target, and the rungs that matter most —
the ones where an addressing or policy mistake is most expensive — are precisely
the ones no lab will hold.

Static analysis inverts that. Batfish ingests **configuration text** and builds a
routing model from it: no QEMU, no boot, no per-switch RAM. A snapshot of 2,000
devices costs what parsing 2,000 files costs. It is the only verification in this
design whose cost does not scale with fidelity, which makes it the only one that
reaches the top of the ladder.

The rule that follows: **emulation proves the platform, static analysis proves
the intent.** They are not redundant and neither substitutes for the other.

### 9.2 The SONiC backend has a trap, and it is silent

Batfish has a first-class SONiC backend, which is why this is viable at all. But
its `config_db.json` parser reads **17 tables, and `BGP_NEIGHBOR` is not one of
them.**

What it does with the rest is the problem:

| step | behaviour |
|---|---|
| encounters `BGP_NEIGHBOR` | drops the table, emits a parse **warning** |
| builds the model | zero BGP sessions |
| reports snapshot status | **parsed successfully** |

So a `config_db`-only snapshot yields a fabric that Batfish considers valid, with
no BGP anywhere, and every BGP question answered "no sessions" — which is
indistinguishable from "no sessions are broken". Ask it *are any sessions
failing?* and it says no. It is the exact failure shape this project keeps
finding: **a check that passes because it measured nothing.**

A green Batfish run against `config_db` alone would be the most dangerous
artifact in the system, because it carries more authority than an unrun check.

### 9.3 `frr.conf` is the precondition, and it is already built

Batfish reads BGP from `frr.conf`, and for the SONiC backend that file is
**mandatory** — absent, the parser throws rather than warning, which is the
correct failure and the opposite of the `BGP_NEIGHBOR` behaviour.

This is the same artifact §5's unnumbered work already required. SONiC's
`config_db` cannot express an interface-keyed neighbour at all (bgpcfgd emits
nothing for one — upstream `sonic-buildimage#26960`), so unnumbered BGP requires
FRR split mode with a rendered `frr.conf`. `nos_catalog.yaml` records this as
`bgp_unnumbered_requires: frr_split_mode`.

So one artifact unlocks both, and `gpufab-network/tools/frr_render.py` already
emits it from the **same derived intent** that produces `config_db`. That
single-derivation rule is load-bearing here specifically: two renderers producing
"the same" config from one source is how this project shipped a fabric whose BGP
peers sat on subnets that did not exist. A drift between these two artifacts
would be worse, because they land on the *same device* — and Batfish would be
verifying a file the switch does not run.

### 9.4 Where it sits: a gate on the PR, not a step in the deploy

The GitOps loop is NetBox → webhook → relay → `repository_dispatch` → render →
PR. Batfish belongs **on that PR**, before merge:

```
NetBox change
   └─> render (config_db + frr.conf, one derivation)
        └─> PR opened
             └─> BATFISH GATE  ← snapshot the rendered/ tree, assert, block merge
                  └─> merge -> deploy
```

Deploy-time analysis would be too late by definition: the point is to reject a
render, and by deploy time the render has already been accepted. PR-time also
means the artifact analysed is byte-identical to the artifact deployed, since
both are the committed `rendered/` tree — not a re-derivation that could differ.

This gate must obey §9.2. It fails the PR if the snapshot has **zero BGP
sessions**, if any device is missing `frr.conf`, or if the parsed device count
disagrees with the model's — before it evaluates a single policy question. A
Batfish assertion that runs against an empty model must be a failure, never a
pass, for the same reason `t_zero` in the test harness now rejects a
non-numeric observation instead of reading it as "none found".

### 9.5 What it catches, and what it cannot

Honest boundaries matter more than the capability list, because the failures this
project has actually hit fall on both sides.

**Would have caught:**

| failure | how |
|---|---|
| BGP peers on subnets that did not exist | session compatibility — endpoints not on a shared subnet |
| `redistribute route-map LOOPBACK-AND-DATA` never defined | `undefinedReferences` |
| host `frr.conf` rendered with zero neighbours | session count per device against the model |
| numbered/unnumbered mismatch | neighbour form is visible in the parsed config |

**Would NOT have caught — all real, all found only by running the fabric:**

| failure | why static analysis is blind to it |
|---|---|
| every SONiC VS shipping base MAC `22:3c:85:c1:e4:36` | a property of the image, not the config; unnumbered peers by link-local, so all 28 switches addressed themselves |
| `containerlab deploy` exiting with output discarded | emulation, not intent |
| exporter retaining stale label sets (478 up of 477) | observability, not routing |
| `config reload` never applied | the config on disk was correct; the device was not running it |

That last row is the general case, and it is the one to keep in view: **Batfish
verifies the file, never the device.** It cannot tell you a switch is running the
config you analysed. That gap is exactly what the live tests cover, which is why
§9.1 says neither substitutes for the other.

### 9.6 Cost and placement

Batfish runs as a container (`batfish/allinone`), stateless, holding snapshots in
memory. It belongs on the **ops host**, not the fabric fleet: it consumes the
`rendered/` tree, which is a product of the SoT, and the fabric hosts are
stateless emulation capacity (§5.4) that a preemption may remove at any time.

Sizing follows §8.0a's lesson — derive it from what is actually consumed rather
than asserting a constant. That measurement has not been taken, so this document
does not name a number. What is already known is that the ops host was found to
be **CPU-bound, not RAM-bound** (§8.0a), NetBox alone consuming 350% of four
cores, and Batfish is a JVM doing graph work on the same machine. It must be
sized against a measured snapshot at S1 before being enabled at S3.

**Status: designed, not built.** `frr_render.py` exists and emits the required
artifact; the gate does not exist. The precondition is in place, which is the
part that usually is not.

---

## §5.7 Deploy invariants established by the 2026-07-27 review

Three review rounds against the deploy path produced twelve findings, six
regressions in the fixes for those findings, and three further defects in the
fixes for *those*. The ratio is the point: each change was small, individually
plausible, and wrong in a way that only reading it again exposed. What follows
are the invariants that survived, recorded so they are not re-litigated.

### A run that runs nothing must not report success

`--from` matching no stage exited 0 and printed "deploy.sh complete", and
recorded a profile for a deployment that never happened. `--reboot` had the same
shape earlier: on a fabric host its start marker was a head-only stage, so stage
98 logged "rebuild COMPLETE" one second after starting. Every selector now fails
when its prefix matches nothing.

### Status must be captured, and failure must change the exit code

`roles/head.sh` turned a failed `deploy.sh` into a log line, and its component
verification logged what was missing and returned success — so an unattended
seed handoff printed "head role complete" after a failed seed. Verification
whose failure changes nothing is not verification. The head role now exits
non-zero, deferred to the end so the operator still sees the whole picture.

### Scope must be recorded, never inferred

The fleet watchdog owned every host in the zone matching `name~fabric`, and
every head installs it — so each sim could restart another sim's fleet (§5.6).
An unknown scope previously meant *act on everything*, the worst default for
something that starts machines; it now refuses to install. Note `FABRIC_HOSTS`
is a list of **VPC addresses**, not instance names, and must be resolved.

The same principle settled the firewall teardown. Selecting rules by a `172.*`
address was wrong in both directions: stage 45's `ESTABLISHED,RELATED` rules
carry no address and survived every teardown while being invisible to the check
that then called the chain clean, and any unrelated rule mentioning `172.x`
would have been deleted. **Ownership is a property of who installed a rule, not
of what it matches**, so stage 45 tags every rule it installs and teardown
deletes exactly those.

### Expectations must be local when the thing measured is local

Spot recovery compared local `clab-*` containers against NetBox's **global**
device count. Equal on a single-host fabric, so it worked by coincidence — but
once a topology is sharded, a healthy shard has local < global *by
construction*, and every shard would be declared partial and destructively
rebuilt. A recovery unit that destroys healthy fabrics is worse than none.
Expected node count now comes from the local topology file, and observed counts
`clab-gpufab-` rather than every containerlab lab on the host.

### Self-update must not change the code mid-decision

Stage 00 force-checks every repo out to `origin/main` — deliberately; that is
what makes a host self-update rather than replay stale disk. But roles and stage
order are computed *before* it runs. Failing when HEAD moves is safe and was
rejected: it turns self-update into a two-run workflow and destroys the
one-command property. The orchestrator re-execs from the new revision instead,
bounded to one hop. A **second** movement fails loudly, because re-execing again
could loop against a branch being pushed to.

### A credential that silently exists is worse than one that is absent

`lib.sh` supplied a hardcoded development token as its final fallback, so every
consumer received a valid-looking credential whether or not one was provisioned,
and stage 98's "refuse to bake a default" guard was unreachable. The absent
credential fails where somebody is watching; the defaulted one fails at 03:00
during a preemption. The fallback is now the secrets file or nothing.

### Structural tests read the generator, not what the host runs

`t22` passed 37/37 while the recovery token was a literal string. The rebuild
body is a **quoted** heredoc, so escapes land verbatim: `\${NETBOX_TOKEN:-}`
reads fine in the generator and is not a parameter expansion at all on the far
side — never empty, past the guard, sent to NetBox as the token. Assertions
about generated scripts must render the heredoc and assert on the result.

### Checks must fail fast when they cannot measure

`verify.sh` ran ~13 host phases through IAP against stopped instances, each
hanging until its tunnel timed out, to discover what one instance-status call
answers in a second. A suite that spends minutes reporting nothing is the same
defect as one reporting success having measured nothing, only more expensive.
Phase 2 is now gated on a preflight.

### Still open

- **Sharding** — placement exists (`_shard()` → `fabric_model.place()`, pod-atomic
  with round-robin cores); end-to-end provisioning ownership does not.
- **Routed management** — ZTP/DHCP and TACACS on the head (§above) is unbuilt:
  no DHCP relay exists, and stage 45 would drop the head-hosted flows anyway.
- **`s5-32768`** — demands 70 links on a 64-port switch. The guard is correct;
  the profile must change while S5 is a declared deployable rung.


---

## §5.8 Sim isolation: what is a boundary and what is not

Written after a review found that §5.6's "nothing is shared" described an
intent rather than the implementation. The distinction matters because the two
failure modes are different: service separation stops sims from *corrupting*
each other by accident, a security boundary stops one from *reaching* another on
purpose. We have the first, and only parts of the second.

### Genuinely isolated

- Separate NetBox, Postgres, Prometheus TSDB, Grafana and disk per ops host.
- Unique VM names and deterministic internal addresses.
- Containerlab state and simulated network namespaces are host-local.
- Log artifacts are namespaced per sim **and per run** (`logs/<sim-id>/<run-id>/`).
- The fleet watchdog owns an explicit host set and refuses to install on unknown
  scope, rather than inferring fleet-wide ownership.
- **The NetBox credential is per-sim** (`gpufab-netbox-token-<sim-id>`). A
  credential valid for one sim is rejected by another's NetBox.
- **Sim-scoped firewall rules**: a per-sim ALLOW at priority 900 and an explicit
  cross-sim **DENY at 950**, which is what actually creates the boundary. The
  allow alone did not: a rule that does not match is disregarded, not treated as
  a denial, so sim A→B fell through B's allow to the role-wide allow at 1000 and
  was permitted. The deny sits between them.

### NOT a boundary — do not rely on these

- **One bucket, one service account.** Run and sim prefixes are correct
  *naming*, but no prefix-conditioned IAM exists, so a compromised host can read
  or overwrite another sim's prefix. Attribution, not isolation.
- **Role-wide firewall rules remain in force** as the fallback. The sim-scoped
  rules narrow the common path; they do not remove the role-wide reachability
  beneath them.
- **Identical SSH keys and one service account on every instance.** There is no
  per-user identity anywhere, so "one user cannot see another's dashboards" has
  no enforcement behind it. That is a design requirement with no implementation.
- **Upgraded sims until they rotate.** A sim carried over from the shared-token
  era republishes that same value under a per-sim NAME unless it rotates —
  identical credential, isolated-looking. `setup_netbox.sh` now detects the
  legacy value, rotates off it, and revokes stale tokens, but a sim that has not
  re-run stage 20 since is still sharing.

### The acceptance test this needs

Isolation claims should be proven negatively, because the positive form ("A can
reach its own things") passes in a world with no boundary at all. Sim A's fabric
must be unable to:

1. authenticate to sim B's NetBox,
2. write sim B's artifact prefix,
3. reach sim B's console or exporter,
4. claim a GitHub job dispatched for sim B.

Status: **1, 3 and 4 are addressed** — per-sim credentials with stale-token
revocation, a cross-sim DENY between the per-sim and role-wide allows, and
workflow routing on `client_payload.sim_id` with a runner identity assertion and
no repository-global NetBox values. **2 is not**: one bucket and one service
account with no prefix-conditioned IAM, so prefixes remain attribution.

**None of it is tested, and none of it has run.** Every claim here is verified by
reading code, not by a sim failing to reach another sim. Until the negative test
above actually executes, treat this section as design intent with an
implementation behind it — not as a demonstrated boundary.

Beneath all of it: identical SSH keys and one service account on every instance,
so there is no per-user identity anywhere. This is a **sim** boundary, never a
customer one.

---

## §5.9 Overlapping the fabric with the seed

**Status: scoped, not implemented.** Measured, not estimated: on the last
complete build the fabric host sat at load 0.0x for **657 seconds** — eleven
minutes of a 64-vCPU machine doing nothing — waiting for the head to bring up
NetBox and finish `30-seed`. That is the single largest remaining item in a
~40-minute build, larger than the golden image (~3m30s measured) by a factor of
three.

### The gate is stronger than the dependency

`roles/fabric.sh` waits for a COMPLETE seed before doing anything. That gate
exists for a good reason — it closed a real race where a cache-hot fabric host
entered topology generation while the head was still writing cables — but it
blocks *all* fabric work, when only *some* fabric work actually needs the SoT.

What `clab/gen_topology.py` reads from NetBox is narrow:

- `nb.dcim.devices.filter(site="sim-dc1")` — name, `node_class` custom field,
  device-type slug, mgmt IP;
- cabled interfaces, to build the link list.

**Every one of those is a pure function of the profile.** `fabric_model.derive()`
already produces them, and this is not speculative: `t14-port-table.sh` and
`t20-insync-skip.sh` both drive the REAL renderer and the REAL push-intent
builder over a profile-derived SoT with no NetBox running. The machinery for a
NetBox-free topology already exists and is under test.

The SoT is genuinely required only for **rendered config** — stage 50. Booting
nodes is not gated on it.

### The change

Split the fabric role's single wait into two:

| phase | needs | can start |
|---|---|---|
| generate `gpufab.clab.yml`, `containerlab deploy`, wait healthy, config-DB ready | profile only | immediately |
| render + push config (stage 50 / ZTP) | the SoT | after seed completes |

Measured costs of the work that moves earlier: `clab-deploy-healthy` **167s**,
`config-db-ready` **28s**. Both fit inside the 657s window with room to spare, so
the overlap is bounded by the head, not by the fabric.

### The trap that makes this dangerous

**The topology the fabric boots must be identical to the one the SoT later
describes.** If they diverge, switches are configured for a fabric that is not
there — no error anywhere, because each side is internally consistent. That is
precisely the shape of the 32-port PORT table applied to 64-port switches, which
rendered cleanly, applied cleanly, passed a rendered-vs-applied check, and lost
178 BGP sessions.

So the profile identity check stops being a nicety and becomes load-bearing:

1. The fabric records the profile content hash it derived its topology from.
2. `seed-complete.json` already carries `profile_sha` (written only after cables
   exist).
3. Before stage 50, the fabric asserts **exact equality**. A mismatch is fatal
   and must say which profile each side used — not "waiting", which is how a
   divergence would otherwise present.

This is the reason the completion record exists. Until now it was written and
never read; this change is what makes it earn its place.

### Sequencing

1. Add `--from-profile` to `gen_topology.py`, deriving devices and links from
   `fabric_model` instead of NetBox. Assert it produces a topology **byte-identical**
   to the NetBox path on a seeded fabric — that equivalence is the whole safety
   argument and must be a committed test, not a one-off comparison.
2. Split `roles/fabric.sh`'s wait as above.
3. Make the `profile_sha` comparison fatal before stage 50.
4. Re-measure. The claim to check is that fabric idle time collapses from ~657s
   to near zero, and that total build time drops by roughly that much — if it
   does not, the bottleneck was somewhere else and this bought nothing.

### What this does not fix

The head remains serial: NetBox up (**278s**) then `30-seed` (**409s**). Nothing
here shortens that, it only stops the fabric waiting on it. If the target is 15
minutes, the head's 687 seconds is the next thing to attack after this — and an
ops-side golden image addresses only the container-pull portion of the 278s, not
the migrations or the seed.

---

## §5.10 Physical first, SoT reconciled after

§5.9 scoped booting the NOS VMs before the SoT is seeded, and framed it as an
optimisation that had to be defended against the risk of diverging from NetBox.
That framing was wrong, and the correction matters more than the optimisation.

**This is the order real network operations already runs in.** Nobody waits for
DCIM to be populated before racking and cabling. The physical topology is built
from a plan, the devices are powered on blank, DCIM records the intent, ZTP
serves config derived from DCIM, and only afterwards is the wiring audited
against the record — LLDP neighbours compared to what DCIM says should be there.

The mapping is exact:

| real DC | this simulator |
|---|---|
| cabling plan, in version control | profile in `gpufab-network/design/profiles/` |
| rack and cable the hardware | `containerlab deploy` from that profile |
| DCIM populated from the plan | `seed.py` → NetBox |
| switches powered on, no config | SONiC VMs boot blank |
| ZTP serves config derived from DCIM | stage 50, rendered from NetBox |
| audit cabling against DCIM | reconciliation, after the fact |

So a fabric that boots from the git-held plan is **more** faithful than one that
idles eleven minutes waiting for NetBox, not less. The waiting version models an
order of operations that no physical data centre uses.

### This does not create a second source of truth

The two artifacts have different jobs, exactly as they do in real operations:

- **Git holds design INTENT** — the cabling plan. It says what should be built.
- **NetBox is the operational RECORD** and the source for rendered config. It
  says what exists and what each device should be running.

`seed.py` populates NetBox from the same profile, so the record is derived from
the intent rather than competing with it. There is one derivation
(`fabric_model.derive()`) and two consumers.

### Reconciliation is what makes it sound

§5.9 proposed comparing the profile's content hash against `seed-complete.json`.
That is weaker than it looks: it compares **intent to intent**, and passes
happily if both sides agree about a topology that was never actually built that
way.

The real check is the one physical networks run: compare what is ACTUALLY wired
against what the record says. In this simulator that means, after the SoT is
seeded, asserting that the booted topology's adjacencies match NetBox's cable
list — the equivalent of LLDP-neighbour validation against DCIM.

That is strictly stronger, and it would have caught a real defect from this
work: an early version of `--from-profile` supplied positional interface names
instead of the assigned ones, which `port_index()` would have turned into wrong
port numbers and a miswired fabric. Every layer would have remained internally
consistent — the exact signature of the 32-port PORT table that reached 64-port
switches and cost 178 BGP sessions. A hash comparison would not have noticed.
Reconciling reality against the record would.

**Status: intent recorded, reconciliation NOT implemented.** `--from-profile`
exists and is verified to produce 124 nodes / 1466 links / 48 sonic-vm with no
NetBox running. The fabric role does not yet use it, and the reconciliation check
does not yet exist. Neither should ship without the other.

---

## §5.11 SNMP: configure it, do not suppress it

**Status: scoped, not implemented. Supersedes the `disable_features` stopgap.**

### What is wrong today

Every SONiC VS switch inherits `SNMP_COMMUNITY {"public": {"TYPE": "RO"}}` from
whichever machine the base snapshot was captured on. Nobody here chose it. It is
a world-readable read-only community string on all 48 switches.

`DROP_TABLES` therefore deletes `SNMP`/`SNMP_COMMUNITY`, and `config_landed`
requires them ABSENT. But `docker-snmp`'s `/usr/bin/start.sh` runs
`snmp_yml_to_configdb.py` on every container start, which reads
`/etc/sonic/snmp.yml` and writes back every entry it does not already find. So
the push deletes them and the image restores them, and **the invariant "no
default community on our switches" has never actually held on any build.** Its
only visible symptom was `skipped(in-sync)` being 0 — the fabric was never in
sync because the difference was re-created after the config landed.

### Why the current fix is a stopgap

`e4f0eb0` disables the `snmp` feature so the container never starts. It makes the
invariant true for the first time and is correct as far as it goes, but it rests
on a fragile mechanism, **measured**: `state=disabled` does NOT inhibit the
writer, it only stops the platform starting the container. Force-started, the
tables returned within 102s despite `state='disabled'`, and hostcfgd did not
re-stop it within five minutes. Anything that starts that container restores the
default community silently.

It is also the wrong shape for a simulator. Real switches run SNMP with a
deliberately chosen community. Disabling it entirely trades a security problem
for a fidelity gap.

### The replacement

**Derive a per-switch community; render it; write it where the image reads it.**

1. `community = HMAC(<per-sim secret>, <device name>)` — deterministic, so the
   renderer computes it without a lookup and no per-device credential is stored
   or rotated individually. The per-sim secret follows the existing
   `gpufab-netbox-token-<sim>` pattern.
2. The renderer EMITS `SNMP`/`SNMP_COMMUNITY` with that value, and both come OUT
   of `DROP_TABLES` — they are legitimate config now, not contamination.

   **CORRECTION, found in implementation: doing literally only that is a trap.**
   The unconditional STRIP must stay. Removing them from `DROP_TABLES` stops us
   deleting our own community, but without an unconditional strip first, a fabric
   with NO secret configured launders the base snapshot's `public` straight into
   the pushed config — and then compares in-sync against it forever. Order:
   strip both unconditionally, then add ours if a secret exists.

2b. **Set `FEATURE.snmp.state` explicitly.** Absent from this design and it is the
   load-bearing half on any fabric that ran the `disable_features` stopgap:
   deleting that function does NOT reset what it wrote, because the push inherits
   `FEATURE` verbatim from the box. Measured on s9 — every table correct,
   community correct, and nothing running. The in-sync check must compare the
   feature state too, or a switch with SNMP configured-but-disabled looks
   identical to one working.
3. The deploy writes `/etc/sonic/snmp.yml` with the same value (`sw_ssh` already
   exists for this). **This is the part that makes it robust rather than a
   trick**: `snmp_yml_to_configdb.py` then writes back exactly what we rendered,
   so the container start is idempotent with our intent instead of fighting it.
   There is no drift to suppress and no feature to keep disabled.
4. `disable_features` is removed in the same change — not before, since it is
   currently the only thing making the invariant true.

The in-sync problem dissolves as a side effect: render and box agree on those
tables, so switches compare equal and the skip path works without special cases.

### Where the secret lives

NetBox records **that** SNMP is configured and which derivation is in use. It does
NOT hold the community value: NetBox has no secret store (the plugin was removed
upstream), so a custom field is plaintext in the SoT and in every API response.
The secret belongs in Secret Manager — the same split already used for the NetBox
token, where NetBox holds intent and Secret Manager holds the credential.

### Departures from this design, made deliberately

- **The secret is generated on the FABRIC host, not published by the head.** The
  fabric is its only consumer, and routing it through the head would reintroduce
  the 30-minute credential stall (#53). Secret Manager is a backup, not the
  delivery channel.
- **The community must never reach a log.** `config_landed` names the KEYS that
  differ — and an SNMP community IS the key of `SNMP_COMMUNITY`, so the
  diagnostic leaked the secret it was diagnosing. Secrets print as
  `sha:1a2b3c4d`; `public`/`private` stay named, because naming them is the
  diagnosis.

### Measured result (gpufab-s9, s1-512)

| | stopgap (`e4f0eb0`) | this design |
|---|---|---|
| `SNMP_COMMUNITY` on box | absent (suppressed) | derived value, exact |
| `public` present | n/a | 0 of 48 artifacts, 0 of 5 boxes |
| `FEATURE.snmp.state` | `disabled` | `enabled`, container Up |
| `skipped(in-sync)` | 45 of 138 records | **46 / 46 / 46** over three runs |
| BGP peer series | 1464/1464 | 1464/1464 |

The community survives a deliberate container restart — asserted separately from
the restart itself, so a container that never came back cannot pass. Negative
direction unchanged: factory config, missing BGP peer, 32-port PORT table, stale
`public`, wrong TACACS server, rotated passkey, wrong hwsku and empty INTERFACE
all still push 46/46.

**NOT yet verified: a cold build.** Hosts fetch `origin/main`, so this was proven
by pushing to a running fabric, not from a factory boot. On a cold build the
`delayed` snmp container may start before the push reaches a switch and add
`public` alongside ours; the first push corrects it with a reload and the second
is clean. Avoiding that entirely needs `snmp.yml` shipped through ZTP.

### Open question

Whether the fidelity work wants SNMP polling. If it does, this is a fidelity
IMPROVEMENT rather than only a security fix, which would raise its priority above
the 657s idle window (§5.9/§5.10).
