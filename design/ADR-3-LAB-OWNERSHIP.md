# ADR-3 — lab ownership, lifecycle, and OOB routing

Status: **PROPOSED.** Not authorized for implementation.

This is an ownership table, a set of state transitions, and executable acceptance
cases. It is deliberately not a narrative: ADR-4 took seven revisions of prose to
settle one integer, and the lesson taken from that is that contracts belong in
tables and tests.

Measured facts are marked as such. Nothing here has been built.

---

## 1. The primitive already exists and was measured

`deploy/checks/c10-lab-per-pod-shared-bridge.sh` is an L1 micro-integration that
ran on a real fabric host against real containerlab and the real SONiC-VS image,
with a `{name,Id,StartedAt}` manifest of every live container asserted before and
after so the running fabric provably was not touched.

It settled the substrate question:

- **Option 1 — one lab, `clab apply` to add pods — is CLOSED on clab 0.77.**
  Measured: `Interface c9fab0:c9n1a is defined via topology but already exists`.
  The re-presented topology re-declares the first pod's bridge veth;
  `CheckEndpointDoesNotExistYet` errors. The endpoint name is mandatory so it
  cannot be dropped, and omitting it makes reconcile DELETE the running pod's
  uplink.
- **Option 2 — a lab per unit, attached to pre-created host bridges — works**, and
  is maintainer-endorsed (srl-labs/containerlab #1440). A foreign unit's endpoint
  is never named in another unit's topology, so the c9 failure is structurally
  impossible, and no link is ever added to a running VM — which matters because
  vrnetlab/sonic-vm fixes NIC wiring at VM boot.

**ADR-3 adopts Option 2 and extends c10 in one respect: many independent
two-port bridges, never one shared bridge.** c10 used a single shared bridge,
which is a broadcast domain — every attached link would see every other link's
frames. One bridge per link keeps each spine↔core adjacency a point-to-point
segment, which is what the model describes.

---

## 2. Ownership

| resource | owner |
|---|---|
| pod containers, topology, mgmt network | the **pod lab**, from manifest R |
| cores assigned to one physical host | the **core-shard lab** on that host, from R |
| the two-port cross-lab bridge | the **host-level link controller** — neither lab |
| cross-host VXLAN endpoints | **local host controllers**, paired by one exact R link identity |
| end-to-end link identity | **manifest R**, including the parallel-link discriminator and VNI |

Two consequences follow and are binding:

- **A lab never creates or destroys a bridge.** If either lab owned it, the
  bridge's lifetime would be tied to one endpoint and destroying that unit would
  tear down a link the other unit still holds.
- **A link's identity is not `(a,z)`.** The micro fixture has 14 parallel
  spine↔core links between one pair, and S2 has 8. The discriminator is part of
  the identity in R, because keying on endpoints alone has silently collapsed
  parallel links three times in this project.

---

## 3. State transitions

Bring-up, per unit:

1. Create and **verify** the unit's bridges and VXLAN endpoints.
2. Create the unit's management network and OOB route.
3. Deploy **only** that lab.
4. Validate: exact endpoint identities, management reachability, dataplane, and
   that **other labs are unaffected** — c10 already demonstrates that assertion
   shape with its before/after container manifest.

Teardown, per unit:

5. Drain, then destroy **the lab first**.
6. Remove a bridge **only after R proves both endpoint owners are absent**.
7. The revision stays **RED through every partial state**.

Step 6 is the one that cannot be reordered: a bridge removed while a peer still
holds its half leaves that peer with an endpoint terminating on nothing, which
every local check reports as healthy.

---

## 4. OOB routing — the unresolved issue, measured

Per-lab `/24`s solve `gen_topology.py`'s one-mgmt-network restriction. **They do
not solve routing.** Measured on the micro fixture at a two-host placement:

    mgmt /24        hosts holding addresses in it
    172.20.0.0/24   [(host-pod001, 16)]
    172.20.1.0/24   [(host-pod002, 16)]
    172.20.2.0/24   [(host-pod001, 3), (host-pod002, 3)]   <-- SPLIT

Pod `/24`s sit entirely behind one host and route with one next-hop. **The shared
core tier does not**: one prefix, two next-hops, and the head cannot choose. At
S2 the same shape appears with 10 cores split 5/5.

### Options, costed

| | mechanism | cost at S2 | scaling |
|---|---|---|---|
| **A** | `/32` host routes for cores | 10 core routes + 2 pod routes = 12 | grows with CORE COUNT — S3 has 16 backend cores, S4 has 39 |
| **B** | separate routing domains | not costed | highest complexity; not evaluated here |
| **C** | a `/24` per **(tier, host)** | 4 subnets, 1 route each | grows with HOSTS, not cores |

**Recommendation: C**, with one consequence stated plainly rather than
discovered later — **it makes the address plan depend on placement.** Today
addressing is derived from the profile alone; under C the core tier's subnets are
a function of which host owns which core. Option A keeps addressing and placement
independent but pushes the same information into the routing table, where it
grows with the core count rather than the host count.

**Capacity warning, measured:** four `/24`s is exactly a `/22`, so S2 under
option C fills the pool with zero spare. A third host, or any growth, needs
`/21`. Sizing the pool at `/22` because S2 fits would be the same class of error
as sizing a host by its converged-idle RSS.

This decision is **not made here**. It requires the acceptance cases in §5 to be
run, because "the head can reach every core on both hosts" is a claim about
routing that only a two-host run can settle.

---

## 5. Executable acceptance cases

Written to be implementable as tests, not as prose. Each names what it measures
and what would make it a false pass.

**One host — pod-1 lab + pod-2 lab + one core lab, micro fixture**

| # | case | false pass it prevents |
|---|---|---|
| A1 | each lab has exactly one mgmt network; three labs, three distinct subnets | a merged lab spanning subnets, which `gen_topology` refuses |
| A2 | every spine↔core link is its **own** two-port bridge | one shared bridge — a broadcast domain in which flooding masks miswiring |
| A3 | each bridge's two endpoints match R exactly, including the parallel discriminator | counting 14 links between a pair while they are cross-connected |
| A4 | destroying pod-2's lab leaves pod-1's containers with identical `{name,Id,StartedAt}` | a restart counted as "unaffected" |
| A5 | destroying pod-2 leaves its bridges present until R shows both owners absent | a bridge removed while pod-1 still holds its half |
| A6 | the **canary path** below, measured continuously across pod-2's destroy | "still running" while degraded |
| A7 | the revision is RED in every partial state | a green verdict mid-transition |

### A6's service level — a tested canary path, not the pod dataplane

Fixed, so "measured continuously" has a number behind it:

- configure ONE exact pod-1-spine ↔ core point-to-point path across its dedicated
  bridge;
- require **20/20** successful baseline probes before anything is destroyed;
- probe every **200 ms**, from before pod-2's destruction until **ten seconds**
  after it completes;
- require at least **50 transmitted** packets and **exactly zero loss**;
- require pod-1 and core `{name,Id,StartedAt}` manifests unchanged;
- require every bridge formerly shared by pod-2 and core to remain **present and
  correctly attached** after pod-2 disappears.

It is called a canary path deliberately. It is one link, not the pod's dataplane,
and claiming otherwise would be the same overreach as calling a converged-idle
RSS sample a capacity allowance. What it proves is that destroying one unit does
not disturb a path that crosses the shared tier — which is the property under
test.

**Two hosts — replace selected bridge halves with VXLAN 14789**

| # | case | false pass it prevents |
|---|---|---|
| B1 | each cross-host link's VXLAN endpoint matches its R tuple: both ends, both interfaces, VNI, remote IP, UDP port | a count of tunnels that are up but cross-connected |
| B2 | the head reaches **every core on both hosts** — the §4 decision, measured | a routing table that resolves for the cores on one host only |
| B3 | partitioning is derived from R, not from hostname or address arithmetic | `--host $(hostname)` on a disposable VM |
| B4 | losing one host: revision RED, surviving pod measured against a **defined** service level | pod-1 "running" with half its core uplinks gone |
| B5 | recovery scope is {pod, its cores, their tunnel ends}, host-1 objects untouched throughout | a global rebuild |

---

## 6. What this does not authorize

No implementation. No change to `gen_topology.py`, `oob_plan.py`,
`40-topology.sh`, `up.sh`, or any Terraform. No firewall rule. Nothing pointed at
the live pair. The `/24`-per-(tier,host) proposal in §4 is a recommendation
awaiting the §5 evidence, not a decision.
