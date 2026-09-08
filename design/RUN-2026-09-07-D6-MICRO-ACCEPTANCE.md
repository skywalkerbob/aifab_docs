# RUN 2026-09-07 — D6 closed on one unit, via the product ZTP path

Immutable record. Host `gpufab-a4-01` (disposable, n2-highmem-32, us-central1-a).
Unit `dc1-pod001` of `tests/fixtures/micro-2pod.yaml`, relocated to
`mgmt_supernet: 172.28.0.0/22` so nothing could collide with a real fabric.

**S1 was not touched.** Every command in this run addressed `gpufab-a4-01`.
No S1 host was contacted, and the frozen pins are unchanged.

## What D6 actually was

D6 was diagnosed twice before and both diagnoses were wrong. It was not
artifact delivery (that was a prerequisite, fixed separately), and not
`deploy_switch`'s second derivation. It was **two defects in the served ZTP
tree**, each of which leaves the server reporting itself healthy:

1. **`ztp/oob/dnsmasq.conf` carried `dhcp-range=172.20.0.0` as a literal** —
   a second derivation of the management network, correct for exactly one unit:
   S1's. On a unit at 172.28.0.0/24 every DISCOVER got

       dnsmasq-dhcp[1]: no address range available for DHCP request via eth0

   sixteen times, while `serve.sh` printed `http OK` and `serving 16 device
   configs; DHCP opt67 live`. Both halves are true in isolation — HTTP works,
   the artifacts exist — and nothing asserted that a DISCOVER is ever
   *answered*.

2. **The per-unit render emitted device directories but not
   `identity_guard.sh`**, which every `ztp.json` references. Once DHCP worked,
   all 16 switches leased, fetched `ztp.json` 200, fetched `/identity_guard.sh`
   404, and stopped — none reached `config_db.json`.

       172.28.0.41 - - "GET /dc1-pod001-bk-p1-r2-leaf01/ztp.json" 200 -
       172.28.0.41 - - "GET /identity_guard.sh" 404 -

Neither is about EVPN, BGP, or the fabric. Both are the served tree failing to
be something a switch can complete against, and both present from outside as
"the switches are still booting". That is why the 2026-09-06 S2 run reported
`l2vpn evpn peers: 0 / 0 established` with every stage green.

The DHCP diagnosis is confirmed by response time, not by reasoning: after
re-serving with the corrected range, **DHCPACKs appeared within 3 seconds** —
the switches had been retrying the whole time.

## What was changed

Source (`gpufab-platform`, branch `ztp-unit-path`, not pushed):

* `tools/fabric_model.py` — `management_units()` locates its own sibling
  `gen_topology`, instead of requiring every caller to put `clab/` on
  `sys.path`. Two callers each carried a private copy of that path; a third
  (serve.sh, through the renderer) got `ModuleNotFoundError`.
* `tools/unit_ztp.py` — drop-in for serve.sh's render slot, so the unit path
  keeps serve.sh's staging, completeness check and safe swap rather than
  writing into a live tree. Renders `dnsmasq.conf` from the unit's own subnet,
  emits `identity_guard.sh` from `R.IDENTITY_GUARD_SH`, and refuses a tree in
  which any `ztp.json` names a file the tree does not contain.
* `ztp/oob/serve.sh` — prefers the rendered per-unit `dnsmasq.conf`, falls back
  to the static one, and **refuses to start when the DHCP range does not
  contain the server address**. One comparison before anything boots, instead
  of thirty minutes waiting for leases that cannot arrive.

Tests: `t92-unit-evpn-acceptance.sh` (on the boxes), `t93-ztp-tree-complete.sh`
(render time, no fabric), both registered in `verify.sh` in the same commit —
the file's own note records t88/t89 having been committed unregistered, and
that mistake was repeated here before being caught.

## S1 is unaffected, checked rather than assumed

S1 renders through `render_fabric_ztp.py`, which produces no `dnsmasq.conf`, so
serve.sh takes the static conf exactly as before. The new guard was evaluated
against S1's own numbers:

    static range 172.20.0.0/24, S1 dc1-pod001 derived ZTP address 172.20.0.4
    guard verdict: ACCEPT

`unit_ztp.py` renders pod001's range as
`dhcp-range=172.20.0.0,static,255.255.255.0,12h` — character for character what
the static file holds.

## Acceptance, measured on the boxes

`t93` (served tree, three units of micro-2pod): **7 passed, 0 failed**, with a
negative control that removes `identity_guard.sh` from a rendered tree and
requires the scanner to report it.

Test-the-test: `t93` run against `unit_ztp.py` from before the fixes (719ba23),
with the sibling repos in place — **13 FAIL**: `identity_guard.sh` missing on
3/3 units, `dhcp-range` unservable on 3/3, and the dangling scan reported
UNMEASURED rather than clean because the function did not exist.

`t92` (unit `dc1-pod001`, 16 switches ZTP-provisioned, sample 4):
**12 passed, 0 failed.**

    on-box EVPN tables vs rendered artifact   equal on 2/2 VTEPs
    EVPN peerings configured                  4  (a zero denominator FAILS here)
    EVPN peerings established                 4 / 4
    remote VTEPs per VTEP                     1, and the model derives 1
    tenant dataplane                          gpu0001 -> gpu0002 (172.28.0.57) forwards
    negative control                          a corrupted VXLAN_TUNNEL IS detected

ZTP itself: 16/16 DHCPACK, 16/16 `ztp.json`, **16/16 `config_db.json`** fetched
from the unit's own derived address 172.28.0.4.

## A defect found in the test, not the fabric

The first `t92` run reported `EVPN peerings CONFIGURED: 0` — D6's exact
signature — on a switch that in fact had two Established EVPN neighbours
exchanging prefixes. `show bgp summary json` nests peers under an
address-family key; `show bgp l2vpn evpn summary json` puts `peers` at the
root. The reader only handled the nested shape.

A RED result about a healthy fabric is the same class of misreport as a false
green, and costs the same to chase — it aims the next diagnosis at EVPN
activation when the defect is in the reader. The fix also splits two facts the
first version conflated: a body that will not parse is UNREADABLE, while a body
that parses with no peers key is a MEASUREMENT OF ZERO, which must fail the
count rather than be laundered into "unreadable".

## Multi-unit run, same day — three units, three servers

`c12 --ztp` (new mode: skip the interim push, serve instead) built all three
micro units and `deploy/ztp_serve_units.sh` served one ZTP server per unit at
that unit's own derived address.

**All 38 switches self-provisioned**, from three separate servers:

    dc1-pod001  ack=48  config_db fetched by 16/16
    dc1-pod002  ack=48  config_db fetched by 16/16
    core        ack=18  config_db fetched by  6/6

That closes "multi-unit serving is unproven". It required two fixes found by
the run itself:

* **The core shard's derived ZTP address was a switch.** `mgmt_infra()` lays out
  a POD's subnet, where devices start above the reserved low addresses; a core
  shard's devices start at .2, so the pod-shaped .4 was
  `clab-c12-core-dc1-ba-core003`. Docker refused with `Address already in use`
  — the good outcome; had the server won that race a switch could not have
  taken its own management address. Core shards now take addresses from their
  own subnet (`.252`), pods are unchanged, and t91 asserts no device holds its
  unit's gateway/tacacs/ztp address (21 pairs across micro, S1 and S2).
* **The unit-address check was a race, not a check.** A single probe moments
  after `docker run` reported "does NOT answer" for a server whose dnsmasq was
  already sending the correct opt67 URL. Bounded retry; "not up yet" is not
  "does not answer".

t92 per unit, with all three deployed:

    dc1-pod002   13 passed  0 failed
    dc1-pod001   12 passed  3 failed   (see D8 below)
    core          1 passed  0 failed  1 skipped — NOT APPLICABLE, no VTEPs

The expectation itself had to be corrected first, and this is worth recording
because the wrong version was mine: t92 expected every VTEP to see every other
deployed VTEP. `features.evpn` names the transits for micro-2pod as the two POD
frontend spines — not the core — so the overlay is **one domain per pod** and
each VTEP has exactly one peer VTEP. The original expectation asserted a
fabric-wide domain nobody declared and failed dc1-pod002, which was correct.
The expectation is now the connected component over {vteps + transits} in the
model's own links.

## D8 (new, NOT D6): a VTEP whose FRR has no EVPN address-family

`dc1-pod001-fr-leaf01` ended the run with its EVPN **config_db correct and
identical to its working pod-mate** — same 31 tables, same key counts, differing
only in `bgp_asn`, `hostname` and `mac` — while its FRR carried no
`address-family l2vpn evpn` at all. Its peer sees it as `NoNeg`; `show evpn vni`
returns nothing; both its VNIs show 0 remote VTEPs.

Neither `systemctl restart bgp` nor `config reload -y -f` changed it.

So the defect is BELOW config_db, in SONiC's own generation of FRR config from
it, and it is intermittent: 1 of 4 VTEPs in this run, 0 of 4 sampled in the
single-unit run, both pod002 VTEPs fine. It is not a gpufab derivation gap and
not D6, and chasing it further is a SONiC investigation rather than a
management-unit one.

t92 caught it. The VXLAN-table comparison passed — correctly, the tables ARE
right — and the remote-VTEP assertion is what failed. That is the layer
argument working in the intended direction for once.

## What this does NOT establish

* ~~Multi-unit serving is unproven~~ — closed above: 38/38 across three units
  and three servers.
* **The tenant dataplane check did not cross a remote VTEP.** Within one unit
  the hosts are dual-homed to both of that unit's VTEPs, so the path exercises
  the VLAN, the anycast gateway and the leaf pair. Remote-VTEP visibility is
  covered by the separate assertion; a cross-VTEP forwarding path needs a
  second unit and is not claimed.
* **Scale is unproven.** 38 switches across three units, not 258.
* **Cross-VTEP forwarding is still not asserted.** The model puts each pod's
  VTEPs in their own EVPN domain, so there is no cross-pod overlay path in this
  topology to test. The tenant check remains within-unit.
* ~~The source was the PROFILE, not NetBox~~ — CLOSED 2026-09-08, see below.
* **(original text)** **The source was the PROFILE, not NetBox.** `unit_ztp.py` calls
  `render_bundle(profile, devices, server=...)` — the same renderer the product
  path uses, so there is no second rendering authority, but a different SOURCE.
  S1 renders from NetBox as SoT. This run therefore proves
  profile -> ZTP -> box, and says nothing about NetBox -> ZTP -> box. Whether
  the unit path should read NetBox is a design question outside D6 and is not
  answered here.

## D9 — systemd-networkd takes the HOST down at S2 scale (found, fixed, unproven)

The first full-S2 attempt through the ZTP unit path reached **258 containers and
106/106 healthy switches** and was then lost, not to the fabric but to the
host's own networking — the same ending as D7, with networkd-dispatcher
verified `masked` for the entire run.

From the serial console (the instance stayed RUNNING throughout, sshd simply
stopped answering):

    09:03:23  systemd-networkd[1208]: br9b56d183cc69: Link DOWN
    09:03:27  google_guest_agent: dial tcp 169.254.169.254:80:
              connect: network is unreachable

2240 systemd-networkd events across **400 distinct clab bridges** plus several
hundred veths. D7's own comment records that systemd-networkd "is a DIFFERENT
unit and is untouched by this" — which is exactly why masking the dispatcher
was necessary and not sufficient. At S2 scale the other unit becomes the
storming party.

Fix (`a4-host.sh`, beside the D7 mask): a systemd-networkd drop-in matching by
**driver** — `veth` and `bridge` — with `Unmanaged=yes`. Matching by driver
rather than name is deliberate: those are precisely the devices containerlab
creates and never the primary NIC (gvnic/virtio_net on GCE), whereas a glob
like `eth*` could strand the host, and a host stranded by its own guard is
worse than the storm it prevents.

Readiness REFUSES unless the drop-in is present AND networkctl reports every
veth/bridge unmanaged — the effect, not the file — because a host where this
silently failed to land is indistinguishable from one where it landed, right up
until a build dies unreachable and cannot report why.

Measured on the replacement host:

    bridge state : off (unmanaged)
    veth state   : off (unmanaged)
    ens4 state   : routable (configured)

**D9's fix is verified at the mechanism and NOT yet at S2 scale.** A second full
S2 run is what would establish that, and until it completes, "S2 through the ZTP
path" remains unproven. What the lost run does establish, independently of D9,
is that the unit path builds 258 devices and 106 healthy switches on one host.

## Open, recorded rather than fixed

`deploy/46-mgmt-isolation.sh:42,66` match `172.20.0.*` as literals — the same
class of defect as the dnsmasq range. A unit on any other subnet silently gets
no isolation rules and no error. Not touched: it is outside D6 and outside the
unit contract this work was scoped to.


---

# Addendum 2026-09-08 — the SoT gap is closed and measured

`unit_ztp.py` now renders from **NetBox** as well as from the profile
(`--sot netbox|profile`, `GPUFAB_ZTP_SOT`), and `ztp_serve_units.sh` asks for
NetBox by default. `render_bundle()` always accepted both; only this caller was
missing.

A netbox render that cannot reach NetBox **REFUSES and renders nothing** — it
never falls back to the profile, because a silent fallback is the defect itself
and would leave a served tree indistinguishable from a correct one. The
connection is proven to answer before anything is rendered. The chosen source is
recorded in `_provenance.json`, so "where did this config come from" is
answerable from the artifact rather than from knowing which caller ran.

**Measured on a disposable host, no fabric booted.** NetBox seeded from
`micro-2pod.yaml` (stage 30 verified 50/50 devices, 222/222 cables), then the
same unit rendered both ways:

    device sets                    equal, 20 each
    artifacts present in both      68
    artifacts differing in CONTENT  0
    artifacts present under one     0

So `profile -> render` and `NetBox(seeded from profile) -> render` produce
byte-identical artifacts. The round-trip is faithful, which is what makes the
2026-09-07 S2 acceptance carry over to the NetBox path rather than having to be
re-run.

`tests/t94-sot-render-agreement.sh` asserts this and is registered in
verify.sh in the same commit. It SKIPs without a live SoT — comparing two
sources with only one available asserts nothing. **5 passed, 0 failed** against
live NetBox.

Two things this addendum does NOT claim: it is one unit of one fixture, not S2;
and it compares renders to each other, not to what a switch ends up running —
that join is t11's and t92's.

## And a host defect that cost two runs

`a4-host.sh` added the cloud-sdk apt repo unconditionally, signed by a key its
own keyring lacks (`NO_PUBKEY C0BA5CE6DC6315A3`). `apt-get update` still exits 0
— one broken source among working ones — so nothing failed there. It failed
later, in stage 00, which exits 100 and never creates `/opt/gpufab-venv`:

* the S2 build's three units rendered NOTHING ("served tree has no device
  directory to ask for"), because serve.sh runs its renderer with `$VENV/python`;
* the first SoT round-trip attempt refused at its first gate.

Both were initially diagnosed as something else. `gsutil` was on the image the
whole time, so the repo bought nothing. It is now skipped when gsutil is
present, removed again if it makes apt unusable, and **readiness refuses while
any apt source is unsigned** — verified on a fresh host: 0 unsigned sources,
repo not added, gsutil present.


---

# Addendum 2026-09-08 — D8 fixed, and what it actually was

D8 was recorded as "a VTEP whose FRR has no EVPN address-family despite correct
config_db, below config_db in SONiC's own FRR generation". That was right about
the layer and wrong about the cause. The cause was already written down in this
repository, in `deploy/56-evpn-persist.sh`:

> `docker_init.sh` takes the `[ -z "$CONFIG_TYPE" ]` branch on every bgp
> container start ... and `rm -f /etc/frr/frr.conf`

`ztp.json` delivers frr.conf in `00-download`, BEFORE `01-configdb-json` applies
the config. That ordering is correct and was measured both ways — the late
ordering is strictly worse ("the artifact is delivered perfectly and is dark").
But it only guarantees the file is on disk *before* the config; it cannot
guarantee the file survives, because **the deleter is the bgp container, not
ZTP**. If that container starts in the window between the two sections — file
present, routing mode not yet set — it deletes frr.conf through the bind mount
and `write_default_zebra_config` CREATES a three-line stub in its place.
Nothing fetches the real file again.

That is why the box survived `systemctl restart bgp` and `config reload -f`
unchanged: both restart a device whose frr.conf is a stub.

## The fix

`02-evpn-guard`, a ZTP plugin section for EVPN speakers only, running AFTER the
config. It asserts the OUTCOME on the device: wait 90s first (FRR is still
starting right after the reload, and an impatient guard would restart a healthy
device for nothing), repair only if the AF is still absent, then verify.

Three things the repair learned from being run against a deliberately broken
VTEP instead of reasoned about:

* **Present is not correct.** The failure state has frr.conf present and
  non-empty. An existence check refuses to repair a device it could fix. The
  condition is whether the file *declares* the AF.
* **Verify what arrived** before overwriting what is there, or a 404 body or a
  second stub gets installed and bgp restarted — success reported for a device
  with no overlay.
* **The management VRF is not optional.** These switches run
  `mgmtVrfEnabled=true`: plain `curl` returns 000 in 0 ms, `ip vrf exec mgmt
  curl` returns 200 for the same URL. A fetch that ignores it fails instantly
  and looks like the server is down. The first two versions of the guard were
  wrong in exactly these ways and the box said so.

## Verified

D8 reproduced **deterministically** rather than waited for: delete
`/etc/sonic/frr/frr.conf` and restart bgp, and the AF goes 1 -> 0 — the same
state observed on 2026-09-07.

    before guard : AF 0, frr.conf declares AF 0
    guard        : "address family restored", rc=0
    after  guard : AF 1, frr.conf declares AF 1,
                   EVPN peers 2 of 2 established, remote VTEPs 1 1
    second run   : "address family present", rc=0, device NOT restarted

The end state was measured independently of the guard's own report.

## Not claimed

The guard is proven against the reproduced failure and on the healthy path. It
has not yet run as part of a full provision (the fabric it was tested on was
provisioned before the guard existed), and the race it defends against is
intermittent, so a clean provision does not by itself demonstrate it fired.
`t93` asserts the guard is present and referenced; nothing yet asserts it RAN.
