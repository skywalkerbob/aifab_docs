"""Render a real artifact for one frontend leaf and show the MANIFEST.

Uses render_fabric_ztp.model_sot() — the same NetBox-shaped derivation the repo
already uses to exercise the real render path off-host — so this needs no live
NetBox and touches nothing on the fabric.

The point is not that VXLAN tables appear. It is that OWNERSHIP IS COMPUTED:
nowhere does any list say "evpn owns VXLAN_TUNNEL". The composer diffs what the
contributor changed and records the owner, so the manifest cannot disagree with
the code that produced it.
"""
import sys, json
S = "/tmp/claude-1000/-mnt-data-bob-sim/93a1e4d6-8d92-46a0-84a4-d3e92388eceb/scratchpad/i87"
sys.path.insert(0, S + "/gpufab-network/tools")
sys.path.insert(0, S + "/gpufab-platform/tools")
import render_fabric_ztp as R
import fabric_model as fm
import gpufab

PROF = S + "/gpufab-network/design/profiles/scale/s1-512.yaml"
TARGET = "dc1-pod001-fr-leaf01"

devices, dev_by_id, iface_by_id, ip_by_iface, peer = R.model_sot(PROF)
base = json.load(open(S + "/gpufab-network/design/base/vs_base_config_db.json"))
port_sets = R.load_port_sets(S + "/gpufab-network/design/base/vs_port_sets.json")

m = fm.derive(gpufab.load_profile(PROF), "vm")
alloc = m.get("features") or {}
mdevs = {d["name"]: d for d in m["devices"]}
print(f"features allocated: {sorted(alloc)}  vteps={alloc['evpn']['vteps']}\n")

dev = next(d for d in devices if d.name == TARGET)
cfg, mgmt, frr, mf = R.device_config(
    dev, iface_by_id, ip_by_iface, peer, dev_by_id, base,
    p2p="numbered", port_sets=port_sets, render_fp="i87proof",
    infra_overrides=R.profile_infra_overrides(PROF),
    model_features=alloc, model_devices=mdevs)

print(f"=== {TARGET}: overlay tables in the rendered config_db ===")
for t in ("VLAN", "VLAN_INTERFACE", "VXLAN_TUNNEL", "VXLAN_EVPN_NVO", "VXLAN_TUNNEL_MAP"):
    if t in cfg:
        print(f"  {t}: {json.dumps(cfg[t], sort_keys=True)}")

print(f"\n=== manifest: who owns what (COMPUTED, not declared) ===")
for t, rec in sorted(mf["tables"].items()):
    mark = "  <-- evpn" if rec["owner"] == "evpn" else ""
    print(f"  {t:<20} owner={rec['owner']:<9} keys={rec['keys']:<4} "
          f"verify={rec['verify'][:52]}{mark}")

print(f"\nabsent  : {mf['absent']}")
print(f"adopted : {[t for t in mf['tables'] if t in ('VLAN','VLAN_MEMBER','VLAN_INTERFACE')]}"
      "   <- tables DECLARED_ABSENT that this render OWNS anyway (#92)")
und = [u for u in mf["unverified"] if u.get("reason") == "NO REASON RECORDED"]
print(f"unverified with NO REASON: {und}   <- must be empty or the render refuses")

# A spine must own nothing in config_db but must still carry the FRR stanza.
sp = next(d for d in devices if d.name == "dc1-pod001-fr-spine01")
cfg2, _, frr2, mf2 = R.device_config(
    sp, iface_by_id, ip_by_iface, peer, dev_by_id, base,
    p2p="numbered", port_sets=port_sets, render_fp="i87proof",
    infra_overrides=R.profile_infra_overrides(PROF),
    model_features=alloc, model_devices=mdevs)
vx = [t for t in mf2["tables"] if t.startswith(("VXLAN", "VLAN"))]
print(f"\nfr-spine01 overlay tables owned: {vx}  (must be [] — spines carry no VTEP)")
print("fr-spine01 frr.conf tail:")
for line in (frr2 or "").strip().splitlines()[-4:]:
    print("   ", line)

# And a backend leaf must be untouched.
bk = next(d for d in devices if "bk-p1-r1-leaf01" in d.name)
_, _, _, mf3 = R.device_config(
    bk, iface_by_id, ip_by_iface, peer, dev_by_id, base,
    p2p="numbered", port_sets=port_sets, render_fp="i87proof",
    infra_overrides=R.profile_infra_overrides(PROF),
    model_features=alloc, model_devices=mdevs)
vx3 = [t for t in mf3["tables"] if t.startswith(("VXLAN", "VLAN"))]
print(f"\n{bk.name} overlay tables owned: {vx3}  (must be [] — blast radius)")
