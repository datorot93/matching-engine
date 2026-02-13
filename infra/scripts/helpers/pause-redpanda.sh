#!/bin/bash
# Used for Test Case A4: Kafka degradation test
# Pauses Redpanda at t=60s, resumes at the end of the test

DELAY_BEFORE_PAUSE="${1:-60}"
PAUSE_DURATION="${2:-120}"

echo "Will pause Redpanda in ${DELAY_BEFORE_PAUSE} seconds..."
sleep "${DELAY_BEFORE_PAUSE}"

echo "Pausing Redpanda (scaling to 0 replicas)..."
kubectl scale statefulset redpanda --replicas=0 -n matching-engine

echo "Redpanda paused. Will resume in ${PAUSE_DURATION} seconds..."
sleep "${PAUSE_DURATION}"

echo "Resuming Redpanda (scaling to 1 replica)..."
kubectl scale statefulset redpanda --replicas=1 -n matching-engine

echo "Waiting for Redpanda to be ready..."
kubectl wait --for=condition=Ready pod/redpanda-0 \
  -n matching-engine --timeout=120s

echo "Redpanda resumed."
