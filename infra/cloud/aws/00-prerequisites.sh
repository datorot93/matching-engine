#!/bin/bash
# =============================================================================
# 00-prerequisites.sh -- Verify tools, find ARM64 AMI, create SSH key pair.
#
# This is the first script to run. It checks that the AWS CLI is installed
# and configured, finds the latest Amazon Linux 2023 ARM64 AMI, and creates
# an SSH key pair for accessing EC2 instances.
#
# Idempotent: skips key pair creation if it already exists.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 0: Prerequisites Check"

# ---------------------------------------------------------------------------
# 1. Check AWS CLI
# ---------------------------------------------------------------------------
info "Checking AWS CLI..."
if ! command -v aws &>/dev/null; then
    error "AWS CLI is not installed. Install it from https://aws.amazon.com/cli/"
    exit 1
fi
AWS_VERSION=$(aws --version 2>&1)
success "AWS CLI: ${AWS_VERSION}"

# ---------------------------------------------------------------------------
# 2. Check AWS credentials / region
# ---------------------------------------------------------------------------
info "Checking AWS credentials..."
CALLER_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)
if [ -z "$CALLER_ID" ]; then
    error "AWS credentials not configured. Run 'aws configure' first."
    exit 1
fi
success "AWS Account: ${CALLER_ID}"

info "Checking AWS region..."
CONFIGURED_REGION=$(aws configure get region 2>/dev/null || echo "")
if [ -z "$CONFIGURED_REGION" ]; then
    warn "No default region configured. Using AWS_REGION=${AWS_REGION}"
else
    if [ "$CONFIGURED_REGION" != "$AWS_REGION" ]; then
        warn "Configured region (${CONFIGURED_REGION}) differs from target (${AWS_REGION})."
        warn "Scripts will use --region ${AWS_REGION} explicitly."
    fi
fi
success "Target region: ${AWS_REGION}, AZ: ${AZ}"

# ---------------------------------------------------------------------------
# 3. Check supporting tools (jq, ssh, scp, curl)
# ---------------------------------------------------------------------------
info "Checking supporting tools..."
for tool in jq ssh scp curl python3; do
    if command -v "$tool" &>/dev/null; then
        success "  ${tool}: found"
    else
        warn "  ${tool}: NOT found (some scripts may fail)"
    fi
done

# ---------------------------------------------------------------------------
# 4. Find latest Amazon Linux 2023 ARM64 AMI
# ---------------------------------------------------------------------------
info "Looking up latest Amazon Linux 2023 ARM64 AMI in ${AWS_REGION}..."
AMI_FOUND=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=al2023-ami-2023*-arm64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=arm64" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text 2>/dev/null || echo "")

if [ -z "$AMI_FOUND" ] || [ "$AMI_FOUND" = "None" ]; then
    error "Could not find Amazon Linux 2023 ARM64 AMI. Check region and permissions."
    exit 1
fi
success "AMI: ${AMI_FOUND}"
persist_var "AMI_ID" "$AMI_FOUND"

# ---------------------------------------------------------------------------
# 5. Create SSH key pair (idempotent)
# ---------------------------------------------------------------------------
info "Checking SSH key pair '${KEY_NAME}'..."
EXISTING_KEY=$(aws ec2 describe-key-pairs \
    --region "$AWS_REGION" \
    --key-names "$KEY_NAME" \
    --query 'KeyPairs[0].KeyName' \
    --output text 2>/dev/null || echo "")

if [ "$EXISTING_KEY" = "$KEY_NAME" ]; then
    success "Key pair '${KEY_NAME}' already exists in AWS."
    if [ -f "$KEY_FILE" ]; then
        success "Private key file exists at ${KEY_FILE}"
    else
        warn "Private key file NOT found at ${KEY_FILE}."
        warn "If you lost the key, delete it with:"
        warn "  aws ec2 delete-key-pair --key-name ${KEY_NAME} --region ${AWS_REGION}"
        warn "Then re-run this script."
    fi
else
    info "Creating key pair '${KEY_NAME}'..."
    mkdir -p "$(dirname "$KEY_FILE")"
    aws ec2 create-key-pair \
        --region "$AWS_REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    success "Key pair created. Private key saved to ${KEY_FILE}"
fi

# ---------------------------------------------------------------------------
# 6. Detect public IP for security group rules
# ---------------------------------------------------------------------------
info "Detecting your public IP address..."
DETECTED_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "")
if [ -n "$DETECTED_IP" ]; then
    MY_IP_CIDR="${DETECTED_IP}/32"
    persist_var "MY_IP" "$MY_IP_CIDR"
    success "Your public IP: ${MY_IP_CIDR}"
else
    warn "Could not detect public IP. You will need to set MY_IP manually in env.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Prerequisites Complete"
echo ""
info "AMI ID:        ${AMI_FOUND}"
info "Key pair:      ${KEY_NAME}"
info "Key file:      ${KEY_FILE}"
info "Your IP:       ${MY_IP_CIDR:-unknown}"
info "Target region: ${AWS_REGION}"
info "Target AZ:     ${AZ}"
echo ""
info "Next step: Run 01-create-network.sh"
