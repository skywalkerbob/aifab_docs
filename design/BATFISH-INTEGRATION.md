# Batfish — evaluated against the defects this project actually produced

Written 2026-07-29. Supersedes `scale-out-architecture.md` §9, which was written
from research and never run (`2dcf26e`: *"the Batfish integration that was
researched but never recorded"*). Every number below was measured on 2026-07-29
against the **real rendered artifacts of the live s11 fabric**, using a Batfish
service running on the workstation.

The proof-of-concept is **not committed**. It lives in
`<scratchpad>/poc/` (snapshots, variants, probe scripts) and
`<scratchpad>/batfish/` (the extracted service and its venv) on the workstation
only. Nothing was written to either sim host, no switch was touched, and no repo
outside this file was modified.

---

## 1. The recommendation

**Do not build it now.** Batfish's SONiC backend fits this project's artifacts
better than anyone expected — the snapshot layout it wants is *byte-for-byte the
directory shape `/opt/gpufab/ztp-srv/` already has*, and it caught the 178-session
PORT defect in 4.3 seconds — but on today's fabric it silently drops **5 of 48
devices (the entire frontend, every EVPN speaker)** because
`SonicConfiguration.getVxlans()` is an unconditional `throw` stub, and it reports
`fileParseStatus: PARTIALLY_UNRECOGNIZED` while doing so. Measured consequence:
the **broken** #104 render models as 48/48 devices and 1464 BGP peers, while the
**correct** render models as 43/48 and 1304 — Batfish scores the defective fabric
as healthier than the fixed one. Against the five defects it would have caught
**two**. One of them — the PORT-table defect — is already covered by three
committed checks that exist and run today, starting with the twelve-line
`assert_interfaces_have_ports()` inside the renderer itself. The other,
`route-target all`, was guarded by nothing and live in the tree when this was
written — and it is caught for zero new infrastructure by `vtysh -C` against the
actual FRR we run, a step
`gpufab-network/.github/workflows/validate.yml` already contains and which has
never once executed. *(Both halves of that recommendation are now done, and
neither needed Batfish or the pipeline: #117 deleted the line — it was invalid
**and** unnecessary, see §3.5 and §6.2 — and `tests/t45-frr-syntax.sh` runs the
`vtysh -C` parse over every rendered `frr.conf` from the suite that does run,
against a live switch's own FRR rather than a CI container one minor version
off.)* **So: fix `route-target all`,
make the FRR syntax gate that already exists actually run, and revisit Batfish
when `frr.conf` becomes the file the switch actually loads (the unnumbered path)
or when the fabric outgrows what can be booted (S3). Both of those change the
arithmetic; neither is true today.**

---

## 2. What Batfish can and cannot parse of our artifacts

### 2.1 The claims in `scale-out-architecture.md` §9, adjudicated

That section was never validated. It is mostly **right**, which is worth saying
plainly given how much of this project's prose has not been.

| §9 claim | verdict | evidence |
|---|---|---|
| "Batfish has a first-class SONiC backend" | **TRUE** | `projects/batfish/src/main/java/org/batfish/vendor/sonic/` — grammar, representation, conversions, 18 test snapshots |
| "parses **17** config_db tables" | **TRUE, exactly 17** | `ConfigDb.java:105-121` — 17 `PROP_*` constants |
| "`BGP_NEIGHBOR` is not one of them" | **TRUE** | the 17 are ACL_RULE, ACL_TABLE, DEVICE_METADATA, INTERFACE, LOOPBACK, LOOPBACK_INTERFACE, MGMT_INTERFACE, MGMT_PORT, MGMT_VRF_CONFIG, PORT, NTP_SERVER, SYSLOG_SERVER, TACPLUS, TACPLUS_SERVER, VLAN, VLAN_INTERFACE, VLAN_MEMBER |
| "`frr.conf` is where Batfish reads BGP from, and it is mandatory — absent, the parser throws" | **TRUE** | `SonicControlPlaneExtractor.java:69` `CONFIG_DB_JSON // must exist`, `:106` `FRR_CONF // must exist` |
| "drops the table with a warning… still reports the snapshot as parsed successfully" | **TRUE and understated** | measured: `fileParseStatus` = `PARTIALLY_UNRECOGNIZED` on all 96 files while 5 devices had **ceased to exist** |
| "a green run against `config_db` alone would be the most dangerous artifact in the system" | **TRUE, and the mechanism is worse than described** | see §2.4 |
| "Batfish runs as a container, **stateless, holding snapshots in memory**" | **FALSE** | snapshots persist to `containers/networks/<uuid>/snapshots/`; measured 100 MB on disk after ~10 snapshots |
| §9.5 "would NOT have caught: every SONiC VS shipping base MAC `22:3c:85:c1:e4:36`… a property of the image, not the config" | **right answer, wrong reason** | 31 of 31 pre-fix `config_db.json` at `363d883` carry that literal — it *was* in the config text. Batfish still cannot see it: `DeviceMetadata.java:17` reads **only `hostname`** |
| §9.6 "it belongs on the ops host" | **supported** — see §5 | ops host has 12,995 MB available, load 0.58 |

### 2.2 The snapshot layout is already our directory layout

Batfish's own SONiC test fixtures
(`projects/batfish/src/test/resources/org/batfish/vendor/sonic/grammar/snapshots/*/`)
have exactly this shape:

```
<snapshot>/sonic_configs/<device>/config_db.json    # mandatory
<snapshot>/sonic_configs/<device>/frr.conf          # mandatory
<snapshot>/sonic_configs/<device>/snmp.yml          # optional
<snapshot>/sonic_configs/<device>/resolv.conf       # optional
```

`/opt/gpufab/ztp-srv/<device>/` already holds `config_db.json`, `frr.conf`,
`manifest.json`, `ztp.json` for each of the 48 switches. Building a valid
snapshot is a `cp` into a `sonic_configs/` parent. **No translation layer is
needed and none should be written** — §2.5.

### 2.3 It parses. Measured, on the real fabric.

48 switches, 96 files, 2.6 MB:

```
init_snapshot                       0.9 s
fileParseStatus                     96 files, ALL "PARTIALLY_UNRECOGNIZED", File_Format SONIC
viConversionStatus                  43 PASSED, 5 FAILED
initIssues                          69 rows
interfaces modelled                 2838   (43 x 64 ports + 43 loopback + 43 mgmt)
interfaces with an address          1390
bgpPeerConfiguration                1304   (= expected.py's 1464 minus the 160 on the 5 lost devices)
bgpSessionCompatibility             140 UNIQUE_MATCH, 1164 UNKNOWN_REMOTE
whole battery, wall clock           4.30 s
```

The arithmetic checks out against `tools/expected.py --profile s1-512.yaml`
independently: `bgp_neighbors_device_sum` 1464, of which fr-leaf01=51,
fr-leaf02=52, fr-leaf03=51, fr-spine01=3, fr-spine02=3 sum to 160.
1464 − 160 = **1304**, exactly what Batfish modelled. Where Batfish sees the
fabric at all, it sees it correctly.

### 2.4 The blocker: the frontend fabric silently disappears

`viConversionStatus` reports **FAILED for `fr-leaf01`, `fr-leaf02`, `fr-leaf03`,
`fr-spine01`, `fr-spine02`** — precisely the five devices carrying
`address-family l2vpn evpn`. They are not in the model: `nodeProperties` returns
43 nodes for a 48-device snapshot.

The cause is in Batfish, not in our render:
`SonicConfiguration.getVxlans()` is an unconditional `UnsupportedOperationException`
stub, reached from `FrrConversions.toEvpnAddressFamily` whenever an EVPN address
family has an activated neighbour. `VXLAN_TUNNEL`, `VXLAN_TUNNEL_MAP` and
`PORTCHANNEL` are likewise unimplemented config_db tables, so no overlay state can
enter the SONiC model from either file.

**`fileParseStatus` does not reveal this.** It says `PARTIALLY_UNRECOGNIZED` for
all 96 files whether the device survived or not. Only `viConversionStatus` shows
it, and `bf.q.parseWarning()` returned **0 rows in every SONiC case even when
warnings existed** — the warnings surface exclusively through `initIssues()`.
Any gate must assert on **both** `initIssues()` and `viConversionStatus` having no
FAILED rows, or it reproduces this project's signature failure exactly.

### 2.5 What a config_db → vendor-format translator would cost

It is not warranted, and the evidence is unusually direct: **the fix for the
178-session defect was to collapse two derivations into one.**
`render_fabric_ztp.py:202-207` — *"PORT and INTERFACE now have ONE origin, the
SoT's interface list, so they cannot disagree about what ports exist."*
`frr_render.py:22-27` — *"config_db and frr.conf are emitted from a SINGLE derived
intent, never derived twice."* #79 is recorded as the **third** recurrence of the
two-derivations class; `f52a043` (TACACS at `.3` vs `.4`, 46 of 48 switches
pointing at a dead port for the life of the project) is a fourth.

A translator is a second place that turns intent into config text, by
construction. The record predicts precisely how it fails: it passes its own tests
(the natural test compares the translation against the `config_db` it was fed —
the comparison that cannot fail), and it diverges only in the configuration
nobody routinely runs. Since Batfish reads our artifacts natively, this cost need
not be paid at all — and must not be.

### 2.6 Parsing `frr.conf` alone is not an option

Tested, on all 122 real `frr.conf` files with no `config_db.json` beside them:

```
nodes: 122      Configuration_Format: CISCO_IOS   (122 of 122)
viConversionStatus: 122 WARNINGS  (nothing FAILED)
initIssues: 1220 rows
bgpPeerConfiguration: 2772        bgpSessionCompatibility: 444 UNIQUE_MATCH,
                                  1164 UNKNOWN_REMOTE, 1164 NO_LOCAL_IP
```

A bare `frr.conf` is misdetected as **Cisco IOS**. Batfish then builds 122
plausible-looking Cisco devices out of FRR configuration, with addresses,
interfaces and peers, and reports no hard failure. This is the single most
dangerous result in the whole evaluation: a wrong model that looks like a right
one. The FRR grammar is reached **only** via `sonic_configs/<device>/frr.conf`
next to a `config_db.json`, or via the Cumulus formats. So the option the brief
raised — *"parse `frr.conf` only, as a committed test"* — is not available.

### 2.7 Grammar vintage, and false positives on correct config

Batfish's FRR grammar carries Cumulus 3.x heritage; its test fixtures declare
`frr version 4.0+cl3u8`. We render `frr version 10.3` and the host containers run
`FRRouting 10.2.1_git` (measured: `docker exec clab-gpufab-dc1-pod001-gpu0005
vtysh -c 'show version'`). Six major versions. Measured consequences on our real
files:

- **`no bgp ebgp-requires-policy` is reported as `This syntax is unrecognized`.**
  It is valid FRR 10.x and it is load-bearing here — `frr_render.py:216` emits it
  precisely so the fabric does not come up Established with zero prefixes. A gate
  that fails on unrecognised lines fails on correct config.
- **`undefinedReferences` returns 43 rows, and all 43 are false.** Every device
  is flagged for `route-map match interface Loopback0` as an undefined *abstract
  interface* — while `Loopback0` is defined in the same snapshot, in
  `LOOPBACK_INTERFACE` and as `interface Loopback0` in the frr.conf. This is the
  question `scale-out-architecture.md` §9.5 nominates as a "would have caught",
  and the one `t07-render.sh:68-77` already emulates by hand for the case that
  actually matters here (a `redistribute … route-map` naming a route-map the file
  never defines). Batfish finds zero of those and 43 of a different, false kind:
  on our fabric its precision is zero.
- `timers bgp 10 30` parses with **no warning** and is never extracted —
  `bgpPeerConfiguration` has no timer columns. Batfish cannot validate BGP timers.
- `route-target import|export` is absent from the grammar in any form; RTs are
  auto-derived on a hard-coded `asn:vni` convention. Batfish cannot validate the
  route-target configuration an EVPN fabric most needs checked.
- `VLAN_INTERFACE` **fails to deserialize** on our artifacts:
  `Unrecognized field "mac_addr" (class InterfaceKeyProperties), not marked as
  ignorable (4 known properties: gwaddr, forced_mgmt_routes, secondary,
  forcedMgmtRoutes)`. The anycast gateway MAC — see §3.4.

---

## 3. The five-defect scorecard

Each row was **run**, not reasoned about: the defect was injected into a copy of
the real rendered artifacts and Batfish was asked the same questions as against
the baseline. Score: **2 of 5**, and neither of the two is currently unguarded.

| # | defect | caught? | already guarded by |
|---|---|---|---|
| 1 | 32-port `PORT` on 64-port switches | **YES — loudly** | `assert_interfaces_have_ports`, `t14`, `t15` |
| 2 | identical base MAC | **NO** | `t06` (indirectly, via mgmt-IP uniqueness) |
| 3 | EVPN declared, never activated (#104) | **NO — and it inverts** | `t40` (offline, exact) |
| 4 | anycast gateway that was not anycast (#126) | **NO** | `t44` (live fabric, three depths) |
| 5 | `route-target all` (#117) | **YES** | **nothing** — now `t45` (`vtysh -C` on the image's own FRR) |

### 3.1 The 32-port PORT table — **YES**

The defect's shape: `INTERFACE` carried `Ethernet128|10.128.9.177/31` while
`PORT` had no `Ethernet128`; SONiC creates netdevs from `PORT`, so the port, its
address and its session never existed (`render_fabric_ztp.py:180-213`).

Batfish reproduces SONiC's rule exactly. `SonicConversions.convertPorts()`
iterates `ports.keySet()` — the `PORT` table — and attaches an address only
`if (interfaces.containsKey(portName))`. An `INTERFACE` entry on a port that
`PORT` does not declare is never visited: no interface, no address, and no
warning. That faithfulness is what makes the defect visible one layer up.

Injected into the real artifacts by truncating `PORT` to 32 keys
(`Ethernet0`…`Ethernet124`) on all 48 switches, leaving `INTERFACE` untouched —
174 orphaned ports, against the 178 sessions the real defect cost:

| | baseline | 32-port defect |
|---|---|---|
| `fileParseStatus` | 96 PARTIALLY_UNRECOGNIZED | **96 PARTIALLY_UNRECOGNIZED — identical** |
| `viConversionStatus` | 43 PASSED / 5 FAILED | **43 / 5 — identical** |
| `initIssues` | 69 | **69 — identical** |
| interfaces modelled | 2838 | 1462 |
| addressed interfaces | 1390 | 1276 |
| `bgpSessionCompatibility` | 140 UNIQUE_MATCH, 1164 UNKNOWN_REMOTE | 128 UNIQUE_MATCH, 1062 UNKNOWN_REMOTE, **114 NO_LOCAL_IP** |

**114 sessions flip to `NO_LOCAL_IP`** — a BGP neighbour configured on an
interface that has no address, which is the defect stated in Batfish's own
vocabulary. Note that every parse-level signal is byte-identical: a gate on
parse status alone would have passed this. The signal is in
`bgpSessionCompatibility` and nowhere else.

**But the marginal value today is zero.** `assert_interfaces_have_ports()`
(`render_fabric_ztp.py:317-328`, twelve lines, *"the check whose absence cost 178
sessions; it runs on every render"*) computes `INTERFACE`-keys minus `PORT`-keys
inside one JSON file and raises. `t14-port-table.sh` asserts the same offline
against a real render, plus five drift cases that must raise; `t15-port-inventory.sh`
asserts it against the artifacts actually served. Batfish finds this defect one
inference later, four seconds slower, and 1.4 GB heavier.

### 3.2 The identical base MAC — **NO**

Pre-fix, 31 of 31 committed `config_db.json` at `363d883` carried the identical
literal `"mac": "22:3c:85:c1:e4:36"`, inherited by `copy.deepcopy` from
`design/base/vs_base_config_db.json:186`. So — contra `scale-out-architecture.md`
§9.5 — it *was* in the config text, as a fleet-wide uniqueness violation.

Batfish still cannot see it, and the reason is definitive rather than
circumstantial: **`DeviceMetadata.java` declares exactly one property,
`PROP_HOSTNAME = "hostname"`.** `mac`, `hwsku`, `bgp_asn`, `platform` and `type`
are all read by nothing. The field is not modelled, not warned on, and not
queryable. (The same line kills a second signal that was present the whole time:
every pre-fix file declared `hwsku: Force10-S6000` on devices the catalog models
as SN5600, and Batfish does not read `hwsku` either.)

Even had it been read, no Batfish question asks "is this property unique across
the snapshot", and the consequence — MAC → EUI-64 → identical `fe80::` on every
switch → unnumbered BGP peering with itself → `Bad Peer AS` — is three semantic
steps past anything Batfish models. A fleet-scoped uniqueness assertion is four
lines of Python over the 48 rendered files; that is the right tool.

### 3.3 EVPN declared but never activated (#104) — **NO, and it inverts**

This is the most important row in the table.

The pre-fix render emitted `address-family l2vpn evpn` with `advertise-all-vni`
or `route-target all` and **zero** `neighbor … activate` lines. Injected into the
real artifacts by stripping all 16 activate lines (16 = `expected.py`'s
`evpn_bgp_peer_series`, exactly):

| | correct render | **#104 defect** |
|---|---|---|
| `viConversionStatus` | 43 PASSED, **5 FAILED** | **48 PASSED, 0 FAILED** |
| `initIssues` | 69 | 68 |
| nodes in the model | 43 | 48 |
| interfaces modelled | 2838 | 3168 |
| `bgpPeerConfiguration` | 1304 | **1464** |
| `bgpSessionCompatibility` | 140 UNIQUE_MATCH | **156 UNIQUE_MATCH** |

**The broken fabric models cleanly and completely; the fixed one loses five
devices and 160 peers.** The mechanism is §2.4: it is the *activated neighbour*
that reaches the `getVxlans()` stub, so removing the activations removes the
crash. Batfish raises no complaint about an EVPN address family with no peers in
it — the AF is simply not in the model, and the underlay rows carry
`Address_Families: []` either way.

A gate phrased "the model must hold ≥ N devices" or "≥ N compatible sessions"
would therefore have **passed the defect and failed the fix**. That is not a
hypothetical: it is the exact failure shape `scale-out-architecture.md:2021-2026`
warns about, arriving from the direction nobody was watching.

`t40-evpn-activate.sh` already catches this offline, on a workstation, with no
fabric and no JVM: it counts `neighbor <ip> activate` lines across the whole
render and asserts equality with `expected.compute()["evpn_bgp_peer_series"]`,
plus six more assertions including that `frr_conf` **refuses** to render without a
model. Its header states the principle Batfish cannot meet here: *"a check that
can only run after the risky operation is not a pre-flight."*

### 3.4 The anycast gateway that was not anycast (#126) — **NO**

Two independent reasons, and the first corrects the brief's premise.

**The three MACs were never in the rendered config.** Pre-fix, `evpn.py`
emitted `VLAN_INTERFACE: {"Vlan100": {}, "Vlan100|10.201.100.1/24": {}, …}` —
**byte-identical on all three VTEPs**. The differing MACs (`22:86:0a:09:8d:af`,
`22:a4:95:95:ac:7d`, `22:4f:c8:cd:f7:88`) were each switch's own system MAC,
applied by SONiC at the device because no `mac_addr` was configured. A cross-device
comparison of the rendered artifacts shows them *agreeing*, and agreement is what
a correct anycast gateway looks like. There was nothing in the text to differ.

**And Batfish cannot read the field even now that it exists.**
`InterfaceKeyProperties` knows four properties — `gwaddr`, `forced_mgmt_routes`,
`secondary`, `forcedMgmtRoutes` — and `mac_addr` is not among them, so the
post-fix artifacts produce a hard deserialization error:

```
Failed to deserialize VLAN_INTERFACE: Unrecognized field "mac_addr"
  (class org.batfish.vendor.sonic.representation.InterfaceKeyProperties)
```

Measured directly: giving the three VTEPs three different gateway MACs
(`02:00:5e:00:01:01/02/03`) produced a model **identical to baseline in every
respect** — 69 initIssues, 43 PASSED / 5 FAILED, 2838 interfaces, 1304 peers,
140 UNIQUE_MATCH. Batfish is not merely unable to judge the anycast gateway; it
cannot represent it.

`t44-anycast-gw.sh` adjudicates it at three depths (model, artifact, and the box
at both kernel and ASIC level) and additionally proves *ownership* — `ip route get
<gw>` answering `local … dev lo` on every VTEP, and zero remote EVPN ARP entries.
None of that is reachable from configuration text by any tool.

### 3.5 `route-target all` (#117) — **YES**

Batfish flags it. Measured by removing exactly that line from the two frontend
spines and re-running: `initIssues` **69 → 68**, with the removed row being
`Type: Parse warning`, `Details: This syntax is unrecognized`,
`Line_Text: route-target all`.

The line is invalid, established from FRR's own source rather than from memory.
`FRRouting/frr@frr-10.2.1:bgpd/bgp_evpn_vty.c`, `grep -n '"route-target'` returns
exactly three forms — `route-target <both|import|export> RTLIST...` (:6711),
`route-target <both|import|export>$type auto` (:6770), and
`route-target <both|import|export> RT` (:7027). There is no `all` form in any
node. (`advertise-all-vni` **is** valid — `bgp_evpn_advertise_all_vni_cmd`,
installed on `BGP_EVPN_NODE` at :7529 — so the leaves are fine.)

**Three things make this the most actionable finding in the document, and none of
them is about Batfish:**

1. **It was live right now.** `tools/features/evpn.py:718-720` emitted it;
   `/opt/gpufab/ztp-srv/dc1-pod001-fr-spine01/frr.conf` and `…-fr-spine02/frr.conf`
   contained it. There was no #117 anywhere in any of the three repos —
   `git log --all --grep='#117'` and `-S'route-target all'` returned nothing, and
   the string had been unchanged on all 17 refs since `cfabb5d` added it.
   **It was never fixed** — until #117, which deleted the line rather than
   correcting it, on the evidence in §6.2. The served artifacts under
   `/opt/gpufab/ztp-srv` still carry it until the fabric is next rendered.
2. **The design and the code are wrong differently.**
   `FEATURE-EXTENSIBILITY.md:690-691` specifies `retain route-target all`; the
   implementation dropped `retain`. By the same grammar, the design's form is
   invalid too — the AF-level command is `bgp retain route-target all`.

   > **Corrected by measurement (#117).** That last clause is wrong, and so is
   > the premise under both proposals. `bgp retain route-target all` is **not**
   > an `l2vpn evpn` AF-level command in the FRR on the image: run through
   > `vtysh -C` inside `fr-spine01`'s own `bgp` container (FRR **10.3**), it is
   > `% Unknown command` under `address-family l2vpn evpn` and at `router bgp`
   > level alike, along with `retain route-target all` in both positions. It is
   > accepted in exactly one node — `address-family ipv4 vpn` — because it is
   > the VPNv4/VPNv6 knob. FRR 10.3 has no EVPN retention command at all, so
   > there is no valid form of this line and the fix was to **delete** it, not
   > to correct its syntax. The spines were already carrying the entire overlay
   > table without it (§6.2 below).
3. **Nothing guards it, and something already almost does.**
   `gpufab-network/.github/workflows/validate.yml` runs
   `docker run … quay.io/frrouting/frr:10.2.1 vtysh -C -f /etc/frr/frr.conf`
   over every rendered `frr.conf`. That is a full FRR-10.2.1 parse — the exact
   FRR we target, with no six-version grammar gap and no
   `no bgp ebgp-requires-policy` false positive. It has never executed: see §4.2.

---

## 4. Where it would sit

### 4.1 Recommended, when the time comes: a committed test (option 1)

`tests/` is the right home, for the reason the brief gives — it needs no rollout
mechanism and no fabric to fail safely — but with one correction to the framing:
**it cannot be an offline test.** `render_fabric_ztp.py` requires a live NetBox
(`pynetbox`, `NETBOX_URL`; header: *"Run on the sim host"*), so a committed test
cannot render its own corpus. It must consume artifacts that already exist, which
today means `/opt/gpufab/ztp-srv/` on the fabric host. `t07-render.sh` and
`t15-port-inventory.sh` already establish that pattern.

The shape, when built:

- **`run_host_phase batfish ssh_h "$FABRIC_HOST" tests/t45-batfish.sh`**, tarring
  `ztp-srv` down or analysing in place; the corpus is 2.6 MB.
- **Three assertions, in this order, and the first two are the point:**
  1. `t_zero "devices whose VI conversion FAILED"` — from `viConversionStatus`,
     never from `fileParseStatus`. This is what §2.4 costs if omitted.
  2. `t_count "devices in the model" == expected.py's switch count` — a model
     that lost a device must fail, not pass quietly.
  3. `t_zero "BGP peers with NO_LOCAL_IP"` — the PORT-class assertion, and the
     only one that earns Batfish its keep.
- **An allowlist of known-benign `initIssues`**, keyed on `Details`, so
  `no bgp ebgp-requires-policy`, `Property 'gwaddr' … is not implemented` and the
  17-table gaps do not drown the signal. Anything not on the allowlist fails.
  The allowlist is the maintenance cost and it is not small — the grammar is six
  FRR majors behind and every renderer change can add to it.
- **Never assert on `undefinedReferences`** — 43 of 43 rows are false on a
  correct fabric.

### 4.2 Not a CI check (option 3) — it is a null position today

The GitOps path has never produced an artifact, and the FRR gate that already
exists there has never run. Measured 2026-07-29:

| observation | evidence |
|---|---|
| `rendered/` holds one file | `git ls-files rendered/` → `rendered/README.md` |
| `instances/` does not exist | the path `render.yml:82` writes to |
| the runner is offline | `gh api gpufab-network/actions/runners` → `gpufab-sim-01`, `"status":"offline"` |
| nightly `render` fails in 0–2 s | `gh run list` — *"failed because of a workflow file issue"*; `vars.SIM_IDS` unset (only `NETBOX_URL` exists), so the matrix is empty by design |
| `drift-check` queues 4–24 h then cancels | same listing |
| `validate.yml` could not fire even if it did | it triggers on `paths: ["rendered/**", …]`; `render.yml` writes `instances/<sim-id>/…` |

Adding a Batfish job to that workflow adds a second thing that does not run. The
correct first move at this position is not Batfish: it is to set `vars.SIM_IDS`,
register the runner, and repoint `validate.yml`'s path filter at
`instances/*/rendered/**` — after which the `vtysh -C` step catches
`route-target all` for free. One correction to that sentence as first written:
the step's `quay.io/frrouting/frr:10.2.1` is **not** the exact FRR version we
run. The switches ship **10.3** (§6.1), so a CI pass there is a pass by a
parser one minor version off the one that matters. `tests/t45-frr-syntax.sh`
closes that gap by parsing with a live switch's own `bgp` container; repointing
the workflow is still worth doing, but it is now the second line of defence
rather than the first.

### 4.3 Not a pre-push gate (option 2) — right idea, wrong tool

`interim_deploy.py` (in `gpufab-network`, not platform) pushes all 46 BGP-speaking
switches in one `ThreadPoolExecutor.map` with `DEFAULT_WORKERS = 24`, no device
selector, no batch size, no canary (`git grep -i canary -- tools/` → zero hits).
It *does* verify — per-switch read-back with retry, then a fleet-wide convergence
gate against `expected.py` — but the gate fires after all 46 are already reloaded.

A Batfish gate here would not address that. What #99 needs is **scope**: waves, a
canary, and a halt between them. A static check bolted to the front of an
unbounded parallel push still leaves the blast radius unbounded for every class of
defect the check does not model — which, per §3, is three of the five this project
has actually produced. Fix the rollout shape first; a pre-push analyser is worth
adding *to* a staged rollout, not *instead of* one.

---

## 5. Cost

| item | measured |
|---|---|
| image `batfish/allinone:latest` | **561.6 MiB compressed, 1353.8 MiB uncompressed** (manifest `sha256:09817554db90e2f2674b72562c2d659427094187de0a3dfc23534ab58bf26207`, built 2025-07-07, version `2025.07.07.2423`) |
| on-disk with venv | ~2.2 GB |
| startup to first answered call | **2.37 s** |
| idle RSS | 174 MB |
| RSS holding the 48-device fabric | **1.2 – 2.2 GB** (`/proc/<pid>/status VmRSS`, sampled across runs) |
| `init_snapshot`, 48 SONiC devices, 2.6 MB | **0.6 – 1.5 s** |
| `init_snapshot`, 122 bare frr.conf | 6.2 s |
| full battery (parse status + VI status + init issues + interfaces + peers + session compatibility) | **4.30 s wall** |
| snapshot storage | 100 MB after ~10 snapshots — persistent, not in-memory |
| `pybatfish` | `2025.7.7.2423`, imports cleanly on Python 3.12.3 with pandas 3.0.5, 19 packages |

**The ops host can carry it.** `gpufab-s11-ops`, n2-standard-4: 4 vCPU,
15,987 MB total with **12,995 MB available**, load 0.58/0.33/0.24, 186 GB free
disk. The ten existing containers sum to ~2.15 GB (NetBox 1.543 GiB,
netbox-worker 212 MiB, Grafana 112 MiB, Prometheus 111 MiB, postgres 128 MiB,
the rest under 20 MiB each). A 2 GB Batfish alongside leaves ~11 GB headroom.

**One sizing trap, and it is sharp.** The image sets `-XX:MaxRAMPercentage=80`,
which resolved to a **50.25 GiB** maximum heap on the 62 GiB workstation and would
claim **~12.8 GiB of the ops host's 16 GiB**. It must be pinned explicitly —
`-Xmx4g` covers the 1.2–2.2 GB measured working set with margin at this scale.
Unpinned, a JVM that never needs the memory will still reserve it away from
NetBox. The pinned value must be re-measured before S3, not extrapolated.

**No container runtime is required to evaluate it.** The workstation has no
docker/podman/skopeo; the service was obtained by pulling the image layers
through the registry HTTP API with `curl`, verifying every layer digest,
extracting the fat JAR and running it on the installed OpenJDK 21 (the JAR is
Java-17 bytecode). Maven Central publishes no Batfish artifacts (`numFound: 0`)
and all ten GitHub releases carry no assets, so the image is the only
distribution channel. On the ops host, which has docker, `batfish/allinone` is
the normal path.

### 5.1 Against the do-nothing baseline

The fabric converges 1464/1464 with 16/16 EVPN sessions. The suite is 43 tests —
18 offline-capable, 24 requiring a live fabric, one hybrid — and it already
catches three of the five defects above, two of them offline before anything is
pushed. Batfish adds, today: a second route to a PORT-class defect that three
committed checks already cover, and grammar validation of a file **the switch
does not currently load** — on the numbered path `ztp.json` fetches only
`config_db.json` (measured: `grep -l frr /opt/gpufab/ztp-srv/*/ztp.json` → 0; ZTP
access log shows 56 `GET …/config_db.json` against 2 `GET …/frr.conf`), and
`render_fabric_ztp.py:950-953` says so outright: *"this artifact is what Batfish
parses."* We already render a file for a consumer that does not exist.

That last point is the whole timing argument. **When the unnumbered path lands,
`frr.conf` becomes the file the device runs** (`docker_routing_config_mode=
split-unified`; `config_db` cannot express an interface-keyed neighbour at all —
upstream `sonic-buildimage#26960`). At that moment grammar validation of
`frr.conf` stops being validation of a shadow artifact and starts being
validation of the running configuration, and Batfish's value roughly doubles for
no new work. The other trigger is scale: §8.0a puts S3 at 270 switch VMs and
1.3 TB across seven hosts, and S5 cannot be cabled at all. Static analysis is the
only verification whose cost does not grow with fidelity — 4.3 s for 48 devices
says that is true here too.

**Verdict: later, on either trigger, whichever arrives first. Not now.**

---

## 6. What could not be established

1. ~~**Whether the SONiC switches run the FRR version we render for.**~~
   **ESTABLISHED by #117: they do.** SSH into the switch VM and
   `vtysh -c "show version"` reports `FRRouting 10.3` on all five frontend
   speakers, which is exactly what the rendered header hardcodes. The host
   containers' `10.2.1_git` is a different population and does not parse switch
   artifacts. Note the consequence for §4.2: the `quay.io/frrouting/frr:10.2.1`
   container `validate.yml` runs is **not** "the exact FRR version we run" — it
   is one minor version off the parser that matters. It happens to reject
   `route-target all` too, but that is a coincidence to stop relying on;
   `tests/t45-frr-syntax.sh` validates against a live switch's own `bgp`
   container instead.
2. ~~**What FRR actually does with `route-target all` on a device.**~~
   **ESTABLISHED by #117, and the premise held.** Both spines answered
   `% Unknown command: route-target all` (rc=1) when a rollout applied it by
   CLI, and `vtysh -C` reproduces it on demand (`rc=2`, `line 45: % Unknown
   command[41]:    route-target all`) against the rendered artifact. Through a
   rendered `frr.conf` the rejection is **silent**: FRR skips the line, applies
   the rest of the stanza, and the artifact still matches the intent it was
   rendered from — which is why nothing above the box ever saw it.

   The second half was the surprise. The line was not only invalid, it was
   **unnecessary**: with it never once accepted and the overlay converged 16/16,
   both spines hold the whole overlay table (6 type-3 routes, 6 RDs — the same
   six every VTEP holds) with **zero** VNIs configured and therefore no import
   RT to match on, and re-advertise 4 of the 6 to each leaf. FRR does not
   RT-filter the global `l2vpn evpn` table. So the comment above the line was
   false in its premise, not merely stale in its syntax, and the fix deleted
   both. Caveat: every VNI currently holds zero local MACs, so only type-3 was
   observable; type-2 shares the table and the auto-derived RT but was not seen.
3. **Batfish behaviour at S3 scale.** Everything here is 48 devices / 2.6 MB.
   4.3 s and 2.2 GB at that size say nothing reliable about 270 devices, and the
   heap trap in §5 makes extrapolation actively unsafe.
4. **Batfish on the ops host itself.** All measurements are from the workstation
   (16 vCPU, 62 GiB). Nothing was installed on either sim host.
5. **Whether the 74 FRR host nodes can join a snapshot at all.** They render
   `frr.conf` and no `config_db.json`, so they cannot be SONiC devices; bare
   `frr.conf` is misdetected as Cisco IOS (§2.6). The Cumulus concatenated format
   is a measured working alternative for FRR bodies in isolation, but whether our
   host configs can be wrapped into it without a second derivation was not
   determined. Until it is, **1164 of 1304 modelled peer rows stay
   `UNKNOWN_REMOTE`**. The 140 `UNIQUE_MATCH` rows are 70 sessions — the
   switch-to-switch links outside the frontend. Batfish therefore adjudicates
   **70 of the fabric's 1386 BGP sessions, 5.0%**: none of the 1308
   switch-to-host sessions, and none of the 8 frontend ones (those devices are
   gone, §2.4).
6. ~~**That `vtysh -C` actually rejects `route-target all`.**~~
   **ESTABLISHED by #117: it does, and it is now a committed check.**
   `tests/t45-frr-syntax.sh` runs `vtysh -C -f` over every rendered `frr.conf`
   inside a live switch's `bgp` container — 122 artifacts in 15 s — and it was
   demonstrated failing and passing against two trees rendered from one NetBox
   by one renderer, differing only in `tools/features/evpn.py`:
   `8 passed / 3 failed` before the fix, naming both spines and the offending
   line; `9 passed / 0 failed` after. It carries two controls, because a
   validator that accepts everything and one that rejects everything both
   produce a clean-looking "0 rejected": a known-good config must be accepted
   **and** the #117 line must be rejected before any verdict is trusted.
7. **#105** — referenced in the brief; used by nothing in any repo.

---

## 7. Reproducing this

Not committed, workstation only, all under the session scratchpad:

- `<scratchpad>/batfish/` — `pull_image.sh` (registry-API layer pull, verifies
  every digest), `start_batfish.sh`, the extracted `allinone-bundle.jar`, the
  Batfish source tree, and the `pybatfish` venv.
- `<scratchpad>/poc/raw/` — the real artifacts: 122 `frr.conf` and 48
  `config_db.json` pulled read-only from `ubuntu@34.55.70.201:/opt/gpufab/ztp-srv/`.
- `<scratchpad>/poc/snap-sonic/` — the baseline snapshot; `snap-sonic-d32port`,
  `-d104`, `-d126`, `-d117fix` the four injected variants; `snap-frr` the bare
  122-file corpus.
- `<scratchpad>/poc/compare.py`, `probe.py`, `probe2.py`, `fmt.py` — the probes.
  `compare.py <snapshot-dir> <network> <name>` produces every table in §3.

If any of this is worth keeping, it belongs in `tests/` as §4.1 describes, not in
a scratchpad — which is the standard this project already holds itself to.
