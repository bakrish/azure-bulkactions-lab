# Azure Spot Fleet Provisioning Latency — Campaign Write-up

**Goal:** Minimise time-to-workload-ready for a disposable Spot fleet launched via the (preview) BulkActions API, in service of **unit-cost** optimisation — not a Linux project, a business goal.
**Date:** 2026-06-28 · Region: UK South (provisioning) · Sub: `ME-MngEnvMCAP244865-bakrish-1`
**Status:** Concluded on the testable axes. Images are at the boot floor; the remaining lever (allocation breadth) belongs to the platform, not the image.

---

## 1. Executive Summary

### 1.1 Artifacts produced

| Artifact | Role |
|---|---|
| [tools/provision-bulk.py](tools/provision-bulk.py) | **Provisioner.** Launches N Spot VMs in one BulkActions PUT (`Microsoft.ComputeBulkActions`, api `2026-02-01-preview`, regional ARM endpoint). `az`-only (no SDK). Supports pinned SKU (`--size`), multi-size pinned basket (`--sizes`), attribute-based selection (`--use-attributes` + vCPU/mem/arch ranges, `--exclude-sizes`), Marketplace plan images (`--use-plan`), SIG image ids, SSH-key auth + base64 CustomData, client wall-clock T0. |
| [tools/measure-bulk.py](tools/measure-bulk.py) | **Measurer.** Runs on the in-VNet jump host. Reads the operation's server-stamped T0, discovers the fleet from the operation, and rebases every boot/init anchor onto T0. Emits the orchestration distribution + fleet fill curve and, with `--with-guest`, the infra-independent in-guest `systemd-analyze` split (Kernel/Initrd/Userspace/sd-Total). |
| [tools/rhel9.pkr.hcl](tools/rhel9.pkr.hcl) | RHEL 9 optimised image build (Packer → SIG `sig_rhel/rhel9opt`, v1.0.5). |
| [tools/ubuntu.pkr.hcl](tools/ubuntu.pkr.hcl) | Ubuntu 24.04 optimised image build (Packer → SIG `sig_rhel/ubuntuopt`). |
| [tools/customdata-stamp.sh](tools/customdata-stamp.sh) | Workload-start stamp injected via CustomData; anchors the "workload begins" event. |
| [tools/boot-latency-findings.md](tools/boot-latency-findings.md) | Pre-BulkActions baseline findings (methodology, OS comparison, infra levers). |

### 1.2 Result summary

- **End-to-end is three layers; only one is image-tunable.** Orchestration (control-plane accept, ~5–9s) + PreBoot (allocation/hydration/firmware, **~12s structural floor**) + in-guest boot. Only the in-guest layer responds to image optimisation, and it is a **minority** of wall time.
- **Image optimisation works, then hits a floor.** Tuned images collapse to a **~10–12s in-guest class** regardless of distro (RHEL-opt 11.7s, Ubuntu-opt 10.6s), versus stock (RHEL 30s, Ubuntu 57s). Once optimised, distro choice is **not a moat**.
- **In-guest userspace is CPU-bound and saturates at ~4 vCPU.** cloud-init/early-systemd parallelise across cores; 2→4 vCPU buys ~2.3s, 4→8 vCPU buys ~nothing. **4 vCPU is the knee.**
- **Orchestration (T0 → VM created) varies by image and by time-of-day, for reasons outside our visibility.** AZL consistently measured the lowest orchestration (every run, non-overlapping distributions); freshly-published SIG image versions measured several seconds slower than long-lived / Marketplace images in the same window. These are *observations* — we have no platform-internal data to attribute a mechanism, so we report direction + range, not a cause.
- **The real residual risk is the allocation tail.** Single-SKU Spot produced 70–87s PreBoot stragglers that wreck p99 while p50 stays clean. No image or guest tuning touches this — it is a basket-breadth / allocation-strategy problem the platform owns.

### 1.3 Recommendation

- **Standardise on an optimised image at the floor** (RHEL-opt 1.0.5 or Ubuntu-opt v1.0.1/v2.0.0). The big, durable win is image build, not distro.
- **Size at the 4 vCPU knee** (e.g. D4-class, 16 GiB) for boot; going larger does not speed boot.
- **For the Spot tail, diversify the basket** — use a multi-size pinned basket (`--sizes`) or attribute-based selection with a **wide** envelope. A collapsed (min=max) attribute envelope reduces to a single SKU and keeps the tail.
- **Do not chase sub-second in-guest levers** (plymouth/ModemManager/apparmor-cache, etc.). The cost/benefit is poor and the maintenance/snowflake risk is real. Tier-1 (eliminate snap seeding) captures ~all of the value at ~zero maintenance.

### 1.4 Potential next steps

- Use `--sizes Standard_D4as_v5,Standard_D4s_v5,Standard_E4s_v5` to test whether **basket breadth smooths the 70–87s straggler tail** (forces real cross-family diversification without the attribute selector collapsing to one family).
- Re-measure the same SIG image versions in a later window to see whether the freshly-published orchestration gap persists or narrows, and share the **observation** (not a proposed mechanism) with the BulkActions engineering team.
- (Parked, by customer decision) Azure Compute Fleet attribute-based Spot with `price_capacity_optimized`. BulkActions is the evolution of Compute Fleet, so this was deliberately not pursued.

---

## 2. Measurement Logic

### 2.1 Definition of "readiness"

"Ready" is overloaded, so we measure **four** readiness points, not one — because the platform's notion of "succeeded" fires **before** the workload can run:

| Readiness point | Anchor | What it actually means |
|---|---|---|
| Provisioned (platform) | `operationStatus = Succeeded` / cloud-init report-ready | Fabric considers the VM provisioned. **Fires early** (before snap seeding / late units). A misleading SLA for "ready to run work." |
| Boot complete (systemd) | `systemd-analyze` sd-Total | Kernel + initrd + userspace finished to the default target. Can be inflated by off-critical-path units (e.g. RHEL kdump ~19s) that do **not** gate workload. |
| **Workload-ready (the one that matters)** | `customdata-start.stamp` (CustomData) / `cloud-final.service` | The instant custom-data / scripts-user actually begins. This is **time-to-work**, the business-relevant readiness. |

The campaign treats **workload-ready (CIDone/Work)** as the headline readiness, with the in-guest `systemd-analyze` split as the infra-independent diagnostic.

### 2.2 How each event is measured

Everything is rebased onto **T0** = the bulk operation's server-stamped `createdTime` (the single shared origin for all N VMs).

```
T0 ──Orchestration──> timeCreated ──PreBoot──> kernel-start ──in-guest──> workload
     (control-plane)                 (alloc/hydrate/firmware)   (systemd + cloud-init)
```

The measurer collects control-plane timestamps via `az`, then SSHes to each VM's private IP and runs a small collector that first blocks on `cloud-init status --wait` (so the logs/status files are final) and then samples the in-guest sources below. Exact source for every event:

| Event | Source on the box | How it is read |
|---|---|---|
| **T0** | BulkActions operation resource | `GET .../launchBulkInstancesOperations/{id}` → `properties.createdTime` (server-stamped UTC). The shared origin for all N VMs. |
| **timeCreated** | VM resource | `az vm ... timeCreated` (control-plane UTC). **Orchestration = timeCreated − T0.** |
| **kernel-start (boot epoch)** | `/proc/uptime` | `time.time() − uptime_seconds`. Sub-second. We deliberately avoid `uptime -s`, which floors to the whole second and skews boot-relative reconstruction. **PreBoot = kernel-start − timeCreated.** |
| **Provisioned / report-ready** | `/var/log/cloud-init.log` | Scan for the line containing both "report" and "ready" (cloud-init reporting ready to the Azure fabric); parse its leading `YYYY-MM-DD HH:MM:SS` timestamp. Last match = the current boot. |
| **Kernel / Initrd / Userspace / sd-Total** | `systemd-analyze time` | Parse the `Startup finished in … (kernel) + … (initrd) + … (userspace) = …` line. Each value is measured by systemd from the uptime origin, so it **excludes T0 and PreBoot** (the infra-independent boot signal). Durations summed across `min`/`s`/`ms` units; `initrd` is absent on some distros (e.g. Ubuntu) and renders blank. |
| **Workload start** | `/var/lib/customdata-start.stamp` | CustomData script ([tools/customdata-stamp.sh](tools/customdata-stamp.sh)) writes an epoch stamp the instant scripts-user runs. Read as a float. |
| **Workload-ready (CIDone)** | `/var/lib/cloud/data/status.json` | `v1.modules-final.finished`. If recorded as seconds-since-boot (newer cloud-init, e.g. AZL 3.0) instead of an absolute epoch, reconstruct as `boot_epoch + value`. |

### 2.3 Why each layer matters

| Event / layer | What it captures | Why it matters | Typical |
|---|---|---|---|
| **Orchestration** | T0 → `VM.timeCreated` | Control-plane ingest/validate/stamp. **Observed** to vary by image and by time-of-day window; mechanism not visible to us. | 3.5–9s (window-dependent) |
| **PreBoot** | `timeCreated` → kernel-start | Allocation, placement, disk hydration, UEFI, Secure Boot/vTPM. **Structural ~12s floor**, region/SKU-invariant. The straggler tail lives here. | ~12s (tail 70–87s) |
| **Kernel** | systemd-analyze | Kernel self-init. Rock-solid, image-fixed. | 1.4–1.9s |
| **Initrd** | systemd-analyze | dracut/initramfs. Tunable; Canonical's linux-azure initramfs is ~free. | 0–3s |
| **Userspace** | systemd-analyze | systemd + **cloud-init** to default target. **CPU-bound, the main tunable surface.** All first-boot baggage lives here. | 5.4–55s |
| **Workload (CIDone)** | T0 → custom-data start | The business metric: when work can begin. | ~28–33s (optimised) |

Why the layering matters: it separates what the **image owner** controls (in-guest) from what the **platform** controls (orchestration + PreBoot). Most of the wall-clock and **all** of the catastrophic tail are platform-side.

### 2.4 Caveats and potential issues

- **In-guest is NOT fully infra-independent.** First-boot units that read off the OS disk (apparmor profile compile, fsck, boot.mount) measured several seconds slower on some runs than others **for the same image**. We confirmed one concrete cause directly — apparmor recompiling profiles because the cache hash shipped in the image did not match the running kernel (seen in `journalctl -u apparmor` and the two hash dirs under `/var/cache/apparmor/`). The remaining run-to-run variation is consistent with host-level I/O and CPU contention, but we cannot measure the host directly and do not assert a specific cause. Always pull `systemd-analyze blame` (flat) when userspace is variable; `critical-chain` truncates parallel branches.
- **systemd boot-complete ≠ workload-ready.** On stock RHEL, `systemd-analyze time` userspace includes kdump (~19s) finishing **after** the usable target. The truer signal is "multi-user.target reached after". Optimising kdump cleans the boot chart and kills a reliability tail but moves workload-readiness **zero**.
- **Orchestration magnitude is window-sensitive.** The image *ordering* (AZL lowest, every run) is stable; the absolute numbers drift by several seconds depending on the time-of-day window. Report **direction + range**, not a fixed number.
- **Attribute envelope collapse.** `--use-attributes` with min=max vCPU/mem reduces to a single SKU → no scarcity diversification → the single-SKU tail returns. Breadth requires a wide envelope or a multi-size `--sizes` basket.
- **Quantisation.** The client wall-clock "submit → all-terminal" is accurate to ±1 `--poll-seconds` interval; per-VM precision comes from measure-bulk's control-plane timestamps.
- **n is small (n=5–10 per cell).** Good for medians and spread; stragglers are caught but rates (eviction, p99) need larger fleets/windows.

---

## 3. Results Summary

### 3.1 Cross-tab — all recently tested configurations

In-guest `systemd-analyze` p50 (seconds). sd-Total is the infra-independent boot signal; CIDoneT0 is end-to-end workload-ready from T0 (infra-confounded). **n** = number of VMs measured in that cell, each from a single bulk launch (medians/spreads are over those VMs, not a single sample).

| Image / config | Size | n | Kernel | Initrd | Userspace | **sd-Total** | CIDoneT0 (E2E) | Note |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Ubuntu 24.04 server (stock) | D2 | 10 | 1.2 | ~0 | 55.3 | **56.6** | 76.9 | snapd.seeded ~42s on-chain + pollinate |
| Ubuntu 24.04 Minimal (stock) | D2 | 5 | 1.4 | ~0 | ~53 | **54.3** | — | bimodal; Minimal STILL seeds snaps |
| RHEL 9 lvm-gen2 (stock) | D2 | 10 | 1.9 | 4.6 | 28.6 | **35.1** | 50.6 | kdump ~19s (cosmetic, off-chain) |
| RHEL 9 raw-gen2 (stock) | D2 | 10 | 1.8 | 2.8 | 25.4 | **29.8** | ~49 | leanest stock v9; kdump present |
| AZL 3.0 marketplace (stock) | D2 | 10 | 0.8 | 1.4 | 13.2 | **15.5** | 34.5 | clean by default; no baggage |
| RHEL SIG rhel8opt (optimised) | D2 | 10 | 0.6 | 2.9 | 11.5 | **15.0** | — | earlier optimised baseline |
| **RHEL-opt 1.0.5** | **D2** | 5 | 1.5 | 2.6 | 7.7 | **11.7** | 33.3 | kdump+grub+disk_setup trimmed |
| **RHEL-opt 1.0.5** | **D4as_v5** | 5 | 1.4 | 2.8 | 5.4 | **9.5** | 28.1 | 4 vCPU knee |
| **RHEL-opt 1.0.5** | **D8as_v5** | 5 | 1.4 | 2.2 | 5.4 | **8.9** | 28.2 | flat vs D4 (one 87s PreBoot outlier excl.) |
| **Ubuntu-opt v1.0.1** | D2 | 5 | 1.5 | ~0 | 9.0 | **10.6** | 30.8 | snapd purged, networkd-wait masked |
| Ubuntu-opt v2.0.0 (Minimal+preseed, Tier-1) | D2 | 5 | 1.4 | ~0 | 5.4* | **15.5** | ~28 | capability-preserving; untuned Tier-1 |

\*v2.0.0 userspace reflects pre-seed reclaiming snap time while keeping snap functional; sd-Total higher than v1.0.1 because Tier-2/3 trims were deliberately **not** applied (customer chose zero-maintenance Tier-1).

**Cross-tab verdict:** Optimisation moves the needle from 30–57s (stock) to a **~9–16s optimised class**. Once optimised, distros converge; the remaining spread is size (vCPU) and which trims were applied.

### 3.2 Top-3 configurations — breakdown

**#1 — RHEL-opt 1.0.5 @ D4as_v5 (4 vCPU) — sd-Total 9.5**
- Kernel 1.4 / Initrd 2.8 / Userspace 5.4. Sits at the **4 vCPU knee** — fastest practical boot.
- Achieved by Packer: disable kdump, `GRUB_TIMEOUT=0`, trim cloud-init `disk_setup`/`mounts`, pin `datasource_list:[Azure]`, disable NetworkManager-wait-online.
- Workload-ready CIDoneT0 ~28s (PreBoot + cloud-init floor dominate the remainder).

**#2 — Ubuntu-opt v1.0.1 @ D2 — sd-Total 10.6**
- Kernel 1.5 / Initrd ~0 (linux-azure initramfs effectively free) / Userspace 9.0.
- Wins purely via the free initrd; userspace slightly heavier than RHEL (Ubuntu service set + 3-stage serial cloud-init).
- Achieved by: `apt purge snapd modemmanager apport udisks2`, **mask** (not disable) networkd-wait-online, disable lxd-installer.socket.

**#3 — RHEL-opt 1.0.5 @ D2 / AZL 3.0 stock — sd-Total 11.7 / 15.5**
- RHEL-opt at 2 vCPU pays the ~2.3s userspace CPU penalty vs D4.
- AZL 3.0 hits ~15.5s **with zero tuning** — proves a lean image reaches the floor for free; but AZL 3.0 is a dead-end (4.0 is a full rearchitecture) and not enterprise-support-aligned here.

### 3.3 SKU-level comparison (RHEL-opt 1.0.5, vertical scaling)

All three cells **n = 5** (one bulk launch per size), p50.

| Size | vCPU | n | Userspace | sd-Total | Δ Userspace | CIDoneT0 |
|---|---:|---:|---:|---:|---:|---:|
| D2(ad)s_v5 | 2 | 5 | 7.7 | 11.7 | — | 33.3 / ~28 |
| D4as_v5 | 4 | 5 | 5.4 | 9.5 | −2.3 | 28.1 |
| D8as_v5 | 8 | 5 | 5.4 | 8.9 | ~0 | 28.2 |

- **Userspace is CPU-bound and saturates at ~4 vCPU.** cloud-init + early systemd parallelise; 2→4 vCPU buys −2.3s, 4→8 buys ~nothing.
- **End-to-end CIDoneT0 is flat (~28s) from 4 vCPU up** — PreBoot (~12s) + the cloud-init floor dominate, so paying for bigger VMs does **not** buy faster time-to-work.
- **Knee = 4 vCPU / 16 GiB.** That is the boot-optimal size; choose larger only for the workload itself, not for boot.

### 3.4 Recommendations (results-driven)

1. **Image:** ship an optimised image (RHEL-opt 1.0.5 or Ubuntu-opt v1.0.1/v2.0.0). The ~20–45s win is the build, repeatable across distros.
2. **Size:** D4-class (4 vCPU / 16 GiB) — the boot knee.
3. **Spot tail:** diversify the basket (`--sizes` multi-family, or a **wide** attribute envelope). Single-SKU Spot owns the 70–87s straggler risk.
4. **Maintenance posture:** Tier-1 only (kill snap seeding via build-time pre-seed; strip kdump/grub countdown on RHEL). Skip sub-second snowflake trims.
5. **Measure workload-ready, not "succeeded."** The platform's success signal fires before work can run.

---

## 4. Other Important Points

- **The Minimal SKU myth.** `Canonical:ubuntu-24_04-lts:minimal:latest` still ships snapd and still seeds snaps on first boot (snapd.seeded ~43s on the critical chain). The "40% faster / no snap seeding" claim is **false** in this context. The boot win was never the SKU — it was deterministically handling snapd. The capability-preserving fix is a **build-time `snap wait system seed.loaded`** pre-seed (reclaims ~43s while keeping snap/Livepatch fully functional), not purging snapd.
- **Optimisation is image-agnostic.** RHEL-opt beat AZL-SIG only because RHEL trimmed cloud-init `disk_setup` and the AZL capture did not — apply the same trim to AZL and it ties. The win is the **optimisation**, not the distro.
- **Two distinct variance sources, both infra-side and outside the image's control.** Orchestration (T0 → timeCreated) varied by image and by window; separately, in-guest first-boot disk reads (apparmor compile, fsck, boot.mount) varied run-to-run for the *same image* (one run: orchestration a fast 3.0s yet userspace inflated by a 9s apparmor recompile). We characterise both by their **observed pattern**; we do not have host-level visibility to assert a cache or warmth mechanism.
- **kdump is cosmetic, grub_timeout is real.** On RHEL, stripping kdump cleans the boot chart and removes a reliability tail but does not speed workload-readiness; `GRUB_TIMEOUT=0` is the only RHEL trim that buys real workload latency (~5s bootloader countdown).
- **Enterprise constraint.** Supported, mainstream distros only — no hand-crafted init systems or exotic boot pipelines (Alpine rejected; AZL 4.0 preview not GA). Optimisation must stay within supportable bounds.
- **What we did NOT pursue (deliberately).** 50-VM quota-saturation run (low insight), Azure Compute Fleet (BulkActions supersedes it), and deep Tier-2/3 in-guest trims (poor cost/benefit, snowflake risk).
