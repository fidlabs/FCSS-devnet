# Tooling patches

Unified diffs applied by [`scripts/tooling/patch.sh`](../../scripts/tooling/patch.sh) (via `just tooling patch` / `just tooling init` / `just init`) onto the pinned [`extern/filecoin-porep-market-tooling`](../../extern/filecoin-porep-market-tooling) submodule (`feature-v2-adjust-contracts`) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-v2-deal-view-compose-from-getters.patch` | Compose `get_deal_view` from market getters + ABI without on-market `getDealView` (ViewHelper-only on this stack); V2 deal/`payee`/`proposedAtEpoch` shape |
| `0002-admin-submit-evidence.patch` | `admin submit-evidence` CLI for `PoRepMarket.submitEvidenceBatch` (`abi.encode(uint256 batchSize)`, optional `--wait`) |
| `0003-propose-deal-type.patch` | PoRepMarket `#120` `dealType`: ABI + request/deal models, `proposeDeal` encoding, CLI `--deal-type private\|public` (default **private**=20) |

**Dropped:** EthAddress zero-address handling — landed upstream as `aa26374`.

**TODO (push upstream):** open PRs on tooling `feature-v2-adjust-contracts` (or successor) and drop these patches once merged. Devnet orchestration lives in [`scripts/tooling/make-deal.sh`](../../scripts/tooling/make-deal.sh). Use `--deal-type public` / `DEAL_TYPE=public` when needed (`make-deal` defaults to private).
