# Issue convergence — how this backlog comes down, and what "down" means

**Question asked:** the tracker reads 40 open / 93 closed / 133 total. Today closed
about 20 and opened about 20, and not one previously-open issue closed. Working
harder appears to convert one fix into two new issues. How does this converge?

**Scope of evidence.** Every number below is measured from
`gpufab-platform` issue bodies and comments (all 133 fetched, bodies *and*
comments), from the three local repos at platform `dc9a05d` / network `b82f07a` /
docs `1d95539`, or from `git log`. Claims taken from an issue *title* are marked as
such. **Twelve open issue bodies were checked against the tree and found materially
wrong** — see §4.7 and §4.9.

> ### Read this before re-checking anything here
>
> **`gpufab-platform` is checked out on branch `o5-merge` at `dc9a05d`, which *is*
> `origin/main`. Its local `main` ref is stale at `8d4c7ff` — 32 commits behind.**
> Verified: `git rev-list --count main..HEAD` = **32**; `git rev-parse origin/main` =
> `dc9a05d`. Anyone auditing "at `main`" without checking this will conclude that
> #124, #128, #130 and the entire telemetry round are unfixed. Two of the wrong
> claims catalogued below have exactly this shape. Check the ref before you check the
> code.

---

## 1. The recommendation

**This backlog is not a leaking fix loop. It is a 32-hour-old census that is nearly
finished, and it converges by finishing it, batching five structural fixes, and not
running a feature build alongside a sweep.** The decisive measurement is that the
*regression* spawn rate — new defects created by the act of fixing — is **0.62 per
closure overall and 0.10 per closure outside the single EVPN feature build** (§2).
Sixty-four per cent of the new issues are pre-existing debt that three deliberate
inventory sweeps wrote down; they were always true, nobody had looked. Meanwhile the
closure engine sustains **1.19 issues/hour with a median issue lifetime of 3.8
hours**, and **at zero arrivals the current 40 open clear in 33.6 hours** of exactly
the work already being done. So the answer is not "stop filing" and it is not "work
harder": it is **(a)** declare the census closed — the sweeps enumerate finite
surfaces (SNMP MIBs, exporter series, dashboard panels) and are essentially done;
**(b)** close **ten** issues that should never be fixed and file three honest
replacements for them (§4); **(c)** spend about a working week on five structural
changes that retire the rest as *classes* rather than one at a time (§5); and **(d)**
serialise feature work against sweep work, because a feature build measurably costs
1.5 new defects per closure while everything else costs 0.10. That takes **40 → about
12**, and 12 pure causes is not a backlog in distress — it is the normal residue of a
system that works. **s11 built cold in 24m11s, was gated by `verify.sh`, converged
1464/1464 BGP sessions and 16/16 EVPN, and is holding steady.** The open issues are
the observability and durability debt *around* a working fabric, not a queue of things
stopping it.

**Three things would change this answer and none of them is engineering capacity.**
First — the mechanism behind the whole complaint — **this project has a ~10-hour
closing window and nothing has ever escaped it.** The longest-lived issue it has ever
closed is **9.66 h** (#74); all 93 closures happened within 24 h of filing; and there
is a clean unbroken gap between 9.66 h and 13.9 h, the age of the *youngest* survivor
(§2.7). The 20 "stuck" issues are not being repeatedly passed over — they are past the
only window in which this project has ever closed anything. Second, **fourteen of those
twenty are blocked on an unmade decision or are simply unowned, not on difficulty**
(§3.4): nine decisions, an hour of someone's judgement. Third, **twelve of the forty
open issues contain a claim that does not survive a read of the repo** (§4.9), each
catchable by one command. **Fixing the filing method and taking nine decisions is worth
more than any structural change in §5**, and costs a fraction of the time.

**The premise of the question is measurably false in five places, and each
correction matters.** They are in §2 and §7; the most important is that **nothing has
survived weeks — the oldest open issue is 33.5 hours old.**

---

## 2. The spawn rate, measured

### 2.1 First, the count is not what it appears

**53 of the 93 "closed" issues were never open work.** Issues #1–#54 (excluding #53)
were filed *and closed within 1–2 seconds each* on 2026-07-28T00:32:47–00:34:42 — a
bulk import of `design/ISSUE-REGISTER.md` by `tools/file_issues.sh`, recording
defects already fixed. `git show e80ebee`: *"docs: issue register — all ~54 defects
with their closing commits."*

Removing the import gives the real tracker:

| | measured |
|---|---|
| Issues genuinely tracked | **80** |
| Closed by doing the work | **40** |
| Open | **40** |
| **Closure rate on genuinely-tracked work** | **50 %** |
| Age of the entire tracker | **32.1 h** (first #1 `2026-07-28T00:32:47Z`, last #133 `2026-07-29T08:37:33Z`) |
| Median lifetime of a closed issue | **3.8 h** |
| Closed in under 8 h | **37 of 40** |

A project that has closed half of everything it has ever tracked, in a day and a
third, with a median fix-to-close of under four hours, is not failing to converge.

### 2.2 Rates

Window boundaries: `f013a80` = `ISSUE-PRIORITY.md` committed (2026-07-28 19:55:57Z);
`1a824c0` = the previous handoff (2026-07-28 21:48:57Z).

| period | hours | opened | closed | arrival:closure | net |
|---|---|---|---|---|---|
| 07-28 00:32 → 21:48 | 21.3 | 47 (2.21/h) | 27 (1.27/h) | 1.74 | +20 |
| 07-28 21:48 → 07-29 10:07 | 12.3 | 33 (2.68/h) | 13 (1.06/h) | 2.54 | +20 |
| **whole tracker** | **33.6** | **80 (2.38/h)** | **40 (1.19/h)** | **2.00** | **+40** |

Closure throughput is **flat at ~1.2/h across both periods**. Nothing has slowed
down. What changed is arrival, from 2.21/h to 2.68/h. **The backlog shrinks whenever
arrivals fall below 1.19/h**, and clearing the current 40 at that rate with no new
arrivals takes **33.6 hours**.

### 2.3 The ratio that actually answers the question

The naive 2.54 conflates three different things. Classifying all 33 new issues by
*why* they exist, with a quoted causal sentence required for every edge:

| class | n | share |
|---|---|---|
| **ORPHAN** — no causal parent; found by a sweep | 10 | 30 % |
| **ADJACENT-DISCOVERY** — pre-existing debt found while working nearby | 11 | 33 % |
| ADJACENT-DISCOVERY, fabricated and closed INVALID | 2 | 6 % |
| **REGRESSION** — the fix created the defect | 6 | 18 % |
| **INCOMPLETE-FIX** — the remainder of a fix | 2 | 6 % |
| **DOWNSTREAM-REQUIREMENT** — enhancement follow-on | 2 | 6 % |

| ratio | value |
|---|---|
| naive (opened / closed) | **2.54** |
| causal (attributable to closed work / closed) | **1.77** |
| **regression-only (REGRESSION + INCOMPLETE-FIX / closed)** | **0.62** |
| regression-only, parent must have closed in-window | **0.38** |

**Split by whether the closure was EVPN feature work:**

| | closures | children | children/closure | new-debt children | **new-debt/closure** |
|---|---|---|---|---|---|
| EVPN lineage (#87, #104, #117, #126) | 4 | 15 | 3.75 | 6 | **1.50** |
| Everything else (10 closures) | 10 | 7 | 0.70 | 1 | **0.10** |

**Six of the eight new-debt issues — 75 % — come from one feature build (#87 EVPN,
designed-but-unbuilt to live in 12 hours) and its own immediate fix (#104). The other
ten closures produced one incomplete-fix between them.**

### 2.4 What produced the orphans

Nine of the ten orphans came from three deliberate inventory sweeps plus one document
reconciliation; one from a user report.

| orphans | producing activity |
|---|---|
| #113, #114, #115 | the SNMP sweep — `design/TELEMETRY-INVENTORY.md` (`d2dcf54`) |
| #108, #109 | management/routing telemetry build (`5c8a439`, `bc4d336`) |
| #110, #111, #112 | dashboard-vs-exporter cross-check, filed as a batch at 23:00:01/03/04 |
| #102 | bringing `HANDOFF-2026-07-29.md` current |
| #125 | user report — *"the fabric topology is not rendering"* |

Corroborated independently in the tree: `HANDOFF-2026-07-29.md:1192`, of
`TELEMETRY-INVENTORY.md`, states **"This is where eleven of the twenty new open
issues came from."** And that document's own framing is a census, not a bug hunt:
*"The question was not 'what metrics could we add'. It was: for each requested item,
is the number produced by something doing the work, or is it produced by the
emulation?"*

### 2.5 What this implies

**The backlog is being inventoried, not multiplied.** 21 of 33 new issues (64 %) are
pre-existing debt written down — #127 says it in as many words: *"Found while fixing
#126; **it predates that work***." Only 8 of 33 (24 %) are debt the work created, and
three-quarters of those trace to one feature build.

Three consequences follow, and they are the whole strategy:

1. **A census terminates.** These sweeps enumerate finite surfaces. Once every
   `SAI_PORT_STAT_*` field, every exporter series and every dashboard panel has been
   adjudicated once, that arrival stream stops. It does not recur at 2.68/h.
2. **The fix loop does not leak enough to prevent convergence.** At 0.62 — and 0.10
   outside feature work — each closure retires more than it creates. This backlog
   *can* be worked down. That is the single most important finding here, and it
   directly contradicts the premise of the question.
3. **Feature builds are the expensive thing, and they are schedulable.** 1.50
   new-debt issues per closure is the measured price of turning on EVPN. That is not
   a defect in the process; it is what it costs to build a feature in a system with
   this much coupling. **The error was running it concurrently with two sweeps**, so
   the arrival curves added and the result looked like a runaway.

### 2.6 The chains are terminating

Deepest causal chain — five edges, six nodes, 12 h 20 m:

```
#87  (EVPN shipped, 20:16 Jul-28)
 └─ #104  REGRESSION   "found in the feature that created it"
     └─ #124  REGRESSION   "the coincidence it relied on ended"
         └─ #126  REGRESSION   "found while building the ASIC next-hop oracle (#124)"
             └─ #128  ADJACENT    "found while publishing the anycast-gateway artifacts"
                 └─ #133  INCOMPLETE-FIX   "#128 closed one hole… the class is wider"
```

Children per generation: **#87→3, #104→6, #124→1, #126→4, #128→1, #133→0.** The
branching factor is decaying. That decay *is* the convergence signal.

### 2.7 The closing window — the mechanism behind the whole complaint

This is the single most explanatory measurement in the document.

| | measured |
|---|---|
| **Longest-lived issue this project has ever closed** | **9.66 h** (#74) |
| Closed issues closed within 24 h of filing | **93 of 93 (100 %)** |
| Median lifetime of an issue closed in the session | **0.83 h** |
| Age of the **youngest** survivor (#100) | **13.9 h** |
| Age of the oldest survivor (#55) | 33.5 h |

**There is a clean, unbroken gap between 9.66 h and 13.9 h.** No issue has ever been
closed more than 9.7 hours after it was filed, and **every one of the 20 survivors is
already past that ceiling**. Ten currently-open issues (#118–#133) are still inside the
historical closing window; all twenty survivors are outside it.

So the survivors are not a queue being repeatedly passed over. **They are past the only
window in which this project has ever closed anything**, and the probability of a
survivor closing under the current working method is, empirically, zero.

The cause is not neglect — it is the project's own doctrine working as designed. The
method that makes this codebase correct is stated at `HANDOFF-2026-07-29.md:33-75`:
*"stop reasoning and go and look at the box… run it, and run it from blank."* **Its
cost is that the issue in front of the running system is always the issue that gets
closed.** Anything that predates the current session has no running system in front of
it, so it is never the next thing looked at.

**That is the finding that makes this backlog tractable**, because it says the fix is
scheduling, not effort: something must deliberately re-enter old issues into the
window. §6.3 names the cheapest version.

**Caveat, stated because it cuts the other way:** #133 is open and explicitly
enumerates its own unfiled next generation — `seed.py` (*"arguably the worst of
these"*, on a live render path, setting `PEER_ASN`/`POD_INFRA`), the 15
`design/profiles/*.yaml`, `/opt/gpufab/secrets/{tacacs_key,snmp_secret}`, and
`ENTRY_POINTS` being a 1-tuple. Four more holes in the same class, none yet an issue.
And #130/#132 closed at 09:41, *after* the last issue was filed, so they have had zero
elapsed time to spawn. The ratios slightly understate eventual yield.

---

## 3. Classification of the 40: instances vs causes

### 3.1 The load-bearing number

| | count | issues |
|---|---|---|
| **INSTANCE** — a structural fix closes it unread | **18** | 76, 85, 86, 95, 97, 101, 105, 107, 108, 113, 114, 115, 118, 119, 121, 124, 129, 131 |
| **CAUSE** — root defect or missing capability; bespoke work only | **13** | 55, 61, 62, 63, 88, 89, 94, 98, 99, 100, 109, 120, 127 |
| **BOTH** — an instance half plus a bespoke half | **9** | 75, 83, 84, 91, 93, 102, 116, 122, 133 |

**18 of 40 are pure instances (45 %). 27 of 40 have something a framework rule can
retire. 13 are pure causes.** Nothing was left unclassified.

By label: 32 `bug`, 4 `enhancement`, 4 unlabelled (#55, #61, #62, #63). 24 of 40 name
a specific file — often a `file:line`; 16 do not.

### 3.2 Mechanism families

Grouped by **defect shape, not component** — batching by component is what produces
work that shares nothing.

| family | n | members | mechanism |
|---|---|---|---|
| **F1 blind assertion** | 3 | 108, 121, 91 | present, named, structurally incapable of a FAIL |
| **F2 self-referential comparison** | 3 | 94, 97, 93 | both sides derive from one source |
| **F3 fabricated / inert metric** | 5 | 113, 114, 115, 118, 124 | served, parses, plausible, not a measurement of its name |
| **F4 runtime-only state** | 2 | 127, 120 | config in RAM, dies on reload |
| **F5 work outside the repo** | 2 | 102, 95 | a number or script no committed artifact produces |
| **F6 provenance blind spot** | 5 | 133, 76, 101, 107, 119 | a change that fails to invalidate the staleness reporter |
| **F7 default naming the wrong system** | 3 | 129, 131, 122b | a default that silently points work at a dead system |
| **F8 missing capability** | 7 | 55, 62, 63, 88, 98, 99, 109 | nothing broken; the thing does not exist |
| **F9 oracle pinned to a coincidence** | 1 | 61 | asserts a level that happened to agree, not the invariant |
| **F10 failure nobody consumes** | 3 | 84, 116, 75b | a component fails and writes no state anything reads |
| **F11 two derivations of one value** | 1 | 105 | `_ABBR` says `fe`, three call sites do `fabric[:2]` → `fr` |
| **F12 unreachable knob** | 1 | 83 | env var read under bare `sudo`, which strips the environment |
| **F13 genuine substrate defect** | 2 | 89, 100 | no framework change touches these |
| **F14 population excludes the failing member** | 2 | 85, 86 | the assertion can fail; it is never applied to what broke |

**F8 is the largest at 7 but is not a mechanism** — it is the residue of things that
do not exist. The largest genuine mechanisms are a three-way tie at 5: **F3**,
**F6**, and **F1+F14 merged** (#108 sits in both; the merged shape is *"reported
success having observed nothing about the thing that failed"*).

### 3.3 The project's signature defect, measured in the harness

This is the mechanism the project's own working agreement names, and it is worth
sizing precisely because the countermeasure already exists and does not reach it.

Measured across `gpufab-platform/tests/` at `dc9a05d`:

| measurement | value |
|---|---|
| test suites | 46 |
| assertion call sites (`t_count`/`t_min`/`t_zero`/`t_eq`) | **1039** |
| suites carrying a demonstrated-failing control | **21** |
| suites with none | **25** (t01–t26 except t10/t22, plus t29) |
| assertions living in control-less suites | **275 (26 %)** |
| `${x:-0}` occurrences in `tests/` | **332** |
| assertion lines that launder a measurement into `0` before asserting | **184** |
| — of which `t_zero "<label>" "${x:-0}"` — the exact #108 shape | **31** |
| — of which `t_count` with **both** sides laundered — the `t_count 0 0` family | **8** |

**The countermeasure is in the wrong place.** `tests/lib.sh:66-77` hardened `t_zero`
to reject an empty or non-numeric observation, with a comment explaining that this is
"the ONE helper in this file that can be fooled by a measurement which never ran."
It is defeated at **184 call sites**, because `${x:-0}` converts *"the measurement did
not run"* into a syntactically perfect `0` **before the assertion library ever sees
it**. The guard cannot fire on a value that was laundered in the argument expression.

The eight `t_count 0 0` sites are `t38:195,196`, `t17:111,112`, `t39:705,706,707`,
`t43:272`. Three of those are exactly the assertions #121 indicts.

**And the same-line count of 184 is itself an undercount.** Verified against the
source: #108's claim about `t03` is true and my grep missed it, because the laundering
is one loop iteration away from the assertion —

```sh
# tests/t03-fabric.sh:63-70
oob_with_bgp=0
for c in "${OOB[@]}"; do
  ...
  [ "${n:-0}" -gt 0 ] && oob_with_bgp=$((oob_with_bgp+1))
done
t_zero "OOB switches carrying fabric BGP" "$oob_with_bgp"
```

`$oob_with_bgp` is a well-formed `0` by construction, so `t_zero`'s hardening passes
it. Worse: if `OOB` is empty — no OOB switches found at all — the loop body never
runs and the assertion still passes. **A fabric with no OOB switches is
indistinguishable from a healthy one.** `t03` was last modified `1597c89`
(2026-07-25), so this defect is four days old and predates by three days the issue
that found it. It is inventory, not churn.

**This matters for §5:** a same-line lint would catch 39 sites and would *not* catch
`t03` or `t39`. Both produce arithmetically perfect numbers. Only perturbation
catches those.

### 3.4 Why the 20 oldest are still open — and it is not because they are hard

The measured survivor set — open at `1a824c0` and still open — is **#55, #61, #62,
#63, #75, #76, #83, #84, #85, #86, #88, #89, #91, #93, #94, #95, #97, #98, #99,
#100.** (The brief's list is wrong in four places; see §7.) Ages: oldest 33.5 h,
median 24.3 h. **"Surviving" overstates a day.**

**All twenty are still true.** Not one has been fixed, partly fixed, or rendered
unreachable; every file named in every survivor still exists. The decisive single
fact: **`gpufab-network/tools/interim_deploy.py` has zero commits since `18f5d4e`** —
byte-identical to the tree `ISSUE-PRIORITY.md` measured 30 minutes before it was
written. Everything #93 / #94 / #97 / #99 / #83 says about the push path holds verbatim.

Classified with a per-issue check against the tree:

| bucket | n | issues |
|---|---|---|
| **NEEDS-A-DECISION** | **8** | 93, 62, 63, 76, 83, 91, 99, 100 |
| **UNOWNED** — nothing hard, nobody picked it up | **6** | 75, 84, 85, 86, 95, 97 |
| **HARD** — genuinely multi-day or architectural | **4** | 94, 98, 55, 89 |
| **BLOCKED on another issue** | **1** | 88 (on #98) |
| **STALE-PREMISE** | **1** | 61 (see §4.2) |

**Fourteen of twenty — 70 % — are a decision or an afternoon. Only four are hard.**

**And the unowned bucket has the same cause as the decision bucket, which is why
§2.7 matters more than either.** The cleanest demonstration is **#84**: its fix is one
line at `gpufab_exporter.py:27`, **five commits hit that file on 2026-07-29, none
touched line 27**, and commit `03941e6`'s own body says *"No new filesystem probe is
added anywhere; #84 is still open at line 27."* The bug was known, the file was open,
it was stepped around. Not difficulty — recency.

Costs, verified: **#95 is fifteen minutes** of text (`CLAUDE.md` is 211 lines, mtime
**2026-07-27 01:52 — before the incident**; a grep for
`secret|password|credential|redact|_safe_key` returns five hits, **none of them
guidance**). **#83 is two lines in two files**, and the correct idiom already sits one
stage away at `deploy/55-unnumbered.sh:61` (`sudo -E env NETBOX_URL=…`). **#86 is 1–2
hours** and its determinism reproduces exactly — deriving from `fabric_model` and
sorting as `t23` does puts the OOB pair at indices **24/25** on `s0-64` and **41/42**
on `s1-512`.

#### The nine decisions, as a list a human can work in an hour

1. **#93** — does the render own `DEVICE_METADATA.mac`, or does containerlab?
   *(`render_fabric_ztp.py:624` is the only `mac` write in either repo. The measurement
   is currently blocked on #107 and #127 — take those first.)*
2. **#61** — keep the 6000 element budget and make the `tier` rung explicit-only, or
   lower it so `auto` can reach `tier`? *(§4.2 recommends closing #61 as filed and
   re-filing this; the decision then attaches to the replacement, not to #61.)*
3. **#62** — is per-sim GCS isolation in scope? *(`grep google_storage_bucket
   terraform/*.tf` returns nothing — the bucket is not in terraform at all, so there is
   no IAM object to condition. `scale-out-architecture.md:2196` already lists it under
   "NOT a boundary".)*
4. **#63** — close as won't-fix for v1, or commit to per-user IAM? *(`terraform/
   fabric.tf:150` maps every admin key to the single `ubuntu` user on every instance.)*
5. **#76** — is the netbox-docker leg in scope? Without that answer the work is
   undefined.
6. **#83** — throttle push concurrency during convergence, or make the knob reachable
   and close as a recorded fidelity limit? Two lines either way.
7. **#91 — this one is a live contradiction on the tracker and must be adjudicated.**
   **#98 says delete `validate.yml` and `drift-check.yml`** (*"a green check that
   validates nothing is worse than no check"*); **#91's newest comment says fix them**
   (*"`validate.yml` already contains a `vtysh -C` FRR gate that has never executed.
   That gate would have caught #117"*). **Two open issues recommend opposite actions on
   the same two files, and nobody has decided.** Partly overtaken:
   `tests/t45-frr-syntax.sh` (`1034ef3`) reimplemented that FRR gate outside CI.
   **ADJUDICATED 2026-07-29 → delete (#98 wins).** Not "partly" overtaken —
   *fully*: the CI gate ran `quay.io/frrouting/frr:10.2.1` on `ubuntu-latest`,
   and #117's `route-target all` is accepted by FRR 10.2.1 and rejected by the
   **10.3** the switch image ships. A fixed `validate.yml` would have gone green
   on the exact config that broke both spines; `t45` asks the switch's own `bgp`
   container instead. #91's "that gate would have caught #117" is therefore
   false. Both files deleted on branch `i91-delete`; rationale recorded in
   `gpufab-network/.github/workflows/README.md`, decision in
   `GITOPS-CLOSURE.md` §10. `drift.py` kept — see §10 for the two defects to fix
   before it is given a caller again.
8. **#99** — is one canary switch plus the existing convergence gate enough, or are
   waves required, and what is a wave: switch, rack, pod, plane? #126 already supplied
   the missing requirement — *a release mechanism must know, per feature, whether a
   partial rollout is SAFE, DEGRADED or INCOHERENT* — and
   `deploy/checks/c5-anycast-gw.sh:12-19` records the reasoning. **This project
   performed a three-wave staged rollout by hand on 2026-07-29 and committed no
   mechanism for it** — the same shape as #130 and #132, both of which *were* closed.
9. **#100** — does the 254-byte MTU deficit matter for jumbo-frame fidelity?
   *(`grep -rn mtu terraform/` returns nothing; `design/policy/addressing.yaml:32` is
   read by nothing; no test asserts an MTU anywhere.)*

Plus one that is Bob's alone because it costs money: **#55 — is multi-host in scope
now?** Passing `--host` is ~5 lines; the prerequisites are 3–5 days plus a multi-host
fleet and at least two builds. Note that the 2026-07-29 EVPN work built *overlay* EVPN
and added **no substrate VXLAN infrastructure** — `grep -rni 'vxlan|4789' terraform/
deploy/` returns only `deploy/checks/c4-evpn-vxlan.sh`, an on-box capability probe — so
the firewall rule the cross-host tunnels need still does not exist.

**Settling 1–9 moves eight issues out of "blocked on judgement", and closes #63 and
#83 outright.**

### 3.5 Ranking did not change behaviour, and it is worth knowing why

`ISSUE-PRIORITY.md` (`f013a80`) ranked 19 entries. Amended once since, by a **one-line**
filename change. Measured against what actually happened:

- **13 issues closed in the session window. Zero were on the ranked list.**
- **13 of 13 were also *created* inside the window.** Median lifetime **0.83 h**.
- Widening to `f013a80`: 14 closed, **exactly one on the list — #87**, ranked **17 of
  19**, under a section headed *"Do not hand-build VXLAN (#87)"* and listed under
  *"Deliberately leave."*
- **Ranks 1–16: zero closed, zero started.** The handoff says so itself
  (`HANDOFF-2026-07-29.md:1710`): *"The three-item `#93 → #97 → #94` workstream is still
  right and still unstarted."*
- The single cheapest action on the whole list — *"run `SAMPLE=46
  t33-gitops-roundtrip.sh`, minutes, and it sizes everything below"* — was never run.
  `t33:56` still reads `SAMPLE="${SAMPLE:-4}"` and `verify.sh:308` still invokes it
  with no override. **The only two occurrences of the string `SAMPLE=46` in all three
  repos are inside `ISSUE-PRIORITY.md` itself.**

Three mechanisms, all fixable:

1. **The ranking was never written where work is selected.** The tracker carries
   **exactly two labels across all 133 issues** — `bug` (52) and `enhancement` (9). No
   priority, no severity, no `blocked`, no milestone; **72 issues carry no label at
   all**. Of the 19 ranked entries, **3** got a comment stating their rank. The other 16
   have no on-tracker trace that the ranking exists. **It lives in a markdown file in a
   different repository.**
2. **It was stale on arrival.** #98 and #99 were filed at 19:37:00Z and 19:37:01Z —
   **19 minutes before** the doc was committed at 19:55:57Z saying of release scope
   *"There is no open issue for it."* Coverage was 18/20 open issues at commit time; it
   is **17/40 (42 %)** now.
3. **The one ranked item that was executed generated the backlog that consumed the
   session.** #87 was fully built, well past the "capability probe only" the doc
   allowed. 17 of the 33 new issues reference the overlay, and 9 of the 13 closures were
   EVPN-derived. **Doing the thing ranked 17-of-19 with "do not do yet" attached
   produced roughly half the new tracker.**

Only one decision record was written in the entire window — `design/I87-EVPN-DECISION.md`,
for #87. **Zero decision records exist for any of the 20 survivors.**

---

## 4. Issues to close without fixing

**Ten closures, in six categories, plus three replacement issues to file.** Each is
defended with what was checked. Candidates that were examined and *rejected* are in
§4.8 — that list matters as much as the closures.

| action | issues |
|---|---|
| Close as **DONE** — fixed in the tree | **#124** |
| Close as **INVALID** — the premise is a failed search | **#119**, **#61** |
| Close as **WONT-FIX / v1 non-goal** | **#63**, **#62** |
| Close as **inherent and already recorded**, replaced by one new issue | **#113**, **#114**, **#115** |
| Close as **DUPLICATE** | one of **#127 / #120** |
| Fix two lines, then close as a recorded fidelity limit | **#83** |
| **File one replacement:** make `TELEMETRY-INVENTORY.md` §1.5's refuse-list binding in code | *(new)* |

### 4.1 Already fixed in the tree — close now (1)

**#124 — ASIC next-hops compared against BGP neighbour count.** **Verified fixed.**
`tools/expected.py:260-261` publishes `asic_next_hops_min_by_device` /
`_max_by_device` / `asic_next_hops_total`;
`monitoring/grafana/dashboards/fabric-health.json:1024` compares against the band, not
`bgp_neighbors`; `tests/t41-mgmt-route-truth.sh:159-162` asserts it. Three commits
name it in their subject: `85c8385`, `b3ef47f`, `1473e16`. Its one stated open
question — *"Why does `fr-leaf01` agree while `fr-leaf02` and `fr-leaf03` are each
+2?"* — was answered by #126 (closed): the gateway was not anycast, so each address
was owned by one leaf and resolved remotely by the other two, and a remote resolution
is the extra next-hop.

**Mechanically confirmed:** across both repos, **#124 is the only open issue with a
dedicated fix commit naming it in the subject line.** Every other open issue genuinely
has no fix landed. There is no wider "already fixed, forgot to close" problem — this
is the one.

### 4.2 Close as INVALID — the premise is a failed search (2)

Both of these are the **#103 failure mode still live in the open set**: a `grep` that
returned nothing was read as evidence of absence.

**#119 — "nothing copies dashboards from the checkout to the path Grafana mounts."**
**Verified invalid**, by running both greps:

```
grep -rl "ops/monitoring" deploy/*.sh   ->  (nothing)   rc=1     <- the issue's grep
grep -rl "ops/monitoring" deploy/       ->  deploy/roles/observability.sh
```

`deploy/*.sh` is a **non-recursive shell glob** — it expands to a file list, so `-r`
does nothing and `deploy/roles/` is never visited. The copy the issue says does not
exist is at `deploy/roles/observability.sh:100`:
`sudo cp -r "$SRC/monitoring/grafana" /opt/gpufab/ops/monitoring/`. The issue's
proposed fix — *"the telemetry stage should install the dashboards into the mounted
path"* — **is already what the code does.** Worse, the issue's own follow-up comment
builds a second correction ("the obvious fix would break scraping") on top of the
refuted premise. The observed symptom (repo 20 panels, deployed 8) is real and has a
*different* cause: the copy runs only when the observability **role** re-runs, and a
tar+scp checkout refresh does not re-run it. **File that as a narrow staleness defect;
close #119.**

**#61 — "topoview aggregation contract unreconciled across code, tests and design."**
**Verified invalid as filed**, three ways. `tests/t09-topoview.sh:28-46` reads the
budget *from code* — `BUDGET=$(python3 -c "… import gen_topoview;
print(gen_topoview.AGGREGATE_ABOVE)")`, printed as `element budget read from
gen_topoview: 6000` — and the file carries an inline comment recording that the stale
1500 was already removed. `ISSUE-PRIORITY.md` §4.7-1 says the same. And **the issue's
own second comment** says: *"MISDIAGNOSED … t09 does NOT hardcode 1500 … Every
numeric budget assertion passes."* The body's ask — *"reconcile the 1500-vs-6000
decision in all three places"* — describes work that must not be done.

There **is** a real defect underneath, and it needs a different title: at a 6000
budget, `auto` can never return `tier` for any committed profile (largest single pod
at the largest rung is 2825 elements), which breaks the pod→tier→device drill chain
and a non-numeric promise at `scale-out-architecture.md:492`. **Close #61 and re-file
that.** Leaving #61 as written has already produced one wrong diagnosis.

### 4.3 Won't-fix for v1 — state as a non-goal, not a tracked item (2)

**#63 — no per-user identity; dashboard isolation has no enforcement.**
`ISSUE-PRIORITY.md` §4.6 already reached this and the reasoning holds: closing it
properly means per-user identity and IAM across every instance — a project. The sim
is single-tenant and disposable, `scale-out-architecture.md` §5.8 already records this
as a sim boundary and never a customer boundary, and there is no second user. **An
open issue reads as "tracked toward closure", and this is not.** Record it as a stated
non-goal; reopen the day a second user exists.

**#62 — GCS artifact prefixes are attribution, not isolation.** Same argument, same
premise, and it is the same decision wearing a different hat: prefixes are only
"isolation" if there is a party to isolate from. Close both together or neither —
closing #63 while leaving #62 open leaves the decision half-recorded.

### 4.4 Close as inherent and already recorded — and file the one issue that matters (3 → 1)

**#113 (`ifInDiscards` is a boot artifact), #114 (`ASIC_TEMPERATURE_INFO` is 0 °C
everywhere), #115 (`bgpPeerRemoteAs` is negative; the LLDP `eth0` row invents a
link).** All three are true observations. All three should close, because **nothing in
this project publishes or consumes any of them**, and **every recommendation they make
is already committed** — in the same commit (`d2dcf54`) they cite as their source.

Verified:

- `git grep -nE "snmpget|snmpwalk|snmpbulkwalk|pysnmp"` across the code repos returns
  **zero** hits outside `design/` prose. **There is no SNMP poller.**
  `t23-snmp-community.sh` compares community *strings* from CONFIG_DB; it never sends
  a packet.
- `git grep -niE "temperature|thermalctld"` → **zero** in both code repos. There is no
  ASIC and no sensor; `pmon` runs no `thermalctld` because
  `/usr/share/sonic/platform/` does not exist.
- The LLDP consumer #115's scenario requires does not exist:
  `gpufab-network/tools/audit_lldp.py:12` is
  `sys.exit("audit_lldp.py: not implemented yet…")`.
- `design/TELEMETRY-INVENTORY.md` §1.5 already carries the refuse-list: item 1
  `ifInDiscards`, item 5 *"STATE_DB `ASIC_TEMPERATURE_INFO` `0`/`0` … exclude from any
  STATE_DB scraper"*, item 6 the LLDP `eth0` neighbour, plus table rows
  *"BGP4-MIB ASN fields … **DO NOT PUBLISH**"*.

**#114 is the out-of-scope-for-a-simulator case, and the honest answer is that it
cannot be fixed at all.** There is no ASIC. The value cannot be made real; the only
available action is exclusion, which is written down. An open issue implies a fix
exists. It does not.

**The one thing none of the three asks for is the real work, and it should be the
replacement issue.** `TELEMETRY-INVENTORY.md:852` claims §1.5 is *"binding rather than
advisory"*, but `git grep -niE "allow.?list|DO NOT PUBLISH|TELEMETRY-INVENTORY"` over
`tests/ deploy/ monitoring/ tools/` finds only the unrelated *features* allow-list.
**Nothing reads it.** The project's own handoff states the principle: *"A warning that
exists only in the document nobody opened first is not a warning."* File one issue —
*make §1.5's refuse-list binding in code* — and close three.

### 4.5 Duplicate pair — close one of #127 / #120 (1)

**The two agents that examined this disagreed, and the disagreement is worth
recording.** One read #127 as a strict superset of #120 (it carries a third gap:
`bgpd.conf` persisted with no EVPN). The other read both bodies in full and found
that **third gap already stated in #120's body two hours earlier** — *"`l2vpn evpn`
appears **0 times** in `/etc/frr/bgpd.conf`"* — which makes #127's stated reason for
existing separately (*"(3) is the one nobody had noticed"*) factually wrong. They were
filed **2 h 04 m apart by the same author** (#120 `01:30:56Z`, #127 `03:35:21Z`), and
#127's one genuinely distinct claim — a live stage-50 hazard — **has been retracted by
its own comment** (*"That hazard is closed"*).

**Recommendation: close #127 into #120**, carrying two lines forward (the *"do not fix
by running `config save` alone"* caution, and the retraction). Either direction is
defensible; what is not defensible is leaving both open, because one will be fixed and
the other will sit open describing the same thing.

### 4.6 Fix two lines, then close as a recorded fidelity limit (1)

**#83 — Redis Lua stall under CPU starvation tears down swss and bgp.** The stall
itself is a *density artefact*: real hardware does not run 48 switches on one CPU, and
the fabric self-healed to 1464/1464. The actionable half is small and named: the
concurrency knob `GPUFAB_PUSH_WORKERS` exists with a measured default table at
`interim_deploy.py:87-89`, and **is unreachable because both call sites
(`deploy/50-configure.sh:39`, `deploy/50-ztp-provision.sh:200`) invoke under bare
`sudo`, which strips the environment.** Two lines, two files. The
deploy-declared-complete-mid-abort half was already fixed by #81. `ISSUE-PRIORITY.md`
§4.5 reaches the same conclusion: *"thirty minutes of code, then close."*

### 4.7 Bodies that are materially wrong — correct, do not close (9)

These are not merely stale; **each overstates or misstates its defect in a way that
changes the fix.** Four were already checked in `ISSUE-PRIORITY.md` §4.7 against
`e9d5f21` / `18f5d4e` and independently re-checked here at `dc9a05d`.

- **#55 — "invokes the generator with neither `--host` nor `--profile`" is half
  wrong.** `deploy/40-topology.sh:29` *does* pass `--profile` on the branch that runs
  (`roles/fabric.sh:338` sets `TOPO_FROM_PROFILE=1`). What is passed by nothing,
  anywhere, is `--host`, and the shard path is gated behind `if args.host:`
  (`gen_topology.py:234`). **Rewrite the body; do not close** — §5.2 of the priority
  doc records the real failure as *worse* than the issue says.
- **#86 — "`t23` never covers the OOB pair" is half wrong.** `t23:103-114` covers them
  on the artifact side; only the on-box half is sampled (`SAMPLE="${SAMPLE:-5}"` at
  `:45`, `"${ROWS[@]:0:$SAMPLE}"` at `:142`). And the miss is **deterministic, not
  probabilistic**: `{pod}-oob-sw{NN}` sorts after `bk-` and `fr-`, landing at indices
  24/25 on `s0-64` and 41/42 on `s1-512`. **Rewrite the body.**
- **#89 — "`t13` derived its denominator from what answered" is simply false.** `t13`
  has used `expected.py --key bgp_peer_series` since its first and only commit
  (`t13:80-81`, `:291`). That description belongs to the pre-#81 `interim_deploy`
  census. **There is nothing to fix in `t13`** — the residual half-open BGP
  observation is real, so narrow the issue to that, or close it: `ISSUE-PRIORITY.md`
  §5.4 explicitly says *do not chase #89's root cause open-endedly*.
- **#100 — "the fabric MTU is 254 bytes short" rests on a substrate that exists in no
  code file.** The 8896 figure appears in **zero** files in either code repo —
  verified: `git grep -c 8896` over `gpufab-platform` and `gpufab-network` returns 0
  files; all **22 occurrences live in `gpufab-docs/design/*.md`** (5 files). Control:
  `9100` hits 3 files in platform code. The issue also cites
  `templates/config_db.json.j2:20` as the render path; that template is dead code —
  no caller, and no `jinja2` import anywhere on the render path. **The MTU question
  may still be real; the arithmetic in the body is against an imaginary denominator.**
- **#102 — "no build produces a committed duration measurement" is too strong.**
  `deploy/lib.sh:112-122` defines `PHASE_BEGIN`/`PHASE_END` with **exactly 6 call
  sites**, summed by `tools/phases.py:91-101`; `run_id` is a UTC start stamp and
  `lib.sh:329` an end stamp. **A total is already derivable and nothing computes it** —
  a far smaller fix than the body implies. The contradiction the issue records
  (`push.all` at 95.7 s and 20.31 s for the same build) remains real and valuable.
- **#108 — its first half was fixed 3 m 20 s before it was filed.** The exporter's
  `poll_mgmt_only()` landed in `03941e6` at `22:52:55Z`; #108 was created at
  `22:56:15Z` claiming *"the OOB switches emit no telemetry at all."* **The second
  half — that `t03`'s OOB assertion cannot fail — is live and verified** (§3.3), and it
  is the important half. Strike the first paragraph.
- **#109 — filed 2 m 59 s after the code it says does not exist.** `t41` landed in
  `5c8a439` at `22:53:17Z`; #109 was created at `22:56:16Z` claiming its grep *"returns
  no files."* `t41:20` now quotes that exact grep as its own motivation. The residual
  claim — FIB *content*, not next-hop count — still holds. **Narrow it.**
- **#116 — its telemetry premise is inverted.** The body says *"octet and packet
  counters ARE real; only error/discard are permanently zero."* There is **no octet
  metric and no error/discard metric at all**; `gpufab_port_bps` is *absent*, not zero
  (`gpufab_exporter.py:1085-1089` — `N/A` raises, `pass` skips, the series is never
  created). The `railstorm-lite.sh` no-op the issue reports is real.
- **#98 — seven of its own claims are corrected in its own comment**, and the body
  cites "#98" twice where it means "#99".

### 4.8 Examined and rejected as closure candidates

Naming these matters as much as the closures — each was a plausible duplicate or
obsolescence that **does not survive checking**.

- **#133 is a genuine remainder of #128, not a re-filing. Keep open.** The #128 fix is
  gated on `render_revision.py:272` `if path.name == "__init__.py":`, and
  `find gpufab-network/tools -name '__init__.py'` returns **0** (control: 14 `*.py` in
  the same directory). Measured against the live fingerprint (`6907cb62e3c5b6fb`, 17
  files): `seed.py covered? False`, `any profile covered? False`,
  `render.py covered? False`. `ENTRY_POINTS` is confirmed a 1-tuple at `:127`, and
  `interim_deploy.py:1990`'s `from seed import derive_topology` is AST-confirmed inside
  `def main()`, which `_module_scope_imports` skips at `:177-178`. **#128's fix covers
  none of #133's four items.**
- **#121 is not a duplicate of the closed #82. Keep open, and it is worse than
  filed.** #82 was a Python `SyntaxError` in `t10`; #121 is an `awk` field-separator
  bug in `t39` — different file, different mechanism. `t39:684-690` is unchanged, and
  against a real exporter line `$NF` is `} 1.0` so `$NF+0 == 0`. The control within the
  same file (`ev_series`, which omits the `$NF` test) correctly matches 1. **Additional
  finding: in the *enabled* branch (`:704-707`) this will emit a false FAILURE the
  moment EVPN is switched on.**
- **#122 is not obsoleted by #130's stage 52. Keep open.**
  `deploy/50-ztp-provision.sh:26` still invokes `serve.sh`, and
  `grep -n "52" deploy/deploy.sh` returns **0** — stage 52 is deliberately outside
  `STAGES`. **The destructive cold path is the one every deploy still runs**, and
  `serve.sh:35` `rm -rf "$SRV"` precedes the render at `:40` with no `trap` anywhere
  under `set -euo pipefail`.
- **#55 — do not close.** `ISSUE-PRIORITY.md:419` says so in terms: *"do not build #55
  sharding yet — and do not close it either."*
- **#62** was retained above as a won't-fix companion to #63; if that decision is not
  taken, it stands on its own merits — ~0.5 d of terraform bounding a blast radius,
  with two precedents (A6, F5) where a correct component targeted the wrong sim's state.
- **#116, #108, #129, #131, #105, #85, #99, #100, #102** — all verified live at HEAD,
  even where their bodies need correction.

**#131 got worse on verification, not better.** `deploy/lib.sh:84` is
`export NETBOX_URL="${NETBOX_URL:-http://127.0.0.1:8000}"`, which exports the wrong
default into every child process — so the renderer's own fallback never even fires.

### 4.9 On the filing bar, since the question asked directly

**The nominal rate looks fine and it is the wrong number.** Reading the closing
comment of every closed issue: **exactly two carry an invalid verdict — #103 and #123
— a 2.2 % nominal false-filing rate.** The other 91 closed with "Fixed", "Implemented",
"Done", "Verified", or a closing sha. (#111 and #112 closed with no comment at all.)
Both invalid filings were self-caught by their own author within 8 and 20 minutes.

- **#103** claimed `expected.py` counts 5 frontend switches while `gen_topology`
  builds none — *"occurrences of 'front' or '-fe-': 0."* Closing comment: *"INVALID —
  I fabricated this. The frontend plane exists and is healthy."* The token is `-fr-`,
  not `-fe-`. **The check that would have caught it:** derive the identifier instead of
  guessing it — `python3 -c "import fabric_model,gpufab; print(sorted({d['name'] …}))"`
  — then grep for a name the model actually produces. The same paragraph carried a
  second bad grep: `dc1-pod001-st` also matched two storage *host* nodes, giving "7
  storage" against a true 5.
- **#123** claimed a dashboard panel joins `key="asic_next_hops"`, a key never
  published, so it rendered *No data*. Closing comment: *"the real expression is
  `key='bgp_neighbors'`. That key IS published — 48 series."* The query was inferred
  from the panel *title* and never read. **The check:**
  `jq -r '.panels[].targets[]?.expr' fabric-health.json | grep asic` — eight seconds,
  no host required.

**Both fabricated issues had positive yield** — #103 → #105 + #106, #123 → #124, all
three real.

**But the honest bar is not "2 in 93 were bad." It is that roughly one in three open
issues contains a claim that does not survive a read of the repo.** Twelve of the 40
carry a materially wrong statement (§4.2, §4.7): #55, #61, #86, #89, #100, #102, #108,
#109, #116, #119, #124, #98. The two closed as INVALID are simply the two where the
author caught himself. Among the closed set the same pattern appears in **#117** (its
own proposed fix was also invalid — FRR 10.3 has no EVPN retention command at any
node), **#125** (its closing comment says 2365; the committed figure is 2039 and 2365
appears in no file), **#111** (its "delete the traffic panels" recommendation was
refuted by measurement — 144/144 counters strictly increased) and **#128** (its "both
natural import spellings contribute nothing" claim is wrong).

**Every one of those twelve would have been caught by a single command** — a `grep`
run recursively rather than over a glob, a `sed -n` on the cited line, a `jq` on the
query, or a `git log` on the file. The failure mode is not carelessness about *whether*
to file; it is reasoning from an assumed string instead of a read one. **That is the
project's signature defect — a check that reports success having measured nothing —
applied to the tracker instead of the fabric.**

---

## 5. Structural changes that retire classes

Ranked by issues retired per unit of work. Cost is engineering time, measured against
the actual cost of comparable committed work.

**The baseline these must beat:** the current way of closing an issue is a new test
suite. Measured from the last five: `t46` 411 lines + 17 in `verify.sh`; `t47` 751 +
19; `t44` 486 + 13; `t45` 231 + 15; `t42` 537 + 13. **~400 lines per issue closed.**
Forty issues closed that way is ~16,000 lines of new test code. That is the number the
structural options are competing against.

### 5.1 Make the refuse-list binding in code — 1 day — retires a class of 3, forces 4

`TELEMETRY-INVENTORY.md` §1.5 already enumerates, in prose, every metric this
substrate must **not** publish. `:852` claims it is *"binding rather than advisory"*.
Verified — it is not: `git grep -niE "allow.?list|DO NOT PUBLISH|TELEMETRY-INVENTORY"`
over `tests/ deploy/ monitoring/ tools/` finds only the unrelated *features*
allow-list. **Nothing reads it.**

The change: every published series declares, in code, **(a)** a liveness/inertness
expectation, **(b)** a value domain, **(c)** an expected cardinality against
`expected.py`, **(d)** a negative-control fixture for the failure it exists to detect
— and a series on the refuse-list is *absent*, never zero, because **zero is the value
that satisfies every alarm**.

This is what makes closing **#113, #114, #115** safe rather than merely tidy (§4.4):
their content becomes an enforced rule instead of three open tickets nobody can act
on. Forces the fix on **#108, #116, #118, #121**.

Why it is cheap: **enforcement is prospective.** Verified — the exporter defines 35
metrics and there is no octet, error, discard or sensor metric among them; there is no
SNMP poller at all. So this costs a schema and a check, not a migration.

The four clauses are not interchangeable, and this is the finding that sizes the work:

| issue | shape | clause that catches it |
|---|---|---|
| #113 | constant served as a measurement | liveness |
| #114 | constant served as a measurement | liveness (must reach STATE_DB, not just SNMP) |
| #115a | live but mis-encoded — 32-bit ASN in a 16-bit field; **0 of 122 ASNs fit** RFC 1657 | domain |
| #115b | live, correctly typed, **fabricated by aggregation** — 1 LLDP neighbour where the model says 32 | cardinality |
| #118 | live, typed, right cardinality, **wrong field** — `state == "Established"` with no `NoNeg` handling anywhere in `gpufab_exporter.py` | negative-control fixture |

A one-clause contract reaches 2 of them. The four-clause contract reaches **8 of the
40** — which is why it is rank 1 despite being a day's work rather than an hour's.

### 5.2 Coverage / denominator rule — hours — forces 3

Every population-based assertion declares its denominator from `expected.py` and
**FAILS when coverage < declared population.** Forces: **#85, #86, #108.**

This is the best ratio in the document, because the work is almost entirely already
done: **`tools/expected.py:244-248` already publishes `switch_mgmt_targets` 48
against `switch_bgp_speakers` 46, and names the gap in a comment. Nothing consumes
it.** The change is wiring, not derivation.

### 5.3 Closure-walk provenance for every derived artifact — 1–2 days — closes 2, forces 3

Every derived artifact — rendered tree, golden image, deployed dashboard copy, host
checkout — carries a fingerprint of its **complete input closure**, computed by
walking the closure rather than from a hand-maintained list, with `_resolve → None`
treated as data rather than absence.

Closes: **#133, #76.** Forces (each then needs one operation): **#101, #107, #119.**

Verified surface: `gpufab-network/tools/render_revision.py` is 417 lines and its
entire configuration is ~20 of them — `ENTRY_POINTS` at `:127` is a **1-tuple**;
`DATA_GLOBS` at `:139` covers only `gpufab-network/design/base/*` and
`gpufab-platform/tools/*_catalog.yaml`, so the **15 profiles under
`design/profiles/` are covered by no glob**; and `interim_deploy.py:1990` does
`from seed import derive_topology` at *function* scope, invisible to a module-scope
walk. #128 already built the queue-the-package walk, so this extends working code.
**#133 names the fix itself in its last line** — *"Then `ENTRY_POINTS`, which is the
structural fix that would have caught all of them."*

### 5.4 No default for a value that names *which* system — hours — closes 2

Require it and fail loudly; the `_require_token()` pattern applied to endpoints, and
ship the endpoint in the same file as the credential. Closes **#129, #131**, and the
fallback half of **#122**.

Verified: `deploy/roles/fabric.sh:48` is `SOT="${SOT:-10.10.0.20}"` — a **terminated
host**; `deploy/70-telemetry.sh:20-21` carries the same fallback.

### 5.5 The proposal put forward for evaluation — demonstrate every assertion failing

**Evaluated, and the honest answer is: adopt it, but it is rank 7, not rank 1, and it
would not have caught what it is credited with.**

**What it does catch — 2 of the 5 blind-assertion family:**

- **#121 — yes, most clearly.** Demonstrating `t_zero "EVPN address families up while
  NO rendered frr.conf declares one"` *failing* requires one Prometheus line with an
  EVPN AF up. Run through the committed `awk -F'"' … $NF+0==1` it yields 0, so the
  demonstration **cannot produce a FAIL** and the defect surfaces at commit time. This
  is precisely how #82 was closed: `t35` drives the committed `t10` against a stub and
  watches the assertion pass, fail-as-absent and fail-as-broken-query.
- **#108 — yes.** Constructing an OOB switch that *does* carry a session forces you to
  construct the unreachable case too, which immediately exposes that `${n:-0}` makes
  it identical to healthy.

**What it does not catch — and this is the important half:**

- **#85, #86 — no.** `t16`'s and `t23`'s assertions *can* fail; they are correct and
  simply never applied to the head, or to the OOB pair. **A fixture that satisfies the
  rule on any sampled switch leaves the pair uncovered forever.** Only §5.2 catches
  these.
- **#91 — no as scoped.** `validate.yml` is a CI gate, not a `lib.sh` assertion —
  *"it lints an empty directory and passes… it is green today, and has always been
  green, having validated nothing."* Verified: `grep -rn 'deploy\.yml\|validate\.yml\|
  drift-check\.yml'` across all 87 test files returns **zero**. Nothing tests any
  workflow, which is why all three survived.

**So the rule covers only the members where the *arithmetic* is broken, and misses
both where the *population* is wrong. §5.2 is cheaper and catches the others. They are
complements, not substitutes.**

**What would enforce it, and what it costs.** The enforcement surface is unusually
cheap here and unusually fragile:

- **There is no CI in `gpufab-platform` at all** — no `.github/` directory. The only
  mechanical gate is `.git/hooks/pre-push`, which requires every commit in
  `remote..local` to appear in `.git/reviewed-shas` (374 entries).
- **That hook is itself unversioned.** `core.hooksPath` is unset, the hook is not in
  `git ls-files`, and no `.md` in any repo mentions `reviewed-shas`. **The project's
  only enforcement mechanism would vanish on a fresh clone** — which is itself an
  instance of F5, the family containing #102, #130 and #132. *Version the hook before
  adding rules to it.*
- **The precedent already exists.** `t35` already sweeps `tests/` and `deploy/`,
  extracts every single-quoted `python3 -c '...'` block and compiles it — with the
  guard that it *"would report '0 blocks failed to compile' having compiled
  nothing"* — and is registered in `verify.sh:599`. A source-level lint is a ~30-line
  addition to an already-registered, workstation-side meta-test.
- **`verify.sh:597-598` has already written the rule down**: *"a stub is the only way
  to make the assertion fail on demand, and **a control nobody has seen fail is not a
  control**."*

**Costs, measured.** The discipline is already ~95 % adopted for suites written since
`t27` (20 of 21 have a control; only `t29` does not) and ~8 % for those written
before. So the rule is not a culture change — it is a **retrofit of 25 suites and 275
assertions**, plus a recurring per-assertion cost on new work. The recurring cost is
the real one: a control is not free, and `t35` is 360 lines to demonstrate three
behaviours of one assertion.

**And it must be per-assertion, not per-suite.** `t39` is a counter-example that
disproves the cheap version: it *has* a control, validates its oracle, rejects an
empty `WANT_EVPN_SERIES` (`:158-159`), and distinguishes not-yet-enabled from down —
and it still shipped two parsers that can only ever return 0 (#121). **Defending the
suite does not defend the assertion.**

### 5.6 Batching — by mechanism, not by component

| batch | issues | why they are one piece of work |
|---|---|---|
| **B1** refuse-list binding in code | 113, 114, 115, 116, 118, 121 (+108) | one schema, one check, six symptoms |
| **B2** coverage/denominator | 85, 86, 108 | one oracle field already published |
| **B3** provenance closure | 133, 76, 101, 107, 119 | one fingerprint walk; last three become operations |
| **B4** system-naming defaults | 129, 131 | one grep, one rule |
| **B5** artifact-vs-box comparison | 97, 93, 94 | `config_landed`'s expected side must come from the artifact |

**Counter-example, stated because batching by component is the tempting mistake:**
#119 and #122 both live in "the deploy/publish path" and share nothing — #119 is a
failed search (close it), #122 is a live `rm -rf` with no rollback on the path every
deploy still runs. Grouping them by component would have buried the second.

Note **B5 is the one that does not fit the "cheap structural fix" story**: 2–3 days
plus a cold build, because the push never reads the artifact `config_db` at all —
`interim_deploy.py:1502` builds its expected side from the box's own
`sonic-cfggen -d --print-data`, and `:634` inherits everything ungrafted verbatim. It
is listed because it retires the whole F2 family and unblocks #88's config half, #91b
and #99's honest landed-check. It is the one multi-day item worth doing.

**Nothing structural reaches these:** #55, #88, #89, #91, #98, #99, #100, #109, #120,
#122. That is the bespoke residue, and it is the target state.

### 5.7 Arithmetic

Stated honestly, including the issues this plan **creates**: closing #61, #119 and the
#113/#114/#115 trio requires filing three replacements (the `tier`-rung defect, the
dashboard-staleness defect, and *make the refuse-list binding*). A plan that hides its
own spawn rate would be the same defect this document is about.

| stage | cost | retires | open after |
|---|---|---|---|
| start | | | **40** |
| §4 closures (10) **less 3 replacement filings** | ~1 h of triage | net −7 | 33 |
| **B4** system-naming defaults | hours | #129, #131 | 31 |
| **B2** coverage / denominator rule | hours | #85, #86, #108 | 28 |
| **B1** refuse-list binding in code | 1 d | the replacement issue, #116, #118, #121 | 24 |
| **B3** provenance closure + 3 operations | 1–2 d | #133, #76, #101, #107, #119-replacement | 19 |
| **B5** artifact-vs-box comparison | 2–3 d | #97, #93, #94 | 16 |
| named small fixes: #105 one derivation, #84 unit liveness, #95 brief the agents, #102 sum the phases | ~1 d total | 4 | **12** |

**Residue at ~12, and it is the right residue:** #55, #88, #89, #91, #98, #99, #100,
#109, #120, #122, plus the two replacement issues. Every one is a *cause* — a missing
capability, a substrate limit, or a decision — not an instance of a mechanism.

**Roughly one working week takes 40 to 12**, against ~16,000 lines of new test code to
retire the same set one at a time. **The single cheapest hour in the plan is B2**, and
the single best-value day is B1.

---

## 6. Filing discipline, and the stopping condition

### 6.1 The bar should not move up. It should move sideways.

**Asked directly whether the filing bar is too low: no — and the honest answer is more
uncomfortable than yes.** The rate of bad filings is normal (2 of 93 closed as
invalid). But **twelve of the 40 open issues contain a claim that does not survive a
read of the repo** (§4.9), and every one of those twelve would have been caught by a
single command. **The problem is not what gets filed. It is that bodies are written
from assumption rather than observation** — and a wrong body is more expensive than a
missing issue, because it dispatches work against a defect that is not there. #103 did
exactly that: it was fabricated *and* it dispatched an agent.

So the rule is not "file less". It is: **one command against the repo before the body
is written.** That converts the 1-in-3 wrong-body rate into roughly zero for the cost
of eight seconds per issue.

The second thing wrong is **altitude**:

**`ISSUE-PRIORITY.md` §6 names six structural gaps. Measured: none of the six has been
filed as an issue in the 14 hours since `f013a80`.** Searched the full text of all 133
issues for each:

| gap named in §6 | filed? |
|---|---|
| **`t_count "label" 0 0` passes** — `lib.sh:30-40` fires its guard only when *expected* is non-zero | **NONE** |
| `manifest.py` / `render_fabric_ztp.py` have no Python unit test | **NONE** |
| Two self-derived BGP denominators survived #81 (`55-unnumbered.sh:215-216`, `rules.yml:11`) | **NONE** |
| `verify.sh` asserts no alert rule anywhere; the whole alerting path is unexercised | **NONE** |
| `tests/fidelity/` is not wired into `verify.sh` | **NONE** |
| A second near-duplicate monitoring compose at `roles/observability.sh:102` | **NONE** |

**The first row is the mechanism underneath #108 and #121 — two open issues whose
shared cause has no tracker item.** The tracker files symptoms at a rate of 2.4/hour
and has filed the mechanism zero times.

**And row three is now demonstrably costing something.** Verified: both self-derived
BGP denominators are still live — `deploy/55-unnumbered.sh:215-216` sums
`gpufab_bgp_peers_total` from the exporter, and `monitoring/rules.yml:11` compares
`sum(gpufab_bgp_established_total) < sum(gpufab_bgp_peers_total)`, exporter against
exporter. **`monitoring/rules.yml` has zero commits since the baseline**: the "every
denominator comes from the oracle" work (#110, `0b03240`) covered the dashboards and
left the alert rules self-derived. Because that gap had no issue, the fix that was
right next to it did not reach it.

That, and not over-filing, is the defect in the process. It is also the *good* news:
the fix is not to file less, it is to file one issue at the mechanism and close the
instances into it.

### 6.2 The countervailing evidence, because under-filing is the worse failure

The record supports the working agreement's claim, and the evidence is specific rather
than rhetorical. **These issues exist only because knowledge was trapped on a host or
in a transcript:**

- **#132 is the cleanest case.** `/opt/gpufab/speakers.py` and
  `/opt/gpufab/diffcheck.py` existed **only on the fabric host, in no repo**, and the
  session-uptime inertness check they implement is described in the issue as *"the
  single most valuable check"* of the day. Filing it is what turned them into
  `deploy/ztp_speakers.py` driven by `t47`. **This project has already released six
  sims.** Without the issue, both scripts would have gone with the host.
- **#130** — four artifact publishes performed by hand before a committed path
  existed. The issue is the only record of the sequence used; it produced
  `deploy/52-ztp-publish.sh` and `t47`.
- **#102** — its table of committed-vs-narrative numbers is the only artefact in which
  the `push.all` contradiction (95.7 s in #58, 20.31 s in the cold-run report, same
  build) is recorded at all. Without it the wrong number simply propagates.
- **#107** — that the gate sim was six commits behind, with `tools/features/` absent
  and `t38`/`t39`/`t40` nonexistent on the box, existed nowhere until it was filed.
  Host-side `git status` is structurally useless here (no host can `git pull`); the
  technique that worked — `git cat-file -t <sha>` — is recorded only in the issue.
- **#95** — the only record that the fabric-secret rotation is **incomplete**: the head
  has the new value, the 46 switches hold the old one until the next push. Nothing else
  says so. Verified that its fix has *not* landed:
  `grep -i "secret\|redact\|digest" /mnt/data/bob/sim/CLAUDE.md` → **zero** hits
  (control: `subagent` → 8). Fifteen minutes of work, still open.
- **#86** — filed precisely because *"the verification that closed #78 was done by hand
  on the box. By this project's own standard that does not count."*
- **#119** — even though its root cause is wrong, its *observation* is the only record
  that the current deployed==repo dashboard match came from an ad-hoc manual copy
  rather than a deploy stage, and will drift again.

And the cost of not writing things down is visible in the corrections themselves:
`1a824c0` corrected **seven** wrong claims, `1d95539` corrected **nine more**. Those
were caught because they were written down.

**The asymmetry is the whole argument: the over-filing cost is one command; the
under-filing cost is a fact nobody can recover.** Filing more, faster, with a mandatory
pre-filing check dominates filing less.

### 6.3 The line

1. **File the mechanism, not only the instance.** When an issue is the *n*-th of a
   shape, file one issue at the shape and reference the instances. #133 is the model:
   it generalises #128 into a class, names four more members, gives a suggested order,
   and ends with the structural fix — and it includes a **"Verified negatives, so
   nobody re-checks them"** section. That section is the single highest-leverage
   convention in the tracker.
2. **One command against the repo before the body is written — and a negative search
   is not evidence until it is controlled.** This is the highest-value line in the
   section, because it fixes 12 open issues' worth of wrong claims at eight seconds
   each. Three of the twelve are a `grep` that returned nothing being read as absence
   (#103's `-fe-`, #119's non-recursive `deploy/*.sh`, #109's stale `tests/`), and two
   more are a body written against a stale ref rather than `origin/main`. **The rule
   `TELEMETRY-INVENTORY.md` already applies to metrics applies to greps: run the
   negative control first.** That document's own standard — *"the negative control
   passed FIRST … `ifOutOctets` moved on 52 of 52 routed ports"* — is exactly what a
   `grep` needs before its zero is believed.
3. **Do not raise the bar on observations.** A sweep that adjudicates 39 SAI fields and
   files 3 issues is working correctly. The 2.68/h arrival rate was a *census*, and a
   census is supposed to spike.
4. **Close aggressively in the same breath.** 2 invalid filings self-caught in under
   20 minutes is the system working; the failure would be leaving them open.
5. **Serialise feature builds against sweeps.** Measured at 1.50 new-debt issues per
   closure versus 0.10, a feature build is the one activity whose arrival curve should
   not be added to another's.
6. **Put the priority where work is selected, not in another repository.** The tracker
   has two labels and 72 unlabelled issues (§3.5); a ranking in a markdown file in
   `gpufab-docs` changed nothing about what got closed in `gpufab-platform`. **Add a
   `needs-decision` label and write each rank onto its issue.** That is the only change
   that makes a ranking visible where the choice is actually made, and it costs about
   as long as it takes to read this paragraph.
7. **Deliberately re-enter old issues into the closing window.** §2.7 shows the
   probability of closing an issue older than ~10 hours is empirically zero, and that
   this follows from the method that makes the project correct rather than from
   neglect. So it will not fix itself. **The cheapest counter-measure: start each
   session by picking one survivor and standing a system in front of it** — because the
   thing this project reliably closes is whatever the running box is currently showing.

### 6.4 The stopping condition

**Zero open is not it, and neither is any issue count.** The project already has a
defined pass/fail state and should use it:

> **Converged = a cold `up.sh` build on merged `main` reaches `VERIFY: all phases
> passed` with zero `SKIPPED_HOST`, and every assertion that produced that verdict has
> been observed failing at least once.**

`tests/verify.sh:603-622` already distinguishes the three outcomes that matter —
`INCOMPLETE` (exit 2) when any host phase never ran, `FAILED`, and `all phases
passed` — and already refuses to call a workstation-only run a release gate: *"host
validation did NOT run — this is not a release gate."* The second clause is the one
that is not yet true: 25 of 46 suites and 275 of 1039 assertions have never been
demonstrated failing.

**Three supporting conditions, each measurable:**

1. **Arrival below 1.19/h** — the measured closure throughput. Not zero arrivals;
   below break-even.
2. **The census is closed** — every telemetry surface adjudicated once in
   `TELEMETRY-INVENTORY.md`, with the negative control passing *first* (that document
   already sets the standard: `ifOutOctets` moved on **52 of 52** routed ports before
   any permanently-zero claim was made).
3. **Every remaining open issue is a CAUSE, not an INSTANCE** — i.e. the §3.1 instance
   count reaches 0. That is the honest target and it is ~13 issues, not 0.

**By that definition the project is close.** s11 built cold in **24m11s**, was gated
by `verify.sh`, converged **1464/1464** BGP sessions and **16/16** EVPN, and is holding
steady. What is not yet true: the overlay is runtime-only (#127) so a reload destroys
it, and s11 is 6 commits behind the tree (#107). Those two are the gap between "it
works" and "it survives", and they are exactly where the remaining bespoke work should
go.

---

## 7. What could not be established

**Corrections to the brief, stated first because they change the conclusion:**

1. **"A stable set of 20 older issues has survived weeks" — false.** Measured against
   docs HEAD (`1d95539`, 2026-07-29 10:07:15Z): the oldest open issue **#55 is 33.5
   hours old**, the median is **24.3 h**, the youngest (#100) is **13.8 h**. The
   entire tracker spans 32.1 hours. Nothing has survived weeks; nothing could have.
2. **The list of "the previously-open 20" in the brief is wrong in four places.** The
   measured set of issues open at `1a824c0` and still open is **#55, #61, #62, #63,
   #75, #76, #83, #84, #85, #86, #88, #89, #91, #93, #94, #95, #97, #98, #99, #100.**
   The brief's list includes **#57** (closed 2026-07-28T07:53:16Z) and **#64** (closed
   09:45:49Z), and omits **#95** and **#98**. The count of 20 is right by coincidence.
3. **"Today closed roughly 20 and opened roughly 20 (#101–#133)" — the closures are
   overcounted.** From `1a824c0`: **13 closed, 33 opened.** From `f013a80`: 14 and 34.
   #101–#133 is 33 issues, not ~20. The claim that **zero previously-open issues
   closed is exactly right** for the `1a824c0` window (one, #87, closed in the wider
   `f013a80` window).
4. **"93 closed" overstates the work by 53.** Fifty-three of them (#1–#54 except #53)
   were filed and closed within 1–2 seconds as a bulk import of already-fixed defects
   (§2.1). The real record is 80 tracked, 40 closed, 40 open.
5. **"At least four issues contain claims later found wrong" — the true figure is at
   least twelve, among the *open* set alone** (§4.9). The four named in the brief are
   the ones already caught.

**What I could not establish:**

- **Whether the census is actually finished.** The strategy in §1 rests on the sweeps
  terminating. I can show they enumerate finite surfaces and that branching is
  decaying, but I cannot show the surface is exhausted — and **#133 explicitly lists
  four more unfiled members of its own class**. If a fourth sweep is run over a
  surface not yet touched, arrivals spike again, and that would not be a process
  failure.
- **Whether the 0.10 non-EVPN regression rate holds for the next feature.** It is one
  observation of one feature build. #87 went from designed-but-unbuilt to live in 12
  hours; a more incremental build might cost less, or the number might simply be what
  features cost here. **Do not plan on 0.10 for feature work.**
- **The true size of the laundering family.** Same-line grep finds 184 assertion sites;
  `t03:63-70` proves the accumulator form is missed, and there are **332** `${x:-0}`
  occurrences in `tests/` overall. The real figure is between 184 and 332 and requires
  reading each site.
- **Whether §5.1's fixture clause is affordable.** It is the clause that catches #118,
  and it is the expensive half of the cheapest structural change. `t35` is 360 lines
  to demonstrate three behaviours of one assertion; I have no measurement of the cost
  of a fixture for a *metric*, only for a *shell assertion*.
- **Which direction the #120 / #127 duplicate should close.** Two independent reads
  reached opposite answers (§4.5) and both are defensible from the bodies. The
  recommendation to close #127 rests on one quoted sentence in #120's body; someone who
  owns the overlay-persistence work should decide in a minute rather than trusting this.
- **Whether `t43-topology-truth.sh` supersedes `t09`'s drill assertions**, which
  determines how much of #61's residual actually remains. It does not appear to assert
  aggregation levels, but that file was not read in full.
- **#100's "six project networks at 1460" figure.** It is a live-GCP observation, not
  derivable from the tree — only one network is declared in terraform. The rest of
  #100's arithmetic was checked and its 8896 denominator does not exist in code.
- **Whether #89's original event is reproducible.** It was cleared by hand from one
  side. The detector is the work; the incident may not recur on demand.
- **Anything about `gpufab-s11` beyond what is recorded.** It was out of scope by
  instruction. Every s11 fact here is quoted from `HANDOFF-2026-07-29.md`, not
  observed. Given #107 records the box as 6 commits behind, **any measurement taken on
  s11 must first establish which tree it is actually on.**
- **Whether twelve wrong bodies is the floor or the ceiling.** Twelve of the 40 were
  checked against the tree and found materially wrong (§4.7). The remaining 28 were
  read but not each independently re-verified line by line. **The checked fraction
  found errors at roughly 1 in 3, so twelve is more likely a floor than a ceiling** —
  but I did not verify the rest, and saying otherwise would be the same defect this
  document is about.

---

## Appendix — how this was established

- All 133 issues fetched with bodies **and** comments (`gh issue view --json
  body,comments`); `gh issue list` pages at 30 by default and that has already
  produced a wrong count in this project's own documents — always pass `--limit`.
- Backfill detection: closed-minus-created < 180 s. 53 issues, contiguous #1–#54
  except #53.
- Harness figures: `grep -c` over `gpufab-platform/tests/` at `dc9a05d`; every
  file:line cited was opened and read.
- Spawn edges: every edge required a quoted causal sentence from the child's body or
  comments. Mere cross-references (*"same family as #82"*, *"#81 exactly"*) were
  rejected as analogical, not causal.
- Read-only throughout: no issue was modified, closed, commented on or labelled; no
  code was changed; `gpufab-s11` was not touched.


---

## 9. The correction pass was executed — 2026-07-30

Applied by `gpufab-platform/tools/issue_corrections_0730.sh` (`90ccd35`). Ten of the
eleven corrected and left open; **#124 closed** as fixed in the tree. **34 open.**

Retitled where the title itself asserted the wrong thing: **#86** (on-box half, and the
miss is deterministic), **#89** (drop "nothing was reporting it"), **#100** (headroom
unverified, not 254 bytes short), **#102** (nothing *sums* the timings that already
exist), **#108** (`t03`'s assertion cannot fail), **#109** (FIB content, not count),
**#119** (bound to role execution, not to sync). Comment-only: **#55**, **#98**,
**#116**.

Bodies were left intact deliberately. Deleting a wrong claim erases the evidence that it
was made, and confident wrongness is this project's failure mode — the trail is worth
more than a tidy body.

### 9.1 Three of this document's own claims did not survive the re-check

Recorded here because it is the same defect this document is about, one level up.

- **"`t23:103-114` covers the OOB pair on the artifact side."** There is **no `oob`
  string anywhere in `t23`** — `grep -n oob tests/t23*.sh` returns nothing. The claim is
  true in substance (the artifact half enumerates every device) but not at those lines,
  and the coverage is therefore invisible to anyone grepping for it. That nuance is now
  in the issue, because the next reader will run that grep and conclude the opposite.
- **"`PHASE_BEGIN` has exactly 6 call sites."** There are **7 matches**; the seventh
  (`roles/fabric.sh`) is a `declare -F` existence guard, not a call. Six real.
- **"Close #119 as INVALID."** `deploy/roles/observability.sh:100` **does** copy
  (`cp -r "$SRC/monitoring/grafana" /opt/gpufab/ops/monitoring/`), so the issue's root
  cause is wrong — but its **observation is real for a different reason**: the copy is
  bound to observability-role execution, not to git sync, so a sync updates the checkout
  and leaves the deployed copy stale. **Closing it would have destroyed the only record
  of a live bug.** Re-scoped instead. Also measured: `cp -r` merges without nesting and
  overwrites, so re-running the role *is* a fix — but it has no `--delete`, so a renamed
  dashboard lingers.

**The lesson generalises.** A document that catalogues unverified claims is not itself
exempt; three of its verdicts needed the same treatment it prescribes. One of them —
#119 — would have closed a real bug on the strength of a correct observation about an
incorrect grep. The instinct to re-run the check rather than trust the write-up is what
this whole exercise is for.
