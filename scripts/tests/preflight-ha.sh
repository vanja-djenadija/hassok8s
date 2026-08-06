#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# HA SSO preflight check
#
# This script validates that the cluster is in a clean and stable
# state before running any failover test.
#
# A failover test must NOT start unless this script exits with 0.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${ROOT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

KC="${KC:-microk8s kubectl}"

EXPECTED_NODES="${EXPECTED_NODES:-3}"
EXPECTED_KEYCLOAK_PODS="${KEYCLOAK_INSTANCES:-3}"
EXPECTED_POSTGRES_PODS="${PG_INSTANCES:-3}"
MIN_KEYCLOAK_STABLE_SECONDS="${MIN_KEYCLOAK_STABLE_SECONDS:-600}"

KEYCLOAK_LABEL="${KEYCLOAK_LABEL:-app=keycloak,app.kubernetes.io/managed-by=keycloak-operator}"
POSTGRES_LABEL="${POSTGRES_LABEL:-cnpg.io/cluster=keycloak-postgres}"

PROBER_IMAGE="${PROBER_IMAGE:-curlimages/curl:8.10.1}"
REALM_DISCOVERY_URL_INTERNAL="https://keycloak-unibl-service.${NAMESPACE}.svc.cluster.local:8443/realms/${REALM_NAME}/.well-known/openid-configuration"

OUT_DIR="${ROOT_DIR}/logs/preflight"
mkdir -p "${OUT_DIR}"

TS="$(date +%Y%m%d-%H%M%S)"
REPORT="${OUT_DIR}/preflight-${TS}.txt"

fail() {
  echo "ERROR: $*" | tee -a "${REPORT}" >&2
  echo "" | tee -a "${REPORT}" >&2
  echo "Preflight FAILED. Do not run failover tests." | tee -a "${REPORT}" >&2
  exit 1
}

info() {
  echo "==> $*" | tee -a "${REPORT}"
}

section() {
  echo "" | tee -a "${REPORT}"
  echo "------------------------------------------------------------" | tee -a "${REPORT}"
  echo "$*" | tee -a "${REPORT}"
  echo "------------------------------------------------------------" | tee -a "${REPORT}"
}

count_unique_nodes_for_selector() {
  local selector="$1"
  ${KC} get pods -n "${NAMESPACE}" -l "${selector}" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | sed '/^$/d' | sort -u | wc -l | tr -d ' '
}

count_ready_pods_for_selector() {
  local selector="$1"
  ${KC} get pods -n "${NAMESPACE}" -l "${selector}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    | awk '$2=="Running" && $3=="True" {count++} END {print count+0}'
}

count_total_pods_for_selector() {
  local selector="$1"
  ${KC} get pods -n "${NAMESPACE}" -l "${selector}" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

section "HA SSO preflight check"
echo "Timestamp: ${TS}" | tee -a "${REPORT}"
echo "Namespace: ${NAMESPACE}" | tee -a "${REPORT}"
echo "Expected nodes: ${EXPECTED_NODES}" | tee -a "${REPORT}"
echo "Expected Keycloak pods: ${EXPECTED_KEYCLOAK_PODS}" | tee -a "${REPORT}"
echo "Expected PostgreSQL pods: ${EXPECTED_POSTGRES_PODS}" | tee -a "${REPORT}"

section "1. Kubernetes nodes"

${KC} get nodes -o wide | tee -a "${REPORT}"

READY_NODES="$(${KC} get nodes --no-headers | awk '$2=="Ready" {count++} END {print count+0}')"
TOTAL_NODES="$(${KC} get nodes --no-headers | wc -l | tr -d ' ')"

info "Ready nodes: ${READY_NODES}/${TOTAL_NODES}"

[[ "${TOTAL_NODES}" -ge "${EXPECTED_NODES}" ]] || fail "Expected at least ${EXPECTED_NODES} nodes, found ${TOTAL_NODES}."
[[ "${READY_NODES}" -ge "${EXPECTED_NODES}" ]] || fail "Expected at least ${EXPECTED_NODES} Ready nodes, found ${READY_NODES}."

section "2. Namespace resources"

${KC} get all -n "${NAMESPACE}" | tee -a "${REPORT}"

BAD_PODS="$(${KC} get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | awk '$3 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|CreateContainerConfigError|CreateContainerError|Pending/ {print $1 ":" $3}' \
  | paste -sd ',' - || true)"

if [[ -n "${BAD_PODS}" ]]; then
  fail "Found problematic pods in namespace ${NAMESPACE}: ${BAD_PODS}"
fi

info "No Pending/CrashLoopBackOff/ImagePullBackOff/Error pods found."

section "3. PostgreSQL cluster state"

${KC} get cluster keycloak-postgres -n "${NAMESPACE}" | tee -a "${REPORT}"
${KC} get pods -n "${NAMESPACE}" -l "${POSTGRES_LABEL}" -L role -o wide | tee -a "${REPORT}"

PG_PHASE="$(${KC} get cluster keycloak-postgres -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
PG_READY="$(${KC} get cluster keycloak-postgres -n "${NAMESPACE}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")"

info "CNPG phase: ${PG_PHASE}"
info "CNPG ready instances: ${PG_READY}/${EXPECTED_POSTGRES_PODS}"

[[ "${PG_PHASE}" == "Cluster in healthy state" ]] || fail "CNPG cluster is not healthy. Current phase: '${PG_PHASE}'."
[[ "${PG_READY}" == "${EXPECTED_POSTGRES_PODS}" ]] || fail "Expected ${EXPECTED_POSTGRES_PODS} ready PostgreSQL instances, found ${PG_READY}."

PG_TOTAL_PODS="$(count_total_pods_for_selector "${POSTGRES_LABEL}")"
PG_READY_PODS="$(count_ready_pods_for_selector "${POSTGRES_LABEL}")"
PG_UNIQUE_NODES="$(count_unique_nodes_for_selector "${POSTGRES_LABEL}")"

info "PostgreSQL pods: total=${PG_TOTAL_PODS}, ready=${PG_READY_PODS}, unique_nodes=${PG_UNIQUE_NODES}"

[[ "${PG_TOTAL_PODS}" == "${EXPECTED_POSTGRES_PODS}" ]] || fail "Expected ${EXPECTED_POSTGRES_PODS} PostgreSQL pods, found ${PG_TOTAL_PODS}."
[[ "${PG_READY_PODS}" == "${EXPECTED_POSTGRES_PODS}" ]] || fail "Expected ${EXPECTED_POSTGRES_PODS} Ready PostgreSQL pods, found ${PG_READY_PODS}."
[[ "${PG_UNIQUE_NODES}" == "${EXPECTED_POSTGRES_PODS}" ]] || fail "PostgreSQL pods are not spread across ${EXPECTED_POSTGRES_PODS} different nodes."

PRIMARY_COUNT="$(${KC} get pods -n "${NAMESPACE}" -l "${POSTGRES_LABEL}" -L role --no-headers \
  | awk '$NF=="primary" {count++} END {print count+0}')"

[[ "${PRIMARY_COUNT}" == "1" ]] || fail "Expected exactly one PostgreSQL primary instance, found ${PRIMARY_COUNT}."

PRIMARY_POD="$(${KC} get pods -n "${NAMESPACE}" -l "${POSTGRES_LABEL}" -L role --no-headers \
  | awk '$NF=="primary" {print $1; exit}')"

info "Current PostgreSQL primary: ${PRIMARY_POD}"

section "4. Keycloak cluster state"

${KC} get keycloak keycloak-unibl -n "${NAMESPACE}" | tee -a "${REPORT}" || fail "Keycloak CR not found."
${KC} get pods -n "${NAMESPACE}" -l "${KEYCLOAK_LABEL}" -o wide | tee -a "${REPORT}"

KC_READY_CONDITION="$(${KC} get keycloak keycloak-unibl -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"

KC_TOTAL_PODS="$(count_total_pods_for_selector "${KEYCLOAK_LABEL}")"
KC_READY_PODS="$(count_ready_pods_for_selector "${KEYCLOAK_LABEL}")"
KC_UNIQUE_NODES="$(count_unique_nodes_for_selector "${KEYCLOAK_LABEL}")"

info "Keycloak Ready condition: ${KC_READY_CONDITION:-<empty>}"
info "Keycloak pods: total=${KC_TOTAL_PODS}, ready=${KC_READY_PODS}, unique_nodes=${KC_UNIQUE_NODES}"

[[ "${KC_READY_CONDITION}" == "True" ]] || fail "Keycloak CR is not Ready."
[[ "${KC_TOTAL_PODS}" == "${EXPECTED_KEYCLOAK_PODS}" ]] || fail "Expected ${EXPECTED_KEYCLOAK_PODS} Keycloak pods, found ${KC_TOTAL_PODS}."
[[ "${KC_READY_PODS}" == "${EXPECTED_KEYCLOAK_PODS}" ]] || fail "Expected ${EXPECTED_KEYCLOAK_PODS} Ready Keycloak pods, found ${KC_READY_PODS}."
[[ "${KC_UNIQUE_NODES}" == "${EXPECTED_KEYCLOAK_PODS}" ]] || fail "Keycloak pods are not spread across ${EXPECTED_KEYCLOAK_PODS} different nodes."

section "4a. Keycloak restart stability"

NOW_EPOCH="$(date +%s)"

while read -r POD RESTARTS FINISHED_AT; do
  [[ -n "${POD}" ]] || continue

  echo "Pod=${POD}, restarts=${RESTARTS}, last_terminated=${FINISHED_AT:-none}" | tee -a "${REPORT}"

  if [[ "${RESTARTS}" -gt 0 && -n "${FINISHED_AT}" ]]; then
    FINISHED_EPOCH="$(date -d "${FINISHED_AT}" +%s)"
    AGE_SECONDS="$((NOW_EPOCH - FINISHED_EPOCH))"

    echo "Last restart age for ${POD}: ${AGE_SECONDS}s" | tee -a "${REPORT}"

    if (( AGE_SECONDS < MIN_KEYCLOAK_STABLE_SECONDS )); then
      fail "Keycloak pod ${POD} restarted ${AGE_SECONDS}s ago. Minimum stable period is ${MIN_KEYCLOAK_STABLE_SECONDS}s."
    fi
  fi
done < <(
  ${KC} get pods -n "${NAMESPACE}" -l "${KEYCLOAK_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{" "}{.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}{end}'
)

info "No recent Keycloak restarts detected within the minimum stability window."

section "5. Services and Ingress"

${KC} get svc -n "${NAMESPACE}" | tee -a "${REPORT}"
${KC} get ingress -n "${NAMESPACE}" | tee -a "${REPORT}"

${KC} get svc keycloak-unibl-service -n "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "Service keycloak-unibl-service does not exist."

${KC} get svc keycloak-postgres-rw -n "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "Service keycloak-postgres-rw does not exist."

${KC} get ingress keycloak-ingress -n "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "Ingress keycloak-ingress does not exist."

info "Required services and ingress exist."

section "6. Realm endpoint check"

PROBE_POD="preflight-curl-${TS}"

cat <<EOF_POD | ${KC} apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  namespace: ${NAMESPACE}
  labels:
    app: preflight-curl
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: ${PROBER_IMAGE}
      command: ["sh", "-c"]
      args:
        - |
          curl -sk --connect-timeout 5 --max-time 20 \
            -o /dev/null \
            -w "%{http_code} %{time_total}\n" \
            "${REALM_DISCOVERY_URL_INTERNAL}"
EOF_POD

cleanup_probe() {
  ${KC} delete pod "${PROBE_POD}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT

PHASE=""
for i in $(seq 1 60); do
  PHASE="$(${KC} get pod "${PROBE_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"

  if [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]]; then
    break
  fi

  sleep 1
done

if [[ "${PHASE}" != "Succeeded" && "${PHASE}" != "Failed" ]]; then
  ${KC} describe pod "${PROBE_POD}" -n "${NAMESPACE}" | tee -a "${REPORT}" >&2 || true
  fail "Preflight curl pod did not finish in time. Current phase: ${PHASE:-unknown}."
fi

PROBE_LOG="$(${KC} logs "${PROBE_POD}" -n "${NAMESPACE}" 2>/dev/null || true)"
echo "Realm discovery check result: ${PROBE_LOG}" | tee -a "${REPORT}"

HTTP_CODE="$(echo "${PROBE_LOG}" | awk '{print $1}' | tail -1)"
[[ "${HTTP_CODE}" == "200" ]] || fail "Realm discovery endpoint did not return HTTP 200. Got: '${PROBE_LOG}'."

info "Realm discovery endpoint returned HTTP 200."

section "7. PVC and storage snapshot"

${KC} get pvc -n "${NAMESPACE}" | tee -a "${REPORT}"

section "Preflight result"

echo "Preflight PASSED." | tee -a "${REPORT}"
echo "Report saved to: ${REPORT}" | tee -a "${REPORT}"
echo ""
echo "OK: The cluster is ready for failover testing."