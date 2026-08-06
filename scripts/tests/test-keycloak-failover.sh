#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# Keycloak failover test
#
# This test verifies whether the Keycloak identity service remains
# available when one Keycloak pod is deleted.
#
# The test measures service availability through the OIDC discovery
# endpoint of the configured realm.
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

NS="${NAMESPACE:-keycloak}"
REALM="${REALM_NAME:-unibl}"
SERVICE_NAME="${KEYCLOAK_SERVICE_NAME:-keycloak-unibl-service}"

PROBER_IMAGE="${PROBER_IMAGE:-curlimages/curl:8.10.1}"
PROBE_INTERVAL="${KEYCLOAK_PROBE_INTERVAL:-1}"
BASELINE_SECONDS="${BASELINE_SECONDS:-20}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-600}"
POST_RECOVERY_SECONDS="${POST_RECOVERY_SECONDS:-20}"

KEYCLOAK_LABEL="${KEYCLOAK_LABEL:-app=keycloak,app.kubernetes.io/managed-by=keycloak-operator}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/logs/tests/keycloak-failover-${RUN_ID}"
mkdir -p "${OUT_DIR}"

REQUESTS_CSV="${OUT_DIR}/requests.csv"
EVENTS_CSV="${OUT_DIR}/events.csv"
SUMMARY_CSV="${OUT_DIR}/summary.csv"

INTERNAL_URL="https://${SERVICE_NAME}.${NS}.svc.cluster.local:8443/realms/${REALM}/.well-known/openid-configuration"

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

event() {
  local name="$1"
  local details="${2:-}"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),${name},${details}" | tee -a "${EVENTS_CSV}" >/dev/null
}

fail() {
  log "ERROR: $*" >&2
  event "test_failed" "$*"
  exit 1
}

cleanup() {
  if [[ -n "${PROBER_POD:-}" ]]; then
    ${KC} delete pod "${PROBER_POD}" -n "${NS}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "timestamp,epoch_ms,http_code,time_total_s,result,phase,error" > "${REQUESTS_CSV}"
echo "timestamp,event,details" > "${EVENTS_CSV}"

event "test_started" "run_id=${RUN_ID}"

log "Output directory: ${OUT_DIR}"
log "Internal probe URL: ${INTERNAL_URL}"

log "Running preflight check..."
if [[ -x "${SCRIPT_DIR}/preflight-ha.sh" ]]; then
  "${SCRIPT_DIR}/preflight-ha.sh"
else
  fail "preflight-ha.sh not found or not executable."
fi
event "preflight_passed" ""

log "Capturing initial Keycloak pod placement..."
${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" -o wide | tee "${OUT_DIR}/initial-keycloak-pods.txt"

INITIAL_READY="$(${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2=="Running" && $3=="True" {count++} END {print count+0}')"

EXPECTED_READY="${KEYCLOAK_INSTANCES:-3}"
[[ "${INITIAL_READY}" == "${EXPECTED_READY}" ]] || fail "Expected ${EXPECTED_READY} Ready Keycloak pods, found ${INITIAL_READY}."

VICTIM_POD="${VICTIM_POD:-$(${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2=="Running" && $3=="True" {print $1; exit}')}"

[[ -n "${VICTIM_POD}" ]] || fail "Could not determine victim Keycloak pod."

VICTIM_NODE="$(${KC} get pod "${VICTIM_POD}" -n "${NS}" -o jsonpath='{.spec.nodeName}')"

log "Victim pod: ${VICTIM_POD}"
log "Victim node: ${VICTIM_NODE}"
event "victim_selected" "pod=${VICTIM_POD};node=${VICTIM_NODE}"

PROBER_POD="kc-failover-prober-${RUN_ID}"

log "Starting prober pod: ${PROBER_POD}"

cat <<EOF_POD | ${KC} apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBER_POD}
  namespace: ${NS}
  labels:
    app: keycloak-failover-prober
spec:
  restartPolicy: Never
  containers:
    - name: prober
      image: ${PROBER_IMAGE}
      command: ["sh", "-c"]
      args:
        - |
          PHASE_FILE="/tmp/phase"
          echo "before" > "\${PHASE_FILE}"

          while true; do
            TS=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            EPOCH_MS=\$((\$(date +%s) * 1000))
            PHASE=\$(cat "\${PHASE_FILE}" 2>/dev/null || echo "unknown")

            OUT=\$(curl -sk \
              --connect-timeout 3 \
              --max-time 10 \
              -o /dev/null \
              -w "%{http_code},%{time_total}" \
              "${INTERNAL_URL}" 2>&1)

            RC=\$?

            if [ "\${RC}" -eq 0 ]; then
              HTTP_CODE=\$(echo "\${OUT}" | cut -d',' -f1)
              TIME_TOTAL=\$(echo "\${OUT}" | cut -d',' -f2)

              if [ "\${HTTP_CODE}" = "200" ]; then
                RESULT="OK"
                ERROR=""
              else
                RESULT="FAIL"
                ERROR="unexpected_http_code"
              fi

              echo "\${TS},\${EPOCH_MS},\${HTTP_CODE},\${TIME_TOTAL},\${RESULT},\${PHASE},\${ERROR}"
            else
              SAFE_OUT=\$(echo "\${OUT}" | tr ',' ';' | tr '\n' ' ')
              echo "\${TS},\${EPOCH_MS},000,0,FAIL,\${PHASE},curl_error_\${RC}:\${SAFE_OUT}"
            fi

            sleep ${PROBE_INTERVAL}
          done
EOF_POD

${KC} wait --for=condition=Ready pod/"${PROBER_POD}" -n "${NS}" --timeout=120s >/dev/null \
  || fail "Prober pod did not become Ready."

event "prober_started" "pod=${PROBER_POD}"

collect_logs() {
  ${KC} logs "${PROBER_POD}" -n "${NS}" 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
    > "${OUT_DIR}/prober-current.log" || true

  {
    head -1 "${REQUESTS_CSV}"
    cat "${OUT_DIR}/prober-current.log"
  } > "${REQUESTS_CSV}.tmp"

  awk '!seen[$0]++' "${REQUESTS_CSV}.tmp" > "${REQUESTS_CSV}"
}

set_probe_phase() {
  local phase="$1"
  ${KC} exec "${PROBER_POD}" -n "${NS}" -- sh -c "echo '${phase}' > /tmp/phase" >/dev/null 2>&1 || true
}

log "Baseline period: ${BASELINE_SECONDS}s"
event "baseline_started" "seconds=${BASELINE_SECONDS}"

sleep "${BASELINE_SECONDS}"
collect_logs

BASELINE_FAILS="$(awk -F',' 'NR>1 && $6=="before" && $5=="FAIL" {count++} END {print count+0}' "${REQUESTS_CSV}")"
BASELINE_TOTAL="$(awk -F',' 'NR>1 && $6=="before" {count++} END {print count+0}' "${REQUESTS_CSV}")"

event "baseline_finished" "total=${BASELINE_TOTAL};fails=${BASELINE_FAILS}"

if (( BASELINE_TOTAL == 0 )); then
  ${KC} logs "${PROBER_POD}" -n "${NS}" --tail=50 || true
  fail "No baseline probe samples collected."
fi

if (( BASELINE_FAILS > 0 )); then
  fail "Baseline contains failed requests. The run is not valid."
fi

log "Injecting failure: deleting pod ${VICTIM_POD}"
set_probe_phase "during"

INJECTION_EPOCH_MS="$(($(date +%s) * 1000))"
event "failure_injected" "deleted_pod=${VICTIM_POD};node=${VICTIM_NODE}"

${KC} delete pod "${VICTIM_POD}" -n "${NS}" --wait=false >/dev/null

log "Waiting for Keycloak recovery, timeout ${RECOVERY_TIMEOUT_SECONDS}s..."

RECOVERY_START_EPOCH_MS="${INJECTION_EPOCH_MS}"
RECOVERY_END_EPOCH_MS=""
RECOVERY_OK="false"

for _ in $(seq 1 "${RECOVERY_TIMEOUT_SECONDS}"); do
  READY_COUNT="$(${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    | awk '$2=="Running" && $3=="True" {count++} END {print count+0}')"

  if [[ "${READY_COUNT}" == "${EXPECTED_READY}" ]]; then
    RECOVERY_END_EPOCH_MS="$(($(date +%s) * 1000))"
    RECOVERY_OK="true"
    break
  fi

  sleep 1
done

if [[ "${RECOVERY_OK}" == "true" ]]; then
  POD_RECOVERY_S="$(awk -v a="${RECOVERY_START_EPOCH_MS}" -v b="${RECOVERY_END_EPOCH_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
  log "Keycloak recovered: ${READY_COUNT}/${EXPECTED_READY} Ready pods after ${POD_RECOVERY_S}s."
  event "pod_recovery_completed" "seconds=${POD_RECOVERY_S}"
else
  POD_RECOVERY_S="n/a"
  event "pod_recovery_timeout" "timeout_seconds=${RECOVERY_TIMEOUT_SECONDS}"
fi

set_probe_phase "after"
log "Post-recovery observation: ${POST_RECOVERY_SECONDS}s"
event "post_recovery_observation_started" "seconds=${POST_RECOVERY_SECONDS}"

sleep "${POST_RECOVERY_SECONDS}"
collect_logs

event "post_recovery_observation_finished" ""

${KC} delete pod "${PROBER_POD}" -n "${NS}" --ignore-not-found=true >/dev/null 2>&1 || true
PROBER_POD=""

log "Capturing final Keycloak pod placement..."
${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" -o wide | tee "${OUT_DIR}/final-keycloak-pods.txt"

TOTAL_REQUESTS="$(awk -F',' 'NR>1 {count++} END {print count+0}' "${REQUESTS_CSV}")"
SUCCESSFUL_REQUESTS="$(awk -F',' 'NR>1 && $5=="OK" {count++} END {print count+0}' "${REQUESTS_CSV}")"
FAILED_REQUESTS="$(awk -F',' 'NR>1 && $5=="FAIL" {count++} END {print count+0}' "${REQUESTS_CSV}")"

AVAILABILITY_PERCENT="$(awk -v ok="${SUCCESSFUL_REQUESTS}" -v total="${TOTAL_REQUESTS}" 'BEGIN { if (total==0) print "0.000"; else printf "%.3f", (ok/total)*100 }')"

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
    SERVICE_DOWNTIME_S="$(awk -v a="${LAST_OK_BEFORE_FAIL_MS}" -v b="${FIRST_OK_AFTER_FAIL_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
  else
    SERVICE_DOWNTIME_S="n/a"
  fi
else
  SERVICE_DOWNTIME_S="0.000"
fi

AFTER_FAILS="$(awk -F',' 'NR>1 && $6=="after" && $5=="FAIL" {count++} END {print count+0}' "${REQUESTS_CSV}")"

RUN_VALID="true"
INVALID_REASON=""

if [[ "${RECOVERY_OK}" != "true" ]]; then
  RUN_VALID="false"
  INVALID_REASON="${INVALID_REASON}pod_recovery_timeout;"
fi

if (( BASELINE_FAILS > 0 )); then
  RUN_VALID="false"
  INVALID_REASON="${INVALID_REASON}baseline_failures;"
fi

if (( AFTER_FAILS > 0 )); then
  RUN_VALID="false"
  INVALID_REASON="${INVALID_REASON}post_recovery_failures;"
fi

if (( TOTAL_REQUESTS == 0 )); then
  RUN_VALID="false"
  INVALID_REASON="${INVALID_REASON}no_probe_samples;"
fi

{
  echo "metric,value"
  echo "run_id,${RUN_ID}"
  echo "test,keycloak_pod_failover"
  echo "namespace,${NS}"
  echo "realm,${REALM}"
  echo "service_name,${SERVICE_NAME}"
  echo "probe_url,${INTERNAL_URL}"
  echo "victim_pod,${VICTIM_POD}"
  echo "victim_node,${VICTIM_NODE}"
  echo "baseline_seconds,${BASELINE_SECONDS}"
  echo "post_recovery_seconds,${POST_RECOVERY_SECONDS}"
  echo "probe_interval_seconds,${PROBE_INTERVAL}"
  echo "total_requests,${TOTAL_REQUESTS}"
  echo "successful_requests,${SUCCESSFUL_REQUESTS}"
  echo "failed_requests,${FAILED_REQUESTS}"
  echo "availability_percent,${AVAILABILITY_PERCENT}"
  echo "service_downtime_s,${SERVICE_DOWNTIME_S}"
  echo "pod_recovery_s,${POD_RECOVERY_S}"
  echo "baseline_total_requests,${BASELINE_TOTAL}"
  echo "baseline_failed_requests,${BASELINE_FAILS}"
  echo "post_recovery_failed_requests,${AFTER_FAILS}"
  echo "run_valid,${RUN_VALID}"
  echo "invalid_reason,${INVALID_REASON:-none}"
} > "${SUMMARY_CSV}"

event "test_finished" "run_valid=${RUN_VALID};availability=${AVAILABILITY_PERCENT};downtime=${SERVICE_DOWNTIME_S}"

echo ""
echo "============================================================"
echo " KEYCLOAK FAILOVER TEST FINISHED"
echo "============================================================"
echo "Run ID:                  ${RUN_ID}"
echo "Output directory:        ${OUT_DIR}"
echo "Victim pod:              ${VICTIM_POD}"
echo "Victim node:             ${VICTIM_NODE}"
echo "Total requests:          ${TOTAL_REQUESTS}"
echo "Successful requests:     ${SUCCESSFUL_REQUESTS}"
echo "Failed requests:         ${FAILED_REQUESTS}"
echo "Availability:            ${AVAILABILITY_PERCENT}%"
echo "Service downtime:        ${SERVICE_DOWNTIME_S}s"
echo "Pod recovery time:       ${POD_RECOVERY_S}s"
echo "Run valid:               ${RUN_VALID}"
echo "Invalid reason:          ${INVALID_REASON:-none}"
echo "============================================================"
echo ""
echo "Generated files:"
echo "  ${REQUESTS_CSV}"
echo "  ${EVENTS_CSV}"
echo "  ${SUMMARY_CSV}"
echo ""

if [[ "${RUN_VALID}" != "true" ]]; then
  exit 2
fi