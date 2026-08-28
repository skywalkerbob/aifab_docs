# Feature extensibility — declaring capability in the profile instead of editing four files

**Status:** design, 2026-07-28. Not implemented. Extends `scale-out-architecture.md`
§5.10 (physical first, SoT reconciled after) and §5.11 (configure it, do not suppress
it). Motivated by #87 (O33, VXLAN/EVPN designed but not built) and #88 (O34, no day-2
add/remove path).

**Scope:** how a capability the NOS already supports becomes a profile edit rather than
a coordinated change across `render_fabric_ztp.py`, `interim_deploy.py`, `expected.py`
and `tests/`. VXLAN/EVPN is the worked example, not the subject. The subject is the
mechanism, and the reason it does not exist today.

---

## 1. The recommendation, first

### 1.1 The flaw, stated precisely

The pipeline is **declarative at both ends and imperative in the middle.**

NetBox can carry configuration content — config contexts are hierarchical JSON merged per
device by scope, and this project uses them nowhere. SONiC can consume it — `config_db`
is one JSON document whose every capability is another table. Between them sits a renderer
that is a hand-written enumeration of the tables it was taught about.

That framing is where this document started, and §1.4 records where the measurements moved
it: NetBox's mechanism is the right *shape* and is structurally incapable of the half of
the problem that matters most. But the middle of the sentence survives every measurement,
and it is the finding: **the translation from intent to table is Python control flow, so a
new kind of state cannot be declared, only coded.**

That is not one enumeration. It is **three**, in two repositories, and a new capability
must extend all three by hand:

| # | Where | What it enumerates | Line |
|---|---|---|---|
| 1 | `render_fabric_ztp.device_config()` | which tables get emitted | `render_fabric_ztp.py:525-695` |
| 2 | `interim_deploy._OWNED_WRITE` / `DROP_TABLES` / `_MD_KEYS` | which tables drift detection governs | `interim_deploy.py:604`, `:178`, `:606` |
| 3 | `expected.py compute()` | the oracle | `expected.py:111-149` |

Miss the third and you get #56 verbatim: `expected.py --key max_ports_per_switch`
printed **70** against a 64-port platform and **exited 0 for the life of the project.**

**The three have already drifted, today, on `main`, with no feature added.** Set-differencing
what the renderer writes with intent against what the push compares:

```
RENDERED WITH INTENT but absent from _OWNED_WRITE:
    MGMT_INTERFACE          <- the management address and its gateway
    MGMT_PORT
    MGMT_VRF_CONFIG         <- the confinement §2.5 is written against
    FEATURE                 <- covered only by a bespoke `if` for snmp
    DEVICE_METADATA         <- covered only by _MD_KEYS, 4 of the 6 keys written

DEVICE_METADATA keys written by the renderer but NOT in _MD_KEYS:
    mac                          <- the system MAC. Colliding MACs cost 82 of
                                    249 sessions; nothing checks it landed.
    docker_routing_config_mode   <- selects FRR split mode. On the unnumbered
                                    path this decides whether the device reads
                                    frr.conf at all; nothing checks it landed.
```

Neither omission was noticed, because nothing anywhere compares the two lists. This is
the same defect class as #56 — an enumeration that silently stops covering what it is
supposed to cover — and it is live now, in the function whose docstring calls itself
"the most consequential function in `interim_deploy`".

### 1.2 What GitOps delivers here today, and what it does not

Stated plainly, because ZTP, IaC and GitOps are each supposed to make this possible and
the reason they do not is specific:

> **The pipeline is GitOps for new VALUES of known state. It is not GitOps for new KINDS
> of state.**

Changing `cores.backend` from 105 to 192 is a value change. It flows from a profile edit
through `fabric_model.derive()` into `expected.py`, `gen_topology.py`, `seed.py`,
`render_fabric_ztp.py` and `interim_deploy.py` with no code change at all — that is #56's
fix, and it is real evidence, not aspiration.

Adding VXLAN is a new kind of state. It flows nowhere, because the *schema of the intent*
is encoded in Python control flow rather than in data. IaC and GitOps deliver "the repo is
the desired state" only to the extent that the desired state is **expressible** in the
repo, and `config_db`'s surface currently is not. ZTP is not the missing link either: ZTP
faithfully serves whatever the renderer produced, and the renderer produces fourteen tables.

The gap is one function: nothing translates a declaration into a table.

### 1.3 The recommendation

**Build a composed render with a computed owned-table manifest.** Six parts, in the order
they must be built:

1. **The profile is the only place a capability is turned on**, in
   `gpufab-network/design/profiles/`, under an **allow-listed** `features:` block.
   Allow-listing is not optional: unknown profile keys are silently ignored today
   (measured — see §3.6), so a typo'd `vxlann:` would read as "feature off" everywhere
   while its author believed it was on.

2. **`nos_catalog.yaml` declares whether the NOS can express it**, and
   `fabric_model.check_nos_capabilities()` refuses the profile at derive time if it
   cannot. This mechanism already exists and already works for `bgp_unnumbered`,
   including the second-order case (`bgp_unnumbered_requires: frr_split_mode` forces the
   profile to declare `config_mode`). It is the single best hook in the codebase and it
   needs no new abstraction.

3. **The model allocates every identifier from a named pool with declared bounds.**
   VNIs, VLAN ids, overlay prefixes, ports. A pool overflow is a `ModelError` at derive
   time with the pool named. This is what closes the #56 class *generically* rather than
   adding one more hand-written assertion.

4. **Features contribute table fragments, not edits.** A module returns only the tables
   it owns, for a composer to merge. This contract already exists —
   `frr_render.to_config_db()` returns `INTERFACE`, `LOOPBACK_INTERFACE` and
   `BGP_NEIGHBOR` and nothing else, "for the caller to merge; it does not deep-copy a
   whole base config, so there is exactly one place that decides what a full `config_db`
   looks like" (`frr_render.py:105-111`). Generalise that sentence and the design is
   most of the way done.

5. **The composer emits a manifest of what it wrote, and that manifest is the owned-table
   set.** Not a list anyone maintains — a record of what was actually emitted, with the
   contributing module named per table and per key. `interim_deploy` reads it instead of
   `_OWNED_WRITE` and `DROP_TABLES`. `expected.py` reads it for declared-table counts.
   The device checks read it to know what to look for. **This is the part that collapses
   three enumerations into one, and it is the part with the highest value per line.**

6. **Declared fragments are render DATA in git**, under `gpufab-network/design/features/`,
   exactly as `vs_base_config_db.json` and `vs_port_sets.json` already are — covered by
   `render_revision`'s whole-directory globs, visible to `model_sot()` offline, reviewable
   in a pull request. **Projecting them into NetBox as config contexts is a later,
   optional step** with three measured preconditions (§1.4). The composer does not depend
   on it.

**Nothing here is a new architecture.** Every mechanism named above already exists in
this codebase for something: capability gating (`nos_catalog`), envelope-bounded
allocation (`addressing.envelope`), fragment contribution (`frr_render.to_config_db`),
profile rewrite-and-re-derive (`oob_plan.py --emit-profile`), artifact provenance
(`render_revision.py`), device readback (`config_landed`), YANG validation
(`t17-mgmt-vrf.sh:277-307`), and shipped device probes (`tests/probes/`). The work is
connecting them, not inventing them.

### 1.4 What was rejected, and why

**NetBox config contexts as the authored surface — rejected for now, on measurement, and
worth revisiting after one upgrade.**

The instinct is right and the mechanism is the right shape. The deployed instance was
measured rather than assumed: `services/setup_netbox.sh:6` pins netbox-docker `3.3.0`,
and `GET /api/status/` on `gpufab-s11-ops` returns **NetBox 4.3.7**. Config contexts and
config templates both exist and respond. What the measurement then found:

- **Contexts are structurally incapable of expressing a derived per-device value.** A
  context is keyed by *scope*, with a literal JSON blob for data. There is no expression
  language and no reference to the device. `bgp_asn`, a /31 from a link index, a VNI from
  a rack index — none of these can be produced by a config context at all. That is not an
  inconvenience; it is the reason the derived/declared split in §3.4 is not a matter of
  taste. **This finding supports the split rather than the mechanism.**
- **The one per-device escape hatch outranks everything.** `Device.local_context_data` is
  free-text JSON that a human types, and `get_config_context()` merges it **last,
  unconditionally**, above every context regardless of weight. That is a hand-written
  value beating a derived one, in the SoT's own schema, with no validation behind it —
  #79 rebuilt as a supported feature. #79 was two derivations of one management address,
  three lines below a comment describing the previous time the same defect was fixed, and
  it cost 54 sessions under routed OOB.
- **There is no schema validation in 4.3.7.** Measured:
  `/api/extras/config-context-schemas/` returns **404**, there is no `jsonschema` anywhere
  under `netbox/extras/`, and `ConfigContext.clean()` enforces exactly one thing —
  `type(self.data) is dict`. A context declaring `{"vxaln": {...}}` saves, merges,
  renders and deploys, and the feature is silently absent. JSON-schema validation arrives
  in **NetBox 4.4** via `ConfigContextProfile`; the deployed version is one minor release
  short of the only thing that would make this safe to hand to a person.
- **The merge engine has a silent-wipe primitive.** `utilities/data.py:22-32`'s
  `deepmerge` recurses into dicts but **replaces lists wholesale**, and — because the
  guard is `val and isinstance(val, dict)` — **an empty dict `{}` at a higher weight
  deletes the entire merged subtree beneath that key.** A per-role context cannot append
  one entry to a global list; it can only restate the list. For a layer whose whole job
  is composing table fragments from several scopes, that is the wrong composition rule.
- **The scoping dimensions this fabric populates are not the ones the design needs.** Of
  13 available dimensions, measured live: `sites` = 1 (degenerate — scoping by site is
  scoping by everything), `roles` = 15 (the genuinely useful axis), `device_types` = 9,
  and **`platforms`, `tags`, `tenants`, `clusters` and `locations` are all 0**. There is
  no `racks` dimension and no per-device dimension.
  `network-automation-design.md:110` specifies "per-fabric via tags (MTU, ECMP)" and
  there are no tags. Adopting contexts means first seeding objects whose only purpose is
  to be a selector.
- **`seed.py --reset` does not delete them, and that is worse than if it did.**
  `reset_topology()` (`:533-549`) deletes cables, IPs, site-scoped devices and prefixes,
  and its docstring says it keeps roles, device types and custom fields. Config contexts
  survive completely — and so do their scoping targets. Reset exists because "addressing
  offsets differ when SWITCHING profiles — a clean slate avoids /31 conflicts". A feature
  context would become **the one part of the SoT that a clean slate does not clean**,
  silently reapplying a previous profile's intent to a rebuilt fabric with every stage
  reporting success. Meanwhile `local_context_data` *is* destroyed, because it is a column
  on a deleted device.
- **They are not in git.** `t01-provenance.sh` compares workstation git against host files
  and is the only trustworthy drift signal in this project; a context is on neither side.
  NetBox does offer `data_source`/`data_path` sync with a `git` DataSource type — but
  measured, **0 data sources exist**, and NetBox's git sync is a pull performed by the
  worker container on the ops host, which meets the same no-credential wall that forced
  the tar+scp deploy path (CLAUDE.md §4).
- **`model_sot()` cannot see them.** `render_fabric_ztp.model_sot()` (`:433-522`) fakes
  the NetBox surface from the profile so the real render path runs on a workstation with
  no NetBox, no image and no fabric. It exists because "the PORT defect survived three
  fabric builds — the only place it could be observed was the place where observing it
  costs a rebuild." A declaration living only in the database is invisible to that path,
  so the offline test would cover the derived half and not the declared, new, untested one.
- **`seed.py` has no update path and no delete path.** The bulk seed is strictly additive
  (`:360-477`); changing a field in the profile changes nothing in NetBox. A context could
  be created once and never corrected without `--reset` — 6002 sequential DELETEs (§7).

**Two findings run the other way and should be recorded honestly.** First, cost is not an
objection: pynetbox never sends `exclude=`, and NetBox 4.3's device serializer includes
`config_context` by default, so **`read_netbox()` already fetches and discards it on every
device.** Measured A/B, interleaved, 124 devices: **+26 to +47 ms, 10–13%** on a call that
is 0.4 s of a 24-minute build. Second, `ConfigContext` is a `ChangeLoggedModel`, so an
edit does bump `/api/core/object-changes/` — which `sot_revision()` already captures.

So the recommendation is: **not yet, and not for the derived half ever.** Revisit after
three things, in order of hardness: (1) upgrade to NetBox ≥ 4.4 for `ConfigContextProfile`
schema validation; (2) ban `local_context_data`, enforced by a committed test asserting it
is null on every device; (3) make `reset_topology()` delete contexts. Until then the
declared half rides git-held render data, which has none of these problems and costs
nothing to build.

**The exception, and it is a real one:** config contexts are the correct home *today* for
the **operational overlay** already designed in `network-automation-design.md:262-269` —
per-device `active | quarantined | maintenance` with owner, reason and expiry. There
mutability is the point, human authorship is the point, the values are scope-uniform
literals rather than derived, and the existing field-level ownership rule already covers
it: "operator-owned fields (and operational overrides such as maintenance state) are never
overwritten by a seed." Two channels, two owners, two rules. Do not conflate them.

**NetBox config templates — rejected outright, and not close.** Measured: there is **no
`jinja` import anywhere in `gpufab-network/tools/`**, and the four `.j2` files under
`templates/` are referenced by nothing in either repo. So this is not "move our Jinja into
NetBox", it is "rewrite a working, commented, unit-testable Python renderer as Jinja and
then put the Jinja in Postgres." That deletes `model_sot()`'s offline path, removes the
render from `render_revision`'s code fingerprint — the mechanism built specifically because
"identical input through changed code is a staleness an input fingerprint is blind to; that
one cost 178 BGP sessions across three fabrics" — and moves derivation logic out of the
review gate. The gain is a UI preview.

**A plugin/registry of feature modules, alone — rejected as insufficient.** A registry
makes the renderer generic and leaves `_OWNED_WRITE` and `expected.py` hand-maintained.
That has fixed one third of the problem and will read as success. The registry is
necessary; the manifest is what makes it work.

**Declarative table fragments merged by a composer — accepted, and this is the
recommendation.** With the addition that the composer must emit its provenance, because
a merge that does not record who contributed what cannot detect the collision in §3.4
and cannot produce the manifest in §4.

**Do nothing, plus a checklist and a test that fails when `expected.py` was not
updated — rejected, but read this paragraph before dismissing it.** It genuinely wins on
cost and it deserves to be taken seriously. It fails for one reason: *you cannot write that
test.* To fail when `expected.py` was not updated, something must know what the renderer
emitted and compare it against what the oracle accounts for. That comparison needs a
computed record of the emitted set — which is the manifest in §4. **The cheapest credible
version of "do nothing" requires the same artifact the full design is built on.** So the
honest conclusion is not "do nothing wins", it is "do phase 0 and stop if you like": the
manifest is worth building even if no feature is ever declared, because it closes a live
defect and it is the precondition for the checklist.

A checklist would also fail on its own terms. #56 was a missed step in a procedure someone
knew; §5.11 was designed correctly and then found two errors in implementation, both of
which "would have produced a broken fix if followed literally". This project's failures are
not failures of intent.

---

## 2. Three enumerations, and what one feature would do to them

Trace VXLAN through the pipeline as it exists. This is not hypothetical; each step is a
read of committed code.

**Enumeration 1 — the renderer.** `device_config()` (`render_fabric_ztp.py:525-695`) is a
fixed sequence: deep-copy the 19-table base snapshot, `apply_snmp`, `DEVICE_METADATA`,
`frr_render.to_config_db`, `apply_port_table`, `MGMT_*`, `auth_tables`. Fourteen tables
carry intent. Adding `VXLAN_TUNNEL` means editing this function. That much is expected.

**Enumeration 2 — the push, and this is where it goes wrong quietly.**

`already_applied()` (`interim_deploy.py:731-748`) is a one-line delegate to
`config_landed()`, which compares exactly `_OWNED_WRITE`, then `DROP_TABLES`, then
`FEATURE.snmp.state`, then `_MD_KEYS`, then falls through to `return True, "ok"`.

- `VXLAN_TUNNEL` is in none of those lists. **The device is reported in-sync and
  skipped** — and because `config_landed` is deliberately the same predicate asked twice
  ("before a push it answers 'is a reload needed?'; after a reload it answers 'did the
  reload work?'"), a `config reload` that dropped the VXLAN tables entirely still prints
  `reloaded+VERIFIED`.
- `VLAN`, `VLAN_MEMBER` and `VLAN_INTERFACE` are in `DROP_TABLES`. `build_switch_config`
  strips them from the running config (`:480`), and `config_landed` hard-fails any device
  still carrying one (`:719-721`). That rejection is pinned by a committed unit test
  (`test_config_landed.py:214-216`).

So on a cold build with VXLAN added to the renderer only: **ZTP applies the VLANs
correctly, the stage-50 backfill deletes them minutes later, and both stages report
success.** That is #58's shape exactly — a correct config, silently rewritten by the next
thing that touched the box, with artifact-level comparison agreeing throughout.

**Enumeration 3 — the oracle.** `expected.py compute()` returns a dict literal of 26
keys. There is no registry, no `--list`, and nothing imports the module. Fifteen of the
26 keys are referenced by no test at all. A VXLAN module contributing VNI counts, VTEP
counts or EVPN session counts must add keys by hand, and **nothing exists that would
notice if it did not.**

And a fourth list nobody counts: `drift.py`'s `normalise()` drop-set (`:85-90`), which
already silently excludes `FEATURE`, `SNMP` and `SNMP_COMMUNITY` from drift detection.

Four lists, in two repos, that must agree and have no mechanism forcing them to.

---

## 3. What a feature module is

### 3.1 The four contributions, and why they must ship together

A module owns four things, in one file, reviewed as one change:

| contribution | consumed by | what it prevents |
|---|---|---|
| **allocation** — identifiers from model-owned pools | `fabric_model` | two derivations of one VNI (#79) |
| **config** — the tables it owns, per device | the composer | the renderer growing another `if` |
| **oracle** — expected counts *and the constraint each must satisfy* | `expected.py` | #56: a number printed and never compared |
| **observation** — what to read on the box, and the count it must yield | `tests/` | #58: renders, applies, never programs |

Splitting them is the failure. Every feature added by hand here has required someone to
remember the last two, and the record is that they do not get remembered: SNMP needed
§5.11 plus two corrections found in implementation, and still measured 0/46 in-sync on
its first cold build after measuring 46/46 warm three times.

### 3.2 The interface, concretely

One module per file under `gpufab-network/tools/features/`, discovered by directory scan
rather than a registry list — the same rule `render_revision.py` already uses for its data
globs, and for the same reason: "a hardcoded list that silently stops covering a new data
file is the same defect class this closes."

```python
NAME     = "evpn"
REQUIRES = ("vxlan_dataplane", "evpn_control_plane")   # keys in nos_catalog capabilities
POOLS    = ("vni", "vlan")                             # identifier namespaces claimed
SCHEMA   = {"fabrics": list, "segments": list, "vni_base": int, "anycast_gw": bool}

def declare(profile) -> dict:
    """Validate and normalise this feature's profile block. An unknown key inside
    the block raises ModelError naming it. Returns {} when the feature is off."""

def allocate(model, decl) -> dict:
    """Every identifier this feature needs, drawn from the pools it claimed. This
    is the ONLY place a VNI, VLAN id or overlay address is computed."""

def applies_to(device, model, decl) -> bool:
    """Selection by fabric and tier from the model — never by name substring.
    (fabric_model recovers `plane` by matching '-p2-' in a device name; that is a
    trap, not a pattern to copy.)"""

def config_db(device, model, alloc) -> dict:
    """Only the tables this module owns. The frr_render.to_config_db contract."""

def frr_conf(device, model, alloc) -> list[str]:
    """Stanzas for the second artifact, where config_db cannot express it (§5.5)."""

def expected(model, alloc) -> list[dict]:
    """Oracle entries. Each is {key, value, must, because}. An entry with no
    `must` is REFUSED — see §3.5."""

def observe(device, model, alloc) -> list[dict]:
    """What to read ON THE BOX. Each is {table, layer, command, min_count, why}.
    Every table config_db() emitted must appear here, or be listed in UNVERIFIED
    with a reason — see §3.6."""
```

`declare`, `allocate` and `applies_to` run inside `fabric_model`; `config_db` and
`frr_conf` inside the composer; `expected` inside `expected.py`; `observe` inside the
test suite. **One file, four consumers, no second copy.**

### 3.3 Where a feature is turned on

In the profile — `gpufab-network/design/profiles/scale/*.yaml`, not
`gpufab-platform/profiles/*.yaml`, which are the legacy `topology.dgx_count` shape and
fail `expected.py` with `KeyError: 'fabric'`.

```yaml
features:
  evpn:
    fabrics: [frontend]           # `fabrics`, not `planes` — see §5.1
    segments:
      - {name: compute,      vlan: 100}
      - {name: provisioning, vlan: 200}
    anycast_gw: true
addressing:
  envelope:
    vni: 64                       # how many segments this fabric may grow to
                                  # WITHOUT renumbering the ones already there
```

The `envelope` placement is deliberate and follows the existing rule. `s1-512.yaml`
already declares a growth envelope so that "growing the fabric adds rather than
rewrites", and "exceeding the envelope is a named error, not a silent renumber."
Identifiers a feature allocates need exactly that property, for exactly that reason.

### 3.4 Precedence: derived refuses declared

**Rule: a declaration may add a table, and may add keys within a table it owns. It may
never write a key another contributor derived. A collision is fatal at render time and
at seed time, and names both contributors.**

Not "derived wins with a loud report". A loud report over 46 devices is noise, and this
project has a documented history of measuring something and continuing — "the 'measured
something, ignored the answer' pattern that produced most of the bugs in this project's
history" (`render_fabric_ztp.py:255-258`).

The rule is enforceable because the composer records provenance at `(table, key)`
granularity as it merges. It is therefore **computed, not maintained** — there is no
deny-list of derived tables to keep in step, which would be enumeration number five.

What about a feature that genuinely needs to extend derived state — EVPN activating an
address family on BGP sessions the model derived? That is not a declaration. It is a
**parameterised deriver**: the profile turns EVPN on, and the routing contributor emits
the address family, because the AF references the ASN, the loopback and the peer list,
all of which the model owns. The rule that decides which channel a thing belongs in:

> **If the content references a derived value, it is derived. If it is a literal the
> model has no opinion about, it may be declared.**

A declaration may *reference* a derived value — `${device.loopback}`, `${segment.vni}` —
resolving against a frozen read-only view of the model. It may not *compute* one. A
reference cannot disagree with the model; an expression can, and an expression language
in the SoT is a second allocator by another name. `oob_plan.py:166-169` states the
principle in one line: "Two allocators for one number is how this project produced the
32-port PORT table; the model stays the only allocator."

**The composer's merge rule must be written down, and NetBox's is the counter-example to
avoid.** `utilities/data.py:22-32` in the deployed NetBox recurses into dicts, **replaces
lists wholesale**, and — because its guard is `val and isinstance(val, dict)` — lets an
empty dict `{}` at higher precedence **delete the entire merged subtree beneath its key**.
A silent-wipe primitive in the middle of a merge engine is exactly the shape of defect this
project keeps producing. This composer's rule instead:

- merge at `(table, key)` granularity, never deeper — a `config_db` key's value is a flat
  field map and is taken whole from its owner;
- **no implicit deletion.** Absence means "I contribute nothing here", never "remove
  this". Removal is explicit, and it is the `absent` set in §4;
- collision is an error, not a precedence question (above).

### 3.5 Validation: three layers, and only one exists

**A correction to the framing that produced this document.** It has been said that
`config reload` performs no YANG validation and only `config replace` does. **That is
false on this image, and this repository holds the measurement.**
`render_fabric_ztp.py:636-647` records that `sonic-mgmt-interface.yang` carries a `must`
condition on `gwaddr`, that "`config reload` and ZTP's `configdb-json` plugin both run
that check before applying a file", and that on 2026-07-27, **0 of 48 served artifacts
passed and 48 of 48 passed once `gwaddr` was added.** Omitting it had silently disabled
the entire ZTP path fleet-wide.

This materially lowers the risk of opening the config surface, and it should be said
plainly rather than argued around. But YANG validates **shape, not sufficiency** — the
32-port PORT table was perfectly valid YANG. So three layers are needed and the middle
one is the one that does not exist:

| layer | catches | status |
|---|---|---|
| **shape** — YANG | a malformed or unmodelled table | **exists**, `t17-mgmt-vrf.sh:277-307` |
| **sufficiency** — the oracle | a table that is valid and wrong-sized | **missing** — this is #56 |
| **programming** — the box | valid, right-sized, never reached the ASIC | **missing** for anything but BGP |

The shape layer is better than it looks and is worth reading before designing anything.
`t17` ships rendered artifacts to a switch, loads them through
`sonic_yang.SonicYang("/usr/local/yang-models")`, runs `validate_data_tree()`, **and then
fails if `sy.tablesWithOutYang` is non-empty** — a table with no YANG model at all is
already a failure, with `bgpraw` popped as the one known exception. A generic declaration
channel plugs straight into a check that already fails closed on exactly the thing a
generic channel makes newly possible.

Two changes it needs. It runs *on a switch*, so it needs a fabric and it samples; and it
`t_skip`s when `/usr/local/yang-models` is absent. **Move it to render time on the
workstation** — `sonic-yang-models` is installable there — so a malformed declaration is
refused before it is served to anything, not discovered on a subset of a built fabric.
That single move is what makes "open the whole surface" safe rather than reckless.

The sufficiency layer is what `expected()` returning `{key, value, must, because}` is
for. `expected.py --check` evaluates every constraint and exits non-zero on any
violation. Applied retroactively, `max_ports_per_switch` gains
`must: "<= platform_ports"` and #56 fails at derive time, on a workstation, before
terraform — instead of printing 70 and exiting 0 for the life of the project. An entry
with no `must` is refused, because a number nothing compares is the exact shape of the
defect.

### 3.6 Verification: the mechanism cannot make it free, but it can make its absence loud

**Tier 1 — universal, and already paid for.** Every table in the manifest is compared
against the box's own `sonic-cfggen -d --print-data`. This is `config_landed` with its
hand-written tuple replaced by the manifest. Zero new device access, and it immediately
covers `MGMT_VRF_CONFIG`, `mac` and `docker_routing_config_mode`, which nothing compares
today.

**Tier 2 — per table, declared once, in `observe()`.** A CONFIG_DB entry proves the
config landed, not that it programmed. The module names the deeper layer and the count it
must yield:

```
VXLAN_TUNNEL     -> STATE_DB  VXLAN_TUNNEL_TABLE|*                     >= 1
VXLAN_TUNNEL_MAP -> APPL_DB   VXLAN_REMOTE_VNI_TABLE / tunnel maps     >= len(segments)
(evpn control)   -> vtysh     show evpn vni json                       == len(segments)
(dataplane)      -> ASIC_DB   ASIC_STATE:SAI_OBJECT_TYPE_TUNNEL*       >= 1
```

The primitives exist but are in the wrong place. `sonic-cfggen -d --var-json <TABLE>` and
`vtysh -c "... json"` are used across `tests/*.sh`. **`sonic-db-cli` appears nowhere in
either repository**; the only redis access anywhere is in `tests/fidelity/remote/`, which
already does `redis-cli -n 1 --scan --pattern 'ASIC_STATE:*'` and
`redis-cli -n 1 hget ... SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID` (`fv-cap-01.remote.sh:49,137`).
So the ASIC-layer readback exists, in a framework `verify.sh` does not run — `grep -n
'fidelity\|fv-cap\|run-f0' tests/verify.sh` returns nothing.

**Tier 3 — the absence is what fails.** A table in the manifest with no tier-2 locator is
recorded as `unverified` with a reason, and the count of unverified tables is asserted
against a committed allow-list. Forgetting becomes a failing test rather than a silent
gap. This is `t_zero`'s trick applied one level up: a check that observed nothing is a
failure, so a table nothing observes must be a failure too.

**And one hole in `lib.sh` must be closed first, because a feature axis drives straight
through it.** `t_count "label" 0 0` **passes.** The "measured NOTHING, which is not a
pass" guard fires only when the *expected* side is non-zero (`lib.sh:30-40`). A profile
with the feature off produces zero expected and zero observed, and the assertion passes
having looked at nothing — which is precisely the state most profiles will be in most of
the time. Either `t_count` learns to refuse `0/0`, or every module must declare a non-zero
expectation or an explicit `unsupported`. `FIDELITY-VERIFICATION-PLAN.md:57-59` already
states the doctrine: "a switched-off phase is reported as `unsupported` with a reason,
never silently dropped."

`t28-oob-routed.sh:97-107` is the pattern to copy: feature off does not mean skip, it
means **assert the machinery is absent** — `t_zero "local: no DHCP relay container"`.

---

## 4. The manifest

One artifact, computed by the composer, written beside `config_db.json` in the ZTP root —
which is already the discovery surface that `t11`, `t13`, `t15`, `t17`, `t18` and `t23`
use to find switches.

```json
{
  "schema": 1,
  "device": "dc1-pod001-fr-leaf01",
  "render": "<render_revision fingerprint>",
  "tables": {
    "INTERFACE":      {"owner": "routing", "keys": 96, "verify": "config_db"},
    "PORT":           {"owner": "ports",   "keys": 64, "verify": "config_db"},
    "MGMT_VRF_CONFIG":{"owner": "mgmt",    "keys": 1,  "verify": "config_db"},
    "SNMP_COMMUNITY": {"owner": "snmp",    "keys": 1,  "verify": "config_db",
                       "secret_keyed": true},
    "VXLAN_TUNNEL":   {"owner": "evpn",    "keys": 1,
                       "verify": "state_db:VXLAN_TUNNEL_TABLE|*"},
    "VLAN":           {"owner": "evpn",    "keys": 2,  "verify": "config_db"}
  },
  "absent": ["ACL_TABLE", "ACL_RULE", "PORTCHANNEL", "TELEMETRY", "RESTAPI"],
  "unverified": []
}
```

Three consumers, one source:

- **`interim_deploy`** replaces `_OWNED_WRITE` with `tables` and `DROP_TABLES` with
  `absent`. `_MD_KEYS` becomes the key list the metadata contributor recorded.
- **`expected.py`** takes its declared-table counts from `tables`, so an emitted table
  with no oracle entry is detectable.
- **the test suite** reads `verify` to know what to read on the box, and `unverified` to
  know what nobody is reading.

`absent` is the only part not derived from this render, and it is honest about that: it is
two things unioned — a small declared set of tables the fabric intends not to run (a
policy statement, which is what `DROP_TABLES` should always have been), and the *diff*
against the manifest the device already carries. The push writes a copy to
`/etc/sonic/gpufab_owned.json`, so removal is computed as box-manifest minus
artifact-manifest. A device with no manifest — a fresh ZTP boot — falls back to the
declared set, which is today's behaviour and is safe.

That diff is also the answer to half of #88 (§7): **a table that leaves the render is
detectable, and a merge-only push that fails to remove it is detectable.**

Three provenance gaps must be closed at the same time or the manifest lies:

- **`render_revision.DATA_GLOBS` does not cover the profiles directory** (`:113-130`).
  A feature toggle changes every rendered artifact while `render_revision` reports the
  transform unchanged — and `sot_revision` sees nothing either, because a profile edit
  writes nothing to NetBox until a seed runs. Both fingerprints say "current" over
  artifacts that are not. One line. Declaring features in the profile is what makes this
  gap load-bearing rather than latent, so it must land in the same change.
- **`sot_revision.is_current()` reads only half of what the record carries.**
  `sot_revision()` captures a changelog id *and* a shape fingerprint, but the verdict
  compares only the fingerprint — an inline generator over five device fields plus cables
  (`:105-113`) — and deliberately ignores the changelog id. Any SoT change outside those
  five fields is recorded and not judged.
- **`drift.py`'s render-staleness verdict never reaches its exit code** (`:194` uses only
  the SoT fingerprint), so a stale-renderer fabric exits 0.

---

## 5. VXLAN/EVPN, worked end to end

### 5.1 Which fabric carries it — frontend, and the word is "fabric"

**Terminology first, because getting it wrong here lands the ambiguity in a profile key.**
This architecture uses "plane" for three unrelated things: the four *fabrics*
(backend/frontend/storage/oob); the backend's *sub-planes* (`p1`/`p2`, `rails × planes`);
and §5.5's three *substrate planes*, of which Plane 2 is the VXLAN that stitches fabric
hosts together. The feature block must say `fabrics: [frontend]`. Note also that
`fabric_model` does not carry `plane` as a field at all — it is recovered by matching
`-p2-` inside a device name (`fabric_model.py:886-888`, `:1423-1432`), which a feature's
`applies_to()` must not imitate.

**Frontend, for four reasons:**

1. **The backend is pure L3 by design and by measurement.** Rail-optimised, `/31` +
   eBGP + ECMP end-to-end, BGP on the endpoints themselves, converging 1464/1464 with no
   overlay of any kind. An overlay there adds encapsulation to RoCE traffic whose entire
   point is that it does not have any, and there is no tenancy inside a rail to separate.
   `gpufab-sim-design.md:227` records it as risk R3, "**Designed out** — pure L3 + plain
   VLAN frontend".
2. **Storage is the same pattern**, plus a service VIP (`10.255.2.100/32`) advertised by
   the active DDN controller — an anycast mechanism that already works without an overlay.
3. **The frontend is the only fabric that already carries L2.** VLANs 100 and 200, a
   single-active SVI gateway, host active-backup bonds standing in for the MCLAG that
   `network-automation-design.md` R4 accepts as absent. `s1-512.yaml` already declares
   `frontend: {leaves: 3, spines: 2, peer_links: 1}`, and `fabric_model` comments that
   peer link as "a single-active SVI gateway needs one; a pure-L3 fabric does not. Data,
   not an assumption." EVPN/VXLAN is the natural replacement for the two things listed as
   v1 non-goals, on the one fabric shaped to take it.
4. **The segments are already declared and implemented nowhere.**
   `gpufab-network/design/policy/addressing.yaml` holds
   `frontend_vlans: [{id: 100, name: compute, ...}, {id: 200, name: provisioning, ...}]`
   with prefixes and gateways. Nothing reads that file — the only reference in either repo
   is `t01-provenance.sh`'s checksum sweep. A declared policy that nothing consumes is
   worse than none, and this design is the thing that would consume it.

Tenant separation is a *motivation*, not a *justification*: §5.8 is explicit that the sim
has service separation and not a security boundary, several of its items remain open, and
a feature must not claim isolation it cannot demonstrate negatively.

The mechanism must still permit `fabrics: [backend]`. A simulator's job includes
reproducing what a customer might do, including the unwise. The model refuses
combinations that are *impossible* (§5.7), not merely inadvisable.

### 5.2 Do not name the module `vxlan`

The token is taken, and taking it back would corrupt a working measurement.
`gen_topology._vni()` (`clab/gen_topology.py:176-189`) allocates
`100 + sha256(...) % 16_000_000` for containerlab's cross-host link transport on UDP
14789; `t25-reconcile.sh:100,202` counts `sum(1 for x in l if (x.get("type") or "") !=
"vxlan")` to avoid double-counting the two topology entries a cross-host link produces;
and `reconcile.py:121-128,364-373` partitions local from remote on the same key. **Name
the module `evpn`.**

### 5.3 What the model allocates

One pool, bounded by the envelope, allocated once:

```
vni      = vni_base + vlan_id        drawn from the `vni` pool, bounded by
                                     addressing.envelope.vni, and asserted
                                     < 2**24 by expected.py --check
vtep_src = device.loopback           REFERENCED, never recomputed
vlan_id  = declared per segment      validated 2..4094, unique within the fabric
anycast  = segment prefix .1         from the addressing plan, one derivation
```

`vtep_src` is the one to watch. The VTEP source address is the device's Loopback0, which
`Addressing.loopback()` already owns (`fabric_model.py:443`). A module that recomputes it
— even correctly — is #79. It must reference it.

### 5.4 What the module contributes

Per frontend leaf (the VTEPs), with `expected()` counts derived from
`len(segments) × len(vtep_devices)`, never written by hand:

```
VLAN|Vlan100                        vlanid
VLAN_MEMBER|Vlan100|Ethernet<n>     tagging_mode, per host-facing port
VLAN_INTERFACE|Vlan100              and |Vlan100|<anycast>/24 when anycast_gw
VXLAN_TUNNEL|vtep                   src_ip = ${device.loopback}
VXLAN_EVPN_NVO|nvo                  source_vtep = vtep
VXLAN_TUNNEL_MAP|vtep|map_<vni>_Vlan100    vni, vlan
```

Frontend spines carry no VTEP and need **no retention directive at all**. This
paragraph used to specify `retain route-target all`; both halves of that were
wrong and #117 measured each on `gpufab-s11`.

*The command does not exist here.* `vtysh -C` (dryrun — parses, applies nothing)
inside `dc1-pod001-fr-spine01`'s own `bgp` container, which is the FRR 10.3 that
actually reads these files: `retain route-target all` and
`bgp retain route-target all` are both `% Unknown command` under
`address-family l2vpn evpn` **and** at `router bgp` level, exactly as the
implementation's `route-target all` was. The string is in the shipped `bgpd`
binary, but only as the VPNv4/VPNv6 knob under `address-family ipv4 vpn`, where
it is accepted (`rc=0`). FRR 10.3 has no retention command under `l2vpn evpn` at
any node.

*And nothing is discarded without it.* With that line never once accepted by
anything and the overlay converged 16/16, both spines hold the **whole** overlay
table — 6 type-3 routes across 6 RDs, the same six every VTEP holds — while
configuring **zero** VNIs and therefore having no import RT to match on. They
re-advertise it too: each leaf receives 4 of the 6 from each spine peer and reads
2 remote VTEPs per VNI. FRR does not RT-filter the global `l2vpn evpn` table;
route targets there select what is imported into a VNI or a VRF, and a transit
device has neither.

### 5.5 What `config_db` cannot express — and this is the part to design for

The EVPN **control plane** is the piece most likely to be unexpressible in `config_db` on
this image, and the precedent is exact. `nos_catalog.yaml` records that "SONiC translates
`config_db` → FRR via `bgpcfgd`. That translator is the constraint, not FRR: the daemon
underneath is FRR and supports far more than `config_db` can express." It then records
`bgp_unnumbered_via_config_db: false  # upstream sonic-buildimage#26960` — `BGP_NEIGHBOR`
is typed `inet:ip-address` in YANG, so an interface key is rejected, and the project had
to build a **second artifact** (`frr.conf`) and a **second stage** (`55-unnumbered.sh`)
to carry what `config_db` could not.

So the claim "`config_db` is the universal interface, therefore any capability is just
another table" is **already falsified by this project's own experience**, in the same
subsystem EVPN needs. The design must accommodate that rather than assume it away, which
is why `frr_conf()` is in the module interface beside `config_db()`. The rule
`55-unnumbered.sh` states for when a capability earns its own stage — "this stage delivers
a SECOND artifact to a location nothing else writes to, and that is a genuinely different
operation from pushing `config_db`" — is the rule to apply.

It is also worth noting that this is not solely a SONiC question. `nos_catalog.yaml`
already declares Cumulus (`artifact: frr.conf + interfaces`), FRR (`frr.conf`) and Arista
EOS (`startup-config`). The mechanism is "declared artifact fragments merged by a composer
with computed provenance"; `config_db` is its SONiC instance, not its definition. Building
only the `config_db` composer today is correct — building it in a way that assumes
`config_db` is the only artifact type is not.

### 5.6 What must be measured before any of this is built

The image ships `vxlanmgrd` — it appears in the base snapshot's `LOGGER` table — but the
base `FEATURE` table has no VXLAN entry, and SAI-VS's tunnel support is not something to
assert from documentation. `nos_catalog.yaml`'s own header sets the standard: "capabilities
marked verified were established on the running image; others are from vendor docs and
should be verified before being relied on."

So the module's first deliverable is not code. It is a `deploy/checks/` probe that answers,
on one live leaf pair:

1. Does `config reload` accept `VXLAN_TUNNEL` and `VXLAN_TUNNEL_MAP` under YANG?
2. Does `vxlanmgrd` create a `STATE_DB` tunnel entry?
3. Does anything appear in `ASIC_DB` under `SAI_OBJECT_TYPE_TUNNEL`?
4. Does a frame actually cross — the `FV-CAP-02` pattern, capturing on the *receiving*
   side with `tcpdump` proven up before the send?
5. Can `bgpcfgd` be made to activate `l2vpn evpn`, or does it need `frr.conf`?

Whatever the deepest observable layer turns out to be, **it is recorded in `nos_catalog`
as a measured capability and it becomes the module's tier-2 locator.** If VS programs no
tunnel into ASIC state, the module says so, verifies at the highest layer that *is*
observable, and the fabric records a fidelity limitation — rather than passing on
`config_db` alone and calling it working. §5.11's judgement applies: a fidelity gap
honestly recorded beats a check that measures the wrong layer.

### 5.7 The nested-encapsulation budget, which is a derive-time check

The simulator's own transport is VXLAN. On a sharded fabric a cross-host link is a
substrate VXLAN tunnel on UDP 14789 over `gpufab-fabric-vpc` at MTU 8896 (§5.5). A
simulated overlay on UDP 4789 rides *inside* that. With the frontend's documented
`host_data: 9000`, a 9000-byte frame plus a 50-byte overlay header needs 9050 bytes of
emulated wire, which needs more than 8896 bytes of substrate. **It does not fit.**

Single-host sims are unaffected — those links are ordinary veths, and `gpufab-s11` is one.
So this is not a blocker today, and that is exactly why it must be a *model* check rather
than something discovered at S2: a profile that enables an overlay on a fabric whose links
may be sharded, with an MTU that does not survive double encapsulation, should raise a
named `ModelError` at derive time. It is the same shape as the port budget, and it is the
kind of thing that otherwise renders, applies, and drops large frames on some links only.

Note the MTU policy itself lives in `design/policy/addressing.yaml`, which nothing reads
(§5.1). Making the budget checkable means making that file an input rather than a
description — a small, contained piece of the same work.

---

## 6. The GitOps round trip

The requirement is the full loop, exercised:

```
git commit -> NetBox (SoT) -> render -> ZTP / push -> device -> observed on the device
```

### 6.1 What the loop actually is today — an arc, not a circle

This must be stated before anything is designed on top of it, because the shape is not
what the pillar summary claims. `gpufab-sim-design.md:30` calls the GitOps pillar "real
(loop verified live)". That claim rests on one run on 2026-07-25, of one leg, on a host
that no longer exists.

**The leg that works, and works well:** a change in NetBox fires an Event Rule →
`bot/webhook_relay.py` verifies the HMAC, debounces 60 s, and POSTs
`repository_dispatch: netbox-change` carrying `sim_id` → `.github/workflows/render.yml`
routes to that sim's runner → `tools/render.py` renders every switch through the *same*
`render_fabric_ztp` builder the ZTP path uses → a PR is opened with the config diff.
Measured 2026-07-25: PR #5, 30 configs, ~80 s. The sim routing is hardened three
independent ways after #F5 — the `sim-<id>` runner label, a self-assertion against
`/opt/gpufab/instance-id` that refuses a mismatch, and a sim-local NetBox credential with
no global fallback.

**Everything downstream of that PR is 2026-07-23 scaffolding that has never been touched.**
Three of the four workflows have exactly one commit each:

- `validate.yml` iterates `find rendered -name config_db.json`. `git ls-files rendered`
  returns exactly one file, `rendered/README.md`. **The loop body never executes and the
  job passes.** Its third step is `echo "... placeholder pass"`. A green check that
  measured nothing — the failure this project has a whole doctrine about.
- `deploy.yml` filters on `rendered/**`; the render writes to
  `instances/<sim-id>/rendered/**`. GitHub path filters anchor at the repo root, so **it
  cannot fire on the only PRs the system produces.** If it did, its apply step is
  `exit 1  # fail loudly until P6 implements the apply`, and `playbooks/p6-gitops.md` does
  not exist. Its post-check calls `tools/check_bgp.py`, which is three lines and exits
  with "not implemented yet".
- `drift-check.yml` runs `drift.py --post-metrics --update-issue`. **Neither flag
  exists** — `drift.py` defines `--root`, `--device`, `--json` — so argparse exits 2. It
  has never done anything but fail, every six hours. It also calls bare `python3` while
  `drift.py` imports `pynetbox`, the identical defect already fixed in `render.yml`.
- The nightly render is a no-op: its matrix falls back to `fromJSON(vars.SIM_IDS || '[]')`
  and **`SIM_IDS` is provisioned by nothing** in terraform.

**And upstream of NetBox there is no arc at all.** `seed.py` is invoked from exactly one
place — `deploy/30-seed.sh` — which runs only inside `deploy.sh`. No workflow, no relay,
no bot ever calls it. **A profile change committed to git never reaches the SoT until a
human re-runs a deploy stage.**

That is the answer to "which link in the chain is missing", and it is two links, not one:

> **commit → NetBox does not exist. merged-artifact → device does not exist.**
> NetBox → PR exists and works. Render → device exists, but only inside a deploy stage a
> human runs.

The only thing outside a deploy stage that reaches a device is `bot/actions/reapply.sh`,
which is triggered by an Alertmanager alert, ships with `BOT_DRY_RUN=1`, and renders
straight from NetBox to the box — bypassing git entirely.

One more thing worth knowing before planning against it: **the Actions runner is probably
not registered on `gpufab-s11`.** `setup_runner.sh` needs a registration token from Secret
Manager `gpufab-gh-runner-token`, and **no terraform resource declares that secret**. Stage
90 is in `NONFATAL`, the stage degrades rather than fails, and health treats the runner as
`optional: true` — so a build that never registered it reports healthy. Determining this
takes one `systemctl is-active gpufab-runner`, and by doctrine that belongs in a committed
test, not an ad-hoc SSH.

### 6.2 What is committed, and what reconciles drift

**Git holds the declaration.** Under `gpufab-network/design/features/`, as render data
beside `vs_base_config_db.json` and `vs_port_sets.json` — which is where the renderer's
other inputs already live, which `render_revision`'s whole-directory glob rule already
covers ("a new data file dropped into either is covered the moment it exists"), and which
`t01-provenance.sh` already checksums under its `design/` pattern.

That is a deliberate departure from "NetBox is the source of truth", and it is narrower
than it sounds. §5.10 already draws the line: "**Git holds design INTENT** — the cabling
plan. It says what should be built. **NetBox is the operational RECORD** and the source
for rendered config." A feature declaration is intent. The *consequences* of it — the
interfaces, addresses and VLAN objects it implies — are record, and those go to NetBox
through `seed.py` exactly as everything else does.

**What reconciles drift, per channel:**

| channel | owner | on divergence |
|---|---|---|
| feature declaration (git) | git | there is nothing to diverge — the renderer reads the file |
| derived SoT objects (NetBox) | `seed.py` from the model | reconciled on seed; `48-reconcile` audits wiring against the box |
| operational overlay (NetBox context) | operator | never overwritten (§1.4) |
| device config | the render | `config_landed` against the manifest (§4) |

Once the config-context projection lands (post-4.4), the rule for it is: **a UI edit to a
git-owned context is drift — detected, reported, reverted on the next seed**; a UI edit to
an operator-owned context is an accepted workflow. Two contexts, distinguished by name and
weight.

Detection then needs one correction that is worth making regardless.
`sot_revision.sot_revision()` captures both a changelog id and a shape fingerprint, but
`is_current()` compares **only the fingerprint** and deliberately ignores the changelog id.
The fingerprint is an inline generator over five device fields plus cables
(`sot_revision.py:105-113`). So a context edit — or any SoT change outside those five
fields — moves a number the record carries and the verdict does not read. That is the
`render_revision` gap of §4 in the other direction, and it should land in the same change.

### 6.3 How it is exercised

The deliverable is one committed test — `t31-gitops-roundtrip.sh`. Reserve the number in
this document, because the `tNN` namespace is contended and `t27` and `t28` are already
spoken for.

It must close both missing links, and it can be built incrementally: the first version can
drive the stages directly and prove the observation half, before any workflow is fixed.

1. Change one declared value in a committed profile — add a third segment.
2. Drive the loop end to end: re-derive, re-seed, re-render, deliver by push or ZTP
   re-fetch.
3. **Read the switch.** `sonic-cfggen -d --var-json VXLAN_TUNNEL_MAP` must show the new
   map, and the tier-2 locator must show it programmed. Assert with `t_count` against
   `expected.py` — never a floor, never `0/0`.
4. Revert the commit and assert the change is **removed from the box**. This is what
   catches a merge-only push, and it is the smallest honest version of #88 (§7).

It runs on one sim. `gpufab-s11` is local mode, single host; no fleet and no routed sim
are required, and the design must not need them — §5.7's nesting constraint is the only
multi-host concern and it is a derive-time check.

The reason it must read the box rather than the artifact is the whole argument: in #58 ZTP
wrote a correct config, a `delayed` container rewrote it 45 seconds later, artifact-vs-intent
agreed the entire time, and only reading the device caught it.

**What "make the round trip real" costs beyond that test**, separated so the estimate is
honest about what is a design and what is a repair:

*Required for the round trip, and this design does not create them:*

- **commit → NetBox.** Something must re-seed on a merge to a declaration or a profile.
  The cheapest correct form is a `seed`-and-`reconcile` job on the sim's own runner, path-
  filtered on `design/**`, since only the sim host can reach its own NetBox. It must be
  idempotent — it already is, additively — and it must not run concurrently with a deploy.
- **merged-artifact → device.** `deploy.yml`'s path filter must become
  `instances/*/rendered/**`, its `exit 1` placeholder must become a call to the existing
  push, and `check_bgp.py` must stop being a three-line stub.

*Repairs that must land first or the loop lies about itself:*

- `validate.yml` lints an empty directory and passes. Point it at
  `instances/*/rendered/**` and give it a non-vacuity assertion — this is `t11`'s
  "0 mismatches out of 0 comparisons" lesson, in CI.
- `drift-check.yml` passes two flags `drift.py` has never accepted, on a broad
  `sim-host` label that would land on an arbitrary sim — the same defect `render.yml`
  already fixed.
- `render.py` writes **no `_provenance.json`**, so the GitOps path is the one path whose
  artifacts cannot say which SoT and which code produced them.
- `vars.SIM_IDS` and the `gpufab-gh-runner-token` secret are declared in no terraform.
- `t22:354-355` asserts "R9 stage 90 requires relay AND bot AND runner" against a line
  that names only relay and bot. It has passed under a false name since `1a092e6`, and it
  is the only thing in the suite that claims to cover the runner.

### 6.4 Ordering — the loop does not lead, it follows

§5.10 is settled and this design does not touch it. Physical topology is built from the
profile with no NetBox running (`gen_topology.py --from-profile`); `seed.py` populates
NetBox from the same profile; `48-reconcile` audits the booted wiring against the record;
only then does the render read NetBox.

A feature declaration composes with that cleanly because **it changes config, not
wiring.** The profile edit reaches `containerlab` (unchanged), reaches NetBox (a new
context), and reaches the render (new tables). Reconciliation continues to check
adjacency and port existence, which a declaration does not alter.

The exception is a feature that *does* change the topology — a route reflector, a border
device. Then §5.10 applies in full: it is a topology change first, reconciled after, and
`gen_topology`'s `GROUP_FOR_ROLE` and `SLUG2MODEL` maps need entries or an unknown slug
raises `KeyError`. Say which kind a feature is in its module header.

---

## 7. Day-2 add and remove (#88)

**The declaration mechanism helps the config half, substantially. It does not fix the SoT
half, and pretending otherwise would be the more damaging error.**

**What it fixes.** Removal of *configuration* becomes computable. Today a table that
leaves the render is simply not written; whether the box still carries it is asserted by
nothing outside `DROP_TABLES`' fifteen hand-listed names. With the manifest, `absent` is
computed as box-manifest minus artifact-manifest, the push has an explicit removal set,
and tier-1 readback reports a leftover as `unexpected N` — which `config_landed` already
knows how to say. **Turning a feature off becomes a verifiable operation rather than an
absence of one.** That is genuinely new, and it is the same operation as removing a
device's config when the device is drained.

**What it does not fix.** Removing a *device* is a NetBox problem. `30-seed` is additive:
`get_or_create` in the schema phase, and a bulk path with no update and no delete. The
only removal path is `seed.py --reset` (`:533-549`), which is one HTTP DELETE per object,
sequential, single-threaded, while the `_bulk()` machinery beside it exists for creates
only. The object count is exact for `s1-512` — 1466 cables + 3024 IPs + 124 devices +
1388 prefixes = **6002** — and no stage exposes it. Two things worth recording that were
not in #88:

- **The ~34-minute figure is a derived estimate, not a measurement.** No committed
  measurement of the reset exists anywhere in either repo. It is consistent with 6002 ÷
  the seed's own measured single-threaded rate, but it should be measured before it is
  planned against.
- **`--reset`'s blast radius is wider than the site.** Cables, IP addresses and prefixes
  are deleted globally and unscoped; only devices are filtered by `site_id`. On a shared
  NetBox that is not a scoped reset.

So #88's remaining work is unchanged by this design: make `--reset` bulk and scoped, expose
it as a stage, and build the convergence-under-change test (remove a leaf from a converged
fabric, assert BGP settles to the *new* `expected.py` figure). What this design contributes
is that the last step becomes possible without a second oracle, and that `t31`'s step 4
(§6.3) is the smallest honest version of it.

---

## 8. Migration

Nothing may regress the current build. The correct baseline numbers, since two of them are
routinely misquoted:

| claim | correct value |
|---|---|
| cold build | **29m38s** (s8, first complete unattended); 25m23s with O5; 29m09s on s10, ~24m30s netting out the O4 regression |
| **1464/1464** | `bgp_peer_series`, the **expected BGP peer-series count** — *not* an assertion total. There is no global assertion counter; `verify.sh` accumulates phase names, not counts |
| 46/46 in-sync | measured **warm** three times, and **0/46 on the first cold build**. A warm measurement does not settle a cold question |

Every phase below is gated on a cold build, because §5.11's history is that warm
verification of a provisioning claim is not verification.

**Phase 0 — the manifest. ~1.5 days. Do this whichever option wins.**
The composer emits `_owned.json`; `interim_deploy` reads it instead of `_OWNED_WRITE` and
`DROP_TABLES`; a test asserts the manifest covers every table the renderer wrote with
intent. No feature, no new table, no behaviour change. **It closes the live drift in §1.1
as a side effect** — `MGMT_VRF_CONFIG`, `mac` and `docker_routing_config_mode` become
compared for the first time. Expect the first cold build after this to find a switch that
was never actually in sync; that is the point.

**Phase 1 — the composer. ~2 days.** `device_config()` becomes a merge over contributors,
with provenance at `(table, key)`. The existing emitters become contributors unchanged.
**The gate is byte-identical rendered output on every profile** — a diff of the ZTP root
before and after, on `s0-64` through `s3-4096`. `t14`'s offline `model_sot` path makes this
checkable on a workstation with no fabric.

**Phase 2 — the profile axis. ~3 days.** `features:` block with an allow-list (modelled on
`_OVERRIDABLE_INFRA`, `fabric_model.py:120`, the only unknown-key rejection in the file);
`nos_catalog` capability gating; named identifier pools with envelope bounds;
`expected.py --check` with `{key, value, must, because}`. `max_ports_per_switch` gains its
constraint retroactively and **#56 becomes a derive-time failure**. Still no feature
declared.

**Phase 3 — the declaration channel. ~3 days.** Git-held fragments as render data under
`gpufab-network/design/features/`; the renderer merges them through the composer;
`model_sot()` reads the same files so the offline path covers the declared half; YANG
validation moved to render time on the workstation; the `render_revision` profiles glob
and the `sot_revision` verdict gaps closed. **No NetBox change at all in this phase** —
that is what dropping the config-context projection to a later, precondition-gated step
buys.

**Phase 4 — `evpn` as the first module. ~3 days plus measurement.** §5.6's capability probe
first — and it is a probe, not code, so budget a fabric for it. Then the module, then the
tier-2 locators. Budget one cold build per iteration.

**Phase 5 — the round trip, and it is mostly repair. ~3 days.** `t31-gitops-roundtrip.sh`
first, driving the stages directly, because the observation half is the part that has never
existed. Then the two missing links and the four CI repairs in §6.3. This phase is
separable and can be scheduled independently; nothing in phases 0–4 depends on it.

**Not scheduled, and stated so it is not forgotten:** the NetBox ≥ 4.4 upgrade and the
config-context projection (§1.4). Worth doing, not worth blocking on, and a Postgres
migration on a live SoT is its own piece of work.

**Prerequisites that are not optional and are not in the estimates above:**

- `t_count 0 0` must stop passing, or every module must declare a non-zero expectation or
  an explicit `unsupported` (§3.6).
- `tests/fidelity/run-f0.sh`'s exit status is broken — `fv_finish` is installed as
  `trap ... EXIT` and never calls `exit`, so a gate with failing assertions exits 0 and
  the runner reports a clean run. Fix it before any module's verification depends on it.
- `verify.sh`'s phase list is hand-written and nothing asserts every `tNN-*.sh` is wired
  in; `t16` shipped unwired and was only ever run by hand. A module's test must be added
  to that list, and something should assert the list is complete.
- Extract the six divergent copies of `sw_run`/`_SSHO` (`t11:74`, `t13:155`, `t17:127`,
  `t18:92`, `t23:120`, `t28:210`) into `lib.sh` and add the `db_scan` / `db_hgetall` pair
  that does not exist at all. t13's copy carries `-n`; t11's and t23's do not, and the
  missing `-n` once ended a device loop after one iteration while the assertion underneath
  still passed.

**What stays working throughout.** Phases 0–2 change no rendered byte. Phase 3 changes
nothing until a profile declares a feature; every existing profile continues to render
identically because `declare()` returns `{}` when the block is absent. Phase 4 touches only
profiles that opt in.

**What breaks, honestly.** Phase 0's first cold build will very likely fail somewhere —
`MGMT_VRF_CONFIG` and `mac` have never been compared against a device, and there is no
reason to assume they have always landed. That is a discovery, not a regression, but it
will look like one and it will cost a cycle. Phase 1 risks a byte-diff on the base
snapshot's inherited tables if the merge order changes; the gate catches it, and the gate
is the reason phase 1 is two days rather than one.

---

## 9. What this costs

**Roughly 12–16 working days**, plus cold builds — of which phase 5 is ~3 and is largely
repair of CI that is already broken, not new design. Phases 0 and 1 are ~3.5 and carry
most of the risk reduction; a reader who stops there has a computed owned-table set, a
composer, and three live unverified tables newly verified.

**The honest comparison is not "13 days versus nothing".** It is 13 days versus paying a
smaller cost repeatedly, and this project has a measured number for the smaller cost.
**SNMP is the closest analogue available** — one configuration feature, added by hand, by
this team, on this codebase. It required: a design section (§5.11); two corrections to that
section found during implementation, both of which "would have produced a broken fix if
followed literally"; `snmp_tables()`, `apply_snmp()`, `apply_snmp_yml()`; `_SECRET_KEYED`
and `_safe_key()` because the diagnostic leaked the secret it was diagnosing; a ZTP section;
a bespoke `FEATURE.snmp.state` branch in `config_landed`; the removal of the
`disable_features` stopgap in the same change; and `t23`, `t29` and a `t20` mutation case.
It measured 46/46 in-sync warm, three times, **and 0/46 on its first cold build**, costing
~280s per build — the largest single lever left in the deploy.

That is roughly a week for a feature with **two tables and no new identifier namespace**.
VXLAN/EVPN has six tables, a new namespace, a control plane `config_db` may not express,
and a nested-encapsulation constraint. Built by hand, against the current enumerations, it
is not cheaper than the mechanism; it is more expensive, and it leaves the next feature
exactly where this one started.

The part that does not appear in either estimate is the risk term, and it is the one that
should decide it. The port budget went unasserted for **the life of the project**. The
management VRF is unasserted **now**. Neither was a hard problem; both were a step in a
procedure that nobody was forced to take. A mechanism that computes the owned set makes
that step impossible to skip, which is a different kind of saving from thirteen days.

---

## 10. Corrections to the framing that produced this document

Each of these was believed, stated, and used to reason with while this design was being
worked out. Recorded rather than quietly dropped, because a reader who arrives holding the
same beliefs will otherwise reach the same wrong conclusions — and because two of them
change the risk assessment in opposite directions.

1. **`config reload` does perform YANG validation on this image.** Measured here:
   0 of 48 artifacts accepted without `gwaddr`, 48 of 48 with it
   (`render_fabric_ztp.py:636-647`). The claim that only `config replace` validates is
   false, and it made opening the config surface look more dangerous than it is.
2. **"1464/1464 assertions" is a category error.** 1464 is `bgp_peer_series`. `t13:64`
   records that the last time this number was written by hand — session count compared
   against series count — two days went into a "drift" that was a category error rather
   than a fault. A design must not promise against a number that does not exist.
3. **`planes: [frontend]` is the wrong axis.** `frontend` is a *fabric*. "Plane" already
   means two other things, one of which is where VXLAN already lives (§5.1).
4. **`config_db` is not the universal interface**, even for SONiC. `bgpcfgd` is the
   constraint, and it has already forced this project to build a second artifact and a
   second stage for BGP unnumbered (#26960) — in the same subsystem EVPN needs (§5.5).
5. **VXLAN is not absent from the codebase; it is present with a different meaning.**
   Naming a fabric feature `vxlan` would corrupt `t25`'s link counting and
   `reconcile.py`'s local/remote partition (§5.2).
6. **The profile is not one file format.** `gpufab-platform/profiles/*.yaml` are the legacy
   `topology.dgx_count` shape and fail `expected.py` with `KeyError: 'fabric'`. The live
   surface is `gpufab-network/design/profiles/`. Declaring a feature in the wrong one is
   silent, because unknown profile keys are ignored without complaint.
7. **"NetBox config contexts are used nowhere" is right, but the reason matters.** They
   are also *incapable* of the thing they were proposed for — a context has no expression
   language and cannot produce a per-device derived value at all. Not using them is
   partly an omission and partly correct.
8. **The GitOps pillar is not "verified live".** `gpufab-sim-design.md:30` says so on the
   strength of one leg, one run, 2026-07-25, on a released host. The other three
   workflows have one commit each and none of them works: one lints an empty directory
   and passes, one cannot fire and would `exit 1`, one passes flags its tool has never
   accepted. This document should be read as correcting that line.
9. **"Nothing proves the round trip end to end" understates it.** Two of the four links do
   not exist. There is no commit → NetBox path anywhere in the system, and no
   merged-artifact → device path. The loop is an arc terminating in an open PR.

---

## Appendix — the seams that already exist

Recorded so an implementer does not rebuild any of them.

| seam | where | use |
|---|---|---|
| capability gate | `nos_catalog.yaml` + `fabric_model.check_nos_capabilities():299` | refuse a profile the NOS cannot express, at derive time |
| fragment contract | `frr_render.to_config_db():105` | the module `config_db()` signature, already in use |
| one derivation, two paths | `idp.auth_tables()`, `idp.apply_snmp()` called by both the push and the renderer | the rule a module must follow |
| profile rewrite + re-derive | `oob_plan.py --emit-profile:223` | expanding a declaration into concrete values without a second allocator |
| envelope-bounded allocation | `addressing.envelope` in the scale profiles | growth is additive; exceeding it is a named error |
| artifact provenance | `render_revision.py`, `sot_revision.py` | stamp which code and which SoT; **two gaps to close, §4** |
| YANG validation | `t17-mgmt-vrf.sh:277-307`, incl. `tablesWithOutYang` | already fails closed on an unmodelled table |
| device readback | `interim_deploy.config_landed():635` via `sonic-cfggen -d --print-data` | tier 1, with its tuple replaced by the manifest |
| ASIC/STATE readback | `tests/fidelity/remote/fv-cap-01.remote.sh:49,137` | tier 2 — exists, but `verify.sh` never runs it |
| forwarding proof | `fv-cap-02`, TTL captured on the receiving side | the model for proving an overlay actually carries traffic |
| shipped device probes | `tests/probes/`, copied to every host fatally by `verify.sh:75-79` | zero-plumbing extension point for a module's observation |
| mutation cases | `t14-port-table.sh:189-301`, `t20-insync-skip.sh:251-259` | prove the module's guards raise, and that a box which took none of its tables is detected |
| ZTP section registry | `render_fabric_ztp.ztp_json():389`, `NN-name` sorted, prefix-stripped | ordered, real, and already used by `00-snmp` |
| second-artifact stage | `deploy/55-unnumbered.sh` | the precedent for a capability `config_db` cannot carry |
| stage membership | `fabric_model.STAGE_ROLES:142` | one declaration, not a bash copy |
| per-sim CI routing | `render.yml:32-57` + `bot/setup_runner.sh:72-77` | label, self-assertion and credential locality — three layers, all needed (#F5) |
| sim identity | `/opt/gpufab/instance-id` | the authority every component keys off; scrubbed from golden images so a fresh instance mints its own |
| SoT → PR | `bot/webhook_relay.py` → `render.yml` → `tools/render.py` | works, measured 2026-07-25; the one leg that does |

### Two measured facts that will be blamed on this design, and are not caused by it

Both taken from the live NetBox 4.3.7 on `gpufab-s11-ops`:

- **`read_netbox()` passes no `limit=`** (`render_fabric_ztp.py:401-403`), so it paginates
  at NetBox's default **50**. That is 3 round trips at 124 devices and 1000 at 50 000.
  `seed.py:346` already sets `limit=1000` and comments on precisely this trap.
- **The renderer's NetBox cost is interfaces and addresses, not devices.** Measured:
  interfaces (4706 rows) **10.1 s**, ip-addresses (3024 rows) **7.3 s**, devices (124
  rows) **0.41 s**. Against the multi-DC 200–500K target, 17 s of serial REST is the wall,
  and a feature axis has nothing to do with it. Worth stating because "the render got
  slower" will be the first thing said after phase 1.
