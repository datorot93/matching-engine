#!/bin/bash
set -euo pipefail

NAMESPACE="${1}"
LABEL_SELECTOR="${2}"
TIMEOUT="${3:-120s}"

echo "  Waiting for pod with label ${LABEL_SELECTOR} in namespace ${NAMESPACE}..."
kubectl wait --for=condition=Ready pod \
  -l "${LABEL_SELECTOR}" \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT}"
