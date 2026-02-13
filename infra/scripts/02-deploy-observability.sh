#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo "Deploying Prometheus..."
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/../k8s/monitoring/prometheus-values.yaml" \
  --wait --timeout 120s

echo "Deploying Grafana..."
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/../k8s/monitoring/grafana-values.yaml" \
  --wait --timeout 120s

echo "Observability stack deployed."
echo "  Prometheus: http://localhost:9090 (via port-forward or NodePort 30090)"
echo "  Grafana: http://localhost:3000 (admin/admin)"
