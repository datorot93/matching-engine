# Unified ASR Testing - Quick Start

## TL;DR - Run Everything

```bash
cd /home/datorot/matching-engine
bash infra/scripts/run-unified-asr-tests.sh --both
```

**Duration:** ~67 minutes
**Output:** `infra/scripts/results/unified-YYYYMMDD-HHMMSS/unified-report.txt`

---

## Fast Development Test (7 minutes)

For quick validation during development:

```bash
cd /home/datorot/matching-engine
NORMAL_RUNS=3 AGGRESSIVE_RUNS=3 bash infra/scripts/run-unified-asr-tests.sh --both
```

---

## Run Individual Test Suites

### ASR 1 Only (Latency)

```bash
bash infra/scripts/run-unified-asr-tests.sh --asr1-only
```

**Duration:** ~47 minutes (20 normal + 20 aggressive runs)

### ASR 2 Only (Scalability)

```bash
bash infra/scripts/run-unified-asr-tests.sh --asr2-only
```

**Duration:** ~20 minutes (3 scalability tests)

---

## View Results

### Text Report (Human-Readable)

```bash
# Find the latest results directory
LATEST=$(ls -td infra/scripts/results/unified-* 2>/dev/null | head -1)

# View the unified report
cat "${LATEST}/unified-report.txt"
```

### CSV Report (Machine-Readable)

```bash
LATEST=$(ls -td infra/scripts/results/unified-* 2>/dev/null | head -1)
cat "${LATEST}/unified-report.csv"
```

### Detailed Test Logs

```bash
LATEST=$(ls -td infra/scripts/results/unified-* 2>/dev/null | head -1)

# ASR 1 detailed results
cat "${LATEST}/asr1/report.txt"

# ASR 2 Prometheus metrics
cat "${LATEST}/asr2/prometheus-metrics.txt"

# Full execution log
cat "${LATEST}/test-execution.log"
```

---

## Check Pass/Fail Status

```bash
LATEST=$(ls -td infra/scripts/results/unified-* 2>/dev/null | head -1)

# Quick check: look for overall result
grep "OVERALL RESULT" "${LATEST}/unified-report.txt"
```

**Expected output (PASS):**
```
OVERALL RESULT:       ✓ PASS - All architectural requirements validated
```

**Expected output (FAIL):**
```
OVERALL RESULT:       ✗ FAIL - One or more requirements not met
```

---

## Grafana Dashboards

Real-time monitoring during test execution:

```
http://localhost:3000
```

**Dashboard:** "Matching Engine Experiment"

**Key Metrics:**
- Matching Latency Distribution (p50, p95, p99)
- Throughput (matches/min per shard)
- Order Book Depth
- JVM Heap Usage
- GC Pause Times

---

## Regenerate Report (Without Re-running Tests)

If you want to regenerate the unified report from existing results:

```bash
bash infra/scripts/report-unified-asr.sh /path/to/results/unified-YYYYMMDD-HHMMSS
```

This is useful if:
- Prometheus data has settled after test completion
- You want to re-query metrics with different time ranges
- The original report generation failed

---

## Skip Deployment (Re-run Tests on Existing Cluster)

If the ME is already deployed and you just want to re-run tests:

```bash
SKIP_DEPLOYMENT=true bash infra/scripts/run-unified-asr-tests.sh --both
```

**Warning:** Ensure the correct deployment is running:
- ASR 1 requires single shard (Shard A only)
- ASR 2 requires multi-shard (3 shards + Gateway)

---

## Troubleshooting

### Port 8081 already in use

```bash
ME_PORT=8082 bash infra/scripts/run-unified-asr-tests.sh --both
```

### k6 not installed

```bash
# macOS
brew install k6

# Ubuntu/Debian
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
  sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6
```

### kubectl not installed

```bash
# macOS
brew install kubectl

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y kubectl
```

### jq not installed

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install -y jq
```

---

## Full Prerequisites Setup

If starting from scratch:

```bash
cd /home/datorot/matching-engine

# 1. Create k3d cluster
bash infra/scripts/01-create-cluster.sh

# 2. Deploy observability stack (Prometheus, Grafana)
bash infra/scripts/02-deploy-observability.sh

# 3. Deploy Redpanda (Kafka-compatible message broker)
bash infra/scripts/03-deploy-redpanda.sh

# 4. Build ME and Gateway Docker images
bash infra/scripts/04-build-images.sh

# 5. Run unified tests
bash infra/scripts/run-unified-asr-tests.sh --both
```

**Total setup time:** ~10 minutes
**Total test time:** ~67 minutes

---

## Understanding the Output

### Unified Report Structure

```
results/unified-YYYYMMDD-HHMMSS/
  ├── unified-report.txt              # ← START HERE
  ├── unified-report.csv
  ├── test-execution.log              # Full stdout/stderr
  ├── asr1/
  │   ├── report.txt                  # Detailed per-run metrics
  │   ├── report.csv
  │   ├── prometheus-metrics.txt      # ME-internal metrics
  │   └── run-*.json                  # k6 JSON summaries
  └── asr2/
      ├── b2-peak-sustained.json
      ├── b3-ramp.json
      ├── b4-hot-symbol.json
      └── prometheus-metrics.txt
```

### Key Metrics to Review

**ASR 1 (Latency):**
- `Max p99` < 200ms (primary criterion)
- `Min success rate` > 99%
- `Max error rate` < 1%

**ASR 2 (Scalability):**
- `Aggregate throughput` >= 4,750 matches/min
- `Shard A/B/C p99` all < 200ms

**Overall:**
- `OVERALL RESULT: PASS` = both ASRs met
- `OVERALL RESULT: FAIL` = one or both ASRs failed
- `OVERALL RESULT: INCOMPLETE` = tests were not run

---

## Next Steps After PASS

1. Review Grafana dashboards for performance characteristics
2. Archive results for stakeholder review
3. Document any edge cases or anomalies observed
4. Plan production deployment configuration based on observed resource usage

## Next Steps After FAIL

1. Identify which ASR failed (ASR 1, ASR 2, or both)
2. Review detailed logs in `test-execution.log`
3. Check Grafana dashboards for latency spikes or resource exhaustion
4. Review Prometheus metrics for bottlenecks:
   - High GC pause times → increase heap size
   - High event publish latency → Kafka producer tuning
   - High WAL append latency → disk I/O optimization
5. Re-run tests after adjustments

---

## Sample Pass Report

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                     UNIFIED ASR VALIDATION REPORT                           ║
╚══════════════════════════════════════════════════════════════════════════════╝

ASR 1: LATENCY REQUIREMENT
  Status:                PASS
  Max p99:               187.45 ms   ← Primary criterion
  Min success rate:      99.87 %
  Max error rate:        0.13 %

ASR 2: SCALABILITY REQUIREMENT
  Status:                PASS
  Aggregate throughput:  5,032.45 matches/min   ← Primary criterion
  Shard A p99:           142.33 ms
  Shard B p99:           138.67 ms
  Shard C p99:           145.12 ms

OVERALL VALIDATION SUMMARY
  ASR 1 (Latency):      PASS
  ASR 2 (Scalability):  PASS

  OVERALL RESULT:       ✓ PASS - All architectural requirements validated
```

---

For detailed documentation, see: `/home/datorot/matching-engine/docs/UNIFIED_ASR_TESTING.md`
