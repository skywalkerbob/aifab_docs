# Stability Retrospective — why silent failure dominated, and the rules it makes binding

This is a retrospective on the stabilization of the gpufab simulator, and — more
importantly — the **binding rules** it establishes for all future work. The
evidence is the project's own record: `ISSUE-REGISTER.md`, `ISSUE-CONVERGENCE.md`,
`WHY-ZTP-IAC-GITOPS-FELL-SHORT.md`, ~50 dated in-code measurements, and the full
commit history across `gpufab-platform`, `gpufab-network`, and `gpufab-docs`.

The rules in §7 are not advice. They are the working agreement (see the project
`CLAUDE.md` §3, which points here), and every change and every check must obey them.

---

## 1. The one-sentence answer

**Almost nothing here failed loudly.** 84% of the ~88 tracked issues were
correctness or verification-gap defects — the system did the wrong thing *and
reported success*. So the cost was never fixing bugs; it was **detecting** them,
and detection required a fresh box, a cold run, or a human reading the actual
device. Stabilization was slow because the failures were silent, not because they
were hard to repair once seen.

## 2. The evidence

- **84% correctness + verification-gap** (51 + 23 of 88). Capability gaps that
  running the system could have exposed: **0** — *running the system can only find
  defects in paths the system already has.*
- **How the defects were actually caught:** ~22 by a human reading a real box,
  ~11 only by a cold/scale build, ~9 in review — and only ~8 by a committed test
  *at the moment it mattered*, because the tests kept being blind too (`t39`
  structurally always-false; `t03` laundered "unmeasured" to 0; `t41` counted
  sessions, not routes).
- **The net is 3.4× the code it verifies** — 14,132 test lines vs 4,162 tool
  lines. Most of the effort went into building the *instrument that can see the
  failure*, not the fabric itself.
- **Fixes spawned regressions** — 0.62 regressions per closure overall (1.5 for
  the one EVPN feature build). Whole review rounds were regressions of the prior
  round's fixes.

## 3. Three defect shapes, each paid for repeatedly

1. **Self-comparison (X == X)** — a check comparing a value to itself,
   structurally unable to fail. `config_landed` built the "expected" config *from
   the box it was checking* (#97); the BGP census divided by the switches that
   answered → **1428/1430 "healthy" with 36 sessions dead** (#81); the run-id gate
   compared two independently-minted ids that could never match (E1). Recurred
   **≥5 times, and once inside the fix for itself** (the MGMT_* tables, one level up).

2. **Presence ≠ function (wrong signal)** — asserting the mechanism, not the
   outcome. BGP `Established` while zero prefixes moved (**a ~15 h overlay outage
   that read healthy**, #118); `/login/` returns 200 without touching the DB (the
   NetBox 500, #61); `config reload` exits 0 with **44 of 48 switches at factory**
   (#8). Paid for **at least three times in EVPN alone** (#118 → #141 → #139).

3. **Silent success** — a real failure that exits 0. A *successful* role never
   wrote the result the launcher waited on because `exec` made the write
   unreachable (#19); `ls <glob>` exits 2 on no-match and skipped teardown
   verification (#22); `--from` ran zero stages and printed "complete" (#14).

## 4. Why they recurred — the real answer to "why so long"

- **The same seam, in every subsystem.** SoT → render → apply → verify has a seam
  at each arrow, and each seam had the same shape. Fixing it in the config-push
  did not inoculate the exporter, the tests, or the sync path — the class simply
  reappeared in the next subsystem, needing its own box-measured diagnosis.
- **Review converges on the diff.** *A review whose input is the last review's
  diff converges on the diff; it cannot diverge toward a requirement it was never
  handed.* Independent, requirement-driven checks are the only way out.
- **The net was reactive.** Nearly every test was born in the commit that fixed
  the defect it now catches — so each class was caught only *after* it had already
  cost a fabric, and every new subsystem started blind again.
- **The onion.** You cannot reach layer N+1's bug until layer N passes. A single
  clean-build attempt on a fresh host pair is illustrative: fixing the NetBox
  token race made a management-plane delivery gap reachable; fixing that made a
  TACACS re-assert flake and a management-host config bug reachable. Each layer was
  invisible until the one beneath it closed.

## 5. Why this project specifically, not "software is hard"

It is a **high-fidelity emulation** — real SONiC-VS, real ZTP, real `config
reload`, real BGP/EVPN — so it inherits real-hardware failure modes that appear
only on a real box at scale: a 32-port table applied to 64-port switches (**178
sessions lost across three fabrics**, #7), identical base MACs colliding
link-locals (**82 sessions**, #6), an FRR line valid on 10.2 and rejected by the
10.3 image the switch ships (#35), a Redis Lua stall at 48 VMs on 64 vCPU (#83).
And the entire *value* of the sim is that intent and reality do not silently
diverge — so building the machinery that keeps them in sync (the ownership
manifest, artifact-vs-box comparison, `expected.py`) **is** the product, not
overhead.

## 6. Is it converging? Yes.

The defect *shapes* are now mostly caught by the net built for them: the manifest
check is what *surfaced* the management-plane delivery gap; the token verify is
what caught the 500. Defects found now are subtler and caught faster (a scale run,
not much later). But the same shapes still appear — a TACACS re-assert that checks
its own exit code instead of whether the server answers is "presence ≠ function"
again — so the net is not finished. It is converging, and the rules below are how
it keeps converging instead of relapsing.

---

## 7. Rules — binding going forward

These are mandatory. They are the distilled cause of every incident above, stated
as prohibitions and obligations. `CLAUDE.md` §3 references this section.

1. **Assert the END STATE, measured on the real system — never the mechanism.**
   `rc=0`, `Established`, HTTP `200`, "container started", "reload returned" are
   *mechanisms*. Check the outcome you actually want to be true — prefixes moving,
   the config present on the box, the token authenticating, the server answering —
   observed on the box, not through a proxy for it.

2. **A check that observed nothing is a FAILURE, not a pass.** Zero, empty, and
   unmeasured are never success. An assertion takes an observed count and fails on
   zero. `${x:-0}` and its kin, which launder "not measured" into "0", are the
   defect — not the guard.

3. **One derivation per fact.** Any value that exists in two places — a run-id, an
   address, an expected count, a secret — will diverge silently and become an
   outage. Derive it once, from the model; a second independent copy is prohibited.

4. **Presence ≠ function.** A session, table, file, container, or route being
   *present* is not proof it *works*. Assert the function (routes installed,
   prefixes exchanged, the port answering the protocol), not existence.

5. **Cold and scale runs are verification instruments.** They find what reading
   and warm re-runs structurally cannot. Run them; treat the *first observed
   failure* as the signal and follow it; never paper over a degraded stage to reach
   a green result.

6. **Verify against the model, not against the diff.** A check whose expectation
   comes from the change under test can only confirm the change. Expected values
   come from the single model derivation (`expected.py` / `fabric_model`), so a
   check can disagree with what was just done.

7. **Never swallow the evidence.** `>/dev/null 2>&1`, `|| true`, and `curl -f` on
   an auth-required endpoint have each hidden the exact error that would have ended
   a diagnosis in minutes. If a step can fail, its failure must be observable.

**The through-line:** distrust every green result until you can name the thing it
measured and confirm that thing is the outcome, on the real system. Most of this
project's cost was paid to results that were green and wrong.
