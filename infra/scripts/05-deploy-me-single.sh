#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deploying ME Shard A (single shard for ASR 1)..."
kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-a-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-a-service.yaml"

echo "Waiting for ME Shard A to be ready..."
bash "${SCRIPT_DIR}/helpers/wait-for-pod.sh" matching-engine "app=matching-engine,shard=a"

echo "ME Shard A deployed and ready."
echo "  Internal: http://me-shard-a.matching-engine.svc:8080"
echo "  Metrics: http://me-shard-a.matching-engine.svc:9091/metrics"
