# provision-bulk.py

Bulk-launch Spot VMs through the **(preview) Azure BulkActions API**, using nothing but the
`az` CLI and the Python standard library. One PUT creates an N-VM Spot fleet; the script then
polls until every VM reaches a terminal state and prints the operation's `operationId` and the
launched VMs.

A single self-contained script — no Azure SDK, no `pip install`, no config files. Drop it on
any box that has `az` and run it. Every default shown below is just an example from one
environment; override it with a flag for yours.

> **Preview API.** This uses `Microsoft.ComputeBulkActions`, api-version `2026-02-01-preview`.
> It is served only from the **regional** ARM endpoint (`https://<region>.management.azure.com`)
> and requires the resource provider to be registered on your subscription.

---

## How it works

The script issues a single async PUT of a `launchBulkInstancesOperations` resource:

```
PUT https://<region>.management.azure.com/subscriptions/<sub>/resourceGroups/<rg>
    /providers/Microsoft.ComputeBulkActions/locations/<region>
    /launchBulkInstancesOperations/<operationId>?api-version=2026-02-01-preview
```

- **RG + location** come from the URL.
- `properties.computeProfile.virtualMachineProfile` is a standard VM template.
- `properties.capacity` / `capacityType` set the count.
- `properties.vmSizesProfile` (or `vmAttributes`) sets sizing.
- `properties.priorityProfile.type = "Spot"` makes the fleet Spot.
- The RP **auto-generates the VM names**; you enumerate them from the operation afterwards
  rather than naming VMs yourself.

Authentication is **exclusively** via `az` shelled through `subprocess`. There is no Azure SDK
or AAD library in play — `az` owns every token. On a jump host this means `az login --identity`.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Python 3 | stdlib only — no `pip install` needed |
| `az` CLI, logged in | `az login`, or `az login --identity` on a managed-identity jump host (needs at least Contributor on the target RG / Reader on the sub) |
| RP registered | `az provider register --namespace Microsoft.ComputeBulkActions` |
| Existing SSH public key | default `~/.ssh/id_rsa.pub`; generate with `ssh-keygen -t rsa -b 4096` |
| A CustomData payload next to the script | optional; defaults to the bundled `customdata-stamp.sh`, or point `--custom-data` at another file (e.g. `customdata-fluentbit.yaml`), or pass `--no-custom-data` to launch without it |
| Existing vnet/subnet | the VMs deploy into an existing subnet — pass `--vnet` / `--subnet` / `--infra-resource-group` for yours |

### CustomData (optional)

By default the script base-64s a file named `customdata-stamp.sh` (sitting **next to**
`provision-bulk.py`) and passes it as CustomData. Replace its contents with any cloud-init
config or shell user-data you want every VM to run at first boot — the launcher doesn't care
what's in it. The bundled example simply records the instant cloud-init hands control to
user-data:

```bash
date +%s.%N > /var/lib/customdata-start.stamp
```

Pass `--no-custom-data` to launch a bare image with no user-data at all.

To attach a **different** payload without renaming files, pass `--custom-data <path>` — e.g.
`--custom-data customdata-fluentbit.yaml`, a cloud-config bundled here that writes a Fluent Bit
config, resolves the per-VM hostname at first boot, and starts shipping logs to Azure Data
Explorer (the image is expected to already ship the Fluent Bit binary). `--custom-data` is
ignored when `--no-custom-data` is set.

---

## Usage

```bash
python3 provision-bulk.py [options]
```

### Common examples

```bash
# Defaults (example env): 10 x Standard_D2ads_v5, RHEL 8.10 gen2, Spot
python3 provision-bulk.py

# Ubuntu 24.04, 10 VMs
python3 provision-bulk.py --image "Canonical:ubuntu-24_04-lts:server:latest" --count 10

# Pin a single SKU, 25 VMs
python3 provision-bulk.py --size Standard_D4ads_v5 --count 25

# Multi-size pinned basket (RP allocates across these explicit SKUs)
python3 provision-bulk.py --sizes Standard_D2ads_v5,Standard_D4ads_v5,Standard_E2ads_v5 --count 30

# Custom image from a Shared Image Gallery (pass the full version resource id)
python3 provision-bulk.py --image "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<imageDef>/versions/1.0.0"
# ... use ".../versions/latest" to always pull the newest gallery version.

# Custom standalone managed image
python3 provision-bulk.py --image "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/images/<imageName>"

# Attribute-based selection (describe the shape, let the RP pick), excluding two SKUs
python3 provision-bulk.py --use-attributes \
    --min-vcpu 2 --max-vcpu 4 --min-mem-gib 4 --max-mem-gib 16 \
    --exclude-sizes Standard_L64s_v3,Standard_L80s_v3

# Attribute-based selection restricted to Gen2-capable SKUs. Pair with a Gen2
# image -- this filters the SKU basket to those that SUPPORT Gen2 (excluding the
# legacy Gen1-only sizes); the generation actually booted is set by the image:
python3 provision-bulk.py --use-attributes \
    --min-vcpu 2 --max-vcpu 4 --min-mem-gib 4 --max-mem-gib 16 \
    --hyperv-generations Gen2 --image "RedHat:RHEL:810-gen2:latest"

# Marketplace image that needs plan/terms acceptance (e.g. Flatcar)
python3 provision-bulk.py --image "kinvolk:flatcar-container-linux-free:stable-gen2:latest" --use-plan

# Install VM extensions at launch (e.g. Azure Monitor Agent); injected into
# computeProfile.extensions. The DCR association is a separate resource afterward.
python3 provision-bulk.py --extensions extensions-ama.json

# Attach a user-assigned managed identity to EVERY launched VM (pre-grant its RBAC first)
python3 provision-bulk.py \
    --user-assigned-identity "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>"

# Force the NVMe disk controller (e.g. a v6 SKU that defaults to SCSI)
python3 provision-bulk.py --size Standard_D2as_v6 --disk-controller-type NVMe

# Capture the FIRST (cold-provision) boot's serial console for pre-kernel latency
# analysis. A reboot cannot reproduce fresh-provision conditions (allocation +
# OS-disk hydration from the image), so enable this AT LAUNCH:
python3 provision-bulk.py --boot-diagnostics --count 1
#   then: az vm boot-diagnostics get-boot-log -g <rg> -n <vm>

# Enable Accelerated Networking (SR-IOV). Needs a 4+ vCPU size (the default
# D2ads_v5 does NOT support it) + SR-IOV drivers in the image:
python3 provision-bulk.py --accelerated-networking --size Standard_D4ads_v5
#   verify on the VM: ethtool -S eth0 | grep vf_tx_packets   (should climb)

# Pin the launch to a single Availability Zone (best-effort: spills to other zones
# only if that zone is capacity-short) -- e.g. to co-locate with a workload in zone 1:
python3 provision-bulk.py --zones 1 --zone-strategy BestEffortSingleZone

# Spread evenly across zones, or fill a preferred zone first then spill:
python3 provision-bulk.py --zones 1,2,3 --zone-strategy StrictBalanced
python3 provision-bulk.py --zones 1,2,3 --zone-strategy Prioritized --zone-preferences 1:0,2:1,3:2

# Attach an alternate CustomData payload (e.g. Fluent Bit -> ADX log shipping)
python3 provision-bulk.py --custom-data customdata-fluentbit.yaml \
    --user-assigned-identity "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>"
```

---

## Options

| Flag | Default | Description |
|---|---|---|
| `--image` | `RedHat:RHEL:810-gen2:latest` | Marketplace URN `Publisher:Offer:Sku:Version` **or** a full image resource id |
| `--count` | `10` | Number of VMs to launch |
| `--size` | `Standard_D2ads_v5` | Single pinned SKU |
| `--sizes` | — | Comma-separated explicit SKUs for a multi-size pinned basket (overrides `--size`; ignored with `--use-attributes`) |
| `--os-disk-size-gb` | `0` | `0` = image default; otherwise **expand** to this size (cannot shrink below the image's native size) |
| `--disk-controller-type` | — | VM-wide disk controller `SCSI` / `NVMe` (OS + data share it). Omit to take the SKU default (v5 = SCSI-only; v6 defaults SCSI, pass `NVMe` to force it; v7 = NVMe-native). Requires the image definition to advertise the value, NVMe drivers in the initramfs, and Gen2 |
| `--user-assigned-identity` | — | Full resource id of a user-assigned managed identity attached to **every** launched VM (stamped as the top-level `identity`). Pre-grant its RBAC before launch — system-assigned identities are per-VM and can't be pre-authorized, so they're unsuitable for ephemeral fleets |
| `--boot-diagnostics` | off | Enable **managed** boot diagnostics on every launched VM (stamped as `diagnosticsProfile.bootDiagnostics.enabled`). Captures the **first (cold-provision) boot's** serial console log — the only artifact that timestamps the pre-kernel window (firmware → GRUB → kernel-load). Read it with `az vm boot-diagnostics get-boot-log`. A reboot can't reproduce fresh-provision conditions (allocation + OS-disk hydration), so enable it at launch |
| `--accelerated-networking` | off | Enable Accelerated Networking / SR-IOV on every launched VM's NIC (stamped as `enableAcceleratedNetworking` per NIC config). **Off by default** (the API default). Requires a **supported size** — 4+ vCPUs on hyperthreaded families (e.g. `Standard_D4ads_v5`; the default 2-vCPU `Standard_D2ads_v5` does **not** support it) — and an image carrying the SR-IOV drivers (mlx4/mlx5/MANA), or the launch is rejected. Verify traffic rides the VF with `ethtool -S eth0 \| grep vf_tx_packets` |
| `--resource-prefix` | `vmbulk` | computerName prefix (truncated to 11 chars so the RP can append a suffix) |
| `-g`, `--resource-group` | `rg-test` | Disposable RG that holds only the VMs |
| `--infra-resource-group` | `rg-infra` | Persistent RG holding vnet/subnet/jump |
| `--vnet` | `vnet-rhel` | Existing VNet |
| `--subnet` | `sub-rhel` | Existing subnet |
| `--region` | `uksouth` | Region (also selects the regional ARM endpoint) |
| `--admin` | `azureuser` | Admin username |
| `--public-key-path` | `~/.ssh/id_rsa.pub` | Existing SSH public key |
| `--use-plan` | off | Accept Marketplace terms and attach the plan (needed by some images) |
| `--use-attributes` | off | Attribute-based selection instead of a pinned SKU (drops `vmSizesProfile`) |
| `--min-vcpu` / `--max-vcpu` | `2` / `4` | vCPU range (attribute mode) |
| `--min-mem-gib` / `--max-mem-gib` | `4` / `16` | Memory range in GiB (attribute mode) |
| `--arch` | `X64` | Architecture type (attribute mode) |
| `--exclude-sizes` | — | Comma-separated SKUs to drop from the attribute basket (only with `--use-attributes`) |
| `--hyperv-generations` | — | Comma-separated Hyper-V generations (`Gen1` and/or `Gen2`) to filter the attribute basket to, stamped at `vmAttributes.hyperVGenerations`. Only valid with `--use-attributes` (fails loudly otherwise). Filters SKUs to those that **support** the generation — the booted generation is set by the image, so pair `Gen2` with a Gen2 image. Not available on the pinned `--size`/`--sizes` path |
| `--zones` | — | Comma-separated Availability Zones the launch may use (e.g. `1` or `1,2,3`), stamped as the top-level `zones` array. Omit = zone-agnostic (regional) placement. Pair with `--zone-strategy` |
| `--zone-strategy` | — | Zone distribution (`properties.zoneAllocationPolicy.distributionStrategy`): `BestEffortSingleZone` (one zone, spill only if capacity-short — the co-location vs Spot-fill compromise), `Prioritized` (fill higher-ranked zones first; needs `--zone-preferences`), `BestEffortBalanced` / `StrictBalanced` (spread across zones). All are best-effort against Spot capacity |
| `--zone-preferences` | — | For `--zone-strategy Prioritized`: comma-separated `zone:rank` pairs, lower rank = higher priority (e.g. `1:0,2:1,3:2`) |
| `--no-custom-data` | off | Skip CustomData entirely (default: base64 `customdata-stamp.sh` next to the script) |
| `--custom-data` | — | Path to an alternate CustomData file to base64 and attach (e.g. `customdata-fluentbit.yaml`). Default: `customdata-stamp.sh` next to the script. Ignored with `--no-custom-data` |
| `--extensions` | — | Path to a JSON array of extensions injected at `computeProfile.extensions` (e.g. `extensions-ama.json` for AMA) |
| `--compute-api-version` | `2024-07-01` | `computeApiVersion` stamped with extensions (only used with `--extensions`) |
| `--poll-seconds` | `15` | Status poll interval |
| `--max-polls` | `60` | Max poll iterations before giving up |

### Sizing modes (pick one)

1. **Single SKU** — `--size` (default).
2. **Multi-size pinned basket** — `--sizes a,b,c`. Real cross-family breadth without going
   full attribute-based; the RP allocates across the explicit list.
3. **Attribute-based** — `--use-attributes` with the vCPU/memory/arch ranges. Mutually
   exclusive with `vmSizesProfile`, so the size list is ignored.

---

## What it prints

- `[wall] submit (T0)` — the **true T0**: the instant the bulk PUT is issued.
- Per-poll progress: `total / succeeded / creating / failed`.
- `[wall] submit -> all-terminal` — caller-observed fleet-fill wall time, quantized to
  `--poll-seconds`.
- A table of the launched VMs (name / power state / private IP).
- The **`operationId`** — the handle for the bulk operation — plus a cleanup hint.

> Note: the operation's terminal status batch-reconciles and can lag real per-VM readiness, so
> treat the wall time as operation bookkeeping rather than a precise "time to ready" SLA. For
> exact per-VM timings, query each VM's own `provisioningState` / instance view.

---

## Cleanup

```bash
az group delete -n rg-test --yes --no-wait
```

The target RG holds only the launched VMs; your networking RG is left untouched.
