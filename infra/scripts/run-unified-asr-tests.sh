#!/bin/bash
# =============================================================================
# Unified ASR Test Orchestrator
#
# This script executes both ASR 1 (Latency) and ASR 2 (Scalability) test
# suites in a single run, handling deployment switching and consolidated
# reporting.
#
# Usage:
#   bash run-unified-asr-tests.sh [--asr1-only|--asr2-only|--both]
#
# Arguments:
#   --asr1-only    Run only ASR 1 tests (stochastic, single shard)
#   --asr2-only    Run only ASR 2 tests (scalability, multi-shard)
#   --both         Run both test suites (default)
#
# Environment variables:
#   SKIP_DEPLOYMENT    - Set to 'true' to skip deployment steps
#   ME_PORT           - Port for ME/Gateway (default: 8081)
#   PROM_URL          - Prometheus remote write URL (default: http://localhost:9090/api/v1/write)
#   NORMAL_RUNS       - Number of normal stochastic runs (default: 20)
#   AGGRESSIVE_RUNS   - Number of aggressive stochastic runs (default: 20)
#
# Output:
#   results/unified-YYYYMMDD-HHMMSS/
#     asr1/                         # ASR 1 stochastic test results
#       run-01-normal.json
#       run-02-aggressive.json
#       ...
#       report.csv
#       report.txt
#     asr2/                         # ASR 2 test summaries
#       b2-peak-sustained.json
#       b3-ramp.json
#       b4-hot-symbol.json
#     unified-report.txt            # Consolidated pass/fail report
#     unified-report.csv            # Machine-readable summary
#     test-execution.log            # Full execution log
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_DIR="${SCRIPT_DIR}/../../src/k6"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${SCRIPT_DIR}/results/unified-${TIMESTAMP}"

SKIP_DEPLOYMENT="${SKIP_DEPLOYMENT:-false}"
ME_PORT="${ME_PORT:-8081}"
PROM_URL="${PROM_URL:-http://localhost:9090/api/v1/write}"
NORMAL_RUNS="${NORMAL_RUNS:-20}"
AGGRESSIVE_RUNS="${AGGRESSIVE_RUNS:-20}"

# Parse arguments
TEST_MODE="both"
if [ "$#" -gt 0 ]; then
    case "$1" in
        --asr1-only)
            TEST_MODE="asr1"
            ;;
        --asr2-only)
            TEST_MODE="asr2"
            ;;
        --both)
            TEST_MODE="both"
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 [--asr1-only|--asr2-only|--both]" >&2
            exit 1
            ;;
    esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# Validate prerequisites
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v k6 &>/dev/null; then
    echo "ERROR: k6 is not installed." >&2
    exit 1
fi

if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl is not installed." >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is not installed." >&2
    exit 1
fi

# Create results directories
mkdir -p "${RESULTS_DIR}/asr1"
mkdir -p "${RESULTS_DIR}/asr2"

# Set up logging
exec > >(tee -a "${RESULTS_DIR}/test-execution.log")
exec 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                   UNIFIED ASR TEST ORCHESTRATOR                         ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  Test mode:         ${TEST_MODE}"
echo "║  Results dir:       ${RESULTS_DIR}"
echo "║  ME Port:           ${ME_PORT}"
echo "║  Prometheus URL:    ${PROM_URL}"
echo "║  Timestamp:         ${TIMESTAMP}"
echo "║  ASR 1 runs:        ${NORMAL_RUNS} normal + ${AGGRESSIVE_RUNS} aggressive"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: ASR 1 - Latency Validation (Stochastic Tests)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$TEST_MODE" == "asr1" ] || [ "$TEST_MODE" == "both" ]; then
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║  PHASE 1: ASR 1 - LATENCY VALIDATION                                   ║"
    echo "║  Single shard deployment + stochastic load tests                       ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Step 1.1: Deploy single shard
    if [ "$SKIP_DEPLOYMENT" != "true" ]; then
        echo "━━━ Step 1.1: Deploying single shard (ME Shard A) ━━━"
        echo "Tearing down any existing ME deployments..."
        kubectl delete deployment,service -n matching-engine -l app=matching-engine --ignore-not-found=true
        kubectl delete deployment,service -n matching-engine -l app=edge-gateway --ignore-not-found=true
        sleep 5

        echo "Deploying ME Shard A..."
        bash "${SCRIPT_DIR}/05-deploy-me-single.sh"

        echo "Setting up port-forward to localhost:${ME_PORT}..."
        kubectl port-forward -n matching-engine svc/me-shard-a ${ME_PORT}:8080 &
        PORT_FORWARD_PID=$!
        echo "Port-forward PID: ${PORT_FORWARD_PID}"
        sleep 5
        echo ""
    else
        echo "━━━ Step 1.1: SKIPPED (SKIP_DEPLOYMENT=true) ━━━"
        echo ""
    fi

    # Step 1.2: Run stochastic tests (mixed normal + aggressive)
    echo "━━━ Step 1.2: Running stochastic load tests ━━━"
    echo "Starting mixed stochastic orchestrator..."
    echo "  Normal runs:     ${NORMAL_RUNS}"
    echo "  Aggressive runs: ${AGGRESSIVE_RUNS}"
    echo ""

    # Run mixed stochastic tests with Prometheus output
    export NORMAL_RUNS
    export AGGRESSIVE_RUNS
    export PROM_URL

    pushd "${K6_DIR}" > /dev/null
    bash run-mixed-stochastic.sh "http://149.130.191.100"

    # Move results to unified results dir
    LATEST_MIXED=$(ls -td results/mixed-stochastic-* 2>/dev/null | head -1 || echo "")
    if [ -n "$LATEST_MIXED" ] && [ -d "$LATEST_MIXED" ]; then
        echo "Copying stochastic results to ${RESULTS_DIR}/asr1/..."
        cp -r "${LATEST_MIXED}"/* "${RESULTS_DIR}/asr1/"
    else
        echo "WARNING: No stochastic results found."
    fi
    popd > /dev/null
    echo ""

    # Step 1.3: Collect ASR 1 metrics from Prometheus
    echo "━━━ Step 1.3: Collecting ASR 1 metrics from Prometheus ━━━"
    sleep 10  # Let metrics settle
    bash "${SCRIPT_DIR}/collect-results.sh" asr1 > "${RESULTS_DIR}/asr1/prometheus-metrics.txt"
    echo "ASR 1 metrics saved to ${RESULTS_DIR}/asr1/prometheus-metrics.txt"
    echo ""

    # Clean up port-forward if we started it
    if [ "$SKIP_DEPLOYMENT" != "true" ] && [ -n "${PORT_FORWARD_PID:-}" ]; then
        echo "Stopping port-forward (PID: ${PORT_FORWARD_PID})..."
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi

    echo "✓ PHASE 1 COMPLETE (ASR 1 - Latency Validation)"
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: ASR 2 - Scalability Validation (Multi-Shard Tests)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$TEST_MODE" == "asr2" ] || [ "$TEST_MODE" == "both" ]; then
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║  PHASE 2: ASR 2 - SCALABILITY VALIDATION                               ║"
    echo "║  Multi-shard deployment + scalability tests                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Step 2.1: Deploy multi-shard (3 shards + Edge Gateway)
    if [ "$SKIP_DEPLOYMENT" != "true" ]; then
        echo "━━━ Step 2.1: Deploying multi-shard (3 shards + Edge Gateway) ━━━"
        echo "Tearing down single shard deployment..."
        kubectl delete deployment,service -n matching-engine -l app=matching-engine --ignore-not-found=true
        kubectl delete deployment,service -n matching-engine -l app=edge-gateway --ignore-not-found=true
        sleep 5

        echo "Deploying 3 ME shards + Edge Gateway..."
        bash "${SCRIPT_DIR}/06-deploy-me-multi.sh"

        echo "Setting up port-forward to Edge Gateway on localhost:${ME_PORT}..."
        kubectl port-forward -n matching-engine svc/edge-gateway ${ME_PORT}:8080 &
        PORT_FORWARD_PID=$!
        echo "Port-forward PID: ${PORT_FORWARD_PID}"
        sleep 5
        echo ""
    else
        echo "━━━ Step 2.1: SKIPPED (SKIP_DEPLOYMENT=true) ━━━"
        echo ""
    fi

    # Step 2.2: Run ASR 2 scalability tests
    echo "━━━ Step 2.2: Running ASR 2 scalability tests ━━━"
    GW_URL="http://149.130.191.100"

    echo ""
    echo "--- Test B2: Peak Sustained (5 min) ---"
    k6 run \
      --summary-export="${RESULTS_DIR}/asr2/b2-peak-sustained.json" \
      --out experimental-prometheus-rw="${PROM_URL}" \
      -e GATEWAY_URL="${GW_URL}" \
      "${K6_DIR}/test-asr2-b2-peak-sustained.js"

    echo ""
    echo "--- Test B3: Ramp (10 min) ---"
    k6 run \
      --summary-export="${RESULTS_DIR}/asr2/b3-ramp.json" \
      --out experimental-prometheus-rw="${PROM_URL}" \
      -e GATEWAY_URL="${GW_URL}" \
      "${K6_DIR}/test-asr2-b3-ramp.js"

    echo ""
    echo "--- Test B4: Hot Symbol (5 min) ---"
    k6 run \
      --summary-export="${RESULTS_DIR}/asr2/b4-hot-symbol.json" \
      --out experimental-prometheus-rw="${PROM_URL}" \
      -e GATEWAY_URL="${GW_URL}" \
      "${K6_DIR}/test-asr2-b4-hot-symbol.js"
    echo ""

    # Step 2.3: Collect ASR 2 metrics from Prometheus
    echo "━━━ Step 2.3: Collecting ASR 2 metrics from Prometheus ━━━"
    sleep 10  # Let metrics settle
    bash "${SCRIPT_DIR}/collect-results.sh" asr2 > "${RESULTS_DIR}/asr2/prometheus-metrics.txt"
    echo "ASR 2 metrics saved to ${RESULTS_DIR}/asr2/prometheus-metrics.txt"
    echo ""

    # Clean up port-forward if we started it
    if [ "$SKIP_DEPLOYMENT" != "true" ] && [ -n "${PORT_FORWARD_PID:-}" ]; then
        echo "Stopping port-forward (PID: ${PORT_FORWARD_PID})..."
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi

    echo "✓ PHASE 2 COMPLETE (ASR 2 - Scalability Validation)"
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Generate unified report
# ─────────────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 3: GENERATING UNIFIED REPORT                                     ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

bash "${SCRIPT_DIR}/report-unified-asr.sh" "${RESULTS_DIR}"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  UNIFIED ASR TEST EXECUTION COMPLETE"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "Results directory: ${RESULTS_DIR}"
echo ""
echo "Key files:"
echo "  - unified-report.txt              # Human-readable pass/fail report"
echo "  - unified-report.csv              # Machine-readable summary"
echo "  - asr1/report.txt                 # ASR 1 stochastic test details"
echo "  - asr1/prometheus-metrics.txt     # ASR 1 Prometheus metrics"
echo "  - asr2/prometheus-metrics.txt     # ASR 2 Prometheus metrics"
echo "  - test-execution.log              # Full execution log"
echo ""
echo "Grafana dashboards: http://localhost:3000"
echo "═══════════════════════════════════════════════════════════════════════════"
