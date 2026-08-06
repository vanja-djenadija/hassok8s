#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

KC="microk8s kubectl"
OUT="${ROOT_DIR}/logs"
mkdir -p "${OUT}"

PROBER_IMAGE="${PROBER_IMAGE:-curlimages/curl:8.10.1}"
CURL_POD="verify-curl-$(date +%s)"

run_curl_in_cluster() {
  local url="$1"
  local out_file="$2"
  ${KC} run "${CURL_POD}" -n "${NAMESPACE}" \
    --rm -i --restart=Never \
    --image="${PROBER_IMAGE}" \
    --command -- sh -c "curl -sk -o /tmp/body.txt -w 'HTTP status: %{http_code}\nResponse time: %{time_total}s\n' '$url'; echo '--- body preview ---'; head -c 500 /tmp/body.txt; echo" \
    | tee "${out_file}"
}

echo "==> [1] Node and HA cluster state"
${KC} get nodes -o wide | tee "${OUT}/06-01-nodes.txt"
echo "" | tee -a "${OUT}/06-01-nodes.txt"
microk8s status | tee "${OUT}/06-02-microk8s-status.txt"

echo ""
echo "==> [2] All resources in namespace ${NAMESPACE}"
${KC} get all -n "${NAMESPACE}" | tee "${OUT}/06-03-get-all.txt"

echo ""
echo "==> [3] Pod placement across nodes (HA distribution evidence)"
${KC} get pods -n "${NAMESPACE}" -o wide \
  --sort-by='{.spec.nodeName}' | tee "${OUT}/06-04-pod-placement.txt"

echo ""
echo "==> [4] PostgreSQL cluster (CNPG): state and roles"
${KC} get cluster -n "${NAMESPACE}" | tee "${OUT}/06-05-pg-cluster.txt"
echo "" | tee -a "${OUT}/06-05-pg-cluster.txt"
${KC} get pods -n "${NAMESPACE}" \
  -l cnpg.io/cluster=keycloak-postgres -L role -o wide \
  | tee -a "${OUT}/06-05-pg-cluster.txt"

echo ""
echo "==> [5] Persistent storage (PVC) — database persistence evidence"
${KC} get pvc -n "${NAMESPACE}" | tee "${OUT}/06-06-pvc.txt"

echo ""
echo "==> [6] Services (CNPG -rw/-ro/-r, Keycloak service and discovery)"
${KC} get svc -n "${NAMESPACE}" | tee "${OUT}/06-07-services.txt"

echo ""
echo "==> [7] Ingress (external entry point)"
${KC} get ingress -n "${NAMESPACE}" | tee "${OUT}/06-08-ingress.txt"
${KC} describe ingress keycloak-ingress -n "${NAMESPACE}" | tee -a "${OUT}/06-08-ingress.txt" || true

echo ""
echo "==> [8] Realm import (Job status)"
${KC} get job -n "${NAMESPACE}" | tee "${OUT}/06-09-realm-import.txt"
echo "" | tee -a "${OUT}/06-09-realm-import.txt"
${KC} get keycloakrealmimport -n "${NAMESPACE}" -o wide | tee -a "${OUT}/06-09-realm-import.txt" || true

echo ""
echo "==> [9] Keycloak Infinispan clustering (session replication)"
{
  for POD in $(${KC} get pods -n "${NAMESPACE}" \
      -l app=keycloak -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "----- ${POD} -----"
    ${KC} logs "${POD}" -n "${NAMESPACE}" 2>/dev/null \
      | grep -iE "ISPN000094|ISPN00094|received new cluster view|members|Channel.*connected|JGroups" \
      | tail -10 || echo "(no clustering lines found in this pod)"
  done
} | tee "${OUT}/06-10-clustering.txt"

echo ""
echo "==> [10] Health/ready endpoint through the internal service"
run_curl_in_cluster \
  "https://keycloak-unibl-service.${NAMESPACE}.svc.cluster.local:9000/health/ready" \
  "${OUT}/06-11-health.txt" || {
    echo "HTTPS health check failed; trying HTTP on port 9000." | tee -a "${OUT}/06-11-health.txt"
    run_curl_in_cluster \
      "http://keycloak-unibl-service.${NAMESPACE}.svc.cluster.local:9000/health/ready" \
      "${OUT}/06-11-health-http.txt" || true
  }

echo ""
echo "==> [11] Realm '${REALM_NAME}' available through the internal service"
run_curl_in_cluster \
  "https://keycloak-unibl-service.${NAMESPACE}.svc.cluster.local:8443/realms/${REALM_NAME}/.well-known/openid-configuration" \
  "${OUT}/06-12-realm.txt" || true

echo ""
echo "==> [12] Summary for HA test validity"
{
  echo "Nodes:"
  ${KC} get nodes --no-headers
  echo ""
  echo "Keycloak pods:"
  ${KC} get pods -n "${NAMESPACE}" -l app=keycloak -o wide
  echo ""
  echo "PostgreSQL pods:"
  ${KC} get pods -n "${NAMESPACE}" -l cnpg.io/cluster=keycloak-postgres -L role -o wide
  echo ""
  echo "CNPG cluster:"
  ${KC} get cluster keycloak-postgres -n "${NAMESPACE}"
} | tee "${OUT}/06-13-ha-summary.txt"

echo ""
echo "============================================================"
echo " DONE: evidence captured in ${OUT}/"
echo " Files 06-01 through 06-13 form a complete system-state snapshot."
echo "============================================================"
