#!/usr/bin/env bash
# =============================================================
#  TEST — Primary PostgreSQL instance failure (CNPG failover)
#
#  Measurement strategy:
#  The PRIMARY instrument is a background writer that attempts one
#  write per second against the -rw service. Because the -rw service
#  always points to the current primary, the writer directly measures
#  the client-visible write downtime. This number does NOT depend on
#  how fast the Kubernetes API server responds, so it is robust even
#  when the control plane is briefly slow.
#
#  A SECONDARY timeline of CNPG cluster state is recorded in parallel
#  for context (phase, primary, ready instances), but the headline
#  downtime metric comes from the writer.
#
#  Outputs (CSV for plotting) in: logs/tests/pg-failover-<RUN_ID>/
#    writes.csv   — per-second write success/failure (PRIMARY metric)
#    state.csv    — CNPG cluster state timeline (context)
#    summary.csv  — key metrics (bar chart)
#    summary.txt  — human-readable report
#
#  Run on n00 after deployment, while the system is healthy.
#  Recommended: run from the repo root (bash scripts/tests/<name>.sh).
# =============================================================
set -uo pipefail

# --- Parameters ----------------------------------------------
NS="keycloak"
CLUSTER="keycloak-postgres"
KC="microk8s kubectl"
WRITER_IMAGE="postgres:16"
RW_HOST="${CLUSTER}-rw.${NS}.svc.cluster.local"   # full in-cluster DNS name
MAX_WAIT=300                                       # max wait for recovery (s)
OBSERVE_AFTER=15                                   # extra seconds to record after recovery

# --- Resolve output directory (robust regardless of CWD) -----
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Walk up until we find the repo root (directory containing config.env).
ROOT_DIR="${SCRIPT_PATH}"
while [[ "${ROOT_DIR}" != "/" && ! -f "${ROOT_DIR}/config.env" ]]; do
  ROOT_DIR="$(dirname "${ROOT_DIR}")"
done
[[ -f "${ROOT_DIR}/config.env" ]] || ROOT_DIR="$(cd "${SCRIPT_PATH}/../.." && pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT_DIR}/logs/tests/pg-failover-${RUN_ID}"
mkdir -p "${OUT}"

STATE_CSV="${OUT}/state.csv"
WRITES_CSV="${OUT}/writes.csv"
SUMMARY_CSV="${OUT}/summary.csv"
SUMMARY_TXT="${OUT}/summary.txt"
WRITER_POD="pg-writer-${RUN_ID}"
WATCH_PID=""

log() { echo "[$(date +%H:%M:%S)] $*"; }

cleanup() {
  [[ -n "${WATCH_PID}" ]] && kill "${WATCH_PID}" >/dev/null 2>&1 || true
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
  exit 1
fi
log "Cluster healthy. Primary: ${INIT_PRIMARY} (${INIT_READY}/${PG_INSTANCES})."

# --- 1. Read DB password -------------------------------------
PGPASS="$(${KC} get secret keycloak-db-secret -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '')"
if [[ -z "${PGPASS}" ]]; then
  echo "ERROR: cannot read DB password from secret keycloak-db-secret." >&2
  exit 1
fi

# --- 2. Create probe table (full DNS name, longer timeout) ---
log "Creating probe table..."
SETUP_OK="false"
for attempt in 1 2 3; do
  if ${KC} run "pg-setup-${RUN_ID}-${attempt}" -n "${NS}" --image="${WRITER_IMAGE}" \
      --restart=Never --rm -i --quiet \
      --env="PGPASSWORD=${PGPASS}" --command -- \
      psql "host=${RW_HOST} user=keycloak dbname=keycloak connect_timeout=10" -tAc \
      "CREATE TABLE IF NOT EXISTS failover_probe(id bigserial PRIMARY KEY, ts timestamptz DEFAULT now());" \
      >/dev/null 2>&1; then
    SETUP_OK="true"; break
  fi
  log "  probe table attempt ${attempt} failed, retrying..."
  sleep 3
done
if [[ "${SETUP_OK}" != "true" ]]; then
  echo "ERROR: could not create probe table after retries." >&2
  echo "Check DB connectivity: ${RW_HOST}" >&2
  exit 1
fi
log "Probe table ready."

# --- 3. Start background writer (PRIMARY measurement) --------
log "Starting background writer against ${RW_HOST}..."
WRITER_SCRIPT='
  end=$((SECONDS + 280))
  while [ $SECONDS -lt $end ]; do
    ts=$(date +%s.%N)
    if psql "host='"${RW_HOST}"' user=keycloak dbname=keycloak connect_timeout=2" \
       -tAc "INSERT INTO failover_probe DEFAULT VALUES;" >/dev/null 2>&1; then
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

# Wait for the writer to actually start producing lines.
log "Waiting for writer to come online..."
for i in $(seq 1 30); do
  if ${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null | grep -q ',OK'; then
    log "Writer is online."
    break
  fi
  sleep 2
done

# --- 4. Start background state watcher (SECONDARY context) ---
# A single long-lived watch avoids repeated slow 'get' calls.
echo "timestamp_epoch,phase,currentPrimary,readyInstances" > "${STATE_CSV}"
(
  ${KC} get cluster/${CLUSTER} -n "${NS}" \
    -o jsonpath='{.status.phase}|{.status.currentPrimary}|{.status.readyInstances}{"\n"}' \
    --watch 2>/dev/null | while IFS='|' read -r p cp ri; do
      echo "$(date +%s.%N),${p},${cp},${ri}" >> "${STATE_CSV}"
    done
) &
WATCH_PID=$!

# --- 5. Inject the failure -----------------------------------
sleep 3
T_INJECT="$(date +%s.%N)"
log "==> INJECTING FAILURE: force-deleting primary ${INIT_PRIMARY}"
${KC} delete pod "${INIT_PRIMARY}" -n "${NS}" --grace-period=0 --force >/dev/null 2>&1 || true

# --- 6. Wait for recovery (based on cluster status) ----------
log "Waiting for full recovery (up to ${MAX_WAIT}s)..."
START="$(date +%s.%N)"
NEW_PRIMARY=""
while :; do
  PHASE="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  CUR_PRIMARY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo '')"
  READY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"

  [[ -n "${CUR_PRIMARY}" && "${CUR_PRIMARY}" != "${INIT_PRIMARY}" ]] && NEW_PRIMARY="${CUR_PRIMARY}"

  if [[ "${PHASE}" == "Cluster in healthy state" && "${READY}" == "${PG_INSTANCES}" && -n "${NEW_PRIMARY}" ]]; then
    log "Cluster healthy again. New primary: ${NEW_PRIMARY}"
    break
  fi

  NOW="$(date +%s.%N)"
  TOTAL="$(awk -v a="${NOW}" -v b="${START}" 'BEGIN{printf "%.0f", a-b}')"
  if (( TOTAL > MAX_WAIT )); then
    log "WARNING: reached max wait without full recovery."
    break
  fi
  sleep 2
done

# Record a bit longer so the writer captures the fully-recovered tail.
log "Observing for ${OBSERVE_AFTER}s more..."
sleep "${OBSERVE_AFTER}"

# --- 7. Stop watcher and collect writer log ------------------
[[ -n "${WATCH_PID}" ]] && kill "${WATCH_PID}" >/dev/null 2>&1 || true

log "Collecting writer results..."
echo "timestamp_epoch,elapsed_s,result" > "${WRITES_CSV}"
${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null | while IFS=',' read -r wts wres; do
  [[ -z "${wts}" ]] && continue
  wel="$(awk -v a="${wts}" -v b="${T_INJECT}" 'BEGIN{printf "%.2f", a-b}')"
  echo "${wts},${wel},${wres}" >> "${WRITES_CSV}"
done

# --- 8. Compute client-side downtime from writer -------------
# Downtime = elapsed between the last OK before the gap and the first OK
# after the gap; failed writes = count of FAIL lines.
WRITE_TOTAL="$(($(wc -l < "${WRITES_CSV}") - 1))"
WRITE_FAILS="$(grep -c ',FAIL' "${WRITES_CSV}" 2>/dev/null || echo 0)"

# First and last FAIL elapsed times (the outage window).
FIRST_FAIL="$(awk -F',' '$3=="FAIL"{print $2; exit}' "${WRITES_CSV}")"
LAST_FAIL="$(awk -F',' '$3=="FAIL"{v=$2} END{print v}' "${WRITES_CSV}")"
if [[ -n "${FIRST_FAIL}" && -n "${LAST_FAIL}" ]]; then
  DOWNTIME="$(awk -v a="${LAST_FAIL}" -v b="${FIRST_FAIL}" 'BEGIN{printf "%.2f", a-b+1}')"
else
  DOWNTIME="0"   # no failed writes observed
fi

# Data-loss check: committed rows.
ROWS="$(${KC} run "pg-check-${RUN_ID}" -n "${NS}" --image="${WRITER_IMAGE}" \
  --restart=Never --rm -i --quiet --env="PGPASSWORD=${PGPASS}" --command -- \
  psql "host=${RW_HOST} user=keycloak dbname=keycloak connect_timeout=10" -tAc \
  "SELECT count(*) FROM failover_probe;" 2>/dev/null | tr -d '[:space:]' || echo 'n/a')"

# --- 9. Write summary ----------------------------------------
{
  echo "metric,value"
  echo "client_write_downtime_s,${DOWNTIME}"
  echo "failed_writes,${WRITE_FAILS}"
  echo "total_write_attempts,${WRITE_TOTAL}"
  echo "committed_rows,${ROWS}"
} > "${SUMMARY_CSV}"

{
  echo "============================================================"
  echo " TEST: Primary PostgreSQL instance failure (CNPG failover)"
  echo " Run ID: ${RUN_ID}"
  echo "============================================================"
  echo ""
  echo "Initial primary:  ${INIT_PRIMARY}"
  echo "New primary:      ${NEW_PRIMARY:-<unchanged>}"
  echo "Instances:        ${PG_INSTANCES}"
  echo ""
  echo "CLIENT-SIDE MEASUREMENT (primary metric, robust):"
  echo "  Write downtime (s):        ${DOWNTIME}"
  echo "  Failed write attempts:     ${WRITE_FAILS}"
  echo "  Total write attempts:      ${WRITE_TOTAL}"
  echo "  Committed rows (no loss):  ${ROWS}"
  echo ""
  echo "CSV files for plotting:"
  echo "  writes.csv  — write availability over time (outage window)"
  echo "  state.csv   — CNPG cluster state timeline (context)"
  echo "  summary.csv — key metrics"
} | tee "${SUMMARY_TXT}"

log "Done. Results in: ${OUT}"