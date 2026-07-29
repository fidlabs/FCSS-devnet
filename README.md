# FCSS-devnet

**FCSS** = **Filecoin Cold Storage Service**. This repository ([`fidlabs/FCSS-devnet`](https://github.com/fidlabs/FCSS-devnet)) is the local **FCSS** development network: a **Curio docker-devnet** that runs **PoRep Market V2 deals** and supports **large paid retrievals**.

(Working tree directory may still be named `porep-curio-devnet`; the GitHub repo name is **FCSS-devnet**.)

This repo targets **PoRep Market V2 contracts** only (`extern/porep-market` on `main`): forge `Deploy.s.sol`, SPRegistry offers, `DataCapEvidenceAdapter` (not the V1 `Client` contract), and the V2 deal lifecycle. It does **not** use V1 `just devnet_deploy` / V1 Client flows.

The resulting stack is suitable for testing [`fidlabs/large-paid-retrievals`](https://github.com/fidlabs/large-paid-retrievals) (`sp-proxy` + `retrieval-client` over MPP / Filecoin Pay). See that project’s README for how to run retrievals against this devnet.

Pinned submodule versions: **Curio v1.28.2**, **porep-market** (`main` / **V2**), **filecoin-porep-market-tooling** (`feature-v2-adjust-contracts`), **filecoin-oracle-service** (`v2`).

## PoRep Market V2

| Piece | V2 in this stack |
|-------|------------------|
| Deploy | `forge script Deploy.s.sol` → `extern/porep-market/deployments/devnet/latest.json` (needs forge libs under `lib/`, from `just init`) |
| Market | `PoRepMarket` proxy (UUPS); deals via `proposeDeal` → accept (if still `PROPOSED`) → init rail |
| Registry | `SPRegistry` — `registerProviderFor`, `setPaymentToken`, `createOffer` (offer price defaults to `1`; contract rejects `0`) |
| Evidence | `DataCapEvidenceAdapter` — `submitDataCapBatch` + `finishDataCapPosting`, then after Curio/VerifReg claims: `PoRepMarket.submitEvidenceBatch` (moves adapter `allocationIds` → `claimIds`) |
| Tooling | CLI on `feature-v2-adjust-contracts` for propose → allocate → claim; `admin submit-evidence` for `submitEvidenceBatch` |
| Deal states | `PROPOSED` → `ACCEPTED` → `ACTIVE` → `FINALIZED` (no V1 `COMPLETED`; DataCap posting finishes while the deal is still `ACCEPTED`) |

Orchestration: [`scripts/porep-market/deploy.sh`](scripts/porep-market/deploy.sh), [`up.sh`](scripts/porep-market/up.sh), [`gen-env.sh`](scripts/porep-market/gen-env.sh), and [`scripts/tooling/make-deal.sh`](scripts/tooling/make-deal.sh). After a chain reset with existing wallets, refresh wiring with `just porep-market up --from-env`.

## Dependencies

| Dependency | Role |
|------------|------|
| [`curio`](extern/curio) (git submodule, **v1.28.2**) | Lotus + Curio docker stack |
| [`porep-market`](extern/porep-market) (git submodule, **main** / **V2**) | PoRep Market V2, SPRegistry, DataCapEvidenceAdapter |
| [`filecoin-porep-market-tooling`](extern/filecoin-porep-market-tooling) (git submodule, **feature-v2-adjust-contracts**) | V2 client/SP/admin CLI (propose → allocate → claim → `submit-evidence`) |
| [`filecoin-oracle-service`](extern/filecoin-oracle-service) (git submodule, **v2**) | Oracle / settlement / SLI jobs against V2 market |
| [`large-paid-retrievals`](https://github.com/fidlabs/large-paid-retrievals) | `sp-proxy` + `retrieval-client` (MPP / Filecoin Pay); test against this devnet |

`curio`, `porep-market`, `filecoin-porep-market-tooling`, and `filecoin-oracle-service` are vendored under [`extern/`](extern/) as git submodules.

## Quick start

```bash
git clone https://github.com/fidlabs/FCSS-devnet.git
cd FCSS-devnet
just init    # submodules (recursive), Curio patches/images, tooling venv, oracle patches
just up      # compose up + Curio config + porep V2 deploy + SP wiring
# prepare + serve a deal manifest/pieces (e.g. Singularity — see below), then:
just make-deal
```

`just init` runs `git submodule update --init --recursive`, then `just curio init` and `just tooling init` (tooling patches + venv). Recursive init is required for porep-market forge libs (`lib/fvm-solidity`, …). Set `SKIP_DOCKER=1` to skip the Curio image build; `SKIP_VENV=1` to skip the tooling venv; `SKIP_PATCH=1` to skip tooling patch reset/apply.

## Just recipes

Root recipes compose submodule modules ([`just/`](just/)):

| Recipe | Does |
|--------|------|
| `just init` | submodule update → `curio init` → `tooling init` (incl. patches) → `oracle patch` |
| `just up` | `curio up` → `porep-market deploy` → `porep-market up` → `oracle up` (init/DB + start, foreground) |
| `just down` | `oracle down` (Postgres compose) + `curio down` |
| `just make-deal …` | tooling venv + V2 deal pipeline (flags go to the script) |

Namespaced (same scripts):

- `just curio init|up|cli|logs|down`
- `just porep-market gen-env|deploy|up`
- `just tooling patch` — reset tooling submodule + apply [`patches/tooling/`](patches/tooling/)
- `just tooling init|make-deal` — `init` applies tooling patches then creates the venv
- `just oracle patch` — reset oracle submodule + apply [`patches/oracle/`](patches/oracle/)
- `just oracle up` — patches + `.env`/build + Postgres/Prisma + `npm run start` (foreground)
- `just oracle get-deals` — `curl` `GET /deals` (optional `--state` / `--page` / `--limit`)
- `just oracle logs` — follow oracle `docker compose` logs
- `just oracle down` — `docker compose down` for oracle Postgres

Oracle cron schedules: edit `TRIGGER_*_CRON` / `SYNC_URL_FINDER_*` in `extern/filecoin-oracle-service/.env` (kept across `just oracle up`), or pass them when regenerating, e.g. `TRIGGER_SYNC_DEALS_JOB_INTERVAL_CRON='* * * * *' just oracle up --force`. Restart after changing crons (`just oracle up`).

Off-chain services **not** part of this local deployment for now: `CDP_SERVICE_URL` (settlement-history sync) and `URL_FINDER_SERVICE_URL` / `URL_FINDER_AUTH_TOKEN` (URL Finder SLI targets). Deal sync and `just oracle get-deals` do not need them; leave those env vars empty unless you point them at external services yourself.

**TODO (push upstream):**

- **Oracle** — local patches under [`patches/oracle/`](patches/oracle/): (1) `0001` settlement history genesis for Curio `CHAIN_ID=31415926`; (2) `0002` re-enable cron schedules; (3) `0003` call `getDealViews` on ViewHelper; (4) `0004` V2 ViewHelper ABI + deal-sync mapping (`proposedAtEpoch` on deal, no `timing` tuple); (5) `0005` skip claim inspector when address unset. Open PRs on oracle `v2` and drop the patches once merged. Local deploy ships ViewHelper via `just porep-market deploy` (or `--view-helper-only`).
- **Tooling** — local patches under [`patches/tooling/`](patches/tooling/) (see that README): compose `get_deal_view` from market getters + V2 ABI (no on-market `getDealView`); `admin submit-evidence` for `submitEvidenceBatch`; `proposeDeal` `dealType` (`--deal-type private|public`, default private). Open PRs on tooling `feature-v2-adjust-contracts` (or successor) and drop the patches once merged. `make-deal` always runs submit-evidence after allocations complete (orchestration in this repo).

## Scripts

Shared helpers live in [`scripts/lib/`](scripts/lib/) (`common.sh`, `envfile.sh`, `lotus.sh`). Task scripts in this repo configure the vendored submodules:

| Script | Purpose |
|--------|---------|
| `scripts/curio/init.sh` | Curio patches, `local-src`, `make docker/devnet` |
| `scripts/curio/up.sh` | Post-bootstrap Curio config (SSRF, IPNI, WinningPoSt, control, escrow) |
| `scripts/curio/cli.sh` | `CURIO_PATH` wrapper: `curio` inside the compose service |
| `scripts/porep-market/gen-env.sh` | Write porep-market `.env` for V2 `Deploy.s.sol` + Curio artifacts |
| `scripts/porep-market/deploy.sh` | NoOp MetaAllocator + V2 `Deploy.s.sol` + helpers (ViewHelper, ClaimInspector, SectorStatusInspector) |
| `scripts/porep-market/up.sh` | SP org + tooling `.env` + V2 register/offer + DataCap to adapter |
| `scripts/tooling/patch.sh` | Reset tooling submodule + apply `patches/tooling/*.patch` |
| `scripts/tooling/init.sh` | Tooling patches + Python venv |
| `scripts/tooling/make-deal.sh` | V2 propose → accept → init → allocate → onboard → claim → add-url → wait allocations → `submit-evidence` → confirm claims |
| `scripts/oracle/patch.sh` | Reset oracle submodule + apply `patches/oracle/*.patch` |
| `scripts/oracle/up.sh` | Patches + `.env`/build + Postgres/Prisma + `npm run start` |
| `scripts/oracle/db-schema.sh` | `npm ci` (if needed) + `prisma generate` + `prisma db push` (used by `up.sh`) |
| `scripts/oracle/get-deals.sh` | `curl` `GET /deals` against the local oracle API |

Also: [`contracts/allocator/NoOpMetaAllocator.{sol,json}`](contracts/allocator/) (MetaAllocator stub so DataCapEvidenceAdapter can call `addVerifiedClient` on FEVM).

## Typical flow

1. `just init`
2. `just up`
3. Prepare a deal dataset (e.g. with Singularity — below), then `just make-deal`
4. Oracle is started by `just up` (`just oracle up`). Re-run `just oracle up` to refresh `.env` and restart.
5. Optional: test paid retrievals with [`large-paid-retrievals`](https://github.com/fidlabs/large-paid-retrievals) — see that project’s README

See each script’s header for flags and env overrides (`CURIO_DIR`, `POREP_MARKET_DIR`, `TOOLING_DIR`, `ENV_FILE`, `RPC_URL`, …).

## Singularity: prepare pieces and serve the manifest

[Singularity](https://github.com/data-preservation-programs/singularity) is an **independent** project (not a submodule of this repo). The steps below are one example of how a user might prepare a dataset and serve piece CARs + a deal `manifest.json` for `just make-deal`. Any other tooling that produces a compatible manifest and HTTP piece URLs works the same way.

[`just make-deal`](scripts/tooling/make-deal.sh) needs two HTTP services on the **host**:

| Port | Role | Who uses it |
|------|------|-------------|
| **8080** | `manifest.json` (deal metadata) | Tooling CLI (`propose-deal-from-manifest`, etc.) |
| **7777** | Piece CARs at `/piece/<pieceCid>` | `sp onboard-data` (aria2c) **and** Curio CommP via `http://host.docker.internal:7777/piece/...` |

Do **not** confuse this with Curio’s in-compose `piece-server` (`:12320`). That bootstraps Curio contracts; it does **not** serve your Singularity CARs.

Upstream docs: [Singularity data preparation](https://data-programs.gitbook.io/singularity/data-preparation/get-started), [distribute CAR files](https://data-programs.gitbook.io/singularity/content-distribution/distribute-car-files).

### Install Singularity

```bash
# Go 1.22+ recommended
go install github.com/data-preservation-programs/singularity@latest
# ensure $(go env GOPATH)/bin is on PATH
singularity version
```

### Working directory

Use a dedicated directory so `singularity.db` and CAR output stay together (example sibling layout used in this project):

```text
../singularity-root/          # CWD for all singularity commands below
  data/<your-dataset>/        # source files to pack
  cars/                       # exported .car pieces
  singularity.db
../manifest.json              # or any dir you will HTTP-serve on :8080
```

```bash
mkdir -p ../singularity-root/{data/sample,cars}
# put at least one non-empty file under data/sample/
cd ../singularity-root
```

### 1. Initialize DB and create a preparation

```bash
singularity admin init

# Convenient one-shot: creates local source + output storages and a named prep.
# Defaults pack toward ~32 GiB pieces; for a tiny local sample, shrink max/piece size:
singularity prep create \
  --name sample-prep \
  --local-source "$(pwd)/data/sample" \
  --local-output "$(pwd)/cars" \
  --max-size 4MiB \
  --piece-size 4MiB \
  --min-piece-size 1MiB
```

Equivalent explicit storage steps:

```bash
singularity storage create local --name sample-src --path "$(pwd)/data/sample"
singularity storage create local --name sample-out --path "$(pwd)/cars"
singularity prep create --name sample-prep --source sample-src --output sample-out \
  --max-size 4MiB --piece-size 4MiB --min-piece-size 1MiB
```

Leave DAG generation enabled (default). PoRep tooling requires **exactly one `dag` piece and ≥1 `data` piece** in the manifest.

### 2. Scan, pack, and generate the DAG piece

```bash
# Source name: use the one from `singularity storage list` (explicit creates use
# sample-src; --local-source may auto-name the storage from the path).
singularity prep start-scan sample-prep sample-src
singularity run dataset-worker    # leave running until pack + dag jobs finish

# In another terminal (same CWD / same singularity.db):
singularity prep status sample-prep
singularity prep list-pieces sample-prep

# If list-pieces shows only data pieces, start DAG generation:
singularity prep start-daggen sample-prep
# ensure dataset-worker is still running, then re-check list-pieces
```

When ready you should see `.car` files under `cars/` named like `baga….car`, including both data and dag pieces.

### 3. Build `manifest.json`

`make-deal` / `propose-deal-from-manifest` expect a **one-element array** with this shape (field names are camelCase and validated strictly):

```json
[
  {
    "pieces": [
      {
        "pieceCid": "baga…",
        "pieceType": "data",
        "pieceSize": 4194304,
        "fileSize": 3059701,
        "preparationId": "1",
        "attachmentId": "1",
        "storagePath": "baga….car"
      },
      {
        "pieceCid": "baga…",
        "pieceType": "dag",
        "pieceSize": 1048576,
        "fileSize": 1040384,
        "preparationId": "1",
        "attachmentId": "1",
        "storagePath": "baga….car"
      }
    ]
  }
]
```

Rules enforced by the tooling:

- Exactly **one** `pieceType: "dag"` and at least one `"data"`
- All pieces share the same `preparationId` and `attachmentId` (string IDs from Singularity)
- Dag `pieceSize` ≥ **1 MiB**
- `storagePath` is the `.car` basename under the output storage (Singularity names these `<pieceCid>.car`)

Easiest path: copy CIDs / sizes from `singularity prep list-pieces sample-prep` into the template.

Or generate from `singularity.db` after prep (CAR filenames already contain the piece CID):

```bash
# run from singularity-root (directory that contains singularity.db)
python3 - <<'PY' > ../manifest.json
import json, sqlite3
conn = sqlite3.connect("singularity.db")
conn.row_factory = sqlite3.Row
rows = conn.execute(
    """
    SELECT piece_type, piece_size, file_size,
           preparation_id, attachment_id, storage_path
    FROM cars ORDER BY id
    """
).fetchall()
pieces = []
for r in rows:
    path = r["storage_path"]
    if not path.endswith(".car"):
        raise SystemExit(f"unexpected storage_path: {path}")
    pieces.append({
        "pieceCid": path[: -len(".car")],
        "pieceType": r["piece_type"],
        "pieceSize": int(r["piece_size"]),
        "fileSize": int(r["file_size"]),
        "preparationId": str(r["preparation_id"]),
        "attachmentId": str(r["attachment_id"]),
        "storagePath": path,
    })
types = [p["pieceType"] for p in pieces]
if types.count("dag") != 1 or "data" not in types:
    raise SystemExit(f"expected ≥1 data + exactly 1 dag, got {types}")
print(json.dumps([{"pieces": pieces}], indent=2))
print(f"wrote {len(pieces)} pieces", file=__import__("sys").stderr)
PY
```

Place the finished file where you will serve it (e.g. parent dir as `../manifest.json`).

### 4. Serve piece CARs (port 7777)

Keep using the same CWD / `singularity.db` that knows about the prep and output storage:

```bash
cd ../singularity-root
# Bind all interfaces so Curio containers can reach the host via host.docker.internal
singularity run content-provider --http-bind 0.0.0.0:7777
```

Smoke-check (use a real `pieceCid` from the manifest):

```bash
curl -sI "http://127.0.0.1:7777/piece/<pieceCid>" | head
# Expect HTTP 200 and Content-Length matching fileSize / CAR size
```

`make-deal` defaults `--piece-base-url` to `http://host.docker.internal:7777/piece` so the Curio container can download the same CARs for CommP. Leave this process running for the whole deal + sealing path.

### 5. Serve `manifest.json` (port 8080)

In another terminal, HTTP-serve the directory that contains `manifest.json` (filename must match the URL path):

```bash
# if manifest.json lives next to FCSS-devnet / singularity-root parent:

cd /path/to/0110-Filecoin-Retrievals-Private-Datasets
python3 -m http.server 8080 --bind 127.0.0.1
```

```bash
curl -sf http://127.0.0.1:8080/manifest.json | jq '.[0].pieces | length'
```

`just make-deal` / `scripts/tooling/make-deal.sh` sets `ALLOW_PRIVATE_MANIFEST_URLS=true` so the tooling CLI accepts loopback/private manifest URLs.

### 6. Run the deal

With Curio already up (`just up`) and both servers running:

```bash
cd FCSS-devnet   # or your local clone directory
just make-deal
# or: just make-deal --manifest-url http://127.0.0.1:8080/manifest.json
# resume: just make-deal --deal-id 1
# stop after Curio add-url (skip sealing wait / submit-evidence):
just make-deal --deal-id 1 --no-wait-claims
```

Pass flags directly to the script, e.g. `just make-deal --deal-id 1`. Optional overrides: `MANIFEST_URL`, `PIECE_BASE_URL`, `--deal-id`, `--no-wait-claims`, `--skip-onboard` (see `scripts/tooling/make-deal.sh --help`).

**Claims vs allocations:** Curio sealing creates VerifReg claims (same numeric IDs as the allocations). `sp get-claims` only shows IDs already stored on the `DataCapEvidenceAdapter` (`getClaimIds`). `make-deal` waits for Lotus allocations to clear, runs `admin submit-evidence`, then confirms claims via `sp get-claims`.

```bash
# default path (also used on resume):
just make-deal --deal-id 1
# manual equivalent after Curio has claimed on VerifReg:
cd extern/filecoin-porep-market-tooling
python porep_tooling_cli.py admin submit-evidence 1 --wait
python porep_tooling_cli.py sp get-claims 1
```

`admin submit-evidence` needs `ADMIN_PRIVATE_KEY` (deployer / `DEFAULT_ADMIN_ROLE` or `POREP_SERVICE_ROLE`).

### Checklist when CommP / onboard fails

- `curl` manifest on **:8080** and a piece on **:7777** from the host
- From inside Curio: `docker exec curio wget -S -O /dev/null http://host.docker.internal:7777/piece/<cid>`
- Content-provider was started with the **same** `singularity.db` / `cars/` used to build the manifest
- Manifest has one `dag` + ≥1 `data`, shared `preparationId` / `attachmentId`

## Prerequisites

- Docker
- `cast`, `jq`, `curl`; `just` + `forge` (Foundry) for V2 contract deploy
- `npm` (Node.js 24+) for `just oracle up` and running filecoin-oracle-service
- Recursive git submodules (`just init`) so porep-market forge libs exist under `extern/porep-market/lib/`
- `aria2c` for `make-deal` onboard-data
- Singularity CLI (`go install github.com/data-preservation-programs/singularity@latest`) for piece prep + content-provider
- Tooling venv via `just init` (or `just tooling init`)
