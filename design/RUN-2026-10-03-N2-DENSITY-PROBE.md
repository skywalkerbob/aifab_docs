# n2-standard-80 density probe — one S3 pod QUALIFIED at 50 VMs / 80 vCPU

**Date:** 2026-10-03 (runs 1-8); header corrected 2026-10-05
**Question:** may one S3 pod be carried by a single `n2-standard-80`?
**Host:** `gpufab-n2probe-01`, n2-standard-80, us-central1-a, disposable, TTL 4h
**Fixture:** `tests/fixtures/n2probe-1pod.yaml` — one s3-4096 pod
**Derived target:** 50 switch VMs, 2266 BGP peer series, 0.625 VM/vCPU
**Outcome (run 8):** **PASS** — 50/50 VMs healthy, 2266 configured and 2266
established counted per-switch on the boxes, 0 unreadable, swap 0, t92 PROVEN
15/0, c12's own verdict OK, teardown VERIFIED. S1 and S2 untouched throughout.

**Scope of the result:** this qualifies the **0.625 operating point**
(50 VMs / 80 vCPU) for one S3 pod. It does **not** establish the 0.75 VM/vCPU
boundary, which remains supported by the separate S1 calibration (48 VMs / 64
vCPU); nothing in these eight runs probed the region between 0.625 and 0.75.
It says nothing about the cross-host path — see §9.

Runs 1-7 each ended on a defect rather than a finding; §§2-7 keep that record
because the defects are the useful part.

---

## 1. What is settled, and what is not

| | |
|---|---|
| nested KVM on n2-standard-80 | **PASS** (runs 3, 5) — `/dev/kvm` 660 root:kvm root-writable, `kvm_intel` loaded, KVM accelerator |
| the NOS image on a fresh host | **PASS** (run 5) — stage 10 loads `vrnetlab/sonic_sonic-vs:202505-ztp` from the GCS cache, 9.04 GB, confirmed by `docker image inspect` |
| the arithmetic floor | **PASS** — 50 VMs on 80 vCPU is 0.625 VM/vCPU, inside the 0.75 bound; 200 GB of guest RAM is 0.637 of MemTotal against 0.85. Being inside the bound is not evidence FOR the bound. |
| c12 builds the single pod | **PASS** (run 5) — 1 unit topology, 50 `sonic-vm` nodes, 2306 links, 117 devices configured, `executor rc=0` |
| **50 SONiC guests converging to 2266/2266 on 80 vCPU** | **PASS** (run 8) — see §8 for what was measured and where |
| the 0.75 VM/vCPU boundary itself | **not probed here** — supported by the S1 calibration (48/64); these runs sat at 0.625 |
| the cross-host path | **UNMEASURED** — §9 |

The probe was run eight times. Runs 1-7 each ended on a defect in the
instrument or in the deploy path rather than on a finding about the hardware,
and run 5 is where that changed in kind: it produced a *diagnosis* rather than a
puzzle — the verdict named the failing step, the evidence archive reached the
workstation before teardown, and teardown proved absence. Run 8 is the
measurement.

## 2. Run 5, step by step

    host ready in ~80s; 80 vCPU, 314 GB; containerlab 0.77.0, Docker 29.1.3
    gate 1   OK   /dev/kvm root-writable, kvm_intel, KVM accelerator
    sync     OK   gpufab-platform c93f4260, gpufab-network 9c7d7eb8 (real git checkouts)
    gate 1b  OK   vrnetlab/sonic_sonic-vs:202505-ztp present (9.04 GB)
    gate 2   deploy launched under systemd, exited status 1 inside the window
    verdict  VOID the deploy itself failed (exit 1); density NOT measured,
                  host NOT implicated
    teardown instance absent, no orphaned disks, no orphaned addresses — VERIFIED

The deploy reached ZTP serving and failed there:

    ztp_serve_units.sh: line 101: SUDO: unbound variable
    ztp/oob/serve.sh: line 189: /opt/gpufab-venv/bin/python: No such file or directory
    [oob-ztp] FATAL: the render FAILED.
      FAIL c12-ztp-dc1-pod001 was not created (create rc=1); claim retired
      FAIL unit dc1-pod001 did not come up, or came up unowned
      0/1 unit address(es) answered
      c12 VERDICT: FAILED

Note what did NOT happen: the failed render left the served tree untouched and
said so, the ownership claim was retired rather than leaked, and the run was
called VOID rather than a density failure. Those are the designed behaviours
working.

## 3. Defect 1 — the interpreter, named in ~45 places in four behaviours

`/opt/gpufab-venv` is created by `terraform/startup.sh` and stage 00. A host
brought up by `deploy/checks/a4-host.sh` installs the same libraries into the
**system** python instead. Every script on the ZTP path coped with that except
one, and that one is on the critical path:

| spelling | files | on a host with no venv |
|---|---|---|
| venv, then `[ -x ] \|\| python3` | `ztp_serve_units.sh`, `ztp_stop_units.sh`, `oob-profile.sh` | works |
| venv, **no fallback** | `ztp/oob/serve.sh`, `ztp/head/serve.sh` | **fatal** |
| a loop over candidates | ~20 tests | works |
| the literal path | `00-bootstrap.sh`, `terraform/startup.sh` | correct — these *create* it |

**Fix:** `deploy/pyexec.sh`, one derivation, sourced by all five scripts on the
ZTP/deploy path. It prefers the venv — so S1, S2 and ops select exactly what
they select today and nothing about them changes — and falls through only when
the venv is absent or broken.

It tests the interpreter by **capability, not by path**: `gpufab_python yaml`
returns an interpreter that can actually `import yaml`. The old
`[ -x "$PY" ] || PY=python3` guards would have selected an executable at the
venv path with an empty `site-packages` and failed later with an import
traceback instead of a diagnosis. Presence is not function, one level down from
where that rule is usually applied.

Nothing usable is a **refusal** with an empty stdout, not an empty string a
caller might run, and it attributes the fault to provisioning rather than to the
fabric.

## 4. Defect 2 — `SUDO` used twenty lines before it was defined

`ztp_serve_units.sh:101` read the NetBox token through `$SUDO`, which was
assigned at line 120. Under `set -u` the command substitution's subshell died,
`NETBOX_TOKEN` silently became empty, and the script carried on. Harmless under
`GPUFAB_ZTP_SOT=profile` (this run), and under `netbox` it produces a 403 whose
message blames NetBox — which is the exact misdiagnosis the block at line 101
was written to prevent.

## 5. Defect 3 (from run 4) — a unit list kept in two places

`c12-unit-labs.sh` hardcoded `UNITS=(dc1-pod001 dc1-pod002 core)`, the default
fixture's units written out a second time, and used it whatever profile it was
given. On the single-pod fixture it generated pod001 and then VOIDed on
`--unit dc1-pod002 is not a unit in this model`. It now derives from
`fabric_model.management_units()` on the profile the run will use; the live
s2-1024 and micro-2pod derive exactly the old list, which is what made it safe
to change a live deploy path.

Run 5 confirms the fix on the real path: one unit topology generated, served,
and named `dc1-pod001` throughout.

## 6. What this says about method

All three defects are the same shape — **one fact, kept in more than one
place** — and all three were invisible until a host that differed from the
reference host ran the code. The cold/unfamiliar environment is the instrument
that finds them; reading and warm re-runs cannot.

The countermeasures landed with the fixes, not after them:

* `tests/t106-n2probe.sh` (119 assertions) drives the probe's supervision,
  evidence and verdict through fakes — non-start, partial start, failed
  evidence capture, nonconvergence, success, interruption — plus the real
  runner and c12's real derivation block.
* `tests/t107-pyexec.sh` (32 assertions) proves the venv still wins, that a
  non-importing interpreter is rejected and SAID so, that a refusal prints
  nothing runnable, and that all five call sites go through the one derivation.
* `tests/t106-red.sh` (12 mutations) and `tests/t107-red.sh` (9 mutations) put
  each defect back and require the test to fail on the assertion that names it.

## 7. Runs 6 and 7 — the render works; the HOST does not survive the fabric

### Run 6: VOID, the deploy destroyed its own fabric

The `pyexec` fix landed exactly as intended — the render, which run 5 could not
perform at all, completed and verified itself:

    [oob-ztp] staged tree verified COMPLETE: 50 device artifacts, 322 files
              rendered 167 device(s), switches=50
    [oob-ztp] swap complete — served-root inode preserved
              dhcp-range 172.28.0.0/24 covers 172.28.0.4

Then:

    docker: Error response from daemon: network c12-oob-dc1-pod001 not found
      FAIL ZTP serving did not come up for every unit

**Cause, and it was in the probe's own command:** no `--keep`. The executor's
contract is that a transaction RELEASES everything it created unless `--keep`
says otherwise, and serving runs after it because serve.sh puts each server ON
its unit's management network. So the run built 169 containers, configured 117
host devices, destroyed them, returned `rc=0`, and served ZTP onto a network
that no longer existed. Every other deploying caller (`a5-partial-teardown.sh`,
`a6-canary-path.sh`) passes `--keep`.

Fixed twice over: the probe's command now carries it, and **c12 refuses `--ztp`
on a deploying run without `--keep`** in its first few lines rather than after
twenty minutes of work. `--ztp --no-deploy`, which re-serves an already standing
fabric, is untouched.

### Run 7: VOID, and the host lost its own networking

The deploy started and built the lab. Then the host went silent, and the serial
console says why:

    10:09:34  systemd-networkd[1303]: veth1fc0901: Gained IPv6LL   (425 such events)
    10:11:40  kernel: neighbour: arp_cache: neighbor table overflow!   (185 lines)
    10:11:40  kernel: net_ratelimit: 6400 callbacks suppressed
              ERROR: (gcloud.compute.ssh) [/usr/bin/ssh] exited with return code [255]

**Three findings.**

**F1 — the disposable host had no sim-scale sysctls.** 169 containers across
2306 links against a kernel default of 128/512/1024 ARP entries. The values
existed in TWO byte-identical copies (`terraform/startup.sh`,
`deploy/00-bootstrap.sh`) and `a4-host.sh` had neither, while its own comment
asserted the opposite:

    # Not OOM, not neighbour-table overflow (00-bootstrap already raises
    # gc_thresh to 4096/8192/16384), not conntrack.

a4-host.sh does not run 00-bootstrap. Every host it has created ran on the
defaults, and the comment ruling that cause out is why it was never suspected.

Fixed: `deploy/host_sysctls.conf` is the one source; stage 00 installs it, a4
embeds it at VM creation before any fabric exists, terraform carries a copy
t106 proves identical line by line, and all three **read gc_thresh3 back out of
the kernel** — `sysctl --system` exits 0 having applied nothing when the file
does not parse.

**F2 — D9 was live.** 425 `systemd-networkd … veth` events is D9's precondition
on the box: the defect that took a host's own networking down mid-build on
2026-09-07. `host_harden.sh --assert` already existed and nothing called it.
Fixed: **gate 1c** now measures host preparation — sysctls in the kernel, D7/D9
in effect — before the deploy, and VOIDs if either is missing.

**F3 — the probe said something false.** Its verdict read:

    VOID the deploy never started (no unit became active within the launch
         deadline); the density was NOT measured and the host is not implicated

Every clause was wrong. The deploy started, the deadline was not what elapsed,
and the host was the entire problem. Cause: `lib-n2probe.sh:62` answered
`never_started` when the RUNNER failed — three definite claims manufactured out
of one unanswered query, which is exactly the laundering CLAUDE.md §3 rule 2
forbids, inside the instrument built to enforce it.

Fixed: `unreadable` is its own state end to end; the deadline carries the last
observed state out instead of overwriting it; the verdict names it, says the
host **IS** implicated, and points at the serial console. `never_started` now
says the host *answered* and reported no unit — the fact it actually describes.

### Four of my own assertions were blind, and the red controls caught them

Three grepped for a string that also appears in the comment explaining the
defect, so renaming a gate or re-adding a duplicate copy still passed. One used
a count threshold that went stale when a fourth fact map appeared. One mutation
was also unfaithful: disabling a branch's condition left a second code path
defending the same property, so the control passed while measuring nothing.

t106 is now 164 assertions and t106-red a baseline plus 25 mutations.

## 8. Run 8 — PASS. The floor holds.

    gate 1   OK   /dev/kvm root-writable, kvm_intel, KVM accelerator
    gate 1b  OK   vrnetlab/sonic_sonic-vs:202505-ztp present (9.04 GB)
    gate 1c  OK   gc_thresh3=16384 (read out of the kernel)
             OK   D7 masked, D9 drop-in present, 1/1 device unmanaged
    gate 2   launch_rc=0, unit active
             est=2266 cfg=2266 vms=50 swap_mb=0 load=45.16 memfree_gb=106
    verdict  PASS 50 VMs converged to 2266/2266 with no swap
    teardown instance absent, no orphaned disks, no orphaned addresses — VERIFIED

**What was measured, and where:**

| fact | value | measured by |
|---|---|---|
| switch VMs | 50 / 50 healthy | `docker ps` on the host |
| host containers | 118 (+1 ZTP server = 169) | the plan derives 169 |
| BGP configured | **2266** | per-switch `show bgp summary json`, summed |
| BGP established | **2266** | same, `state == "Established"` |
| switches unreadable | **0** | a non-zero here VOIDs the run |
| swap | **0 MB** | 213 GB used of 322, load 42 |
| density | **0.625 VM/vCPU** | bound 0.75 |
| EVPN + dataplane | t92 **PROVEN 15/0** | 4 VTEPs, 14/14 EVPN established, a real tenant forward, and a negative control proving the comparison can fail |
| c12's own verdict | **OK** | independent of the probe |

2266 is `expected.py`'s derived `bgp_peer_series` for this fixture, so the check
compares the boxes against the MODEL rather than against itself. The EVPN leg
carries its own negative control: a corrupted `VXLAN_TUNNEL` is detected, so the
comparison is known to be capable of failing.

### Two instrument defects found by distrusting the PASS

Neither changes the result; both were found by asking what the green actually
measured.

**The sample lied about its own timing.** `t+0s est=2266` was stamped thirteen
minutes before the sample was taken: `now` is captured at the top of the
iteration and printed at the bottom, and the gather ssh's to every switch, so a
switch still booting blocks until it answers and one iteration implicitly waited
for the whole fabric. The numbers were real; **the convergence TIME was never
measured** — this run cannot say whether the fabric took two minutes or
thirteen. Now stamped when the sample finishes, with the gather's duration
beside it.

**`BGP_WAIT` was advisory.** Because that gather blocks, the bound was only
evaluated BETWEEN iterations; a gather that never returned would have run past
it indefinitely — on a host that had stopped answering, forever. Now bounded,
killing the process GROUP on overrun, and an overrun emits `gather_timed_out=1`
rather than an empty success that would read as zero.

### What this does and does not establish

**Does:** one s3-4096 pod — 50 SONiC VMs, 2266 BGP sessions, 4 VTEPs — runs and
converges on a single `n2-standard-80` at **0.625 VM/vCPU** with no swap, on a
host prepared by `a4-host.sh` alone. That qualifies the 0.625 operating point
and the 80-vCPU floor for one S3 pod.

**Does not support the 0.75 bound.** A measurement at 0.625 sits inside the
bound and says nothing about where the bound is; 0.75 remains supported by the
S1 calibration (48 VMs / 64 vCPU), and the region between the two is unprobed.

**Does not** declare a baseline, write any pin, or say anything about the
**cross-host path**. S3-4096 builds **5 pods on 5 hosts** — 270 switches and 595
host nodes, 865 nodes in total, 11,730 local links and **800 cross-host links**
(derived from `fabric_model.place()`, cross-checked independently). The 35 in
`addressing.envelope.pods` is the shared **addressing** envelope, which sizes the
management address plan and is NOT a build size: s5-32768 is the rung that
builds 35 hosts (2055 switches, 6800 cross-host links). `c12` is still a
one-host launcher. This run also does not establish a convergence time, for the
reason above.

## 9. Next

The hardware question is answered. What remains, in order:

**Prove the cross-host MECHANISM on a two-host slice, not the full five-host
S3.** Every rung above S2 needs it and nothing has measured it: `c12` deploys
one host, and S3-4096 builds 5 pods on 5 hosts with 800 cross-host links. The
mechanism is identical at two hosts and at five; the slice is what makes it
cheap enough to iterate on, and the full five-host build should only be
considered after the two-host transport passes.

Folded into that ONE acceptance run, so that D9-at-scale and convergence
timing do not each cost a separate paid run:

1. **Exact per-link identities** — the bridge and VXLAN identity of every
   cross-host link, and UDP **14789**, asserted per link rather than in
   aggregate.
2. **Both MTU boundaries, and the adjacent failures** — the largest frame that
   must pass and the smallest that must not, on both sides of each boundary.
3. **Cross-host BGP/EVPN dataplane** — sessions across the host boundary, and a
   tenant forward that actually traverses it.
4. **Ownership-safe teardown and recovery** — the lifecycle leg that is still
   only DEMONSTRATED for the substrate, not for unattended teardown.
5. **`host_harden.sh --assert` AFTER all lab interfaces exist** — gate 1c can
   only check the one veth that predates the deploy, and run 7 logged 425
   `systemd-networkd … veth` events, so D9's effect at several hundred devices
   is still unproven.
6. **Honestly bounded convergence timestamps** — now that the sample is stamped
   when it finishes and the gather is bounded, the convergence time is
   measurable for the first time.

A later consistency follow-up, not part of that run:
`c12-unit-labs.sh` still resolves its own interpreter rather than going through
`deploy/pyexec.sh`.

Known and deliberately NOT changed: `c12-unit-labs.sh` still resolves its own
interpreter with the venv-preferred-plus-fallback form rather than through
`pyexec.sh`. It is functional and was proven on this exact host in run 5, so it
is a consistency follow-up, not a blocker.
