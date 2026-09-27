# Tooling patches

Unified diffs applied by [`scripts/tooling/patch.sh`](../../scripts/tooling/patch.sh) (via `just tooling patch` / `just tooling init` / `just init`) onto the pinned [`extern/filecoin-porep-market-tooling`](../../extern/filecoin-porep-market-tooling) submodule (`master`) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-admin-submit-evidence.patch` | `admin submit-evidence` CLI for `PoRepMarket.submitEvidenceBatch` (`abi.encode(uint256 batchSize)`, optional `--wait`) via ViewHelper deal reads |
| `0002-v2-make-allocations-allow-claims.patch` | V2: claims while ACCEPTED are OK; do not fail `make-allocations` when VerifReg claims appear before posting finishes |
| `0003-lotus-devnet-actorid-t0-prefix.patch` | Curio/Lotus local chain `31415926` uses `t0` actor IDs (not `f0`) |

**Dropped (landed on tooling `master`):** deal-view composition / ViewHelper client, `proposeDeal` `dealType`, EthAddress zero-address handling, finish-DataCap-posting when all pieces already allocated.

**TODO (push upstream):** open PRs for `admin submit-evidence` and Lotus-devnet `t0` ActorId prefix (drop 0001/0003 once merged). Devnet orchestration lives in [`scripts/tooling/make-deal.sh`](../../scripts/tooling/make-deal.sh). Use `--deal-type public` / `DEAL_TYPE=public` when needed (`make-deal` defaults to private).
