#!/bin/bash
set -euo pipefail

CLUSTER_NAME="matching-engine-exp"

echo "Killing port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true

echo "Deleting k3d cluster: ${CLUSTER_NAME}..."
k3d cluster delete ${CLUSTER_NAME}

echo "Cluster deleted. Clean up complete."
