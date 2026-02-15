#!/bin/bash
# =============================================================================
# 05-create-load-balancer.sh -- Create OCI Flexible Load Balancer (Always Free)
#
# Creates:
#   - Flexible LB (10 Mbps) in the public subnet
#   - Backend set with health check on /health:8080
#   - Backend pointing to edge-and-tools private IP
#   - HTTP listener on port 80
#
# Idempotent: uses find_lb() before creating.
#
# Usage: ./05-create-load-balancer.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

banner "Phase 5: Create Load Balancer"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ -z "${COMPARTMENT_ID}" ]]; then
    error "COMPARTMENT_ID not set. Run 00-prerequisites.sh first."
    exit 1
fi

if [[ -z "${PUBLIC_SUBNET_ID}" ]]; then
    error "PUBLIC_SUBNET_ID not set. Run 01-create-network.sh first."
    exit 1
fi

if [[ -z "${EDGE_PRIVATE_IP}" ]]; then
    error "EDGE_PRIVATE_IP not set. Run 02-launch-instances.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BACKEND_SET_NAME="gateway-backends"
LISTENER_NAME="http-listener"
LB_MIN_BW=10
LB_MAX_BW=10

# ===== Create Load Balancer =====
step "Creating Flexible Load Balancer: ${LB_NAME}"

EXISTING_LB=$(find_lb)
if [[ -n "${EXISTING_LB}" && "${EXISTING_LB}" != "None" ]]; then
    LB_ID="${EXISTING_LB}"
    info "Load Balancer already exists: ${LB_ID}"
else
    info "Creating LB (this may take 2-5 minutes)..."
    LB_ID=$(oci lb load-balancer create \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${LB_NAME}" \
        --shape-name "flexible" \
        --shape-details "{\"minimumBandwidthInMbps\":${LB_MIN_BW},\"maximumBandwidthInMbps\":${LB_MAX_BW}}" \
        --subnet-ids "[\"${PUBLIC_SUBNET_ID}\"]" \
        --is-private false \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 600 \
        --query "data.id" --raw-output 2>/dev/null)

    # The create command with --wait-for-state returns a work request.
    # We need to look up the LB by name after creation.
    if [[ -z "${LB_ID}" || "${LB_ID}" == "None" ]]; then
        info "Fetching LB ID by display name..."
        sleep 10
        LB_ID=$(oci lb load-balancer list \
            --compartment-id "${COMPARTMENT_ID}" \
            --display-name "${LB_NAME}" \
            --lifecycle-state ACTIVE \
            --query "data[0].id" --raw-output 2>/dev/null || echo "")
    fi

    if [[ -z "${LB_ID}" || "${LB_ID}" == "None" ]]; then
        error "Failed to create Load Balancer. Check OCI console."
        exit 1
    fi
    success "Load Balancer created: ${LB_ID}"
fi
save_state "LB_ID" "${LB_ID}"

# ===== Create Backend Set =====
step "Creating Backend Set: ${BACKEND_SET_NAME}"

# Check if backend set already exists
EXISTING_BS=$(oci lb backend-set get \
    --load-balancer-id "${LB_ID}" \
    --backend-set-name "${BACKEND_SET_NAME}" \
    --query "data.name" --raw-output 2>/dev/null || echo "")

if [[ -n "${EXISTING_BS}" && "${EXISTING_BS}" != "None" ]]; then
    info "Backend set '${BACKEND_SET_NAME}' already exists"
else
    oci lb backend-set create \
        --load-balancer-id "${LB_ID}" \
        --name "${BACKEND_SET_NAME}" \
        --policy "ROUND_ROBIN" \
        --health-checker-protocol "HTTP" \
        --health-checker-url-path "/health" \
        --health-checker-port "${GW_APP_PORT}" \
        --health-checker-interval-in-millis 10000 \
        --health-checker-timeout-in-millis 3000 \
        --health-checker-retries 3 \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 300
    success "Backend set created"
fi

# ===== Add Backend (edge-and-tools) =====
step "Adding backend: ${EDGE_PRIVATE_IP}:${GW_APP_PORT}"

# Check if backend already exists
EXISTING_BACKEND=$(oci lb backend list \
    --load-balancer-id "${LB_ID}" \
    --backend-set-name "${BACKEND_SET_NAME}" \
    --query "data[?\"ip-address\"=='${EDGE_PRIVATE_IP}'].name | [0]" --raw-output 2>/dev/null || echo "")

if [[ -n "${EXISTING_BACKEND}" && "${EXISTING_BACKEND}" != "None" ]]; then
    info "Backend ${EDGE_PRIVATE_IP}:${GW_APP_PORT} already exists"
else
    oci lb backend create \
        --load-balancer-id "${LB_ID}" \
        --backend-set-name "${BACKEND_SET_NAME}" \
        --ip-address "${EDGE_PRIVATE_IP}" \
        --port "${GW_APP_PORT}" \
        --weight 1 \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 300
    success "Backend added"
fi

# ===== Create HTTP Listener =====
step "Creating HTTP Listener: ${LISTENER_NAME} (port 80)"

# Check if listener already exists
EXISTING_LISTENER=$(oci lb listener get \
    --load-balancer-id "${LB_ID}" \
    --listener-name "${LISTENER_NAME}" \
    --query "data.name" --raw-output 2>/dev/null || echo "")

if [[ -n "${EXISTING_LISTENER}" && "${EXISTING_LISTENER}" != "None" ]]; then
    info "Listener '${LISTENER_NAME}' already exists"
else
    oci lb listener create \
        --load-balancer-id "${LB_ID}" \
        --name "${LISTENER_NAME}" \
        --default-backend-set-name "${BACKEND_SET_NAME}" \
        --protocol "HTTP" \
        --port 80 \
        --wait-for-state SUCCEEDED \
        --max-wait-seconds 300
    success "HTTP listener created on port 80"
fi

# ===== Retrieve LB Public IP =====
step "Retrieving Load Balancer public IP"

LB_PUBLIC_IP=$(oci lb load-balancer get \
    --load-balancer-id "${LB_ID}" \
    --query "data.\"ip-addresses\"[?\"is-public\"==\`true\`].\"ip-address\" | [0]" \
    --raw-output 2>/dev/null || echo "")

if [[ -z "${LB_PUBLIC_IP}" || "${LB_PUBLIC_IP}" == "None" ]]; then
    # Fallback: try without the is-public filter
    LB_PUBLIC_IP=$(oci lb load-balancer get \
        --load-balancer-id "${LB_ID}" \
        --query "data.\"ip-addresses\"[0].\"ip-address\"" \
        --raw-output 2>/dev/null || echo "")
fi

if [[ -n "${LB_PUBLIC_IP}" && "${LB_PUBLIC_IP}" != "None" ]]; then
    save_state "LB_PUBLIC_IP" "${LB_PUBLIC_IP}"
    success "Load Balancer public IP: ${LB_PUBLIC_IP}"
else
    warn "Could not retrieve LB public IP. Check OCI console."
fi

# ===== Verify LB health =====
step "Verifying Load Balancer health"

# Wait a bit for LB health checks to run
info "Waiting 30s for LB health checks to initialize..."
sleep 30

HEALTH_STATUS=$(oci lb backend-health get \
    --load-balancer-id "${LB_ID}" \
    --backend-set-name "${BACKEND_SET_NAME}" \
    --backend-name "${EDGE_PRIVATE_IP}:${GW_APP_PORT}" \
    --query "data.status" --raw-output 2>/dev/null || echo "UNKNOWN")

if [[ "${HEALTH_STATUS}" == "OK" ]]; then
    success "Backend health: OK"
else
    warn "Backend health: ${HEALTH_STATUS} (may still be initializing)"
    info "Check health: oci lb backend-health get --load-balancer-id ${LB_ID} --backend-set-name ${BACKEND_SET_NAME} --backend-name ${EDGE_PRIVATE_IP}:${GW_APP_PORT}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Load Balancer setup complete"
echo ""
echo "  LB Name:       ${LB_NAME}"
echo "  LB OCID:       ${LB_ID}"
echo "  LB Public IP:  ${LB_PUBLIC_IP:-PENDING}"
echo "  Bandwidth:     ${LB_MIN_BW} - ${LB_MAX_BW} Mbps (Always Free)"
echo "  Backend:       ${EDGE_PRIVATE_IP}:${GW_APP_PORT}"
echo "  Listener:      HTTP on port 80"
echo ""

if [[ -n "${LB_PUBLIC_IP}" && "${LB_PUBLIC_IP}" != "None" ]]; then
    echo "  Test endpoint:"
    echo "    curl http://${LB_PUBLIC_IP}/health"
    echo ""
fi

info "All LB details saved to ${STATE_FILE}"
info "Run 06-run-tests.sh next."
