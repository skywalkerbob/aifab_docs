# O4 / issue #58 — why `skipped(in-sync)` is 0/46 on a COLD build

Captured on **gpufab-s10-fabric, 2026-07-28**, on the fabric produced by the
cold build `20260728T064952` (network+platform `0843625`), converged 1464/1464.

## The answer in one line

ZTP writes `config_db.json` and nothing else. `/etc/sonic/snmp.yml` keeps the
image's `snmp_rocommunity: public`, and ~45 seconds after the ZTP config lands
the `delayed` docker-snmp container runs `/usr/bin/snmp_yml_to_configdb.py`,
which **adds** `SNMP_COMMUNITY|public` to the config DB. The box then holds
`{<derived>, public}` while `interim_deploy` intends `{<derived>}`, so

    config_landed: SNMP_COMMUNITY 2/1 keys: unexpected 1 (public)   -> NOT in sync

for **every** switch, on **every** cold build. Nothing else differs.

## Why the two previous fixes verified clean

`interim_deploy.apply_snmp_yml()` (O11) writes the correct community into
`snmp.yml` — but only **during a push**, and it does not remove the entry the
container has already written. So it makes run *N+1* clean and can never make
run *N* clean. Every verification of O11 and of the earlier `auth_tables` fix
was run against a fabric that had already been pushed, which is the one state
in which the defect cannot exist. `--dry-run` reporting 45/46 warm was honest;
it was answering a different question from the one a build asks.

`t20-insync-skip.sh` compares the ZTP **artifact** against the push **intent**
and they agree — it never models what the image does to the box afterwards. It
also writes only `tacacs_key` into its temp secrets dir, so
`fabric_snmp_configured()` is False and its positive path never exercises a
community at all.

## 1. The two never-pushed switches are a preserved post-ZTP specimen

`interim_deploy.main()` selects `role != "oob-switch"`, so `dc1-pod001-oob-sw01`
and `-oob-sw02` are ZTP-provisioned and never pushed. The deploy log confirms
it — 46 switches `reloaded+VERIFIED`, and:

    dc1-pod001-oob-sw01: auth +auth
    dc1-pod001-oob-sw02: auth +auth

`artifact-vs-box.txt` compares `sonic-cfggen -d --print-data` against
`/opt/gpufab/ztp-srv/<dev>/config_db.json` over every table
`interim_deploy._OWNED_WRITE` compares. On both OOB switches:

    INTERFACE / LOOPBACK_INTERFACE / BGP_NEIGHBOR / AAA / TACPLUS /
    TACPLUS_SERVER / PORT / SNMP                          IDENTICAL
    SNMP_COMMUNITY: DIFFERS art=1 box=2
        only in BOX (extra) [1]: ['public']
    DEVICE_METADATA hostname/bgp_asn/type/hwsku           SAME
    FEATURE.snmp.state                                    enabled on both

On the three switches that *were* pushed (`bk-p1-spine01`, `bk-p1-r1-leaf01`,
`fr-leaf01`) every owned table including `SNMP_COMMUNITY` is identical — the
push is what removes `public`.

    admin@172.20.0.86 (oob-sw01, never pushed)
      /etc/sonic/snmp.yml    snmp_rocommunity: public
                             snmp_location: public
      CONFIG_DB              SNMP_COMMUNITY|45522357703a1d79c2a660b90ecea849
                             SNMP_COMMUNITY|public
    admin@172.20.0.72 (bk-p1-spine01, pushed)
      /etc/sonic/snmp.yml    snmp_rocommunity: 814aec86541a045ef782eb0b24165c8e
                             snmp_location: dc1-pod001-bk-p1-spine01
      CONFIG_DB              SNMP_COMMUNITY|814aec86541a045ef782eb0b24165c8e

So a fabric that reports itself converged is serving SNMP on the well-known
default community from the two boxes that ARE the management network. That is
a live security finding independent of the build-time cost, and it is not
fixable by the push, which never touches them.

## 2. The ordering, from the build's own log

    [07:08:15]   provisioning: 48/48 switches fetched config (DHCP leases: 94)
    [07:08:15]   all switches fetched config; settling
    [07:09:45] config-push backfill: finishing any switch that didn't self-provision

    oob-sw01  docker inspect -f {{.State.StartedAt}} snmp -> 2026-07-28T07:09:05Z
    oob-sw01  uptime -s                                   -> 2026-07-28 06:52:45

The snmp container on the never-pushed switch started **07:09:05 — 40 seconds
before the push began**, and every switch's `push.read` took 0-1s. So the DB
already carried `public` when `already_applied()` was evaluated, for all 46.

## 3. Recreated cold on a live fabric leaf

`/etc/sonic/snmp.yml` on `dc1-pod001-bk-p2-r8-leaf02` (172.20.0.71) was restored
to the image default and `sudo config ztp run -y` issued at 07:56:10, polling
the box every 20s:

    07:56:49  tables=18  SNMP_COMMUNITY = []                       (config cleared)
    07:57:10  tables=18  SNMP_COMMUNITY = []
    07:57:30  tables=19  SNMP_COMMUNITY = ['public']               (container, on the empty DB)
    07:57:51  tables=28  SNMP_COMMUNITY = ['258426a9...']          (ZTP config lands)
    07:58:14  tables=28  SNMP_COMMUNITY = ['258426a9...']
    07:58:35  tables=28  SNMP_COMMUNITY = ['258426a9...', 'public'] (+44s: container again)

44 seconds against a 90-second settle. `postpush-vs-cold.txt` diffs that cold
box against the SAME switch's post-push config — which the push's own read-back
had already verified equal to intent — over every owned table:

    INTERFACE (68) LOOPBACK_INTERFACE (2) BGP_NEIGHBOR (34) AAA (1)
    TACPLUS (1) TACPLUS_SERVER (1) PORT (64) SNMP (1)      IDENTICAL
    SNMP_COMMUNITY: intent=1 cold=2, UNEXPECTED on cold box: ['public']
    DROP tables present on cold box: []
    hostname / bgp_asn / type / hwsku                       SAME
    FEATURE.snmp.state                                      enabled on both

    OWNED TABLES THAT DIFFER: 1

## 4. The mechanism, from the image

`/usr/lib/ztp/plugins/configdb-json` with `clear-config: true` runs
`config reload -f` and renames the downloaded file to
`/etc/sonic/config_db.json`. It never touches `/etc/sonic/snmp.yml`.

`docker-snmp`'s `/usr/bin/start.sh` runs `/usr/bin/snmp_yml_to_configdb.py`,
which only ever ADDS:

    community = yaml_snmp_info['snmp_rocommunity']
    if community not in snmp_config_db_communities:
        db.set_entry('SNMP_COMMUNITY', community, {"TYPE": "RO"})

Nothing in SONiC removes an entry; only a `config reload` of a document without
it does. `FEATURE.snmp.delayed = True`, which is where the ~45s comes from.

## 5. The fix

`render_fabric_ztp.ztp_json()` now emits a second section using the image's own
`/usr/lib/ztp/plugins/snmp`, carrying the same derived community
`idp.snmp_community(device)` that `config_db.json` already carries:

    "00-snmp": {"community-ro": "<hmac hex>",
                "snmp-location": "<device>",
                "restart-agent": false}

`00-` orders it before the config: ZTP runs sections in `sorted()` order
(`ZTPSections.section_names`) and resolves the plugin by stripping `^[0-9]+-`
from the section name (`ZTPSections.ConfigSection.plugin`). Writing the file
before the config is applied leaves no window rather than a race.

See `render_fabric_ztp.patch`. Verified on the same leaf, `config ztp run -y`
at 08:10:53 with `snmp.yml` reset to the image default first — the renderer was
re-run against the live NetBox on the host, so the artifact under test is the
one the fixed renderer actually produces. `fixed-run-timeline.txt`:

    08:12:21  yml = 258426a9... / dc1-pod001-bk-p2-r8-leaf02   (00-snmp, pre-config)
    08:12:42  config lands, SNMP_COMMUNITY = ['258426a9...']
    08:13:07  docker-snmp container starts
    08:15:09  SNMP_COMMUNITY = ['258426a9...']                 -- `public` never returns

    admin@172.20.0.71:~$ show ztp status
    ZTP Status : SUCCESS
    00-snmp: SUCCESS
    01-configdb-json: SUCCESS

`fixed-cold-vs-intent.txt` — the cold box against the verified push intent, over
every table `already_applied()` compares:

    INTERFACE (68) LOOPBACK_INTERFACE (2) BGP_NEIGHBOR (34) AAA (1) TACPLUS (1)
    TACPLUS_SERVER (1) PORT (64) SNMP (1) SNMP_COMMUNITY (1)   ALL IDENTICAL
    DROP tables present: []   hostname/bgp_asn/type/hwsku SAME   FEATURE.snmp enabled

    OWNED TABLES THAT DIFFER: 0  ->  interim_deploy would SKIP this switch

The leaf reconverged: 34 of 34 neighbours Established, 1428 prefixes.

## 6. The test

`t29-ztp-snmp-yml.sh` models the two image behaviours above (both transcribed
from the image, both named in the code) and asks `already_applied()` the cold
question. `t29-before-fix.txt` / `t29-after-fix.txt`:

    before   14 passed  3 failed
             FAIL  ZTP documents with no snmp section: 46 found
             FAIL  ZTP snmp sections actually inspected: observed 0 (expected 46)
             FAIL  in sync AFTER docker-snmp has run snmp_yml_to_configdb.py:
                   observed 0 (expected 46)
             # first NOT-in-sync cold: dc1-pod001-bk-p1-r1-leaf01:
                   SNMP_COMMUNITY 2/1 keys: unexpected 1 (public)
    after    17 passed  0 failed

The negative controls all still fire at 46/46 — a switch at factory, one with
the 32-port PORT table, one missing a BGP peer, one whose ZTP section names
`public` or another device's community, and one that already had `public` in
the DB from an earlier boot are all still PUSHED.

## What this does NOT establish

* The 444s -> ~165s saving is inferred from the warm/cold `push.all` figures and
  from t16 (n=46, p50 162s per reload), not from a post-fix cold build. Only a
  full cold build measures it.
* The on-device demonstration is one leaf, twice (once broken, once fixed), plus
  the two OOB switches. It is not 46.
* t29 models the image rather than driving it. The model is small and its
  sources are named, but a change to the sonic-vs image would invalidate it
  silently — t23 (snmp community, host-side) is the check that would still be
  looking at a real box.
