# Designing multi-part systems to maturity with AI agents — a methodology for gpufab

*Grounds every rule in a gpufab failure and in what agents specifically do well/badly. Written
2026-08-26 after the sot_reset "canary" episode, whose four-round S1 loop is the worked example
throughout. The eight-phase flow and its phase-2 seam (attack the invariant before writing code)
are the operative recommendations; §6 records the phase-2 attack that killed the canary design and
selected disable-the-trigger in its place.*

The question, in Bob's words: *"we are not designing things in a very systematic way."* The
canary episode is the proof — the same class-S1 finding four rounds running, each round a local
patch pushed to `main`, on a mechanism that gates a `containerlab destroy` of a 124-node fabric.
This document is the systematic way, built to be **agent-native**: it exploits what a fleet of
Opus agents is uniquely good at, and it puts guardrails exactly where agents are uniquely
dangerous.

The through-line of the whole project (STABILITY-RETROSPECTIVE.md §1): **84% of defects were the
system doing the wrong thing AND reporting success.** Detection, not repair, is the cost. Agents
move fast and write confident prose, which makes green-but-wrong *cheaper to produce* and *harder
to doubt*. So the methodology's job is to make **disagreement** cheap: an independent adversary,
a measurement on a real box, a test that can go RED — always cheaper than trusting a green.

---

## 1. Diagnosis — the failure modes, generalized, and why agents amplify each

The canary loop is not one bug; it is six recurring shapes. For each: what it is, why an *agentic*
workflow makes it **more** likely, and where agents actually help.

### 1.1 Proxy-instead-of-invariant (approximating the property one dimension at a time)
The real property — "the exact EFFECTIVE unit systemd will execute is the canonical harmless
canary, and nothing else" (CANARY-SAFETY-TABLE.md) — was never written down. It was approximated
by a growing pile of local guards: path → disk hash → reload state → drop-in set. Each guard was
correct; the *set* was incomplete, and incompleteness is invisible from inside any one guard.
This is the same shape as the retrospective's "self-comparison" and "presence≠function": a check
that measures a proxy for the outcome instead of the outcome.

**Why agents amplify it:** an agent handed a specific counterexample is *superb* at closing that
exact counterexample — fast, plausibly, with a passing test. That very competence is the trap: it
resolves the named finding and moves on, never lifting its eyes to "what is the *complete* set of
dimensions?" The reviewer's counterexample becomes the spec. A human, slower, is more likely to
feel the itch of "this keeps happening — the *method* is wrong."

**Where agents help:** an agent told *"enumerate every input that determines this property"* will
fan out and list dimensions a human forgets (runtime `/run` drop-ins, `NeedDaemonReload`, foreign
late-sorting `99-*.conf`). The strength is real — it just has to be *pointed at the invariant*,
not at the diff.

### 1.2 Review-as-substitute-for-execution
The agent repeatedly reasoned its way to "plausible but wrong" conclusions that only *running on
real systemd* disproved — e.g. `ConditionResult` reads `no` even for a unit that RAN (discovered
only on the disposable VM; see the bring-up memory's DISPOSABLE-VM entry). Reviews were being used
to decide questions only execution can answer.

**Why agents amplify it:** agents produce fluent, confident causal narratives from static reading.
The prose *reads* like knowledge. There is no internal signal distinguishing "I verified this" from
"this is a well-formed guess." A human at least feels the uncertainty; an agent's uncertainty is
invisible in its output.

**Where agents help:** agents make execution *cheap* — spinning a disposable Ubuntu-255 VM,
running the frozen artifact, power-cycling it, tearing it down (already done, per the memory). The
fix is not "trust agents less" but "make every load-bearing claim earn a run," which agents make
affordable enough to *always* do.

### 1.3 Tests-mirror-assumptions
Each round's test was written *from the fix's own mental model*, so it proved the guard exists, not
that the model is complete. Concretely, `test_block.sh`'s fake ssh **defaults to the happy state**
(`FR_CANARY_RAN:-absent`, `FR_DROPINPATHS-` empty): any dimension the code forgot to check is, by
default, benign in the test. The test can only fail on scenarios someone *thought to inject*.

**Why agents amplify it:** an agent writes the implementation and the test in one motion from one
model; they share a blind spot by construction. The test passing feels like independent
confirmation but is an echo.

**Where agents help:** agents are tireless at the *opposite* discipline — mutation testing (mutate
the code, prove a test dies), property testing (assert the invariant over generated inputs),
adversarial-default fakes (default to *unexpected* state). These are laborious for humans and free
for agents.

### 1.4 Premature integration to main
Every round pushed to `main` before the complete safety case was reviewed — making `main` the
integration branch for safety-critical code. CLAUDE.md already forbids `git push origin main` (a
`drift.py` push once carried an unrelated `interim_deploy` commit past the gate); this is the same
disease one level up — pushing *unfinished safety reasoning*, not just unrelated commits.

**Why agents amplify it:** "committed + pushed" reads as "done" and clears the agent's working
memory — there is a gravitational pull toward closing the loop. Cheap commits make premature
landing frictionless.

**Where agents help:** an agent can maintain a long-lived integration branch and a running
"safety case" document without fatigue, so the human's scarce attention lands once, on the whole
case, not on round N's diff.

### 1.5 Plausible-but-wrong
The signature. `config_landed` built "expected" from the box it was checking (#97); BGP
`Established` while 0 prefixes moved (#118). The canary's `ConditionResult` assumption is the same:
internally consistent, externally false.

**Why agents amplify it:** fluency. An agent's wrong answer arrives in the same confident register
as its right ones. The reader has no tone cue.

**Where agents help:** an *independent* agent, given only the requirement (never the first agent's
reasoning), will often reach a *different* wrong answer — and the disagreement is the signal. Two
agents that agree from independent starts is weak evidence; two that disagree is a found bug.

### 1.6 Accretive patching (the meta-failure)
The same class recurring is itself the datum. The team already knows this
(feedback-prove-complete-invariant: *"repeated same-class findings are a STOP SIGNAL about the
verification METHOD, not a cue to add one more assertion"*). The methodology's job is to make the
stop-signal *structural* — a phase gate that cannot be satisfied by one more guard.

**What is genuinely new vs classic discipline.** Invariant-first specification, adversarial review,
execution-as-oracle, and integration branches are *classic engineering*. What agents change is the
**cost curve**: fan-out of N design alternatives and N adversarial attacks in parallel, a disposable
VM per experiment, mutation testing that runs overnight, an independent adversary for every artifact
— all become cheap enough to do *always*, not just for the crown jewels. The one truly new hazard is
**confident prose at machine speed**: the methodology must never let an agent's "looks complete"
substitute for an independent adversary plus a measurement.

---

## 2. The phased methodology — blank slate to mature subsystem

Eight phases. Each has an **artifact** (durable, reviewable), a **gate** (a measured condition to
leave the phase), and an explicit **agent role assignment** — crucially *who must be independent
from whom*. The independence rule throughout: **the agent that builds an artifact never reviews its
own artifact for completeness; a separate agent, given only the requirement, does.**

| # | Phase | Artifact | Gate to leave | Agent roles (independence) |
|---|-------|----------|---------------|----------------------------|
| 0 | **Frame & decompose** | One-page problem statement: the property that must hold, the blast radius if it doesn't, the units/seams (SoT→render→apply→verify). A decision record (ADR) for each irreversible choice. | Main agent + Bob agree the decomposition and blast radius. Named seams. | **Main** drafts; **Bob** decides irreversibles (destructive scope, spend). Not delegated — this is the decision. |
| 1 | **Invariant specification** | The **complete invariant, as a table** — every dimension that determines the property, its canonical expected value, its observation, and a *uniform refuse rule* (unknown/missing/additional/nonzero/unmeasured ⇒ refuse). Exactly CANARY-SAFETY-TABLE.md. | The table exists and every row names a *measurable* observation on the real system. | **One generator agent** writes it. |
| 2 | **Adversarial spec-completeness review** | A written attack on the *table itself*: "what effective-config source or resolution rule is NOT a row?" A list of proposed missing dimensions, each accepted or rejected with reason. | An **independent** agent, given the property statement but NOT the generator's reasoning, finds **no** uncovered dimension — or the ones it finds are added and it is re-run until clean. | **Adversary agent**, independent of the generator. Fan out 2–3 in parallel for breadth. Main adjudicates. |
| 3 | **Interface / decomposition design** | The routine signature(s): one authentication routine implementing the whole table, dependency-injected so it is testable host-free (block/unblock take the ssh fn as `$1` — already the pattern). "One derivation per fact" wired in (content fns, not literals). | Design review: one routine per invariant (not one guard per finding); every fact derived once; the seam is host-free testable. | **Design agent** proposes; **main** reviews against retrospective §7.3 (one derivation) and §1.1 (one routine). |
| 4 | **Reference oracle / test harness** | (a) A **property/adversarial test** whose fake **defaults to UNEXPECTED state**, so any unchecked row fails by default; (b) a **mutation battery** — remove each guard, prove RED; (c) a **frozen-artifact execution** plan on a disposable VM. | The harness goes RED on the negated property and on each single-guard removal (test-the-test), BEFORE the implementation is trusted. | **Test agent**, independent of the eventual implementer. This is the `t_verdict` + neg-controls loop (feedback-deterministic-verdict). |
| 5 | **Implementation** | The one routine, implementing **every** table row; self-certifying (`t_verdict`: PROVEN iff ≥1 assertion, 0 failed, 0 skipped). | The whole-table test (phase 4) is GREEN and its mutation battery still RED-on-mutation. Script renders its own deterministic VERDICT. | **Implementer agent**. May be the design agent; must NOT be the phase-2 adversary or the phase-6 reviewer. |
| 6 | **Adversarial correctness review** | A written attack on the *code*: false-pass, false-fail, mechanism-not-end-state, over-claim, one-derivation drift. Findings ranked; fixes landed on the integration branch. | An **independent** agent finds no false-PROVEN; every finding fixed and re-reviewed. (Each of the first two canary cross-checks found a real ship-blocker — this phase pays for itself.) | **Correctness adversary**, independent of the implementer. |
| 7 | **Execution / fault-injection in a real environment** | A disposable-VM run of the **exact frozen artifact** (checksum recorded): happy path PLUS fault injection for every adversarial row (foreign drop-in early/late, `/run` drop-in, stale reload, ssh loss at each observation, partial install, reboot-while-blocked). Evidence bundle. | Every adversarial case ends *fail-fast or fail-closed*, catastrophe-clean, measured on the box — never on the diff. A happy-path VM run alone does **not** qualify (CANARY-SAFETY-TABLE.md §"Adversarial cases"). | **Execution agent** on a disposable VM (bounded attempts — memory: bound SSH-heavy agents). Relays exit code + VERDICT only. |
| 8 | **Maturity gate & land** | The **complete safety case**: table + spec-review + whole-table test + mutation battery + frozen-artifact VM evidence, reviewed as ONE package. Handoff doc in `gpufab-docs/design/` + memory pointer. | Bob (or the human-designated reviewer) signs off on the *whole case*, not the latest finding. Then push by refspec, source/test/docs as separate commits. | **Main** assembles; **Bob** gates the land of safety-critical parts. |

**The gate that breaks the accretion loop** is the seam between phases 2 and 5: *implementation may
not begin until the invariant table has survived an independent completeness attack.* Four rounds
of S1 happened because implementation started against round-1's mental model and every subsequent
round was a phase-2 finding arriving *after* the code shipped. Move the completeness attack **before**
the code, and the same four findings arrive in one review, on one table, in one round.

---

## 3. Exploiting agent strengths; neutralizing agent weaknesses

**Strengths to exploit (things a fleet does that a solo human can't afford):**

- **Parallel fan-out of alternatives.** Phase 0/3: spawn 3 agents on 3 decompositions (e.g.
  Option-1 pre-wired-bridge vs Option-2 lab-per-pod — exactly the fork the bring-up work ran); each
  returns costs and a killer flaw. The ladder caught "Option 1 is dead on clab 0.77" at L1 in
  ~17 min. Cheap divergence beats one serial guess.
- **Parallel fan-out of *attacks*.** Phase 2/6: N adversaries hunt independently. Diversity of wrong
  answers is the product. This is the opposite of diff review, which converges (retrospective §4:
  *"a review whose input is the last review's diff converges on the diff"*).
- **Generate-then-attack, not author-then-self-check.** One agent builds the invariant; a *different*
  agent, given only the property, tries to find an uncovered dimension. Independence is the whole
  value — a self-review shares the blind spot.
- **Tireless mutation/property testing.** Agents will happily mutate every guard and confirm each
  death, generate thousands of adversarial inputs, run the neg-control battery on every change.
- **Disposable execution as arbiter.** A VM per experiment, self-deleting, no service account — the
  bring-up team already built this. Execution, not argument, settles "does `ConditionResult` lie?"

**Weaknesses to neutralize (structurally, not by asking nicely):**

- **"Looks complete" is worthless without an adversary + a measurement.** Rule: no invariant is
  "complete" until an independent agent failed to break it; no code is "correct" until a mutation
  test proved it can go RED and a real box measured the end state.
- **Confident prose hides guesses.** Rule: every load-bearing causal claim ("systemd will skip")
  must cite either a measurement on a box or is quarantined as "unverified" until phase 7 runs it.
- **Speed closes the named finding and stops.** Rule: repeated same-class findings *halt the patch
  track* and kick back to phase 1 (rewrite the invariant), per feedback-prove-complete-invariant.
- **The human's attention is scarce and mis-spent on diffs.** Rule: land Bob's review on the
  **invariant table** (phase 2) and the **complete safety case** (phase 8) — the two artifacts where
  a human's judgment is irreplaceable — not on round-N's guard. Agents handle the diffs.

---

## 4. Verification that does not mirror the implementation's assumptions

The retrospective's rules §7 are the floor. Four techniques lift verification off the
implementation's mental model — the specific failure of `test_block.sh` today:

1. **Adversarial-default fakes.** The fake's *default* return must be an *unexpected* state (an
   extra drop-in, a foreign FragmentPath, an unmeasured probe), so **any dimension the code forgot
   to check fails by default**. Today the fake defaults to happy (`FR_CANARY_RAN:-absent`), so a
   forgotten row is silently benign. Flip the default and the test surface inverts from "prove the
   guards I wrote exist" to "prove nothing unexpected gets through."
2. **Property/table-driven testing.** Drive the test from the *invariant table*, not from a
   hand-listed scenario set: for each row, generate the violating observation and assert REFUSE.
   A new row in the table *is* a new test, automatically — the test can't lag the spec.
3. **Mutation testing (test-the-test).** Every guard removed must turn the suite RED (already the
   discipline: "7-mutation battery all RED"; `c10-neg-controls.sh`). Extend it to *every* table row,
   so a row present in the table but absent in the code is caught as an un-killed mutant.
4. **Execution-as-oracle.** The frozen artifact runs on a real systemd VM with fault injection. This
   is the only thing that catches "plausible-but-wrong" (the `ConditionResult` lie). Verify against
   the model and the box — never against the diff (retrospective §7.6).

### How the canary case is caught in ONE round instead of four

- **Phase 1** forces the *whole* invariant onto paper: "the EFFECTIVE unit = base + **the complete
  DropInPaths set** + resolution order." Writing "complete set" makes the `99-*.conf` late-drop-in
  a *row*, not a round-4 surprise.
- **Phase 2** hands an independent adversary the property and asks "what determines the effective
  unit that isn't a row?" `/run` drop-ins, late-sorting `ExecStart=` resets, `NeedDaemonReload` all
  surface here — *before any code* — because that is the adversary's only job.
- **Phase 4's adversarial-default fake** fails the *first* implementation that authenticates only
  the base file + one known drop-in, because the default injected state includes an extra drop-in
  the code never queried. Round 1 goes RED on exactly the dimension that took four rounds to find.
- **Phase 7** runs it on real systemd and learns `ConditionResult` is a false-safe signal *by
  measurement*, once, instead of by a wrong guess that ships.

Result: the four S1 rounds collapse into one table, one completeness attack, one whole-table test.

---

## 5. Branch / integration / review discipline for safety-critical parts

**Why `main` must not be the integration branch.** CLAUDE.md already bans `git push origin main`
because a branch push carries whatever else landed. For safety-critical code the deeper reason is
that pushing round-N's guard publishes *unfinished safety reasoning* as if settled, and clears the
agent's memory of why it's unfinished. `main` should carry only **complete safety cases**.

**Concretely:**
- **A `safety/<feature>` integration branch** collects the phased work. Rounds of guards, reviews,
  and fixes accumulate there. `main` never sees a partial invariant.
- **A "complete safety case" is a single reviewable package** (phase 8): the invariant table + the
  spec-completeness review sign-off + the whole-table test + the mutation battery + the
  frozen-artifact VM evidence with recorded checksum. It gates the *land*, not each commit.
- **Push by refspec, source/test/docs separate** (CLAUDE.md §5): `git push origin <sha>:main` after
  confirming `git log --oneline origin/main..HEAD` is all yours; append each SHA to
  `.git/reviewed-shas`.
- **Human-in-the-loop lands on two decisions only:** (1) the invariant table is complete
  [phase 2 sign-off], (2) the complete safety case holds [phase 8 sign-off]. Everything between is
  agent work with an agent adversary. Destructive execution (gate 7 in the current work) is always
  Bob's explicit, separate go — *never destroy on an ambiguous signal* (CLAUDE.md §5; the
  124-node destroy).

*Note the tension with feedback-dont-self-stop:* "don't self-stop" means keep working the next
item, not "land safety-critical code without the human gate." The two coexist — the agent keeps
*building the safety case* without pausing, and stops only at the two human-judgment gates and at
destructive execution.

---

## 6. Worked application — how the canary work should now proceed

**State today (measured from the tree, not assumed):** `CANARY-SAFETY-TABLE.md` exists with 10
rows (phase-1 artifact is DONE). The canary is deployed to `gpufab-fabric-01`; all 15 sot_reset
commits are on `origin/main`; gate 4 (quiesce→backup→verify) is closed pending Bob; gate 7
(destructive reset) is closed. `test_block.sh` has 51 assertions and a mutation battery.

**A live finding this investigation surfaced — the table is ahead of the code.** `block_rebuild`
(`_lib.sh:317-466`) authenticates the canary on rows **1** (LoadState, :346), **2** (FragmentPath,
:363), **3** (unit bytes, :349-352), **5-partial** (the *one known* drop-in's bytes, :354-357),
**7** (NeedDaemonReload, :365), and **10** (start-skip acceptance, :439-463). It does **not** query
the canary's own **DropInPaths** (row 4 — the complete set, the exact dimension the table was
written to force), the canary's **effective ExecStart** (row 6), its **is-enabled** (row 8), or its
**is-active** (row 9). `deploy-canary.sh` checks is-enabled (row 8) at deploy time but also skips
rows 4 and 6. So a foreign late-sorting `99-*.conf` **on the canary** that resets its `ExecStart`
would pass `block_rebuild`'s authentication today — the S1 class, one level over, still open. This
is precisely a phase-5-vs-phase-1 gap: the invariant is specified but not fully implemented.

**The plan, by phase (executable by the main agent):**

1. **Spec-completeness review of the table [phase 2] — do this FIRST, independent agent.** Give one
   Opus agent *only* the invariant sentence and "list every source that determines the effective
   unit systemd executes for `CANARY_UNIT`; is each a row?" Expected confirmations: row 4 must say
   *complete DropInPaths set incl `/run`*, row 6 *exactly one ExecStart == touch sentinel*. Gate:
   no uncovered dimension. Artifact: a sign-off appended to the table.
2. **Single authentication routine [phase 3+5].** Refactor the canary authentication in
   `block_rebuild` and the overlapping checks in `deploy-canary.sh` into **one** function
   (`authenticate_canary <ssh_fn>`), implementing **all 10 rows**, sharing one derivation of every
   expected value (the content fns already exist). This directly answers
   feedback-prove-complete-invariant: one routine for the whole table, not one guard per round.
   Add the missing rows: query the canary's `DropInPaths` and assert it is *exactly* `{CANARY_DROPIN}`
   (row 4), query effective `ExecStart` and assert the single canonical argv (row 6), assert
   `is-enabled == static` (row 8) and `is-active == inactive` (row 9).
3. **Whole-table test via an adversarial-default fake [phase 4].** Rewrite `test_block.sh`'s fake so
   its **default** injects an unexpected state (an extra canary drop-in AND a foreign ExecStart), so
   the *current* implementation fails until rows 4 and 6 are added. Add one adversarial case per
   table row (foreign early `10-*.conf`, foreign late `99-*.conf` resetting ExecStart, a `/run`
   drop-in, `>1` ExecStart, enabled canary, active canary) each asserting REFUSE. Extend the
   mutation battery so removing *any* of the 10 row-checks flips RED — an un-killed mutant means a
   row is in the table but not the code.
4. **Correctness cross-check [phase 6], independent agent.** Hunt false-PROVEN in the new single
   routine, especially one-derivation drift between `block_rebuild` and `deploy-canary` now that they
   share it.
5. **Frozen-artifact VM run [phase 7].** On a disposable systemd-255 VM (the existing pattern), run
   the *exact frozen artifact* (record its rollup sha256) through: happy skip; foreign late drop-in
   on the canary resetting ExecStart → REFUSE before any start; `/run` drop-in → REFUSE;
   reboot-while-blocked → block persists. A happy-path run alone does not qualify (the table says so).
   Relay exit code + VERDICT only.
6. **Maturity gate & land [phase 8].** Assemble the complete safety case (table + spec sign-off +
   whole-table test + mutation battery + VM evidence + checksum) as ONE package for Bob. On his
   sign-off, push by refspec (source/test separate), append SHAs to `.git/reviewed-shas`, re-run
   `deploy-canary` on `-01` to re-authenticate. **Gate 4 stays closed until this lands; gate 7
   remains Bob's separate, explicit go.** Commit a handoff doc to `gpufab-docs/design/` + a memory
   pointer.

The point of the worked example: the artifact that finally breaks the four-round loop (the table)
already exists. What is missing is the *discipline that consumes it as a whole* — attack the table
before the code, implement it as one routine, default the fake to hostile, and let a real VM be the
arbiter. Do that once here and it becomes the template for the incremental-bring-up subsystems
(§8 of the bring-up architecture) that are next.

**Update — the phase-2 attack changed the design (2026-08-26).** Run for real, the phase-2
completeness attack on the canary table did not merely find missing rows — it found the invariant
has **no bottom**. `systemctl start CANARY_UNIT` pulls in the unit's *dependency graph*: a
`gpufab-sotreset-canary.service.wants/evil.service` symlink — which never appears in `DropInPaths`,
so no row catches it — **executes on the acceptance start with all ten rows green**; below that sit
`Wants=`/`OnSuccess=`, every `Exec*` hook, and ultimately the integrity of `/usr/bin/touch` itself.
The moment a design *starts something* to prove the block, it inherits systemd's entire
start-transaction model as its verification surface — unbounded. This is the phase-2 seam doing
exactly its job: it converted "add a fifth guard" into "the invariant is un-completable, change the
design," **before** a single one of the ten rows was implemented. The chosen replacement —
**disable-the-trigger** (quiesce `systemctl disable`s the destructive unit and confirms it inactive
with no live trigger; resume re-enables it to the recorded state; **nothing is ever started**) — has
a *bounded, completable* invariant (a single observable, `is-enabled`, plus "no path can start it
during the window"), and it is what the remaining work builds through these same phases. The canary
table and its completeness attack are kept as the record of *why* the started-proof design was
rejected — a phase-2 artifact that earned its keep by killing a design cheaply.

---

## Appendix — what is new vs classic, in one line each

- **Classic discipline, now cheap enough to always do:** invariant-first specs; adversarial review;
  integration branches over trunk for risky work; mutation/property testing; execution as the
  arbiter of truth. Agents change the *cost*, not the *idea*.
- **Genuinely new because agents exist:** parallel fan-out of both design alternatives *and*
  independent attacks; a disposable execution environment per hypothesis; an independent adversary
  for *every* artifact, not just the crown jewels.
- **Genuinely new *hazard* because agents exist:** confident, fluent prose produced at machine speed
  with no internal tell for "verified" vs "guessed" — which is why the non-negotiable rule is that
  no green result is trusted until you can name what it measured, on the real system, and an
  independent adversary failed to break it.
