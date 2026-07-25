# Oracle patches

Unified diffs applied by [`scripts/oracle/patch.sh`](../../scripts/oracle/patch.sh) (via `just oracle patch` / `just oracle init` / `just init`) onto the pinned [`extern/filecoin-oracle-service`](../../extern/filecoin-oracle-service) submodule (`v2`) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-settlement-history-local-chain-genesis.patch` | Settlement-history sync: resolve genesis via `Filecoin.ChainGetGenesis` for Curio local `CHAIN_ID=31415926` (no Calibration/Mainnet hardcode) |
| `0002-enable-cron-schedules.patch` | Re-enable `cron.schedule` job wiring in `src/index.ts` (imports + schedules; end-epoch → `finalizeDealJob`) |
| `0003-getDealViews-use-view-helper.patch` | Call `getDealViews` on `POREP_MARKET_VIEW_HELPER_CONTRACT_ADDRESS` (not the market proxy) |
| `0004-v2-view-helper-abi.patch` | V2 ViewHelper ABI + deal-sync mapping (`proposedAtEpoch` on deal; no `timing` tuple) |
| `0005-skip-claim-inspector-when-unset.patch` | Skip ClaimInspector / claim fetch when `CLAIM_INSPECTOR_CONTRACT_ADDRESS` is unset |

Env / Postgres wiring for the local stack lives in [`scripts/oracle/init.sh`](../../scripts/oracle/init.sh) and compose helpers, not as oracle-tree patches. ViewHelper / ClaimInspector are deployed by [`scripts/porep-market/deploy.sh`](../../scripts/porep-market/deploy.sh).

**TODO (push upstream):** open PRs on oracle `v2` and drop these patches once merged.
