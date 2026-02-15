#!/bin/bash
# =============================================================================
# 04-deploy-me.sh -- Build, transfer, and deploy all application containers
#
# Deploys (in order):
#   1. Redpanda on me-shard-c (Kafka broker)
#   2. Matching Engine containers on me-shard-a, me-shard-b, me-shard-c
#   3. Edge Gateway container on edge-and-tools
#   4. Prometheus on edge-and-tools (scraping all ME shards + gateway)
#   5. Grafana on edge-and-tools
#
# All containers use --network host for simplicity (bare-metal-like networking).
# Docker images are built locally (linux/arm64) and transferred via SCP.
#
# Usage: ./04-deploy-me.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Project root (two levels up from infra/cloud/oci)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

banner "Phase 4: Deploy Application Containers"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ -z "${BASTION_PUBLIC_IP}" ]]; then
    error "BASTION_PUBLIC_IP not set. Run 02-launch-instances.sh first."
    exit 1
fi

for var_name in ME_SHARD_A_PRIVATE_IP ME_SHARD_B_PRIVATE_IP ME_SHARD_C_PRIVATE_IP EDGE_PRIVATE_IP; do
    if [[ -z "${!var_name}" ]]; then
        error "${var_name} not set. Run 02-launch-instances.sh first."
        exit 1
    fi
done

if ! command -v docker &>/dev/null; then
    error "Docker not found locally. Required to build images."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: remote execute
# ---------------------------------------------------------------------------
remote_exec() {
    local target_ip="$1"
    shift
    ssh_via_bastion "${target_ip}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: wait for a service health check
# ---------------------------------------------------------------------------
wait_for_health() {
    local target_ip="$1"
    local port="$2"
    local path="${3:-/health}"
    local name="${4:-service}"
    local max_wait="${5:-120}"

    info "Waiting for ${name} health check at ${target_ip}:${port}${path} (max ${max_wait}s)..."
    local elapsed=0
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        if remote_exec "${target_ip}" "curl -sf http://localhost:${port}${path}" &>/dev/null; then
            success "${name} is healthy"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    error "${name} failed health check after ${max_wait}s"
    return 1
}

# ===== Step 1: Build Docker images (linux/arm64) =====
step "Building Docker images for linux/arm64"

ME_IMAGE_TAR="/tmp/matching-engine-arm64.tar"
GW_IMAGE_TAR="/tmp/edge-gateway-arm64.tar"

# Build Matching Engine JAR if needed
if [[ ! -f "${PROJECT_ROOT}/src/matching-engine/build/libs/matching-engine.jar" ]]; then
    info "Building Matching Engine JAR..."
    (cd "${PROJECT_ROOT}/src/matching-engine" && ./gradlew clean bootJar -x test)
fi

# Build Edge Gateway JAR if needed
if [[ ! -f "${PROJECT_ROOT}/src/edge-gateway/build/libs/edge-gateway.jar" ]]; then
    info "Building Edge Gateway JAR..."
    (cd "${PROJECT_ROOT}/src/edge-gateway" && ./gradlew clean bootJar -x test)
fi

# Build Docker images for ARM64
info "Building matching-engine:arm64 image..."
docker buildx build \
    --platform linux/arm64 \
    -t matching-engine:arm64 \
    --load \
    "${PROJECT_ROOT}/src/matching-engine"
success "matching-engine:arm64 built"

info "Building edge-gateway:arm64 image..."
docker buildx build \
    --platform linux/arm64 \
    -t edge-gateway:arm64 \
    --load \
    "${PROJECT_ROOT}/src/edge-gateway"
success "edge-gateway:arm64 built"

# Export images to tar files
info "Exporting Docker images to tar files..."
docker save matching-engine:arm64 -o "${ME_IMAGE_TAR}"
docker save edge-gateway:arm64 -o "${GW_IMAGE_TAR}"
success "Images exported: $(du -sh ${ME_IMAGE_TAR} | cut -f1) (ME), $(du -sh ${GW_IMAGE_TAR} | cut -f1) (GW)"

# ===== Step 2: Transfer images to instances =====
step "Transferring Docker images to instances"

# ME image goes to shard-a, shard-b, shard-c
for shard_ip in "${ME_SHARD_A_PRIVATE_IP}" "${ME_SHARD_B_PRIVATE_IP}" "${ME_SHARD_C_PRIVATE_IP}"; do
    info "SCP matching-engine image to ${shard_ip}..."
    scp_via_bastion "${ME_IMAGE_TAR}" "${shard_ip}" "~/matching-engine-arm64.tar"
    remote_exec "${shard_ip}" "docker load -i ~/matching-engine-arm64.tar && rm ~/matching-engine-arm64.tar"
    success "ME image loaded on ${shard_ip}"
done

# GW image goes to edge-and-tools
info "SCP edge-gateway image to ${EDGE_PRIVATE_IP}..."
scp_via_bastion "${GW_IMAGE_TAR}" "${EDGE_PRIVATE_IP}" "~/edge-gateway-arm64.tar"
remote_exec "${EDGE_PRIVATE_IP}" "docker load -i ~/edge-gateway-arm64.tar && rm ~/edge-gateway-arm64.tar"
success "GW image loaded on edge-and-tools"

# Cleanup local tar files
rm -f "${ME_IMAGE_TAR}" "${GW_IMAGE_TAR}"

# ===== Step 3: Deploy Redpanda on me-shard-c =====
step "Deploying Redpanda on me-shard-c (${ME_SHARD_C_PRIVATE_IP})"

REDPANDA_CMD="
# Stop existing Redpanda container if running
docker rm -f redpanda 2>/dev/null || true

# Run Redpanda container
docker run -d \
    --name redpanda \
    --network host \
    --restart unless-stopped \
    -v /var/lib/redpanda/data:/var/lib/redpanda/data \
    docker.redpanda.com/redpandadata/redpanda:latest \
    redpanda start \
    --smp 1 \
    --memory 1G \
    --overprovisioned \
    --node-id 0 \
    --kafka-addr PLAINTEXT://0.0.0.0:${REDPANDA_KAFKA_PORT} \
    --advertise-kafka-addr PLAINTEXT://${ME_SHARD_C_PRIVATE_IP}:${REDPANDA_KAFKA_PORT} \
    --check=false

echo 'Waiting for Redpanda to start...'
sleep 10

# Create topics
rpk topic create orders --partitions 12 --replicas 1 -X brokers=${ME_SHARD_C_PRIVATE_IP}:${REDPANDA_KAFKA_PORT} 2>/dev/null || echo 'Topic orders may already exist'
rpk topic create matches --partitions 12 --replicas 1 -X brokers=${ME_SHARD_C_PRIVATE_IP}:${REDPANDA_KAFKA_PORT} 2>/dev/null || echo 'Topic matches may already exist'

echo 'Redpanda deployed and topics created'
"

remote_exec "${ME_SHARD_C_PRIVATE_IP}" "bash -s" <<< "${REDPANDA_CMD}"
success "Redpanda running on me-shard-c:${REDPANDA_KAFKA_PORT}"

# ===== Step 4: Deploy Matching Engine shards =====
step "Deploying Matching Engine containers"

deploy_me_shard() {
    local shard_ip="$1"
    local shard_id="$2"
    local shard_symbols="$3"
    local shard_name="me-shard-${shard_id}"

    info "Deploying ${shard_name} on ${shard_ip}..."

    local me_cmd="
# Stop existing container
docker rm -f ${shard_name} 2>/dev/null || true

# Run ME shard
docker run -d \
    --name ${shard_name} \
    --network host \
    --restart unless-stopped \
    -e SHARD_ID=${shard_id} \
    -e SHARD_SYMBOLS=${shard_symbols} \
    -e HTTP_PORT=${ME_APP_PORT} \
    -e METRICS_PORT=${ME_METRICS_PORT} \
    -e KAFKA_BOOTSTRAP=${ME_SHARD_C_PRIVATE_IP}:${REDPANDA_KAFKA_PORT} \
    -e WAL_PATH=/app/wal \
    -e WAL_SIZE_MB=64 \
    -e JAVA_OPTS='${ME_JVM_OPTS}' \
    matching-engine:arm64

echo '${shard_name} container started'
"
    remote_exec "${shard_ip}" "bash -s" <<< "${me_cmd}"
    success "${shard_name} deployed on ${shard_ip}"
}

# Deploy all three shards
deploy_me_shard "${ME_SHARD_A_PRIVATE_IP}" "a" "${SHARD_A_SYMBOLS}"
deploy_me_shard "${ME_SHARD_B_PRIVATE_IP}" "b" "${SHARD_B_SYMBOLS}"
deploy_me_shard "${ME_SHARD_C_PRIVATE_IP}" "c" "${SHARD_C_SYMBOLS}"

# Wait for health checks
step "Waiting for ME shard health checks"
wait_for_health "${ME_SHARD_A_PRIVATE_IP}" "${ME_APP_PORT}" "/health" "me-shard-a" 120
wait_for_health "${ME_SHARD_B_PRIVATE_IP}" "${ME_APP_PORT}" "/health" "me-shard-b" 120
wait_for_health "${ME_SHARD_C_PRIVATE_IP}" "${ME_APP_PORT}" "/health" "me-shard-c" 120

# ===== Step 5: Deploy Edge Gateway on edge-and-tools =====
step "Deploying Edge Gateway on edge-and-tools (${EDGE_PRIVATE_IP})"

ME_SHARD_MAP="a=http://${ME_SHARD_A_PRIVATE_IP}:${ME_APP_PORT},b=http://${ME_SHARD_B_PRIVATE_IP}:${ME_APP_PORT},c=http://${ME_SHARD_C_PRIVATE_IP}:${ME_APP_PORT}"
SHARD_SYMBOLS_MAP="a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L"

GW_CMD="
# Stop existing container
docker rm -f edge-gateway 2>/dev/null || true

# Run Edge Gateway
docker run -d \
    --name edge-gateway \
    --network host \
    --restart unless-stopped \
    -e HTTP_PORT=${GW_APP_PORT} \
    -e METRICS_PORT=${GW_METRICS_PORT} \
    -e ME_SHARD_MAP='${ME_SHARD_MAP}' \
    -e SHARD_SYMBOLS_MAP='${SHARD_SYMBOLS_MAP}' \
    -e JAVA_OPTS='${GW_JVM_OPTS}' \
    edge-gateway:arm64

echo 'edge-gateway container started'
"

remote_exec "${EDGE_PRIVATE_IP}" "bash -s" <<< "${GW_CMD}"
wait_for_health "${EDGE_PRIVATE_IP}" "${GW_APP_PORT}" "/health" "edge-gateway" 120
success "Edge Gateway deployed on edge-and-tools"

# ===== Step 6: Deploy Prometheus on edge-and-tools =====
step "Deploying Prometheus on edge-and-tools"

# Transfer recording rules
RECORDING_RULES="${PROJECT_ROOT}/infra/prometheus/recording-rules.yaml"
if [[ -f "${RECORDING_RULES}" ]]; then
    scp_via_bastion "${RECORDING_RULES}" "${EDGE_PRIVATE_IP}" "~/recording-rules.yaml"
    success "Recording rules transferred"
else
    warn "Recording rules file not found at ${RECORDING_RULES}. Prometheus will run without recording rules."
fi

# Generate Prometheus config locally (with variable expansion) and transfer
PROM_CONFIG_TMP=$(mktemp /tmp/prometheus-XXXXXX.yml)
cat > "${PROM_CONFIG_TMP}" <<PROMEOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - /etc/prometheus/recording-rules.yaml

scrape_configs:
  - job_name: matching-engine
    static_configs:
      - targets:
        - '${ME_SHARD_A_PRIVATE_IP}:${ME_METRICS_PORT}'
        - '${ME_SHARD_B_PRIVATE_IP}:${ME_METRICS_PORT}'
        - '${ME_SHARD_C_PRIVATE_IP}:${ME_METRICS_PORT}'
    relabel_configs:
      - source_labels: [__address__]
        regex: '${ME_SHARD_A_PRIVATE_IP}:.*'
        target_label: shard
        replacement: a
      - source_labels: [__address__]
        regex: '${ME_SHARD_B_PRIVATE_IP}:.*'
        target_label: shard
        replacement: b
      - source_labels: [__address__]
        regex: '${ME_SHARD_C_PRIVATE_IP}:.*'
        target_label: shard
        replacement: c

  - job_name: edge-gateway
    static_configs:
      - targets: ['localhost:${GW_METRICS_PORT}']
PROMEOF

scp_via_bastion "${PROM_CONFIG_TMP}" "${EDGE_PRIVATE_IP}" "~/prometheus.yml"
rm -f "${PROM_CONFIG_TMP}"
success "Prometheus config transferred"

# Deploy Prometheus container
remote_exec "${EDGE_PRIVATE_IP}" "bash -s" <<REMOTEPROM
set -euo pipefail

# Stop existing Prometheus container
docker rm -f prometheus 2>/dev/null || true

# Create config directory
mkdir -p ~/prometheus

# Move config files into place
mv ~/prometheus.yml ~/prometheus/prometheus.yml
if [[ -f ~/recording-rules.yaml ]]; then
    mv ~/recording-rules.yaml ~/prometheus/recording-rules.yaml
else
    touch ~/prometheus/recording-rules.yaml
fi

# Run Prometheus container
docker run -d \
    --name prometheus \
    --network host \
    --restart unless-stopped \
    -v ~/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
    -v ~/prometheus/recording-rules.yaml:/etc/prometheus/recording-rules.yaml:ro \
    -v /var/lib/prometheus:/prometheus \
    prom/prometheus:v${PROM_VERSION} \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.retention.time=7d \
    --web.listen-address=':${PROMETHEUS_PORT}' \
    --web.enable-remote-write-receiver \
    --web.enable-lifecycle

echo 'Prometheus container started'
REMOTEPROM

# Verify Prometheus is reachable
sleep 5
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://localhost:${PROMETHEUS_PORT}/-/healthy" &>/dev/null; then
    success "Prometheus running on edge-and-tools:${PROMETHEUS_PORT}"
else
    warn "Prometheus may still be starting. Check: ssh to edge-and-tools, docker logs prometheus"
fi

# ===== Step 7: Deploy Grafana on edge-and-tools =====
step "Deploying Grafana on edge-and-tools"

# Transfer Grafana dashboard JSON if available
DASHBOARD_JSON="${PROJECT_ROOT}/infra/grafana/dashboards/matching-engine-experiment.json"
if [[ -f "${DASHBOARD_JSON}" ]]; then
    scp_via_bastion "${DASHBOARD_JSON}" "${EDGE_PRIVATE_IP}" "~/matching-engine-experiment.json"
    success "Grafana dashboard JSON transferred"
fi

# Generate Grafana datasource provisioning locally (with variable expansion) and transfer
GRAFANA_DS_TMP=$(mktemp /tmp/grafana-ds-XXXXXX.yaml)
cat > "${GRAFANA_DS_TMP}" <<DSEOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:${PROMETHEUS_PORT}
    isDefault: true
    editable: true
DSEOF

scp_via_bastion "${GRAFANA_DS_TMP}" "${EDGE_PRIVATE_IP}" "~/grafana-datasource.yaml"
rm -f "${GRAFANA_DS_TMP}"

# Deploy Grafana container
remote_exec "${EDGE_PRIVATE_IP}" "bash -s" <<'REMOTEGRAFANA'
set -euo pipefail

# Stop existing Grafana container
docker rm -f grafana 2>/dev/null || true

# Create Grafana provisioning directories
mkdir -p ~/grafana/provisioning/datasources
mkdir -p ~/grafana/provisioning/dashboards
mkdir -p ~/grafana/dashboards

# Move datasource config into place
mv ~/grafana-datasource.yaml ~/grafana/provisioning/datasources/prometheus.yaml

# Dashboard provisioning config (no variables needed)
cat > ~/grafana/provisioning/dashboards/default.yaml << 'DBEOF'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
DBEOF

# Copy dashboard JSON if available
if [[ -f ~/matching-engine-experiment.json ]]; then
    cp ~/matching-engine-experiment.json ~/grafana/dashboards/
fi

# Run Grafana container
docker run -d \
    --name grafana \
    --network host \
    --restart unless-stopped \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    -e GF_USERS_ALLOW_SIGN_UP=false \
    -v ~/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v ~/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    grafana/grafana-oss:10.4.1

echo 'Grafana container started'
REMOTEGRAFANA

# Verify Grafana
sleep 10
if remote_exec "${EDGE_PRIVATE_IP}" "curl -sf http://localhost:${GRAFANA_PORT}/api/health" &>/dev/null; then
    success "Grafana running on edge-and-tools:${GRAFANA_PORT}"
else
    warn "Grafana may still be starting. Check: ssh to edge-and-tools, docker logs grafana"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "All applications deployed"
echo ""
echo "  Service            | Instance         | Port(s)"
echo "  -------------------|------------------|-------------------"
echo "  Redpanda (Kafka)   | me-shard-c       | ${REDPANDA_KAFKA_PORT}"
echo "  ME Shard A         | me-shard-a       | ${ME_APP_PORT} (HTTP), ${ME_METRICS_PORT} (metrics)"
echo "  ME Shard B         | me-shard-b       | ${ME_APP_PORT} (HTTP), ${ME_METRICS_PORT} (metrics)"
echo "  ME Shard C         | me-shard-c       | ${ME_APP_PORT} (HTTP), ${ME_METRICS_PORT} (metrics)"
echo "  Edge Gateway       | edge-and-tools   | ${GW_APP_PORT} (HTTP), ${GW_METRICS_PORT} (metrics)"
echo "  Prometheus         | edge-and-tools   | ${PROMETHEUS_PORT}"
echo "  Grafana            | edge-and-tools   | ${GRAFANA_PORT} (admin/admin)"
echo ""
echo "  Access Grafana via SSH tunnel:"
echo "    ssh -i ${SSH_KEY_PATH} -L 3000:${EDGE_PRIVATE_IP}:3000 -L 9090:${EDGE_PRIVATE_IP}:9090 ${SSH_USER}@${BASTION_PUBLIC_IP}"
echo "    Then open: http://localhost:3000"
echo ""
info "Run 05-create-load-balancer.sh next."
