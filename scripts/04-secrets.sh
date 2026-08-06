#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

KC="microk8s kubectl"

DB_PASS="${1:-${KC_DB_PASSWORD:-}}"
ADMIN_PASS="${2:-${KC_ADMIN_PASSWORD:-}}"

if [[ -z "${DB_PASS}" || -z "${ADMIN_PASS}" ]]; then
  echo "ERROR: missing passwords." >&2
  echo "Usage: $0 <db-password> <admin-password>" >&2
  echo "Alternative: KC_DB_PASSWORD='...' KC_ADMIN_PASSWORD='...' $0" >&2
  exit 1
fi

echo "==> Namespace '${NAMESPACE}'"
${KC} create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo "==> Secret: database credentials (keycloak-db-secret)"
${KC} create secret generic keycloak-db-secret \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="${PG_USERNAME}" \
  --from-literal=password="${DB_PASS}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo "==> Secret: admin credentials (keycloak-admin-secret)"
${KC} create secret generic keycloak-admin-secret \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="${KEYCLOAK_ADMIN_USER}" \
  --from-literal=password="${ADMIN_PASS}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | ${KC} apply -f -

echo "==> TLS certificate (self-signed) for ${KEYCLOAK_HOSTNAME}"
echo "    For production, replace this with a trusted certificate, for example via cert-manager / Let's Encrypt."
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
echo "==> Verification"
${KC} get secrets -n "${NAMESPACE}"
echo ""
echo "DONE: namespace and Secrets have been created."
