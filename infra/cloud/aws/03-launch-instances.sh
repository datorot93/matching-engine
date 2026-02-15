#!/bin/bash
# =============================================================================
# 03-launch-instances.sh -- Launch all EC2 instances and create the NLB.
#
# Instances launched:
#   - Redpanda           c7g.medium   10.0.2.10   (On-Demand, private)
#   - ME Shard A         c7g.medium   10.0.2.20   (On-Demand, private)
#   - ME Shard B         c7g.medium   10.0.2.21   (On-Demand, private, ASR 2 only)
#   - ME Shard C         c7g.medium   10.0.2.22   (On-Demand, private, ASR 2 only)
#   - Edge Gateway       c7g.medium   10.0.2.30   (On-Demand, private)
#   - Monitoring         t4g.small    10.0.2.40   (Spot, private)
#   - k6 Load Generator  c7g.large    (auto IP)   (Spot, public)
#   - NLB                             (public)
#
# Usage:
#   ./03-launch-instances.sh           # Launch ASR 1 set (no shards B/C)
#   ./03-launch-instances.sh --all     # Launch all instances including shards B/C
#   ./03-launch-instances.sh --asr2    # Same as --all
#
# Idempotent: checks if an instance with the same Name tag already exists
# (in running/pending/stopped state) before launching.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 3: Launch EC2 Instances"

# Parse arguments
LAUNCH_ALL=false
if [[ "${1:-}" == "--all" ]] || [[ "${1:-}" == "--asr2" ]]; then
    LAUNCH_ALL=true
    info "Mode: Full deployment (ASR 1 + ASR 2, all 3 shards)"
else
    info "Mode: ASR 1 only (single shard). Use --all or --asr2 for all shards."
fi

# Validate prerequisites
for var in AMI_ID VPC_ID PRIV_SUBNET_ID PUB_SUBNET_ID SG_RP_ID SG_ME_ID SG_EDGE_ID SG_MON_ID SG_LG_ID; do
    val="${!var:-}"
    if [ -z "$val" ] || [ "$val" = "None" ]; then
        error "${var} is not set. Run previous scripts first."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Helper: check if an instance with a given Name tag exists and is usable
# ---------------------------------------------------------------------------
find_instance_by_name() {
    local name="$1"
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:Name,Values=${name}" \
            "Name=instance-state-name,Values=running,pending,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "None"
}

# ---------------------------------------------------------------------------
# Helper: launch an on-demand instance
# ---------------------------------------------------------------------------
launch_instance() {
    local name="$1"
    local instance_type="$2"
    local subnet_id="$3"
    local sg_id="$4"
    local private_ip="$5"     # empty string for auto-assign (public subnet)
    local block_devices="$6"
    local user_data="$7"
    local var_name="$8"

    local existing
    existing=$(find_instance_by_name "$name")
    if [ "$existing" != "None" ] && [ -n "$existing" ]; then
        success "Instance '${name}' already exists: ${existing}"
        eval "${var_name}=${existing}"
        persist_var "$var_name" "$existing"
        return
    fi

    info "Launching instance '${name}' (${instance_type})..."

    local ip_flag=""
    if [ -n "$private_ip" ]; then
        ip_flag="--private-ip-address ${private_ip}"
    fi

    local instance_id
    instance_id=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$instance_type" \
        --key-name "$KEY_NAME" \
        --subnet-id "$subnet_id" \
        --security-group-ids "$sg_id" \
        ${ip_flag} \
        --block-device-mappings "$block_devices" \
        --user-data "$user_data" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'Instances[0].InstanceId' --output text)

    success "Launched '${name}': ${instance_id}"
    eval "${var_name}=${instance_id}"
    persist_var "$var_name" "$instance_id"
}

# ---------------------------------------------------------------------------
# Helper: launch a spot instance
# ---------------------------------------------------------------------------
launch_spot_instance() {
    local name="$1"
    local instance_type="$2"
    local subnet_id="$3"
    local sg_id="$4"
    local private_ip="$5"
    local block_devices="$6"
    local user_data="$7"
    local var_name="$8"
    local spot_type="${9:-one-time}"

    local existing
    existing=$(find_instance_by_name "$name")
    if [ "$existing" != "None" ] && [ -n "$existing" ]; then
        success "Instance '${name}' already exists: ${existing}"
        eval "${var_name}=${existing}"
        persist_var "$var_name" "$existing"
        return
    fi

    info "Launching spot instance '${name}' (${instance_type}, ${spot_type})..."

    local ip_flag=""
    if [ -n "$private_ip" ]; then
        ip_flag="--private-ip-address ${private_ip}"
    fi

    local spot_opts
    if [ "$spot_type" = "persistent" ]; then
        spot_opts='{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}'
    else
        spot_opts='{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}'
    fi

    local instance_id
    instance_id=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$instance_type" \
        --key-name "$KEY_NAME" \
        --subnet-id "$subnet_id" \
        --security-group-ids "$sg_id" \
        ${ip_flag} \
        --instance-market-options "$spot_opts" \
        --block-device-mappings "$block_devices" \
        --user-data "$user_data" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'Instances[0].InstanceId' --output text)

    success "Launched spot '${name}': ${instance_id}"
    eval "${var_name}=${instance_id}"
    persist_var "$var_name" "$instance_id"
}

# ---------------------------------------------------------------------------
# User data scripts (base64-encoded by AWS CLI automatically)
# ---------------------------------------------------------------------------

# Common Docker installation preamble
read -r -d '' DOCKER_INSTALL_SCRIPT << 'USERDATA_EOF' || true
#!/bin/bash
set -ex
yum update -y
yum install -y docker jq
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user
USERDATA_EOF

# --- Redpanda user data ---
read -r -d '' UD_REDPANDA << USERDATA_EOF || true
#!/bin/bash
set -ex
yum update -y
yum install -y docker jq
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# Mount data volume
if [ -b /dev/xvdf ]; then
    mkfs.xfs /dev/xvdf
    mkdir -p /data
    mount /dev/xvdf /data
    echo '/dev/xvdf /data xfs defaults,nofail 0 2' >> /etc/fstab
fi

# Start Redpanda
docker run -d --name redpanda --restart always --network host \
    -v /data:/var/lib/redpanda/data \
    docker.redpanda.com/redpandadata/redpanda:latest \
    redpanda start --smp=1 --memory=1G --overprovisioned \
    --kafka-addr PLAINTEXT://0.0.0.0:${KAFKA_PORT} \
    --advertise-kafka-addr PLAINTEXT://${IP_REDPANDA}:${KAFKA_PORT} \
    --node-id 0 --check=false
USERDATA_EOF

# --- ME Shard user data template ---
generate_me_userdata() {
    local shard_id="$1"
    local shard_symbols="$2"
    local private_ip="$3"

    cat << USERDATA_EOF
#!/bin/bash
set -ex
yum update -y
yum install -y docker jq
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# Mount WAL volume
if [ -b /dev/xvdf ]; then
    mkfs.xfs /dev/xvdf
    mkdir -p /data/wal
    mount /dev/xvdf /data/wal
    echo '/dev/xvdf /data/wal xfs defaults,nofail 0 2' >> /etc/fstab
fi

echo "Waiting for Docker to be fully ready..."
sleep 5

echo "ME Shard ${shard_id} user-data complete. Container will be started by 05-deploy-me.sh."
USERDATA_EOF
}

# --- Edge Gateway user data ---
read -r -d '' UD_EDGE << USERDATA_EOF || true
#!/bin/bash
set -ex
yum update -y
yum install -y docker jq
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

echo "Edge Gateway user-data complete. Container will be started by 05-deploy-me.sh."
USERDATA_EOF

# --- Monitoring user data ---
read -r -d '' UD_MONITORING << USERDATA_EOF || true
#!/bin/bash
set -ex
yum update -y
yum install -y docker jq
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

echo "Monitoring user-data complete. Containers will be started by 05-deploy-me.sh."
USERDATA_EOF

# --- k6 Load Generator user data ---
read -r -d '' UD_K6 << 'USERDATA_EOF' || true
#!/bin/bash
set -ex
yum update -y
yum install -y docker jq wget tar

# Install k6 ARM64 binary
K6_VERSION="v0.50.0"
wget -q "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-arm64.tar.gz" -O /tmp/k6.tar.gz
tar xzf /tmp/k6.tar.gz -C /tmp/
mv /tmp/k6-*/k6 /usr/local/bin/k6 2>/dev/null || mv /tmp/k6 /usr/local/bin/k6 2>/dev/null || true
chmod +x /usr/local/bin/k6
rm -rf /tmp/k6*

# Verify
k6 version || echo "k6 installation may need manual verification"

echo "k6 load generator user-data complete."
USERDATA_EOF

# ---------------------------------------------------------------------------
# EBS block device mappings
# ---------------------------------------------------------------------------
BDM_STANDARD='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]'
BDM_ME='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}},{"DeviceName":"/dev/xvdf","Ebs":{"VolumeSize":10,"VolumeType":"gp3","DeleteOnTermination":true}}]'
BDM_REDPANDA='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}},{"DeviceName":"/dev/xvdf","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]'
BDM_MONITORING='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]'

# ---------------------------------------------------------------------------
# Launch instances
# ---------------------------------------------------------------------------

# 1. Redpanda
launch_instance \
    "${PROJECT_PREFIX}-redpanda" \
    "$INSTANCE_TYPE_REDPANDA" \
    "$PRIV_SUBNET_ID" \
    "$SG_RP_ID" \
    "$IP_REDPANDA" \
    "$BDM_REDPANDA" \
    "$UD_REDPANDA" \
    "INST_REDPANDA"

# 2. ME Shard A (always launched)
UD_ME_A=$(generate_me_userdata "a" "$SHARD_A_SYMBOLS" "$IP_ME_SHARD_A")
launch_instance \
    "${PROJECT_PREFIX}-shard-a" \
    "$INSTANCE_TYPE_ME" \
    "$PRIV_SUBNET_ID" \
    "$SG_ME_ID" \
    "$IP_ME_SHARD_A" \
    "$BDM_ME" \
    "$UD_ME_A" \
    "INST_ME_A"

# 3. ME Shard B (ASR 2 only)
if [ "$LAUNCH_ALL" = true ]; then
    UD_ME_B=$(generate_me_userdata "b" "$SHARD_B_SYMBOLS" "$IP_ME_SHARD_B")
    launch_instance \
        "${PROJECT_PREFIX}-shard-b" \
        "$INSTANCE_TYPE_ME" \
        "$PRIV_SUBNET_ID" \
        "$SG_ME_ID" \
        "$IP_ME_SHARD_B" \
        "$BDM_ME" \
        "$UD_ME_B" \
        "INST_ME_B"
else
    info "Skipping ME Shard B (ASR 1 mode). Use --all for ASR 2."
fi

# 4. ME Shard C (ASR 2 only)
if [ "$LAUNCH_ALL" = true ]; then
    UD_ME_C=$(generate_me_userdata "c" "$SHARD_C_SYMBOLS" "$IP_ME_SHARD_C")
    launch_instance \
        "${PROJECT_PREFIX}-shard-c" \
        "$INSTANCE_TYPE_ME" \
        "$PRIV_SUBNET_ID" \
        "$SG_ME_ID" \
        "$IP_ME_SHARD_C" \
        "$BDM_ME" \
        "$UD_ME_C" \
        "INST_ME_C"
else
    info "Skipping ME Shard C (ASR 1 mode). Use --all for ASR 2."
fi

# 5. Edge Gateway
launch_instance \
    "${PROJECT_PREFIX}-edge-gateway" \
    "$INSTANCE_TYPE_EDGE" \
    "$PRIV_SUBNET_ID" \
    "$SG_EDGE_ID" \
    "$IP_EDGE_GW" \
    "$BDM_STANDARD" \
    "$UD_EDGE" \
    "INST_EDGE"

# 6. Monitoring (Spot, persistent)
launch_spot_instance \
    "${PROJECT_PREFIX}-monitoring" \
    "$INSTANCE_TYPE_MONITORING" \
    "$PRIV_SUBNET_ID" \
    "$SG_MON_ID" \
    "$IP_MONITORING" \
    "$BDM_MONITORING" \
    "$UD_MONITORING" \
    "INST_MONITORING" \
    "persistent"

# 7. k6 Load Generator (Spot, one-time, public subnet)
launch_spot_instance \
    "${PROJECT_PREFIX}-k6-loadgen" \
    "$INSTANCE_TYPE_K6" \
    "$PUB_SUBNET_ID" \
    "$SG_LG_ID" \
    "" \
    "$BDM_STANDARD" \
    "$UD_K6" \
    "INST_K6" \
    "one-time"

# ---------------------------------------------------------------------------
# Wait for instances to reach running state
# ---------------------------------------------------------------------------
header "Waiting for Instances"

ALL_INSTANCES=("$INST_REDPANDA" "$INST_ME_A" "$INST_EDGE" "$INST_MONITORING" "$INST_K6")
ALL_NAMES=("Redpanda" "ME-Shard-A" "Edge-Gateway" "Monitoring" "k6-LoadGen")

if [ "$LAUNCH_ALL" = true ]; then
    if [ -n "${INST_ME_B:-}" ]; then
        ALL_INSTANCES+=("$INST_ME_B")
        ALL_NAMES+=("ME-Shard-B")
    fi
    if [ -n "${INST_ME_C:-}" ]; then
        ALL_INSTANCES+=("$INST_ME_C")
        ALL_NAMES+=("ME-Shard-C")
    fi
fi

for i in "${!ALL_INSTANCES[@]}"; do
    wait_for_instance "${ALL_INSTANCES[$i]}" "${ALL_NAMES[$i]}"
done

# ---------------------------------------------------------------------------
# Get k6 public IP
# ---------------------------------------------------------------------------
info "Retrieving k6 load generator public IP..."
K6_PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INST_K6" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "")
if [ -n "$K6_PUBLIC_IP" ] && [ "$K6_PUBLIC_IP" != "None" ]; then
    persist_var "K6_PUBLIC_IP" "$K6_PUBLIC_IP"
    success "k6 public IP: ${K6_PUBLIC_IP}"
else
    warn "k6 public IP not yet available. Check later with:"
    warn "  aws ec2 describe-instances --instance-ids ${INST_K6} --query 'Reservations[0].Instances[0].PublicIpAddress'"
fi

# ---------------------------------------------------------------------------
# Create NLB
# ---------------------------------------------------------------------------
header "Creating Network Load Balancer"

EXISTING_NLB=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --names "${PROJECT_PREFIX}-nlb" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || echo "None")

if [ "$EXISTING_NLB" != "None" ] && [ -n "$EXISTING_NLB" ]; then
    success "NLB already exists: ${EXISTING_NLB}"
    NLB_ARN="$EXISTING_NLB"
else
    info "Creating NLB '${PROJECT_PREFIX}-nlb'..."
    NLB_ARN=$(aws elbv2 create-load-balancer \
        --region "$AWS_REGION" \
        --name "${PROJECT_PREFIX}-nlb" \
        --type network \
        --subnets "$PUB_SUBNET_ID" \
        --scheme internet-facing \
        --tags "Key=Name,Value=${PROJECT_PREFIX}-nlb" "Key=Project,Value=${PROJECT_PREFIX}" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    success "NLB created: ${NLB_ARN}"
fi
persist_var "NLB_ARN" "$NLB_ARN"

# Create target group
EXISTING_TG=$(aws elbv2 describe-target-groups \
    --region "$AWS_REGION" \
    --names "${PROJECT_PREFIX}-edge-tg" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || echo "None")

if [ "$EXISTING_TG" != "None" ] && [ -n "$EXISTING_TG" ]; then
    success "Target group already exists: ${EXISTING_TG}"
    TG_ARN="$EXISTING_TG"
else
    info "Creating target group..."
    TG_ARN=$(aws elbv2 create-target-group \
        --region "$AWS_REGION" \
        --name "${PROJECT_PREFIX}-edge-tg" \
        --protocol TCP \
        --port "$APP_PORT" \
        --vpc-id "$VPC_ID" \
        --target-type instance \
        --health-check-protocol TCP \
        --health-check-port "$APP_PORT" \
        --health-check-interval-seconds 10 \
        --healthy-threshold-count 3 \
        --tags "Key=Name,Value=${PROJECT_PREFIX}-edge-tg" "Key=Project,Value=${PROJECT_PREFIX}" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)
    success "Target group created: ${TG_ARN}"
fi
persist_var "TG_ARN" "$TG_ARN"

# Register edge instance as target
info "Registering Edge Gateway instance as NLB target..."
aws elbv2 register-targets \
    --region "$AWS_REGION" \
    --target-group-arn "$TG_ARN" \
    --targets "Id=${INST_EDGE},Port=${APP_PORT}" 2>/dev/null || true
success "Edge Gateway registered as target."

# Create listener
EXISTING_LISTENER=$(aws elbv2 describe-listeners \
    --region "$AWS_REGION" \
    --load-balancer-arn "$NLB_ARN" \
    --query 'Listeners[0].ListenerArn' \
    --output text 2>/dev/null || echo "None")

if [ "$EXISTING_LISTENER" != "None" ] && [ -n "$EXISTING_LISTENER" ]; then
    success "Listener already exists: ${EXISTING_LISTENER}"
    LISTENER_ARN="$EXISTING_LISTENER"
else
    info "Creating NLB listener (TCP:${APP_PORT})..."
    LISTENER_ARN=$(aws elbv2 create-listener \
        --region "$AWS_REGION" \
        --load-balancer-arn "$NLB_ARN" \
        --protocol TCP \
        --port "$APP_PORT" \
        --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
        --query 'Listeners[0].ListenerArn' --output text)
    success "Listener created: ${LISTENER_ARN}"
fi
persist_var "LISTENER_ARN" "$LISTENER_ARN"

# Get NLB DNS name
NLB_DNS=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --load-balancer-arns "$NLB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text)
persist_var "NLB_DNS" "$NLB_DNS"
success "NLB DNS: ${NLB_DNS}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Instances and NLB Complete"
echo ""
info "Instances:"
info "  Redpanda:       ${INST_REDPANDA} (${IP_REDPANDA})"
info "  ME Shard A:     ${INST_ME_A} (${IP_ME_SHARD_A})"
if [ "$LAUNCH_ALL" = true ]; then
    info "  ME Shard B:     ${INST_ME_B:-N/A} (${IP_ME_SHARD_B})"
    info "  ME Shard C:     ${INST_ME_C:-N/A} (${IP_ME_SHARD_C})"
fi
info "  Edge Gateway:   ${INST_EDGE} (${IP_EDGE_GW})"
info "  Monitoring:     ${INST_MONITORING} (${IP_MONITORING})"
info "  k6 Load Gen:    ${INST_K6} (public: ${K6_PUBLIC_IP:-pending})"
echo ""
info "NLB:"
info "  ARN:  ${NLB_ARN}"
info "  DNS:  http://${NLB_DNS}:${APP_PORT}"
echo ""
info "Next step: Run 04-setup-software.sh"
