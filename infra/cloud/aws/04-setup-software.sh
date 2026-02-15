#!/bin/bash
# =============================================================================
# 04-setup-software.sh -- Install and configure software on all instances.
#
# Private instances have no direct internet access. This script:
#   1. Creates a NAT Gateway so private instances can reach the internet.
#   2. Waits for user-data scripts to complete (Docker install via yum).
#   3. Verifies Docker is running on each private instance.
#   4. Builds ME and Edge Gateway Docker images locally and transfers them
#      through the k6 bastion host.
#   5. Starts the Redpanda container on the Redpanda instance.
#   6. Starts Prometheus and Grafana containers on the monitoring instance.
#   7. Verifies k6 is installed on the load generator.
#
# SSH access to private instances is proxied through the k6 instance in the
# public subnet (ProxyJump / bastion pattern).
#
# Usage:
#   ./04-setup-software.sh               # Full setup
#   ./04-setup-software.sh --skip-build   # Skip Docker image build (reuse)
#   ./04-setup-software.sh --skip-nat     # Skip NAT gateway (already exists)
#
# Idempotent: checks state before acting.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 4: Software Setup"

# Parse arguments
SKIP_BUILD=false
SKIP_NAT=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --skip-nat)   SKIP_NAT=true ;;
    esac
done

# Validate prerequisites
for var in VPC_ID PUB_SUBNET_ID PRIV_SUBNET_ID IGW_ID PUB_RT_ID \
           INST_REDPANDA INST_ME_A INST_EDGE INST_MONITORING INST_K6 K6_PUBLIC_IP; do
    val="${!var:-}"
    if [ -z "$val" ] || [ "$val" = "None" ]; then
        error "${var} is not set. Run previous scripts first."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Helper: SSH to a private instance via k6 bastion (ProxyJump)
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
# Helper: SCP to a private instance via k6 bastion
# ---------------------------------------------------------------------------
bastion_scp() {
    local src="$1"
    local private_ip="$2"
    local dst="$3"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        -i "$KEY_FILE" \
        -o "ProxyJump=ec2-user@${K6_PUBLIC_IP}" \
        "$src" "ec2-user@${private_ip}:${dst}"
}

# ---------------------------------------------------------------------------
# Helper: wait for SSH to become available on a private instance
# ---------------------------------------------------------------------------
wait_for_ssh_bastion() {
    local private_ip="$1"
    local name="$2"
    local max_attempts=30
    local attempt=1

    info "Waiting for SSH on ${name} (${private_ip}) via bastion..."
    while [ $attempt -le $max_attempts ]; do
        if bastion_ssh "$private_ip" "echo ok" &>/dev/null; then
            success "SSH ready on ${name}"
            return 0
        fi
        info "  Attempt ${attempt}/${max_attempts}... retrying in 10s"
        sleep 10
        attempt=$((attempt + 1))
    done
    error "SSH not available on ${name} after ${max_attempts} attempts."
    return 1
}

# ---------------------------------------------------------------------------
# Helper: wait for SSH to become available on k6 (public, direct)
# ---------------------------------------------------------------------------
wait_for_ssh_direct() {
    local ip="$1"
    local name="$2"
    local max_attempts=20
    local attempt=1

    info "Waiting for SSH on ${name} (${ip})..."
    while [ $attempt -le $max_attempts ]; do
        if ssh_cmd "$ip" "echo ok" &>/dev/null; then
            success "SSH ready on ${name}"
            return 0
        fi
        info "  Attempt ${attempt}/${max_attempts}... retrying in 10s"
        sleep 10
        attempt=$((attempt + 1))
    done
    error "SSH not available on ${name} after ${max_attempts} attempts."
    return 1
}

# ---------------------------------------------------------------------------
# 1. Create NAT Gateway for private subnet internet access
# ---------------------------------------------------------------------------
if [ "$SKIP_NAT" = true ]; then
    info "Skipping NAT gateway creation (--skip-nat)."
else
    header "Creating NAT Gateway"

    # Check for existing NAT Gateway
    EXISTING_NAT=$(aws ec2 describe-nat-gateways \
        --region "$AWS_REGION" \
        --filter "Name=tag:Name,Values=${PROJECT_PREFIX}-natgw" "Name=state,Values=available,pending" \
        --query 'NatGateways[0].NatGatewayId' \
        --output text 2>/dev/null || echo "None")

    if [ "$EXISTING_NAT" != "None" ] && [ -n "$EXISTING_NAT" ]; then
        success "NAT Gateway already exists: ${EXISTING_NAT}"
        NAT_GW_ID="$EXISTING_NAT"
    else
        # Allocate Elastic IP for NAT Gateway
        info "Allocating Elastic IP for NAT Gateway..."
        EIP_ALLOC_ID=$(aws ec2 allocate-address \
            --region "$AWS_REGION" \
            --domain vpc \
            --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-natgw-eip},{Key=Project,Value=${PROJECT_PREFIX}}]" \
            --query 'AllocationId' --output text)
        success "Elastic IP allocated: ${EIP_ALLOC_ID}"
        persist_var "NAT_EIP_ALLOC_ID" "$EIP_ALLOC_ID"

        # Create NAT Gateway in the public subnet
        info "Creating NAT Gateway in public subnet..."
        NAT_GW_ID=$(aws ec2 create-nat-gateway \
            --region "$AWS_REGION" \
            --subnet-id "$PUB_SUBNET_ID" \
            --allocation-id "$EIP_ALLOC_ID" \
            --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-natgw},{Key=Project,Value=${PROJECT_PREFIX}}]" \
            --query 'NatGateway.NatGatewayId' --output text)
        success "NAT Gateway created: ${NAT_GW_ID}"

        info "Waiting for NAT Gateway to become available (this takes 1-2 minutes)..."
        aws ec2 wait nat-gateway-available \
            --region "$AWS_REGION" \
            --nat-gateway-ids "$NAT_GW_ID"
        success "NAT Gateway is available."
    fi
    persist_var "NAT_GW_ID" "$NAT_GW_ID"

    # Create or update private route table with NAT Gateway route
    PRIV_RT_ID=$(aws ec2 describe-route-tables \
        --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=${PROJECT_PREFIX}-private-rt" \
        --query 'RouteTables[0].RouteTableId' \
        --output text 2>/dev/null || echo "None")

    if [ "$PRIV_RT_ID" = "None" ] || [ -z "$PRIV_RT_ID" ]; then
        info "Creating private route table..."
        PRIV_RT_ID=$(aws ec2 create-route-table \
            --region "$AWS_REGION" \
            --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-private-rt},{Key=Project,Value=${PROJECT_PREFIX}}]" \
            --query 'RouteTable.RouteTableId' --output text)
        success "Private route table created: ${PRIV_RT_ID}"

        info "Associating private route table with private subnet..."
        aws ec2 associate-route-table \
            --region "$AWS_REGION" \
            --route-table-id "$PRIV_RT_ID" \
            --subnet-id "$PRIV_SUBNET_ID" >/dev/null
        success "Route table associated."
    else
        success "Private route table already exists: ${PRIV_RT_ID}"
    fi
    persist_var "PRIV_RT_ID" "$PRIV_RT_ID"

    info "Adding default route via NAT Gateway..."
    aws ec2 create-route \
        --region "$AWS_REGION" \
        --route-table-id "$PRIV_RT_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || \
    aws ec2 replace-route \
        --region "$AWS_REGION" \
        --route-table-id "$PRIV_RT_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
    success "Private subnet now has internet access via NAT Gateway."
fi

# ---------------------------------------------------------------------------
# 2. Wait for all instance status checks to pass
# ---------------------------------------------------------------------------
header "Waiting for Instance Status Checks"

ALL_INST_IDS=("$INST_REDPANDA" "$INST_ME_A" "$INST_EDGE" "$INST_MONITORING" "$INST_K6")
ALL_INST_NAMES=("Redpanda" "ME-Shard-A" "Edge-Gateway" "Monitoring" "k6-LoadGen")

if [ -n "${INST_ME_B:-}" ] && [ "${INST_ME_B}" != "None" ]; then
    ALL_INST_IDS+=("$INST_ME_B")
    ALL_INST_NAMES+=("ME-Shard-B")
fi
if [ -n "${INST_ME_C:-}" ] && [ "${INST_ME_C}" != "None" ]; then
    ALL_INST_IDS+=("$INST_ME_C")
    ALL_INST_NAMES+=("ME-Shard-C")
fi

for i in "${!ALL_INST_IDS[@]}"; do
    wait_for_status_ok "${ALL_INST_IDS[$i]}" "${ALL_INST_NAMES[$i]}"
done

# ---------------------------------------------------------------------------
# 3. Ensure SSH key is available on the bastion for ProxyJump
# ---------------------------------------------------------------------------
header "Configuring Bastion (k6 instance)"

wait_for_ssh_direct "$K6_PUBLIC_IP" "k6-LoadGen"

info "Copying SSH key to bastion for ProxyJump to private instances..."
scp_to "$K6_PUBLIC_IP" "$KEY_FILE" ".ssh/${KEY_NAME}.pem"
ssh_cmd "$K6_PUBLIC_IP" "chmod 400 ~/.ssh/${KEY_NAME}.pem"
success "SSH key deployed to bastion."

# Configure SSH on the bastion to use the key for private subnet
ssh_cmd "$K6_PUBLIC_IP" "cat > ~/.ssh/config << 'SSHEOF'
Host 10.0.2.*
    User ec2-user
    IdentityFile ~/.ssh/${KEY_NAME}.pem
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHEOF
chmod 600 ~/.ssh/config"
success "Bastion SSH config written."

# ---------------------------------------------------------------------------
# 4. Verify Docker on private instances + retry install if user-data failed
# ---------------------------------------------------------------------------
header "Verifying Docker on Private Instances"

verify_docker() {
    local ip="$1"
    local name="$2"

    wait_for_ssh_bastion "$ip" "$name"

    info "Checking Docker on ${name} (${ip})..."
    if bastion_ssh "$ip" "sudo docker info" &>/dev/null; then
        success "Docker is running on ${name}."
        return 0
    fi

    warn "Docker not ready on ${name}. Installing via yum..."
    bastion_ssh "$ip" "sudo yum install -y docker jq && sudo systemctl enable docker && sudo systemctl start docker && sudo usermod -aG docker ec2-user"

    # Verify after install
    sleep 3
    if bastion_ssh "$ip" "sudo docker info" &>/dev/null; then
        success "Docker installed and running on ${name}."
    else
        error "Failed to install Docker on ${name}."
        return 1
    fi
}

PRIVATE_IPS=("$IP_REDPANDA" "$IP_ME_SHARD_A" "$IP_EDGE_GW" "$IP_MONITORING")
PRIVATE_NAMES=("Redpanda" "ME-Shard-A" "Edge-Gateway" "Monitoring")

if [ -n "${INST_ME_B:-}" ] && [ "${INST_ME_B}" != "None" ]; then
    PRIVATE_IPS+=("$IP_ME_SHARD_B")
    PRIVATE_NAMES+=("ME-Shard-B")
fi
if [ -n "${INST_ME_C:-}" ] && [ "${INST_ME_C}" != "None" ]; then
    PRIVATE_IPS+=("$IP_ME_SHARD_C")
    PRIVATE_NAMES+=("ME-Shard-C")
fi

for i in "${!PRIVATE_IPS[@]}"; do
    verify_docker "${PRIVATE_IPS[$i]}" "${PRIVATE_NAMES[$i]}"
done

# ---------------------------------------------------------------------------
# 5. Start Redpanda container
# ---------------------------------------------------------------------------
header "Starting Redpanda"

info "Checking Redpanda container status..."
RP_RUNNING=$(bastion_ssh "$IP_REDPANDA" "sudo docker ps --filter name=redpanda --format '{{.Names}}'" 2>/dev/null || echo "")

if [ "$RP_RUNNING" = "redpanda" ]; then
    success "Redpanda container is already running."
else
    # Check if the container exists but is stopped
    RP_EXISTS=$(bastion_ssh "$IP_REDPANDA" "sudo docker ps -a --filter name=redpanda --format '{{.Names}}'" 2>/dev/null || echo "")
    if [ "$RP_EXISTS" = "redpanda" ]; then
        info "Redpanda container exists but is stopped. Restarting..."
        bastion_ssh "$IP_REDPANDA" "sudo docker start redpanda"
    else
        info "Pulling and starting Redpanda container..."
        bastion_ssh "$IP_REDPANDA" "sudo docker run -d --name redpanda --restart always --network host \
            docker.redpanda.com/redpandadata/redpanda:latest \
            redpanda start --smp=1 --memory=1G --overprovisioned \
            --kafka-addr PLAINTEXT://0.0.0.0:${KAFKA_PORT} \
            --advertise-kafka-addr PLAINTEXT://${IP_REDPANDA}:${KAFKA_PORT} \
            --node-id 0 --check=false"
    fi

    # Wait for Redpanda to be ready
    info "Waiting for Redpanda to become healthy..."
    local_attempt=1
    while [ $local_attempt -le 30 ]; do
        if bastion_ssh "$IP_REDPANDA" "curl -sf http://localhost:${REDPANDA_ADMIN_PORT}/v1/status/ready" &>/dev/null; then
            success "Redpanda is healthy."
            break
        fi
        if [ $local_attempt -eq 30 ]; then
            warn "Redpanda health check timed out. It may still be starting."
        fi
        sleep 5
        local_attempt=$((local_attempt + 1))
    done
fi

# Create required topics
info "Creating Kafka topics..."
bastion_ssh "$IP_REDPANDA" "sudo docker exec redpanda rpk topic create matching-events --partitions 3 --replicas 1 2>/dev/null || true"
bastion_ssh "$IP_REDPANDA" "sudo docker exec redpanda rpk topic create order-events --partitions 3 --replicas 1 2>/dev/null || true"
success "Kafka topics ready."

# ---------------------------------------------------------------------------
# 6. Build and transfer Docker images
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = true ]; then
    info "Skipping Docker image build (--skip-build)."
else
    header "Building and Transferring Docker Images"

    PROJECT_ROOT="${SCRIPT_DIR}/../../.."

    # Check if Gradle wrapper exists and build the JARs
    if [ -f "${PROJECT_ROOT}/gradlew" ]; then
        info "Building Matching Engine JAR..."
        (cd "${PROJECT_ROOT}" && ./gradlew :matching-engine:bootJar --no-daemon -q 2>&1) || \
            warn "Gradle build for matching-engine may have failed. Checking for existing JAR..."

        info "Building Edge Gateway JAR..."
        (cd "${PROJECT_ROOT}" && ./gradlew :edge-gateway:bootJar --no-daemon -q 2>&1) || \
            warn "Gradle build for edge-gateway may have failed. Checking for existing JAR..."
    else
        warn "Gradle wrapper not found. Assuming JARs are pre-built."
    fi

    # Build Docker images (multi-arch for ARM64)
    info "Building Matching Engine Docker image for linux/arm64..."
    docker buildx build --platform linux/arm64 \
        -t "${ME_IMAGE}" \
        -f "${PROJECT_ROOT}/src/matching-engine/Dockerfile" \
        "${PROJECT_ROOT}/src/matching-engine" \
        --load 2>&1 || {
        warn "buildx not available, trying regular docker build..."
        docker build \
            -t "${ME_IMAGE}" \
            -f "${PROJECT_ROOT}/src/matching-engine/Dockerfile" \
            "${PROJECT_ROOT}/src/matching-engine" 2>&1
    }
    success "ME image built: ${ME_IMAGE}"

    info "Building Edge Gateway Docker image for linux/arm64..."
    docker buildx build --platform linux/arm64 \
        -t "${EDGE_IMAGE}" \
        -f "${PROJECT_ROOT}/src/edge-gateway/Dockerfile" \
        "${PROJECT_ROOT}/src/edge-gateway" \
        --load 2>&1 || {
        warn "buildx not available, trying regular docker build..."
        docker build \
            -t "${EDGE_IMAGE}" \
            -f "${PROJECT_ROOT}/src/edge-gateway/Dockerfile" \
            "${PROJECT_ROOT}/src/edge-gateway" 2>&1
    }
    success "Edge image built: ${EDGE_IMAGE}"

    # Save images to tar files
    TMPDIR=$(mktemp -d)
    info "Saving Docker images to tarballs..."
    docker save "${ME_IMAGE}" | gzip > "${TMPDIR}/me-image.tar.gz"
    docker save "${EDGE_IMAGE}" | gzip > "${TMPDIR}/edge-image.tar.gz"
    success "Images saved to ${TMPDIR}"

    # Transfer images to k6 bastion first
    info "Transferring images to bastion (k6 instance)..."
    scp_to "$K6_PUBLIC_IP" "${TMPDIR}/me-image.tar.gz" "/tmp/me-image.tar.gz"
    scp_to "$K6_PUBLIC_IP" "${TMPDIR}/edge-image.tar.gz" "/tmp/edge-image.tar.gz"
    success "Images transferred to bastion."

    # Transfer from bastion to ME shard instances
    transfer_image() {
        local ip="$1"
        local name="$2"
        local image_file="$3"
        local image_name="$4"

        info "Transferring ${image_name} to ${name} (${ip})..."
        ssh_cmd "$K6_PUBLIC_IP" "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i ~/.ssh/${KEY_NAME}.pem \
            /tmp/${image_file} ec2-user@${ip}:/tmp/${image_file}"
        bastion_ssh "$ip" "sudo docker load < /tmp/${image_file} && rm -f /tmp/${image_file}"
        success "Image ${image_name} loaded on ${name}."
    }

    # ME image -> all ME shard instances
    transfer_image "$IP_ME_SHARD_A" "ME-Shard-A" "me-image.tar.gz" "${ME_IMAGE}"

    if [ -n "${INST_ME_B:-}" ] && [ "${INST_ME_B}" != "None" ]; then
        transfer_image "$IP_ME_SHARD_B" "ME-Shard-B" "me-image.tar.gz" "${ME_IMAGE}"
    fi
    if [ -n "${INST_ME_C:-}" ] && [ "${INST_ME_C}" != "None" ]; then
        transfer_image "$IP_ME_SHARD_C" "ME-Shard-C" "me-image.tar.gz" "${ME_IMAGE}"
    fi

    # Edge image -> Edge Gateway instance
    transfer_image "$IP_EDGE_GW" "Edge-Gateway" "edge-image.tar.gz" "${EDGE_IMAGE}"

    # Clean up local temp files
    rm -rf "${TMPDIR}"
    success "Docker images distributed to all instances."
fi

# ---------------------------------------------------------------------------
# 7. Set up Monitoring (Prometheus + Grafana)
# ---------------------------------------------------------------------------
header "Setting Up Monitoring"

info "Checking Prometheus container status..."
PROM_RUNNING=$(bastion_ssh "$IP_MONITORING" "sudo docker ps --filter name=prometheus --format '{{.Names}}'" 2>/dev/null || echo "")

if [ "$PROM_RUNNING" = "prometheus" ]; then
    success "Prometheus container is already running."
else
    # Prepare Prometheus config on the monitoring instance
    info "Creating Prometheus configuration..."

    # Build the static targets list for scrape configs
    ME_TARGETS="'${IP_ME_SHARD_A}:${METRICS_PORT}'"
    if [ -n "${INST_ME_B:-}" ] && [ "${INST_ME_B}" != "None" ]; then
        ME_TARGETS="${ME_TARGETS}, '${IP_ME_SHARD_B}:${METRICS_PORT}'"
    fi
    if [ -n "${INST_ME_C:-}" ] && [ "${INST_ME_C}" != "None" ]; then
        ME_TARGETS="${ME_TARGETS}, '${IP_ME_SHARD_C}:${METRICS_PORT}'"
    fi

    bastion_ssh "$IP_MONITORING" "sudo mkdir -p /opt/prometheus /opt/prometheus/rules /opt/grafana/provisioning/datasources /opt/grafana/provisioning/dashboards /opt/grafana/dashboards"

    # Write Prometheus config
    bastion_ssh "$IP_MONITORING" "sudo tee /opt/prometheus/prometheus.yml > /dev/null << 'PROMEOF'
global:
  scrape_interval: 5s
  scrape_timeout: 5s
  evaluation_interval: 5s

rule_files:
  - /etc/prometheus/rules/*.yaml

scrape_configs:
  - job_name: matching-engine
    static_configs:
      - targets: [${ME_TARGETS}]
    relabel_configs:
      - source_labels: [__address__]
        regex: '${IP_ME_SHARD_A}:.*'
        target_label: shard
        replacement: a
      - source_labels: [__address__]
        regex: '${IP_ME_SHARD_B}:.*'
        target_label: shard
        replacement: b
      - source_labels: [__address__]
        regex: '${IP_ME_SHARD_C}:.*'
        target_label: shard
        replacement: c

  - job_name: edge-gateway
    static_configs:
      - targets: ['${IP_EDGE_GW}:${METRICS_PORT}']

  - job_name: redpanda
    static_configs:
      - targets: ['${IP_REDPANDA}:${REDPANDA_ADMIN_PORT}']
    metrics_path: /public_metrics
PROMEOF"
    success "Prometheus config written."

    # Write recording rules
    info "Writing Prometheus recording rules..."
    bastion_ssh "$IP_MONITORING" "sudo tee /opt/prometheus/rules/recording-rules.yaml > /dev/null << 'RULESEOF'
groups:
  - name: matching-engine-experiment
    interval: 5s
    rules:
      - record: me:match_duration_p99:30s
        expr: histogram_quantile(0.99, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

      - record: me:match_duration_p95:30s
        expr: histogram_quantile(0.95, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

      - record: me:match_duration_p50:30s
        expr: histogram_quantile(0.50, sum(rate(me_match_duration_seconds_bucket[30s])) by (le, shard))

      - record: me:matches_per_minute:total
        expr: sum(rate(me_matches_total[1m])) * 60

      - record: me:matches_per_minute:by_shard
        expr: rate(me_matches_total[1m]) * 60

      - record: me:validation_avg_seconds
        expr: rate(me_order_validation_duration_seconds_sum[1m]) / rate(me_order_validation_duration_seconds_count[1m])

      - record: me:orderbook_insertion_avg_seconds
        expr: rate(me_orderbook_insertion_duration_seconds_sum[1m]) / rate(me_orderbook_insertion_duration_seconds_count[1m])

      - record: me:matching_algorithm_avg_seconds
        expr: rate(me_matching_algorithm_duration_seconds_sum[1m]) / rate(me_matching_algorithm_duration_seconds_count[1m])

      - record: me:wal_append_avg_seconds
        expr: rate(me_wal_append_duration_seconds_sum[1m]) / rate(me_wal_append_duration_seconds_count[1m])

      - record: me:event_publish_avg_seconds
        expr: rate(me_event_publish_duration_seconds_sum[1m]) / rate(me_event_publish_duration_seconds_count[1m])

      - record: me:gc_pause_rate:1m
        expr: rate(jvm_gc_collection_seconds_sum{gc="ZGC Pauses"}[1m])

      - record: me:orders_per_second
        expr: sum(rate(me_orders_received_total[30s]))
RULESEOF"
    success "Recording rules written."

    # Start Prometheus container
    info "Starting Prometheus container..."
    bastion_ssh "$IP_MONITORING" "sudo docker rm -f prometheus 2>/dev/null || true"
    bastion_ssh "$IP_MONITORING" "sudo docker run -d --name prometheus --restart always --network host \
        -v /opt/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
        -v /opt/prometheus/rules:/etc/prometheus/rules:ro \
        prom/prometheus:latest \
        --config.file=/etc/prometheus/prometheus.yml \
        --web.enable-remote-write-receiver \
        --storage.tsdb.retention.time=7d \
        --web.listen-address=0.0.0.0:${PROMETHEUS_PORT}"
    success "Prometheus started on port ${PROMETHEUS_PORT}."
fi

info "Checking Grafana container status..."
GF_RUNNING=$(bastion_ssh "$IP_MONITORING" "sudo docker ps --filter name=grafana --format '{{.Names}}'" 2>/dev/null || echo "")

if [ "$GF_RUNNING" = "grafana" ]; then
    success "Grafana container is already running."
else
    # Write Grafana datasource provisioning
    info "Creating Grafana provisioning configs..."
    bastion_ssh "$IP_MONITORING" "sudo tee /opt/grafana/provisioning/datasources/prometheus.yaml > /dev/null << 'DSEOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false
DSEOF"

    # Write dashboard provisioning config
    bastion_ssh "$IP_MONITORING" "sudo tee /opt/grafana/provisioning/dashboards/dashboards.yaml > /dev/null << 'DBEOF'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
DBEOF"

    # Transfer the Grafana dashboard JSON
    DASHBOARD_FILE="${SCRIPT_DIR}/../../grafana/dashboards/matching-engine-experiment.json"
    if [ -f "$DASHBOARD_FILE" ]; then
        info "Transferring Grafana dashboard..."
        scp_to "$K6_PUBLIC_IP" "$DASHBOARD_FILE" "/tmp/matching-engine-experiment.json"
        ssh_cmd "$K6_PUBLIC_IP" "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i ~/.ssh/${KEY_NAME}.pem \
            /tmp/matching-engine-experiment.json ec2-user@${IP_MONITORING}:/tmp/matching-engine-experiment.json"
        bastion_ssh "$IP_MONITORING" "sudo cp /tmp/matching-engine-experiment.json /opt/grafana/dashboards/"
        success "Dashboard JSON deployed."
    else
        warn "Dashboard file not found at ${DASHBOARD_FILE}. Grafana will start without pre-provisioned dashboard."
    fi

    # Start Grafana container
    info "Starting Grafana container..."
    bastion_ssh "$IP_MONITORING" "sudo docker rm -f grafana 2>/dev/null || true"
    bastion_ssh "$IP_MONITORING" "sudo docker run -d --name grafana --restart always --network host \
        -e GF_SECURITY_ADMIN_PASSWORD=admin1234 \
        -e GF_SERVER_HTTP_PORT=${GRAFANA_PORT} \
        -v /opt/grafana/provisioning:/etc/grafana/provisioning:ro \
        -v /opt/grafana/dashboards:/var/lib/grafana/dashboards:ro \
        grafana/grafana:latest"
    success "Grafana started on port ${GRAFANA_PORT}."
fi

# Verify monitoring health
info "Waiting for Prometheus to be ready..."
sleep 5
PROM_UP=$(bastion_ssh "$IP_MONITORING" "curl -sf http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null || echo "")
if [ -n "$PROM_UP" ]; then
    success "Prometheus is healthy."
else
    warn "Prometheus health check failed. It may still be starting."
fi

GF_UP=$(bastion_ssh "$IP_MONITORING" "curl -sf http://localhost:${GRAFANA_PORT}/api/health" 2>/dev/null || echo "")
if [ -n "$GF_UP" ]; then
    success "Grafana is healthy."
else
    warn "Grafana health check failed. It may still be starting."
fi

# ---------------------------------------------------------------------------
# 8. Verify k6 on the load generator
# ---------------------------------------------------------------------------
header "Verifying k6 on Load Generator"

K6_VERSION_CHECK=$(ssh_cmd "$K6_PUBLIC_IP" "k6 version" 2>/dev/null || echo "")
if [ -n "$K6_VERSION_CHECK" ]; then
    success "k6 is installed: ${K6_VERSION_CHECK}"
else
    warn "k6 not yet installed. Installing..."
    ssh_cmd "$K6_PUBLIC_IP" "
        K6_VERSION=v0.50.0
        wget -q \"https://github.com/grafana/k6/releases/download/\${K6_VERSION}/k6-\${K6_VERSION}-linux-arm64.tar.gz\" -O /tmp/k6.tar.gz
        tar xzf /tmp/k6.tar.gz -C /tmp/
        sudo mv /tmp/k6-*/k6 /usr/local/bin/k6 2>/dev/null || sudo mv /tmp/k6 /usr/local/bin/k6 2>/dev/null || true
        sudo chmod +x /usr/local/bin/k6
        rm -rf /tmp/k6*
    "
    K6_VERSION_CHECK=$(ssh_cmd "$K6_PUBLIC_IP" "k6 version" 2>/dev/null || echo "FAILED")
    if [ "$K6_VERSION_CHECK" != "FAILED" ]; then
        success "k6 installed: ${K6_VERSION_CHECK}"
    else
        error "Failed to install k6 on load generator."
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Software Setup Complete"
echo ""
info "Services running:"
info "  Redpanda:      ${IP_REDPANDA}:${KAFKA_PORT}"
info "  Prometheus:    ${IP_MONITORING}:${PROMETHEUS_PORT}"
info "  Grafana:       ${IP_MONITORING}:${GRAFANA_PORT} (admin/admin1234)"
info "  k6:            ${K6_PUBLIC_IP} (public)"
echo ""
info "Docker images loaded on:"
info "  ME shards:     ${ME_IMAGE}"
info "  Edge Gateway:  ${EDGE_IMAGE}"
echo ""
info "SSH to private instances via bastion:"
info "  ssh -i ${KEY_FILE} -o ProxyJump=ec2-user@${K6_PUBLIC_IP} ec2-user@<PRIVATE_IP>"
echo ""
info "Next step: Run 05-deploy-me.sh"
