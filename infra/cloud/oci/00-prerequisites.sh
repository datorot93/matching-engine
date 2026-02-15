#!/bin/bash
# =============================================================================
# 00-prerequisites.sh -- Verify OCI CLI, tenancy, SSH keys, and set variables
#
# This script checks that all required tools are installed and configured,
# and populates the env.state file with the compartment ID and availability
# domain for use by subsequent scripts.
#
# Usage: ./00-prerequisites.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

banner "Phase 0: Prerequisites Check"

ERRORS=0

# ---------------------------------------------------------------------------
# 1. Check OCI CLI
# ---------------------------------------------------------------------------
step "Checking OCI CLI installation"
if command -v oci &>/dev/null; then
    OCI_VERSION=$(oci --version 2>&1)
    success "OCI CLI installed: ${OCI_VERSION}"
else
    error "OCI CLI not found. Install with: brew install oci-cli (macOS) or pip install oci-cli"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 2. Check OCI CLI configuration
# ---------------------------------------------------------------------------
step "Verifying OCI CLI configuration"
if oci iam region list --output table &>/dev/null; then
    success "OCI CLI configured and authenticated"
else
    error "OCI CLI not configured. Run: oci setup config"
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 3. Verify tenancy and region
# ---------------------------------------------------------------------------
step "Checking OCI tenancy"
TENANCY_ID=$(oci iam tenancy get --query "data.name" --raw-output 2>/dev/null || echo "")
if [[ -n "${TENANCY_ID}" ]]; then
    success "Tenancy: ${TENANCY_ID}"
else
    warn "Could not retrieve tenancy name (may still work with correct config)"
fi

CURRENT_REGION=$(oci iam region-subscription list \
    --query "data[?\"is-home-region\"].\"region-name\" | [0]" \
    --raw-output 2>/dev/null || echo "unknown")
info "Home region: ${CURRENT_REGION}"
info "Target region: ${OCI_REGION}"

# ---------------------------------------------------------------------------
# 4. Get or verify compartment ID
# ---------------------------------------------------------------------------
step "Resolving compartment ID"
if [[ -z "${COMPARTMENT_ID}" ]]; then
    # Try to get the root compartment (tenancy)
    COMPARTMENT_ID=$(oci iam compartment list \
        --compartment-id-in-subtree true \
        --query "data[?\"lifecycle-state\"=='ACTIVE'] | [0].\"compartment-id\"" \
        --raw-output 2>/dev/null || echo "")

    if [[ -z "${COMPARTMENT_ID}" ]]; then
        # Fall back to tenancy ID itself
        COMPARTMENT_ID=$(oci iam tenancy get --query "data.id" --raw-output 2>/dev/null || echo "")
    fi
fi

if [[ -n "${COMPARTMENT_ID}" ]]; then
    success "Compartment ID: ${COMPARTMENT_ID}"
    save_state "COMPARTMENT_ID" "${COMPARTMENT_ID}"
else
    error "Could not determine compartment ID. Set COMPARTMENT_ID environment variable."
    ERRORS=$((ERRORS + 1))
fi

# ---------------------------------------------------------------------------
# 5. Get availability domain
# ---------------------------------------------------------------------------
step "Resolving availability domain"
if [[ -n "${COMPARTMENT_ID}" ]]; then
    AD=$(oci iam availability-domain list \
        --compartment-id "${COMPARTMENT_ID}" \
        --query "data[0].name" --raw-output 2>/dev/null || echo "")
    if [[ -n "${AD}" ]]; then
        success "Availability domain: ${AD}"
        save_state "AD" "${AD}"
    else
        error "Could not list availability domains"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 6. Check SSH key pair
# ---------------------------------------------------------------------------
step "Checking SSH key pair"
if [[ -f "${SSH_KEY_PATH}" && -f "${SSH_KEY_PUB}" ]]; then
    success "SSH key pair found: ${SSH_KEY_PATH}"
else
    warn "SSH key pair not found at ${SSH_KEY_PATH}"
    info "Generating new ED25519 key pair..."
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -N "" -q
    success "SSH key pair generated: ${SSH_KEY_PATH}"
fi

# ---------------------------------------------------------------------------
# 7. Resolve compute images
# ---------------------------------------------------------------------------
step "Resolving compute images"
if [[ -n "${COMPARTMENT_ID}" ]]; then
    # ARM64 Oracle Linux 9 image (for A1.Flex instances)
    ARM64_IMAGE_ID=$(oci compute image list \
        --compartment-id "${COMPARTMENT_ID}" \
        --operating-system "Oracle Linux" \
        --operating-system-version "9" \
        --shape "${A1_SHAPE}" \
        --sort-by TIMECREATED --sort-order DESC \
        --query "data[0].id" --raw-output 2>/dev/null || echo "")

    if [[ -n "${ARM64_IMAGE_ID}" ]]; then
        success "ARM64 image: ${ARM64_IMAGE_ID}"
        save_state "ARM64_IMAGE_ID" "${ARM64_IMAGE_ID}"
    else
        error "Could not find ARM64 Oracle Linux 9 image for ${A1_SHAPE}"
        ERRORS=$((ERRORS + 1))
    fi

    # x86_64 Oracle Linux 9 image (for E2.1.Micro bastion)
    X86_IMAGE_ID=$(oci compute image list \
        --compartment-id "${COMPARTMENT_ID}" \
        --operating-system "Oracle Linux" \
        --operating-system-version "9" \
        --shape "${MICRO_SHAPE}" \
        --sort-by TIMECREATED --sort-order DESC \
        --query "data[0].id" --raw-output 2>/dev/null || echo "")

    if [[ -n "${X86_IMAGE_ID}" ]]; then
        success "x86_64 image: ${X86_IMAGE_ID}"
        save_state "X86_IMAGE_ID" "${X86_IMAGE_ID}"
    else
        error "Could not find x86_64 Oracle Linux 9 image for ${MICRO_SHAPE}"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 8. Check additional tools
# ---------------------------------------------------------------------------
step "Checking local tools"

if command -v ssh &>/dev/null; then
    success "ssh: available"
else
    error "ssh not found"
    ERRORS=$((ERRORS + 1))
fi

if command -v scp &>/dev/null; then
    success "scp: available"
else
    error "scp not found"
    ERRORS=$((ERRORS + 1))
fi

if command -v jq &>/dev/null; then
    success "jq: available"
else
    warn "jq not found. Some scripts may use python3 as fallback."
fi

if command -v python3 &>/dev/null; then
    success "python3: available"
else
    warn "python3 not found. JSON parsing in collect-results may fail."
fi

# ---------------------------------------------------------------------------
# 9. Display resource budget summary
# ---------------------------------------------------------------------------
step "OCI Always Free Budget"
echo ""
echo "  A1 OCPUs:   4 used / 4 available  (me-shard-a, me-shard-b, me-shard-c, edge-and-tools)"
echo "  A1 RAM:     24 GB used / 24 GB available  (6 GB x 4 instances)"
echo "  Micro:      1 used / 2 available  (bastion)"
echo "  Boot Vol:   170 GB used / 200 GB available  (30+30+30+40+40 = 170, 30 reserved for spare)"
echo "  LB:         1 used / 1 available  (10 Mbps flexible)"
echo ""

# ---------------------------------------------------------------------------
# 10. Generate SSH config snippet
# ---------------------------------------------------------------------------
step "SSH config helper"
echo ""
echo "  Add the following to ~/.ssh/config for easy access:"
echo ""
echo "  -------------------------------------------------------"
echo "  Host me-bastion"
echo "      HostName <BASTION_PUBLIC_IP>"
echo "      User opc"
echo "      IdentityFile ${SSH_KEY_PATH}"
echo ""
echo "  Host me-shard-a me-shard-b me-shard-c edge-and-tools"
echo "      User opc"
echo "      IdentityFile ${SSH_KEY_PATH}"
echo "      ProxyJump me-bastion"
echo "      StrictHostKeyChecking no"
echo "  -------------------------------------------------------"
echo ""
echo "  (IPs will be printed by 02-launch-instances.sh)"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ ${ERRORS} -gt 0 ]]; then
    error "${ERRORS} prerequisite check(s) failed. Fix the issues above before proceeding."
    exit 1
else
    banner "All prerequisites satisfied. Run 01-create-network.sh next."
    exit 0
fi
