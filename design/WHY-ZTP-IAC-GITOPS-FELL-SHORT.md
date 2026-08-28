# Why ZTP, IaC and GitOps fell short

**A retrospective on a process failure, not a bug report.**
Written 2026-07-28 against the repository record. Every claim below cites a file,
commit, issue or workflow run. Where something could not be established from the
record, this document says so instead of inferring it.

Measurement points, because all three repos were moving while this was written:
`gpufab-platform` at `8af859a` (branch `o5-merge`), `gpufab-network` at `047c8ca`,
`gpufab-docs` at `3f08c8c`. GitHub state read at 2026-07-28 ~11:10Z, at which
point `gpufab-platform` held 89 issues.

---

## 1. The answer, in plain terms

**Because the project navigates by failing tests, and none of the three could
produce one.**

The build has a config surface of roughly twelve `config_db` tables, hand-written
into one renderer. Everything the project measures — 1464/1464 BGP sessions,
46/46 in-sync, 48/48 ZTP fetches, 24m11s cold build, 124 containers — is a
*quantity* of that surface. No metric, no test and no review round is capable of
falling below threshold because the surface itself is too small. A gap with no
failing test is invisible to a process that finds its work by running the suite,
and that is exactly what happened.

More precisely, the three pillars failed in three different ways, and conflating
them is part of why it went unnoticed:

- **ZTP is genuinely strong, and is the one pillar that did close.** On the s11
  cold build it provisioned 48/48 switches and the follow-up push found 46 of 46
  already in sync and pushed nothing (issue #58, comment 2026-07-28T09:45:46Z).
  What it delivers, though, is a *fixed* config surface — whatever
  `render_fabric_ztp.py` was written to emit.
- **IaC is real for scale and absent for content.** A profile edit can change the
  size and shape of the fabric from 64 to 32,768 GPUs. It cannot introduce a kind
  of state the renderer was not already taught. NetBox config contexts and config
  templates — the mechanism a real NetBox-driven shop uses for exactly this — are
  referenced **nowhere** in either code repo.
- **GitOps is half-built, and the built half stops at a pull request.** The
  NetBox→webhook→render→PR path is real and ran unattended nine times. The
  apply half was never implemented: `deploy.yml`'s apply step is a literal
  `exit 1` stub, and the loop has never once put a byte on a switch.

The honest one-line summary is: **the project got very good at proving that a
narrow thing was correct, and never asked whether the thing was wide enough.**

On the framing "the user repeatedly said these are the centre of the sim" — the
repository record cannot show what was said in conversation, and this document
does not claim to. What it *can* show is that the design documents say it, in
their own words: *"the full lifecycle of a GPU-cloud network fabric — bring-up
(ZTP), configuration (IaC/GitOps), observability, and closed-loop operations"*
(`network-automation-design.md:47`), and *"An operator never SSHes to a switch to
make a lasting change; they change the SoT ... and the loop renders → reviews →
applies → verifies"* (`network-automation-design.md:49`). Judged against the
project's own stated centre, the gap is real.

---

## 2. The single most quotable number

Counted in `gpufab-platform/tests/` at `8af859a`:

```
$ ls t[0-9][0-9]-*.sh | wc -l                                              31
$ grep -l -i -E 'ztp' t[0-9][0-9]-*.sh | wc -l                             15
$ grep -l -i -E 'gpufab-runner|actions-runner|reapply|workflow_dispatch|gitops' t[0-9][0-9]-*.sh | wc -l   1
$ grep -l -i -E 'config_context|config_template' t[0-9][0-9]-*.sh | wc -l   0
$ grep -l -E 'git (push|commit)' t[0-9][0-9]-*.sh | wc -l                   0
$ grep -l -E '\bgh (run|workflow|api|issue)' t[0-9][0-9]-*.sh | wc -l       0
```

Half the suite exercises ZTP. One file mentions the GitOps machinery, and it
mentions it by `grep`-ing the *text of committed shell scripts*
(`t22-review-regressions.sh:39`: `cnt() { grep -cE "$1" "$2" 2>/dev/null | head -1; }`).
No test in the suite runs a workflow, merges a branch, dispatches a job, or
observes a device afterwards. **The honest count of tests proving the GitOps loop
closes is zero.**

A caution about this count, recorded because it is the kind of error this
document is about: the first attempt at it used `grep -lieE '<pattern>' t*.sh`,
which bash parses as `-l -i -e E` — it searches for the literal letter `E`,
matches every file, and reports "31 files test GitOps". The numbers above were
re-derived with the flags separated. A retrospective about checks that measure
nothing must not contain one.

Two counts that soften the picture and belong here for fairness: **17** of 31
tests reference NetBox, and **5** reference Terraform. The source-of-truth and
infrastructure-provisioning layers are not untested. What those tests assert is
covered in §3.2.

---

## 3. Per-capability status, with evidence

The three states below have very different remedies and are kept strictly apart:
**NOT BUILT** (no code exists), **BUILT AND BROKEN** (code exists and fails),
**BUILT BUT UNPROVEN** (code exists, plausibly works, nothing demonstrates it).

### 3.1 ZTP — the strongest pillar, and it did close

**Status: BUILT AND PROVEN, with one caveat.**

What works, measured:

- On the s11 cold build, `skipped(in-sync)` went from `0/46` to **`46/46`** and
  `push.all` from `444s` to **`95.7s`** — "46 `push.switch` records, 46 skipped, 0
  actually pushed; ZTP self-provisioned 48/48. Total cold deploy **24m11s**"
  (issue #58, comment 2026-07-28T09:45:46Z). Zero pushes means the config-push
  backfill applied nothing: ZTP alone brought the fabric to the state the pusher
  would have written.
- That result is the end of the hardest defect in the project's history. #58 (O4)
  survived six review rounds, was twice "root-caused" against a *running* fabric,
  and both hypotheses (`auth_tables`, then O11) died against a cold boot. The
  real cause was found by diffing a cold box: `docker-snmp` is a *delayed*
  container that runs `snmp_yml_to_configdb.py` ~45s after ZTP's config lands and
  re-adds `SNMP_COMMUNITY|public`, measured on `bk-p2-r8-leaf02` as "config
  landed 07:57:51 with one community, 07:58:35 had two — 44s against a 90s
  settle" (#58, comment 2026-07-28T08:19:56Z). That is exemplary debugging and
  should be recorded as such.
- The forensic evidence bundle `gpufab-docs/evidence/2026-07-27-insync-tacacs/`
  is real work: 48 ZTP `200` responses counted from the server log, on-box
  `sonic-cfggen -d` compared field-by-field against the served artifact for three
  switches of three roles, and a SONiC YANG validation run showing the fixed
  artifact is accepted (`tables=26 AAA=1 TACPLUS=1 TACPLUS_SERVER=1 PORT=64`).

**The caveat, and it is the project's own.**
`FIDELITY-VERIFICATION-PLAN.md:185` states: *"FV-ZTP-01 is the experiment this
project has never run. ZTP's work has always been overwritten by the config-push
backfill before it could finish, so ZTP has been observed neither working nor
failing."* The pass criterion at `:180` is "N/M switches fetched AND applied,
**with the backfill disabled**". The s11 run did not disable the backfill; it
made the backfill skip. That is functionally equivalent evidence and arguably
stronger — but FV-ZTP-01 as written is still unrun, and FV-ZTP-03 (invalid config
rejection) and FV-ZTP-04 (canary rollout halts on health failure) have never been
attempted at all.

**What ZTP does not deliver.** A fixed surface. The renderer derives roughly
twelve `config_db` tables — `PORT`, `INTERFACE`, `LOOPBACK_INTERFACE`,
`BGP_NEIGHBOR`, `DEVICE_METADATA`, `MGMT_INTERFACE`, `MGMT_PORT`,
`MGMT_VRF_CONFIG`, `AAA`, `TACPLUS`, `TACPLUS_SERVER`, `SNMP`/`SNMP_COMMUNITY`.
A grep of `render_fabric_ztp.py` for `VLAN`, `VLAN_MEMBER`, `VLAN_INTERFACE`,
`PORTCHANNEL`, `ACL_TABLE`, `ACL_RULE`, `VXLAN_TUNNEL`, `BUFFER_POOL`, `QUEUE`,
`ROUTE_MAP`, `PREFIX_SET` returns **zero hits for every one**. The remaining
tables in the 26-table artifact come verbatim from the static snapshot
`design/base/vs_base_config_db.json`; they are not derived from intent.

### 3.2 IaC — real for scale, absent for content

**Status: BUILT AND PROVEN for infrastructure and for fabric *size*.
NOT BUILT for fabric *content*.**

What is genuinely real, and should not be minimised:

- **Terraform IaC is real and is tested by execution.** 1291 lines across
  `gpufab-platform/terraform/`. `tests/t24-secret-iam.sh` reads
  `terraform output -json netbox_secrets`, then *performs the actual read as the
  service account* rather than inspecting a policy — and refuses to skip when
  Terraform cannot answer (`t24:91`: "terraform output produced no sims — ...
  nothing below was measured"). That is the standard the rest of the suite should
  be judged by.
- **Scale is genuinely parameter-driven.** The profile ladder `s0-64` through
  `s5-32768` drives topology, addressing, ASN allocation, port budgets and
  expected counts through `fabric_model.py` and `tools/expected.py`. Issue #56
  (O2) was closed as a **profile edit with no code change** — "O2 was closed as a
  PROFILE defect rather than a code bug, so nobody 'fixes' a guard that is
  correctly refusing 70 links on a 64-port switch"
  (`HANDOFF-2026-07-29.md`, "Issue tracking"). That is IaC working exactly as
  intended.
- **NetBox is genuinely read at render time on the GitOps path.**
  `tools/render.py:62` calls `rfz.read_netbox(nb)`.

What is absent:

- **NetBox is not the source of truth for the path that actually configures every
  fabric.** The tool that converges the fabric on every build is
  `interim_deploy.py`, invoked as `--profile "$PROFILE"`
  (`deploy/50-configure.sh:39`, `deploy/50-ztp-provision.sh:154`), and
  `grep -c -E 'pynetbox|NETBOX_URL|nb\.dcim' gpufab-network/tools/interim_deploy.py`
  returns **0**. Topology is the same story: `deploy/roles/fabric.sh:338` sets
  `TOPO_FROM_PROFILE=1`, so `40-topology.sh` builds from the profile, not NetBox.
  Meanwhile `deploy/50-configure.sh:37` logs *"pushing NetBox-derived config
  (incl. AAA)"* — which is false. This is defensible as architecture and the
  project argues it well (`HANDOFF-2026-07-29.md`, "Traps a fresh reader will
  hit": "git holds design intent,
  NetBox is the operational record ... nobody waits for DCIM before cabling").
  It is not defensible as a **log line**, and `gpufab-sim-design.md:246` states
  the opposite outright: "NetBox is the active SoT for config (render +
  gen_topology read NetBox, not the profile)."

- **NetBox config contexts and config templates are used nowhere.**
  `grep -rn 'config_context\|config_template' --include='*.py' gpufab-network
  gpufab-platform` returns zero hits; so does a grep across all file types in all
  three repos. This is the mechanism NetBox provides for declaring arbitrary
  per-device configuration content, and the design document specifies it in
  detail — `network-automation-design.md:110`: *"Config contexts | weight-ordered:
  global (DNS/NTP/syslog) → per-role (BGP timers) → per-fabric via tags (MTU,
  ECMP) → per-device"*. None of it exists.
- **The fields consumed from NetBox are a fixed, small set** —
  `render.py`'s own docstring (`:11-12`) says it reuses the ZTP builder over
  "devices/interfaces/IPs/cables/bgp_asn". A config context added in NetBox today
  would be silently ignored, because nothing reads one.
- **The apply path actively deletes the vocabulary of a richer config.**
  `interim_deploy.py:238-242` — `DROP_TABLES` contains `VLAN`, `VLAN_MEMBER`,
  `VLAN_INTERFACE`, `PORTCHANNEL`, `PORTCHANNEL_MEMBER`, `PORTCHANNEL_INTERFACE`,
  `ACL_TABLE`, `ACL_RULE`, `TELEMETRY`, `RESTAPI`. These are removed from the
  device on every push.
- **The test suite pins that narrowness in place.**
  `tests/t14-port-table.sh:260-278` constructs `PortChannel1`, `Vlan100`,
  `Bridge1`, `Tunnel0`, `Loopback9` and a LAG and asserts all six are *silently
  skipped* (`:298`, expected 6), while unknown physical names must *raise*
  (`:300`, expected 3). t14 is, in effect, an **anti-expressiveness test**: a
  VXLAN tunnel or a VLAN table added tomorrow would be dropped by design and t14
  would still pass.

**Net: the profile can declare new *values* and new *sizes* of known state. It
cannot declare a new *kind* of state.** Adding one requires coordinated hand
edits to at least three separate enumerations — the renderer, `interim_deploy`'s
owned-table set (`_OWNED_WRITE`, `interim_deploy.py:664-665`), and the oracle
`tools/expected.py` — plus the tests. That is the subject of the parallel design
`design/FEATURE-EXTENSIBILITY.md`, and this document deliberately does not
duplicate it.

### 3.3 GitOps — the left half runs, the right half was never written

**Status: mixed, and the components must be separated.**

The complete workflow run history for `gpufab-network`, all 41 runs from
2026-07-23T19:28:36Z to 2026-07-28T07:43:31Z:

| workflow | runs | success | failure | cancelled | queued |
|---|---|---|---|---|---|
| `render` | 17 | **10** | 6 | 1 | 0 |
| `validate` | 4 | **4** | 0 | 0 | 0 |
| `drift-check` | 18 | **0** | 11 | 3 | 4 |
| `deploy` | 2 | **0** | 2 | 0 | 0 |

And: **nine render PRs were opened; `mergedAt` is `null` on all nine.**

| component | verdict | evidence |
|---|---|---|
| NetBox event rule → webhook relay → `repository_dispatch` | **BUILT AND PROVEN** | 8 `repository_dispatch` render runs exist; only `bot/webhook_relay.py:49-58` can fire them |
| Self-hosted runner, per-sim routing | **BUILT AND PROVEN, now offline** | `bot/setup_runner.sh:76` registers `--labels "sim-host,sim-$SIM_ID"`; jobs ran under `runner_name: gpufab-sim-01`; that runner is now `status: offline` and its labels lack `sim-<id>`, which `render.yml:38-40` has required since 07-27 — so 4 drift-check jobs have sat queued for 3–21h |
| `render.yml` + `render.py` | **BUILT AND PROVEN — to a PR** | 6 `render/*` branches on origin authored by `gpufab-render <render@gpufab>`; 9 PRs opened |
| `validate.yml` | **BUILT AND BROKEN** | `:4` filters `paths: ["rendered/**"]` and `:17` runs `find rendered -name config_db.json`, but `render.py:42-43` writes to `instances/<sim-id>/rendered/`. The 4 "successes" iterated an empty loop. `:26` cross-device lint is `echo "…placeholder pass"` |
| Merge to `main` | **NOT BUILT** | 9/9 PRs unmerged; no `gpufab-render`-authored commit exists on `main` |
| `deploy.yml` apply | **NOT BUILT** | `:23-27` is a stub ending `exit 1  # fail loudly until P6 implements the apply` |
| `check_bgp.py` post-check | **NOT BUILT** | 13-line file; `:13` is `sys.exit("check_bgp.py: not implemented yet — build phase P4")` |
| `drift-check.yml` | **BUILT AND BROKEN** | `:17` passes `--post-metrics --update-issue`; `drift.py:111-116` accepts only `--root`, `--device`, `--json` → argparse exit 2. This is why every run died in 6–8s |
| `drift.py` itself | **BUILT BUT UNPROVEN** | Sound logic; no test invokes it, and its only caller passes flags it rejects |
| `remediation_bot.py`, `reapply.sh`, `bounce.sh` | **BUILT AND BROKEN — severed twice** | `monitoring/alertmanager.yml:2-8` is `route: {receiver: blackhole}` with a null receiver ("Route to the remediation bot once P8 lands"), so **no alert can ever reach the bot**. Independently, the bot's allowlist keys are `ConfigDrift`/`BGPPeerDown`/`InterfaceOperDown` (`remediation_bot.py:41-43`) while `monitoring/rules.yml` emits `SonicBgpPeerDown`, `FabricSessionsDegraded`, `SwitchUnreachable`… — **not one name matches**, so even if routed, no action could fire. Bot also ships `BOT_DRY_RUN=1` (`:31`), and `reapply.sh:38` re-renders **from NetBox**, so proving it would still not prove a *git*→device path |
| `playbooks/p4-render.md`, `p6-gitops.md` | **NOT BUILT** | Referenced by `validate.yml:26`, `deploy.yml:25`, `check_bgp.py:13`; neither file exists. `gpufab-docs/playbooks/README.md` lists all eleven playbooks p0–p10 as "not started" |

The apply step, verbatim (`gpufab-network/.github/workflows/deploy.yml:23-27`, in
a file of 30 lines total, with **one commit in its entire history** — the
2026-07-23 scaffold):

```yaml
      - name: Apply per-device (config load/reload; frr-reload for hosts)  # P6
        run: |
          echo "tools/deploy_device logic lands in P6 (playbooks/p6-gitops.md)"
          echo "would deploy: ${{ steps.diff.outputs.devices }}"
          exit 1                     # fail loudly until P6 implements the apply
```

**There are four independent breaks, any one of which alone prevents the loop
from closing**, which is why "the loop has never closed" is a structural
statement and not bad luck:

1. No PR has ever been merged (0 of 9).
2. `deploy.yml:5` filters on `rendered/**`, but renders have gone to
   `instances/<sim-id>/rendered/` since `7c08d0e` (2026-07-24). A merged PR would
   not even fire the workflow. That commit changed `render.yml`, `render.py` and
   `rendered/README.md` and did **not** change `deploy.yml` or `validate.yml`.
3. The apply step is a stub.
4. The post-check it would gate on is also a stub.

**What is worth crediting anyway.** `render.yml` (108 lines) is careful, senior
work: it routes a matrix on `client_payload.sim_id`; it makes the runner assert
its own `/opt/gpufab/instance-id` matches the dispatched sim and *fail loudly* on
mismatch (`:43-58`); it takes NetBox URL and token from a sim-local file with
**no global fallback** (`:72-76`), because a repo-wide variable let a correctly
routed runner reach another sim's NetBox; and it renders an **empty matrix**
rather than one arbitrary runner when `vars.SIM_IDS` is unset (`:32-40`), on the
stated grounds that "a job that visibly does not run is a configuration error
somebody fixes; a job that silently covers one sim of six is one nobody notices."
That is precisely the right instinct. It was applied to one workflow of four.

**And config does reach the switches on every build** — via
`tools/interim_deploy.py` over SSH, which `REVIEW-2026-07-27.md:618` calls "the
apply — the only thing that puts routing config on a switch". There is also a
NetBox→device remediation path (`bot/actions/reapply.sh`). Neither touches git.
`grep -rn "git push"` across `deploy/`, `bot/` and both `tools/` trees finds
**no matches**; the only `git push` in the entire system is `render.yml:101`.

---

## 4. Root cause of the process failure

The hypothesis under test was: *effort went into making an existing narrow path
correct, and almost none into making the system able to express new kinds of
state.* **The commit and issue record supports this strongly, with one specific
correction.**

### 4.1 The commit ratio

All 465 non-merge commits across the three repos were classified
(`.claude/worktrees/` excluded):

| bucket | platform | network | docs | total |
|---|---|---|---|---|
| **A** correctness / fix | 138 | 41 | 0 | **179** |
| **B** verification / test | 66 | 7 | 1 | **74** |
| **C** scale / parameterisation | 22 | 17 | 0 | **39** |
| **D** new expressive capability | 3 | 11 | 0 | **14** |
| **E** ops / infra / plumbing | 82 | 4 | 0 | **86** |
| **F** docs | 2 | 2 | 69 | **73** |

**(A+B) : D = 253 : 14 = 18 : 1.** Five of the fourteen D commits are the first
48 hours *creating* the path rather than widening it (`c81818c`, `d164c40`,
`f8e1ece`, `9d83795`, `aaa4998`); against expansion only the ratio is **28 : 1**.
Even moving nine arguable C/E commits into D leaves 11 : 1.

A corroborating measure: in `gpufab-platform`, `tests/` is 14,132 tracked lines
against `tools/` — all the derivation and model logic — at 4,162. **The
verification layer is 3.4× the size of the thing it verifies.**

The timeline shows a sharp phase change. 07-23/24 is genesis (6 of 14 D commits).
07-25 is one day of pure modelling — 21 C commits building `fabric_model.py` and
the S0–S5 ladder — and produced **zero** D. From 07-26 onward the curve inverts:
07-26 and 07-27 together contribute 120 A + 43 B against 5 D, and 07-27 is 83%
correctness-and-test.

The renderer's own history makes the point in miniature. `render_fabric_ztp.py`
took 21 commits, +1024/−227 to reach 797 lines, of which only ~500 are code.
**Its single largest commit, `23260dc` (+319/−44), adds no new table at all** —
it re-derives `PORT` from the SoT because a 32-port table from a base snapshot
had been applied to 64-port switches, rendered cleanly, was accepted by `config
reload`, and passed a rendered-vs-applied test while 178 BGP sessions were lost.
That is the shape of essentially all renderer growth after 07-26.

### 4.2 The issue record, and the mechanism

Of the 88 issues open at the time of classification: **51 CORRECTNESS + 23
VERIFICATION GAP = 74, or 84%.** Capability gaps: 4. Scale/perf: 2. Ops/infra: 8.

The decisive cell is the cross-tab of category against how the issue was found:

```
                review-round   cold-run   test-failure   user-question   TOTAL
CORRECTNESS               40         11              0               0      51
VERIFICATION               7         11              5               0      23
SCALE/PERF                 0          2              0               0       2
CAPABILITY                 2          0              0               2       4
OPS/INFRA                  5          3              0               0       8
TOTAL                     54         27              5               2      88
```

**CAPABILITY × cold-run = 0. CAPABILITY × test-failure = 0.** Thirty-two issues
were found by *executing* the system — including the celebrated cold run that
found eight defects ten review rounds could not — and not one of them was a
capability gap. This is not a coincidence or an oversight; it is a property of
the method. **Running the system can only find defects in paths the system
already has.**

The project's own closure behaviour confirms the asymmetry: correctness issues
are 8% open; capability issues are 75% open.

### 4.3 The correction to the hypothesis

The claim that #87 (VXLAN/EVPN) and #88 (day-2 add/remove) were the *first*
capability-gap issues is **refuted**. Two earlier ones exist, and both were
raised in the very first review round:

- **#55 [O1]** — multi-host deployment never enables topology sharding; every
  host builds the whole fabric. Register item **A1**. Still OPEN.
- **#57 [O3]** — routed head-hosted management (ZTP/TACACS) unimplemented; "no
  DHCP-relay deployment exists ... This is a project, not a patch." Register item
  **A3**. Closed 2026-07-28 by `283b546`/`fe6c631` — with the explicit caveat
  *"Not yet measured end to end — `terraform apply` is the user's to run, so no
  switch has reached the head."*

So reviews *can* surface capability gaps. They surfaced two, both in round one,
and nothing in rounds B through H. What the hypothesis gets right in substance is
the trigger: #87 and #88 both open with the human's question verbatim — *"Raised
as a fidelity question: how do we verify VXLAN?"* and *"Raised as: how do we test
adding or removing a switch or a GPU node?"* They are also the **only two of 89
issues labelled `enhancement`**; the other labelled issues all carry `bug`.

### 4.4 The mechanism, stated plainly

The coordinator's proposed mechanism — that the suite grew where failures were
already being found, so ZTP tests found ZTP defects which justified more ZTP
tests, a feedback loop with no term for anything outside it — **is supported by
the record, and it is a better explanation than deliberate deprioritisation
because it requires nobody to have decided anything.**

The evidence is in the test files' own birth commits:

- `t26` — "asserts the port budget nothing was asserting (O2)"
- `t29` — "models the second write that t20 is structurally blind to"
- `t27` — "executes image-scrub's positive controls instead of trusting them"
- `t28` — "executes the routed-OOB claims instead of asserting them"
- `t22` — "asserts the review fixes, and it found another one"
- `t04`/`t05`/`t06` — "a harness, because ad-hoc verification kept reporting
  results it had not measured"

Almost every test in the suite was born from a defect that had already been
found. That is a healthy reflex and it produced a genuinely good suite. But it is
a *reactive* rule, and a reactive rule can only ever cover ground that has
already produced a failure. GitOps produced no failures because nothing ran it;
because nothing ran it, no test was written for it; because no test was written
for it, it produced no failures. Nothing in the loop can break that cycle from
the inside.

No evidence was found of a deliberate decision to deprioritise IaC or GitOps.
There is no commit, issue or design-doc entry saying "defer GitOps". What exists
instead is a scaffold created on 2026-07-23 (`aefbdd3`) and never returned to:
`deploy.yml`, `drift-check.yml` and `validate.yml` have **exactly one commit each
in their entire history**, while `render.yml` has nine. Three quarters of the
GitOps pipeline was written once, on day one, and never touched again.

---

## 5. Why the design rounds did not catch it

Ten review rounds found ~50 defects by reading (`ISSUE-REGISTER.md` sections A–G:
12+6+4+8+6+8+6) and one cold run found 8 more (section H). Not one was "the
config surface is fixed." The reason is structural and is written into the review
document's own scope statement.

**`REVIEW-2026-07-27.md:7-8` defines its scope as: "All commits with an author
date from `2026-07-26 00:00 UTC` to `2026-07-27 05:40 UTC`, on `main` in all
three repos."** And `:3-5`: the document exists "so a reviewer can decide,
subsystem by subsystem, whether to accept **each change**".

**The unit of review is the diff.** A capability that was never coded produces no
diff, and therefore falls outside the scope of every review round by
construction. The review's section headings confirm it: §1 the deploy sequence,
§2 the model, §3 the renderer, §4 the apply path, §5 the deploy stages, §6 the
SoT, §7 observability, §8 tests, §9 terraform, §10 docs, §11 new files, §12
uncommitted work, §13 known-open items. Every section is organised around a
component that exists. There is no section that asks *what should exist and does
not.*

This also explains the review rounds' most striking statistic — that sections B,
C and D of the register are **regressions in the previous round's fixes** (6, 4
and 8 findings respectively). A review whose input is the last review's diff will
converge on the diff, and will keep converging on it. It cannot diverge toward a
requirement it was never handed.

Three further blind spots follow from the same cause:

1. **The oracle can only count.** `tools/expected.py` is described in its own
   header as "the single place that answers *how many of X should exist*". All 25
   of its keys are cardinalities — `switches`, `cables`, `bgp_sessions`,
   `max_ports_per_switch`, `gpus`, `switches_by_tier`. There is no key for a
   capability, a table type or a feature. **A test cannot assert what the oracle
   cannot state**, so a test suite built on `expected.py` is confined to counting
   by construction.
2. **The assertions are overwhelmingly numeric.** Across all 31 tests: `t_count`
   150, `t_min` 155, `t_zero` 125, `t_eq` 48 — **430 of 478 assertions (90%) are
   numeric cardinality**, and the 48 `t_eq` are exit statuses, addresses,
   aggregation-level names and reachability booleans.
3. **The fidelity plan has GitOps in a section title and nowhere else.**
   `FIDELITY-VERIFICATION-PLAN.md:176` heads §5.6 "**ZTP / GitOps** (guide 7.10)
   — target L1, **strong area**". The section contains FV-ZTP-01 through
   FV-ZTP-04 — **four ZTP items and zero GitOps items**. The nearest thing to a
   GitOps test in the whole plan is FV-TEL-01 ("Config drift: alter MTU/BGP
   out-of-band, detect and correct", `:194`), filed under telemetry, unrun. The
   document that exists specifically to enumerate what is *not yet verified*
   called GitOps a strong area and then listed nothing to verify about it.

One further countermeasure is weaker than it reads. `tests/lib.sh:30-39` —
`t_count` treats an observation of zero as a failure **only when the expected
value is non-zero**; `t_count "label" 0 0` passes. Several tests reach that
branch on paths where nothing was contacted. This does not undermine the suite's
overall quality, but it means "a check that measured nothing is a failure" is not
yet true everywhere the project believes it is.

---

## 6. The doc-vs-code delta

Nothing in the project tests documentation against code. The suite tests the code
against itself. This is where the gap accumulated silently.

| # | Doc claim | Where | Status | Evidence |
|---|---|---|---|---|
| 1 | "② GitOps (render/validate/deploy/drift + relay + runner) — **identical** — real (**loop verified live**)" | `gpufab-sim-design.md:30` | **CONTRADICTED** | `deploy.yml:23-27` is an `exit 1` stub; deploy has 2 runs, both failed; drift-check 0/18 successes |
| 2 | "**P6 GitOps — loop live end-to-end** … Remaining: `deploy.yml` apply-on-merge + `drift-check` to green" | `gpufab-sim-design.md:252` | **ACCURATE** | Self-caveated correctly. The PR half genuinely ran (PR #3, 2026-07-24). This line is the honest one; line 30 is not |
| 3 | "An operator never SSHes to a switch to make a lasting change … the loop renders → reviews → applies → verifies" | `network-automation-design.md:49` | **NOT IMPLEMENTED** | Every lasting change is applied by `interim_deploy.py` over SSH; `deploy/50-configure.sh:39`, `deploy/50-ztp-provision.sh:154` |
| 4 | "Config contexts — weight-ordered: global → per-role → per-fabric via tags → per-device" | `network-automation-design.md:110` | **NOT IMPLEMENTED** | `grep -rn 'config_context\|config_template'` across all three repos: zero hits |
| 5 | "SoT-authoritative, **drift-reverted** — … drift-check reverts hand edits" | `network-automation-design.md:332` | **NOT IMPLEMENTED** | `drift-check` has never succeeded (0/18); `drift.py` has no revert path and its caller passes flags it rejects |
| 6 | "**B2 GitOps** … exit criterion: a SoT edit auto-opens a rendered PR" | `network-automation-design.md:303` | **IMPLEMENTED** | 9 PRs, 6 `render/*` branches authored by `gpufab-render`. This exit criterion was met |
| 7 | `rendered/README.md` states `deploy.yml`, the ZTP web root, the drift checker and the bot all read `instances/<sim-id>/rendered/` | `gpufab-network/rendered/README.md` | **CONTRADICTED** | `render.py` is the sole writer of that path and has **zero readers**; `git ls-files 'instances/*'` returns 0 |
| 8 | "FV-ZTP-01 … with the backfill disabled" | `FIDELITY-VERIFICATION-PLAN.md:180,185` | **NOT RUN** (doc is candid, and now stale) | The s11 run gives equivalent evidence but the stated experiment is still unrun; `:185` still says ZTP "has been observed neither working nor failing", which the s11 result supersedes |
| 9 | §5.6 titled "ZTP / **GitOps** — strong area" | `FIDELITY-VERIFICATION-PLAN.md:176` | **VACUOUS** | Four ZTP items, zero GitOps items |
| 10 | Playbooks p0–p10, incl. `p4-render.md` and `p6-gitops.md` | `gpufab-docs/playbooks/README.md` | **NOT WRITTEN** (doc is candid) | All eleven marked "not started"; none exists. Three code sites point at two of them |
| 11 | Build times 29m38s / 25m23s / 29m09s | `HANDOFF-2026-07-29.md` | **CORRECTED 07-29** | The s11 cold build measured **24m11s** (#58, 09:45Z). The handoff now records that `29m09s` appears nowhere in any repo, and that `terraform/sims.tf:118-119` and `FEATURE-EXTENSIBILITY.md:1008` are the two sites still stale |
| 12 | "NetBox is the active SoT for config (render + gen_topology read NetBox, not the profile)" | `gpufab-sim-design.md:246` | **CONTRADICTED** | `interim_deploy.py` has 0 NetBox references and is invoked `--profile`; `roles/fabric.sh:338` sets `TOPO_FROM_PROFILE=1`. See §3.2 |
| 13 | `validate` is a "**required gate**": JSON-schema, NOS syntax, cross-device lint (ASN/loopback uniqueness, /31 pairing, neighbour symmetry) | `network-automation-design.md:175` | **NOT IMPLEMENTED, and passes having measured nothing** | `validate.yml:26` is `echo "…placeholder pass"`; `:17,24` `find rendered …` over a directory holding only `README.md`. Both loops execute zero times and the step exits 0 — the codebase's signature defect, inside its own required gate |
| 14 | "QoS config is still rendered & validated, just inert (hardware-ready)" | `gpufab-sim-design.md:17,225` | **CONTRADICTED** | No `BUFFER_POOL`, `BUFFER_PROFILE`, `WRED_*`, `QUEUE`, `PORT_QOS_MAP`, `SCHEDULER` or PFC table is emitted anywhere; the base snapshot has none. `drift.py:87` lists the buffer tables in its *ignore* set |
| 15 | Frontend VLANs 100/200, single-active SVI gateway; "MTU 9214 fabric / 9000 host" | `network-automation-design.md:73,138` | **CONTRADICTED / NOT IMPLEMENTED** | `interim_deploy.py:240` **deletes** `VLAN`/`VLAN_MEMBER`/`VLAN_INTERFACE` from every switch on every push. `grep -rni 'mtu'` over all renderer/model code: **zero hits** — no interface is ever given an MTU |
| 16 | `design/policy/{addressing,asn,naming}.yaml` — "**THE single source** for every CIDR and allocation rule" | `addressing.yaml:1` | **CONTRADICTED — entirely dead** | No code opens them; the only reference is a *comment* in `t01-provenance.sh:40`. Live allocation is hardcoded in `fabric_model.Addressing` and `gpufab.derive()` |
| 17 | Fidelity tiers `vm` / `container` / `frr` underpin the "no ceiling" cost model | `scale-out-architecture.md:708-715,1908` | **NOT IMPLEMENTED** | Fidelity is used only for RAM arithmetic (`fabric_model.py:50`); `gen_topology.py:286-297` emits three hardcoded kinds and never branches on it. All 10 profiles pin `fidelity: vm` |
| 18 | BGP unnumbered — "Implementation status: **done**"; "p2p addresses \| 0" | `scale-out-architecture.md:571,664,1626` | **PARTIAL — built, unused** | The path is real (`render_fabric_ztp.py:706`, `deploy/55-unnumbered.sh`) but defaults to `numbered`, and **all 10 scale profiles declare `p2p: numbered`**. Every deployable fabric still allocates /31s |
| 19 | Slurm rendered from NetBox and deployed via `scontrol reconfigure`; DDN service VIP BGP-advertised; host bootstrap via Ansible | `gpufab-sim-design.md:166,172-176,94` | **NOT IMPLEMENTED** | No `slurm.conf.j2`/`gres.conf.j2`, no `.sbatch`, no `scontrol`, no `gpufab-platform/slurm/`, no `ansible/` directory. `gpufab.py:493-495` still shells out to `ansible-playbook site.yml` |
| 20 | LLDP audit gate — "the reservation asserts identity, LLDP confirms position" | `network-automation-design.md:219,284,305` | **NOT IMPLEMENTED** | `tools/audit_lldp.py:12` is `sys.exit("not implemented yet — build phase P3")`. `clab/reconcile.py` is a good substitute but compares clab adjacency to NetBox, not LLDP from the devices |
| 21 | "Status: design. **Nothing below has been run.**" | `FIDELITY-VERIFICATION-PLAN.md:9` | **STALE — the doc understates the project** | All five F0 gates exist and ran with committed evidence (`tests/fidelity/evidence/FV-CAP-0{1..5}/result.json`). FV-CAP-02, the plan's "single highest-value test", is `pass` at **L3** — the VS dataplane does forward, 20/20 leaf-to-leaf. Of the 34 downstream FV tests, **0 are implemented** |

**The pattern is consistent and worth naming: the parts the project measured are
real and good; the parts it only described drifted, and nothing in the repo can
tell the two apart.** `scale-out-architecture.md` is largely honest about itself
— it labels Batfish "designed, not built" (`:2070`), the VXLAN substrate "none
are currently in place" (`:1460`), and keeps a "Still open" list. Read as a
roadmap it is accurate. `gpufab-sim-design.md` and `network-automation-design.md`
are where the delta is sharpest, precisely because they describe things as
*working*.

**One live defect fell out of this comparison and should be filed.** The three
management tables `MGMT_INTERFACE`, `MGMT_PORT` and `MGMT_VRF_CONFIG` are emitted
**only** by the ZTP renderer (`render_fabric_ztp.py:675-677`). `interim_deploy`
neither writes them nor lists them in `_OWNED_WRITE` (`:664-665`). So the
management-VRF isolation invariant is delivered by one of the two apply paths,
and **a switch that regressed on it would still be reported in-sync.** That is
the same shape as the SNMP defect that cost six review rounds — and `SNMP`/
`SNMP_COMMUNITY`, now correctly owned by the push, are dropped by `drift.py:87`,
so a switch reverting to the `public` community is invisible to the drift
checker that was supposed to be the backstop.

**One important item is *not* a doc-vs-code delta, and the record corrects the
framing of issue #87.** VXLAN/EVPN was **explicitly designed out**, not
overlooked or promised:

- `gpufab-sim-design.md:227` — "R3 | EVPN/VXLAN fragile on VS | **Designed out** —
  pure L3 + plain VLAN frontend"
- `network-automation-design.md:331` — "Pure L3 backend, VLANs only on the
  frontend — **EVPN/MCLAG are explicit non-goals for v1**"

#87's title, "VXLAN/EVPN is designed but not built", is therefore not quite
right; the docs declared it out of scope with a stated reason. The real finding
underneath #87 is the more general one and does survive: **there is no mechanism
by which VXLAN — or any other new kind of state — could be added without
coordinated hand edits across three enumerations and the test suite.** That is
the right issue, and it is what `FEATURE-EXTENSIBILITY.md` addresses.

---

## 7. What honest reporting would have looked like

Every number reported over this project was true. 1464/1464 BGP sessions,
46/46/46 in-sync, 48/48 ZTP fetches, 124 containers, 24m11s cold build, 46/46
scrub controls, 103/103 on t22 — all measured, most measured against a device
rather than a metric, several re-measured after an earlier claim was found to
have been taken warm. The measurement culture here is better than most production
teams achieve.

**The problem is not that the numbers were wrong. It is that they were all
denominated in the same unit — quantity of the narrow path — and quantity of a
narrow path rises monotonically as the path is polished.** Every report was
therefore both accurate and reassuring, and their accuracy is precisely what made
them reassuring. Nine consecutive true statements that the fabric converged
1464/1464 read as nine pieces of evidence that the system was healthy, when they
were nine measurements of the same twelve tables.

Three specific reporting habits made it worse:

1. **A caveat present in one place and dropped in another.**
   `gpufab-sim-design.md:252` states the GitOps position correctly, including
   "Remaining: `deploy.yml` apply-on-merge + `drift-check` to green". The summary
   table at `:30` compresses the same fact to "real (loop verified live)". Summary
   tables are what get read.
2. **"Verified" used for two different things.** PR #3 verified that a NetBox
   edit produces a reviewable PR. It did not verify that a change reaches a
   device. Both were reported as the loop being live.
3. **Progress reported against the plan's *stages* rather than its *claims*.**
   The handoff documents are organised by what was worked on (O4, O5, O6,
   telemetry, secrets). Nothing is organised by the design's own pillar list, so
   pillar ② could go four days without a commit and never appear as a gap.

**What should be tracked alongside the existing metrics**, so this surfaces
without anyone having to think of it:

- **A config-surface count, reported next to the BGP count.** "12 derived
  `config_db` tables, unchanged for 6 days" is a one-line addition to every
  handoff and would have made the ceiling visible on day two. It is derivable
  mechanically from `render_fabric_ztp.py`.
- **Divergence between the three enumerations.** The renderer's tables,
  `interim_deploy._OWNED_WRITE` and `expected.py`'s keys should be printed side
  by side by a committed check. Any table rendered but not owned is silently
  unverified on the box — which is exactly how the SNMP defect survived.
- **A per-pillar status line, using the four-state vocabulary in §3**: NOT BUILT
  / BUILT AND BROKEN / BUILT BUT UNPROVEN / BUILT AND PROVEN, with the proof
  cited. "GitOps: BUILT AND PROVEN to a PR; apply NOT BUILT" is a sentence nobody
  could have read as healthy.
- **Last-successful-run age per workflow.** `drift-check` has never succeeded in
  18 attempts across five days. A single line in the gate — "drift-check: last
  success never" — would have surfaced it immediately.
- **Doc-claim coverage.** A committed check that extracts the exit criteria from
  `network-automation-design.md` §B2 and the disposition table in
  `gpufab-sim-design.md`, and reports which have a corresponding test. This is
  the only item on this list that does not exist in any form today, and it is the
  one that would have caught the whole class.

---

## 8. What to do now, ranked

The mechanism design is `design/FEATURE-EXTENSIBILITY.md`, committed in parallel
with this document as `fcd1ce6` ("three enumerations collapsed into one computed
manifest"; status "design, 2026-07-28, not implemented"). It covers the
three-enumeration problem, the feature-module interface, precedence, validation
layers, the GitOps round trip, day-2 add/remove and migration. **This section
deliberately does not restate it** and ranks only the actions that follow from
this retrospective.

| # | Action | Cost | Why this rank |
|---|---|---|---|
| 1 | **Fix `drift-check` and report last-success-age per workflow.** `drift.py:111-116` must accept `--post-metrics` and `--update-issue`, or `drift-check.yml:17` must stop passing them. | ~1 hour | A one-flag mismatch has kept the only automatic SoT-vs-device comparison dead for five days and 18 runs. Cheapest possible restoration of a real GitOps property, and the flag-mismatch class is already known (register H8, `verify.sh` and `--zone`) |
| 2 | **Close the render→deploy path filter.** `deploy.yml:5` and `validate.yml:4` filter `rendered/**`; renders go to `instances/<sim>/rendered/`. Also `deploy.yml:20`'s `cut -d/ -f2` would yield the sim id, not the device. | ~1 hour | Independent of the apply stub, and if it is not fixed then implementing the apply changes nothing. Also un-vacuums `validate.yml`, whose 4 "successes" iterated an empty loop |
| 3 | **Add one end-to-end GitOps test that fails today**, closing the loop on a single device: commit a rendered change → merge → workflow applies → assert on the box. | ~1 day | This is the missing feedback term identified in §4.4. Until a GitOps failure can be *observed*, the process cannot allocate work to GitOps. Model it on `t11-config-applied.sh`, which already compares on-box config to rendered config |
| 4 | **Implement `deploy.yml`'s apply and `check_bgp.py`.** Both are stubs pointing at unwritten playbooks. | ~2–3 days | The apply is the pillar's whole point. Rank 3 comes first deliberately: write the test that fails, then make it pass |
| 5 | **Emit the config-surface and enumeration-divergence report** described in §7, wired into `verify.sh`. | ~half a day | Makes the ceiling and the three-enumeration drift visible on every run, permanently. Cheap, and it is the standing guard against a recurrence |
| 5a | **File and fix the `MGMT_*` ownership asymmetry** (§6). Add `MGMT_INTERFACE`/`MGMT_PORT`/`MGMT_VRF_CONFIG` to `interim_deploy._OWNED_WRITE`, or make the push emit them. | ~2 hours | A live latent defect of exactly the shape that cost six review rounds on SNMP: a switch can regress on mgmt-VRF isolation and still be reported in-sync. Item 5 would have surfaced it automatically |
| 5b | **Retire or migrate the legacy `gpufab.py` CLI and its profile set — decision OPEN (see the CLI issue).** The legacy CLI reads a *second, noncanonical* profile set — `gpufab-platform/profiles/` (full/gpu64/lite/minimal/th5), distinct from the canonical `gpufab-network/design/profiles/` scale ladder — and its `validate/estimate/up` evaluate *unrelated legacy bounds* and merge legacy defaults, so they never validated the scale model at all. **Contained, not resolved:** the deploy default was repointed to `scale/s0-64.yaml` (`bc9e061`), and `gpufab.py` now REFUSES `fabric.regions` profiles loudly before any command runs (`74a02f4`, proven behaviorally by `t06`). What remains is the deliberate choice: **retire** (preferred — the unattended path is `tools/up.sh` + role/deploy scripts and scale rendering is `fabric_model.py`, so `gpufab.py up`'s legacy Terraform/GCP lifecycle is a second orchestrator not worth keeping) or **migrate** the CLI onto `fabric_model` end to end (its summary schemas differ, so not a one-line swap). | ~half a day | No longer a fabrication landmine (scale is refused); this is now an architecture decision about whether a legacy orchestrator + profile set survives at all |
| 6 | **Run FV-ZTP-01 as specified** — backfill disabled, on a sacrificial fabric — and update `FIDELITY-VERIFICATION-PLAN.md:185`, which the s11 result has already overtaken. | ~half a day + one sim | ZTP is the strongest pillar and is one experiment away from being provably closed rather than inferentially closed |
| 7 | **Reconcile the design docs against the code**, starting with the eleven rows in §6. At minimum, correct `gpufab-sim-design.md:30` and `gpufab-network/rendered/README.md`. | ~half a day | The docs are the only statement of intent. While line 30 says "loop verified live", every future reader re-inherits the same false picture |
| 8 | **Implement `FEATURE-EXTENSIBILITY.md`.** | See that document's §9 | Correctly last. It is the largest item and the one most likely to be built on wrong assumptions if items 1–5 have not first made the current surface and its failures visible |

Items 1, 2 and 5 together cost roughly a day and change the project's feedback
structure permanently. Items 3 and 4 are the pillar. Item 8 is the future.

---

## 9. What this project did well, and should not lose

A retrospective that reads as uniformly negative gets discounted, and this one
would deserve to be.

- **A cold, unattended build from bare VMs to a converged 512-GPU fabric in
  24m11s**, with 1464/1464 BGP sessions matching `expected.py` exactly. The first
  one took 29m38s and beat the previous hand-assembled best by ten minutes.
- **O4 was root-caused from a live device after two plausible hypotheses had
  died.** The discipline of refusing a third hypothesis and diffing a cold box
  instead — and of *reopening* an issue after noticing the closing measurement had
  been taken warm — is rarer and more valuable than the fix.
- **Per-sim runner routing in `render.yml`** is genuinely careful engineering:
  identity asserted on the box, no global credential fallback, an empty matrix in
  preference to one arbitrary runner.
- **`t24-secret-iam.sh` performs the read** rather than inspecting a policy, and
  refuses to skip when it cannot measure. `t27` executes the image scrub's
  positive controls — 6 failures against `origin/main`, 10 passes against the fix.
  `t11` compares the box against what was rendered for it. These are the right
  patterns.
- **The evidence bundle** at `gpufab-docs/evidence/2026-07-27-insync-tacacs/`,
  including a YANG validation run to prove a config change could not brick ZTP
  fleet-wide before it was shipped.
- **The register is honest about its own failures**, including that sections B, C
  and D are regressions in the previous rounds' fixes, and that section H's eight
  defects were invisible to all ten reading passes.

The failure this document describes is not a failure of rigour. It is a failure
of *aim*: extraordinary rigour, applied for five days to a target that was never
re-examined.

---

## Appendix — how this was established

Commands and sources, so any claim here can be re-derived:

- Commit classification: `git log --no-merges --numstat` over all three repos,
  `.claude/worktrees/` excluded; 465 commits classified individually.
- Issue classification: `gh issue list --repo gpufab-platform --state all
  --limit 200 --json number,title,state,labels,createdAt,closedAt,body`.
  Note: all issues were **filed on 2026-07-28**, retroactively, by
  `tools/file_issues.sh` (#1–72) and by hand (#73–89), so creation date is a
  filing date, not a discovery date. Discovery order is the A–H register prefix.
- Workflow history: `gh run list --repo gpufab-network --limit 300 --json
  workflowName,conclusion,status,event,createdAt`; 41 runs total.
- PR history: `gh pr list --repo gpufab-network --state all --json
  number,state,mergedAt`.
- The `deploy.yml` stub was confirmed twice: in the workflow source and in the
  downloaded run log for run `30134817613`, line 97.
- Profile derivation was tested by calling `fabric_model.derive()` on a
  `yaml.safe_load`ed profile. The first attempt passed a *path* instead of the
  loaded dict and raised `AttributeError` for every profile including the ones
  that work — a check that measured nothing and would have "confirmed" the
  finding for the wrong reason. The numbers here are from the corrected call.
- Test counts: `grep -l` with flags separated, in
  `gpufab-platform/tests/` at `8af859a`.

**Not established from the record, and therefore not claimed:** what was said in
conversation at any point; why `deploy.yml` was left as a scaffold (no commit,
issue or doc records a decision either way); and whether the 4 queued
`drift-check` jobs would succeed if a correctly-labelled runner came online, since
`drift.py` would still reject the flags.
