#!/usr/bin/env bash
# =============================================================
#  TEST — Primary PostgreSQL instance failure (CNPG failover)
#  Measures detection time, replica promotion time and full
#  recovery time, plus write availability and any data loss
#  during the transition.
#
#  Outputs (CSV for plotting) in: logs/tests/pg-failover-<RUN_ID>/
#    state.csv    — time series of cluster state (for timeline chart)
#    writes.csv   — per-second write success/failure (availability chart)
#    summary.csv  — key metrics (for bar chart)
#    summary.txt  — human-readable report
#
#  Run on n00 after deployment, while the system is healthy.
# =============================================================
set -uo pipefail

# --- Parameters ----------------------------------------------
NS="keycloak"
CLUSTER="keycloak-postgres"
KC="microk8s kubectl"
POLL_INTERVAL=1          # seconds between state samples
MAX_WAIT=300             # max wait for recovery (s)
USE_WRITER="true"        # measure write availability (needs DB credentials)
WRITER_IMAGE="postgres:16"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT_DIR}/logs/tests/pg-failover-${RUN_ID}"
mkdir -p "${OUT}"

STATE_CSV="${OUT}/state.csv"
WRITES_CSV="${OUT}/writes.csv"
SUMMARY_CSV="${OUT}/summary.csv"
SUMMARY_TXT="${OUT}/summary.txt"
WRITER_POD="pg-writer-${RUN_ID}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

cleanup() {
  ${KC} delete pod "${WRITER_POD}" -n "${NS}" --ignore-not-found \
    --grace-period=0 --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 0. Verify the cluster is healthy before the test --------
log "Checking initial cluster state..."
INIT_PHASE="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
INIT_PRIMARY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo '')"
INIT_READY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"
PG_INSTANCES="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo '3')"

if [[ "${INIT_PHASE}" != "Cluster in healthy state" || "${INIT_READY}" != "${PG_INSTANCES}" ]]; then
  echo "ERROR: cluster is not healthy before the test (phase='${INIT_PHASE}', ready='${INIT_READY}/${PG_INSTANCES}')." >&2
  echo "Test aborted. Wait for the cluster to become healthy and retry." >&2
  exit 1
fi
log "Cluster healthy. Primary instance: ${INIT_PRIMARY} (${INIT_READY}/${PG_INSTANCES})."

# --- 1. Prepare write measurement (optional) -----------------
PGPASS=""
if [[ "${USE_WRITER}" == "true" ]]; then
  PGPASS="$(${KC} get secret keycloak-db-secret -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '')"
  if [[ -z "${PGPASS}" ]]; then
    log "WARNING: cannot read DB password; write measurement skipped."
    USE_WRITER="false"
  fi
fi

if [[ "${USE_WRITER}" == "true" ]]; then
  log "Creating probe table for write measurement..."
  ${KC} run "pg-setup-${RUN_ID}" -n "${NS}" --image="${WRITER_IMAGE}" \
    --restart=Never --rm -i --quiet \
    --env="PGPASSWORD=${PGPASS}" --command -- \
    psql -h "${CLUSTER}-rw" -U keycloak -d keycloak -tAc \
    "CREATE TABLE IF NOT EXISTS failover_probe(id bigserial PRIMARY KEY, ts timestamptz DEFAULT now());" \
    >/dev/null 2>&1 || { log "WARNING: probe table setup failed; write measurement skipped."; USE_WRITER="false"; }
fi

# --- 2. Start background writer (measures availability) ------
if [[ "${USE_WRITER}" == "true" ]]; then
  log "Starting background writer (one insert per second)..."
  WRITER_SCRIPT='
    end=$((SECONDS + 240))
    while [ $SECONDS -lt $end ]; do
      ts=$(date +%s.%N)
      if psql -h '"${CLUSTER}"'-rw -U keycloak -d keycloak -tAc \
         "INSERT INTO failover_probe DEFAULT VALUES;" >/dev/null 2>&1; then
        echo "${ts},OK"
      else
        echo "${ts},FAIL"
      fi
      sleep 1
    done
  '
  ${KC} run "${WRITER_POD}" -n "${NS}" --image="${WRITER_IMAGE}" \
    --restart=Never --env="PGPASSWORD=${PGPASS}" \
    --command -- bash -c "${WRITER_SCRIPT}" >/dev/null 2>&1 || true
  # Give the writer a moment to start.
  sleep 8
fi

# --- 3. CSV headers ------------------------------------------
echo "timestamp_epoch,elapsed_s,phase,currentPrimary,targetPrimary,readyInstances" > "${STATE_CSV}"

# --- 4. Inject the failure -----------------------------------
T_INJECT="$(date +%s.%N)"
log "==> INJECTING FAILURE: deleting primary instance ${INIT_PRIMARY}"
${KC} delete pod "${INIT_PRIMARY}" -n "${NS}" --grace-period=0 --force >/dev/null 2>&1 || true

# --- 5. Track the recovery -----------------------------------
T_DETECT=""        # first sign of failure (phase changes or ready drops)
T_NEW_PRIMARY=""   # new primary elected and ready
T_RECOVERED=""     # cluster fully healthy again (all instances)

log "Tracking recovery (up to ${MAX_WAIT}s)..."
START="$(date +%s.%N)"
while :; do
  NOW="$(date +%s.%N)"
  ELAPSED="$(awk -v a="${NOW}" -v b="${T_INJECT}" 'BEGIN{printf "%.2f", a-b}')"

  PHASE="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  CUR_PRIMARY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo '')"
  TGT_PRIMARY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.targetPrimary}' 2>/dev/null || echo '')"
  READY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"

  echo "${NOW},${ELAPSED},${PHASE},${CUR_PRIMARY},${TGT_PRIMARY},${READY}" >> "${STATE_CSV}"
  log "  t=${ELAPSED}s phase='${PHASE}' primary='${CUR_PRIMARY}' ready='${READY}/${PG_INSTANCES}'"

  # Detection: first deviation from the healthy state.
  if [[ -z "${T_DETECT}" ]]; then
    if [[ "${PHASE}" != "Cluster in healthy state" || "${READY}" != "${PG_INSTANCES}" || "${TGT_PRIMARY}" != "${INIT_PRIMARY}" ]]; then
      T_DETECT="${NOW}"
      log "  >> FAILURE DETECTED at t=${ELAPSED}s"
    fi
  fi

  # New primary: currentPrimary changed and differs from the original.
  if [[ -z "${T_NEW_PRIMARY}" && -n "${CUR_PRIMARY}" && "${CUR_PRIMARY}" != "${INIT_PRIMARY}" ]]; then
    T_NEW_PRIMARY="${NOW}"
    log "  >> NEW PRIMARY: ${CUR_PRIMARY} at t=${ELAPSED}s"
  fi

  # Full recovery: healthy state with all instances ready.
  if [[ "${PHASE}" == "Cluster in healthy state" && "${READY}" == "${PG_INSTANCES}" ]]; then
    # Require detection to have been recorded (so we don't catch the start).
    if [[ -n "${T_DETECT}" ]]; then
      T_RECOVERED="${NOW}"
      log "  >> FULL RECOVERY at t=${ELAPSED}s"
      break
    fi
  fi

  # Timeout.
  TOTAL="$(awk -v a="${NOW}" -v b="${START}" 'BEGIN{printf "%.0f", a-b}')"
  if (( TOTAL > MAX_WAIT )); then
    log "WARNING: reached max wait (${MAX_WAIT}s) without full recovery."
    break
  fi
  sleep "${POLL_INTERVAL}"
done

# --- 6. Collect write measurements ---------------------------
WRITE_DOWNTIME="n/a"
WRITE_FAILS="n/a"
WRITE_TOTAL="n/a"
ROWS="n/a"
if [[ "${USE_WRITER}" == "true" ]]; then
  log "Collecting writer results..."
  sleep 5
  echo "timestamp_epoch,elapsed_s,result" > "${WRITES_CSV}"
  ${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null | while IFS=',' read -r wts wres; do
    [[ -z "${wts}" ]] && continue
    wel="$(awk -v a="${wts}" -v b="${T_INJECT}" 'BEGIN{printf "%.2f", a-b}')"
    echo "${wts},${wel},${wres}" >> "${WRITES_CSV}"
  done
  # Failed writes and estimated downtime (one write per second).
  WRITE_TOTAL="$(grep -c ',' "${WRITES_CSV}" 2>/dev/null || echo 0)"
  WRITE_TOTAL=$(( WRITE_TOTAL - 1 ))   # minus header
  WRITE_FAILS="$(grep -c ',FAIL' "${WRITES_CSV}" 2>/dev/null || echo 0)"
  WRITE_DOWNTIME="${WRITE_FAILS}"      # seconds (1 write/s)

  # Data-loss check: total rows committed to the probe table.
  ROWS="$(${KC} run "pg-check-${RUN_ID}" -n "${NS}" --image="${WRITER_IMAGE}" \
    --restart=Never --rm -i --quiet --env="PGPASSWORD=${PGPASS}" --command -- \
    psql -h "${CLUSTER}-rw" -U keycloak -d keycloak -tAc \
    "SELECT count(*) FROM failover_probe;" 2>/dev/null | tr -d '[:space:]' || echo 'n/a')"
fi

# --- 7. Compute metrics --------------------------------------
dur() { awk -v a="$1" -v b="$2" 'BEGIN{ if(a==""||b=="") print "n/a"; else printf "%.2f", a-b }'; }

DETECTION="$(dur "${T_DETECT}" "${T_INJECT}")"
PROMOTION="$(dur "${T_NEW_PRIMARY}" "${T_INJECT}")"
RECOVERY="$(dur "${T_RECOVERED}" "${T_INJECT}")"

# --- 8. Write the summary ------------------------------------
{
  echo "metric,value_seconds"
  echo "detection_time,${DETECTION}"
  echo "promotion_time,${PROMOTION}"
  echo "full_recovery_time,${RECOVERY}"
  echo "write_downtime,${WRITE_DOWNTIME}"
  echo "failed_writes,${WRITE_FAILS}"
} > "${SUMMARY_CSV}"

{
  echo "============================================================"
  echo " TEST: Primary PostgreSQL instance failure (CNPG failover)"
  echo " Run ID: ${RUN_ID}"
  echo "============================================================"
  echo ""
  echo "Initial primary instance:    ${INIT_PRIMARY}"
  echo "New primary instance:        ${CUR_PRIMARY}"
  echo "Number of instances:         ${PG_INSTANCES}"
  echo ""
  echo "MEASURED METRICS (seconds):"
  echo "  Failure detection time:          ${DETECTION}"
  echo "  New primary promotion time:      ${PROMOTION}"
  echo "  Full recovery time:              ${RECOVERY}"
  echo ""
  if [[ "${USE_WRITER}" == "true" ]]; then
    echo "WRITE AVAILABILITY:"
    echo "  Total write attempts:            ${WRITE_TOTAL}"
    echo "  Failed writes:                   ${WRITE_FAILS}"
    echo "  Estimated write downtime (s):    ${WRITE_DOWNTIME}"
    echo "  Total rows in probe table:       ${ROWS}"
    echo ""
  fi
  echo "CSV files for plotting:"
  echo "  state.csv   — cluster state timeline"
  echo "  writes.csv  — write availability over time"
  echo "  summary.csv — key metrics (bar chart)"
} | tee "${SUMMARY_TXT}"

log "Done. Results in: ${OUT}"