# .env helpers. Requires common.sh (die). Uses ENV_FILE when file omitted.
# Compatible with macOS /bin/bash 3.2.

# Usage: env_get KEY [file]
# Prints value (quotes stripped, whitespace trimmed). Returns 1 if missing.
env_get() {
  local key="$1"
  local file="${2:-${ENV_FILE:-}}"
  local line val
  [[ -n "$file" ]] || die "env_get: ENV_FILE not set and no file given"
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  val="${line#*=}"
  if [[ "$val" =~ ^\".*\"$ ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" =~ ^\'.*\'$ ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s\n' "$(printf '%s' "$val" | tr -d ' \t\r\n')"
}

# Usage: set_env_key KEY VALUE
#    or: set_env_key FILE KEY VALUE
set_env_key() {
  local file key value
  if [[ $# -eq 3 ]]; then
    file="$1"
    key="$2"
    value="$3"
  elif [[ $# -eq 2 ]]; then
    file="${ENV_FILE:-}"
    key="$1"
    value="$2"
    [[ -n "$file" ]] || die "set_env_key: ENV_FILE not set"
  else
    die "set_env_key: need KEY VALUE or FILE KEY VALUE"
  fi
  case "$value" in
    *$'\n'*|*$'\r'*) die "refusing to write ${key}: value contains a newline" ;;
  esac
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
    rm -f "${file}.bak"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}
