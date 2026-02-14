#!/bin/bash
set -euo pipefail

echo "========================================="
echo "  SMOKE TEST: End-to-End Wiring Check"
echo "========================================="

ME_PORT="${ME_PORT:-8081}"
ME_URL="${ME_URL:-http://localhost:${ME_PORT}}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
PASS=0
FAIL=0

check() {
    local name="$1"
    local result="$2"
    if [ "$result" == "true" ]; then
        echo "  [PASS] ${name}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "--- 1. ME Health Check ---"
ME_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${ME_URL}/health" 2>/dev/null || echo "000")
check "ME /health returns 200" "$([ "$ME_HEALTH" == "200" ] && echo true || echo false)"

echo ""
echo "--- 2. Order Submission ---"
ORDER_RESP=$(curl -s -X POST "${ME_URL}/orders" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"smoke-buy-1","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":10000,"quantity":10}' 2>/dev/null || echo '{}')
ORDER_STATUS=$(echo "$ORDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
check "Order submission returns ACCEPTED" "$([ "$ORDER_STATUS" == "ACCEPTED" ] && echo true || echo false)"

echo ""
echo "--- 3. Seed Endpoint ---"
SEED_RESP=$(curl -s -X POST "${ME_URL}/seed" \
  -H "Content-Type: application/json" \
  -d '{"orders":[{"orderId":"smoke-seed-1","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15100,"quantity":50}]}' 2>/dev/null || echo '{}')
SEEDED=$(echo "$SEED_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('seeded',0))" 2>/dev/null || echo "0")
check "Seed endpoint accepts orders" "$([ "$SEEDED" -gt 0 ] && echo true || echo false)"

echo ""
echo "--- 4. Matching Works ---"
# Seed a sell at 15000, then submit a buy at 15000
curl -s -X POST "${ME_URL}/seed" \
  -H "Content-Type: application/json" \
  -d '{"orders":[{"orderId":"smoke-seed-match","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15000,"quantity":50}]}' > /dev/null 2>&1

MATCH_RESP=$(curl -s -X POST "${ME_URL}/orders" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"smoke-match-buy","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":15000,"quantity":50}' 2>/dev/null || echo '{}')
MATCH_STATUS=$(echo "$MATCH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
check "Buy order at matching price is accepted" "$([ "$MATCH_STATUS" == "ACCEPTED" ] && echo true || echo false)"

echo ""
echo "--- 5. Prometheus Metrics ---"
sleep 6  # Wait for Prometheus scrape (5s interval)

# Check metrics existence via Prometheus API (metrics port 9091 is not port-forwarded)
check_metric() {
    local metric_name="$1"
    local result=$(curl -s "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=${metric_name}" 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('data',{}).get('result',[]) else 'false')" 2>/dev/null || echo "false")
    echo "$result"
}

check "me_matches_total metric exists in Prometheus" "$(check_metric 'me_matches_total')"
check "me_match_duration_seconds metric exists in Prometheus" "$(check_metric 'me_match_duration_seconds_count')"
check "me_orderbook_depth metric exists in Prometheus" "$(check_metric 'me_orderbook_depth')"
check "jvm_gc_collection metric exists in Prometheus" "$(check_metric 'jvm_gc_collection_seconds_sum')"

echo ""
echo "--- 6. Prometheus Scrape Verification ---"
PROM_TARGETS=$(curl -s "${PROM_URL}/api/v1/targets" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
active = [t for t in data.get('data',{}).get('activeTargets',[]) if 'matching-engine' in t.get('labels',{}).get('job','')]
up = [t for t in active if t.get('health') == 'up']
print(f'{len(up)}/{len(active)}')
" 2>/dev/null || echo "0/0")
check "Prometheus scraping ME targets (${PROM_TARGETS})" "$([ "${PROM_TARGETS}" != "0/0" ] && echo true || echo false)"

echo ""
echo "--- 7. Grafana Accessible ---"
GRAFANA_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_URL}/api/health" 2>/dev/null || echo "000")
check "Grafana is accessible" "$([ "$GRAFANA_HEALTH" == "200" ] && echo true || echo false)"

echo ""
echo "========================================="
echo "  RESULTS: ${PASS} passed, ${FAIL} failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
    echo "  SMOKE TEST FAILED. Fix issues before running experiments."
    exit 1
else
    echo "  SMOKE TEST PASSED. Ready to run experiments."
    exit 0
fi
