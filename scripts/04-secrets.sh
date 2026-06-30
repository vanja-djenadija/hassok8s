#!/usr/bin/env bash
# =============================================================
#  04 — Namespace, Secrets i TLS certifikat
#  Pokrenuti SAMO na n00.
#
#  Upotreba:
#    bash 04-secrets.sh <db-lozinka> <admin-lozinka>
#  ili kroz okruženje:
#    KC_DB_PASSWORD=... KC_ADMIN_PASSWORD=... bash 04-secrets.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

KC="microk8s kubectl"

DB_PASS="${1:-${KC_DB_PASSWORD:-}}"
ADMIN_PASS="${2:-${KC_ADMIN_PASSWORD:-}}"

if [[ -z "${DB_PASS}" || -z "${ADMIN_PASS}" ]]; then
  echo "GREŠKA: nedostaju lozinke." >&2
  echo "Upotreba: $0 <db-lozinka> <admin-lozinka>" >&2
  exit 1
fi

echo "==> Namespace '${NAMESPACE}'"
${KC} create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo "==> Secret: kredencijali baze (keycloak-db-secret)"
${KC} create secret generic keycloak-db-secret \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="${PG_USERNAME}" \
  --from-literal=password="${DB_PASS}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo "==> Secret: admin kredencijali (keycloak-admin-secret)"
${KC} create secret generic keycloak-admin-secret \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="${KEYCLOAK_ADMIN_USER}" \
  --from-literal=password="${ADMIN_PASS}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo "==> TLS certifikat (self-signed) za ${KEYCLOAK_HOSTNAME}"
# Za produkciju zamijeniti važećim certifikatom (cert-manager / Let's Encrypt).
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMP_DIR}/tls.key" \
  -out "${TMP_DIR}/tls.crt" \
  -subj "/CN=${KEYCLOAK_HOSTNAME}/O=${ORG_TLS_O}" \
  -addext "subjectAltName=DNS:${KEYCLOAK_HOSTNAME}" 2>/dev/null

${KC} create secret tls keycloak-tls \
  --cert="${TMP_DIR}/tls.crt" \
  --key="${TMP_DIR}/tls.key" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo ""
echo "==> Provjera"
${KC} get secrets -n "${NAMESPACE}"
echo ""
echo "DONE: namespace i Secrets su kreirani."
