# Linux VM Boot on Azure: Kernel → systemd → cloud-init (and where waagent/extensions fit)

This explains, end to end, what happens between "ARM created the VM" and "my workload is
running" on an Azure Linux VM — how the **kernel**, **systemd**, and **cloud-init** hand off
to each other, where the **"Provisioning succeeded"** signal comes from, and where the
**guest agent (waagent) and VM extensions** (e.g. Azure Monitor Agent) slot in.

It also maps every phase to the four measurement anchors used by the timing harness
(`PreBoot`, `Ready`, `Workload`, `CIDone`) so the numbers have a physical meaning.

---

## 1. The cast (who does what)

| Component | Role | Runs as |
|---|---|---|
| **Azure fabric / host** | Allocates the VM, attaches the OS disk, presents the provisioning config (IMDS + a UDF CD-ROM with `ovf-env.xml`) | Host, *outside* the guest |
| **Kernel + initramfs** | Brings up CPU, memory, drivers, mounts root, then hands off to PID 1 | Guest, earliest userspace |
| **systemd** | PID 1. Orchestrates the boot as a dependency graph of *units* ordered by *targets* | Guest |
| **cloud-init** | First-boot provisioning agent. Applies hostname, users, SSH keys, networking, disks, and runs your CustomData. Reports "ready" to the fabric | Guest, as systemd units |
| **waagent** (Azure Linux Agent) | The Azure guest agent. On modern images it no longer does provisioning — its main job is **VM extensions** and goal-state handling | Guest, as a systemd service |
| **VM extensions** (AMA, Custom Script, etc.) | Optional add-ons pushed by the control plane *after* provisioning succeeds | Guest, driven by waagent |

Key idea: **the fabric sets the clock (`timeCreated`)**, the **kernel + systemd boot the OS**,
**cloud-init provisions it and signals readiness**, and **waagent layers extensions on afterward**.

---

## 2. The pipeline, in order

```
ARM "create" (timeCreated)
        │
        │  fabric: allocate node, attach OS disk, start VM   ← Azure-side, not yours
        ▼
┌─────────────────────────────────────────────────────────────┐
│ GUEST BOOT                                                   │
│                                                             │
│  Kernel + initramfs ──► systemd (PID 1)                     │
│        │                     │                              │
│        │                     ├─ sysinit.target             │
│        │                     ├─ basic.target               │
│        │                     ├─ network(-online).target    │
│        │                     └─ multi-user.target          │
│        │                                                    │
│        └─ cloud-init runs AS systemd units, interleaved:    │
│                                                             │
│   1. cloud-init-local   (pre-network)                       │
│   2. cloud-init         (init / network stage)  ──► REPORT READY ──► ProvisioningState=Succeeded
│   3. cloud-config       (config stage)                      │
│   4. cloud-final        (final stage)  ──► runs CustomData  │
│                                                             │
│  ── meanwhile, AFTER report-ready ──                        │
│   waagent processes the goal state ──► installs extensions  │
│                                   (AMA: download→install→   │
│                                    config→DCR→heartbeat)    │
└─────────────────────────────────────────────────────────────┘
```

The two columns at the bottom — **cloud-final** and **waagent extensions** — run
**concurrently**. They have no ordering dependency on each other; they just share the CPU.

---

## 3. Kernel → systemd handoff

1. The fabric starts the VM; the **kernel** initializes hardware, mounts the root filesystem
   from the OS disk, then execs **PID 1 = systemd**.
2. **systemd** doesn't run scripts top-to-bottom — it resolves a **dependency graph** of units
   and pulls in **targets** (milestones) in order:
   - `sysinit.target` → early filesystem/mounts/udev
   - `basic.target` → sockets, timers, paths ready
   - `network.target` / `network-online.target` → NIC up, routes present
   - `multi-user.target` → normal system-up state
3. **cloud-init is not a monolith** — it ships **four systemd units**, each ordered against
   those targets. That's how "the kernel, systemd, and cloud-init work together": cloud-init
   is just a set of well-placed systemd jobs hanging off the boot graph.

This is also why distro boot times differ so much: a leaner image (fewer/faster units,
smaller initramfs, lighter `multi-user.target`) reaches each target sooner, so cloud-init
starts — and finishes — earlier.

---

## 4. cloud-init's four stages (the important part)

Source of truth: Microsoft Learn — *Understanding cloud-init* (boot stages), and the
cloud-init Azure datasource reference.

| # | Stage | systemd ordering | What it does | Anchor |
|---|---|---|---|---|
| 1 | **cloud-init-local** | before networking | Finds the **Azure datasource**, applies fallback network config | — |
| 2 | **cloud-init (init / network)** | after `network.target` | NIC/routes, hostname, users, SSH keys, disk/ephemeral setup. **At the end of this stage cloud-init reports "ready" to the fabric.** | **Ready** |
| 3 | **cloud-config (config)** | mid-boot | Runs `cloud_config_modules` | — |
| 4 | **cloud-final (final)** | late, near `multi-user.target` | Runs `cloud_final_modules`: package installs, **`runcmd`**, and **CustomData** via `scripts-user` | **Workload** / **CIDone** |

### The "Provisioning succeeded" signal (the Ready anchor)

At the **end of stage 2 (init/network)**, cloud-init's Azure datasource calls
`_report_ready()` → posts a health report with `State=Ready` to the **WireServer**. The fabric
receiving that flips the control-plane **`ProvisioningState` to `Succeeded`** — the exact thing
the portal shows as **"Provisioning succeeded."**

> Documented quote (Learn, boot stages, stage 3 init/network):
> *"After this stage, cloud-init sends a signal to the Azure platform that the VM has been
> provisioned successfully. Some modules may have failed, however not all module failures
> automatically result in a provisioning failure."*

Two consequences:
- **"Succeeded" ≠ "fully configured."** It fires *before* config/final stages run. That's why
  your workload (which runs in final) always lands *after* Ready.
- This equivalence holds when **cloud-init is the provisioning agent** (the modern marketplace
  default). On legacy images where **waagent** provisions, the same Ready report comes from
  waagent (`/var/log/waagent.log`) instead.

### Where CustomData runs (the Workload anchor)

CustomData executes in **stage 4 (final)** via the `scripts-user` module — structurally one of
the **last** things cloud-init does. That's *by design*, and it's why a CustomData payload can't
start until ~the final stage. If you need code earlier, use `bootcmd` (stage 2-ish) or a baked-in
early systemd unit instead of CustomData.

---

## 5. Where waagent and extensions (e.g. AMA) fit

- The **VM provisioning state** and the **extension provisioning state** are **independent**.
  The VM reports `Succeeded` (Ready) regardless of whether any extension has installed.
- The control plane only pushes the **extension goal state** to waagent **after** provisioning
  success. So extensions — including **Azure Monitor Agent** — run **post-Ready**.
- Practically, extension install (`download → install → configure → DCR association → first
  heartbeat`) runs **concurrently with cloud-final**. No ordering dependency, but on small SKUs
  (e.g. 2 vCPU) they **contend** for CPU/disk/network.

Implications for the anchors:
- **PreBoot, Ready** — unaffected by extensions (they run earlier / independently).
- **Workload, CIDone** — can drift a few seconds *via contention* on small VMs, not via ordering.
- The true cost of an agent like AMA is a **fifth interval after CIDone** ("agent active /
  reporting") that the four anchors don't capture.

---

## 6. The four anchors, summarized

All measured as **seconds from `timeCreated`** (the immutable control-plane create time):

| Anchor | Event | Guest source | Meaning |
|---|---|---|---|
| **PreBoot** | Kernel boot epoch | `now − /proc/uptime` | Fabric allocation + image deploy + kernel/initramfs. **Azure-side, not yours.** |
| **Ready** | cloud-init reported ready | `/var/log/cloud-init.log` ("report…ready") | `ProvisioningState=Succeeded`. End of init/network stage. |
| **Workload** | CustomData started | `/var/lib/customdata-start.stamp` | Your payload began (final stage, `scripts-user`). |
| **CIDone** | cloud-init fully finished | `status.json` `v1.modules-final.finished` | All modules done; nothing meaningful runs after. |

Expected ordering, always: **`PreBoot < Ready < Workload ≤ CIDone`**.

Reading the *gaps* is more useful than the absolutes:
- `Ready − PreBoot` ≈ init/network stage cost.
- `Workload − Ready` ≈ config + final overhead before your script.
- `CIDone − Workload` ≈ whatever runs after your script (≈0 if yours is last).

---

## 7. What the measurements showed (uksouth, D2ads_v5 Spot, n=10 each)

| Anchor | AZL 3.0 | Ubuntu 24.04 | RHEL 8.10 |
|---|---|---|---|
| PreBoot | 13.8s | 15.0s | 24.8s |
| Ready | 20.6s | 21.2s | 31.0s |
| Workload | 28.6s | 33.0s | 39.3s |
| CIDone | 28.8s | 33.1s | 39.5s |

Interpretation:
- **RHEL's ~11s deficit is born at PreBoot** (heavier kernel/initramfs/early systemd) and simply
  carries forward — its cloud-init *stages* run about as fast as AZL3's. The lever for RHEL is
  **image trimming / a prebaked image**, not CustomData placement.
- **Ubuntu's extra `Workload − Ready`** (~12s vs ~8s) is its heavier `cloud_final_modules`.
- **CIDone − Workload ≈ 0.1s everywhere** — the CustomData script is the last meaningful step.

---

## 8. Where the time goes, and the levers

- **PreBoot (~14–25s): the hard floor.** Fabric + kernel + initramfs. Not reducible by you on
  marketplace images; only a trimmed/prebaked image moves it.
- **Ready − PreBoot (~6s): init/network stage.** Largely fixed; minor.
- **Workload − Ready (~8–12s): cloud-init config+final overhead.** **Recoverable** — move the
  payload earlier (`bootcmd`, early systemd unit) or bake it into the image.
- **Anything you bake into the image** collapses "time to workload" toward PreBoot, because
  there's nothing to fetch or stage at boot.

**Bottom line:** the kernel and systemd get you to a running OS; cloud-init turns that OS into
*your* configured VM and tells Azure "I'm ready" at the end of its network stage; your CustomData
runs near the very end of cloud-init; and extensions like AMA pile on *after* readiness. To make
a VM useful sooner, attack **boot weight** (image) and **payload placement** (delivery
mechanism) — not the distro label alone.
