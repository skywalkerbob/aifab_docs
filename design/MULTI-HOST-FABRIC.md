# Multi-host fabric — the design for blocker 1

Status: **REJECTED AT REVIEW, rev 2.** Not approved, not authorized for
implementation. Five blockers were raised against rev 1; all five were verified
against the sources and are recorded below with what was measured.

Rev 1 was too optimistic in three specific ways, corrected here: it called the
infrastructure "built" when the substrate prerequisites are explicitly not in
place, it sized host nodes from a constant the codebase contradicts, and it
proposed a management stride that is internally unsatisfiable and that the
generator refuses today.

Scope: what S1→S2 needs to run one fabric across two hosts. It does **not**
design the S1→S2 migration (step 4) or authorize any change to the live pair.

Numbers were measured on 2026-09-02 against the committed model. Where something
was not measured, it says so.

---

## 1. State of each layer

| layer | state | why |
|---|---|---|
| model / placement | **built, but architecture-defining** | `fabric_model.place()` returns `assign`/`hosts`/`cross_links` — but what it returns depends on machine type, §2 |
| topology generation | **built, but REFUSES S2 today** | `gen_topology.py --host` emits slices and VXLAN tunnels, and exits on every S2 shard, §3 |
| infrastructure | **PARTIAL** | countable instances and deterministic IPs only; the substrate prerequisites are absent, §4 |
| orchestration + OOB | **not built** | §5 |
| lifecycle | **not built, and rev 1 got the contract wrong** | §6 |

---

## 2. Placement is decided by machine type, not by sizing

### The RAM model contradicts itself — fix this first

Two committed "measured" values for one fact:

    fabric_model.py:182   NODE_RAM_GB = 0.029    # measured: a host container is ~29 MB
    fabric.tf:18-24       76 host nodes x 0.34 GB = 26 GB   <- never counted

They differ by 12x. `fabric.tf` carries the fuller account — it corrects an
earlier estimate that counted switch VMs only, and lands S1 at 224 GB of 251
usable, 89%. Rev 1 of this document used the model's 0.029 and therefore
under-sized every host in it.

**This is a one-derivation violation and it must be resolved before any sizing
rests on either number.** Until it is, every placement figure here is provisional.

### Neither machine currently yields a valid two-host S2

Recomputed with `fabric.tf`'s 0.34 GB/node:

| | switches | nodes | total | usable | |
|---|---|---|---|---|---|
| S2 shard on `n2-highmem-32` @4.00 GB/sw | 53 | 76 | 249.8 GB | 251 | **99.5%** |
| S2 shard on `n2-highmem-32` @4.12 GB/sw (measured) | 53 | 76 | 256.2 GB | 251 | **102.1% — over** |
| S2 shard on `n2-highmem-64` | 53 | 76 | ~250 GB | 495 | ~51% |

And the placement the model derives depends on which machine is declared:

    n2-highmem-32   ->  hosts=2  cross-host links=200   (what rev 1 assumed)
    n2-highmem-64   ->  hosts=1  cross-host links=0     (the LIVE machine)

`n2-highmem-64` — the machine actually running today — makes the model bin-pack
all 258 objects onto one host and the multi-host architecture disappears
entirely. `n2-highmem-32` produces two hosts, each at or over capacity.

**Machine type is not a sizing decision here; it selects the architecture.**
Neither current option gives a valid two-host S2.

### Consequence: the 200-link cut is contingent, not invariant

Rev 1 called it invariant. It is invariant only *given* one pod per host. Under a
one-pod-per-host constraint the cut is insensitive to core placement:

| placement | cut | load |
|---|---|---|
| cores round-robined (model's) | 200 | 129 / 129 |
| all cores on host 1 | 200 | 134 / 124 |
| cores split by fabric | 200 | 130 / 128 |
| dedicated core host (3 hosts) | **400** | 124 / 124 / 10 |

That structure is real — every core links symmetrically to both pods, so its
links to the non-co-located pod always cross, and a dedicated core host makes
*both* pods' core links cross. But it only applies once placement is pinned.

**Required: an explicit one-pod-per-host placement constraint**, independent of
RAM bin-packing, so the architecture stops being a side effect of a machine-type
string. Until that exists, no cut figure is a design invariant.

---

## 3. Management addressing — rev 1's proposal is withdrawn

### Why it was unsatisfiable

Rev 1 proposed `172.20.0.0/22` *and* per-host blocks at `172.20.30.0/24` and
`172.20.31.0/24`. A `/22` at `172.20.0.0` covers third octets **0–3**. It cannot
contain `.30` or `.31`. The two halves of the proposal contradicted each other.

It also does not preserve S1: S1's committed block is `172.20.0.0/24`, so a
host-indexed `.30/24` **is** a renumber — the opposite of what rev 1 claimed for
it. The `/22` measurement that showed *0 moved* used the model's allocation from
base `172.20.0.0`, which is a different scheme from the host-indexed stride
proposed two paragraphs later. Rev 1 conflated them.

The `/22` measurement itself stands and is still useful:

    S2 mgmt supernet        common devices   moved
    172.16.0.0/12  (committed)     124        124
    172.20.0.0/24                REFUSED — exhausted at pod 1
    172.20.0.0/23                REFUSED — exhausted at pod 2
    172.20.0.0/22                  124          0
    172.20.0.0/16                  124          0

Holding the base and widening preserves pod 1's addresses. Choosing a *different*
base moves them. That much is measured and true. What does not follow — and what
rev 1 asserted anyway — is that a host-indexed stride can deliver it.

### The structural obstacle rev 1 missed

The model gives the **core tier its own mgmt subnet slot**, separate from pods
(`fabric_model.py:1071`, `core_net = addr.mgmt_subnet(dc_seq, addr.core_pod_slot)`).
Measured on S2:

    172.16.0.0/24   leaf 40, spine 8, node 76     (pod001)
    172.16.1.0/24   leaf 40, spine 8, node 76     (pod002)
    172.16.2.0/24   core 10                        (shared tier)

    host-pod001 spans 2 mgmt subnets -> ['172.16.0.0/24', '172.16.2.0/24']
    host-pod002 spans 2 mgmt subnets -> ['172.16.1.0/24', '172.16.2.0/24']

and `gen_topology.py` exits on **both** shards:

    nodes span 2 mgmt subnets (...) but a containerlab topology has one mgmt network

Its own comment names this case: *"Several pod subnets on one host is the S2
case, and it needs routed pod mgmt, not a silently widened supernet here."*

So "pod plus its five cores in one host `/24`" is not expressible: cores are in a
different subnet by construction, and one clab topology has one mgmt network.

**Required: a placement-aware address projection.** Changing `oob_plan.py`'s
stride cannot express this through one global profile, because the constraint is
per-shard and the profile is global. Either the core tier's management is routed
rather than co-resident, or the projection must map a shard's several logical
subnets onto the one network clab allows. Neither is designed. `oob_plan.py`'s
refusal of wider supernets must survive whatever replaces it — it is what stands
between us and one sim answering another's DHCP.

---

## 4. Infrastructure is PARTIAL, not built

`terraform/fabric.tf` provides countable instances (`fabric_host_count`) and
deterministic addresses (`cidrhost(…, 30 + count.index)`). That is the whole of
what exists.

`scale-out-architecture.md:1472` already enumerates the rest, and states
plainly: **"Checked against the live project; none are currently in place"**

| requirement | today | needed |
|---|---|---|
| fabric VPC | does not exist | create at **MTU 8896** |
| VXLAN firewall | only `tcp:22`, on `gpufab-vpc` | allow **UDP 4789** within the fabric subnet |
| fabric-host NICs | **single-NIC** (`fabric.tf:102`) | dual-NIC, assigned at instance creation |

Two further facts rev 1 omitted:

- **MTU.** The control VPC is 1460. VXLAN encapsulation over a 1460-byte path
  will fragment or drop fabric traffic; the prerequisite table calls for a
  dedicated 8896-MTU fabric VPC precisely for this. Untested either way.
- **Port contradiction, unresolved.** `gen_topology.py:472` emits `udp-port:
  14789`. `scale-out-architecture.md` says allow **4789** and pass `--dst-port
  4789` "since clab defaults to 14789". Two committed documents disagree about
  which port the firewall must open. This must be settled before a rule is
  written, or the rule will be for the wrong port and the symptom will be tunnels
  that never come up.

---

## 5. Orchestration — not built

1. `up.sh` takes a single `--fabric`; needs N, one manifest for all of them, and
   a wait on every host.
2. `oob-profile.sh:58` refuses anything but exactly one fabric host.
3. `oob_plan.py` refuses supernets wider than `/24` — correctly, pending §3.
4. `40-topology.sh` deploys one monolithic lab; must pass `--host`.
5. `verify.sh` accepts only one fabric host.

---

## 6. Lifecycle — rev 1 had the contract backwards

Rev 1 said a preempted fabric host means rebuilding the whole fabric. That
conflates a **global acceptance verdict** with **global destruction**, and it
contradicts the approved architecture.

`BRINGUP-ARCHITECTURE.md` Pillar 1: a pod that fails to converge is *"retried or
quarantined **in isolation of other pods** — but never in isolation of the shared
core tier it attaches to."* The correct contract is:

- the **revision** goes and stays RED while any unit is unconverged;
- the **failed pod** is repaired in isolation;
- the **healthy pod keeps running**;
- shared-tier (core) changes have a larger blast radius and get their own
  explicit acceptance gate.

Pillar 1 also records that the containerlab unit lifecycle this depends on
**does not exist today**. That is a prerequisite, not a detail.

### One run id is not identity

Rev 1 leaned on `up.sh`'s single run id. A run id proves two hosts were launched
by the same invocation. It does not prove they used the same profile, the same
placement, or the same code.

**Required: a frozen manifest R**, computed once and bound to every result:

    R = { host map            physical names and addresses, not derived per host
          unit set            which pods/tiers exist and which host owns each
          placement           the device -> host assignment itself
          profile/SoT fingerprint
          code closure        the commit every host actually ran }

Every per-host result records R's fingerprint; the gate refuses if any two
disagree. This is the same reasoning as the run-id gate one level up: the failure
it prevents is two hosts building different fabrics and both reporting success.

---

## 7. What must be proven on disposable infrastructure

Rev 1's proof was not executable. `_shard()` derives physical hosts as
`gpufab-fabric-{i+1:02d}` with consecutive addresses from `--fabric-base`
(`gen_topology.py:194`), so `--host $(hostname)` rejects any ordinarily-named
disposable VM. The physical mapping must come from manifest R, not from a
hardcoded pattern.

The gate must validate the **exact model-derived tunnel set** — for every crossing
link: both endpoints, both interfaces, VNI, remote IP, UDP port — not a count of
200 sessions.

> **Counts cannot detect miswiring when parallel links exist.** Eight parallel
> spine↔core links can be cross-connected to each other and every count stays
> correct. This is not hypothetical: keying links by `(a,z)` collapsed them in
> t08, in a later t08 fix, and again in an ad-hoc VNI measurement made while
> writing this document — which reported 32 distinct VNIs where there are 200.
> Three occurrences in one day. Any check that identifies a link by its endpoints
> will eventually be wrong in this specific way.

Corrected measurement, per link rather than per pair: **200 cross-host links,
200 distinct VNIs, 0 collisions.**

The proof:

1. Two disposable fabric hosts under an explicit one-pod-per-host placement.
2. Substrate prerequisites in place (fabric VPC at 8896, firewall on the settled
   port, dual-NIC) — or an explicit, recorded decision to test without them and
   what that does not prove.
3. Both slices generate — i.e. §3's address projection exists.
4. Every one of the 200 tunnels matches the model-derived tuple, and carries
   traffic. Presence of a VXLAN interface is not function.
5. A **deliberate partial failure**: kill host 2 mid-deploy; the revision must go
   RED while pod 1 keeps running — not a global rebuild, per §6.
6. Teardown proven with evidence.

---

## 8. Decisions needed

1. **Resolve `NODE_RAM_GB` 0.029 vs 0.34.** Everything in §2 depends on it.
2. **Choose the machine and pin the placement.** Neither current option yields a
   valid two-host S2; a one-pod-per-host constraint is required either way.
3. **Settle UDP 4789 vs 14789** between `gen_topology.py` and
   `scale-out-architecture.md` before any firewall rule is written.
4. **Decide the management projection** (§3): routed core management, or a
   shard-level projection onto clab's single mgmt network.
5. **Port allocator** — unchanged from rev 1 and still coupled: restoring `tier`
   takes S1→S2 port moves 70→0 but re-ports 1234 existing links. The
   compatibility-preserving alternative is unexplored. It should not be attempted
   before placement settles, because placement determines which links are new.

---

## 9. What this document does not authorize

No implementation. No change to `oob_plan.py`, `oob-profile.sh`, `up.sh`,
`40-topology.sh`, `verify.sh` or `fabric_model.py`. No Terraform apply. No
firewall rule. No change to the live pair, and nothing pointed at S2 on it.
S1-512's map stays frozen in `gpufab-platform/tests/baselines/s1-512.map`, guarded
by `t76`.
