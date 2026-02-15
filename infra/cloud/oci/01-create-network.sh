#!/bin/bash
# =============================================================================
# 01-create-network.sh -- Create VCN, gateways, route tables, security lists,
#                          and subnets in OCI for the Matching Engine experiment.
#
# Idempotent: checks for existing resources by display name before creating.
#
# Usage: ./01-create-network.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

banner "Phase 1: Create VCN and Networking"

if [[ -z "${COMPARTMENT_ID}" ]]; then
    error "COMPARTMENT_ID not set. Run 00-prerequisites.sh first."
    exit 1
fi

# ===== VCN =====
step "Creating VCN: ${VCN_NAME}"
EXISTING_VCN=$(find_vcn)
if [[ -n "${EXISTING_VCN}" && "${EXISTING_VCN}" != "None" ]]; then
    VCN_ID="${EXISTING_VCN}"
    info "VCN already exists: ${VCN_ID}"
else
    VCN_ID=$(oci network vcn create \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${VCN_NAME}" \
        --cidr-blocks "[\"${VCN_CIDR}\"]" \
        --dns-label "${VCN_DNS_LABEL}" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "VCN created: ${VCN_ID}"
fi
save_state "VCN_ID" "${VCN_ID}"

# ===== Internet Gateway =====
step "Creating Internet Gateway: ${IGW_NAME}"
EXISTING_IGW=$(oci network internet-gateway list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${IGW_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_IGW}" && "${EXISTING_IGW}" != "None" ]]; then
    IGW_ID="${EXISTING_IGW}"
    info "Internet Gateway already exists: ${IGW_ID}"
else
    IGW_ID=$(oci network internet-gateway create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${IGW_NAME}" \
        --is-enabled true \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Internet Gateway created: ${IGW_ID}"
fi
save_state "IGW_ID" "${IGW_ID}"

# ===== NAT Gateway =====
step "Creating NAT Gateway: ${NAT_NAME}"
EXISTING_NAT=$(oci network nat-gateway list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${NAT_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_NAT}" && "${EXISTING_NAT}" != "None" ]]; then
    NAT_ID="${EXISTING_NAT}"
    info "NAT Gateway already exists: ${NAT_ID}"
else
    NAT_ID=$(oci network nat-gateway create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${NAT_NAME}" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "NAT Gateway created: ${NAT_ID}"
fi
save_state "NAT_ID" "${NAT_ID}"

# ===== Public Route Table =====
step "Creating Public Route Table: ${PUBLIC_RT_NAME}"
EXISTING_PUB_RT=$(oci network route-table list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${PUBLIC_RT_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_PUB_RT}" && "${EXISTING_PUB_RT}" != "None" ]]; then
    PUBLIC_RT_ID="${EXISTING_PUB_RT}"
    info "Public route table already exists: ${PUBLIC_RT_ID}"
    # Update routes in case IGW changed
    oci network route-table update \
        --rt-id "${PUBLIC_RT_ID}" \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${IGW_ID}\"}]" \
        --force \
        --wait-for-state AVAILABLE > /dev/null 2>&1 || true
else
    PUBLIC_RT_ID=$(oci network route-table create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${PUBLIC_RT_NAME}" \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${IGW_ID}\"}]" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Public route table created: ${PUBLIC_RT_ID}"
fi
save_state "PUBLIC_RT_ID" "${PUBLIC_RT_ID}"

# ===== Private Route Table =====
step "Creating Private Route Table: ${PRIVATE_RT_NAME}"
EXISTING_PRIV_RT=$(oci network route-table list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${PRIVATE_RT_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_PRIV_RT}" && "${EXISTING_PRIV_RT}" != "None" ]]; then
    PRIVATE_RT_ID="${EXISTING_PRIV_RT}"
    info "Private route table already exists: ${PRIVATE_RT_ID}"
    oci network route-table update \
        --rt-id "${PRIVATE_RT_ID}" \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${NAT_ID}\"}]" \
        --force \
        --wait-for-state AVAILABLE > /dev/null 2>&1 || true
else
    PRIVATE_RT_ID=$(oci network route-table create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${PRIVATE_RT_NAME}" \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${NAT_ID}\"}]" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Private route table created: ${PRIVATE_RT_ID}"
fi
save_state "PRIVATE_RT_ID" "${PRIVATE_RT_ID}"

# ===== Public Security List =====
step "Creating Public Security List: ${PUBLIC_SL_NAME}"

# Public ingress: SSH (22) from anywhere, HTTP (80) from anywhere for LB
PUBLIC_INGRESS='[
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":22,"max":22}},"description":"SSH access"},
  {"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":80,"max":80}},"description":"HTTP via LB"}
]'
PUBLIC_EGRESS='[{"protocol":"all","destination":"0.0.0.0/0","description":"Allow all egress"}]'

EXISTING_PUB_SL=$(oci network security-list list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${PUBLIC_SL_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_PUB_SL}" && "${EXISTING_PUB_SL}" != "None" ]]; then
    PUBLIC_SL_ID="${EXISTING_PUB_SL}"
    info "Public security list already exists: ${PUBLIC_SL_ID}"
    # Update rules
    oci network security-list update \
        --security-list-id "${PUBLIC_SL_ID}" \
        --ingress-security-rules "${PUBLIC_INGRESS}" \
        --egress-security-rules "${PUBLIC_EGRESS}" \
        --force \
        --wait-for-state AVAILABLE > /dev/null 2>&1 || true
else
    PUBLIC_SL_ID=$(oci network security-list create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${PUBLIC_SL_NAME}" \
        --ingress-security-rules "${PUBLIC_INGRESS}" \
        --egress-security-rules "${PUBLIC_EGRESS}" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Public security list created: ${PUBLIC_SL_ID}"
fi
save_state "PUBLIC_SL_ID" "${PUBLIC_SL_ID}"

# ===== Private Security List =====
step "Creating Private Security List: ${PRIVATE_SL_NAME}"

# Private ingress: SSH from VCN, app ports from VCN, Prometheus scrape, Grafana, Kafka
PRIVATE_INGRESS='[
  {"protocol":"6","source":"10.0.0.0/16","tcpOptions":{"destinationPortRange":{"min":22,"max":22}},"description":"SSH from VCN"},
  {"protocol":"6","source":"10.0.0.0/16","tcpOptions":{"destinationPortRange":{"min":3000,"max":3000}},"description":"Grafana"},
  {"protocol":"6","source":"10.0.0.0/16","tcpOptions":{"destinationPortRange":{"min":8080,"max":8080}},"description":"App HTTP (ME + Gateway)"},
  {"protocol":"6","source":"10.0.0.0/16","tcpOptions":{"destinationPortRange":{"min":9090,"max":9092}},"description":"Prometheus, ME metrics, Kafka"},
  {"protocol":"6","source":"10.0.0.0/16","tcpOptions":{"destinationPortRange":{"min":9091,"max":9091}},"description":"ME metrics port"},
  {"protocol":"1","source":"10.0.0.0/16","description":"ICMP within VCN"}
]'
PRIVATE_EGRESS='[{"protocol":"all","destination":"0.0.0.0/0","description":"Allow all egress"}]'

EXISTING_PRIV_SL=$(oci network security-list list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${PRIVATE_SL_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_PRIV_SL}" && "${EXISTING_PRIV_SL}" != "None" ]]; then
    PRIVATE_SL_ID="${EXISTING_PRIV_SL}"
    info "Private security list already exists: ${PRIVATE_SL_ID}"
    oci network security-list update \
        --security-list-id "${PRIVATE_SL_ID}" \
        --ingress-security-rules "${PRIVATE_INGRESS}" \
        --egress-security-rules "${PRIVATE_EGRESS}" \
        --force \
        --wait-for-state AVAILABLE > /dev/null 2>&1 || true
else
    PRIVATE_SL_ID=$(oci network security-list create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${PRIVATE_SL_NAME}" \
        --ingress-security-rules "${PRIVATE_INGRESS}" \
        --egress-security-rules "${PRIVATE_EGRESS}" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Private security list created: ${PRIVATE_SL_ID}"
fi
save_state "PRIVATE_SL_ID" "${PRIVATE_SL_ID}"

# ===== Public Subnet =====
step "Creating Public Subnet: ${PUBLIC_SUBNET_NAME}"
EXISTING_PUB_SUB=$(oci network subnet list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${PUBLIC_SUBNET_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_PUB_SUB}" && "${EXISTING_PUB_SUB}" != "None" ]]; then
    PUBLIC_SUBNET_ID="${EXISTING_PUB_SUB}"
    info "Public subnet already exists: ${PUBLIC_SUBNET_ID}"
else
    PUBLIC_SUBNET_ID=$(oci network subnet create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${PUBLIC_SUBNET_NAME}" \
        --cidr-block "${PUBLIC_SUBNET_CIDR}" \
        --route-table-id "${PUBLIC_RT_ID}" \
        --security-list-ids "[\"${PUBLIC_SL_ID}\"]" \
        --dns-label "${PUBLIC_SUBNET_DNS}" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Public subnet created: ${PUBLIC_SUBNET_ID}"
fi
save_state "PUBLIC_SUBNET_ID" "${PUBLIC_SUBNET_ID}"

# ===== Private Subnet =====
step "Creating Private Subnet: ${PRIVATE_SUBNET_NAME}"
EXISTING_PRIV_SUB=$(oci network subnet list \
    --compartment-id "${COMPARTMENT_ID}" \
    --vcn-id "${VCN_ID}" \
    --display-name "${PRIVATE_SUBNET_NAME}" \
    --lifecycle-state AVAILABLE \
    --query "data[0].id" --raw-output 2>/dev/null || echo "")
if [[ -n "${EXISTING_PRIV_SUB}" && "${EXISTING_PRIV_SUB}" != "None" ]]; then
    PRIVATE_SUBNET_ID="${EXISTING_PRIV_SUB}"
    info "Private subnet already exists: ${PRIVATE_SUBNET_ID}"
else
    PRIVATE_SUBNET_ID=$(oci network subnet create \
        --compartment-id "${COMPARTMENT_ID}" \
        --vcn-id "${VCN_ID}" \
        --display-name "${PRIVATE_SUBNET_NAME}" \
        --cidr-block "${PRIVATE_SUBNET_CIDR}" \
        --route-table-id "${PRIVATE_RT_ID}" \
        --security-list-ids "[\"${PRIVATE_SL_ID}\"]" \
        --prohibit-public-ip-on-vnic true \
        --dns-label "${PRIVATE_SUBNET_DNS}" \
        --query "data.id" --raw-output \
        --wait-for-state AVAILABLE)
    success "Private subnet created: ${PRIVATE_SUBNET_ID}"
fi
save_state "PRIVATE_SUBNET_ID" "${PRIVATE_SUBNET_ID}"

# ===== Summary =====
banner "Networking setup complete"
echo "  VCN:              ${VCN_ID}"
echo "  Internet Gateway: ${IGW_ID}"
echo "  NAT Gateway:      ${NAT_ID}"
echo "  Public RT:        ${PUBLIC_RT_ID}"
echo "  Private RT:       ${PRIVATE_RT_ID}"
echo "  Public SL:        ${PUBLIC_SL_ID}"
echo "  Private SL:       ${PRIVATE_SL_ID}"
echo "  Public Subnet:    ${PUBLIC_SUBNET_ID}"
echo "  Private Subnet:   ${PRIVATE_SUBNET_ID}"
echo ""
info "All OCIDs saved to ${STATE_FILE}"
info "Run 02-launch-instances.sh next."
