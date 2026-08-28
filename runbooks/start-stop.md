# Start / stop and preemption recovery

What happens when a fabric host goes away, what comes back on its own, and what
does not. Measured on **gpufab-s4-fabric** (SPOT, profile s1-512) on 2026-07-26
by stopping it with `gcloud compute instances stop` and then observing without
intervening.

Run the drill this way — issue the stop and then *watch*. Every number below is
from that run; nothing here is inferred from reading the scripts.

## The two units

| unit | host | stage | job |
|---|---|---|---|
| `gpufab-fleet-watchdog.timer/.service` | **ops** | 97 | every 2 min, start any `name~fabric` instance that is not RUNNING |
| `gpufab-rebuild.service` | **fabric** | 98 | on boot, repopulate emulation state from the SoT |

They are deliberately split across hosts: the ops host is not spot, so it is
still there to notice that the fabric host is gone.

## Measured timeline

| t | event | delta |
|---|---|---|
| 23:45:51 | `instances stop` issued | — |
| 23:46:43 | status `TERMINATED` | 52 s |
| 23:46:43 | watchdog logs `gpufab-s4-fabric is TERMINATED — starting` | same second |
| 23:46:53 | start API call issued | +10 s |
| 23:47:01 | status `RUNNING` | **17 s from TERMINATED** |
| 23:47:29 | sshd answering | +28 s |
| 23:47:31 | `gpufab-rebuild` sees 76 of 124 nodes, declares PARTIAL, starts | +2 s |
| 23:47:41 | `40-topology`: 124 nodes, 1466 links, 48 sonic-vm generated from the SoT | |
| 23:51:40 | all 48 switch VMs healthy | ~4 min from clab deploy |
| 23:51:40 | `waiting for SONiC config DB` — probe never succeeds, burns its full allowance | **+10 min, wasted** |
| 00:03:21 | stage 50 (ZTP) begins: TACACS up, rendering from NetBox | |
| 00:07 | **observation stopped here.** `gpufab-rebuild.service` still `activating` | **>19 min, not finished** |

**The rebuild did not complete inside the observation window.** Node count and
QEMU count were fully restored (124 / 49) but BGP was still 0 and the service
was still `activating` when measurement stopped. Budget **well over 20 minutes**
for a cold S1 rebuild, and do not treat "instance RUNNING" or "124 containers"
as recovery — neither implies a routing fabric.

Ten of those minutes are pure waste: `40-topology`'s `waiting for SONiC config
DB` probe polls `sonic-cfggen` 30 times at 20 s and then proceeds **regardless**
of the outcome, so when it cannot succeed it costs the full 600 s and changes
nothing. It is a sleep with extra steps.

**Detection latency is luck.** The timer fires every 2 minutes and happened to
run one second after the instance reached TERMINATED. Budget **up to 120 s**
before the restart is even attempted; 17 s is the best case, not the typical
one.

## What survives a stop/start, and what does not

This is the part that makes a preempted host dangerous rather than merely down:

| | restart policy | after boot |
|---|---|---|
| 76 FRR host containers | `always` | **came back by themselves** |
| 48 SONiC switch containers (QEMU) | `no` | **did not come back** |

So the host boots with **76 of 124 nodes**, Docker healthy, exporters running,
dashboards answering — and no switches. Every signal says the host is fine. The
BGP count simply drops and nothing says why.

That is why `gpufab-rebuild` compares against the SoT's device count and not
against zero. A check for "any nodes present" sees 76 and declares victory.

## The trap: which SoT does the rebuild use?

Stage 98 generates `/usr/local/bin/gpufab-rebuild` from a **quoted** heredoc, so
until 2026-07-26 the expression `${NETBOX_URL:-http://10.10.0.20:8000}` was
written into the script verbatim and evaluated at *run* time — under systemd,
where `NETBOX_URL` does not exist. Every fabric host therefore rebuilt itself
from `gpufab-ops-01` regardless of which ops host actually held its SoT.

Measured on s4-fabric, whose SoT is `10.10.0.41`:

    systemctl show gpufab-rebuild.service -p Environment   ->  Environment=
    resolved SoT in that environment                       ->  http://10.10.0.20:8000

It was **silently** wrong: both NetBoxes answer 200 and both hold 124 devices,
so the count gate passes and the rebuild proceeds to build this host's fabric
from another sim's intent. No device count exposes this.

Stage 70 gets it right on the same host by accident of quoting — its heredoc is
unquoted — so `gpufab-exporter.service` carried the correct address while
`gpufab-rebuild.service` carried none. Two units, one host, two answers to
"where is my SoT".

The URL is now resolved once at install time, proven to answer 200 *and* hold
devices, and baked in. `tests/t12-recovery-units.sh` asserts it from the runtime
side — what `systemctl show` has loaded, and what the script resolves under
`env -i` — because every check that ran in a login shell passed while the bug
was live.

**If you re-run stage 98 by hand, `NETBOX_URL` must be set**, or it now refuses
to install rather than guessing:

    cd /opt/gpufab/gpufab-platform/deploy && sudo NETBOX_URL=http://<this-sim-ops>:8000 \
      ROLE=fabric PROFILE=<profile> bash ./98-spot-rebuild.sh

## Verifying recovery

Do not trust the unit's exit code; it is a `oneshot` that has reported success
having rebuilt nothing.

    # from the workstation
    tests/verify.sh --host gpufab-s4-fabric --ops gpufab-s4-ops --sot 10.10.0.41 --only recovery
    tests/verify.sh --host gpufab-s4-fabric --ops gpufab-s4-ops --sot 10.10.0.41 --only applied

    # on the fabric host — the two numbers that matter
    sudo docker ps --format '{{.Names}}' | grep -c '^clab-'      # expect the SoT's device count
    curl -s localhost:9101/metrics | awk '/^gpufab_bgp_peer_up/ {s+=$2} END {print s}'

## Known ceiling: 1286 sessions, not the full peer count

Both s3 and s4 plateau at **1286** BGP peer series up out of **1464**. This is
not a convergence failure and waiting does not improve it — the count is stable
across repeated verification passes, and `t11-config-applied` passes, so the
rendered config does reach the switches.

The cause is the emulated switch's port count. Every leaf establishes *exactly*
32 sessions regardless of how many neighbours it is configured with:

| switch | BGP_NEIGHBOR configured | established |
|---|---|---|
| backend leaf | 34 | 32 |
| `fr-leaf02` | 52 | 32 |
| `st-leaf01` | 48 | 32 |
| `st-spine01` | 3 | 0 |

The switch VM has 32 Ethernet interfaces and 32 addressed interfaces, while
`BGP_NEIGHBOR` correctly holds all 34. `vm_port()` maps a NetBox port to
`Ethernet{4*idx}` against a 32-port hwsku with no bound check, so the 33rd link
onward is rendered onto a port that does not exist, gets no address, and its
session never leaves `Active`. The storage spines reach 0/3 because their leaves
had already exhausted 32 ports before the spine uplinks were mapped.

The shortfall reconciles exactly: 32 backend leaves x 2, plus 19+20+19 on the
frontend leaves, plus 16+18+16 on the storage leaves, plus 6 on the storage
spines = **178** = 1464 - 1286.

The fix is a real >32-port HWSKU (`Accton-AS7816-64X`) in
`tools/switch_catalog.yaml` plus a matching PORT table in
`design/base/vs_port_sets.json`, with the render refusing to emit a device whose
interfaces exceed its SKU. Deployed fabrics built before that change keep the
32-port table and stay at 1286 until their topology is regenerated.

## Every switch is at the FACTORY password after a rebuild

`containerlab destroy` throws the switch VMs away, so a rebuilt fabric comes
back on the factory password (`admin`) and stays there until `60-auth` runs.
Anything reaching for a switch between `40-topology` and `60-auth` must try
`admin` first — `interim_deploy.py` does exactly that, and it is why the config
push works during a rebuild while password-pinning tooling does not.

Two independent barriers bite in that window, and both look like "the switch is
down" when it is not:

1. **Host keys change.** Every VM regenerates its SSH host key on redeploy.
   `StrictHostKeyChecking=no` is *not* enough — it only auto-accepts a key never
   seen before; a key that *conflicts* with `known_hosts` is still a hard
   refusal (`REMOTE HOST IDENTIFICATION HAS CHANGED`, rc=255). You need
   `UserKnownHostsFile=/dev/null` as well. `t11` was missing it and reported 48
   healthy switches as unreachable.
2. **Password.** rc=5 `Permission denied` right after a rebuild usually means
   the switch is at factory and the caller offered the rotated password.

rc=255 and rc=5 are worth distinguishing on sight: the first is your key cache,
the second is where the fabric is in its lifecycle. Neither is a broken switch.

## Summary: what recovers unattended

- **Yes, proven** — the instance restarts (stage 97, ops host): 17 s, no human,
  and `automaticRestart: false` rules out GCP having done it.
- **Yes, proven** — stage 98 correctly classifies a 76/124 boot as PARTIAL,
  reaches the **correct** SoT, and regenerates the full topology (124 nodes,
  1466 links, 48 sonic-vm) with all 48 VMs healthy in ~4 min.
- **Not observed to completion** — the run above was still `activating` at
  19 minutes with 0 BGP sessions. Node recovery is proven; *routing* recovery
  was not, in this window.
- **No** — nothing raises the 1286 ceiling; that needs the HWSKU change above.
- **Caveat** — a host whose stage 98 predates 2026-07-26 will rebuild from
  `10.10.0.20` no matter which sim it belongs to. Re-run stage 98 with
  `NETBOX_URL` set, then confirm with `t12`.
