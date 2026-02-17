#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K6_DIR="${SCRIPT_DIR}/../../src/k6"
PROM_URL="http://localhost:9090/api/v1/write"
GW_URL="http://149.130.191.100"

echo "========================================="
echo "  ASR 2: SCALABILITY VALIDATION"
echo "========================================="

echo ""
echo "--- Test B2: Peak Sustained 3 Shards (5 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e GATEWAY_URL="${GW_URL}" \
  "${K6_DIR}/test-asr2-b2-peak-sustained.js"

echo ""
echo "--- Test B3: Ramp Test (10 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e GATEWAY_URL="${GW_URL}" \
  "${K6_DIR}/test-asr2-b3-ramp.js"

echo ""
echo "--- Test B4: Hot Symbol Test (5 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e GATEWAY_URL="${GW_URL}" \
  "${K6_DIR}/test-asr2-b4-hot-symbol.js"

echo ""
echo "========================================="
echo "  ASR 2 TEST SUITE COMPLETE"
echo "  Check Grafana at http://localhost:3000"
echo "========================================="
