#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deploying Redpanda..."
kubectl apply -f "${SCRIPT_DIR}/../k8s/redpanda/statefulset.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/redpanda/service.yaml"

echo "Waiting for Redpanda to be ready..."
kubectl wait --for=condition=Ready pod/redpanda-0 \
  -n matching-engine --timeout=120s

echo "Creating Kafka topics..."
kubectl exec -n matching-engine redpanda-0 -- \
  rpk topic create orders matches \
  --partitions 12 --replicas 1

echo "Redpanda deployed and topics created."
