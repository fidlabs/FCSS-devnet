# large-paid-retrievals helpers (sibling checkout; not a submodule yet)
set working-directory := ".."

keys *args:
    ./scripts/retrieval/keys.sh {{args}}

fund *args:
    ./scripts/retrieval/fund.sh {{args}}
