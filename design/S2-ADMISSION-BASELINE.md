# S2 admission baseline — established 2026-09-13

`gpufab-platform/tests/admit-s2.sh` is the standing admission target for the S2
fabric. It is a **separate entry point**, deliberately not a branch inside
`verify.sh`: the default suite judges S1, and a suite that silently changes
which fabric it judges is #129 with extra steps.

Run it before any S2 experiment:

    bash tests/admit-s2.sh              # ADMIT / REFUSE / UNKNOWN
    bash tests/admit-s2.sh --self-test  # negative control

It is READ-ONLY on both fabrics. The S1 leg calls `admit-experiment.sh`, which
is read-only by its own contract; **no S1 operation is performed, only a read.**

---

## 1. The baseline

Established from the `c12 --ztp` run of 2026-09-12 that ended `RUN COMPLETE
rc=0` with the post-provision gate PASS on all three units, and measured again
on 2026-09-13 at admission.

| leg | measured | compared against |
|---|---|---|
| frozen trees | 6/6 match on `gpufab-s11-fabric` | declared constants at platform `e06e1cf` |
| profile | `69d1784928b2…` | declared `S2_PROFILE_SHA256` |
| NetBox devices | 258 | `expected.py devices_total` |
| NetBox cables | 3332 | `expected.py cables` |
| sonic-vm nodes | 106 (48+48+10) | switch set the probe targeted |
| ZTP | **106/106 SUCCESS** | devices manifest R names |
| EVPN speakers with l2vpn AF | **10/10** | D8 postcondition |
| switches unreadable | 0 | — (nonzero refuses) |
| underlay CONFIGURED | **3728** | `expected.py bgp_peer_series` |
| underlay ESTABLISHED | **1112** | `bgp_switch_switch_sessions` × 2 |
| EVPN CONFIGURED | **32** | `evpn_bgp_sessions` × 2 |
| EVPN ESTABLISHED | **32** | == configured |
| VTEPs with a VNI | **6** | `expected.py evpn_vteps` |
| t92 | 15 / 15 / 1 per unit | committed acceptance, tenant dataplane asserted on both VTEP-bearing units |
| S1 | **ADMIT** | `admit-experiment.sh` |

Nothing here is compared to a previous measurement. Every number is checked
against a declared constant or a value `tools/expected.py` derives from the
profile the fabric was actually built from.

**Sessions vs endpoints.** The model derives SESSION counts; switches report
ENDPOINT counts, and a switch-to-switch session is seen by both ends. The factor
of two is written into the gate rather than buried in a constant.

## 2. The declared deficiency — switch-to-host BGP

**2616 of 3728 underlay sessions are configured on the switch and dead on the
host side.** Pinned by identity; the gate prints it every run and REFUSES if the
number moves in either direction.

Cause, traced to source:

- `c12 --ztp` prints *"switches will self-provision; NOT running the push
  configurer"* and never passes `--configure`.
- `tools/unit_configure.py:187` routes every node that is **not** `kind:
  sonic-vm` to `deploy_host` — so the push configurer is the **only** thing that
  starts daemons on host nodes.
- `clab/gen_topology.py:517` emits host nodes with `cmd: "sleep infinity"`,
  commented *"daemons are started by the deploy tooling"*, which overrides the
  `gpufab-host:1.0` image's own `Cmd` of `/usr/lib/frr/docker-start`.

So in ZTP mode FRR never starts in the gpu/cpu/storage containers. Confirmed on
the boxes: `neighbor 10.128.0.0 … description dc1-pod001-gpu0001` sits in
`Active`, and those containers have no `bgpd` and no `frr.conf`.

**S2 has never had a run where both layers were correct.** The 2026-09-06 push
run reached 3728/3728 underlay (t92's own header records it) but reported EVPN
`0/0` — that was D6. The ZTP path fixed the overlay and lost the host underlay.
Neither path has produced a complete fabric.

**This is recorded, not tolerated.** Until it is fixed, S2 experiments must not
depend on switch-to-host BGP. Remove the pin when host nodes are configured — do
not widen it.

## 3. What this found about the 2026-09-12 report

That run was reported as "S2 is up" on the strength of 1144 established sessions
— a raw count with no configured total and no derived expectation beside it. The
derived comparison shows what it should have been: 3728 configured, of which
only the 1112 switch-to-switch endpoints came up. **A measurement is not an
expectation**, and the gap between them is exactly what this gate exists to
make visible.

## 4. Two defects found in the gate by running it

- The workstation key filter was `^[a-z_]+=`, silently dropping every key
  containing a digit or hyphen (`profile_sha256`, `topo_sonic_dc1-pod001`). It
  reported UNKNOWN rather than passing — the right failure — but the filter was
  wrong.
- The D8 leg counted lines in `/etc/sonic/frr/frr.conf` and called ≤5 a stub.
  These switches run `frr_split_mode` and have **no** `frr.conf` at all (config
  lives in `bgpd.conf` 1060 lines / `zebra.conf` 1982), so `wc` failed to 0 and
  all 10 EVPN speakers were reported stubbed **while EVPN was 32/32
  established**. It now asserts the outcome — the `l2vpn evpn` address-family,
  whose loss is D8's actual symptom — which is config-mode independent.

A false RED costs what a false green costs.
