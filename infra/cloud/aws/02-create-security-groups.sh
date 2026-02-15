#!/bin/bash
# =============================================================================
# 02-create-security-groups.sh -- Create all security groups with ingress rules.
#
# Security groups (from the AWS deployment guide):
#   sg-nlb          NLB (TCP 8080 from the world or your IP)
#   sg-edge         Edge Gateway (TCP 8080 from NLB SG; SSH from your IP)
#   sg-me           Matching Engine shards (TCP 8080 from edge, loadgen; 9091 from mon)
#   sg-redpanda     Redpanda (TCP 9092 from ME; 9644 from mon; SSH from your IP)
#   sg-monitoring   Prometheus+Grafana (TCP 9090, 3000, SSH from your IP)
#   sg-loadgen      k6 (SSH from your IP; all outbound to VPC)
#
# Idempotent: checks if each SG exists by group name before creating.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 2: Security Groups"

# Validate that VPC exists
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    error "VPC_ID is not set. Run 01-create-network.sh first."
    exit 1
fi

# Validate that MY_IP is set
if [ -z "$MY_IP" ]; then
    info "MY_IP not set. Detecting public IP..."
    DETECTED_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "")
    if [ -n "$DETECTED_IP" ]; then
        MY_IP="${DETECTED_IP}/32"
        persist_var "MY_IP" "$MY_IP"
        success "Detected public IP: ${MY_IP}"
    else
        error "Could not detect public IP. Set MY_IP in env.sh manually (e.g., 1.2.3.4/32)."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Helper: create a security group if it does not exist
# ---------------------------------------------------------------------------
create_sg() {
    local name="$1"
    local description="$2"
    local var_name="$3"

    local existing
    existing=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

    if [ "$existing" != "None" ] && [ -n "$existing" ]; then
        success "SG '${name}' already exists: ${existing}"
        eval "${var_name}=${existing}"
        persist_var "$var_name" "$existing"
        return
    fi

    info "Creating security group '${name}'..."
    local sg_id
    sg_id=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$name" \
        --description "$description" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'GroupId' --output text)
    success "Created SG '${name}': ${sg_id}"
    eval "${var_name}=${sg_id}"
    persist_var "$var_name" "$sg_id"
}

# ---------------------------------------------------------------------------
# Helper: add an ingress rule (idempotent -- ignores duplicate errors)
# ---------------------------------------------------------------------------
add_ingress_cidr() {
    local sg_id="$1"
    local protocol="$2"
    local port="$3"
    local cidr="$4"
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$sg_id" \
        --protocol "$protocol" \
        --port "$port" \
        --cidr "$cidr" 2>/dev/null || true
}

add_ingress_sg() {
    local sg_id="$1"
    local protocol="$2"
    local port="$3"
    local source_sg="$4"
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$sg_id" \
        --protocol "$protocol" \
        --port "$port" \
        --source-group "$source_sg" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Create all security groups
# ---------------------------------------------------------------------------
create_sg "${PROJECT_PREFIX}-sg-nlb"      "NLB security group"                "SG_NLB_ID"
create_sg "${PROJECT_PREFIX}-sg-edge"     "API Gateway + Order Gateway"       "SG_EDGE_ID"
create_sg "${PROJECT_PREFIX}-sg-me"       "Matching Engine shards"            "SG_ME_ID"
create_sg "${PROJECT_PREFIX}-sg-redpanda" "Redpanda broker"                   "SG_RP_ID"
create_sg "${PROJECT_PREFIX}-sg-monitoring" "Prometheus + Grafana"            "SG_MON_ID"
create_sg "${PROJECT_PREFIX}-sg-loadgen"  "k6 load generator"                "SG_LG_ID"

# ---------------------------------------------------------------------------
# 2. NLB rules: TCP 8080 from the world (or restrict to your IP)
# ---------------------------------------------------------------------------
info "Configuring NLB security group rules..."
add_ingress_cidr "$SG_NLB_ID" "tcp" "8080" "0.0.0.0/0"
success "SG NLB: TCP 8080 from 0.0.0.0/0"

# ---------------------------------------------------------------------------
# 3. Edge Gateway rules
# ---------------------------------------------------------------------------
info "Configuring Edge Gateway security group rules..."
add_ingress_cidr "$SG_EDGE_ID" "tcp" "22"   "$MY_IP"
add_ingress_cidr "$SG_EDGE_ID" "tcp" "8080" "$VPC_CIDR"
add_ingress_cidr "$SG_EDGE_ID" "tcp" "9091" "${PRIVATE_SUBNET_CIDR}"
success "SG Edge: TCP 22 from ${MY_IP}; TCP 8080 from VPC; TCP 9091 from private subnet"

# ---------------------------------------------------------------------------
# 4. Matching Engine rules
# ---------------------------------------------------------------------------
info "Configuring Matching Engine security group rules..."
add_ingress_sg   "$SG_ME_ID" "tcp" "8080" "$SG_EDGE_ID"
add_ingress_sg   "$SG_ME_ID" "tcp" "8080" "$SG_LG_ID"
add_ingress_sg   "$SG_ME_ID" "tcp" "9091" "$SG_MON_ID"
add_ingress_cidr "$SG_ME_ID" "tcp" "22"   "$MY_IP"
success "SG ME: TCP 8080 from edge,loadgen; TCP 9091 from monitoring; SSH from ${MY_IP}"

# ---------------------------------------------------------------------------
# 5. Redpanda rules
# ---------------------------------------------------------------------------
info "Configuring Redpanda security group rules..."
add_ingress_sg   "$SG_RP_ID" "tcp" "9092" "$SG_ME_ID"
add_ingress_sg   "$SG_RP_ID" "tcp" "9092" "$SG_EDGE_ID"
add_ingress_sg   "$SG_RP_ID" "tcp" "9644" "$SG_MON_ID"
add_ingress_cidr "$SG_RP_ID" "tcp" "22"   "$MY_IP"
success "SG Redpanda: TCP 9092 from ME,Edge; TCP 9644 from monitoring; SSH from ${MY_IP}"

# ---------------------------------------------------------------------------
# 6. Monitoring rules
# ---------------------------------------------------------------------------
info "Configuring Monitoring security group rules..."
add_ingress_cidr "$SG_MON_ID" "tcp" "9090" "$MY_IP"
add_ingress_cidr "$SG_MON_ID" "tcp" "3000" "$MY_IP"
add_ingress_cidr "$SG_MON_ID" "tcp" "22"   "$MY_IP"
# Also allow monitoring to reach itself (Prometheus -> Grafana datasource)
add_ingress_cidr "$SG_MON_ID" "tcp" "9090" "${PRIVATE_SUBNET_CIDR}"
add_ingress_cidr "$SG_MON_ID" "tcp" "3000" "${PRIVATE_SUBNET_CIDR}"
success "SG Monitoring: TCP 9090,3000 from ${MY_IP}; SSH from ${MY_IP}"

# ---------------------------------------------------------------------------
# 7. Load Generator rules
# ---------------------------------------------------------------------------
info "Configuring Load Generator security group rules..."
add_ingress_cidr "$SG_LG_ID" "tcp" "22" "$MY_IP"
success "SG LoadGen: SSH from ${MY_IP}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Security Groups Complete"
echo ""
info "SG NLB:        ${SG_NLB_ID}"
info "SG Edge:       ${SG_EDGE_ID}"
info "SG ME:         ${SG_ME_ID}"
info "SG Redpanda:   ${SG_RP_ID}"
info "SG Monitoring: ${SG_MON_ID}"
info "SG LoadGen:    ${SG_LG_ID}"
echo ""
info "Next step: Run 03-launch-instances.sh"
