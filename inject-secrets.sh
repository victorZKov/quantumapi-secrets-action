#!/usr/bin/env bash
# QuantumAPI Secrets — GitHub Action entrypoint
#
# Reads QAPI_SECRET_PATHS (newline-separated VAR=secret/name pairs), fetches
# each value via the QuantumVault API, registers it as a GitHub Actions mask
# (so it never appears in logs), and (by default) exports it via $GITHUB_ENV.
#
# Optional features:
#   - QAPI_SECRETS_FILE: write KEY=value lines to this path (mode 0600).
#   - QAPI_CACHE=true:   memoize results in $GITHUB_STATE for the lifetime of
#                        the job. A second invocation with the same set of
#                        paths short-circuits.

set -euo pipefail

: "${QAPI_API_KEY:?QAPI_API_KEY is required (the action input 'api-key')}"
: "${QAPI_SECRET_PATHS:?QAPI_SECRET_PATHS is required (the action input 'secret-paths')}"
QAPI_ENDPOINT="${QAPI_ENDPOINT:-https://api.quantumapi.eu}"
QAPI_ENDPOINT="${QAPI_ENDPOINT%/}"
QAPI_EXPORT_ENV="${QAPI_EXPORT_ENV:-true}"
QAPI_SECRETS_FILE="${QAPI_SECRETS_FILE:-}"
QAPI_CACHE="${QAPI_CACHE:-false}"

# Mask the API key itself defensively, in case it ever ends up in logs.
echo "::add-mask::${QAPI_API_KEY}"

if ! command -v curl >/dev/null 2>&1; then
  echo "::error::curl is required but not found in PATH"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required but not found in PATH (it's preinstalled on ubuntu-latest, macos-latest, windows-latest runners)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse + validate the secret-paths input. We collect (var,path) pairs into
# parallel arrays so we can compute the cache key BEFORE making any HTTP call.
# ---------------------------------------------------------------------------
vars=()
paths=()

while IFS= read -r raw_line; do
  line="$(printf '%s' "$raw_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  case "$line" in '#'*) continue ;; esac

  if [[ "$line" != *"="* ]]; then
    echo "::error::Invalid secret-paths line (expected VAR=secret/name): $line"
    exit 1
  fi
  var="${line%%=*}"
  path="${line#*=}"

  if [ -z "$var" ] || [ -z "$path" ]; then
    echo "::error::Invalid secret-paths line (empty var or path): $line"
    exit 1
  fi

  if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "::error::Invalid environment variable name: $var"
    exit 1
  fi

  vars+=("$var")
  paths+=("$path")
done <<<"${QAPI_SECRET_PATHS}"

# ---------------------------------------------------------------------------
# Cache key: sorted concatenation of "VAR=path" lines. Job-scoped via
# $GITHUB_STATE (saved with `core.saveState` semantics: env-file form).
# ---------------------------------------------------------------------------
cache_hit="false"
cache_key=""
if [ "$QAPI_CACHE" = "true" ] && [ "${#vars[@]}" -gt 0 ]; then
  cache_lines=""
  for i in "${!vars[@]}"; do
    cache_lines+="${vars[$i]}=${paths[$i]}"$'\n'
  done
  # sha256 of sorted lines
  if command -v sha256sum >/dev/null 2>&1; then
    cache_key="$(printf '%s' "$cache_lines" | sort | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    cache_key="$(printf '%s' "$cache_lines" | sort | shasum -a 256 | awk '{print $1}')"
  else
    # Fallback: not cryptographically strong, but cache key only needs uniqueness.
    cache_key="$(printf '%s' "$cache_lines" | sort | cksum | awk '{print $1"-"$2}')"
  fi
  state_var="QAPI_CACHE_${cache_key}"
  if [ -n "${!state_var:-}" ]; then
    cache_hit="true"
    echo "[QuantumAPI] cache hit for key ${cache_key} — reusing previously fetched values"
  fi
fi

injected=""

if [ "$cache_hit" = "true" ]; then
  # Replay the previously injected variable names so the `injected-vars`
  # output stays consistent across invocations. Values are already in the
  # job environment from the prior run.
  for v in "${vars[@]}"; do
    if [ -n "$injected" ]; then
      injected="${injected},${v}"
    else
      injected="${v}"
    fi
  done
else
  # ---------------------------------------------------------------------------
  # Fetch each secret. We collect KEY=value pairs for the optional secrets-file
  # write so we can chmod 0600 atomically at the end.
  # ---------------------------------------------------------------------------
  file_lines=""

  for i in "${!vars[@]}"; do
    var="${vars[$i]}"
    path="${paths[$i]}"

    enc_path="${path// /%20}"
    url="${QAPI_ENDPOINT}/api/v1/secrets/by-name/${enc_path}?includeValue=true"

    http_code="$(curl -sS -o /tmp/qapi_resp.json -w '%{http_code}' \
                    -H "X-Api-Key: ${QAPI_API_KEY}" \
                    -H 'Accept: application/json' \
                    "$url" || echo "000")"

    if [ "$http_code" != "200" ]; then
      echo "::error::Failed to fetch secret '$path' (HTTP $http_code)"
      exit 1
    fi

    value="$(jq -r '.value // empty' /tmp/qapi_resp.json)"
    if [ -z "$value" ]; then
      echo "::error::Secret '$path' returned empty value (insufficient scope or missing secret?)"
      exit 1
    fi

    echo "::add-mask::${value}"

    if [ "${QAPI_EXPORT_ENV}" = "true" ]; then
      delim="QAPI_DELIM_$(date +%s%N)_RANDOM_$$"
      {
        printf '%s<<%s\n' "$var" "$delim"
        printf '%s\n' "$value"
        printf '%s\n' "$delim"
      } >> "$GITHUB_ENV"
    fi

    if [ -n "$QAPI_SECRETS_FILE" ]; then
      # Buffer KEY=value lines; we write+chmod once at the end so the file is
      # never world-readable in the window between create and chmod.
      file_lines+="${var}=${value}"$'\n'
    fi

    if [ -n "$injected" ]; then
      injected="${injected},${var}"
    else
      injected="${var}"
    fi

    echo "[QuantumAPI] injected ${var} from ${path} ([MASKED])"
  done

  rm -f /tmp/qapi_resp.json

  # Write the secrets file with restrictive permissions.
  if [ -n "$QAPI_SECRETS_FILE" ]; then
    # Create with mode 0600 atomically: install --mode is portable on Linux,
    # but mac/Git Bash may lack it — use umask + tempfile + mv as a fallback.
    parent_dir="$(dirname -- "$QAPI_SECRETS_FILE")"
    if [ -n "$parent_dir" ] && [ ! -d "$parent_dir" ]; then
      mkdir -p -- "$parent_dir"
    fi
    tmp_file="$(mktemp "${parent_dir:-/tmp}/qapi_secrets_file.XXXXXX")"
    chmod 600 "$tmp_file"
    printf '%s' "$file_lines" > "$tmp_file"
    mv -f "$tmp_file" "$QAPI_SECRETS_FILE"
    chmod 600 "$QAPI_SECRETS_FILE"
    echo "[QuantumAPI] wrote ${#vars[@]} secret(s) to ${QAPI_SECRETS_FILE} (mode 0600)"
  fi

  # Persist the cache marker for the next invocation in this job.
  if [ "$QAPI_CACHE" = "true" ] && [ -n "$cache_key" ] && [ -n "${GITHUB_STATE:-}" ]; then
    echo "QAPI_CACHE_${cache_key}=1" >> "$GITHUB_STATE"
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "injected-vars=${injected}" >> "$GITHUB_OUTPUT"
  echo "cache-hit=${cache_hit}" >> "$GITHUB_OUTPUT"
fi
