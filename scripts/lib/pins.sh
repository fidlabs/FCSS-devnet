# Pin lock helpers. Sourced after common.sh.
# Compatible with macOS /bin/bash 3.2.

: "${VERSIONS_LOCK:=${REPO_ROOT}/versions.lock.yaml}"

# Print lock field for a submodule key: path|repository|commit|ref
# Usage: pin_lock_field curio commit
pin_lock_field() {
  local key="$1" field="$2"
  require_file "$VERSIONS_LOCK"
  require_cmd python3
  python3 - "$VERSIONS_LOCK" "$key" "$field" <<'PY'
import sys
path, key, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

text = open(path, encoding="utf-8").read()
data = None
if yaml is not None:
    data = yaml.safe_load(text)
else:
    # Minimal YAML subset parser for our lockfile shape (no PyYAML required).
    data = {"submodules": {}}
    cur = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":"):
            cur = line.strip()[:-1]
            data["submodules"][cur] = {}
            continue
        if cur and line.startswith("    ") and ":" in line:
            k, _, v = line.strip().partition(":")
            data["submodules"][cur][k.strip()] = v.strip()

sub = (data or {}).get("submodules", {}).get(key)
if not sub or field not in sub:
    sys.stderr.write(f"lock missing submodules.{key}.{field}\n")
    sys.exit(2)
print(sub[field])
PY
}

pin_lock_keys() {
  require_file "$VERSIONS_LOCK"
  require_cmd python3
  python3 - "$VERSIONS_LOCK" <<'PY'
import sys
path = sys.argv[1]
try:
    import yaml
    data = yaml.safe_load(open(path, encoding="utf-8"))
    for k in data.get("submodules", {}):
        print(k)
except ImportError:
    cur = None
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].rstrip()
        if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":"):
            print(line.strip()[:-1])
PY
}
