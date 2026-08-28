# Closing the GitOps loop — `seed.py` becomes a reconciler

**Design, 2026-07-28. Not implemented.** Issue [#98 / O44]; the rollout half it
hands off to is [#99 / O45]; the broken-workflow inventory it depends on is
[#91 / O37]. All three are in `gpufab-platform`.

Measurement points, because all three repos were moving while this was written:
`gpufab-network` at `18f5d4e` (`main`, = `origin/main`), `gpufab-platform` at
`e9d5f21` (branch `o5-merge`), `gpufab-docs` at `74c1326` (`main`). GitHub state
read 2026-07-28 ~20:00Z. NetBox is `netboxcommunity/netbox:v4.3-3.3.0`
(`gpufab-platform/deploy/image-scrub.sh:474`).

Every claim below cites a file, commit, issue or measurement. Where something is
inferred rather than measured, it says so and names the measurement that would
settle it. Sections 1 and 4.2 are the ones to read if you read nothing else:
section 1 corrects the agreed design against the record, and section 4.2 is the
part that will destroy something if it is built as stated.

---

## 1. Corrections to the agreed design

The design in #98 was settled before it was checked against the repository.
Seven of its claims are wrong or materially incomplete. None of them changes the
shape of the design; four of them change what has to be built first.

| # | Claim as agreed | What the record says |
|---|---|---|
| 1 | `seed.py` "is called only from deploy stages (`30-seed.sh`, `40-topology.sh`, `48-reconcile.sh`, and the two roles)" | It is called from **exactly one place**: `deploy/30-seed.sh:8` and `:10`. Every other hit is a comment or an error-message string — `40-topology.sh:13`, `48-reconcile.sh:73`, `roles/fabric.sh:495,515`, `tools/gpufab.py:507` (a runbook data structure, not an invocation). #91's own body already states this correctly, so #98 and #91 contradict each other and #91 is right. |
| 2 | "entirely `get_or_create` — it creates, never updates or removes" | Almost. There is **one** PATCH: `seed.py:441-456` bulk-updates `primary_ip4`, guarded by `not d.primary_ip4`. It can *set* a primary IP, never re-point one. The conclusion holds; the reason is "set-once", not "no update path". A second, sharper gap in the same family: `seed.py:134-136` creates interface templates **only when the device type was newly created** (`if c:`), so a device type whose templates are wrong is never corrected. |
| 3 | "`seed.py --reset` is 6002 sequential DELETEs, measured at ~34 minutes" | 6002 is exact and re-derivable — `expected.py --profile design/profiles/scale/s1-512.yaml` gives 1466 cables + 3024 IPs + 124 devices + 1388 prefixes = 6002. **~34 minutes is a derived estimate, not a measurement**, and `FEATURE-EXTENSIBILITY.md:965-968` already says so: "No committed measurement of the reset exists anywhere in either repo." Do not plan against it. |
| 4 | "The trigger already exists." | The *code* exists; the trigger does not. `gh api gpufab-network/actions/runners` returns **one** runner, `gpufab-sim-01`, `status: offline`, labels `[self-hosted, Linux, X64, sim-host]` — **no `sim-<id>` label**. `render.yml:38-40` has required `sim-<id>` for payload-routed dispatches since 07-27, so it currently matches no runner in the account. The live runner was not installed by `setup_runner.sh` either: version `2.336.0` vs the script's `2.319.1`, workdir `/opt/actions-runner/_work` vs `/opt/gpufab/actions-runner`, and its name is the `hostname -s` fallback rather than the instance-id the script would have used. Stage 90 is in `NONFATAL` (`deploy/deploy.sh:234`) and `90-automation.sh:15` degrades rather than fails, so a build that never registered a runner reports healthy. **`setup_runner.sh` has never successfully registered a runner in production.** |
| 5 | The per-sim routing "exists because a change originating in sim A was once picked up by sim B's runner" | No evidence it ever happened. Every source is conditional — `render.yml:14-16` and `setup_runner.sh:10-13` both say "**could** be picked up", and commit `59bcc13` says the same. Measured: one runner has ever been registered, and one sim id appears across all 20 render runs and all 9 PRs (`gpufab-sim-01-8842744075247408112`). There was never a sim B. The routing closes a **latent** defect, which is a better reason than a war story and should be stated as such. |
| 6 | `drift-check.yml` "passes two flags `drift.py` has never accepted, dies in 6s; 0/18 runs succeeded" | Flags: verified — `drift-check.yml:17` passes `--post-metrics --update-issue`; `drift.py:113-115` accepts only `--root`, `--device`, `--json`, and `git log -S` across all four commits that touched the file shows those two flags existed only in the 07-23 scaffold *docstring*, never as arguments. Counts: **0/20**, not 0/18 — 11 failure, 5 cancelled (all at 86401s, GitHub's 24h no-runner cancellation), 4 still queued. And the stated cause is wrong: the job dies at `drift.py:41` with `ModuleNotFoundError: No module named 'pynetbox'` (job log, run `30203677093`) because the workflow calls bare `python3` — argparse is never reached. Fixing only the flags leaves it failing identically. |
| 7 | `validate.yml` "passes having iterated zero files" | True of today's tree — `git ls-tree -r HEAD -- rendered/` returns exactly `rendered/README.md` — but false of the recorded runs. All 4 successes were on 2026-07-24 18:51–18:59Z, before `7c08d0e` moved renders to `instances/<sim-id>/rendered/`, and the head SHA of the last one held 30 `config_db.json` files. Since then its path filter (`rendered/**`, `templates/**`, `design/**`) has not matched a single render PR: `gh pr checks 9` reports "no checks reported on the branch". **It is not passing vacuously; it is not being invoked.** #91's "always been green, having validated nothing" is wrong on "always". |

Two further corrections to numbers quoted in #98's cost section:

- **Cold build is 24m11s, not 20m57s.** `24m11s` is the s11 measurement (#58,
  comment 2026-07-28T09:45:46Z), against 29m38s and 29m09s before it. `20m57s`
  appears nowhere in any of the three repos or in any issue; `gh search issues
  "20m57"` returns empty. If a faster run exists it is not in the record.
- **`1464/1464` is not an assertion total.** It is `bgp_peer_series`, the
  *expected* peer-series count from `expected.py`
  (`FEATURE-EXTENSIBILITY.md:989`). `46/46 in-sync` is now genuinely a **cold**
  result — it went `0/46 → 46/46` on the s11 cold build (#58, 09:45:46Z), which
  supersedes `FEATURE-EXTENSIBILITY.md:990`'s "measured warm three times, and
  0/46 on the first cold build".

Finally, a housekeeping note for anyone following citations: #98's body says
"see #98" and "Related: … #98 (release scope)" where it means **#99**.

---

## 2. The gap, precisely

### 2.1 One writer, one caller

`seed.py` is the only component in either repo that writes topology into NetBox.
Measured: of the nine modules that import `pynetbox`
(`render.py`, `render_fabric_ztp.py`, `render_revision.py`, `sot_revision.py`,
`drift.py`, `seed.py`, `test_bulk.py`, `clab/gen_topology.py`,
`clab/reconcile.py`), a grep for `.create(`, `.update(`, `.delete(`, `.save()`
and the `requests` write verbs finds writes in exactly two: `seed.py`, and
`test_bulk.py` — which creates and deletes only scratch `/31`s under `10.253/16`
with a run-unique description, explicitly "so this never touches seeded
topology" (`test_bulk.py:9-10`).

Its single caller is `deploy/30-seed.sh`, which runs only inside `deploy.sh`. So
**a profile change committed to git never reaches the SoT until a human re-runs a
deploy stage.**

### 2.2 It creates; it does not correct and it does not remove

`seed.py`'s create surface, in the order it runs:

*`--bootstrap-schema` (`seed.py:88-137`)* — `dcim.sites` (`sim-dc1`),
`dcim.racks`, `dcim.device_roles`, `extras.custom_field_choice_sets`,
`extras.custom_fields`, `dcim.manufacturers`, `dcim.device_types`,
`dcim.interface_templates`.

*`--profile` (`seed.py:312-524`)* — `dcim.devices`, `dcim.interfaces`
(`Loopback0` only; every physical port comes from the device-type template at
device creation), `ipam.prefixes`, `ipam.ip_addresses`, the `primary_ip4` PATCH,
`dcim.cables`. Then a completion record to
`/opt/gpufab/logs/seed-complete.json` (`:499-524`).

Everything in that list is guarded by a pre-fetched snapshot and skipped if
present (`seed.py:351-357`). Nothing in it reconciles a *difference*. Change
`bgp_asn` in the profile and NetBox keeps the old one; change a link and NetBox
keeps both the old cable and the new. `FEATURE-EXTENSIBILITY.md:207-209` states
the same conclusion from the other direction.

The only removal path is `reset_topology()` (`seed.py:533-549`): a `for` loop of
`obj.delete()` over cables, then IPs, then site-scoped devices, then prefixes.
It is exposed by no stage — `roles/fabric.sh:495` names it in an *error message*
as something a human should run by hand. Two properties of it matter for what
follows:

- **It is unscoped except for devices.** `nb.dcim.cables.all()`,
  `nb.ipam.ip_addresses.all()` and `nb.ipam.prefixes.all()` are global; only
  `nb.dcim.devices.filter(site_id=site.id)` is scoped
  (`FEATURE-EXTENSIBILITY.md:969-971`).
- **It is sequential and single-threaded**, while the `_bulk()` machinery three
  hundred lines above it exists for creates only.

### 2.3 `reconcile.py` is a detector

`gpufab-platform/clab/reconcile.py` (495 lines) compares two layers and writes
nothing. Its docstring (`:28-40`): "**L1 PLAN-AS-EXECUTED vs RECORD** — the
deployed `gpufab.clab.yml` … against NetBox's cable list"; "**L2 KERNEL vs
RECORD** — for every node, the interfaces that actually exist in its network
namespace, against the ports the record says that device terminates." A grep for
every write verb and every filesystem-write call over the whole file returns zero
hits; its three subprocess calls are `docker ps`, `docker inspect` and `nsenter
… ip -o link show`. Its product is an exit code — `0 reconciled · 1 DIVERGED ·
2 could not measure` (`:60`) — and on divergence it prints "Refusing to
configure." (`:488`). It refuses; it does not repair.

Its only production caller is `deploy/48-reconcile.sh:63`, which is one line of
executable work wrapped in preflight and an rc mapping, and which does **not**
call `seed.py`.

### 2.4 So: three missing properties, not a system

| missing | today |
|---|---|
| **removal** | `get_or_create` can add a device, never move or delete one. `--reset` is 6002 sequential DELETEs on `s1-512`, unscoped for three of its four classes, exposed by no stage. |
| **trigger** | nothing runs `seed.py` from a commit. `render.yml` is triggered by a NetBox *change*, which is the wrong end of the arc. |
| **continuity** | it runs once, when a human runs stage 30. |

---

## 3. The design

### 3.1 `seed.py` becomes a reconciler

Diff-based. Derive the declared fabric from the profile, read the actual from
NetBox, apply the difference — create, update, delete. Not `--reset`: a diff
touches only what changed, so a one-rack edit is seconds rather than an unmeasured
half hour.

The read half already exists and is already cheap. `seed()` pre-fetches every
collection into a dict in five requests (`seed.py:351-357`), on the stated
grounds that "idempotency … now comes from comparing against a full snapshot of
what exists, rather than from a per-object GET" (`:341-344`). **That snapshot is
the `actual` side of the diff.** The reconciler is not a new read path; it is the
existing read path with two more verbs behind it.

The write half also already exists for two of the three verbs. `_bulk()`
(`seed.py:265-309`) batches POSTs 200 at a time over four connections, with a
per-batch fallback to one-at-a-time so "a single bad object cannot take out the
other 199 — and the failure is reported rather than swallowed" (`:267-268`). And
pynetbox's bulk *delete* is already exercised by a committed live test:
`test_bulk.py:43-47` deletes by explicit id list in chunks of 200, with the rule
that matters written into its docstring — "**Delete by explicit id list; a filter
that silently matches nothing would leave the next run to collide with this
one's leftovers.**" So "6002 sequential DELETEs" is not a property of NetBox or
of pynetbox. It is a property of `reset_topology()` having been written before
`_bulk()` existed.

### 3.2 The load-bearing constraint: derive through `fabric_model`

The SoT holds *derived* state — addresses, cables, ASNs — so reconciling means
re-deriving and diffing. A second derivation inside the reconciler would be the
fourth instance of the defect that has already cost this project three.

The comment above the call site that this design keeps pointing at,
`render_fabric_ztp.py:760-765`, verbatim:

```
        # gateway and TACACS both come from fabric_model.mgmt_infra() — the one
        # table of pod-infrastructure offsets. The gateway used to be spelled
        # `subnet[1]` here, which is the same literal MGMT_INFRA_OFFSETS exists
        # to remove; f52a043 removed the OTHER copy of it (setup_auth.sh said
        # .3, interim_deploy said .4, and 46 of 48 switches were pointed at a
        # port nothing listens on for the life of the project).
```

The full incident, from `f52a043` (gpufab-platform, 2026-07-27): the TACACS+
server address was declared twice and disagreed. `setup_auth.sh` started the
container on `172.20.0.3`; `interim_deploy.py` told every switch `172.20.0.4` —
which is the **ZTP server's** offset (`fabric_model.py:73`:
`MGMT_INFRA_OFFSETS = {"gateway": 1, "tacacs": 3, "ztp": 4}`). The "port nothing
listens on" is TCP/49 on `.4`. Measured on `gpufab-s4-fabric`: 46 of 48 switches
pointed at it, for the life of the project, and **nothing reported it** because
AAA was `tacacs+,local` with failthrough — every login fell to local and
succeeded.

#79 is the third recurrence of the same shape, closed today: `render_fabric_ztp`
called `fabric_model.mgmt_infra(subnet)` without `overrides`, so ZTP artifacts
carried `TACPLUS_SERVER 172.20.56.3` while the push wanted `10.10.0.46`; three
switches failed `config reload` and the fabric finished 1410/1464.
`t32-oob-mgmt-addressing.sh:31` says it plainly: "This is the **THIRD** time one
management address has had two derivations here." The fix removed the unsafe
default rather than correcting it — `mgmt_infra()` now raises on
`overrides=None` (`fabric_model.py:135-142`).

So: the reconciler calls `gpufab.derive_topology(prof)` through the existing
`derive_topology()` wrapper (`seed.py:183-208`) and diffs its output. It computes
no address, no ASN and no cable endpoint of its own. If the diff needs a value
the model does not expose, the fix is to expose it from the model, not to compute
it here.

### 3.3 The trigger, and what has to be true before it exists

The mechanism is right and the routing is careful work. `render.yml` routes a
matrix on `client_payload.sim_id`, makes the runner assert its own
`/opt/gpufab/instance-id` and fail loudly on mismatch (`:43-58`), takes NetBox
URL and token from a sim-local file with no global fallback (`:72-77`), and
renders an *empty* matrix rather than one arbitrary runner when `vars.SIM_IDS`
is unset (`:32-40`) — "a job that visibly does not run is a configuration error
somebody fixes; a job that silently covers one sim of six is one nobody
notices." The reconcile job should be modelled on it line for line.

But per correction 4, **there is no working runner today**, and the label
`render.yml` now requires exists on no runner in the account. Before a commit can
trigger anything:

1. `gpufab-gh-runner-token` must be declared in terraform. It is declared in no
   terraform resource (`FEATURE-EXTENSIBILITY.md:825-831`), and
   `setup_runner.sh:42` reads it from Secret Manager.
2. Stage 90 must stop degrading silently on runner failure, or health must stop
   treating the runner as `optional: true` — one of the two, not neither.
3. `vars.SIM_IDS` must be set, or every schedule-driven path stays a no-op. The
   07-28 nightly render failed with **0 jobs and 0s wall** for exactly this
   reason; repo Actions variables today contain only `NETBOX_URL`.
4. `t22-review-regressions.sh:354-355` asserts "stage 90 requires relay AND bot
   AND runner" against a line that names only relay and bot. It has passed under
   a false name since `1a092e6` and is the only thing in the suite that claims to
   cover the runner (`FEATURE-EXTENSIBILITY.md:920-922`).

The reconcile job itself is small: `on: push` to `main`, `paths:
["design/profiles/**", "design/base/**", "design/policy/**"]`, `runs-on:
[self-hosted, sim-<id>]`, and one step that runs `seed.py --reconcile` with the
sim-local NetBox credential. It must carry the same `concurrency` group as
`deploy.yml` — see §7.5.

### 3.4 Delivery is the existing pipeline, unchanged

Render → ZTP/push → device, with the manifest governing ownership and steady
state governing removal. No parallel delivery mechanism. The loop is the same
code path as a deploy, triggered differently.

This is not a preference. The config half of ownership was rebuilt over three
issues in the last two days and it works: `manifest.py` (478 lines) attributes
every changed `(table, key)` pair to the contributor that wrote it, with the
rule "**NO IMPLICIT DELETION. Absence means 'I contribute nothing here', never
'remove this'**" (`:53-57`); `interim_deploy.py:1173` computes cross-render
removal as `set(box_tables) - set(art_tables)`, guarded because "without that
guard a device carrying a box manifest and served no artifact manifest would
compute 'remove everything the last render owned' — INTERFACE, PORT,
BGP_NEIGHBOR — and the push would strip the fabric it exists to build"
(`:1124-1131`); #92 split bootstrap from steady state; #96 made the steady-state
arm reachable on the default ZTP path, where it had been dead because
`USE_ZTP=1` meant all 46 switches were skipped in-sync and never wrote a box
manifest. All three are closed. A second delivery path would have to argue all of
that again.

### 3.5 Continuity is the same reconciler on a timer

Drift is "the reconciler found a difference". One definition, one implementation.
`--plan` on a schedule replaces `drift-check.yml` (§10) and, unlike it, produces
a number a test can assert on.

Note what the reconciler does *not* subsume: `drift.py` compares three copies —
INTENT (NetBox), RENDERED (artifacts), RUNNING (the box) — and "reports TWO
INDEPENDENT KINDS of divergence and never merges them" (`drift.py:6-21`). The
reconciler owns the git↔NetBox edge only. Artifact staleness and box divergence
stay with `drift.py`, `render_revision` and `t33`.

---

## 4. What the reconciler diffs, class by class

This is the section that will destroy something if it is wrong.

### 4.1 The rule, before the table

**The reconciler may delete only objects it can prove it created.** Not "objects
the profile does not mention" — that is delete-by-absence, and it is the exact
rule `manifest.py:53-57` rejects for config:

> `* NO IMPLICIT DELETION. Absence means "I contribute nothing here", never "remove this"`

The config half of this system spent three issues learning that. The SoT half
should not learn it again on a live NetBox. Concretely: **`seed.py` records no
ownership on anything it creates today** — no tag, no custom field, no marker.
So phase 0 of §11 is to start recording it, and no delete verb ships until
ownership has been recorded for at least one full build.

The natural marker is a NetBox **tag**, applied at create time to every object
the reconciler owns. It is the direct analogue of `record_ownership()` /
`/etc/sonic/gpufab_owned.json` on the config side (`interim_deploy.py:851-902`),
and it makes the delete predicate "tagged and no longer declared" rather than
"not declared". Measured caution: **zero tags exist in this NetBox today**
(`FEATURE-EXTENSIBILITY.md:178-182`, live measurement), and `site.yaml:30`
declares three tag patterns that `bootstrap_schema()` never creates — so tags are
a new object class with no existing users, which is the cheapest possible place
to add one.

### 4.2 What else lives in this NetBox that `seed.py` did not create

**This is the part most likely to destroy something.** A reconciler that deletes
by absence would delete its own credentials and its own trigger. Every item below
is created by a different component and must be invisible to the diff:

| object | created by | what deleting it costs |
|---|---|---|
| `users.User` (admin), `users.Token` | `services/setup_netbox.sh:141-152` (nbshell) | the API token every consumer authenticates with. `setup_netbox.sh:149` already revokes *stale* tokens for that user, so a second authority deleting tokens is two authorities on one object. |
| `extras.Webhook` `gitops-relay`, `extras.EventRule` | `bot/wire_netbox_webhook.py` | the only leg of the GitOps loop that has ever run in anger. The event rule covers `dcim.device`, `dcim.interface`, `dcim.cable`, `ipam.ipaddress` on create/update/delete. |
| `extras.ConfigContext` | nothing today | reserved for the operational overlay (`network-automation-design.md:262-269`), which is operator-owned by design (`FEATURE-EXTENSIBILITY.md:225-230`). |
| `dcim.Location`, `extras.Tag` | **nothing** — declared in `design/base/site.yaml:3` and `:30`, never read by `bootstrap_schema()` | nothing today, but a reconciler that starts creating tags (§4.1) must not then treat *these* declarations as its own. |
| `eth0_mac` custom-field *values* | nothing — `harvest_macs.py` is a stub that exits "not implemented yet — build phase P3" | nothing today. When P3 lands it becomes an **observation-written** field on a device the reconciler owns, read by `ztp/render_ztp.py:67`. The reconciler must own the device and not that field. |

The last row is the general rule and it is worth stating separately:
**object ownership and field ownership are different questions.** The reconciler
owns `dcim.device` records; it does not own every field on them. `manifest.py`
already models exactly this distinction for config —
`FIELD_LEVEL_TABLES = frozenset({"DEVICE_METADATA"})` (`:151`) plus
`rec["owned_keys"]` (`:349-350`) so a consumer compares only the keys the render
claims. The SoT needs the same shape: a per-class list of owned fields, and
anything outside it is left alone.

### 4.3 Delete safety, class by class

`R` = risk if the reconciler deletes it. The cascade column is **inferred from
the NetBox 4.3 data model, not measured** — see §4.4 for the measurement that
settles it.

| class | created at | delete verdict | why |
|---|---|---|---|
| `dcim.site` (`sim-dc1`) | bootstrap | **never** | everything is scoped to it; there is exactly one, and the profile cannot express its absence. |
| `dcim.rack` | bootstrap | never automatically | measured oddity: **`seed.py` assigns no device to a rack.** The `want_dev` payload (`:368-376`) carries `name`, `site`, `device_type`, `role`, `custom_fields` — no `rack`. The six racks in `site.yaml` are created and stay empty. Deleting one is harmless today and would stop being harmless the moment rack assignment lands. |
| `dcim.device_role` | bootstrap | never automatically | NetBox `PROTECT`s a role in use, so a delete of an in-use role errors rather than cascading — which is safe but produces a reconciler that fails on a legal profile edit. Roles are cheap; leave orphans. |
| `extras.custom_field` | bootstrap | **never** | deleting a custom field destroys its value on every device, silently and irreversibly. `bgp_asn` is a custom field, and it is what `sot_revision`'s fingerprint and every render read. |
| `extras.custom_field_choice_set` | bootstrap | **never** | referenced by the select-typed custom fields. |
| `dcim.manufacturer` | bootstrap | never automatically | `PROTECT`ed by device types. |
| `dcim.device_type` | bootstrap | never automatically | `PROTECT`ed by devices, and deleting one takes its interface templates with it. A profile that stops using a switch model is not a reason to delete the model. |
| `dcim.interface_template` | bootstrap, **only on first creation** (`:134-136`) | delete-and-recreate, gated | this is the class that most needs *update* and least needs standalone delete. Today a device type whose templates are wrong can only be fixed by deleting the device type — which means deleting every device of that type. Recommendation: reconcile templates as a set (add missing, remove extra) against `load_switch_models()`, and refuse if any device of that type already exists, because changing a template does **not** retroactively change interfaces on existing devices. |
| `dcim.device` | seed | **the dangerous one** | a device delete cascades to its interfaces, and through them to the IPs assigned to those interfaces and to its cable terminations. On `s1-512` one leaf carries ~52 interfaces, ~52 addresses and ~52 cables. This is the verb that makes #88 work and the verb that can empty a fabric. Gated hardest — see §7.3. |
| `dcim.interface` | seed (`Loopback0` only) | dangerous | physical interfaces are not the reconciler's to delete: they are created by the device-type template, so removing one puts the device out of agreement with its own type. Only `Loopback0` is directly created and only it should be directly deleted. |
| `ipam.prefix` | seed | **safe** | nothing references a prefix. Deleting a `/31` container does not delete the addresses inside it. This is the class where delete is cheapest and most obviously correct. |
| `ipam.ip_address` | seed | **not harmless — looks harmless** | `Device.primary_ip4` is `SET_NULL`, so deleting a management address silently nulls the device's primary IP rather than erroring. The device then renders and pushes without an address and nothing reports a failure. **Clear `primary_ip4` explicitly before deleting the IP it points at, and re-assert it afterwards** — do not rely on the cascade to be visible. |
| `dcim.cable` | seed | **safe, and required** | deleting a cable removes its two `CableTermination`s and recomputes paths; both interfaces survive uncabled. Rewiring is the common day-2 change and this is how it is expressed. `seed.py:236-238` records the object graph from a py-spy profile: "a cable changes five of them (the Cable, two CableTerminations, and both Interfaces, which `CableTermination.save()` rewrites)". |
| `users.*`, `extras.Webhook`, `extras.EventRule`, `extras.ConfigContext`, `dcim.Location`, `extras.Tag` | §4.2 | **never** | not created here. Not in the diff at all. |

Two ordering constraints fall out, and `reset_topology`'s docstring already
asserts one of them ("Order matters: cables -> IPs -> devices -> prefixes"):

- **Delete order**: cables → IP addresses (after clearing `primary_ip4`) →
  `Loopback0` interfaces → devices → prefixes.
- **Create order** is the existing one (`seed()`), and it is not the reverse:
  devices → interfaces → prefixes → IPs → `primary_ip4` → cables.

A reconcile pass therefore runs deletes and creates as two ordered phases, not
interleaved per object.

### 4.4 What is inferred, and the measurement that settles it

Everything in the "cascade" reasoning above is read off the NetBox 4.3 data model
and off `reset_topology`'s ordering, not off a live NetBox. **No committed test
in either repo observes a NetBox cascade.** That is the same gap that let the
`--reset` runtime be quoted as a measurement for weeks.

The measurement, and by CLAUDE.md §2 it belongs in `tests/`, not in an ad-hoc
SSH: extend `gpufab-network/tools/test_bulk.py`, which already creates and
deletes scratch objects against a live NetBox under a run-unique tag. Under a
scratch site, create one device with a device type carrying templates, an
assigned IP, a `primary_ip4`, and a cable to a second device. Then delete the
device and count, by explicit query rather than by inference: interfaces
remaining, IP addresses remaining, cables remaining, and whether the peer
device's `primary_ip4` survived. Assert with `t_count` against a stated
expectation — never `t_min 0`, never a floor.

Until that runs, **no delete verb ships**. §11 puts it in phase 0.

### 4.5 What "update" means, and where it bites

Updates are the quiet half and they are more of the work than deletes.

- **Device**: `custom_fields` (`fabric`, `plane`, `rail`, `node_class`,
  `ztp_mode`, `bgp_asn`), `role`, `device_type`. A profile edit that changes a
  leaf's ASN must PATCH it. Today it does nothing.
- **IP address**: an address whose interface assignment changed. Cheaper to
  delete-and-create than to re-point, but the `primary_ip4` rule in §4.3 applies.
- **Prefix**: `description` only. Not worth reconciling; ignore.
- **Cable**: cables have no meaningful update — a rewire is a delete plus a
  create, and must be sequenced that way or the create hits the duplicate-
  termination error that "killed an earlier seed" (`seed.py:462`).
- **`primary_ip4`**: today set-once (`:446`, `not d.primary_ip4`). The reconciler
  must be able to re-point it, which means removing that guard — and that is
  precisely a case where the existing behaviour is protective, so the re-point
  must be conditional on the declared address differing, not unconditional.
- **Interface templates**: §4.3. The `if c:` guard at `:134` is a live latent
  defect independent of this design.

---

## 5. Secrets are out of scope, and must stay out

**NetBox has no secret store and the reconciler must never attempt to manage
one.** Stated in three independent places in the code, and no code contradicts
it — a grep for `custom_field.*(secret|password|key|community)` across both repos
returns zero hits:

> "NetBox records THAT snmp is configured and which derivation is used, never the
> value: it has no secret store (the plugin was removed upstream), so a custom
> field there is plaintext in the SoT and in every API response."
> — `services/tacacs/setup_auth.sh:171-173`

> "The per-sim HMAC key the community is derived from. Root-owned in `$SECRETS`
> beside `tacacs_key`; **NEVER in NetBox, which has no secret store**"
> — `interim_deploy.py:334-336`

Secrets live on-host under `$SECRETS` = `$GPUFAB/secrets`, default
`/opt/gpufab/secrets` (`deploy/lib.sh:14,18`; note the fabric role uses
`GPUFAB_SECRETS` instead, `roles/fabric.sh:45`), `root:ubuntu 0640`, with
Secret Manager as the durable copy: `netbox_token`, `admin_password`,
`snmp_secret`, `tacacs_key`, `tacacs_user_password`, `gh_token`,
`netbox_webhook_secret`, `automation_ed25519`.

One nuance the reconciler must not flatten: Secret Manager is **not uniformly the
channel**. For `netbox_token` and the routed-OOB shared secrets the head owns and
publishes and the fabric restores and must not generate — a fabric that cannot
read them exits 1 (`setup_auth.sh:144-149`). For `snmp_secret` in local mode the
order is "local, then Secret Manager, then generate", where Secret Manager is
"a **BACKUP** of a local value rather than the channel it arrives by"
(`setup_auth.sh:175-187`). Neither precedence is expressible in a NetBox diff and
neither should be.

The reconciler's rule is therefore one line: **if a value cannot be derived from
the profile through `fabric_model`, it is not the reconciler's.**

---

## 6. Ordering — the loop follows, it does not lead

§5.10 of `scale-out-architecture.md` is titled *"Physical first, SoT reconciled
after"* (`:2328`) and settles this. Verbatim, `:2334-2338`:

> "**This is the order real network operations already runs in.** Nobody waits
> for DCIM to be populated before racking and cabling. The physical topology is
> built from a plan, the devices are powered on blank, DCIM records the intent,
> ZTP serves config derived from DCIM, and only afterwards is the wiring audited
> against the record."

and `:2359-2365`:

> "**Git holds design INTENT** — the cabling plan… **NetBox is the operational
> RECORD** and the source for rendered config. … `seed.py` populates NetBox from
> the same profile, so the record is derived from the intent rather than
> competing with it. There is one derivation (`fabric_model.derive()`) and two
> consumers."

**Warning for anyone following that citation:** `:2387-2390` still carries the
status line "*intent recorded, reconciliation NOT implemented … The fabric role
does not yet use it, and the reconciliation check does not yet exist.*" All three
assertions are now false — `reconcile.py` is 495 lines, `48-reconcile.sh` is
wired into both `STAGES` and `RECOVER_STAGES` (`deploy/deploy.sh:93`), and
`roles/fabric.sh:279-286` implements the two-phase split it describes: "phase 1
topology + containerlab deploy + healthy + config-DB — *profile only*; phase 2
reconcile, render, push config — *needs the SoT*. … Physical first, SoT
reconciled after — which is what stage 48-reconcile, in phase 2 and before any
config is rendered, is for." The status line is stale, not the section.

### How the two compose

The deploy stage order is `… 20-services 30-seed … 40-topology 44-oob-routed
45-isolation 48-reconcile <configure> …` (`deploy/deploy.sh:93`), so on a cold
build the SoT is **seeded before the fabric exists**. That is not a contradiction
of §5.10: the point of §5.10 is that the physical build does not *wait* on the
SoT. `40-topology.sh:7-16` states the mechanism — `TOPO_FROM_PROFILE=1` derives
the topology from the cabling plan in git "so this stage can run while the head
is still seeding NetBox", and "this is not a second source of truth (§5.10)".

So there are two modes and the reconciler must behave differently in each:

| | cold build | reconcile |
|---|---|---|
| trigger | a human runs `deploy.sh` | a commit, or a timer |
| NetBox at start | empty | populated |
| fabric at start | does not exist | running |
| correct behaviour | create everything; **delete nothing** — an empty NetBox is not evidence that 6002 objects should be removed | diff and apply |
| ordering | stage 30, before `40-topology` | after the fabric is up, never concurrent with 40/44/45/48 |

**Stage 30 keeps its current semantics.** `--bootstrap-schema` and `--profile`
stay exactly as they are: additive, idempotent, delete-free. `--reconcile` is a
third mode, and it is never what a cold build runs. That is the cheapest possible
answer to "what if the reconciler runs against a half-built fabric" — it does
not, because the stage that runs during a build is not the reconciling one.

The reconciler is also **not** a replacement for `48-reconcile`. That stage
audits *booted wiring* against the record and it is deliberately fatal
(`48-reconcile.sh:32-35`: "FATAL, deliberately. It is not in `deploy.sh`'s
NONFATAL list, so a divergence stops the deploy before config is pushed."). The
two answer different questions: `reconcile.py` asks "is the
record true of the fabric?", the reconciler asks "is the record true of git?". A
reconcile that changes the record should be followed by `48-reconcile` before
anything is configured from it.

---

## 7. Failure modes, and the refusal rules

The model for every rule here is `deploy/98-spot-rebuild.sh:108-173`, which is
the one piece of this codebase that has already been through this argument and
come out right. Its structure: establish the target or stop; observe or declare
UNKNOWN; if ambiguous, report and exit non-zero; act only on the unambiguous
signal. Its comment at `:164-168`:

> "A fabric that is still CONVERGING is indistinguishable from one that is STUCK
> by this measurement, and an unattended unit must not resolve that ambiguity by
> destroying things."

### 7.1 NetBox unreachable

**Change nothing, exit non-zero, name the endpoint.** The trap is specific and
has already been hit twice in this project: a `curl -f` that treated an
auth-required 403 as "unreachable" (CLAUDE.md §3), and a hardcoded token fallback
that meant "every consumer received a valid-LOOKING credential whether or not one
had been provisioned … and the symptom surfaced as an empty SoT rather than as a
rejected credential" (`seed.py:552-557`). `_require_token()` already refuses
rather than defaulting; the reconciler must extend the same treatment to the
read: **a read that returns zero devices is not evidence that zero devices should
exist.** Distinguish "NetBox says the site is empty" from "NetBox did not
answer", and never let the second become a 6002-object delete plan.

### 7.2 The derivation fails

**Change nothing, exit non-zero.** `expected.py`'s docstring already states the
rule: "Exit status is 1 if the profile cannot be derived, so a caller that
captures a value cannot silently treat a failure as zero." A profile that derives
to zero nodes is a derivation failure, not an instruction to empty NetBox. This
is not hypothetical: `lite.yaml` and `full.yaml` — one of which is still
`deploy/lib.sh:51`'s default `PROFILE` — raise `KeyError: 'fabric'` against
`fabric_model.derive()` (measured, `WHY-ZTP-IAC-GITOPS-FELL-SHORT.md:625`).

### 7.3 The diff is enormous, or a delete would remove too much

Three gates, in order:

1. **`--plan` is the default.** `--apply` is explicit. A plan prints the create,
   update and delete sets by object class with exact counts, and exits 0 whether
   or not it found a difference. Divergence goes in the exit *summary*, not the
   exit code, so a scheduled plan does not page on a legitimate pending change.
2. **A delete ceiling, expressed against the derived total, not a constant.**
   `expected.py --json` already answers "how many of X should exist" for the
   profile. A reconcile that would delete more than a stated fraction of the
   owned objects of any class — start at 5%, and make it a flag, not a literal —
   **reports and refuses**. It does not delete the first N and stop halfway; a
   half-applied plan is worse than a refused one.
3. **Device deletes are gated separately and harder.** A device delete cascades
   (§4.3) and is the only verb that can take a switch out of the fabric. It
   requires an explicit `--allow-device-delete` and prints the device list before
   acting, and the ceiling for it is a count, not a fraction — because "5% of 124
   devices" is six switches, which is not a number anything should reach
   unattended.

The refusal message must name the manual command, the way `98-spot-rebuild.sh:172`
does ("If it is genuinely stuck: `deploy.sh --recover`, by hand"). A refusal
that does not say what to do next gets bypassed with `--force`.

### 7.4 The feedback loop through the event rule

This one is not in #98 and it is a real hazard.

`wire_netbox_webhook.py` registers an Event Rule on `dcim.device`,
`dcim.interface`, `dcim.cable` and `ipam.ipaddress` for `object_created`,
`object_updated` **and `object_deleted`**. So **every write the reconciler makes
fires the relay**, which POSTs `repository_dispatch: netbox-change`, which runs
`render.yml`, which opens a PR. That is the desired composition — a SoT change
should re-render — but three consequences follow:

- **The debounce is a sliding timer**, not a window: `webhook_relay.py:63-69`
  cancels and restarts a 60s timer on every event. A long reconcile therefore
  dispatches once, ~60s after its *last* write. That is correct behaviour and it
  is what the relay was built for — its docstring says "Debounce collapses the
  burst a seed run makes (it touches thousands of objects) into a single
  dispatch." Worth stating so nobody "fixes" it into a fixed window.
- **A reconcile that changes nothing must write nothing**, or the timer never
  settles. This is an argument for the diff being exact rather than
  "PATCH everything and let NetBox decide" — a no-op PATCH still fires
  `object_updated`.
- **A revert fires a second event.** §8's conflict rule means a human NetBox edit
  produces one dispatch (and a render PR), and the reconciler's revert produces
  another (and a second PR that undoes the first). Both PRs are correct and the
  pair is confusing. The reconciler's revert must therefore say so in its own
  output — see §8.

`ipam.prefix` is **not** in the event rule's object types, so prefix churn does
not dispatch. That asymmetry is invisible today and would become confusing the
moment prefixes are the only thing that changed.

### 7.5 Concurrency with a deploy

A reconcile that runs while `deploy.sh` is mid-build will fight stage 30, and
worse, may see a partially-seeded NetBox and compute deletes against it. The
fabric role already has a gate for exactly this shape — `roles/fabric.sh:360-524`
blocks on "a COMPLETE seed" by device *and* cable count, on the stated grounds
that "`seed.py` writes cables LAST, so a full device count with short cables
means the head is still seeding" (`:515`).

Two mechanisms, both needed:

- **In Actions**: the reconcile job joins `deploy.yml`'s existing
  `concurrency: {group: deploy, cancel-in-progress: false}` (`deploy.yml:20-22`).
- **On the host**: `deploy.sh` is run by hand, so Actions concurrency cannot see
  it. The reconciler takes a host lock (`flock` on a file under `/opt/gpufab`)
  that `deploy.sh` also takes, and **refuses rather than waits** if it cannot get
  it — a queued reconcile that fires an hour later against a changed fabric is
  the ambiguous-signal shape again.

---

## 8. The conflict rule — git wins, and the revert is announced

**A human editing NetBox is drift, not a workflow.** Otherwise there are two
sources of truth and no way to tell which is lying. The reconciler reverts, and
it prints what it is about to revert *before* it does it, in the same output that
carries the plan.

Resist the obvious escape hatch — a "hand-managed, do not reconcile" tag. It
reintroduces the second source with extra steps, and this codebase's failure mode
is precisely two authorities disagreeing silently. The exception that already
exists and stays: the operational overlay (`active | quarantined | maintenance`
with owner, reason, expiry) is operator-owned by design, lives in a config
context, and is out of the reconciler's scope entirely — "mutability is the
point, human authorship is the point, the values are scope-uniform literals
rather than derived" (`FEATURE-EXTENSIBILITY.md:225-230`). That is not an escape
hatch for derived state; it is a different object class with a different owner,
and `FEATURE-EXTENSIBILITY.md:848-860` already tabulates the per-channel rule.

### The consequence nobody has stated

**The only leg of the GitOps loop that has ever run in anger is triggered by a
human editing NetBox.** `render.yml` fires on `repository_dispatch:
netbox-change`; the relay fires on a NetBox Event Rule; eight of the render runs
were `repository_dispatch` and nine PRs came out of them. Declaring NetBox edits
to be drift does not break that path — the reconciler's own writes fire the same
event rule (§7.4) — but it does change what the path *means*. Today a NetBox edit
is how you propose a change. After this design it is how you cause a revert.

That is the right answer and it should be said out loud rather than discovered:
after this lands, **the way to change the fabric is to edit the profile in git**,
and the NetBox UI becomes read-mostly. Anyone who has been using the UI as the
input surface needs to be told, because the failure mode is silent — their edit
renders a PR, and then a later reconcile renders the opposite PR.

---

## 9. Where release scope plugs in (#99)

Between reconcile and push. The reconciler produces *what changed*; the rollout
decides *where it goes first*. Content and blast radius stay orthogonal and
neither needs the other's internals.

The interface exists in this design; the rollout side is unbuilt, and the gap is
measurable rather than rhetorical:

- **`interim_deploy.py` has no way to scope a push to a subset of switches.** Its
  entire argument surface is `--profile`, `--verify-only`, `--hosts-only`,
  `--setup-auth`, `--workers`, `--force`, `--no-wait`, `--converge-timeout`,
  `--dry-run` (`:1954-1974`). `--hosts-only` is a class filter, not a subset.
  #99 records the current behaviour: 46 switches in parallel at 24 workers, "no
  canary, no wave, no gate between".
- **`FV-ZTP-04` — "Canary rollout + health-check failure halts fleet rollout;
  rollout stops; blast radius bounded and measured" — is written down at
  `FIDELITY-VERIFICATION-PLAN.md:183` and has never been attempted**
  (`WHY-ZTP-IAC-GITOPS-FELL-SHORT.md:135-137`). The requirement is not new; the
  execution is missing.
- **The verification primitive already exists and #99 says not to build another**:
  the convergence gate (#81, `t31-convergence-gate.sh`), which blocks on
  `expected.py --key bgp_peer_series` with a timeout derived from measured
  per-session establishment times.

Two defects this project has already paid for are exactly the shape a canary
catches, and both are in #99: a 32-port `PORT` table applied to 64-port switches
(**178 BGP sessions lost across three independently built fabrics, every stage
reporting success**), and an identical default base MAC across every SONiC VS
giving every switch the same IPv6 link-local, so **82 of 249 unnumbered sessions
could never come up**. Note the second one is why "the canary converged" is not a
sufficient gate: each switch was individually correct and the *set* was broken.

#99's own honest framing is worth carrying: it may be that **a canary of one
switch plus the existing convergence gate gets 90% of the value for 10% of the
work**, and that should be evaluated before waves are designed.

---

## 10. What to delete rather than fix

> **DONE, 2026-07-29 — both deletions below have been carried out** on branch
> `i91-delete` in `gpufab-network`, adjudicating the #91/#98 contradiction
> (§ "issues that need a decision", item 7) **in favour of #98 — delete**. Every
> measurement in this section was re-verified against the live repo and GitHub
> Actions API first; all of it held, and two facts were added:
>
> - `validate.yml`'s FRR step took **0.0 s in all 4 lifetime runs** (jobs API,
>   runs `30119046975`, `30118803038`) — positive proof the `vtysh -C` loop body
>   #91 wanted to keep never executed, since the image pull alone costs tens of
>   seconds.
> - `main` has **no branch protection and no rulesets** (404 / `[]`), so
>   `validate.yml` was never actually a "required check" and nothing is
>   merge-blocked. The three open render PRs already report "no checks reported".
>
> The rationale, the measurements and the caveat at :702-706 are restated **in the
> repo where someone would recreate these files**, at
> `gpufab-network/.github/workflows/README.md`, alongside the surviving
> `deploy.yml`. A deletion recorded only in a design doc in another repo does not
> reach the person editing `.github/workflows/`.

### `validate.yml` — delete

It has not run on a render PR since 2026-07-24 (correction 7), and on today's
tree both of its `find rendered` loops iterate zero files while `exit $fail` with
`fail=0` reports success. Its third step is a literal
`echo "…placeholder pass"`. Real validation is now the manifest
(`t33-gitops-roundtrip.sh`, `t37-manifest-transition.sh`) plus the convergence
gate (#81, `t31`).

One thing to preserve before deleting it: its path filter includes `design/**`
and `templates/**`, so it is the only PR-time check that fires on a *design*
change at all. Deleting it without putting the reconciler's `--plan` on the same
trigger removes a check that is vacuous but load-bearing in the org chart sense —
someone will notice the missing green tick and not the missing coverage.

> **This caveat was NOT satisfied, and the deletion proceeded anyway.** The
> reconciler's `--plan` does not exist yet, so as of 2026-07-29 `gpufab-network`
> has **zero `pull_request`-triggered workflows** — `validate.yml` was the only
> one. That is a deliberate trade: no check is visibly no check, whereas a green
> tick over two empty `find` loops is the codebase's signature defect sitting
> inside its own required gate. **Putting `--plan` on
> `paths: ["design/**", "templates/**", "instances/*/rendered/**"]` is now the
> open item that reoccupies this slot**, and it is recorded in
> `gpufab-network/.github/workflows/README.md` so it is visible to whoever next
> edits that directory.

### `drift-check.yml` — delete

0 successes in 20 runs. It dies at `drift.py:41` on `ModuleNotFoundError: No
module named 'pynetbox'` because it invokes bare `python3`; the two flags it
passes and `drift.py` has never accepted are a second, currently unreachable
defect behind it. Its last 9 runs never reached a runner at all (5 cancelled at
GitHub's 24h limit, 4 still queued) because the only registered runner has been
offline since 2026-07-26.

Drift on the git↔NetBox edge becomes the reconciler's `--plan` on a schedule.
**`drift.py` itself stays** — it answers a different question (§3.5) and its
logic is sound; what dies is the workflow that has never once invoked it
successfully.

### `deploy.yml` — keep, and finish the fix

Its path filter was fixed today: `8b36b27`, 2026-07-28 11:49:16Z,
`paths: ["rendered/**"] → paths: ["instances/*/rendered/**"]`. The stub to
replace is `deploy.yml:37-41`:

```yaml
      - name: Apply per-device (config load/reload; frr-reload for hosts)  # P6
        run: |
          echo "tools/deploy_device logic lands in P6 (playbooks/p6-gitops.md)"
          echo "would deploy: ${{ steps.diff.outputs.devices }}"
          exit 1                     # fail loudly until P6 implements the apply
```

**But the trigger was fixed and the body was not**, and this matters more than
the stub:

- `:34` still reads `git diff --name-only HEAD~1 -- rendered/ | cut -d/ -f2`.
  The pathspec is the abandoned top-level directory, so the device list comes out
  empty. And corrected to `instances/`, `cut -d/ -f2` yields the **sim id**, not
  the device. This is measured, not theoretical: run `30134817613` logged
  `would deploy: README.md`.
- `:27` is `runs-on: [self-hosted, sim-host]` — the **broad** label. This is the
  defect `render.yml` fixed on 07-27. It is harmless while the apply is a stub
  and becomes a fleet-wide hazard the moment it is not: a merge would apply on
  whichever sim's runner picked it up.
- `instances/` **does not exist on `origin/main`** (`gh api …/contents/instances`
  → 404), because 0 of 9 render PRs have ever been merged. So the new filter also
  cannot fire yet, for a second and independent reason.

"The path filter was fixed" is true. "`deploy.yml` can now fire" is not.

---

## 11. Phased plan

Every phase is gated on the phase before it having run against a real NetBox,
because the whole subject here is delete safety and this project's most recent
lesson is that warm verification of a provisioning claim is not verification:
#58 was closed on a 46/46/46 measurement taken by pushing to a fabric that was
already up, then reopened when the cold run measured 0/46 (#58, comments
2026-07-28T06:20:37Z and 07:27:56Z — "I closed this on the strength of a
measurement that did not test it").

### Phase 0 — measure the cascade, and start recording ownership. ~0.5 day.

Extend `test_bulk.py` with the cascade measurement in §4.4. Add the ownership tag
in §4.1 to every create path in `seed.py`. **No new verb, no behaviour change** —
a re-seed of an existing fabric creates the tag and nothing else.

*Makes possible:* everything after it. *Still broken:* all three missing
properties. *Why first:* the delete predicate cannot be "not declared" and there
is nothing today that records what the reconciler created.

### Phase 1 — `--plan`. ~1–1.5 days.

Derive, read the existing snapshot, diff, print create/update/delete sets by
class with exact counts. **Writes nothing.** Ships the whole diff engine at zero
blast radius, and is immediately useful: pointed at a running sim it answers
"has anyone touched this NetBox", which nothing answers today.

*Makes possible:* replacing `drift-check.yml`. *Still broken:* a profile edit
still changes nothing in NetBox.

### Phase 2 — `--apply` for create and update only. ~1 day.

The delete set is computed, printed, and **not executed**. Fixes the
`primary_ip4` re-point, the device custom-field updates, and the interface-
template `if c:` guard.

*Makes possible:* a profile field edit reaching the SoT — which is the smaller
half of #98 and lands two phases before the risky half. *Still broken:* removal.
A shrunk profile leaves orphans, exactly as today.

### Phase 3 — delete, bulk, scoped, ceiling-gated. ~1.5–2 days.

Bulk delete by explicit id list (`test_bulk.py:43-47`'s pattern), scoped by
ownership tag and by site, ordered per §4.3, gated per §7.3. Also: make
`--reset` bulk and scoped and expose it as a stage, which is #88's other
outstanding item.

*Makes possible:* #88's SoT half — a leaf removed from the profile leaves the
record. *Still broken:* nothing runs any of it from a commit.

### Phase 4 — the trigger. ~0.5 day, **blocked**.

A reconcile job on the sim's own runner, modelled on `render.yml`, path-filtered
on `design/**`, sharing `deploy.yml`'s concurrency group plus a host lock.

**Blocked on the four items in §3.3** — the runner-token terraform resource,
stage 90's silent degradation, `vars.SIM_IDS`, and the `t22` assertion that has
never measured the runner. None is large; all four are prerequisites, and the
first is the hard one because it is a secret nothing declares.

*Makes possible:* commit → NetBox, for the first time. *Still broken:*
NetBox → device still requires `deploy.yml`'s apply, which is still a stub, and
still requires a merge, which has happened 0 times in 9 PRs.

### Phase 5 — continuity. ~0.25 day.

`--plan` on a schedule; `drift-check.yml` deleted. A scheduled plan that finds a
difference reports it and exits 0; it does not apply, because "the reconciler
found a difference" during a deploy is the ambiguous signal.

### Phase 6 — the end-to-end test. ~1 day, and it should arguably be written first.

`t33-gitops-roundtrip.sh` already asserts artifact → device on the box, and its
header already claims the full chain `git commit -> render -> ZTP artifact ->
device -> OBSERVED ON THE DEVICE`. It does not make a commit. The missing steps
are the left half: change one declared value in a committed profile, drive the
loop, read the switch with `sonic-cfggen -d`, then **revert the commit and assert
the change is removed from the box**. That last step is what catches a merge-only
push and is the smallest honest version of #88
(`FEATURE-EXTENSIBILITY.md:879-886`).

Ranking it last is the honest sequencing of the *work*; #98's own predecessor
ranks writing a failing end-to-end test **above** implementing the apply
(`WHY-ZTP-IAC-GITOPS-FELL-SHORT.md:621-622`, items 3 and 4: "write the test that
fails, then make it pass"). If that ordering is taken seriously, phase 6's
skeleton lands with phase 1 and is allowed to fail until phase 4.

**Total: roughly 5–6 days**, which is consistent with #98's "days, not hours" and
is not consistent with treating the trigger as wiring — phase 4 is small but its
four prerequisites are not.

---

## 12. Cost, and the honest caveat

The reconciler is the real work. Diffing derived state against NetBox is fiddly,
the delete path needs care, and §4.2 is the reason: the object classes that must
never be touched are not the ones a diff naturally excludes.

**Is a reconciling controller worth it for a simulator?** "Run a deploy" is a
legitimate alternative and the deploy path now works well: **24m11s** cold on
s11, `skipped(in-sync)` `0/46 → 46/46` cold, and `bgp_peer_series` matching
`expected.py` at 1464 exactly (#58, comment 2026-07-28T09:45:46Z; and see the
correction in §1 — 20m57s is not a figure in the record).

The answer is yes, for one specific reason: **the reconciler is what makes day-2
add/remove work at all**, and that is the capability being asked for. Precisely:

- **#88 (open)** is device-level day-2 add/remove — adding or draining a switch
  or GPU node against a live fabric. Detection exists (`reconcile.py`); mutation
  does not. This design is its SoT half.
- **#94 (open)** is *not* add/remove and #98 mis-describes it. It is day-2
  **change** of an adopted table: "ADD is governed by ZTP … REMOVE is governed by
  the manifest … **CHANGE is governed by neither**", so a drifted adopted table
  is carried forward verbatim and `config_landed` cannot see it. #94 calls itself
  "the remaining half of #88", so pairing them is fair — describing both as
  "add/remove" is not.

If it were only about continuous convergence, defer it. Phase 5 is a quarter-day
and is the least valuable phase in the plan.

---

## Appendix — how this was established

Commands and sources, so any claim here can be re-derived.

**Object counts.** `gpufab-platform/tools/expected.py --profile
../gpufab-network/design/profiles/scale/s1-512.yaml`, run on the workstation:
124 devices, 1466 cables, 3024 IP addresses, 1388 p2p prefixes → 6002. Matches
`FEATURE-EXTENSIBILITY.md:961-962` exactly.

**Writers.** `grep -rln pynetbox` over `gpufab-network/tools`,
`gpufab-platform/tools`, `gpufab-platform/clab`, `gpufab-platform/bot` → nine
modules; then `grep -n '\.create(\|\.update(\|\.delete(\|\.save()\|requests\.
(post|patch|delete)'` over each → writes in `seed.py` and `test_bulk.py` only.

**Callers.** `grep -rn 'seed\.py' gpufab-platform gpufab-network`, then removing
comment and string hits by inspection → `deploy/30-seed.sh:8,10`.

**Workflows and runs.** `gh run list --workflow=<f> --limit 200`, `gh run view
<id> --log`, `gh api gpufab-network/actions/runners`, `gh pr list
--state all`, `gh api …/contents/instances`, `gh api …/actions/variables`. Read
2026-07-28 ~20:00Z.

**Flag history.** `git log -S post-metrics -- tools/drift.py` plus
`git show <sha>:tools/drift.py` for all four commits that touched the file.

**Issues.** `gh issue view <n> --repo gpufab-platform`. All six of
#79/#81/#88/#92/#94/#96, plus #91/#98/#99, are in `gpufab-platform`;
`gpufab-network` and `gpufab-docs` have zero issues. **Do not use
`ISSUE-REGISTER.md` for these** — it uses letter codes A1–O18, its "still open"
table stops at O10/#64, and it contains none of O25/O27/O34/O38/O40/O42.

**Cascade behaviour is the one thing not established here.** §4.3's delete column
is read off the NetBox 4.3 data model and off `reset_topology`'s ordering. No
committed test in either repo observes a NetBox cascade. §4.4 names the
measurement; §11 phase 0 schedules it; nothing in §11 phase 3 ships before it
runs.
