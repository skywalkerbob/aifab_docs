# Issue priority — every open issue in `gpufab-platform`, ranked

**Written 2026-07-28.** Measurement points: `gpufab-platform` at `e9d5f21`
(= `origin/main`; the local checkout sits on a branch named `o5-merge` that is
0 ahead / 0 behind), `gpufab-network` at `18f5d4e` (= `origin/main`),
`gpufab-docs` at `74c1326`. GitHub state read 2026-07-28: **18 open, 71 closed.**

The rank axis is **what to do next**, not severity. It is expected value per unit
of delay: what an issue unblocks or prevents, divided by what it costs, weighted
up when its failure mode is silent.

Every claim cites a file, line, commit, issue or measurement. Where a claim is
inference rather than measurement it says so. No host was contacted; **`gpufab-s11`
was deliberately untouched** — a VXLAN implementation was running against it.

---

## 1. The ranked list

Ranks 1–3 are **one workstream, not three items.** #94 is the root cause and #97
and #93 are its symptoms — but the work order is symptom-first, because this
project's record is that mechanisms designed from source and confirmed warm die
against a cold box (#58 killed two such hypotheses in a week).

| # | Issue | One-line reason |
|---|---|---|
| **1** | **#93** `DEVICE_METADATA.mac` | Half a day of measurement, not a desk decision: the artifact carries the right MAC, the box carries a value written by nothing in either repo, and that is #58's shape — which #94 would inherit. |
| **2** | **#97** `config_landed` compares the box against itself | Write the failing test first. A fleet-wide artifact-vs-box check is a day, it sizes #94, and it enumerates a set the issue says nothing enumerates. |
| **3** | **#94** the push cannot derive an adopted table | **The root cause of all three.** The push never reads the artifact `config_db`, so its "expected" side is the box. Fixing it makes drift observable, makes a config change SoT-governed, and is the user's stated second priority arriving as a correctness fix. |
| **4** | **R0** *(unfiled — §6)* release scope / blast-radius control | The user's stated third priority has **no issue and no code**. Both delivery paths are fleet-wide by construction. It must exist before an automated apply does. |
| **5** | **#91a** the still-broken GitOps workflows | `validate.yml` is green today having validated nothing — the signature defect inside the required gate. Hours. (The *apply* half, #91b, is ranked 10 deliberately.) |
| **6** | **#75 + #84** telemetry un-gates a good build; the exporter crash-loops | **One incident, one work item, three lines, ~1 day.** #75 lets a converged fabric go uncertified; #84 is a second way the same `User=ubuntu` unit dies. Land them together — see §4.4. |
| **7** | **#76** golden-image tag drift | Not hypothetical: **12 tags are declared and 15 are created**, so three already drift, and the comment claiming a check would catch it is factually wrong. |
| **8** | **#86** `t23` samples 5 switches and never the OOB pair | An hour. The miss is **deterministic, not probabilistic** — sorted order puts the OOB pair beyond the sample on every shipped profile. |
| **9** | **#61** topoview aggregation contract | Small work gated on a decision, and with #93 it is the difference between a gate whose red means red and a gate with two permanent reds everyone learns to skip. |
| **10** | **#91b** the GitOps apply + commit→NetBox | The pillar's whole point, and 3–4 days. Ranked below #97/#94 and R0 on purpose: automating a fleet-wide apply on top of a blind landed-check industrialises the blind spot. |
| **11** | **#55** multi-host sharding | The only open issue that raises the ceiling above one host, and the target is 200–500K. **3–5 days, not the one-line flag it reads as** — and S2 cannot be generated on *any* host today, not just S2+. |
| **12** | **#88** day-2 add/remove | Do the cheap half — drain a leaf from a converged fabric, assert BGP settles to the *new* expected figure. Defer the SoT half: `--reset` is 6002 sequential, unscoped, silent DELETEs. |
| **13** | **#85** the head writes no phase records | Its stated justification (ranking build-time levers) evaporated when build time stopped being the constraint. What survives is that `t16` passes having measured half the system. |
| **14** | **#89** half-open asymmetric BGP session | Build the detector. Timebox the diagnosis to one day — it may be a VS artefact, and #81 already made it visible, which is the property that gets things fixed. |
| **15** | **#62** GCS prefixes are attribution, not isolation | Terraform-only, half a day. Justified not by an attacker but by two precedents where a *correct* component targeted the wrong sim's state (A6, F5). The artifacts are this project's audit trail. |
| **16** | **#95** a subagent printed a fabric secret | Fifteen minutes, in `CLAUDE.md`, not in code. Ranked here because it blocks nothing — do it in the next gap, not next week. |
| **17** | **#87** VXLAN/EVPN | Already in flight against s11. It should ship *through* the composer, not beside it — §5.3 lists what must land with it or it reproduces #58 exactly. |
| **18** | **#83** Redis Lua stall under CPU starvation | **Thirty minutes of code, then close as a recorded fidelity limitation.** The concurrency knob it turns on already exists and is unreachable from a deploy — §4.5. |
| **19** | **#63** no per-user identity | **Close as won't-fix for v1.** A project, not a fix, on a single-tenant disposable sim. `§5.8` already records it as a non-boundary; leaving it open implies it is being tracked toward closure. |

All 18 open issues appear. Two entries are not open issues: **R0** is a gap with
no issue and should be filed (§6), and **#91** is split across ranks 5 and 10
because its two halves are a few hours and several days respectively, and the
second must not precede rank 3.

---

## 2. The finding that set ranks 1–3

Verified by reading `gpufab-network@18f5d4e`, not taken from the issue text.

```python
# interim_deploy.py:1473-1476   — the observed side
r = run_ssh(ip, "sonic-cfggen -d --print-data");  running = json.loads(r.stdout)

# interim_deploy.py:1502        — the "expected" side, built FROM the observed side
cfg = build_switch_config(node, links, running, hw, strip=own.strip)
insync = already_applied(before, cfg, own)        # -> config_landed(before, cfg, own)

# interim_deploy.py:593-594
def build_switch_config(node, links, running, hw=None, strip=None):
    """Graft our intent onto the box's running config.

# interim_deploy.py:634         — everything not grafted is inherited verbatim
cfg = {k: v for k, v in running.items() if k not in drop}
```

`before` is a deep copy of `running`. **Both sides of the comparison are the box.**
Any table or key the graft does not itself write is compared against itself and
can never differ. The tool concedes it at `:1295-1297`: *"If the device never had
it at all, `cfg` cannot invent it, so both sides are empty and this passes."*

The cause is one absence: **`interim_deploy` never reads the artifact `config_db`.**
The only path it opens under the ZTP root is `<device>/manifest.json`
(`:1006`); there is no `requests`, `urllib`, `gs://` or `curl` anywhere in the
file. So the push knows *which* tables it owns and not *what their values should
be*. `build_switch_config` writes only `SNMP`/`SNMP_COMMUNITY`/`FEATURE.snmp`
(`:638`), three `DEVICE_METADATA` keys (`:639-641`), `PORT`/`hwsku` (`:642-645`),
`LOOPBACK_INTERFACE` (`:646`), the auth tables (`:666`), `INTERFACE` (`:691`) and
`BGP_NEIGHBOR` (`:706-709`). Everything else is the box's own opinion, compared
against itself.

**The codebase has already written this down as its own next step**, in a
committed passing assertion — `tests/t36-bootstrap-vs-steady.sh:603-607`:

```
# The limit of the change, asserted rather than described. If this ever fails,
# the push has learned to derive adopted tables from the artifact — close #88's
# remaining half and update this line deliberately.
t_count "BOUNDARY: the push preserves an adopted table but does NOT correct its drift" ...
```

That is #94, asserted by the test suite as a boundary with instructions for
removing it. It is the strongest evidence available that this is the right next
change, and it did not come from an opinion.

**One precedent for how to do it exists in the same file.** `PORT`/`hwsku` are the
single exception where render intent reaches the push — and it arrives not from
the artifact but by re-running the derivation through a shared function
(`:733-749`, `import render_fabric_ztp as rfz` … `rfz.port_table_from_sot(...)`).
That is why `PORT` is one of the few tables meaningfully compared today, and it
is also why #94 should read the artifact rather than import more derivations:
a second derivation is the anti-pattern `oob_plan.py:166-169` names —
*"Two allocators for one number is how this project produced the 32-port PORT
table."*

---

## 3. Dependency graph

```
  CLOSED, and each created one of the items above:
    #90 computed manifest  ──►  #93   (mac became tracked, and still never matches)
    #92 bootstrap/steady   ──►  #94   (a table can be adopted, and never changed)
    #96 steady reachable   ──►  #97   (found while fixing it)
    #81 authoritative BGP  ──►  #89   (found by the gate that fixed the denominator)

  #94  the push reads the artifact config_db          ◄── ROOT CAUSE
    │
    ├── symptom ─► #97  config_landed compares box-vs-box
    ├── symptom ─► #93  mac written by the render, never compared, never landed
    │
    ├──► #88 config half   (turning a feature off becomes a verifiable operation)
    ├──► #87 VXLAN day-2   (a VLAN table can be CHANGED, not merely preserved)
    └──► #91b apply        (an automated apply needs an honest landed-check)

  WORK ORDER inside that cluster is the reverse of causality, deliberately:
      #93 measure the box  ──►  #97 write the failing test  ──►  #94 build it

  R0  staging / blast-radius   ──► #91b   (never wire a fleet-wide apply to a merge)
  #91a CI repairs              ──► #91b   (a workflow that cannot fire hides which break is real)

  #84 exporter trustworthy at gate time ──► #75's t13 caution, #89's detector,
                                            and every exporter-derived assertion
  #75 telemetry stops failing the role  ──► the gate can certify a good build
                                            ──► every issue judged by the gate

  #83 density stall at 48 sw/host ──evidence for──► #55 sharding
  #55 sharding ──► any claim about 200–500K
        └──► #87 §5.7 nested-encap MTU budget becomes REAL (inert on one host)

  #61 + #93 ──► no permanently-red gate phase ──► red means red
```

---

## 4. Per issue — cost, what it unblocks, silent or loud

**Cost calibration, from the closed record**, because estimates here have been
wrong in one consistent direction:

- **#82** was a single f-string syntax error. Closing it took the fix *plus*
  `t35` (11 assertions, each demonstrated failing first) *plus* a sweep that
  compiles every embedded `python3 -c` in `tests/` and `deploy/`. **A one-line
  bug costs a day once its test is written.**
- **#92** was ~2 days and the implementing agent **proved its own brief wrong**:
  dropping the floor would have left every peerless device inheriting stale
  neighbours.
- **#96** was ~1.5 days, and its second defect — `read_box_manifest` running a
  plain `cat` on a `0600 root:root` file, the error swallowed by the command's
  own `2>/dev/null` — **was found by the live run, not by the test.** The agent's
  `t37` passed 62/0 against the half-fix.
- **#58** took six review rounds and three hypotheses across a week.

So: **anything touching the push path is 1.5–2 days plus a cold build**, and two
of the last three such fixes were falsified only by a cold run. Nothing below is
costed at "an hour" unless it is a text change or a decision.

| # | Issue | Cost | Unblocks | Failure mode |
|---|---|---|---|---|
| 1 | #93 | **~0.5d on a box, then the decision** | #94 (it would inherit the same race); un-reds `t33` | **Silent** — nothing compared it until #90, and the comparison that now does is vacuous |
| 2 | #97 | **~1d** | Sizes #94; enumerates the unknown divergent set | **Silent, and structurally so** — the comparison is correct and blind to the layer beneath it |
| 3 | #94 | **~2–3d + one cold build** | #97, #93, #88 config half, #87 day-2, #91b | **Silent** — a drifted adopted table is invisible to the comparison built to catch drift |
| 4 | R0 | **~1–2d** | #91b; any multi-switch change made with confidence | **Loud when it fires, unbounded in scope** — 46/46 at once, by construction |
| 5 | #91a | **~3–4h** | #91b; removes two vacuous-green checks | **Silent** — `validate.yml` has been green since day one having validated nothing |
| 6 | #75+#84 | **3 lines in 3 files, ~1d with its assertions** | The gate's ability to certify anything; trustworthy exporter numbers | **#75 loud but inverted** (a good build reported failed); **#84 silent** — and the gate that would have caught #84 is the one #75 skips |
| 7 | #76 | **~4–8h in-tree; the netbox-docker leg is 1–2d and a design decision** | Nothing; prevents a class that has already fired | **Silent by design** — "the image quietly stops saving what it was built to save while continuing to look like it works" |
| 8 | #86 | **~1–2h coverage; up to 1d if the OOB repair path is in scope** | Nothing; replaces a hand-verified claim with a committed one | **Silent** — the OOB pair is outside the push path, which is why it was missed |
| 9 | #61 | **3–4 files, ~60–70 lines, ~0.5d — gated on a decision** | A gate with no permanent reds | **Loud** — 66/6, visible on every run |
| 10 | #91b | **~3–4d** | The GitOps pillar | **Loud today** (`exit 1`); **silent once implemented** if #94 has not landed |
| 11 | #55 | **~3–5d + a multi-host fleet + ≥2 builds** | Every claim about scale | **Loud** — the generator refuses to emit at all, on every host, from S2 up |
| 12 | #88 | **cheap half ~1d; SoT half ~2d** | Convergence-under-change, the operationally interesting case | **Silent** — no test exists, so there is no signal at all |
| 13 | #85 | **3 files, ~40–60 lines, ~0.5–1d** | Instrumented head figures | **Silent** — "NO PHASE RECORDS", and the restriction is one wiring line, not a bug in the test |
| 14 | #89 | **~1.5–2d, most of it in `t31`** | Confidence in any convergence claim | **Was silent, now partly loud** — but a *compensating* count still hides it, and the gate prints that signal without acting on it |
| 15 | #62 | **~0.5d terraform + a `t24`-shaped test** | Nothing; bounds a blast radius | **Silent** — a wrong-sim write succeeds and looks identical to a right one |
| 16 | #95 | **15 min** | Nothing | **Loud** — noticed immediately; exposure local-only, secret rotated |
| 17 | #87 | **probe ~1d; module ~3d atop composer ~2d** | The frontend overlay | **Silent in the worst way** — §5.3 |
| 18 | #83 | **2 lines in 2 files, ~30 min — then close** | Makes an existing measured knob reachable | **Loud, and it self-healed** — 1464/1464 at 09:10:48 |
| 19 | #63 | **0 (close it)** | Nothing | n/a |

### 4.1 #93 — measure before deciding, and the framing in the issue is too small

#93 asks a binary question: does the push write `mac`, or does the renderer stop
claiming it? Both answers are wrong until one measurement is taken, because a
third fact is unaccounted for.

The render derives `02:01:` + the four octets of the management IP
(`render_fabric_ztp.py:337-358`), applied at `:622`. `02:01:ac:14:00:28` decodes
to `172.20.0.40` — correct, unique, and deliberately offset from the mgmt MAC by
its second octet. **The box carries `22:73:a1:c4:ee:e7`, which is written by
nothing in either repository.** The base snapshot's value is
`22:3c:85:c1:e4:36` (`design/base/vs_base_config_db.json:186`) and the only other
`mac` write anywhere is the renderer's. So the served artifact is correct, and
something on the device replaces it.

**That is #58's shape exactly** — ZTP writes a correct config and a later,
unmodelled writer replaces it, with artifact-vs-intent agreeing throughout. Both
of #93's options are unsafe until the writer is named: having the push write
`mac` races it, and having the renderer stop claiming it removes a derivation
whose *absence* once cost 82 of 249 BGP sessions. And #94 would inherit the race
either way.

**What lowers the urgency, honestly:** the failure it guards against is currently
inert. The system MAC matters because BGP-unnumbered peers by IPv6 link-local and
link-local derives from it — and every deployable profile declares
`p2p: numbered` (`design/profiles/scale/s{0,1,2,3,4,5}-*.yaml:14` and `:20`).
Uniqueness today is supplied by whatever writes `22:73:…` per device, not by the
render. So this is a half-day measurement that un-reds a gate phase and de-risks
#94 — not an emergency.

One correction to the issue text: *"`_MD_KEYS` never listed it"* is now stale.
`_MD_KEYS = _LEGACY_MD_KEYS` (`interim_deploy.py:954`) is a dead alias with no
consumers; since `243915c` the manifest computes `md_keys` from render provenance
(`manifest.py:366-370`), and `mac` reaches `own.md_keys` on any manifested
device. #90 added `mac` to the compared set without making the comparison capable
of observing anything — which is §2 in one sentence.

### 4.2 #97 — the first action costs minutes

`t33-gitops-roundtrip.sh` already does artifact-vs-box via the manifest — it
loads `manifest.json`, `config_db.json` and a `sonic-cfggen -d --print-data` dump
(`t33:199`, `:212-214`) — on a sample of four: `SAMPLE="${SAMPLE:-4}"`
(`t33:56`), invoked with no override by `verify.sh:293`. **Running it once at
`SAMPLE=46` answers the open question in #97** — *"There may be others; nothing
enumerates them"* — before anyone designs anything.

Two limits to state, because the run will otherwise be over-read:

- **t33 compares key sets, not values,** for ordinary tables (`:224-234`:
  `if want and not got` / `elif set(want) != set(got)`). Only the `md_keys`
  branch (`:237-239`) compares values. So a table whose keys match and whose
  values drifted is still invisible. Closing #97 properly means value comparison
  over the whole owned set, which is the same read and a different assertion.
- `t11-config-applied.sh` is the other device-level check and is count-based on
  `BGP_NEIGHBOR` alone, at `SAMPLE=5`.

### 4.3 #91a — three breaks are in the issue and three more are not

Verified on `gpufab-network@18f5d4e`:

- `deploy.yml:2-4` now filters `instances/*/rendered/**` — fixed, but by commit
  **`8b36b27`**, not `3891cb9` as #91's comment states.
- `deploy.yml:34` still diffs the **old** path
  (`git diff --name-only HEAD~1 -- rendered/ | cut -d/ -f2`), so a push that now
  fires the workflow yields an **empty** device list. And `cut -d/ -f2` is
  calibrated for `rendered/<device>/…`, where the device is field 2; under
  `instances/<sim>/rendered/<device>/…` it is field 4.
- `git ls-files instances/` returns **nothing** — the newly-correct filter matches
  a path never committed.
- `validate.yml:4` filters `["rendered/**", "templates/**", "design/**"]` while
  `render.yml:93` commits `instances/<sim>/rendered/**`, so the "required check"
  **never runs on the only PRs the system produces** — in addition to linting an
  empty directory when it does run.
- `drift-check.yml:17` exits **2** on argparse, which `drift.py:29` documents as
  its *"render is stale"* code, so a log-skimmer sees a plausible domain error
  rather than a CLI error. It also calls bare `python3` while `drift.py` imports
  `pynetbox` — a second, earlier failure on the runner.
- **Nothing tests any of it**: `grep -rn 'deploy\.yml\|validate\.yml\|drift-check\.yml'`
  across all 87 files in `tests/` returns **zero**. `t22` is the only file that
  asserts against a workflow at all, and only against `render.yml`. That is
  precisely why all three survived.

### 4.4 #75 and #84 are one incident, and three lines close both

They are filed as two issues and they are one `User=ubuntu` unit dying two ways
on first boot.

- **#75** — `70-telemetry` loses a first-boot race against systemd/dbus still
  settling. It is not a race *between stages*: stages run strictly serially
  (`deploy.sh:371`) and nothing else in the tree touches dbus. Five of the six
  `systemctl` calls in `70-telemetry.sh` are unguarded under `set -euo pipefail`,
  and `deploy/lib.sh` has no `systemctl` retry wrapper at all.
- **#84** — `monitoring/gpufab_exporter.py:27` calls `.exists()` on the
  automation key at **module scope, one line outside** a `try/except OSError`
  that would have caught the `PermissionError` verbatim. The unsearchable window
  is real: `services/tacacs/setup_auth.sh:52` creates `/opt/gpufab/secrets` as
  `root:root 0700` and only widens it ~250 lines later at `:304`. And
  `deploy/70-telemetry.sh:73` sets `StartLimitIntervalSec=0`, so the unit
  **crash-loops forever instead of going `failed`** — which is why 53 restarts
  produced no state anything reads.

**The exact change for #75 is one line**, `deploy/lib.sh:390` — and the token is
the *stage* name, `70-telemetry`, not `telemetry`, because `run_stage_soft`
records the stage (`deploy.sh:252-253`). Note the issue cites `lib.sh:383`, which
is correct against a stale local `main` ref and is line **390** in current code.

Two things the issues get wrong, and both matter:

- **"Nothing reported" (#84) is only true of the deploy.** No stage checks
  `is-active`, `is-failed` or a restart count — but three gate assertions would
  have caught it (`t04-roles.sh:59,67`, with the exporter marked
  `critical: true` in `monitoring/platform_services.yaml:48`; `t03-fabric.sh:77`;
  `t13:56`). **The gate that would have caught #84 is exactly the gate #75 causes
  `up.sh` to skip.** That is the coupling, and it is why they should land
  together.
- **The #75 one-liner converts a hard failure into a silent one.** With
  `70-telemetry` non-blocking, a genuinely dead exporter now reaches the gate, so
  `t04-roles.sh:67` becomes load-bearing. Verify that assertion fires before
  landing the one-liner — otherwise this trades the inverse defect for the
  ordinary one. #75's own caution about `t13` stands alongside it.

### 4.5 #83 — thirty minutes of code, then close

The density finding itself is settled: the arithmetic closes exactly (est 1404 /
down 60, decomposing to four named devices), the fabric self-healed to 1464/1464,
and the trigger is host CPU starvation at load ~113 across 48 SONiC VMs. Real
hardware does not do that. The actual defect — the deploy declaring complete 34s
after the daemons aborted — **#81 already fixed** by gating on authoritative
convergence, and the note is already carried in-code at `interim_deploy.py:~1936`.

But the issue asks whether to reduce concurrency during convergence, and the
answer contains a live defect it does not mention. **The knob exists, its default
was set by measurement, and it is unreachable from a deploy.**
`interim_deploy.py:113` reads `GPUFAB_PUSH_WORKERS` (default 24, with a measured
table at `:87-89`: 6 workers → 840s / 8 waves, 24 → 297s / 2 waves). Both call
sites — `deploy/50-configure.sh:39` and `deploy/50-ztp-provision.sh:200` — invoke
it under a **bare `sudo`**, which strips the environment, and neither passes
`--workers`. The repo already knows this trap: `roles/fabric.sh:593-595` chose a
flag over an env var for `--converge-timeout` for exactly this reason.

That is the H8 class — *"`up.sh` passes `--zone`; `verify.sh` had no such flag"* —
a knob that cannot be reached is not a knob. **Fix it (2 lines, 2 files), then
close #83 as a recorded fidelity limitation.** Do *not* lower the default: it
would spend build time to suppress a signal worth keeping, and
`t31-convergence-gate.sh:27-34` already waits transient shortfalls out by design.

Two things to record while closing. `interim_deploy.py:1805` floors the census at
`max_workers=max(workers, 8)`, so `--workers 4` still runs an 8-wide SSH census
every 15s *while converging* — lowering below 8 has no effect. And the larger
unbounded phase is not the push at all: `deploy/40-topology.sh:167` starts all 48
SONiC VMs with `containerlab deploy` and **no bound of any kind**. If the stall is
attributed to aggregate host CPU rather than the push wave, that is the real
target, and it is new code plus a day of build cycles to measure.

### 4.6 #63 — close as won't-fix for v1, and defend it in the doc, not the tracker

Closing it properly means per-user identity and IAM across every instance: a
project. The sim is single-tenant and disposable, `§5.8` already records this as a
sim boundary and never a customer boundary, and there is no second user. An open
issue reads as "tracked toward closure", and this is not. Record it as a stated
non-goal and reopen it the day a second user exists.

### 4.7 Four claims in the open issues are wrong, and should not survive into planning

Each was checked against `e9d5f21` / `18f5d4e`:

1. **#61 — `t09` does not hardcode 1500.** It reads the budget from the code
   (`t09-topoview.sh:38-45` imports `gen_topoview.AGGREGATE_ABOVE`), and `:31-37`
   records that the stale 1500 was already removed. Only the **level** assertions
   are stale (`:156`, `:157`, `:183`), with three cascade failures at `:185`,
   `:186`, `:191` because `:96-101` harvests `tier` nodes `auto` no longer
   produces. So the fix is *not* "a number in three places" — at a 6000 budget
   (`gen_topoview.py:448`) `auto` can never return `tier` for any committed
   profile, because the largest single pod at the largest rung is 2825 elements.
   That breaks the pod→tier→device drill chain and a non-numeric promise
   (`scale-out-architecture.md:492`). Decide whether to keep 6000 and make `tier`
   explicit-only, or lower the budget; then assert the *property*, not the level.
   The design figure lives at `scale-out-architecture.md:514` and `:942`, and the
   UI carries a stale `|| 1500` fallback at `portal/topology.html:205`.
2. **#89 — `t13` never derived its denominator "from what answered."** It has used
   `expected.py --key bgp_peer_series` since its first and only commit
   (`t13:80-81`, `:291`). That description belongs to the pre-#81
   `interim_deploy` census. There is nothing to fix in `t13`.
3. **#55 — the generator *is* passed `--profile`.** `deploy/40-topology.sh:29`
   passes it on the branch that actually runs (`roles/fabric.sh:338` sets
   `TOPO_FROM_PROFILE=1`). What is passed by nothing, anywhere, is `--host`, and
   the entire shard path is gated behind `if args.host:`
   (`gen_topology.py:234`). See §5.2 — the failure is also worse than the issue
   says.
4. **#86 — `t23` does cover the OOB pair on the artifact side** (`:103-114` loops
   every row); only the **on-box** half is sampled (`:45`, `:142`). And the miss
   is deterministic rather than probabilistic: the sample is the head of a
   lexicographic listing (`:76`), and `{pod}-oob-sw{NN}` sorts after `bk-` and
   `fr-`, landing at indices 24/25 on `s0-64` and 41/42 on `s1-512`. **They reach
   the on-box assertions on zero of the shipped profiles.** Note also there is
   currently no repair path for an already-built OOB switch's SNMP — extending
   coverage will surface a fix that does not exist.

---

## 5. Do not do yet

### 5.1 Do not implement the GitOps apply (#91b) before #94

This is the one place this document disagrees with the stated priority, and it is
a sequencing disagreement rather than a substantive one.

The apply is the pillar's whole point, and `deploy.yml:37-41` is still
`exit 1  # fail loudly until P6 implements the apply`, untouched since the
2026-07-23 scaffold. But the thing an apply would call is `interim_deploy`, and
`interim_deploy`'s verdict that a change landed is `config_landed`, which
compares the box against itself (§2). Wiring a merge to a fleet-wide apply on top
of that **automates the delivery of changes the system cannot verify arrived** —
at 46 devices today, and at 200–500K later.

The precedent is exact: in #58, ZTP wrote a correct config, a `delayed` container
rewrote it 45 seconds later, and artifact-vs-intent agreed the entire time. The
apply would be industrialising that.

**Do #91a now** (hours, and it removes two green checks that measure nothing).
**Do #91b after #94 and R0.**

### 5.2 Do not build #55 sharding yet — and do not close it either

It is the S1 that has been open since review round one, it is the only issue that
raises the ceiling above one host, and #83 is evidence the ceiling is already
being touched (load ~113, Redis Lua stalls tearing swss and bgp down on a
*converged* fabric).

**The failure is worse than the issue states, and the fix is larger.** The
unsharded generator does not merely make "S2+ fail" — it refuses to emit at all,
on **every** host including the first, dying at `gen_topology.py:392-398`
(*"nodes span N mgmt subnets … but a containerlab topology has one mgmt
network"*). **S1 is the last rung that can be built.** `terraform/fabric.tf:42`
defaults `fabric_host_count = 1`, so nothing has ever hit it.

The placement logic is genuinely complete — `_shard()` (`gen_topology.py:150`) →
`fabric_model.place()` (`:1052`), pod-atomic with a `ModelError` on a split pod
(`:1070-1072`) and round-robin cores (`:1109`) — and cross-host VXLAN tunnels are
emitted (`gen_topology.py:359-370`). Passing `--host` is ~5 lines. **The other
3–5 days are the parts nobody has built:** no primitive maps a machine to its own
`gpufab-fabric-NN` identity (`roles/fabric.sh:67` yields only a VPC IP); there is
**no VXLAN infrastructure in terraform at all** — `grep '14789\|4789\|vxlan'`
over `terraform/` and `deploy/` returns nothing, so no firewall rule exists for
the UDP port the generator emits; routed pod management is the generator's own
named prerequisite; and per-host OOB scoping assumes one fabric host. No test
references `_shard`, `--host` or multi-host anywhere, and
`REVIEW-2026-07-27.md:1892-1895` records that sharding *"has never run against a
fabric … verified symmetric over 1600 synthetic links and has produced zero real
tunnels"* — with that 1600-link verification committed nowhere.

It waits for two reasons. It is loud — the generator refuses rather than
producing something wrong. And replicating a blind apply and a fleet-wide push
across N hosts is strictly worse than having them on one; this project has
already produced two multi-host defects of exactly that shape (A6: every head's
watchdog controlled every sim's fabric hosts; F5: GitHub routing selected the
right runner and targeted global NetBox state).

### 5.3 Do not hand-build VXLAN (#87) — and it is in flight, so read this

Four measured reasons, none of which is "it is hard":

1. **It was explicitly designed out, not overlooked.**
   `gpufab-sim-design.md:227` — *"R3 | EVPN/VXLAN fragile on VS | **Designed out**
   — pure L3 + plain VLAN frontend"*. `network-automation-design.md:331` —
   *"EVPN/MCLAG are explicit non-goals for v1"*. #87's title says "designed but
   not built"; the record says the opposite.
2. **The capability is unmeasured.** `FEATURE-EXTENSIBILITY.md:719-742` requires a
   probe *before* code: does `config reload` accept the tables under YANG, does
   `vxlanmgrd` create a `STATE_DB` entry, does anything appear in `ASIC_DB` under
   `SAI_OBJECT_TYPE_TUNNEL`, does a frame actually cross. The base `FEATURE` table
   has no VXLAN entry.
3. **It is arithmetically impossible on the fabric the scale target requires.**
   §5.7: a cross-host link is a substrate VXLAN tunnel at MTU **8896**
   (`scale-out-architecture.md:1376`); the frontend's documented host MTU is
   **9000** (`network-automation-design.md:138`); 9000 plus a 50-byte overlay
   header needs 9050 bytes of emulated wire. **It does not fit.** It works on s11
   only because a single-host sim's links are ordinary veths. So a hand-built
   overlay optimises exactly the configuration the roadmap says goes away — and
   the derive-time check that would refuse it does not exist.
4. **Its verification is where it will fail, and #94 is why.** A rendered VXLAN
   tunnel that never programs into ASIC state is indistinguishable from a working
   one in every artifact-level check — #87 says this itself. And `config_landed`
   cannot see it either, because `VXLAN_TUNNEL` values would be grafted from the
   box (§2).

**Since it is in flight, the useful form of this is what must ship with it:** the
§5.6 capability probe first, with its result recorded in `nos_catalog` as a
measured capability; a tier-2 locator (`STATE_DB` / `ASIC_DB` /
`vtysh show evpn vni json`) or an explicit `unverified` entry with a reason; and
an honest statement that no device-level check can distinguish "rendered" from
"programmed" until #94 lands. A fidelity gap recorded beats a check that measures
the wrong layer.

### 5.4 Do not chase #89's root cause open-endedly

A session sat half-open for 28 minutes; `clear bgp` from the spine did nothing
and from the leaf fixed it. That asymmetry is genuinely interesting and may be a
VS artefact rather than a defect. It is now **visible** — #81's authoritative
denominator found it, where the old check derived its denominator from what
answered, so a spine at 15/16 was simply 15/15. Build the detector (a
per-neighbour cross-check between the two ends, which nothing does today),
timebox the diagnosis to a day, and record what is found either way.

### 5.5 Do not do #88's SoT half

`seed.py --reset` (`:533-549`) is one blocking HTTP DELETE per object, sequential,
with no executor and no batching — while the same file carries parallel bulk
machinery for the **create** side only (`_bulk()` at `:265-309`). The object count
reproduces exactly from `expected.py` on `s1-512`: 1466 cables + 3024 IPs + 124
devices + 1388 prefixes = **6002**. Three facts worth carrying that #88 does not
state:

- **No deploy stage invokes it.** The only three `--reset` references in either
  repo are the argparse line, an error string, and a prose remediation hint
  printed to a human at `deploy/roles/fabric.sh:495`.
- **Its blast radius is wider than the site.** Cables, IP addresses and prefixes
  are deleted **globally and unscoped**; only devices are `site_id`-filtered.
- **The ~34-minute figure is asserted, not measured.** Its sole origin in-repo is
  a prose comment at `terraform/sims.tf:66-70`. `reset_topology` has no progress
  logging, no sleep and no rate limit — it runs **silent** for its entire
  duration.

Making it bulk and scoped is real work with no payoff until a removal test needs
it, and the valuable half of #88 does not: draining a leaf from a converged
fabric and asserting BGP settles to the new figure requires no SoT mutation.

---

## 6. R0 — the gap with no issue, and the smaller ones behind it

The user's stated third priority is, verbatim: *"you cannot have a config change
and no staging release and massively apply to all switches/nos config."*

**There is no open issue for it, and no code.** Measured on
`gpufab-network@18f5d4e`:

- `interim_deploy.py` accepts exactly `--profile --verify-only --hosts-only
  --setup-auth --workers --force --no-wait --converge-timeout --dry-run`
  (`:1954-1976`). There is **no device selector, no pod or fabric scope, no batch
  size, no canary, no halt-on-health.** The device set is built unconditionally:
  `switches = [n for n in topo["nodes"] if n["kind"] == "sonic-vm" and
  n["role"] != "oob-switch"]` (`:1998`). `--workers` is concurrency, not scope —
  it changes how fast all 46 are done, never how many.
- The ZTP path is no better: `render_fabric_ztp.py` is invoked with
  `--root <STAGE>` and writes the whole artifact tree at once; there is no
  per-device or per-subset publication.
- `FIDELITY-VERIFICATION-PLAN.md:183` already names the missing test —
  **FV-ZTP-04**, *"Canary rollout + health-check failure halts fleet rollout;
  rollout stops; blast radius bounded and measured"* — never attempted.

The primitives exist and nothing composes them. `--dry-run` already does *"read +
compare only; report which switches WOULD be reloaded and what differs"* — a
staging diff. #81's convergence gate is a health signal that could halt a wave.
`expected.py` can state the expected post-change figure.

**Recommendation: file it and rank it 4.** Scope: a device/pod/fabric selector, a
canary batch with a health gate between waves, and a refusal to proceed
fleet-wide without an explicit flag. ~1–2 days. It must exist before #91b, or the
first thing the GitOps loop does when it finally closes is precisely the thing
the user said must not be possible.

**Smaller unfiled gaps, all cheap and all load-bearing:**

- **`t_count "label" 0 0` passes.** `tests/lib.sh:30-40` fires the "measured
  NOTHING, which is not a pass" guard only when the *expected* side is non-zero.
  Every feature-gated assertion drives straight through it, and the doctrine this
  project is built on is not yet true where it believes it is. A few lines.
- **`manifest.py` and `render_fabric_ztp.py` have no Python unit test.**
  `test_ownership.py` and `test_manifest.py` do not exist and never have, while
  `config_landed` has ~60 checks in `test_config_landed.py`. Since `243915c` the
  manifest *is* the ownership source of truth for the push, and it is covered only
  by `t36`/`t37`, both simulation-side.
- **Two self-derived BGP denominators survived #81** — `deploy/55-unnumbered.sh:215-216`
  and `monitoring/rules.yml:11`. #81 fixed the one in `interim_deploy`; these two
  still count what answered. That is the defect #89 was found by fixing, still
  live in two places.
- **`verify.sh` asserts no alert rule anywhere** — nothing checks that
  `monitoring/rules.yml` loads or that any alert can fire. Combined with
  `alertmanager.yml`'s null receiver and the bot's non-matching allowlist (both
  recorded in `WHY-ZTP-IAC-GITOPS-FELL-SHORT.md` §3.3), the entire alerting path
  is unexercised.
- **`tests/fidelity/` is not wired into `verify.sh`.** Five F0 gates with
  committed evidence run only from their own `run-f0.sh`, whose exit status is
  broken (`fv_finish` installed as an `EXIT` trap that never calls `exit`, per
  `FEATURE-EXTENSIBILITY.md` §8). Any tier-2 device observation — including
  VXLAN's — would land in a framework the gate does not run.
- **A second, near-duplicate monitoring compose** is written at deploy time
  (`deploy/roles/observability.sh:102`) carrying the same three container tags as
  `monitoring/docker-compose.yml`, with nothing asserting they agree. That is #76's
  problem one layer further in.

---

## 7. Next week, one engineer

**Do these three.**

1. **Ranks 1–3 as one workstream — ~4 days.** In order: (a) run
   `SAMPLE=46 t33-gitops-roundtrip.sh` on a sim and publish the list of fields
   that have never matched — minutes, and it sizes everything below; (b) find what
   writes `22:73:…` into `DEVICE_METADATA.mac` on the box and when, then take the
   #93 decision with that in hand; (c) make `config_landed`'s expected side come
   from the artifact `config_db` rather than the graft, and have the push carry
   owned tables from it. **Deliverable:** a committed test red on
   `e9d5f21`/`18f5d4e` and green after, plus a named list of every field the
   artifact declares and the push does not derive. Expect more than `mac`.

2. **#91a plus the three breaks the issue does not mention — half a day.**
   `drift.py` accepts `--post-metrics`/`--update-issue` or the workflow stops
   passing them; `validate.yml`'s path filter and a non-vacuity assertion;
   `deploy.yml:34`'s device extraction. Add the one-line report the retrospective
   asks for — *"drift-check: last success never"* — to the gate. Cheapest
   restoration of a real GitOps property available, and a workflow that cannot
   fire hides which of the remaining breaks is real.

3. **The gate-integrity batch: #75 + #84 (one incident) + #61 — ~1.5 days.**
   Three lines of product code — `deploy/lib.sh:390`,
   `monitoring/gpufab_exporter.py:27`, `services/tacacs/setup_auth.sh:52` — plus
   the assertions that prove each. After it the gate has no permanently-red phases
   and no non-fatal component that can un-gate a good build, so its verdict is
   usable again. **Two cautions, both of which turn this from a one-liner into a
   day:** making `70-telemetry` non-blocking lets a genuinely dead exporter reach
   the gate, so `t04-roles.sh:67` must be observed firing first; and it must not
   convert `t13` into a check that observes nothing and reports success. While a
   build runs, spend fifteen minutes on #95 and thirty on #83's env-var
   reachability (§4.5).

**Deliberately leave.**

- **R0** — rank 4, and it still waits a week. It is a day or two, but it is
  design work that wants #94's shape settled first, and nothing is being applied
  automatically today.
- **#55**, **#91b**, **#88**'s SoT half, **#62**, **#85**, **#89** — all real,
  all sequenced behind something above. #55 in particular reads like a one-line
  flag and is 3–5 days (§5.2); do not let it be picked up as a filler task.
- **#87** beyond the capability probe.
- **#63** — close it this week, in ten minutes. **#83** — thirty minutes of code
  (§4.5), then close.
- **#76** is the one item ranked 7 that is *not* in the week. It is cheap and it
  is real drift today, but it competes with three items that each unblock
  something, and it needs a decision about the netbox-docker leg before the work
  is well-defined.

---

## 8. Where this disagrees with the stated priority

Stated: ZTP, IaC and GitOps are the centre of the sim; features must be
configurable rather than requiring re-architecture; release scope must be
controlled.

- **"Features configurable, not re-architected" — agreed, and it is rank 3.** The
  highest-value work open is exactly this, arriving as a correctness fix. The
  manifest half already landed (#90, network `243915c`); what is missing is the
  push reading the artifact.
- **GitOps — agreed as a destination, disagreed as a starting point.** Repair the
  three broken workflows now, because two are green while measuring nothing. Do
  not build the apply until the landed-check is honest (§5.1). Note also that
  **two links are missing, not one**: there is no commit→NetBox path anywhere.
  `seed.py` has two operator-invoked call sites (`deploy/30-seed.sh:8,10` and
  `tools/gpufab.py:507`) and **zero CI callers**; the only relay runs the other
  way, NetBox→GitHub (`bot/webhook_relay.py:49-55`).
- **Release scope control — agreed, and invisible in the tracker.** No issue, no
  code, both delivery paths fleet-wide by construction (§6). This was the most
  surprising thing found while ranking: a stated priority with coverage of zero.
- **VXLAN — disagreed, on four measured grounds (§5.3)**, the sharpest being that
  the frontend overlay as designed **cannot fit** on the sharded multi-host fabric
  the 200–500K target requires: 9000 + 50 > 8896. It works on s11 because s11 is
  one host.

The uncomfortable summary: **the pillar called the centre is one afternoon away
from honest and three or four days away from real, and the thing standing between
it and being worth having is a comparison that has been asking the box whether it
agrees with itself.**

---

## Appendix — how this was established

- Issue bodies and comments read in full via
  `gh issue list --repo gpufab-platform --state open --limit 100 --json
  number,title,body,labels,comments` — 18 open. Closed issues #92, #96, #90, #82,
  #74 and #58 read for cost calibration.
- Code claims verified by reading `gpufab-network@18f5d4e` and
  `gpufab-platform@e9d5f21` on the workstation, across three independent
  read-only sweeps (GitOps/CI surface; the push and ownership machinery; the test
  and deploy plumbing), each required to answer CONFIRMED / REFUTED /
  CANNOT-DETERMINE with a file and line. Four issue claims came back REFUTED and
  are recorded in §4.7 rather than dropped.
  **No host was contacted; `s11` was deliberately untouched.**
- **A line-number trap worth knowing:** the local `main` ref in
  `gpufab-platform` is 45 commits stale while the checkout (`o5-merge`) is
  current. #75's `lib.sh:383` is correct against that stale ref and is line
  **390** in the code that runs. Line numbers in this document are from the
  working tree.
- The §2 finding was read directly at `interim_deploy.py:593-594, 634, 1268,
  1426-1447, 1473-1476, 1502`, not taken from the issue text.
- Design context: `WHY-ZTP-IAC-GITOPS-FELL-SHORT.md`, `FEATURE-EXTENSIBILITY.md`,
  `ISSUE-REGISTER.md`, `HANDOFF-2026-07-29.md`.
- **Inferred, not measured, and flagged as such:** every cost estimate; the claim
  that #97 will find fields beyond `mac` (#97 asserts it; nothing enumerates it);
  the identity of whatever writes `22:73:…` on the box, which is the measurement
  #93 needs; the `~34 min` `--reset` figure, which is a prose comment in
  `terraform/sims.tf`; and the 2026-07-28 cold-run figures quoted as context
  (**20m57s deploy, 46/46 in-sync, `push.all` 20.31s, BGP 1464/1464, gate 742
  passed / 7 failed across 36 phases**), which were reported in session and are
  committed nowhere — the last figure committed anywhere is 24m11s, in #58's
  09:45Z comment.
