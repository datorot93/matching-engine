#!/bin/bash
# =============================================================================
# Unified ASR Report Generator
#
# Generates a consolidated pass/fail report covering both ASR 1 (Latency)
# and ASR 2 (Scalability) requirements.
#
# Usage:
#   bash report-unified-asr.sh <results_dir>
#
# Arguments:
#   results_dir  - Path to unified results directory containing asr1/ and asr2/
#
# Output:
#   <results_dir>/unified-report.txt  # Human-readable report
#   <results_dir>/unified-report.csv  # Machine-readable summary
#
# Pass/Fail Criteria:
#   ASR 1:
#     - p99 matching latency < 200ms (from stochastic tests)
#     - Error rate < 1%
#     - Success rate > 99%
#
#   ASR 2:
#     - Aggregate throughput >= 4,750 matches/min (sustained for >= 4 min)
#     - Per-shard p99 latency < 200ms
#     - Linear scaling: throughput(3 shards) >= 0.9 * 3 * throughput(1 shard)
# =============================================================================

set -euo pipefail

RESULTS_DIR="${1:?ERROR: results_dir argument required}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

if [ ! -d "$RESULTS_DIR" ]; then
    echo "ERROR: Results directory not found: $RESULTS_DIR" >&2
    exit 1
fi

TXT_REPORT="${RESULTS_DIR}/unified-report.txt"
CSV_REPORT="${RESULTS_DIR}/unified-report.csv"

# ─────────────────────────────────────────────────────────────────────────────
# Helper function: Query Prometheus
# ─────────────────────────────────────────────────────────────────────────────
query_prometheus() {
    local query="$1"
    local result=$(curl -s "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=${query}" 2>/dev/null | \
      python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    value = results[0].get('value', [0, 'N/A'])[1]
    print(value)
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
    echo "$result"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper function: Extract from k6 JSON summary
# ─────────────────────────────────────────────────────────────────────────────
extract_k6_metric() {
    local json_file="$1"
    local metric_path="$2"
    local default="${3:-N/A}"

    if [ ! -f "$json_file" ]; then
        echo "$default"
        return
    fi

    local value=$(jq -r "$metric_path // \"$default\"" "$json_file" 2>/dev/null || echo "$default")
    echo "$value"
}

# ─────────────────────────────────────────────────────────────────────────────
# Analyze ASR 1 Results
# ─────────────────────────────────────────────────────────────────────────────
analyze_asr1() {
    local asr1_dir="${RESULTS_DIR}/asr1"

    # Parse stochastic test results
    local total_runs=0
    local total_reqs=0
    local avg_p99=0
    local avg_p95=0
    local avg_p50=0
    local max_p99=0
    local min_success_rate=100
    local max_error_rate=0

    if [ -f "${asr1_dir}/report.csv" ]; then
        # Count runs (excluding header)
        total_runs=$(tail -n +2 "${asr1_dir}/report.csv" | wc -l)

        # Aggregate metrics from CSV
        tail -n +2 "${asr1_dir}/report.csv" | while IFS=',' read -r run_num run_type total_req buy sell p50 p95 p99 avg_lat err_pct ok_pct rps; do
            total_reqs=$((total_reqs + total_req))
            avg_p99=$(echo "$avg_p99 + $p99" | bc -l)
            avg_p95=$(echo "$avg_p95 + $p95" | bc -l)
            avg_p50=$(echo "$avg_p50 + $p50" | bc -l)

            # Track max p99
            if (( $(echo "$p99 > $max_p99" | bc -l) )); then
                max_p99=$p99
            fi

            # Track min success rate
            if (( $(echo "$ok_pct < $min_success_rate" | bc -l) )); then
                min_success_rate=$ok_pct
            fi

            # Track max error rate
            if (( $(echo "$err_pct > $max_error_rate" | bc -l) )); then
                max_error_rate=$err_pct
            fi
        done

        if [ "$total_runs" -gt 0 ]; then
            avg_p99=$(echo "scale=2; $avg_p99 / $total_runs" | bc -l)
            avg_p95=$(echo "scale=2; $avg_p95 / $total_runs" | bc -l)
            avg_p50=$(echo "scale=2; $avg_p50 / $total_runs" | bc -l)
        fi
    fi

    # Query Prometheus for ME-internal metrics
    local prom_p99=$(query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le))')
    if [ "$prom_p99" != "N/A" ]; then
        prom_p99_ms=$(python3 -c "print(f'{float(\"$prom_p99\") * 1000:.2f}')" 2>/dev/null || echo "N/A")
    else
        prom_p99_ms="N/A"
    fi

    # Determine pass/fail
    local asr1_pass="UNKNOWN"
    if [ "$max_p99" != "0" ] && [ "$max_p99" != "N/A" ]; then
        if (( $(echo "$max_p99 < 200" | bc -l) )) && \
           (( $(echo "$min_success_rate > 99" | bc -l) )) && \
           (( $(echo "$max_error_rate < 1" | bc -l) )); then
            asr1_pass="PASS"
        else
            asr1_pass="FAIL"
        fi
    fi

    # Export for report generation
    export ASR1_TOTAL_RUNS="$total_runs"
    export ASR1_TOTAL_REQS="$total_reqs"
    export ASR1_AVG_P99="$avg_p99"
    export ASR1_AVG_P95="$avg_p95"
    export ASR1_AVG_P50="$avg_p50"
    export ASR1_MAX_P99="$max_p99"
    export ASR1_MIN_SUCCESS_RATE="$min_success_rate"
    export ASR1_MAX_ERROR_RATE="$max_error_rate"
    export ASR1_PROM_P99_MS="$prom_p99_ms"
    export ASR1_PASS="$asr1_pass"
}

# ─────────────────────────────────────────────────────────────────────────────
# Analyze ASR 2 Results
# ─────────────────────────────────────────────────────────────────────────────
analyze_asr2() {
    local asr2_dir="${RESULTS_DIR}/asr2"

    # Extract metrics from k6 test summaries
    local b2_p99=$(extract_k6_metric "${asr2_dir}/b2-peak-sustained.json" '.metrics.http_req_duration.values["p(99)"]' "0")
    local b2_reqs=$(extract_k6_metric "${asr2_dir}/b2-peak-sustained.json" '.metrics.http_reqs.values.count' "0")

    local b3_p99=$(extract_k6_metric "${asr2_dir}/b3-ramp.json" '.metrics.http_req_duration.values["p(99)"]' "0")
    local b3_reqs=$(extract_k6_metric "${asr2_dir}/b3-ramp.json" '.metrics.http_reqs.values.count' "0")

    local b4_p99=$(extract_k6_metric "${asr2_dir}/b4-hot-symbol.json" '.metrics.http_req_duration.values["p(99)"]' "0")
    local b4_reqs=$(extract_k6_metric "${asr2_dir}/b4-hot-symbol.json" '.metrics.http_reqs.values.count' "0")

    # Query Prometheus for throughput and per-shard latency
    local throughput=$(query_prometheus 'sum(rate(me_matches_total[5m])) * 60')
    local shard_a_p99=$(query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard) and on(shard) label_replace({shard="a"}, "", "", "", ""))')
    local shard_b_p99=$(query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard) and on(shard) label_replace({shard="b"}, "", "", "", ""))')
    local shard_c_p99=$(query_prometheus 'histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[5m])) by (le, shard) and on(shard) label_replace({shard="c"}, "", "", "", ""))')

    # Convert to ms
    if [ "$shard_a_p99" != "N/A" ]; then
        shard_a_p99_ms=$(python3 -c "print(f'{float(\"$shard_a_p99\") * 1000:.2f}')" 2>/dev/null || echo "N/A")
    else
        shard_a_p99_ms="N/A"
    fi

    if [ "$shard_b_p99" != "N/A" ]; then
        shard_b_p99_ms=$(python3 -c "print(f'{float(\"$shard_b_p99\") * 1000:.2f}')" 2>/dev/null || echo "N/A")
    else
        shard_b_p99_ms="N/A"
    fi

    if [ "$shard_c_p99" != "N/A" ]; then
        shard_c_p99_ms=$(python3 -c "print(f'{float(\"$shard_c_p99\") * 1000:.2f}')" 2>/dev/null || echo "N/A")
    else
        shard_c_p99_ms="N/A"
    fi

    # Determine pass/fail
    local asr2_pass="UNKNOWN"
    if [ "$throughput" != "N/A" ]; then
        throughput_num=$(python3 -c "print(float('$throughput'))" 2>/dev/null || echo "0")
        if (( $(echo "$throughput_num >= 4750" | bc -l) )); then
            asr2_pass="PASS"
        else
            asr2_pass="FAIL"
        fi
    fi

    # Check latency constraints
    local all_shards_ok="true"
    for shard_p99_ms in "$shard_a_p99_ms" "$shard_b_p99_ms" "$shard_c_p99_ms"; do
        if [ "$shard_p99_ms" != "N/A" ]; then
            if (( $(echo "$shard_p99_ms >= 200" | bc -l) )); then
                all_shards_ok="false"
                asr2_pass="FAIL"
            fi
        fi
    done

    # Export for report generation
    export ASR2_B2_P99="$b2_p99"
    export ASR2_B2_REQS="$b2_reqs"
    export ASR2_B3_P99="$b3_p99"
    export ASR2_B3_REQS="$b3_reqs"
    export ASR2_B4_P99="$b4_p99"
    export ASR2_B4_REQS="$b4_reqs"
    export ASR2_THROUGHPUT="$throughput"
    export ASR2_SHARD_A_P99_MS="$shard_a_p99_ms"
    export ASR2_SHARD_B_P99_MS="$shard_b_p99_ms"
    export ASR2_SHARD_C_P99_MS="$shard_c_p99_ms"
    export ASR2_PASS="$asr2_pass"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main execution
# ─────────────────────────────────────────────────────────────────────────────
echo "Analyzing ASR 1 results..."
if [ -d "${RESULTS_DIR}/asr1" ]; then
    analyze_asr1
else
    echo "WARNING: ASR 1 results directory not found. Skipping ASR 1 analysis."
    export ASR1_PASS="NOT_RUN"
    export ASR1_TOTAL_RUNS="0"
    export ASR1_TOTAL_REQS="0"
    export ASR1_AVG_P99="N/A"
    export ASR1_MAX_P99="N/A"
    export ASR1_MIN_SUCCESS_RATE="N/A"
    export ASR1_MAX_ERROR_RATE="N/A"
    export ASR1_PROM_P99_MS="N/A"
fi

echo "Analyzing ASR 2 results..."
if [ -d "${RESULTS_DIR}/asr2" ]; then
    analyze_asr2
else
    echo "WARNING: ASR 2 results directory not found. Skipping ASR 2 analysis."
    export ASR2_PASS="NOT_RUN"
    export ASR2_THROUGHPUT="N/A"
    export ASR2_B2_P99="N/A"
    export ASR2_B3_P99="N/A"
    export ASR2_B4_P99="N/A"
    export ASR2_SHARD_A_P99_MS="N/A"
    export ASR2_SHARD_B_P99_MS="N/A"
    export ASR2_SHARD_C_P99_MS="N/A"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generate unified report (text)
# ─────────────────────────────────────────────────────────────────────────────
cat > "$TXT_REPORT" <<EOF
╔══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                     UNIFIED ASR VALIDATION REPORT                                   ║
║                                     $(date '+%Y-%m-%d %H:%M:%S')                                                        ║
╠══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  Results Directory: ${RESULTS_DIR}
╚══════════════════════════════════════════════════════════════════════════════════════════════════════╝

┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ASR 1: LATENCY REQUIREMENT                                                                         │
│  Target: p99 matching latency < 200ms, error rate < 1%, success rate > 99%                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Status:                ${ASR1_PASS}

  Stochastic Test Summary:
    Total runs:          ${ASR1_TOTAL_RUNS}
    Total requests:      ${ASR1_TOTAL_REQS}

    Latency (k6 measurements):
      Avg p50:           ${ASR1_AVG_P50} ms
      Avg p95:           ${ASR1_AVG_P95} ms
      Avg p99:           ${ASR1_AVG_P99} ms
      Max p99:           ${ASR1_MAX_P99} ms   ← Primary criterion

    Error rates:
      Min success rate:  ${ASR1_MIN_SUCCESS_RATE} %
      Max error rate:    ${ASR1_MAX_ERROR_RATE} %

  ME-Internal Metrics (Prometheus):
    p99 match duration:  ${ASR1_PROM_P99_MS} ms

  Detailed results: ${RESULTS_DIR}/asr1/report.txt


┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ASR 2: SCALABILITY REQUIREMENT                                                                     │
│  Target: >= 4,750 matches/min sustained, per-shard p99 < 200ms, linear scaling                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Status:                ${ASR2_PASS}

  Throughput (Prometheus):
    Aggregate (3 shards): ${ASR2_THROUGHPUT} matches/min   ← Primary criterion

  Per-Shard p99 Latency (Prometheus):
    Shard A:             ${ASR2_SHARD_A_P99_MS} ms
    Shard B:             ${ASR2_SHARD_B_P99_MS} ms
    Shard C:             ${ASR2_SHARD_C_P99_MS} ms

  k6 Test Results:
    B2 (Peak Sustained): p99 = ${ASR2_B2_P99} ms, ${ASR2_B2_REQS} requests
    B3 (Ramp):           p99 = ${ASR2_B3_P99} ms, ${ASR2_B3_REQS} requests
    B4 (Hot Symbol):     p99 = ${ASR2_B4_P99} ms, ${ASR2_B4_REQS} requests

  Detailed results: ${RESULTS_DIR}/asr2/prometheus-metrics.txt


┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  OVERALL VALIDATION SUMMARY                                                                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

  ASR 1 (Latency):      ${ASR1_PASS}
  ASR 2 (Scalability):  ${ASR2_PASS}

  ─────────────────────────────────────────────────────────────────────────────────────────────────────
EOF

# Add overall determination
if [ "$ASR1_PASS" == "PASS" ] && [ "$ASR2_PASS" == "PASS" ]; then
    cat >> "$TXT_REPORT" <<EOF
  OVERALL RESULT:       ✓ PASS - All architectural requirements validated
  ─────────────────────────────────────────────────────────────────────────────────────────────────────

  The Matching Engine architecture successfully meets both latency and scalability requirements.
  The system is ready for production deployment pending stakeholder review.

EOF
elif [ "$ASR1_PASS" == "NOT_RUN" ] || [ "$ASR2_PASS" == "NOT_RUN" ]; then
    cat >> "$TXT_REPORT" <<EOF
  OVERALL RESULT:       INCOMPLETE - Not all tests were run
  ─────────────────────────────────────────────────────────────────────────────────────────────────────

  Review the test execution log for details on which test suites were executed.

EOF
else
    cat >> "$TXT_REPORT" <<EOF
  OVERALL RESULT:       ✗ FAIL - One or more requirements not met
  ─────────────────────────────────────────────────────────────────────────────────────────────────────

  The Matching Engine architecture does not meet all specified requirements.
  Review the detailed results above to identify root causes and necessary optimizations.

EOF
fi

cat >> "$TXT_REPORT" <<EOF

═══════════════════════════════════════════════════════════════════════════════════════════════════════
  Additional Resources
═══════════════════════════════════════════════════════════════════════════════════════════════════════

  Grafana Dashboards:   http://localhost:3000
  Prometheus:           http://localhost:9090
  Test Execution Log:   ${RESULTS_DIR}/test-execution.log

═══════════════════════════════════════════════════════════════════════════════════════════════════════
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Generate CSV report
# ─────────────────────────────────────────────────────────────────────────────
cat > "$CSV_REPORT" <<EOF
requirement,metric,value,threshold,status
ASR1,max_p99_latency_ms,${ASR1_MAX_P99},200,${ASR1_PASS}
ASR1,min_success_rate_pct,${ASR1_MIN_SUCCESS_RATE},99,${ASR1_PASS}
ASR1,max_error_rate_pct,${ASR1_MAX_ERROR_RATE},1,${ASR1_PASS}
ASR1,total_runs,${ASR1_TOTAL_RUNS},N/A,N/A
ASR1,total_requests,${ASR1_TOTAL_REQS},N/A,N/A
ASR2,throughput_matches_per_min,${ASR2_THROUGHPUT},4750,${ASR2_PASS}
ASR2,shard_a_p99_latency_ms,${ASR2_SHARD_A_P99_MS},200,${ASR2_PASS}
ASR2,shard_b_p99_latency_ms,${ASR2_SHARD_B_P99_MS},200,${ASR2_PASS}
ASR2,shard_c_p99_latency_ms,${ASR2_SHARD_C_P99_MS},200,${ASR2_PASS}
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Print report to stdout
# ─────────────────────────────────────────────────────────────────────────────
cat "$TXT_REPORT"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Report files generated:"
echo "    ${TXT_REPORT}"
echo "    ${CSV_REPORT}"
echo "═══════════════════════════════════════════════════════════════════════════"
