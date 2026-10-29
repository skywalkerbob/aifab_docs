# Measuring what a cross-host tunnel costs

Status: **instrument built and tested; the paid run is not authorised.**
Date: 2026-10-28

---

## 1. Why this is being measured

`max_vm_per_vcpu: 0.75` (`gpufab-platform/tools/gcp_catalog.yaml`) was calibrated
on **S1 — 48 switch VMs on one 64-vCPU host with zero cross-host links.** That is
the only rung ever actually built. Every rung above it already *plans*
cross-host links:

| rung | fleet_machine | hosts | local links | **cross-host links** |
|---|---|---|---|---|
| s0-64 | n2-highmem-64 | 1 | 225 | **0** |
| s1-512 | n2-highmem-64 | 1 | 1466 | **0** |
| s2-1024 | n2-highmem-64 | 3 | 2932 | **400** |
| s3-4096 | n2-standard-80 | 5 | 11730 | **800** |
| s4-10240 | n2-standard-80 | 11 | 28965 | **2000** |
| s5-32768 | n2-standard-80 | 35 | 92460 | **6800** |

(Derived by executing `fabric_model.place()`, 2026-10-28.)

**Nothing charges those crossings.** The bound has no tunnel term;
`place()` computes its VM budget at `fabric_model.py:1241` *before* any
assignment exists, while the crossing count is only known at `:1337` *after* all
of it; and that count is returned as a **bare total** with no per-host
breakdown, so there is currently nothing to charge a host *with*.

So this is not a question about a hypothetical pod split. It is an uncharged
term in the capacity model of the ladder we already intend to build.

## 2. Why the obvious measurement returns the wrong answer

The `vxlan-stitch` datapath is entirely in the host kernel:

```
guest tap → veth ve-<node>_<iface> → tc ingress mirred redirect
          → vxlan netdev vx-<node>_<iface> → UDP encap → underlay NIC
```

Not one step is attributable to a process. `top`, `docker stats` and per-container
cgroup CPU accounting all show approximately nothing, so a probe built on process
CPU reports that tunnels are **free** — confidently, and wrongly. That is
CLAUDE.md §3's failure mode exactly: the system does the wrong thing and reports
success.

The cost lands in **softirq + system + irq jiffies on the host**
(`/proc/stat`). The ceiling shows up as **NAPI budget exhaustion**
(`/proc/net/softnet_stat` `time_squeeze`). The silent-loss mode shows up in the
**mirred action's own `Sent … (dropped …)` statistics**, which nothing in this
codebase read before `tools/tunnel_cost.py`.

## 3. Two costs, never one number

| | scales with | paid when |
|---|---|---|
| **Structural** | tunnel **count** | always — a netdev, two tc filters, a neighbour entry each |
| **Per-packet** | packet **rate** | only under load |

Conflating them is how a capacity model goes wrong at the rung nobody tested.
And the per-packet term must be expressed **per packet, not per gigabit**: this
fabric's cross-host traffic is control plane (BGP updates, EVPN routes), so a
per-gigabit figure flatters the substrate by orders of magnitude.

## 4. What is being differenced — and why it is not "tunnel vs nothing"

Splitting a pod, or spreading a fabric, does **not add links. It converts local
ones.** The cost that matters is therefore the delta between carrying a given
link as a local veth and carrying the same link as a stitched tunnel. A figure
measured against an idle host charges the substrate for the whole cost of moving
the packet — which the fabric pays either way — and overstates the charge.

`tools/tunnel_cost.py` requires three conditions and refuses to produce a cost
without all three: `idle` (the host's own kernel floor and the structural
sweep), `local` (the load over a veth), `tunnel` (the same load over a stitch).

## 5. THE EXPERIMENT — one fabric, two placements

`s1-512-small` has 59 switch VMs (2 pods of 26, plus 7 cores). Changing only its
`placement.fleet_machine` moves it between a one-host and a two-host placement,
**with the device set, the BGP session count and the link set all identical**:

| arm | machine | hosts | switch VMs/host | local links | **cross-host** |
|---|---|---|---|---|---|
| **A** | 1 × n2-standard-80 | 1 | 59 | 1914 | **0** |
| **B** | 2 × n2-standard-80 | 2 | 30 / 29 | 1690 | **224** |
| **C** | 2 × n2-standard-48 | 2 | 30 / 29 | 1690 | **224** |

The only difference between A and B is that **224 links moved from veth to
vxlan-stitch**. Difference the host kernel CPU, normalise per packet, divide by
224 → the per-tunnel charge **at real fabric load**.

This is strictly better than a synthetic load test, for three reasons:

1. It measures the real control-plane traffic, not an invented flow.
2. **It needs no `pps_per_tunnel` input** — the fabric supplies its own load, so
   the one unmeasured number that would otherwise gate the decision disappears.
3. It *is* a split, so it answers the question directly rather than by inference.

**A vs B** isolates the tunnel cost on identical hardware. **B vs C** then says
whether the smaller, cheaper host can carry it.

### Residual confounders, stated rather than claimed away

- **Guest density differs between arms** (A: 59/80 = 0.74; B: 30/80 = 0.375).
  Per-packet normalisation handles the load difference, but contention regimes
  are not identical. Arm C is closer to A on density (0.625) at the cost of
  changing the machine type, which is why both B and C are worth running.
- **The saturation ceiling does not transfer between machine sizes.** NIC queue
  count scales with vCPU, so a ceiling observed on one machine says nothing
  about another. Per-packet *cost* does transfer within the N2 family.
- **Offload state** (`tx-udp_tnl-segmentation`, GRO) swings the per-byte figure
  by about an order of magnitude and is recorded with every sample.
- **Steal** on a shared GCE host is the hypervisor's cost, not the tunnel's;
  recorded, and bounded at 2% by a declared threshold.

### Spend

On-demand: A $3.88/h, B $7.76/h, C $4.66/h. Spot: $1.36 / $2.72 / $1.64.
Three arms at roughly 2h each ≈ **$33 on demand, ≈ $11 spot.**

## 6. What is built, and what is not

**Built and proven (host-free):**

- `gpufab-platform/tools/tunnel_cost.py` — the single derivation. Parsers for
  `/proc/stat`, `/proc/net/softnet_stat`, `ip -s -d link show` (text form — `ip
  -j` emits malformed JSON for a VXLAN device on the iproute2 the fabric hosts
  run), `tc -s filter show` mirred statistics, `ethtool -k`. Differencing, the
  structural least-squares fit, the per-packet delta, the planner charge, an
  11-leg table and a PROVEN / NOT-PROVEN / UNREADABLE verdict.
- `gpufab-platform/tests/t122-tunnel-cost.sh` — 46 assertions. Every figure in
  closed form against synthetic `/proc/stat`; every refusal; contamination
  (squeeze, drops, steal, unrecorded offload) as findings rather than data.
- `gpufab-platform/deploy/checks/tunnel-cost-probe.sh` — contract, host
  lifecycle (delegated to `a4-host.sh`), sampler contract, `plan` mode that
  states the spend and creates nothing.

**Deliberately refusing rather than guessing:**

- `USER_HZ` is **measured** from the samples (summed jiffies / nproc / window)
  and the same arithmetic is the consistency check on the window. A window that
  cannot be reconciled with its own duration is rejected, not scaled.
- `pps_per_tunnel` has **no default**. Supplied only by a fabric measurement;
  until then `PLANNER_CHARGE` and `BOUND_SURVIVES` stay `NOT-ASSERTED` and the
  verdict cannot be PROVEN. The §5 experiment removes this need entirely.
- A tunnel measuring **cheaper** than a veth is reported as not credible, never
  clamped to zero — clamping would publish "tunnels are free" from a broken run.
- Format coverage comes only from **real captures** in
  `tests/fixtures/tunnelcost-*`. t122 SKIPs loudly while they are absent rather
  than passing: a hand-written fixture asserting a format nobody has seen is how
  `ip -j`'s malformed VXLAN JSON got as far as it did.

**Not built:** the lab build, the forwarding proof
(`tunnel_check.py` + `df_probe.py`), and the load drive — gates 2–4 of the
probe. It tears both hosts down and VOIDs rather than improvising them, because
a paid run with unwritten middle gates produces exactly the
plausible-but-unfounded number the contract exists to prevent.

## 7. Open defects found while building this

1. **`tools/gpufab.py:449-458` is a second, independent derivation of host VM
   capacity.** It derives from `sonic_vm.vcpu = 2` and `sizing.cpu_oversub = 1.5`
   → 0.75 VM/vCPU — numerically identical to `max_vm_per_vcpu`, arrived at from
   two unrelated numbers, and it never reads the catalog. Both inputs are
   profile-overridable. It feeds `gcp.machine_type: None  # auto-pick`. A tunnel
   term added to the catalog and to `place()` would leave the machine recommender
   permanently pre-tunnel and `verify.sh` would stay green. Violates §3 rule 3.
2. **Nothing asserts `placement.fleet_machine` == terraform's
   `fabric_machine_type`.** There are *four* independent machine-type defaults:
   `terraform/fabric.tf:75` (n2-highmem-64), s3/s4/s5 profiles (n2-standard-80),
   `terraform/stage-c/variables.tf:26` (n2-standard-96),
   `deploy/checks/a4-host.sh:30` (n2-highmem-32). `fabric.tf:70-73` states the
   hazard in a **comment and nowhere else**. `fabric_host_count` defaults to 1
   against measured placements of 3 (s2) and 5 (s3).
3. **All four `scale-small` profiles are unplaceable as committed.** They declare
   `fleet_machine: n2-highmem-16` (admits 12 VMs at the bound) against pods of 26
   switch VMs, so `place()` refuses every one of them.
4. **The crossing predicate `assign[a] != assign[b]` is written out five times**,
   twice in production code (`fabric_model.py:1337` in `a`/`b` form,
   `gen_topology.py:689` in `a`/`z` form). Nothing exports a
   `crossing_links(model, assign)`.
5. **`GPUFAB_MAX_VM_PER_VCPU` overrides the gate but not the planner.**
   `tests/experiments/e-lifecycle-01-probe.sh:114` sets it to 0.85, so that run's
   gate admitted 0.85 while `place()` still planned at 0.75.

## 8. A LIVE defect found while checking this: the core unit is served by nothing

The management-network hazard turned out to be **real, already planned, and not
about splitting pods at all.**

`fabric_model.management_units` is explicit that a lifecycle unit — *"pods AND
core shards"* — **owns exactly one management subnet**, and lists three refusals
because *"every one of these has a silent failure mode that ends in a fabric
served by nothing"*:

- a unit spanning more than one mgmt subnet has no single server address;
- a unit with no addressed device cannot host a server;
- a device in zero units is never rendered, in two it is rendered twice.

`deploy/ztp_serve_units.sh` then creates **one server per unit, on that unit's
own docker network, at that unit's own derived address.**

Meanwhile `place()` spreads core switches round-robin across hosts, with the
stated reason that *"a core switch has no locally attached nodes, and its links
all run to spines already spread across hosts, so co-locating or splitting them
costs nothing."* **That is true about links, and became false once units started
owning a management subnet.** `management_units` was written later, for the
multi-pod ZTP fix.

Measured, 2026-10-28, by crossing `management_units()` against `place()`:

| rung | hosts | units | the `core` unit |
|---|---|---|---|
| s1-512 | 1 | 1 | n/a |
| s2-1024 | 3 | 3 | all 10 devices on `host-core01` — **safe, by bin-packing outcome, not by design** |
| s3-4096 | 5 | 6 | **20 devices spread 4-per-host over all 5 hosts**, one ZTP server at `172.20.35.252` |

On s3-4096 as planned today, one host gets the `core` unit's server and the
other **16 of 20 core switches sit on four other hosts** — each on its own
host-local docker bridge carrying the *same* name and the *same* subnet, with no
server on it and no route to the one that exists (the substrate carries only
cabled fabric links; nothing tunnels `eth0`). They would be served by nothing,
with every stage reporting success. s4-10240 (11 hosts) and s5-32768 (35 hosts)
spread it wider.

**The three refusals cannot see it**: a spread core unit spans one subnet
(passes), has addressed devices (passes), and has every device in exactly one
unit (passes). The missing invariant is a fourth one of the same kind —

> a unit whose devices span more than one HOST has no single server address
> either, and serving one host strands the rest.

s2-1024 passing is luck: the spill loop happened to put all 10 cores on one
host. A profile change could regress it silently.

### Three ways out, and what each costs

| | change | cost |
|---|---|---|
| **a** | place the core unit atomically on one host | s3's five hosts have ~10 free VM slots each and the core unit needs 20 — so this buys a **sixth host** |
| **b** | shard the core into one unit per host, each with its own subnet and server | matches the design's own language (*"core shards"*, plural); likely the cheapest and most faithful fix |
| **c** | make a unit's ZTP server reachable cross-host | re-opens the routed-OOB work and widens the firewall surface |

**(b) is the recommendation.** It needs a decision, not an edit, so it is not
being made here.

### This does NOT affect the §5 experiment

Arms A/B/C spread **whole pods**, one per host — each pod is a unit, each unit
lands entirely on one host, each gets its own server on its own bridge. That is
the supported shape and S2 runs it today (t92 15/15 per pod). Splitting a *pod*
remains exposed to exactly the defect above, and that is now the strongest
argument against it — stronger than any CPU figure.


---

## 9. Measured on a box, 2026-10-28 (gpufab-ops-01, kernel 6.17.0-1021-gcp, iproute2 6.1.0, clab 0.77.0)

`gpufab-platform/tests/tunnel-cost-surfaces.sh` built a `vxlan-stitch` lab,
captured every surface and committed 45 real fixtures
(`tests/fixtures/tunnelcost-*`, 199 KB). **All nine surfaces are readable.**
Column layouts are confirmed against the box, not assumed — `softnet_stat`'s
15th column carries the CPU index, which is what proves the first three are
`processed / dropped / time_squeeze`.

### The finding that changes the expected answer

```
tx-udp_tnl-segmentation:        off [fixed]
tx-udp_tnl-csum-segmentation:   off [fixed]
tx-gso-partial:                 off [fixed]
generic-segmentation-offload:   on
generic-receive-offload:        on
large-receive-offload:          off [fixed]
```

`virtio_net` has **no tunnel-segmentation offload at all** — `[fixed]` means the
feature is absent from the device, not merely disabled — and all 32 tunnels
agree. **VXLAN encapsulation is segmented in SOFTWARE on this platform and
cannot be otherwise.** GSO is on, so the kernel does it on the CPU.

So the per-byte cost the paid run measures will be a *software-segmentation*
cost. A host on gVNIC or bare metal with hardware tunnel segmentation could be
roughly an order of magnitude cheaper for identical offered load. The driver is
therefore **part of the measurement**: `tunnel_cost.py` records it with every
sample, and its `OFFLOAD_RECORDED` leg requires the feature flags *and* the
driver, and refuses if the conditions disagree about either — because the two
arms are taken on different machines, and one arm offloading while the other
does not would charge the tunnel for the difference between two platforms.

### Structural cost: essentially free at rest

| K tunnels | host netdevs | deploy | destroy | idle system+softirq / 10 s | time_squeeze Δ |
|---|---|---|---|---|---|
| 0 | 12 (**+2**) | 606 ms | 303 ms | 126 jiffies | 0 |
| 8 | 28 (**+18**) | 1420 ms | 635 ms | 746 | 0 |
| 32 | 76 (**+66**) | 2581 ms | 919 ms | 302 | 0 |

**Netdev count is exact and perfectly linear: `12 + 2K`** — one `vx-` and one
`ve-` per stitched link. Creation averages ~62 ms/tunnel (marginal 102 → 48),
so 224 tunnels build in ~14 s and 800 in ~50 s. Not a constraint.

**An idle tunnel is close to free**: 32 tunnels cost 4–9 softirq jiffies per 10 s
across 4 CPUs, and `time_squeeze` moved **0** at every K. **So the cost is
per-packet, not per-tunnel-existing** — which is what the structural/per-packet
split was built to distinguish, and it lands on the per-packet side.

The CPU column above is **not** a per-tunnel claim and the data says why: it is
non-monotonic in K (746 at K=8, 302 at K=32) because ops-01 is a 4-vCPU shared
instance also running NetBox, Postgres, Prometheus and Grafana. Memory per
tunnel is **unmeasurable there** — the deltas change sign and the untouched
baseline drifted 123 MB during the run.

### The attribution surface counts real traffic, proven

| phase | `ve-` RX | `ve-` mirred | `vx-` TX | `vx-` TX **errors** | `vx-` RX | `vx-` mirred | far-end RX/TX | ping |
|---|---|---|---|---|---|---|---|---|
| txhalf (blackhole) | 205 | **205** | 211 | 0 | 0 | 0 | — | 200/0 |
| hairpin (`remote 127.0.0.1`) | 203 | **203** | **0** | **209** | 0 | 0 | — | 200/0 |
| peer (far netns) | 205 | **205** | 211 | 0 | **204** | **204** | **211 / 204** | **200/200** |

The tc mirred counter equals the veth RX count **packet for packet** in all
three phases, and the decap-side counter matches too. Corroborated by an
independent witness in another namespace (`vx- TX 211 == far RX 211`), and by an
end-state proof rather than a counter: `200 transmitted, 200 received, 0% loss`.
This is the difference between a surface being *present* and it *counting real
traffic*.

### Three traps the captures caught

1. **A tunnel can lose every packet with `dropped` at zero.** The hairpin
   (`remote 127.0.0.1`) deploys cleanly, looks healthy, fires its redirect 203
   times — and transmits **0** packets while booking **209 TX errors**. The
   kernel's `vxlan_xmit` refuses an `RTCF_LOCAL` destination. The loss appears
   in the tunnel's TX **`errors`** column and **nowhere else** — not `dropped`,
   not any tc counter, not snmp. A reader of bytes/packets/dropped alone would
   report a tunnel discarding 100% of its traffic as a tunnel with nothing
   wrong. `t122` now proves the drops leg fails on TX errors with `dropped=0`.
   It also means **the decap half can never be measured by pointing a tunnel at
   the host's own address** — a peer netns or a second host is mandatory.
2. **The `fan-map` token is live on this platform in the TEXT form too.**
   Ubuntu's iproute2 carries the fan-networking patch, so an `ip link`-created
   vxlan device prints a stray `fan-map` token mid-detail-line — the same token
   behind fact 3's malformed JSON — and **it shifts the position of `dev`**. A
   positional parser would mis-read it. `tunnel_cost.py` keys on the capture's
   own `RX:`/`TX:` header names and never on a field offset.
3. **The u32 filter's own hit counter does not exist here.** The `-gcp` kernel is
   not built with `CONFIG_CLS_U32_PERF`, so the text never appears. It stays
   `UNMEASURED` — rendering it `0` would assert "the filter was never hit" about
   a filter that forwarded every packet.

### Teardown

Verified twice — by the script's trap and again independently in a fresh
session: host netdevs back to the baseline 10, zero `vx-`/`ve-` devices, zero
netdevs carrying any `vxlan id` anywhere on the host, zero namespaces, zero
containerlab-labelled containers, zero `ingress`/`clsact` qdiscs against a
recorded baseline of 0. NetBox answering before (HTTP 403 — auth required, i.e.
alive) and after. No token was read or emitted.

A trap worth keeping: `http://localhost:8000/api/` returns **curl rc 7, code
000** on that host because NetBox is published on the primary address, not
loopback. A liveness check written the obvious way would report a false DEAD and
abort against a perfectly healthy SoT. The endpoint is derived from
`docker port`, not written down.
