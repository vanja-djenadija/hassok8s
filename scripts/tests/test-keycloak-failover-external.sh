#!/usr/bin/env bash
set -euo pipefail

KC="${KC:-kubectl}"

NS="${NAMESPACE:-keycloak}"
KEYCLOAK_LABEL="${KEYCLOAK_LABEL:-app=keycloak}"
KEYCLOAK_NAME="${KEYCLOAK_NAME:-keycloak-unibl}"
REALM="${REALM_NAME:-unibl}"

PROBE_URL="${PROBE_URL:-https://auth.etfbl.net/realms/${REALM}/.well-known/openid-configuration}"

BASELINE_SECONDS="${BASELINE_SECONDS:-20}"
AFTER_SECONDS="${AFTER_SECONDS:-90}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-15}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-600}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-/home/vanja/hassok8s/logs/tests/keycloak-failover-external-${RUN_ID}}"
mkdir -p "${OUT_DIR}"

REQUESTS_CSV="${OUT_DIR}/requests.csv"
SUMMARY_TXT="${OUT_DIR}/summary.txt"
PHASE_FILE="${OUT_DIR}/phase.txt"
STOP_FILE="${OUT_DIR}/stop-prober"

log() {
  echo "[$(date +%H:%M:%S)] $*" | tee -a "${SUMMARY_TXT}"
}

epoch_ms() {
  echo "$(($(date +%s) * 1000))"
}

probe_loop() {
  echo "timestamp,epoch_ms,http_code,time_total_s,result,phase,error" > "${REQUESTS_CSV}"

  while [[ ! -f "${STOP_FILE}" ]]; do
    PHASE="$(cat "${PHASE_FILE}")"
    TS_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    EPOCH_MS="$(epoch_ms)"

    set +e
    OUT="$(
      curl -sk --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" \
        -o /dev/null \
        -w "%{http_code};%{time_total}" \
        "${PROBE_URL}" 2>&1
    )"
    RC=$?
    set -e

    if [[ "${RC}" == "0" ]]; then
      HTTP_CODE="$(echo "${OUT}" | cut -d';' -f1)"
      TIME_TOTAL="$(echo "${OUT}" | cut -d';' -f2)"

      if [[ "${HTTP_CODE}" == "200" ]]; then
        echo "${TS_UTC},${EPOCH_MS},${HTTP_CODE},${TIME_TOTAL},OK,${PHASE}," >> "${REQUESTS_CSV}"
      else
        echo "${TS_UTC},${EPOCH_MS},${HTTP_CODE},${TIME_TOTAL},FAIL,${PHASE},http_${HTTP_CODE}" >> "${REQUESTS_CSV}"
      fi
    else
      SAFE_ERR="$(echo "${OUT}" | tr ',' ';' | tr '\n' ' ' | cut -c1-180)"
      echo "${TS_UTC},${EPOCH_MS},000,0,FAIL,${PHASE},curl_error_${RC}:${SAFE_ERR}" >> "${REQUESTS_CSV}"
    fi

    sleep "${INTERVAL_SECONDS}"
  done
}

cleanup() {
  touch "${STOP_FILE}" 2>/dev/null || true
  if [[ -n "${PROBER_PID:-}" ]]; then
    wait "${PROBER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "Output directory: ${OUT_DIR}"
log "Probe URL: ${PROBE_URL}"
log "Using kubectl command: ${KC}"

log "Running preflight..."
KC="${KC}" ./scripts/tests/preflight-ha.sh | tee -a "${SUMMARY_TXT}"

log "Capturing Keycloak pod placement before test..."
${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" -o wide | tee "${OUT_DIR}/pods-before.txt" | tee -a "${SUMMARY_TXT}"

if [[ -n "${VICTIM_POD:-}" ]]; then
  log "Using manually selected victim pod: ${VICTIM_POD}"

  if ! ${KC} get pod "${VICTIM_POD}" -n "${NS}" >/dev/null 2>&1; then
    log "ERROR: Manually selected victim pod does not exist: ${VICTIM_POD}"
    exit 1
  fi

  VICTIM_READY="$(${KC} get pod "${VICTIM_POD}" -n "${NS}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  if [[ "${VICTIM_READY}" != "true" ]]; then
    log "ERROR: Manually selected victim pod is not Ready: ${VICTIM_POD}"
    exit 1
  fi
else
  VICTIM_POD="$(
    ${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    | sort -k2,2n | head -1 | awk '{print $1}'
  )"

  log "Automatically selected victim pod: ${VICTIM_POD}"
fi

VICTIM_NODE="$(${KC} get pod "${VICTIM_POD}" -n "${NS}" -o jsonpath='{.spec.nodeName}')"
VICTIM_UID_BEFORE="$(${KC} get pod "${VICTIM_POD}" -n "${NS}" -o jsonpath='{.metadata.uid}')"

log "Victim pod: ${VICTIM_POD}"
log "Victim node: ${VICTIM_NODE}"
log "Victim UID before: ${VICTIM_UID_BEFORE}"

echo "before" > "${PHASE_FILE}"

log "Starting external probe loop..."
probe_loop &
PROBER_PID=$!

log "Baseline period: ${BASELINE_SECONDS}s"
sleep "${BASELINE_SECONDS}"

BASELINE_FAILS="$(awk -F',' '$6=="before" && $5=="FAIL"{c++} END{print c+0}' "${REQUESTS_CSV}")"

if [[ "${BASELINE_FAILS}" != "0" ]]; then
  log "ERROR: Baseline contains failed requests. Run is not valid."
  echo "run_valid=false" >> "${SUMMARY_TXT}"
  echo "invalid_reason=baseline_failed_requests" >> "${SUMMARY_TXT}"
  exit 1
fi

log "Baseline OK. Injecting failure: deleting pod ${VICTIM_POD}"
echo "after" > "${PHASE_FILE}"

INJECTION_EPOCH_MS="$(epoch_ms)"
INJECTION_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

${KC} delete pod "${VICTIM_POD}" -n "${NS}" --wait=false

log "Waiting for Keycloak recovery, timeout ${RECOVERY_TIMEOUT_SECONDS}s..."

RECOVERY_START="$(date +%s)"
RECOVERED="false"
POD_RECOVERY_S="NA"

while true; do
  NOW="$(date +%s)"
  ELAPSED="$((NOW - RECOVERY_START))"

  if (( ELAPSED > RECOVERY_TIMEOUT_SECONDS )); then
    log "ERROR: Recovery timeout."
    break
  fi

  TOTAL="$(${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  READY="$(${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" --no-headers 2>/dev/null | awk '$2=="1/1"{c++} END{print c+0}')"

  NEW_UID="$(${KC} get pod "${VICTIM_POD}" -n "${NS}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  VICTIM_READY="$(${KC} get pod "${VICTIM_POD}" -n "${NS}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  KC_READY="$(${KC} get keycloak "${KEYCLOAK_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"

  if [[ "${TOTAL}" == "3" && "${READY}" == "3" && -n "${NEW_UID}" && "${NEW_UID}" != "${VICTIM_UID_BEFORE}" && "${VICTIM_READY}" == "true" && "${KC_READY}" == "True" ]]; then
    RECOVERED="true"
    RECOVERY_EPOCH_MS="$(epoch_ms)"
    POD_RECOVERY_S="$(awk "BEGIN {printf \"%.3f\", (${RECOVERY_EPOCH_MS}-${INJECTION_EPOCH_MS})/1000}")"
    log "Recovered. pod_recovery_s=${POD_RECOVERY_S}"
    break
  fi

  sleep 1
done

log "Continuing external probe after recovery for ${AFTER_SECONDS}s..."
sleep "${AFTER_SECONDS}"

touch "${STOP_FILE}"
wait "${PROBER_PID}" 2>/dev/null || true
trap - EXIT

${KC} get pods -n "${NS}" -l "${KEYCLOAK_LABEL}" -o wide | tee "${OUT_DIR}/pods-after.txt" | tee -a "${SUMMARY_TXT}"

TOTAL_REQ="$(awk -F',' 'NR>1{c++} END{print c+0}' "${REQUESTS_CSV}")"
SUCCESS_REQ="$(awk -F',' 'NR>1 && $5=="OK"{c++} END{print c+0}' "${REQUESTS_CSV}")"
FAILED_REQ="$(awk -F',' 'NR>1 && $5=="FAIL"{c++} END{print c+0}' "${REQUESTS_CSV}")"
FAILED_AFTER="$(awk -F',' 'NR>1 && $6=="after" && $5=="FAIL"{c++} END{print c+0}' "${REQUESTS_CSV}")"

FIRST_FAIL_AFTER_MS="$(awk -F',' '$6=="after" && $5=="FAIL"{print $2; exit}' "${REQUESTS_CSV}")"
LAST_FAIL_AFTER_MS="$(awk -F',' '$6=="after" && $5=="FAIL"{x=$2} END{print x}' "${REQUESTS_CSV}")"

if [[ -n "${FIRST_FAIL_AFTER_MS:-}" && -n "${LAST_FAIL_AFTER_MS:-}" ]]; then
  SERVICE_DOWNTIME_S="$(awk "BEGIN {printf \"%.3f\", (${LAST_FAIL_AFTER_MS}-${FIRST_FAIL_AFTER_MS}+(${INTERVAL_SECONDS}*1000))/1000}")"
else
  SERVICE_DOWNTIME_S="0.000"
fi

AVAILABILITY="$(awk "BEGIN {if (${TOTAL_REQ}>0) printf \"%.3f\", (${SUCCESS_REQ}/${TOTAL_REQ})*100; else print \"0.000\"}")"

RUN_VALID="true"
INVALID_REASON="none"

if [[ "${RECOVERED}" != "true" ]]; then
  RUN_VALID="false"
  INVALID_REASON="recovery_timeout"
fi

{
  echo ""
  echo "================ SUMMARY ================"
  echo "test_type=keycloak_failover_external"
  echo "probe_url=${PROBE_URL}"
  echo "victim_pod=${VICTIM_POD}"
  echo "victim_node=${VICTIM_NODE}"
  echo "injection_ts=${INJECTION_TS}"
  echo "total_requests=${TOTAL_REQ}"
  echo "successful_requests=${SUCCESS_REQ}"
  echo "failed_requests=${FAILED_REQ}"
  echo "failed_requests_after_injection=${FAILED_AFTER}"
  echo "availability_percent=${AVAILABILITY}"
  echo "service_downtime_s=${SERVICE_DOWNTIME_S}"
  echo "pod_recovery_s=${POD_RECOVERY_S}"
  echo "run_valid=${RUN_VALID}"
  echo "invalid_reason=${INVALID_REASON}"
  echo "requests_csv=${REQUESTS_CSV}"
  echo "summary_txt=${SUMMARY_TXT}"
  echo "========================================="
} | tee -a "${SUMMARY_TXT}"

log "Done."