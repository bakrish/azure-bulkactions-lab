# measure-bulk.py

Measure how long an Azure **BulkActions** Spot fleet takes to come up, rebased onto a single
true zero — **T0**, the instant the bulk API call was issued. Run it from any host with direct
VNET line of sight to the fleet. `az` CLI + Python standard library only — no Azure SDK, no
`pip install`, no config files.

> **Companion to `provision-bulk.py`,** but not coupled to it: it works against *any*
> BulkActions operation id, however the fleet was launched. Every default below is an example
> from one environment; override it with a flag for yours.

---

## What it measures — the layer model

Every anchor is reported as **seconds from T0**, so the numbers stack into a single timeline
from the API call to a fully-provisioned, cloud-init-complete VM:

```
T0 ──Orchestration──> VM created ──PreBoot──> kernel ──> Ready ──> WorkStart ──> CIDone
(bulk PUT)            (timeCreated)          (boot)    (fabric)   (user-data)   (cloud-init done)
```

| Anchor (column) | Means | Source |
|---|---|---|
| **Orchestration** (`Orch`) | T0 → the VM resource exists | `VM.timeCreated − T0` |
| **PreBoot** (`BootT0`) | T0 → kernel starts | guest `now − /proc/uptime` (sub-second) |
| **Ready** (`ReadyT0`) | T0 → fabric "provisioning succeeded" | cloud-init **report-ready** log line |
| **WorkStart** (`WorkT0`) | T0 → user-data **starts** executing | a stamp file your CustomData writes (see below) |
| **CIDone** (`CIDoneT0`) | T0 → cloud-init fully complete | `status.json` `modules-final.finished` |

`T0` itself is the bulk operation resource's server-stamped `properties.createdTime`.

Two semantic cautions worth keeping straight:
- **Ready is the *fabric* ready signal, not your workload.** It fires when cloud-init reports
  "provisioning succeeded" to the Azure fabric — typically several seconds *before* user-data
  runs. Don't read it as "app is up."
- **WorkStart is the *start* of user-data, not its completion** (see next section).

### The WorkStart anchor (optional)

`WorkStart` is the one anchor that needs cooperation from the image's first-boot script. The
collector simply reads a stamp file and treats its epoch as "user-data started":

```
/var/lib/customdata-start.stamp
```

To populate it, have your CustomData / cloud-init write that file as the very first thing it
does — e.g. a one-line user-data script:

```bash
date +%s.%N > /var/lib/customdata-start.stamp
```

If a fleet is launched without that stamp, nothing breaks: the `WorkStart` column is simply
blank (`n=0`) and every other anchor still reports normally. So the metric is opt-in — wire up
the stamp when you care about "time to first user-data", skip it otherwise.

---

## Modes

Give it the bulk `--operation-id` and it discovers the fleet authoritatively from the
operation, reports **Orchestration as a distribution** (p50/p90/p99, min/max, spread) + a fleet
fill curve. Add `--with-guest` to rebase every boot/init anchor onto T0 and add the in-guest
systemd split.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Python 3 | stdlib only — no `pip install` |
| `az` CLI, logged in | `az login`, or `az login --identity` on a managed-identity host; needs at least **Reader** on the subscription |
| SSH private key | default `~/.ssh/id_rsa`, whose public half is in each fleet VM's `authorized_keys` (only needed for `--with-guest`) |
| Direct VNET line of sight | connects straight to each VM's **private IP** — no ProxyJump. The host must be in (or peered to) the fleet's VNET |

`--with-guest` collection SSHes into each VM and runs a small bash→python collector that emits
one JSON line of anchors. VMs that are unreachable or mid-boot are retried
(`--collect-retries` × `--collect-retry-delay`) and then reported blank rather than failing the
whole run. Without `--with-guest`, the tool only reads the operation from ARM — no SSH needed.

**Large fleets.** The guest collect fans out `--concurrency` parallel SSH workers (default 32) —
each a separate `ssh` process — so a several-hundred-VM fleet collects in about a minute instead
of one VM at a time. Because every anchor is measured independently on its own VM, the per-VM
and distribution numbers are identical to a serial run; only wall time changes. Pass
`--concurrency 1` to force the strictly-serial path.

---

## Usage

```bash
# Orchestration distribution only (fast; no SSH into the fleet):
python3 measure-bulk.py --operation-id 17b9b2ad-...

# Full end-to-end, every anchor rebased onto T0 (SSHes into each VM):
python3 measure-bulk.py --operation-id 17b9b2ad-... --with-guest
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--operation-id` | required | Bulk operation id to measure |
| `-g`, `--resource-group` | `rg-test` | RG holding the fleet |
| `--region` | `uksouth` | Region (selects the regional ARM endpoint for the operation read) |
| `--with-guest` | off | (bulk mode) also SSH-collect guest anchors and rebase onto T0 |
| `-u`, `--user` | `azureuser` | SSH user on the fleet VMs |
| `-i`, `--identity` | ssh default | SSH private key (defaults to ssh's own `~/.ssh/id_rsa`) |
| `--collect-retries` | `3` | Per-VM guest-collect attempts before giving up |
| `--collect-retry-delay` | `20` | Seconds between collect attempts |
| `--concurrency` | `32` | (bulk `--with-guest`) parallel SSH collect workers; `1` = serial |

---

## Reading the output

**End-to-end table** — one row per VM, all columns in seconds from T0:

```
VM   Orch  BootT0  ReadyT0  WorkT0  CIDoneT0
```

**Distribution (from T0)** — p50/p90/p99/min/max/spread/n per anchor. `spread = max − min`.
`n` is how many VMs reported that anchor (so a blank `WorkStart` shows `n=0`).

**In-guest boot (systemd-analyze)** — `Kernel / Initrd / Userspace / sd-Total`. These come
from `systemd-analyze time`, measured by systemd from the uptime origin, so they are
**infra-independent**: they exclude T0, orchestration, and PreBoot/hydration entirely. Use them
to compare the *image's* own boot cost across runs/regions without control-plane noise.

### Interpretation notes

- **`CIDoneT0` is the truthful "ready to run work" figure** — when cloud-init has fully
  finished on the VM.
- **Don't trust the bulk operation's terminal status as an SLA.** The operation status plane
  batch-reconciles — it can flip all VMs to "succeeded" tens of seconds *after* they were
  actually ready. For a fast per-VM signal, query each VM's own `provisioningState` / instance
  view instead.
- **Orchestration is the layer most sensitive to time-of-day / image**, though it typically
  stays in the low single-digit seconds. The boot/init layers are stable across runs.

---

## How it works

For a given operation id, the tool reads the operation resource from the **regional** ARM
endpoint (`https://<region>.management.azure.com`, api-version `2026-02-01-preview`) to get
both `T0` (`properties.createdTime`) and the authoritative VM list. With `--with-guest` it then
SSHes each VM's private IP, collects the guest anchors, and rebases them onto T0.

Authentication is **exclusively** via `az` shelled through `subprocess` — no Azure SDK or AAD
library. `az` owns every token.
