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

## What this does NOT establish

* **Multi-unit serving is unproven.** This is one unit, one ZTP server. S2 has
  three units, each with its own management subnet and its own server, and
  nothing here demonstrates three of them running at once.
* **The tenant dataplane check did not cross a remote VTEP.** Within one unit
  the hosts are dual-homed to both of that unit's VTEPs, so the path exercises
  the VLAN, the anycast gateway and the leaf pair. Remote-VTEP visibility is
  covered by the separate assertion; a cross-VTEP forwarding path needs a
  second unit and is not claimed.
* **Scale is unproven.** 16 switches, not 258.

## Open, recorded rather than fixed

`deploy/46-mgmt-isolation.sh:42,66` match `172.20.0.*` as literals — the same
class of defect as the dnsmasq range. A unit on any other subnet silently gets
no isolation rules and no error. Not touched: it is outside D6 and outside the
unit contract this work was scoped to.
