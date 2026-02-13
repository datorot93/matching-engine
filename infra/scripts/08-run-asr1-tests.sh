#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K6_DIR="${SCRIPT_DIR}/../../src/k6"
PROM_URL="http://localhost:9090/api/v1/write"
ME_URL="http://localhost:8080"

echo "========================================="
echo "  ASR 1: LATENCY VALIDATION"
echo "========================================="

echo ""
echo "--- Test A1: Warm-up (2 min) ---"
k6 run -e ME_SHARD_A_URL="${ME_URL}" "${K6_DIR}/test-asr1-a1-warmup.js"

echo ""
echo "--- Test A2: Normal Load Latency (5 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e ME_SHARD_A_URL="${ME_URL}" \
  "${K6_DIR}/test-asr1-a2-normal-load.js"

echo ""
echo "--- Test A4: Kafka Degradation (3 min) ---"
echo "Starting Redpanda pause helper in background..."
bash "${SCRIPT_DIR}/helpers/pause-redpanda.sh" 60 120 &
PAUSE_PID=$!

k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e ME_SHARD_A_URL="${ME_URL}" \
  "${K6_DIR}/test-asr1-a4-kafka-degradation.js"

wait $PAUSE_PID 2>/dev/null || true

echo ""
echo "========================================="
echo "  ASR 1 TEST SUITE COMPLETE"
echo "  Check Grafana at http://localhost:3000"
echo "========================================="
