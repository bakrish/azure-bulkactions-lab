#!/usr/bin/env python3
"""
measure-bulk.py -- run on a VM that has direct VNET access to the fleet.

Orchestration = VM.timeCreated - T0      (the single bulk API call -> VM created)

where T0 = the bulk operation resource's server-stamped properties.createdTime.

BulkActions: read T0, discover the fleet authoritatively from the operation, report
Orchestration as a DISTRIBUTION (p50/p90/p99, min/max, spread) + a fleet fill curve.
With --with-guest it also rebases every boot/init anchor onto T0.

Azure access is ONLY via the `az` CLI shelled through subprocess (no Azure SDK /
AAD libraries). Python stdlib only. `az` owns every token -- on the jump,
`az login --identity` with the jump's managed identity (needs Reader on the sub).

Prereqs on the jump host:
  - az CLI installed and `az login --identity` working (Reader on the sub).
  - An SSH private key (default ~/.ssh/id_rsa) whose public half is in each fleet
    VM's authorized_keys. Direct to the private IP -- no ProxyJump.

Usage:
  # Orchestration distribution only (defaults: -g rg-test, --region uksouth):
  python3 measure-bulk.py --operation-id 17b9b2ad-...
  # End-to-end rebased onto T0:
  python3 measure-bulk.py --operation-id 17b9b2ad-... --with-guest
"""
import argparse
import datetime
import json
import math
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

API_VERSION = "2026-02-01-preview"
ARM_RESOURCE = "https://management.azure.com/"

# Guest-side collector: bash bootstraps python, python emits ONE JSON line.
# VERBATIM from fleet-measure.py -- this is the accuracy core; do not alter.
COLLECTOR = r'''
created="$1"
command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1
py=$(command -v python3 || command -v python || echo /usr/libexec/platform-python)
"$py" - "$created" <<'PY'
import json, sys, datetime, subprocess, time, re
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

def _dur(s):
    # systemd prints durations as "1min 3.456s" / "12.345s" / "345ms"; sum parts.
    tot = 0.0
    for m in re.finditer(r"([\d.]+)\s*(min|ms|s)", s):
        v = float(m.group(1)); u = m.group(2)
        tot += v * 60 if u == "min" else v / 1000.0 if u == "ms" else v
    return round(tot, 3)

def systemd_times():
    # `systemd-analyze time` is the infra-INDEPENDENT boot signal: every value is
    # measured by systemd from the uptime origin (kernel-clock zero), so it excludes
    # T0 and PreBoot/hydration entirely. One human line, parsed here, e.g.:
    #   Startup finished in 1.5s (kernel) + 3.2s (initrd) + 12.0s (userspace) = 16.8s
    # firmware/loader are usually absent on VMs; initrd may be missing on some
    # distros; if startup isn't finished it raises -> empty (blank columns).
    try:
        out = subprocess.check_output(["systemd-analyze", "time"],
                                      stderr=subprocess.STDOUT).decode(errors="ignore")
    except Exception:
        return {}
    res = {}
    for label, key in (("kernel", "Kernel"), ("initrd", "Initrd"),
                       ("userspace", "Userspace")):
        m = re.search(r"([0-9][^()+=]*?)\s*\(" + label + r"\)", out)
        if m:
            res[key] = _dur(m.group(1))
    m = re.search(r"=\s*([0-9][^\n]*)", out)
    if m:
        res["SdTotal"] = _dur(m.group(1))
    return res

out = {
    "PreBoot":  delta(boot()),
    "Ready":    delta(report_ready()),
    "WorkStart": delta(workload()),
    "CIDone":   delta(cloud_init_done()),
}
out.update(systemd_times())
print(json.dumps(out))
PY
'''

ANCHORS = ("PreBoot", "Ready", "WorkStart", "CIDone")


# --- az helpers (subprocess only; az owns the token) ------------------------
def az(args, check=True):
    p = subprocess.run(["az"] + args, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise SystemExit(f"az {' '.join(args)} failed:\n{(p.stderr or p.stdout).strip()}")
    return p


def az_json(args, default=None, check=True):
    p = az(args, check=check)
    if p.returncode != 0:
        return default
    out = p.stdout.strip()
    if not out:
        return default
    return json.loads(out)


def created_epoch(s):
    # az emits a VARIABLE number of fractional digits (0-7; trailing zeros are
    # stripped, so e.g. ...27.33952+00:00 is only 5). fromisoformat before
    # Python 3.11 accepts ONLY exactly 3 or 6, so normalize the fraction to 6
    # (pad short, truncate long).
    s = s.replace("Z", "+00:00")
    m = re.search(r"\.(\d+)", s)
    if m:
        frac = (m.group(1) + "000000")[:6]
        s = s[:m.start()] + "." + frac + s[m.end():]
    return datetime.datetime.fromisoformat(s).timestamp()


# --- distribution helpers (mirror measure-bulk.ps1) -------------------------
def pctile(vals, p):
    s = sorted(v for v in vals if v is not None)
    n = len(s)
    if n == 0:
        return None
    if n == 1:
        return round(float(s[0]), 1)
    rank = math.ceil(p / 100.0 * n)
    rank = max(1, min(rank, n))
    return round(float(s[rank - 1]), 1)


def stat_row(name, vals):
    s = [v for v in vals if v is not None]
    if not s:
        return {"Anchor": name, "p50": "-", "p90": "-", "p99": "-",
                "min": "-", "max": "-", "spread": "-", "n": 0}
    mn = round(min(s), 1)
    mx = round(max(s), 1)
    return {"Anchor": name, "p50": pctile(s, 50), "p90": pctile(s, 90), "p99": pctile(s, 99),
            "min": mn, "max": mx, "spread": round(mx - mn, 1), "n": len(s)}


def fill_curve(deltas):
    s = sorted(v for v in deltas if v is not None)
    n = len(s)
    if not n:
        print("  (no data)")
        return
    mx = s[-1] or 1.0
    if mx <= 0:
        mx = 1.0
    buckets = 12
    width = mx / buckets
    for b in range(1, buckets + 1):
        edge = width * b
        cum = sum(1 for x in s if x <= edge)
        bar = "#" * int(round((cum / n) * 30))
        print(f"  +{edge:6.1f}s  {bar:<30} {cum}/{n}")


def _cell(x):
    return "" if x is None else str(x)


def print_table(rows, cols):
    if not rows:
        return
    widths = {c: max([len(str(c))] + [len(_cell(r.get(c))) for r in rows]) for c in cols}
    print("  ".join(str(c).ljust(widths[c]) for c in cols))
    print("  ".join("-" * widths[c] for c in cols))
    for r in rows:
        print("  ".join(_cell(r.get(c)).ljust(widths[c]) for c in cols))


# --- guest collect (direct private IP, no ProxyJump) ------------------------
def measure(ip, created_ep, user, identity, retries=3, delay=20):
    args = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=15",
    ]
    if identity:
        args += ["-i", identity]
    args += [f"{user}@{ip}", f"bash -s -- {created_ep}"]
    # Linux origin: piping the LF script via stdin is clean -- no CRLF, no base64.
    # Slow-booting VMs can time out the hop (banner exchange) on the first try, so
    # retry the collect with backoff before giving up.
    detail = None
    for attempt in range(1, retries + 1):
        p = subprocess.run(args, input=COLLECTOR, capture_output=True, text=True)
        for line in p.stdout.splitlines():
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line), None
        detail = (p.stderr or p.stdout or "").strip() or f"exit {p.returncode}, no output"
        if attempt < retries:
            last = detail.splitlines()[-1][:80] if detail else ""
            print(f"  collect attempt {attempt}/{retries} failed ({last}); retrying in {delay}s ...")
            time.sleep(delay)
    return None, detail


# --- mode: BulkActions (T0-rebased) -----------------------------------------
def run_bulk(a):
    arm_host = f"https://{a.region}.management.azure.com"
    sub = az(["account", "show", "--query", "id", "-o", "tsv"]).stdout.strip()
    if not sub:
        raise SystemExit("Not logged in -- run 'az login' (or 'az login --identity').")

    base = (f"{arm_host}/subscriptions/{sub}/resourceGroups/{a.resource_group}"
            f"/providers/Microsoft.ComputeBulkActions/locations/{a.region}"
            f"/launchBulkInstancesOperations/{a.operation_id}")

    # 1) operation resource -> T0
    op = az_json(["rest", "--method", "get", "--uri", f"{base}?api-version={API_VERSION}",
                  "--resource", ARM_RESOURCE, "-o", "json"])
    props = (op or {}).get("properties", {})
    created = props.get("createdTime")
    if not created:
        raise SystemExit(f"Operation {a.operation_id} has no createdTime "
                         f"(not found, or wrong -g/--region).")
    t0 = created_epoch(created)
    capacity = props.get("capacity")
    prov_state = props.get("provisioningState")

    # 2) authoritative fleet + status
    fleet = (az_json(["rest", "--method", "get", "--uri",
                      f"{base}/virtualMachines?api-version={API_VERSION}",
                      "--resource", ARM_RESOURCE, "-o", "json"]) or {}).get("value") or []
    by_status = {}
    for f in fleet:
        st = f.get("operationStatus")
        by_status[st] = by_status.get(st, 0) + 1
    succeeded = [f for f in fleet if f.get("operationStatus") == "Succeeded"]

    # 3) control-plane timeCreated (NO -d: -d resolves every NIC, and one dangling
    #    NIC from a prior failed op errors the whole call and drops all rows).
    cp = az_json(["vm", "list", "-g", a.resource_group,
                  "--query", "[].{name:name, created:timeCreated}", "-o", "json"]) or []
    cp_by = {v["name"]: dict(v) for v in cp}
    if a.with_guest:
        # ip/power need instance/network details; tolerate per-VM failures.
        detail = az_json(["vm", "list", "-g", a.resource_group, "-d",
                          "--query", "[].{name:name, ip:privateIps, power:powerState}",
                          "-o", "json"], default=[], check=False) or []
        for v in detail:
            if v["name"] in cp_by:
                cp_by[v["name"]]["ip"] = v.get("ip")
                cp_by[v["name"]]["power"] = v.get("power")

    # 4) orchestration deltas
    rows = []
    for f in sorted(fleet, key=lambda x: x.get("name", "")):
        v = cp_by.get(f["name"])
        orch = None
        if v and v.get("created"):
            orch = round(created_epoch(v["created"]) - t0, 1)
        rows.append({"VM": f["name"].replace(a.operation_id, "#"),
                     "Status": f.get("operationStatus"),
                     "Orchestration": orch})

    print(f"Bulk operation : {a.operation_id}")
    print(f"T0 (createdTime): {created}")
    status_str = " ".join(f"{k}={v}" for k, v in by_status.items())
    print(f"Requested {capacity} | delivered {len(succeeded)} | "
          f"provisioningState {prov_state} | status [{status_str}]")

    print("\n=== ORCHESTRATION: API call -> VM created (seconds from T0) ===")
    print_table(rows, ["VM", "Status", "Orchestration"])
    print("\nDistribution:")
    print_table([stat_row("Orchestration", [r["Orchestration"] for r in rows])],
                ["Anchor", "p50", "p90", "p99", "min", "max", "spread", "n"])
    print("\nFleet fill curve (cumulative VMs created since T0):")
    fill_curve([r["Orchestration"] for r in rows])

    if not a.with_guest:
        print("\n(boot/init not collected; add --with-guest for rebased end-to-end.)")
        return

    # 5) guest collect, rebased onto T0
    e2e = []

    def collect_one(f):
        # Pure per-VM work: cheap skip checks + the (blocking) SSH collect. Returns
        # (name, idx, message, row|None) so the caller prints/aggregates. No shared
        # mutable state -> safe to run under a thread pool (each call owns its own
        # ssh subprocess; the GIL is released while blocked on it).
        idx = f["name"].replace(a.operation_id, "#")
        v = cp_by.get(f["name"])
        if not v:
            return f["name"], idx, "  skip: no control-plane record", None
        if v.get("power") and "running" not in v["power"]:
            return f["name"], idx, f"  skip: {v['power']}", None
        ip = (v.get("ip") or "").split(",")[0].strip()
        if not ip:
            return f["name"], idx, "  skip: no private IP", None
        c_ep = created_epoch(v["created"])
        orch = round(c_ep - t0, 1)
        r, err = measure(ip, c_ep, a.user, a.identity, a.collect_retries, a.collect_retry_delay)
        if not r:
            return f["name"], idx, f"  ssh/collect failed after {a.collect_retries} attempts: {err}", None

        def add(x):
            return None if x is None else round(orch + x, 1)

        row = {"VM": idx, "Orch": orch,
               "BootT0": add(r.get("PreBoot")), "ReadyT0": add(r.get("Ready")),
               "WorkT0": add(r.get("WorkStart")), "CIDoneT0": add(r.get("CIDone")),
               "Kernel": r.get("Kernel"), "Initrd": r.get("Initrd"),
               "Userspace": r.get("Userspace"), "SdTotal": r.get("SdTotal")}
        msg = (f"  Orch={row['Orch']}s  Boot={row['BootT0']}s  Ready={row['ReadyT0']}s  "
               f"WorkStart={row['WorkT0']}s  CIDone={row['CIDoneT0']}s  (all from T0)")
        return f["name"], idx, msg, row

    targets = sorted(succeeded, key=lambda x: x.get("name", ""))
    workers = max(1, a.concurrency)
    rows_by = {}
    if workers == 1 or len(targets) <= 1:
        for f in targets:
            name, idx, msg, row = collect_one(f)
            print(f"\n--- {idx} ---")
            print(msg)
            rows_by[name] = row
    else:
        print(f"\nCollecting {len(targets)} VMs with {workers} parallel SSH workers ...")
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(collect_one, f): f for f in targets}
            for n, fut in enumerate(as_completed(futs), 1):
                name, idx, msg, row = fut.result()
                rows_by[name] = row
                print(f"\n--- [{n}/{len(targets)}] {idx} ---")
                print(msg)
    # Build the table in deterministic (name-sorted) order regardless of completion order.
    for f in targets:
        row = rows_by.get(f["name"])
        if row:
            e2e.append(row)

    if e2e:
        print("\n=== END-TO-END, rebased onto T0 (seconds from the bulk API call) ===")
        print_table(e2e, ["VM", "Orch", "BootT0", "ReadyT0", "WorkT0", "CIDoneT0"])
        print("\nDistribution (from T0):")
        dist = [
            stat_row("Orchestration", [r["Orch"] for r in e2e]),
            stat_row("Boot", [r["BootT0"] for r in e2e]),
            stat_row("Ready", [r["ReadyT0"] for r in e2e]),
            stat_row("WorkStart", [r["WorkT0"] for r in e2e]),
            stat_row("CIDone", [r["CIDoneT0"] for r in e2e]),
        ]
        print_table(dist, ["Anchor", "p50", "p90", "p99", "min", "max", "spread", "n"])

        # Infra-INDEPENDENT view: systemd-analyze, measured from the uptime origin,
        # so it excludes T0 (control-plane) AND PreBoot (placement/hydration). This
        # is the apples-to-apples image-boot number -- steady across day/night.
        if any(r.get("SdTotal") is not None for r in e2e):
            print("\n=== IN-GUEST BOOT (systemd-analyze, uptime-origin -- infra-independent) ===")
            print_table(e2e, ["VM", "Kernel", "Initrd", "Userspace", "SdTotal"])
            print("\nDistribution (independent of T0 and PreBoot/hydration):")
            sd = [
                stat_row("Kernel", [r.get("Kernel") for r in e2e]),
                stat_row("Initrd", [r.get("Initrd") for r in e2e]),
                stat_row("Userspace", [r.get("Userspace") for r in e2e]),
                stat_row("sd-Total", [r.get("SdTotal") for r in e2e]),
            ]
            print_table(sd, ["Anchor", "p50", "p90", "p99", "min", "max", "spread", "n"])


def main():
    ap = argparse.ArgumentParser(
        description="BulkActions T0-rebased fleet measurement, run from the jump host.")
    ap.add_argument("--operation-id", required=True,
                    help="Bulk operation id -> T0-rebased fleet measurement.")
    ap.add_argument("-g", "--resource-group", default="rg-test")
    ap.add_argument("--region", default="uksouth")
    ap.add_argument("--with-guest", action="store_true",
                    help="also collect guest anchors and rebase onto T0.")
    ap.add_argument("-u", "--user", default="azureuser")
    ap.add_argument("-i", "--identity", default=None,
                    help="SSH private key (default: ssh's own ~/.ssh/id_rsa)")
    ap.add_argument("--collect-retries", type=int, default=3)
    ap.add_argument("--collect-retry-delay", type=int, default=20)
    ap.add_argument("--concurrency", type=int, default=32,
                    help="(--with-guest) parallel SSH collect workers. 1 = serial.")
    a = ap.parse_args()
    run_bulk(a)


if __name__ == "__main__":
    main()
