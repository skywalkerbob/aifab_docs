# Sim id: one derivation — IN PROGRESS

Status: **landed for the credential path; IN FLIGHT for the runner label and the
artifact-bucket namespace.**
Last updated: 2026-11-05

---

## What this is

The **sim id** is the namespace key a sim's per-sim resources are named for:

| consumer | resource | state |
|---|---|---|
| Secret Manager | `gpufab-netbox-token-<sim>`, `gpufab-oob-*-<sim>`, `gpufab-snmp-secret-<sim>` | **DONE** |
| GitHub Actions | the self-hosted runner's name and its `sim-<id>` label | **IN FLIGHT** |
| artifact bucket / GitOps repo | `instances/<sim>/` | **IN FLIGHT** |
| `result.json` | its `sim_id` field | not started |
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
