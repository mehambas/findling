#!/bin/bash
# Creates the self-signed certificate scripts/build.sh signs with, imports it into the login keychain
# and writes a password-protected backup. Keep the backup: macOS ties folder permissions to the
# certificate, so builds signed with a new one make every user grant access again.
set -euo pipefail
name="Findling Self-Signed"
backup_dir="${1:?Usage: scripts/make-certificate.sh <backup directory>}"
if security find-identity -p codesigning | grep -qF "\"$name\""; then
    echo "\"$name\" is already in the keychain." >&2
    exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes -config "$work/openssl.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
password="$(/usr/bin/openssl rand -base64 24)"
mkdir -p "$backup_dir"
backup="$backup_dir/findling-signing.p12"
(umask 077; /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -passout "pass:$password" -out "$backup")
security import "$backup" -k "$HOME/Library/Keychains/login.keychain-db" -P "$password" -T /usr/bin/codesign
security add-generic-password -U -s "$name backup" -a "$(basename "$backup")" -w "$password"
echo "Imported \"$name\". Backup: $backup"
echo "Backup password: security find-generic-password -s \"$name backup\" -w"
