#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ingress}"
URL="${URL:-https://auth.etfbl.net/realms/unibl/.well-known/openid-configuration}"
VICTIM_POD="${VICTIM_POD:?VICTIM_POD environment variable is required}"

PRE_REQUESTS="${PRE_REQUESTS:-10}"
POST_REQUESTS="${POST_REQUESTS:-180}"
SLEEP="${SLEEP:-1}"

OUT_DIR="${OUT_DIR:-/home/vanja/hassok8s/logs/tests/ingress-failover-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

RESULTS="$OUT_DIR/results.csv"
EVENTS="$OUT_DIR/events.txt"
SUMMARY="$OUT_DIR/summary.txt"

echo "[INFO] Ingress failover test"
echo "[INFO] URL: $URL"
echo "[INFO] NAMESPACE: $NAMESPACE"
echo "[INFO] VICTIM_POD: $VICTIM_POD"
echo "[INFO] OUT_DIR: $OUT_DIR"

echo "[INFO] Cluster state before test" | tee -a "$EVENTS"
kubectl get pods -n "$NAMESPACE" -o wide | tee -a "$EVENTS"
kubectl get pods -n keycloak -o wide | tee -a "$EVENTS"

echo "seq,timestamp,phase,http_code,time_total,success" > "$RESULTS"

echo "[INFO] Baseline requests before deleting ingress pod..." | tee -a "$EVENTS"

for i in $(seq 1 "$PRE_REQUESTS"); do
  TS="$(date -Iseconds)"

  LINE="$(curl -k -s -o /dev/null \
    --resolve auth.etfbl.net:8443:127.0.0.1 \
    -w "%{http_code},%{time_total}" \
    "$URL" || echo "000,0")"

  HTTP_CODE="$(echo "$LINE" | cut -d',' -f1)"
  TIME_TOTAL="$(echo "$LINE" | cut -d',' -f2)"

  if [ "$HTTP_CODE" = "200" ]; then
    SUCCESS=1
  else
    SUCCESS=0
  fi

  echo "$i,$TS,pre_delete,$HTTP_CODE,$TIME_TOTAL,$SUCCESS" >> "$RESULTS"
  sleep "$SLEEP"
done

DELETE_TS="$(date -Iseconds)"
echo "[EVENT] $DELETE_TS deleting ingress pod $VICTIM_POD" | tee -a "$EVENTS"
kubectl delete pod -n "$NAMESPACE" "$VICTIM_POD" --wait=false | tee -a "$EVENTS"

echo "[INFO] Requests after deleting ingress pod..." | tee -a "$EVENTS"

for i in $(seq 1 "$POST_REQUESTS"); do
  TS="$(date -Iseconds)"
  SEQ=$((PRE_REQUESTS + i))

  LINE="$(curl -k -s -o /dev/null \
    --resolve auth.etfbl.net:8443:127.0.0.1 \
    -w "%{http_code},%{time_total}" \
    "$URL" || echo "000,0")"

  HTTP_CODE="$(echo "$LINE" | cut -d',' -f1)"
  TIME_TOTAL="$(echo "$LINE" | cut -d',' -f2)"

  if [ "$HTTP_CODE" = "200" ]; then
    SUCCESS=1
  else
    SUCCESS=0
  fi

  echo "$SEQ,$TS,post_delete,$HTTP_CODE,$TIME_TOTAL,$SUCCESS" >> "$RESULTS"

  if (( i % 30 == 0 )); then
    echo "[INFO] Progress after delete: $i/$POST_REQUESTS"
  fi

  sleep "$SLEEP"
done

echo "[INFO] Cluster state after test" | tee -a "$EVENTS"
kubectl get pods -n "$NAMESPACE" -o wide | tee -a "$EVENTS"
kubectl get pods -n keycloak -o wide | tee -a "$EVENTS"

python3 - <<PY
import csv
import statistics
from pathlib import Path

results = Path("$RESULTS")
summary = Path("$SUMMARY")
rows = list(csv.DictReader(results.open()))

total = len(rows)
successful = sum(1 for r in rows if r["success"] == "1")
failed = total - successful
availability = successful / total * 100 if total else 0

post = [r for r in rows if r["phase"] == "post_delete"]
post_total = len(post)
post_success = sum(1 for r in post if r["success"] == "1")
post_failed = post_total - post_success
post_availability = post_success / post_total * 100 if post_total else 0

times = [float(r["time_total"]) for r in rows if r["success"] == "1"]

def percentile(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = (len(values) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(values) - 1)
    if f == c:
        return values[f]
    return values[f] + (values[c] - values[f]) * (k - f)

max_fail_streak = 0
current = 0
for r in post:
    if r["success"] == "0":
        current += 1
        max_fail_streak = max(max_fail_streak, current)
    else:
        current = 0

interruption_s = max_fail_streak * float("$SLEEP")

if times:
    avg = statistics.mean(times)
    median = statistics.median(times)
    p95 = percentile(times, 95)
    maximum = max(times)
    minimum = min(times)
else:
    avg = median = p95 = maximum = minimum = 0.0

status_codes = {}
for r in rows:
    status_codes[r["http_code"]] = status_codes.get(r["http_code"], 0) + 1

text = (
    f"test=ingress_failover\\n"
    f"victim_pod=$VICTIM_POD\\n"
    f"total_requests={total}\\n"
    f"successful_requests={successful}\\n"
    f"failed_requests={failed}\\n"
    f"availability_percent={availability:.3f}\\n"
    f"post_delete_requests={post_total}\\n"
    f"post_delete_successful={post_success}\\n"
    f"post_delete_failed={post_failed}\\n"
    f"post_delete_availability_percent={post_availability:.3f}\\n"
    f"estimated_interruption_s={interruption_s:.3f}\\n"
    f"min_response_time_s={minimum:.6f}\\n"
    f"avg_response_time_s={avg:.6f}\\n"
    f"median_response_time_s={median:.6f}\\n"
    f"p95_response_time_s={p95:.6f}\\n"
    f"max_response_time_s={maximum:.6f}\\n"
    f"status_codes={status_codes}\\n"
)

summary.write_text(text)
print(text)
PY

echo "[INFO] Results saved in: $OUT_DIR"