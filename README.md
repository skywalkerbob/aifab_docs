# gpufab-docs

Design, instructions, and playbooks for **gpufab** — a simulated GPU-cloud network fabric
(NVIDIA DGX B300 pod · SONiC NOS · containerlab on GCP · NetBox as source of truth · GitOps).

## Contents

| Directory | Purpose |
|---|---|
| [`design/`](design/) | Architecture & design documents, now split in two: **[network-automation-design.md](design/network-automation-design.md)** is the **substrate-agnostic automation blueprint** (NetBox SoT, GitOps, ZTP, telemetry, remediation) — concrete SONiC/DGX example, structured to generalize, with a **physical-hardware bootstrap** chapter. **[gpufab-sim-design.md](design/gpufab-sim-design.md)** is the **simulation platform** that exercises it on GCP (containerlab/vrnetlab/QEMU, fidelity contract, sim-only findings). Read the automation doc first; the sim doc references it. |
| [`playbooks/`](playbooks/) | Step-by-step build instructions, one per build phase (written as each phase is executed). |
| [`runbooks/`](runbooks/) | Operational procedures: demo storyline, chaos drills, start/stop, troubleshooting. |

## Status

- **2026-07-23** — Design document v1 complete and under review. Implementation not started.
- **2026-07-23** — Design v1.1: parameterized profile system, native resource estimator, and the `gpufab` lifecycle CLI (design ch. 13); working CLI landed in gpufab-platform.
- **2026-07-24** — Live build to a 64-GPU (8×8) fabric: NetBox-driven render, ZTP + config-push backfill (148/148 host BGP), GitOps loop proven end-to-end (a NetBox edit auto-opens a rendered PR), reboot-recovery hardening.
- **2026-07-24** — **Design split into two docs**: the substrate-agnostic automation blueprint (usable to bootstrap physical infra) + the GCP simulation platform that exercises it.

## Related repositories

- [`gpufab-platform`] **exists**: `gpufab` CLI (validate/topology/estimate + deploy→sim→destroy orchestrator), profiles, GCP machine catalog; Terraform/Ansible/images land in phases P0+
- [`gpufab-network`] **exists**: the GitOps repo — design-as-code (profiles/policy/NetBox schema), templates, `rendered/` convention, render/validate/deploy/drift workflows; tool implementations land in P2–P6
