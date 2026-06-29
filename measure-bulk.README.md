# measure-bulk.py

Measure how long an Azure **BulkActions** Spot fleet takes to come up, rebased onto a single
true zero — **T0**, the instant the bulk API call was issued. Run it from a jump host that has
direct VNET access to the fleet. `az` CLI + Python stdlib only; no Azure SDK.

> **Companion to `provision-bulk.py`.** That script launches the fleet and prints an
> `operationId`; this script consumes that id to time the fleet. They share no state beyond
> the operation id and the `customdata-stamp.sh` convention (see **WorkStart** below).

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
| **WorkStart** (`WorkT0`) | T0 → user-data **starts** executing | `/var/lib/customdata-start.stamp` |
| **CIDone** (`CIDoneT0`) | T0 → cloud-init fully complete | `status.json` `modules-final.finished` |

Two semantic cautions for whoever inherits this:
- **Ready is the *fabric* ready signal, not your workload.** It fires when cloud-init reports
  "provisioning succeeded" to the Azure fabric — typically several seconds *before* user-data
  runs. Don't read it as "app is up."
- **WorkStart is the *start* of user-data, not its completion.** It's the moment cloud-init's
  scripts-user stage hands control to the `customdata-stamp.sh` payload. If a run uses
  `--no-custom-data`, there's no stamp and this column is blank (`n=0`).

`T0` itself is the bulk operation resource's server-stamped `properties.createdTime`.

---

## Modes

Give it the bulk `--operation-id` and it discovers the fleet authoritatively from the
operation, reports **Orchestration as a distribution** (p50/p90/p99, min/max, spread) + a fleet
fill curve. Add `--with-guest` to rebase every boot/init anchor onto T0 and add the in-guest
systemd split.

---

## Prerequisites (on the jump host)

| Requirement | Notes |
|---|---|
| Python 3 | stdlib only — no `pip install` |
| `az` CLI, logged in | `az login --identity` with the jump's managed identity; needs **Reader** on the subscription |
| SSH private key | default `~/.ssh/id_rsa`, whose public half is in each fleet VM's `authorized_keys` (this is what `provision-bulk.py` injects) |
| Direct VNET line of sight | connects straight to each VM's **private IP** — no ProxyJump. The jump host must be in (or peered to) the fleet's VNET |

`--with-guest` collection SSHes into each VM and runs a small bash→python collector that emits
one JSON line of anchors. VMs that are unreachable or mid-boot are retried
(`--collect-retries` × `--collect-retry-delay`) and then reported blank rather than failing the
whole run.

**Large fleets.** The guest collect runs `--concurrency` SSH workers in parallel (default 32),
so an 800-VM fleet collects in ~a minute instead of serially. The per-VM numbers are identical
to a serial run — each anchor is read independently on its own VM — so parallelism only changes
wall time, not the statistics. Use `--concurrency 1` to force the original serial path (e.g. for
a regression baseline).

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
| `--concurrency` | `32` | (bulk `--with-guest`) parallel SSH collect workers; `1` = serial (original behaviour) |

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

### Interpretation notes for handoff

- **`CIDoneT0` is the truthful "ready to run work" figure.** It's when cloud-init has fully
  finished on the VM.
- **Don't trust the bulk operation's terminal status as an SLA.** The operation status plane
  batch-reconciles — it can flip all VMs to "succeeded" tens of seconds *after* they were
  actually ready. The poll-loop wall time in `provision-bulk.py` measures that bookkeeping, not
  time-to-work. For a fast per-VM signal, query each VM's own `provisioningState` / instance
  view instead.
- **Orchestration is the only layer that drifts with time-of-day / image**, and even then it
  stays in the low single-digit seconds. The boot/init layers are stable across runs.

---

## Relationship to the rest of the toolset

```
provision-bulk.py   launch the Spot fleet  ──prints──>  operationId
                                                            │
measure-bulk.py     time the fleet         <──consumes─────┘
customdata-stamp.sh  the WorkStart payload (provisioned by provision-bulk.py, read here)
```

This is internal tooling — it bakes in the project's anchor model and infra assumptions, so it
isn't meant for standalone publication the way `provision-bulk.py` is.
