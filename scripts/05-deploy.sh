#!/usr/bin/env bash
# =============================================================
#  05 — Deploy aplikativnog sloja (PostgreSQL, Keycloak, Ingress)
#  Pokrenuti SAMO na n00, nakon skripti 03 i 04.
#  Popunjava ${...} placeholdere iz config.env i primjenjuje
#  manifeste redom uz čekanje na spremnost.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config.env"

KC="microk8s kubectl"

command -v envsubst >/dev/null || { apt-get update -q && apt-get install -y gettext-base; }

export NAMESPACE PG_INSTANCES PG_STORAGE_SIZE PG_DATABASE PG_USERNAME
export KEYCLOAK_INSTANCES KEYCLOAK_HOSTNAME REALM_NAME REALM_DISPLAY_NAME

RENDER_DIR="$(mktemp -d)"
echo "==> Renderovanje manifesta"

render() { envsubst < "$1" > "$2"; }

render "${ROOT_DIR}/templates/postgres/cnpg-cluster.yaml"    "${RENDER_DIR}/cnpg-cluster.yaml"

# Opcioni storageClass.
if [[ -n "${PG_STORAGE_CLASS}" ]]; then
  sed -i "s|##STORAGECLASS##|    storageClass: ${PG_STORAGE_CLASS}|" "${RENDER_DIR}/cnpg-cluster.yaml"
else
  sed -i "/##STORAGECLASS##/d" "${RENDER_DIR}/cnpg-cluster.yaml"
fi

render "${ROOT_DIR}/templates/keycloak/keycloak-cr.yaml"     "${RENDER_DIR}/keycloak-cr.yaml"
render "${ROOT_DIR}/templates/keycloak/realm-import-cr.yaml" "${RENDER_DIR}/realm-import-cr.yaml"
render "${ROOT_DIR}/templates/ingress/ingress.yaml"          "${RENDER_DIR}/ingress.yaml"

echo "==> [1/4] PostgreSQL klaster"
${KC} apply -f "${RENDER_DIR}/cnpg-cluster.yaml"
echo "    Čekanje da PostgreSQL bude zdrav (do 5 min)..."
${KC} wait --for=condition=Ready cluster/keycloak-postgres \
  -n "${NAMESPACE}" --timeout=300s

echo "==> [2/4] Keycloak klaster"
${KC} apply -f "${RENDER_DIR}/keycloak-cr.yaml"
echo "    Čekanje na Keycloak podove (JVM warmup, do 8 min)..."
sleep 20
${KC} wait --for=condition=Ready pod \
  -l "app.kubernetes.io/managed-by=keycloak-operator" \
  -n "${NAMESPACE}" --timeout=480s || true

echo "==> [3/4] Realm import"
${KC} apply -f "${RENDER_DIR}/realm-import-cr.yaml"

echo "==> [4/4] Ingress"
${KC} apply -f "${RENDER_DIR}/ingress.yaml"

rm -rf "${RENDER_DIR}"

echo ""
echo "==> Stanje resursa"
${KC} get all -n "${NAMESPACE}"
echo ""
echo "============================================================"
echo " DEPLOY ZAVRŠEN"
echo " Otvorite:  https://${KEYCLOAK_HOSTNAME}"
echo " Admin:     https://${KEYCLOAK_HOSTNAME}/admin"
echo "============================================================"
