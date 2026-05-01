#!/usr/bin/env bats
# Unit tests for inject-secrets.sh
#
# Run with: bats test/inject-secrets.bats
# (bats-core: https://github.com/bats-core/bats-core)
#
# These tests stub `curl` via PATH shim so the script can be exercised offline.

setup() {
  export TMPDIR_TEST="$(mktemp -d)"
  export PATH="${TMPDIR_TEST}/bin:$PATH"
  mkdir -p "${TMPDIR_TEST}/bin"

  # Mock GitHub Actions output files
  export GITHUB_ENV="${TMPDIR_TEST}/github_env"
  export GITHUB_OUTPUT="${TMPDIR_TEST}/github_output"
  export GITHUB_STATE="${TMPDIR_TEST}/github_state"
  : >"$GITHUB_ENV"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STATE"

  export QAPI_API_KEY="qapi_sk_test123"
  export QAPI_ENDPOINT="http://mock"
  export QAPI_EXPORT_ENV="true"
  unset QAPI_SECRETS_FILE
  unset QAPI_CACHE
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# Provide a curl shim that returns canned JSON.
mock_curl_ok() {
  cat >"${TMPDIR_TEST}/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Find the -o argument and write the canned response there
out=""
i=1
while [ $i -le $# ]; do
  v="${!i}"
  if [ "$v" = "-o" ]; then
    j=$((i+1)); out="${!j}"
  fi
  i=$((i+1))
done
echo '{"name":"foo","value":"super-s3cret"}' >"${out:-/tmp/curl_out.json}"
echo "200"
EOF
  chmod +x "${TMPDIR_TEST}/bin/curl"
}

mock_curl_404() {
  cat >"${TMPDIR_TEST}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
i=1
while [ $i -le $# ]; do
  v="${!i}"
  if [ "$v" = "-o" ]; then j=$((i+1)); out="${!j}"; fi
  i=$((i+1))
done
echo '{"error":"not_found"}' >"${out:-/tmp/curl_out.json}"
echo "404"
EOF
  chmod +x "${TMPDIR_TEST}/bin/curl"
}

# A curl shim that records every invocation in a counter file. Useful for
# asserting that the cache short-circuits subsequent runs.
mock_curl_count() {
  cat >"${TMPDIR_TEST}/bin/curl" <<EOF
#!/usr/bin/env bash
out=""
i=1
while [ \$i -le \$# ]; do
  v="\${!i}"
  if [ "\$v" = "-o" ]; then j=\$((i+1)); out="\${!j}"; fi
  i=\$((i+1))
done
echo '{"name":"foo","value":"super-s3cret"}' >"\${out:-/tmp/curl_out.json}"
printf '1\n' >>"${TMPDIR_TEST}/curl_count"
echo "200"
EOF
  chmod +x "${TMPDIR_TEST}/bin/curl"
  : >"${TMPDIR_TEST}/curl_count"
}

@test "exits non-zero when QAPI_API_KEY is missing" {
  unset QAPI_API_KEY
  export QAPI_SECRET_PATHS="FOO=bar"
  run bash inject-secrets.sh
  [ "$status" -ne 0 ]
}

@test "exits non-zero when QAPI_SECRET_PATHS is missing" {
  unset QAPI_SECRET_PATHS
  run bash inject-secrets.sh
  [ "$status" -ne 0 ]
}

@test "rejects a path line with no equals sign" {
  mock_curl_ok
  export QAPI_SECRET_PATHS=$'no_equals_sign_here'
  run bash inject-secrets.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid secret-paths line"* ]]
}

@test "rejects an invalid env var name" {
  mock_curl_ok
  export QAPI_SECRET_PATHS=$'1bad_var=foo/bar'
  run bash inject-secrets.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid environment variable name"* ]]
}

@test "skips comment and blank lines" {
  mock_curl_ok
  export QAPI_SECRET_PATHS=$'# this is a comment\n\nGOOD=foo/bar'
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  grep -q '^GOOD<<' "$GITHUB_ENV"
  grep -q 'super-s3cret' "$GITHUB_ENV"
}

@test "writes injected-vars output and masks values" {
  mock_curl_ok
  export QAPI_SECRET_PATHS=$'A=foo\nB=bar'
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::super-s3cret"* ]]
  grep -q 'injected-vars=A,B' "$GITHUB_OUTPUT"
}

@test "fails on non-200 HTTP response" {
  mock_curl_404
  export QAPI_SECRET_PATHS=$'X=missing/secret'
  run bash inject-secrets.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to fetch secret"* ]]
}

# ---------------------------------------------------------------------------
# secrets-file tests (#237)
# ---------------------------------------------------------------------------

@test "secrets-file writes KEY=value with mode 0600" {
  mock_curl_ok
  export QAPI_SECRET_PATHS=$'A=foo\nB=bar'
  export QAPI_SECRETS_FILE="${TMPDIR_TEST}/out.env"
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  [ -f "$QAPI_SECRETS_FILE" ]
  grep -q '^A=super-s3cret$' "$QAPI_SECRETS_FILE"
  grep -q '^B=super-s3cret$' "$QAPI_SECRETS_FILE"
  # Mode check — portable across linux/macOS.
  if stat -c '%a' "$QAPI_SECRETS_FILE" >/dev/null 2>&1; then
    perms="$(stat -c '%a' "$QAPI_SECRETS_FILE")"
  else
    perms="$(stat -f '%Lp' "$QAPI_SECRETS_FILE")"
  fi
  [ "$perms" = "600" ]
}

@test "secrets-file is created in a non-existent parent directory" {
  mock_curl_ok
  export QAPI_SECRET_PATHS=$'A=foo'
  export QAPI_SECRETS_FILE="${TMPDIR_TEST}/sub/dir/out.env"
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  [ -f "$QAPI_SECRETS_FILE" ]
}

# ---------------------------------------------------------------------------
# cache tests (#237)
# ---------------------------------------------------------------------------

@test "cache=true writes a cache marker to GITHUB_STATE" {
  mock_curl_count
  export QAPI_SECRET_PATHS=$'A=foo'
  export QAPI_CACHE="true"
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  grep -q '^QAPI_CACHE_' "$GITHUB_STATE"
  # Exactly 1 curl call.
  [ "$(wc -l <"${TMPDIR_TEST}/curl_count" | tr -d ' ')" = "1" ]
  grep -q 'cache-hit=false' "$GITHUB_OUTPUT"
}

@test "cache=true short-circuits when the marker env var is already set" {
  mock_curl_count
  export QAPI_SECRET_PATHS=$'A=foo'
  export QAPI_CACHE="true"

  # First run — populates the cache.
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  # Extract the cache key from the state file.
  marker="$(grep -o 'QAPI_CACHE_[A-Fa-f0-9-]*' "$GITHUB_STATE" | head -n1)"
  [ -n "$marker" ]

  # Second run — pre-set the marker so the cache is "hit".
  : >"$GITHUB_OUTPUT"
  : >"${TMPDIR_TEST}/curl_count"
  export "$marker"=1
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  grep -q 'cache-hit=true' "$GITHUB_OUTPUT"
  # No curl calls on cache hit.
  [ ! -s "${TMPDIR_TEST}/curl_count" ]
}

@test "cache key changes when paths change" {
  mock_curl_count
  export QAPI_CACHE="true"

  export QAPI_SECRET_PATHS=$'A=foo'
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  key1="$(grep -o 'QAPI_CACHE_[A-Fa-f0-9-]*' "$GITHUB_STATE" | head -n1)"

  : >"$GITHUB_STATE"
  export QAPI_SECRET_PATHS=$'A=bar'
  run bash inject-secrets.sh
  [ "$status" -eq 0 ]
  key2="$(grep -o 'QAPI_CACHE_[A-Fa-f0-9-]*' "$GITHUB_STATE" | head -n1)"

  [ "$key1" != "$key2" ]
}
