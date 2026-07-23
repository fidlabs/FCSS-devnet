# filecoin-porep-market-tooling patches

Unified diffs applied by [`scripts/tooling/init.sh`](../../scripts/tooling/init.sh) (via `just tooling init` / `just init`) onto the pinned [`extern/filecoin-porep-market-tooling`](../../extern/filecoin-porep-market-tooling) submodule (**v1**) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-allow-private-manifest-urls.patch` | Allow loopback/private manifest URLs (local Singularity / piece server) |

Needed for `scripts/tooling/make-deal.sh` against a local `http://127.0.0.1:...` manifest; upstream `validate_and_parse_url` rejects those IPs.
