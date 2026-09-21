# E-LIFECYCLE-01 — substrate isolation DEMONSTRATED; ownership-safe teardown NOT YET

> **STATUS 2026-09-20, split deliberately, because one half is proven and the
> other is not:**
>
> - **Substrate isolation and per-unit rebuild: DEMONSTRATED.** pod002 was
>   destroyed and rebuilt while pod001 and core remained byte-identical, and the
>   fabric returned to 3728/3728 with `admit-s2` ADMIT. That is a real functional
>   property of separate-labs-per-unit and it holds.
> - **Ownership-safe unattended teardown: NOT YET DEMONSTRATED.** The cycle ran
>   unattended, but the implementation that made it unattended departed from the
>   authorized contract, so what it demonstrated is that the *mechanism* works —
>   not that it is *safe*. See §7a.
>
> The distinction matters: an unattended teardown that can delete a stranger's
> container, or treat an unreadable Docker as an absent one, is not a lifecycle
> anything should be built on.

**Date:** 2026-09-17
**Fabric:** S2 on `gpufab-s11-fabric`, unit `dc1-pod002` only. S1 not touched.
**Scripts:** `tests/experiments/e-lifecycle-01.sh` (+ `-probe.sh`), `bcbf8ca`

---

## 1. The decision

`BRINGUP-ARCHITECTURE.md §9.3` calls a proven containerlab unit lifecycle **the
hardest gap, unsolved today**, and gates everything behind it: *"No build until
one is demonstrated."* Three substrates were offered; this tested the first,
separate-labs-per-unit.

**Verdict, split: the SUBSTRATE is DEMONSTRATED, 2026-09-20; the ownership-safe
teardown is not** (§7a). Three distinct defects were fixed to get the cycle to
run at all — the deletion transition (§5), a log-arity bug in that fix, and the
serving layer's missing destroy (§4) — and the third of those was then rejected
on review for how it did it. The clean cycle:

    stopped ZTP server c12-ztp-dc1-pod002
    releasing c12-dc1-pod002 only: 10 resource(s) adopted, 404 left owned
    lab:c12-dc1-pod002 resuming a deletion: owned partial deletion:
        6 of 124 member(s) remain and all are ours, with DELETING already recorded
    release rc=0        deploy rc=0        RUN COMPLETE rc=0

| unit | devices | gone at mid | containers same | configs same | sessions |
|---|---|---|---|---|---|
| **dc1-pod002** (rebuilt) | 48 | **48** | **0** | 40 | 1664 → 1664 |
| dc1-pod001 (untouched) | 48 | 0 | **48** | **48** | 1664 → 1664 |
| core (untouched) | 10 | 0 | **10** | **10** | 400 → 400 |

Container identity proves both halves with one measurement: the rebuilt unit
kept **none** of its container ids, the untouched units kept **all** of theirs —
at mid-teardown *and* after. Fabric back to **3728/3728**, 0 unreadable,
**`admit-s2: ADMIT`** with **`S1 ADMISSION: ADMIT`**.

**No hand touched it** — every previous attempt needed a `docker rm` of the
unit's ZTP server. That establishes the functional property. It does **not**
establish an ownership-safe teardown; see §7a.

## 2. Two distinct blockers

**(a) `--deploy-unit` alone cannot rebuild a unit that is already up.** It
*acquires* the unit's resources; on a live unit they are `PRESENT and already
ledgered`, so the engine VOIDs. Correctly — re-acquiring what you already own is
not a rebuild. That flag adds a unit *alongside* others. My first invocation was
simply wrong, and nothing was destroyed by it.

**(b) `--release-unit` cannot complete a teardown.** This is the real finding.
The lab's recorded identity is its **container-ID set**. `containerlab destroy`
removes containers as it runs, so by the time the engine re-checks identity the
set has shrunk:

    FAIL lab:c12-dc1-pod002 is not the object we created —
         identity was '<124 container ids>' and is now '<3 ids>'.
         Something replaced it during the run; refusing to delete someone else's resource

**The teardown invalidates the identity that authorises the teardown.** It
refused *mid-delete*, leaving `dc1-pod002` at 0 containers, the fabric at
**1864/3728**, and the ledger holding entries for a unit that no longer existed.

## 3. What DID hold

**Scoping.** The release adopted **4 exclusive resources and left 404 owned by
other units**. `pod001` (124 containers, `a44b9ba36e459985`) and `core` (10,
`d7c90f007a5044d0`) were byte-identical at every checkpoint — before, mid,
after — verified independently of the gate's own fingerprint. The blast radius
was exactly the unit named, which is the property the architecture most needs.

`_exclusive_to()`'s docstring records why: every bridge is shared between a pod
and the core, none is exclusive, so a partial teardown leaves cross-unit links
standing. That held.

## 4. Recovery, and a second confirmation of a known gap

Recovery could not proceed until `c12-ztp-dc1-pod002` was removed by hand. The
ZTP servers are plain docker containers **outside the ownership ledger**, and
they hold the `c12-oob-*` networks open, so the network delete fails with
`network:c12-oob-dc1-pod002 is PRESENT after cleanup`. This is the same gap
recorded on 2026-09-12 as breaking `--recover`; it is now also shown to **block
recovery from a failed teardown**, which makes it more than a nuisance.

Once that one container was removed, the drain completed (`c12 VERDICT: OK`) and
the redeploy succeeded.

**Restored and re-admitted:** ZTP 48/48 on the rebuilt unit, post-provision gate
PASS scoped to `dc1-pod002`, t92 15/15 with tenant dataplane, fabric
**3728/3728** and **32/32 EVPN**, 0 unreadable, **`admit-s2: ADMIT`** with
**`S1 ADMISSION: ADMIT`**.

## 5. What the fix must be

**"Capture identity once" is not sufficient** — it still misses a replacement
race. The deletion protocol needs an explicit durable transition:

    CONFIRMED  ->  DELETING  ->  ABSENT

- **authorize immediately before deletion**, against the original identity;
- **judge the postcondition as ABSENCE**, not identity equality — the mistake
  above is judging a half-deleted object by whether it still looks like itself;
- **recovery may treat a strict SUBSET** of the original container IDs as an
  owned partial deletion, and must **refuse any new or foreign ID**;
- **hold the host lock across authorization AND mutation**, so nothing can
  replace the object in between.

**IMPLEMENTED AND FAULT-TESTED 2026-09-17** — `tools/ownership.py` (`eddc5b4`),
`tests/t101-delete-transition.sh` (`3dc21d6`), 42 assertions host-free.

All four requirements are in the engine: authorization immediately before the
mutation against the original identity; `DELETING` recorded durably *before*
`res.delete()` (that ordering is what makes a crash mid-call recoverable, and is
its own RED control); the postcondition judged as **absence**; the strict-subset
rule for owned partial deletion, gated on DELETING having been recorded, with any
foreign member refusing outright. The host lock is now *enforced* across
authorization and mutation — `release_all` refuses without it — rather than left
to convention. Set-valued identities are declared (`SET_IDENTITY_KINDS`), not
inferred from punctuation.

Five RED controls fire: equality-only (7 assertions fail), DELETING not replayed
(5), foreign member allowed (5), lock not required (3), DELETING marked after the
delete (3). The last needed a fake that dies *inside* `delete()` — with a fake
that merely returned early the marker was written either way, so the ordering
looked untested when it was in fact unprobed.

### Re-run with the engine deployed — 2026-09-20

**The transition works on a real fabric. The lab deletion no longer refuses.**
Where the 17 September run died on `identity was '<124 ids>' and is now
'<3 ids>'`, the engine now logs `resuming a deletion: identity unchanged` and
deletes the lab cleanly. That failure mode is gone.

Three runs, three *different* failures, each further along:

| run | failed at | cause |
|---|---|---|
| 17 Sep, no engine | lab delete | the teardown invalidated its own authority — **fixed** |
| 20 Sep #1, engine deployed | `cleanup raised TypeError` | **my** one-argument `self.log` call in the fix |
| 20 Sep #2, arity fixed | `network ... PRESENT after cleanup` | the ZTP server, outside the ledger, holds it |

**The arity bug is the one worth dwelling on.** The transition's new "resuming a
deletion" line called `self.log` with one argument where it takes
`(level, message)`. So the fix's own logging broke the release it had just made
possible. **t101 could not see it**: the fake was `lambda *_: None`, which
accepts any arity — more permissive than the real logger, and therefore unable
to catch a contract violation. The host-free suite was green and the deployed
engine passed t101 42/42 *on the host* before this appeared. Only a real
release found it. Fixed in `2a28426`, with a strict fake at the production
signature, an assertion that every logged call had two parts, an assertion that
the resume line actually ran, and a RED control.

**Substrate-1 is still NOT DEMONSTRATED — but the blocker has moved off the
engine.** What now fails is `network:c12-oob-dc1-pod002 is PRESENT after
cleanup`, because `c12-ztp-dc1-pod002` holds it and has no ledger entry (§4).
That gap has now blocked three separate operations: `--recover` (12 Sep),
recovery from a failed teardown (17 Sep), and the teardown itself (20 Sep).

**The next fix is bounded and specific:** make the unit's ZTP server a ledger
resource, or have the unit release tear it down as part of the unit. Nothing
else stands between this substrate and a demonstration.

**State after, restored and re-admitted twice:** pod002 rebuilt, ZTP 48/48, gate
PASS scoped to `dc1-pod002`, both untouched units verified unchanged by the
gate's fingerprint *and* by an independent container-identity guard, fabric
**3728/3728** and **32/32 EVPN** with 0 unreadable, **`admit-s2: ADMIT`** with
**`S1 ADMISSION: ADMIT`**. The S2 pin was re-taken at `2a28426` because the
engine the fabric runs changed — only `platform/tools` moved.

## 7a. Why the teardown is not yet ownership-safe

The stop that made the cycle unattended has three defects, each one a shape this
codebase has already paid for, reproduced inside the fix meant to close an
ownership gap:

1. **It deletes by deterministic NAME with no durable identity**
   (`ztp_stop_units.sh:42`). `docker rm -f "$name"` removes whatever currently
   answers to that name. A foreign container that happens to share it would be
   destroyed. This is precisely what `Resource.identity()` exists to prevent —
   *a name is not an identity* — and the ownership engine has refused exactly
   this kind of deletion since it was written.
2. **It launders UNREADABLE into ABSENT** (`ztp_stop_units.sh:50`). The presence
   read is `docker ps -aq ... 2>/dev/null`; if Docker fails, the output is empty
   and the script concludes the container is gone and reports success. That is
   binding rule 2 (a check that observed nothing is a FAILURE) and rule 7 (never
   swallow the evidence), both broken in one line.
3. **It runs OUTSIDE the canonical lock** (`c12-unit-labs.sh:278`). The stop is
   invoked before `unit_executor.py`, which is where `HostLock` is taken — so
   serve, stop and release are concurrently mutable against each other. The same
   change that added lock enforcement to `release_all` left this outside it.

And the comment claiming **"symmetric ownership at the creating layer"** was an
assertion, not a fact: that layer recorded neither authorship nor Docker ID, so
it owned nothing in any sense the engine would recognise.

**The corrected path** is §7b.

## 7b. The corrected path (host-free, 2026-09-20)

All three defects came from writing the fix in shell beside the thing it was
fixing, instead of calling `tools/ownership.py`, which already implements every
one of them correctly. So the serving layer now gets the SAME machinery rather
than a second copy of the idea.

**An adversarial cross-check of the first correction returned "No" and found
four more**, three of which were the same defects one file over:

| # | what | where |
|---|---|---|
| 1 | `docker rm -f "$ZTP_NAME" 2>/dev/null \|\| true` — blockers 1 and 2 verbatim, in the **create** path of the same feature whose teardown refuses exactly that | `ztp/oob/serve.sh` |
| 2 | claim, create and confirm were three separate processes, so the lock was released between them and the `docker run` ran under **none** of it — an interleaved teardown left a container no future teardown would ever be permitted to remove | `ztp_serve_units.sh` |
| 3 | a server that started and then failed its self-test was claimed, never confirmed, and refused by every later teardown — and since a failed stop aborts c12 *before* the executor, `--recover` could not run **at all**. A deadlock, and a regression against the rejected version | `ztp_ownership.py` + c12 |
| 4 | the **network** read accepted the bare substring `"not found"`, which also matches `docker: command not found` — so it could print "nothing attached" about a network it never read. Untested, and untestable by the harness as written | `ztp_ownership.py` |

**A second round found four more, one of which broke the feature outright.**
Fixing round 1's "`docker inspect` also resolves images" by switching to
`docker container inspect` changed the error text from `No such object` to
`No such container` — and the matcher still looked for the old phrase. On a
real host *every* absent container then read UNREADABLE, so every stop failed
and every serve on a clean host refused at step one: both of the outages this
feature exists to fix, caused by hardening one line and not the line that read
its output. The suite was 93/0 because the fake emitted the other phrasing, and
`"no such object"` lived in the matcher, the docstring and the fake — three
copies of one assumption with no independent source.

The remedy is not the right phrase. It is not to parse phrases at all:
`docker ps -aq --no-trunc --filter name=^X$`, where **the daemon answering**
decides — `rc != 0` UNREADABLE, `rc == 0` with no rows ABSENT, one row PRESENT,
several rows UNREADABLE. `docker ps` lists only containers, so the image
fallback is gone by construction, and there is no `--format` template left to
get wrong. `observe_network` works the same way, which retires the mirror-image
bug the round-1 fix had just introduced (`"no such network"` does not match the
modern `network X not found`).

Round 2 also reversed a judgement call of mine that was **strictly worse than
the original blocker**: confirming a container when the create had *failed*.
The argument had been "step 1 measured absence under this lock, so anything
here is ours" — the opposite threat model to the one I had used three functions
away to justify deleting by id, in the same commit. A stranger taking the name
makes our `docker run` fail with a 125 conflict; confirming there records the
*stranger's* id as ours, and the next teardown deletes it precisely, by id,
reporting success. Durable, replayed, unrecoverable.

Plus: the delete still addressed the **name** after authorizing the **id**;
`docker inspect` resolves images too; two derivations of how to call docker
(`sudo docker` creating, bare `docker` owning — off the docker group the create
succeeds and the confirm cannot see it); and **four assertions that stayed green
while the property they named was false**.

The last of those is the one to carry: a test suite can reproduce the defect
class it was written to catch. `grep -q 'confirm'` on a shell file, a
`--recover` guard matched over a window containing three prose mentions of the
word, and a DELETING-ordering check read from the ledger *after* the run — when
the ordering is the entire reason the marker exists.

`tools/ztp_ownership.py` — `Ledger`, `authorize_delete`, `HostLock`, used, not
reimplemented:

| requirement | how |
|---|---|
| record the Docker ID durably **at creation** | a single `serve` verb holds **one** `HostLock` across remove-if-ours → claim → create → confirm. Not three calls: as three processes the lock was released between them and the create ran under none of it |
| bind the stop to the **canonical** lock | serve and stop both take `--lock "$LOCK"` — the path `unit_executor.py` is given, not a lock of their own |
| refuse **unreadable** | docker is a tristate `PRESENT(id)` / `ABSENT` / `UNREADABLE`; UNREADABLE is never a state, only a refusal — including `OSError`, and including the network read, where only `"no such network"` counts as absence |
| refuse **changed** identity | `authorize_delete(KIND, recorded, current, deleting)`; `container` is not in `SET_IDENTITY_KINDS`, so it is equality or refuse. `docker container inspect`, not `docker inspect`, which also resolves images |
| delete what was **authorized** | `docker rm -f <id>`, never `<name>`. Authorizing `val` and removing `name` leaves the replacement window the authorization exists to close, and the lock does not cover it — it orders gpufab runs, not a restart policy or an operator |
| retire only after **measured absence** | `mark_deleting` → `rm` → re-read → retire ONLY on a measured `ABSENT`. An unreadable post-read FAILS without retiring, leaving DELETING for a retry to resume from |
| never strand a container, never forge one | the **creator reports the id it made** (`GPUFAB_SERVE_IDFILE`). That is the only thing that separates "our container started and then failed its self-test" — which must come out OWNED, or the unit deadlocks — from "our create lost a name race", which must own nothing, or the recovery path deletes the stranger. An exit code cannot tell them apart; the id can |
| bound a hung create | the create is inside the held interval, so its hang is everyone's: `GPUFAB_SERVE_TIMEOUT` (900s default, a nonsense value REFUSES), and the child's whole **process group** is killed, since killing only the direct child leaves grandchildren mutating the host after the lock is released |
| do not outlive a killed owner | `PR_SET_PDEATHSIG`. The kernel releases a flock when the process dies, and the orphaned child kept creating — the concurrency hazard this verb exists to close, through a narrower door, and reachable because long operations here outlive their SSH session |
| one derivation of privilege | `ZTP_SUDO`, the same variable and default `serve.sh` reads, with the resolved value exported to the child so it inherits the decision rather than repeating it |

`deploy/ztp_stop_units.sh` now contains **no `docker` call at all** — it maps
units to names and delegates. That is asserted, not intended: t102 fails if a
`docker` invocation or a `2>/dev/null` reappears in it.

The serving ledger is separate from the executor's — the executor cannot create
these containers, so its have-check must not find them — but derived in ONE
place, `serving_ledger()`, from the executor's own path. Separate ledger, same
lock: the ledger split is about what each layer can create; the shared lock is
about what must not interleave.

### Controls (`tests/t102-ztp-stop-units.sh`, 128 assertions, host-free)

| control | required behaviour |
|---|---|
| **foreign same-name container** | recorded `sha256aaa`, present `sha256FOREIGN` → REFUSE, container survives, ownership not retired |
| **failed Docker read BEFORE** | daemon down → FAIL; must not say "already absent"; nothing removed while blind |
| **failed Docker read AFTER** | removal ran, absence unmeasurable → FAIL, **not** retired, DELETING left recorded |
| **wrong-lock concurrency** | another holder on the canonical lock → VOID(2) having mutated nothing, then succeeds once the lock is measurably free |
| **replacement between authorize and delete** | recorded and inspected `sha256aaa`, swapped to `sha256INTRUDER` before the `rm` → the intruder survives, because the delete addressed the authorized id |
| **unreadable NETWORK read** | a failure that is not absence → FAIL, and no "nothing attached" line |
| **DELETING before the mutation** | recorded by the fake docker *at the instant of the rm*, because the ledger afterwards looks identical either ordering |
| **create over a stranger** | a container we cannot prove is ours → the create REFUSES rather than clearing the way |
| **create that fails after starting** | still comes out OWNED, and the next teardown removes it with no hand operation |
| unowned container present | no ledger record → REFUSE, even with `--adopt-unconfirmed` |
| **docker unreadable AFTER the create** | the creator's reported id is recorded anyway, so a later teardown can still tell ours from a stranger; with no reported id the claim is retired instead, leaving nothing for the adopt path |
| **a create that lost a name race** | records nothing AND retires its claim, so even `--adopt-unconfirmed` leaves the stranger alone |
| **a hung create** | bounded by `GPUFAB_SERVE_TIMEOUT`, whole process group killed, lock free afterwards |
| **a SIGKILLed owner** | takes its create child with it, rather than leaving it mutating docker unlocked |
| an image sharing the name | cannot arise: `docker ps` lists only containers |
| removal that did not take | `rm` returns 0, container remains → FAIL, not retired |

The lock control holds the lock from a separate process and **observes** both
that it is held before the refusal and that it is free before the success —
because `flock <file> <cmd> &` leaves the lock with the command's process, not
the pid `$!` names, so the first version of the control killed the wrong process
and was measuring a stale lock rather than the code.

### The test-the-test (`tests/t102-red.sh`, 28 mutations)

Each mutation reintroduces one defect to a **copy** of the tree and require t102
to go red **on the named assertion** — after asserting the mutation actually
changed the file, because two earlier RED controls in this project reported
"15 passed" while their mutation silently never applied, which is a false
reassurance pointing the wrong way.

It paid for itself repeatedly: **four of the first six expectations written for
it were wrong**, and three more went stale as the code moved and were caught by
the mutation-landed guard rather than passing vacuously. One exposed that the "not claimed" refusal was unreachable in
practice (the unconfirmed check refused first), so a control was added for the
`--adopt-unconfirmed` case where it is genuinely load-bearing. Another showed
that the unreadable-read case's return-code assertion was not the discriminator
it looked like — the network read fails in the same scenario and masks it — so
the control targets the message assertion that actually distinguishes.

Both are registered in `tests/verify.sh` (`ztp-stop`, `ztp-stop-red`). A control
nobody runs is a control that rots — and `t102-red` is the more expensive of
the two by far, since it runs the whole of t102 once per mutation. It snapshots
only `tools/`, `deploy/` and `ztp/` rather than the 136 MB platform tree, and
asserts that t102 reads nothing outside that set, so the snapshot cannot
silently go stale; the remaining cost is the mutation count itself.

Three guards make a red result mean something:

1. **the mutation must land** — an unmatched anchor is a FAILURE, because two
   earlier RED controls in this project reported "15 passed" while their
   mutation silently never applied;
2. **the mutated tree must still parse** — a mutation that merely breaks syntax
   fails everything, and a third of the cases would then report PASS on it;
3. **t102 must go red on the NAMED assertion**, not merely go red.

Guard 1 earned its place again this round: the `observe` redesign invalidated
four mutation anchors at once, and all four reported "measured nothing" instead
of quietly passing.

### One judgement call, stated as such

**c12 passes `--adopt-unconfirmed`, and the stop's only call site is that one**,
so in practice the strict default never applies inside c12. The trade: a claim
is a durable record, written under the same lock as the create, that this
ledger was about to make that exact name — narrower than the name-only delete
it replaces, which needed no record at all. A container with **no** claim is
still refused, flag or not, and that is asserted.

What makes the trade safe is the id file. A create that *lost a name race*
retires its own claim, so there is nothing for the recovery path to adopt; only
a create that demonstrably made a container leaves a claim behind. Without that
step the adopt path deleted the stranger one call later, which is how the
previous round's "unowned is recoverable" argument failed.

The other judgement call from the previous round — confirming a container whose
create had failed — was **wrong and has been reversed**. It is recorded above
rather than quietly dropped, because the way it was wrong is the lesson: it
applied one threat model to the delete and the opposite one to the create,
within a single commit.

### What this is NOT

**It has no real-host evidence.** Every assertion above is host-free, against a
faked docker. The live fabrics still run the rejected code, and `admit-s2`'s
behavioural pin was **deliberately not moved**: the pin describes what the
fabric RUNS, so advancing it for code no fabric runs would be a false statement
of exactly the kind this section is about.

**No further destructive cycle will be run for this.** Both fabrics stay
admitted; the corrected path takes its real-host evidence from the next
genuinely needed lifecycle operation, not from one staged to produce it.

## 6. Also found

**`--deploy-unit` re-serves ZTP for ALL units**, not just the rebuilt one: c12
passes the full unit list to `ztp_serve_units.sh` regardless of rebuild scope. It
stages before swapping and provisioned switches do not re-run ZTP, so it caused
no harm — but the serving step sits **outside** the ownership scoping that
protects everything else, the same class of gap as the ZTP servers themselves.

**A literal SoT address, written by me.** The probe hardcoded
`NETBOX_URL=http://10.10.0.58:8000`. `tests/t52` scans untracked files and caught
it **through S1's admission gate** — S1 refused, and the cause was a file on the
workstation, not anything wrong with S1. That is #129's exact defect class,
written into the repo by the person who had just been citing #129. The check
earned its keep; the address is now derived from `/opt/gpufab/sot` or required
from the caller, never guessed.

## 7. Process note

During recovery I reported *"nothing was destroyed"* on the strength of the
engine's refusal message, without checking state. The refusal had fired **after**
containerlab tore the lab down. The correct reading required looking at container
counts and session totals, which showed the opposite. **A refusal message is not
a statement about the world**; only a measurement is.
