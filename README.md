# porep-curio-devnet

Machinery to set up a **local Curio docker-devnet** capable of running **PoRep Market deals** and supporting **large paid retrievals**.

## Dependencies

| Dependency | Role |
|------------|------|
| [`curio`](extern/curio) (git submodule, pinned to **v1.28.2**) | Lotus + Curio docker stack |
| `porep-market` | PoRep Market / SPRegistry / Client contracts |
| `filecoin-porep-market-tooling` | Client/SP CLI for propose → allocate → claim |
| `large-paid-retrievals` | `sp-proxy` + `retrieval-client` (MPP / Filecoin Pay) |
| Singularity (local content provider) | Piece CARs / manifest for deals |

`curio` is vendored under [`extern/curio`](extern/curio) as a git submodule today; the remaining dependencies will be brought in the same way.

Clone and initialize:

```bash
git clone <this-repo>
./scripts/setup-submodules.sh
```

That runs `git submodule update --init --recursive`, resets `./extern/curio` to the pinned commit, applies [`patches/curio/`](patches/curio/) (compose `host.docker.internal`, IPNI null-head guard, Dockerfile/`make deps` submodule skips), prepares `extern/curio/docker/local-src` (filecoin-services + multicall3 for contracts-bootstrap), then runs `make docker/devnet`. Set `SKIP_DOCKER=1` to skip the image build.

## Scripts

All under [`scripts/`](scripts/):

| Script | Purpose |
|--------|---------|
| `setup-submodules.sh` | Init submodules, apply `patches/curio/*`, prepare `docker/local-src`, run `make docker/devnet` |
| `init-curio.sh` | Post-bootstrap Curio config (SSRF off, IPNI announce, disable WinningPoSt, miner control, escrow) |
| `gen-devnet-env.sh` | Write `porep-market` `.env` from Curio contract bootstrap artifacts |
| `setup-curio-devnet.sh` | Deploy (optional) + fund SP org + write tooling `.env` + register Curio miner + DataCap |
| `curio-docker.sh` | Thin wrapper: run `curio` CLI inside the compose service (`CURIO_PATH`) |
| `make-deal.sh` | End-to-end deal: propose → accept → init → allocate → onboard → claim → add-url |
| `extract-keys-from-env.sh` | Copy CLIENT/SP keys from tooling `.env` into key files for retrieval tooling |
| `fund-devnet-wallets.sh` | Fund retrieval wallets with FIL + USDFC after a chain reset |
| `devnet-env.sh` | `source` to export `PAYMENTS` / `USDFC` / `POREP_MARKET` / provider + piece CID for sp-proxy |

Also included: `NoOpMetaAllocator.{sol,json}` (MetaAllocator stub required for local Client DataCap transfer).

## Typical flow

1. `./scripts/setup-submodules.sh` (inits submodules, applies Curio patches, prepares local-src, builds `docker/devnet` images).
2. Start Curio compose: `(cd extern/curio && make devnet/up)`.
3. `./scripts/init-curio.sh`
4. `./scripts/setup-curio-devnet.sh --deploy` (or without `--deploy` if contracts are already up).
5. Serve a Singularity manifest; run `./scripts/make-deal.sh`.
6. For paid retrievals: `./scripts/extract-keys-from-env.sh`, `./scripts/fund-devnet-wallets.sh`, then `source ./scripts/devnet-env.sh` and run `sp-proxy` / `retrieval-client`.

See each script’s header for flags and env overrides (`CURIO_DIR`, `POREP_MARKET_DIR`, `TOOLING_DIR`, `ENV_FILE`, …).

## Prerequisites

- Docker
- `cast`, `jq`, `curl`; `just` + `forge` for contract deploy
- `aria2c` for `make-deal.sh` onboard-data
- Tooling Python venv available for the CLI (once `filecoin-porep-market-tooling` is present)
