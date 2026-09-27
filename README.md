# FCSS-devnet

**FCSS** = **Filecoin Cold Storage Service**. This repo ([`fidlabs/FCSS-devnet`](https://github.com/fidlabs/FCSS-devnet)) is a local **Curio docker-devnet** that runs **PoRep Market V2** deals and is suitable for testing [`fidlabs/large-paid-retrievals`](https://github.com/fidlabs/large-paid-retrievals).

PoRep Market **V2 only** (`extern/porep-market` on `main`): `Deploy.s.sol`, SPRegistry offers, `DataCapEvidenceAdapter`, V2 deal lifecycle. No V1 Client / `just devnet_deploy` flows.

Pinned tips (see [`versions.lock.yaml`](versions.lock.yaml)): **Curio v1.28.2**, **porep-market** `main`, **tooling** `feature-v2-adjust-contracts`, **Hyperion** [`hyperion`](https://github.com/fidlabs/hyperion) `main`.

## Prerequisites

- Docker
- `just`, `cast`, `jq`, `curl`, Foundry `forge`
- Node.js 24.11+ / `npm` (Hyperion)
- `aria2c` (`make-deal` onboard)
- Recursive git submodules (`just init` pulls forge libs under `extern/porep-market/lib/`)

## Quick start

```bash
git clone https://github.com/fidlabs/FCSS-devnet.git
cd FCSS-devnet

just init     # submodules, patches, Curio images, tooling venv, pin-verify
just up       # Curio + V2 deploy + SP wiring + Hyperion
just status   # Lotus / Curio / Hyperion / ACTIVE / pins

# prepare + serve a deal manifest/pieces (see Singularity below), then:
just make-deal
# or: just seed-deals   # 3 clients × (2 private + 1 public) via Docker Singularity
```

Skip steps when iterating: `SKIP_DOCKER=1`, `SKIP_VENV=1`, or `SKIP_PATCH=1` on init helpers.

## Lifecycle

| Command | Safe? | What it does |
|---------|-------|----------------|
| `just init` | Yes | Submodules → Curio/tooling/hyperion patches → `pin-verify` |
| `just up` | Yes | Bring stack up, deploy, wire SP, start Hyperion |
| `just status` | Yes | Probe RPC, Curio, Hyperion, `ACTIVE`, pins |
| `just down` | **Destructive** | Stop stack; wipe Curio data, Hyperion volumes, `.runtime/`, `.deployment/` |
| `just reset` | **Destructive** | `just down` + backup generated `.env` files → then `just up` |
| `just make-deal …` | Yes | V2 deal pipeline (flags passed through) |
| `just seed-deals …` | Yes | 3 clients × (2 private + 1 public), unique piece CIDs (Singularity) |

### `just down` vs `just reset`

**`just down`** ([`scripts/down.sh`](scripts/down.sh)):

- Stops seed-deals HTTP + Singularity content-provider container
- Hyperion: `docker compose down -v` (Postgres volume removed) and Nest pid
- Curio: upstream `make devnet/down` → `docker compose down --rmi=local` **and** `rm -rf ./docker/data`
- Deletes `.runtime/` (seed-deals, tooling onboard/logs, …) and `extern/porep-market/.deployment/`

**`just reset`** runs `just down`, moves generated `.env` aside (`.env.bak.<ts>`), then `just up`.

**Preserves** (neither down nor reset removes these by design)

- Generated `.env` files on `just down` only (reset backs them up)
- Submodule checkouts, local patches, `versions.lock.yaml`
- Docker images / proof params
- Immutable deploy records under `extern/porep-market/deployments/devnet/records/`

After `just down`, bring the chain back with `just up` (or `just curio up` + `just porep-market deploy` + …).

## Host endpoints

FCSS publishes **non-default host ports** so it can sit beside another Curio/Lotus stack. Defaults: [`scripts/lib/ports.sh`](scripts/lib/ports.sh). **Container-internal** ports (Lotus `1234`, Curio API `12300`, market `12310`, …) are unchanged.

| Service | Host |
|---------|------|
| **Curio UI** | [http://127.0.0.1:24701](http://127.0.0.1:24701) |
| Lotus RPC | `http://127.0.0.1:2234/rpc/v1` |
| Curio API | `http://127.0.0.1:22300` |
| Curio Market / HTTP | `http://127.0.0.1:22310` |
| piece-server (Curio bootstrap) | `http://127.0.0.1:22320` |
| Indexer | `23000`–`23003` |
| Yugabyte YSQL (host) | `25433` |
| Hyperion Postgres | `localhost:28037` |
| **Hyperion HTTP** | [http://127.0.0.1:23300](http://127.0.0.1:23300) (`/docs`, `/`) |

Override any `FCSS_*_HOST_PORT` / `FCSS_HOST` before sourcing scripts if needed.

## Hyperion

[`extern/hyperion`](extern/hyperion) ([fidlabs/hyperion](https://github.com/fidlabs/hyperion)) indexes PoRep Market + Filecoin Pay on the local Curio chain:

| Use | Hyperion endpoint |
|-----|-------------------|
| Indexed deals | `GET /po-rep/deals` |
| Settlement (`settledUpTo`) | `GET /filecoin-pay/rails/:railId` |

`just hyperion up` (also part of `just up`):

1. Applies [`patches/hyperion/`](patches/hyperion/) (Curio chain `31415926`, index from genesis, `PORT` env)
2. Writes `.env` from ACTIVE deploy (market / SPRegistry / FilecoinPay + Lotus RPC)
3. Starts Hyperion Postgres ([`docker/hyperion-compose.yaml`](docker/hyperion-compose.yaml))
4. Runs Prisma migrate, builds Nest
5. Starts Nest in the **background** (`.runtime/hyperion.pid`, logs `.runtime/hyperion.log`)

Full Fil+ health checks (ipinfo / Filscan) may fail locally; PoRep deal + rail APIs are what matter.

```bash
just hyperion up          # or: just hyperion up --foreground
just hyperion logs
just hyperion down
```

## Pins (`versions.lock.yaml`)

[`versions.lock.yaml`](versions.lock.yaml) is the source of truth for submodule commits that local patches must apply against.

```bash
just pin-verify   # also runs at the end of just init
```

Checks:

1. Each submodule `HEAD` matches the lock commit  
2. Parent gitlink matches the lock commit  
3. `patches/{curio,tooling,hyperion}/*.patch` apply cleanly on that commit  

**Bump pins:** update submodule gitlinks → refresh patches if needed → rewrite commits in the lockfile → `just pin-verify`.

## Deployment records

On a successful `just porep-market deploy` (or full `just up`):

1. Writes `extern/porep-market/deployments/devnet/records/deployment-<UTC>-<shortsha>/latest.json`
2. Points `…/deployments/devnet/ACTIVE` at that record name
3. Mirrors the same JSON to `…/deployments/devnet/latest.json` (backward compatible)

Consumers (`porep-market up`, `hyperion up`) prefer **ACTIVE → record**, then fall back to `latest.json`.

```bash
# Public exports only (no private keys) — useful for large-paid-retrievals, etc.
eval "$(just porep-market tooling-env)"

# Point ACTIVE at an older record (no chain change); then refresh envs
just porep-market use-deployment deployment-20260729T180000Z-b1c728e
just porep-market up --from-env
just hyperion up --force
```

## Diagnostics

Wait timeouts dump stack traces under **`.runtime/failures/<UTC>-<label>/`** (gitignored): compose `ps`, recent lotus/curio/hyperion logs, `Filecoin.ChainHead`, copies of `ACTIVE` / `latest.json` when present.

```bash
just status
ls .runtime/failures/
```

## PoRep Market V2

| Piece | In this stack |
|-------|----------------|
| Deploy | `forge script Deploy.s.sol` → `latest.json` + immutable `records/` |
| Market | `PoRepMarket` (UUPS); `proposeDeal` → accept → init rail |
| Registry | `SPRegistry` — register, payment token, offer (price defaults to `1`; `0` rejected) |
| Evidence | `DataCapEvidenceAdapter` → then `PoRepMarket.submitEvidenceBatch` |
| Tooling | propose → allocate → claim; `admin submit-evidence` |
| Deal states | `PROPOSED` → `ACCEPTED` → `ACTIVE` → `FINALIZED` |

Orchestration: [`scripts/porep-market/`](scripts/porep-market/) + [`scripts/tooling/make-deal.sh`](scripts/tooling/make-deal.sh). After a chain wipe with existing wallets: `just porep-market up --from-env`.

## Dependencies

| Dependency | Role |
|------------|------|
| [`curio`](extern/curio) (**v1.28.2**) | Lotus + Curio docker stack |
| [`porep-market`](extern/porep-market) (**main** / V2) | Market, SPRegistry, DataCapEvidenceAdapter |
| [`filecoin-porep-market-tooling`](extern/filecoin-porep-market-tooling) (`feature-v2-adjust-contracts`) | Client / SP / admin CLI |
| [`hyperion`](extern/hyperion) (`main`) | PoRep/Pay indexer + REST APIs |
| [`large-paid-retrievals`](https://github.com/fidlabs/large-paid-retrievals) | `sp-proxy` + `retrieval-client` against this devnet |

All four code deps are git submodules under [`extern/`](extern/).

## Just recipes

Root recipes ([`justfile`](justfile)) compose modules in [`just/`](just/):

| Recipe | Does |
|--------|------|
| `just init` | submodule update → curio/tooling/hyperion patches → `pin-verify` |
| `just pin-verify` | lockfile vs HEADs/gitlinks + patch `--check` |
| `just up` | curio up → deploy → SP up → Hyperion |
| `just status` | health probes + ACTIVE + pin-verify (warn) |
| `just down` | stop stack; wipe Curio data, DB volumes, `.runtime/`, `.deployment/` |
| `just reset` | `just down` + backup `.env` → `just up` |
| `just make-deal …` | tooling venv + deal pipeline |
| `just seed-deals …` | 3×(2 private + 1 public) unique-piece deals fixture |

Namespaced:

- `just curio init\|up\|cli\|logs\|down`
- `just porep-market gen-env\|deploy\|up\|tooling-env\|use-deployment`
- `just tooling patch\|init\|make-deal\|seed-deals`
- `just hyperion patch\|up\|logs\|down`

### Upstream patch TODO

- **Tooling** — [`patches/tooling/`](patches/tooling/): compose deal view, `submit-evidence`, `proposeDeal` `dealType`. Drop once merged.
- **Hyperion** — [`patches/hyperion/`](patches/hyperion/): Curio chain id `31415926`, genesis origin, `PORT` env. Drop once upstream supports local FEVM.
- **Curio** — [`patches/curio/`](patches/curio/) are **environmental only** (host ports, IPNI, docker build); not for upstream.

## Scripts

Shared libs: [`scripts/lib/`](scripts/lib/) (`common.sh`, `ports.sh`, `runtime.sh`, `deployment.sh`, `pins.sh`, `envfile.sh`, `lotus.sh`).

| Script | Purpose |
|--------|---------|
| `scripts/curio/init.sh` | Curio patches, `local-src`, `make docker/devnet` |
| `scripts/curio/up.sh` | Post-bootstrap Curio config (SSRF, IPNI, WinningPoSt, …) |
| `scripts/curio/cli.sh` | `curio` inside the compose service |
| `scripts/porep-market/gen-env.sh` | porep-market `.env` for `Deploy.s.sol` |
| `scripts/porep-market/deploy.sh` | V2 deploy + helpers → `records/` + `ACTIVE` |
| `scripts/porep-market/up.sh` | SP org, tooling `.env`, register/offer, DataCap |
| `scripts/porep-market/tooling-env.sh` | Public `export` lines from ACTIVE |
| `scripts/porep-market/use-deployment.sh` | Retarget `ACTIVE` + mirror `latest.json` |
| `scripts/pins/verify.sh` | Lock + patch checks |
| `scripts/status.sh` | Stack health |
| `scripts/reset.sh` | Destructive wipe → `just up` |
| `scripts/hyperion/patch.sh` / `up.sh` / `down.sh` | Hyperion patches + Postgres + Nest |
| `scripts/tooling/init.sh` / `patch.sh` / `make-deal.sh` | Tooling venv + V2 deal path |

Also: [`contracts/allocator/NoOpMetaAllocator.{sol,json}`](contracts/allocator/) (FEVM MetaAllocator stub for DataCap).

## Typical flow

1. `just init`
2. `just up`
3. `just status` — confirm Curio UI at [http://127.0.0.1:24701](http://127.0.0.1:24701), Hyperion at [http://127.0.0.1:23300/](http://127.0.0.1:23300/), and Lotus RPC
4. Prepare dataset + serve manifest/pieces → `just make-deal`
5. Optional: `eval "$(just porep-market tooling-env)"` and run [`large-paid-retrievals`](https://github.com/fidlabs/large-paid-retrievals)

Script headers document flags and overrides (`RPC_URL`, `CURIO_DIR`, `ENV_FILE`, …).

---

## Singularity: prepare pieces and serve the manifest

[Singularity](https://github.com/data-preservation-programs/singularity) is an **independent** project (not a submodule). The steps below are one way to produce a deal `manifest.json` and HTTP piece URLs for `just make-deal`. Any tool that yields a compatible manifest works the same way.

[`just make-deal`](scripts/tooling/make-deal.sh) needs two HTTP services on the **host**:

| Port | Role | Who uses it |
|------|------|-------------|
| **8080** | `manifest.json` | Tooling CLI |
| **7777** | Piece CARs at `/piece/<pieceCid>` | `sp onboard-data` and Curio CommP via `http://host.docker.internal:7777/piece/...` |

Do **not** confuse this with Curio’s in-compose piece-server (host **`:22320`**, container `:12320`). That bootstraps Curio contracts; it does **not** serve your Singularity CARs.

Upstream docs: [data preparation](https://data-programs.gitbook.io/singularity/data-preparation/get-started), [distribute CAR files](https://data-programs.gitbook.io/singularity/content-distribution/distribute-car-files).

### Install Singularity

```bash
# Go 1.22+ recommended
go install github.com/data-preservation-programs/singularity@latest
# ensure $(go env GOPATH)/bin is on PATH
singularity version
```

### Working directory

```text
../singularity-root/          # CWD for singularity commands below
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

# Tiny local sample: shrink max/piece size (defaults aim ~32 GiB pieces)
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
# Source name: from `singularity storage list` (explicit creates use sample-src)
singularity prep start-scan sample-prep sample-src
singularity run dataset-worker    # leave running until pack + dag jobs finish

# In another terminal (same CWD / same singularity.db):
singularity prep status sample-prep
singularity prep list-pieces sample-prep

# If list-pieces shows only data pieces:
singularity prep start-daggen sample-prep
# ensure dataset-worker is still running, then re-check list-pieces
```

When ready you should see `.car` files under `cars/` named like `baga….car`, including both data and dag pieces.

### 3. Build `manifest.json`

`make-deal` expects a **one-element array** with this shape:

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

Rules:

- Exactly **one** `pieceType: "dag"` and at least one `"data"`
- All pieces share the same `preparationId` and `attachmentId`
- Dag `pieceSize` ≥ **1 MiB**
- `storagePath` is the `.car` basename (Singularity: `<pieceCid>.car`)

Generate from `singularity.db` after prep:

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

### 4. Serve piece CARs (port 7777)

```bash
cd ../singularity-root
singularity run content-provider --http-bind 0.0.0.0:7777
```

```bash
curl -sI "http://127.0.0.1:7777/piece/<pieceCid>" | head
```

`make-deal` defaults `--piece-base-url` to `http://host.docker.internal:7777/piece`. Leave this process running for deal + sealing.

### 5. Serve `manifest.json` (port 8080)

```bash
cd /path/to/directory-containing-manifest.json
python3 -m http.server 8080 --bind 127.0.0.1
curl -sf http://127.0.0.1:8080/manifest.json | jq '.[0].pieces | length'
```

`just make-deal` sets `ALLOW_PRIVATE_MANIFEST_URLS=true` so loopback/private manifest URLs are accepted.

### 6. Run the deal

With Curio already up (`just up`) and both servers running:

```bash
cd FCSS-devnet
just make-deal
# just make-deal --manifest-url http://127.0.0.1:8080/manifest.json
# just make-deal --deal-id 1
# just make-deal --deal-id 1 --no-wait-claims
```

Onboard CARs/manifests land in `.runtime/tooling/deal-<id>/`; CLI tx logs in `.runtime/tooling/logs/` (wiped by `just down`).

### Seed many deals (3 clients × 2 private + 1 public)

For Hyperion fixtures with **distinct owners**, **both deal types**, and **unique `pieceCid`s** per deal:

```bash
just seed-deals
# just seed-deals --prep-only    # only Singularity (Docker) + HTTP servers
# just seed-deals --deals-only   # reuse .runtime/seed-deals manifests
```

[`scripts/tooling/seed-deals.sh`](scripts/tooling/seed-deals.sh) will:

1. Reuse tooling `CLIENT_*` as **C1**, create **C2/C3** via `cast wallet new` (cached in `.runtime/seed-deals/clients.json`)
2. Fund FIL + USDFC for each client
3. Prep **nine** tiny datasets (per client: `private`, `private:2`, `public`) with **Singularity in Docker** → manifests under `.runtime/seed-deals/http/seed/<slot>/manifest.json`
4. Serve manifests on **:18080** (python) and CARs on **:17777** (Singularity content-provider container `fcss-seed-singularity-cp`)
5. Run the full `make-deal` pipeline nine times, then restore `CLIENT_*` to USER_1

No host `singularity` binary is required — only Docker. Override image with `SINGULARITY_IMAGE=…`.

This is **slow** (nine sealing/evidence waits). Escape hatch: `--manifests-file` with `{client,dealType,manifestUrl}` objects if you already have unique manifests.

Afterward, Hyperion `GET /po-rep/deals?pieceCid=<cid>` should return a single deal.

**Claims vs allocations:** Curio sealing creates VerifReg claims (same numeric IDs as allocations). `sp get-claims` only shows IDs already on the `DataCapEvidenceAdapter`. `make-deal` waits for Lotus allocations to clear, runs `admin submit-evidence`, then confirms via `sp get-claims`.

```bash
just make-deal --deal-id 1
# manual:
cd extern/filecoin-porep-market-tooling
python porep_tooling_cli.py admin submit-evidence 1 --wait
python porep_tooling_cli.py sp get-claims 1
```

`admin submit-evidence` needs `ADMIN_PRIVATE_KEY` (deployer / `DEFAULT_ADMIN_ROLE` or `POREP_SERVICE_ROLE`).

### Checklist when CommP / onboard fails

- `curl` manifest on **:8080** and a piece on **:7777** from the host
- From inside Curio: `docker exec curio wget -S -O /dev/null http://host.docker.internal:7777/piece/<cid>`
- Content-provider uses the **same** `singularity.db` / `cars/` as the manifest
- Manifest has one `dag` + ≥1 `data`, shared `preparationId` / `attachmentId`
