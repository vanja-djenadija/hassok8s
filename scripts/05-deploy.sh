#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config.env"

KC="microk8s kubectl"

if ! command -v envsubst >/dev/null 2>&1; then
  echo "==> Installing envsubst (gettext-base)"
  apt-get update -q
  apt-get install -y gettext-base
fi

export NAMESPACE PG_INSTANCES PG_STORAGE_SIZE PG_DATABASE PG_USERNAME
export KEYCLOAK_INSTANCES KEYCLOAK_HOSTNAME REALM_NAME REALM_DISPLAY_NAME

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

echo "==> Rendering manifests"
render() { envsubst < "$1" > "$2"; }

render "${ROOT_DIR}/templates/postgres/cnpg-cluster.yaml"    "${RENDER_DIR}/cnpg-cluster.yaml"

if [[ -n "${PG_STORAGE_CLASS}" ]]; then
  sed -i "s|##STORAGECLASS##|    storageClass: ${PG_STORAGE_CLASS}|" "${RENDER_DIR}/cnpg-cluster.yaml"
else
  sed -i "/##STORAGECLASS##/d" "${RENDER_DIR}/cnpg-cluster.yaml"
fi

render "${ROOT_DIR}/templates/keycloak/keycloak-cr.yaml"     "${RENDER_DIR}/keycloak-cr.yaml"
render "${ROOT_DIR}/templates/keycloak/realm-import-cr.yaml" "${RENDER_DIR}/realm-import-cr.yaml"
render "${ROOT_DIR}/templates/ingress/ingress.yaml"          "${RENDER_DIR}/ingress.yaml"

echo "==> Validating rendered manifests"
for f in "${RENDER_DIR}"/*.yaml; do
  echo "    dry-run: $(basename "$f")"
  ${KC} apply --dry-run=server -f "$f" >/dev/null
done

echo "==> [1/4] PostgreSQL cluster"
${KC} apply -f "${RENDER_DIR}/cnpg-cluster.yaml"

echo "    Waiting for PostgreSQL to become healthy (up to 20 min)..."
PG_MAX_TRIES=240
PHASE=""
READY="0"
for i in $(seq 1 "${PG_MAX_TRIES}"); do
  PHASE="$(${KC} get cluster/keycloak-postgres -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  READY="$(${KC} get cluster/keycloak-postgres -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")"

  echo "    [$i/${PG_MAX_TRIES}] phase='${PHASE:-<none>}' readyInstances='${READY}/${PG_INSTANCES}'"

  if [[ "${PHASE}" == "Cluster in healthy state" && "${READY}" == "${PG_INSTANCES}" ]]; then
    echo "    PostgreSQL cluster is healthy (${READY}/${PG_INSTANCES} instances)."
    break
  fi
  sleep 5
done

if [[ "${PHASE}" != "Cluster in healthy state" || "${READY}" != "${PG_INSTANCES}" ]]; then
  echo "ERROR: PostgreSQL cluster did not become healthy within the timeout." >&2
  ${KC} get cluster keycloak-postgres -n "${NAMESPACE}" >&2 || true
  ${KC} get pods -n "${NAMESPACE}" -l cnpg.io/cluster=keycloak-postgres -o wide >&2 || true
  ${KC} describe cluster keycloak-postgres -n "${NAMESPACE}" >&2 || true
  exit 1
fi

echo "==> [2/4] Keycloak cluster"
${KC} apply -f "${RENDER_DIR}/keycloak-cr.yaml"

echo "    Waiting for Keycloak to become ready (up to 20 min)..."
KC_MAX_TRIES=240
KC_READY="false"
COND=""
PODS_READY="0"

for i in $(seq 1 "${KC_MAX_TRIES}"); do
  COND="$(${KC} get keycloak/keycloak-unibl -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"

  PODS_READY="$(${KC} get pods -n "${NAMESPACE}" \
    -l app=keycloak,app.kubernetes.io/managed-by=keycloak-operator \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c "True" || true)"
  PODS_READY="${PODS_READY:-0}"

  echo "    [$i/${KC_MAX_TRIES}] Keycloak Ready='${COND:-<none>}' ready pods='${PODS_READY}/${KEYCLOAK_INSTANCES}'"

  if [[ "${COND}" == "True" && "${PODS_READY}" == "${KEYCLOAK_INSTANCES}" ]]; then
    echo "    Keycloak cluster is ready (${PODS_READY}/${KEYCLOAK_INSTANCES} instances)."
    KC_READY="true"
    break
  fi
  sleep 5
done

if [[ "${KC_READY}" != "true" ]]; then
  echo "ERROR: Keycloak did not become ready within the timeout." >&2
  ${KC} get keycloak keycloak-unibl -n "${NAMESPACE}" >&2 || true
  ${KC} get pods -n "${NAMESPACE}" -o wide >&2 || true
  ${KC} describe keycloak keycloak-unibl -n "${NAMESPACE}" >&2 || true
  exit 1
fi

echo "==> [3/4] Realm import"
${KC} apply -f "${RENDER_DIR}/realm-import-cr.yaml"

echo "    Waiting for the realm import Job to complete (up to 10 min)..."
# The Keycloak operator creates an import Job. Its name may vary, so we search for realm/import-related jobs.
IMPORT_JOB=""
for i in $(seq 1 60); do
  IMPORT_JOB="$(${KC} get jobs -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'realm-import|keycloak.*import' | tail -1 || true)"
  [[ -n "${IMPORT_JOB}" ]] && break
  sleep 5
done

if [[ -n "${IMPORT_JOB}" ]]; then
  ${KC} wait --for=condition=complete "job/${IMPORT_JOB}" -n "${NAMESPACE}" --timeout=600s || {
    echo "ERROR: the realm import Job did not complete successfully." >&2
    ${KC} logs "job/${IMPORT_JOB}" -n "${NAMESPACE}" >&2 || true
    exit 1
  }
else
  echo "    WARNING: realm import Job not found; continuing, but check the KeycloakRealmImport status."
fi

echo "==> [4/4] Ingress"
${KC} apply -f "${RENDER_DIR}/ingress.yaml"

echo ""
echo "==> Resource state"
${KC} get all -n "${NAMESPACE}"
${KC} get ingress -n "${NAMESPACE}"

echo ""
echo "============================================================"
echo " DEPLOYMENT COMPLETED"
echo " Open:  https://${KEYCLOAK_HOSTNAME}"
echo " Admin: https://${KEYCLOAK_HOSTNAME}/admin"
echo "============================================================"
