#!/usr/bin/env bash
# =============================================================
#  06 — Provjera i prikupljanje dokaza
#  Pokrenuti na n00 nakon deploya. Snima izlaze u docs/ kao
#  materijal za pisanje rada.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config.env"

KC="microk8s kubectl"
OUT="${ROOT_DIR}/docs"
mkdir -p "${OUT}"

echo "==> Stanje čvorova (HA klaster)"
${KC} get nodes -o wide | tee "${OUT}/01-nodes.txt"
microk8s status | tee "${OUT}/01-microk8s-status.txt"

echo ""
echo "==> Svi resursi u ${NAMESPACE}"
${KC} get all -n "${NAMESPACE}" | tee "${OUT}/02-get-all.txt"

echo ""
echo "==> PostgreSQL klaster (CNPG)"
${KC} get cluster -n "${NAMESPACE}" | tee "${OUT}/03-pg-cluster.txt"
${KC} get pods -n "${NAMESPACE}" \
  -l cnpg.io/cluster=keycloak-postgres -o wide \
  | tee -a "${OUT}/03-pg-cluster.txt"

echo ""
echo "==> Servisi (-rw/-ro/-r + Keycloak)"
${KC} get svc -n "${NAMESPACE}" | tee "${OUT}/04-services.txt"

echo ""
echo "==> Keycloak Infinispan clustering"
POD="$(${KC} get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/managed-by=keycloak-operator" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
if [[ -n "${POD}" ]]; then
  ${KC} logs "${POD}" -n "${NAMESPACE}" \
    | grep -iE "infinispan|ISPN|cluster|view|members" \
    | tail -20 | tee "${OUT}/05-clustering.txt" || \
    echo "Nema clustering linija (provjeriti ručno)."
fi

echo ""
echo "==> Health endpoint"
curl -sk "https://${KEYCLOAK_HOSTNAME}/health/ready" \
  | tee "${OUT}/06-health.txt" || echo "Health nedostupan preko Ingressa."

echo ""
echo "DONE: dokazi snimljeni u ${OUT}/"
