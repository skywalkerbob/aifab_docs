#!/usr/bin/env bash
# t29 — a ZTP-provisioned switch must still be in sync AFTER the image's own
# SNMP writer has run. This is the COLD half of t20, and it is the half that
# has never been measured.
#
# THE DEFECT THIS GUARDS (issue #58 / O4). On a cold build every ZTP-provisioned
# switch is re-pushed: `skipped(in-sync)` is 0/46, push.all takes 444s against
# 165s warm, and all 46 pay a full `config reload`. Two fixes have already been
# aimed at this symptom (auth_tables, then the SNMP community) and BOTH were
# verified against a fabric that was already up, where the defect cannot be
# observed at all.
#
# The device is not a pure function of the artifact ZTP serves. The sonic-vs
# image ships /etc/sonic/snmp.yml holding the well-known default:
#
#     snmp_rocommunity: public
#     snmp_location: public
#
# ZTP writes config_db.json and NOTHING ELSE — `clear-config` runs
# `config reload -f`, which rewrites the config DB and restarts every container
# but does not touch that file (/usr/lib/ztp/plugins/configdb-json). docker-snmp
# is a `delayed` feature, so it starts ~45s after the reload and runs
# /usr/bin/snmp_yml_to_configdb.py, which ADDS every community named in snmp.yml
# that is not already a key:
#
#     if community not in snmp_config_db_communities:
#         db.set_entry('SNMP_COMMUNITY', community, {"TYPE": "RO"})
#
# So the box ends up holding {<derived>, public} while interim_deploy intends
# {<derived>}, config_landed reports
#
#     SNMP_COMMUNITY 2/1 keys: unexpected 1 (public)
#
# and the switch is reloaded. Every switch. Every cold build.
#
# MEASURED on gpufab-s10-fabric 2026-07-28. Two independent observations:
#
#   1. dc1-pod001-oob-sw01 and -oob-sw02 are ZTP-provisioned and, being
#      role=oob-switch, are the two switches interim_deploy NEVER pushes. They
#      are therefore a preserved post-ZTP specimen. Both hold
#      SNMP_COMMUNITY|<derived> AND SNMP_COMMUNITY|public, with
#      /etc/sonic/snmp.yml still saying `public`, on a fabric converged
#      1464/1464. Every other owned table is byte-identical to the artifact.
#
#   2. ZTP was re-run on one live leaf (dc1-pod001-bk-p2-r8-leaf02) with
#      snmp.yml restored to the image default, polling the box every 20s:
#
#        07:57:30  SNMP_COMMUNITY = [public]                  (config cleared)
#        07:57:51  SNMP_COMMUNITY = [258426a9...]             (ZTP config lands)
#        07:58:35  SNMP_COMMUNITY = [258426a9..., public]     (+44s: container)
#
#      Diffed against the same switch's post-push config — which the push's own
#      read-back had verified equal to intent — the cold box differs in exactly
#      ONE owned table: SNMP_COMMUNITY, unexpected `public`. INTERFACE (68),
#      BGP_NEIGHBOR (34), PORT (64), AAA, TACPLUS, TACPLUS_SERVER, SNMP, hwsku
#      and FEATURE.snmp.state are all identical.
#
#      Stage 50 settles 90s after the last switch fetches its config, so 44s
#      guarantees every switch carries `public` before the push reads it.
#
# WHY IT IS INVISIBLE WARM, WHICH IS THE POINT OF THIS FILE.
# interim_deploy.apply_snmp_yml() writes the CORRECT community into snmp.yml —
# but only during a push, and it does not remove the entry the container has
# already written. So the push fixes the file one run too late: the first run
# after ZTP is always out of sync and always reloads, and every run after that
# is in sync. `--dry-run` against a running fabric reports 45/46 and is honest;
# it is simply answering a different question from the one the build asks.
#
# t20 asserts the ARTIFACT agrees with the push intent, and it does. It cannot
# see this because it compares the artifact to the intent and never models what
# the image does to the box afterwards. (It also runs with only a tacacs_key in
# its temp secrets dir, so fabric_snmp_configured() is False and its positive
# path never exercises a community at all.) This file writes BOTH secrets and
# runs the image's writer over the artifact before asking the question.
#
# WHY IT RUNS ON THE WORKSTATION. Like t14 and t20 it drives the real renderer
# and the real push-intent builder over a profile-derived SoT. The two image
# behaviours it models — the ZTP snmp plugin and snmp_yml_to_configdb.py — are
# transcribed from the image this fabric runs and are named in the code below,
# so a reader can check the model against the source rather than trust it. The
# ON-DEVICE demonstration is the measurement quoted above; this test exists so
# that the next regression is caught without spending a 40-minute cold build.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh
T_NAME="t29-ztp-snmp-yml"
GITROOT=""
while [ $# -gt 0 ]; do case "$1" in --gitroot) GITROOT="$2"; shift 2;; *) shift;; esac; done
[ -n "$GITROOT" ] || { echo "  FAIL --gitroot required"; exit 1; }
cd "$GITROOT" 2>/dev/null || { echo "  FAIL --gitroot '$GITROOT' unusable from $(pwd)"; exit 1; }
GITROOT=$(pwd)

# The profile the real fabrics are built from — the 46 push-scope switches ARE
# the population that took 444s on the 2026-07-28 cold build.
PROFILE="gpufab-network/design/profiles/scale/s1-512.yaml"
[ -f "$PROFILE" ] || { t_bad "profile $PROFILE absent"; t_summary; exit 1; }

get() { awk -v k="$2" '$1==k{print $2}' <<<"$1"; }

# Expected counts come from expected.py — the ONE derivation of "how many of X
# should exist". Push scope is switches minus the OOB switches
# (interim_deploy.main: role != "oob-switch"). Derived here, never typed.
exp_scope=$(python3 - "$PROFILE" <<'PY' 2>/dev/null
import json, subprocess, sys
e = json.loads(subprocess.run(
    [sys.executable, "gpufab-platform/tools/expected.py", "--profile", sys.argv[1],
     "--json"], capture_output=True, text=True).stdout)
print(e["switches"] - e.get("switches_by_fabric", {}).get("oob", 0))
PY
)
if [ -z "${exp_scope:-}" ] || [ "$exp_scope" -eq 0 ] 2>/dev/null; then
  t_bad "expected.py produced no push-scope switch count for $PROFILE — nothing can be asserted against"
  t_summary; exit 1
fi
echo "  profile: $(basename "$PROFILE")  expected push-scope switches=$exp_scope"

R=$(python3 - "$PROFILE" <<'PY' 2>&1
import sys, json, copy, re, tempfile, pathlib
sys.path.insert(0, "gpufab-platform/tools")
sys.path.insert(0, "gpufab-network/tools")
import render_fabric_ztp as rfz
import interim_deploy as idp
import gpufab
from seed import derive_topology

PROFILE = sys.argv[1]
SERVER = "172.20.0.4"

# BOTH secrets, in a temp dir. tacacs_key alone is what t20 writes, and with no
# snmp_secret fabric_snmp_configured() is False, snmp_tables() returns {} on
# both paths, and the entire SNMP dimension of the comparison is vacuous — which
# is one reason this defect survived a test written to catch exactly its shape.
# Never read the host's secrets, never depend on one being present.
sec = pathlib.Path(tempfile.mkdtemp())
(sec / "tacacs_key").write_text("t29-not-a-real-key\n")
(sec / "snmp_secret").write_text("t29-not-a-real-snmp-secret\n")
idp.SECRETS = sec

prof = gpufab.load_profile(PROFILE)
topo = derive_topology(prof, PROFILE)
idp.PEER_ASN = {n["name"]: n["asn"] for n in topo["nodes"]}
idp.POD_INFRA = topo.get("pod_infra", {})
nodes = {n["name"]: n for n in topo["nodes"]
         if n["kind"] == "sonic-vm" and n["role"] != "oob-switch"}
links = topo["links"]
hw = idp.hardware_tables(PROFILE)

base = json.load(open("gpufab-network/design/base/vs_base_config_db.json"))
ps = rfz.load_port_sets("gpufab-network/design/base/vs_port_sets.json")
devices, dev_by_id, iface_by_id, ip_by_iface, peer = rfz.model_sot(PROFILE)
sw = [d for d in devices if (d.custom_fields or {}).get("node_class") == "sonic-vm"
      and d.name in nodes]

# --- the image, transcribed ------------------------------------------------
# What /etc/sonic/snmp.yml holds on a switch this ZTP image has just booted.
# Not a guess: read off gpufab-s10-fabric's dc1-pod001-oob-sw01, a switch ZTP
# provisioned and the push never touched.
IMAGE_SNMP_YML = {"snmp_rocommunity": "public", "snmp_location": "public"}


def ztp_plugin_name(section_name, data):
    """Which plugin ZTP runs for a section — ZTPSections.ConfigSection.plugin().
    An explicit `plugin` wins; otherwise the section name with a leading
    `^[0-9]+-` stripped. This is why "01-configdb-json" reaches the
    configdb-json plugin, and why a section must be NAMED for its plugin."""
    p = data.get("plugin")
    if isinstance(p, str):
        return p
    if isinstance(p, dict) and p.get("name"):
        return p["name"]
    res = re.split("^[0-9]+-", section_name, maxsplit=1)
    return res[1] if len(res) > 1 else res[0]


def ztp_snmp_plugin(snmp_yml, data):
    """/usr/lib/ztp/plugins/snmp — sets snmp_rocommunity / snmp_location in
    /etc/sonic/snmp.yml, creating or sed-replacing each line."""
    out = dict(snmp_yml)
    if data.get("community-ro") is not None:
        out["snmp_rocommunity"] = data["community-ro"]
    if data.get("snmp-location") is not None:
        out["snmp_location"] = data["snmp-location"]
    return out


def snmp_yml_to_configdb(cfg, snmp_yml):
    """/usr/bin/snmp_yml_to_configdb.py, run by docker-snmp's start.sh on every
    container start. It only ever ADDS: an entry already present is left alone,
    an entry named in snmp.yml and absent from the DB is created. Nothing in
    SONiC ever removes one — only a `config reload` of a document without it."""
    box = copy.deepcopy(cfg)
    comm = snmp_yml.get("snmp_rocommunity")
    if comm is not None and comm not in box.get("SNMP_COMMUNITY", {}):
        box.setdefault("SNMP_COMMUNITY", {})[comm] = {"TYPE": "RO"}
    loc = snmp_yml.get("snmp_location")
    if loc and "LOCATION" not in box.get("SNMP", {}):
        box.setdefault("SNMP", {})["LOCATION"] = {"Location": loc}
    return box


def boot_from_ztp(artifact, doc, snmp_yml=None):
    """The box, after ZTP has run the document and the delayed snmp container
    has started. Sections run in sorted() order (ZTPSections.section_names)."""
    yml = dict(IMAGE_SNMP_YML if snmp_yml is None else snmp_yml)
    box = None
    for name in sorted(doc["ztp"]):
        data = doc["ztp"][name]
        plugin = ztp_plugin_name(name, data)
        if plugin == "snmp":
            yml = ztp_snmp_plugin(yml, data)
        elif plugin == "configdb-json":
            box = copy.deepcopy(artifact)   # clear-config -> config reload -f
    if box is None:
        raise RuntimeError("ztp.json has no configdb-json section")
    return snmp_yml_to_configdb(box, yml)


def would_skip(box, node):
    """The REAL decision interim_deploy.deploy_switch makes on a box holding
    `box`. Snapshot first: build_switch_config mutates its argument in place."""
    before = copy.deepcopy(box)
    cfg = idp.build_switch_config(node, links, copy.deepcopy(box), hw.get(node["name"]))
    return idp.already_applied(before, cfg)


def why(box, node):
    before = copy.deepcopy(box)
    cfg = idp.build_switch_config(node, links, copy.deepcopy(box), hw.get(node["name"]))
    return idp.config_landed(before, cfg)[1]


rendered = build_failures = 0
artifacts, docs = {}, {}
for d in sw:
    try:
        cfg, _mgmt, _frr = rfz.device_config(d, iface_by_id, ip_by_iface, peer,
                                             dev_by_id, base, port_sets=ps)
    except Exception as e:                                    # noqa: BLE001
        build_failures += 1
        if build_failures == 1:
            print(f"# first render failure: {d.name}: {type(e).__name__}: {str(e)[:120]}")
        continue
    rendered += 1
    artifacts[d.name] = cfg
    docs[d.name] = rfz.ztp_json(d.name, SERVER)

print("switches_rendered", rendered)
print("render_failures", build_failures)

# --- the ZTP document must configure snmp.yml, before the config -------------
no_section = wrong_plugin = wrong_order = mismatched = examined = 0
for name, doc in docs.items():
    secs = doc["ztp"]
    snmp_secs = [s for s in secs if ztp_plugin_name(s, secs[s]) == "snmp"]
    cdb_secs = [s for s in secs if ztp_plugin_name(s, secs[s]) == "configdb-json"]
    if not snmp_secs:
        no_section += 1
        continue
    # Counted so the three t_zero assertions below cannot pass vacuously. A
    # `continue` above skips all of them, so with no section at all they would
    # each report "none found" having looked at nothing — the exact shape of the
    # image-scrub decoy that could never match.
    examined += 1
    s = snmp_secs[0]
    if ztp_plugin_name(s, secs[s]) != "snmp":
        wrong_plugin += 1
    # sorted() order decides which runs first, and the whole point is that
    # snmp.yml is right BEFORE the reload that starts the container.
    if not cdb_secs or min(snmp_secs) > min(cdb_secs):
        wrong_order += 1
    # ONE derivation: the community the ZTP document writes into snmp.yml must
    # be the community the config_db artifact carries, or the image's writer
    # adds a second one and we are back where we started with a longer story.
    want = set(artifacts[name].get("SNMP_COMMUNITY", {}))
    if {secs[s].get("community-ro")} != want:
        mismatched += 1
print("artifacts_without_ztp_snmp_section", no_section)
print("ztp_snmp_sections_examined", examined)
print("ztp_snmp_sections_wrong_plugin", wrong_plugin)
print("ztp_snmp_sections_after_configdb", wrong_order)
print("ztp_snmp_community_disagrees_with_configdb", mismatched)

# --- POSITIVE: in sync BEFORE and AFTER the image's writer runs --------------
# The first number is what t20 already asserts, restated here because with a
# real snmp_secret present it is a stronger claim than t20's. The second is the
# one that has never been true.
pre = sum(1 for n, a in artifacts.items() if would_skip(copy.deepcopy(a), nodes[n]))
print("insync_before_image_writer", pre)

cold, first = 0, None
for name, art in artifacts.items():
    box = boot_from_ztp(art, docs[name])
    if would_skip(box, nodes[name]):
        cold += 1
    elif first is None:
        first = f"{name}: {why(box, nodes[name])}"
print("insync_after_image_writer", cold)
if first:
    print(f"# first NOT-in-sync cold: {first}")

# --- NEGATIVE: the check must still be able to fail --------------------------
# Each is a state this fabric has actually been in. `pushed` counts switches the
# tool would NOT skip, so it must equal the whole population.
def count_pushed(mutate):
    n = 0
    for name, art in artifacts.items():
        try:
            box = mutate(art, name)
            if box is None:
                continue
            if not would_skip(box, nodes[name]):
                n += 1
        except Exception as e:                                # noqa: BLE001
            print(f"# harness error mutating {name}: {type(e).__name__}: {str(e)[:100]}")
            return -1
    return n


def no_ztp_snmp(art, name):
    """The pre-fix renderer: ZTP writes config_db and nothing else, so snmp.yml
    keeps the image's `public` and the container adds it to the DB."""
    doc = {"ztp": {k: v for k, v in docs[name]["ztp"].items()
                   if ztp_plugin_name(k, v) != "snmp"}}
    return boot_from_ztp(art, doc)


def ztp_snmp_names_public(art, name):
    """A section that writes the DEFAULT into snmp.yml — the shape of a fix that
    made the two files agree on the wrong value."""
    doc = copy.deepcopy(docs[name])
    for k, v in doc["ztp"].items():
        if ztp_plugin_name(k, v) == "snmp":
            v["community-ro"] = "public"
    return boot_from_ztp(art, doc)


def ztp_snmp_names_another_device(art, name):
    """The section carries a community, but not THIS device's — a per-device
    derivation wired to the wrong name."""
    other = next(n for n in artifacts if n != name)
    doc = copy.deepcopy(docs[name])
    for k, v in doc["ztp"].items():
        if ztp_plugin_name(k, v) == "snmp":
            v["community-ro"] = idp.snmp_community(other)
    return boot_from_ztp(art, doc)


def factory(_art, _name):
    """A switch that never provisioned at all."""
    return copy.deepcopy(base)


def stale_public_left_behind(art, name):
    """snmp.yml is right, but a previous boot already put `public` in the DB.
    Nothing in SONiC removes it, so this switch genuinely needs a reload."""
    box = boot_from_ztp(art, docs[name])
    box.setdefault("SNMP_COMMUNITY", {})["public"] = {"TYPE": "RO"}
    return box


def lose_one_bgp(art, name):
    box = boot_from_ztp(art, docs[name])
    if not box.get("BGP_NEIGHBOR"):
        return None
    box["BGP_NEIGHBOR"].pop(sorted(box["BGP_NEIGHBOR"])[0])
    return box


def factory_port_table(art, name):
    box = boot_from_ztp(art, docs[name])
    box["PORT"] = copy.deepcopy(base["PORT"])
    return box


for label, fn in (("pushed_without_ztp_snmp_section", no_ztp_snmp),
                  ("pushed_ztp_snmp_names_public", ztp_snmp_names_public),
                  ("pushed_ztp_snmp_wrong_device", ztp_snmp_names_another_device),
                  ("pushed_factory", factory),
                  ("pushed_stale_public_in_db", stale_public_left_behind),
                  ("pushed_missing_one_bgp_peer", lose_one_bgp),
                  ("pushed_factory_port_table", factory_port_table)):
    print(label, count_pushed(fn))

# --- the no-secret state ----------------------------------------------------
# Before setup_auth.sh has run there is no snmp_secret, so neither path has a
# community to state and the ZTP document must not invent one. (Stage 50 runs
# setup_auth.sh before serve.sh renders, and setup_auth.sh is FATAL if the
# secret is missing afterwards, so a real build never renders in this state.)
(sec / "snmp_secret").unlink()
nokey = sum(1 for d in sw if any(
    ztp_plugin_name(k, v) == "snmp"
    for k, v in rfz.ztp_json(d.name, SERVER)["ztp"].items()))
print("nokey_ztp_snmp_sections", nokey)
PY
)

if [ -z "$(get "$R" switches_rendered)" ]; then
  t_bad "the render/boot-model harness produced NO measurements"
  echo "$R" | sed 's/^/        /' | tail -12
  t_summary; exit 1
fi
echo "$R" | grep '^# ' | sed 's/^/      /'

# ---------------------------------------------------------------------------
# 1. The population. Nothing below means anything if this is wrong.
# ---------------------------------------------------------------------------
t_zero  "switches that FAILED to render"                 "$(get "$R" render_failures)"
t_count "push-scope switches rendered"                   "$(get "$R" switches_rendered)" "$exp_scope"

# ---------------------------------------------------------------------------
# 2. The ZTP document configures /etc/sonic/snmp.yml, with THIS device's
#    community, through the image's own snmp plugin, BEFORE the config lands.
#    This is the fix; without it section 3 is 0.
# ---------------------------------------------------------------------------
t_zero  "ZTP documents with no snmp section" \
        "$(get "$R" artifacts_without_ztp_snmp_section)"
# Without this the three t_zero checks below report "none" on a run in which
# they inspected nothing at all.
t_count "ZTP snmp sections actually inspected" \
        "$(get "$R" ztp_snmp_sections_examined)" "$exp_scope"
t_zero  "snmp sections whose name does not resolve to the snmp plugin" \
        "$(get "$R" ztp_snmp_sections_wrong_plugin)"
t_zero  "snmp sections ordered AFTER the config (container would win the race)" \
        "$(get "$R" ztp_snmp_sections_after_configdb)"
t_zero  "snmp sections naming a community the config_db does not carry" \
        "$(get "$R" ztp_snmp_community_disagrees_with_configdb)"

# ---------------------------------------------------------------------------
# 3. POSITIVE. The first line is t20's claim with a real snmp_secret present.
#    The second is the cold one: after docker-snmp has started and run
#    snmp_yml_to_configdb.py, the switch must STILL be in sync. This number was
#    0 for the life of the project, and each 1 is a `config reload` not paid.
# ---------------------------------------------------------------------------
t_count "in sync as ZTP renders it (before the image's writer)" \
        "$(get "$R" insync_before_image_writer)" "$exp_scope"
t_count "in sync AFTER docker-snmp has run snmp_yml_to_configdb.py" \
        "$(get "$R" insync_after_image_writer)" "$exp_scope"

# ---------------------------------------------------------------------------
# 4. NEGATIVE. A skip check that cannot fail is worth less than none: a slow
#    correct deploy beats a fast one that leaves a switch at factory.
# ---------------------------------------------------------------------------
t_count "still pushed: ZTP writes no snmp.yml (the pre-fix renderer)" \
        "$(get "$R" pushed_without_ztp_snmp_section)" "$exp_scope"
t_count "still pushed: ZTP writes 'public' into snmp.yml" \
        "$(get "$R" pushed_ztp_snmp_names_public)" "$exp_scope"
t_count "still pushed: ZTP writes another device's community" \
        "$(get "$R" pushed_ztp_snmp_wrong_device)" "$exp_scope"
t_count "still pushed: switch at FACTORY config" \
        "$(get "$R" pushed_factory)" "$exp_scope"
t_count "still pushed: 'public' already in the DB from an earlier boot" \
        "$(get "$R" pushed_stale_public_in_db)" "$exp_scope"
t_count "still pushed: one BGP peer missing" \
        "$(get "$R" pushed_missing_one_bgp_peer)" "$exp_scope"
t_count "still pushed: factory 32-port PORT table (178-session bug)" \
        "$(get "$R" pushed_factory_port_table)" "$exp_scope"

# ---------------------------------------------------------------------------
# 5. No secret yet: state no community rather than invent one.
# ---------------------------------------------------------------------------
t_zero  "ZTP snmp sections rendered with NO snmp_secret" \
        "$(get "$R" nokey_ztp_snmp_sections)"

t_summary
