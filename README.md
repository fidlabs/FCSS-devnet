# porep-curio-devnet

Machinery to set up a **local Curio docker-devnet** capable of running **PoRep Market deals** and supporting **large paid retrievals**.

This repo is the glue between sibling checkouts:

| Sibling | Role |
|---------|------|
| [`curio`](../curio) | Lotus + Curio docker stack |
| [`porep-market`](../porep-market) | PoRep Market / SPRegistry / Client contracts |
| [`filecoin-porep-market-tooling`](../filecoin-porep-market-tooling) | Client/SP CLI for propose → allocate → claim |
| [`large-paid-retrievals`](../large-paid-retrievals) | `sp-proxy` + `retrieval-client` (MPP / Filecoin Pay) |
| [`singularity-root`](../singularity-root) | Local piece CARs / Singularity content provider |

Scripts assume this layout (siblings under the same parent directory) unless you override paths with env vars.

## Scripts

All under [`scripts/`](scripts/):

| Script | Purpose |
|--------|---------|
| `init-curio.sh` | Post-bootstrap Curio config (SSRF off, IPNI announce, disable WinningPoSt, miner control, escrow) |
| `gen-devnet-env.sh` | Write `porep-market` `.env` from Curio contract bootstrap artifacts |
| `setup-curio-devnet.sh` | Deploy (optional) + fund SP org + write tooling `.env` + register Curio miner + DataCap |
| `curio-docker.sh` | Thin wrapper: run `curio` CLI inside the compose service (`CURIO_PATH`) |
| `make-deal.sh` | End-to-end deal: propose → accept → init → allocate → onboard → claim → add-url |
| `extract-keys-from-env.sh` | Copy CLIENT/SP keys from tooling `.env` into `large-paid-retrievals` |
| `fund-devnet-wallets.sh` | Fund retrieval wallets with FIL + USDFC after a chain reset |
| `devnet-env.sh` | `source` to export `PAYMENTS` / `USDFC` / `POREP_MARKET` / provider + piece CID for sp-proxy |

Also included: `NoOpMetaAllocator.{sol,json}` (MetaAllocator stub required for local Client DataCap transfer).

## Typical flow

1. Start Curio docker compose (`../curio/docker`).
2. `./scripts/init-curio.sh`
3. `./scripts/setup-curio-devnet.sh --deploy` (or without `--deploy` if contracts are already up).
4. Serve a Singularity manifest; run `./scripts/make-deal.sh`.
5. For paid retrievals: `./scripts/extract-keys-from-env.sh`, `./scripts/fund-devnet-wallets.sh`, then `source ./scripts/devnet-env.sh` and run `sp-proxy` / `retrieval-client`.

See each script’s header for flags and env overrides (`CURIO_DIR`, `POREP_MARKET_DIR`, `TOOLING_DIR`, `ENV_FILE`, …).

## Prerequisites

- Docker (Curio compose stack running)
- `cast`, `jq`, `curl`; `just` + `forge` for contract deploy
- `aria2c` for `make-deal.sh` onboard-data
- Sibling checkouts above, with tooling’s Python venv available for the CLI
