# Why `interim_deploy` re-pushed every switch ZTP had already configured

Evidence captured on **gpufab-s3-fabric, 2026-07-27**, before that sim was
released. s3 was a converged 48-switch fabric built from
`design/profiles/scale/s1-512.yaml`, running network repo `4d4ad0e`.

## 1. ZTP provisioned the whole fabric

    $ sudo docker logs gpufab-ztp-oob 2>&1 | grep 'config_db\.json' \
        | grep -E '" 200 ' | grep -oE '/[A-Za-z0-9._-]+/config_db\.json' \
        | sort -u | wc -l
    48

## 2. The box holds exactly what ZTP served it

`onbox-vs-artifact.txt` — three switches of three roles, comparing
`sonic-cfggen -d --print-data` against `/opt/gpufab/ztp-srv/<dev>/config_db.json`
over the seven tables `interim_deploy._OWNED_WRITE` compares:

    INTERFACE / LOOPBACK_INTERFACE / BGP_NEIGHBOR / PORT   SAME on all three
    AAA / TACPLUS / TACPLUS_SERVER                          0 keys, artifact AND box

SONiC did not normalise, reorder or rewrite anything. The read-back path is
faithful, so "the comparison reads a different artifact than ZTP served" and
"SONiC rewrites fields on write" are both ruled out.

## 3. No artifact has ever carried the auth tables — but the key exists

    ztp artifacts on s3: 48
    artifacts with NO AAA/TACPLUS/TACPLUS_SERVER: 48
    artifacts still carrying SNMP/SNMP_COMMUNITY: 48
    tacacs_key present on host: True

`render_fabric_ztp.py` contained no reference to AAA, TACPLUS or tacacs at all.
`interim_deploy.build_switch_config` writes all three whenever
`/opt/gpufab/secrets/tacacs_key` exists — and `deploy/50-ztp-provision.sh` runs
`services/tacacs/setup_auth.sh` (which generates that key) BEFORE it renders and
serves the artifacts. So the push always wanted three tables ZTP had never
installed, and `config_landed` failed on the first of them:

    AAA is empty on the box, 1 pushed

for every switch, on every run. `skipped(in-sync)` was 0 by construction.

The 48/48 SNMP count is the *previous* instance of the same defect (1775c0f),
still visible here because these artifacts predate that fix.

## 4. What it cost

Measured on gpufab-s5-fabric 2026-07-27: 48/48 switches ZTP-provisioned,
`skipped(in-sync)` = 0, 46 `push.switch` records, `push.switches` = **456s** —
the largest single item in a 38-minute build.

## 5. Regression guard

`gpufab-platform/tests/t20-insync-skip.sh`, workstation-side, no fabric needed.
With the fix: 46/46 skipped. With the renderer change reverted: 0/46 skipped and
8 assertions fail.
