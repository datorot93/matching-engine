#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deploying 3 ME Shards + Edge Gateway (ASR 2 configuration)..."

# Deploy all 3 shards
for shard in a b c; do
  echo "Deploying ME Shard ${shard}..."
  kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-${shard}-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-${shard}-service.yaml"
done

# Deploy Edge Gateway
echo "Deploying Edge Gateway..."
kubectl apply -f "${SCRIPT_DIR}/../k8s/edge-gateway/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/edge-gateway/service.yaml"

# Wait for all pods
for shard in a b c; do
  echo "Waiting for ME Shard ${shard}..."
  bash "${SCRIPT_DIR}/helpers/wait-for-pod.sh" matching-engine "app=matching-engine,shard=${shard}"
done

echo "Waiting for Edge Gateway..."
bash "${SCRIPT_DIR}/helpers/wait-for-pod.sh" matching-engine "app=edge-gateway"

echo "All shards and Edge Gateway deployed and ready."
