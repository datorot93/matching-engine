#!/bin/bash
# =============================================================================
# 03-setup-software.sh -- Install Docker, Java 21, and k6 on all instances
#
# All commands are executed via SSH through the bastion jump host.
#
# Installs:
#   - Docker CE on all private instances (me-shard-a/b/c, edge-and-tools)
#   - Java 21 (OpenJDK) on all private instances (fallback for non-Docker runs)
#   - k6 on edge-and-tools
#   - rpk CLI on me-shard-c (for Redpanda topic management)
#
# Usage: ./03-setup-software.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

banner "Phase 3: Install Software on Instances"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ -z "${BASTION_PUBLIC_IP}" ]]; then
    error "BASTION_PUBLIC_IP not set. Run 02-launch-instances.sh first."
    exit 1
fi

for var_name in ME_SHARD_A_PRIVATE_IP ME_SHARD_B_PRIVATE_IP ME_SHARD_C_PRIVATE_IP EDGE_PRIVATE_IP; do
    if [[ -z "${!var_name}" ]]; then
        error "${var_name} not set. Run 02-launch-instances.sh first."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Helper: run a command on a remote instance with retry
# ---------------------------------------------------------------------------
remote_exec() {
    local target_ip="$1"
    shift
    ssh_via_bastion "${target_ip}" "$@"
}

remote_exec_retry() {
    local target_ip="$1"
    shift
    local max_retries=5
    local retry_delay=15
    local attempt=1

    while [[ ${attempt} -le ${max_retries} ]]; do
        if remote_exec "${target_ip}" "$@" 2>/dev/null; then
            return 0
        fi
        warn "SSH to ${target_ip} failed (attempt ${attempt}/${max_retries}). Retrying in ${retry_delay}s..."
        sleep "${retry_delay}"
        attempt=$((attempt + 1))
    done

    error "SSH to ${target_ip} failed after ${max_retries} attempts."
    return 1
}

# ---------------------------------------------------------------------------
# Wait for SSH readiness on all instances
# ---------------------------------------------------------------------------
step "Waiting for SSH readiness on all instances"

ALL_PRIVATE_IPS=(
    "${ME_SHARD_A_PRIVATE_IP}"
    "${ME_SHARD_B_PRIVATE_IP}"
    "${ME_SHARD_C_PRIVATE_IP}"
    "${EDGE_PRIVATE_IP}"
)

ALL_NAMES=(
    "me-shard-a"
    "me-shard-b"
    "me-shard-c"
    "edge-and-tools"
)

# First, wait for bastion itself to accept SSH
info "Waiting for bastion SSH..."
for i in $(seq 1 20); do
    if ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           -o ConnectTimeout=5 \
           -i "${SSH_KEY_PATH}" \
           "${SSH_USER}@${BASTION_PUBLIC_IP}" \
           "echo ok" &>/dev/null; then
        success "Bastion SSH ready"
        break
    fi
    if [[ ${i} -eq 20 ]]; then
        error "Bastion SSH not ready after 100s. Check the instance."
        exit 1
    fi
    sleep 5
done

# Now wait for each private instance
for idx in "${!ALL_PRIVATE_IPS[@]}"; do
    local_ip="${ALL_PRIVATE_IPS[$idx]}"
    local_name="${ALL_NAMES[$idx]}"
    info "Waiting for ${local_name} (${local_ip}) SSH via bastion..."
    remote_exec_retry "${local_ip}" "echo ok"
    success "${local_name} SSH ready"
done

# ---------------------------------------------------------------------------
# Install Docker on all private instances
# ---------------------------------------------------------------------------
step "Installing Docker on all private instances"

DOCKER_INSTALL_SCRIPT='
set -euo pipefail

# Check if Docker is already installed and running
if command -v docker &>/dev/null && sudo systemctl is-active docker &>/dev/null; then
    echo "Docker already installed and running"
    docker --version
    exit 0
fi

# Install Docker from Oracle Linux repos
sudo dnf install -y dnf-utils
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Add opc user to docker group
sudo usermod -aG docker opc

# Verify
docker --version
echo "Docker installed successfully"
'

for idx in "${!ALL_PRIVATE_IPS[@]}"; do
    local_ip="${ALL_PRIVATE_IPS[$idx]}"
    local_name="${ALL_NAMES[$idx]}"
    step "Installing Docker on ${local_name} (${local_ip})"
    remote_exec "${local_ip}" "bash -s" <<< "${DOCKER_INSTALL_SCRIPT}"
    success "Docker installed on ${local_name}"
done

# ---------------------------------------------------------------------------
# Install Java 21 on all private instances
# ---------------------------------------------------------------------------
step "Installing Java 21 on all private instances"

JAVA_INSTALL_SCRIPT='
set -euo pipefail

# Check if Java 21 is already installed
if java -version 2>&1 | grep -q "21\."; then
    echo "Java 21 already installed"
    java -version
    exit 0
fi

# Install OpenJDK 21 from Oracle Linux repos
sudo dnf install -y java-21-openjdk java-21-openjdk-devel

# Verify
java -version
echo "Java 21 installed successfully"
'

for idx in "${!ALL_PRIVATE_IPS[@]}"; do
    local_ip="${ALL_PRIVATE_IPS[$idx]}"
    local_name="${ALL_NAMES[$idx]}"
    step "Installing Java 21 on ${local_name} (${local_ip})"
    remote_exec "${local_ip}" "bash -s" <<< "${JAVA_INSTALL_SCRIPT}"
    success "Java 21 installed on ${local_name}"
done

# ---------------------------------------------------------------------------
# Install rpk CLI on me-shard-c (for Redpanda topic management)
# ---------------------------------------------------------------------------
step "Installing rpk CLI on me-shard-c"

RPK_INSTALL_SCRIPT='
set -euo pipefail

# Check if rpk is already installed
if command -v rpk &>/dev/null; then
    echo "rpk already installed"
    rpk version
    exit 0
fi

# Install rpk (Redpanda CLI) from Redpanda RPM repo
curl -1sLf "https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.rpm.sh" | sudo -E bash
sudo dnf install -y redpanda

echo "rpk installed successfully"
rpk version
'

remote_exec "${ME_SHARD_C_PRIVATE_IP}" "bash -s" <<< "${RPK_INSTALL_SCRIPT}"
success "rpk CLI installed on me-shard-c"

# ---------------------------------------------------------------------------
# Install k6 on edge-and-tools
# ---------------------------------------------------------------------------
step "Installing k6 on edge-and-tools"

K6_INSTALL_SCRIPT='
set -euo pipefail

# Check if k6 is already installed
if command -v k6 &>/dev/null; then
    echo "k6 already installed"
    k6 version
    exit 0
fi

# Import k6 GPG key and add repo
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
    --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69 2>/dev/null || true

# Install k6 using the RPM package directly
K6_VERSION=$(curl -sL https://api.github.com/repos/grafana/k6/releases/latest | \
    python3 -c "import sys,json; print(json.load(sys.stdin)[\"tag_name\"].lstrip(\"v\"))" 2>/dev/null || echo "0.54.0")

curl -sLO "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-arm64.tar.gz"
tar xzf "k6-v${K6_VERSION}-linux-arm64.tar.gz"
sudo mv "k6-v${K6_VERSION}-linux-arm64/k6" /usr/local/bin/k6
sudo chmod +x /usr/local/bin/k6
rm -rf "k6-v${K6_VERSION}-linux-arm64" "k6-v${K6_VERSION}-linux-arm64.tar.gz"

# Verify
k6 version
echo "k6 installed successfully"
'

remote_exec "${EDGE_PRIVATE_IP}" "bash -s" <<< "${K6_INSTALL_SCRIPT}"
success "k6 installed on edge-and-tools"

# ---------------------------------------------------------------------------
# Create application directories on all private instances
# ---------------------------------------------------------------------------
step "Creating application directories"

for idx in "${!ALL_PRIVATE_IPS[@]}"; do
    local_ip="${ALL_PRIVATE_IPS[$idx]}"
    local_name="${ALL_NAMES[$idx]}"
    remote_exec "${local_ip}" "mkdir -p ~/app ~/logs"
    success "Directories created on ${local_name}"
done

# ---------------------------------------------------------------------------
# Verify installations
# ---------------------------------------------------------------------------
step "Verifying installations"

echo ""
echo "  Instance           | Docker | Java 21 | Extra"
echo "  -------------------|--------|---------|------"

for idx in "${!ALL_PRIVATE_IPS[@]}"; do
    local_ip="${ALL_PRIVATE_IPS[$idx]}"
    local_name="${ALL_NAMES[$idx]}"

    docker_ok="NO"
    java_ok="NO"
    extra=""

    if remote_exec "${local_ip}" "docker --version" &>/dev/null; then
        docker_ok="OK"
    fi

    if remote_exec "${local_ip}" "java -version 2>&1 | head -1" &>/dev/null; then
        java_ok="OK"
    fi

    if [[ "${local_name}" == "me-shard-c" ]]; then
        if remote_exec "${local_ip}" "command -v rpk" &>/dev/null; then
            extra="rpk: OK"
        else
            extra="rpk: NO"
        fi
    fi

    if [[ "${local_name}" == "edge-and-tools" ]]; then
        if remote_exec "${local_ip}" "command -v k6" &>/dev/null; then
            extra="k6: OK"
        else
            extra="k6: NO"
        fi
    fi

    printf "  %-18s | %-6s | %-7s | %s\n" "${local_name}" "${docker_ok}" "${java_ok}" "${extra}"
done

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Software installation complete"
info "All private instances have Docker and Java 21."
info "me-shard-c has rpk (Redpanda CLI)."
info "edge-and-tools has k6 (load testing)."
echo ""
info "Run 04-deploy-me.sh next."
