# Multi-host fabric — the design for blocker 1

Status: **NOT APPROVED, rev 5.** Not authorized for implementation. This is a
problem statement, not a plan: it records what is built, what is not, and what
must be settled before anything is.

Review history, all findings verified against the sources before acceptance:

- **rev 1 → rev 2**, five blockers. Rev 1 called the infrastructure "built" when
  the substrate prerequisites are explicitly absent, sized host nodes from a
  constant the codebase contradicts by 12x, and proposed a management stride that
  is internally unsatisfiable and that the generator refuses today.
- **rev 2 → rev 3**, three further findings. Rev 2's manifest R named a commit
  where it needed a measured content digest (§6); its disposable proof carried a
  waiver inside an acceptance gate (§7); and it scoped host-loss recovery to "a
  pod" when a host also carries half the shared core tier (§6).
- **rev 3 → rev 4**, two findings, both introduced by rev 3's own refinements.
  Its Stage-B "full-MTU without fragmentation" was undefined and, at production
  frame sizes, impossible — and contradicted an existing section that had already
  settled the arithmetic (§7). Its digest requirement said "the same expression
  `sync_branch` uses", which is MD5 over a policy-dependent tar, and left the
  measuring code inside the tree it authenticates (§6).
- **rev 4 → rev 5**, two contract gaps. Rev 4's closure digest listed the
  questions to answer ("which paths", "modes and symlinks") instead of answering
  them, so two implementations could produce incompatible digests and a
  mode/symlink/untracked change could pass a content check (§6). And its MTU
  contract tested success at both encapsulations but an adjacent failure at only
  one, so the tenant-overlay boundary was never actually located (§7).

The recurring shape in all twelve: something that **names** a fact standing in
for something that **measures** it — an intent for a measurement, a question for
a decision, a distant failure for an adjacent one. Rev 3 and rev 4 each
reproduced that shape while fixing earlier instances of it.

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
- the **failed unit** is repaired in isolation;
- the **healthy pod keeps running**;
- shared-tier (core) changes have a larger blast radius and get their own
  explicit acceptance gate.

### The failed unit is not "a pod"

Each host carries one pod **and five of the ten shared cores**, round-robined. So
losing a host is not losing a pod. Measured on S2:

    cores: 10 total, 5 on host 1, 5 on host 2
    pod-1 spine->core links: 100 to host-1 cores, 100 to host-2 cores

**Killing host 2 costs pod 1 exactly half of its 200 core uplinks**, on top of
losing all of pod 2 and half the shared tier. Pod 1 keeps running the whole time.

The recovery scope is therefore:

    { the pod, its assigned cores, the attachment and tunnel ends they carry }

not "the pod". And because the shared tier is partly gone, the repair crosses the
shared-tier acceptance gate that Pillar 1 requires — it is not a pod-local event
even though only one pod's devices vanished.

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
          code closure        the reviewed CONTENT DIGEST of each repository }

**A commit id is intent; a content digest is evidence.** An earlier draft defined
the code closure as "the commit every host actually ran" and asked each host to
record R's fingerprint. That is echoable: a stale host can report the expected
value while executing different bytes, and nothing in the record would differ.

This project has already paid for exactly that. `deploy/lib.sh:455-476` records
the incident — `result-fabric.json` carried `git_sha 3e2d264` for a build whose
working tree was `927ded8`, so *"seven commits of the change under test were
invisible to the record of the run that tested them"* — and fixes it by
distinguishing four fields:

    code_sha      what actually ran   (the synced commit, else HEAD)
    code_source   "sync" | "git"      how code_sha was determined
    code_tree     CONTENT DIGEST of the synced tree
    git_sha       the host ref, unchanged

The split is not theoretical, and the machinery is currently WRONG on the live
host — which is the strongest possible argument for measuring rather than
echoing. Read from `gpufab-fabric-01` after the successful paired deploy:

    run_id       20260902T111015-3ffc-c14061f    <- built from git at c14061f
    git_sha      c14061f...                       correct
    code_source  "sync"                           WRONG
    code_sha     11dbbf2...                       WRONG, three commits stale
    code_tree    b9b8eaac...                      digest of a tree no longer on disk
    actual HEAD  a14f566...

`sync_branch.sh` stamped `.gpufab-source` at 07:58; nothing removes it when a
later deploy takes the **git** path, and the file is untracked so stage 00's
`checkout --force` leaves it. Every git build since has reported itself as a
synced build from a commit it did not run.

This is the 3e2d264/927ded8 incident inverted — a stale stamp rather than an
absent one — and it is exactly why R's code closure must be a digest each host
COMPUTES from its own tree after bootstrap, compares, and refuses on mismatch. A
manifest that trusted the recorded `code_sha` here would certify the wrong code
today. (Tracked separately; not fixed by this document, which changes no code.)

So R carries the reviewed per-repository **content digests**, and the obligation
on each host is to MEASURE, not to echo:

1. after bootstrap, each host independently computes its own tree digest and
   **refuses to proceed** on a mismatch, rather than recording one;
2. it records the **observed** digest, not the expected one, and the gate compares
   observed against R.

**The digest procedure must be frozen in R, not inherited.** "The same expression
`sync_branch` uses" is not a specification: that expression is
`md5sum <"$TAR.local"` (`tools/sync_branch.sh:194`) — MD5, over a tar whose
contents depend on the exclusion flags in force at the time. The live host's
`code_tree b9b8eaac7e32ccf4843830b9bdf8f2f5` is 128-bit, confirming it. A digest
whose recipe can drift is not an identity. R therefore pins:

those were questions, not decisions, and two implementations answering them
differently produce incompatible digests. The contract is:

**Canonical record.** One line per object under the repository root, joined by
TAB, terminated by NUL:

    <relpath> \t <type> \t <mode> \t <digest>

    relpath   POSIX-relative to the repo root, raw bytes
    type      f (regular file) | l (symlink)
    mode      execution-relevant bits ONLY: 100755 / 100644 for f, 120000 for l
    digest    f: SHA-256 of the file bytes
              l: SHA-256 of the TARGET STRING -- never of what it resolves to

**Closure digest** = SHA-256 over those records concatenated, sorted by `relpath`
as **raw bytes** — not locale-collated, because a collation change would move the
digest without moving a single file.

**Rejections, not omissions.** Any object that is not `f` or `l` — device,
socket, FIFO, gitlink/submodule — is a REFUSAL, and so is a symlink whose target
escapes the repository root. Skipping them would let the unrepresentable become
invisible.

**Exclusions are an enumerated allowlist frozen in R** (`.git`, `__pycache__`,
`.gpufab-source`, …). Everything not excluded is INCLUDED — **including files the
manifest did not expect.** An untracked import is a change to what executes, and
this repo has a live instance: `.gpufab-source` is untracked, survives
`checkout --force`, and is currently causing every git build to misreport its own
provenance (§6 above).

**Mode is not cosmetic here**, and the repo says so in three places:
`tools/sync_branch.sh:15` ships a tar of the working tree rather than
`git archive` precisely because *"git archive ships mode 644 and strips the exec
bits"*, and `deploy/97-fleet-watchdog.sh:103,175` guard the same trap;
`bot/setup_automation.sh:86` is the `chmod +x` those bits come from. A tree with
byte-identical content and wrong modes executes differently, so a content-only
digest would certify it as correct.

**And the measuring routine must not come from the tree being measured.** A
digest computed by a script inside the checkout it is authenticating is circular:
a stale or wrong checkout supplies the very code that certifies it. The routine
must be launcher-supplied or independently authenticated. This is not a
hypothetical — §6's live example is a stale artifact *in the checkout* causing
every git build to misreport its own provenance.

A result that reports the expected digest without having measured it is the
"measured nothing, reported a number" shape, one level up from the code.

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

The proof is TWO stages, and they are not interchangeable. An earlier draft
allowed the substrate prerequisites to be waived "with the limitation recorded".
That is legitimate for an exploratory spike and inadmissible in an acceptance
gate: a single-NIC 1460-MTU run qualifies nothing about a dual-NIC 8896-MTU
design, and recording that it doesn't does not make it evidence. A waiver inside
an acceptance gate is how a degraded stage reaches green.

### Stage A — mechanism spike (waivers allowed, proves only mechanism)

Purpose: does the cross-host mechanism work at all. Explicitly does **not**
qualify the production substrate, and no result from it may be cited in the
step-6 decision.

1. Two disposable fabric hosts under an explicit one-pod-per-host placement.
2. Both slices generate — i.e. §3's address projection exists.
3. Tunnels come up and pass traffic on whatever substrate is available.
4. Teardown proven with evidence.

Any waiver taken here is recorded with what it invalidates.

### Stage B — production-substrate acceptance (NO WAIVER)

Purpose: qualify the design that will run. Every condition is mandatory; a
missing prerequisite is a STOP, not a footnote.

1. Substrate prerequisites actually in place: dedicated fabric VPC at **MTU
   8896**, firewall on the settled port (§4), **dual-NIC** hosts. None may be
   waived.
2. **MTU behaviour, as a NUMERIC contract.** An earlier draft asked for
   "full-MTU frames without fragmentation", which is undefined and, at
   production frame sizes, impossible. `scale-out-architecture.md` **CORRECTION
   (#100)** already settles the arithmetic — and supersedes the 9214/9000 figures
   quoted elsewhere in that file, which "was read by nothing":

       9100  MEASURED switch port MTU (not 9000)
       8896  GCP VPC maximum (the PROPOSED fabric VPC; it does not exist today)
     -  ~50  substrate VXLAN  -> 8846 on the wire across the cut
     -  ~50  the fabric's OWN overlay riding inside it -> 8796 to the payload
     = 304 bytes SHORT of the 9100 port; 254 short even with no overlay at all

   So the deficit is **pre-existing, not a VXLAN problem** — VXLAN only makes it
   visible. It does not bind today because pod-atomic placement keeps every
   cross-host link at `core-spine`, so VTEP traffic rides local veths; it begins
   to bind exactly when a real multi-host deployment carries production frames
   across the cut, which is what Stage B is for.

   The acceptance contract is therefore four assertions, not one:

   Each encapsulation gets its OWN success and its OWN **adjacent** failure. A
   success at 8796 paired only with a failure at 9100 proves nothing about where
   the second boundary actually is — it could lie anywhere in 8797..9099, and
   Stage B would pass without ever testing the encapsulation it exists to
   qualify:

   | layer | succeeds | adjacent failure, must report ceiling |
   |---|---|---|
   | substrate (wire across the cut) | **8846** DF | **8847** -> ICMP frag-needed naming **8846** |
   | tenant overlay (payload) | **8796** DF | **8797** -> ICMP frag-needed naming **8796** |

   `9100` is retained as a far-above-limit case, not as the boundary test. MSS
   clamping is asserted where the path requires it. Silent blackholing of large
   flows is the classic production failure this must reproduce rather than
   avoid;
   - **local links retain their measured MTU** — 9100 switch port, 9500 host
     veth, which `tests/t58-mtu-headroom.sh` already asserts (measured local
     overlay headroom 350 bytes). A proof that quietly lowered intra-pod MTU to
     make the cross-host case pass would destroy the property pod-atomic
     placement exists to protect.

   The 304-byte shortfall is recorded as a **known fidelity limit**, not a defect
   to be engineered away: anything measuring cross-pod throughput at production
   frame sizes is measuring the substrate. Closing it needs bare metal or a
   provider permitting a >=9264 underlay — a substrate choice, not a design
   change.
3. Every one of the 200 tunnels matches its model-derived tuple — both endpoints,
   both interfaces, VNI, remote IP, UDP port — and carries traffic. Presence of a
   VXLAN interface is not function, and a count is not identity.
4. Manifest R measured, not echoed, on every host (§6).
5. A **deliberate partial failure**: kill host 2 mid-deploy. The revision must go
   RED, and pod 1 must be measured against a **defined service level** — not
   observed to be "still running". Pod 1 survives host 2's loss with half its core
   uplinks gone; liveness cannot distinguish that from health. State the expected
   post-loss numbers (surviving sessions, reachable prefixes) and assert them.
6. Repair is scoped to {pod 2, its five cores, their tunnel ends} and crosses the
   shared-tier acceptance gate, with host 1's objects untouched throughout.
7. Teardown proven with evidence.

Only after Stage B does step 6 (rebuild live S1) become answerable.

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
