#!/bin/bash
set -euo pipefail

CLUSTER_NAME="matching-engine-exp"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Building Matching Engine image..."
cd "${PROJECT_ROOT}/src/matching-engine"
./gradlew clean build -x test
docker build -t matching-engine:experiment-v1 .

echo "Building Edge Gateway image..."
cd "${PROJECT_ROOT}/src/edge-gateway"
./gradlew clean build -x test
docker build -t edge-gateway:experiment-v1 .

echo "Importing images into k3d cluster..."
k3d image import matching-engine:experiment-v1 -c ${CLUSTER_NAME}
k3d image import edge-gateway:experiment-v1 -c ${CLUSTER_NAME}

echo "Images built and imported successfully."
