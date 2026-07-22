#!/bin/zsh
# Create a local code-signing identity for Agent Island.
#
# WHY THIS EXISTS
# macOS pins permission grants (Accessibility, audio capture) to a signature's
# designated requirement. An ad-hoc signature changes on every build, so every
# rebuild revokes whatever you granted. A stable self-signed identity keeps the
# requirement constant and the grants stick.
#
# WHAT IT IS NOT
# This is not for distributing the app. It is not notarized and Gatekeeper will
# still warn on machines other than the one that made it. It exists purely so a
# developer stops re-approving permissions after every build.
#
# SCOPE
# The certificate is created with CA:FALSE and Code Signing as its only extended
# key usage, so it cannot issue other certificates and cannot be used for TLS.
# The private key is imported with access limited to /usr/bin/codesign rather
# than to all applications. It lives in your login keychain only; nothing is
# added to the system trust store.
#
# TO REMOVE
#   security delete-certificate -c "Agent Island Local"
# Builds fall back to ad-hoc automatically.

set -euo pipefail

NAME="Agent Island Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "'$NAME' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
# The key material must not outlive the import.
trap 'rm -rf "$WORK"' EXIT

echo "creating a code-signing-only certificate..."
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$NAME/O=Agent Island/C=US" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$WORK/bundle.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$PASS" -name "$NAME" >/dev/null 2>&1

security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo
echo "done. '$NAME' is in your login keychain."
echo "Rebuild with scripts/build-app.sh and permissions will persist across builds."
