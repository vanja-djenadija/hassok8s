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
trap 'rm -rf "${RENDER_DIR}"' EXIT

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
PHASE=""
READY="0"

for i in $(seq 1 60); do
  PHASE="$(${KC} get cluster/keycloak-postgres -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"

  READY="$(${KC} get cluster/keycloak-postgres -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")"

  echo "    [$i/60] phase='${PHASE}' readyInstances='${READY}/${PG_INSTANCES}'"

  if [[ "${PHASE}" == "Cluster in healthy state" && "${READY}" == "${PG_INSTANCES}" ]]; then
    echo "    PostgreSQL klaster je zdrav (${READY}/${PG_INSTANCES} instanci)."
    break
  fi

  sleep 5
done

if [[ "${PHASE}" != "Cluster in healthy state" || "${READY}" != "${PG_INSTANCES}" ]]; then
  echo "GREŠKA: PostgreSQL klaster nije postao zdrav u zadatom vremenu." >&2
  echo "Provjera:" >&2
  echo "  microk8s kubectl get cluster keycloak-postgres -n ${NAMESPACE}" >&2
  echo "  microk8s kubectl get pods -n ${NAMESPACE} -l cnpg.io/cluster=keycloak-postgres -o wide" >&2
  echo "  microk8s kubectl describe cluster keycloak-postgres -n ${NAMESPACE}" >&2
  exit 1
fi

echo "==> [2/4] Keycloak klaster"
${KC} apply -f "${RENDER_DIR}/keycloak-cr.yaml"

echo "    Čekanje da Keycloak bude spreman (JVM warmup, do 8 min)..."
sleep 20

${KC} wait --for=condition=Ready keycloak/keycloak-unibl \
  -n "${NAMESPACE}" --timeout=480s

echo "==> [3/4] Realm import"
${KC} apply -f "${RENDER_DIR}/realm-import-cr.yaml"

echo "==> [4/4] Ingress"
${KC} apply -f "${RENDER_DIR}/ingress.yaml"

echo ""
echo "==> Stanje resursa"
${KC} get all -n "${NAMESPACE}"

echo ""
echo "============================================================"
echo " DEPLOY ZAVRŠEN"
echo " Otvorite:  https://${KEYCLOAK_HOSTNAME}"
echo " Admin:     https://${KEYCLOAK_HOSTNAME}/admin"
echo "============================================================"