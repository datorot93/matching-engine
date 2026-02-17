# Unified ASR Testing Guide

## Overview

This document describes the unified ASR (Architecturally Significant Requirement) testing framework that validates both ASR 1 (Latency) and ASR 2 (Scalability) in a single execution.

## Architecture

The unified testing framework orchestrates two distinct test phases:

### Phase 1: ASR 1 - Latency Validation (Single Shard)
- **Deployment:** Single ME shard (Shard A) with no gateway
- **Test Type:** Stochastic load tests with mixed normal and aggressive bursts
- **Duration:** Variable (default: 20 normal runs × 2 min + 20 aggressive runs × 20 sec ≈ 47 minutes)
- **Target:** Direct ME shard access via `http://localhost:8081`
- **Criteria:**
  - p99 latency < 200ms
  - Error rate < 1%
  - Success rate > 99%

### Phase 2: ASR 2 - Scalability Validation (Multi-Shard)
- **Deployment:** 3 ME shards (A, B, C) + Edge Gateway
- **Test Type:** Scalability tests (baseline, peak sustained, ramp, hot symbol)
- **Duration:** 20 minutes (5 min + 10 min + 5 min)
- **Target:** Edge Gateway via `http://localhost:8081`
- **Criteria:**
  - Aggregate throughput >= 4,750 matches/min
  - Per-shard p99 latency < 200ms
  - Linear scaling: throughput(3 shards) >= 0.9 × 3 × throughput(1 shard)

## Project Structure

```
infra/scripts/
  run-unified-asr-tests.sh       # Main orchestrator (executes both phases)
  report-unified-asr.sh           # Consolidated report generator
  05-deploy-me-single.sh          # Single shard deployment (ASR 1)
  06-deploy-me-multi.sh           # Multi-shard deployment (ASR 2)
  08-run-asr1-tests.sh            # Legacy ASR 1 runner (deprecated)
  09-run-asr2-tests.sh            # Legacy ASR 2 runner (deprecated)
  collect-results.sh              # Prometheus metric collector

src/k6/
  run-mixed-stochastic.sh         # Stochastic test orchestrator (ASR 1)
  test-stochastic-normal-2min.js  # Normal load test (2 min)
  test-stochastic-aggressive-20s.js # Aggressive burst test (20 sec)
  test-asr2-b1-baseline.js        # Single shard baseline
  test-asr2-b2-peak-sustained.js  # Peak sustained (5K/min)
  test-asr2-b3-ramp.js            # Progressive ramp (1K → 5K)
  test-asr2-b4-hot-symbol.js      # Hot symbol test (80% skew)
```

## Prerequisites

1. **k3d cluster** with observability stack:
   ```bash
   bash infra/scripts/01-create-cluster.sh
   bash infra/scripts/02-deploy-observability.sh
   bash infra/scripts/03-deploy-redpanda.sh
   bash infra/scripts/04-build-images.sh
   ```

2. **Tools installed:**
   - k6 (Grafana k6)
   - kubectl
   - jq
   - python3 (with json module)
   - bc (basic calculator)

3. **Prometheus remote write** enabled:
   - The orchestrator expects Prometheus at `http://localhost:9090/api/v1/write`
   - This is pre-configured in the observability stack deployment

## Execution

### Run Both ASR 1 and ASR 2 (Full Suite)

```bash
cd /home/datorot/matching-engine
bash infra/scripts/run-unified-asr-tests.sh --both
```

**Duration:** ~67 minutes total
- ASR 1: ~47 minutes (20 normal + 20 aggressive runs)
- ASR 2: ~20 minutes (3 tests)

### Run Only ASR 1 (Latency Tests)

```bash
bash infra/scripts/run-unified-asr-tests.sh --asr1-only
```

**Duration:** ~47 minutes

### Run Only ASR 2 (Scalability Tests)

```bash
bash infra/scripts/run-unified-asr-tests.sh --asr2-only
```

**Duration:** ~20 minutes

### Environment Variables

| Variable | Default | Description |
|:---|:---|:---|
| `SKIP_DEPLOYMENT` | `false` | Set to `true` to skip k8s deployment steps |
| `ME_PORT` | `8081` | Port for ME/Gateway port-forward |
| `PROM_URL` | `http://localhost:9090/api/v1/write` | Prometheus remote write endpoint |
| `NORMAL_RUNS` | `20` | Number of normal (2 min) stochastic runs |
| `AGGRESSIVE_RUNS` | `20` | Number of aggressive (20 sec) stochastic runs |

**Example:** Run shorter test for development validation:

```bash
NORMAL_RUNS=5 AGGRESSIVE_RUNS=5 \
  bash infra/scripts/run-unified-asr-tests.sh --both
```

**Example:** Run tests against existing deployment (skip deployment):

```bash
SKIP_DEPLOYMENT=true \
  bash infra/scripts/run-unified-asr-tests.sh --both
```

## Output Structure

All results are written to `infra/scripts/results/unified-YYYYMMDD-HHMMSS/`:

```
results/unified-20260215-143022/
  ├── test-execution.log              # Full execution log (stdout + stderr)
  ├── unified-report.txt              # Human-readable pass/fail report
  ├── unified-report.csv              # Machine-readable summary
  ├── asr1/                           # ASR 1 stochastic test results
  │   ├── run-01-normal.json          # k6 JSON summary per run
  │   ├── run-02-aggressive.json
  │   ├── ...
  │   ├── report.csv                  # Consolidated CSV (all runs)
  │   ├── report.txt                  # Human-readable report (all runs)
  │   ├── sequence.txt                # Execution order
  │   └── prometheus-metrics.txt      # ASR 1 Prometheus metrics
  └── asr2/                           # ASR 2 scalability test results
      ├── b2-peak-sustained.json      # k6 JSON summary (Test B2)
      ├── b3-ramp.json                # k6 JSON summary (Test B3)
      ├── b4-hot-symbol.json          # k6 JSON summary (Test B4)
      └── prometheus-metrics.txt      # ASR 2 Prometheus metrics
```

## Sample Unified Report

### Text Format (`unified-report.txt`)

```
╔══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                     UNIFIED ASR VALIDATION REPORT                                   ║
║                                     2026-02-15 14:52:33                                             ║
╠══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  Results Directory: /home/datorot/matching-engine/infra/scripts/results/unified-20260215-143022
╚══════════════════════════════════════════════════════════════════════════════════════════════════════╝

┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ASR 1: LATENCY REQUIREMENT                                                                         │
│  Target: p99 matching latency < 200ms, error rate < 1%, success rate > 99%                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Status:                PASS

  Stochastic Test Summary:
    Total runs:          40
    Total requests:      105,234

    Latency (k6 measurements):
      Avg p50:           45.23 ms
      Avg p95:           112.67 ms
      Avg p99:           156.89 ms
      Max p99:           187.45 ms   ← Primary criterion

    Error rates:
      Min success rate:  99.87 %
      Max error rate:    0.13 %

  ME-Internal Metrics (Prometheus):
    p99 match duration:  153.21 ms

  Detailed results: /home/datorot/matching-engine/infra/scripts/results/unified-20260215-143022/asr1/report.txt


┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ASR 2: SCALABILITY REQUIREMENT                                                                     │
│  Target: >= 4,750 matches/min sustained, per-shard p99 < 200ms, linear scaling                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

  Status:                PASS

  Throughput (Prometheus):
    Aggregate (3 shards): 5,032.45 matches/min   ← Primary criterion

  Per-Shard p99 Latency (Prometheus):
    Shard A:             142.33 ms
    Shard B:             138.67 ms
    Shard C:             145.12 ms

  k6 Test Results:
    B2 (Peak Sustained): p99 = 165.23 ms, 25,200 requests
    B3 (Ramp):           p99 = 172.45 ms, 50,400 requests
    B4 (Hot Symbol):     p99 = 168.91 ms, 25,200 requests

  Detailed results: /home/datorot/matching-engine/infra/scripts/results/unified-20260215-143022/asr2/prometheus-metrics.txt


┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  OVERALL VALIDATION SUMMARY                                                                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

  ASR 1 (Latency):      PASS
  ASR 2 (Scalability):  PASS

  ─────────────────────────────────────────────────────────────────────────────────────────────────────
  OVERALL RESULT:       ✓ PASS - All architectural requirements validated
  ─────────────────────────────────────────────────────────────────────────────────────────────────────

  The Matching Engine architecture successfully meets both latency and scalability requirements.
  The system is ready for production deployment pending stakeholder review.


═══════════════════════════════════════════════════════════════════════════════════════════════════════
  Additional Resources
═══════════════════════════════════════════════════════════════════════════════════════════════════════

  Grafana Dashboards:   http://localhost:3000
  Prometheus:           http://localhost:9090
  Test Execution Log:   /home/datorot/.../results/unified-20260215-143022/test-execution.log

═══════════════════════════════════════════════════════════════════════════════════════════════════════
```

### CSV Format (`unified-report.csv`)

```csv
requirement,metric,value,threshold,status
ASR1,max_p99_latency_ms,187.45,200,PASS
ASR1,min_success_rate_pct,99.87,99,PASS
ASR1,max_error_rate_pct,0.13,1,PASS
ASR1,total_runs,40,N/A,N/A
ASR1,total_requests,105234,N/A,N/A
ASR2,throughput_matches_per_min,5032.45,4750,PASS
ASR2,shard_a_p99_latency_ms,142.33,200,PASS
ASR2,shard_b_p99_latency_ms,138.67,200,PASS
ASR2,shard_c_p99_latency_ms,145.12,200,PASS
```

## Interpreting Results

### ASR 1 Pass Criteria

✓ **PASS** if ALL conditions are met:
- Max p99 latency < 200ms (across all stochastic runs)
- Min success rate > 99%
- Max error rate < 1%

✗ **FAIL** if ANY condition fails:
- Any run has p99 >= 200ms
- Any run has success rate <= 99%
- Any run has error rate >= 1%

### ASR 2 Pass Criteria

✓ **PASS** if ALL conditions are met:
- Aggregate throughput >= 4,750 matches/min (sustained for >= 4 min in Test B2)
- Per-shard p99 < 200ms for ALL shards (A, B, C)
- Linear scaling ratio >= 0.9 (calculated from Test B1 baseline)

✗ **FAIL** if ANY condition fails:
- Throughput < 4,750 matches/min
- Any shard has p99 >= 200ms
- Scaling efficiency < 90%

### Overall Result

- **PASS:** Both ASR 1 and ASR 2 pass
- **FAIL:** Either ASR 1 or ASR 2 fails
- **INCOMPLETE:** One or both test suites were not run

## Grafana Dashboards

View real-time metrics during test execution:

1. Open Grafana: http://localhost:3000
2. Navigate to "Matching Engine Experiment" dashboard
3. Key panels:
   - **Matching Latency Distribution** (p50, p95, p99)
   - **Throughput** (matches/min per shard, aggregate)
   - **Order Book Depth** (per symbol)
   - **JVM Heap Usage** (per shard)
   - **GC Pause Times** (ZGC)

## Troubleshooting

### Problem: "Port 8081 already in use"

**Solution:** Change the port via environment variable:
```bash
ME_PORT=8082 bash infra/scripts/run-unified-asr-tests.sh --both
```

### Problem: "k6 dropped iterations"

**Cause:** Not enough VUs allocated to sustain the requested rate.

**Solution:** The test scripts are pre-configured with adequate VU counts. If this error persists, check CPU/memory constraints on the k3d cluster.

### Problem: "No data in Prometheus"

**Cause:** Prometheus remote write receiver may not be enabled or metrics are not being pushed.

**Solution:**
1. Verify Prometheus remote write is enabled:
   ```bash
   kubectl logs -n observability deployment/prometheus
   ```
2. Check k6 output for `--out experimental-prometheus-rw` errors
3. Verify `PROM_URL` environment variable is correct

### Problem: "Tests pass but unified report shows FAIL"

**Cause:** Prometheus query timing mismatch (report queries last 5 min, but test just finished).

**Solution:** Wait 30 seconds after test completion before generating the report, or manually regenerate:
```bash
bash infra/scripts/report-unified-asr.sh /path/to/results/unified-YYYYMMDD-HHMMSS
```

### Problem: "Seed orders failing"

**Cause:** Order Book symbol mismatch or incorrect target URL.

**Solution:**
1. Verify symbols in `src/k6/lib/config.js` match ME deployment:
   ```bash
   kubectl get pods -n matching-engine -o yaml | grep SHARD_SYMBOLS
   ```
2. Check target URL is correct (Gateway for ASR 2, direct ME for ASR 1)

## Performance Optimization Tips

### Reduce Test Duration (for Development)

```bash
NORMAL_RUNS=3 AGGRESSIVE_RUNS=3 \
  bash infra/scripts/run-unified-asr-tests.sh --both
```

This reduces ASR 1 duration from ~47 min to ~7 min.

### Run Tests in Parallel (Advanced)

For CI/CD pipelines, run ASR 1 and ASR 2 in separate jobs:

**Job 1 (ASR 1):**
```bash
bash infra/scripts/run-unified-asr-tests.sh --asr1-only
```

**Job 2 (ASR 2):**
```bash
bash infra/scripts/run-unified-asr-tests.sh --asr2-only
```

Then merge results manually or use a custom aggregation script.

### Increase Seed Depth (for Higher Throughput)

Edit `src/k6/lib/seedHelper.js`:
```javascript
export function seedShard(shardId, symbols, ordersPerSymbol = 500, priceLevels = 50, targetUrl) {
  // Increase ordersPerSymbol and priceLevels for deeper Order Books
  // Example: ordersPerSymbol = 2000, priceLevels = 100
}
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: ASR Validation
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  unified-asr-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install k6
        run: |
          sudo gpg -k
          sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
            --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
          echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
            sudo tee /etc/apt/sources.list.d/k6.list
          sudo apt-get update
          sudo apt-get install k6

      - name: Set up k3d cluster
        run: |
          bash infra/scripts/01-create-cluster.sh
          bash infra/scripts/02-deploy-observability.sh
          bash infra/scripts/03-deploy-redpanda.sh
          bash infra/scripts/04-build-images.sh

      - name: Run unified ASR tests (short version)
        run: |
          NORMAL_RUNS=5 AGGRESSIVE_RUNS=5 \
            bash infra/scripts/run-unified-asr-tests.sh --both

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: asr-results
          path: infra/scripts/results/unified-*/

      - name: Check test status
        run: |
          REPORT=$(ls -td infra/scripts/results/unified-* | head -1)/unified-report.txt
          grep "OVERALL RESULT:.*PASS" "$REPORT"
```

## Migration from Legacy Scripts

If you were previously using separate ASR test scripts:

### Old Approach (Deprecated)
```bash
# ASR 1
bash infra/scripts/08-run-asr1-tests.sh

# ASR 2
bash infra/scripts/09-run-asr2-tests.sh

# Manual result collection
bash infra/scripts/collect-results.sh asr1
bash infra/scripts/collect-results.sh asr2
```

### New Approach (Unified)
```bash
# Single command for both ASRs
bash infra/scripts/run-unified-asr-tests.sh --both

# Report is auto-generated
cat infra/scripts/results/unified-*/unified-report.txt
```

**Benefits:**
- Single execution flow
- Automated deployment switching
- Consolidated pass/fail report
- Consistent test environment
- Reduced manual intervention

## Future Enhancements

Planned improvements to the unified testing framework:

1. **Automated baseline capture:** Save Test B1 baseline and use it for scaling ratio calculation
2. **Historical trend analysis:** Compare current run against previous runs
3. **Slack/Email notifications:** Send pass/fail notifications
4. **Cost estimation:** Report cloud resource usage for production sizing
5. **Regression detection:** Flag if performance degrades compared to previous runs

## References

- **Spec 3:** Matching Engine Architecture Experiment (ASR 1 & ASR 2)
- **k6 Documentation:** https://k6.io/docs/
- **Prometheus PromQL:** https://prometheus.io/docs/prometheus/latest/querying/basics/
- **Grafana Dashboards:** http://localhost:3000

---

**Last Updated:** 2026-02-15
**Version:** 1.0
**Maintainer:** Matching Engine Team
