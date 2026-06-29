# Measurement Logic — v2 (BulkActions, T0-rebased)

> **What changed from v1.** v1 (see [measurement-logic.md](measurement-logic.md))
> measures every VM from its **own** `timeCreated`. That is correct for a single
> VM but it **normalizes away the one thing BulkActions is about**: how a whole
> fleet fans out from a *single* API call. v2 adds the missing left-hand anchor
> (T0) and rebases everything onto it, and reports a **distribution + fill
> curve** instead of a mean.

---

## 1. The new leading anchor: T0 and Orchestration

A bulk launch is **one** API call that creates **N** VMs. The thing that matters
is the spread between that call and each VM coming into existence:

```
T0 ──Orchestration──▶ VM.timeCreated ──PreBoot──▶ kernel up ──▶ Ready ──▶ Workload ──▶ CIDone
(bulk API call)        (per-VM create)
```

```
Orchestration = VM.timeCreated − T0          (seconds)
```

- **T0** — `properties.createdTime` on the bulk operation resource. Server-stamped,
  immutable, **shared by the whole fleet**. This is the origin v1 was missing.
- **VM.timeCreated** — the per-VM control-plane create stamp (the v1 baseline).
  Now reinterpreted as the **end** of orchestration, not the origin of everything.

Every downstream guest anchor is then **rebased onto T0**:

```
<anchor>FromT0 = Orchestration + <anchor>     for Boot / Ready / Workload / CIDone
```

so the numbers read as *true* "API call → Ready" end-to-end, not the
per-VM-origin understatement v1 produced.

The four guest anchors themselves (PreBoot, Ready, Workload, CIDone) are
**unchanged from v1** — same sources, same cross-distro normalization. v2 only
prepends the T0 axis and shifts the reporting frame.

---

## 2. Why a distribution, not a mean

At fleet scale the engine deliberately trades **simultaneity for throughput**:
it does not create all N VMs at the same instant. The mean hides this; the
**tail (straggler)** is what determines when the fleet is actually usable.

v2 therefore reports, per anchor:

- **p50 / p90 / p99**, **min / max**, and **spread** (max − min);
- a **fleet fill curve** — how many VMs have crossed the anchor over time.

Two fleets with the same mean can have very different fill shapes:

- **Wide fan-out** (SKU pinned): VMs land across several time buckets → larger
  spread, lower floor.
- **Near-synchronous** (attribute-based selection): VMs land in one bucket → tiny
  spread (~0.2 s), higher floor. (See the vmAttributes result in
  [ba-results-2026-06-27.md](ba-results-2026-06-27.md).)

---

## 3. Authoritative fleet discovery

The fleet is discovered from the **operation**, not by listing the resource
group (which can include unrelated or stale resources):

```
GET .../launchBulkInstancesOperations/{operationId}/virtualMachines?api-version=2026-02-01-preview
  → per-VM { id, name, operationStatus, error? }
```

- VM names follow `{operationId}_{index}`.
- Per-VM **bulk** failures are read here via `.error.code` / `.error.message`
  (e.g. Flatcar without a plan → `VMMarketplaceInvalidInput`).

`timeCreated` (and, only when `-WithGuest`, ip/power) is then fetched from the
control plane:

- **Orchestration query** uses plain `az vm list` (NO `-d`). `-d` resolves every
  NIC, and a single dangling NIC left by a *prior failed op* errors the whole
  call → empty result → **n=0**. This was a real bug; `-d` is now used **only**
  for ip/power under `-WithGuest`, and that path tolerates per-VM failures.

---

## 4. Guest collection today (pull over ssh -J) — and its limits

When `-WithGuest -JumpHost <ip>` is set, v2 wraps (does not replace) the v1 guest
collector. The collector heredoc is base64-piped to each VM and run as
`base64 -d | bash -s -- <timeCreated>`, which prints a JSON line of the four
anchors; v2 rebases each onto T0.

Transport hardening currently in place:
- throwaway known_hosts (`$env:TEMP\measure_bulk_known_hosts`) +
  `StrictHostKeyChecking=no` → never touches the real known_hosts;
- stderr **merged** (`2>&1`) under `$ErrorActionPreference='Continue'` so real
  failures are visible (PS 5.1 promotes native stderr to terminating errors);
- **retry-with-backoff** (`-CollectRetries` default 3, `-CollectRetryDelay`
  default 20 s) for slow-booters whose sshd isn't ready inside `ConnectTimeout`.
  Retries do **not** distort Boot/Ready — those are computed from each VM's own
  `timeCreated`; retry only avoids *dropping* a slow VM.

**Known structural weaknesses of this transport (the reason for v3 below):**
- **Per-VM `ssh -J` proxy-jump** from the laptop renegotiates a fresh proxied hop
  for every VM → "banner exchange" / port-65535 timeouts under load.
- **JIT dependence** — the jump host's port 22 is gated by a time-boxed JIT grant;
  when it lapses mid-run, *all* remaining VMs fail.
- **Pull-only** — an evicted (deallocated) Spot VM has no running guest, so its
  data is unrecoverable. The longer you wait, the fewer VMs remain measurable.

---

## 5. Planned rearchitecture (v3) — single in-network vantage

**Decision (2026-06-27): collapse guest collection to ONE in-network machine.**
The multiple random `ssh -J` proxy jumps are the root of the flakiness. A single
vantage box that already sits inside the `rg-infra` vnet (or peered) has **direct
line-of-sight to the `rg-test` private IPs**, so it can hit each VM **directly**:

- no `-J` proxy hop, so no per-hop renegotiation;
- no per-run JIT dependence for the inner hop (internal, NSG-allowed);
- the laptop just **kicks off** the run on that box.

Open question to settle when building v3: **reuse the existing jump host** as the
collector (run the collector *on* it instead of hopping *through* it) vs. **a
dedicated small measurement VM**. That choice drives the rest of the rewrite.

Longer-term, surviving Spot eviction requires moving from pull to a **push**
model (each guest self-reports its anchors on boot to a central sink), so that an
evicted VM's data is already captured before it disappears.

---

## 6. Anchor reference (unchanged from v1)

The per-VM anchors, sources, and expected ordering are identical to v1 — see
[measurement-logic.md](measurement-logic.md) for the full detail:

```
PreBoot < Ready < Workload ≤ CIDone
```

- **PreBoot** — `/proc/uptime` boot epoch − created (platform/fabric + kernel).
- **Ready** — cloud-init "Reported ready to Azure fabric." (network stage).
- **Workload** — `/var/lib/customdata-start.stamp` (CustomData began; final stage).
- **CIDone** — `v1.modules-final.finished` in `status.json`, normalized
  (`f if f > 1e9 else boot()+f`) for the RHEL/Ubuntu-epoch vs. AZL-boot-relative split.

v2 simply prepends **Orchestration** and shifts each of these onto the T0 frame.
