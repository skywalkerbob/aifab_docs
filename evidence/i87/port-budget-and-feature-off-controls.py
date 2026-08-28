"""Two controls that must be shown failing before they are trusted.

A: the #56 port budget. `max_ports_per_switch` printed 70 against a 64-port
   platform and exited 0 for the life of the project. Reconstruct the pre-fix
   profile and prove --check refuses it.

B: the feature OFF. A disabled feature must render IDENTICALLY, and asserting
   that requires comparing something — "no VXLAN tables appeared" over an empty
   set is the 0/0 pass this suite exists to eliminate.
"""
import sys, yaml, copy, json
S = "/tmp/claude-1000/-mnt-data-bob-sim/93a1e4d6-8d92-46a0-84a4-d3e92388eceb/scratchpad/i87"
sys.path.insert(0, S + "/gpufab-platform/tools")
import fabric_model as fm
import expected as ex

SCALE = S + "/gpufab-network/design/profiles/scale/"

print("=== CONTROL A — the #56 port budget ===")
s5 = yaml.safe_load(open(SCALE + "s5-32768.yaml"))
post = ex.compute(SCALE + "s5-32768.yaml")
print(f"  post-fix (cores.backend=192): max_ports={post['max_ports_per_switch']} "
      f"platform={post['platform_ports']}  violations={len(ex.check(post))}")

# The pre-fix profile: issue O2/#56 was closed by raising cores.backend 105->192.
pre = copy.deepcopy(s5)
pre["fabric"]["regions"][0]["dcs"][0]["core"]["backend"]["switches"] = 105
import tempfile, os
fd, tmp = tempfile.mkstemp(suffix=".yaml"); os.close(fd)
yaml.safe_dump(pre, open(tmp, "w"))
prev = ex.compute(tmp)
bad = ex.check(prev)
print(f"  pre-fix  (cores.backend=105): max_ports={prev['max_ports_per_switch']} "
      f"platform={prev['platform_ports']}  violations={len(bad)}")
for k, must, why, because in bad:
    print(f"    REFUSED {k}: {why}  [must: {must}]")
os.unlink(tmp)
assert prev["max_ports_per_switch"] > prev["platform_ports"], \
    "control did not reproduce the over-budget condition"
assert bad, "CONTROL FAILED: --check passed a profile wanting more ports than the platform has"
print("  CONTROL A PASSES: the check can fail, and fails on exactly #56.\n")

print("=== CONTROL B — feature OFF renders identically ===")
on = yaml.safe_load(open(SCALE + "s1-512.yaml"))
off = copy.deepcopy(on)
off.pop("features")
off.pop("config_mode")             # only needed because the feature needs it
off["addressing"]["envelope"].pop("vni")

m_on, m_off = fm.derive(copy.deepcopy(on), "vm"), fm.derive(copy.deepcopy(off), "vm")


def shape(m):
    """Everything the model says EXCEPT the feature block."""
    return json.dumps({k: m[k] for k in ("devices", "nodes", "links", "counters")},
                      sort_keys=True, default=str)


same = shape(m_on) == shape(m_off)
print(f"  topology identical with feature on vs off : {same}")
print(f"  devices/nodes/links compared              : "
      f"{len(m_on['devices'])}/{len(m_on['nodes'])}/{len(m_on['links'])}")
assert len(m_on["devices"]) > 0 and len(m_on["links"]) > 0, \
    "compared nothing — a 0/0 comparison proves nothing"
assert same, "CONTROL FAILED: enabling the feature changed the topology"

print(f"  features when ON  : {sorted(m_on['features'])}")
print(f"  features when OFF : {sorted(m_off['features'])}  (must be empty)")
assert m_off["features"] == {}, "feature OFF still allocated"

ev = fm.features.discover()["evpn"]
decl_off = m_off.get("features_declared", {}).get("evpn", {})
n_dev = 0
tables_off = set()
for d in m_off["devices"]:
    n_dev += 1
    tables_off |= set(ev.config_db(d, m_off, m_off["features"].get("evpn", {})))
print(f"  devices examined with feature OFF         : {n_dev}")
print(f"  VXLAN/VLAN tables emitted with feature OFF: {len(tables_off)} {sorted(tables_off)}")
assert n_dev == 48, f"expected 48 devices to examine, got {n_dev} — measured too little"
assert tables_off == set(), "feature OFF emitted tables"

# And the positive arm, so the assertion above is not vacuous.
tables_on = set()
n_vtep = 0
for d in m_on["devices"]:
    t = set(ev.config_db(d, m_on, m_on["features"]["evpn"]))
    if t:
        n_vtep += 1
    tables_on |= t
print(f"  VTEP devices with feature ON              : {n_vtep} of {len(m_on['devices'])}")
print(f"  tables emitted with feature ON            : {len(tables_on)} {sorted(tables_on)}")
assert n_vtep == 3, f"expected 3 VTEPs, got {n_vtep}"
assert len(tables_on) == 5, f"expected 5 tables, got {sorted(tables_on)}"
print("  CONTROL B PASSES: OFF emits 0 tables across 48 devices; ON emits 5 across 3.")
