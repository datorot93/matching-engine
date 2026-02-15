#!/bin/bash
# =============================================================================
# env.sh -- Shared environment variables for OCI Matching Engine deployment
#
# This file is sourced by all other scripts. It stores:
#   1. Configuration constants (region, shapes, CIDR blocks)
#   2. Resource OCIDs (populated by create scripts, persisted to env.state)
#   3. IP addresses (populated after instance launch)
#   4. Helper functions for colored output and SSH
#
# Usage: source env.sh
# =============================================================================

# ---------------------------------------------------------------------------
# State file: persists OCIDs between script invocations
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/env.state"

# ---------------------------------------------------------------------------
# OCI Configuration
# ---------------------------------------------------------------------------
OCI_REGION="${OCI_REGION:-us-ashburn-1}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"

# Compartment ID -- override via environment or set in env.state
COMPARTMENT_ID="${COMPARTMENT_ID:-}"

# ---------------------------------------------------------------------------
# SSH Key
# ---------------------------------------------------------------------------
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/oci-me-experiment}"
SSH_KEY_PUB="${SSH_KEY_PATH}.pub"
SSH_USER="opc"

# ---------------------------------------------------------------------------
# Resource Display Names (used for idempotent lookups)
# ---------------------------------------------------------------------------
VCN_NAME="matching-engine-exp-vcn"
IGW_NAME="me-igw"
NAT_NAME="me-nat"
PUBLIC_RT_NAME="me-public-rt"
PRIVATE_RT_NAME="me-private-rt"
PUBLIC_SL_NAME="me-public-sl"
PRIVATE_SL_NAME="me-private-sl"
PUBLIC_SUBNET_NAME="me-public-subnet"
PRIVATE_SUBNET_NAME="me-private-subnet"
LB_NAME="me-experiment-lb"

# ---------------------------------------------------------------------------
# Networking Constants
# ---------------------------------------------------------------------------
VCN_CIDR="10.0.0.0/16"
VCN_DNS_LABEL="mevcn"
PUBLIC_SUBNET_CIDR="10.0.0.0/24"
PUBLIC_SUBNET_DNS="pubsub"
PRIVATE_SUBNET_CIDR="10.0.1.0/24"
PRIVATE_SUBNET_DNS="privsub"

# ---------------------------------------------------------------------------
# Instance Configuration
# ---------------------------------------------------------------------------
# Shapes
A1_SHAPE="VM.Standard.A1.Flex"
MICRO_SHAPE="VM.Standard.E2.1.Micro"

# Instance display names
BASTION_NAME="me-bastion"
ME_SHARD_A_NAME="me-shard-a"
ME_SHARD_B_NAME="me-shard-b"
ME_SHARD_C_NAME="me-shard-c"
EDGE_NAME="edge-and-tools"

# A1 shape config (OCPUs and RAM in GB)
A1_OCPUS=1
A1_MEMORY_GB=6

# Boot volume sizes (total must be <= 200 GB)
BASTION_BOOT_GB=30
ME_SHARD_A_BOOT_GB=30
ME_SHARD_B_BOOT_GB=30
ME_SHARD_C_BOOT_GB=40
EDGE_BOOT_GB=40
# Spare micro = 30 GB (not created in this automation)
# Total: 30 + 30 + 30 + 40 + 40 = 170 GB (30 GB reserved for spare micro)

# ---------------------------------------------------------------------------
# Application Configuration
# ---------------------------------------------------------------------------
ME_APP_PORT=8080
ME_METRICS_PORT=9091
GW_APP_PORT=8080
GW_METRICS_PORT=9091
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
REDPANDA_KAFKA_PORT=9092

# Shard symbol assignments
SHARD_A_SYMBOLS="TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D"
SHARD_B_SYMBOLS="TEST-ASSET-E,TEST-ASSET-F,TEST-ASSET-G,TEST-ASSET-H"
SHARD_C_SYMBOLS="TEST-ASSET-I,TEST-ASSET-J,TEST-ASSET-K,TEST-ASSET-L"

# JVM settings
ME_JVM_OPTS="-XX:+UseZGC -Xms512m -Xmx1g -XX:+AlwaysPreTouch"
GW_JVM_OPTS="-XX:+UseZGC -Xms128m -Xmx256m"

# Prometheus version
PROM_VERSION="2.51.0"

# ---------------------------------------------------------------------------
# Resource OCIDs (loaded from state file if it exists)
# ---------------------------------------------------------------------------
VCN_ID="${VCN_ID:-}"
IGW_ID="${IGW_ID:-}"
NAT_ID="${NAT_ID:-}"
PUBLIC_RT_ID="${PUBLIC_RT_ID:-}"
PRIVATE_RT_ID="${PRIVATE_RT_ID:-}"
PUBLIC_SL_ID="${PUBLIC_SL_ID:-}"
PRIVATE_SL_ID="${PRIVATE_SL_ID:-}"
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID:-}"
PRIVATE_SUBNET_ID="${PRIVATE_SUBNET_ID:-}"
AD="${AD:-}"
ARM64_IMAGE_ID="${ARM64_IMAGE_ID:-}"
X86_IMAGE_ID="${X86_IMAGE_ID:-}"
BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
ME_SHARD_A_INSTANCE_ID="${ME_SHARD_A_INSTANCE_ID:-}"
ME_SHARD_B_INSTANCE_ID="${ME_SHARD_B_INSTANCE_ID:-}"
ME_SHARD_C_INSTANCE_ID="${ME_SHARD_C_INSTANCE_ID:-}"
EDGE_INSTANCE_ID="${EDGE_INSTANCE_ID:-}"
LB_ID="${LB_ID:-}"

# ---------------------------------------------------------------------------
# IP Addresses (loaded from state file)
# ---------------------------------------------------------------------------
BASTION_PUBLIC_IP="${BASTION_PUBLIC_IP:-}"
ME_SHARD_A_PRIVATE_IP="${ME_SHARD_A_PRIVATE_IP:-}"
ME_SHARD_B_PRIVATE_IP="${ME_SHARD_B_PRIVATE_IP:-}"
ME_SHARD_C_PRIVATE_IP="${ME_SHARD_C_PRIVATE_IP:-}"
EDGE_PRIVATE_IP="${EDGE_PRIVATE_IP:-}"
LB_PUBLIC_IP="${LB_PUBLIC_IP:-}"

# ---------------------------------------------------------------------------
# Load state file if it exists (overrides defaults above)
# ---------------------------------------------------------------------------
load_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Save a variable to state file (append or update)
# ---------------------------------------------------------------------------
save_state() {
    local var_name="$1"
    local var_value="$2"

    # Export so child shells can access it
    export "${var_name}=${var_value}"

    # Create state file if it does not exist
    touch "${STATE_FILE}"

    # Remove existing entry for this variable, then append
    if grep -q "^${var_name}=" "${STATE_FILE}" 2>/dev/null; then
        # Use a temp file for portable sed -i behavior
        local tmp_file
        tmp_file=$(mktemp)
        grep -v "^${var_name}=" "${STATE_FILE}" > "${tmp_file}" || true
        mv "${tmp_file}" "${STATE_FILE}"
    fi
    echo "${var_name}=\"${var_value}\"" >> "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Colored output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "${CYAN}${BOLD}>>> $*${NC}"; }
banner()  {
    echo ""
    echo -e "${BOLD}=========================================${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}=========================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------

# Execute a command on a private instance via bastion jump host
ssh_via_bastion() {
    local target_ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY_PATH}" \
        -J "${SSH_USER}@${BASTION_PUBLIC_IP}" \
        "${SSH_USER}@${target_ip}" \
        "$@"
}

# SCP a file to a private instance via bastion
scp_via_bastion() {
    local local_path="$1"
    local target_ip="$2"
    local remote_path="$3"
    scp -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY_PATH}" \
        -J "${SSH_USER}@${BASTION_PUBLIC_IP}" \
        "${local_path}" \
        "${SSH_USER}@${target_ip}:${remote_path}"
}

# ---------------------------------------------------------------------------
# OCI CLI helper -- wait for a resource to reach a lifecycle state
# ---------------------------------------------------------------------------
wait_for_instance() {
    local instance_id="$1"
    local target_state="${2:-RUNNING}"
    local max_wait="${3:-600}"

    info "Waiting for instance ${instance_id} to reach ${target_state} (max ${max_wait}s)..."
    oci compute instance get \
        --instance-id "${instance_id}" \
        --wait-for-state "${target_state}" \
        --max-wait-seconds "${max_wait}" \
        > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Idempotent resource lookup: find existing resource by display name
# Returns OCID or empty string
# ---------------------------------------------------------------------------
find_vcn() {
    oci network vcn list \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${VCN_NAME}" \
        --lifecycle-state AVAILABLE \
        --query "data[0].id" --raw-output 2>/dev/null || echo ""
}

find_instance() {
    local display_name="$1"
    oci compute instance list \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${display_name}" \
        --lifecycle-state RUNNING \
        --query "data[0].id" --raw-output 2>/dev/null || echo ""
}

find_lb() {
    oci lb load-balancer list \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${LB_NAME}" \
        --lifecycle-state ACTIVE \
        --query "data[0].id" --raw-output 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Load state on source
# ---------------------------------------------------------------------------
load_state
