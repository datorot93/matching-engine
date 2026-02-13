#!/bin/bash
set -euo pipefail

MODE="${1:-single}"  # 'single' or 'multi'

echo "Killing any existing port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

ME_PORT="${ME_PORT:-8081}"  # Use 8081 by default to avoid conflict with other services on 8080

if [ "$MODE" == "single" ]; then
  echo "Setting up port-forwards for ASR 1 (single shard)..."
  kubectl port-forward svc/me-shard-a ${ME_PORT}:8080 -n matching-engine &
  echo "  ME Shard A: http://localhost:${ME_PORT}"
else
  echo "Setting up port-forwards for ASR 2 (multi shard)..."
  kubectl port-forward svc/edge-gateway ${ME_PORT}:8080 -n matching-engine &
  echo "  Edge Gateway: http://localhost:${ME_PORT}"
fi

# Prometheus remote write endpoint
kubectl port-forward svc/prometheus-server 9090:80 -n monitoring &
echo "  Prometheus: http://localhost:9090"

# Grafana
kubectl port-forward svc/grafana 3000:80 -n monitoring &
echo "  Grafana: http://localhost:3000"

echo ""
echo "Port forwards established. Run tests with k6."
echo "To stop: pkill -f 'kubectl port-forward'"
