# S2 baseline on gpufab-s11-fabric — the host is too small. Measured, not inferred.

**Date:** 2026-09-11
**Host:** `gpufab-s11-fabric` (10.10.0.58), n2-highmem-64 — 64 vCPU, 503 GB
**Fabric:** s2-1024, 106 SONiC VMs, 3 units (dc1-pod001, dc1-pod002, core)
**Outcome:** build REFUSED as unsupportable on this host. Deployment preserved,
not torn down. Frozen S1 untouched throughout (read-only measurement only).

---

## 1. What was asked, and what the measurement did to the hypothesis

The bounded path was: stop the run without teardown; measure for at most 30
minutes whether CPU reaches a stable quiescent condition and whether re-serving
then completes ZTP; define a gate from those measurements using consecutive
CPU-idle samples plus switch readiness; permit exactly one clean rerun; and if
it saturates again, stop changing lifecycle code and move to a larger host.

The hypothesis under test was *transient synchronization* — that ZTP discovery
churn was self-sustaining while 106 QEMU VMs booted, and that the 2026-09-08
success owed to an accidental ~20-minute settle gap.

**The measurement falsified it outright, which is why steps 3 and 4 were not
executed.** Both presuppose that a settled state exists to gate on. It does not:

- **ZTP had already finished.** 104/106 devices fetched `config_db.json` (the
  ZTP servers' own logs — the only party that sees every request, and it needs
  no SSH). `ztp status` reads `Service: Inactive` on every device sampled.
  There is no discovery churn left to settle.
- **Re-serving cannot help.** The devices already hold their config. The failure
  is entirely downstream of ZTP.
- **The gate could never pass.** 20 consecutive samples, one per minute:

        idle%  = 0    on every sample, distinct value set across the window = {0}
        healthy = 112  flat
        config_db = 104/106  flat

  Zero forward progress and zero idle for the entire window. This is a **stable
  starved state, not a converging one**. A consecutive-CPU-idle gate on this
  host would wait forever.

Spending the permitted rerun would have bought a second copy of a result 20
samples already establish, at ~2.5 hours of build.

## 2. `18/106` was a measurement artifact, not ZTP's state

The gate failed reporting `18/106 SUCCESS, 29 pending, 59 unreadable`. That
number never described the fabric.

`deploy/ztp_wait.sh` polls **serially**, one SSH per device, trying **two**
passwords at `ConnectTimeout=10` each. An unreadable device therefore costs 20s.
With 59 unreadable, a single sweep costs ~20 minutes — so within the 1800s
budget the waiter completes roughly **one pass**, and reports first-pass counts
as if they were current. The true figure at that moment was 104/106.

This is §3 in the other direction: a check that reported a number it had not
actually measured. Recorded here; not repaired in this run (see §6).

## 3. The real failure, with the daemon naming its own cause

    host oversubscription
      -> guest CPU starvation
      -> swss dead or never started
      -> no orchagent
      -> 0 of 39 ports programmed
      -> every BGP peer stuck in Active
      -> 0 sessions

Evidence at each link, measured on the boxes:

**Starvation, from FRR's own log** on `dc1-pod001-bk-p1-r1-leaf01`:

    bgpd: [EC 100663315] Thread Starvation: {... timer r=-10.493
          (bgp_connect_timer)() ...} was scheduled to pop greater than 4s ago

The BGP connect timer fired **10.5 seconds late**. Guest-side idle: 0%.

**swss, sampled across 12 devices:**

    exited x5   created x3   running x1   unreadable x3
    ports up = 0 on every readable device

`created` is the decisive state — the container was never able to start at all.

**Peer states:** `{'Active': 34}` — all 34, none past Active. With 212 neighbor
lines configured. Some devices had `BGPCFG=0` (D8's frr.conf stub) as well; that
is a separate known fault and was never reached, because the gate failed first.

**S1 reference, same machine type, read-only:**

    swss=running  syncd=running  ports up=39   83% idle   load 24   1464/1464 BGP

Same image, same render path, same containerlab version. The only variable is
density.

## 4. The two calibration points

Both on n2-highmem-64 (64 vCPU, 503 GB):

| | VMs | VM/vCPU | guest RAM | idle | load | swss | ports | BGP |
|---|---|---|---|---|---|---|---|---|
| **S1** `gpufab-fabric-01` | 48 | **0.75** | 192 GB (0.38) | 83% | 24 | running | 39/39 | 1464/1464 |
| **S2** `gpufab-s11-fabric` | 106 | **1.66** | 424 GB (0.84) | **0%** ×20 | 263 | dead | 0 | **0** |

0.75 is proven good. 1.66 is proven fatal. Nothing between them is measured.

**Guest RAM was not the discriminator** — S2 sat at 0.843 of MemTotal, just
under a 0.85 bound. Had capacity been judged on memory it would have passed.
CPU density is what separates the two, and it is the only thing that does.

At S1's proven density, 106 VMs need **≥ 142 vCPU**.

## 5. What landed

Both pushed to `skywalkerbob/aifab_platform`, source and tests separately:

- `41fa9b8` `deploy/checks/host-capacity.sh` — read-only precondition. Counts
  `kind: sonic-vm` from the topology that will actually be deployed (one
  derivation, the same rule `gen_topology` documents for `switch_count()`),
  reads the host's real vCPU/MemTotal, refuses above the bound, and states the
  remedy rather than only refusing. Zero, non-numeric, unreadable or
  switch-free input is VOID, never a pass. Validated against **both real
  hosts**: exit 0 / `VERDICT: OK` on S1, exit 1 / `VERDICT: REFUSE` on S2 with
  `106 VMs needs >= 142 vCPU`.
- `0318e5b` `tests/t97-host-capacity.sh` — 21 assertions, host-free, registered
  in `verify.sh` as phase `host-capacity`. Asserts the check *discriminates the
  two measured points*, not merely that it runs. Test-the-test, both RED: a
  check whose `rc=1` becomes `rc=0` fails 4 assertions; one that reads an
  unmeasured count as zero fails 3.

The cost asymmetry is the point: this defect took ~2.5 hours of build plus two
30-minute timeouts to surface. The check decides it in the time it takes to read
`/proc/cpuinfo`.

## 6. Open, recorded not fixed

- ~~`ztp_wait.sh` serial polling~~ — **FIXED and pushed** (`d08f606`, test
  `c7e14e4`). Sweeps now run concurrently (`GPUFAB_ZTPWAIT_PAR`, default 32):
  measured 12 probes x 1s in 1s vs 12s serially. The credential is derived once
  **by measurement** and never assumed, SUCCESS is counted rather than inferred
  by subtraction, and a sweep that does not account for every target is refused
  rather than reported. `tests/t98-ztp-wait.sh`, 24 assertions, host-free.

  This was fixed despite the lifecycle-code freeze because it is not a timing
  tweak chasing the settle hypothesis — it is a check that reported numbers it
  had not measured, which is the one thing §3 does not permit to stand. It is
  also needed on any host: even with every device readable, a serial sweep at
  106 devices costs minutes.

  Two of t98's assertions failed on first run against the new implementation and
  found two real defects in it: the credential was **assumed** when only one
  candidate existed, which made an authentication failure indistinguishable from
  a dead device — the waiter would blame the fabric for its own inability to log
  in — and the resolution was never reported at all. Both fixed before the
  commit landed.
- **2 devices never fetched config_db**: `dc1-pod001-bk-p1-r5-leaf01`
  (172.28.0.48), `dc1-pod001-fr-leaf01` (172.28.0.76). Cause unexamined — on a
  starved host it is not separable from the general failure.
- **D8** still present on some devices (`BGPCFG=0`). The reconciler that repairs
  it never ran, because `ztp_wait` gated first.
- **D2** remains open from the S1 regression; unrelated to this run.

## 7. State left behind

`gpufab-s11-fabric` is **RUNNING with the deployment preserved** — 267
containers, 112 healthy, 3 ZTP servers up, NetBox local at
`http://10.10.0.58:8000` (258 devices / 3332 cables). Nothing was torn down.
`gpufab-s11-ops` remains TERMINATED with its disk preserved (`autoDelete=False`).

**Frozen S1 was never mutated.** Every S1 interaction in this run was a
read-only measurement (`nproc`, `/proc/meminfo`, `docker inspect`,
`show interfaces status`).

The next decision — resize or re-scope — is a spend decision and is the
operator's. It is stated with costs in the session; nothing here presumes it.

---

## 8. The resize (2026-09-12) — and two things it found

Authorized: n2-highmem-128, rerun with the gate. What actually happened:

**Three stockouts.** `n2-highmem-128`, `n2-standard-128` and `c3-standard-176`
are all unavailable in us-central1-a. This is the single-zone stockout risk that
has been on the open list; it is now a realised cost, not a hypothetical.

**n2d-standard-128 started and was REJECTED.** 128 vCPU, 504 GB, docker up,
disk intact, load 0.12, 100% idle — and `/dev/kvm` **absent**, no SVM flag. GCP's
nested virtualisation here is Intel-VMX only, so on AMD the SONiC guests would
have fallen back to TCG emulation. The host looked perfect and could not run a
single switch. Caught by an explicit `/dev/kvm` check BEFORE building; had the
rebuild simply been launched, 106 VMs would have crawled under emulation and the
symptom would have looked like something else entirely. The acceptance test for
a candidate host is therefore `/dev/kvm` on the booted machine — never the
support matrix, never the machine type's name.

**Accepted: `m3-megamem-128`** — 128 vCPU, 1921 GB, Intel Xeon, `kvm_intel`
loaded, VMX present. Density 106/128 = **0.828**, RAM 424/1921 = 0.22. More
expensive than the n2 plan (memory-optimised), and chosen because it is what has
capacity and passes the only test that matters.

**The host was never hardened.** `--assert` REFUSED on first contact:
networkd-dispatcher unmasked (D7) and the systemd-networkd unmanaged drop-in
missing (D9). `gpufab-s11-fabric` was built outside `a4-host.sh`, and the
hardening existed ONLY inside that script's VM-creation startup script — so it
had neither, while running an S2 build with systemd-networkd managing all 405 of
its containerlab veths and bridges. That is the configuration that on 2026-09-07
took a host's own networking down mid-build and left sshd dead while the
instance stayed RUNNING. It did not fire this time; that is luck, not safety.

Fixed at the root: `deploy/host_harden.sh` is now the single definition of D7+D9,
and `a4-host.sh` EMBEDS it rather than restating it (`19cb260`, test `f480ba6`,
20 assertions). Its `--d7`/`--d9` steps initially returned 0 while `systemctl
mask` failed silently behind `|| true` — a step that did not happen reporting
success, on the path that decides whether a host is safe to build on. They now
fail unless systemd confirms the state changed.

**Disk survived the machine-type change intact**: all four plan/profile
checksums identical to pre-stop, 106 config_db artifacts present, NetBox back at
**258 devices / 3332 cables** — the pre-resize numbers. Postgres was stopped
explicitly before power-down rather than trusted to the ACPI path.

**The gate is now IN the build path** (`c2f173d`, test `e06e1cf`), not a wrapper
someone remembers to run — the 2026-09-11 build had every ingredient of the
check available and simply never asked. On the rebuild it counted 48+48+10 = 106
`sonic-vm` nodes from the generated topologies and passed at 0.828 before
anything booted.

### 8a. Two things the rebuild itself found

**The ZTP servers are outside the ownership engine.** `ztp_serve_units.sh`
creates `c12-ztp-<unit>` as plain docker containers, so they carry no
containerlab label and no ledger entry. After the host reboot they RESTARTED on
their own, held the three `c12-oob-*` networks open, and `c12 --recover` then
failed with `network:c12-oob-core is PRESENT after cleanup — expected ABSENT`:
the engine had correctly adopted and released everything it owned, and could not
account for the thing it does not. Removing the three containers by hand let
recovery complete cleanly (`adopted 3 ledger entry(ies)`, `VERDICT: OK`).

Open, not fixed: the servers c12 creates should be ledger resources like its
labs, networks and bridges, or a reboot will block the next build every time.

**Do not destroy outside the ownership engine.** The first rebuild attempt
destroyed the stale labs with `containerlab destroy` directly, and c12 then
refused in five seconds with eight `ledger holds X but nothing was acquired or
adopted for it` failures — the engine working exactly as designed. `--recover`
is the documented drain and existed for precisely this; reaching past it turned
a one-command recovery into a debugging detour. The fix was to use the committed
path, not to force past it.

## 9. Result — S2 is up on the resized host

`c12 VERDICT: OK`, `RUN COMPLETE rc=0`, **post-provision gate PASS on all three
units**. Wall clock **~19.5 minutes** (04:51:39 -> 05:11:07 UTC), against the
2.5 hours the previous attempt spent failing.

The capacity gate ran inside c12, counted 48+48+10 = 106 `sonic-vm` nodes from
the generated topologies, and passed at **0.828 VM/vCPU** before anything booted.

**ZTP: 106/106 SUCCESS, 0 failed, 0 unreadable.** Sweep times **11s, then 2s, 1s**
— the concurrent waiter doing what it was built for; the same sweep cost ~20
minutes before the fix, which is why the old run reported `18/106` about a fabric
that was at 104/106.

**EVPN reconcile: 0 failed** across all three units. **t92: 15/15 on dc1-pod001,
15/15 on dc1-pod002**, core correctly NOT APPLICABLE — including on-box EVPN
tables equal to their rendered artifacts, every configured peering established,
remote-VTEP counts matching each EVPN domain, tenant dataplane forwarding, and
the negative control firing.

Measured across all 106 devices afterwards, in parallel, 0 unreadable:

| | before (64 vCPU) | after (128 vCPU) |
|---|---|---|
| swss running | 1 of 12 sampled | **106 / 106** |
| Ethernet ports oper-up | 0 | **3882** |
| BGP sessions Established | 0 | **1144** |
| EVPN sessions Established | 0 | **32** |
| devices unreadable | 3 of 12 | **0** |
| load / idle | 263 / 0% | **24.5 / 83%** |

The host now sits at **load 24.5, 83% idle** — the same profile as healthy S1
(load 24, 83% idle). Same fabric, same code, same images; only the vCPU count
changed. That is the diagnosis confirmed from the other side.

Note on the totals: 1144 BGP and 32 EVPN are MEASURED counts, not model-derived
expectations. The model-derived acceptance is t92, which passed per unit against
`fabric_model`; these two numbers are recorded as observations and should not be
treated as a target until `expected.py` derives them.

