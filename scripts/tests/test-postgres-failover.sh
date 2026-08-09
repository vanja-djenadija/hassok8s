#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# PostgreSQL primary failover test
#
# This test verifies whether the PostgreSQL cluster managed by
# CloudNativePG can recover from the failure of the current primary
# instance.
#
# The test continuously writes rows through the CNPG read-write
# service:
#
#   keycloak-postgres-rw
#
# This service is the same stable database endpoint used by Keycloak.
#
# The test is executed from an external machine through kubectl, but
# the writer itself runs inside the Kubernetes cluster. This is
# intentional and academically valid because PostgreSQL is not a
# public user-facing component. It is consumed by the application
# layer, i.e. Keycloak, through an internal Kubernetes service.
#
# A run is valid only if:
#   - preflight check passes,
#   - baseline writes succeed before failure injection,
#   - a new primary is detected,
#   - the cluster recovers to a healthy state,
#   - committed_rows == successful_writes,
#   - no failed writes appear after the post-recovery phase begins.
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

NAMESPACE="${NAMESPACE:-keycloak}"
PG_INSTANCES="${PG_INSTANCES:-3}"
PG_CLUSTER="${PG_CLUSTER:-keycloak-postgres}"
PG_RW_SERVICE="${PG_RW_SERVICE:-keycloak-postgres-rw}"
DB_SECRET="${DB_SECRET:-keycloak-db-secret}"

NS="${NAMESPACE}"

: "${PG_DATABASE:?Missing PG_DATABASE in config.env}"
: "${PG_USERNAME:?Missing PG_USERNAME in config.env}"

POSTGRES_LABEL="${POSTGRES_LABEL:-cnpg.io/cluster=${PG_CLUSTER}}"
WRITER_IMAGE="${WRITER_IMAGE:-postgres:16.4}"

WRITE_INTERVAL="${POSTGRES_WRITE_INTERVAL:-0.5}"
BASELINE_SECONDS="${BASELINE_SECONDS:-20}"
POST_RECOVERY_SECONDS="${POST_RECOVERY_SECONDS:-20}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-600}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/logs/tests/postgres-failover-${RUN_ID}"
mkdir -p "${OUT_DIR}"

WRITES_CSV="${OUT_DIR}/writes.csv"
EVENTS_CSV="${OUT_DIR}/events.csv"
SUMMARY_CSV="${OUT_DIR}/summary.csv"

TEST_TABLE="${TEST_TABLE:-ha_failover_probe}"
JDBC_HOST="${PG_RW_SERVICE}.${NS}.svc.cluster.local"
PGPORT="5432"

WRITER_POD=""

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

event() {
  local name="$1"
  local details="${2:-}"
  echo "$(date --iso-8601=seconds),${name},${details}" >> "${EVENTS_CSV}"
}

fail() {
  log "ERROR: $*" >&2
  event "test_failed" "$*"
  exit 1
}

cleanup() {
  if [[ -n "${WRITER_POD:-}" ]]; then
    ${KC} delete pod "${WRITER_POD}" -n "${NS}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

append_invalid() {
  local reason="$1"

  if [[ "${INVALID_REASON}" == "none" ]]; then
    INVALID_REASON="${reason}"
  else
    INVALID_REASON="${INVALID_REASON};${reason}"
  fi

  RUN_VALID="false"
}

percentile_from_sorted_values() {
  local p="$1"

  awk -v p="${p}" '
    { a[NR]=$1 }
    END {
      if (NR == 0) {
        print "n/a"
      } else {
        idx = int(p * NR)
        if (idx < 1) idx = 1
        if (idx > NR) idx = NR
        print a[idx]
      }
    }'
}

latency_stat() {
  local phase="$1"
  local percentile="$2"

  awk -F',' -v phase="${phase}" '
    NR>1 && $6==phase && $5=="OK" {print $4}
  ' "${WRITES_CSV}" | sort -n | percentile_from_sorted_values "${percentile}"
}

latency_max() {
  local phase="$1"

  awk -F',' -v phase="${phase}" '
    NR>1 && $6==phase && $5=="OK" {
      if ($4 > max) max = $4
    }
    END {
      if (max == "") print "n/a";
      else print max
    }
  ' "${WRITES_CSV}"
}

collect_logs() {
  if [[ -z "${WRITER_POD:-}" ]]; then
    return 0
  fi

  ${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
    > "${OUT_DIR}/writer-current.log" || true

  {
    head -1 "${WRITES_CSV}"
    cat "${OUT_DIR}/writer-current.log" 2>/dev/null || true
  } > "${WRITES_CSV}.tmp"

  awk '!seen[$0]++' "${WRITES_CSV}.tmp" > "${WRITES_CSV}"
}

set_writer_phase() {
  local phase="$1"

  if [[ -n "${WRITER_POD:-}" ]]; then
    ${KC} exec "${WRITER_POD}" -n "${NS}" -- \
      bash -c "echo '${phase}' > /tmp/phase" >/dev/null 2>&1 || true
  fi
}

stop_writer_gracefully() {
  if [[ -z "${WRITER_POD:-}" ]]; then
    return 0
  fi

  log "Stopping writer gracefully..."
  event "writer_stop_requested" "pod=${WRITER_POD}"

  ${KC} exec "${WRITER_POD}" -n "${NS}" -- \
    bash -c "touch /tmp/stop" >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    PHASE="$(${KC} get pod "${WRITER_POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")"

    if [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" || "${PHASE}" == "Missing" ]]; then
      break
    fi

    sleep 1
  done

  collect_logs
}

# -------------------------------------------------------------
# 0. Initialize output files
# -------------------------------------------------------------
echo "timestamp,epoch_ms,seq,duration_ms,result,phase,error" > "${WRITES_CSV}"
echo "timestamp,event,details" > "${EVENTS_CSV}"

event "test_started" "run_id=${RUN_ID}"

log "Output directory: ${OUT_DIR}"
log "PostgreSQL RW service: ${PG_RW_SERVICE}"
log "Database: ${PG_DATABASE}"
log "Writer interval: ${WRITE_INTERVAL}s"
log "Using kubectl command: ${KC}"

# -------------------------------------------------------------
# 1. Preflight check
# -------------------------------------------------------------
log "Running preflight check..."

if [[ -x "${SCRIPT_DIR}/preflight-ha.sh" ]]; then
  KC="${KC}" "${SCRIPT_DIR}/preflight-ha.sh"
else
  fail "preflight-ha.sh not found or not executable."
fi

event "preflight_passed" ""

# -------------------------------------------------------------
# 2. Capture initial PostgreSQL state
# -------------------------------------------------------------
log "Capturing initial PostgreSQL state..."

${KC} get cluster "${PG_CLUSTER}" -n "${NS}" | tee "${OUT_DIR}/initial-pg-cluster.txt"
${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role -o wide | tee "${OUT_DIR}/initial-pg-pods.txt"
${KC} get svc -n "${NS}" | grep "${PG_CLUSTER}" | tee "${OUT_DIR}/initial-pg-services.txt" || true

PG_PHASE="$(${KC} get cluster "${PG_CLUSTER}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
PG_READY="$(${KC} get cluster "${PG_CLUSTER}" -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")"

[[ "${PG_PHASE}" == "Cluster in healthy state" ]] || fail "CNPG cluster is not healthy before test. Phase: ${PG_PHASE}"
[[ "${PG_READY}" == "${PG_INSTANCES}" ]] || fail "Expected ${PG_INSTANCES} ready PostgreSQL instances, found ${PG_READY}."

PRIMARY_POD="$(${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role --no-headers \
  | awk '$NF=="primary" {print $1; exit}')"

[[ -n "${PRIMARY_POD}" ]] || fail "Could not determine current PostgreSQL primary pod."

PRIMARY_NODE="$(${KC} get pod "${PRIMARY_POD}" -n "${NS}" -o jsonpath='{.spec.nodeName}')"

log "Initial primary pod: ${PRIMARY_POD}"
log "Initial primary node: ${PRIMARY_NODE}"
event "initial_primary_detected" "pod=${PRIMARY_POD};node=${PRIMARY_NODE}"

# -------------------------------------------------------------
# 3. Prepare test table
# -------------------------------------------------------------
log "Preparing test table..."

DB_PASS="$(${KC} get secret "${DB_SECRET}" -n "${NS}" -o jsonpath='{.data.password}' | base64 -d)"

${KC} exec -c postgres "${PRIMARY_POD}" -n "${NS}" -- \
  env PGPASSWORD="${DB_PASS}" \
  psql \
    -h "${PG_RW_SERVICE}" \
    -p "${PGPORT}" \
    -U "${PG_USERNAME}" \
    -d "${PG_DATABASE}" \
    -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (
          run_id text NOT NULL,
          seq integer NOT NULL,
          created_at timestamptz NOT NULL DEFAULT now(),
          writer_pod text NOT NULL,
          phase text NOT NULL,
          PRIMARY KEY (run_id, seq)
        );" >/dev/null

event "test_table_prepared" "table=${TEST_TABLE}"

# -------------------------------------------------------------
# 4. Start writer pod
# -------------------------------------------------------------
WRITER_POD="pg-failover-writer-${RUN_ID}"

log "Starting writer pod: ${WRITER_POD}"

cat <<EOF | ${KC} apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${WRITER_POD}
  namespace: ${NS}
  labels:
    app: postgres-failover-writer
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: NotIn
                values:
                  - ${PRIMARY_NODE}
  containers:
    - name: writer
      image: ${WRITER_IMAGE}
      env:
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: ${DB_SECRET}
              key: password
      command: ["bash", "-c"]
      args:
        - |
          set +e

          PHASE_FILE="/tmp/phase"
          STOP_FILE="/tmp/stop"

          echo "before" > "\${PHASE_FILE}"

          SEQ=0

          while true; do
            if [ -f "\${STOP_FILE}" ]; then
              break
            fi

            SEQ=\$((SEQ + 1))
            TS=\$(date --iso-8601=seconds)
            EPOCH_MS=\$(date +%s%3N)
            PHASE=\$(cat "\${PHASE_FILE}" 2>/dev/null || echo "unknown")
            START_MS=\$(date +%s%3N)

            OUT=\$(psql \
              -h "${JDBC_HOST}" \
              -p "${PGPORT}" \
              -U "${PG_USERNAME}" \
              -d "${PG_DATABASE}" \
              -v ON_ERROR_STOP=1 \
              -qAt \
              -c "INSERT INTO ${TEST_TABLE}(run_id, seq, writer_pod, phase) VALUES ('${RUN_ID}', \${SEQ}, '${WRITER_POD}', '\${PHASE}');" 2>&1)

            RC=\$?
            END_MS=\$(date +%s%3N)
            DURATION_MS=\$((END_MS - START_MS))

            if [ "\${RC}" -eq 0 ]; then
              echo "\${TS},\${EPOCH_MS},\${SEQ},\${DURATION_MS},OK,\${PHASE},"
            else
              SAFE_OUT=\$(echo "\${OUT}" | tr ',' ';' | tr '\n' ' ')
              echo "\${TS},\${EPOCH_MS},\${SEQ},\${DURATION_MS},FAIL,\${PHASE},psql_error_\${RC}:\${SAFE_OUT}"
            fi

            sleep ${WRITE_INTERVAL}
          done

          exit 0
EOF

${KC} wait --for=condition=Ready pod/"${WRITER_POD}" -n "${NS}" --timeout=120s >/dev/null \
  || fail "Writer pod did not become Ready."

WRITER_NODE="$(${KC} get pod "${WRITER_POD}" -n "${NS}" -o jsonpath='{.spec.nodeName}')"

log "Writer pod node: ${WRITER_NODE}"
event "writer_started" "pod=${WRITER_POD};node=${WRITER_NODE}"

if [[ "${WRITER_NODE}" == "${PRIMARY_NODE}" ]]; then
  event "writer_on_primary_node" "writer_node=${WRITER_NODE};primary_node=${PRIMARY_NODE}"
  log "WARNING: Writer pod is on the same node as the current primary."
  log "This should normally not happen because nodeAffinity excludes the primary node."
fi

# -------------------------------------------------------------
# 5. Baseline period
# -------------------------------------------------------------
log "Baseline period: ${BASELINE_SECONDS}s"
event "baseline_started" "seconds=${BASELINE_SECONDS}"

sleep "${BASELINE_SECONDS}"
collect_logs

BASELINE_TOTAL="$(awk -F',' 'NR>1 && $6=="before" {count++} END {print count+0}' "${WRITES_CSV}")"
BASELINE_FAILS="$(awk -F',' 'NR>1 && $6=="before" && $5=="FAIL" {count++} END {print count+0}' "${WRITES_CSV}")"

event "baseline_finished" "total=${BASELINE_TOTAL};fails=${BASELINE_FAILS}"

if (( BASELINE_TOTAL == 0 )); then
  fail "No baseline write samples collected."
fi

if (( BASELINE_FAILS > 0 )); then
  fail "Baseline contains failed writes. The run is not valid."
fi

BASELINE_P50_MS="$(latency_stat "before" "0.50")"
BASELINE_P95_MS="$(latency_stat "before" "0.95")"
BASELINE_MAX_MS="$(latency_max "before")"

log "Baseline latency: p50=${BASELINE_P50_MS}ms, p95=${BASELINE_P95_MS}ms, max=${BASELINE_MAX_MS}ms"
event "baseline_latency" "p50_ms=${BASELINE_P50_MS};p95_ms=${BASELINE_P95_MS};max_ms=${BASELINE_MAX_MS}"

# -------------------------------------------------------------
# 6. Inject primary failure
# -------------------------------------------------------------
log "Injecting failure: deleting current primary pod ${PRIMARY_POD}"

set_writer_phase "during"

INJECTION_EPOCH_MS="$(date +%s%3N)"
INJECTION_TS="$(date --iso-8601=seconds)"

event "failure_injected" "deleted_primary=${PRIMARY_POD};node=${PRIMARY_NODE}"

${KC} delete pod "${PRIMARY_POD}" -n "${NS}" --wait=false >/dev/null

# -------------------------------------------------------------
# 7. Wait for new primary and full CNPG recovery
# -------------------------------------------------------------
log "Waiting for new primary and full cluster recovery, timeout ${RECOVERY_TIMEOUT_SECONDS}s..."

NEW_PRIMARY_POD=""
NEW_PRIMARY_NODE=""
FAILOVER_DETECTED_EPOCH_MS=""
CLUSTER_RECOVERY_EPOCH_MS=""
RECOVERY_OK="false"

for _ in $(seq 1 "${RECOVERY_TIMEOUT_SECONDS}"); do
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

  sleep 1
done

if [[ "${RECOVERY_OK}" == "true" ]]; then
  CLUSTER_FULL_RECOVERY_S="$(awk -v a="${INJECTION_EPOCH_MS}" -v b="${CLUSTER_RECOVERY_EPOCH_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
  log "CNPG cluster recovered after ${CLUSTER_FULL_RECOVERY_S}s."
  event "cluster_recovery_completed" "seconds=${CLUSTER_FULL_RECOVERY_S}"
else
  CLUSTER_FULL_RECOVERY_S="n/a"
  event "cluster_recovery_timeout" "timeout_seconds=${RECOVERY_TIMEOUT_SECONDS}"
fi

# -------------------------------------------------------------
# 8. Post-recovery observation
# -------------------------------------------------------------
set_writer_phase "after"

log "Post-recovery observation: ${POST_RECOVERY_SECONDS}s"
event "post_recovery_observation_started" "seconds=${POST_RECOVERY_SECONDS}"

sleep "${POST_RECOVERY_SECONDS}"

stop_writer_gracefully

event "post_recovery_observation_finished" ""

# Writer logs are now frozen and collected.
${KC} delete pod "${WRITER_POD}" -n "${NS}" --ignore-not-found=true >/dev/null 2>&1 || true
WRITER_POD=""

# -------------------------------------------------------------
# 9. Capture final PostgreSQL state
# -------------------------------------------------------------
log "Capturing final PostgreSQL state..."

${KC} get cluster "${PG_CLUSTER}" -n "${NS}" | tee "${OUT_DIR}/final-pg-cluster.txt"
${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role -o wide | tee "${OUT_DIR}/final-pg-pods.txt"

# -------------------------------------------------------------
# 10. Verify committed rows
# -------------------------------------------------------------
log "Verifying committed rows..."

VERIFY_POD="$(${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" -L role --no-headers 2>/dev/null \
  | awk '$NF=="primary" {print $1; exit}')"

if [[ -z "${VERIFY_POD}" ]]; then
  VERIFY_POD="$(${KC} get pods -n "${NS}" -l "${POSTGRES_LABEL}" --no-headers 2>/dev/null | awk '{print $1; exit}')"
fi

[[ -n "${VERIFY_POD}" ]] || fail "Could not find PostgreSQL pod for verification."

COMMITTED_ROWS="$(${KC} exec -c postgres "${VERIFY_POD}" -n "${NS}" -- \
  env PGPASSWORD="${DB_PASS}" \
  psql \
    -h "${PG_RW_SERVICE}" \
    -p "${PGPORT}" \
    -U "${PG_USERNAME}" \
    -d "${PG_DATABASE}" \
    -qAt \
    -c "SELECT count(*) FROM ${TEST_TABLE} WHERE run_id='${RUN_ID}';" \
  | tr -d '[:space:]')"

DISTINCT_COMMITTED_SEQ="$(${KC} exec -c postgres "${VERIFY_POD}" -n "${NS}" -- \
  env PGPASSWORD="${DB_PASS}" \
  psql \
    -h "${PG_RW_SERVICE}" \
    -p "${PGPORT}" \
    -U "${PG_USERNAME}" \
    -d "${PG_DATABASE}" \
    -qAt \
    -c "SELECT count(DISTINCT seq) FROM ${TEST_TABLE} WHERE run_id='${RUN_ID}';" \
  | tr -d '[:space:]')"

SUCCESSFUL_WRITES="$(awk -F',' 'NR>1 && $5=="OK" {count++} END {print count+0}' "${WRITES_CSV}")"
FAILED_WRITES="$(awk -F',' 'NR>1 && $5=="FAIL" {count++} END {print count+0}' "${WRITES_CSV}")"
TOTAL_ATTEMPTS="$(awk -F',' 'NR>1 {count++} END {print count+0}' "${WRITES_CSV}")"

FAILED_WRITES_AFTER_INJECTION="$(awk -F',' -v inj="${INJECTION_EPOCH_MS}" '
  NR>1 && $2>=inj && $5=="FAIL" {count++}
  END {print count+0}
' "${WRITES_CSV}")"

AFTER_FAILS="$(awk -F',' 'NR>1 && $6=="after" && $5=="FAIL" {count++} END {print count+0}' "${WRITES_CSV}")"

if (( COMMITTED_ROWS < SUCCESSFUL_WRITES )); then
  DATA_LOSS_CHECK="fail"
  MEASUREMENT_CHECK="committed_rows_less_than_logged_successes"
elif (( COMMITTED_ROWS == SUCCESSFUL_WRITES )); then
  DATA_LOSS_CHECK="pass"
  MEASUREMENT_CHECK="exact_match"
else
  DATA_LOSS_CHECK="pass"
  MEASUREMENT_CHECK="committed_rows_greater_than_logged_successes"
fi

if [[ "${COMMITTED_ROWS}" != "${DISTINCT_COMMITTED_SEQ}" ]]; then
  MEASUREMENT_CHECK="${MEASUREMENT_CHECK};duplicate_seq_detected"
fi

event "committed_rows_verified" "successful_writes=${SUCCESSFUL_WRITES};committed_rows=${COMMITTED_ROWS};distinct_seq=${DISTINCT_COMMITTED_SEQ};data_loss=${DATA_LOSS_CHECK};measurement=${MEASUREMENT_CHECK}"

# -------------------------------------------------------------
# 11. Calculate downtime metrics
# -------------------------------------------------------------
FIRST_FAIL_AFTER_INJECTION_MS="$(awk -F',' -v inj="${INJECTION_EPOCH_MS}" '
  NR>1 && $2>=inj && $5=="FAIL" {print $2; exit}
' "${WRITES_CSV}")"

if [[ -n "${FIRST_FAIL_AFTER_INJECTION_MS}" ]]; then
  LAST_OK_BEFORE_FAIL_MS="$(awk -F',' -v firstfail="${FIRST_FAIL_AFTER_INJECTION_MS}" '
    NR>1 && $2<firstfail && $5=="OK" {last=$2}
    END {print last}
  ' "${WRITES_CSV}")"

  FIRST_OK_AFTER_FAIL_MS="$(awk -F',' -v firstfail="${FIRST_FAIL_AFTER_INJECTION_MS}" '
    NR>1 && $2>firstfail && $5=="OK" {print $2; exit}
  ' "${WRITES_CSV}")"

  if [[ -n "${LAST_OK_BEFORE_FAIL_MS}" && -n "${FIRST_OK_AFTER_FAIL_MS}" ]]; then
    CLIENT_WRITE_DOWNTIME_S="$(awk -v a="${LAST_OK_BEFORE_FAIL_MS}" -v b="${FIRST_OK_AFTER_FAIL_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
  else
    CLIENT_WRITE_DOWNTIME_S="n/a"
  fi
else
  CLIENT_WRITE_DOWNTIME_S="0.000"
fi

if [[ -n "${FAILOVER_DETECTED_EPOCH_MS}" ]]; then
  FAILOVER_DETECTED_S="$(awk -v a="${INJECTION_EPOCH_MS}" -v b="${FAILOVER_DETECTED_EPOCH_MS}" 'BEGIN {printf "%.3f", (b-a)/1000}')"
else
  FAILOVER_DETECTED_S="n/a"
fi

POST_RECOVERY_P50_MS="$(latency_stat "after" "0.50")"
POST_RECOVERY_P95_MS="$(latency_stat "after" "0.95")"
POST_RECOVERY_MAX_MS="$(latency_max "after")"

# -------------------------------------------------------------
# 12. Determine run validity
# -------------------------------------------------------------
RUN_VALID="true"
INVALID_REASON="none"

if (( BASELINE_FAILS > 0 )); then
  append_invalid "baseline_failures"
fi

if [[ "${RECOVERY_OK}" != "true" ]]; then
  append_invalid "cluster_recovery_timeout"
fi

if [[ -z "${NEW_PRIMARY_POD}" ]]; then
  append_invalid "new_primary_not_detected"
elif [[ "${NEW_PRIMARY_POD}" == "${PRIMARY_POD}" ]]; then
  append_invalid "primary_did_not_change"
fi

if [[ "${DATA_LOSS_CHECK}" != "pass" ]]; then
  append_invalid "possible_data_loss"
fi

if [[ "${MEASUREMENT_CHECK}" != "exact_match" ]]; then
  append_invalid "measurement_check_${MEASUREMENT_CHECK}"
fi

if (( AFTER_FAILS > 0 )); then
  append_invalid "post_recovery_failures"
fi

if [[ "${CLIENT_WRITE_DOWNTIME_S}" == "n/a" ]]; then
  append_invalid "downtime_not_measurable"
fi

if (( TOTAL_ATTEMPTS == 0 )); then
  append_invalid "no_write_samples"
fi

# -------------------------------------------------------------
# 13. Write summary
# -------------------------------------------------------------
{
  echo "metric,value"
  echo "run_id,${RUN_ID}"
  echo "test,postgres_primary_failover"
  echo "namespace,${NS}"
  echo "cluster,${PG_CLUSTER}"
  echo "rw_service,${PG_RW_SERVICE}"
  echo "database,${PG_DATABASE}"
  echo "test_table,${TEST_TABLE}"
  echo "writer_pod,pg-failover-writer-${RUN_ID}"
  echo "writer_node,${WRITER_NODE}"
  echo "initial_primary_pod,${PRIMARY_POD}"
  echo "initial_primary_node,${PRIMARY_NODE}"
  echo "new_primary_pod,${NEW_PRIMARY_POD:-n/a}"
  echo "new_primary_node,${NEW_PRIMARY_NODE:-n/a}"
  echo "baseline_seconds,${BASELINE_SECONDS}"
  echo "post_recovery_seconds,${POST_RECOVERY_SECONDS}"
  echo "write_interval_seconds,${WRITE_INTERVAL}"
  echo "baseline_total_writes,${BASELINE_TOTAL}"
  echo "baseline_failed_writes,${BASELINE_FAILS}"
  echo "baseline_write_p50_ms,${BASELINE_P50_MS}"
  echo "baseline_write_p95_ms,${BASELINE_P95_MS}"
  echo "baseline_write_max_ms,${BASELINE_MAX_MS}"
  echo "total_write_attempts,${TOTAL_ATTEMPTS}"
  echo "successful_writes,${SUCCESSFUL_WRITES}"
  echo "failed_writes,${FAILED_WRITES}"
  echo "failed_writes_after_injection,${FAILED_WRITES_AFTER_INJECTION}"
  echo "committed_rows,${COMMITTED_ROWS}"
  echo "distinct_committed_seq,${DISTINCT_COMMITTED_SEQ}"
  echo "data_loss_check,${DATA_LOSS_CHECK}"
  echo "measurement_check,${MEASUREMENT_CHECK}"
  echo "client_write_downtime_s,${CLIENT_WRITE_DOWNTIME_S}"
  echo "failover_detected_s,${FAILOVER_DETECTED_S}"
  echo "cluster_full_recovery_s,${CLUSTER_FULL_RECOVERY_S}"
  echo "post_recovery_failed_writes,${AFTER_FAILS}"
  echo "post_recovery_write_p50_ms,${POST_RECOVERY_P50_MS}"
  echo "post_recovery_write_p95_ms,${POST_RECOVERY_P95_MS}"
  echo "post_recovery_write_max_ms,${POST_RECOVERY_MAX_MS}"
  echo "run_valid,${RUN_VALID}"
  echo "invalid_reason,${INVALID_REASON}"
} > "${SUMMARY_CSV}"

event "test_finished" "run_valid=${RUN_VALID};downtime=${CLIENT_WRITE_DOWNTIME_S};data_loss=${DATA_LOSS_CHECK};measurement=${MEASUREMENT_CHECK}"

# -------------------------------------------------------------
# 14. Print final report
# -------------------------------------------------------------
echo ""
echo "============================================================"
echo " POSTGRESQL PRIMARY FAILOVER TEST FINISHED"
echo "============================================================"
echo "Run ID:                       ${RUN_ID}"
echo "Output directory:             ${OUT_DIR}"
echo "Initial primary pod:          ${PRIMARY_POD}"
echo "Initial primary node:         ${PRIMARY_NODE}"
echo "New primary pod:              ${NEW_PRIMARY_POD:-n/a}"
echo "New primary node:             ${NEW_PRIMARY_NODE:-n/a}"
echo "Writer node:                  ${WRITER_NODE}"
echo "Total write attempts:         ${TOTAL_ATTEMPTS}"
echo "Successful writes:            ${SUCCESSFUL_WRITES}"
echo "Failed writes:                ${FAILED_WRITES}"
echo "Failed writes after failure:  ${FAILED_WRITES_AFTER_INJECTION}"
echo "Committed rows:               ${COMMITTED_ROWS}"
echo "Distinct committed seq:       ${DISTINCT_COMMITTED_SEQ}"
echo "Data loss check:              ${DATA_LOSS_CHECK}"
echo "Measurement check:            ${MEASUREMENT_CHECK}"
echo "Client write downtime:        ${CLIENT_WRITE_DOWNTIME_S}s"
echo "Failover detected:            ${FAILOVER_DETECTED_S}s"
echo "Cluster full recovery:        ${CLUSTER_FULL_RECOVERY_S}s"
echo "Baseline p95 latency:         ${BASELINE_P95_MS}ms"
echo "Post-recovery p95 latency:    ${POST_RECOVERY_P95_MS}ms"
echo "Run valid:                    ${RUN_VALID}"
echo "Invalid reason:               ${INVALID_REASON}"
echo "============================================================"
echo ""
echo "Generated files:"
echo "  ${WRITES_CSV}"
echo "  ${EVENTS_CSV}"
echo "  ${SUMMARY_CSV}"
echo ""

if [[ "${RUN_VALID}" != "true" ]]; then
  exit 2
fi