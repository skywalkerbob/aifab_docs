# Sim id: one derivation — IN PROGRESS

Status: **COMPLETE.** Every consumer resolves through `tools/sim_id.sh`; no sim
id anywhere falls back to a hostname, and none is laundered into a usable value.
Last updated: 2026-11-05

---

## What this is

The **sim id** is the namespace key a sim's per-sim resources are named for:

| consumer | resource | state |
|---|---|---|
| Secret Manager | `gpufab-netbox-token-<sim>`, `gpufab-oob-*-<sim>`, `gpufab-snmp-secret-<sim>` | **DONE** |
| GitHub Actions | the self-hosted runner's name and its `sim-<id>` label | **DONE** |
| artifact bucket / GitOps repo | `instances/<sim>/` | **DONE** |
| `result.json` | its `sim_id` field | **DONE** (UNRESOLVED, never "unknown") |
| log shipping | the log prefix | arguably a host identity, not this |

It is **not a host name**, and that confusion is the whole defect.

## What it cost before being fixed

Ten live derivations in three regex variants. Two orphaned credential containers
are live in Secret Manager whose names match no derivation in the tree
(`gpufab-netbox-token-gpufab-s11-fabric`, and `...-gpufab-a4-01` plus four
suffixed variants). `terraform/secrets.tf` predicted it exactly: *"the head
would create its own unbound container beside it and the fabric would wait out
the same 30 minutes, with terraform reporting success."*

The root cause, which `tools/sot.py` had already diagnosed for itself:
`/opt/gpufab/instance-id` holds a **host** identity. `tools/up.sh` writes
`${OPS%-ops}`, which strips nothing from a host named `gpufab-ops-01` — so on
the primary that file holds a host name and on an extra sim a sim name.
Deriving one from the other produced the nonexistent `gpufab-ops-01-ops`, and
the refusal blamed DNS.

## Landed (pushed, `origin/main` at `65effef`)

- **`gpufab-platform/tools/sim_id.sh`** — the one resolver. Order:
  `$GPUFAB_SIM_ID` → published `gpufab-sim-id` instance metadata →
  `/opt/gpufab/sim-id` → `/opt/gpufab/instance-id` (compatibility only) →
  **REFUSE**, naming every source tried. **No hostname branch, by
  construction.** Sourcing is side-effect-free (guarded on `BASH_SOURCE`).
  Also exports `gpufab_netbox_secret`, so the secret *name* has one producer.
- **`terraform`** — `variable "netbox_sim_id"` (default `gpufab-ops-01`, the
  value in use, so introducing it changed nothing live), with a validation
  block because `secret_id` is ForceNew and a typo destroys a live credential.
  Published to both host kinds as instance metadata.
- **Ten call sites converted**, including `services/setup_netbox.sh` — the side
  that **creates** the container, which had a third variant with no `sed` at
  all. Left alone, the rename would have had the head mint
  `gpufab-netbox-token-fab-…` while every fabric fetched the old name.
- **`tests/t123-sim-id.sh`** — 43 assertions: the resolution order, the refusal
  naming every source, malformed values refused rather than sanitised,
  side-effect-free sourcing, and the cross-check that terraform's declared
  default and the resolver name the *same* secret. Its two sweeps carry three
  **named** exemptions and assert those exemptions are still present, so the
  sweep cannot quietly become a scan of an empty set.
- **Both VMs renamed**: `gpufab-fabric-01` → `fab-fabric-01`,
  `gpufab-ops-01` → `fab-ops-01`. Stop → `set-name` → `state rm` + `import`,
  never `terraform apply` (an instance name is ForceNew; applying would
  destroy and recreate the host). Verified same instance ids, and the ops
  token digest `5239d9c2bbf7` identical before and after.

**What that bought, measured by plan rather than asserted:** renaming the ops
host went from `4 to add, 2 to change, 4 to destroy` — instance, secret
container and its IAM binding, with the token value unrecoverable because
terraform never holds it — to `1 to add, 3 to change, 1 to destroy`.

## In flight

### The runner label

| site | derivation |
|---|---|
| `bot/setup_runner.sh:56` | `cat /opt/gpufab/instance-id \|\| hostname -s` |
| `bot/setup_automation.sh:85` | `cat /opt/gpufab/instance-id \|\| hostname` |
| `bot/webhook_relay.py:37` | `$GPUFAB_SIM_ID or _read(instance-id) or "default"` |

### The artifact-bucket / GitOps namespace

| site | derivation |
|---|---|
| `gpufab-network/.github/workflows/render.yml:53` | `cat instance-id \|\| echo unknown` (inside a loud guard — see traps) |
| `render.yml:82,95` | `instances/$(cat instance-id \|\| echo default)` |
| `gpufab-network/tools/render.py` | its own read |

### The intended design

The render runner is **self-hosted and runs ON the sim host**
(`runs-on: [self-hosted, sim-<id>]`), so `tools/sim_id.sh` and the metadata
server are both reachable — this is not a GitHub-hosted runner, and an earlier
reading of mine that assumed otherwise was wrong.

- Shell sites call `tools/sim_id.sh` and propagate its refusal.
- `webhook_relay.py` **shells out** to the same resolver rather than
  reimplementing the order in Python. Two implementations of one order is two
  derivations.
- `render.yml` resolves **once** via the resolver and passes the id explicitly
  to `render.py`, so `gpufab-network` acquires no path dependency into
  `gpufab-platform`.

## Traps a fresh reader will hit

1. **`setup_runner.sh` has never successfully registered a runner in
   production.** `GITOPS-CLOSURE.md` row 4: the live runner is `gpufab-sim-01`,
   `status: offline`, labels `[self-hosted, Linux, X64, sim-host]` — **no
   `sim-<id>` label**, version 2.336.0 against the script's 2.319.1, workdir
   `/opt/actions-runner/_work` against `/opt/gpufab/actions-runner`, and *named
   by the `hostname -s` fallback*. So changing this derivation **orphans
   nothing** — but it also means the change cannot be validated by observing a
   working runner, because there isn't one.
2. **Stage 90 degrades rather than fails** (`deploy/deploy.sh:234`,
   `90-automation.sh:15`), so a build that never registered a runner reports
   healthy. Do not read a green deploy as evidence the runner works.
3. **`instances/<sim>/` is a DATA LAYOUT**, not just a name. Changing the sim id
   moves the folder in the GitOps repo and leaves previously rendered configs at
   the old prefix. The ids are not changing here — only where they are read
   from — but a future change to the *value* is a migration.
4. **`render.yml:53` is already a loud cross-check**, not a naive fallback: it
   compares `matrix.sim` against the runner's own `instance-id` and `::error::`s
   on mismatch. The `|| echo unknown` only bites when the file is absent, and
   then the comparison fails anyway. It is still worth converting, but it is the
   least dangerous of the set.
5. **The hosts were renamed on 2026-11-04**, so any hostname-derived value is
   now different from what it was. `fab-ops-01` does not end in `-ops`, so the
   `s/-ops$//` family of derivations strips nothing from it — they return the
   host name unchanged, which is *accidentally* correct for the primary and
   wrong for anything else.
6. **`/opt/gpufab/sim-id` was written by hand on `fab-ops-01`** before the
   rename, to make the id explicit while the hostname it used to be derived
   from changed underneath. `tools/up.sh` now writes it too, but a host
   provisioned before that still has only the ambiguous `instance-id`.


---

## Closed 2026-11-05

Seven remaining sites converted, plus `deploy/lib.sh`'s `result.json` field.
Pushed: `gpufab-platform` `d49ccf0`, `gpufab-network` `2d285bf`, gated on a
105-phase suite at 3573 PASS / 0 FAIL.

**THE SWEEP THAT SAID "ONE DERIVATION" WAS WRONG.** t123 keyed on SHAPES —
`hostname -s | sed` and `%-ops` — and three live derivations used neither:
`bot/setup_runner.sh` fell back to `hostname -s`, `bot/setup_automation.sh` to
bare `hostname` (not even `-s`, so on a host with a domain it answered
differently again), and `bot/webhook_relay.py` reimplemented the order in Python
ending `or "default"`. The sweeps now key on the **fallback**, which is what
every variant shares:

- no identity anywhere falls back to a hostname;
- no unresolvable sim id is laundered into a usable value.

Probes that report the host name AS A FACT are excluded — they are not standing
in for something they could not resolve — and `image-scrub.sh`'s
`|| echo absent` is exempt BY NAME, with its presence asserted so the sweep
cannot become a scan of an empty set.

### Two defects introduced and caught during the work

1. **A comment inside a `<<JSON` heredoc.** A heredoc body is literal, so the
   explanation was emitted INTO `result.json` and made it unparseable. `t31`
   reported it as *"no result-fabric.json was written at all"* in four cases —
   the file WAS written and could not be read. Confirmed self-inflicted by
   reverting `lib.sh` to HEAD (43/0 before, 4 failures after) rather than
   assumed. Now guarded as `t22` **F16**, keyed on the delimiter being JSON so a
   legitimate comment in a shell heredoc does not fire it.
2. **Two new assertions defeated by prose.** `GPUFAB_INSTANCE_ID` and
   `gpufab-platform` appear in `render.py`'s docstring and in its
   operator-facing refusal message, which legitimately names the command to
   run. Replaced with AST walks. That is the third time in this work that a
   grep was satisfied by the explanation beside the thing it checks.

### A stale hostname was costing a live assertion

The ops-side code references were deliberately reverted while the ops rename
was deferred, and not restored when it was done. `tests/verify.sh`'s `OPS_HOST`
default still said `gpufab-ops-01`, and `t49`'s live publish check reported

    SKIP  gpufab-ops-01 is unreachable — live publish check NOT attempted
          (this is not a pass)

and would have reported it forever: **a check that cannot reach its host does
not fail, it stops measuring.** Corrected, `t49` goes 17 passed / 0 failed /
**zero skipped**. The only reason it was visible is that whoever wrote that
`t_skip` appended "this is not a pass"; worded as a bare skip it would have read
as nothing to see.

### Still deliberately derived, and why

`deploy/95-logship.sh` and `monitoring/logship.sh` read the id for a LOG PREFIX,
and `tools/up.sh` keeps `${GPUFAB_SIM_ID:-${OPS%-ops}}` as the documented
workstation default — it cannot read the published `gpufab-sim-id` metadata
until terraform has applied it, which is a bootstrap ordering constraint and not
a preference. All three are named exemptions in `t123`, asserted present.
