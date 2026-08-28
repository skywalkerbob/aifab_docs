# Fidelity verification plan — gpufab sim vs. a DGX B300 / SN5600 fabric

Design for a test suite that answers, feature by feature, how faithfully this
simulator represents the physical target. It implements
`sonic_sim_fidelity_verification_agent.md` against THIS simulator rather than a
generic one, so it commits to specific fidelity ceilings, names the rows that
are structurally impossible here, and reuses the tests that already exist.

Status: design. Nothing below has been run. Test IDs are allocated, not earned.

---

## 1. The two environments, stated precisely

Everything in this plan follows from the gap between these two columns.

| | Simulated | Physical target |
|---|---|---|
| Switch | SONiC-VS `sonic-vs 202505-ztp`, 9.04 GB vrnetlab image | NVIDIA SN5600, part `920-9N42F-00RI-7C0` |
| ASIC | **SAI-VS (generic virtual SAI)** | **Spectrum-4, 51.2T** |
| Ports | HWSKU `vs-sn5600-64x800`, 64 ports, names/lanes synthesized | 64×800G OSFP |
| Dataplane | software, capability UNVERIFIED (see F0.2) | hardware pipeline |
| Hosts | FRR containers (`frrouting/frr:10.2.1`), `kind: linux` | DGX B300 + ConnectX/SuperNIC |
| Virtualization | QEMU **nested inside** GCE `n2-highmem-64` | bare metal |
| SoT / render | NetBox → `fabric_model.py` → `render_fabric_ztp.py` | same intent, real devices |
| Scale under test | s1-512: 124 devices, 48 switches, 76 hosts, 1466 links | production pod |

`vs-sn5600-64x800` is a **synthesized HWSKU that imitates the SN5600's port
count and naming**. It shares no ASIC code with Spectrum-4. Any result from this
simulator that is phrased as a statement about Spectrum-4 is unsupported, and
§7 lists those prohibited claims explicitly so they cannot be produced by
accident.

## 2. Fidelity ceiling, declared before testing

Per the guide's §3 levels. This is a structural property of the environment, not
a prediction of results:

| Level | Attainable here? | Why |
|---|---|---|
| L1 control-plane | **Yes**, and largely already attained | Real SONiC, real FRR, real NetBox-driven render |
| L2 SAI semantics | **Conditionally** — generic SAI only | SAI-VS models object semantics, not Spectrum-4's |
| L3 software behavior | **Unknown until F0.2** | Depends on whether the VS dataplane forwards at all |
| L4 hardware-correlated | **No** | No target hardware, and nested virtualization makes every timing measurement unusable as a correlation input (guide §9) |
| L5 physical qualification | **No** | No physical lab |

Consequence: this suite's job is to prove L1 rigorously, establish exactly how
far L2 reaches, discover whether L3 is available at all, and **refuse** L4/L5.
A plan that quietly attempts L4 rows produces the failure this codebase already
specializes in — a confident number nobody can defend.

**Management-plane isolation from compute (#138) — was a ceiling, now ENFORCED
(2026-08, `deploy/46-mgmt-isolation.sh`, platform `8f8cb3e`).** containerlab wires
every node — switches AND compute hosts — with an `eth0` on the SAME
`172.20.0.0/24` management bridge, because that is how the fabric host reaches
switches for SSH/ZTP/TACACS. Left alone, an unprivileged compute container shared
a broadcast domain with the entire management plane: measured from
`clab-gpufab-dc1-pod001-gpu0001`, switch mgmt IPs answered and
`wget http://<ztp>/<device>/config_db.json` returned artifacts carrying
`SNMP_COMMUNITY` / `TACPLUS` / `AAA` for all 122 devices. **This is now closed.**
Stage 46 installs an nftables BRIDGE-family forward drop — host-mgmt (`.88-.254`)
→ infra + switch mgmt (`.3-.87`) — derived from the running fabric, persisted via
a systemd oneshot, and self-verified both directions (a compute node is BLOCKED
from a switch mgmt IP; the fabric host STILL reaches switches over SSH). Re-measured
from the same compute container: switch mgmt / ZTP / TACACS are unreachable, while
switch↔switch and switch↔infra (over the mgmt VRF) and BGP are intact. The GCP
SUBSTRATE boundary is separately isolated (`c3-substrate-isolation.sh` — verified).
**So OOB-isolation-from-compute IS now enforced and testable** — stage 46 asserts
it at deploy, and `t57`'s host→OOB-mgmt row may be promoted from report to assert.
Two things remain, and neither is the credential exposure: (a) #140 gap A, the
provisioning VLAN 200 into its own data-plane VRF (in flight); (b) a topology-level
split (compute on a genuinely separate management bridge, #140 item 2B) which would
make the separation structural rather than firewall-enforced — a fidelity
refinement, not an open security hole.

## 3. Discovery gates run FIRST (phase F0)

The guide's matrix presumes capabilities. Ours must establish them, because
designing forty tests against a capability we do not have wastes the effort and
produces `not_tested` rows dressed as coverage. **Each F0 result switches later
phases on or off**, and the plan is explicit that a switched-off phase is
reported as `unsupported` with a reason, never silently dropped.

| ID | Question | Gates |
|---|---|---|
| **FV-CAP-01** | Is `ASIC_DB` present and populated on a SONiC-VS switch? Dump it after a known route install and count objects. | All of 7.3; the L2 rows of 7.4–7.7 |
| **FV-CAP-02** | **Does the VS dataplane forward a packet between two front-panel ports?** Inject a frame on one side, count it on the other. | Every L3 row: 7.4 packet tests, 7.5, 7.6, 7.7, 7.8, 7.9, scenarios G/H |
| **FV-CAP-03** | Is CRM present and does it report/enforce modeled resource limits? | 7.3 resource exhaustion, scenario E |
| **FV-CAP-04** | Does any traffic generator exist in this environment, and can it drive 64-port scale? | Scenarios G, H; 7.4 distribution rows |
| **FV-CAP-05** | Characterize nested-virt scheduling noise: run one fixed workload N times on an idle fabric host and report the spread. | Every quantitative metric in guide §9 |

FV-CAP-05 is not optional bookkeeping. Convergence was measured at 22m27s on
this platform; without a noise figure there is no way to say whether a later
18m is an improvement or the same run on a quieter host. Its output is a
**required denominator** for every timing claim this suite makes.

FV-CAP-02 is the single highest-value test in the plan. If the VS does not
forward, roughly half the guide's matrix collapses to L0/L1 for us, and knowing
that on day one prevents months of tests that can only ever return `unsupported`.

## 4. What already exists, mapped to the matrix

These are not to be rewritten. They must, however, **emit `result.json`** in the
guide's §5 schema to count as evidence — today they print PASS/FAIL to a
terminal, which is not reproducible evidence.

| Guide row | Existing test | Level | Gap to close |
|---|---|---|---|
| 7.1 device inventory | `tools/expected.py`, `t02-sot.sh` | L1 | emit evidence |
| 7.1 cable topology | `t02-sot.sh`, `t08-addressing.sh` | L1 | emit evidence |
| 7.1 IP/ASN allocation | `t08-addressing.sh` | L1 | emit evidence |
| 7.1 speed/breakout intent | `t14-port-table.sh`, `t15-port-inventory.sh` | L1–L2 | emit evidence |
| 7.2 ConfigDB/schema | `t11-config-applied.sh` | L1 | emit evidence |
| 7.2 template rendering | `t07-render.sh` | L1 | **t07 currently fails 122 vs 48 (test bug)** |
| 7.2 FRR/BGP | `t13-bgp-peer-truth.sh` | L1 | emit evidence |
| 7.2 VRF isolation | `t17-mgmt-vrf.sh`, `t05-isolation.sh` | L1–L3 | L3 claim needs FV-CAP-02 |
| 7.10 SoT validation | `t01-provenance.sh`, `t19-host-can-pull.sh` | L1 | emit evidence |
| 7.10 DHCP bootstrap | stage-50 ZTP fetch gate | L1 | **ZTP has never had a clean run** |
| 7.11 telemetry APIs | `t10-observability.sh` | L1 | emit evidence |
| 7.11 process recovery | `t12-recovery-units.sh` | L1–L3 | emit evidence |

Roughly **60% of the guide's L1 surface is already covered** by work done for
other reasons. The suite's new work is therefore concentrated in 7.3–7.9, which
is exactly where the fidelity ceiling is lowest and the honest answer matters
most.

## 5. New tests, by area

Numbering: `FV-<AREA>-<nn>`. Each carries a target level; a test that cannot
reach its target reports the level it *did* reach plus a limitation, never a
pass at the aspirational level.

### 5.1 Topology and design (guide 7.1) — target L1

| ID | Test | Pass criteria |
|---|---|---|
| FV-TOPO-01 | Rail mapping: every GPU NIC rank maps to its intended rail | rank→rail map matches profile for all 512 GPUs; 0 unmapped |
| FV-TOPO-02 | Plane separation: no unintended cross-plane link or route | 0 cross-fabric links outside declared interconnects |
| FV-TOPO-03 | Oversubscription/bisection: computed capacity vs. design intent | computed ratio equals `expected.py`; surviving bisection after N spine removals reported |
| FV-TOPO-04 | Failure-domain diversity: remove each spine in turn, recompute paths | every leaf retains ≥1 path to every other leaf; report worst-case width |

FV-TOPO-03/04 are **graph computations on the SoT, not fabric operations** —
they are cheap, deterministic, and need no running fabric. They should run in CI
on every profile change.

### 5.2 Control plane (guide 7.2) — target L1, some L2/L3

| ID | Test | Pass criteria |
|---|---|---|
| FV-CTRL-01 | Route policy: advertise, filter, leak, withdraw a test prefix | RIB reflects each action within a bounded window; withdrawal is observed, not assumed |
| FV-CTRL-02 | FIB programming reaches ASIC_DB *(gated on FV-CAP-01)* | route present in ASIC_DB with correct next-hop |
| FV-CTRL-03 | BFD session up/down | state transitions observed both directions |
| FV-CTRL-04 | Warm restart: restart SWSS/FRR, compare state before/after | session count and RIB restored; delta reported |
| FV-CTRL-05 | Rollback: apply a knowingly-bad config, verify rejection and restore | prior revision restored; **no partial state** |

FV-CTRL-05 matters disproportionately here: `config replace` validates against
YANG and `config reload` does not, and a YANG `must` condition on
`MGMT_INTERFACE.gwaddr` once rejected all 48 rendered artifacts fleet-wide while
every stage reported success.

### 5.3 SAI/ASIC semantics (guide 7.3) — target L2, generic only

Gated entirely on FV-CAP-01.

| ID | Test | Pass criteria |
|---|---|---|
| FV-SAI-01 | SWSS→SAI translation for a known config delta | expected object types created; counts match |
| FV-SAI-02 | Object dependency ordering | references exist before referrers; trace captured |
| FV-SAI-03 | Update/delete cleanup | 0 orphaned objects after teardown |
| FV-SAI-04 | SAI error injection | failure surfaces and rolls back — **likely unsupported in VS; report as such** |
| FV-SAI-05 | Resource exhaustion via CRM *(gated on FV-CAP-03)* | limit enforced, alarm raised, no corrupt state |

**Every FV-SAI result carries the fixed limitation: "SAI-VS, not Spectrum-4. No
statement about vendor SDK behavior, table capacity, or shared-resource
dynamics."**

### 5.4 Forwarding and ECMP (guide 7.4) — L2 achievable, L3 gated

| ID | Test | Level | Gate |
|---|---|---|---|
| FV-FWD-01 | Next-hop group members present for a multipath route | L2 | FV-CAP-01 |
| FV-FWD-02 | Member failure/recovery changes group membership | L2 | FV-CAP-01 |
| FV-FWD-03 | Packet reachability leaf→leaf | L3 | FV-CAP-02 |
| FV-FWD-04 | ECMP distribution across many flows, skew computed | L3 | FV-CAP-02 + FV-CAP-04 |

### 5.5 QoS / ECN / PFC (guide 7.5–7.7) — expected L1–L2, mostly config-only

| ID | Test | Level |
|---|---|---|
| FV-QOS-01 | Buffer pools/profiles and scheduler objects created and bound | L2 |
| FV-QOS-02 | WRED/ECN threshold objects created and updatable | L2 |
| FV-QOS-03 | PFC priorities and watchdog configured | L2 |
| FV-QOS-04 | CE marking under controlled congestion | L3 — **expect unsupported** |
| FV-QOS-05 | PFC watchdog state machine under synthetic storm | L3 — **expect unsupported** |

The guide is explicit that line-rate pause timing and real buffer-cell behavior
require hardware. This plan does **not** attempt them; it establishes whether the
*configuration and object model* are faithful, and stops there with that stated.

### 5.6 ZTP / GitOps (guide 7.10) — target L1, strong area

| ID | Test | Pass criteria |
|---|---|---|
| FV-ZTP-01 | Blank switch self-provisions: DHCP → opt67 → config → applied | N/M switches fetched AND applied, with the backfill disabled |
| FV-ZTP-02 | Identity matching: MAC/serial → role | correct per-device config served |
| FV-ZTP-03 | Invalid config rejection | bad artifact rejected, device left in a known state |
| FV-ZTP-04 | Canary rollout + health-check failure halts fleet rollout | rollout stops; blast radius bounded and measured |

**FV-ZTP-01 is the experiment this project has never run.** ZTP's work has
always been overwritten by the config-push backfill before it could finish, so
ZTP has been observed neither working nor failing. It requires disabling the
backfill on a sacrificial fabric — see §6.

### 5.7 Telemetry and remediation (guide 7.11) — target L1–L3

| ID | Test | Pass criteria |
|---|---|---|
| FV-TEL-01 | Config drift: alter MTU/BGP out-of-band, detect and correct | drift detected, corrected, event recorded |
| FV-TEL-02 | Link failure → route withdrawal → remediation timeline | timeline captured with FV-CAP-05 noise bounds |
| FV-TEL-03 | Kill BGP process, observe detection and restart | recovery observed, not inferred |
| FV-TEL-04 | Switch reboot recovery | fabric returns to expected session count |
| FV-TEL-05 | **Loop guardrail:** repeat a failing repair, prove retry/cooldown holds | automatic action does NOT fire on an ambiguous signal |

FV-TEL-05 encodes a real incident: an automatic rebuild triggered on "BGP below
threshold" while a fabric was still converging and reached `containerlab
destroy` on 124 live nodes. The guardrail exists now; nothing tests it.

### 5.8 Physical, thermal, power (guide 7.12–7.13) — L0 by construction

Declared unsupported up front, with one exception: where a *workflow* exists
(alarm → containment → ticket → recovery), the workflow is testable with
injected values at L3 while the physics remains L0.

| ID | Test | Level |
|---|---|---|
| FV-PHY-01 | Synthetic FEC/optic alarm drives containment workflow | L3 workflow / L0 physics |
| FV-PHY-02 | Synthetic thermal alarm drives remediation | L3 workflow / L0 physics |
| — | BER, eye diagram, SerDes, cooling, power transient | **L0, not attempted** |

## 6. Destructive tests need a sandbox — this changes the release plan

Scenarios B, C, D, E, F and I in the guide, and FV-ZTP-01, are **destructive**:
they kill links, fail spines, exhaust resources, push bad config, and disable the
backfill that currently guarantees convergence.

Running them against the only surviving sim is not acceptable. Recommendation:
**retain one of s3/s4 as a dedicated destructive-test sandbox** rather than
releasing both, and keep s5 as the clean reference. s4 is the better candidate —
it is the spot instance, so the sandbox is the cheap one, and its fabric is
already rebuildable from SoT by design.

If both are released, every destructive scenario in this plan requires standing
up a fresh sim first, and the suite's wall-clock cost rises by a full build per
scenario batch.

## 7. Prohibited claims — write these into the report template

Per the guide's §11. These must be emitted as explicit `unsupported` findings,
not omitted:

- "The simulator validates Spectrum-4 ECMP hashing/bucket behavior" — SAI-VS has no Spectrum-4 correlation.
- "The simulator validates SN5600 table capacity or shared-buffer dynamics" — modeled limits only, exact profile unknown.
- "Measured convergence time predicts production convergence" — nested virtualization; no L4 correlation exists.
- "PFC pause propagation / line-rate timing is validated" — requires hardware.
- "RoCE/DCQCN/NCCL completion behavior is validated" — no NIC firmware, no GPU, no line rate.
- "ZTP is proven" — until FV-ZTP-01 runs with the backfill disabled, ZTP's state is unknown, not good.
- "The management plane is isolated from compute / OOB is isolated from workload" — NOW ENFORCED (`deploy/46-mgmt-isolation.sh`, #138): an nftables bridge drop blocks host-mgmt→switch-mgmt/infra on the shared `172.20.0.0/24` bridge, self-verified both directions. Re-measured: a compute container can no longer reach switch mgmt or read ZTP/SNMP/TACACS. The claim is now defensible AT THE FIREWALL layer. Still honest to note the topology remains one bridge (a genuinely separate compute mgmt bridge, #140 item 2B, would make it structural) — so state it as "enforced by host firewall," not "physically separate."

## 8. Evidence and result schema

Adopt the guide's §5 layout verbatim, rooted at
`gpufab-platform/tests/fidelity/evidence/<test-id>/`, with `result.json` in the
guide's schema plus two mandatory local fields:

- `git_sha` — the commit the suite ran from
- `render_revision` — the content fingerprint from `tools/render_revision.py`

Without those, evidence cannot be tied to the code that produced it, and this
project has already shipped a 32-port PORT table to 64-port switches while every
artifact looked plausible.

Two project rules bind onto the guide's non-negotiables:

- The guide's rule 1 ("configuration presence is not behavioral validation") is
  this codebase's dominant failure mode. `tests/lib.sh` already enforces that a
  check observing nothing is a failure; every fidelity result must carry an
  observed count, and must report `not_tested` rather than `pass` when nothing
  was observed.
- The guide's rule 5 (use `unsupported`/`not_tested`/`failed` precisely) maps
  directly onto `t_zero`'s refusal to read an empty measurement as zero.

## 9. Sequencing

1. **F0 discovery** (FV-CAP-01..05) — cheap, gates everything, do first.
2. **Evidence retrofit** — make existing t01–t19 emit `result.json`. Converts ~60% of the L1 surface into defensible evidence for near-zero cost.
3. **Graph-only tests** (FV-TOPO-01..04) — no fabric required, CI-able.
4. **Control plane** (FV-CTRL-01..05) — on the clean reference sim.
5. **SAI/forwarding**, scoped by what F0 actually found.
6. **Destructive scenarios** — sandbox only, after §6 is settled.
7. **Report**: fidelity matrix, scores + confidence, gaps, minimum physical-lab plan, and the JSON of guide §12.

Steps 1–3 deliver most of the defensible answer. Step 5's scope is unknowable
until step 1 returns, which is the point of running it first.
