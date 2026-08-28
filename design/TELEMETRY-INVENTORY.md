# Telemetry feasibility inventory — what this simulator can honestly report

Written 2026-07-28 against **gpufab-s11** (`s1-512`, 48 switches, 76 hosts,
1464/1464 BGP peer series), read-only. Every claim below cites a command run on
that fabric or a file in the repos. Where something is inferred rather than
measured it says so.

The question was not "what metrics could we add". It was: for each requested
item, is the number **produced by something doing the work**, or is it produced
by the emulation? A metric that reports a number nothing measured is the defect
this codebase keeps producing, and on `docker-syncd-vs` it is easy to produce by
accident.

Four buckets, used throughout:

| | meaning |
|---|---|
| **REAL** | something actually did the work; a change in the fabric changes the number |
| **SYNTHETIC** | a number exists but the emulation generates it — constant, seeded, or derived from config. Worse than absent if published unlabelled |
| **CONTROL-PLANE ONLY** | the intent is observable, the effect is not (the #87 shape) |
| **ABSENT** | nothing on this image exposes it |

---

## 0. What was excluded before measurement, and why

**Dropped from scope by decision, not by finding:** backend link/FEC errors,
PFC/ECN/WRED counters and RoCE queue health; storage link utilisation,
drops/errors and QoS/flow-control counters. `syncd` here is `docker-syncd-vs`
(`libsai_vs`) — a software SAI over veth/tc with no ASIC and no congestion —
so these counters have no mechanism that could ever move them. That is not a
guess: SNMP `ifInErrors` and `ifOutErrors` read **0 with delta 0** on every port
across a 25-second sample in which `ifHCInOctets` and `ifHCOutOctets` moved by
453 and 716 bytes on the same interfaces, and COUNTERS_DB agrees —
`SAI_PORT_STAT_IF_IN_ERRORS: '0'`, `SAI_PORT_STAT_IF_OUT_ERRORS: '0'`,
`SAI_PORT_STAT_ETHER_STATS_TX_NO_ERRORS: '0'`, while `ifInDiscards` sits at
frozen per-port constants (8/2/2/2/6) that also did not move. **Octet and packet
counters in that table are REAL; the error and discard counters beside them are
permanently zero and can never be anything else.** Publishing them as "0 errors"
would be indistinguishable from a healthy real switch — a permanently-green
light — which is the worst outcome available here and is why they are refused
rather than merely deprioritised. If someone asks for them again, this paragraph
is the answer: it is not a rendering gap or a missing feature flag, it is the
image, and the fix is a NOS with a real dataplane, tracked by
`nos_catalog.yaml`'s `vxlan_forwarding: none` and published live as
`gpufab_overlay_forwarding_observable`.

**§1.5 extends this to SNMP and settles it there too.** The short version:
of the 39 `SAI_PORT_STAT_*` fields present on every port, **4 move, 1 is a
frozen non-zero, and 34 are permanently `0`** — while `FLEX_COUNTER_DB` holds
3,785 keys, so the poller is running and the SAI is what returns zero. That
cannot be fixed by configuration. **SNMP does not get around the `libsai_vs`
boundary; it exposes the same boundary through a different protocol.**

---

## 1. The inventory

### 1.1 OOB fabric

| item | bucket | built? |
|---|---|---|
| switch mgmt reachability | **REAL** — but covered 46 of 48 | **BUILT** |
| SNMP reachability | **REAL** — 48/48 answer, counters verified against COUNTERS_DB | ranked #1 next |
| gNMI reachability | **REAL** — server returns live DB state | **BUILT** |
| management VRF route health | **REAL** — kernel FIB | **BUILT** |
| device / BMC / PDU access | **ABSENT** | **REFUSED** |

#### Switch mgmt reachability — the two switches nothing measured

```
curl -s :9101/metrics | grep -c '^gpufab_scrape_ok{'   ->  46
curl -s :9101/metrics | grep -c 'oob-sw'               ->   0
expected.py --key switch_mgmt_targets                  ->  48
```

`gpufab_exporter.py` selects `n["role"] != "oob-switch"`. That selection is
**correct** for BGP — the OOB fabric is a flat layer-2 management segment, its
links carry no `/31`, and `fabric_model` gives its two switches a
switch↔switch p2p degree of **0** — so polling them for sessions would publish
`0 established of 0 configured` forever. The consequence was not correct: they
appeared in **no metric at all**, and both could be dead with every number in
this system still green.

**They are not dead.** Measured on 172.20.0.86/.87: SSH answers,
`sonic-db-cli CONFIG_DB keys "PORT|*"` = 64, mgmt VRF healthy, and the main
routing table holds exactly one route (`240.127.1.0/24 dev docker0 … linkdown`).
Exactly as designed, and invisible.

**No existing check would notice**, and one of them cannot even in principle.
`tests/t03-fabric.sh:62-70`:

```bash
n=$(sw_ssh "$ip" "vtysh -c 'show bgp summary json' | grep -c remoteAs")
[ "${n:-0}" -gt 0 ] && oob_with_bgp=$((oob_with_bgp+1))
...
t_zero "OOB switches carrying fabric BGP" "$oob_with_bgp"
```

An unreachable switch returns empty, `${n:-0}` makes it 0, it is not counted,
and `t_zero` passes with "none". **A dead OOB switch and a healthy one produce
the identical PASS.** t03's exporter-coverage assertion is symmetric: its
denominator is `docker ps | grep -E 'leaf|spine|core'`, which excludes `oob-sw`
too, so it compares 46 against 46 and passes. t17's mgmt-VRF sample is 4
switches sorted by ZTP directory name, which puts `oob-sw01/02` last and
permanently outside the sample.

#### SNMP — REAL, and better covered than SSH

**Where the client comes from, corrected.** The first sweep concluded "no SNMP
tooling exists anywhere" — `which snmpget snmpwalk snmpbulkwalk` is empty on the
fabric host and in the switch's own namespace, and `pysnmp`/`puresnmp` are both
`ModuleNotFoundError` — and built a dependency-free SNMPv2c client to get past
it. That conclusion was **wrong, and wrong in the direction that costs work**:
the complete net-snmp 5.9.3 suite is inside the switch's own `snmp` container.

```
docker exec snmp sh -c 'ls /usr/bin/snmp*'
  snmpbulkget  snmpbulkwalk  snmpdelta  snmpget  snmpgetnext  snmpstatus
  snmptable    snmptranslate snmpwalk   snmpset  (and 12 more)
docker exec snmp snmpget -v2c -c "$c" -t 3 -r 1 127.0.0.1 1.3.6.1.2.1.1.5.0
  iso.3.6.1.2.1.1.5.0 = STRING: "dc1-pod001-fr-leaf01"
```

The trap that produced the wrong answer is worth recording because it will
recur: **`command -v a b c` in `dash` prints only the FIRST match.** It printed
`/usr/bin/snmpget` and nothing else, which read as "only snmpget exists" when in
fact every binary was there. Use `ls /usr/bin/snmp*`.

This changes the cost of building SNMP from ~100 lines of hand-rolled BER to a
one-line addition to the poll block the exporter already runs — the same shape
as the gNMI check, with the same honest limit: executed on-box against
`127.0.0.1`, it proves **the agent answers**, not that UDP/161 is reachable
off-box. `snmpset` exists in that container and must never be invoked.

Measured with the dependency-free client (before the above was known; the
findings stand and were re-confirmed with the image's own tooling):

```
ss -lnup (in fr-leaf01)   UNCONN 0.0.0.0:161      docker ps -> snmp  Up 4 hours
GET sysDescr.0   -> "SONiC Software Version: SONiC.202505.0-dirty-20260724.060659
                     - HwSku: Accton-AS7816-64X - Distribution: Debian 12.15 ..."
GET sysUpTime.0  -> 1443980, then 1446283 23s later  (delta 2303cs = 23.03s)
GET sysName.0    -> "dc1-pod001-fr-leaf01"
negative: bogus OID -> noSuchObject;  wrong community -> TIMEOUT-no-reply
fleet: sysName.0 answered AND matched hostname on 48/48, failures 0
```

Octet counters are real, not synthesised: SNMP `ifHCInOctets.1` read **241366**
at the same instant `COUNTERS:oid:0x1000000000002 SAI_PORT_STAT_IF_IN_OCTETS`
read **241366**. 15 of 30 sampled counters moved over 25s. **That result does
not generalise across the MIB — see §1.5, which is the whole point of this
section.**

**The coverage argument, on the two switches that matter.** Both OOB switches —
the ones with no series in any other metric — run the snmp container, carry all
23 net-snmp binaries, and answer:

```
oob-sw01  ctl=64  snmp_container=1  binaries=23  sysName="dc1-pod001-oob-sw01"
oob-sw02  ctl=64  snmp_container=1  binaries=23  sysName="dc1-pod001-oob-sw02"
negative control (1.3.6.1.2.1.1.99.0):
          "No Such Object available on this agent at this OID"
```

The negative control is load-bearing: `No Such Object` is a **reply**, and it is
therefore distinguishable from a timeout. That is what keeps "the agent has no
data for this OID" apart from "the agent is unreachable" — the same three-way
rule `gpufab_vtep_observed` follows, available here for free.

**Two traps, both live.** `/opt/gpufab/secrets/snmp_secret` is the **master**
secret, not the community. `services/tacacs/setup_auth.sh:165` states the rule:
"Every switch's read-only community is HMAC(this secret, device name)". So the
secret file is 64 characters, the community actually on the wire is a
**per-device 32-character** value carried in each rendered `config_db.json`
under `SNMP_COMMUNITY`, and a probe that sends the master secret times out and
reports "SNMP down" on a perfectly healthy agent. A prober must read the
per-device value — from CONFIG_DB or from NetBox — never the master.

Per-device derivation confirmed without disclosing anything: the two OOB
switches answer with communities whose `sha256` prefixes are `ceb3f41a7d8b91c3`
and `e32f58c9cae53f34`, both 32 characters. **Per #95 no community value or
prefix appears in this document; compare digests, never values.** And SNMP `ifName`
returns the SONiC **alias** (`Eth1(Port1)`), not `Ethernet0`, with ifIndexes
striding by 4 — a walk filtered on `Ethernet*` matches nothing and reports "no
interfaces to check" as a pass.

**Not built, and now cheap to build.** The **top-ranked next build** (§4):
48/48 coverage including the OOB pair, a second daemon and data path entirely
independent of the vtysh one, and today `t23`/`t29` assert the community
*value* and never send a packet. Which OIDs it may use is not a free choice —
see §1.5.

#### gNMI — REAL, and free

```
ps aux (in fr-leaf01) -> /usr/sbin/telemetry --noTLS --port 8080 --vrf mgmt ...
docker exec gnmi gnmi_get -xpath_target STATE_DB -xpath MGMT_PORT_TABLE/eth0 \
    -target_addr 127.0.0.1:8080 -notls
  val: < json_ietf_val: "{\"admin_status\":\"up\",\"oper_status\":\"up\"}" >
```

Live DB state, answered on all five switches probed including `oob-sw01`, and
the whole block costs **89 ms**. Two traps: the container and feature are named
**`gnmi`**, so `CONFIG_DB keys "*TELEMETRY*"` is empty and `FEATURE|telemetry`
is `{}` on a switch that is serving it — a probe looking for "telemetry"
concludes gNMI is absent. And the flag is **`-notls`**, not `-insecure`;
`-insecure` means *skip certificate validation* and fails against a `--noTLS`
server with `first record does not look like a TLS handshake`.

#### Management VRF route health — REAL, kernel FIB

Identical on all 48 switches (swept, not sampled):

```
ctl=64  mgmtvrf=1  mgmtroutes=3  mgmtdefault=1  maindefault=0
ip route show vrf mgmt
  default via 172.20.0.1 dev eth0 metric 201
  127.0.0.0/16 dev lo-m proto kernel scope link src 127.0.0.1
  172.20.0.0/24 dev eth0 proto kernel scope link src 172.20.0.<n>
ip route get 169.254.169.254 vrf mgmt -> via 172.20.0.1 dev eth0 table mgmt
ip route get 169.254.169.254          -> RTNETLINK: Network is unreachable
ping -c2 -I eth0 172.20.0.1           -> 0% packet loss
```

The bucket turns on one question: is there a number that moves if route health
degrades? Yes, three, and all are kernel reads rather than config reads —
`mgmtdefault` goes 1→0 if a render regression drops `gwaddr` **while
CONFIG_DB still says `mgmtVrfEnabled=true`**; `maindefault` goes 0→≥1 the moment
anything leaks a default into the data-plane VRF (the §2.5 isolation break); and
STATE_DB `MGMT_PORT_TABLE|eth0` `oper_status` goes down. CONFIG_DB's
`MGMT_VRF_CONFIG|vrf_global` is intent only. APPL_DB has no mgmt-VRF presence at
all (`keys "*VRF*"` empty against 1727 total keys — the read works). **ASIC_DB
has no signal here either**: the single `SAI_OBJECT_TYPE_VIRTUAL_ROUTER` object
is the data-plane VRF; the mgmt VRF is a pure Linux L3 master and never reaches
SAI. Looking for it there will mislead.

Honest limit: this is one static default from `MGMT_INTERFACE.gwaddr`. There is
no routing protocol in the mgmt VRF, so "route health" can only ever mean
{route present, next hop reachable, link up}. t17 already asserts most of the
render and switch-side property on `SAMPLE=4`; the increment built here is that
it is **fleet-wide, continuous, and includes the OOB pair**.

#### Device / BMC / PDU — ABSENT, refused

`grep -rin 'bmc\|ipmi\|redfish\|pdu'` across both repos returns three things and
nothing else: `bmc0` as an **interface name** (`gpufab.py:381-387` cables one per
GPU/head/DDN node onto the OOB switches), one **sizing label** (`gpufab.py:194`,
"BMCs per switch"), and `tcpdump` containing the substring `pdu`.
`grep -rln 'redfish\|ipmitool\|/redfish/v1\|623'` matches **no files**. The three
catalogs contain no power, PSU, PDU or watt object. On the box: `bmc0` has **no
IPv4 address**, nothing listens on 623, and no IPMI/Redfish process exists on any
node or on the host.

**The topology models the BMC cable faithfully and there is no endpoint behind
it.** The nearest honest substitute is the QEMU serial console on `:5000` and
monitor on `:4000` inside each hypervisor container, plus
`/opt/gpufab/logs/components/clab-gpufab-<device>.console.log` — that is the real
analogue of BMC access (reaching a box whose mgmt plane is dead), it is REAL,
and nothing uses it.

**Explicit warning.** A `gpufab_bmc_reachable` derived from container liveness
would be SYNTHETIC and mislabelled. `docker ps` reports the **hypervisor
container**, not the SONiC VM inside it — a switch whose VM has hung, whose mgmt
plane is wedged, or which never finished ZTP still reads `Up`. All 126 read `Up`
today and the metric is structurally incapable of reading anything else.

### 1.2 GPU compute backend fabric

| item | bucket | built? |
|---|---|---|
| BGP sessions | REAL — exists (`gpufab_bgp_peer_up`, t03, t13) | — |
| ECMP path count | **REAL**, varies structurally | **BUILT** |
| BFD status | **ABSENT as deployed** | **REFUSED** |

#### ECMP — REAL, and the obvious hypothesis was wrong

`maximum-paths` appears in **zero** of the 48 rendered `frr.conf` files
(`grep -rl maximum-paths /opt/gpufab/ztp-srv/ | wc -l` → 0). It is nevertheless
active: line 7 of every file is `frr defaults datacenter` (maximum-paths 64) and
line 151 is `bgp bestpath as-path multipath-relax`, without which no two paths
here could ever be equal-cost, since every device has a unique ASN. **Both are
inherited, neither is written down, and either is one profile edit from
disappearing** — at which point every session stays Established and spine
capacity halves in silence.

Measured widths, from `ip -4 route show proto bgp`:

| device | bgp routes | multipath | max width | ASIC next hops | derived neighbours |
|---|---|---|---|---|---|
| `bk-p1-r1-leaf01` | 1396 | 754 | 34 | **34** | **34** |
| `bk-p1-spine01` | 1428 | 1412 | 16 | **16** | **16** |
| `fr-leaf01` | 1380 | 73 | 48 | **51** | **51** |
| `st-leaf01` | 1382 | 512 | 48 | **48** | **48** |
| `oob-sw01` | 0 | 0 | 0 | **0** | **0** |

All four layers agree — FRR RIB, kernel FIB, APPL_DB `nexthop` (a
comma-separated list whose length *is* the programmed width), and ASIC_DB. The
last column is `expected.py bgp_neighbors_by_device`, derived from
`fabric_model`, and it matches the box **five for five including the zero**. That
is the only number in this whole inventory with an exact oracle, so it is
asserted as an equality per device rather than a floor. `tests/fidelity/fv-cap-01`
asserts `t_min NEXT_HOP 1` today, which passes on a switch that has lost 33 of
its 34.

Widths are derivable from the topology and were checked against it: leaf → its
attached spine's loopback = 1; leaf → same-pod remote leaf = 2 (the spine count);
leaf → the other pod = 32 (its GPU-host count, because the pods share no spine
and the multi-homed hosts are the transit); spine → cross-pod = 16.

**Three traps, all live.** `SAI_OBJECT_TYPE_NEXT_HOP*` also matches
`NEXT_HOP_GROUP` and `NEXT_HOP_GROUP_MEMBER` — it returns **172/179/407/499** for
the four switches whose true counts are 34/16/51/48; the locator needs the
**colon**. A width-1 route has **no `nexthop` keyword at all** (it is one line),
so counting `nexthop` lines reports 0 — not 1 — for 642 of one leaf's 1396
routes. And APPL_DB **drops the mask on host routes**:
`ROUTE_TABLE:10.0.0.15` exists while `ROUTE_TABLE:10.0.0.15/32` returns `{}`,
and `{}` is also what a genuinely missing route returns — indistinguishable.

#### BFD — ABSENT, refused

Not configured (`grep -n bfd .../frr.conf` → no match; the 48 files that do
match `bfd` match the `SAI_API_BFD` **syslog-loglevel** block in
`config_db.json`, a decoy). Not running: `show daemons` → `mgmtd zebra bgpd
staticd`; `show bfd peers` → `bfdd is not running`; `pgrep -x bfdd` → 0.
Nothing in STATE_DB, APPL_DB, CONFIG_DB or ASIC_DB.

The binary exists (`/usr/lib/frr/bfdd`, FRR 10.3, inside the `bgp` container) but
`/etc/frr/daemons` does not — SONiC 202505 starts FRR from supervisord, and there
is **no `[program:bfdd]` stanza**, so bfdd can never start. Enabling it is an
**image change** (the supervisord config lives inside
`sonic-vs-202505-ztp.qcow2`, which `ztp-srv` cannot reach) plus a `neighbor <ip>
bfd` render plus a `config reload`. Both are mutations; neither was performed.

Refused on value, not only cost: every `frr.conf` already carries
`timers bgp 10 30`, so detection is already 30s, and BFD's entire contribution
would be a **sub-second timing claim on nested QEMU** — a number this
environment cannot support honestly.

### 1.3 GPU compute frontend fabric

| item | bucket | built? |
|---|---|---|
| BGP sessions | REAL — exists | — |
| EVPN/VXLAN state | CONTROL-PLANE ONLY — landed in `e358045` (#87) | — |
| tenant / service VRFs | **ABSENT — not a modelled concept** | **REFUSED** |
| frontend route reachability | **REAL** | **BUILT** (per-device; see limits) |
| ACL / PBR / firewall path health | **ABSENT** | **REFUSED** |

#### Tenant / service VRFs — ABSENT, refused

`fabric_model.py` contains **zero** occurrences of `vrf`, case-insensitively
(positive control: the same grep found 45 `def `). `s1-512.yaml` likewise. No
rendered `config_db.json` has a `VRF` key — only `MGMT_VRF_CONFIG`
(`grep -l '"VRF"' ztp-srv/*/config_db.json` → no files; control `"PORT"` → 48
files). On fr-leaf01/02/03 and both fr-spines: `ip vrf show` → one row, `mgmt
5000`; `CONFIG_DB keys 'VRF*'`, `APPL_DB keys 'VRF_TABLE*'`, `STATE_DB keys
'VRF*'` all empty; `show ip route vrf all summary` → exactly `default` and
`mgmt`.

**The decoy:** `ASIC_STATE:SAI_OBJECT_TYPE_VIRTUAL_ROUTER*` = **1** on every
switch measured, frontend and backend alike. It is the stock data-plane router,
and the mgmt VRF does **not** add a second — so a "tenant VRF count" built on SAI
virtual routers reads 1 on a box with zero tenant VRFs. Same family as the 54
stock tunnel objects.

Adding tenant VRFs means a profile feature module plus a renderer, in one change
— EVPN is the cautionary precedent, declared in the profile and rendered nowhere.

#### Frontend route reachability — REAL

`show bgp ipv4 unicast summary` on fr-leaf01: `peerCount 51`, all Established —
48 hosts + 2 spines + 1 peer leaf. All five frontend loopbacks (10.0.4.36-.40)
resolve. FRR, kernel and APPL_DB agree per prefix. **The planes are not
separately routed:** fr-leaf01 has 22 ECMP nexthops to backend `10.0.0.0/32` and
45 to storage `10.0.8.41/32`, every one of them a host `fe0`/`fe1` address, so
the multi-homed compute nodes are the inter-fabric transit. That is a property of
the built fabric, taken from the box, not from the design.

Forwarding is genuinely crossing the switches. `cpu0002` → `gpu0001`: 0% loss,
`ttl=62`, `traceroute -I` showing `10.0.4.38` then `10.0.4.37` — two SONiC
Loopback0 addresses as intermediate hops, each having decremented TTL and
sourced its own ICMP time-exceeded. A bridge shortcut would give `ttl=64` and one
hop. Negative controls behave: `10.99.99.99` and `203.0.113.99` both `rc=1`,
and FRR prints nothing for either.

**Three traps.** UDP-mode `traceroute` to a loopback returns `* * * * * * * *`
while `traceroute -I` and `ping` show a perfectly healthy path — SONiC does not
emit ICMP port-unreachable for UDP to a loopback, so a UDP-traceroute check
reports total failure on a working fabric. There is a **permanent 48-route
RIB/FIB gap** on every frontend leaf (`ebgp 1428 / FIB 1380`): the p2p `/31`s are
re-advertised by the neighbour and lose to the connected route, benign and
forever, so a naive "RIB vs FIB delta" alarm is permanently lit. And raw FRR-FIB
vs APPL_DB counts differ by up to 7 across the leaves; the invariant that holds
exactly is `APPL_DB = (FRR FIB − kernel-sourced FIB) + 1`, and **the +1 is
unexplained and must be pinned before it becomes an assertion.**

**Nothing covered this before:** `grep -rln "ROUTE_TABLE\|show ip route" tests/`
returned **zero files**. Every routing claim in this project is about sessions,
and a session can be Established while zebra programs nothing.

#### ACL / PBR / firewall path health — ABSENT, refused

Not control-plane-only: there is no control plane to be only. Nothing renders
ACLs (`grep -l 'ACL_TABLE\|ACL_RULE' ztp-srv/*/config_db.json` → no files;
`fabric_model.py` has zero `acl` occurrences; `show running-config | grep -c
access-list` → 0). CONFIG_DB `ACL_TABLE*`, `ACL_RULE*`, `PBH*`, `POLICER*` are
all empty — even the stock DATAACL/EVERFLOW/SNMP_ACL tables are absent, because
the generated config is minimal. `show acl table`, `show acl rule` and `aclshow`
print headers and zero rows.

**The decoy:** `SAI_OBJECT_TYPE_ACL_TABLE*` = **1** on every switch (a DTEL
table, six `SAI_ACL_ACTION_TYPE_DTEL_*` actions, switch-level bind point), with
0 entries and 0 counters. COUNTERS_DB's only `*ACL*` keys are 10 CRM **capacity
gauges** — sampled twice 173 s apart, byte-identical, and structurally incapable
of moving. PBR: `ip rule show` is entirely stock (l3mdev + the two mgmt-VRF
rules); `CONFIG_DB keys 'PBH_*'` empty. `show running-config` line 415 reads
`ip protocol bgp route-map RM_SET_SRC`, which **looks** like PBR in a grep and is
stock SONiC source-address selection.

The dangerous outcome is reachable but needs a specific mistake: with zero rules
an `aclshow`-based exporter emits no series, which is detectable. A metric
written as `sum(...) or 0`, or one counting `SAI_OBJECT_TYPE_ACL_TABLE`
(permanent 1) or `ACL_COUNTER` (permanent 0), would publish "0 denies" forever.

### 1.4 Storage backend fabric

| item | bucket | built? |
|---|---|---|
| BGP or static route health | **REAL** — BGP only, zero static routes | **BUILT** |
| storage path reachability | **REAL dataplane** | **REFUSED as new work** — extend `fv-cap-02` |

`grep -c "^ *ip route " .../st-leaf01/frr.conf` → **0**, across all five storage
devices; `show ip route static` returns empty and `show ip route summary` has no
`static` row. The storage skeleton is the backend's. Health: st-leaf01 48/48
Established, st-spine01 3/3.

Per-fabric denominators now exist (§3) and reproduce independently from
`fabric_model`: storage = 146 sessions / 152 series = 6 switch↔switch + 140
switch↔host. The per-**device** denominator is the one that mattered: st-leaf02
derives **50** neighbours against st-leaf01/03's 48, so a checker summing what
answered would get 54 "of 54" and read 100% healthy with 50 sessions invisible.

Path reachability is genuine. `storage0001 → storage0002` loopback: 0% loss,
`ttl=61`, `ip route get` → `via 10.128.10.51 dev st1 … proto bgp`, `traceroute
-n` → `10.128.10.51` then the target, `ping -t 1` 100% loss / `ping -t 2` 0%
loss, and the interfaces are containerlab point-to-point veths with no master —
the only bridges on the host carry `docker0` (down) and the mgmt subnet.

**The trap here is the sharpest in the document.** Every `frr-host` container
carries `default via 172.20.0.1 dev eth0`, and storage0001/0002 sit on the same
L2 management segment. Pinging a `172.20.0.x` address — or resolving a target by
hostname onto its mgmt IP — reports "storage path healthy" **with the entire
storage fabric down**, at `ttl=64 / 0.005 ms` instead of `ttl=61 / 1.5 ms`. A
bare `ping && echo ok` has neither discriminator. Worse, the obvious negative
control passes for the wrong reason: every fabric route is a /32 or /31 with no
aggregate, so an unrouted destination is punted onto mgmt and dies at the GCE
gateway — `ip route get 10.0.0.200` → `via 172.20.0.1 dev eth0`. That control
proves the mgmt gateway will not forward, **not** that the fabric has no path. A
meaningful one needs a TTL/latency discrimination or a link shut, and a link shut
is a mutation.

`tests/fidelity/fv-cap-02-dataplane-forwarding.sh` already does this class of
test properly — receiving-side tcpdump, an explicit `TTL == 63` assertion that
rejects both the host shortcut (64) and the spine detour (61), both-port counter
deltas — but it picks any two hosts sharing a leaf, never targets storage, and is
not wired into `verify.sh`. **Extending it is a smaller and better job than
writing a second one**, and it needs one addition: assert the target is a fabric
address, not a `172.20.0.x` one.

### 1.5 SNMP MIB areas — where the `libsai_vs` boundary falls

Reachability is not enough. `sonic-snmpagent` is a **translator over the SONiC
DBs**, so an OID is exactly as real as its backing store — and a reachable agent
serving permanently-zero counters is worse than no agent. This section exists so
that question is settled once.

Measured with the image's own net-snmp 5.9.3, from inside each switch's `snmp`
container against `127.0.0.1`. Every area was traced to its backing store and
the store read directly; nothing here is inferred from an OID name.

One structural fact underpins the whole table: **`snmpd` and `sonic_ax_impl` are
separate processes**, joined over `agentxsocket tcp:localhost:3161` (proved by
`ps`). So the MIB has two halves with different trustworthiness — net-snmp's own
modules read the VM's real Linux kernel, and the AgentX subagent translates
SONiC DBs. The `libsai_vs` boundary runs between **the DBs that hold control
state** (real) and **the DBs that hold hardware state** (mock).

| area | bucket | backing store | verdict |
|---|---|---|---|
| BGP4-MIB peer state `15.3.1` | **REAL** | STATE_DB `NEIGH_STATE_TABLE` | **PUBLISH** `.2/.3/.7/.16` |
| BGP4-MIB ASN fields `.9`, `bgpLocalAs` | **REAL data, BROKEN encoding** | same | **DO NOT PUBLISH** |
| LLDP-MIB, `Ethernet*` rows | **REAL** | APPL_DB `LLDP_ENTRY_TABLE`, real `lldpd` | **PUBLISH** |
| LLDP-MIB, the `eth0` row | **SYNTHETIC artifact** | same table, one key for 32 neighbours | **DO NOT PUBLISH** |
| `ifOperStatus` `2.2.1.8` | **REAL** | APPL_DB `PORT_TABLE.oper_status` | **PUBLISH** |
| `ifAdminStatus` `2.2.1.7` | REAL-consistent, **unfalsified** | APPL_DB/CONFIG_DB `admin_status` | publish with the caveat |
| CPU / memory / load | **REAL** | net-snmp's own modules over `/proc` | **PUBLISH** |
| disk `dskTable` `2021.9` | **ABSENT** | none — module not served | **DO NOT PUBLISH** |
| disk `hrStorageTable` | **REAL for RAM, ABSENT for real filesystems** | `/proc/meminfo` + mounts | **DO NOT PUBLISH** as disk |
| `sysName` / `sysUpTime` / `sysDescr` | **REAL** (static by nature) | hostname, agent clock, `sonic_version.yml` | **PUBLISH** |
| `sysLocation`, `sysServices` | **SYNTHETIC** | hardcoded in `snmpd.conf` | **DO NOT PUBLISH** |
| ENTITY-MIB `47.1.1.1.1` | **near-empty, but HONEST** | STATE_DB `EEPROM_INFO`=0 keys | **DO NOT PUBLISH** |

**BGP4-MIB is genuinely real, and it is the best SNMP signal on the box.** Row
counts equal the real peer count on all seven devices tested — 51/34/3/16/48 for
fr-leaf01, bk-p1-r1-leaf01, fr-spine01, bk-p1-spine01, st-leaf01 — with
`bgpPeerState` = 6 (established) for every row, and
`bgpPeerFsmEstablishedTime` advancing exactly +35 over 35 s. The zero-peer
control passes: both OOB switches return `No Such Instance currently exists at
this OID`, an empty table rather than fabricated rows, and that is correctly
distinct from the `No Such Object` returned by an absent subtree and from a
timeout. **The three-way distinction is available in SNMP for free.**

**But every ASN it reports is a negative number.** On bk-p1-r1-leaf01:

```
iso.3.6.1.2.1.15.3.1.9.10.128.0.0 = INTEGER: -94967248
```

RFC 1657 types `bgpPeerRemoteAs` as `INTEGER (0..65535)`; the agent stuffs a
4-byte private ASN into it and it BER-encodes negative. Verified against the
model rather than by assuming the wraparound:
`-94967248 + 2^32 = 4200000048`, which is `dc1-pod001-gpu0001`'s derived ASN and
the far end of the `10.128.0.0/31` this peer sits on; `-94967296 + 2^32 =
4200000000`, the leaf's own. **Of the 122 ASNs this profile derives,
`0` fit RFC 1657's field.** So this is not an edge case — every ASN in every
fabric this project builds is negative over SNMP.

**Never poll the `1.3.6.1.2.1.15` subtree as a whole.** Measured on one leaf:
the full walk returns **726,121 varbinds in 186 s**, against **1,173 rows in
under a second** for `15.3.1` alone. The bulk is `bgp4PathAttrTable`. An NMS
pointed at the subtree root costs ~2.5 hours across 48 switches.

**The LLDP `eth0` row is the most dangerous artifact found.** The neighbour
*names* are real and exactly match the wiring — bk-p1-r1-leaf01 reports
`dc1-pod001-bk-p1-spine01` and `-spine02` on Ethernet0/4, precisely its two
switch-side links. But all 48 switches share one containerlab management bridge,
so `lldpd` sees 32 neighbours on `eth0` while `LLDP_ENTRY_TABLE` is keyed by
*local interface* — 32 collapse into 1, and the survivor differs per device and
is entirely plausible (`fr-leaf01 → fr-leaf03`, `bk-p1-r1-leaf01 →
bk-p1-r8-leaf02`, `oob-sw01 → bk-p2-r5-leaf01`). **An NMS building topology from
LLDP will draw a point-to-point link between two switches that are not
connected.** Coverage is also thin for a second reason: SNMP shows 3-17
neighbours where `lldpctl` sees 34-48, because the containerlab host nodes run
no `lldpd` at all.

**`ifOperStatus` was properly falsified**, which matters because most of this
table could not be. A full alias→ifIndex→APPL_DB join over two leaves gave
**128 port-comparisons with zero mismatches**, and the value genuinely varies —
4/17/35/41/41/49/53 up across the seven devices, with fr-spine01 correctly
reporting 61 down. `ifAdminStatus`, by contrast, reads 1 on all 455 interfaces;
CONFIG_DB and APPL_DB are also 100% `up`, so it agrees with its store, but **no
admin-down port exists anywhere in this fabric and creating one is a write.**
Honest verdict: consistent, discrimination unproven. That is not the same as
verified, and it is recorded as such.

**CPU and memory are the most trustworthy numbers in the MIB**, precisely
because they do not come from SONiC at all. `laLoad` was byte-identical to
`/proc/loadavg` on two independent samples (`1.47 1.35 0.75`, then
`1.25 1.30 0.76`), `memTotalReal` matched `free -m` exactly, and
`hrSystemUptime` matched `/proc/uptime` to 0.4 s.

**Disk is a configured intent that serves nothing** — the `snmpd.conf` on every
switch contains `disk / 10000` and `includeAllDisks 10%`, yet `2021.9` returns
`No Such Object` while `2021.4.5.0` on the same enterprise tree answers `INTEGER:
3938752`. The positive control proves the tree is served and only the disk module
is missing. `hrStorageTable`'s 23 rows carry `/dev`, `/tmp`, `/etc/hosts` and
`/proc/kcore` — and **not `/`, `/host` or `/var/log`**, the only filesystems that
can actually fill. Anyone reading `snmpd.conf` will believe disk alarms work.
They do not.

**ENTITY-MIB is empty but, unusually for this document, honest.** Two rows per
device, `entPhysicalSerialNum` = the literal string `"N/A"`, Mfg and Model
empty, backed by `EEPROM_INFO`/`CHASSIS_INFO`/`TRANSCEIVER_INFO` at zero keys.
Nothing is fabricated. It is still refused, for a different reason: a naive
collector will store the string `"N/A"` as the serial number of all 48 switches.
Related and worth flagging to whoever owns inventory: `sysDescr` advertises
`HwSku: Accton-AS7816-64X` while `show platform summary` reports
`x86_64-kvm_x86_64-r0, ASIC: vs` — real data from `sonic_version.yml`, but an
asset system will record 48 physical Accton chassis.

#### IF-MIB counters — 4 of 39 fields are real, and the other 35 are worse than absent

**The negative control passed first, and everything below depends on it.** Over
a 297 s window on fr-leaf01, `ifOutOctets` moved on **52 of 52** L3-routed ports
(deltas 2670-7200 octets) and `ifInOctets` on 51 of 52; independently on
bk-p1-spine01 over 146 s, **16 of 16**. The ifIndex→port map resolved 64/64.
Traffic was flowing and it was observed moving. Only against that baseline does
"this counter did not move" mean anything.

| field | verdict |
|---|---|
| `ifInOctets`/`ifOutOctets`, `ifHCInOctets`/`ifHCOutOctets`, `ifInUcastPkts`/`ifOutUcastPkts` | **REAL — PUBLISH** |
| the same six on the 12 unconfigured ports | **REAL, correctly zero — PUBLISH** |
| `ifInErrors`, `ifOutErrors`, `ifOutDiscards` | **permanent 0 — DO NOT PUBLISH** |
| `ifInDiscards` | **frozen non-zero — DO NOT PUBLISH** |
| CISCO-SWITCH-QOS-MIB `9.9.580.1.5.5` (5,120 objects) | **permanent 0 — DO NOT PUBLISH** |
| CISCO-PFC-EXT-MIB `9.9.813` (1,152 objects) | **permanent 0 — DO NOT PUBLISH** |
| `SAI_ROUTER_INTERFACE_STAT_*` (52 RIF objects) | **totally 0 — DO NOT PUBLISH** |
| queue / priority-group / watermark (5,376 keys) | **permanent 0 — DO NOT PUBLISH** |
| FEC counters | **ABSENT — nothing to publish** |

**Of the 39 `SAI_PORT_STAT_*` fields present on every port, 4 move, 1 is a
frozen non-zero, and 34 are permanently `0`** — the same count on both devices
sampled.

**This is not a disabled poller.** `FLEX_COUNTER_DB` holds **3,785** keys
(`PORT_STAT_COUNTER`, `QUEUE_STAT_COUNTER`, `QUEUE_WATERMARK_STAT_COUNTER`,
`PG_DROP_STAT_COUNTER`, `PG_WATERMARK_STAT_COUNTER`). The counters are actively
polled and `libsai_vs` returns zero. That distinction is the whole finding: it
cannot be fixed by configuration.

**And SNMP mirrors COUNTERS_DB exactly** — six interleaved reads on Ethernet0
gave `SNMP=286920 DB=286920 diff=0`, 6 for 6. (Reversing the read order produced
`diff=85` twice, which is read-order skew, not a structural offset.) So an SNMP
zero is a real COUNTERS_DB zero, which is a real `libsai_vs` zero. **SNMP does
not get around the boundary; it exposes it through a different protocol.**

**`ifInDiscards` is the single most dangerous item in this entire document.** It
is non-zero on 48 of 64 ports with a *believable per-port spread* — 2, 4, 6, 7,
8, 16, 22, 31 — that looks exactly like accumulated drop history. It is a boot
artifact. It was bit-identical at t, t+81 s and t+297 s, and again via
`show interfaces counters errors` twelve minutes later. A trend chart of it
shows a flat line at a plausible non-zero value forever, and a
"discards increasing" alert can never fire. A permanently-*zero* counter at
least looks suspicious to a careful reader; this one does not.

Runner-up: **PFC.** 1,152 constant zeros presented as pause requests and
indications. On a fabric whose entire purpose is lossless RoCE, "PFC pause
count = 0" is the most seductive false green available.

#### Physical sensors — absent, and honest about it

This is the good news of the audit. **Every** sensor MIB returns
`No Such Object`: `entPhySensorTable` (`1.3.6.1.2.1.99.1.1`),
CISCO-ENTITY-FRU-CONTROL (`9.9.117`), CISCO-ENVMON (`9.9.13`), LM-SENSORS
(`2021.13.16`), Dell/Force10 (`674.10895`). All **twelve** STATE_DB platform
tables — `PSU_INFO`, `FAN_INFO`, `FAN_DRAWER_INFO`, `TEMPERATURE_INFO`,
`THERMAL_INFO`, `VOLTAGE_INFO`, `CURRENT_INFO`, `TRANSCEIVER_INFO`,
`TRANSCEIVER_DOM_SENSOR`, `TRANSCEIVER_STATUS`, `CHASSIS_INFO`, `EEPROM_INFO` —
hold **zero keys**.

The agent code for those MIBs is present (`rfc3433.py:714
PhysicalSensorTableMIB`) and simply finds an empty database. The cause is one
level down: **`/usr/share/sonic/platform/` does not exist**, so `pmon` runs only
`rsyslogd`, `stormond` and the exit listener — no `thermalctld`, `psud`,
`xcvrd`, `ledd`, `syseepromd`, `pcied`. Nothing ever writes those tables. The
CLI is honest too: `show platform psustatus` fails with rc=1, `show platform
syseeprom` with rc=19 (`does not support EEPROM`), `show platform fan` →
`Fan Not detected`, `show platform temperature` → `Thermal Not detected`, and
`show platform ssdhealth` reports `QEMU HARDDISK` with `Health: N/A`.

**The one exception, and it must be excluded explicitly.** STATE_DB
`ASIC_TEMPERATURE_INFO` exists and holds

```
{'maximum_temperature': '0', 'average_temperature': '0'}
```

**byte-identical on all five switches sampled**, unchanged over 95 s. It is not
reachable over SNMP — but any STATE_DB scraper picks it up, and `0 °C` satisfies
every `temperature < threshold` alarm forever. Identical values across five
different switches is the proof that it is a constant rather than a
measurement.

#### The boundary, stated once so it is not re-litigated

> On the gpufab simulator SONiC runs `docker-syncd-vs` over `libsai_vs`, a
> software SAI on veth/tc with no ASIC. Measured 2026-07-28 on `gpufab-s11`:
>
> **Real side** — IF-MIB *volume* counters only: `ifInOctets`/`ifOutOctets`
> (`.2.2.1.10/.16`), `ifHCInOctets`/`ifHCOutOctets` (`.31.1.1.1.6/.10`),
> `ifInUcastPkts`/`ifOutUcastPkts` (`.11`/`.17`). They move with real traffic
> and SNMP matches COUNTERS_DB byte-for-byte.
>
> **Mock side** — every IF-MIB *health* counter (`ifInErrors` `.14`,
> `ifOutErrors` `.20`, `ifOutDiscards` `.19`, `ifInDiscards` `.13`); every
> broadcast / multicast / non-unicast / unknown-protos / oversize / undersize /
> fragment / jabber counter; all 5,120 objects of CISCO-SWITCH-QOS-MIB
> `9.9.580.1.5.5`; all 1,152 of CISCO-PFC-EXT-MIB `9.9.813`; every queue,
> priority-group and watermark counter; and all `SAI_ROUTER_INTERFACE_STAT_*`.
> 34 of the 39 `SAI_PORT_STAT_*` fields per port are permanently `0`, and the
> flex-counter poller is running — the zeros come from the SAI, not from
> configuration.
>
> **Absent, correctly** — FEC counters exist in no form: no `SAI_PORT_STAT_*FEC*`
> field and no OID in a 1,939,241-object full walk. Pause counters likewise.
> Every physical-sensor MIB returns `No Such Object`.
>
> **No monitoring stack built on this simulator may present an interface error
> rate, a discard rate, a PFC/queue/watermark statistic, or any environmental
> reading. They are not degraded measurements; they are the absence of a
> measurement wearing the name of one.**

#### Plausible-looking constants — the refuse list

Ranked by how convincingly each lies:

1. **`ifInDiscards` `.2.2.1.13`** — non-zero, believably distributed, frozen
   forever. The worst of them.
2. **CISCO-PFC-EXT-MIB `9.9.813`** — 1,152 zeros reading as "no pause frames" on
   a lossless-RoCE fabric.
3. **`ifInErrors` `.14`, `ifOutErrors` `.20`, `ifOutDiscards` `.19`** — constant
   0, indistinguishable from a healthy switch.
4. **CISCO-SWITCH-QOS-MIB `9.9.580.1.5.5`** — 5,120 zeros as per-queue traffic
   and drop statistics.
5. **STATE_DB `ASIC_TEMPERATURE_INFO` `0`/`0`** — not SNMP-reachable, identical
   on five switches; exclude from any STATE_DB scraper.
6. **the LLDP `eth0` neighbour** — one arbitrary survivor of 32, different and
   believable on every device.
7. **`sysLocation`** — a correct-looking device name, so a location-keyed NMS
   silently fills with hostnames.
8. **`sysServices = 72`** — identical everywhere, bitmask omits layer 3 on a
   router.
9. **`entPhysicalSerialNum = "N/A"`** — a string, not a null.
10. **`ifAdminStatus = 1` / `bgpPeerAdminStatus = 2`** — correct today, never
    observed taking any other value.

#### One thing to hand on

`STATE_DB PORT_TABLE|Ethernet0` reports `speed: 4294967295` (0xFFFFFFFF) while
APPL_DB says `100000`. Anything built on `ifSpeed`/`ifHighSpeed` must read
APPL_DB, and must not be built before that discrepancy is understood.

**Safety fact, measured:** net-snmp scrubs `-c <community>` out of its own
`argv`, so invoking it does not leak the community via `ps`.

---

## 2. What was built

Three commits in `gpufab-platform` (source / oracle / tests, separately), none
pushed.

**`monitoring/gpufab_exporter.py`** — two new read blocks appended to the
existing single SSH per poll (no new connections: slirp wedges under connection
churn). Measured cost of both blocks together, through the real quoting path,
including SSH setup: **0.38-0.45 s per switch**, against a 60 s round.

| metric | what it is |
|---|---|
| `gpufab_switch_mgmt_reachable{device,fabric,role}` | 48/48, including the OOB pair |
| `gpufab_mgmt_vrf_routes` | routes in kernel table 5000 |
| `gpufab_mgmt_vrf_default_present` | the gateway route exists |
| `gpufab_default_route_in_main_table` | **must be 0** — §2.5 isolation, published continuously |
| `gpufab_route_observed{device,fabric,role}` | did the routing read run |
| `gpufab_route_bgp_total` | BGP routes in the kernel FIB |
| `gpufab_route_multipath` | how many have >1 nexthop |
| `gpufab_route_ecmp_max` | widest ECMP set |
| `gpufab_route_appl_db_total` | ROUTE_TABLE entries fpmsyncd published |
| `gpufab_asic_next_hops` | SAI next-hop objects — **the one with an exact oracle** |
| `gpufab_gnmi_get_ok` | the gNMI server answered a live Get |

The OOB pair is polled by a new `poll_mgmt_only()`, which runs both blocks and
no BGP. Its answer is the point: an OOB switch must read **0 BGP routes and 0
SAI next hops**, with `observed=1` beside them proving the zero was measured.

`gpufab_scrape_ok` was deliberately **not** widened to 48. It means "the full
telemetry poll completed", which is a different question from "the box
answered" — and t39 asserts one overlay observation per `scrape_ok==1` switch,
so widening it would break a correct check on two switches that legitimately
carry no overlay.

**`tools/expected.py`** — six new derived keys, each with a constraint, because
a number nothing compares is how `max_ports_per_switch` printed 70 against a
64-port platform for the life of the project:

```
bgp_sessions_by_fabric      backend=1088 frontend=152 storage=146   (oob 0)
bgp_peer_series_by_fabric   backend=1152 frontend=160 storage=152   (oob 0)
bgp_neighbors_by_device     48 entries; sums to 1464 == bgp_peer_series
switch_mgmt_targets         48      switch_bgp_speakers  46
```

Constraints added: each fabric sum equals the fabric-wide total,
`bgp_neighbors_device_sum == bgp_peer_series`,
`bgp_neighbors_max <= platform_ports`, `switch_bgp_speakers <=
switch_mgmt_targets`. **18/18 hold for s1-512; 8/8 for s0-64, s2-1024, s3-4096,
s4-10240.** Each was demonstrated failing by corrupting the value first. The
legacy `lite/minimal/gpu64/full/th5` profiles fail to derive with
`KeyError: 'fabric'` — pre-existing, verified against `git stash`, not caused
here.

**`tests/t41-mgmt-route-truth.sh`** (wired into `verify.sh` as `mgmt-route`) —
41 assertions off-host, more once an exporter answers. It drives the committed
exporter's own parsers through every verdict; drives the real `poll()` with a
patched `subprocess` so the **partition chain under test is the one that runs**
rather than a copy of it; adjudicates the exporter's claim against the devices
using the exporter's own command strings; asserts the ASIC next-hop count
**equals** the derived per-device neighbour count; and runs the `NEXT_HOP*`
decoy on a live box.

**Every assertion was demonstrated failing before it passed.** Eight mutations
of the exporter, each caught by a *named, specific* assertion:

| mutation | caught by |
|---|---|
| drop the colon from the SAI next-hop locator | locator assertions (2) |
| remove the `PORT\|*` positive control | route block control |
| remove the `ctl < 1` guard from the parser | `r_no_db_cli` parses instead of REFUSING |
| remove the `__ROUTE__` partition from `poll()` | `poll_full` route=0 |
| `-notls` → `-insecure` | gNMI flag assertions (2) |
| except-arm drops instead of publishing 0 | `poll_dead` mgmt series vanishes |
| remove the `__ROUTE_END__` sentinel | truncation refusal |
| overlay series published instead of dropped on failure | `poll_dead` vtep present |

The `poll()` drive earned its keep immediately: it caught a bug in the **test**
— the node dict omitted `rail`, which `poll()` reads inside the portstat loop,
so a `KeyError` took the whole poll into its except arm and every plane reported
"asked, could not read" for a device that had answered perfectly.

---

## 3. What is NOT verified, and must not be assumed

**t41 has never run on gpufab-s11, and cannot without a mutation.** The host is
behind git — `monitoring/gpufab_exporter.py` there is `fa07b3eb…` against git's
`5f85fc78…`, contains **zero** occurrences of `gpufab_vtep_observed`, and
`/opt/gpufab/gpufab-platform/tests/` ends at t36. So t37, t38, t39, t40 and t41
have all never executed against this fabric. Everything in §2 was verified by
driving the committed code, by mutation, and by running each command string
against live devices through the real quoting path — but the exporter itself has
not been restarted with these metrics, because that is a mutation and the brief
was read-only.

The first thing to do with this work is **sync and restart the exporter on a
fabric, then run `verify.sh --only mgmt-route`**. Expect it to fail at section 3
until then, with the message that says exactly why. §H of the issue register is
the precedent: one cold run found six defects ten code reviews could not.

Additionally: the `+1` in the APPL_DB/FRR-FIB invariant is unexplained; and
`gpufab_exporter.py:27` still calls `Path.exists()` unguarded, which is the #84
site (`PermissionError` propagates rather than returning False when the parent is
not searchable, on Python ≤3.11). **Nothing added here introduces a new
filesystem probe** — the SNMP community, if built, must be read from CONFIG_DB
over the existing SSH, never from `/opt/gpufab/secrets`.

---

## 4. Ranked: what to build next, and what to refuse

**Build, in this order.**

1. **SNMP responding, 48/48.** The only requested item that is REAL, measured
   end-to-end, and still unbuilt. A second daemon and data path independent of
   vtysh, covering the OOB pair, where today `t23`/`t29` assert the community
   value and never send a packet. **Cost is now one line in the existing poll
   block**, not the ~100-line BER client first estimated — the full net-snmp
   suite is inside the switch's `snmp` container (§1.1). Constraints, all
   binding: community read from CONFIG_DB over the existing SSH (**not**
   `snmp_secret`, which is a different value of a different length) and never
   logged or echoed (#95); `snmpset` never invoked; and the **OID allow-list**
   below, which §1.5 derives and which is binding rather than advisory:

   | allowed | refused |
   |---|---|
   | `sysName.0`, `sysUpTime.0`, `sysDescr.0` | `sysLocation`, `sysServices` |
   | `bgpPeerState` `15.3.1.2`, `bgpPeerFsmEstablishedTime` `.16` | `bgpPeerRemoteAs` `.9`, `bgpLocalAs` — negative for every ASN |
   | `ifOperStatus` `2.2.1.8` | `ifInErrors` `.14`, `ifOutErrors` `.20`, `ifInDiscards` `.13`, `ifOutDiscards` `.19` |
   | `ifHCInOctets`/`ifHCOutOctets`, `ifInUcastPkts`/`ifOutUcastPkts` | all queue/PFC/watermark/RIF counters; all sensor MIBs; ENTITY-MIB |
   | UCD CPU / load / memory | `dskTable`, `hrStorageTable` as "disk" |
   | LLDP `Ethernet*` rows | the LLDP `eth0` row |

   Never walk a subtree root: `1.3.6.1.2.1.15` returns **726,121 varbinds in
   186 s** on one leaf (~2.5 h fleet-wide) against 1,173 rows in under a second
   for `15.3.1`. GET the specific OIDs.
2. **Per-prefix route adjudication in t41.** The counts are built; what is
   missing is "every switch loopback resolves in APPL_DB", which is the assertion
   that catches Established-but-not-programmed per prefix. It must carry the
   bare-IP key rule for /32s, or it reports every host route as missing.
3. **Storage/backend dataplane probe — by extending `fv-cap-02`**, adding a
   storage pair, wiring it into `verify.sh`, and asserting the target is a fabric
   address rather than `172.20.0.x`.
4. **Serial-console reachability** (`:5000` per hypervisor) as the honest
   BMC substitute, named for what it is.
5. **Wire the `by_fabric` keys to a consumer.** They are derived and constrained
   and nothing reads them; a per-fabric assertion in t13 is a small job.
6. **The `+1`.** Pin it before anything asserts on APPL_DB route totals.

**Refuse.** BMC/IPMI/Redfish and PDU (nothing to measure; any metric would be a
`docker ps` proxy wearing a hardware name). BFD (absent; enabling needs an image
change and buys only a sub-second timing claim nested QEMU cannot support).
Tenant/service VRFs and ACL/PBR (metrics for features that do not exist, each
with a non-zero stock baseline that would make a naive version look like it
works). And the dataplane error counters of §0, permanently.

---

## 5. Trap register

Every one of these was hit or reproduced during this work.

| trap | what it does |
|---|---|
| `SAI_OBJECT_TYPE_NEXT_HOP*` | 172/179/407/499 vs true 34/16/51/48 — needs the colon |
| `SAI_OBJECT_TYPE_TUNNEL*` | 54 on a clean box (#87) |
| `SAI_OBJECT_TYPE_VIRTUAL_ROUTER*` | 1 on a box with zero tenant VRFs |
| `SAI_OBJECT_TYPE_ACL_TABLE*` | 1 (a DTEL table) on a box with no ACL |
| `ROUTE_TABLE:10.0.0.15/32` | `{}` — host routes drop the mask; `{}` also means absent |
| width-1 routes | no `nexthop` keyword; counting them yields 0, not 1 |
| `ip route show \| grep -c .` | counts multipath continuation lines — 3911 on one leaf |
| `sonic-db-cli keys \| wc -l` | 1 on no match (bare newline); needs `grep -c .` |
| `grep -c` | prints 0 **and** exits 1; `\|\| echo 0` makes the value `"0\n0"` |
| SNMP community | `HMAC(snmp_secret, device)` — 32 chars in the artifact, not the 64-char master; never print it (#95) |
| SNMP `ifName` | returns the alias `Eth1(Port1)`; ifIndex strides by 4 |
| `command -v a b c` in dash | prints only the FIRST match — read as "only snmpget exists" when all 23 net-snmp binaries were present. Use `ls /usr/bin/snmp*` |
| `which snmpwalk` on the switch | empty, because the tooling is inside the `snmp` CONTAINER, not the VM's namespace |
| `ifInDiscards` | frozen NON-zero with a believable spread (2/4/6/7/8/16/22/31) — a boot artifact that reads as drop history |
| `bgpPeerRemoteAs` | negative for every ASN — RFC 1657 types it `INTEGER (0..65535)`; 0 of this profile's 122 ASNs fit |
| walking `1.3.6.1.2.1.15` | 726,121 varbinds / 186 s per leaf; `15.3.1` alone is 1,173 rows in under a second |
| LLDP `eth0` row | 32 mgmt-bridge neighbours collapse into 1 arbitrary plausible row — invents a link between unconnected switches |
| `snmpd.conf` `disk / 10000` | configured and NOT served; `2021.9` returns `No Such Object` while `2021.4.5.0` answers |
| `hrStorageTable` | lists `/etc/hosts` and `/proc/kcore`, omits `/`, `/host`, `/var/log` |
| STATE_DB `ASIC_TEMPERATURE_INFO` | `0`/`0`, identical on five switches, never moves — the only synthetic sensor value on the box |
| STATE_DB `PORT_TABLE speed` | `4294967295` where APPL_DB says `100000` |
| `No Such Object` vs `No Such Instance` vs timeout | three different answers — absent subtree, empty table, unreachable. SNMP gives the three-way distinction for free |
| gNMI naming | container/feature is `gnmi`; `*TELEMETRY*` is empty on a serving box |
| gNMI flag | `-notls`, not `-insecure` |
| UDP traceroute | silent on a healthy path to a loopback |
| frr-host default route | a `172.20.0.x` ping reports the fabric healthy while it is down |
| unrouted negative control | dies at the GCE gateway, not in the fabric |
| `docker exec clab-gpufab-<sw>` | lands in the QEMU wrapper, whose hostname **is** the device name |
| `ps aux \| grep -c "[b]fdd"` | 1, from the parent shell's own command line |
| `grep -rli bfd` on artifacts | 48 files — the `SAI_API_BFD` syslog block |
| `frr defaults datacenter` | supplies maximum-paths 64 with `maximum-paths` written nowhere |
| RIB/FIB delta on fr-leaves | permanently 48; benign |
| `ip protocol bgp route-map` | stock source selection, not PBR |
