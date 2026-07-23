# Curio patches

Unified diffs applied by [`scripts/curio/init.sh`](../../scripts/curio/init.sh) (via `just curio init` / `just init`) onto the pinned [`extern/curio`](../../extern/curio) submodule (v1.28.2) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-docker-compose-host-docker-internal.patch` | `DEV_CURIO_EXTERNAL_URL` + `extra_hosts` so Curio/indexer can reach the host |
| `0002-ipni-summary-null-head.patch` | Tolerate null IPNI ad heads in the web UI summary query |
| `0003-dockerfile-skip-submodule-init.patch` | Nested-submodule docker build: skip in-image `git submodule update` |
| `0004-deps-mk-skip-submodule-init.patch` | Same for `make deps` (`build/.update-modules`) |
| `0005-build-mk-git-describe-fallback.patch` | Soft-fail `git log` for `CurrentCommit` when nested `.git` is invalid in-image |

Post-bootstrap Curio config lives in this repo as [`scripts/curio/up.sh`](../../scripts/curio/up.sh), not as a Curio-tree patch.
