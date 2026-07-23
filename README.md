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
just up      # compose up + Curio config + porep deploy + SP wiring
# prepare + serve Singularity pieces/manifest (see below), then:
just make-deal
```

`just init` runs `git submodule update --init --recursive`, then `just curio init` and `just tooling init`. Set `SKIP_DOCKER=1` to skip the Curio image build; `SKIP_VENV=1` to skip the tooling venv.

## Just recipes

Root recipes compose submodule modules ([`just/`](just/)):

| Recipe | Does |
|--------|------|
| `just init` | submodule update → `curio init` → `tooling init` |
| `just up` | `curio up` → `porep-market deploy` → `porep-market up` |
| `just logs` / `just down` | Curio compose logs / tear down |
| `just make-deal` | tooling venv + deal pipeline |

Namespaced (same scripts):

- `just curio init|up|cli|logs|down`
- `just porep-market gen-env|deploy|up`
- `just tooling init|make-deal`
- `just retrieval keys|fund`

## Scripts

Shared helpers live in [`scripts/lib/`](scripts/lib/) (`common.sh`, `envfile.sh`, `lotus.sh`). Task scripts are under the submodule they touch:

| Script | Purpose |
|--------|---------|
| `scripts/curio/init.sh` | Curio patches, `local-src`, `make docker/devnet` |
| `scripts/curio/up.sh` | Post-bootstrap Curio config (SSRF, IPNI, WinningPoSt, control, escrow) |
| `scripts/curio/cli.sh` | `CURIO_PATH` wrapper: `curio` inside the compose service |
| `scripts/porep-market/gen-env.sh` | Write porep-market `.env` from Curio contract artifacts |
| `scripts/porep-market/deploy.sh` | NoOp MetaAllocator + `just devnet_deploy` |
| `scripts/porep-market/up.sh` | SP org + tooling `.env` + register miner + DataCap |
| `scripts/tooling/init.sh` | Tooling patches + Python venv |
| `scripts/tooling/make-deal.sh` | Propose → accept → allocate → onboard → claim → add-url |
| `scripts/retrieval/keys.sh` | Copy CLIENT/SP keys from tooling `.env` for retrieval tooling |
| `scripts/retrieval/fund.sh` | Fund retrieval wallets with FIL + USDFC after a chain reset |
| `scripts/retrieval/env.sh` | `source` to export `PAYMENTS` / `USDFC` / `POREP_MARKET` / piece CID for sp-proxy |

Also: [`contracts/allocator/NoOpMetaAllocator.{sol,json}`](contracts/allocator/) (MetaAllocator stub for local Client DataCap transfer).

## Typical flow

1. `just init`
2. `just up`
3. Prepare pieces + serve Singularity (below), then `just make-deal`
4. Paid retrievals: `just retrieval keys`, `just retrieval fund`, then `source ./scripts/retrieval/env.sh` and run `sp-proxy` / `retrieval-client`

See each script’s header for flags and env overrides (`CURIO_DIR`, `POREP_MARKET_DIR`, `TOOLING_DIR`, `ENV_FILE`, `RPC_URL`, …).

## Singularity: prepare pieces and serve the manifest

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
# if manifest.json lives next to porep-curio-devnet / singularity-root parent:
cd /path/to/0110-Filecoin-Retrievals-Private-Datasets
python3 -m http.server 8080 --bind 127.0.0.1
```

```bash
curl -sf http://127.0.0.1:8080/manifest.json | jq '.[0].pieces | length'
```

Tooling is patched in this repo to allow loopback/private manifest URLs (`patches/filecoin-porep-market-tooling/`); that lands via `just tooling init`.

### 6. Run the deal

With Curio already up (`just up`) and both servers running:

```bash
cd porep-curio-devnet
just make-deal
# or: just make-deal --manifest-url http://127.0.0.1:8080/manifest.json
```

Optional overrides: `MANIFEST_URL`, `PIECE_BASE_URL`, `--deal-id`, `--wait-claims` (see `scripts/tooling/make-deal.sh --help`).

### Checklist when CommP / onboard fails

- `curl` manifest on **:8080** and a piece on **:7777** from the host
- From inside Curio: `docker exec curio wget -S -O /dev/null http://host.docker.internal:7777/piece/<cid>`
- Content-provider was started with the **same** `singularity.db` / `cars/` used to build the manifest
- Manifest has one `dag` + ≥1 `data`, shared `preparationId` / `attachmentId`

## Prerequisites

- Docker
- `cast`, `jq`, `curl`; `just` + `forge` for contract deploy
- `aria2c` for `make-deal` onboard-data
- Singularity CLI (`go install github.com/data-preservation-programs/singularity@latest`) for piece prep + content-provider
- Tooling venv via `just init` (or `just tooling init`)
