# azure-bulkactions-lab

Tooling to launch a disposable fleet of Spot VMs in a single Azure **BulkActions** call and measure their end-to-end provisioning latency. Built for boot-latency benchmarking on preview BulkActions; `az`-only, Python stdlib, no SDK.

## Scripts

- **[provision-bulk.py](provision-bulk.py)** — launches N Spot VMs in one BulkActions PUT (pinned SKU, multi-size basket, or attribute-based selection; SIG/Marketplace images; optional CustomData and extensions). See [provision-bulk.README.md](provision-bulk.README.md).
- **[measure-bulk.py](measure-bulk.py)** — runs on an in-VNet jump host; discovers the fleet, rebases every boot anchor onto the operation's T0, and reports the latency distribution. See [measure-bulk.public.README.md](measure-bulk.public.README.md).

## License

[MIT](LICENSE)
