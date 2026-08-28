# Playbooks

Step-by-step build instructions for each phase of the [build plan](../design/gpufab-sim-design.md#15-build-plan).
Each playbook is written as its phase is executed, capturing exact commands and the validation gate results.

| Playbook | Phase | Status |
|---|---|---|
| `p0-foundation.md` | Terraform, host bootstrap, tunnels | not started |
| `p1-images.md` | sonic-vm build, gpufab-host/head images, C1 checkpoint | not started |
| `p2-netbox-seed.md` | NetBox deploy, schema, seeder | not started |
| `p3-topology.md` | Topology generation, bring-up, LLDP audit | not started |
| `p4-render.md` | Templates, render pipeline, C2 checkpoint | not started |
| `p5-ztp.md` | DHCP/HTTP infra, fleet-wide true ZTP | not started |
| `p6-gitops.md` | Runner, workflows, webhook relay | not started |
| `p7-telemetry.md` | gnmic, Prometheus, dashboards | not started |
| `p8-remediation.md` | Bot, chaos CLI, drills 1–4 | not started |
| `p9-slurm-ddn.md` | Slurm, DDN sim, drill 5 | not started |
| `p10-full-demo.md` | Full profile, demo rehearsal | not started |
