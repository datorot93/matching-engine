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

    echo "GC Pause Rate (last 5 min, ZGC Pauses seconds/sec):"
    query_prometheus 'rate(jvm_gc_collection_seconds_sum{gc="ZGC Pauses"}[5m])'
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
        RESULT=$(python3 -c "print('PASS' if float('${P99_VALUE}') < 0.2 else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        echo "  ASR 1 Primary Criterion: ${RESULT} (threshold: < 200 ms)"
    else
        echo "  ASR 1 Primary Criterion: NO DATA (run load test first)"
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
        RESULT=$(python3 -c "print('PASS' if float('${THROUGHPUT}') >= 4750 else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        echo "  ASR 2 Throughput Criterion: ${RESULT} (threshold: >= 4,750 matches/min)"
    else
        echo "  ASR 2 Throughput Criterion: NO DATA (run load test first)"
    fi
else
    echo "  Unknown test type: ${TEST_TYPE}"
    echo "  Usage: $0 [asr1|asr2]"
    exit 1
fi

echo ""
echo "========================================="
echo "  Check Grafana for detailed visualizations"
echo "  URL: http://localhost:3000"
echo "  Dashboard: Matching Engine Experiment"
echo "========================================="
