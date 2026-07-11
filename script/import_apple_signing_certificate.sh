#!/usr/bin/env bash
set -euo pipefail

: "${CERTIFICATE_P12_BASE64:?CERTIFICATE_P12_BASE64 is required}"
: "${CERTIFICATE_PASSWORD:?CERTIFICATE_PASSWORD is required}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD is required}"
KEYCHAIN="${RUNNER_TEMP:-/tmp}/localwrap-signing.keychain-db"
P12="${RUNNER_TEMP:-/tmp}/localwrap-developer-id.p12"

printf '%s' "$CERTIFICATE_P12_BASE64" | base64 --decode >"$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -P "$CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
rm -f "$P12"
