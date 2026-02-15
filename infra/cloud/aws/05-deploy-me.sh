#!/bin/bash
# =============================================================================
# 05-deploy-me.sh -- Start Matching Engine containers on all instances.
#
# This script starts the application containers (ME shards, Edge Gateway)
# on the EC2 instances that were provisioned and prepared by previous scripts.
# Redpanda, Prometheus, and Grafana are already running from 04-setup-software.sh.
#
# Usage:
#   ./05-deploy-me.sh single    # ASR 1: only Shard A (direct access, no gateway)
#   ./05-deploy-me.sh multi     # ASR 2: all 3 shards + Edge Gateway
#   ./05-deploy-me.sh stop      # Stop all ME/Edge containers
#
# The "single" mode starts only Shard A for latency testing (ASR 1).
# The "multi" mode starts all 3 shards and the Edge Gateway for scalability
# testing (ASR 2). The NLB forwards traffic to the Edge Gateway.
#
# Idempotent: stops existing containers before starting new ones.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 5: Deploy Matching Engine"

MODE="${1:-single}"
info "Deployment mode: ${MODE}"

# Validate prerequisites
for var in INST_REDPANDA INST_ME_A INST_EDGE K6_PUBLIC_IP; do
    val="${!var:-}"
    if [ -z "$val" ] || [ "$val" = "None" ]; then
        error "${var} is not set. Run previous scripts first."
        exit 1
    fi
done

if [ "$MODE" = "multi" ]; then
    for var in INST_ME_B INST_ME_C; do
        val="${!var:-}"
        if [ -z "$val" ] || [ "$val" = "None" ]; then
            error "${var} is not set. Launch all instances with: 03-launch-instances.sh --all"
            exit 1
        fi
    done
fi

# ---------------------------------------------------------------------------
# Helper: SSH to a private instance via k6 bastion
# ---------------------------------------------------------------------------
bastion_ssh() {
    local private_ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 -o ServerAliveInterval=15 \
        -i "$KEY_FILE" \
        -o "ProxyJump=ec2-user@${K6_PUBLIC_IP}" \
        "ec2-user@${private_ip}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: Stop a container on a private instance
# ---------------------------------------------------------------------------
stop_container() {
    local ip="$1"
    local container_name="$2"
    local instance_name="$3"

    local running
    running=$(bastion_ssh "$ip" "sudo docker ps --filter name=${container_name} --format '{{.Names}}'" 2>/dev/null || echo "")
    if [ "$running" = "$container_name" ]; then
        info "Stopping ${container_name} on ${instance_name} (${ip})..."
        bastion_ssh "$ip" "sudo docker stop ${container_name} && sudo docker rm ${container_name}" 2>/dev/null || true
        success "Stopped ${container_name} on ${instance_name}."
    else
        info "Container ${container_name} is not running on ${instance_name}."
    fi
}

# ---------------------------------------------------------------------------
# Helper: Start an ME shard container
# ---------------------------------------------------------------------------
start_me_shard() {
    local ip="$1"
    local shard_id="$2"
    local shard_symbols="$3"
    local instance_name="$4"

    # Stop existing container
    stop_container "$ip" "matching-engine" "$instance_name"

    info "Starting ME Shard ${shard_id} on ${instance_name} (${ip})..."
    bastion_ssh "$ip" "sudo docker run -d --name matching-engine --restart unless-stopped --network host \
        -e SHARD_ID=${shard_id} \
        -e SHARD_SYMBOLS=${shard_symbols} \
        -e HTTP_PORT=${APP_PORT} \
        -e METRICS_PORT=${METRICS_PORT} \
        -e KAFKA_BOOTSTRAP=${IP_REDPANDA}:${KAFKA_PORT} \
        -e WAL_PATH=/app/wal \
        -e WAL_SIZE_MB=64 \
        -e ENABLE_DETAILED_LOGGING=false \
        -e JAVA_OPTS='${ME_JAVA_OPTS}' \
        -v /data/wal:/app/wal \
        ${ME_IMAGE}"

    # Wait for the shard to become healthy
    info "Waiting for Shard ${shard_id} to become healthy..."
    local attempt=1
    while [ $attempt -le 30 ]; do
        local health_code
        health_code=$(bastion_ssh "$ip" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}/health" 2>/dev/null || echo "000")
        if [ "$health_code" = "200" ]; then
            success "Shard ${shard_id} is healthy on ${instance_name}."
            return 0
        fi
        if [ $attempt -eq 30 ]; then
            warn "Shard ${shard_id} health check timed out. Checking container logs..."
            bastion_ssh "$ip" "sudo docker logs --tail 20 matching-engine" 2>/dev/null || true
            return 1
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
}

# ---------------------------------------------------------------------------
# Helper: Start the Edge Gateway container
# ---------------------------------------------------------------------------
start_edge_gateway() {
    local shard_map="$1"
    local symbols_map="$2"

    stop_container "$IP_EDGE_GW" "edge-gateway" "Edge-Gateway"

    info "Starting Edge Gateway on ${IP_EDGE_GW}..."
    bastion_ssh "$IP_EDGE_GW" "sudo docker run -d --name edge-gateway --restart unless-stopped --network host \
        -e HTTP_PORT=${APP_PORT} \
        -e METRICS_PORT=${METRICS_PORT} \
        -e ME_SHARD_MAP='${shard_map}' \
        -e SHARD_SYMBOLS_MAP='${symbols_map}' \
        -e JAVA_OPTS='${EDGE_JAVA_OPTS}' \
        ${EDGE_IMAGE}"

    # Wait for the gateway to become healthy
    info "Waiting for Edge Gateway to become healthy..."
    local attempt=1
    while [ $attempt -le 30 ]; do
        local health_code
        health_code=$(bastion_ssh "$IP_EDGE_GW" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}/health" 2>/dev/null || echo "000")
        if [ "$health_code" = "200" ]; then
            success "Edge Gateway is healthy."
            return 0
        fi
        if [ $attempt -eq 30 ]; then
            warn "Edge Gateway health check timed out. Checking container logs..."
            bastion_ssh "$IP_EDGE_GW" "sudo docker logs --tail 20 edge-gateway" 2>/dev/null || true
            return 1
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
}

# ---------------------------------------------------------------------------
# Mode: stop -- Stop all containers
# ---------------------------------------------------------------------------
if [ "$MODE" = "stop" ]; then
    header "Stopping All ME Containers"
    stop_container "$IP_ME_SHARD_A" "matching-engine" "ME-Shard-A"
    if [ -n "${INST_ME_B:-}" ] && [ "${INST_ME_B}" != "None" ]; then
        stop_container "$IP_ME_SHARD_B" "matching-engine" "ME-Shard-B"
    fi
    if [ -n "${INST_ME_C:-}" ] && [ "${INST_ME_C}" != "None" ]; then
        stop_container "$IP_ME_SHARD_C" "matching-engine" "ME-Shard-C"
    fi
    stop_container "$IP_EDGE_GW" "edge-gateway" "Edge-Gateway"
    success "All ME containers stopped."
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: single -- ASR 1 (Shard A only)
# ---------------------------------------------------------------------------
if [ "$MODE" = "single" ]; then
    header "ASR 1 Deployment: Single Shard"

    # Stop any multi-shard containers that might be running
    if [ -n "${INST_ME_B:-}" ] && [ "${INST_ME_B}" != "None" ]; then
        stop_container "$IP_ME_SHARD_B" "matching-engine" "ME-Shard-B"
    fi
    if [ -n "${INST_ME_C:-}" ] && [ "${INST_ME_C}" != "None" ]; then
        stop_container "$IP_ME_SHARD_C" "matching-engine" "ME-Shard-C"
    fi
    stop_container "$IP_EDGE_GW" "edge-gateway" "Edge-Gateway"

    # Start Shard A
    start_me_shard "$IP_ME_SHARD_A" "a" "$SHARD_A_SYMBOLS" "ME-Shard-A"

    # Update NLB target to point directly to Shard A instead of Edge Gateway
    info "Updating NLB target group to point to Shard A for ASR 1..."
    # Deregister Edge Gateway
    aws elbv2 deregister-targets \
        --region "$AWS_REGION" \
        --target-group-arn "$TG_ARN" \
        --targets "Id=${INST_EDGE},Port=${APP_PORT}" 2>/dev/null || true
    # Register Shard A
    aws elbv2 register-targets \
        --region "$AWS_REGION" \
        --target-group-arn "$TG_ARN" \
        --targets "Id=${INST_ME_A},Port=${APP_PORT}" 2>/dev/null || true
    success "NLB target group updated: Shard A direct."

    header "ASR 1 Deployment Complete"
    echo ""
    info "Shard A:     ${IP_ME_SHARD_A}:${APP_PORT}"
    info "NLB:         http://${NLB_DNS}:${APP_PORT} -> Shard A"
    info "Metrics:     ${IP_ME_SHARD_A}:${METRICS_PORT}"
    info "Prometheus:  ${IP_MONITORING}:${PROMETHEUS_PORT}"
    info "Grafana:     ${IP_MONITORING}:${GRAFANA_PORT}"
    echo ""
    info "Test endpoint from k6: http://${IP_ME_SHARD_A}:${APP_PORT}"
    info "Next step: Run 06-run-tests.sh asr1"

# ---------------------------------------------------------------------------
# Mode: multi -- ASR 2 (3 Shards + Edge Gateway)
# ---------------------------------------------------------------------------
elif [ "$MODE" = "multi" ]; then
    header "ASR 2 Deployment: Multi-Shard + Edge Gateway"

    # Start all 3 shards
    start_me_shard "$IP_ME_SHARD_A" "a" "$SHARD_A_SYMBOLS" "ME-Shard-A"
    start_me_shard "$IP_ME_SHARD_B" "b" "$SHARD_B_SYMBOLS" "ME-Shard-B"
    start_me_shard "$IP_ME_SHARD_C" "c" "$SHARD_C_SYMBOLS" "ME-Shard-C"

    # Start Edge Gateway with shard map pointing to private IPs
    SHARD_MAP="a=http://${IP_ME_SHARD_A}:${APP_PORT},b=http://${IP_ME_SHARD_B}:${APP_PORT},c=http://${IP_ME_SHARD_C}:${APP_PORT}"
    SYMBOLS_MAP="a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L"
    start_edge_gateway "$SHARD_MAP" "$SYMBOLS_MAP"

    # Update NLB target to point to Edge Gateway
    info "Updating NLB target group to point to Edge Gateway for ASR 2..."
    # Deregister Shard A (in case it was registered for ASR 1)
    aws elbv2 deregister-targets \
        --region "$AWS_REGION" \
        --target-group-arn "$TG_ARN" \
        --targets "Id=${INST_ME_A},Port=${APP_PORT}" 2>/dev/null || true
    # Register Edge Gateway
    aws elbv2 register-targets \
        --region "$AWS_REGION" \
        --target-group-arn "$TG_ARN" \
        --targets "Id=${INST_EDGE},Port=${APP_PORT}" 2>/dev/null || true
    success "NLB target group updated: Edge Gateway."

    header "ASR 2 Deployment Complete"
    echo ""
    info "Shard A:      ${IP_ME_SHARD_A}:${APP_PORT}"
    info "Shard B:      ${IP_ME_SHARD_B}:${APP_PORT}"
    info "Shard C:      ${IP_ME_SHARD_C}:${APP_PORT}"
    info "Edge Gateway: ${IP_EDGE_GW}:${APP_PORT}"
    info "NLB:          http://${NLB_DNS}:${APP_PORT} -> Edge Gateway"
    info "Prometheus:   ${IP_MONITORING}:${PROMETHEUS_PORT}"
    info "Grafana:      ${IP_MONITORING}:${GRAFANA_PORT}"
    echo ""
    info "Test endpoint from k6: http://${IP_EDGE_GW}:${APP_PORT}"
    info "Next step: Run 06-run-tests.sh asr2"

else
    error "Unknown mode: ${MODE}"
    echo ""
    echo "Usage: $0 [single|multi|stop]"
    echo "  single  -- ASR 1: Shard A only (latency test)"
    echo "  multi   -- ASR 2: 3 shards + Edge Gateway (scalability test)"
    echo "  stop    -- Stop all ME containers"
    exit 1
fi
