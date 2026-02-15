#!/bin/bash
# =============================================================================
# 99-teardown.sh -- Full cleanup of all AWS resources in reverse order.
#
# This script deletes every resource created by scripts 00 through 04:
#   1. Terminate all EC2 instances (and wait for termination)
#   2. Delete NLB listener, target group, and load balancer
#   3. Delete NAT Gateway and release Elastic IP
#   4. Delete security groups
#   5. Detach and delete Internet Gateway
#   6. Delete subnets
#   7. Delete route tables (public and private)
#   8. Delete VPC
#   9. Delete SSH key pair (from AWS; local .pem file is preserved)
#  10. Reset dynamic variables in env.sh
#
# Usage:
#   ./99-teardown.sh              # Interactive (prompts for confirmation)
#   ./99-teardown.sh --confirm    # Skip confirmation prompt
#
# Resources are identified by their IDs stored in env.sh. If an ID is empty
# or the resource no longer exists, the deletion step is skipped gracefully.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Teardown: Full AWS Resource Cleanup"

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--confirm" ]]; then
    echo ""
    warn "This will PERMANENTLY DELETE all resources for project '${PROJECT_PREFIX}':"
    echo ""
    info "  EC2 instances (ME shards, Edge GW, Redpanda, Monitoring, k6)"
    info "  Network Load Balancer, target group, listener"
    info "  NAT Gateway and Elastic IP"
    info "  Security groups"
    info "  Internet Gateway"
    info "  Subnets (public and private)"
    info "  Route tables (public and private)"
    info "  VPC"
    info "  SSH key pair (AWS-side only; local .pem file is kept)"
    echo ""
    read -rp "Type 'yes' to proceed: " RESPONSE
    if [ "$RESPONSE" != "yes" ]; then
        info "Teardown cancelled."
        exit 0
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# Helper: safe delete -- only act if the ID is non-empty and not "None"
# ---------------------------------------------------------------------------
is_set() {
    local val="${1:-}"
    [ -n "$val" ] && [ "$val" != "None" ]
}

# ===========================================================================
# 1. Terminate all EC2 instances
# ===========================================================================
header "Step 1: Terminate EC2 Instances"

INSTANCE_IDS=()
INSTANCE_LABELS=()

for pair in \
    "INST_K6:k6-LoadGen" \
    "INST_MONITORING:Monitoring" \
    "INST_EDGE:Edge-Gateway" \
    "INST_ME_C:ME-Shard-C" \
    "INST_ME_B:ME-Shard-B" \
    "INST_ME_A:ME-Shard-A" \
    "INST_REDPANDA:Redpanda"; do

    var_name="${pair%%:*}"
    label="${pair##*:}"
    inst_id="${!var_name:-}"

    if is_set "$inst_id"; then
        info "Terminating ${label} (${inst_id})..."
        aws ec2 terminate-instances \
            --region "$AWS_REGION" \
            --instance-ids "$inst_id" >/dev/null 2>&1 || warn "  Could not terminate ${inst_id} (may already be terminated)."
        INSTANCE_IDS+=("$inst_id")
        INSTANCE_LABELS+=("$label")
    else
        info "Skipping ${label} (not set)."
    fi
done

if [ ${#INSTANCE_IDS[@]} -gt 0 ]; then
    info "Waiting for all instances to terminate (this may take 1-2 minutes)..."
    aws ec2 wait instance-terminated \
        --region "$AWS_REGION" \
        --instance-ids "${INSTANCE_IDS[@]}" 2>/dev/null || warn "  Wait timed out; some instances may still be terminating."
    success "All instances terminated."
else
    info "No instances to terminate."
fi

# ===========================================================================
# 2. Delete NLB, Target Group, Listener
# ===========================================================================
header "Step 2: Delete Network Load Balancer"

# Delete listener
if is_set "${LISTENER_ARN:-}"; then
    info "Deleting NLB listener..."
    aws elbv2 delete-listener \
        --region "$AWS_REGION" \
        --listener-arn "$LISTENER_ARN" 2>/dev/null || warn "  Listener deletion failed (may not exist)."
    success "Listener deleted."
else
    info "No listener to delete."
fi

# Delete NLB
if is_set "${NLB_ARN:-}"; then
    info "Deleting NLB..."
    aws elbv2 delete-load-balancer \
        --region "$AWS_REGION" \
        --load-balancer-arn "$NLB_ARN" 2>/dev/null || warn "  NLB deletion failed (may not exist)."
    success "NLB deleted."

    # NLB takes time to fully deregister from ENIs
    info "Waiting 30s for NLB to release network interfaces..."
    sleep 30
else
    info "No NLB to delete."
fi

# Delete target group
if is_set "${TG_ARN:-}"; then
    info "Deleting target group..."
    aws elbv2 delete-target-group \
        --region "$AWS_REGION" \
        --target-group-arn "$TG_ARN" 2>/dev/null || warn "  Target group deletion failed (may not exist)."
    success "Target group deleted."
else
    info "No target group to delete."
fi

# ===========================================================================
# 3. Delete NAT Gateway and Elastic IP
# ===========================================================================
header "Step 3: Delete NAT Gateway"

if is_set "${NAT_GW_ID:-}"; then
    info "Deleting NAT Gateway (${NAT_GW_ID})..."
    aws ec2 delete-nat-gateway \
        --region "$AWS_REGION" \
        --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || warn "  NAT Gateway deletion failed."

    info "Waiting for NAT Gateway to be deleted (this takes 1-2 minutes)..."
    local_attempt=1
    while [ $local_attempt -le 30 ]; do
        NAT_STATE=$(aws ec2 describe-nat-gateways \
            --region "$AWS_REGION" \
            --nat-gateway-ids "$NAT_GW_ID" \
            --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
        if [ "$NAT_STATE" = "deleted" ]; then
            success "NAT Gateway deleted."
            break
        fi
        sleep 10
        local_attempt=$((local_attempt + 1))
    done
else
    info "No NAT Gateway to delete."
fi

# Release Elastic IP
if is_set "${NAT_EIP_ALLOC_ID:-}"; then
    info "Releasing Elastic IP (${NAT_EIP_ALLOC_ID})..."
    aws ec2 release-address \
        --region "$AWS_REGION" \
        --allocation-id "$NAT_EIP_ALLOC_ID" 2>/dev/null || warn "  EIP release failed (may already be released)."
    success "Elastic IP released."
else
    info "No Elastic IP to release."
fi

# ===========================================================================
# 4. Delete Security Groups
# ===========================================================================
header "Step 4: Delete Security Groups"

# Security groups must be deleted in an order that respects dependencies
# (SGs that reference other SGs in their rules must be deleted first,
#  or we revoke the rules first). Revoke all cross-SG references first.

# Revoke cross-SG ingress rules to break circular dependencies
for sg_id_var in SG_NLB_ID SG_EDGE_ID SG_ME_ID SG_RP_ID SG_MON_ID SG_LG_ID; do
    sg_id="${!sg_id_var:-}"
    if is_set "$sg_id"; then
        # Get all ingress rules that reference other SGs
        RULES=$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null || echo "[]")
        if [ "$RULES" != "[]" ] && [ -n "$RULES" ]; then
            aws ec2 revoke-security-group-ingress \
                --region "$AWS_REGION" \
                --group-id "$sg_id" \
                --ip-permissions "$RULES" 2>/dev/null || true
        fi
    fi
done
info "Cross-SG ingress rules revoked."

for pair in \
    "SG_LG_ID:sg-loadgen" \
    "SG_MON_ID:sg-monitoring" \
    "SG_RP_ID:sg-redpanda" \
    "SG_ME_ID:sg-me" \
    "SG_EDGE_ID:sg-edge" \
    "SG_NLB_ID:sg-nlb"; do

    var_name="${pair%%:*}"
    label="${pair##*:}"
    sg_id="${!var_name:-}"

    if is_set "$sg_id"; then
        info "Deleting security group ${label} (${sg_id})..."
        aws ec2 delete-security-group \
            --region "$AWS_REGION" \
            --group-id "$sg_id" 2>/dev/null || warn "  Could not delete ${sg_id} (may have dependencies)."
        success "Deleted ${label}."
    else
        info "Skipping ${label} (not set)."
    fi
done

# ===========================================================================
# 5. Detach and Delete Internet Gateway
# ===========================================================================
header "Step 5: Delete Internet Gateway"

if is_set "${IGW_ID:-}" && is_set "${VPC_ID:-}"; then
    info "Detaching Internet Gateway (${IGW_ID}) from VPC (${VPC_ID})..."
    aws ec2 detach-internet-gateway \
        --region "$AWS_REGION" \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID" 2>/dev/null || warn "  IGW detach failed (may not be attached)."

    info "Deleting Internet Gateway..."
    aws ec2 delete-internet-gateway \
        --region "$AWS_REGION" \
        --internet-gateway-id "$IGW_ID" 2>/dev/null || warn "  IGW deletion failed."
    success "Internet Gateway deleted."
elif is_set "${IGW_ID:-}"; then
    info "Deleting Internet Gateway (no VPC to detach from)..."
    aws ec2 delete-internet-gateway \
        --region "$AWS_REGION" \
        --internet-gateway-id "$IGW_ID" 2>/dev/null || warn "  IGW deletion failed."
else
    info "No Internet Gateway to delete."
fi

# ===========================================================================
# 6. Delete Subnets
# ===========================================================================
header "Step 6: Delete Subnets"

for pair in \
    "PRIV_SUBNET_ID:Private" \
    "PUB_SUBNET_ID:Public"; do

    var_name="${pair%%:*}"
    label="${pair##*:}"
    subnet_id="${!var_name:-}"

    if is_set "$subnet_id"; then
        info "Deleting ${label} subnet (${subnet_id})..."
        aws ec2 delete-subnet \
            --region "$AWS_REGION" \
            --subnet-id "$subnet_id" 2>/dev/null || warn "  Could not delete ${subnet_id} (may have active ENIs)."
        success "Deleted ${label} subnet."
    else
        info "Skipping ${label} subnet (not set)."
    fi
done

# ===========================================================================
# 7. Delete Route Tables
# ===========================================================================
header "Step 7: Delete Route Tables"

for pair in \
    "PRIV_RT_ID:Private" \
    "PUB_RT_ID:Public"; do

    var_name="${pair%%:*}"
    label="${pair##*:}"
    rt_id="${!var_name:-}"

    if is_set "$rt_id"; then
        # Disassociate all non-main associations
        ASSOC_IDS=$(aws ec2 describe-route-tables \
            --region "$AWS_REGION" \
            --route-table-ids "$rt_id" \
            --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
            --output text 2>/dev/null || echo "")
        for assoc_id in $ASSOC_IDS; do
            if [ -n "$assoc_id" ] && [ "$assoc_id" != "None" ]; then
                info "  Disassociating route table association ${assoc_id}..."
                aws ec2 disassociate-route-table \
                    --region "$AWS_REGION" \
                    --association-id "$assoc_id" 2>/dev/null || true
            fi
        done

        info "Deleting ${label} route table (${rt_id})..."
        aws ec2 delete-route-table \
            --region "$AWS_REGION" \
            --route-table-id "$rt_id" 2>/dev/null || warn "  Could not delete ${rt_id} (may be the main route table)."
        success "Deleted ${label} route table."
    else
        info "Skipping ${label} route table (not set)."
    fi
done

# ===========================================================================
# 8. Delete VPC
# ===========================================================================
header "Step 8: Delete VPC"

if is_set "${VPC_ID:-}"; then
    info "Deleting VPC (${VPC_ID})..."
    aws ec2 delete-vpc \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" 2>/dev/null || warn "  VPC deletion failed. Check for remaining dependencies."
    success "VPC deleted."
else
    info "No VPC to delete."
fi

# ===========================================================================
# 9. Delete SSH Key Pair (AWS-side only)
# ===========================================================================
header "Step 9: Delete SSH Key Pair"

info "Deleting key pair '${KEY_NAME}' from AWS..."
aws ec2 delete-key-pair \
    --region "$AWS_REGION" \
    --key-name "$KEY_NAME" 2>/dev/null || warn "  Key pair deletion failed."
success "Key pair deleted from AWS."
info "Local key file preserved at: ${KEY_FILE}"
info "To remove it manually: rm -f ${KEY_FILE}"

# ===========================================================================
# 10. Reset dynamic variables in env.sh
# ===========================================================================
header "Step 10: Reset env.sh Variables"

DYNAMIC_VARS=(
    AMI_ID VPC_ID IGW_ID PUB_SUBNET_ID PRIV_SUBNET_ID PUB_RT_ID
    SG_NLB_ID SG_EDGE_ID SG_ME_ID SG_RP_ID SG_MON_ID SG_LG_ID
    INST_REDPANDA INST_ME_A INST_ME_B INST_ME_C INST_EDGE INST_MONITORING INST_K6
    K6_PUBLIC_IP NLB_ARN TG_ARN LISTENER_ARN NLB_DNS MY_IP
    NAT_GW_ID NAT_EIP_ALLOC_ID PRIV_RT_ID
)

ENV_FILE="${SCRIPT_DIR}/env.sh"
for var in "${DYNAMIC_VARS[@]}"; do
    if grep -q "^export ${var}=" "$ENV_FILE"; then
        sed -i "s|^export ${var}=.*|export ${var}=\"\${${var}:-}\"|" "$ENV_FILE"
    fi
done
success "Dynamic variables reset in env.sh."

# ===========================================================================
# Summary
# ===========================================================================
header "Teardown Complete"
echo ""
success "All AWS resources for '${PROJECT_PREFIX}' have been deleted."
echo ""
info "Preserved:"
info "  Local SSH key: ${KEY_FILE}"
info "  env.sh:        Dynamic variables reset to defaults"
echo ""
info "To re-deploy, start from: ./00-prerequisites.sh"
