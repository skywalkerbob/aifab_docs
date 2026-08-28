# Issue register — 2026-07-27/28

Every defect found in this review-and-run cycle, with the commit that closed it.
Ordered by how it was found, because that ordering is itself the finding: the
last section was produced by a single execution and is qualitatively different
from everything above it.

Status: **CLOSED** (fixed and pushed) · **OPEN** (needs a decision or work) ·
**NOT A CODE BUG** (correctly diagnosed elsewhere).

---

## A. First review pass — 12 findings

| # | Sev | Issue | Status | Commit |
|---|---|---|---|---|
| A1 | S1 | Multi-host deploy never enables sharding; every host builds the whole fabric | **OPEN** | placement exists (`_shard`→`fabric_model.place`); provisioning ownership does not |
| A2 | S1 | S5 cannot pass stage 30 — port materialization fails | **NOT A CODE BUG** | `s5-32768` wants **70 links on a 64-port switch**. The guard is right; the profile must change |
| A3 | S1 | Routed head-hosted management (ZTP/TACACS) unimplemented | **OPEN** | needs a DHCP relay; stage 45 would block the flows anyway |
| A4 | S1 | Spot recovery compares a local shard against the **global** SoT count | CLOSED | `795736e` |
| A5 | S1 | Head role converts a failed deploy into a log line and returns success | CLOSED | `0a5e139` |
| A6 | S1 | Every head's watchdog controls **every** sim's fabric hosts | CLOSED | `795736e` |
| A7 | S2 | Recovery validates one NetBox token and embeds another | CLOSED | `795736e` |
| A8 | S2 | Stage 00 changes code revisions mid-deployment | CLOSED | `2dd0339` |
| A9 | S2 | `--from` can run zero stages and report success | CLOSED | `0a5e139` |
| A10 | S2 | Non-ZTP path probes one hardcoded, profile-specific address | CLOSED | `773a595` |
| A11 | S2 | Head telemetry installs fabric-only services | CLOSED | `0a5e139` |
| A12 | S3 | Teardown does not restore the baseline it claims | CLOSED | `773a595`, `925c98d` |

## B. Second pass — 6 regressions **in the fixes for A**

| # | Issue | Status | Commit |
|---|---|---|---|
| B1 | A11's guard broke the legacy monolith (`ROLE` unset must run everything) | CLOSED | `925c98d` |
| B2 | A12 not actually fixed — wrong crontab user; live INPUT rules left; flushing DOCKER-USER erased unrelated policy | CLOSED | `925c98d` |
| B3 | A6 half-fixed — `FABRIC_HOSTS` holds **addresses**, not instance names | CLOSED | `925c98d` |
| B4 | A10's diagnostic unreachable: the failed assignment aborted under `set -e` first | CLOSED | `925c98d` |
| B5 | A7's fix exposed the token in a world-readable unit file | CLOSED | `925c98d` |
| B6 | Recovery counted **every** containerlab lab as gpufab nodes | CLOSED | `925c98d` |

## C. Third pass — 4 more, in the fixes for B

| # | Issue | Status | Commit |
|---|---|---|---|
| C1 | Token was a **literal string**: escapes inside a quoted heredoc reached the host as `${NETBOX_TOKEN:-}`, never expanded, never empty, sent to NetBox as the token | CLOSED | `c96a7e5` |
| C2 | `lib.sh` supplied the dev token as a fallback, so C1's guard could never fire | CLOSED | `c96a7e5` |
| C3 | Teardown inferred firewall ownership from addresses — **twice**, the second time two rounds after the design forbade it | CLOSED | `c96a7e5`, `95033c5` |
| C4 | A8 left a second-update race: once re-exec'd, the revision check was skipped | CLOSED | `c96a7e5` |

## D. Fourth/fifth pass — 8 more

| # | Issue | Status | Commit |
|---|---|---|---|
| D1 | Firewall rule lifecycle neither idempotent nor upgrade-safe (`iptables -C` matches the full spec, so tagged ≠ untagged) | CLOSED | `21d972f` |
| D2 | Stopped-fleet preflight produced a **false green** — skips counted as passes | CLOSED | `21d972f` |
| D3 | `del_both` deleted a generic `ESTABLISHED,RELATED` rule indistinguishable from ordinary host policy | CLOSED | `32161e3` |
| D4 | `--only` overruled by phases it never selected | CLOSED | `32161e3` |
| D5 | Credential provisioning not end-to-end: head created one token, stage 00 fetched a different one | CLOSED | `b6f757b`, `7ec8e04` |
| D6 | Seed gate proved **quantity, not identity** (`>=` satisfied by a larger stale topology) | CLOSED | `dab5224`, `4a8050b` |
| D7 | Exit zero did not mean complete — six required subcomponents swallowed their own failures | CLOSED | `dab5224` |
| D8 | Sim-scoped ALLOW created **no boundary**: a non-matching rule is disregarded, not a denial | CLOSED | `32161e3` (explicit cross-sim DENY at priority 950) |

## E. Controller / identity pass — 6

| # | Issue | Status | Commit |
|---|---|---|---|
| E1 | Head and fabric minted **different run ids**, so the gate's equality check was unsatisfiable by anything | CLOSED | `a79c181` (`tools/up.sh`) |
| E2 | `result-head.json` written by the child **before** the wrapper finished | CLOSED | `a79c181`, `4cd339e` |
| E3 | Early failures recorded locally but never shipped (logship ran after fallible stages) | CLOSED | `a79c181` |
| E4 | Teardown minted a run id, wrote no result, then deleted the logs | CLOSED | `a79c181` |
| E5 | S3 sink omitted the run id the GCS/rsync sinks carried | CLOSED | `a79c181` |
| E6 | Re-exec made the run-id SHA misleading | CLOSED | `a79c181` (records `initial_sha`) |

## F. Completion-blocker pass — 8

| # | Issue | Status | Commit |
|---|---|---|---|
| F1 | A **successful** fabric role never wrote the result the launcher waits for — `exec` made the write unreachable | CLOSED | `4cd339e` |
| F2 | Clean-host launch reported success without starting either role (redirect ran pre-`sudo`, backgrounded) | CLOSED | `4cd339e` |
| F3 | Expiring runner token blocked the whole transaction | CLOSED | `4cd339e` (named non-blocking list) |
| F4 | The live gate never received the NetBox credential | CLOSED | `4cd339e` |
| F5 | GitHub routing selected the right runner but targeted **global** NetBox state | CLOSED | `5c26cd7`, `fd48491` |
| F6 | Post-observability degradation could still produce head `rc=0` | CLOSED | `4cd339e` |
| F7 | Upgraded sims republished the **same** shared credential under per-sim names | CLOSED | `057faf6` (rotate **and revoke**) |
| F8 | Runner absent from every deploy script; stage-90 health accepted relay OR bot OR runner, so its absence read healthy | CLOSED | `a1d8a40` |

## G. Consistency pass — 6

| # | Issue | Status | Commit |
|---|---|---|---|
| G1 | Runner optional in deploy, mandatory in health — moved the failure to the gate | CLOSED | `1a092e6` |
| G2 | Replacement fabric hosts never got `netbox.env` (persistence lived in the retry branch) | CLOSED | `1a092e6` |
| G3 | Legacy credential re-adopted from the per-sim secret (hash check applied to only one candidate) | CLOSED | `1a092e6` |
| G4 | `netbox-runner.env` created `root:root` — nested `sudo` makes `SUDO_USER` = root | CLOSED | `1a092e6` |
| G5 | `SIM_IDS` unprovisioned; the fallback made an unconfigured fleet look covered | CLOSED | `fd48491` |
| G6 | The firewall boundary excluded the **primary** ops/fabric pair | CLOSED | `1a092e6` |

---

## H. Found by RUNNING — 8, and none of them exists in the source

This section is the point of the document. Sections A–G are ~46 findings from
ten rounds of reading, and a large share of them were regressions in the previous
round's fixes. Section H came from **one cold end-to-end run**, and not one of
these could have been found by inspection: they are timing, process semantics,
IAM and interface mismatches.

| # | Issue | Status | Commit |
|---|---|---|---|
| H1 | Seed raced the GCE startup script's dpkg lock — died in 7s; the same command by hand a minute later succeeded | CLOSED | `7ec611f` |
| H2 | Launcher **hung on its own SSH channel** after starting head; fabric never launched. Head was deploying with 4 containers while up.sh waited | CLOSED | `7396415` |
| H3 | Launcher swallowed its own progress — `say()` piped into `grep -qx launched`. Four minutes of empty log on a working run | CLOSED | `7396415` |
| H4 | Teardown's verification **never ran when the teardown had worked**: `ls <glob>` exits 2 on no match, aborting under `pipefail`. Its EXIT trap then recreated `/opt/gpufab` root-owned, breaking the **next** build's stage 10 | CLOSED | `417a198`, `22684be` |
| H5 | Token read-back raced `latest` — killed a cold build on a publish that had succeeded | CLOSED | `78471d7` |
| H6 | Read-back passed a full resource path where a bare version number was wanted — killed a second and third build; **never once caught a real fault** | CLOSED | `12a81f1`, downgraded to a warning in `5959db4` |
| H7 | Per-sim secret created at runtime inherits **no IAM binding** — the fabric could not read it. Presented as *timing* ("waiting for the head to publish") while the credential existed and the failure was **authorisation** | CLOSED | `7970572` |
| H8 | `up.sh` passes `--zone`; `verify.sh` had no such flag. The first successful build was gated by **nothing** | CLOSED | `277b2d3` |

### What section H cost, and what it bought

H5 and H6 together killed **three consecutive cold builds** and never caught a
real fault — a check I wrote in a review round, shipped unexecuted, and which
produced only false failures. H4 explains a symptom I had misdiagnosed by
reading. H7 would have burned a 30-minute deadline reporting a missing
credential that was sitting right there.

The run that surfaced them also produced the first complete unattended build in
the project's history: **29m38s, bare VMs to a converged 512-GPU fabric,
1464/1464 BGP peer series**.

---

## I. Closed since — the three-workstream round

Run concurrently on separate branches **and separate sims**, then merged.

| # | GH | Issue | Commit |
|---|---|---|---|
| O2 | #56 | `s5-32768` needed **70 ports on a 64-port switch**. Fixed as a pure profile edit: `cores.backend` 105 → **192**, frontend/storage 3 → 4. The allocator hands spine uplinks round-robin *restarting at core 0 in each pod*, so the core count must **divide** the 192 slots — every value except exactly 192 leaves zero-link switches | net `3269847`, plat `0843625` |
| O4 | #58 | `skipped(in-sync)` always 0 — cause was the SNMP table rewrite, not the auth tables | see O11 |
| O5 | #59 | Fabric idled ~657s waiting for the seed; now boots NOS from the profile and reconciles after | `ae3bc4e` |
| O11 | #65 | SNMP **configured** with a derived per-switch community persisted to NetBox, not suppressed | plat `d45a294`, net `243b1d0` |
| O12 | #66 | Results misreported `git_sha` on tar+scp'd trees — now `code_sha` + `code_source` | `ae3bc4e` |
| O13 | #67 | `degrade_count` returned empty instead of an integer | `ae3bc4e` |
| O14–O18 | #68–#72 | Five defects **in the tests themselves**, found by running them | `0843625` and predecessors |

### What this round cost, and what it bought

O5 measured **29m38s → 25m23s (−14.3%)**, and `48-reconcile` passed against
NetBox for the first time. O11 made `skipped(in-sync)` deterministic at
**46/46/46**. `t06-static` passes **11/0** and `t17` runs to completion
(**16/0**) — both for the first time in the project's history.

Two lessons worth keeping:

**O2's obvious fix is a trap.** "The switch needs more ports, so add more cores"
passes `t06` at several core counts while leaving **8 zero-link switches** —
built, ZTP'd, addressed and polled, carrying nothing. Only 192 divides evenly.
And nothing anywhere asserted the port budget: `expected.py --key
max_ports_per_switch` printed **70** against a 64-port platform and exited 0 for
the life of the project.

**O11 vindicated distrusting the mechanism, not just the bug.** The proposal on
the table was to drop SNMP from `DROP_TABLES` — which in-code comments had
already rejected, because it leaves a world-readable `public` community. The
right fix was to configure SNMP correctly rather than suppress it.

---

## Still open — 7

| Issue | GH | Why it is open |
|---|---|---|
| O1 sharding | #55 | placement logic exists (`_shard` → `fabric_model.place`); end-to-end provisioning ownership does not |
| O3 routed management | #57 | unbuilt: needs a DHCP relay, and stage 45 would block the flows |
| O6 ops golden image | #60 | **in flight**. The last remaining time lever — fabric-side work is squeezed to ~zero, and the residual 487s is NetBox startup (278s) + seed (409s). An image removes the apt install and container pull, **not** the migrations |
| O7 t09 topoview | #61 | 1500-vs-6000 budget contract unreconciled across code, test and design |
| O8 bucket IAM | #62 | prefixes are attribution, not isolation (§5.8) |
| O9 per-user identity | #63 | identical SSH keys and one service account everywhere; §5.8's requirement has no implementation |
| O10 gate a build | #64 | the successful cold build was gated by nothing; `verify.sh --zone` now exists but no build has run through it |
