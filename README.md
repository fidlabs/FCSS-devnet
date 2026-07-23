# porep-curio-devnet

Machinery to set up a **local Curio docker-devnet** capable of running **PoRep Market deals** and supporting **large paid retrievals**.

Pinned submodule versions: **Curio v1.28.2**, **porep-market v1.2.0**, **filecoin-porep-market-tooling v1**.

## Dependencies

| Dependency | Role |
|------------|------|
| [`curio`](extern/curio) (git submodule, **v1.28.2**) | Lotus + Curio docker stack |
| [`porep-market`](extern/porep-market) (git submodule, **v1.2.0**) | PoRep Market / SPRegistry / Client contracts |
| [`filecoin-porep-market-tooling`](extern/filecoin-porep-market-tooling) (git submodule, **v1**) | Client/SP CLI for propose → allocate → claim |
| `large-paid-retrievals` | `sp-proxy` + `retrieval-client` (MPP / Filecoin Pay) |
| Singularity (local content provider) | Piece CARs / manifest for deals |

`curio`, `porep-market`, and `filecoin-porep-market-tooling` are vendored under [`extern/`](extern/) as git submodules; the remaining dependencies will be brought in the same way.

## Quick start

```bash
git clone <this-repo>
just init    # submodules, patches, docker images, tooling venv
just up      # compose up + Curio config + porep deploy
just make-deal
```

`just init` runs [`scripts/init.sh`](scripts/init.sh): `git submodule update --init --recursive`, resets Curio/tooling to pinned commits, applies [`patches/curio/`](patches/curio/) and [`patches/filecoin-porep-market-tooling/`](patches/filecoin-porep-market-tooling/), prepares `extern/curio/docker/local-src`, then `make docker/devnet`. Set `SKIP_DOCKER=1` to skip the image build. It also creates the tooling Python venv.

## Scripts

Shared helpers live in [`scripts/lib/`](scripts/lib/) (`common.sh`, `envfile.sh`, `lotus.sh`). Entrypoints:

| Script | Purpose |
|--------|---------|
| `init.sh` | Submodules, patches, `local-src`, `make docker/devnet` |
| `up-curio.sh` | Post-bootstrap Curio config (SSRF, IPNI, WinningPoSt, control, escrow) |
| `up-porep.sh` | Deploy (optional) + SP org + tooling `.env` + register miner + DataCap |
| `gen-porep-env.sh` | Write porep-market `.env` from Curio contract artifacts (used by `up-porep --deploy`) |
| `curio-cli.sh` | `CURIO_PATH` wrapper: `curio` inside the compose service |
| `make-deal.sh` | Propose → accept → allocate → onboard → claim → add-url |
| `retrieval-keys.sh` | Copy CLIENT/SP keys from tooling `.env` for retrieval tooling |
| `retrieval-fund.sh` | Fund retrieval wallets with FIL + USDFC after a chain reset |
| `retrieval-env.sh` | `source` to export `PAYMENTS` / `USDFC` / `POREP_MARKET` / piece CID for sp-proxy |

Also: [`contracts/allocator/NoOpMetaAllocator.{sol,json}`](contracts/allocator/) (MetaAllocator stub for local Client DataCap transfer).

## Typical flow

1. `just init`
2. `just up` (compose + `up-curio.sh` + `up-porep.sh --deploy`)
3. Serve a Singularity manifest; `just make-deal`
4. Paid retrievals: `./scripts/retrieval-keys.sh`, `./scripts/retrieval-fund.sh`, then `source ./scripts/retrieval-env.sh` and run `sp-proxy` / `retrieval-client`

See each script’s header for flags and env overrides (`CURIO_DIR`, `POREP_MARKET_DIR`, `TOOLING_DIR`, `ENV_FILE`, `RPC_URL`, …).

## Prerequisites

- Docker
- `cast`, `jq`, `curl`; `just` + `forge` for contract deploy
- `aria2c` for `make-deal.sh` onboard-data
- Tooling venv via `just init` (or `just _tooling-venv`)
