#!/bin/bash
# =============================================================================
# env.sh -- Shared environment variables for all AWS deployment scripts.
#
# This file is sourced by every script in this directory. It stores:
#   1. Static configuration (region, CIDR blocks, instance types, etc.)
#   2. Dynamic resource IDs populated by each script after creation.
#
# After a script creates a resource (VPC, subnet, instance, etc.), it writes
# the resource ID back into this file using persist_var(). Subsequent scripts
# source this file to pick up those IDs without requiring a single shell session.
# =============================================================================

# ---------------------------------------------------------------------------
# Region and AZ
# ---------------------------------------------------------------------------
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AZ="${AZ:-us-east-1a}"

# ---------------------------------------------------------------------------
# Naming prefix (all AWS resources are tagged with this for easy identification)
# ---------------------------------------------------------------------------
export PROJECT_PREFIX="me-experiment"

# ---------------------------------------------------------------------------
# SSH key pair
# ---------------------------------------------------------------------------
export KEY_NAME="${PROJECT_PREFIX}-key"
export KEY_FILE="${HOME}/.ssh/${KEY_NAME}.pem"

# ---------------------------------------------------------------------------
# Network CIDRs
# ---------------------------------------------------------------------------
export VPC_CIDR="10.0.0.0/16"
export PUBLIC_SUBNET_CIDR="10.0.1.0/24"
export PRIVATE_SUBNET_CIDR="10.0.2.0/24"

# ---------------------------------------------------------------------------
# Static private IPs (must be within PRIVATE_SUBNET_CIDR)
# ---------------------------------------------------------------------------
export IP_REDPANDA="10.0.2.10"
export IP_ME_SHARD_A="10.0.2.20"
export IP_ME_SHARD_B="10.0.2.21"
export IP_ME_SHARD_C="10.0.2.22"
export IP_EDGE_GW="10.0.2.30"
export IP_MONITORING="10.0.2.40"

# ---------------------------------------------------------------------------
# Instance types
# ---------------------------------------------------------------------------
export INSTANCE_TYPE_ME="c7g.medium"
export INSTANCE_TYPE_EDGE="c7g.medium"
export INSTANCE_TYPE_REDPANDA="c7g.medium"
export INSTANCE_TYPE_MONITORING="t4g.small"
export INSTANCE_TYPE_K6="c7g.large"

# ---------------------------------------------------------------------------
# Docker images (matching local k3d deployment naming)
# ---------------------------------------------------------------------------
export ME_IMAGE="matching-engine:experiment-v1"
export EDGE_IMAGE="edge-gateway:experiment-v1"

# ---------------------------------------------------------------------------
# Shard symbol assignments (must match k6 config.js)
# ---------------------------------------------------------------------------
export SHARD_A_SYMBOLS="TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D"
export SHARD_B_SYMBOLS="TEST-ASSET-E,TEST-ASSET-F,TEST-ASSET-G,TEST-ASSET-H"
export SHARD_C_SYMBOLS="TEST-ASSET-I,TEST-ASSET-J,TEST-ASSET-K,TEST-ASSET-L"

# ---------------------------------------------------------------------------
# Application ports
# ---------------------------------------------------------------------------
export APP_PORT=8080
export METRICS_PORT=9091
export KAFKA_PORT=9092
export REDPANDA_ADMIN_PORT=9644
export PROMETHEUS_PORT=9090
export GRAFANA_PORT=3000

# ---------------------------------------------------------------------------
# Java opts for ME (AWS c7g.medium has 2 GiB RAM; Docker gets ~1.5 GiB)
# ---------------------------------------------------------------------------
export ME_JAVA_OPTS="-XX:+UseZGC -Xms512m -Xmx1g -XX:+AlwaysPreTouch"
export EDGE_JAVA_OPTS="-Xms128m -Xmx256m"

# ---------------------------------------------------------------------------
# Dynamic resource IDs -- populated by scripts at runtime.
# Each script calls persist_var() to write values here.
# ---------------------------------------------------------------------------
export AMI_ID="${AMI_ID:-}"
export VPC_ID="${VPC_ID:-}"
export IGW_ID="${IGW_ID:-}"
export PUB_SUBNET_ID="${PUB_SUBNET_ID:-}"
export PRIV_SUBNET_ID="${PRIV_SUBNET_ID:-}"
export PUB_RT_ID="${PUB_RT_ID:-}"
export SG_NLB_ID="${SG_NLB_ID:-}"
export SG_EDGE_ID="${SG_EDGE_ID:-}"
export SG_ME_ID="${SG_ME_ID:-}"
export SG_RP_ID="${SG_RP_ID:-}"
export SG_MON_ID="${SG_MON_ID:-}"
export SG_LG_ID="${SG_LG_ID:-}"
export INST_REDPANDA="${INST_REDPANDA:-}"
export INST_ME_A="${INST_ME_A:-}"
export INST_ME_B="${INST_ME_B:-}"
export INST_ME_C="${INST_ME_C:-}"
export INST_EDGE="${INST_EDGE:-}"
export INST_MONITORING="${INST_MONITORING:-}"
export INST_K6="${INST_K6:-}"
export K6_PUBLIC_IP="${K6_PUBLIC_IP:-}"
export NLB_ARN="${NLB_ARN:-}"
export TG_ARN="${TG_ARN:-}"
export LISTENER_ARN="${LISTENER_ARN:-}"
export NLB_DNS="${NLB_DNS:-}"
export MY_IP="${MY_IP:-}"
export NAT_GW_ID="${NAT_GW_ID:-}"
export NAT_EIP_ALLOC_ID="${NAT_EIP_ALLOC_ID:-}"
export PRIV_RT_ID="${PRIV_RT_ID:-}"

# ---------------------------------------------------------------------------
# Helper: persist a variable back to this file so subsequent scripts see it.
# Usage:  persist_var "VPC_ID" "vpc-0abcdef123456"
# ---------------------------------------------------------------------------
persist_var() {
    local var_name="$1"
    local var_value="$2"
    local env_file
    env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

    # Export immediately in the current shell
    export "${var_name}=${var_value}"

    # Replace the default empty value in the file with the real value.
    # Match: export VAR_NAME="${VAR_NAME:-}" or export VAR_NAME="${VAR_NAME:-old_value}"
    if grep -q "^export ${var_name}=" "$env_file"; then
        sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${var_value}\"|" "$env_file"
    else
        echo "export ${var_name}=\"${var_value}\"" >> "$env_file"
    fi
}

# ---------------------------------------------------------------------------
# Helper: colored output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${CYAN}============================================${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}============================================${NC}"; }

# ---------------------------------------------------------------------------
# Helper: wait for an EC2 instance to reach "running" state
# ---------------------------------------------------------------------------
wait_for_instance() {
    local instance_id="$1"
    local name="${2:-instance}"
    info "Waiting for ${name} (${instance_id}) to reach 'running' state..."
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$AWS_REGION"
    success "${name} is running."
}

# ---------------------------------------------------------------------------
# Helper: wait for instance status checks to pass (2/2 checks)
# ---------------------------------------------------------------------------
wait_for_status_ok() {
    local instance_id="$1"
    local name="${2:-instance}"
    info "Waiting for ${name} (${instance_id}) status checks to pass..."
    aws ec2 wait instance-status-ok --instance-ids "$instance_id" --region "$AWS_REGION"
    success "${name} status checks passed."
}

# ---------------------------------------------------------------------------
# Helper: SSH command builder
# ---------------------------------------------------------------------------
ssh_cmd() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -i "$KEY_FILE" "ec2-user@${ip}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: SCP file to instance
# ---------------------------------------------------------------------------
scp_to() {
    local ip="$1"
    local src="$2"
    local dst="$3"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$KEY_FILE" "$src" "ec2-user@${ip}:${dst}"
}
