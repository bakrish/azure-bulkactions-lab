# BulkActions (BA) API — Results, 2026-06-27

Single-call fleet launches via `Microsoft.ComputeBulkActions`
(`launchBulkInstancesOperations`, api `2026-02-01-preview`, regional endpoint
`https://uksouth.management.azure.com`). Sub
`46427a45-8a0a-4c2e-b5ba-91ba905139f6`, region `uksouth`, Spot, into `rg-test`.

The metric under study is **orchestration latency**:

```
Orchestration = VM.timeCreated − T0          (seconds)
```

- **T0** = `properties.createdTime` on the bulk operation resource (the single API call).
- **VM.timeCreated** = per-VM control-plane create stamp (orchestration end anchor).

Reported as a **distribution** (p50 with [min–max] range), not a mean, because at
scale the engine trades simultaneity for throughput and the **tail** defines when
the fleet is actually usable.

---

## 1. Orchestration latency by image (SKU pinned)

All runs pinned `Standard_D2ads_v5` via `vmSizesProfile`, Spot, n as noted.

| Image | URN | p50 (s) | Range [min–max] | n | Notes |
|---|---|---:|---|---:|---|
| Ubuntu 24.04 | `Canonical:ubuntu-24_04-lts:server:latest` | **3.5** | 3.3–3.7 | 10 | Fastest. Plan-free. |
| Azure Linux 3.0 #2 | `MicrosoftCBLMariner:azure-linux-3:azure-linux-3-gen2:latest` | **4.0** | 3.9–4.4 | 10 | Plan-free. |
| Azure Linux 3.0 #1 | (same) | 4.2 | 4.1–4.4 | 8 | Plan-free. |
| RHEL 8.10 #2 | `RedHat:RHEL:810-gen2:latest` | **5.0** | 4.9–5.4 | 10 | Plan-free. |
| RHEL 8.10 #1 | (same, op `17b9b2ad`) | 5.6 | 5.5–5.9 | 9 | Plan-free. |
| Optimized RHEL | Packer → SIG `sig_rhel/rhel8opt`, replicated local | 5.2 | 4.9–5.8 | 10 | Behaves like stock RHEL. |
| Flatcar | `kinvolk:flatcar-container-linux-free:stable-gen2:latest` | **6.6** | 6.3–7.2 | 10 | **Slowest.** Plan-bearing (`-UsePlan`). Slimmest image. |

**Ordering:** Ubuntu 3.5 < AZL 4.0 < RHEL 5.0–5.6 < Flatcar 6.6.

The ordering is **image-correlated and stable** (~1.2–1.8 s span), and is *not*
explained by image size — the slimmest image (Flatcar) is the slowest.

---

## 2. SKU-pinned vs. attribute-based selection (vmAttributes)

Same RHEL 8.10 image; one run pins the SKU, the other selects by attributes
(`vCpuCount`, `memoryInGiB`, `architectureTypes`), which are mutually exclusive
with `vmSizesProfile`.

| Selection mode | p50 (s) | Range | Spread | n | Fill shape |
|---|---:|---|---:|---:|---|
| SKU pinned (`Standard_D2ads_v5`) | 5.0–5.6 | 4.9–5.9 | 0.4–0.6 | 10 | Fans out across buckets |
| `-UseAttributes` (vCpu 2–4, mem 4–16 GiB, X64) | **6.0** | 5.9–6.1 | **0.2** | 10 | Near-synchronous (one bucket, D-shape) |

**Confirmed prediction (the one tradeoff that held):**
- Attribute-based selection adds a **+0.5–1.0 s floor tax** — an extra SKU
  resolve/score step before the create stamp.
- In exchange it produces a **tighter, more synchronous** fan-out (spread 0.2 vs
  0.4–0.6) and (expected at larger scale, not visible at n=10) **pool
  resilience** — fewer evictions because the engine isn't locked to one SKU.

---

## 3. In-guest end-to-end metrics, rebased onto T0

Full guest collection (`-WithGuest`) for the two images where it was captured.
**Every value is seconds from T0 (the bulk API call)** — i.e. each anchor is
`Orchestration + <guest anchor>`. Reported as a distribution; spread = max − min.

### Azure Linux 3.0 (op AZL #1, n=8)

| Anchor | p50 | p90 | p99 | min | max | spread |
|---|---:|---:|---:|---:|---:|---:|
| Orchestration | 4.2 | 4.4 | 4.4 | 4.1 | 4.4 | 0.3 |
| Boot (kernel up) | **19.5** | 20.2 | 20.2 | 18.7 | 20.2 | 1.5 |
| Ready (reportReady) | 25.9 | 28.9 | 28.9 | 24.8 | 28.9 | 4.1 |
| Workload (CustomData) | 34.3 | 37.2 | 37.2 | 33.1 | 37.2 | 4.1 |
| CIDone (cloud-init done) | 34.4 | 37.3 | 37.3 | 33.2 | 37.3 | 4.1 |

### RHEL 8.10 #1 (op `17b9b2ad`, n=9)

| Anchor | p50 | p90 | p99 | min | max | spread |
|---|---:|---:|---:|---:|---:|---:|
| Orchestration | 5.6 | 5.9 | 5.9 | 5.5 | 5.9 | 0.4 |
| Boot (kernel up) | **39.7** | 41.4 | 41.4 | 36.0 | 41.4 | 5.4 |
| Ready (reportReady) | 46.3 | 48.3 | 48.3 | 42.3 | 48.3 | 6.0 |
| Workload (CustomData) | 54.4 | 57.0 | 57.0 | 50.1 | 57.0 | 6.9 |
| CIDone (cloud-init done) | 54.5 | 57.1 | 57.1 | 50.2 | 57.1 | 6.9 |

### AZL vs. RHEL #1 — where the time goes (p50, from T0)

| Stage (incremental) | AZL | RHEL | Δ (RHEL − AZL) |
|---|---:|---:|---:|
| T0 → kernel up (Orch + PreBoot) | 19.5 | 39.7 | **+20.2** |
| kernel up → Ready | 6.4 | 6.6 | +0.2 |
| Ready → Workload | 8.4 | 8.1 | −0.3 |
| Workload → CIDone | 0.1 | 0.1 | 0.0 |
| **T0 → CIDone (total)** | **34.4** | **54.5** | **+20.1** |

Per-stage gaps **after** kernel-up are **identical** between the two images → the
entire ~20 s RHEL penalty is in the **boot-to-kernel-up** segment. **100% of the
AZL end-to-end win is faster BOOT**, not orchestration or init. The orchestration
lever and the boot lever are independent.

> The other runs (Ubuntu, Flatcar, RHEL #2, AZL #2, optimized RHEL, the
> `-UseAttributes` run) were **orchestration-only** (no `-WithGuest`), so no
> in-guest anchors were captured for them.

---

## 4. Hypotheses — status after today

| # | Hypothesis (orchestration lever) | Status | Killed/confirmed by |
|---|---|---|---|
| 1 | Measurement noise | **Refuted** | Repeated runs reproduce per-image ordering. |
| 2 | Marketplace **plan** validation tax | **Refuted** (as the general lever) | RHEL/AZL/Ubuntu all plan-FREE yet still ordered. (Survives only to explain Flatcar's position.) |
| 3 | Replication **locality** | **Refuted** | Locally-replicated optimized RHEL = stock RHEL. |
| 4 | Packer **optimization** / leaner image | **Refuted** | Optimized RHEL (5.2) = stock RHEL (~5.3). Packer tuning is all boot-time. |
| 5 | OS-disk **size / slimness** | **Refuted (decisive)** | Flatcar = slimmest image **and** slowest (6.6). Opposite of predicted. |
| 6 | Image **popularity / cache-warmth** | **Leading (user's)** | Survives all falsifications; explains full ordering. |
| 7 | vmAttributes **floor tax** vs. SKU-pin | **Confirmed** | +0.5–1.0 s floor, spread tightens to 0.2 (§2). |

**Leading explanation (cache/popularity).** A colder, less-popular image artifact
must hydrate before the OS disk can be created; that hydration lands *before* the
`timeCreated` stamp, so it shows up as orchestration latency. This:
- beats the first-party theory (Ubuntu, a 3rd-party image, is the *fastest*);
- beats the size theory (Flatcar, the *smallest*, is the *slowest*);
- explains the complete ordering Ubuntu < AZL < RHEL < Flatcar.

The mechanism is not pinned to a single confirming test (the user chose not to
pursue a plan-free slim image like community-gallery Alpine to split
cache-warmth from artifact-format).

---

## 5. Tooling changes made today

- **`provision-bulk.ps1`**: added `-OsDiskSizeGB` (expand-only; cannot shrink
  below the image's native size), `-UsePlan` (terms-accept + top-level `plan`
  triple for plan-bearing images like Flatcar — without it: `VMMarketplaceInvalidInput`),
  and `-UseAttributes` (+ `-MinVCpu/-MaxVCpu/-MinMemGiB/-MaxMemGiB/-Arch`, swaps
  `vmSizesProfile` for `vmAttributes`). PUT failures now print the full ARM body.
- **`measure-bulk.ps1`**: fixed an n=0 bug (a dangling NIC made `az vm list -d`
  error and drop all rows — orchestration query no longer uses `-d`); guest ssh
  errors are now surfaced (2>&1 merge instead of swallow); added
  **retry-with-backoff** (`-CollectRetries`/`-CollectRetryDelay`) around the
  per-VM collect for slow-booters.

> Caveat on the per-VM bulk failures seen in op `8fef58ec` (first Flatcar attempt
> without `-UsePlan`): all VMs Failed with `VMMarketplaceInvalidInput`; that op
> left the harmless dangling `nic-f966f26c`.
