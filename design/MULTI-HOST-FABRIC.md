# Multi-host fabric — the design for blocker 1

Status: **DESIGN, not authorized for implementation.** Nothing here has been
built or run. It exists to be reviewed before anything is.

Scope: what S1→S2 needs in order to run one fabric across two hosts — placement,
per-host management, routed DHCP/ZTP, core attachment, and cross-host links.
It does **not** design the S1→S2 migration itself (step 4) or authorize any
change to the live pair.

Everything below that states a number was measured on 2026-09-02 against the
committed model. Where something was not measured, it says so.

---

## 1. The finding that reframes this

Three of the four layers **already implement multi-host.** This design is much
smaller than "build multi-host support", and writing it as though nothing exists
would have re-specified working code.

| layer | state | evidence |
|---|---|---|
| model / placement | **built** | `fabric_model.place()` returns `assign`, `hosts`, `cross_links` |
| topology generation | **built** | `clab/gen_topology.py --host` emits one host's slice; cross-host links become VXLAN |
| infrastructure | **built** | `terraform/fabric.tf` `variable "fabric_host_count"`, `cidrhost(…, 30 + count.index)` |
| orchestration + OOB | **NOT built** | see §4 |

`fabric.tf:5` already says it: *"growth past S1 is `fabric_host_count = N`, not a
new design."* `gen_topology.py:280-281` already says it: *"--host emits ONE host's slice. A
link with both ends here is an ordinary veth; a link with one end elsewhere
becomes a VXLAN tunnel to that host."*

The gap is the **lifecycle and the management plane**, not the fabric.

---

## 2. Measured facts

    fabric_model.py s2-1024.yaml --placement
      GPUs 1,024 | pods 2 | switches 106 | nodes 152
      links 3,332 (host 2,772 + interswitch 560)
      fabric hosts 2 (derived) | cross-host links 200 (6.0%)

Placement, per host:

    host-pod001: leaf 40, spine 8, core 5, nodes 76   = 129 objects
    host-pod002: leaf 40, spine 8, core 5, nodes 76   = 129 objects

Every one of the 200 crossing links is **spine↔core** (192 backend, 4 frontend,
4 storage). No host↔leaf or leaf↔spine link ever crosses, because pods are
atomic. That is what makes the cut small and uniform.

### The cut is invariant, and a third host makes it worse

Core placement was treated as an open choice and costed:

| placement | cut | load |
|---|---|---|
| (a) cores round-robined — **as the model does it** | **200** | 129 / 129 |
| (b) all cores co-located on host 1 | 200 | 134 / 124 |
| (c) dedicated core host (3 fabric hosts) | **400** | 124 / 124 / 10 |
| (d) cores split by fabric | 200 | 130 / 128 |

200 is a floor for two pods on two hosts, and it is *structural*: every core
links symmetrically to both pods' spines, so wherever a core sits, its links to
the other pod cross. A dedicated core host doubles the cut because then *both*
pods' core links cross. **The model's placement is already optimal — implement
it, do not re-derive it.**

### Resource envelope

    est per fabric host: 53 switches x 4.0 GB + 76 nodes x 0.029 GB + 12 GB services
                       ~ 226 GB

Measured on the live S1 host: `n2-highmem-64`, 503 GB total, **216 GB in use**
for 48 switches. So each S2 host carries about the same load the current host
already carries. This is not a scaling risk at S2.

**OPEN — profile/reality mismatch.** Both profiles declare
`placement.fleet_machine: n2-highmem-32` (256 GB), but the running host is
`n2-highmem-64` (503 GB). At an estimated 226 GB, an `n2-highmem-32` would be at
88% before headroom. Either the profile is wrong or the deployment is; they must
be reconciled *before* sizing decisions rest on either.

---

## 3. Management addressing — the part that is genuinely new

### The constraint

`tools/oob_plan.py` derives the OOB block from the host that owns it:

    172.20.<last octet of the fabric host's substrate address>.0/24

Unique VPC-wide by construction, because the substrate address already is. All
sims share one VPC and a VPC route names exactly one next-hop, so two sims cannot
both own `172.20.0.0/24`.

It **refuses** a mgmt supernet wider than `/24`, deliberately: at a stride of one
`/24` per host, host 56's `/22` would swallow hosts 57–59 and the symptom would be
one sim answering another's DHCP. `deploy/oob-profile.sh:58` likewise refuses
anything but exactly one fabric host.

Both refusals are correct today and are the reason widening S1 right now would
make the paired deploy refuse. Neither is a bug to be removed; both need a
**stride design**.

### The measurement that decides the shape

    S2 mgmt supernet        common devices   moved
    172.16.0.0/12  (committed)     124        124
    172.20.0.0/24                REFUSED — exhausted at pod 1
    172.20.0.0/23                REFUSED — exhausted at pod 2
    172.20.0.0/22                  124          0
    172.20.0.0/16                  124          0

**The management renumber is not forced by scale.** It is forced by changing the
base. Holding the base at `172.20.0.0` and widening to `/22` preserves every one
of pod 1's 124 addresses exactly. S2 needs 258 addresses; a `/22` supplies four
`/24`s.

An earlier version of this analysis claimed the renumber was unavoidable because
258 > 254. That was wrong: it compared against a single `/24` rather than against
a wider pool with the same base.

### The proposed stride

One `/24` per **fabric host**, allocated from the sim's `/22`, indexed by the
host's substrate octet exactly as today:

    fabric host 1  10.10.0.30  ->  172.20.30.0/24   pod001 + its 5 cores
    fabric host 2  10.10.0.31  ->  172.20.31.0/24   pod002 + its 5 cores

This keeps every property the current derivation was built for:

- **unique VPC-wide**, because the substrate octet is;
- **legible** — `172.20.31.7` names the machine to look at;
- **one derivation**, still `oob_plan.py`, still rewriting the profile that every
  consumer already reads.

And it keeps pod 1 on host 1 with its existing `/24`, which is what makes pod 1's
addresses survivable.

`oob_plan.py` must change from *"refuse anything wider than /24"* to *"allocate
one /24 per fabric host from the declared pool, and refuse if the pool cannot
cover `fabric_host_count` hosts without overlapping a neighbouring sim's octets."*
The refusal must remain — it is the thing standing between us and one sim
answering another's DHCP.

---

## 4. What is not built

1. **`up.sh` takes a single `--fabric`.** It must accept N, mint one run id for
   all of them (it already mints one for two roles), launch them, and wait for
   every one.
2. **`oob-profile.sh:58` refuses ≠1 fabric host.** Needs the per-host stride.
3. **`oob_plan.py` refuses supernets wider than /24.** Needs the stride design
   above.
4. **`40-topology.sh` destroys and deploys one monolithic lab.** It must pass
   `--host $(hostname)` to `gen_topology.py`, which already accepts it.
5. **Lifecycle across hosts** — the genuinely hard part, §5.

---

## 5. Lifecycle — the part with no precedent here

A VXLAN tunnel has two ends on two machines. `gen_topology.py` derives the VNI
from the link itself precisely so the two ends agree without coordination — but
they only *meet* if both hosts actually deploy. That creates failure modes this
project has never had:

- **Partial deploy.** Host 1 finishes, host 2 fails at stage 40. Host 1 holds a
  complete pod whose spine uplinks terminate on tunnels to nothing. Every local
  check on host 1 passes. The fabric is half-built and cheerfully green — the
  exact silent-success shape this codebase keeps producing.
- **Ordering.** Neither host can verify the cut alone. "Are the 200 tunnels up?"
  is the first question in this project that no single host can answer.
- **Asymmetric rebuild.** `40-topology` destroys and redeploys. One host
  rebuilding alone tears down 100 tunnel ends the other still believes in.
- **Preemption.** Fabric hosts are `fleet_spot: true`. Losing one mid-run is a
  routine event, not an exception.

The design owes an answer to each. Sketch, for review:

- The **gate must be cross-host**: assert 200 tunnels up *and carrying traffic*,
  from a vantage point that sees both — the head. Presence of a VXLAN interface
  is not function; the assertion must be prefixes or packets, per the
  verification rule.
- **A run is atomic across hosts or it is a failure.** `up.sh` already waits for
  both roles and requires one run id; extend that to N and require every host to
  reach a terminal state before the gate runs.
- **No host may rebuild alone** once the fabric is up. A rebuild is a
  whole-fabric operation.
- **Preemption of one fabric host is a whole-fabric event**, not a per-host
  repair. `98-spot-rebuild` currently thinks per host.

None of this is designed yet. It is the work.

---

## 6. What must be proven on disposable infrastructure

Before any of it touches the live pair:

1. Two disposable fabric hosts, `fabric_host_count = 2`, a 2-pod profile.
2. `gen_topology.py --host` produces two slices whose VXLAN endpoints **meet** —
   verified by traffic across the cut, not by interface presence.
3. All 200 cross-host links carry BGP, and the count is asserted against
   `expected.py`, not counted by hand.
4. Per-host `/24` management: both hosts' switches get addresses inside their own
   host's `/24`, DHCP `giaddr` routes each to the head, and no address collides.
5. A **deliberate partial failure**: kill host 2 mid-deploy and confirm the gate
   goes RED rather than reporting a healthy half-fabric.
6. Teardown proven, with evidence, per the disposable-VM obligation.

Only after all six does step 6 (rebuild live S1) become answerable — and only if
the completed design shows a baseline migration is genuinely unavoidable.

---

## 7. Decisions needed

1. **Machine type.** Reconcile `fleet_machine: n2-highmem-32` against the running
   `n2-highmem-64` before either is used for sizing.
2. **Mgmt pool.** `172.20.0.0/22` preserves pod 1 exactly and needs the stride in
   §3. Confirm the pool, and confirm no neighbouring sim owns octets in it.
3. **Port allocator.** Separate from this document but coupled to it: restoring
   the `tier` key takes S1→S2 port moves from 70 to 0 but re-ports 1234 existing
   links. The compatibility-preserving alternative — keep S1's map, allocate only
   new core uplinks from the reserved high-port block — is unexplored. Neither
   should be attempted before this design settles, because the cut determines
   which links are new.

---

## 8. What this document does not authorize

No implementation. No change to `oob_plan.py`, `oob-profile.sh`, `up.sh` or
`40-topology.sh`. No Terraform apply. No change to the live pair, and nothing
pointed at S2 on it. S1-512's map is frozen in
`gpufab-platform/tests/baselines/s1-512.map` and guarded by `t76`; any change
that moves it fails there first, by design.
