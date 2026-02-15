#!/bin/bash
# =============================================================================
# 06-run-tests.sh -- Transfer k6 test scripts and run ASR experiments
#
# Steps:
#   1. SCP k6 test files to edge-and-tools instance
#   2. Run ASR 1 tests (against me-shard-a directly for single-shard latency)
#   3. Run ASR 2 tests (against edge-gateway for multi-shard scalability)
#   4. Collect and display results
#
# Usage:
#   ./06-run-tests.sh             # Run all tests (ASR 1 + ASR 2)
#   ./06-run-tests.sh asr1        # Run only ASR 1 tests
#   ./06-run-tests.sh asr2        # Run only ASR 2 tests
#   ./06-run-tests.sh smoke       # Run smoke test only
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
K6_SRC_DIR="${PROJECT_ROOT}/src/k6"
RESULTS_DIR="${SCRIPT_DIR}/results"

# Parse mode argument
MODE="${1:-all}"

banner "Phase 6: Run Experiments (mode: ${MODE})"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ -z "${BASTION_PUBLIC_IP}" ]]; then
    error "BASTION_PUBLIC_IP not set. Run 02-launch-instances.sh first."
    exit 1
fi

if [[ -z "${EDGE_PRIVATE_IP}" ]]; then
    error "EDGE_PRIVATE_IP not set. Run 02-launch-instances.sh first."
    exit 1
fi

if [[ ! -d "${K6_SRC_DIR}" ]]; then
    error "k6 test directory not found at ${K6_SRC_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: remote execute
# ---------------------------------------------------------------------------
remote_exec() {
    local target_ip="$1"
    shift
    ssh_via_bastion "${target_ip}" "$@"
}

# Create local results directory
mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Transfer k6 test scripts
# ---------------------------------------------------------------------------
step "Transferring k6 test scripts to edge-and-tools"

# Create remote directory
remote_exec "${EDGE_PRIVATE_IP}" "mkdir -p ~/k6-scripts/lib"

# Transfer all k6 scripts
for script_file in "${K6_SRC_DIR}"/*.js; do
    if [[ -f "${script_file}" ]]; then
        local_name=$(basename "${script_file}")
        scp_via_bastion "${script_file}" "${EDGE_PRIVATE_IP}" "~/k6-scripts/${local_name}"
        info "Transferred: ${local_name}"
    fi
done

# Transfer lib directory
for lib_file in "${K6_SRC_DIR}"/lib/*.js; do
    if [[ -f "${lib_file}" ]]; then
        local_name=$(basename "${lib_file}")
        scp_via_bastion "${lib_file}" "${EDGE_PRIVATE_IP}" "~/k6-scripts/lib/${local_name}"
        info "Transferred: lib/${local_name}"
    fi
done

success "All k6 scripts transferred"

# ---------------------------------------------------------------------------
# Step 2: Smoke test -- verify connectivity before running full tests
# ---------------------------------------------------------------------------
step "Running pre-flight smoke test"

SMOKE_ERRORS=0

# Check ME Shard A health
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://${ME_SHARD_A_PRIVATE_IP}:${ME_APP_PORT}/health" &>/dev/null; then
    success "ME Shard A health: OK"
else
    error "ME Shard A health: FAILED"
    SMOKE_ERRORS=$((SMOKE_ERRORS + 1))
fi

# Check ME Shard B health
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://${ME_SHARD_B_PRIVATE_IP}:${ME_APP_PORT}/health" &>/dev/null; then
    success "ME Shard B health: OK"
else
    error "ME Shard B health: FAILED"
    SMOKE_ERRORS=$((SMOKE_ERRORS + 1))
fi

# Check ME Shard C health
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://${ME_SHARD_C_PRIVATE_IP}:${ME_APP_PORT}/health" &>/dev/null; then
    success "ME Shard C health: OK"
else
    error "ME Shard C health: FAILED"
    SMOKE_ERRORS=$((SMOKE_ERRORS + 1))
fi

# Check Edge Gateway health
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://localhost:${GW_APP_PORT}/health" &>/dev/null; then
    success "Edge Gateway health: OK"
else
    error "Edge Gateway health: FAILED"
    SMOKE_ERRORS=$((SMOKE_ERRORS + 1))
fi

# Check Prometheus health
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://localhost:${PROMETHEUS_PORT}/-/healthy" &>/dev/null; then
    success "Prometheus health: OK"
else
    error "Prometheus health: FAILED"
    SMOKE_ERRORS=$((SMOKE_ERRORS + 1))
fi

# Check Grafana health
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://localhost:${GRAFANA_PORT}/api/health" &>/dev/null; then
    success "Grafana health: OK"
else
    warn "Grafana health: FAILED (non-blocking)"
fi

if [[ ${SMOKE_ERRORS} -gt 0 ]]; then
    error "${SMOKE_ERRORS} smoke test(s) failed. Fix issues before running experiments."
    exit 1
fi

success "All smoke tests passed"

if [[ "${MODE}" == "smoke" ]]; then
    banner "Smoke test completed successfully"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 3: Run ASR 1 tests (single-shard latency)
# ---------------------------------------------------------------------------
run_asr1() {
    banner "Running ASR 1: Single-Shard Latency Tests"

    # ASR 1 targets me-shard-a directly
    local ME_TARGET="http://${ME_SHARD_A_PRIVATE_IP}:${ME_APP_PORT}"
    local PROM_RW="http://localhost:${PROMETHEUS_PORT}/api/v1/write"

    # A1: Warmup
    step "ASR 1 - A1: Warmup"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e ME_SHARD_A_URL=${ME_TARGET} \
        -e GATEWAY_URL=${ME_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr1-a1-warmup.json \
        test-asr1-a1-warmup.js" 2>&1 || warn "ASR 1 A1 warmup returned non-zero (may be expected)"
    success "ASR 1 A1 warmup complete"

    # A2: Normal Load
    step "ASR 1 - A2: Normal Load (1000 matches/min target)"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e ME_SHARD_A_URL=${ME_TARGET} \
        -e GATEWAY_URL=${ME_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr1-a2-normal.json \
        test-asr1-a2-normal-load.js" 2>&1 || warn "ASR 1 A2 normal load returned non-zero"
    success "ASR 1 A2 normal load complete"

    # A3: Depth Variation
    step "ASR 1 - A3: Depth Variation"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e ME_SHARD_A_URL=${ME_TARGET} \
        -e GATEWAY_URL=${ME_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr1-a3-depth.json \
        test-asr1-a3-depth-variation.js" 2>&1 || warn "ASR 1 A3 depth variation returned non-zero"
    success "ASR 1 A3 depth variation complete"

    # A4: Kafka Degradation (optional, requires Redpanda pause)
    step "ASR 1 - A4: Kafka Degradation"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e ME_SHARD_A_URL=${ME_TARGET} \
        -e GATEWAY_URL=${ME_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr1-a4-kafka.json \
        test-asr1-a4-kafka-degradation.js" 2>&1 || warn "ASR 1 A4 kafka degradation returned non-zero"
    success "ASR 1 A4 kafka degradation complete"

    # Collect ASR 1 results from Prometheus
    step "Collecting ASR 1 results from Prometheus"

    # Wait for final scrape
    sleep 10

    local P99_LATENCY
    P99_LATENCY=$(remote_exec "${EDGE_PRIVATE_IP}" "curl -sf 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket{shard=\"a\"}[5m])) by (le))' \
        | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[\"data\"][\"result\"][0][\"value\"][1] if r[\"data\"][\"result\"] else \"N/A\")'" 2>/dev/null || echo "N/A")

    local THROUGHPUT
    THROUGHPUT=$(remote_exec "${EDGE_PRIVATE_IP}" "curl -sf 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=sum(rate(me_matches_total{shard=\"a\"}[5m])) * 60' \
        | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[\"data\"][\"result\"][0][\"value\"][1] if r[\"data\"][\"result\"] else \"N/A\")'" 2>/dev/null || echo "N/A")

    echo ""
    echo "  ================================================"
    echo "  ASR 1 Results (Single Shard)"
    echo "  ================================================"
    echo "  p99 Latency:   ${P99_LATENCY} seconds (target: < 0.200s)"
    echo "  Throughput:    ${THROUGHPUT} matches/min (target: >= 1000)"
    echo "  ================================================"
    echo ""

    # Determine pass/fail
    if [[ "${P99_LATENCY}" != "N/A" ]]; then
        local P99_MS
        P99_MS=$(python3 -c "print(float('${P99_LATENCY}') * 1000)" 2>/dev/null || echo "0")
        if python3 -c "exit(0 if float('${P99_LATENCY}') < 0.200 else 1)" 2>/dev/null; then
            success "ASR 1 PASS: p99 = ${P99_MS}ms < 200ms"
        else
            warn "ASR 1 FAIL: p99 = ${P99_MS}ms >= 200ms"
        fi
    else
        warn "ASR 1: Could not retrieve p99 latency from Prometheus"
    fi

    # Download k6 summary files
    for summary in asr1-a1-warmup asr1-a2-normal asr1-a3-depth asr1-a4-kafka; do
        scp -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -i "${SSH_KEY_PATH}" \
            -J "${SSH_USER}@${BASTION_PUBLIC_IP}" \
            "${SSH_USER}@${EDGE_PRIVATE_IP}:/tmp/${summary}.json" \
            "${RESULTS_DIR}/${summary}.json" 2>/dev/null || true
    done
    info "k6 summaries downloaded to ${RESULTS_DIR}/"
}

# ---------------------------------------------------------------------------
# Step 4: Run ASR 2 tests (multi-shard scalability)
# ---------------------------------------------------------------------------
run_asr2() {
    banner "Running ASR 2: Multi-Shard Scalability Tests"

    # ASR 2 targets the edge gateway (which routes to all shards)
    local GW_TARGET="http://localhost:${GW_APP_PORT}"
    local PROM_RW="http://localhost:${PROMETHEUS_PORT}/api/v1/write"

    # Seed orderbooks on all shards
    step "Seeding orderbooks"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e GATEWAY_URL=${GW_TARGET} \
        -e ME_SHARD_A_URL=${GW_TARGET} \
        seed-orderbooks.js" 2>&1 || warn "Seed script returned non-zero (may be expected)"
    success "Orderbooks seeded"

    # B1: Baseline
    step "ASR 2 - B1: Baseline (3 shards, 1000 matches/min)"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e GATEWAY_URL=${GW_TARGET} \
        -e ME_SHARD_A_URL=${GW_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr2-b1-baseline.json \
        test-asr2-b1-baseline.js" 2>&1 || warn "ASR 2 B1 baseline returned non-zero"
    success "ASR 2 B1 baseline complete"

    # B2: Peak Sustained (5000 matches/min)
    step "ASR 2 - B2: Peak Sustained (3 shards, 5000 matches/min)"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e GATEWAY_URL=${GW_TARGET} \
        -e ME_SHARD_A_URL=${GW_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr2-b2-peak.json \
        test-asr2-b2-peak-sustained.js" 2>&1 || warn "ASR 2 B2 peak sustained returned non-zero"
    success "ASR 2 B2 peak sustained complete"

    # B3: Ramp
    step "ASR 2 - B3: Ramp (1000 -> 5000 matches/min)"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e GATEWAY_URL=${GW_TARGET} \
        -e ME_SHARD_A_URL=${GW_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr2-b3-ramp.json \
        test-asr2-b3-ramp.js" 2>&1 || warn "ASR 2 B3 ramp returned non-zero"
    success "ASR 2 B3 ramp complete"

    # B4: Hot Symbol
    step "ASR 2 - B4: Hot Symbol"
    remote_exec "${EDGE_PRIVATE_IP}" "cd ~/k6-scripts && k6 run \
        -e GATEWAY_URL=${GW_TARGET} \
        -e ME_SHARD_A_URL=${GW_TARGET} \
        --out experimental-prometheus-rw=${PROM_RW} \
        --summary-export /tmp/asr2-b4-hot.json \
        test-asr2-b4-hot-symbol.js" 2>&1 || warn "ASR 2 B4 hot symbol returned non-zero"
    success "ASR 2 B4 hot symbol complete"

    # Collect ASR 2 results from Prometheus
    step "Collecting ASR 2 results from Prometheus"

    sleep 10

    local AGGREGATE_THROUGHPUT
    AGGREGATE_THROUGHPUT=$(remote_exec "${EDGE_PRIVATE_IP}" "curl -sf 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=sum(rate(me_matches_total[5m])) * 60' \
        | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[\"data\"][\"result\"][0][\"value\"][1] if r[\"data\"][\"result\"] else \"N/A\")'" 2>/dev/null || echo "N/A")

    local PER_SHARD_THROUGHPUT
    PER_SHARD_THROUGHPUT=$(remote_exec "${EDGE_PRIVATE_IP}" "curl -sf 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=rate(me_matches_total[5m]) * 60' \
        | python3 -c 'import sys,json; r=json.load(sys.stdin); results=r[\"data\"][\"result\"]; [print(f\"  Shard {d[\\\"metric\\\"].get(\\\"shard\\\",\\\"?\\\")}: {d[\\\"value\\\"][1]} matches/min\") for d in results]'" 2>/dev/null || echo "  N/A")

    local P99_ALL
    P99_ALL=$(remote_exec "${EDGE_PRIVATE_IP}" "curl -sf 'http://localhost:${PROMETHEUS_PORT}/api/v1/query' \
        --data-urlencode 'query=histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le))' \
        | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[\"data\"][\"result\"][0][\"value\"][1] if r[\"data\"][\"result\"] else \"N/A\")'" 2>/dev/null || echo "N/A")

    echo ""
    echo "  ================================================"
    echo "  ASR 2 Results (Multi-Shard Scalability)"
    echo "  ================================================"
    echo "  Aggregate Throughput: ${AGGREGATE_THROUGHPUT} matches/min (target: >= 4750)"
    echo "  p99 Latency (all):   ${P99_ALL} seconds"
    echo "  Per-shard throughput:"
    echo "${PER_SHARD_THROUGHPUT}"
    echo "  ================================================"
    echo ""

    # Determine pass/fail
    if [[ "${AGGREGATE_THROUGHPUT}" != "N/A" ]]; then
        if python3 -c "exit(0 if float('${AGGREGATE_THROUGHPUT}') >= 4750 else 1)" 2>/dev/null; then
            success "ASR 2 PASS: Aggregate throughput = ${AGGREGATE_THROUGHPUT} matches/min >= 4750"
        else
            warn "ASR 2 FAIL: Aggregate throughput = ${AGGREGATE_THROUGHPUT} matches/min < 4750"
        fi
    else
        warn "ASR 2: Could not retrieve aggregate throughput from Prometheus"
    fi

    # Download k6 summary files
    for summary in asr2-b1-baseline asr2-b2-peak asr2-b3-ramp asr2-b4-hot; do
        scp -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -i "${SSH_KEY_PATH}" \
            -J "${SSH_USER}@${BASTION_PUBLIC_IP}" \
            "${SSH_USER}@${EDGE_PRIVATE_IP}:/tmp/${summary}.json" \
            "${RESULTS_DIR}/${summary}.json" 2>/dev/null || true
    done
    info "k6 summaries downloaded to ${RESULTS_DIR}/"
}

# ---------------------------------------------------------------------------
# Run selected tests
# ---------------------------------------------------------------------------
case "${MODE}" in
    asr1)
        run_asr1
        ;;
    asr2)
        run_asr2
        ;;
    all)
        run_asr1
        run_asr2
        ;;
    *)
        error "Unknown mode: ${MODE}. Usage: ./06-run-tests.sh [all|asr1|asr2|smoke]"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Final Summary
# ---------------------------------------------------------------------------
banner "Experiment execution complete"
echo ""
echo "  Results saved to: ${RESULTS_DIR}/"
echo ""
echo "  View live dashboards:"
echo "    ssh -i ${SSH_KEY_PATH} \\"
echo "        -L 3000:${EDGE_PRIVATE_IP}:3000 \\"
echo "        -L 9090:${EDGE_PRIVATE_IP}:9090 \\"
echo "        ${SSH_USER}@${BASTION_PUBLIC_IP}"
echo ""
echo "    Grafana:    http://localhost:3000 (admin/admin)"
echo "    Prometheus: http://localhost:9090"
echo ""
if [[ -n "${LB_PUBLIC_IP}" && "${LB_PUBLIC_IP}" != "None" ]]; then
    echo "    Load Balancer: http://${LB_PUBLIC_IP}/health"
fi
echo ""
info "Run 99-teardown.sh when finished to clean up all OCI resources."
