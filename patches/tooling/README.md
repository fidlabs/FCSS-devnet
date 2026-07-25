# Tooling patches

Unified diffs applied by [`scripts/tooling/patch.sh`](../../scripts/tooling/patch.sh) (via `just tooling patch` / `just tooling init` / `just init`) onto the pinned [`extern/filecoin-porep-market-tooling`](../../extern/filecoin-porep-market-tooling) submodule (`feature-v2-adjust-contracts`) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-ethaddress-zero-idempotent.patch` | `EthAddress` idempotent / zero-address handling (avoids falsy `0x0…0` breakage in `__post_init__`) |
| `0002-v2-deal-view-compose-from-getters.patch` | Compose `get_deal_view` from market getters + ABI without on-market `getDealView` (ViewHelper-only on this stack); V2 deal/`payee`/`proposedAtEpoch` shape |
| `0003-admin-submit-evidence.patch` | `admin submit-evidence` CLI for `PoRepMarket.submitEvidenceBatch` (`abi.encode(uint256 batchSize)`, optional `--wait`) |

**TODO (push upstream):** open PRs on tooling `feature-v2-adjust-contracts` (or successor) and drop these patches once merged. Devnet orchestration (wait allocations → submit-evidence → confirm claims) lives in [`scripts/tooling/make-deal.sh`](../../scripts/tooling/make-deal.sh) (FCSS-devnet), not in the tooling submodule.
