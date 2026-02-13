#!/bin/bash
set -euo pipefail

CLUSTER_NAME="matching-engine-exp"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Creating k3d cluster: ${CLUSTER_NAME}"

k3d cluster create ${CLUSTER_NAME} \
  --servers 1 \
  --agents 3 \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

kubectl config use-context k3d-${CLUSTER_NAME}

echo "Cluster created. Nodes:"
kubectl get nodes -o wide

echo "Creating namespace: matching-engine"
kubectl apply -f "${SCRIPT_DIR}/../k8s/namespace.yaml"

echo "Creating namespace: monitoring"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
