#!/usr/bin/env python3
"""
provision-bulk.py -- bulk Spot VM launch via the (preview) BulkActions API.

Method :  PUT the launchBulkInstancesOperations RESOURCE to the REGIONAL ARM
endpoint (https://<region>.management.azure.com), api-version 2026-02-01-preview:

    PUT .../Microsoft.ComputeBulkActions/locations/<loc>/launchBulkInstancesOperations/<id>

RG + location come from the URL. properties.computeProfile.virtualMachineProfile
is the standard VM template; capacity/capacityType set the count; vmSizesProfile
sets sizing; priorityProfile.type='Spot' makes them Spot. The RP auto-generates
the VM names, so measure-bulk.py enumerates them from the operation unchanged.

Azure access is ONLY via the `az` CLI shelled through subprocess (no Azure SDK /
AAD libraries). Python stdlib only. `az` owns every token (on the jump,
`az login --identity`). Needs an EXISTING SSH public key (no --generate-ssh-keys)
and base-64 CustomData -- this wrapper supplies both.

Examples:
  python3 provision-bulk.py
  python3 provision-bulk.py --image "Canonical:ubuntu-24_04-lts:server:latest" --count 10
  python3 provision-bulk.py --size Standard_D4ads_v5 --count 25
  python3 provision-bulk.py --image "kinvolk:flatcar-container-linux-free:stable-gen2:latest" --use-plan
  python3 provision-bulk.py --use-attributes --min-vcpu 2 --max-vcpu 4 --min-mem-gib 4 --max-mem-gib 16

PREVIEW: requires Microsoft.ComputeBulkActions registered on the subscription
(az provider register --namespace Microsoft.ComputeBulkActions).
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid

API_VERSION = "2026-02-01-preview"
ARM_RESOURCE = "https://management.azure.com/"


def az(args, check=True):
    """Run an az command, capturing output. Exit on failure when check=True."""
    p = subprocess.run(["az"] + args, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.stderr.write((p.stderr or p.stdout or "").strip() + "\n")
        raise SystemExit(p.returncode or 1)
    return p


def az_tsv(args):
    return az(args).stdout.strip()


def main():
    ap = argparse.ArgumentParser(
        description="Bulk Spot VM launch via the BulkActions API (az-only).")
    ap.add_argument("--image", default="RedHat:RHEL:810-gen2:latest",
                    help="Marketplace URN 'Publisher:Offer:Sku:Version' OR a full image resource id.")
    ap.add_argument("--count", type=int, default=10)
    ap.add_argument("--size", default="Standard_D2ads_v5")
    ap.add_argument("--sizes", default=None,
                    help="Comma-separated explicit SKUs for a multi-size pinned basket "
                         "(overrides --size; ignored when --use-attributes).")
    ap.add_argument("--os-disk-size-gb", type=int, default=0,
                    help="0 = image default; else EXPAND to this (cannot shrink below image size).")
    ap.add_argument("--resource-prefix", default="vmbulk")
    ap.add_argument("-g", "--resource-group", default="rg-test", help="disposable: holds only the VMs")
    ap.add_argument("--infra-resource-group", default="rg-infra", help="persistent: vnet/subnet/jump")
    ap.add_argument("--vnet", default="vnet-rhel")
    ap.add_argument("--subnet", default="sub-rhel")
    ap.add_argument("--region", default="uksouth")
    ap.add_argument("--admin", default="azureuser")
    ap.add_argument("--public-key-path", default=os.path.expanduser("~/.ssh/id_rsa.pub"))
    ap.add_argument("--use-plan", action="store_true")
    ap.add_argument("--use-attributes", action="store_true")
    ap.add_argument("--min-vcpu", type=int, default=2)
    ap.add_argument("--max-vcpu", type=int, default=4)
    ap.add_argument("--min-mem-gib", type=float, default=4)
    ap.add_argument("--max-mem-gib", type=float, default=16)
    ap.add_argument("--arch", default="X64")
    ap.add_argument("--exclude-sizes", default=None,
                    help="Comma-separated SKUs to exclude from an attribute-based basket "
                         "(only applies with --use-attributes).")
    ap.add_argument("--poll-seconds", type=int, default=15)
    ap.add_argument("--max-polls", type=int, default=60)
    ap.add_argument("--no-custom-data", action="store_true",
                    help="Skip CustomData entirely (default: base64 customdata-stamp.sh "
                         "next to this script, which stamps the WorkStart anchor).")
    ap.add_argument("--extensions", default=None,
                    help="Path to a JSON file: an array of extension objects (or {'extensions':[...]}) "
                         "injected at computeProfile.extensions, e.g. extensions-ama.json for AMA.")
    ap.add_argument("--compute-api-version", default="2024-07-01",
                    help="computeApiVersion stamped alongside extensions (only used with --extensions).")
    a = ap.parse_args()

    # --- Image: Marketplace URN OR a full image resource ID -----------------
    plan_ref = None
    if a.image.startswith("/subscriptions/"):
        image_reference = {"id": a.image}
    else:
        parts = a.image.split(":")
        if len(parts) != 4:
            raise SystemExit(f"Image must be a full URN 'Publisher:Offer:Sku:Version' "
                             f"or a full image resource ID (got '{a.image}').")
        publisher, offer, sku, version = parts
        image_reference = {"publisher": publisher, "offer": offer, "sku": sku, "version": version}
        # Marketplace plan (name=sku, product=offer, publisher=publisher); only used with --use-plan.
        plan_ref = {"name": sku, "product": offer, "publisher": publisher}

    # --- SSH public key -----------------------------------------------------
    if not os.path.isfile(a.public_key_path):
        raise SystemExit(f"SSH public key not found at {a.public_key_path}. "
                         f"Generate one with: ssh-keygen -t rsa -b 4096")
    with open(a.public_key_path, "r") as fh:
        pub_key = fh.read().strip()

    # --- CustomData (LF-normalized, base64) ---------------------------------
    # Optional: default is to stamp customdata-stamp.sh (next to this script),
    # which measure-bulk.py reads back as the WorkStart anchor. --no-custom-data
    # launches a bare image with no user-data.
    custom_data_b64 = None
    if not a.no_custom_data:
        cd_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "customdata-stamp.sh")
        if not os.path.isfile(cd_path):
            raise SystemExit("customdata-stamp.sh not found next to this script "
                             "(or pass --no-custom-data to skip it).")
        with open(cd_path, "r", newline="") as fh:
            cd_body = fh.read().replace("\r\n", "\n")
        custom_data_b64 = base64.b64encode(cd_body.encode("utf-8")).decode("ascii")

    # --- Subscription + subnet ----------------------------------------------
    sub_id = az_tsv(["account", "show", "--query", "id", "-o", "tsv"])
    if not sub_id:
        raise SystemExit("Not logged in -- run 'az login' (or 'az login --identity').")
    subnet_id = az_tsv(["network", "vnet", "subnet", "show", "-g", a.infra_resource_group,
                        "--vnet-name", a.vnet, "-n", a.subnet, "--query", "id", "-o", "tsv"])
    if not subnet_id:
        raise SystemExit("Subnet not found -- run setup-infra.ps1 first.")

    # --- Disposable RG ------------------------------------------------------
    az(["group", "create", "-n", a.resource_group, "-l", a.region, "-o", "none"])

    # --- operation id: names the launchBulkInstancesOperations resource -----
    operation_id = str(uuid.uuid4())

    # computerName prefix: keep short so the RP can append a per-VM suffix.
    cn = a.resource_prefix[:11]

    # Sizing: one pinned SKU (--size) or a multi-size pinned basket (--sizes).
    # A multi-size vmSizesProfile lets the RP allocate across several explicit
    # SKUs (real cross-family breadth) without going full attribute-based.
    size_list = [s.strip() for s in a.sizes.split(",")] if a.sizes else [a.size]

    # --- Build the LaunchBulkInstancesOperation body ------------------------
    body = {
        "properties": {
            "capacityType": "VM",
            "capacity": a.count,
            "priorityProfile": {"type": "Spot"},
            "vmSizesProfile": [{"name": s} for s in size_list],
            "computeProfile": {
                "virtualMachineProfile": {
                    "storageProfile": {
                        "imageReference": image_reference,
                        "osDisk": {
                            "osType": "Linux",
                            "createOption": "FromImage",
                            "deleteOption": "Delete",
                            "caching": "ReadWrite",
                            "managedDisk": {"storageAccountType": "Premium_LRS"},
                        },
                    },
                    "osProfile": {
                        "computerName": cn,
                        "adminUsername": a.admin,
                        "linuxConfiguration": {
                            "disablePasswordAuthentication": True,
                            "ssh": {
                                "publicKeys": [
                                    {"path": f"/home/{a.admin}/.ssh/authorized_keys",
                                     "keyData": pub_key}
                                ]
                            },
                        },
                    },
                    "networkProfile": {
                        "networkApiVersion": "2020-11-01",
                        "networkInterfaceConfigurations": [
                            {
                                "name": "nic",
                                "properties": {
                                    "primary": True,
                                    "enableIPForwarding": True,
                                    "ipConfigurations": [
                                        {
                                            "name": "ip",
                                            "properties": {
                                                "primary": True,
                                                "subnet": {"id": subnet_id},
                                            },
                                        }
                                    ],
                                },
                            }
                        ],
                    },
                }
            },
        }
    }

    # Optional OS-disk expansion (cannot shrink below the image's native size).
    if a.os_disk_size_gb > 0:
        body["properties"]["computeProfile"]["virtualMachineProfile"]["storageProfile"]["osDisk"]["diskSizeGB"] = a.os_disk_size_gb

    # Optional CustomData: attach only when not skipped (default: WorkStart stamp).
    if custom_data_b64:
        body["properties"]["computeProfile"]["virtualMachineProfile"]["osProfile"]["customData"] = custom_data_b64

    # Optional extensions: computeProfile.extensions is a VMSS-style array, a
    # sibling of virtualMachineProfile. AMA installs at launch this way (the DCR
    # association is a separate resource). computeApiVersion pins the handler schema.
    if a.extensions:
        with open(a.extensions, "r", encoding="utf-8") as fh:
            ext = json.load(fh)
        ext_list = ext.get("extensions") if isinstance(ext, dict) else ext
        if not isinstance(ext_list, list) or not ext_list:
            raise SystemExit("--extensions file must be a non-empty JSON array (or {'extensions':[...]}).")
        cp = body["properties"]["computeProfile"]
        cp["extensions"] = ext_list
        cp["computeApiVersion"] = a.compute_api_version

    # Attribute-based selection: describe the VM shape instead of pinning a SKU.
    # vmAttributes is a sibling of vmSizesProfile under properties and is mutually
    # exclusive with it -- so drop vmSizesProfile when --use-attributes is set.
    if a.use_attributes:
        body["properties"].pop("vmSizesProfile", None)
        body["properties"]["vmAttributes"] = {
            "vCpuCount": {"min": a.min_vcpu, "max": a.max_vcpu},
            "memoryInGiB": {"min": a.min_mem_gib, "max": a.max_mem_gib},
            "architectureTypes": [a.arch],
        }
        # Optional: drop specific SKUs from the resolved attribute basket.
        if a.exclude_sizes:
            body["properties"]["vmAttributes"]["excludedVMSizes"] = \
                [s.strip() for s in a.exclude_sizes.split(",")]

    # Optional Marketplace plan (required by some images, e.g. Flatcar). Plan is a
    # top-level sibling of 'properties' on the bulk resource (ResourcePlanProperty).
    if a.use_plan:
        if not plan_ref:
            raise SystemExit("--use-plan requires a Marketplace URN image, not an image resource id.")
        print(f"Accepting Marketplace terms for {a.image} ...")
        az(["vm", "image", "terms", "accept", "--urn", a.image, "-o", "none"])
        body["plan"] = plan_ref

    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    try:
        json.dump(body, tmp)
        tmp.close()

        # --- Submit: PUT the launchBulkInstancesOperations resource (LRO) ----
        arm_host = f"https://{a.region}.management.azure.com"
        put_uri = (f"{arm_host}/subscriptions/{sub_id}/resourceGroups/{a.resource_group}"
                   f"/providers/Microsoft.ComputeBulkActions/locations/{a.region}"
                   f"/launchBulkInstancesOperations/{operation_id}?api-version={API_VERSION}")
        size_desc = (f"attrs[vCpu {a.min_vcpu}-{a.max_vcpu}, mem {a.min_mem_gib}-{a.max_mem_gib} GiB, {a.arch}]"
                     if a.use_attributes else ",".join(size_list))
        # Client-side wall clock. run_start is the TRUE T0 (the instant the caller
        # issues the bulk PUT) -- the control plane does not stamp anything until
        # after this. The PUT is an async LRO that returns ~immediately, so this
        # marks the start of the provisioning interval the poll loop closes below.
        run_start = time.time()
        print(f"[wall] submit (T0): {time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(run_start))}Z")
        print(f"Submitting bulk launch ({operation_id}): {a.count} x {size_desc} ({a.image}), Spot ...")
        put = subprocess.run(
            ["az", "rest", "--method", "put", "--uri", put_uri, "--resource", ARM_RESOURCE,
             "--headers", "Content-Type=application/json", "--body", f"@{tmp.name}", "-o", "json"],
            capture_output=True, text=True)
    finally:
        os.unlink(tmp.name)

    if put.returncode != 0:
        print(f"Bulk launch PUT failed (exit {put.returncode}) -- raw response:")
        for line in (put.stderr or put.stdout or "").splitlines():
            print(f"    | {line}")
        sys.exit(put.returncode)

    # --- Poll the bulk action's VM list until all reach a terminal state -----
    arm_host = f"https://{a.region}.management.azure.com"
    vm_list_uri = (f"{arm_host}/subscriptions/{sub_id}/resourceGroups/{a.resource_group}"
                   f"/providers/Microsoft.ComputeBulkActions/locations/{a.region}"
                   f"/launchBulkInstancesOperations/{operation_id}/virtualMachines?api-version={API_VERSION}")
    print("Polling bulk action VM status ...")

    def vm_status(v):
        return v.get("operationStatus") or (v.get("properties") or {}).get("operationStatus")

    for i in range(a.max_polls):
        p = subprocess.run(["az", "rest", "--method", "get", "--uri", vm_list_uri,
                            "--resource", ARM_RESOURCE, "-o", "json"],
                           capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip():
            vms = (json.loads(p.stdout).get("value")) or []
            succeeded = sum(1 for v in vms if vm_status(v) == "Succeeded")
            failed = sum(1 for v in vms if vm_status(v) == "Failed")
            creating = sum(1 for v in vms if vm_status(v) == "Creating")
            print(f"  [{i:02d}] total {len(vms)}  succeeded {succeeded}  creating {creating}  failed {failed}")
            if len(vms) >= a.count and creating == 0:
                break
        time.sleep(a.poll_seconds)

    # --- Client-side wall time (submit -> all VMs terminal) ------------------
    # Quantized to --poll-seconds, so accurate to +/- one poll interval. This is
    # the caller's observed fleet-fill wall time; the precise per-VM control-plane
    # numbers come from measure-bulk.py (which can now anchor Orch to the T0 above).
    run_end = time.time()
    print(f"\n[wall] all-terminal:  {time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(run_end))}Z")
    print(f"[wall] submit -> all-terminal: {run_end - run_start:.1f}s "
          f"(poll granularity {a.poll_seconds}s)")
    print(f"\nVMs in {a.resource_group}:")
    subprocess.run(["az", "vm", "list", "-g", a.resource_group, "-d",
                    "--query", "[].{name:name, power:powerState, ip:privateIps}", "-o", "table"])

    print(f"\nbulk operationId: {operation_id}")
    rg_arg = f" -g {a.resource_group}" if a.resource_group != ap.get_default("resource_group") else ""
    print(f"Measure:  python3 measure-bulk.py --operation-id {operation_id}{rg_arg} --with-guest")
    print(f"Cleanup:  az group delete -n {a.resource_group} --yes --no-wait")


if __name__ == "__main__":
    main()
