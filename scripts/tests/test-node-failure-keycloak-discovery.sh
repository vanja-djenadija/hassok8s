#!/usr/bin/env bash
set -euo pipefail

FAILED_NODE_NAME="${FAILED_NODE_NAME:-n02}"
FAILED_NODE_IP="${FAILED_NODE_IP:-78.28.135.132}"

NAMESPACE="${NAMESPACE:-keycloak}"
CNPG_CLUSTER="${CNPG_CLUSTER:-keycloak-postgres}"

ENDPOINT_HOST="${ENDPOINT_HOST:-auth.etfbl.net}"
ENDPOINT_PORT="${ENDPOINT_PORT:-8443}"
ENDPOINT_PATH="${ENDPOINT_PATH:-/realms/unibl/.well-known/openid-configuration}"
RESOLVE_IP="${RESOLVE_IP:-127.0.0.1}"

PRE_REQUESTS="${PRE_REQUESTS:-20}"
POST_REQUESTS="${POST_REQUESTS:-220}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"

OUTDIR="${OUTDIR:-logs/tests/node-failure-keycloak-discovery-${FAILED_NODE_NAME}-manual-$(date +%Y%m%d-%H%M%S)}"
RESULTS_CSV="$OUTDIR/results.csv"
SUMMARY_TXT="$OUTDIR/summary.txt"
PRE_STATE="$OUTDIR/pre-state.txt"
FAILURE_STATE="$OUTDIR/failure-state.txt"
POST_STATE="$OUTDIR/post-state.txt"
EVENTS_LOG="$OUTDIR/events.log"

mkdir -p "$OUTDIR"

log_event() {
  echo "$(date --iso-8601=seconds),$*" | tee -a "$EVENTS_LOG"
}

run_state_snapshot() {
  local file="$1"
  {
    echo "=== Timestamp ==="
    date --iso-8601=seconds
    echo

    echo "=== Nodes ==="
    kubectl get nodes -o wide
    echo

    echo "=== CNPG cluster ==="
    kubectl get cluster "$CNPG_CLUSTER" -n "$NAMESPACE"
    echo

    echo "=== PostgreSQL pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide | grep keycloak-postgres || true
    echo

    echo "=== Keycloak pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide | grep keycloak-unibl || true
    echo

    echo "=== Ingress pods ==="
    kubectl get pods -n ingress -o wide || true
    echo

    echo "=== Keycloak services ==="
    kubectl get svc -n "$NAMESPACE" || true
    echo

    echo "=== StorageClass ==="
    kubectl get storageclass || true
    echo

    echo "=== PVCs ==="
    kubectl get pvc -A || true
  } | tee "$file"
}

get_primary_pod() {
  kubectl get cluster "$CNPG_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.status.currentPrimary}'
}

get_pod_node() {
  local pod="$1"
  kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}'
}

check_failed_node_is_not_primary() {
  local primary_pod
  local primary_node

  primary_pod="$(get_primary_pod)"
  primary_node="$(get_pod_node "$primary_pod")"

  echo "$primary_pod" > "$OUTDIR/postgres-primary-pod.txt"
  echo "$primary_node" > "$OUTDIR/postgres-primary-node.txt"

  log_event "postgres_primary_pod=$primary_pod"
  log_event "postgres_primary_node=$primary_node"
  log_event "selected_failed_node=$FAILED_NODE_NAME"

  if [[ "$primary_node" == "$FAILED_NODE_NAME" ]]; then
    echo "ERROR: Selected node $FAILED_NODE_NAME hosts PostgreSQL primary pod $primary_pod. Aborting." | tee -a "$EVENTS_LOG"
    exit 1
  fi
}

measure_once() {
  local phase="$1"
  local ts
  local res
  local code
  local time_total
  local success

  ts="$(date --iso-8601=seconds)"

  res="$(curl -k -s -o /dev/null \
    -w "%{http_code},%{time_total}" \
    --resolve "${ENDPOINT_HOST}:${ENDPOINT_PORT}:${RESOLVE_IP}" \
    "https://${ENDPOINT_HOST}:${ENDPOINT_PORT}${ENDPOINT_PATH}" || echo "000,0")"

  code="$(echo "$res" | cut -d',' -f1)"
  time_total="$(echo "$res" | cut -d',' -f2)"

  if [[ "$code" == "200" ]]; then
    success="1"
  else
    success="0"
  fi

  echo "$ts,$phase,$code,$time_total,$success" | tee -a "$RESULTS_CSV"
}

write_summary() {
  python3 - "$RESULTS_CSV" "$SUMMARY_TXT" "$FAILED_NODE_NAME" "$FAILED_NODE_IP" "$ENDPOINT_HOST" "$ENDPOINT_PORT" "$ENDPOINT_PATH" <<'PY'
import csv
import sys
from pathlib import Path

results_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
failed_node = sys.argv[3]
failed_node_ip = sys.argv[4]
endpoint_host = sys.argv[5]
endpoint_port = sys.argv[6]
endpoint_path = sys.argv[7]

rows = list(csv.DictReader(results_path.open()))

def summarize(subset):
    total = len(subset)
    success = sum(1 for r in subset if r["success"] == "1")
    failed = total - success
    availability = success / total * 100 if total else 0.0

    durations = []
    for r in subset:
        if r["success"] == "1":
            try:
                durations.append(float(r["time_total"]))
            except ValueError:
                pass

    durations_sorted = sorted(durations)

    def pct(p):
        if not durations_sorted:
            return 0.0
        idx = round((p / 100) * (len(durations_sorted) - 1))
        return durations_sorted[int(idx)]

    longest_fail = 0
    current_fail = 0
    for r in subset:
        if r["success"] == "0":
            current_fail += 1
            longest_fail = max(longest_fail, current_fail)
        else:
            current_fail = 0

    return {
        "total_requests": str(total),
        "successful_requests": str(success),
        "failed_requests": str(failed),
        "availability_percent": f"{availability:.3f}",
        "estimated_interruption_s": f"{longest_fail:.3f}",
        "min_response_time_s": f"{min(durations) if durations else 0.0:.6f}",
        "avg_response_time_s": f"{sum(durations)/len(durations) if durations else 0.0:.6f}",
        "median_response_time_s": f"{pct(50):.6f}",
        "p95_response_time_s": f"{pct(95):.6f}",
        "max_response_time_s": f"{max(durations) if durations else 0.0:.6f}",
    }

lines = []
lines.append("test=node_failure_keycloak_discovery_manual")
lines.append(f"failed_node={failed_node}")
lines.append(f"failed_node_ip={failed_node_ip}")
lines.append(f"endpoint=https://{endpoint_host}:{endpoint_port}{endpoint_path}")
lines.append("entrypoint=external_haproxy_8443")
lines.append("failure_type=manual_microk8s_stop_on_single_non_primary_node")
lines.append("note=The measurement, state capture and metric calculation were automated. The node failure and recovery were triggered manually by running microk8s stop/start on the selected node.")

for label in ["all", "pre_failure", "post_failure"]:
    subset = rows if label == "all" else [r for r in rows if r["phase"] == label]
    lines.append("")
    lines.append(f"[{label}]")
    for k, v in summarize(subset).items():
        lines.append(f"{k}={v}")

summary_path.write_text("\n".join(lines) + "\n")
print(summary_path.read_text())
PY
}

wait_for_node_ready() {
  log_event "waiting_for_${FAILED_NODE_NAME}_ready"

  for i in $(seq 1 120); do
    status="$(kubectl get node "$FAILED_NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")"

    if [[ "$status" == "True" ]]; then
      log_event "${FAILED_NODE_NAME}_ready"
      return 0
    fi

    sleep 5
  done

  log_event "warning_${FAILED_NODE_NAME}_not_ready_after_wait"
  return 1
}

log_event "test_started"
log_event "outdir=$OUTDIR"
log_event "endpoint=https://${ENDPOINT_HOST}:${ENDPOINT_PORT}${ENDPOINT_PATH}"
log_event "pre_requests=$PRE_REQUESTS"
log_event "post_requests=$POST_REQUESTS"
log_event "interval_seconds=$INTERVAL_SECONDS"

check_failed_node_is_not_primary

log_event "saving_pre_state"
run_state_snapshot "$PRE_STATE"

echo "timestamp,phase,http_code,time_total,success" > "$RESULTS_CSV"

log_event "starting_pre_failure_measurements"
for i in $(seq 1 "$PRE_REQUESTS"); do
  measure_once "pre_failure"
  sleep "$INTERVAL_SECONDS"
done

echo
echo "============================================================"
echo "MANUAL ACTION REQUIRED"
echo "Open another terminal, connect to $FAILED_NODE_NAME ($FAILED_NODE_IP), and run:"
echo
echo "  microk8s stop"
echo
echo "Wait a few seconds, then return here and press ENTER."
echo "============================================================"
echo

log_event "waiting_for_manual_microk8s_stop"
read -r -p "Press ENTER after microk8s stop has been executed on ${FAILED_NODE_NAME}: "
log_event "manual_microk8s_stop_confirmed"

log_event "saving_failure_state"
run_state_snapshot "$FAILURE_STATE" || true

log_event "starting_post_failure_measurements"
for i in $(seq 1 "$POST_REQUESTS"); do
  measure_once "post_failure"
  sleep "$INTERVAL_SECONDS"
done

echo
echo "============================================================"
echo "MANUAL RECOVERY REQUIRED"
echo "Open another terminal, connect to $FAILED_NODE_NAME ($FAILED_NODE_IP), and run:"
echo
echo "  microk8s start"
echo
echo "Then return here and press ENTER."
echo "============================================================"
echo

log_event "waiting_for_manual_microk8s_start"
read -r -p "Press ENTER after microk8s start has been executed on ${FAILED_NODE_NAME}: "
log_event "manual_microk8s_start_confirmed"

wait_for_node_ready || true

log_event "saving_post_state"
run_state_snapshot "$POST_STATE"

log_event "writing_summary"
write_summary

log_event "test_finished"
echo "Results saved in: $OUTDIR"