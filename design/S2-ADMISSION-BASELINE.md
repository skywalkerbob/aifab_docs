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
| frozen trees | 6/6 match on `gpufab-s11-fabric` | declared constants at platform `20903f7` |
| profile | `69d1784928b2…` | declared `S2_PROFILE_SHA256` |
| NetBox devices | 258 | `expected.py devices_total` |
| NetBox cables | 3332 | `expected.py cables` |
| sonic-vm nodes | 106 (48+48+10) | switch set the probe targeted |
| ZTP | **106/106 SUCCESS** | devices manifest R names |
| EVPN speakers with l2vpn AF | **10/10** | D8 postcondition |
| switches unreadable | 0 | — (nonzero refuses) |
| underlay CONFIGURED | **3728** | `expected.py bgp_peer_series` |
| underlay ESTABLISHED | **3728** | `expected.py bgp_peer_series` (all of it) |
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

## 2. FIXED 2026-09-14 — switch-to-host BGP (was a declared deficiency)

**This was wrong to record as a waiver, and the verdict was wrong to be ADMIT.**
A gate cannot admit "S2" while 2616 sessions the model derives are knowingly
absent: pinning a deficiency records what is broken, it does not make the fabric
admissible. `admit-s2` now requires every derived session Established, and it was
proven NOT-ADMIT against the unfixed fabric first —
`REFUSE underlay 1112/3728 — 2616 absent`.

**The cause, traced to source.** `c12 --ztp` skipped the push configurer —
correct for SWITCHES, since a switch with a startup config never runs ZTP — and
that skip also dropped the HOST nodes, which nothing else configures:
`unit_configure.py:187` routes every node that is not `kind: sonic-vm` to
`interim_deploy.deploy_host`, and `gen_topology.py:517` launches host nodes with
`cmd: "sleep infinity"` commented *"daemons are started by the deploy tooling"*.
So FRR never started in one gpu/cpu/storage container.

**The fix restores that delegated path and nothing else** (`d1883d8`, test
`20903f7`):

- `unit_executor` records each unit's `sonic-vm` set from the **topology's own
  `kind`** — the field containerlab dispatches on and gen_topology wrote — so
  "is this a switch" has one derivation and cannot drift from a name.
- `configure_targets(hosts_only=True)` subtracts that set from R's `configured`.
  The set is R's **minus** switches, so a host R does not name is still never
  touched.
- Selecting 0 devices REFUSES (rc=2) and never calls the configurer.
- `sonic_push_refusal` states the same rule **independently at the push**, so the
  two derivations disagreeing is a refusal rather than a silent second writer on
  a box ZTP is already provisioning.
- A host that fails, is unreadable, or raises **fails the run** (rc=1).
- `t100`, 16 assertions, host-free (driver and push both faked). RED control:
  removing the subtraction fails 5 assertions and the switches leak into the set.

**Applied in place, no rebuild** (`tools/configure_hosts.py`, which adds no logic
— same `configure_targets`, same `interim_push` — and touches no ownership
ledger, because configuring a host daemon is not a resource lifecycle
operation). 148 host devices: 258 total − 106 switches − the 4 R lists as
unconfigured. `configured 148 device(s)`, rc=0, ~11 minutes.

**Result, measured on all 106 switches:** underlay **3728/3728 Established**,
**0 switches with any session down**, EVPN 32/32, hosts peering
(`gpu0001` 20/20, `cpu0001` 3/3).

**The pin was re-taken at `20903f7`** (`0232216`) because the fabric's behaviour
legitimately changed: `deploy/` and `tools/` moved, `clab/` and `monitoring/` did
not — which is what a behavioural freeze is supposed to show. Re-pinning is how
the old baseline is retired; widening a tolerance is not.

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
