# Measurement Logic

How VM provisioning timing is measured. Every number is **seconds elapsed from
the moment Azure created the VM record**, so the four anchors form a timeline of
"how long after create did X happen."

```
created ──PreBoot──▶ kernel up ──▶ Ready ──▶ Workload ──▶ CIDone
 (ARM)              (uptime)    (reportReady) (CustomData) (cloud-init done)
```

All anchors share one shape:

```
metric = event_epoch − created_epoch
```

- `created_epoch` — the control-plane truth, fetched once from `az` (`timeCreated`).
- `event_epoch` — read **inside the guest** from immutable, self-recorded signals.

---

## The baseline: `created`

**What it is:** `timeCreated` from `az vm list -d` / `az vm show` — the instant
Azure Resource Manager created the VM resource.

**Why it's the anchor:** it is **immutable**. Unlike `ProvisioningState/succeeded`
(which is re-stamped on every later VM model write — extension installs,
run-command, tag edits), `timeCreated` never changes, so deltas are stable and
reproducible across re-measurements.

**How it's computed:** ISO string → epoch seconds. Azure emits 7 fractional
digits (`…20.5758866+00:00`); Python's `fromisoformat` before 3.11 only accepts
3 or 6, so the fraction is clamped to 6 before parsing.

---

## 1. PreBoot — kernel is up

**Significance:** time from "ARM created the VM" to "the Linux kernel started."
This covers fabric allocation, disk attach, VM start, and kernel init — i.e. the
platform-side cost before the guest OS exists.

**Source:** boot epoch from `/proc/uptime` (`now − uptime`).

**Why `/proc/uptime` and not `uptime -s`:** `uptime -s` floors boot time to the
whole second, introducing up to ~1s error. `now − uptime` is sub-second
accurate, which matters because CIDone is reconstructed from boot time on some
distros (see CIDone).

**Calculation:** `boot_epoch − created`.

---

## 2. Ready — fabric "Provisioning succeeded"

**Significance:** the instant cloud-init's Azure datasource calls
**reportReady** — telling the platform the VM is provisioned. This is what
surfaces in the control plane as `ProvisioningState = succeeded`. It fires
during cloud-init's **network (init) stage**, *after* users/SSH are configured
but *before* the final stage and *before* your CustomData runs.

**Source:** the last line in `/var/log/cloud-init.log` containing both "report"
and "ready" (literally `Reported ready to Azure fabric.`), parsed from its
`YYYY-MM-DD HH:MM:SS` prefix.

**Why "last" match:** marketplace images retain **build-time** cloud-init log
entries (e.g. 2025 dates from when the image was baked). The current boot appends
a fresh "Reported ready" line at the end of the log, so we take the **last**
occurrence, not the first.

**Why `sudo`:** `cloud-init.log` is root-only (`0640`). Over SSH we run as the
admin user, so the log is read via passwordless `sudo` (Azure Linux images grant
the admin `NOPASSWD`). When the collector runs as root (e.g. via run-command),
sudo is a harmless no-op.

**Calculation:** `reportReady_epoch − created`.

---

## 3. Workload — your CustomData ran

**Significance:** the instant your provisioning payload actually started doing
work. This is usually the number that matters most operationally — "when did my
script begin." CustomData runs via the `scripts-user` module inside
**cloud-final** (the final stage), so it lands after Ready.

**Source:** `/var/lib/customdata-start.stamp`, written by `customdata-stamp.sh`
with `date +%s.%N` the moment the script executed. This is **already an absolute
epoch** — no conversion needed.

**Dependency:** this anchor is blank unless the VM was provisioned with
`customdata-stamp.sh` as CustomData.

**Calculation:** `stamp_epoch − created`.

---

## 4. CIDone — cloud-init fully finished

**Significance:** the very last thing cloud-init does — `modules-final.finished`.
Everything cloud-init was going to do (including your CustomData and any package
installs) is complete. It is the latest anchor in the timeline.

**Source:** `v1.modules-final.finished` in `/var/lib/cloud/data/status.json`.

**The cross-distro catch:** the format of `finished` differs by cloud-init
version:
- **RHEL / Ubuntu** (older cloud-init): an **absolute Unix epoch** (~`1.78e9`).
- **Azure Linux 3** (newer cloud-init): **seconds since boot** (e.g. `14.28`).

A naive `finished − created` is correct on the first and wildly negative on the
second (`14.28 − 1.78e9`). The collector normalizes:

```python
return f if f > 1e9 else boot() + f
```

If `finished` looks like a real epoch (`> 1e9`) it's used directly; otherwise
it's boot-relative and reconstructed as `boot_epoch + finished`. This is why
PreBoot's sub-second boot epoch matters — it keeps CIDone aligned with the
absolute-stamped Workload (otherwise CIDone reads ~0.5–1s low and dips *below*
Workload, which is physically impossible).

**Calculation:** `cloud_init_done_epoch − created`.

---

## What to infer from the results

**Expected ordering (always):**

```
PreBoot < Ready < Workload ≤ CIDone
```

- `PreBoot < Ready` — the kernel must be up before cloud-init can report ready.
- `Ready < Workload` — reportReady is in the network stage; CustomData is in the
  final stage.
- `Workload ≤ CIDone` — CustomData runs *inside* the final stage, so cloud-init
  finishes just after (typically ~0.1s later). If CIDone < Workload, suspect the
  boot-epoch/relative-time reconstruction (see CIDone).

**Reading the gaps:**
- Large `PreBoot` → platform/fabric allocation or kernel boot is slow (capacity,
  disk type, image size).
- Large `Ready − PreBoot` → cloud-init's early/network stages are slow
  (datasource, network bring-up, user setup).
- Large `Workload − Ready` → the config stage or `package_update_upgrade_install`
  running before `scripts-user` (a common latency landmine).
- Large `CIDone − Workload` → your CustomData script itself is long-running.

**Medians vs. rows:** medians are reported because Spot fleets have outliers
(noisy neighbors, cold capacity). The per-VM table exposes the spread; the
median is the representative figure.

---

## Important caveats

- **Timezone:** `cloud-init.log` timestamps and the boot epoch math assume the
  guest is **UTC** (Azure Linux images default to UTC, matching `timeCreated`).
  A non-UTC guest would skew every delta by the offset — verify with
  `timedatectl` if numbers look uniformly shifted.
- **Pull-based limitation:** these signals are read live over SSH. An **evicted
  (deallocated) Spot VM has no running guest**, so its data is unrecoverable —
  the longer you wait after provisioning, the fewer VMs remain measurable.
  Surviving eviction requires a *push* model (guest self-reports on boot).
- **Distro-agnostic:** the collector only depends on cloud-init artifacts
  (`uptime`/`/proc/uptime`, `cloud-init.log`, `status.json`) plus the optional
  CustomData stamp — all present on any cloud-init Linux image (RHEL, Ubuntu,
  Debian, Azure Linux), so the same logic works unchanged across images.
