# Oracle patches

Unified diffs applied by [`scripts/oracle/patch.sh`](../../scripts/oracle/patch.sh) (via `just oracle patch` / `just oracle up` / `just init`) onto the pinned [`extern/filecoin-oracle-service`](../../extern/filecoin-oracle-service) submodule (`v2`) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-settlement-history-local-chain-genesis.patch` | Settlement-history sync: resolve genesis via `Filecoin.ChainGetGenesis` for Curio local `CHAIN_ID=31415926` (no Calibration/Mainnet hardcode) |
| `0002-enable-cron-schedules.patch` | Re-enable `cron.schedule` job wiring in `src/index.ts` (imports + schedules; end-epoch → `finalizeDealJob`; includes reject-expired) |
| `0003-getDealViews-use-view-helper.patch` | Call `getDealViews` on `POREP_MARKET_VIEW_HELPER_CONTRACT_ADDRESS` (not the market proxy) |
| `0004-v2-view-helper-abi.patch` | V2 ViewHelper ABI + deal-sync mapping (`proposedAtEpoch` on deal; no `timing` tuple) |
| `0005-skip-claim-inspector-when-unset.patch` | Skip ClaimInspector / claim fetch when `CLAIM_INSPECTOR_CONTRACT_ADDRESS` is unset |

Refreshed against `v2` @ `d30df23` (sync-deal-job rewrite + cron comment drift). Upstream PRs: [#30](https://github.com/fidlabs/filecoin-oracle-service/pull/30)–[#33](https://github.com/fidlabs/filecoin-oracle-service/pull/33).

Env / Postgres / app wiring for the local stack lives in [`scripts/oracle/up.sh`](../../scripts/oracle/up.sh), not as oracle-tree patches. ViewHelper / ClaimInspector are deployed by [`scripts/porep-market/deploy.sh`](../../scripts/porep-market/deploy.sh).

**TODO (push upstream):** drop these patches once the corresponding PRs merge.
