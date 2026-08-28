"""Negative-path controls: every guard must be shown FAILING, not assumed."""
import sys, yaml, copy
S = "/tmp/claude-1000/-mnt-data-bob-sim/93a1e4d6-8d92-46a0-84a4-d3e92388eceb/scratchpad/i87"
sys.path.insert(0, S + "/gpufab-platform/tools")
import fabric_model as fm

P = S + "/gpufab-network/design/profiles/scale/s1-512.yaml"
base = yaml.safe_load(open(P))


def case(label, mutate):
    p = copy.deepcopy(base)
    mutate(p)
    try:
        fm.derive(p, "vm")
        print(f"  NO-RAISE   {label}   <-- BAD: this must fail")
        return 0
    except fm.ModelError as e:
        print(f"  ModelError {label}")
        print(f"             {' '.join(str(e).split())[:170]}")
        return 1
    except Exception as e:
        print(f"  {type(e).__name__} (not ModelError) {label}: {str(e)[:150]}")
        return 0


n = 0
n += case("unknown FEATURE NAME (vxlann)",
          lambda p: p["features"].update({"vxlann": {"segments": [{"name": "x", "vlan": 10}]}}))
n += case("unknown KEY in block (segement)",
          lambda p: p["features"]["evpn"].update({"segement": []}))
n += case("NOS lacks capability (arista_eos)", lambda p: p.update({"nos": "arista_eos"}))
n += case("config_mode missing (2nd order)", lambda p: p.pop("config_mode"))
n += case("vlan out of range (4095)",
          lambda p: p["features"]["evpn"]["segments"].__setitem__(0, {"name": "a", "vlan": 4095, "prefix": "10.1.0.0/24"}))
n += case("duplicate vlan",
          lambda p: p["features"]["evpn"]["segments"].__setitem__(1, {"name": "b", "vlan": 100, "prefix": "10.1.0.0/24"}))
n += case("envelope exceeded (vni:1)",
          lambda p: p["addressing"]["envelope"].update({"vni": 1}))
n += case("VNI past 2**24", lambda p: p["features"]["evpn"].update({"vni_base": 16777200}))
n += case("anycast_gw on, no prefix",
          lambda p: p["features"]["evpn"]["segments"].__setitem__(0, {"name": "a", "vlan": 100}))
n += case("no segments", lambda p: p["features"]["evpn"].update({"segments": []}))
n += case("fabrics: [oob] (unrouted mgmt)", lambda p: p["features"]["evpn"].update({"fabrics": ["oob"]}))
n += case("typo fabric name (frontned)", lambda p: p["features"]["evpn"].update({"fabrics": ["frontned"]}))
n += case("bare `evpn: true`", lambda p: p["features"].update({"evpn": True}))
print(f"\n{n}/13 negative cases raised ModelError at DERIVE time")
