# gpufab — architecture, design, and the defects that shaped it

**Status:** current as of 2026-09-19. Supersedes nothing; it is the map that the
40-odd focused documents in this directory hang off. Where a detail is recorded
elsewhere in more depth, this points at it rather than restating it.

**Scope:** what the system is, how it is built, why it is built that way, and —
in detail — the defects that forced each design decision. The last part is the
longest on purpose: almost every structural choice here exists because something
failed silently first.

---

# Part I — What this is

## 1. The object

A simulator for DGX-B300-class GPU fabrics: real SONiC network operating systems,
running as QEMU guests under containerlab, on GCP hosts, provisioned from a
NetBox source of truth by the same automation that would drive physical
hardware.

**The point is not emulation.** It is to run parameter and configuration
experiments — timers, topologies, failure modes, bring-up strategies — against a
fabric whose control plane behaves like the real thing, on a platform stable
enough that a measurement means something. Emulation is the substrate; the
experiments are the product.

**Scale target:** multi-DC, 200–500K GPUs, with no design ceiling. The profile
ladder runs `s0-64` → `s5-32768` today:

| profile | devices | switches | cables | derived BGP peer series |
|---|---|---|---|---|
| s0-64 | 43 | 30 | 225 | 249 |
| s1-512 | 124 | 48 | 1,466 | 1,464 |
| s2-1024 | 258 | 106 | 3,332 | 3,728 |
| s3-4096 | 865 | 270 | 12,530 | 13,330 |
| s4-10240 | 2,111 | 626 | 30,965 | 32,582 |
| s5-32768 | 6,815 | 2,055 | 99,260 | 104,370 |

The model computes all of these today. What has been *built and run* is s1 and
s2. `scale-out-architecture.md` argues the ceilings that matter are modelling
ceilings — singletons where there should be shards (one clab file, one NetBox,
one ZTP server, one render process) — not capacity ones.

## 2. The two live fabrics

Everything in this document is measured against one of these.

| | **S1** | **S2** |
|---|---|---|
| host | `gpufab-fabric-01`, n2-highmem-64 | `gpufab-s11-fabric`, m3-megamem-128 |
| profile | `s1-512.yaml` | `s2-1024.yaml` (relocated to 172.28.0.0/22) |
| devices / switches | 124 / 48 | 258 / 106 |
| units | one pod | `dc1-pod001`, `dc1-pod002`, `core` |
| SoT | NetBox on `gpufab-ops-01` (10.10.0.20) | NetBox local to the fabric host |
| underlay BGP | 1,464 / 1,464 | 3,728 / 3,728 |
| EVPN | 16 / 16 | 32 / 32 endpoints (16 sessions) |
| admission gate | `tests/admit-experiment.sh` | `tests/admit-s2.sh` |

Both are **frozen and experiment-admitted**. S2's NetBox is local to its fabric
host, so host loss also loses that experiment's SoT — recorded deliberately: S2
is not an HA qualification.

## 3. Size of the thing

| | lines |
|---|---|
| `tools/` (platform) | 8,309 |
| `deploy/` incl. 24 checks | 17,403 |
| `tests/` (101 test files, 100 verify phases) | 32,980 |

**The verification net is roughly 4× the code it verifies.** That ratio is not
an accident or an excess; §III explains why it is the correct shape for this
system.

---

# Part II — Architecture

## 4. The layers

    profile (YAML, the intent)
        │
        ├─ fabric_model.py ──── the derivation: devices, links, addressing, units
        │      │
        │      ├─ expected.py ─ THE ORACLE: every count anything asserts
        │      └─ unit_plan.py ─ manifest R: which devices a unit owns
        │
        ├─ seed.py ──────────── NetBox: the source of truth, populated FROM the profile
        │      │
        │      └─ render_fabric_ztp.py / unit_ztp.py
        │             └─ per-device artifacts: config_db.json, frr.conf, manifest
        │
        ├─ gen_topology.py ──── containerlab topology (kind: sonic-vm | linux | bridge)
        │      │
        │      └─ unit_executor.py + ownership.py
        │             └─ THE SUBSTRATE: labs, docker networks, bridges, containers
        │
        ├─ provisioning
        │      ├─ ZTP path  (switches provision THEMSELVES from the served tree)
        │      └─ push path (unit_configure → interim_deploy → deploy_switch/deploy_host)
        │
        └─ verification
               ├─ verify.sh ─── 100 phases, workstation + on-host
               └─ admission ─── admit-experiment.sh (S1), admit-s2.sh (S2)

## 5. Source of truth and the oracle

**NetBox is the SoT**, seeded *from the profile*, and the fabric is rendered
*from NetBox*. That round trip is deliberate: it exercises the same path real
automation would take, and it means a render can disagree with the profile —
which is a finding, not a nuisance.

**`tools/expected.py` is the single oracle.** Every expected count in the system
derives from it, from the profile, through `fabric_model`. This is §3 rule 3 of
the working agreement — *one derivation per fact* — and it exists because every
check that invented its own expected number has been wrong at some point.

The rule has teeth. When the E-CONV-02 control measured 3,760 established
sessions against a derived 3,728, it **VOIDed rather than proceeding**: the sweep
was summing every address family while `bgp_peer_series` derives the ipv4
underlay only. Two different quantities. Without the oracle there would have been
nothing to notice against.

**Management units.** Every lifecycle unit — pods *and* the core shard — owns one
management subnet with explicit gateway, TACACS and ZTP addresses. The model
asserts no device holds a unit's infrastructure address; core-shard infra
addresses relocate to the top of the subnet when a device would otherwise collide.

## 6. The substrate and the ownership engine

Containerlab builds labs of `sonic-vm` guests (QEMU inside a container, via
vrnetlab), `linux` host nodes, and bridges. Three separate labs per S2 fabric —
one per unit — with cross-unit links on shared bridges.

**Everything the substrate creates is owned, and ownership is durable.**
`tools/ownership.py` is the engine:

- **`Ledger`** — an append-only, fsync'd journal of what this run caused to
  exist. Reloaded on start, so a crashed run's resources can be adopted and
  cleaned up rather than stranded. A malformed line is a refusal, not a skip.
- **`Resource`** — name, kind, and **identity**: what the object *is* as
  distinct from what it is *called*. A bridge can be deleted and recreated under
  the same name during the hour a deploy takes; cleanup that trusted names would
  remove a stranger's object.
- **`Transaction`** — `acquire` / `adopt` / `borrow` / `defer` / `release_all`,
  with a decision table (`TABLE`, `ACQUIRE_TABLE`) mapping observed state ×
  ownership → action, so no path is decided ad hoc.
- **`HostLock`** — one transaction per host, non-blocking. Bridge names are
  deterministic, so two concurrent runs of the same plan target the same objects;
  the dangerous interleaving is two runs both passing preflight before either
  mutates, which no per-resource check can close.

**The deletion protocol** (added 2026-09-17, §16.11) is a durable state machine:

    CONFIRMED ──authorize against the ORIGINAL identity──▶ DELETING ──verify──▶ ABSENT

- authorization happens **immediately before** the mutation;
- `DELETING` is recorded **before** `res.delete()`, so a crash mid-delete is
  recoverable rather than a permanent refusal;
- the postcondition is **absence**, not identity equality — a different question
  from the precondition, and conflating them was a real outage;
- a strict **subset** of the original members is an *owned partial deletion*,
  accepted only when `DELETING` was recorded; any **foreign** member refuses
  outright;
- the host lock is **enforced** across authorization and mutation, not documented.

## 7. Provisioning: two paths, and why both exist

**ZTP path** — the switch DHCPs, fetches `ztp.json` and its `config_db.json`
from a per-unit server, and applies it. This is the path that produced S1's
working EVPN, because the switch applies the *rendered artifact whole*.

**Push path** — `unit_configure.py` renders exactly the devices manifest R names
and pushes through `interim_deploy`, which merges intent into live running state.

They are **mutually exclusive for switches by construction**: a switch that has
been pushed to has a startup config, and SONiC ZTP does not run on a switch that
has one.

They were **not** mutually exclusive for *hosts*, and missing that cost 2,616
BGP sessions — §16.9.

**ZTP section ordering is load-bearing.** `00-download` must sort before
`01-configdb-json`. A plugin section placed *after* the config cannot fetch its
plugin at all: applying `config_db` enables `mgmtVrfEnabled=true` and moves eth0
into the `mgmt` VRF, while ZTP's downloader runs in the default VRF — plain curl
gets 000, `ip vrf exec mgmt curl` gets 200. That is why there are no sections
after the config, and why D8's repair lives in a deploy-side reconciler instead.

## 8. Verification architecture

**`tests/verify.sh`** — 100 phases, split into workstation-side (logic, renders,
lifecycles with fakes) and host-side (behaviour, measured on the boxes). The
split is a contract: phase 1 proves the hosts are what we think they are before
phase 2 judges what they are doing.

**Admission gates** are a different instrument from the suite. `verify.sh`
answers *"is everything about this platform correct"* and takes ~20 minutes;
an admission gate answers the one question an experimenter has before pressing
go, is read-only, and is designed to be run every time:

- **`admit-experiment.sh`** (S1) and **`admit-s2.sh`** (S2) both emit
  **ADMIT / REFUSE / UNKNOWN**, where UNKNOWN is *do not proceed* — unmeasured is
  never a pass.
- Both pin **behavioural trees**, not commit SHAs: `git rev-parse <rev>:<dir>`
  hashes for the directories that determine what the fabric *does*. A test or a
  document does not move the pin; a change to `deploy/` or `tools/` does. Pinning
  commits was tried and was wrong — the gate lives in a repo it pins, so
  committing it invalidated its own pin.
- The pin describes **what the live fabric runs**, not the tip of main. Those
  diverge the moment anything is promoted, and a gate that refused every
  experiment when main moved would train an operator to ignore it.
- Both carry a **negative control**: `--self-test` corrupts the expected revision
  and asserts the verdict becomes REFUSE. *A gate never seen to refuse is not
  known to be a gate.*

---

# Part III — The verification philosophy

## 9. Why the test net is 4× the code

`STABILITY-RETROSPECTIVE.md` measured it: **84% of defects were correctness or
verification-gap bugs** — the system did the wrong thing *and reported success*.
Capability gaps that running the system could have exposed: **zero**. Running the
system only finds defects in paths the system already has.

How defects were actually caught: ~22 by a human reading a real box, ~11 only by
a cold or scale build, ~9 in review — and only ~8 by a committed test *at the
moment it mattered*, because the tests kept being blind too.

**Three defect shapes, each paid for repeatedly:**

1. **Self-comparison (X == X)** — a check structurally unable to fail.
   `config_landed` built its "expected" config *from the box it was checking*;
   the BGP census divided by the switches that answered, giving *1428/1430
   healthy with 36 sessions dead*. Recurred ≥5 times, once inside the fix for
   itself.
2. **Presence ≠ function** — asserting the mechanism, not the outcome. BGP
   `Established` while zero prefixes moved: a ~15-hour overlay outage that read
   healthy. `config reload` exiting 0 with 44 of 48 switches at factory defaults.
3. **Silent success** — a real failure that exits 0. A *successful* role never
   wrote the result the launcher waited on because `exec` made the write
   unreachable; `--from` ran zero stages and printed "complete".

## 10. The binding rules

From `STABILITY-RETROSPECTIVE.md` §7, in force for every change:

1. **Assert the END STATE, measured on the real system — never the mechanism.**
   `rc=0`, `Established`, HTTP 200, "container started" are mechanisms.
2. **A check that observed nothing is a FAILURE.** Zero, empty and unmeasured are
   never passes; `${x:-0}` laundering "not measured" into "0" is the bug, not the
   guard.
3. **One derivation per fact.** A value in two places diverges silently into an
   outage.
4. **Presence ≠ function.**
5. **Cold and scale runs are verification instruments.** Follow the first
   observed failure; never paper over a degraded stage to reach green.
6. **Verify against the model, not the diff** — so a check can disagree with what
   was just done.
7. **Never swallow the evidence** — `>/dev/null 2>&1`, `|| true`, and `curl -f`
   on an auth-required endpoint have each hidden the error that would have ended
   a diagnosis in minutes.

**The through-line: distrust every green result until you can name what it
measured and confirm that thing is the outcome, on the real system.**

## 11. Practices that follow from it

- **Test-the-test.** A new check must be shown RED against a deliberately broken
  input before it is trusted green. Every check added recently carries its RED
  controls in the commit message.
- **A false RED costs what a false green costs.** Reading only the nested shape
  of `show bgp summary json` reported 0 EVPN peers for a switch with two
  Established neighbours — the reader manufactured D6's exact signature. The
  E-CONV-01 detection of **−2.99 s** was caught only because it was *implausible*;
  a few seconds of clock skew the other way would have been believed.
- **Operations live in committed scripts.** A `/tmp` script that is scp'd is
  unversioned, invisible, and unrepeatable; a one-off command produces a claim
  only its author can vouch for, and those claims have been wrong.
- **Managed background work is identified by marker, never by command-line text.**
  `tools/bg.sh` runs each job in its own process group with a `GPUFAB_BG`
  environment marker. Four waiters were missed by `ps | grep` in one session, and
  one `pkill -f` matched its own command line and killed the SSH session running
  it — both the same mistake, identifying a process by text another layer owns.

---

# Part IV — The defects, in detail

Grouped by what they teach. Each is: what happened, why it was invisible, what
changed.

> **A naming collision to know about.** There are **two unrelated `D`-series** in
> this repository. `ISSUE-REGISTER.md` uses `D` as a *review-pass letter*
> ("D. Fourth/fifth pass"), so its D1–D8 are deploy and firewall issues from that
> pass. The **runtime** D6/D7/D8/D9 used below and throughout the RUN-* documents
> are fabric defects (served ZTP tree, networkd-dispatcher, frr.conf stub,
> systemd-networkd). They are different namespaces that happen to share letters,
> and `ISSUE-REGISTER` D2 ("stopped-fleet preflight false green") is NOT the
> runtime D2 ("duplicate kernel bindings"). This document means the **runtime**
> series unless it says otherwise.

## 12. Host-level defects — the fabric's floor

### 12.1 D7 — networkd-dispatcher storms
`networkd-dispatcher` runs a script per link event and reloads its entire
interface list each time. At ~6,664 veths it is a fork storm that takes the host
down. **Fix:** mask the unit. **Why it was insufficient:** its own note said
systemd-networkd "is a DIFFERENT unit and is untouched by this" — which is
exactly why D9 was still waiting.

### 12.2 D9 — systemd-networkd managing containerlab's interfaces
At S2 scale, systemd-networkd itself becomes the storming party: **2,240 events
across 400 clab bridges**, then `169.254.169.254: network is unreachable` and
sshd dead **while the instance stayed RUNNING**. A build that cannot report why
it died.

**Fix:** an `Unmanaged=yes` drop-in matched **by driver** (`veth`, `bridge`) —
never by name. A name glob like `eth*` could strand the primary NIC, and *a host
stranded by its own guard is worse than the storm it prevents*.

**The fix's own regression:** applying it mid-script ran `networkctl reload`,
which does not merely re-read drop-ins — it *reconfigures existing links*,
including the primary NIC. Measured on the serial console: `ens4: DHCP lease
lost`, and the startup script died on the next command needing the network. Two
earlier hosts had survived the same reload purely on timing. **So D9 is applied
LAST, after all network-dependent work, and the script then waits for the
metadata server to answer again before declaring readiness.**

### 12.3 Both were single-copy, in the wrong place
D7 and D9 lived **only** inside `a4-host.sh`'s VM-creation startup script. A host
built by any other path had neither — and `gpufab-s11-fabric` was exactly that
host. It ran an entire S2 build with systemd-networkd managing all **405** of its
clab veths and bridges. It did not fire; that is luck, not safety.

**Fix:** `deploy/host_harden.sh` is now the single definition, with
`--apply`/`--d7`/`--d9` and a read-only `--assert`. `a4-host.sh` **embeds** it
into the generated startup script (a fresh VM has no checkout, so it carries a
copy generated from the one source) rather than restating it. `t99` asserts the
embed reaches the generated script exactly once, that the order is D7 → D9 →
assert, and that D9 matches by driver not name.

**And the fix had the classic bug:** run unprivileged, `--d7` returned 0 while
`systemctl mask` failed silently behind `|| true` — a step that did not happen,
reporting success, on the path that decides whether a host is safe to build on.
Both steps now verify their own effect.

### 12.4 Host capacity — the fatal one that every stage called green
S2 was built with **106 SONiC VMs on a host that runs 48**. Every stage reported
success: containerlab started all 106, all 106 went healthy, 104/106 fetched
`config_db`, ZTP reported finished. And the fabric was dead — `swss` exited or
never left `created` on essentially every device, so no `orchagent`, **0 of 39
ports programmed**, every BGP peer stuck in `Active`, **0 sessions**.

FRR named its own cause in `bgpd.log`:

    Thread Starvation: ... (bgp_connect_timer) was scheduled to pop
    greater than 4s ago     r=-10.493

Two calibration points on the *same machine type*:

| | VMs | VM/vCPU | idle | swss | ports | BGP |
|---|---|---|---|---|---|---|
| S1 | 48 | **0.75** | 83% | running | 39/39 | 1464/1464 |
| S2 | 106 | **1.66** | **0% for 28 consecutive samples** | dead | 0 | **0** |

**Guest RAM was not the discriminator** — S2 sat at 0.843 of MemTotal, just under
a 0.85 bound. Judging capacity on memory would have passed it. CPU density is the
only thing that separates them.

**Fix:** `deploy/checks/host-capacity.sh`, wired **into** `c12` after topology
generation and before the executor, counting `kind: sonic-vm` from the very
files containerlab is about to deploy. It refuses above the proven-good density
and states the remedy (*"106 VMs needs >= 142 vCPU"*) rather than only refusing.
Validated against both real hosts: exit 0 on S1, exit 1 on S2.

**The diagnostic lesson:** the hypothesis under test was "transient
synchronisation that will settle". It was falsified, not merely unmet — ZTP had
*already finished*, so there was no churn to settle, and 28 one-minute samples
showed idle `{0}`, healthy `{112}`, config_db `{104/106}`, perfectly flat. A
*stable starved state*, not a converging one. The gate that had been requested —
consecutive CPU-idle samples — could never have passed.

### 12.5 Nested virtualisation is Intel-only here
Resizing S2 met three stockouts, then `n2d-standard-128` (AMD) started and was
**rejected**: 128 vCPU, 504 GB, docker up, 100% idle — and **`/dev/kvm` absent**,
no SVM flag. The guests would have fallen back to TCG emulation. The host looked
perfect and could not run a single switch.

**The acceptance test for a candidate host is `/dev/kvm` on the booted machine** —
never the machine type's name, never a support matrix. Accepted:
`m3-megamem-128` (Intel, `kvm_intel` loaded, VMX present).

## 13. Provisioning defects

### 13.1 D6 — the served ZTP tree (diagnosed wrong twice first)
D6 was **not** artifact delivery and **not** `deploy_switch`'s second
derivation. It was two defects in the *served tree*, each leaving the server
reporting itself healthy:

1. `ztp/oob/dnsmasq.conf` hard-coded `dhcp-range=172.20.0.0` — a second
   derivation of the management network, correct only for S1's subnet. Any other
   unit got `no address range available for DHCP request via eth0` for every
   DISCOVER **while `serve.sh` printed `http OK` and `DHCP opt67 live`**.
2. The per-unit render omitted `identity_guard.sh`, which every `ztp.json`
   references. Switches leased, fetched `ztp.json` 200, fetched it 404, and
   stopped — never reaching `config_db.json`.

Both present from outside as *"the switches are still booting"*. This is why a
run reported `l2vpn evpn peers: 0 / 0` with every stage green.

**Confirmed by response time, not reasoning:** after re-serving with the correct
range, DHCPACKs appeared **within 3 seconds** — the switches had been retrying
all along.

### 13.2 D8 — `frr.conf` replaced by a three-line stub
Not SONiC nondeterminism. `docker_init.sh` does `rm -f /etc/frr/frr.conf` when
the routing mode is absent at bgp-container start, and `write_default_zebra_config`
then creates a stub in its place. **The deleter is the bgp container, not ZTP** —
which is why the box survived both `restart bgp` and `config reload -f`: both
restart a device whose `frr.conf` is already a stub.

Reproducible on demand: delete the file, restart bgp, AF goes 1 → 0.

**Fix:** `deploy/evpn_reconcile.sh`, operator-invoked *after* provisioning,
scoped from manifest R by identity. Three lessons, each learned by running it
against a deliberately broken VTEP rather than by reasoning: **present is not
correct** (the stub exists, so an existence check refuses to repair); **verify
what arrived** before overwriting; **the mgmt VRF is not optional**.

### 13.3 Host nodes were never configured — 2,616 sessions
`c12 --ztp` skipped the push configurer entirely. Correct for switches. But
`unit_configure.py` routes every node that is **not** `kind: sonic-vm` to
`interim_deploy.deploy_host`, and `gen_topology.py` launches host nodes with
`cmd: "sleep infinity"` precisely because *"daemons are started by the deploy
tooling"*. In ZTP mode that tooling never ran, so FRR never started in a single
gpu/cpu/storage container.

Result: **2,616 of 3,728 derived BGP sessions configured on the switch and dead
on the host side** — while ZTP reported 106/106, t92 passed 15/15 per pod, and
every stage was green. S2 had never had a run where *both* layers were correct:
the push path gave hosts and broke EVPN (D6); the ZTP path fixed the overlay and
lost the hosts.

**This was reported as "S2 is up"** on the strength of 1,144 established
sessions — a raw count with no configured total and no derived expectation beside
it. The derived comparison showed 3,728 configured. *A measurement is not an
expectation.*

**Fix:** `--configure-hosts-only`. The SONiC set comes from the **topology's own
`kind`** — the field containerlab dispatches on — so "is this a switch" has one
derivation and cannot drift from a name. `configure_targets(hosts_only=True)`
subtracts it from R's `configured`; selecting zero devices REFUSES rather than
reporting success; and `sonic_push_refusal` states the same rule *independently*
at the push, so the two derivations disagreeing is a refusal rather than a silent
second writer on a ZTP-provisioned box.

### 13.4 `ztp_wait` reported numbers it had not measured
The waiter polled **serially**, trying two passwords per device at
`ConnectTimeout=10`, so an unreadable device cost 20 s. At 106 devices with 59
unreadable, one sweep cost **~20 minutes** against a 1,800 s budget — it
completed roughly one pass and printed that pass's counts as if current. It
reported `18/106 SUCCESS, 59 unreadable` for a fabric where 104/106 had already
fetched config and ZTP had finished.

Not a green that measured nothing — **a RED that measured something stale and
presented it as the present.**

**Fix:** concurrent sweeps (measured: 12 probes × 1 s take 1 s vs 12 s serially);
the credential derived **once, by measurement**, never assumed — assuming it made
an auth failure indistinguishable from a dead device, so the waiter blamed the
fabric for its own inability to log in; and SUCCESS **counted**, not computed by
subtracting the other buckets.

## 14. Fabric-state defects

### 14.1 D2 — duplicate kernel address bindings — **CAUSE STILL UNKNOWN**
The same address bound on both the rendered port and a pre-rebaseline port 8
higher. It cost 178 BGP sessions across three independently built fabrics with
**nothing anywhere reporting an error**, and it recurred after being repaired.

The repair is scoped and gated: `d2-precondition.sh` requires the exact current
`(interface, address)` delete set to match a human-approved *identity set* —
refusing on any added, missing or changed pair — because the repair recomputes
its own delete set at run time and a set approved for 46 specific bindings must
not silently delete 47, or 46 different ones.

**The re-adding agent has never been identified.** This is the largest open
correctness question in the system.

### 14.2 #129 — literal SoT addresses
A literal SoT address outlives the host it names, and a run pointed at the wrong
SoT does not merely mis-measure — **it provisions a different fabric while
reporting success**. `roles/fabric.sh` defaulted `SOT=10.10.0.20`, a host that
was by then terminated.

`tests/t52` scans for literals with exactly one checksum-bound exception, and it
scans **untracked files too**.

**It caught me.** On 2026-09-17 an experiment probe hardcoded
`NETBOX_URL=http://10.10.0.58:8000`. S1's admission gate returned REFUSE — and
the cause was an uncommitted file on the workstation, not anything wrong with S1.
Written by the person who had been citing #129 all session. The address is now
derived from `/opt/gpufab/sot` or required from the caller, never guessed.

### 14.3 EVPN: presence ≠ function, three times
`#118 → #141 → #139`. BGP sessions `Established` while zero prefixes moved — a
~15-hour overlay outage that read healthy. The fix each time was to assert the
*exchange* (`pfxRcd>0 or pfxSnt>0`), the on-box tables against the rendered
artifact, and the remote-VTEP count the model derives — not the session state.

`t92` is the resulting acceptance: per-device assertions, domain-derived
expectations, an explicit **UNREADABLE vs measured-zero** split, a tenant
dataplane forwarding check, and a negative control that corrupts a
`VXLAN_TUNNEL` to prove the comparison can fail.

### 14.4 The reader that manufactured a defect
`show bgp summary json` nests peers under an address-family key;
`show bgp l2vpn evpn summary json` puts `peers` at the **root**. Reading only the
nested shape reported 0 EVPN peers for a switch with two Established neighbours —
D6's exact signature, produced by the reader. **A false RED costs what a false
green costs.**

## 15. Lifecycle and ownership defects

### 15.1 Destroying on an ambiguous signal
An automatic rebuild fired on "BGP below threshold" while a fabric was still
converging, and reached `containerlab destroy` on **124 live nodes**. Rule since:
**automatic action requires an unambiguous signal; anything else reports and
stops.**

### 15.2 Recovery that was structurally impossible
The ledger used to default into a fresh `mktemp -d` per invocation, so
`--recover` always read a ledger created empty microseconds earlier: it adopted 0
entries, released nothing, and printed `c12 VERDICT: OK` while the crashed run's
bridges, networks and labs were still on the host. **Durable ownership without
durable release is a worse promise than none.**

### 15.3 The ZTP servers are outside the ledger — twice now
`c12-ztp-<unit>` containers are created by `ztp_serve_units.sh` as plain docker
containers: no containerlab label, no ledger entry. They restart on host boot and
hold the `c12-oob-*` networks open, so the network delete fails and `--recover`
cannot complete. Recorded 2026-09-12; **it then blocked recovery from a failed
teardown on 2026-09-17.** Still open.

### 15.4 The teardown that invalidated its own authority
The defect that produced the newest engine work. A per-unit teardown refused
**mid-delete** and left `dc1-pod002` at 0 containers, the fabric at 1,864/3,728,
and the ledger holding entries for a unit that no longer existed.

`release_all` judged a half-deleted object by whether it still **equalled** the
confirmed identity. A lab's identity is its **container-ID set**, and
`containerlab destroy` removes them as it runs — so on the next pass the set had
shrunk from 124 ids to 3 and the guard concluded someone had replaced the object:

    FAIL lab:c12-dc1-pod002 is not the object we created —
         identity was '<124 ids>' and is now '<3 ids>'.
         Something replaced it during the run; refusing to delete someone else's resource

**The teardown invalidated the identity that authorises the teardown.**

"Capture identity once" does not fix it — that still misses a replacement race.
The fix is the durable transition in §6, with the ordering (mark `DELETING`
*before* mutating) load-bearing: the failure must be in the safe direction, since
a marker for a delete that never started costs nothing while the reverse
authorises a stranger.

`t101` fault-tests it host-free with 42 assertions and five RED controls,
including a delete that **dies inside the call** followed by a new process that
must resume it. One of those controls did not fire at first — a gap in the test,
not the fix: the fake returned early instead of dying mid-call, so the marker was
written either way and the ordering *looked* tested when it was merely unprobed.

### 15.5 What the incident also proved — scoping holds
The release adopted **4 exclusive resources and left 404 owned by other units**;
`pod001` (124 containers) and `core` (10) were byte-identical before, mid and
after, verified independently of the gate's own fingerprint. `_exclusive_to()`
records why this is safe: *every* bridge is shared between a pod and the core,
none is exclusive, so a partial teardown leaves cross-unit links standing.

**Blast radius was exactly the unit named.** That is the property the incremental
architecture most needs, and it survived the failure.

## 16. Process defects

### 16.1 Background work identified by text
Claude Code wraps a background command, so the script name is **not** in the
command line. A waiter polling a dead log survived **1d 13h and two explicit
searches**. `tools/bg.sh` fixed it with an environment marker, per-job process
groups, and kill/sweep that *verify absence* rather than trusting a signal.
Its own first test failed by matching the shell running the test.

**Scope discipline that came with it:** "no live jobs, no orphans" means *no
GPUFAB_BG-marked work remains* — not that the host has no unrelated background
processes. Reporting "nothing is running" from a check that looked at part of the
machine is how the 1d13h waiter was declared absent twice.

### 16.2 Reading a refusal as a statement about the world
During the 2026-09-17 recovery I reported *"nothing was destroyed"* on the
strength of the engine's refusal message. The refusal had fired **after**
containerlab tore the lab down; container counts and session totals said the
opposite. **A refusal message is not a measurement.**

---

# Part V — Experiments

The platform exists for these. Method as much as result.

## 17. E-CONV — reconvergence

Each has a fixed contract written *before* the measurement: decision, observable,
oracle, confounders, safety, controls, outcome.

| | what it established |
|---|---|
| **E-CONV-01** (closed) | method works; near-end detection sub-second; settle ~36–43 s against a 30 s hold. Consistent with timer domination; **could not establish it** |
| **E-CONV-02** | settle shifts **21.70 s for a 21 s hold reduction — 1:1**; far-end transition tracks negotiated hold (30.05 s @ 30, 8.42 s @ 9). Timer conclusion established for that link |
| **E-CONV-03** | same method on a link identical in **both** fabrics; the ~6.5 s residual **reproduces on a different link role** |
| **E-CONV-04** | the S1 leg: 48 switches vs 106, everything else held constant |

**The size comparison result:** across a 2.2× change in fabric size — with link
role, port identity, peer addresses, timers, fault mechanism, polling and clocks
all held constant — **no reconvergence difference above ~1–2 s was detected**.
Stated as a *bound*, not invariance: the settle detector polls at 3 s with two
stable samples, so a smaller effect could not have been seen.

**The decomposition, on two fabrics:**

    reconvergence = hold timer (1:1, negotiated)
                  + ~6.5–7.5 s residual, up to ~3.5 s of which is the detector
                  + no detected size term over 48 → 106 switches

**Two measurement defects the experiments' own controls caught:**
- an **oracle mismatch** (3,760 measured vs 3,728 derived — all address families
  vs ipv4 underlay), which VOIDed *before any fault was applied*;
- a **two-clock subtraction** reporting a detection **2.99 s before its own
  cause**, because the fault was timestamped on the host and the detection inside
  the switch VM.

**A model that fits and is not proven:** the far end transitions in
`[hold − keepalive, hold]` because the hold timer counts from the **last received
keepalive**, not from the fault. All eight default-timer trials fall in that band.
Not tested by controlling the phase deliberately.

## 18. E-LIFECYCLE-01 — the unit lifecycle

Tested `BRINGUP-ARCHITECTURE.md` §9.3's first substrate. **NOT DEMONSTRATED** —
see §15.4. Evidence design worth keeping: **container identity** proves both
halves with one measurement, since a container never destroyed keeps its docker
ID, so the target's IDs must *differ* and the others' must be *identical*.

---

# Part VI — Where it stands

## 19. Open, and honest about it

| item | state |
|---|---|
| **D2 re-adding agent** | **unknown.** The largest open correctness question |
| **§9.3 substrate-1** | NOT DEMONSTRATED. Transition implemented and fault-tested; the *demonstration* needs a real-fabric rerun |
| **ZTP servers outside the ledger** | open; has now blocked recovery twice |
| **`--deploy-unit` re-serves ALL units** | the serving step sits outside the ownership scoping |
| **residual composition** | ~6.5 s not separated into detector vs route propagation |
| **scale beyond 2.2×** | nothing measured above s2-1024; the ladder goes to s5-32768 |
| **SoT/render as the real ceiling** | believed, **never measured** |
| **host checkout drift** | S1 hosts ~69 commits behind; evidence, not noise — the baseline differs from main |
| **`90-automation`** | GitHub Actions runner never bootstrapped |
| **SNMP** | UNKNOWN / NOT-MEASURED, deliberately not relabelled |
| **cross-pod overlay** | no path exists by construction; each pod's VTEPs are their own EVPN domain |

## 20. The pinned-expected-failure discipline

S1's gate pins exactly two failures as expected on the frozen baseline —
`fabric role failed before completion` and `stages with NO artifact` — and treats
**any** other failure, *including a changed signature on those two*, as a
regression. This is how a known-imperfect baseline stays useful without the
imperfections rotting into a silent allowance. The same mechanism was *misused*
once, when a known-absent 2,616 sessions was recorded as a "declared deficiency"
inside an **ADMIT** verdict; that was corrected — **a declared deficiency belongs
in a RED verdict, never an acceptance waiver.**

## 21. If you read one thing

`STABILITY-RETROSPECTIVE.md`. This system's defining property is not its scale or
its protocol coverage — it is that **its failures are silent by default**, and
almost every structure described above exists to make one specific class of
silence audible.
