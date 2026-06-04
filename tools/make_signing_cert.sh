#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity in your login keychain.
#
# Why: build.sh otherwise ad-hoc signs, and an ad-hoc signature's identity is its
# code hash — which changes on every build. macOS binds the "Always Allow"
# keychain permission to that identity, so each rebuild invalidates it and macOS
# re-prompts for your password. A self-signed cert gives a *stable* identity
# (designated requirement = bundle id + certificate hash), so "Always Allow"
# sticks across every rebuild.
#
# Run this once. build.sh then signs with the identity automatically.
# Idempotent: does nothing if the identity already exists.
set -euo pipefail

IDENTITY="${CLAUDE_USAGE_SIGN_IDENTITY:-Claude Usage Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Identity '$IDENTITY' already exists — nothing to do."
    echo "    (Delete it in Keychain Access if you want to recreate it.)"
    exit 0
fi

# macOS's LibreSSL produces a PKCS#12 that `security import` reads natively;
# Homebrew's OpenSSL 3 defaults to a SHA-256 MAC that macOS can't verify.
OSSL=/usr/bin/openssl
# A non-empty transit password sidesteps macOS's empty-password p12 MAC quirk.
PW="claude-usage-transit"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/req.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $IDENTITY
[ v3 ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

echo "==> Generating self-signed code-signing certificate…"
"$OSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/req.cnf" 2>/dev/null
"$OSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -passout "pass:$PW" -out "$TMP/identity.p12"

# -A: let any app (i.e. codesign) use the private key without a password prompt.
echo "==> Importing into login keychain…"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PW" -A >/dev/null

echo "==> Done. Identity '$IDENTITY' is ready; build.sh will use it automatically."
echo "    First launch after rebuilding will ask once more (the app's identity"
echo "    changed) — click \"Always Allow\" that final time and it will stick."
