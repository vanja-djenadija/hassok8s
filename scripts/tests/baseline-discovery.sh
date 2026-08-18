#!/usr/bin/env bash
set -euo pipefail

URL="${URL:-https://auth.etfbl.net/realms/unibl/.well-known/openid-configuration}"
COUNT="${COUNT:-300}"
SLEEP="${SLEEP:-1}"

OUT_DIR="${OUT_DIR:-/home/vanja/hassok8s/logs/tests/baseline-discovery-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

RESULTS="$OUT_DIR/results.csv"
SUMMARY="$OUT_DIR/summary.txt"

echo "seq,timestamp,http_code,time_total,success" > "$RESULTS"

echo "[INFO] Baseline discovery test"
echo "[INFO] URL: $URL"
echo "[INFO] COUNT: $COUNT"
echo "[INFO] SLEEP: $SLEEP"
echo "[INFO] OUT_DIR: $OUT_DIR"

for i in $(seq 1 "$COUNT"); do
  TS="$(date -Iseconds)"

  LINE="$(curl -k -s -o /dev/null \
    -w "%{http_code},%{time_total}" \
    "$URL" || echo "000,0")"

  HTTP_CODE="$(echo "$LINE" | cut -d',' -f1)"
  TIME_TOTAL="$(echo "$LINE" | cut -d',' -f2)"

  if [ "$HTTP_CODE" = "200" ]; then
    SUCCESS=1
  else
    SUCCESS=0
  fi

  echo "$i,$TS,$HTTP_CODE,$TIME_TOTAL,$SUCCESS" >> "$RESULTS"

  if (( i % 30 == 0 )); then
    echo "[INFO] Progress: $i/$COUNT"
  fi

  sleep "$SLEEP"
done

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

if times:
    avg = statistics.mean(times)
    median = statistics.median(times)
    p95 = percentile(times, 95)
    maximum = max(times)
    minimum = min(times)
else:
    avg = median = p95 = maximum = minimum = 0.0

text = (
    f"test=baseline_discovery\\n"
    f"total_requests={total}\\n"
    f"successful_requests={successful}\\n"
    f"failed_requests={failed}\\n"
    f"availability_percent={availability:.3f}\\n"
    f"min_response_time_s={minimum:.6f}\\n"
    f"avg_response_time_s={avg:.6f}\\n"
    f"median_response_time_s={median:.6f}\\n"
    f"p95_response_time_s={p95:.6f}\\n"
    f"max_response_time_s={maximum:.6f}\\n"
)

summary.write_text(text)
print(text)
PY

echo "[INFO] Results saved in: $OUT_DIR"