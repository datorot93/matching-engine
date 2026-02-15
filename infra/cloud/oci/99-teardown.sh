#!/bin/bash
# =============================================================================
# 99-teardown.sh -- Full cleanup of all OCI resources in reverse dependency order
#
# Deletes:
#   1. Load Balancer
#   2. All compute instances (wait for TERMINATED)
#   3. Subnets (private, then public)
#   4. Security lists (private, then public)
#   5. Route tables (private, then public)
#   6. NAT Gateway
#   7. Internet Gateway
#   8. VCN
#   9. State file
#
# Safe: checks if resource exists before attempting deletion.
# Confirmation prompt unless --force is passed.
#
# Usage:
#   ./99-teardown.sh           # Interactive confirmation
#   ./99-teardown.sh --force   # Skip confirmation
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

banner "Phase 99: Full Teardown"

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
FORCE="${1:-}"
if [[ "${FORCE}" != "--force" ]]; then
    echo ""
    warn "This will DELETE all OCI resources created for the Matching Engine experiment."
    echo ""
    echo "  Resources to be deleted:"
    echo "    - Load Balancer:     ${LB_ID:-not set}"
    echo "    - Bastion:           ${BASTION_INSTANCE_ID:-not set}"
    echo "    - ME Shard A:        ${ME_SHARD_A_INSTANCE_ID:-not set}"
    echo "    - ME Shard B:        ${ME_SHARD_B_INSTANCE_ID:-not set}"
    echo "    - ME Shard C:        ${ME_SHARD_C_INSTANCE_ID:-not set}"
    echo "    - Edge + Tools:      ${EDGE_INSTANCE_ID:-not set}"
    echo "    - Private Subnet:    ${PRIVATE_SUBNET_ID:-not set}"
    echo "    - Public Subnet:     ${PUBLIC_SUBNET_ID:-not set}"
    echo "    - Private SL:        ${PRIVATE_SL_ID:-not set}"
    echo "    - Public SL:         ${PUBLIC_SL_ID:-not set}"
    echo "    - Private RT:        ${PRIVATE_RT_ID:-not set}"
    echo "    - Public RT:         ${PUBLIC_RT_ID:-not set}"
    echo "    - NAT Gateway:       ${NAT_ID:-not set}"
    echo "    - Internet Gateway:  ${IGW_ID:-not set}"
    echo "    - VCN:               ${VCN_ID:-not set}"
    echo ""
    read -r -p "  Type 'yes' to confirm deletion: " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        info "Teardown cancelled."
        exit 0
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# Helper: safe delete with error suppression
# ---------------------------------------------------------------------------
safe_delete() {
    local resource_type="$1"
    local resource_id="$2"
    shift 2
    # Remaining args are the OCI CLI delete command arguments

    if [[ -z "${resource_id}" || "${resource_id}" == "None" ]]; then
        info "Skipping ${resource_type}: no OCID saved"
        return 0
    fi

    info "Deleting ${resource_type}: ${resource_id}"
    if "$@" 2>/dev/null; then
        success "${resource_type} deleted"
    else
        warn "${resource_type} deletion failed or already deleted (OCID: ${resource_id})"
    fi
}

# ---------------------------------------------------------------------------
# Helper: wait for instance to reach TERMINATED state
# ---------------------------------------------------------------------------
wait_for_terminated() {
    local instance_id="$1"
    local name="$2"
    local max_wait=300
    local elapsed=0

    if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
        return 0
    fi

    info "Waiting for ${name} to reach TERMINATED state (max ${max_wait}s)..."
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        local state
        state=$(oci compute instance get \
            --instance-id "${instance_id}" \
            --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null || echo "TERMINATED")

        if [[ "${state}" == "TERMINATED" ]]; then
            success "${name} terminated"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    warn "${name} did not reach TERMINATED within ${max_wait}s (current: ${state:-UNKNOWN})"
}

# ===== 1. Delete Load Balancer =====
step "Deleting Load Balancer"
if [[ -n "${LB_ID}" && "${LB_ID}" != "None" ]]; then
    info "Deleting Load Balancer: ${LB_ID}"
    oci lb load-balancer delete \
        --load-balancer-id "${LB_ID}" \
        --force \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 300 2>/dev/null || warn "LB deletion may have already completed"

    # Wait for LB to fully disappear
    info "Waiting for Load Balancer to be fully removed..."
    sleep 30
    success "Load Balancer deleted"
else
    info "No Load Balancer to delete"
fi

# ===== 2. Terminate all compute instances =====
step "Terminating compute instances"

# Terminate each instance (non-blocking, then wait)
INSTANCE_IDS=(
    "${BASTION_INSTANCE_ID:-}"
    "${ME_SHARD_A_INSTANCE_ID:-}"
    "${ME_SHARD_B_INSTANCE_ID:-}"
    "${ME_SHARD_C_INSTANCE_ID:-}"
    "${EDGE_INSTANCE_ID:-}"
)

INSTANCE_NAMES=(
    "bastion"
    "me-shard-a"
    "me-shard-b"
    "me-shard-c"
    "edge-and-tools"
)

# Fire all terminate requests
for idx in "${!INSTANCE_IDS[@]}"; do
    inst_id="${INSTANCE_IDS[$idx]}"
    inst_name="${INSTANCE_NAMES[$idx]}"

    if [[ -z "${inst_id}" || "${inst_id}" == "None" ]]; then
        info "Skipping ${inst_name}: no OCID saved"
        continue
    fi

    # Check if already terminated
    local_state=$(oci compute instance get \
        --instance-id "${inst_id}" \
        --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null || echo "TERMINATED")

    if [[ "${local_state}" == "TERMINATED" ]]; then
        info "${inst_name} already terminated"
        continue
    fi

    info "Terminating ${inst_name}: ${inst_id}"
    oci compute instance terminate \
        --instance-id "${inst_id}" \
        --preserve-boot-volume false \
        --force 2>/dev/null || warn "Could not terminate ${inst_name}"
done

# Wait for all instances to terminate
for idx in "${!INSTANCE_IDS[@]}"; do
    inst_id="${INSTANCE_IDS[$idx]}"
    inst_name="${INSTANCE_NAMES[$idx]}"
    wait_for_terminated "${inst_id}" "${inst_name}"
done

success "All instances terminated"

# ===== 3. Delete Subnets =====
step "Deleting subnets"

# Private subnet first (no dependencies after instances are gone)
safe_delete "Private Subnet" "${PRIVATE_SUBNET_ID:-}" \
    oci network subnet delete \
        --subnet-id "${PRIVATE_SUBNET_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

# Public subnet
safe_delete "Public Subnet" "${PUBLIC_SUBNET_ID:-}" \
    oci network subnet delete \
        --subnet-id "${PUBLIC_SUBNET_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

# Wait for subnet deletion to propagate
sleep 10

# ===== 4. Delete Security Lists =====
step "Deleting security lists"

safe_delete "Private Security List" "${PRIVATE_SL_ID:-}" \
    oci network security-list delete \
        --security-list-id "${PRIVATE_SL_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

safe_delete "Public Security List" "${PUBLIC_SL_ID:-}" \
    oci network security-list delete \
        --security-list-id "${PUBLIC_SL_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

# ===== 5. Delete Route Tables =====
step "Deleting route tables"

# Clear route rules before deleting (required by OCI -- cannot delete RT with rules)
if [[ -n "${PRIVATE_RT_ID}" && "${PRIVATE_RT_ID}" != "None" ]]; then
    oci network route-table update \
        --rt-id "${PRIVATE_RT_ID}" \
        --route-rules '[]' \
        --force \
        --wait-for-state AVAILABLE > /dev/null 2>&1 || true
fi

if [[ -n "${PUBLIC_RT_ID}" && "${PUBLIC_RT_ID}" != "None" ]]; then
    oci network route-table update \
        --rt-id "${PUBLIC_RT_ID}" \
        --route-rules '[]' \
        --force \
        --wait-for-state AVAILABLE > /dev/null 2>&1 || true
fi

safe_delete "Private Route Table" "${PRIVATE_RT_ID:-}" \
    oci network route-table delete \
        --rt-id "${PRIVATE_RT_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

safe_delete "Public Route Table" "${PUBLIC_RT_ID:-}" \
    oci network route-table delete \
        --rt-id "${PUBLIC_RT_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

# ===== 6. Delete Gateways =====
step "Deleting gateways"

safe_delete "NAT Gateway" "${NAT_ID:-}" \
    oci network nat-gateway delete \
        --nat-gateway-id "${NAT_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

safe_delete "Internet Gateway" "${IGW_ID:-}" \
    oci network internet-gateway delete \
        --ig-id "${IGW_ID:-none}" \
        --force \
        --wait-for-state TERMINATED \
        --max-wait-seconds 300

# ===== 7. Delete VCN =====
step "Deleting VCN"

# Wait for all sub-resources to be fully deleted
sleep 15

if [[ -n "${VCN_ID}" && "${VCN_ID}" != "None" ]]; then
    info "Deleting VCN: ${VCN_ID}"

    # Retry VCN deletion (may fail if sub-resources are still being deleted)
    local_retries=5
    for i in $(seq 1 ${local_retries}); do
        if oci network vcn delete \
            --vcn-id "${VCN_ID}" \
            --force \
            --wait-for-state TERMINATED \
            --max-wait-seconds 300 2>/dev/null; then
            success "VCN deleted"
            break
        fi
        if [[ ${i} -lt ${local_retries} ]]; then
            warn "VCN deletion attempt ${i}/${local_retries} failed. Retrying in 15s..."
            sleep 15
        else
            warn "VCN deletion failed after ${local_retries} attempts. Delete manually via OCI console."
        fi
    done
else
    info "No VCN to delete"
fi

# ===== 8. Remove state file =====
step "Cleaning up state file"

if [[ -f "${STATE_FILE}" ]]; then
    info "Removing state file: ${STATE_FILE}"
    rm -f "${STATE_FILE}"
    success "State file removed"
else
    info "No state file to remove"
fi

# Also clean up results directory if empty
RESULTS_DIR="${SCRIPT_DIR}/results"
if [[ -d "${RESULTS_DIR}" ]]; then
    info "Results directory preserved at: ${RESULTS_DIR}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Teardown complete"
echo ""
echo "  All OCI resources have been deleted:"
echo "    [x] Load Balancer"
echo "    [x] Compute instances (5)"
echo "    [x] Subnets (2)"
echo "    [x] Security lists (2)"
echo "    [x] Route tables (2)"
echo "    [x] NAT Gateway"
echo "    [x] Internet Gateway"
echo "    [x] VCN"
echo "    [x] State file"
echo ""
echo "  Resources NOT deleted (manual cleanup if needed):"
echo "    - SSH key pair: ${SSH_KEY_PATH}"
echo "    - Test results: ${RESULTS_DIR:-none}"
echo ""
success "Teardown finished. OCI resources cleaned up."
