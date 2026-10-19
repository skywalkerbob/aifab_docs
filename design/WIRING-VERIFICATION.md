# Wiring verification — rail, plane, and every cable

Status: IMPLEMENTED 2026-10-19. Measured on the live S1 fabric.

## 1. The question, and why the obvious answer is wrong

**Is this fabric wired the way the source of truth says?**

The obvious instrument is the BGP census, and it cannot answer. Two leaves
cross-connected on the wrong rails still establish every session, still count
correctly, and still forward traffic. A rail-optimised dual-plane backend is
built out of *parallel* links — 8 rails per plane per node, and from s2 up a
further 8 parallel links from each spine to each core — and
`MULTI-HOST-FABRIC.md:663` says it outright:

> counts cannot detect miswiring when parallel links exist. Eight parallel
> spine-core links can be cross-connected to each other and every count stays
> correct.

With 8 rails × 2 planes × `leaves_per_rail_plane: 2`, a DGX-B300's 16 backend
NICs can be permuted arbitrarily across the 16 rail-leaves and **every** count
holds: NICs per node, ports per leaf, links per pod, sessions per switch. So
the oracle has to be **identity per endpoint**, judged against the SoT.

## 2. Three layers, three oracles

| layer | instrument | what it can prove |
|---|---|---|
| the model against itself | `gpufab-platform/tools/wiring.py`, `t118` | the fabric R *describes* is rail-correct |
| the SoT against the box | `gpufab-network/tools/audit_lldp.py`, `t119`, `deploy/checks/lldp-audit.sh` | the fabric that *exists* matches R, per cable, per port |
| cross-host tunnels | `tools/tunnel_check.py`, `t113` | each substrate tunnel's VNI, remote and port, both ends |

### 2.1 The model layer, and the independence that makes it non-circular

`fabric_model` places a node's k-th backend link by **position**:

    leaf = bk_leaf_list[(pl * rails + r) * lpr + (idx % lpr)]

Checking that formula against itself proves nothing. What *is* independent is
that the allocator builds each device's **name** from (plane, rail) while the
link builder places links by slot **index** — two encodings of one fact,
produced by different code. And every operator-facing artifact keys off the
**name**: NetBox's `plane`/`rail` custom fields, the rail topology view, any
LLDP expectation. So:

* **W0** position ↔ name agreement, for every backend leaf and spine
* **W1–W4** NIC *k* lands on rail `k % rails`, plane `k // rails`; its peer is
  a rail-leaf of that (plane, rail); every pair has exactly `lpr` leaves
* **W5–W6** a leaf uplinks only inside its own plane, to every spine of it
* **W7** no backend link crosses a pod
* **W8** the SoT's `plane`/`rail` fields equal the name's own encoding
* **W9–W11** the spine→core multiset equals `cores[(i*up + u) % cores_n]` with
  `up = spine_ports − rails*lpr`

W0 comes first because W1–W11 are judged against the name.

**Measured clean on all six rungs**, s0-64 through s5-32768 — 1260 switches and
66080 NIC attachments at the top rung, zero violations. Seven mis-wirings are
proven detectable by mutating the model: a rail swap, a plane-crossing uplink
pair, a device whose name stops matching its slot, a pod-crossing link, a
missing parallel spine-core link, a parallel link *moved between cores*, and a
SoT field disagreeing with its name.

### 2.2 The box layer, and the translation that makes it possible at all

`audit_lldp.py` replaces a 12-line stub that had exited nonzero since the day
it was written, keeping its contract: for every switch, read the LLDP table and
compare against NetBox Cable objects; exit 0 only if every cable is seen and no
unexpected neighbour exists.

**The hard part is the port names, and the obvious implementation fails
everything.** The SoT names ports by *catalog lane* — `first_lane +
k*lanes_per_port`, stride 8 on an 800G 64-port leaf — while a `sonic-vm` runs a
VS HWSKU whose PORT table is stride 4. Measured on the live fabric:

    SoT   leaf:Ethernet504  <->  spine01:Ethernet120
    LLDP  leaf:Ethernet252  -->  spine01:Ethernet60      (504/8 = 63, 63*4 = 252)

Comparing the SoT's names directly against LLDP — which is what the stub's own
docstring describes — reports **every correctly wired link as mis-wired, on
every switch, at every rung**: a 100% false-failure audit that looks
authoritative. The audit therefore translates through
`interim_deploy.vm_port`, the mapping the renderer itself calls, on **both**
ends (translating only the local side moves the false failure onto the
peer-port check), and **refuses** a device whose model is unknown rather than
passing a name through.

**Four measured behaviours the parser is built around**, each of which an
invented fixture would have got wrong:

* `lldpctl -f json` returns `lldp.interface` as a **list** of single-key
  objects and the same ifname **repeats** once per neighbour — 34 entries on
  the captured leaf, of which `eth0` appears 32 times. A dict comprehension
  keeps one of the thirty-two.
* the remote port's `id` is an **alias**, `Eth16(Port16)`; `descr` carries the
  real name, `Ethernet60`. Matching on `id` fails every link.
* `show lldp table` is **lossy** — it rendered one of `eth0`'s 32 neighbours.
* the **management bridge** makes every switch a neighbour of every other on
  `eth0`. Those are not cables; auditing them reports 32 undeclared neighbours
  on a correct device. The audited set is the SoT's own: a port is judged if
  and only if the SoT declares a cable on it.

## 3. Coverage is the verdict

The SoT cables a rail leaf 34 times: 32 GPU rail attachments and 2 spine
uplinks. The GPU nodes ship `/usr/sbin/lldpcli` and **did not run `lldpd`** —
their clab `cmd` is `sleep infinity` and daemons arrive by `docker exec`, which
`deploy/55-unnumbered.sh` did for FRR only. So the audit could see **2 of 34**.

An audit reporting "clean" having judged 2 of 34 is this project's signature
defect with a new name, so `coverage` travels with every verdict, a device with
nothing observable is UNREADABLE rather than PROVEN, and the fabric gate
refuses partial coverage unless `--accept-partial` says so out loud.

`55-unnumbered.sh` now starts `lldpd` alongside the FRR daemons — the same
rule as FRR, start the *daemon*, never restart the container, or containerlab's
veths go with it. **The check is the daemon answering (`lldpcli show chassis`),
not `pgrep`:** a pgrep two seconds after the exec raced a daemon that had not
finished starting and reported FAILED about an lldpd that was running and had
already been learned by its neighbour.

### Measured, whole fabric

    profile .../s1-512.yaml derives 48 sonic-vm switch(es)
    lldpd answering on 75 host node(s), silent on 1
    123 device(s) answer lldpcli and can therefore be observed
    devices: 48 PROVEN, 0 NOT-PROVEN, 0 UNREADABLE
    cable-ends (summed per device): 1546 declared, 1544 observable, 1544 seen
    VERDICT: REFUSE  coverage is 1544/1546

Per leaf, coverage went from **2/34 to 34/34**. The two it could not reach were
the **head node's**: `gpufab-head:1.0` had no `lldpd` installed at all, so
`images/Dockerfile.head` now installs it, which takes the fabric to 1546/1546.

*Cable-ENDS, not cables*: a switch-to-switch cable is declared by both of its
devices, so at S1 1466 distinct cables present as 1546 ends.

## 4. Two defaults that are not defaults

* **Which NetBox** comes from `tools/sot.py` — PINNED, CONFIGURED, or REFUSED.
  The first version of the gate defaulted to `http://127.0.0.1:8000`, and on a
  *fabric* host nothing listens there. It fetched nothing and reported VOID,
  which was honest — but a default that reaches a **different sim's** NetBox is
  how a stage renders the wrong fabric, and `sot.py` exists because that nearly
  happened.
* **A 403 is not unreachable.** The token is proven to authenticate before any
  cable is fetched; otherwise an auth failure presents as a fabric with no
  cables, indistinguishable from one that is not cabled. #125 is this
  confusion exactly: 2039 background builds 403'd for a service's whole
  lifetime while a health check read the 200 beside them as success.

## 5. What this does not yet prove

* **The node side of a rail attachment is observed from the switch only.** LLDP
  gives the leaf's view; the audit does not yet ask the GPU node what *it*
  sees on `rail8p2`. Both ends agreeing is strictly stronger.
* **`fabric_model._plane_rail` is still a name parser.** The SoT's `plane` and
  `rail` fields are recovered by splitting the device name rather than carried
  from the allocator that assigned them — a second derivation of one fact, with
  the authority resting on a string. W8 can only check that a loose parser
  agrees with a strict one. Carrying plane/rail on the device record, with
  `_plane_rail` demoted to a cross-check, is the real fix.
* **Nothing runs the fabric gate on a schedule.** It is a `deploy/checks/`
  gate, invoked by hand or by a stage; it is not yet a host phase in
  `tests/verify.sh`.

## 6. Three false findings this work produced before it was right

Recorded because each is a way an invariant checker lies with confidence, and
all three are now written into the code that made them.

1. **The shape was read from the growth envelope.** `backend_shape()` matched
   the first dict carrying `rails` and `planes`, which is
   `addressing.envelope`. At s0-64 the pod declares
   `leaves_per_rail_plane: 1` and the envelope declares 2, so every leaf came
   out one slot off: **31 "mislabelled device" findings** about a correct
   fabric. The envelope says how far the fabric may grow; it does not say what
   was built.
2. **The core tier was omitted entirely.** s1-512 has none, so an invariant
   written against s1 looked complete and then reported all **384** of s2's
   spine-core links as "a plane could not be read from a name". Cores are
   plane-agnostic by design.
3. **The core clause then required every core to be reached from every
   plane**, and s5-32768 "failed" it **192** times: with 192 cores, 48 uplinks
   and 4 spines per pod the round-robin partitions exactly, so each core serves
   one plane — which for a dual-plane fabric is plane separation preserved to
   the core. **Requiring the merge was requiring a defect.**

The rule that came out of (3): **assert the derivation, report the
consequence.** The check now compares the exact multiset the model's own
formula produces and *reports* the plane merge as an observation — which is how
we know the core layer **merges planes at s2–s4** (0 of 6, 0 of 16, 0 of 39
single-plane cores) and **separates them completely at s5** (192 of 192).
Neither shape is a free choice; both fall out of `cores_n` against the fan-out.

A fourth, from the box layer: **"43% of assigned switch ports do not exist on
any platform"** — raised, then withdrawn. It compared catalog-lane names
against VS-native names, the same category error the audit's translation step
exists to avoid. There is no such defect, and the renderer already refuses the
real version of it loudly.
