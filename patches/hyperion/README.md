# Hyperion patches for Curio / FCSS local FEVM

Unified diffs applied by [`scripts/hyperion/patch.sh`](../../scripts/hyperion/patch.sh) (via `just hyperion up` / `just init`) onto the pinned [`extern/hyperion`](../../extern/hyperion) submodule (`main`).

Stock Hyperion targets **mainnet (314)** and **calibnet (314159)**, indexes from a calibnet origin block, binds Nest to port 3000, and runs PoRep/Pay indexers hourly (plus once on bootstrap). FCSS runs a short-lived Curio FEVM (`31415926`) and needs deals visible quickly for tooling. Drop each patch once upstream covers that gap.

| Patch | Why |
|-------|-----|
| `0001-curio-local-chain-and-genesis.patch` | Register chain `31415926` and set `PO_REP_ORIGIN_BLOCK = 0` |
| `0002-listen-port-from-env.patch` | Honor `PORT` (FCSS host **23300**) |
| `0003-index-every-5-minutes.patch` | Cron every 5 minutes (stock is hourly; bootstrap already runs once) |
| `0004-tolerate-missing-erc20-token-metadata.patch` | Avoid HTTP 500 on stale payment-token addresses after chain reset |
| `0005-fix-start-prod-entrypoint.patch` | `npm run start:prod` must run `dist/src/main.js` (Nest outDir), not `dist/main` |
| `0006-shorten-po-rep-http-cache-ttl.patch` | Cut `/po-rep/*` HTTP cache from 30m → 5s so empty pre-index responses do not stick |

V2 events (`DealCreated` / `DealFinalized`), piece-CID indexing, and non-TLS local Postgres are already upstream in Hyperion — no FCSS patches for those.
