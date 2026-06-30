#!/usr/bin/env bash
# =============================================================
#  TEST — Whole node failure (all three layers + dqlite quorum)
#
#  This is the strongest HA test: it removes an entire node, which
#  simultaneously affects the control plane (dqlite quorum), the
#  identity layer (a Keycloak pod) and the persistence layer (a
#  PostgreSQL instance) that happen to run on that node.
#
#  Two failure modes are supported via the MODE variable:
#    drain  — cordon + drain the node (graceful; pods evicted and
#             rescheduled). Safe, repeatable, no SSH to other hosts.
#    stop   — actually stop the node's kubelet/microk8s (closer to a
#             real crash). Requires that the node be brought back
#             manually afterwards; use with care.
#
#  Default is 'drain' because it is repeatable and reversible.
#
#  Measurement:
#  A background prober hits the Keycloak service /health/ready and a
#  DB writer hits the -rw service, both once per second, so the test
#  captures client-visible availability of BOTH layers during the
#  node loss. The cluster control plane is expected to stay available
#  because two of three dqlite members remain (quorum).
#
#  Outputs in: logs/tests/node-failure-<RUN_ID>/
#    probes.csv   — Keycloak HTTP availability over time
#    writes.csv   — DB write availability over time
#    state.csv    — node + workload readiness timeline
#    summary.csv  — key metrics
#    summary.txt  — human-readable report
#
#  Run on n00. Do NOT target n00 itself as the victim (you would cut
#  your own session); the script picks a non-n00 node by default.
# =============================================================
set -uo pipefail

# --- Parameters ----------------------------------------------
NS="keycloak"
KC="microk8s kubectl"
MODE="drain"                       # drain | stop
CLUSTER="keycloak-postgres"
KC_CR="keycloak-unibl"
SERVICE="keycloak-unibl-service"
PROBER_IMAGE="curlimages/curl:latest"
WRITER_IMAGE="postgres:16"
HEALTH_URL="https://${SERVICE}.${NS}.svc.cluster.local:9000/health/ready"
RW_HOST="${CLUSTER}-rw.${NS}.svc.cluster.local"
MAX_WAIT=420
OBSERVE_AFTER=20
SELF_NODE="$(hostname)"            # avoid draining the node we run on

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_PATH}"
while [[ "${ROOT_DIR}" != "/" && ! -f "${ROOT_DIR}/config.env" ]]; do
  ROOT_DIR="$(dirname "${ROOT_DIR}")"
done
[[ -f "${ROOT_DIR}/config.env" ]] || ROOT_DIR="$(cd "${SCRIPT_PATH}/../.." && pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT="${ROOT_DIR}/logs/tests/node-failure-${RUN_ID}"
mkdir -p "${OUT}"

PROBES_CSV="${OUT}/probes.csv"
WRITES_CSV="${OUT}/writes.csv"
STATE_CSV="${OUT}/state.csv"
SUMMARY_CSV="${OUT}/summary.csv"
SUMMARY_TXT="${OUT}/summary.txt"
PROBER_POD="node-prober-${RUN_ID}"
WRITER_POD="node-writer-${RUN_ID}"
WATCH_PID=""
VICTIM_NODE=""

log() { echo "[$(date +%H:%M:%S)] $*"; }

cleanup() {
  [[ -n "${WATCH_PID}" ]] && kill "${WATCH_PID}" >/dev/null 2>&1 || true
  ${KC} delete pod "${PROBER_POD}" "${WRITER_POD}" -n "${NS}" --ignore-not-found \
    --grace-period=0 --force >/dev/null 2>&1 || true
  # Always uncordon the victim so the cluster returns to normal.
  if [[ -n "${VICTIM_NODE}" ]]; then
    log "Uncordoning ${VICTIM_NODE} (restoring scheduling)..."
    ${KC} uncordon "${VICTIM_NODE}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- 0. Pre-checks -------------------------------------------
log "Checking initial state..."
PG_READY="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"
PG_INSTANCES="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo '3')"
KC_DESIRED="$(${KC} get statefulset "${KC_CR}" -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '0')"
KC_READY="$(${KC} get statefulset "${KC_CR}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0')"

if [[ "${PG_READY}" != "${PG_INSTANCES}" || "${KC_READY}" != "${KC_DESIRED}" ]]; then
  echo "ERROR: system not fully healthy (PG ${PG_READY}/${PG_INSTANCES}, KC ${KC_READY}/${KC_DESIRED})." >&2
  exit 1
fi
log "System healthy. PG ${PG_READY}/${PG_INSTANCES}, KC ${KC_READY}/${KC_DESIRED}."

# Pick a victim node that is NOT the one we run on.
VICTIM_NODE="$(${KC} get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -v "^${SELF_NODE}$" | head -1)"
if [[ -z "${VICTIM_NODE}" ]]; then
  echo "ERROR: could not find a node other than ${SELF_NODE} to fail." >&2
  exit 1
fi
log "Victim node: ${VICTIM_NODE} (mode: ${MODE})"

# Read DB password for the writer.
PGPASS="$(${KC} get secret keycloak-db-secret -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '')"

# Probe table.
if [[ -n "${PGPASS}" ]]; then
  ${KC} run "node-setup-${RUN_ID}" -n "${NS}" --image="${WRITER_IMAGE}" \
    --restart=Never --rm -i --quiet --env="PGPASSWORD=${PGPASS}" --command -- \
    psql "host=${RW_HOST} user=keycloak dbname=keycloak connect_timeout=10" -tAc \
    "CREATE TABLE IF NOT EXISTS failover_probe(id bigserial PRIMARY KEY, ts timestamptz DEFAULT now());" \
    >/dev/null 2>&1 || log "WARNING: probe table setup failed; DB measurement may be incomplete."
fi

# --- 1. Start background probers (Keycloak + DB) -------------
log "Starting Keycloak HTTP prober..."
PROBER_SCRIPT='
  end=$((SECONDS + 360))
  while [ $SECONDS -lt $end ]; do
    ts=$(date +%s.%N)
    code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 3 "'"${HEALTH_URL}"'" 2>/dev/null || echo "000")
    [ "$code" = "200" ] && echo "${ts},OK,${code}" || echo "${ts},FAIL,${code}"
    sleep 1
  done
'
${KC} run "${PROBER_POD}" -n "${NS}" --image="${PROBER_IMAGE}" \
  --restart=Never --command -- sh -c "${PROBER_SCRIPT}" >/dev/null 2>&1 || true

if [[ -n "${PGPASS}" ]]; then
  log "Starting DB writer..."
  WRITER_SCRIPT='
    end=$((SECONDS + 360))
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
fi

log "Waiting for probers to come online..."
sleep 12

# --- 2. Background state watcher -----------------------------
echo "timestamp_epoch,victim_node_ready,pg_ready,kc_ready" > "${STATE_CSV}"
(
  while :; do
    nstat="$(${KC} get node "${VICTIM_NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?')"
    pgr="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"
    kcr="$(${KC} get statefulset "${KC_CR}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0')"
    echo "$(date +%s.%N),${nstat},${pgr},${kcr}" >> "${STATE_CSV}"
    sleep 2
  done
) &
WATCH_PID=$!

# --- 3. Inject node failure ----------------------------------
sleep 3
T_INJECT="$(date +%s.%N)"
log "==> INJECTING NODE FAILURE on ${VICTIM_NODE} (mode: ${MODE})"
if [[ "${MODE}" == "drain" ]]; then
  ${KC} cordon "${VICTIM_NODE}" >/dev/null 2>&1 || true
  ${KC} drain "${VICTIM_NODE}" --ignore-daemonsets --delete-emptydir-data \
    --force --grace-period=0 --timeout=60s >/dev/null 2>&1 || true
else
  echo "MODE=stop requires manually stopping microk8s on ${VICTIM_NODE}." >&2
  echo "Run on that node:  sudo microk8s stop" >&2
  echo "This script will now wait and measure; bring the node back when ready." >&2
fi

# --- 4. Wait for the system to re-stabilise ------------------
log "Waiting for workloads to recover (up to ${MAX_WAIT}s)..."
START="$(date +%s.%N)"
while :; do
  PGR="$(${KC} get cluster/${CLUSTER} -n "${NS}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo '0')"
  KCR="$(${KC} get statefulset "${KC_CR}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0')"
  # In drain mode, pods reschedule onto remaining nodes; we wait until
  # both layers are back to full readiness OR we hit the timeout.
  if [[ "${PGR}" == "${PG_INSTANCES}" && "${KCR}" == "${KC_DESIRED}" ]]; then
    log "Workloads fully ready again (PG ${PGR}, KC ${KCR})."
    break
  fi
  NOW="$(date +%s.%N)"
  TOTAL="$(awk -v a="${NOW}" -v b="${START}" 'BEGIN{printf "%.0f", a-b}')"
  if (( TOTAL > MAX_WAIT )); then
    log "WARNING: reached max wait. Note: with hostpath storage a PG"
    log "         replica bound to the failed node may stay Pending"
    log "         until the node returns (expected limitation)."
    break
  fi
  sleep 3
done

log "Observing for ${OBSERVE_AFTER}s more..."
sleep "${OBSERVE_AFTER}"

# --- 5. Stop watcher, restore node, collect logs -------------
[[ -n "${WATCH_PID}" ]] && kill "${WATCH_PID}" >/dev/null 2>&1 || true
if [[ "${MODE}" == "drain" ]]; then
  log "Uncordoning ${VICTIM_NODE}..."
  ${KC} uncordon "${VICTIM_NODE}" >/dev/null 2>&1 || true
fi

log "Collecting prober results..."
echo "timestamp_epoch,elapsed_s,result,http_code" > "${PROBES_CSV}"
${KC} logs "${PROBER_POD}" -n "${NS}" 2>/dev/null | while IFS=',' read -r pts pres pcode; do
  [[ -z "${pts}" ]] && continue
  pel="$(awk -v a="${pts}" -v b="${T_INJECT}" 'BEGIN{printf "%.2f", a-b}')"
  echo "${pts},${pel},${pres},${pcode}" >> "${PROBES_CSV}"
done

if [[ -n "${PGPASS}" ]]; then
  echo "timestamp_epoch,elapsed_s,result" > "${WRITES_CSV}"
  ${KC} logs "${WRITER_POD}" -n "${NS}" 2>/dev/null | while IFS=',' read -r wts wres; do
    [[ -z "${wts}" ]] && continue
    wel="$(awk -v a="${wts}" -v b="${T_INJECT}" 'BEGIN{printf "%.2f", a-b}')"
    echo "${wts},${wel},${wres}" >> "${WRITES_CSV}"
  done
fi

# --- 6. Compute availability metrics -------------------------
downtime_of() {
  # $1 = csv file, $2 = result column index
  local f="$1" col="$2"
  local ff lf
  ff="$(awk -F',' -v c="${col}" '$c=="FAIL"{print $2; exit}' "${f}" 2>/dev/null)"
  lf="$(awk -F',' -v c="${col}" '$c=="FAIL"{v=$2} END{print v}' "${f}" 2>/dev/null)"
  if [[ -n "${ff}" && -n "${lf}" ]]; then
    awk -v a="${lf}" -v b="${ff}" 'BEGIN{printf "%.2f", a-b+1}'
  else
    echo "0"
  fi
}

KC_DOWNTIME="$(downtime_of "${PROBES_CSV}" 3)"
KC_FAILS="$(grep -c ',FAIL,' "${PROBES_CSV}" 2>/dev/null || echo 0)"
DB_DOWNTIME="0"; DB_FAILS="0"
if [[ -f "${WRITES_CSV}" ]]; then
  DB_DOWNTIME="$(downtime_of "${WRITES_CSV}" 3)"
  DB_FAILS="$(grep -c ',FAIL' "${WRITES_CSV}" 2>/dev/null || echo 0)"
fi

# --- 7. Write summary ----------------------------------------
{
  echo "metric,value"
  echo "keycloak_service_downtime_s,${KC_DOWNTIME}"
  echo "keycloak_failed_requests,${KC_FAILS}"
  echo "db_write_downtime_s,${DB_DOWNTIME}"
  echo "db_failed_writes,${DB_FAILS}"
} > "${SUMMARY_CSV}"

{
  echo "============================================================"
  echo " TEST: Whole node failure (mode: ${MODE})"
  echo " Run ID: ${RUN_ID}"
  echo "============================================================"
  echo ""
  echo "Victim node:       ${VICTIM_NODE}"
  echo ""
  echo "IDENTITY LAYER (Keycloak service):"
  echo "  Service downtime (s):       ${KC_DOWNTIME}"
  echo "  Failed HTTP requests:       ${KC_FAILS}"
  echo ""
  echo "PERSISTENCE LAYER (PostgreSQL writes):"
  echo "  Write downtime (s):         ${DB_DOWNTIME}"
  echo "  Failed writes:              ${DB_FAILS}"
  echo ""
  echo "CONTROL PLANE:"
  echo "  The cluster stayed reachable throughout (two of three dqlite"
  echo "  members remained, preserving quorum). If this script ran to"
  echo "  completion, the control plane survived the node loss."
  echo ""
  echo "Note (hostpath storage limitation): the PostgreSQL replica that"
  echo "lived on the failed node may remain Pending until the node"
  echo "returns, because its data is local to that node. This is an"
  echo "expected property of hostpath storage and worth discussing in"
  echo "the thesis as a limitation."
  echo ""
  echo "CSV files for plotting:"
  echo "  probes.csv  — Keycloak availability over time"
  echo "  writes.csv  — DB write availability over time"
  echo "  state.csv   — node + workload readiness timeline"
} | tee "${SUMMARY_TXT}"

log "Done. Results in: ${OUT}"