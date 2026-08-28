# #87 — VXLAN/EVPN as the first declared feature module

Written 2026-07-28. Records the plane decision, the measurements that settled it,
and three defects the measurements found in the design this implements.

The code is **not committed to `gpufab-platform` or `gpufab-network`** — see
"Where the code is" at the end. The patch series is in `evidence/i87/`.

---

## 1. The decision: the FRONTEND fabric, and the module is named `evpn`

`fabrics: [frontend]` — the word is `fabrics`, not `planes`, because "plane"
means three unrelated things in this architecture and only this word means the
backend/frontend/storage/oob axis.

Four reasons, each checkable against the repo rather than against vendor docs:

1. **The backend is pure L3 by design and by measurement.** Rail-optimised
   `/31` + eBGP + ECMP, converging 1464/1464 with no overlay. An overlay there
   adds encapsulation to RoCE traffic whose entire point is that it has none,
   and there is no tenancy inside a rail to separate. `gpufab-sim-design.md:227`
   already records it as risk R3, "**Designed out**".
2. **Storage is the same pattern**, plus a service VIP (`10.255.2.100/32`)
   advertised by the active DDN controller — anycast that already works without
   an overlay, on links equally sensitive to added latency.
3. **The frontend is the only fabric already shaped for L2.** `s1-512.yaml`
   declares `frontend: {leaves: 3, spines: 2, peer_links: 1}`. Storage declares
   no `peer_links`, because only a single-active SVI gateway needs one. That
   peer link is a structural signal in the profile itself.
4. **The segments are already declared and implemented nowhere.**
   `design/policy/addressing.yaml:29` holds `frontend_vlans` — VLAN 100
   `compute`, VLAN 200 `provisioning`, with prefixes and gateways. **Measured
   2026-07-28: zero code references in either repo.** A declared policy nothing
   consumes is worse than none.

**Blast radius, measured:** 3 VTEP devices of 48 switches. Frontend spines carry
the EVPN address family and no VTEP; every backend and storage device is
untouched. Verified by rendering all three classes — see §4.

**What was rejected.** `backend` (reasons 1 and 2; but the mechanism still
*permits* it — a simulator must reproduce what a customer might do, including
the unwise). `storage` (reason 2, and it has no `peer_links`). "Everywhere to be
safe" — blast radius is a first-class concern and the whole point of scoping.
`oob` is refused as **impossible**, not unwise: see §3.1.

**The module is named `evpn`, not `vxlan`.** The `vxlan` token belongs to the
simulator's own transport — `gen_topology._vni()` allocates VNIs for cross-host
links on UDP 14789, and `reconcile.py` and `t25` both partition on
`type == "vxlan"`. Taking it back would corrupt three working measurements.

---

## 2. The MTU question, measured and corrected

A claim was raised that a frontend overlay cannot fit on a sharded fabric:
`9000 + 50 > 8896`. It is directionally right, **arithmetically wrong twice, and
causally misattributed.**

Measured on the box and in terraform:

| | claimed | measured |
|---|---|---|
| SONiC port MTU | 9000 | **9100** (CONFIG_DB, all 64 ports, every switch) |
| container veth | — | **9500** (containerlab default) |
| fabric VPC MTU | 8896 | **does not exist.** `gpufab-vpc` has no `mtu` argument in terraform; all six networks in the project are at **1460**; the fabric VM has one NIC |
| `addressing.yaml` `9214/9000` | authoritative | read by **nothing** |

The correct arithmetic subtracts the substrate's 50 bytes once, not zero times:

```
  8896  aspirational fabric VPC ceiling (does not exist today)
-   50  SUBSTRATE VXLAN, UDP 14789 — present with NO overlay feature at all
= 8846  emulated wire on a cross-host link
-   50  the simulated overlay, UDP 4789
= 8796  usable inner payload   vs a 9100 port MTU -> 304 bytes short
```

**With no overlay feature built, a 9100-byte port on a cross-host link is
already 254 bytes over budget.** The overlay contributes 50 of a 304-byte
deficit — 16%. It inherits a substrate limit that
`scale-out-architecture.md:1490` already states in as many words: *"A
production-sized 9000-byte frame cannot traverse a pod boundary. This is
inherent to the substrate, not a configuration error."*

**And it barely binds on this feature at all.** Placement is pod-atomic by
construction (`fabric_model.py:1067` refuses to split a pod rather than
splitting it), and measured across every rung s1→s5, **every cross-host link is
`core-spine`. Zero `leaf-spine`, zero `leaf-leaf`, zero `host-leaf`, ever.** The
VTEPs are the frontend *leaves*, so overlay traffic rides local veths at 9500 at
every scale. Only the 4–140 frontend spine↔core uplinks cross a host.

This *strengthens* the frontend choice: at s5 the backend has 6545 cross-host
links, the frontend 140.

---

## 3. Three defects the measurements found in the design being implemented

### 3.1 The tier-2 ASIC locator passes on a switch with no overlay

`FEATURE-EXTENSIBILITY.md` §3.6 specifies:

```
(dataplane) -> ASIC_DB  ASIC_STATE:SAI_OBJECT_TYPE_TUNNEL*  >= 1
```

**Measured on `fr-leaf01` with zero VXLAN configured:**

```
ASIC_STATE:SAI_OBJECT_TYPE_TUNNEL                    1
ASIC_STATE:SAI_OBJECT_TYPE_TUNNEL_TERM_TABLE_ENTRY  53
```

That is the stock **IPinIP decap** tunnel every SONiC box carries, one term per
peer loopback. The proposed locator returns **54** on an unconfigured switch and
would have passed on a fabric with no overlay — this project's signature defect,
reproduced inside the design written to prevent it. The discriminator is
`SAI_TUNNEL_ATTR_TYPE == SAI_TUNNEL_TYPE_VXLAN`, which measured **0** on that
baseline and **1** once a tunnel was programmed.

### 3.2 The STATE_DB locator fails on a tunnel that IS programmed

Same section specifies `STATE_DB VXLAN_TUNNEL_TABLE|* >= 1`. Measured with the
tunnel confirmed in ASIC_DB: **STATE_DB holds zero VXLAN keys.** Its only tunnel
content is `TUNNEL_DECAP_TERM_TABLE|IPINIP_TUNNEL|*`. STATE_DB's VXLAN tables
describe *remote* VTEPs learned through EVPN, so a correctly programmed local
VTEP with no peer populates none of them. Asserting `>= 1` there would fail a
working tunnel — the inverse error to §3.1, from the same source. The programmed
local VTEP appears in **APPL_DB**: `VXLAN_TUNNEL_TABLE:vtep`,
`VXLAN_TUNNEL_MAP_TABLE:vtep:map_<vni>_Vlan<id>`, `VXLAN_EVPN_NVO_TABLE:nvo`.

### 3.3 `oob` was silently a legal target

The OOB switches carry `tier: "leaf"` and a loopback, so tier-based VTEP
selection matched them and the module rendered a full overlay onto the fabric's
two **management** switches — which have no p2p links, no BGP session and an
empty INTERFACE table, and which `derive()` itself excludes from p2p addressing.
Found by a negative-path control, not by reading. Now refused as impossible.

**Also found:** `deploy/55-unnumbered.sh:162` uses `sudo docker exec "$hname"
vtysh …`. The switches are `sonic-vm` (vrnetlab/QEMU), so `docker exec` lands in
the launcher, not SONiC — `vtysh: executable file not found`. That line cannot
work on this image. Unrelated to #87; filed here because it was measured.

---

## 4. What was proved, and how

**The tunnel programs.** `deploy/checks/c4-evpn-vxlan.sh`, one frontend leaf,
live, no `config reload`:

```
BASELINE  config_db=0  state_db=0  appl_db=0  asic_db(vxlan)=0
BASELINE  bgp series=1464 up=1464
AFTER     config_db=3  state_db=0  appl_db=3  asic_db(vxlan)=1
  ASIC_STATE:SAI_OBJECT_TYPE_TUNNEL:oid:0x2a00000000185d -> SAI_TUNNEL_TYPE_VXLAN
BGP after: series=1464 up=1464
```

**The fidelity ceiling, stated not discovered.** `syncd` is `docker-syncd-vs`
(libsai_vs), a software dataplane. This proves orchagent asked SAI to build the
tunnel. It does **not** prove a frame crossed one, and no check on this image
can. A capture-based proof is meaningless here and is deliberately not
attempted. Recorded in `nos_catalog` as `vxlan_forwarding: none`.

**Ownership is computed, not declared.** Rendering `fr-leaf01`:

```
VLAN               owner=evpn  keys=2  verify=appl_db:VLAN_TABLE:*
VLAN_INTERFACE     owner=evpn  keys=4  verify=appl_db:INTF_TABLE:Vlan*
VXLAN_EVPN_NVO     owner=evpn  keys=1  verify=vtysh:show bgp l2vpn evpn summary json
VXLAN_TUNNEL       owner=evpn  keys=1  verify=asic_db:...[SAI_TUNNEL_ATTR_TYPE=...VXLAN]
VXLAN_TUNNEL_MAP   owner=evpn  keys=2  verify=appl_db:VXLAN_TUNNEL_MAP_TABLE:*
```

No list anywhere says evpn owns these; the composer diffed what the contributor
changed. **#92 visible in one line:** `VLAN` and `VLAN_INTERFACE` are in
`DECLARED_ABSENT` and were **adopted** — they dropped out of `absent` because
this render owns them, with `DROP_TABLES` unedited. `VLAN_MEMBER`, which the
module does not write, correctly stays in `absent`.

`fr-spine01` owns **0** overlay tables and carries the FRR transit stanza —
`address-family l2vpn evpn` with its neighbour activations and nothing else.
(It carried a `route-target all` line until #117: not a command in the FRR on
this image, rejected on both spines, and unnecessary — a spine with no VNI has
no import RT to match and FRR does not RT-filter the global `l2vpn evpn` table.)
`bk-p1-r1-leaf01` owns **0**.

**13 negative paths refused at derive time**, each demonstrated failing:
unknown feature name, unknown key inside the block, NOS lacking the capability,
missing `config_mode`, vlan out of range, duplicate vlan, envelope exceeded, VNI
past 2²⁴, anycast without a prefix, no segments, `oob`, typo'd fabric name, bare
`evpn: true`.

**#56 closed retroactively.** `expected.py --check` now evaluates constraints.
Reconstructing the pre-fix `s5-32768` (`cores.backend` 192→105):

```
post-fix: max_ports=64 platform=64  violations=0
pre-fix : max_ports=70 platform=64  violations=1
  REFUSED max_ports_per_switch: violated (value 70)  [must: <= platform_ports]
```

The number that printed 70 and exited 0 for the life of the project now fails at
derive, on a workstation, before terraform.

---

## 5. What was NOT done

- **The fabric was not re-rendered.** s11's ZTP artifacts are still
  `origin/main`'s, without the overlay. `t38` correctly **fails** its
  artifact and programming arms against that state rather than reporting
  success — which is the property that was asked for.
- **No widening past one switch.** The c4 probe touched one frontend leaf and
  removed its own config; `CONFIG_DB VXLAN keys after cleanup: 0`. BGP was
  1464/1464 before, during and after, checked every run.
- **`VLAN_MEMBER` is not emitted.** Binding a host-facing port needs the
  port-assignment map, which lives in the renderer, not the model.
  `config_db(device, model, alloc)` has no port names to be correct about, and
  guessing one would be a second derivation of a value the renderer owns. The
  tunnel does not depend on it.
- **`addressing.yaml:frontend_vlans` is still unconsumed.** The segments are
  declared in the profile instead. Making that policy file an input is a
  contained, separate piece of work.

---

## 6. What a second feature module costs

Measured, not estimated.

| | lines | one-time or per-feature |
|---|---|---|
| `tools/features/__init__.py` (discovery) | 85 | one-time |
| `fabric_model.py` (allow-list + gate + allocate) | +101 | one-time |
| `expected.py` (feature oracle + `--check`) | +94 | one-time |
| `render_fabric_ztp.py` (contributor loop) | +60 | one-time |
| **mechanism total** | **~340** | **one-time** |
| `tools/features/evpn.py` | 520 | per-feature |
| profile block | 27 | per-feature |
| `nos_catalog` capabilities | 31 | per-feature |
| `manifest.py` VERIFY_LOCATORS | 23 | **per-feature** |
| `tests/t38-vxlan.sh` | 315 | per-feature |

**The extensibility claim mostly holds, with one honest exception.** A second
module needs no edit to `fabric_model`, `expected.py` or `render_fabric_ztp` —
all three iterate over what the directory scan found. It does need a
`VERIFY_LOCATORS` entry per new table, because the render refuses to emit a
manifest table with no tier-2 locator and no recorded reason. That refusal is
correct and should stay; it is a per-feature cost, not a defect.

Of `evpn.py`'s 520 lines, roughly 60% is comment recording measured evidence.
The executable core is ~200 lines. A second config-only module on tables that
already have locators would be **~250 lines plus a test** — against the ~1 week
SNMP cost the design cites as the hand-built benchmark.

---

## 7. Where the code is

The implementing agent was sandboxed to a `gpufab-docs` worktree and could not
write to `gpufab-platform` or `gpufab-network`. The work was done in a verified
working copy and is reviewable as a patch series in `evidence/i87/`:

- `01-source.patch` — +966/-14, the module, model, oracle, manifest, renderer, profile
- `02-tests.patch` — +519/-3, `t38-vxlan.sh`, its `verify.sh` registration, `c4-evpn-vxlan.sh`

Apply to a branch `i87-vxlan` cut from `origin/main` in each repo, as **separate
commits**: source, then tests. Nothing here has been pushed.
