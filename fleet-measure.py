#!/usr/bin/env python3
"""
fleet-measure.py -- run ON the jump host (inside the VNet).

Enumerates a fleet from the Azure control plane (via az + the jump's managed
identity) and SSHes each running VM's PRIVATE IP directly -- no ProxyJump, no
PowerShell, no CRLF/base64 dance. One file, one language.

It reports four anchors as seconds from the control-plane timeCreated:
    PreBoot  = guest kernel boot (uptime -s)        - timeCreated
    Ready    = fabric "Reported ready" (cloud-init) - timeCreated
    Workload = customdata-stamp.sh fired            - timeCreated
    CIDone   = cloud-init modules-final.finished    - timeCreated

Prereqs on the jump host:
  - az CLI installed and `az login --identity` working. The jump's system-
    assigned managed identity needs **Reader** on the fleet resource group.
  - An SSH private key (default ~/.ssh/id_rsa) whose public half is in each
    fleet VM's authorized_keys (the fleet was made with --generate-ssh-keys
    against your workstation key, so copy that key here once).

Usage:
  python3 fleet-measure.py -g rg-rhel810-spotv3
  python3 fleet-measure.py -g rg-rhel810-spotv3 -u azureuser -i ~/.ssh/id_rsa
"""
import argparse
import datetime
import json
import re
import statistics
import subprocess

# Guest-side collector: bash bootstraps python, python emits ONE JSON line.
COLLECTOR = r'''
created="$1"
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1
py=$(command -v python3 || command -v python || echo /usr/libexec/platform-python)
"$py" - "$created" <<'PY'
import json, sys, datetime, subprocess, time
created = float(sys.argv[1])
def delta(t): return None if t is None else round(t - created, 1)

def boot():
    # Sub-second boot epoch (now - uptime). `uptime -s` floors to the whole
    # second, which skews the AZL3 boot-relative CIDone reconstruction.
    up = float(open("/proc/uptime").read().split()[0])
    return time.time() - up

def report_ready():           # fabric "Provisioning succeeded"; last match = this boot
    ts = None
    try:
        data = subprocess.check_output(["sudo", "-n", "cat", "/var/log/cloud-init.log"]).decode(errors="ignore")
        for line in data.splitlines():
            lo = line.lower()
            if "report" in lo and "ready" in lo:
                try:
                    ts = datetime.datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S").timestamp()
                except Exception:
                    pass
    except Exception:
        pass
    return ts

def cloud_init_done():
    # Newer cloud-init (e.g. Azure Linux 3) records stage times as seconds since
    # boot, not an absolute epoch; reconstruct absolute time from boot when so.
    try:
        f = json.load(open("/var/lib/cloud/data/status.json"))["v1"]["modules-final"]["finished"]
    except Exception:
        return None
    if f is None:
        return None
    return f if f > 1e9 else boot() + f

def workload():
    try:
        return float(open("/var/lib/customdata-start.stamp").read())
    except Exception:
        return None

print(json.dumps({
    "PreBoot":  delta(boot()),
    "Ready":    delta(report_ready()),
    "Workload": delta(workload()),
    "CIDone":   delta(cloud_init_done()),
}))
PY
'''

ANCHORS = ("PreBoot", "Ready", "Workload", "CIDone")


def created_epoch(s):
    # az emits 7 fractional digits (e.g. ...20.5758866+00:00); fromisoformat
    # before Python 3.11 only accepts 3 or 6, so clamp the fraction to 6.
    s = re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00"))
    return datetime.datetime.fromisoformat(s).timestamp()


def az_fleet(rg):
    out = subprocess.check_output([
        "az", "vm", "list", "-g", rg, "-d", "-o", "json",
        "--query", "[].{name:name, ip:privateIps, created:timeCreated, power:powerState}",
    ])
    return json.loads(out)


def measure(ip, created_epoch, user, identity):
    args = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=15",
    ]
    if identity:
        args += ["-i", identity]
    args += [f"{user}@{ip}", f"bash -s -- {created_epoch}"]
    # Linux origin: piping the LF script via stdin is clean -- no CRLF, no base64.
    p = subprocess.run(args, input=COLLECTOR, capture_output=True, text=True)
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line), None
    # No JSON came back -- report exactly why (exit code + stderr/stdout).
    detail = (p.stderr or p.stdout or "").strip() or f"exit {p.returncode}, no output"
    return None, detail


def main():
    ap = argparse.ArgumentParser(description="Fleet provisioning measurement from the jump host.")
    ap.add_argument("-g", "--resource-group", required=True)
    ap.add_argument("-u", "--user", default="azureuser")
    ap.add_argument("-i", "--identity", default=None, help="SSH private key (default: ssh's own ~/.ssh/id_rsa)")
    a = ap.parse_args()

    rows = []
    for v in az_fleet(a.resource_group):
        name = v["name"]
        print(f"\n--- {name} ---")
        if v.get("power") and "running" not in v["power"]:
            print(f"  skip: {v['power']} (not running)")
            continue
        ip = (v.get("ip") or "").split(",")[0].strip()
        if not ip:
            print("  skip: no private IP")
            continue
        created = created_epoch(v["created"])
        r, err = measure(ip, created, a.user, a.identity)
        if not r:
            print(f"  ssh/collect failed: {err}")
            continue
        r["VM"] = name
        rows.append(r)
        print("  " + "  ".join(f"{k}={r[k]}s" for k in ANCHORS))

    if rows:
        print(f"\n=== MEDIANS (n={len(rows)}) ===")
        meds = []
        for k in ANCHORS:
            vals = sorted(x[k] for x in rows if x[k] is not None)
            m = round(statistics.median(vals), 1) if vals else None
            meds.append(f"{k}={m}s")
        print("  ".join(meds))


if __name__ == "__main__":
    main()
