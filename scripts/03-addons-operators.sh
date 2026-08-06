#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

KC="microk8s kubectl"

echo "==> [1/5] DNS (internal service name resolution)"
microk8s enable dns

echo "==> [2/5] hostpath-storage (default storage class)"
echo "    Note: hostpath is acceptable for test environments, but it is not production-grade HA storage."
microk8s enable hostpath-storage

echo "==> [3/5] ingress (nginx Ingress controller)"
microk8s enable ingress

echo "    Waiting for microk8s to become ready..."
microk8s status --wait-ready --timeout 300

echo "==> [4/5] CloudNativePG operator (v${CNPG_VERSION})"
${KC} apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"

echo "    Waiting for CNPG CRDs..."
${KC} wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=180s
${KC} wait --for=condition=Established crd/backups.postgresql.cnpg.io --timeout=180s || true
${KC} wait --for=condition=Established crd/scheduledbackups.postgresql.cnpg.io --timeout=180s || true

${KC} rollout restart deployment/cnpg-controller-manager -n cnpg-system
${KC} rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=300s

echo "==> [5/5] Keycloak operator (v${KEYCLOAK_VERSION})"
BASE="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"

${KC} apply -f "${BASE}/keycloaks.k8s.keycloak.org-v1.yml"
${KC} apply -f "${BASE}/keycloakrealmimports.k8s.keycloak.org-v1.yml"

echo "    Waiting for Keycloak CRDs to be registered..."

for crd in keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org; do
  for i in $(seq 1 60); do
    if ${KC} get crd "${crd}" >/dev/null 2>&1; then
      echo "    CRD ${crd} is registered."
      break
    fi

    if [[ "${i}" -eq 60 ]]; then
      echo "ERROR: CRD ${crd} was not registered in time." >&2
      exit 1
    fi

    sleep 2
  done
done

sleep 5

${KC} create namespace "${NAMESPACE}" --dry-run=client -o yaml | ${KC} apply -f -
${KC} -n "${NAMESPACE}" apply -f "${BASE}/kubernetes.yml"

echo "    Adjusting the Keycloak operator ClusterRoleBinding subject namespace"
if ${KC} get clusterrolebinding keycloak-operator-clusterrole-binding >/dev/null 2>&1; then
  ${KC} patch clusterrolebinding keycloak-operator-clusterrole-binding \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/subjects/0/namespace\",\"value\":\"${NAMESPACE}\"}]" || true
fi

${KC} rollout restart -n "${NAMESPACE}" deployment/keycloak-operator
${KC} rollout status -n "${NAMESPACE}" deployment/keycloak-operator --timeout=300s

echo ""
echo "==> Verification"
${KC} get pods -n cnpg-system -o wide
${KC} get pods -n "${NAMESPACE}" -o wide
${KC} get crd | grep -E 'keycloak|cnpg|postgresql' || true

echo ""
echo "DONE: addons and operators are active."
