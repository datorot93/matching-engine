# Spec 5: Integration Glue (Metrics, Dashboards, Seed Data, End-to-End Wiring)

## 1. Role and Scope

**Role Name:** Integration Glue Developer

**Scope:** Implement the connective tissue that ties all components together into a running experiment. This includes:

1. **Grafana dashboard JSON** -- The 4 key panels defined in `experiment-design.md` Section 9.5.
2. **Prometheus recording rules** -- Pre-computed queries for pass/fail evaluation.
3. **Seed data generation** -- The logic that creates realistic resting order distributions for pre-seeding Order Books.
4. **Smoke test script** -- An end-to-end verification that all components are wired correctly before running the full experiment.
5. **Results collection script** -- Queries Prometheus after a test run to extract pass/fail metrics and generate a summary report.

**Out of Scope:** The ME application code (Spec 1), the Gateway application code (Spec 2), the k6 test scripts themselves (Spec 3), and the Kubernetes manifests / deployment scripts (Spec 4). This spec is the "last mile" of wiring.

---

## 2. Technology Stack

| Component | Technology | Version |
|:---|:---|:---|
| Grafana dashboard | JSON model (provisioned via ConfigMap) | Grafana 10.x compatible |
| Prometheus rules | YAML (recording rules) | Prometheus 2.x |
| Smoke test | Bash + curl + jq | -- |
| Results collection | Bash + curl (Prometheus HTTP API) | -- |

---

## 3. Project Structure

```
infra/
  grafana/
    dashboards/
      matching-engine-experiment.json    # Main experiment dashboard (4 panels)
  prometheus/
    recording-rules.yaml                 # Pre-computed recording rules
  scripts/
    smoke-test.sh                        # End-to-end wiring verification
    collect-results.sh                   # Post-test results collection and pass/fail evaluation
    generate-seed-data.sh                # Convenience wrapper for seeding
```

---

## 4. Grafana Dashboard

### 4.1 Dashboard Overview

The dashboard contains the 4 key panels defined in `experiment-design.md` Section 9.5, plus 2 additional utility panels. It is provisioned as a ConfigMap mounted into the Grafana pod.

**Dashboard title:** `Matching Engine Experiment`
**Refresh interval:** 5 seconds
**Time range:** Last 15 minutes

### 4.2 Panel Specifications

#### Panel 1: Matching Latency Heatmap (ASR 1 Primary)

| Property | Value |
|:---|:---|
| Title | Matching Latency (ASR 1) |
| Type | Heatmap |
| Query | `histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))` |
| Additional series | p50: `histogram_quantile(0.50, ...)`, p95: `histogram_quantile(0.95, ...)` |
| Threshold line | Horizontal line at 0.2 (200ms target, red) |
| Budget line | Horizontal line at 0.05 (50ms budget estimate, yellow) |
| Y-axis | Seconds (0 to 0.5) |
| Legend | `{{shard}}` |

**Alternative (if heatmap is complex):** Use a time series panel with 3 lines (p50, p95, p99) per shard.

**Simplified query for time series:**
```
# p99 per shard
histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

# p95 per shard
histogram_quantile(0.95, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

# p50 per shard
histogram_quantile(0.50, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))
```

#### Panel 2: Throughput Per Shard (ASR 2 Primary)

| Property | Value |
|:---|:---|
| Title | Match Throughput per Shard (ASR 2) |
| Type | Time series |
| Query | `rate(me_matches_total[30s]) * 60` (matches/min per shard) |
| Additional series | `sum(rate(me_matches_total[30s])) * 60` (aggregate) |
| Threshold line | 1000 matches/min (normal target), 5000 matches/min (peak target) |
| Y-axis | Matches/minute |
| Legend | `shard={{shard}}` and `aggregate` |

#### Panel 3: Latency Budget Breakdown

| Property | Value |
|:---|:---|
| Title | Latency Budget Breakdown |
| Type | Stacked bar chart or time series (stacked) |
| Queries | One series per sub-component, each showing the avg duration: |

```
# Validation
avg(rate(me_order_validation_duration_seconds_sum[1m]) / rate(me_order_validation_duration_seconds_count[1m]))

# Order Book Insertion
avg(rate(me_orderbook_insertion_duration_seconds_sum[1m]) / rate(me_orderbook_insertion_duration_seconds_count[1m]))

# Matching Algorithm
avg(rate(me_matching_algorithm_duration_seconds_sum[1m]) / rate(me_matching_algorithm_duration_seconds_count[1m]))

# WAL Append
avg(rate(me_wal_append_duration_seconds_sum[1m]) / rate(me_wal_append_duration_seconds_count[1m]))

# Event Publish
avg(rate(me_event_publish_duration_seconds_sum[1m]) / rate(me_event_publish_duration_seconds_count[1m]))
```

| Y-axis | Seconds |
| Legend | `validation`, `orderbook_insertion`, `matching_algorithm`, `wal_append`, `event_publish` |

#### Panel 4: Resource Saturation

| Property | Value |
|:---|:---|
| Title | Resource Saturation |
| Type | Time series |
| Queries | |

```
# Ring Buffer Utilization (per shard)
me_ringbuffer_utilization_ratio

# Order Book Depth (bid + ask, per shard)
me_orderbook_depth

# JVM GC Pause Duration (max over 1m window)
max_over_time(jvm_gc_pause_seconds_max[1m])

# JVM Heap Used
jvm_memory_used_bytes{area="heap"}
```

| Y-axis | Dual: ratio (0-1) for ring buffer, bytes for heap |
| Legend | Per metric name and shard |

#### Panel 5: k6 Request Rate (Utility)

| Property | Value |
|:---|:---|
| Title | k6 Request Rate |
| Type | Time series |
| Query | `rate(k6_http_reqs_total[30s])` |
| Y-axis | Requests/second |

#### Panel 6: k6 End-to-End Latency (Utility)

| Property | Value |
|:---|:---|
| Title | k6 HTTP Request Duration |
| Type | Time series |
| Query | `histogram_quantile(0.99, sum(rate(k6_http_req_duration_seconds_bucket[30s])) by (le))` |
| Threshold line | 0.2 (200ms) |
| Y-axis | Seconds |

### 4.3 Dashboard JSON

**File:** `infra/grafana/dashboards/matching-engine-experiment.json`

The full JSON model must be created following the Grafana dashboard JSON schema. Below is the structural skeleton. The coding agent must fill in the complete JSON with proper panel IDs, grid positions, and query targets.

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "liveNow": true,
  "panels": [
    {
      "id": 1,
      "title": "Matching Latency (ASR 1) - p50/p95/p99",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))",
          "legendFormat": "p99 shard={{shard}}"
        },
        {
          "expr": "histogram_quantile(0.95, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))",
          "legendFormat": "p95 shard={{shard}}"
        },
        {
          "expr": "histogram_quantile(0.50, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))",
          "legendFormat": "p50 shard={{shard}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 0.05 },
              { "color": "red", "value": 0.2 }
            ]
          },
          "unit": "s",
          "custom": {
            "drawStyle": "line",
            "lineWidth": 2
          }
        }
      }
    },
    {
      "id": 2,
      "title": "Match Throughput per Shard (ASR 2)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        {
          "expr": "rate(me_matches_total[30s]) * 60",
          "legendFormat": "shard={{shard}}"
        },
        {
          "expr": "sum(rate(me_matches_total[30s])) * 60",
          "legendFormat": "aggregate"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": { "drawStyle": "line", "lineWidth": 2 }
        }
      }
    },
    {
      "id": 3,
      "title": "Latency Budget Breakdown (avg per component)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        {
          "expr": "avg(rate(me_order_validation_duration_seconds_sum[1m]) / rate(me_order_validation_duration_seconds_count[1m]))",
          "legendFormat": "validation"
        },
        {
          "expr": "avg(rate(me_orderbook_insertion_duration_seconds_sum[1m]) / rate(me_orderbook_insertion_duration_seconds_count[1m]))",
          "legendFormat": "orderbook_insertion"
        },
        {
          "expr": "avg(rate(me_matching_algorithm_duration_seconds_sum[1m]) / rate(me_matching_algorithm_duration_seconds_count[1m]))",
          "legendFormat": "matching_algorithm"
        },
        {
          "expr": "avg(rate(me_wal_append_duration_seconds_sum[1m]) / rate(me_wal_append_duration_seconds_count[1m]))",
          "legendFormat": "wal_append"
        },
        {
          "expr": "avg(rate(me_event_publish_duration_seconds_sum[1m]) / rate(me_event_publish_duration_seconds_count[1m]))",
          "legendFormat": "event_publish"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "custom": {
            "drawStyle": "line",
            "lineWidth": 2,
            "stacking": { "mode": "normal" }
          }
        }
      }
    },
    {
      "id": 4,
      "title": "Resource Saturation",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "targets": [
        {
          "expr": "me_ringbuffer_utilization_ratio",
          "legendFormat": "ringbuffer shard={{shard}}"
        },
        {
          "expr": "me_orderbook_depth",
          "legendFormat": "orderbook_depth shard={{shard}} side={{side}}"
        },
        {
          "expr": "max_over_time(jvm_gc_pause_seconds_max[1m])",
          "legendFormat": "gc_pause_max"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": { "drawStyle": "line", "lineWidth": 1 }
        }
      }
    },
    {
      "id": 5,
      "title": "k6 Request Rate",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 0, "y": 16 },
      "targets": [
        {
          "expr": "rate(k6_http_reqs_total[30s])",
          "legendFormat": "requests/sec"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": { "drawStyle": "line", "lineWidth": 2 }
        }
      }
    },
    {
      "id": 6,
      "title": "k6 End-to-End Latency",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 16 },
      "targets": [
        {
          "expr": "histogram_quantile(0.99, sum(rate(k6_http_req_duration_seconds_bucket[30s])) by (le))",
          "legendFormat": "p99"
        },
        {
          "expr": "histogram_quantile(0.50, sum(rate(k6_http_req_duration_seconds_bucket[30s])) by (le))",
          "legendFormat": "p50"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "thresholds": {
            "steps": [
              { "color": "green", "value": null },
              { "color": "red", "value": 0.2 }
            ]
          },
          "custom": { "drawStyle": "line", "lineWidth": 2 }
        }
      }
    }
  ],
  "refresh": "5s",
  "schemaVersion": 39,
  "tags": ["matching-engine", "experiment"],
  "templating": { "list": [] },
  "time": { "from": "now-15m", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Matching Engine Experiment",
  "uid": "me-experiment",
  "version": 1
}
```

**Note:** The JSON above is a structural skeleton. The coding agent MUST expand each panel with complete field configurations, proper datasource references (use `"datasource": {"type": "prometheus", "uid": "${DS_PROMETHEUS}"}` or just `"Prometheus"` for the default), and ensure the dashboard imports cleanly into Grafana 10.x.

### 4.4 Dashboard ConfigMap

The dashboard JSON is deployed as a Kubernetes ConfigMap that Grafana's sidecar discovers and provisions.

**File to add to Spec 4's Grafana Helm values or as a separate manifest:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  matching-engine-experiment.json: |
    <PASTE THE FULL DASHBOARD JSON HERE>
```

Alternatively, the Grafana Helm chart's `dashboardsConfigMaps` value (already in Spec 4's `grafana-values.yaml`) references this ConfigMap.

---

## 5. Prometheus Recording Rules

**File:** `infra/prometheus/recording-rules.yaml`

Recording rules pre-compute expensive queries so they are instantly available for dashboard rendering and pass/fail evaluation.

```yaml
groups:
  - name: matching-engine-experiment
    interval: 5s
    rules:
      # ASR 1: Primary metric -- p99 matching latency per shard
      - record: me:match_duration_p99:30s
        expr: histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

      - record: me:match_duration_p95:30s
        expr: histogram_quantile(0.95, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

      - record: me:match_duration_p50:30s
        expr: histogram_quantile(0.50, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

      # ASR 2: Primary metric -- aggregate throughput (matches/min)
      - record: me:matches_per_minute:total
        expr: sum(rate(me_matches_total[1m])) * 60

      # ASR 2: Per-shard throughput (matches/min)
      - record: me:matches_per_minute:by_shard
        expr: rate(me_matches_total[1m]) * 60

      # Latency budget: average per sub-component
      - record: me:validation_avg_seconds
        expr: rate(me_order_validation_duration_seconds_sum[1m]) / rate(me_order_validation_duration_seconds_count[1m])

      - record: me:orderbook_insertion_avg_seconds
        expr: rate(me_orderbook_insertion_duration_seconds_sum[1m]) / rate(me_orderbook_insertion_duration_seconds_count[1m])

      - record: me:matching_algorithm_avg_seconds
        expr: rate(me_matching_algorithm_duration_seconds_sum[1m]) / rate(me_matching_algorithm_duration_seconds_count[1m])

      - record: me:wal_append_avg_seconds
        expr: rate(me_wal_append_duration_seconds_sum[1m]) / rate(me_wal_append_duration_seconds_count[1m])

      - record: me:event_publish_avg_seconds
        expr: rate(me_event_publish_duration_seconds_sum[1m]) / rate(me_event_publish_duration_seconds_count[1m])

      # GC pause max
      - record: me:gc_pause_max:1m
        expr: max_over_time(jvm_gc_pause_seconds_max[1m])

      # Orders received rate
      - record: me:orders_per_second
        expr: sum(rate(me_orders_received_total[30s]))
```

This file must be mounted into the Prometheus container. Add to the Prometheus Helm values:

```yaml
serverFiles:
  recording_rules.yml:
    groups:
      - name: matching-engine-experiment
        # ... (same content as above)
```

Or deploy as a ConfigMap and add it to `prometheus.yml` via `rule_files`.

---

## 6. Smoke Test Script

**File:** `infra/scripts/smoke-test.sh`

A comprehensive end-to-end verification that all components are wired correctly before running the full experiment.

```bash
#!/bin/bash
set -euo pipefail

echo "========================================="
echo "  SMOKE TEST: End-to-End Wiring Check"
echo "========================================="

ME_URL="${ME_URL:-http://localhost:8080}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
PASS=0
FAIL=0

check() {
    local name="$1"
    local result="$2"
    if [ "$result" == "true" ]; then
        echo "  [PASS] ${name}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "--- 1. ME Health Check ---"
ME_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${ME_URL}/health" 2>/dev/null || echo "000")
check "ME /health returns 200" "$([ "$ME_HEALTH" == "200" ] && echo true || echo false)"

echo ""
echo "--- 2. Order Submission ---"
ORDER_RESP=$(curl -s -X POST "${ME_URL}/orders" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"smoke-buy-1","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":10000,"quantity":10}' 2>/dev/null || echo '{}')
ORDER_STATUS=$(echo "$ORDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
check "Order submission returns ACCEPTED" "$([ "$ORDER_STATUS" == "ACCEPTED" ] && echo true || echo false)"

echo ""
echo "--- 3. Seed Endpoint ---"
SEED_RESP=$(curl -s -X POST "${ME_URL}/seed" \
  -H "Content-Type: application/json" \
  -d '{"orders":[{"orderId":"smoke-seed-1","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15100,"quantity":50}]}' 2>/dev/null || echo '{}')
SEEDED=$(echo "$SEED_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('seeded',0))" 2>/dev/null || echo "0")
check "Seed endpoint accepts orders" "$([ "$SEEDED" -gt 0 ] && echo true || echo false)"

echo ""
echo "--- 4. Matching Works ---"
# Seed a sell at 15000, then submit a buy at 15000
curl -s -X POST "${ME_URL}/seed" \
  -H "Content-Type: application/json" \
  -d '{"orders":[{"orderId":"smoke-seed-match","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15000,"quantity":50}]}' > /dev/null 2>&1

MATCH_RESP=$(curl -s -X POST "${ME_URL}/orders" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"smoke-match-buy","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":15000,"quantity":50}' 2>/dev/null || echo '{}')
MATCH_STATUS=$(echo "$MATCH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
check "Buy order at matching price is accepted" "$([ "$MATCH_STATUS" == "ACCEPTED" ] && echo true || echo false)"

echo ""
echo "--- 5. Prometheus Metrics ---"
sleep 6  # Wait for Prometheus scrape (5s interval)
ME_METRICS=$(curl -s "${ME_URL%:8080}:9091/metrics" 2>/dev/null || echo "")
check "me_matches_total metric exists" "$(echo "$ME_METRICS" | grep -q 'me_matches_total' && echo true || echo false)"
check "me_match_duration_seconds metric exists" "$(echo "$ME_METRICS" | grep -q 'me_match_duration_seconds' && echo true || echo false)"
check "me_orderbook_depth metric exists" "$(echo "$ME_METRICS" | grep -q 'me_orderbook_depth' && echo true || echo false)"
check "jvm_gc_pause metric exists" "$(echo "$ME_METRICS" | grep -q 'jvm_gc' && echo true || echo false)"

echo ""
echo "--- 6. Prometheus Scrape Verification ---"
PROM_TARGETS=$(curl -s "${PROM_URL}/api/v1/targets" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
active = [t for t in data.get('data',{}).get('activeTargets',[]) if 'matching-engine' in t.get('labels',{}).get('job','')]
up = [t for t in active if t.get('health') == 'up']
print(f'{len(up)}/{len(active)}')
" 2>/dev/null || echo "0/0")
check "Prometheus scraping ME targets" "$([ "${PROM_TARGETS}" != "0/0" ] && echo true || echo false)"

echo ""
echo "--- 7. Grafana Accessible ---"
GRAFANA_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_URL}/api/health" 2>/dev/null || echo "000")
check "Grafana is accessible" "$([ "$GRAFANA_HEALTH" == "200" ] && echo true || echo false)"

echo ""
echo "========================================="
echo "  RESULTS: ${PASS} passed, ${FAIL} failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
    echo "  SMOKE TEST FAILED. Fix issues before running experiments."
    exit 1
else
    echo "  SMOKE TEST PASSED. Ready to run experiments."
    exit 0
fi
```

---

## 7. Results Collection Script

**File:** `infra/scripts/collect-results.sh`

Queries Prometheus after a test run and evaluates pass/fail criteria.

```bash
#!/bin/bash
set -euo pipefail

PROM_URL="${PROM_URL:-http://localhost:9090}"
TEST_TYPE="${1:-asr1}"  # 'asr1' or 'asr2'

echo "========================================="
echo "  RESULTS COLLECTION: ${TEST_TYPE}"
echo "========================================="

query_prometheus() {
    local query="$1"
    local result=$(curl -s "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=${query}" 2>/dev/null | \
      python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    for r in results:
        labels = r.get('metric', {})
        value = r.get('value', [0, '0'])[1]
        label_str = ','.join([f'{k}={v}' for k, v in labels.items() if k != '__name__'])
        print(f'{label_str}: {value}')
else:
    print('NO_DATA')
" 2>/dev/null || echo "ERROR")
    echo "$result"
}

echo ""
if [ "$TEST_TYPE" == "asr1" ]; then
    echo "--- ASR 1: Latency Results ---"
    echo ""

    echo "p99 Matching Latency (per shard):"
    query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    echo "p95 Matching Latency (per shard):"
    query_prometheus 'histogram_quantile(0.95, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    echo "p50 Matching Latency (per shard):"
    query_prometheus 'histogram_quantile(0.50, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    echo "Total Matches Executed:"
    query_prometheus 'me_matches_total'
    echo ""

    echo "Max GC Pause (last 5 min):"
    query_prometheus 'max_over_time(jvm_gc_pause_seconds_max[5m])'
    echo ""

    echo "Latency Budget Breakdown (avg seconds):"
    echo "  Validation:"
    query_prometheus 'avg(rate(me_order_validation_duration_seconds_sum[5m]) / rate(me_order_validation_duration_seconds_count[5m]))'
    echo "  OrderBook Insertion:"
    query_prometheus 'avg(rate(me_orderbook_insertion_duration_seconds_sum[5m]) / rate(me_orderbook_insertion_duration_seconds_count[5m]))'
    echo "  Matching Algorithm:"
    query_prometheus 'avg(rate(me_matching_algorithm_duration_seconds_sum[5m]) / rate(me_matching_algorithm_duration_seconds_count[5m]))'
    echo "  WAL Append:"
    query_prometheus 'avg(rate(me_wal_append_duration_seconds_sum[5m]) / rate(me_wal_append_duration_seconds_count[5m]))'
    echo "  Event Publish:"
    query_prometheus 'avg(rate(me_event_publish_duration_seconds_sum[5m]) / rate(me_event_publish_duration_seconds_count[5m]))'
    echo ""

    echo "--- Pass/Fail Evaluation ---"
    P99_VALUE=$(curl -s "${PROM_URL}/api/v1/query" \
      --data-urlencode 'query=histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le))' | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else 'N/A')" 2>/dev/null || echo "N/A")

    if [ "$P99_VALUE" != "N/A" ]; then
        P99_MS=$(python3 -c "print(f'{float(\"${P99_VALUE}\") * 1000:.2f}')" 2>/dev/null || echo "N/A")
        echo "  p99 Matching Latency: ${P99_MS} ms"
        PASS=$(python3 -c "print('PASS' if float('${P99_VALUE}') < 0.2 else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        echo "  ASR 1 Primary Criterion: ${PASS} (threshold: < 200 ms)"
    else
        echo "  ASR 1 Primary Criterion: NO DATA"
    fi

elif [ "$TEST_TYPE" == "asr2" ]; then
    echo "--- ASR 2: Scalability Results ---"
    echo ""

    echo "Aggregate Throughput (matches/min, last 5m average):"
    query_prometheus 'sum(rate(me_matches_total[5m])) * 60'
    echo ""

    echo "Per-Shard Throughput (matches/min):"
    query_prometheus 'rate(me_matches_total[5m]) * 60'
    echo ""

    echo "Per-Shard p99 Latency:"
    query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    echo "JVM Heap Usage (per shard):"
    query_prometheus 'jvm_memory_used_bytes{area="heap"}'
    echo ""

    echo "--- Pass/Fail Evaluation ---"
    THROUGHPUT=$(curl -s "${PROM_URL}/api/v1/query" \
      --data-urlencode 'query=sum(rate(me_matches_total[5m])) * 60' | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else 'N/A')" 2>/dev/null || echo "N/A")

    if [ "$THROUGHPUT" != "N/A" ]; then
        echo "  Aggregate Throughput: ${THROUGHPUT} matches/min"
        PASS=$(python3 -c "print('PASS' if float('${THROUGHPUT}') >= 4750 else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        echo "  ASR 2 Throughput Criterion: ${PASS} (threshold: >= 4,750 matches/min)"
    else
        echo "  ASR 2 Throughput Criterion: NO DATA"
    fi
fi

echo ""
echo "========================================="
echo "  Check Grafana for detailed visualizations"
echo "  URL: http://localhost:3000"
echo "========================================="
```

---

## 8. Integration Points

### 8.1 What This Role Produces

| Artifact | Consumed By |
|:---|:---|
| Grafana dashboard JSON | Grafana (via ConfigMap provisioning) |
| Prometheus recording rules | Prometheus (via Helm values or ConfigMap) |
| Smoke test script | Operator (run manually before experiments) |
| Results collection script | Operator (run manually after experiments) |
| Dashboard ConfigMap YAML | Kubernetes / Helm (Spec 4 deploys it) |

### 8.2 Dependencies From Other Specs

| Dependency | Spec | What is needed |
|:---|:---|:---|
| Prometheus metric names | Spec 1 (MetricsRegistry) | Exact metric names must match: `me_match_duration_seconds`, `me_matches_total`, etc. |
| ME HTTP endpoints | Spec 1 (OrderHttpHandler, HealthHttpHandler, SeedHttpHandler) | `/orders`, `/health`, `/seed` |
| Gateway HTTP endpoints | Spec 2 (OrderProxyHandler, SeedProxyHandler) | `/orders`, `/seed/{shardId}` |
| Prometheus deployment | Spec 4 (Helm values) | Recording rules must be added to Prometheus config |
| Grafana deployment | Spec 4 (Helm values) | Dashboard ConfigMap must be referenced |
| Port-forward setup | Spec 4 (07-port-forward.sh) | localhost:8080 (ME/GW), localhost:9090 (Prometheus), localhost:3000 (Grafana) |

---

## 9. Acceptance Criteria

This role is "done" when:

1. **Grafana dashboard imports cleanly:** The JSON file can be imported into Grafana 10.x (via UI import or ConfigMap provisioning) without errors.
2. **All 6 panels render data:** When the ME is running and receiving orders, all panels show data (not "No data" or "N/A").
3. **ASR 1 panel shows p99 latency:** The "Matching Latency" panel displays p50, p95, and p99 lines with the 200ms threshold visible.
4. **ASR 2 panel shows per-shard throughput:** The "Match Throughput" panel shows separate lines for each shard and an aggregate line.
5. **Latency budget panel breaks down sub-components:** The stacked chart shows 5 distinct sub-component contributions.
6. **Recording rules produce data:** Querying `me:match_duration_p99:30s` in Prometheus returns a value after recording rules are deployed.
7. **Smoke test passes:** `smoke-test.sh` returns exit code 0 with all checks passing when the ME is deployed and running.
8. **Results collection works for ASR 1:** `collect-results.sh asr1` outputs p99 latency, GC pause, and latency budget breakdown after running test A2.
9. **Results collection works for ASR 2:** `collect-results.sh asr2` outputs aggregate throughput and per-shard latency after running test B2.
10. **Dashboard ConfigMap YAML is valid:** `kubectl apply --dry-run=client -f grafana-dashboards-configmap.yaml` succeeds.

---

## 10. Grafana Dashboard Provisioning

To deploy the dashboard alongside Grafana, either:

**Option A: ConfigMap (recommended for k3d)**

Create the ConfigMap in the `monitoring` namespace and reference it in the Grafana Helm values. The Grafana sidecar container automatically discovers ConfigMaps with the label `grafana_dashboard: "1"` and provisions them.

```bash
kubectl create configmap grafana-dashboards \
  --from-file=matching-engine-experiment.json=infra/grafana/dashboards/matching-engine-experiment.json \
  -n monitoring

kubectl label configmap grafana-dashboards grafana_dashboard=1 -n monitoring
```

**Option B: Grafana API (post-deployment)**

```bash
GRAFANA_URL="http://localhost:3000"
DASHBOARD_JSON=$(cat infra/grafana/dashboards/matching-engine-experiment.json)

curl -s -X POST "${GRAFANA_URL}/api/dashboards/db" \
  -H "Content-Type: application/json" \
  -u admin:admin \
  -d "{\"dashboard\": ${DASHBOARD_JSON}, \"overwrite\": true}"
```

The coding agent should implement both options and document them.
