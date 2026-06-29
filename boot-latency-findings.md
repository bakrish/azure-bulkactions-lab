# Azure VM Provisioning Latency — Findings

**Goal:** Minimise time-to-ready for a disposable Spot fleet, in service of **unit-cost** optimisation.
**Status:** ~40s original → **~19s** (AZL, bare) / **~23.5s** (AZL, fully secured + stable).
**Date:** 2026-06-25 · Region: UK South (unless noted) · Size: `Standard_D2s_v5` (unless noted)

---

## 1. Measurement methodology

Three timestamps ("anchors") per VM:

| Anchor | Source | Field | Marks | Clock | Precision |
|---|---|---|---|---|---|
| `created` | `az vm get-instance-view` | `.timeCreated` | VM resource accepted by the control plane | Control-plane (UTC) | sub-second |
| `boot` | `az vm run-command invoke "uptime -s"` | parsed stdout | Kernel start (wall-clock) | Guest OS, **NTP-synced** | ±1s |
| `succeeded` | `az vm get-instance-view` | `ProvisioningState/succeeded` time | Guest agent reported ready | Control-plane (UTC) | sub-second |

**Derived metrics**

```
PreBoot = boot      - created     (allocation + firmware + boot-prep, BEFORE kernel start)
Guest   = succeeded - boot        (kernel + userspace bring-up, AFTER kernel start)
E2E     = succeeded - created     ( = PreBoot + Guest )
```

**Timeline**

```
created                      boot (uptime -s)                 succeeded
  |--------- PreBoot ----------|------------ Guest ------------|
  |  allocation / placement    |  kernel init                 |
  |  disk attach + hydrate     |  systemd / userspace         |
  |  UEFI firmware             |  cloud-init / waagent        |
  |  Secure Boot + vTPM (TL)   |  agent signals "provisioned" |
  |  GRUB -> kernel handoff    |                              |
  |---------------------------- E2E -----------------------------|
```

**Notes**
- `created` and `succeeded` share the control-plane clock → **E2E is exact**. `uptime -s` is NTP-aligned → PreBoot/Guest accurate to ±1s.
- `uptime -s` (kernel start) is the correct anchor — **not** `/var/log/messages` first line (rsyslog start, pre-NTP, ~5s later).
- **Allocation latency IS captured** (it lands in PreBoot). Proven by the Spot run: capacity scarcity inflated PreBoot to 41s — impossible if allocation were stamped before `created`.
- `systemd-analyze` (in-guest firmware/kernel/userspace split) was used only as an independent cross-check on the Guest phase, **not** as an input to these metrics.

---

## 2. OS / image comparison (on-demand)

| Image | Region | PreBoot | Guest | E2E | n | Note |
|---|---|---|---|---|---|---|
| RHEL 8 **original** (kdump + agents on) | mixed | ~12.5 | ~27* | **~40** | — | *inferred — starting point |
| RHEL 8 **optimised** golden image | mixed | ~12.5 | ~12 | ~24–26 | — | kdump off + timers no-op'd |
| AZL 3.0 | SE Asia | 12.3 | 12.0 | 24.3 | 1 | single sample |
| AZL 3.0 | UK South | 12.6 | 14.1 | 26.7 | 1 | single sample (slow host) |
| **AZL 3.0** | UK South | **10.7** | **8.0** | **19.0** | 5 | controlled median — **fastest** |
| Ubuntu 24.04 server | UK South | 12.3 | 9.6 | 21.8 | 1 | single sample (lucky) |
| Ubuntu 24.04 server | UK South | 13.0 | 12.8 | 25.2 | 5 | controlled median |
| Ephemeral OS disk (D2ds_v5) | UK South | 15.9 | 12.2 | 28.0 | 1 | ephemeral — **worse** (+image copy) |

**Verdict:** At n=5 head-to-head, **AZL 3.0 (19.0s) beat Ubuntu (25.2s)** with barely-overlapping distributions. Single-sample runs had misleadingly favoured Ubuntu.

---

## 3. Infra levers on AZL 3.0 (on-demand, n=5 each)

| Arm | PreBoot | Guest | E2E |
|---|---|---|---|
| A — baseline (inline net, RW cache) | 11.2 | 8.1 | 21.0 |
| B — pre-staged subnet | 10.6 | 11.4* | 23.3 |
| C — ReadOnly OS cache | 10.5 | 8.2 | 19.5 |
| D — subnet + ReadOnly cache | 10.7 | 8.2 | 18.8 |

*B's Guest is a jitter outlier.

**Verdict:** PreBoot is flat (10.5–11.2s) — **no lever moves per-VM latency**; E2E deltas are within noise + time-of-day. Pre-staged subnet's only real win is **wall-time + fleet throughput** (invisible to E2E). ReadOnly cache = harmless free default.

---

## 4. Security + Spot (AZL 3.0, realistic config)

| Config | Priority | PreBoot | Guest | E2E | n | Note |
|---|---|---|---|---|---|---|
| **Reference build** (Trusted Launch + subnet + RO cache) | on-demand | 12.2 | 10.4 | **23.5** (19–24) | 5 | stable, secured — **headline number** |
| Same config + Spot | Spot | 20.0 | 10.4 | 33.6 (26–56) | 5 | single-SKU — **highly variable** |

**Trusted Launch tax ≈ +3s** (≈ +1.3s PreBoot firmware/vTPM, ≈ +2s early-guest), measured cleanly on-demand.
**Spot variance (26–56s)** is **single-SKU scarcity**, not the image/TL — a **Fleet-basket** problem.

---

## 5. Levers tested and rejected

| Lever | Result | Why |
|---|---|---|
| Region (SE Asia vs UK South) | ❌ no effect | Allocation floor ~12s is region-invariant |
| Ephemeral OS disk | ❌ worse (+3s PreBoot) | Upfront image copy to local disk |
| Pre-staged subnet (for per-VM latency) | ❌ noise | Real value is wall-time + fleet throughput |
| ReadOnly OS cache (for latency) | ➖ neutral/marginal | Harmless free default; no clear per-VM win |
| Single-SKU Spot | ❌ high variance | Worst case; fixed by Fleet basket breadth |
| v6 / NVMe | *(excluded from this report)* | Tested separately |

---

## 6. Headline & recommendation

> **AZL 3.0**, full secured production config (**Trusted Launch + pre-staged networking + ReadOnly cache**), on-demand: **~23.5s median, stable 19–24s range.**
> Drop Trusted Launch (if not mandated) → **~20s**.

**Composition of the ~23s secured floor:** ~12s allocation (structural, region/SKU-invariant) + ~8s guest + ~3s Trusted Launch.

- **Image:** AZL 3.0 fastest; **Ubuntu** the governance-safe near-equal alternative (broader ISV/cert ecosystem).
- **Biggest historical win:** kdump removal + agent-timer no-op (~40s → ~24s) — all guest-side.
- **Per-VM infra levers:** ≈ noise. The real cost dials are **image choice + Fleet basket + allocation strategy**.
- **Spot:** allocation variance belongs to the Fleet basket, not the boot path.

---

## 7. Next step (open)

Measure **SKU-agnostic Spot** via an **Azure Compute Fleet** with attribute-based selection — the production path we could not reproduce with `az vm create` (which requires a fixed `--size`):

- `vmAttributes`: e.g. `vCPUCount 2–4`, `memoryInGiB 4–16`, family include/exclude per governance
- allocation strategy: `price_capacity_optimized`
- capture **Fleet-submit → all-N-ready**, the SKU mix chosen, basket price, and eviction rate over a window

This yields the real Spot latency + basket price + eviction in one shot — the inputs that actually drive **$/unit-of-work**.
