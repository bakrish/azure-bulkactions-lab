Read [](file:///c%3A/Users/bakrish/OneDrive%20-%20Microsoft/TSO/Customers/SCB/tools/ba-results-2026-06-27.md#1-1), lines 1 to 60

Read [](file:///c%3A/Users/bakrish/OneDrive%20-%20Microsoft/TSO/Customers/SCB/tools/ba-results-2026-06-27.md#60-60), lines 60 to 135

Here's the consolidated cross-distro reference, organized by the layer model so each number is read with the right caveat. All p50, n=10 (unless noted), `Standard_D2ads_v5`, uksouth, Spot.

## A. In-guest boot — infra-independent, STABLE (the layer you control)
This is the trustworthy cross-image comparison (kernel-origin, immune to placement/window).

| Image | sd-Total | Kernel | Initrd | Userspace | Notes |
|---|---:|---:|---:|---:|---|
| **AZL 3.0** (mkt / SIG) | **14.6–15.5** | 0.8 | 1.5 | 12.3–13.2 | lean kernel+initrd = the real AZL edge |
| **RHEL9 optimized** | **15.4–16.1** | 1.7 | 3.1 | 11.2 | ≈ AZL floor; pays v9 kernel/initrd, recovers in userspace |
| RHEL8 optimized (SIG) | 15.0 | — | — | — | campaign baseline |
| RHEL9 **marketplace** | **29.8** | 1.7 | 2.8 | 25.3 | kdump first-boot rebuild (cosmetic/off-chain) |
| Ubuntu 24.04 mkt | **56.6** | — | — | — | `snapd.seeded` ~42s **on-chain (real)** |

**Takeaway:** optimized RHEL9 ≈ clean AZL on the controllable layer (~1s apart). Marketplace baggage (kdump, snapd) is the whole spread.

## B. Orchestration — WINDOW/WARMTH-SENSITIVE (not image-controllable)
Reframed by tonight's discriminator: this tracks **replica cache warmth**, not lineage/plan/size.

| Serve state | Image | Orch |
|---|---|---:|
| **Warm** (mkt / long-lived) | Ubuntu mkt | 3.5 |
| | AZL mkt | 4.0–5.1 |
| | RHEL8 mkt / rhel8opt-SIG (warm) | 5.0–5.6 / 5.2 |
| | RHEL9 mkt | 7.0 |
| | Flatcar mkt (plan-bearing) | 6.6 |
| **Cold** (fresh SIG version) | rhel9opt-SIG / azl3raw-SIG | **8.7–9.2** |

**Takeaway:** AZL-mkt 5.1 → AZL-SIG-fresh 8.9 (+3.8, *same image*) proved the orch number is about *serving state*, not the OS. Report direction + range to BA eng, never a fixed value. (8-hour warm re-run pending to confirm cold-cache mechanism.)

## C. Workload-ready — CIDone from T0 (end-to-end; orch/PreBoot window-contaminated)

| Image | CIDone from T0 | Comment |
|---|---:|---|
| AZL 3.0 mkt | **34.4** | warm orch + lean boot |
| AZL-SIG (tonight) | 38.0 | cold orch inflated |
| RHEL9 optimized | 38.3 → 40.7 | varies with window |
| RHEL9 marketplace | 48.9 | kdump + heavier cloud-init |
| Ubuntu 24.04 | 76.9 | snapd dominates |

**How to read:** A is the honest image scorecard. B is the platform/serving story (not yours to tune). C is the customer-visible end-to-end, but its absolute level rides on B's window. Your remaining lever lives entirely in **A → the cloud-init slice of userspace**, which is exactly what the workload-readiness work targets next.

Want this dropped into the `ba-results` reference doc, or just keeping it here for eyeballing?