#!/bin/bash
# =============================================================================
# 06-run-tests.sh -- Run k6 load tests from the load generator instance.
#
# This script copies k6 test files to the k6 load generator EC2 instance
# (in the public subnet) and runs the tests against the ME cluster in the
# private subnet. Results are pushed to Prometheus via remote write.
#
# Usage:
#   ./06-run-tests.sh asr1           # Run ASR 1 latency tests (single shard)
#   ./06-run-tests.sh asr2           # Run ASR 2 scalability tests (3 shards)
#   ./06-run-tests.sh smoke          # Quick smoke test
#   ./06-run-tests.sh collect-asr1   # Collect ASR 1 results from Prometheus
#   ./06-run-tests.sh collect-asr2   # Collect ASR 2 results from Prometheus
#   ./06-run-tests.sh seed           # Seed orderbooks only
#
# The k6 instance has direct access to private instances via VPC routing.
# Prometheus remote write URL points to the monitoring instance's Prometheus.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 6: Run Tests"

MODE="${1:-smoke}"
info "Test mode: ${MODE}"

# Validate prerequisites
for var in K6_PUBLIC_IP IP_ME_SHARD_A IP_MONITORING; do
    val="${!var:-}"
    if [ -z "$val" ] || [ "$val" = "None" ]; then
        error "${var} is not set. Run previous scripts first."
        exit 1
    fi
done

# Prometheus URL on the monitoring instance (private IP, reachable from k6 via VPC)
PROM_URL="http://${IP_MONITORING}:${PROMETHEUS_PORT}"
PROM_RW_URL="${PROM_URL}/api/v1/write"

# Target URL depends on mode
if [ "$MODE" = "asr1" ] || [ "$MODE" = "smoke" ] || [ "$MODE" = "seed" ]; then
    TARGET_URL="http://${IP_ME_SHARD_A}:${APP_PORT}"
elif [ "$MODE" = "asr2" ]; then
    TARGET_URL="http://${IP_EDGE_GW}:${APP_PORT}"
fi

# ---------------------------------------------------------------------------
# Helper: Transfer k6 test files to the load generator instance
# ---------------------------------------------------------------------------
transfer_k6_files() {
    local k6_src="${SCRIPT_DIR}/../../../src/k6"

    if [ ! -d "$k6_src" ]; then
        error "k6 test directory not found at ${k6_src}"
        exit 1
    fi

    info "Transferring k6 test files to load generator..."

    # Create directory structure on k6 instance
    ssh_cmd "$K6_PUBLIC_IP" "mkdir -p ~/k6-tests/lib"

    # Transfer all test files
    for f in "${k6_src}"/*.js; do
        if [ -f "$f" ]; then
            scp_to "$K6_PUBLIC_IP" "$f" "k6-tests/$(basename "$f")"
        fi
    done

    # Transfer library files
    for f in "${k6_src}"/lib/*.js; do
        if [ -f "$f" ]; then
            scp_to "$K6_PUBLIC_IP" "$f" "k6-tests/lib/$(basename "$f")"
        fi
    done

    success "k6 test files transferred."
}

# ---------------------------------------------------------------------------
# Helper: Run a single k6 test on the load generator
# ---------------------------------------------------------------------------
run_k6_test() {
    local test_name="$1"
    local test_file="$2"
    local env_vars="$3"

    info "Running test: ${test_name}"
    info "  File: ${test_file}"
    info "  Env:  ${env_vars}"
    echo ""

    ssh_cmd "$K6_PUBLIC_IP" "cd ~/k6-tests && k6 run \
        --out experimental-prometheus-rw=${PROM_RW_URL} \
        ${env_vars} \
        ${test_file}" 2>&1 || {
        warn "Test ${test_name} exited with non-zero status."
    }

    echo ""
    success "Test ${test_name} complete."
    echo ""
}

# ---------------------------------------------------------------------------
# Helper: SSH to a private instance via k6 bastion
# ---------------------------------------------------------------------------
bastion_ssh() {
    local private_ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 -o ServerAliveInterval=15 \
        -i "$KEY_FILE" \
        -o "ProxyJump=ec2-user@${K6_PUBLIC_IP}" \
        "ec2-user@${private_ip}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: Query Prometheus via the monitoring instance (localhost access)
# The k6 instance cannot reach the monitoring SG ports directly, so we
# SSH into the monitoring host via bastion and curl localhost:9090.
# ---------------------------------------------------------------------------
query_prometheus() {
    local query="$1"
    bastion_ssh "$IP_MONITORING" "curl -s 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=${query}'" 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    for r in results:
        labels = r.get('metric', {})
        value = r.get('value', [0, '0'])[1]
        label_str = ','.join([f'{k}={v}' for k, v in labels.items() if k != '__name__'])
        if label_str:
            print(f'  {label_str}: {value}')
        else:
            print(f'  {value}')
else:
    print('  NO_DATA')
" 2>/dev/null || echo "  ERROR"
}

# ---------------------------------------------------------------------------
# Helper: Query Prometheus raw (returns JSON, for pass/fail evaluation)
# ---------------------------------------------------------------------------
query_prometheus_raw() {
    local query="$1"
    bastion_ssh "$IP_MONITORING" "curl -s 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=${query}'" 2>/dev/null
}

# Transfer test files (needed for all modes except collect)
case "$MODE" in
    collect-asr1|collect-asr2)
        # No file transfer needed
        ;;
    *)
        transfer_k6_files

        # Set up SSH tunnel from k6 to monitoring for Prometheus remote write.
        # The k6 instance is in the public subnet and cannot reach the monitoring
        # SG ports directly. We tunnel localhost:9090 on k6 -> monitoring:9090.
        info "Setting up SSH tunnel from k6 to monitoring for Prometheus remote write..."
        ssh_cmd "$K6_PUBLIC_IP" "
            # Kill any existing tunnel
            pkill -f 'ssh.*-L.*9090.*${IP_MONITORING}' 2>/dev/null || true
            sleep 1
            # Create tunnel in background
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -i ~/.ssh/${KEY_NAME}.pem \
                -L 9090:localhost:${PROMETHEUS_PORT} \
                -N -f ec2-user@${IP_MONITORING}
        " 2>/dev/null || warn "SSH tunnel setup failed. k6 metrics may not be pushed to Prometheus."
        PROM_RW_URL="http://localhost:${PROMETHEUS_PORT}/api/v1/write"
        success "SSH tunnel established (k6:localhost:9090 -> monitoring:${PROMETHEUS_PORT})."
        ;;
esac

# ===========================================================================
# Mode: smoke -- Quick connectivity and health check
# ===========================================================================
if [ "$MODE" = "smoke" ]; then
    header "Smoke Test"

    PASS=0
    FAIL=0

    check() {
        local name="$1"
        local result="$2"
        if [ "$result" = "true" ]; then
            success "  ${name}"
            PASS=$((PASS + 1))
        else
            error "  ${name}"
            FAIL=$((FAIL + 1))
        fi
    }

    echo ""
    info "--- 1. ME Shard A Health Check ---"
    ME_HEALTH=$(ssh_cmd "$K6_PUBLIC_IP" "curl -s -o /dev/null -w '%{http_code}' http://${IP_ME_SHARD_A}:${APP_PORT}/health" 2>/dev/null || echo "000")
    check "ME Shard A /health returns 200" "$([ "$ME_HEALTH" = "200" ] && echo true || echo false)"

    echo ""
    info "--- 2. Redpanda Health Check ---"
    RP_HEALTH=$(bastion_ssh "$IP_REDPANDA" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${REDPANDA_ADMIN_PORT}/v1/status/ready" 2>/dev/null || echo "000")
    check "Redpanda /v1/status/ready returns 200" "$([ "$RP_HEALTH" = "200" ] && echo true || echo false)"

    echo ""
    info "--- 3. Order Submission ---"
    ORDER_RESP=$(ssh_cmd "$K6_PUBLIC_IP" "curl -s -X POST http://${IP_ME_SHARD_A}:${APP_PORT}/orders \
        -H 'Content-Type: application/json' \
        -d '{\"orderId\":\"smoke-buy-aws-1\",\"symbol\":\"TEST-ASSET-A\",\"side\":\"BUY\",\"type\":\"LIMIT\",\"price\":10000,\"quantity\":10}'" 2>/dev/null || echo '{}')
    ORDER_STATUS=$(echo "$ORDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    check "Order submission returns ACCEPTED" "$([ "$ORDER_STATUS" = "ACCEPTED" ] && echo true || echo false)"

    echo ""
    info "--- 4. Seed Endpoint ---"
    SEED_RESP=$(ssh_cmd "$K6_PUBLIC_IP" "curl -s -X POST http://${IP_ME_SHARD_A}:${APP_PORT}/seed \
        -H 'Content-Type: application/json' \
        -d '{\"orders\":[{\"orderId\":\"smoke-seed-aws-1\",\"symbol\":\"TEST-ASSET-A\",\"side\":\"SELL\",\"type\":\"LIMIT\",\"price\":15100,\"quantity\":50}]}'" 2>/dev/null || echo '{}')
    SEEDED=$(echo "$SEED_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('seeded',0))" 2>/dev/null || echo "0")
    check "Seed endpoint accepts orders" "$([ "$SEEDED" -gt 0 ] 2>/dev/null && echo true || echo false)"

    echo ""
    info "--- 5. Prometheus Health ---"
    PROM_HEALTH=$(bastion_ssh "$IP_MONITORING" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null || echo "000")
    check "Prometheus is healthy" "$([ "$PROM_HEALTH" = "200" ] && echo true || echo false)"

    echo ""
    info "--- 6. Prometheus Metrics (waiting 6s for scrape) ---"
    sleep 6
    METRIC_CHECK=$(bastion_ssh "$IP_MONITORING" "curl -s 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=me_orders_received_total'" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('data',{}).get('result',[]) else 'false')" 2>/dev/null || echo "false")
    check "Prometheus has me_orders_received_total metric" "$METRIC_CHECK"

    echo ""
    info "--- 7. Grafana Health ---"
    GF_HEALTH=$(bastion_ssh "$IP_MONITORING" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${GRAFANA_PORT}/api/health" 2>/dev/null || echo "000")
    check "Grafana is healthy" "$([ "$GF_HEALTH" = "200" ] && echo true || echo false)"

    echo ""
    header "Smoke Test Results: ${PASS} passed, ${FAIL} failed"
    if [ "$FAIL" -gt 0 ]; then
        error "Smoke test FAILED. Fix issues before running experiments."
        exit 1
    else
        success "Smoke test PASSED. Ready to run experiments."
    fi

# ===========================================================================
# Mode: seed -- Seed orderbooks
# ===========================================================================
elif [ "$MODE" = "seed" ]; then
    header "Seeding Orderbooks"

    info "Running seed script on Shard A..."
    run_k6_test "seed-orderbooks" "seed-orderbooks.js" \
        "-e ME_SHARD_A_URL=http://${IP_ME_SHARD_A}:${APP_PORT}"

    success "Orderbook seeding complete."

# ===========================================================================
# Mode: asr1 -- ASR 1 latency tests (single shard)
# ===========================================================================
elif [ "$MODE" = "asr1" ]; then
    header "ASR 1: Latency Validation Tests"

    ENV_VARS="-e ME_SHARD_A_URL=http://${IP_ME_SHARD_A}:${APP_PORT}"

    echo ""
    info "=== Test A1: Warm-up (2 min) ==="
    run_k6_test "A1-warmup" "test-asr1-a1-warmup.js" "$ENV_VARS"

    echo ""
    info "=== Test A2: Normal Load Latency (5 min) ==="
    run_k6_test "A2-normal-load" "test-asr1-a2-normal-load.js" "$ENV_VARS"

    echo ""
    info "=== Test A3: Depth Variation (5 min) ==="
    run_k6_test "A3-depth-variation" "test-asr1-a3-depth-variation.js" "$ENV_VARS"

    echo ""
    info "=== Test A4: Kafka Degradation (3 min) ==="
    # Pause Redpanda briefly during the test to simulate broker degradation
    info "Scheduling Redpanda pause (pause at 60s for 120s)..."
    ssh_cmd "$K6_PUBLIC_IP" "nohup bash -c '
        sleep 60
        echo \"Pausing Redpanda...\"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i ~/.ssh/${KEY_NAME}.pem \
            ec2-user@${IP_REDPANDA} \"sudo docker pause redpanda\"
        sleep 120
        echo \"Resuming Redpanda...\"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i ~/.ssh/${KEY_NAME}.pem \
            ec2-user@${IP_REDPANDA} \"sudo docker unpause redpanda\"
    ' > /tmp/pause-redpanda.log 2>&1 &"

    run_k6_test "A4-kafka-degradation" "test-asr1-a4-kafka-degradation.js" "$ENV_VARS"

    # Ensure Redpanda is unpaused
    ssh_cmd "$K6_PUBLIC_IP" "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ~/.ssh/${KEY_NAME}.pem \
        ec2-user@${IP_REDPANDA} 'sudo docker unpause redpanda 2>/dev/null || true'"

    header "ASR 1 Test Suite Complete"
    echo ""
    info "Collecting results..."
    echo ""

    # Fall through to collect results
    MODE="collect-asr1"

# ===========================================================================
# Mode: asr2 -- ASR 2 scalability tests (3 shards + gateway)
# ===========================================================================
elif [ "$MODE" = "asr2" ]; then
    header "ASR 2: Scalability Validation Tests"

    ENV_VARS="-e GATEWAY_URL=http://${IP_EDGE_GW}:${APP_PORT}"

    echo ""
    info "=== Test B1: Baseline (3 min) ==="
    run_k6_test "B1-baseline" "test-asr2-b1-baseline.js" "$ENV_VARS"

    echo ""
    info "=== Test B2: Peak Sustained (5 min) ==="
    run_k6_test "B2-peak-sustained" "test-asr2-b2-peak-sustained.js" "$ENV_VARS"

    echo ""
    info "=== Test B3: Ramp (10 min) ==="
    run_k6_test "B3-ramp" "test-asr2-b3-ramp.js" "$ENV_VARS"

    echo ""
    info "=== Test B4: Hot Symbol (5 min) ==="
    run_k6_test "B4-hot-symbol" "test-asr2-b4-hot-symbol.js" "$ENV_VARS"

    header "ASR 2 Test Suite Complete"
    echo ""
    info "Collecting results..."
    echo ""

    # Fall through to collect results
    MODE="collect-asr2"
fi

# ===========================================================================
# Mode: collect-asr1 -- Collect ASR 1 results from Prometheus
# ===========================================================================
if [ "$MODE" = "collect-asr1" ]; then
    header "ASR 1 Results Collection"

    echo ""
    info "p99 Matching Latency (per shard):"
    query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    info "p95 Matching Latency (per shard):"
    query_prometheus 'histogram_quantile(0.95, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    info "p50 Matching Latency (per shard):"
    query_prometheus 'histogram_quantile(0.50, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    info "Total Matches Executed:"
    query_prometheus 'me_matches_total'
    echo ""

    info "GC Pause Rate (ZGC Pauses, seconds/sec):"
    query_prometheus 'rate(jvm_gc_collection_seconds_sum{gc="ZGC Pauses"}[5m])'
    echo ""

    info "Latency Budget Breakdown (avg seconds):"
    info "  Validation:"
    query_prometheus 'avg(rate(me_order_validation_duration_seconds_sum[5m]) / rate(me_order_validation_duration_seconds_count[5m]))'
    info "  OrderBook Insertion:"
    query_prometheus 'avg(rate(me_orderbook_insertion_duration_seconds_sum[5m]) / rate(me_orderbook_insertion_duration_seconds_count[5m]))'
    info "  Matching Algorithm:"
    query_prometheus 'avg(rate(me_matching_algorithm_duration_seconds_sum[5m]) / rate(me_matching_algorithm_duration_seconds_count[5m]))'
    info "  WAL Append:"
    query_prometheus 'avg(rate(me_wal_append_duration_seconds_sum[5m]) / rate(me_wal_append_duration_seconds_count[5m]))'
    info "  Event Publish:"
    query_prometheus 'avg(rate(me_event_publish_duration_seconds_sum[5m]) / rate(me_event_publish_duration_seconds_count[5m]))'
    echo ""

    # Pass/Fail evaluation
    info "--- Pass/Fail Evaluation ---"
    P99_VALUE=$(query_prometheus_raw 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le))' | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else 'N/A')" 2>/dev/null || echo "N/A")

    if [ "$P99_VALUE" != "N/A" ]; then
        P99_MS=$(python3 -c "print(f'{float(\"${P99_VALUE}\") * 1000:.2f}')" 2>/dev/null || echo "N/A")
        info "  p99 Matching Latency: ${P99_MS} ms"
        RESULT=$(python3 -c "print('PASS' if float('${P99_VALUE}') < 0.2 else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        if [ "$RESULT" = "PASS" ]; then
            success "  ASR 1 Primary Criterion: PASS (threshold: < 200 ms)"
        else
            error "  ASR 1 Primary Criterion: FAIL (threshold: < 200 ms)"
        fi
    else
        warn "  ASR 1 Primary Criterion: NO DATA (run load test first)"
    fi

# ===========================================================================
# Mode: collect-asr2 -- Collect ASR 2 results from Prometheus
# ===========================================================================
elif [ "$MODE" = "collect-asr2" ]; then
    header "ASR 2 Results Collection"

    echo ""
    info "Aggregate Throughput (matches/min, last 5m average):"
    query_prometheus 'sum(rate(me_matches_total[5m])) * 60'
    echo ""

    info "Per-Shard Throughput (matches/min):"
    query_prometheus 'rate(me_matches_total[5m]) * 60'
    echo ""

    info "Per-Shard p99 Latency:"
    query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard))'
    echo ""

    info "JVM Heap Usage (per shard):"
    query_prometheus 'jvm_memory_used_bytes{area="heap"}'
    echo ""

    # Pass/Fail evaluation
    info "--- Pass/Fail Evaluation ---"
    THROUGHPUT=$(query_prometheus_raw 'sum(rate(me_matches_total[5m])) * 60' | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else 'N/A')" 2>/dev/null || echo "N/A")

    if [ "$THROUGHPUT" != "N/A" ]; then
        THROUGHPUT_FMT=$(python3 -c "print(f'{float(\"${THROUGHPUT}\"):.0f}')" 2>/dev/null || echo "N/A")
        info "  Aggregate Throughput: ${THROUGHPUT_FMT} matches/min"
        RESULT=$(python3 -c "print('PASS' if float('${THROUGHPUT}') >= 4750 else 'FAIL')" 2>/dev/null || echo "UNKNOWN")
        if [ "$RESULT" = "PASS" ]; then
            success "  ASR 2 Throughput Criterion: PASS (threshold: >= 4,750 matches/min)"
        else
            error "  ASR 2 Throughput Criterion: FAIL (threshold: >= 4,750 matches/min)"
        fi
    else
        warn "  ASR 2 Throughput Criterion: NO DATA (run load test first)"
    fi
fi

echo ""
header "Test Execution Complete"
info "Grafana dashboard (via SSH tunnel):"
info "  ssh -i ${KEY_FILE} -L 3000:${IP_MONITORING}:${GRAFANA_PORT} ec2-user@${K6_PUBLIC_IP}"
info "  Then open: http://localhost:3000  (admin / admin1234)"
echo ""
info "Prometheus (via SSH tunnel):"
info "  ssh -i ${KEY_FILE} -L 9090:${IP_MONITORING}:${PROMETHEUS_PORT} ec2-user@${K6_PUBLIC_IP}"
info "  Then open: http://localhost:9090"
