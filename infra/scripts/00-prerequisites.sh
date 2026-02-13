#!/bin/bash
set -euo pipefail

echo "Checking prerequisites..."

# Check Docker
docker info > /dev/null 2>&1 || { echo "ERROR: Docker is not running. Start Docker Desktop."; exit 1; }
echo "  Docker: OK"

# Check k3d
command -v k3d > /dev/null 2>&1 || { echo "Installing k3d..."; brew install k3d; }
echo "  k3d: OK ($(k3d version | head -1))"

# Check kubectl
command -v kubectl > /dev/null 2>&1 || { echo "ERROR: kubectl not found."; exit 1; }
echo "  kubectl: OK"

# Check Helm
command -v helm > /dev/null 2>&1 || { echo "Installing helm..."; brew install helm; }
echo "  helm: OK"

# Check k6
command -v k6 > /dev/null 2>&1 || { echo "Installing k6..."; brew install k6; }
echo "  k6: OK"

# Check Java 21
java -version 2>&1 | grep -q "21" || { echo "WARNING: Java 21 not found. Needed for local builds."; }
echo "  Java: $(java -version 2>&1 | head -1)"

echo ""
echo "All prerequisites satisfied."
