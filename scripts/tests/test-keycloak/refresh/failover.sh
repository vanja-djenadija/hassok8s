#!/usr/bin/env bash
set -euo pipefail

KC_URL="${KC_URL:-https://auth.etfbl.net}"
REALM="${REALM:-unibl}"
CLIENT_ID="${CLIENT_ID:-ha-test-cli}"
USERNAME="${USERNAME:-ha.test}"
PASSWORD="${PASSWORD:?PASSWORD environment variable is required}"

NAMESPACE="${NAMESPACE:-keycloak}"
VICTIM_POD="${VICTIM_POD:?VICTIM_POD environment variable is required}"

COUNT_AFTER_DELETE="${COUNT_AFTER_DELETE:-120}"
SLEEP="${SLEEP:-1}"

OUT_DIR="${OUT_DIR:-/home/vanja/hassok8s/logs/tests/keycloak-refresh-failover-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

TOKEN_URL="$KC_URL/realms/$REALM/protocol/openid-connect/token"
RESULTS="$OUT_DIR/results.csv"
EVENTS="$OUT_DIR/events.txt"
SUMMARY="$OUT_DIR/summary.txt"

echo "[INFO] Refresh-token failover test"
echo "[INFO] TOKEN_URL: $TOKEN_URL"
echo "[INFO] VICTIM_POD: $VICTIM_POD"
echo "[INFO] OUT_DIR: $OUT_DIR"

echo "[INFO] Cluster state before test" | tee -a "$EVENTS"
kubectl get pods -n "$NAMESPACE" -o wide | tee -a "$EVENTS"

echo "[INFO] Getting initial tokens..." | tee -a "$EVENTS"

INITIAL_BODY="$OUT_DIR/initial-token.json"
INITIAL_STATUS="$(curl -k -s -o "$INITIAL_BODY" \
  -w "%{http_code}" \
  -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=$CLIENT_ID" \
  -d "username=$USERNAME" \
  -d "password=$PASSWORD")"

if [ "$INITIAL_STATUS" != "200" ]; then
  echo "[ERROR] Initial token request failed with status $INITIAL_STATUS" | tee -a "$EVENTS"
  cat "$INITIAL_BODY" | tee -a "$EVENTS"
  exit 1
fi

REFRESH_TOKEN="$(python3 - <<PY
import json
from pathlib import Path
data=json.loads(Path("$INITIAL_BODY").read_text())
print(data.get("refresh_token",""))
PY
)"

if [ -z "$REFRESH_TOKEN" ]; then
  echo "[ERROR] No refresh_token in initial response" | tee -a "$EVENTS"
  exit 1
fi

rm -f "$INITIAL_BODY"

echo "[INFO] Initial refresh token obtained" | tee -a "$EVENTS"
echo "seq,timestamp,phase,http_code,time_total,success" > "$RESULTS"

echo "[INFO] Baseline refresh before deleting pod..." | tee -a "$EVENTS"

for i in $(seq 1 10); do
  TS="$(date -Iseconds)"
  BODY="$OUT_DIR/pre-body-${i}.json"

  LINE="$(curl -k -s -o "$BODY" \
    -w "%{http_code},%{time_total}" \
    -X POST "$TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=$CLIENT_ID" \
    -d "refresh_token=$REFRESH_TOKEN" || echo "000,0")"

  HTTP_CODE="$(echo "$LINE" | cut -d',' -f1)"
  TIME_TOTAL="$(echo "$LINE" | cut -d',' -f2)"

  if [ "$HTTP_CODE" = "200" ] && grep -q "access_token" "$BODY"; then
    SUCCESS=1
    NEW_REFRESH="$(python3 - <<PY
import json
from pathlib import Path
data=json.loads(Path("$BODY").read_text())
print(data.get("refresh_token",""))
PY
)"
    if [ -n "$NEW_REFRESH" ]; then
      REFRESH_TOKEN="$NEW_REFRESH"
    fi
    rm -f "$BODY"
  else
    SUCCESS=0
  fi

  echo "$i,$TS,pre_delete,$HTTP_CODE,$TIME_TOTAL,$SUCCESS" >> "$RESULTS"
  sleep "$SLEEP"
done

DELETE_TS="$(date -Iseconds)"
echo "[EVENT] $DELETE_TS deleting pod $VICTIM_POD" | tee -a "$EVENTS"
kubectl delete pod -n "$NAMESPACE" "$VICTIM_POD" --wait=false | tee -a "$EVENTS"

echo "[INFO] Refresh attempts after deleting pod..." | tee -a "$EVENTS"

for i in $(seq 1 "$COUNT_AFTER_DELETE"); do
  TS="$(date -Iseconds)"
  BODY="$OUT_DIR/post-body-${i}.json"
  SEQ=$((10 + i))

  LINE="$(curl -k -s -o "$BODY" \
    -w "%{http_code},%{time_total}" \
    -X POST "$TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=$CLIENT_ID" \
    -d "refresh_token=$REFRESH_TOKEN" || echo "000,0")"

  HTTP_CODE="$(echo "$LINE" | cut -d',' -f1)"
  TIME_TOTAL="$(echo "$LINE" | cut -d',' -f2)"

  if [ "$HTTP_CODE" = "200" ] && grep -q "access_token" "$BODY"; then
    SUCCESS=1
    NEW_REFRESH="$(python3 - <<PY
import json
from pathlib import Path
data=json.loads(Path("$BODY").read_text())
print(data.get("refresh_token",""))
PY
)"
    if [ -n "$NEW_REFRESH" ]; then
      REFRESH_TOKEN="$NEW_REFRESH"
    fi
    rm -f "$BODY"
  else
    SUCCESS=0
  fi

  echo "$SEQ,$TS,post_delete,$HTTP_CODE,$TIME_TOTAL,$SUCCESS" >> "$RESULTS"

  if (( i % 30 == 0 )); then
    echo "[INFO] Progress after delete: $i/$COUNT_AFTER_DELETE"
  fi

  sleep "$SLEEP"
done

echo "[INFO] Cluster state after test" | tee -a "$EVENTS"
kubectl get pods -n "$NAMESPACE" -o wide | tee -a "$EVENTS"

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
else:
    avg = median = p95 = maximum = 0.0

text = (
    f"test=keycloak_refresh_failover\\n"
    f"victim_pod=$VICTIM_POD\\n"
    f"total_requests={total}\\n"
    f"successful_requests={successful}\\n"
    f"failed_requests={failed}\\n"
    f"availability_percent={availability:.3f}\\n"
    f"post_delete_requests={post_total}\\n"
    f"post_delete_successful={post_success}\\n"
    f"post_delete_failed={post_failed}\\n"
    f"post_delete_availability_percent={post_availability:.3f}\\n"
    f"estimated_refresh_interruption_s={interruption_s:.3f}\\n"
    f"avg_response_time_s={avg:.6f}\\n"
    f"median_response_time_s={median:.6f}\\n"
    f"p95_response_time_s={p95:.6f}\\n"
    f"max_response_time_s={maximum:.6f}\\n"
)

summary.write_text(text)
print(text)
PY

echo "[INFO] Results saved in: $OUT_DIR"