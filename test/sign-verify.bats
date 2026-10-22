#!/usr/bin/env bats
# Unit tests for sign-verify.sh (mode: sign | verify)
#
# Run with: bats test/sign-verify.bats
# `curl` is stubbed via a PATH shim that records the request body and returns
# a canned status + JSON, so the script is exercised offline.

setup() {
  export TMPDIR_TEST="$(mktemp -d)"
  export PATH="${TMPDIR_TEST}/bin:$PATH"
  mkdir -p "${TMPDIR_TEST}/bin"
  export GITHUB_OUTPUT="${TMPDIR_TEST}/github_output"
  : >"$GITHUB_OUTPUT"

  export QAPI_API_KEY="qapi_sk_supersecretkey"
  export QAPI_ENDPOINT="http://mock"
  export QAPI_KEY_ID="11111111-2222-3333-4444-555555555555"
  export QAPI_FILE="${TMPDIR_TEST}/app.tar.gz"
  printf 'hello release' >"$QAPI_FILE"
  # base64 of the raw SHA-256 digest of the file (what `qapi sign --file` sends)
  EXPECTED_DATA="$(openssl dgst -sha256 -binary "$QAPI_FILE" | base64 | tr -d '\n')"
  export EXPECTED_DATA
  unset QAPI_SIGNATURE QAPI_SIGNATURE_OUTPUT QAPI_ALGORITHM
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# mock_curl <http-code> <json-body>
mock_curl() {
  printf '%s' "$2" >"${TMPDIR_TEST}/canned.json"
  cat >"${TMPDIR_TEST}/bin/curl" <<CURLEOF
#!/usr/bin/env bash
out=""; body=""; url=""; hdrs=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --data-binary) body="\${2#@}"; shift 2 ;;
    -H) hdrs+="\$2"\$'\n'; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
cp "\$body" "${TMPDIR_TEST}/last_body.json"
printf '%s\n' "\$url" >"${TMPDIR_TEST}/last_url"
printf '%s' "\$hdrs" >"${TMPDIR_TEST}/last_headers"
cp "${TMPDIR_TEST}/canned.json" "\$out"
printf '%s' "$1"
CURLEOF
  chmod +x "${TMPDIR_TEST}/bin/curl"
}

@test "masks the API key before anything else" {
  mock_curl 200 '{"signature":"c2ln","keyId":"k","algorithm":"ML-DSA-65"}'
  export QAPI_MODE=sign
  run bash sign-verify.sh
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "::add-mask::qapi_sk_supersecretkey" ]
}

@test "never prints the API key, even on failure" {
  mock_curl 401 '{}'
  export QAPI_MODE=sign
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  # only the add-mask directive may contain the key
  [ "$(printf '%s\n' "$output" | grep -c 'qapi_sk_supersecretkey')" -eq 1 ]
}

@test "rejects an unknown mode" {
  export QAPI_MODE=encrypt
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error"*"Unsupported mode"* ]]
}

@test "sign requires file and key-id" {
  export QAPI_MODE=sign
  QAPI_KEY_ID="" run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"'key-id' is required"* ]]
  QAPI_FILE="" run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"'file' is required"* ]]
}

@test "sign fails when the file does not exist" {
  export QAPI_MODE=sign QAPI_FILE="${TMPDIR_TEST}/nope"
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"File not found"* ]]
}

@test "sign posts the base64 SHA-256 digest to /api/v1/sign (CLI-compatible)" {
  mock_curl 200 '{"signature":"c2lnbmF0dXJl","keyId":"k","algorithm":"ML-DSA-65"}'
  export QAPI_MODE=sign
  run bash sign-verify.sh
  [ "$status" -eq 0 ]
  [ "$(cat "${TMPDIR_TEST}/last_url")" = "http://mock/api/v1/sign" ]
  [ "$(jq -r .data "${TMPDIR_TEST}/last_body.json")" = "$EXPECTED_DATA" ]
  [ "$(jq -r .keyId "${TMPDIR_TEST}/last_body.json")" = "$QAPI_KEY_ID" ]
  [ "$(jq 'has("algorithm")' "${TMPDIR_TEST}/last_body.json")" = "false" ]
  grep -q "X-Api-Key: qapi_sk_supersecretkey" "${TMPDIR_TEST}/last_headers"
}

@test "sign writes <file>.sig and outputs signature-path" {
  mock_curl 200 '{"signature":"c2lnbmF0dXJl","keyId":"k","algorithm":"ML-DSA-65"}'
  export QAPI_MODE=sign
  run bash sign-verify.sh
  [ "$status" -eq 0 ]
  [ "$(cat "${QAPI_FILE}.sig")" = "c2lnbmF0dXJl" ]
  grep -q "signature-path=${QAPI_FILE}.sig" "$GITHUB_OUTPUT"
}

@test "sign honours signature-output and algorithm" {
  mock_curl 200 '{"signature":"YWJj","keyId":"k","algorithm":"ML-DSA-87"}'
  export QAPI_MODE=sign QAPI_ALGORITHM=ML-DSA-87 QAPI_SIGNATURE_OUTPUT="${TMPDIR_TEST}/out/rel.sig"
  run bash sign-verify.sh
  [ "$status" -eq 0 ]
  [ "$(cat "${TMPDIR_TEST}/out/rel.sig")" = "YWJj" ]
  [ "$(jq -r .algorithm "${TMPDIR_TEST}/last_body.json")" = "ML-DSA-87" ]
}

@test "sign gives a scope hint on 403" {
  mock_curl 403 '{}'
  export QAPI_MODE=sign
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"'sign' API-key scope"* ]]
}

@test "verify succeeds on a valid signature from a signature file" {
  mock_curl 200 '{"isValid":true}'
  printf 'c2lnbmF0dXJl\n' >"${TMPDIR_TEST}/rel.sig"
  export QAPI_MODE=verify QAPI_SIGNATURE="${TMPDIR_TEST}/rel.sig"
  run bash sign-verify.sh
  [ "$status" -eq 0 ]
  [ "$(cat "${TMPDIR_TEST}/last_url")" = "http://mock/api/v1/verify" ]
  [ "$(jq -r .signature "${TMPDIR_TEST}/last_body.json")" = "c2lnbmF0dXJl" ]
  [ "$(jq -r .data "${TMPDIR_TEST}/last_body.json")" = "$EXPECTED_DATA" ]
  grep -q "verified=true" "$GITHUB_OUTPUT"
}

@test "verify accepts a raw base64 signature" {
  mock_curl 200 '{"isValid":true}'
  export QAPI_MODE=verify QAPI_SIGNATURE="cmF3c2ln"
  run bash sign-verify.sh
  [ "$status" -eq 0 ]
  [ "$(jq -r .signature "${TMPDIR_TEST}/last_body.json")" = "cmF3c2ln" ]
}

@test "verify fails the job with an error annotation on an invalid signature" {
  mock_curl 200 '{"isValid":false}'
  export QAPI_MODE=verify QAPI_SIGNATURE="YmFk"
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error title=QuantumAPI verify::Invalid signature"* ]]
  grep -q "verified=false" "$GITHUB_OUTPUT"
}

@test "verify treats a malformed-signature 400 as an invalid signature" {
  mock_curl 400 '{"title":"Bad Request"}'
  export QAPI_MODE=verify QAPI_SIGNATURE="not-base64!!"
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid signature"* ]]
}

@test "verify requires the signature input" {
  export QAPI_MODE=verify
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"'signature' is required"* ]]
}

@test "verify gives a scope hint on 403" {
  mock_curl 403 '{}'
  export QAPI_MODE=verify QAPI_SIGNATURE="YWJj"
  run bash sign-verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"'verify' API-key scope"* ]]
}
