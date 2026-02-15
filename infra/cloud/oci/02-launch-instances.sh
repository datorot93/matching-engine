#!/bin/bash
# =============================================================================
# 02-launch-instances.sh -- Launch all compute instances for the ME experiment
#
# Creates 5 instances:
#   - bastion:        VM.Standard.E2.1.Micro, public subnet, public IP, 30 GB
#   - me-shard-a:     VM.Standard.A1.Flex (1 OCPU, 6 GB), private subnet, 30 GB
#   - me-shard-b:     VM.Standard.A1.Flex (1 OCPU, 6 GB), private subnet, 30 GB
#   - me-shard-c:     VM.Standard.A1.Flex (1 OCPU, 6 GB), private subnet, 40 GB
#   - edge-and-tools: VM.Standard.A1.Flex (1 OCPU, 6 GB), private subnet, 40 GB
#
# Idempotent: uses find_instance() before creating.
#
# Usage: ./02-launch-instances.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

banner "Phase 2: Launch Compute Instances"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ -z "${COMPARTMENT_ID}" ]]; then
    error "COMPARTMENT_ID not set. Run 00-prerequisites.sh first."
    exit 1
fi

if [[ -z "${PUBLIC_SUBNET_ID}" || -z "${PRIVATE_SUBNET_ID}" ]]; then
    error "Subnet IDs not set. Run 01-create-network.sh first."
    exit 1
fi

if [[ -z "${AD}" ]]; then
    error "Availability domain (AD) not set. Run 00-prerequisites.sh first."
    exit 1
fi

if [[ -z "${ARM64_IMAGE_ID}" || -z "${X86_IMAGE_ID}" ]]; then
    error "Image IDs not set. Run 00-prerequisites.sh first."
    exit 1
fi

if [[ ! -f "${SSH_KEY_PUB}" ]]; then
    error "SSH public key not found at ${SSH_KEY_PUB}. Run 00-prerequisites.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: launch an instance (idempotent)
# ---------------------------------------------------------------------------
launch_instance() {
    local display_name="$1"
    local shape="$2"
    local image_id="$3"
    local subnet_id="$4"
    local assign_public_ip="$5"
    local boot_volume_gb="$6"
    local shape_config="${7:-}"  # JSON string, empty for non-Flex shapes

    # Check if already exists
    local existing_id
    existing_id=$(find_instance "${display_name}")
    if [[ -n "${existing_id}" && "${existing_id}" != "None" ]]; then
        info "Instance '${display_name}' already exists: ${existing_id}"
        echo "${existing_id}"
        return 0
    fi

    info "Launching instance '${display_name}' (${shape}, ${boot_volume_gb} GB boot)..."

    local launch_cmd=(
        oci compute instance launch
        --compartment-id "${COMPARTMENT_ID}"
        --availability-domain "${AD}"
        --display-name "${display_name}"
        --shape "${shape}"
        --image-id "${image_id}"
        --subnet-id "${subnet_id}"
        --assign-public-ip "${assign_public_ip}"
        --boot-volume-size-in-gbs "${boot_volume_gb}"
        --ssh-authorized-keys-file "${SSH_KEY_PUB}"
        --query "data.id" --raw-output
        --wait-for-state RUNNING
        --max-wait-seconds 900
    )

    # Add shape-config for Flex shapes
    if [[ -n "${shape_config}" ]]; then
        launch_cmd+=(--shape-config "${shape_config}")
    fi

    local instance_id
    instance_id=$("${launch_cmd[@]}")

    if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
        error "Failed to launch instance '${display_name}'"
        error "Hint: If you see 'Out of Host Capacity', retry at off-peak hours or try another region."
        exit 1
    fi

    success "Instance '${display_name}' launched: ${instance_id}"
    echo "${instance_id}"
}

# ---------------------------------------------------------------------------
# Helper: get an IP address from instance VNIC
# ---------------------------------------------------------------------------
get_private_ip() {
    local instance_id="$1"
    oci compute instance list-vnics \
        --instance-id "${instance_id}" \
        --query "data[0].\"private-ip\"" --raw-output 2>/dev/null || echo ""
}

get_public_ip() {
    local instance_id="$1"
    oci compute instance list-vnics \
        --instance-id "${instance_id}" \
        --query "data[0].\"public-ip\"" --raw-output 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# A1 Flex shape configuration
# ---------------------------------------------------------------------------
A1_SHAPE_CONFIG="{\"ocpus\":${A1_OCPUS},\"memoryInGBs\":${A1_MEMORY_GB}}"

# ===== 1. Bastion (Micro, public subnet, public IP) =====
step "Launching bastion: ${BASTION_NAME}"
BASTION_INSTANCE_ID=$(launch_instance \
    "${BASTION_NAME}" \
    "${MICRO_SHAPE}" \
    "${X86_IMAGE_ID}" \
    "${PUBLIC_SUBNET_ID}" \
    "true" \
    "${BASTION_BOOT_GB}" \
    "")
save_state "BASTION_INSTANCE_ID" "${BASTION_INSTANCE_ID}"

# ===== 2. ME Shard A (A1.Flex, private subnet) =====
step "Launching ME Shard A: ${ME_SHARD_A_NAME}"
ME_SHARD_A_INSTANCE_ID=$(launch_instance \
    "${ME_SHARD_A_NAME}" \
    "${A1_SHAPE}" \
    "${ARM64_IMAGE_ID}" \
    "${PRIVATE_SUBNET_ID}" \
    "false" \
    "${ME_SHARD_A_BOOT_GB}" \
    "${A1_SHAPE_CONFIG}")
save_state "ME_SHARD_A_INSTANCE_ID" "${ME_SHARD_A_INSTANCE_ID}"

# ===== 3. ME Shard B (A1.Flex, private subnet) =====
step "Launching ME Shard B: ${ME_SHARD_B_NAME}"
ME_SHARD_B_INSTANCE_ID=$(launch_instance \
    "${ME_SHARD_B_NAME}" \
    "${A1_SHAPE}" \
    "${ARM64_IMAGE_ID}" \
    "${PRIVATE_SUBNET_ID}" \
    "false" \
    "${ME_SHARD_B_BOOT_GB}" \
    "${A1_SHAPE_CONFIG}")
save_state "ME_SHARD_B_INSTANCE_ID" "${ME_SHARD_B_INSTANCE_ID}"

# ===== 4. ME Shard C + Redpanda (A1.Flex, private subnet, 40 GB) =====
step "Launching ME Shard C + Redpanda: ${ME_SHARD_C_NAME}"
ME_SHARD_C_INSTANCE_ID=$(launch_instance \
    "${ME_SHARD_C_NAME}" \
    "${A1_SHAPE}" \
    "${ARM64_IMAGE_ID}" \
    "${PRIVATE_SUBNET_ID}" \
    "false" \
    "${ME_SHARD_C_BOOT_GB}" \
    "${A1_SHAPE_CONFIG}")
save_state "ME_SHARD_C_INSTANCE_ID" "${ME_SHARD_C_INSTANCE_ID}"

# ===== 5. Edge + Tools (A1.Flex, private subnet, 40 GB) =====
step "Launching Edge + Tools: ${EDGE_NAME}"
EDGE_INSTANCE_ID=$(launch_instance \
    "${EDGE_NAME}" \
    "${A1_SHAPE}" \
    "${ARM64_IMAGE_ID}" \
    "${PRIVATE_SUBNET_ID}" \
    "false" \
    "${EDGE_BOOT_GB}" \
    "${A1_SHAPE_CONFIG}")
save_state "EDGE_INSTANCE_ID" "${EDGE_INSTANCE_ID}"

# ---------------------------------------------------------------------------
# Retrieve and save IP addresses
# ---------------------------------------------------------------------------
step "Retrieving IP addresses"

BASTION_PUBLIC_IP=$(get_public_ip "${BASTION_INSTANCE_ID}")
if [[ -z "${BASTION_PUBLIC_IP}" || "${BASTION_PUBLIC_IP}" == "None" ]]; then
    error "Could not retrieve bastion public IP"
    exit 1
fi
save_state "BASTION_PUBLIC_IP" "${BASTION_PUBLIC_IP}"
success "Bastion public IP: ${BASTION_PUBLIC_IP}"

ME_SHARD_A_PRIVATE_IP=$(get_private_ip "${ME_SHARD_A_INSTANCE_ID}")
save_state "ME_SHARD_A_PRIVATE_IP" "${ME_SHARD_A_PRIVATE_IP}"
success "ME Shard A private IP: ${ME_SHARD_A_PRIVATE_IP}"

ME_SHARD_B_PRIVATE_IP=$(get_private_ip "${ME_SHARD_B_INSTANCE_ID}")
save_state "ME_SHARD_B_PRIVATE_IP" "${ME_SHARD_B_PRIVATE_IP}"
success "ME Shard B private IP: ${ME_SHARD_B_PRIVATE_IP}"

ME_SHARD_C_PRIVATE_IP=$(get_private_ip "${ME_SHARD_C_INSTANCE_ID}")
save_state "ME_SHARD_C_PRIVATE_IP" "${ME_SHARD_C_PRIVATE_IP}"
success "ME Shard C private IP: ${ME_SHARD_C_PRIVATE_IP}"

EDGE_PRIVATE_IP=$(get_private_ip "${EDGE_INSTANCE_ID}")
save_state "EDGE_PRIVATE_IP" "${EDGE_PRIVATE_IP}"
success "Edge + Tools private IP: ${EDGE_PRIVATE_IP}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "All instances launched"
echo "  Instance           | OCID (last 8)            | IP"
echo "  -------------------|--------------------------|-------------------"
echo "  bastion            | ...${BASTION_INSTANCE_ID: -8} | ${BASTION_PUBLIC_IP} (public)"
echo "  me-shard-a         | ...${ME_SHARD_A_INSTANCE_ID: -8} | ${ME_SHARD_A_PRIVATE_IP}"
echo "  me-shard-b         | ...${ME_SHARD_B_INSTANCE_ID: -8} | ${ME_SHARD_B_PRIVATE_IP}"
echo "  me-shard-c         | ...${ME_SHARD_C_INSTANCE_ID: -8} | ${ME_SHARD_C_PRIVATE_IP}"
echo "  edge-and-tools     | ...${EDGE_INSTANCE_ID: -8} | ${EDGE_PRIVATE_IP}"
echo ""
echo "  A1 OCPUs used: 4/4    A1 RAM used: 24/24 GB"
echo "  Boot storage:  ${BASTION_BOOT_GB}+${ME_SHARD_A_BOOT_GB}+${ME_SHARD_B_BOOT_GB}+${ME_SHARD_C_BOOT_GB}+${EDGE_BOOT_GB} = 170 GB / 200 GB"
echo ""
info "SSH to bastion: ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${BASTION_PUBLIC_IP}"
info "SSH to private: ssh -i ${SSH_KEY_PATH} -J ${SSH_USER}@${BASTION_PUBLIC_IP} ${SSH_USER}@<PRIVATE_IP>"
echo ""
info "All OCIDs and IPs saved to ${STATE_FILE}"
info "Run 03-setup-software.sh next."
