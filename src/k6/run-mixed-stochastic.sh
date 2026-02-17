#!/usr/bin/env bash
# =============================================================================
# Mixed Stochastic Load Test Orchestrator
#
# Executes 20 normal (2 min) and 20 aggressive (20 sec) stochastic tests
# in random order, starting with a normal test. Collects per-run k6 JSON
# summaries and generates a consolidated CSV + text report.
#
# Usage:
#   bash run-mixed-stochastic.sh [ME_URL]
#
# Arguments:
#   ME_URL  - (optional) ME Shard A URL. Default: http://localhost:8081
#
# Environment variables:
#   NORMAL_RUNS     - Number of normal runs (default: 20)
#   AGGRESSIVE_RUNS - Number of aggressive runs (default: 20)
#   PROM_URL        - Prometheus remote write URL (optional)
#
# Output:
#   results/mixed-stochastic-YYYYMMDD-HHMMSS/
#     run-01-normal.json       # k6 JSON summary per run
#     run-02-aggressive.json
#     ...
#     report.csv               # Consolidated CSV report
#     report.txt               # Human-readable report
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
ME_URL="${1:-http://149.130.191.100}"
NORMAL_RUNS="${NORMAL_RUNS:-20}"
AGGRESSIVE_RUNS="${AGGRESSIVE_RUNS:-20}"
PROM_URL="${PROM_URL:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMAL_SCRIPT="${SCRIPT_DIR}/test-stochastic-normal-2min.js"
AGGRESSIVE_SCRIPT="${SCRIPT_DIR}/test-stochastic-aggressive-20s.js"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${SCRIPT_DIR}/results/mixed-stochastic-${TIMESTAMP}"

TOTAL_RUNS=$(( NORMAL_RUNS + AGGRESSIVE_RUNS ))

# ─────────────────────────────────────────────────────────────────────────────
# Validate
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v k6 &>/dev/null; then
    echo "ERROR: k6 is not installed. Install it first." >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is not installed. Install it first." >&2
    exit 1
fi

if [ ! -f "$NORMAL_SCRIPT" ]; then
    echo "ERROR: Normal test script not found: $NORMAL_SCRIPT" >&2
    exit 1
fi

if [ ! -f "$AGGRESSIVE_SCRIPT" ]; then
    echo "ERROR: Aggressive test script not found: $AGGRESSIVE_SCRIPT" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Generate random execution sequence
# First run is always normal, remaining are shuffled
# ─────────────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║       Mixed Stochastic Load Test Orchestrator                      ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Normal runs:     ${NORMAL_RUNS}                                            ║"
echo "║  Aggressive runs: ${AGGRESSIVE_RUNS}                                            ║"
echo "║  Total runs:      ${TOTAL_RUNS}                                            ║"
echo "║  ME URL:          ${ME_URL}"
echo "║  Results dir:     ${RESULTS_DIR}"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Build the sequence: first is always "normal", rest are shuffled
SEQUENCE=("normal")  # First run is always normal
REMAINING_NORMAL=$(( NORMAL_RUNS - 1 ))
REMAINING_AGGRESSIVE=$AGGRESSIVE_RUNS

# Build pool of remaining runs
POOL=()
for (( i=0; i<REMAINING_NORMAL; i++ )); do
    POOL+=("normal")
done
for (( i=0; i<REMAINING_AGGRESSIVE; i++ )); do
    POOL+=("aggressive")
done

# Shuffle the pool (Fisher-Yates)
for (( i=${#POOL[@]}-1; i>0; i-- )); do
    j=$(( RANDOM % (i + 1) ))
    tmp="${POOL[$i]}"
    POOL[$i]="${POOL[$j]}"
    POOL[$j]="$tmp"
done

# Append shuffled pool to sequence
SEQUENCE+=("${POOL[@]}")

echo "Execution sequence:"
for (( i=0; i<${#SEQUENCE[@]}; i++ )); do
    RUN_NUM=$(( i + 1 ))
    printf "  Run %02d: %s\n" "$RUN_NUM" "${SEQUENCE[$i]}"
done
echo ""

# Save sequence to file
SEQUENCE_FILE="${RESULTS_DIR}/sequence.txt"
for (( i=0; i<${#SEQUENCE[@]}; i++ )); do
    RUN_NUM=$(( i + 1 ))
    printf "%02d %s\n" "$RUN_NUM" "${SEQUENCE[$i]}" >> "$SEQUENCE_FILE"
done

# ─────────────────────────────────────────────────────────────────────────────
# Execute test runs
# ─────────────────────────────────────────────────────────────────────────────
NORMAL_COUNT=0
AGGRESSIVE_COUNT=0

for (( i=0; i<${#SEQUENCE[@]}; i++ )); do
    RUN_NUM=$(( i + 1 ))
    RUN_TYPE="${SEQUENCE[$i]}"
    RUN_NUM_PADDED=$(printf "%02d" "$RUN_NUM")
    JSON_FILE="${RESULTS_DIR}/run-${RUN_NUM_PADDED}-${RUN_TYPE}.json"

    if [ "$RUN_TYPE" = "normal" ]; then
        NORMAL_COUNT=$(( NORMAL_COUNT + 1 ))
        SCRIPT="$NORMAL_SCRIPT"
        DURATION_LABEL="2 min"
    else
        AGGRESSIVE_COUNT=$(( AGGRESSIVE_COUNT + 1 ))
        SCRIPT="$AGGRESSIVE_SCRIPT"
        DURATION_LABEL="20 sec"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Run ${RUN_NUM_PADDED}/${TOTAL_RUNS}  │  Type: ${RUN_TYPE^^}  │  Duration: ${DURATION_LABEL}"
    echo "  Normal so far: ${NORMAL_COUNT}/${NORMAL_RUNS}  │  Aggressive so far: ${AGGRESSIVE_COUNT}/${AGGRESSIVE_RUNS}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Build k6 command
    K6_CMD="k6 run --summary-export=${JSON_FILE} -e ME_SHARD_A_URL=${ME_URL}"

    if [ -n "$PROM_URL" ]; then
        K6_CMD="$K6_CMD --out experimental-prometheus-rw=${PROM_URL}"
    fi

    K6_CMD="$K6_CMD $SCRIPT"

    # Run k6 (allow failures -- we capture everything in the JSON)
    START_TIME=$(date +%s)
    eval "$K6_CMD" || true
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))

    echo ""
    echo "  Run ${RUN_NUM_PADDED} completed in ${ELAPSED}s. Summary saved to: $(basename "$JSON_FILE")"
    echo ""

    # Brief pause between runs to let the system settle
    if [ "$i" -lt $(( ${#SEQUENCE[@]} - 1 )) ]; then
        echo "  Pausing 5 seconds before next run..."
        sleep 5
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Generate consolidated report
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Generating consolidated report...                                 ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

CSV_FILE="${RESULTS_DIR}/report.csv"
TXT_FILE="${RESULTS_DIR}/report.txt"

# CSV header
echo "run_number,run_type,total_requests,buy_orders,sell_orders,p50_latency_ms,p95_latency_ms,p99_latency_ms,avg_latency_ms,error_rate_pct,success_rate_pct,http_reqs_per_sec" > "$CSV_FILE"

# Text report header
{
    echo "╔══════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                         MIXED STOCHASTIC LOAD TEST REPORT                                         ║"
    echo "║                         $(date '+%Y-%m-%d %H:%M:%S')                                                        ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════════════════════════════╣"
    echo "║  ME URL:          ${ME_URL}"
    echo "║  Normal runs:     ${NORMAL_RUNS} (2 min each)"
    echo "║  Aggressive runs: ${AGGRESSIVE_RUNS} (20 sec each)"
    echo "║  Total runs:      ${TOTAL_RUNS}"
    echo "╚══════════════════════════════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    printf "%-6s %-12s %12s %12s %12s %10s %10s %10s %10s %10s %10s %12s\n" \
        "Run#" "Type" "Total Reqs" "BUY Orders" "SELL Orders" "p50(ms)" "p95(ms)" "p99(ms)" "Avg(ms)" "Err%" "OK%" "Reqs/sec"
    printf "%-6s %-12s %12s %12s %12s %10s %10s %10s %10s %10s %10s %12s\n" \
        "─────" "────────────" "────────────" "────────────" "────────────" "──────────" "──────────" "──────────" "──────────" "──────────" "──────────" "────────────"
} > "$TXT_FILE"

# Accumulators for summary
TOTAL_REQS_ALL=0
TOTAL_BUY_ALL=0
TOTAL_SELL_ALL=0
NORMAL_REQS=0
AGGRESSIVE_REQS=0

# Process each run's JSON summary
for (( i=0; i<${#SEQUENCE[@]}; i++ )); do
    RUN_NUM=$(( i + 1 ))
    RUN_TYPE="${SEQUENCE[$i]}"
    RUN_NUM_PADDED=$(printf "%02d" "$RUN_NUM")
    JSON_FILE="${RESULTS_DIR}/run-${RUN_NUM_PADDED}-${RUN_TYPE}.json"

    if [ ! -f "$JSON_FILE" ]; then
        echo "  WARNING: Missing results file: $(basename "$JSON_FILE")"
        printf "%d,%s,0,0,0,0,0,0,0,0,0,0\n" "$RUN_NUM" "$RUN_TYPE" >> "$CSV_FILE"
        printf "%-6s %-12s %12s %12s %12s %10s %10s %10s %10s %10s %10s %12s\n" \
            "$RUN_NUM_PADDED" "$RUN_TYPE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" >> "$TXT_FILE"
        continue
    fi

    # Extract metrics from k6 JSON summary using jq
    TOTAL_REQS=$(jq -r '.metrics.http_reqs.values.count // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    BUY_COUNT=$(jq -r '.metrics.buy_order_count.values.count // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    SELL_COUNT=$(jq -r '.metrics.sell_order_count.values.count // 0' "$JSON_FILE" 2>/dev/null || echo "0")

    # If buy/sell counters not available, estimate from buy_order_rate
    if [ "$BUY_COUNT" = "0" ] && [ "$SELL_COUNT" = "0" ] && [ "$TOTAL_REQS" != "0" ]; then
        BUY_RATE=$(jq -r '.metrics.buy_order_rate.values.rate // 0' "$JSON_FILE" 2>/dev/null || echo "0")
        if [ "$BUY_RATE" != "0" ] && [ "$BUY_RATE" != "null" ]; then
            BUY_COUNT=$(echo "$TOTAL_REQS * $BUY_RATE" | bc -l 2>/dev/null | cut -d. -f1 || echo "0")
            SELL_COUNT=$(( TOTAL_REQS - BUY_COUNT ))
        fi
    fi

    P50=$(jq -r '.metrics.http_req_duration.values["p(50)"] // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    P95=$(jq -r '.metrics.http_req_duration.values["p(95)"] // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    P99=$(jq -r '.metrics.http_req_duration.values["p(99)"] // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    AVG=$(jq -r '.metrics.http_req_duration.values.avg // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    REQS_PER_SEC=$(jq -r '.metrics.http_reqs.values.rate // 0' "$JSON_FILE" 2>/dev/null || echo "0")

    # Error rate
    FAIL_RATE=$(jq -r '.metrics.http_req_failed.values.rate // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    ERR_PCT=$(echo "$FAIL_RATE * 100" | bc -l 2>/dev/null | head -c6 || echo "0")

    # Success rate from custom metric
    SUCCESS_RATE=$(jq -r '.metrics.order_success_rate.values.rate // 0' "$JSON_FILE" 2>/dev/null || echo "0")
    OK_PCT=$(echo "$SUCCESS_RATE * 100" | bc -l 2>/dev/null | head -c6 || echo "0")

    # Format numbers
    P50_FMT=$(printf "%.2f" "$P50" 2>/dev/null || echo "$P50")
    P95_FMT=$(printf "%.2f" "$P95" 2>/dev/null || echo "$P95")
    P99_FMT=$(printf "%.2f" "$P99" 2>/dev/null || echo "$P99")
    AVG_FMT=$(printf "%.2f" "$AVG" 2>/dev/null || echo "$AVG")
    RPS_FMT=$(printf "%.2f" "$REQS_PER_SEC" 2>/dev/null || echo "$REQS_PER_SEC")

    # Write CSV row
    printf "%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$RUN_NUM" "$RUN_TYPE" "$TOTAL_REQS" "$BUY_COUNT" "$SELL_COUNT" \
        "$P50_FMT" "$P95_FMT" "$P99_FMT" "$AVG_FMT" "$ERR_PCT" "$OK_PCT" "$RPS_FMT" >> "$CSV_FILE"

    # Write text row
    printf "%-6s %-12s %12s %12s %12s %10s %10s %10s %10s %10s %10s %12s\n" \
        "$RUN_NUM_PADDED" "$RUN_TYPE" "$TOTAL_REQS" "$BUY_COUNT" "$SELL_COUNT" \
        "$P50_FMT" "$P95_FMT" "$P99_FMT" "$AVG_FMT" "$ERR_PCT" "$OK_PCT" "$RPS_FMT" >> "$TXT_FILE"

    # Accumulate totals
    TOTAL_REQS_ALL=$(( TOTAL_REQS_ALL + TOTAL_REQS ))
    TOTAL_BUY_ALL=$(( TOTAL_BUY_ALL + BUY_COUNT ))
    TOTAL_SELL_ALL=$(( TOTAL_SELL_ALL + SELL_COUNT ))

    if [ "$RUN_TYPE" = "normal" ]; then
        NORMAL_REQS=$(( NORMAL_REQS + TOTAL_REQS ))
    else
        AGGRESSIVE_REQS=$(( AGGRESSIVE_REQS + TOTAL_REQS ))
    fi
done

# Write summary to text report
{
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║  SUMMARY                                                                                          ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════════════════════════════╣"
    echo "║"
    echo "║  Total requests (all runs):    ${TOTAL_REQS_ALL}"
    echo "║  Total BUY orders:             ${TOTAL_BUY_ALL}"
    echo "║  Total SELL orders:            ${TOTAL_SELL_ALL}"
    echo "║"
    echo "║  Requests from NORMAL runs:    ${NORMAL_REQS}"
    echo "║  Requests from AGGRESSIVE runs: ${AGGRESSIVE_REQS}"
    echo "║"
    echo "╚══════════════════════════════════════════════════════════════════════════════════════════════════════╝"
} >> "$TXT_FILE"

# Print report to stdout
echo ""
cat "$TXT_FILE"

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Results saved to: ${RESULTS_DIR}/"
echo "  - report.csv       (machine-readable)"
echo "  - report.txt       (human-readable)"
echo "  - sequence.txt     (execution order)"
echo "  - run-XX-TYPE.json (per-run k6 JSON summaries)"
echo "═══════════════════════════════════════════════════════════════════════"
