#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${ROOT_DIR}/config.env"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

KC="${KC:-kubectl}"

NS="${NAMESPACE:-keycloak}"
PG_CLUSTER="${PG_CLUSTER:-keycloak-postgres}"
PG_INSTANCES="${PG_INSTANCES:-3}"
POSTGRES_LABEL="${POSTGRES_LABEL:-cnpg.io/cluster=${PG_CLUSTER}}"

TOKEN_URL="${TOKEN_URL:-https://auth.etfbl.net/realms/unibl/protocol/openid-connect/token}"
CLIENT_ID="${CLIENT_ID:?CLIENT_ID is required}"
TEST_USERNAME="${TEST_USERNAME:?TEST_USERNAME is required}"
TEST_PASSWORD="${TEST_PASSWORD:?TEST_PASSWORD is required}"
CLIENT_SECRET="${CLIENT_SECRET:-}"

AUTH_INTERVAL_SECONDS="${AUTH_INTERVAL_SECONDS:-1}"
BASELINE_SECONDS="${BASELINE_SECONDS:-20}"
POST_RECOVERY_SECONDS="${POST_RECOVERY_SECONDS:-60}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-600}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/logs/tests/keycloak-token-pg-failover-${RUN_ID}"
mkdir -p "${OUT_DIR}"

REQUESTS_CSV="${OUT_DIR}/token-requests.csv"
EVENTS_CSV="${OUT_DIR}/events.csv"
SUMMARY_CSV="${OUT_DIR}/summary.csv"

echo "timestamp,epoch_ms,duration_ms,http_code,result,phase,error" > "${REQUESTS_CSV}"
echo "timestamp,event,details" > "${EVENTS_CSV}"

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

event() {
  local name="$1"
  local details="${2:-}"
  echo "$(date --iso-8601=seconds),${name},${details}" >> "${EVENTS_CSV}"
}

token_probe() {
  local phase="$1"
  local ts epoch start end duration body_file http_code result error

  ts="$(date --iso-8601=seconds)"
  epoch="$(date +%s%3N)"
  start="$(date +%s%3N)"
  body_file="$(mktemp)"

  if [[ -n "${CLIENT_SECRET}" ]]; then
    http_code="$(curl -sk -o "${body_file}" -w "%{http_code}" \
      -X POST "${TOKEN_URL}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "client_secret=${CLIENT_SECRET}" \
      --data-urlencode "username=${TEST_USERNAME}" \
      --data-urlencode "password=${TEST_PASSWORD}" 2>/dev/null || echo "000")"
  else
    http_code="$(curl -sk -o "${body_file}" -w "%{http_code}" \
      -X POST "${TOKEN_URL}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "username=${TEST_USERNAME}" \
      --data-urlencode "password=${TEST_PASSWORD}" 2>/dev/null || echo "000")"
  fi

  end="$(date +%s%3N)"
  duration=$((end - start))

  if [[ "${http_code}" == "200" ]] && grep -q '"access_token"' "${body_file}"; then
    result="OK"
    error=""
  else
    result="FAIL"
    error="$(cat "${body_file}" | tr ',' ';' | tr '\n' ' ' | cut -c1-300)"
  fi

  rm -f "${body_file}"

  echo "${ts},${epoch},${duration},${http_code},${result},${phase},${error}" >> "${REQUESTS_CSV}"
}

fail() {
  log "ERROR: $*" >&2
  event "test_failed" "$*"
  exit 1
}

log "Output directory: ${OUT_DIR}"
log "Token URL: ${TOKEN_URL}"
log "Client ID: ${CLIENT_ID}"
log "Test username: ${TEST_USERNAME}"

log "Running preflight check..."
KC="${KC}" "${SCRIPT_DIR}/preflight-ha.sh" | tee "${OUT_DIR}/preflight.txt"
event "preflight_passed" ""

log "Capturing initial PostgreSQL state..."
${KC} get cluster "${PG_CLUSTER}" -n "${NS}" | tee "${OUT_DIR}/initial-pg-cluster.txt"
${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role -o wide | tee "${OUT_DIR}/initial-pg-pods.txt"

PRIMARY_POD="$(${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role --no-headers \
  | awk '$NF=="primary" {print $1; exit}')"

[[ -n "${PRIMARY_POD}" ]] || fail "Could not determine current PostgreSQL primary pod."

PRIMARY_NODE="$(${KC} get pod "${PRIMARY_POD}" -n "${NS}" -o jsonpath='{.spec.nodeName}')"

log "Initial primary pod: ${PRIMARY_POD}"
log "Initial primary node: ${PRIMARY_NODE}"
event "initial_primary_detected" "pod=${PRIMARY_POD};node=${PRIMARY_NODE}"

PG_PHASE="$(${KC} get cluster "${PG_CLUSTER}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
PG_READY="$(${KC} get cluster "${PG_CLUSTER}" -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")"

[[ "${PG_PHASE}" == "Cluster in healthy state" ]] || fail "CNPG cluster is not healthy before test. Phase: ${PG_PHASE}"
[[ "${PG_READY}" == "${PG_INSTANCES}" ]] || fail "Expected ${PG_INSTANCES} ready PostgreSQL instances, found ${PG_READY}."

log "Baseline token period: ${BASELINE_SECONDS}s"
event "baseline_started" "seconds=${BASELINE_SECONDS}"

baseline_end=$((SECONDS + BASELINE_SECONDS))
while (( SECONDS < baseline_end )); do
  token_probe "before"
  sleep "${AUTH_INTERVAL_SECONDS}"
done

BASELINE_TOTAL="$(awk -F',' 'NR>1 && $6=="before" {c++} END{print c+0}' "${REQUESTS_CSV}")"
BASELINE_FAILS="$(awk -F',' 'NR>1 && $6=="before" && $5=="FAIL" {c++} END{print c+0}' "${REQUESTS_CSV}")"

event "baseline_finished" "total=${BASELINE_TOTAL};fails=${BASELINE_FAILS}"

if (( BASELINE_TOTAL == 0 )); then
  fail "No baseline token samples collected."
fi

if (( BASELINE_FAILS > 0 )); then
  fail "Baseline contains failed token requests. Test is not valid."
fi

log "Injecting PostgreSQL primary failure: deleting ${PRIMARY_POD}"
INJECTION_EPOCH_MS="$(date +%s%3N)"
INJECTION_TS="$(date --iso-8601=seconds)"
event "failure_injected" "deleted_primary=${PRIMARY_POD};node=${PRIMARY_NODE}"

${KC} delete pod "${PRIMARY_POD}" -n "${NS}" --wait=false >/dev/null

NEW_PRIMARY_POD=""
NEW_PRIMARY_NODE=""
FAILOVER_DETECTED_EPOCH_MS=""
CLUSTER_RECOVERY_EPOCH_MS=""
RECOVERY_OK="false"

log "Running token probes during PostgreSQL failover..."

while true; do
  token_probe "during"

  CURRENT_PRIMARY="$(${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role --no-headers 2>/dev/null \
    | awk '$NF=="primary" {print $1; exit}' || true)"

  if [[ -n "${CURRENT_PRIMARY}" && "${CURRENT_PRIMARY}" != "${PRIMARY_POD}" && -z "${NEW_PRIMARY_POD}" ]]; then
    NEW_PRIMARY_POD="${CURRENT_PRIMARY}"
    NEW_PRIMARY_NODE="$(${KC} get pod "${NEW_PRIMARY_POD}" -n "${NS}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")"
    FAILOVER_DETECTED_EPOCH_MS="$(date +%s%3N)"
    event "new_primary_detected" "pod=${NEW_PRIMARY_POD};node=${NEW_PRIMARY_NODE}"
    log "New primary detected: ${NEW_PRIMARY_POD} on ${NEW_PRIMARY_NODE}"
  fi

  PG_PHASE_NOW="$(${KC} get cluster "${PG_CLUSTER}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  PG_READY_NOW="$(${KC} get cluster "${PG_CLUSTER}" -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")"

  if [[ -n "${NEW_PRIMARY_POD}" && "${PG_PHASE_NOW}" == "Cluster in healthy state" && "${PG_READY_NOW}" == "${PG_INSTANCES}" ]]; then
    CLUSTER_RECOVERY_EPOCH_MS="$(date +%s%3N)"
    RECOVERY_OK="true"
    break
  fi

  elapsed_s=$(( ( $(date +%s%3N) - INJECTION_EPOCH_MS ) / 1000 ))
  if (( elapsed_s > RECOVERY_TIMEOUT_SECONDS )); then
    break
  fi

  sleep "${AUTH_INTERVAL_SECONDS}"
done

if [[ "${RECOVERY_OK}" == "true" ]]; then
  CLUSTER_FULL_RECOVERY_S="$(awk -v a="${INJECTION_EPOCH_MS}" -v b="${CLUSTER_RECOVERY_EPOCH_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
  log "CNPG cluster recovered after ${CLUSTER_FULL_RECOVERY_S}s."
  event "cluster_recovery_completed" "seconds=${CLUSTER_FULL_RECOVERY_S}"
else
  CLUSTER_FULL_RECOVERY_S="n/a"
  event "cluster_recovery_timeout" "timeout_seconds=${RECOVERY_TIMEOUT_SECONDS}"
fi

log "Post-recovery token observation: ${POST_RECOVERY_SECONDS}s"
event "post_recovery_observation_started" "seconds=${POST_RECOVERY_SECONDS}"

post_end=$((SECONDS + POST_RECOVERY_SECONDS))
while (( SECONDS < post_end )); do
  token_probe "after"
  sleep "${AUTH_INTERVAL_SECONDS}"
done

event "post_recovery_observation_finished" ""

log "Capturing final PostgreSQL state..."
${KC} get cluster "${PG_CLUSTER}" -n "${NS}" | tee "${OUT_DIR}/final-pg-cluster.txt"
${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role -o wide | tee "${OUT_DIR}/final-pg-pods.txt"

TOTAL_REQUESTS="$(awk -F',' 'NR>1 {c++} END{print c+0}' "${REQUESTS_CSV}")"
SUCCESSFUL_REQUESTS="$(awk -F',' 'NR>1 && $5=="OK" {c++} END{print c+0}' "${REQUESTS_CSV}")"
FAILED_REQUESTS="$(awk -F',' 'NR>1 && $5=="FAIL" {c++} END{print c+0}' "${REQUESTS_CSV}")"
FAILED_AFTER_INJECTION="$(awk -F',' -v inj="${INJECTION_EPOCH_MS}" 'NR>1 && $2>=inj && $5=="FAIL" {c++} END{print c+0}' "${REQUESTS_CSV}")"
AFTER_FAILS="$(awk -F',' 'NR>1 && $6=="after" && $5=="FAIL" {c++} END{print c+0}' "${REQUESTS_CSV}")"

AVAILABILITY_PERCENT="$(awk -v s="${SUCCESSFUL_REQUESTS}" -v t="${TOTAL_REQUESTS}" 'BEGIN{if(t>0) printf "%.3f", (s/t)*100; else printf "0.000"}')"

FIRST_FAIL_AFTER_INJECTION_MS="$(awk -F',' -v inj="${INJECTION_EPOCH_MS}" '
  NR>1 && $2>=inj && $5=="FAIL" {print $2; exit}
' "${REQUESTS_CSV}")"

if [[ -n "${FIRST_FAIL_AFTER_INJECTION_MS}" ]]; then
  LAST_OK_BEFORE_FAIL_MS="$(awk -F',' -v firstfail="${FIRST_FAIL_AFTER_INJECTION_MS}" '
    NR>1 && $2<firstfail && $5=="OK" {last=$2}
    END {print last}
  ' "${REQUESTS_CSV}")"

  FIRST_OK_AFTER_FAIL_MS="$(awk -F',' -v firstfail="${FIRST_FAIL_AFTER_INJECTION_MS}" '
    NR>1 && $2>firstfail && $5=="OK" {print $2; exit}
  ' "${REQUESTS_CSV}")"

  if [[ -n "${LAST_OK_BEFORE_FAIL_MS}" && -n "${FIRST_OK_AFTER_FAIL_MS}" ]]; then
    TOKEN_AUTH_DOWNTIME_S="$(awk -v a="${LAST_OK_BEFORE_FAIL_MS}" -v b="${FIRST_OK_AFTER_FAIL_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
  else
    TOKEN_AUTH_DOWNTIME_S="n/a"
  fi
else
  TOKEN_AUTH_DOWNTIME_S="0.000"
fi

if [[ -n "${FAILOVER_DETECTED_EPOCH_MS}" ]]; then
  FAILOVER_DETECTED_S="$(awk -v a="${INJECTION_EPOCH_MS}" -v b="${FAILOVER_DETECTED_EPOCH_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
else
  FAILOVER_DETECTED_S="n/a"
fi

RUN_VALID="true"
INVALID_REASON="none"

append_invalid() {
  local reason="$1"
  if [[ "${INVALID_REASON}" == "none" ]]; then
    INVALID_REASON="${reason}"
  else
    INVALID_REASON="${INVALID_REASON};${reason}"
  fi
  RUN_VALID="false"
}

if [[ "${RECOVERY_OK}" != "true" ]]; then
  append_invalid "cluster_recovery_timeout"
fi

if (( BASELINE_FAILS > 0 )); then
  append_invalid "baseline_token_failures"
fi

if (( AFTER_FAILS > 0 )); then
  append_invalid "post_recovery_token_failures"
fi

if [[ "${TOKEN_AUTH_DOWNTIME_S}" == "n/a" ]]; then
  append_invalid "token_downtime_not_measurable"
fi

{
  echo "metric,value"
  echo "run_id,${RUN_ID}"
  echo "test,keycloak_token_auth_during_postgres_failover"
  echo "token_url,${TOKEN_URL}"
  echo "client_id,${CLIENT_ID}"
  echo "test_username,${TEST_USERNAME}"
  echo "initial_primary_pod,${PRIMARY_POD}"
  echo "initial_primary_node,${PRIMARY_NODE}"
  echo "new_primary_pod,${NEW_PRIMARY_POD:-n/a}"
  echo "new_primary_node,${NEW_PRIMARY_NODE:-n/a}"
  echo "injection_ts,${INJECTION_TS}"
  echo "total_token_requests,${TOTAL_REQUESTS}"
  echo "successful_token_requests,${SUCCESSFUL_REQUESTS}"
  echo "failed_token_requests,${FAILED_REQUESTS}"
  echo "failed_token_requests_after_injection,${FAILED_AFTER_INJECTION}"
  echo "availability_percent,${AVAILABILITY_PERCENT}"
  echo "token_auth_downtime_s,${TOKEN_AUTH_DOWNTIME_S}"
  echo "failover_detected_s,${FAILOVER_DETECTED_S}"
  echo "cluster_full_recovery_s,${CLUSTER_FULL_RECOVERY_S}"
  echo "run_valid,${RUN_VALID}"
  echo "invalid_reason,${INVALID_REASON}"
} > "${SUMMARY_CSV}"

echo
echo "============================================================"
echo " KEYCLOAK TOKEN AUTH DURING POSTGRESQL FAILOVER FINISHED"
echo "============================================================"
echo "Run ID:                              ${RUN_ID}"
echo "Output directory:                    ${OUT_DIR}"
echo "Initial primary pod:                 ${PRIMARY_POD}"
echo "Initial primary node:                ${PRIMARY_NODE}"
echo "New primary pod:                     ${NEW_PRIMARY_POD:-n/a}"
echo "New primary node:                    ${NEW_PRIMARY_NODE:-n/a}"
echo "Total token requests:                ${TOTAL_REQUESTS}"
echo "Successful token requests:           ${SUCCESSFUL_REQUESTS}"
echo "Failed token requests:               ${FAILED_REQUESTS}"
echo "Failed token requests after failure: ${FAILED_AFTER_INJECTION}"
echo "Availability:                        ${AVAILABILITY_PERCENT}%"
echo "Token auth downtime:                 ${TOKEN_AUTH_DOWNTIME_S}s"
echo "Failover detected:                   ${FAILOVER_DETECTED_S}s"
echo "Cluster full recovery:               ${CLUSTER_FULL_RECOVERY_S}s"
echo "Run valid:                           ${RUN_VALID}"
echo "Invalid reason:                      ${INVALID_REASON}"
echo "============================================================"
echo
echo "Generated files:"
echo "  ${REQUESTS_CSV}"
echo "  ${EVENTS_CSV}"
echo "  ${SUMMARY_CSV}"
echo

if [[ "${RUN_VALID}" != "true" ]]; then
  exit 2
fi