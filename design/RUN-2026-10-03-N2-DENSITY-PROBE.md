# n2-standard-80 density probe — the instrument now explains itself; two code defects stand in the way

**Date:** 2026-10-03
**Question:** may the ladder above 1024 GPUs be planned on `n2-standard-80`?
**Host:** `gpufab-n2probe-01`, n2-standard-80, us-central1-a, disposable, TTL 4h
**Fixture:** `tests/fixtures/n2probe-1pod.yaml` — one s3-4096 pod
**Derived target:** 50 switch VMs, 2266 BGP peer series, 0.625 VM/vCPU
**Outcome:** **VOID** — the deploy failed; the density was NOT measured and the
host is NOT implicated. S1 and S2 untouched. Teardown VERIFIED.

---

## 1. What is settled, and what is not

| | |
|---|---|
| nested KVM on n2-standard-80 | **PASS** (runs 3, 5) — `/dev/kvm` 660 root:kvm root-writable, `kvm_intel` loaded, KVM accelerator |
| the NOS image on a fresh host | **PASS** (run 5) — stage 10 loads `vrnetlab/sonic_sonic-vs:202505-ztp` from the GCS cache, 9.04 GB, confirmed by `docker image inspect` |
| the arithmetic floor | **PASS** — 50 VMs on 80 vCPU is 0.625 VM/vCPU against a 0.75 bound; 200 GB of guest RAM is 0.637 of MemTotal against 0.85 |
| c12 builds the single pod | **PASS** (run 5) — 1 unit topology, 50 `sonic-vm` nodes, 2306 links, 117 devices configured, `executor rc=0` |
| **50 SONiC guests converging to 2266/2266 on 80 vCPU** | **STILL UNMEASURED** |

The probe has now been run five times. Runs 1–4 ended on defects in the
instrument or in the deploy path, not on findings about the hardware. Run 5 is
the first that produced a *diagnosis* rather than a puzzle, and that is the
change worth recording: the verdict named the failing step, the evidence archive
was on the workstation before teardown, and teardown proved absence.

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

## 7. Next

One more `n2-standard-80` attempt, same fixed target and no fallback:
**50 VMs, 2266 configured, 2266 established, zero unreadable, no swap,
validated evidence, verified teardown.** Nothing about the hardware question has
changed; the three defects between the probe and the answer are closed.

Known and deliberately NOT changed: `c12-unit-labs.sh` still resolves its own
interpreter with the venv-preferred-plus-fallback form rather than through
`pyexec.sh`. It is functional and was proven on this exact host in run 5, so it
is a consistency follow-up, not a blocker.
