#!/bin/bash
# =============================================================================
# 01-create-network.sh -- Create VPC, subnets, internet gateway, route tables,
#                          and the Network Load Balancer (NLB).
#
# Topology:
#   VPC 10.0.0.0/16
#     Public  subnet 10.0.1.0/24  (NLB, k6 load generator)
#     Private subnet 10.0.2.0/24  (ME shards, Edge GW, Redpanda, Monitoring)
#
# Idempotent: checks if resources exist (by Name tag) before creating.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

header "Phase 1: VPC and Networking"

# ---------------------------------------------------------------------------
# Helper: look up a resource by Name tag
# ---------------------------------------------------------------------------
find_resource_by_tag() {
    local resource_type="$1"  # e.g., "vpc", "subnet", "internet-gateway"
    local tag_value="$2"
    case "$resource_type" in
        vpc)
            aws ec2 describe-vpcs --region "$AWS_REGION" \
                --filters "Name=tag:Name,Values=${tag_value}" "Name=state,Values=available" \
                --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None"
            ;;
        subnet)
            aws ec2 describe-subnets --region "$AWS_REGION" \
                --filters "Name=tag:Name,Values=${tag_value}" \
                --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "None"
            ;;
        internet-gateway)
            aws ec2 describe-internet-gateways --region "$AWS_REGION" \
                --filters "Name=tag:Name,Values=${tag_value}" \
                --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "None"
            ;;
        route-table)
            aws ec2 describe-route-tables --region "$AWS_REGION" \
                --filters "Name=tag:Name,Values=${tag_value}" \
                --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "None"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Create VPC
# ---------------------------------------------------------------------------
info "Checking for existing VPC '${PROJECT_PREFIX}-vpc'..."
EXISTING_VPC=$(find_resource_by_tag "vpc" "${PROJECT_PREFIX}-vpc")

if [ "$EXISTING_VPC" != "None" ] && [ -n "$EXISTING_VPC" ]; then
    success "VPC already exists: ${EXISTING_VPC}"
    VPC_ID="$EXISTING_VPC"
else
    info "Creating VPC (${VPC_CIDR})..."
    VPC_ID=$(aws ec2 create-vpc \
        --region "$AWS_REGION" \
        --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-vpc},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'Vpc.VpcId' --output text)
    success "VPC created: ${VPC_ID}"
fi
persist_var "VPC_ID" "$VPC_ID"

# Enable DNS hostnames on VPC
info "Enabling DNS hostnames on VPC..."
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
success "DNS hostnames enabled."

# ---------------------------------------------------------------------------
# 2. Create Internet Gateway
# ---------------------------------------------------------------------------
info "Checking for existing Internet Gateway '${PROJECT_PREFIX}-igw'..."
EXISTING_IGW=$(find_resource_by_tag "internet-gateway" "${PROJECT_PREFIX}-igw")

if [ "$EXISTING_IGW" != "None" ] && [ -n "$EXISTING_IGW" ]; then
    success "Internet Gateway already exists: ${EXISTING_IGW}"
    IGW_ID="$EXISTING_IGW"
else
    info "Creating Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$AWS_REGION" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-igw},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'InternetGateway.InternetGatewayId' --output text)
    success "Internet Gateway created: ${IGW_ID}"

    info "Attaching Internet Gateway to VPC..."
    aws ec2 attach-internet-gateway \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --internet-gateway-id "$IGW_ID" 2>/dev/null || true
    success "Internet Gateway attached."
fi
persist_var "IGW_ID" "$IGW_ID"

# ---------------------------------------------------------------------------
# 3. Create Public Subnet (10.0.1.0/24)
# ---------------------------------------------------------------------------
info "Checking for existing public subnet '${PROJECT_PREFIX}-public'..."
EXISTING_PUB=$(find_resource_by_tag "subnet" "${PROJECT_PREFIX}-public")

if [ "$EXISTING_PUB" != "None" ] && [ -n "$EXISTING_PUB" ]; then
    success "Public subnet already exists: ${EXISTING_PUB}"
    PUB_SUBNET_ID="$EXISTING_PUB"
else
    info "Creating public subnet (${PUBLIC_SUBNET_CIDR}) in ${AZ}..."
    PUB_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "$PUBLIC_SUBNET_CIDR" \
        --availability-zone "$AZ" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-public},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'Subnet.SubnetId' --output text)
    success "Public subnet created: ${PUB_SUBNET_ID}"

    info "Enabling auto-assign public IPs on public subnet..."
    aws ec2 modify-subnet-attribute \
        --region "$AWS_REGION" \
        --subnet-id "$PUB_SUBNET_ID" \
        --map-public-ip-on-launch
    success "Auto-assign public IPs enabled."
fi
persist_var "PUB_SUBNET_ID" "$PUB_SUBNET_ID"

# ---------------------------------------------------------------------------
# 4. Create Private Subnet (10.0.2.0/24)
# ---------------------------------------------------------------------------
info "Checking for existing private subnet '${PROJECT_PREFIX}-private'..."
EXISTING_PRIV=$(find_resource_by_tag "subnet" "${PROJECT_PREFIX}-private")

if [ "$EXISTING_PRIV" != "None" ] && [ -n "$EXISTING_PRIV" ]; then
    success "Private subnet already exists: ${EXISTING_PRIV}"
    PRIV_SUBNET_ID="$EXISTING_PRIV"
else
    info "Creating private subnet (${PRIVATE_SUBNET_CIDR}) in ${AZ}..."
    PRIV_SUBNET_ID=$(aws ec2 create-subnet \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "$PRIVATE_SUBNET_CIDR" \
        --availability-zone "$AZ" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-private},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'Subnet.SubnetId' --output text)
    success "Private subnet created: ${PRIV_SUBNET_ID}"
fi
persist_var "PRIV_SUBNET_ID" "$PRIV_SUBNET_ID"

# ---------------------------------------------------------------------------
# 5. Create Route Table for Public Subnet
# ---------------------------------------------------------------------------
info "Checking for existing public route table '${PROJECT_PREFIX}-public-rt'..."
EXISTING_RT=$(find_resource_by_tag "route-table" "${PROJECT_PREFIX}-public-rt")

if [ "$EXISTING_RT" != "None" ] && [ -n "$EXISTING_RT" ]; then
    success "Public route table already exists: ${EXISTING_RT}"
    PUB_RT_ID="$EXISTING_RT"
else
    info "Creating public route table..."
    PUB_RT_ID=$(aws ec2 create-route-table \
        --region "$AWS_REGION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT_PREFIX}-public-rt},{Key=Project,Value=${PROJECT_PREFIX}}]" \
        --query 'RouteTable.RouteTableId' --output text)
    success "Public route table created: ${PUB_RT_ID}"

    info "Adding default route to Internet Gateway..."
    aws ec2 create-route \
        --region "$AWS_REGION" \
        --route-table-id "$PUB_RT_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$IGW_ID" >/dev/null
    success "Default route added."

    info "Associating route table with public subnet..."
    aws ec2 associate-route-table \
        --region "$AWS_REGION" \
        --route-table-id "$PUB_RT_ID" \
        --subnet-id "$PUB_SUBNET_ID" >/dev/null
    success "Route table associated with public subnet."
fi
persist_var "PUB_RT_ID" "$PUB_RT_ID"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Networking Complete"
echo ""
info "VPC:            ${VPC_ID}"
info "Internet GW:    ${IGW_ID}"
info "Public subnet:  ${PUB_SUBNET_ID} (${PUBLIC_SUBNET_CIDR})"
info "Private subnet: ${PRIV_SUBNET_ID} (${PRIVATE_SUBNET_CIDR})"
info "Route table:    ${PUB_RT_ID}"
echo ""
info "Next step: Run 02-create-security-groups.sh"
