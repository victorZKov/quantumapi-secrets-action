#!/usr/bin/env bash
# QuantumAPI Sign / Verify — GitHub Action entrypoint for `mode: sign|verify`.
#
# Interchangeable with the CLI: like `qapi sign --file` / `qapi verify --file`
# it signs/verifies the raw 32-byte SHA-256 digest of the file (base64 in the
# JSON `data` field), via POST /api/v1/sign and POST /api/v1/verify.
#
# Env: QAPI_MODE (sign|verify), QAPI_API_KEY, QAPI_ENDPOINT, QAPI_FILE,
#      QAPI_KEY_ID, QAPI_SIGNATURE (verify: file path or raw base64),
#      QAPI_SIGNATURE_OUTPUT (sign: where to write, default <file>.sig),
#      QAPI_ALGORITHM (sign, optional; empty = server default ML-DSA-65).

set -euo pipefail

: "${QAPI_API_KEY:?QAPI_API_KEY is required (the action input 'api-key')}"
# Mask first so the key can never reach the log, even on later errors.
echo "::add-mask::${QAPI_API_KEY}"

QAPI_MODE="${QAPI_MODE:-}"
QAPI_ENDPOINT="${QAPI_ENDPOINT:-https://api.quantumapi.eu}"
QAPI_ENDPOINT="${QAPI_ENDPOINT%/}"
QAPI_FILE="${QAPI_FILE:-}"
QAPI_KEY_ID="${QAPI_KEY_ID:-}"
QAPI_SIGNATURE="${QAPI_SIGNATURE:-}"
QAPI_SIGNATURE_OUTPUT="${QAPI_SIGNATURE_OUTPUT:-}"
QAPI_ALGORITHM="${QAPI_ALGORITHM:-}"

fail() { echo "::error title=QuantumAPI ${QAPI_MODE:-sign/verify}::$*"; exit 1; }

case "$QAPI_MODE" in sign | verify) ;; *) fail "Unsupported mode '${QAPI_MODE}' (expected sign or verify)" ;; esac
[ -n "$QAPI_FILE" ] || fail "Input 'file' is required for mode ${QAPI_MODE}"
[ -n "$QAPI_KEY_ID" ] || fail "Input 'key-id' is required for mode ${QAPI_MODE}"
[ -f "$QAPI_FILE" ] || fail "File not found: ${QAPI_FILE}"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found in PATH"
command -v jq >/dev/null 2>&1 || fail "jq is required but not found in PATH"

# SHA-256 of the file as raw bytes, then base64 (same payload as the CLI).
if command -v sha256sum >/dev/null 2>&1; then
  hex="$(sha256sum -- "$QAPI_FILE" | awk '{print $1}')"
else
  hex="$(shasum -a 256 -- "$QAPI_FILE" | awk '{print $1}')"
fi
esc="$(printf '%s' "$hex" | sed 's/../\\x&/g')"
# shellcheck disable=SC2059
data_b64="$(printf "$esc" | base64 | tr -d '\n')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

call_api() { # $1=path, $2=body-file -> echoes http code, response in $work/resp.json
  curl -sS -o "$work/resp.json" -w '%{http_code}' -X POST \
    -H "X-Api-Key: ${QAPI_API_KEY}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary "@$2" "${QAPI_ENDPOINT}$1" || echo "000"
}

api_error() { # $1=http code
  local msg
  msg="$(jq -r '.detail // .message // .error // empty' "$work/resp.json" 2>/dev/null || true)"
  case "$1" in
    401) fail "Authentication failed (HTTP 401): check the api-key input" ;;
    403) fail "API key lacks the required scope (HTTP 403): ${QAPI_MODE} needs the '${QAPI_MODE}' API-key scope ${msg}" ;;
    404) fail "Key '${QAPI_KEY_ID}' not found (HTTP 404) ${msg}" ;;
    *) fail "${QAPI_MODE} request failed (HTTP $1) ${msg}" ;;
  esac
}

if [ "$QAPI_MODE" = "sign" ]; then
  jq -n --arg d "$data_b64" --arg k "$QAPI_KEY_ID" --arg a "$QAPI_ALGORITHM" \
    '{data:$d,keyId:$k} + (if $a == "" then {} else {algorithm:$a} end)' >"$work/req.json"
  code="$(call_api /api/v1/sign "$work/req.json")"
  [ "$code" = "200" ] || api_error "$code"
  sig="$(jq -r '.signature // empty' "$work/resp.json")"
  [ -n "$sig" ] || fail "The API returned no signature"
  out="${QAPI_SIGNATURE_OUTPUT:-${QAPI_FILE}.sig}"
  mkdir -p -- "$(dirname -- "$out")"
  printf '%s' "$sig" >"$out" # same format as `qapi sign --output`
  alg="$(jq -r '.algorithm // empty' "$work/resp.json")"
  echo "[QuantumAPI] signed ${QAPI_FILE} with key ${QAPI_KEY_ID}${alg:+ ($alg)} -> ${out}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "signature-path=${out}" >>"$GITHUB_OUTPUT"
  fi
else
  [ -n "$QAPI_SIGNATURE" ] || fail "Input 'signature' is required for mode verify"
  sig="$QAPI_SIGNATURE"
  if [ -f "$QAPI_SIGNATURE" ]; then
    sig="$(tr -d '[:space:]' <"$QAPI_SIGNATURE")"
  fi
  jq -n --arg d "$data_b64" --arg s "$sig" --arg k "$QAPI_KEY_ID" \
    '{data:$d,signature:$s,keyId:$k}' >"$work/req.json"
  code="$(call_api /api/v1/verify "$work/req.json")"
  if [ "$code" = "400" ] && ! jq -e 'has("isValid")' "$work/resp.json" >/dev/null 2>&1; then
    # A malformed signature is rejected by the API: still an invalid signature.
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "verified=false" >>"$GITHUB_OUTPUT"
    fail "Invalid signature for ${QAPI_FILE}: the signature is malformed or does not match key ${QAPI_KEY_ID}"
  fi
  [ "$code" = "200" ] || api_error "$code"
  valid="$(jq -r '.isValid' "$work/resp.json")"
  if [ "$valid" != "true" ]; then
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "verified=false" >>"$GITHUB_OUTPUT"
    fail "Invalid signature: ${QAPI_FILE} does not match the signature for key ${QAPI_KEY_ID}. Do not deploy this artifact."
  fi
  echo "[QuantumAPI] signature valid for ${QAPI_FILE} (key ${QAPI_KEY_ID})"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "verified=true" >>"$GITHUB_OUTPUT"
fi
