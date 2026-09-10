# S2 baseline — operating constraints

Standing constraints for the S2 experiment baseline on `gpufab-s11-fabric`.
Recorded because each was learned by hitting it, and none is self-evident from
the code.

## 1. The SoT is LOCAL to the fabric host — this is not an HA qualification

NetBox for this baseline runs on `gpufab-s11-fabric` itself
(`http://10.10.0.58:8000`), the same topology the 2026-09-08 S2 acceptance
qualified.

**Losing that host loses the experiment's source of truth along with the
fabric.** There is no second copy: the SoT, the served ZTP artifacts and the
running fabric share one failure domain. That is acceptable for an experiment
baseline and is NOT a high-availability qualification; nothing here should be
cited as evidence about SoT durability or recovery.

`gpufab-s11-ops` is STOPPED, not deleted, with its 200 GB disk preserved and
`autoDelete=False`, so a decision to move the SoT off-host later remains
reversible.

## 2. `sot_reset` is S1-ONLY and must not run against s11

`gpufab-network/tools/sot_reset/_lib.sh` hard-codes the head's NetBox endpoint:

    # The head's NetBox endpoint. Hard-coded per the reset runbook. (FLAG: 10.10.0.20)

`10.10.0.20` is `gpufab-ops-01` — the FROZEN S1 SoT. Running any `sot_reset`
script while thinking about s11 would reset **S1**, not the S2 baseline. The
tool offers no target argument and no authentication of which fabric it is
pointed at.

**It must not be run against s11 until its target is explicit and
authenticated** — passed in and verified, not implied by a runbook. Until then,
clearing the S2 SoT is done by tearing down the NetBox stack on the S2 host and
re-seeding, which cannot reach S1.

## 3. A hard reset after a critical filesystem mutation requires an END-STATE
   read plus a durable sync — a successful `rm` is not enough

Measured: `/var/lib/gpufab/bootstrap-done` was removed, the removal was VERIFIED
by reading it back ("marker now: absent"), and the host was then hard-reset with
`gcloud compute instances reset`. On reboot the seed found the marker PRESENT
and exited early:

    + '[' -f /var/lib/gpufab/bootstrap-done ']'
    + exit 0

`reset` is a power cycle, not a shutdown: the unlink was still in page cache and
never reached disk. The read-back was honest and still insufficient, because it
was served from the same cache that had not been flushed.

**Required before any hard reset that depends on a filesystem mutation:**
`sync` (durably), THEN read the end state back, and treat "the command
succeeded" as the weakest of the three signals. Prefer a graceful reboot, which
flushes, over `reset`.

A corollary that also cost time: `containerlab` surviving a teardown made
`command -v containerlab` look like proof the seed had run. Presence of a tool
the teardown never removes is not evidence about a bootstrap.

## 4. The terraform host seed installs containerlab UNPINNED

`gpufab-s11-fabric`'s metadata `startup-script` installs containerlab from
`get.containerlab.dev` with no version, so a freshly seeded host gets whatever
is current — **0.79.0** at the time of writing. Both qualified fabrics run
**0.77.0**, and `deploy/checks/a4-host.sh` pins it deliberately:

    # containerlab pinned to the version the fabric hosts run. A different minor
    # version is a different lifecycle, and this arm exists to characterise THAT one.

The S2 baseline build failed on 0.79.0 (`lab:c12-dc1-pod002 not acquired`) and
was corrected by installing 0.77.0. **Any terraform-provisioned host must have
its containerlab version asserted against the qualified one before a build is
trusted**, because the seed will silently drift it forward.
