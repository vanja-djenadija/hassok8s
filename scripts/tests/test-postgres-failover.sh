#!/usr/bin/env bash
# =============================================================
#  TEST — Primary PostgreSQL pod failure (CloudNativePG failover)
#
#  Primary metric:
#    Client-visible write downtime through the CNPG read-write service,
#    measured as:
#      first successful INSERT that started after failure injection
#      minus
#      last successful INSERT that completed before failure injection
#
#  Methodological safeguards:
#    - each run is isolated by run_id
#    - writer must be stable before failure injection
#    - writer keeps running until recovery is observed or timeout expires
#    - writer is stopped before committed rows are counted
#    - committed rows are counted only for this run_id
#    - run is marked VALID only if measurement and consistency checks pass
#
#  Outputs:
#    logs/tests/pg-failover-<RUN_ID>/
#      writer.raw.log, writes.csv, state.csv, events.csv,
#      summary.csv, summary.txt
#
#  Run on n00 after deployment, while the cluster is healthy.
# =============================================================
set -euo pipefail

# --- Parameters ------------------------------------------------
NS="${NS:-keycloak}"
CLUSTER="${CLUSTER:-keycloak-postgres}"
KC="${KC:-microk8s kubectl}"
WRITER_IMAGE="${WRITER_IMAGE:-postgres:16}"
DB_USER="${DB_USER:-keycloak}"
DB_NAME="${DB_NAME:-keycloak}"
DB_SECRET="${DB_SECRET:-keycloak-db-secret}"
RW_HOST="${RW_HOST:-${CLUSTER}-rw.${NS}.svc.cluster.local}"

MAX_WAIT="${MAX_WAIT:-600}"                 # max wait for client-side recovery, seconds
OBSERVE_AFTER="${OBSERVE_AFTER:-60}"        # observation after first post-failure OK, seconds
WRITER_DURATION="${WRITER_DURATION:-900}"   # hard upper bound for writer lifetime, seconds
PRE_OK_REQUIRED="${PRE_OK_REQUIRED:-10}"    # stable OK writes required before injection
WRITE_INTERVAL="${WRITE_INTERVAL:-1}"       # seconds between attempts
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-2}"     # psql connect_timeout, seconds
PSQL_STATEMENT_TIMEOUT_MS="${PSQL_STATEMENT_TIMEOUT_MS:-3000}"

# --- Output directory -----------------------------------------
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_PATH}"
while [[ "${ROOT_DIR}" != "/" && ! -f "${ROOT_DIR}/config.env" ]]; do
  ROOT_DIR="$(dirname "${ROOT_DIR}")"
done
[[ -f "${ROOT_DIR}/config.env" ]] || ROOT_DIR="$(cd "${SCRIPT_PATH}/../.." && pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT_DIR}/logs/tests/pg-failover-${RUN_ID}"
mkdir -p "${OUT}"

STATE_CSV="${OUT}/state.csv"
EVENTS_CSV="${OUT}/events.csv"
WRITES_CSV="${OUT}/writes.csv"
WRITER_RAW_LOG="${OUT}/writer.raw.log"
SUMMARY_CSV="${OUT}/summary.csv"
SUMMARY_TXT="${OUT}/summary.txt"
WRITER_POD="pg-writer-${RUN_ID}"
WATCH_PID=""
WRITER_STOPPED="false"
T_INJECT=""

log() { echo "[$(date +%H:%M:%S)] $*"; }
event() { echo "$(date +%s.%N),$1,$2" >> "${EVENTS_CSV}"; }

cleanup() {
  if [[ -n "${WATCH_PID}" ]]; then
    kill "${WATCH_PID}" >/dev/null 2>&1 || true
    wait "${WATCH_PID}" >/dev/null 2>&1 || true
  fi
  ${KC} delete pod "${WRITER_POD}" -n "${NS}" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

run_psql() {
  local pod_name="$1"
  local sql="$2"
  ${KC} run "${pod_name}" -n "${NS}" --image="${WRITER_IMAGE}" \
    --restart=Never --rm -i --quiet \
    --env="PGPASSWORD=${PGPASS}" --command -- \
    psql "host=${RW_HOST} user=${DB_USER} dbname=${DB_NAME} connect_timeout=10" \
    -v ON_ERROR_STOP=1 -tAc "${sql}"
}

require_number() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${name} must be a non-negative integer, got '${value}'."
}

require_number MAX_WAIT "${MAX_WAIT}"
require_number OBSERVE_AFTER "${OBSERVE_AFTER}"
require_number WRITER_DURATION "${WRITER_DURATION}"
require_number PRE_OK_REQUIRED "${PRE_OK_REQUIRED}"
require_number CONNECT_TIMEOUT "${CONNECT_TIMEOUT}"
require_number PSQL_STATEMENT_TIMEOUT_MS "${PSQL_STATEMENT_TIMEOUT_MS}"

command -v awk >/dev/null || fail "awk is required."
command -v base64 >/dev/null || fail "base64 is required."

# --- 0. Preflight --------------------------------------------
log "Checking initial cluster state..."
INIT_PHASE="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
INIT_PRIMARY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo '')"
INIT_READY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"
PG_INSTANCES="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo '3')"

if [[ -z "${INIT_PRIMARY}" || "${INIT_PHASE}" != "Cluster in healthy state" || "${INIT_READY}" != "${PG_INSTANCES}" ]]; then
  fail "cluster is not healthy before test (phase='${INIT_PHASE}', primary='${INIT_PRIMARY}', ready='${INIT_READY}/${PG_INSTANCES}')."
fi
log "Cluster healthy. Primary: ${INIT_PRIMARY} (${INIT_READY}/${PG_INSTANCES})."

PGPASS="$(${KC} get secret "${DB_SECRET}" -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '')"
[[ -n "${PGPASS}" ]] || fail "cannot read DB password from secret '${DB_SECRET}'."

# --- 1. Prepare isolated table -------------------------------
log "Preparing probe table for run_id=${RUN_ID}..."
SETUP_SQL="
CREATE TABLE IF NOT EXISTS failover_probe (
  id bigserial PRIMARY KEY,
  run_id text NOT NULL,
  attempt_no bigint NOT NULL,
  inserted_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS failover_probe_run_attempt_idx
  ON failover_probe(run_id, attempt_no);
DELETE FROM failover_probe WHERE run_id = '${RUN_ID}';
"

SETUP_OK="false"
for attempt in 1 2 3; do
  if run_psql "pg-setup-${RUN_ID}-${attempt}" "${SETUP_SQL}" >/dev/null 2>&1; then
    SETUP_OK="true"
    break
  fi
  log "  setup attempt ${attempt} failed, retrying..."
  sleep 3
done
[[ "${SETUP_OK}" == "true" ]] || fail "could not prepare probe table. Check DB connectivity to ${RW_HOST}."
log "Probe table ready."

# --- 2. Start writer -----------------------------------------
log "Starting writer pod ${WRITER_POD} against ${RW_HOST}..."
WRITER_SCRIPT=$(cat <<EOF_INNER
set -u
run_id='${RUN_ID}'
rw_host='${RW_HOST}'
db_user='${DB_USER}'
db_name='${DB_NAME}'
duration='${WRITER_DURATION}'
interval='${WRITE_INTERVAL}'
connect_timeout='${CONNECT_TIMEOUT}'
statement_timeout_ms='${PSQL_STATEMENT_TIMEOUT_MS}'
attempt=0
end=\$((SECONDS + duration))
while [ "\$SECONDS" -lt "\$end" ] && [ ! -f /tmp/stop ]; do
  attempt=\$((attempt + 1))
  start_ts=\$(date +%s.%N)
  if psql "host=\${rw_host} user=\${db_user} dbname=\${db_name} connect_timeout=\${connect_timeout}" \
      -v ON_ERROR_STOP=1 -tAc \
      "SET statement_timeout = '\${statement_timeout_ms}ms'; INSERT INTO failover_probe(run_id, attempt_no) VALUES ('\${run_id}', \${attempt});" >/dev/null 2>&1; then
    result="OK"
  else
    result="FAIL"
  fi
  end_ts=\$(date +%s.%N)
  duration_ms=\$(awk -v a="\${end_ts}" -v b="\${start_ts}" 'BEGIN{printf "%.0f", (a-b)*1000}')
  echo "\${attempt},\${start_ts},\${end_ts},\${duration_ms},\${result}"
  sleep "\${interval}"
done
EOF_INNER
)

${KC} delete pod "${WRITER_POD}" -n "${NS}" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
${KC} run "${WRITER_POD}" -n "${NS}" --image="${WRITER_IMAGE}" \
  --restart=Never --env="PGPASSWORD=${PGPASS}" \
  --command -- bash -c "${WRITER_SCRIPT}" >/dev/null

log "Waiting for ${PRE_OK_REQUIRED} stable OK writes before injection..."
PRE_OK_COUNT=0
for _ in $(seq 1 120); do
  PRE_OK_COUNT="$(${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null | awk -F',' '$5=="OK"{c++} END{print c+0}')"
  if (( PRE_OK_COUNT >= PRE_OK_REQUIRED )); then
    log "Writer stable (${PRE_OK_COUNT} OK writes)."
    break
  fi
  sleep 1
done
(( PRE_OK_COUNT >= PRE_OK_REQUIRED )) || fail "writer did not produce ${PRE_OK_REQUIRED} successful writes before injection. See: ${KC} logs ${WRITER_POD} -n ${NS}"

# --- 3. Start state watcher ----------------------------------
echo "timestamp_epoch,phase,currentPrimary,readyInstances" > "${STATE_CSV}"
echo "timestamp_epoch,event,detail" > "${EVENTS_CSV}"
event "initial_primary" "${INIT_PRIMARY}"
(
  ${KC} get cluster/${CLUSTER} -n "${NS}" \
    -o jsonpath='{.status.phase}|{.status.currentPrimary}|{.status.readyInstances}{"\n"}' \
    --watch 2>/dev/null | while IFS='|' read -r p cp ri; do
      echo "$(date +%s.%N),${p},${cp},${ri}" >> "${STATE_CSV}"
    done
) &
WATCH_PID=$!

# --- 4. Inject primary failure -------------------------------
sleep 2
T_INJECT="$(date +%s.%N)"
event "failure_injected" "force_delete_primary=${INIT_PRIMARY}"
log "==> INJECTING FAILURE: force-deleting primary ${INIT_PRIMARY}"
${KC} delete pod "${INIT_PRIMARY}" -n "${NS}" --grace-period=0 --force >/dev/null

# --- 5. Wait for client-visible recovery ---------------------
log "Waiting for first successful write after failure injection (up to ${MAX_WAIT}s)..."
FIRST_OK_AFTER=""
START_WAIT="$(date +%s.%N)"
while :; do
  FIRST_OK_AFTER="$(${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null | \
    awk -F',' -v inj="${T_INJECT}" '$5=="OK" && $2 > inj {print $3; exit}')"
  if [[ -n "${FIRST_OK_AFTER}" ]]; then
    event "client_write_recovered" "first_ok_after=${FIRST_OK_AFTER}"
    log "Client-visible writes recovered."
    break
  fi

  NOW="$(date +%s.%N)"
  WAITED="$(awk -v a="${NOW}" -v b="${START_WAIT}" 'BEGIN{printf "%.0f", a-b}')"
  if (( WAITED > MAX_WAIT )); then
    event "client_write_recovery_timeout" "max_wait=${MAX_WAIT}"
    log "WARNING: no successful write observed within ${MAX_WAIT}s."
    break
  fi
  sleep 1
done

# --- 6. Wait for full CNPG recovery, secondary metric --------
log "Checking full CNPG recovery state (secondary metric)..."
NEW_PRIMARY=""
CLUSTER_RECOVERED_AT=""
START_CLUSTER_WAIT="$(date +%s.%N)"
while :; do
  PHASE="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  CUR_PRIMARY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo '')"
  READY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"

  [[ -n "${CUR_PRIMARY}" && "${CUR_PRIMARY}" != "${INIT_PRIMARY}" ]] && NEW_PRIMARY="${CUR_PRIMARY}"

  if [[ "${PHASE}" == "Cluster in healthy state" && "${READY}" == "${PG_INSTANCES}" && -n "${NEW_PRIMARY}" ]]; then
    CLUSTER_RECOVERED_AT="$(date +%s.%N)"
    event "cluster_recovered" "new_primary=${NEW_PRIMARY}"
    log "Cluster healthy again. New primary: ${NEW_PRIMARY}"
    break
  fi

  NOW="$(date +%s.%N)"
  WAITED="$(awk -v a="${NOW}" -v b="${START_CLUSTER_WAIT}" 'BEGIN{printf "%.0f", a-b}')"
  if (( WAITED > MAX_WAIT )); then
    event "cluster_recovery_timeout" "phase=${PHASE};primary=${CUR_PRIMARY};ready=${READY}/${PG_INSTANCES}"
    log "WARNING: cluster did not report full recovery within ${MAX_WAIT}s."
    break
  fi
  sleep 2
done

log "Observing for ${OBSERVE_AFTER}s after recovery window..."
sleep "${OBSERVE_AFTER}"

# --- 7. Stop writer and watcher before final counting --------
log "Stopping writer before collecting final metrics..."
if [[ -n "${WATCH_PID}" ]]; then
  kill "${WATCH_PID}" >/dev/null 2>&1 || true
  wait "${WATCH_PID}" >/dev/null 2>&1 || true
  WATCH_PID=""
fi

${KC} exec "${WRITER_POD}" -n "${NS}" -- touch /tmp/stop >/dev/null 2>&1 || true
for _ in $(seq 1 45); do
  WRITER_PHASE="$(${KC} get pod "${WRITER_POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  if [[ "${WRITER_PHASE}" == "Succeeded" || "${WRITER_PHASE}" == "Failed" ]]; then
    WRITER_STOPPED="true"
    break
  fi
  sleep 1
done

log "Capturing writer log..."
${KC} logs "${WRITER_POD}" -n "${NS}" > "${WRITER_RAW_LOG}" 2>/dev/null || true
${KC} delete pod "${WRITER_POD}" -n "${NS}" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true

# --- 8. Normalize writer log ---------------------------------
log "Building writes.csv..."
echo "attempt_no,start_ts,end_ts,duration_ms,result,elapsed_start_s,elapsed_end_s,period" > "${WRITES_CSV}"
while IFS=',' read -r attempt_no start_ts end_ts duration_ms result extra; do
  [[ "${attempt_no}" =~ ^[0-9]+$ ]] || continue
  [[ "${start_ts}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
  [[ "${end_ts}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
  [[ "${result}" == "OK" || "${result}" == "FAIL" ]] || continue

  elapsed_start="$(awk -v a="${start_ts}" -v b="${T_INJECT}" 'BEGIN{printf "%.3f", a-b}')"
  elapsed_end="$(awk -v a="${end_ts}" -v b="${T_INJECT}" 'BEGIN{printf "%.3f", a-b}')"

  if awk -v e="${end_ts}" -v inj="${T_INJECT}" 'BEGIN{exit !(e < inj)}'; then
    period="before"
  elif awk -v s="${start_ts}" -v inj="${T_INJECT}" 'BEGIN{exit !(s > inj)}'; then
    period="after"
  else
    period="overlap"
  fi

  echo "${attempt_no},${start_ts},${end_ts},${duration_ms},${result},${elapsed_start},${elapsed_end},${period}" >> "${WRITES_CSV}"
done < "${WRITER_RAW_LOG}"

WRITE_TOTAL="$(awk -F',' 'NR>1{c++} END{print c+0}' "${WRITES_CSV}")"
(( WRITE_TOTAL > 0 )) || fail "no writer log lines were collected."

# --- 9. Compute metrics --------------------------------------
SUCCESSFUL_WRITES="$(awk -F',' 'NR>1 && $5=="OK"{c++} END{print c+0}' "${WRITES_CSV}")"
FAILED_WRITES="$(awk -F',' 'NR>1 && $5=="FAIL"{c++} END{print c+0}' "${WRITES_CSV}")"
FAILS_AFTER_INJECTION="$(awk -F',' 'NR>1 && $5=="FAIL" && ($8=="after" || $8=="overlap"){c++} END{print c+0}' "${WRITES_CSV}")"
OK_BEFORE_COUNT="$(awk -F',' 'NR>1 && $5=="OK" && $8=="before"{c++} END{print c+0}' "${WRITES_CSV}")"
OK_AFTER_COUNT="$(awk -F',' 'NR>1 && $5=="OK" && $8=="after"{c++} END{print c+0}' "${WRITES_CSV}")"

LAST_OK_BEFORE_LOG="$(awk -F',' 'NR>1 && $5=="OK" && $8=="before"{v=$3} END{print v}' "${WRITES_CSV}")"
FIRST_OK_AFTER_LOG="$(awk -F',' 'NR>1 && $5=="OK" && $8=="after"{print $3; exit}' "${WRITES_CSV}")"

if [[ -n "${LAST_OK_BEFORE_LOG}" && -n "${FIRST_OK_AFTER_LOG}" ]]; then
  CLIENT_DOWNTIME="$(awk -v a="${FIRST_OK_AFTER_LOG}" -v b="${LAST_OK_BEFORE_LOG}" 'BEGIN{printf "%.3f", a-b}')"
else
  CLIENT_DOWNTIME="n/a"
fi

if [[ -n "${CLUSTER_RECOVERED_AT}" ]]; then
  CLUSTER_RECOVERY_S="$(awk -v a="${CLUSTER_RECOVERED_AT}" -v b="${T_INJECT}" 'BEGIN{printf "%.3f", a-b}')"
else
  CLUSTER_RECOVERY_S="n/a"
fi

if [[ -n "${FIRST_OK_AFTER_LOG}" ]]; then
  SECONDARY_FAILS_AFTER_RECOVERY="$(awk -F',' -v first="${FIRST_OK_AFTER_LOG}" \
    'NR>1 && $5=="FAIL" && $2 > first {c++} END{print c+0}' "${WRITES_CSV}")"
else
  SECONDARY_FAILS_AFTER_RECOVERY="n/a"
fi

ROWS="n/a"
for attempt in 1 2 3 4 5; do
  R="$(run_psql "pg-check-${RUN_ID}-${attempt}" \
    "SELECT count(*) FROM failover_probe WHERE run_id = '${RUN_ID}';" \
    2>/dev/null | tr -d '[:space:]' || echo '')"
  if [[ -n "${R}" && "${R}" =~ ^[0-9]+$ ]]; then
    ROWS="${R}"
    break
  fi
  sleep 3
done

DATA_LOSS_CHECK="UNKNOWN"
if [[ "${ROWS}" =~ ^[0-9]+$ ]]; then
  if [[ "${ROWS}" == "${SUCCESSFUL_WRITES}" ]]; then
    DATA_LOSS_CHECK="PASS"
  else
    DATA_LOSS_CHECK="FAIL"
  fi
fi

RUN_VALID="true"
INVALID_REASON=""
if (( OK_BEFORE_COUNT < PRE_OK_REQUIRED )); then
  RUN_VALID="false"; INVALID_REASON+="writer_not_stable_before_injection;"
fi
if [[ "${CLIENT_DOWNTIME}" == "n/a" ]]; then
  RUN_VALID="false"; INVALID_REASON+="no_client_recovery_observed;"
fi
if [[ "${DATA_LOSS_CHECK}" != "PASS" ]]; then
  RUN_VALID="false"; INVALID_REASON+="successful_writes_do_not_match_committed_rows;"
fi
if [[ "${WRITER_STOPPED}" != "true" ]]; then
  RUN_VALID="false"; INVALID_REASON+="writer_did_not_stop_gracefully;"
fi
[[ -z "${INVALID_REASON}" ]] && INVALID_REASON="none"

# --- 10. Summary ---------------------------------------------
{
  echo "metric,value"
  echo "run_id,${RUN_ID}"
  echo "run_valid,${RUN_VALID}"
  echo "invalid_reason,${INVALID_REASON}"
  echo "initial_primary,${INIT_PRIMARY}"
  echo "new_primary,${NEW_PRIMARY:-n/a}"
  echo "instances,${PG_INSTANCES}"
  echo "client_write_downtime_s,${CLIENT_DOWNTIME}"
  echo "cluster_full_recovery_s,${CLUSTER_RECOVERY_S}"
  echo "failed_writes_total,${FAILED_WRITES}"
  echo "failed_writes_after_injection,${FAILS_AFTER_INJECTION}"
  echo "secondary_fails_after_recovery,${SECONDARY_FAILS_AFTER_RECOVERY}"
  echo "successful_writes,${SUCCESSFUL_WRITES}"
  echo "total_write_attempts,${WRITE_TOTAL}"
  echo "committed_rows_for_run_id,${ROWS}"
  echo "data_loss_check,${DATA_LOSS_CHECK}"
  echo "pre_failure_ok_count,${OK_BEFORE_COUNT}"
  echo "post_failure_ok_count,${OK_AFTER_COUNT}"
  echo "writer_stopped_gracefully,${WRITER_STOPPED}"
  echo "write_interval_s,${WRITE_INTERVAL}"
  echo "connect_timeout_s,${CONNECT_TIMEOUT}"
  echo "statement_timeout_ms,${PSQL_STATEMENT_TIMEOUT_MS}"
} > "${SUMMARY_CSV}"

{
  echo "============================================================"
  echo " TEST: Primary PostgreSQL pod failure (CNPG failover)"
  echo " Run ID: ${RUN_ID}"
  echo "============================================================"
  echo ""
  echo "Initial primary:        ${INIT_PRIMARY}"
  echo "New primary:            ${NEW_PRIMARY:-n/a}"
  echo "Instances:              ${PG_INSTANCES}"
  echo "Run valid:              ${RUN_VALID}"
  echo "Invalid reason:         ${INVALID_REASON}"
  echo ""
  echo "CLIENT-SIDE MEASUREMENT (primary metric):"
  echo "  Write downtime (s):              ${CLIENT_DOWNTIME}"
  echo "  Failed writes after injection:   ${FAILS_AFTER_INJECTION}"
  echo "  Successful writes:               ${SUCCESSFUL_WRITES}"
  echo "  Total write attempts:            ${WRITE_TOTAL}"
  echo ""
  echo "CONSISTENCY CHECK:"
  echo "  Committed rows for run_id:       ${ROWS}"
  echo "  Data-loss check:                 ${DATA_LOSS_CHECK}"
  echo ""
  echo "SECONDARY OBSERVATIONS:"
  echo "  CNPG full recovery (s):          ${CLUSTER_RECOVERY_S}"
  echo "  Fails after first recovery:      ${SECONDARY_FAILS_AFTER_RECOVERY}"
  echo "  Writer stopped gracefully:       ${WRITER_STOPPED}"
  echo ""
  echo "CSV files:"
  echo "  writer.raw.log — raw writer output"
  echo "  writes.csv     — every write attempt with timestamps"
  echo "  state.csv      — CNPG cluster state timeline"
  echo "  events.csv     — failure injection and recovery events"
  echo "  summary.csv    — machine-readable metrics"
} | tee "${SUMMARY_TXT}"

log "Done. Results in: ${OUT}"
