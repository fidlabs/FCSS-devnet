# CDP patches for Curio / FCSS local FEVM

Unified diffs applied by [`scripts/cdp/patch.sh`](../../scripts/cdp/patch.sh) (via `just cdp up` / `just init`) onto the pinned [`extern/compliance-data-platform`](../../extern/compliance-data-platform) submodule (`main`).

Stock CDP targets **mainnet (314)** and **calibnet (314159)**, indexes from a calibnet origin block, assumes TLS Postgres, binds Nest to port 3000, and runs PoRep/Pay indexers hourly. FCSS runs a short-lived Curio FEVM (`31415926`) with local compose Postgres and needs deals visible quickly for oracle/tooling. Drop each patch once upstream covers that gap.

| Patch | Purpose |
|-------|---------|
| `0001-support-curio-local-chain-id.patch` | Add viem chain `31415926` to PoRep supported chains |
| `0002-index-from-genesis-local.patch` | PoRep + FilecoinPay indexers start at block `0` |
| `0003-listen-port-from-env.patch` | Nest listens on `PORT` (default 3000) for FCSS host map |
| `0004-disable-ssl-for-local-postgres.patch` | Kysely/pg pool: no SSL unless `NODE_ENV=production` (local compose has no TLS) |
| `0005-v2-deal-created-finalized-events.patch` | PoRep Market V2: `DealCreated`/`DealFinalized` ABI + indexer; terms via `getDealTerms`/`getDealPayment` |
| `0006-index-on-startup-every-5-minutes.patch` | Run PoRep/Pay indexers on boot and every 5 minutes (stock is hourly only) |
| `0007-expose-deal-type-on-po-rep-deals.patch` | Persist on-chain `dealType` (`getDeal`) and return it on `GET /po-rep/deals` (`PUBLIC`/`PRIVATE`) |

## Justifications

### `0001` — Curio local chain id

CDP refuses unknown `PO_REP_CHAIN_ID` values. Without registering `31415926`, Nest never starts against Curio.

`defineChain` hardcodes `http://127.0.0.1:2234/rpc/v1` only as a **viem** (EVM client library) fallback. Live transport uses `PO_REP_RECENT_RPC_URL` / `PO_REP_ARCHIVE_RPC_URL` from [`scripts/cdp/up.sh`](../../scripts/cdp/up.sh) (`RPC_URL` / [`ports.sh`](../../scripts/lib/ports.sh)). Do not pull `RPC_URL` into the chain constant — registering the chain id is what this patch must do.

### `0002` — Index from genesis

Stock origin (`5934198`) is a calibnet height where PoRep contracts were deployed. On a fresh Curio chain that block does not exist, so indexers would skip all local events. `0n` is correct for a private chain that starts empty.

### `0003` — `PORT` from env

Stock Nest always listens on `3000`. FCSS maps CDP HTTP to host **23300** (`FCSS_CDP_APP_HOST_PORT`) so it does not collide with other local services. `up.sh` sets `PORT`; this patch makes Nest honor it.

### `0004` — Disable SSL for local Postgres

Stock Kysely/`pg` always opens an SSL session. [`docker/cdp-compose.yaml`](../../docker/cdp-compose.yaml) Postgres has no TLS, so connections fail with SSL errors. Enable SSL only when `NODE_ENV=production`.

### `0005` — V2 deal events + terms getters

Stock ABI/indexer still expect V1 names (`DealProposalCreated` / `DealCompleted`) and pull terms from a V1-shaped `getDeals` blob. PoRep Market V2 emits `DealCreated` / `DealFinalized`, and terms/payment live behind `getDealTerms` / `getDealPayment`. Without this, CDP indexes nothing useful and `/po-rep/deals` stays empty after `just make-deal`. Also maps V2 bandwidth (bytes/s) → CDP’s Mbps column.

### `0006` — Index on boot + every 5 minutes

Stock runners only cron hourly. Local demos propose/accept deals and expect oracle/CDP to see them within minutes. `onModuleInit` runs one pass at startup; `EVERY_5_MINUTES` is a compromise (faster than hourly, not as chatty as every minute).

### `0007` — Expose `dealType` on `/po-rep/deals`

V2 stores `dealType` on-chain (`PUBLIC=10`, `PRIVATE=20`) but `DealCreated` does not emit it, and stock CDP has no column/API field. Indexer reads `getDeal`, persists `po_rep_deal.dealType`, and the deals list returns `PUBLIC` / `PRIVATE` (custom uint8 codes as decimal strings). Indexer version bump forces a full reindex after apply.

**TODO (push upstream):** local chain support, configurable origin, `PORT`, optional non-TLS DB, V2 events/`dealType`, and a configurable indexer cadence — then drop the matching patches here.
