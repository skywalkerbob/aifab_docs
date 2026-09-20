# E-LIFECYCLE-01 — §9.3 substrate-1: DEMONSTRATED

> **STATUS: CLOSED 2026-09-20.** The per-unit release/deploy cycle completed
> with **no manual intervention**, and `admit-s2` returned **ADMIT** with
> **S1 ADMIT**. Separate-labs-per-unit is the unit-lifecycle substrate. The
> sections below are the record of how it got there — three failures, each a
> different defect, each fixed. Nothing here is pending.

**Date:** 2026-09-17
**Fabric:** S2 on `gpufab-s11-fabric`, unit `dc1-pod002` only. S1 not touched.
**Scripts:** `tests/experiments/e-lifecycle-01.sh` (+ `-probe.sh`), `bcbf8ca`

---

## 1. The decision

`BRINGUP-ARCHITECTURE.md §9.3` calls a proven containerlab unit lifecycle **the
hardest gap, unsolved today**, and gates everything behind it: *"No build until
one is demonstrated."* Three substrates were offered; this tested the first,
separate-labs-per-unit.

**Verdict: DEMONSTRATED, 2026-09-20**, after three distinct defects were fixed —
the deletion transition (§5), a log-arity bug in that fix, and the serving
layer's missing destroy (§4). The clean cycle:

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

**No hand touched it.** That is the whole criterion: every previous attempt
needed a `docker rm` of the unit's ZTP server.

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
