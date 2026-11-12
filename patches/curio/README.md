# Curio patches

Unified diffs applied by [`scripts/curio/init.sh`](../../scripts/curio/init.sh) (via `just curio init` / `just init`) onto the pinned [`extern/curio`](../../extern/curio) submodule (v1.28.6) after `git submodule update`.

| Patch | Purpose |
|-------|---------|
| `0001-docker-compose-host-docker-internal.patch` | `DEV_CURIO_EXTERNAL_URL` + `extra_hosts` so Curio/indexer can reach the host |
| `0002-ipni-summary-null-head.patch` | Tolerate null IPNI ad heads in the web UI summary query |
| `0003-dockerfile-skip-submodule-init.patch` | Nested-submodule docker build: skip in-image `git submodule update` |
| `0004-deps-mk-skip-submodule-init.patch` | Same for `make deps` (`build/.update-modules`) |
| `0005-fcss-host-ports.patch` | Publish Curio/Lotus/Yugabyte/indexer on FCSS host ports (`2234`, `22300`, `22310`, …) and set `DEV_CURIO_EXTERNAL_URL` to `:22310` |
| `0006-dockerfile-run-foundryup-as-binary.patch` | Run `foundryup` as a binary (Foundry installer no longer ships a sourceable script) |
| `0007-blst-without-supraseal-tree.patch` | BLST install: `mkdir -p` + clone under dockerignored `extern/supraseal` (no make prerequisite on that path) |
| `0008-golang-1.26.10-pin.patch` | **TEMPORARY** — pin Docker builders to `golang:1.26.10-trixie`. Go 1.26.11 CVE-2026-97038 rejects LTO/`.llvmbc` in `libfilcrypto.a`; CVE-2026-97039 rejects local `.pc` paths in `#cgo pkg-config`. **Remove when upstream filecoin-ffi/curio works on Go 1.26.11+.** |
| `0009-devnet-up-stop-before-wipe.patch` | `devnet/up`: `compose down` before `rm -rf ./docker/data` so bind mounts (yugabyte) release files; avoids macOS `Directory not empty` |

**Dropped:** `git describe` soft-fail — landed upstream as `CURIO_BUILD_COMMIT ?= … \|\| echo unknown` in `00-vars.mk`.

These patches are **environmental only** (nested-submodule docker build, host reachability, local UI edge cases). They are **not** suitable to push upstream to Curio.

Post-bootstrap Curio config lives in this repo as [`scripts/curio/up.sh`](../../scripts/curio/up.sh), not as a Curio-tree patch.
