# Spec 4: Infrastructure and Deployment

## 1. Role and Scope

**Role Name:** Infrastructure and Deployment Developer

**Scope:** Create all infrastructure artifacts needed to run the experiment locally on k3d: Dockerfiles (already defined in Specs 1 and 2, but this role builds and tags them), the k3d cluster creation script, all Kubernetes manifests (Deployments, Services, StatefulSets, ConfigMaps), Helm values for Prometheus and Grafana, deployment orchestration scripts, and teardown scripts.

**Out of Scope:** The Java application code (Specs 1, 2), the k6 test scripts (Spec 3), and the Grafana dashboard JSON / Prometheus metric instrumentation code (Spec 5). This spec covers only the infra-as-code layer.

---

## 2. Technology Stack

| Component | Technology | Version |
|:---|:---|:---|
| Local Kubernetes | k3d (k3s-in-Docker) | latest (brew install k3d) |
| Container runtime | Docker Desktop | 20.10+ |
| Container orchestration | Kubernetes (via k3s) | 1.28+ |
| Package manager | Helm | 3.x (brew install helm) |
| Observability | Prometheus (Helm chart) | prometheus-community/prometheus |
| Dashboards | Grafana (Helm chart) | grafana/grafana |
| Message broker | Redpanda (StatefulSet) | docker.redpanda.com/redpandadata/redpanda:latest |
| Shell | Bash | 5.x |

---

## 3. Project Structure

```
infra/
  scripts/
    00-prerequisites.sh         # Check and install prerequisites
    01-create-cluster.sh        # Create k3d cluster
    02-deploy-observability.sh  # Deploy Prometheus + Grafana via Helm
    03-deploy-redpanda.sh       # Deploy Redpanda StatefulSet
    04-build-images.sh          # Build Docker images and import to k3d
    05-deploy-me-single.sh      # Deploy single ME shard (ASR 1)
    06-deploy-me-multi.sh       # Deploy 3 ME shards + Edge Gateway (ASR 2)
    07-port-forward.sh          # Set up port forwards for k6 access
    08-run-asr1-tests.sh        # Orchestrate ASR 1 test suite
    09-run-asr2-tests.sh        # Orchestrate ASR 2 test suite
    10-teardown.sh              # Delete cluster and clean up
    helpers/
      wait-for-pod.sh           # Wait for a pod to be Ready
      pause-redpanda.sh         # Pause Redpanda for Test A4
  k8s/
    namespace.yaml              # matching-engine namespace
    redpanda/
      statefulset.yaml          # Redpanda StatefulSet
      service.yaml              # Redpanda headless Service
    matching-engine/
      shard-a-deployment.yaml   # ME Shard A Deployment
      shard-a-service.yaml      # ME Shard A Service
      shard-b-deployment.yaml   # ME Shard B Deployment
      shard-b-service.yaml      # ME Shard B Service
      shard-c-deployment.yaml   # ME Shard C Deployment
      shard-c-service.yaml      # ME Shard C Service
    edge-gateway/
      deployment.yaml           # Edge Gateway Deployment
      service.yaml              # Edge Gateway Service
    monitoring/
      prometheus-values.yaml    # Helm values for Prometheus
      grafana-values.yaml       # Helm values for Grafana
      prometheus-scrape-config.yaml  # Additional scrape config ConfigMap
```

---

## 4. k3d Cluster Configuration

### 4.1 `scripts/01-create-cluster.sh`

```bash
#!/bin/bash
set -euo pipefail

CLUSTER_NAME="matching-engine-exp"

echo "Creating k3d cluster: ${CLUSTER_NAME}"

k3d cluster create ${CLUSTER_NAME} \
  --servers 1 \
  --agents 3 \
  --port "8080:80@loadbalancer" \
  --port "9090:9090@loadbalancer" \
  --port "3000:3000@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

kubectl config use-context k3d-${CLUSTER_NAME}

echo "Cluster created. Nodes:"
kubectl get nodes -o wide

echo "Creating namespace: matching-engine"
kubectl apply -f ../k8s/namespace.yaml

echo "Creating namespace: monitoring"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
```

### 4.2 `k8s/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: matching-engine
```

---

## 5. Kubernetes Manifests

### 5.1 Redpanda

#### `k8s/redpanda/statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redpanda
  namespace: matching-engine
spec:
  serviceName: redpanda
  replicas: 1
  selector:
    matchLabels:
      app: redpanda
  template:
    metadata:
      labels:
        app: redpanda
    spec:
      containers:
      - name: redpanda
        image: docker.redpanda.com/redpandadata/redpanda:latest
        args:
        - redpanda
        - start
        - --smp=1
        - --memory=1G
        - --overprovisioned
        - --kafka-addr=PLAINTEXT://0.0.0.0:9092
        - --advertise-kafka-addr=PLAINTEXT://redpanda-0.redpanda.matching-engine.svc.cluster.local:9092
        - --node-id=0
        - --check=false
        ports:
        - containerPort: 9092
          name: kafka
        - containerPort: 9644
          name: admin
        resources:
          requests:
            cpu: "1"
            memory: 1Gi
          limits:
            cpu: "2"
            memory: 2Gi
        readinessProbe:
          tcpSocket:
            port: 9092
          initialDelaySeconds: 10
          periodSeconds: 5
```

#### `k8s/redpanda/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redpanda
  namespace: matching-engine
spec:
  clusterIP: None
  ports:
  - port: 9092
    name: kafka
  - port: 9644
    name: admin
  selector:
    app: redpanda
```

### 5.2 Matching Engine Shards

#### `k8s/matching-engine/shard-a-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: me-shard-a
  namespace: matching-engine
  labels:
    app: matching-engine
    shard: a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: matching-engine
      shard: a
  template:
    metadata:
      labels:
        app: matching-engine
        shard: a
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9091"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: matching-engine
        image: matching-engine:experiment-v1
        imagePullPolicy: Never
        env:
        - name: SHARD_ID
          value: "a"
        - name: SHARD_SYMBOLS
          value: "TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D"
        - name: KAFKA_BOOTSTRAP
          value: "redpanda-0.redpanda.matching-engine.svc.cluster.local:9092"
        - name: HTTP_PORT
          value: "8080"
        - name: METRICS_PORT
          value: "9091"
        - name: WAL_PATH
          value: "/app/wal"
        - name: WAL_SIZE_MB
          value: "64"
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 9091
          name: metrics
        resources:
          requests:
            cpu: "1"
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 1Gi
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 10
```

#### `k8s/matching-engine/shard-a-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: me-shard-a
  namespace: matching-engine
spec:
  selector:
    app: matching-engine
    shard: a
  ports:
  - port: 8080
    name: http
    targetPort: 8080
  - port: 9091
    name: metrics
    targetPort: 9091
```

#### `k8s/matching-engine/shard-b-deployment.yaml`

Same structure as shard-a, with these changes:

```yaml
# Changes from shard-a:
metadata:
  name: me-shard-b
  labels:
    shard: b
spec:
  selector:
    matchLabels:
      shard: b
  template:
    metadata:
      labels:
        shard: b
    spec:
      containers:
      - env:
        - name: SHARD_ID
          value: "b"
        - name: SHARD_SYMBOLS
          value: "TEST-ASSET-E,TEST-ASSET-F,TEST-ASSET-G,TEST-ASSET-H"
```

#### `k8s/matching-engine/shard-b-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: me-shard-b
  namespace: matching-engine
spec:
  selector:
    app: matching-engine
    shard: b
  ports:
  - port: 8080
    name: http
    targetPort: 8080
  - port: 9091
    name: metrics
    targetPort: 9091
```

#### `k8s/matching-engine/shard-c-deployment.yaml`

Same structure as shard-a, with these changes:

```yaml
# Changes from shard-a:
metadata:
  name: me-shard-c
  labels:
    shard: c
spec:
  selector:
    matchLabels:
      shard: c
  template:
    metadata:
      labels:
        shard: c
    spec:
      containers:
      - env:
        - name: SHARD_ID
          value: "c"
        - name: SHARD_SYMBOLS
          value: "TEST-ASSET-I,TEST-ASSET-J,TEST-ASSET-K,TEST-ASSET-L"
```

#### `k8s/matching-engine/shard-c-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: me-shard-c
  namespace: matching-engine
spec:
  selector:
    app: matching-engine
    shard: c
  ports:
  - port: 8080
    name: http
    targetPort: 8080
  - port: 9091
    name: metrics
    targetPort: 9091
```

### 5.3 Edge Gateway

#### `k8s/edge-gateway/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-gateway
  namespace: matching-engine
  labels:
    app: edge-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: edge-gateway
  template:
    metadata:
      labels:
        app: edge-gateway
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9091"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: edge-gateway
        image: edge-gateway:experiment-v1
        imagePullPolicy: Never
        env:
        - name: HTTP_PORT
          value: "8080"
        - name: METRICS_PORT
          value: "9091"
        - name: ME_SHARD_MAP
          value: "a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080"
        - name: SHARD_SYMBOLS_MAP
          value: "a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L"
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 9091
          name: metrics
        resources:
          requests:
            cpu: "0.5"
            memory: 256Mi
          limits:
            cpu: "1"
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

#### `k8s/edge-gateway/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: edge-gateway
  namespace: matching-engine
spec:
  selector:
    app: edge-gateway
  ports:
  - port: 8080
    name: http
    targetPort: 8080
  - port: 9091
    name: metrics
    targetPort: 9091
```

### 5.4 Monitoring Helm Values

#### `k8s/monitoring/prometheus-values.yaml`

```yaml
server:
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  global:
    scrape_interval: 5s
  service:
    type: NodePort
    nodePort: 30090
  extraArgs:
    web.enable-remote-write-receiver: ""
  # Additional scrape configs for ME pods
  extraScrapeConfigs: |
    - job_name: 'matching-engine'
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names:
              - matching-engine
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
          action: keep
          regex: true
        - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
          action: replace
          target_label: __address__
          regex: (.+)
          replacement: ${1}
        - source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
          action: replace
          target_label: __address__
          regex: (.+);(.+)
          replacement: $1:$2
        - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
          action: replace
          target_label: __metrics_path__
          regex: (.+)
        - source_labels: [__meta_kubernetes_pod_label_app]
          action: replace
          target_label: app
        - source_labels: [__meta_kubernetes_pod_label_shard]
          action: replace
          target_label: shard

alertmanager:
  enabled: false

kube-state-metrics:
  enabled: false

prometheus-node-exporter:
  enabled: false

prometheus-pushgateway:
  enabled: false
```

#### `k8s/monitoring/grafana-values.yaml`

```yaml
resources:
  requests:
    cpu: 250m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

service:
  type: NodePort
  nodePort: 30000

adminPassword: admin

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-server.monitoring.svc:80
      access: proxy
      isDefault: true

dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
    - name: 'default'
      orgId: 1
      folder: ''
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards/default

dashboardsConfigMaps:
  default: grafana-dashboards
```

---

## 6. Deployment Scripts

### 6.1 `scripts/00-prerequisites.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "Checking prerequisites..."

# Check Docker
docker info > /dev/null 2>&1 || { echo "ERROR: Docker is not running. Start Docker Desktop."; exit 1; }
echo "  Docker: OK"

# Check k3d
command -v k3d > /dev/null 2>&1 || { echo "Installing k3d..."; brew install k3d; }
echo "  k3d: OK ($(k3d version | head -1))"

# Check kubectl
command -v kubectl > /dev/null 2>&1 || { echo "ERROR: kubectl not found."; exit 1; }
echo "  kubectl: OK"

# Check Helm
command -v helm > /dev/null 2>&1 || { echo "Installing helm..."; brew install helm; }
echo "  helm: OK"

# Check k6
command -v k6 > /dev/null 2>&1 || { echo "Installing k6..."; brew install k6; }
echo "  k6: OK"

# Check Java 21
java -version 2>&1 | grep -q "21" || { echo "WARNING: Java 21 not found. Needed for local builds."; }
echo "  Java: $(java -version 2>&1 | head -1)"

echo ""
echo "All prerequisites satisfied."
```

### 6.2 `scripts/04-build-images.sh`

```bash
#!/bin/bash
set -euo pipefail

CLUSTER_NAME="matching-engine-exp"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Building Matching Engine image..."
cd "${PROJECT_ROOT}/src/matching-engine"
./gradlew clean build -x test
docker build -t matching-engine:experiment-v1 .

echo "Building Edge Gateway image..."
cd "${PROJECT_ROOT}/src/edge-gateway"
./gradlew clean build -x test
docker build -t edge-gateway:experiment-v1 .

echo "Importing images into k3d cluster..."
k3d image import matching-engine:experiment-v1 -c ${CLUSTER_NAME}
k3d image import edge-gateway:experiment-v1 -c ${CLUSTER_NAME}

echo "Images built and imported successfully."
```

### 6.3 `scripts/02-deploy-observability.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo "Deploying Prometheus..."
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/../k8s/monitoring/prometheus-values.yaml" \
  --wait --timeout 120s

echo "Deploying Grafana..."
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/../k8s/monitoring/grafana-values.yaml" \
  --wait --timeout 120s

echo "Observability stack deployed."
echo "  Prometheus: http://localhost:9090 (via port-forward or NodePort 30090)"
echo "  Grafana: http://localhost:3000 (admin/admin)"
```

### 6.4 `scripts/03-deploy-redpanda.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deploying Redpanda..."
kubectl apply -f "${SCRIPT_DIR}/../k8s/redpanda/statefulset.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/redpanda/service.yaml"

echo "Waiting for Redpanda to be ready..."
kubectl wait --for=condition=Ready pod/redpanda-0 \
  -n matching-engine --timeout=120s

echo "Creating Kafka topics..."
kubectl exec -n matching-engine redpanda-0 -- \
  rpk topic create orders matches \
  --partitions 12 --replicas 1

echo "Redpanda deployed and topics created."
```

### 6.5 `scripts/05-deploy-me-single.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deploying ME Shard A (single shard for ASR 1)..."
kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-a-deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-a-service.yaml"

echo "Waiting for ME Shard A to be ready..."
bash "${SCRIPT_DIR}/helpers/wait-for-pod.sh" matching-engine "app=matching-engine,shard=a"

echo "ME Shard A deployed and ready."
echo "  Internal: http://me-shard-a.matching-engine.svc:8080"
echo "  Metrics: http://me-shard-a.matching-engine.svc:9091/metrics"
```

### 6.6 `scripts/06-deploy-me-multi.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deploying 3 ME Shards + Edge Gateway (ASR 2 configuration)..."

# Deploy all 3 shards
for shard in a b c; do
  echo "Deploying ME Shard ${shard}..."
  kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-${shard}-deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/../k8s/matching-engine/shard-${shard}-service.yaml"
done

# Deploy Edge Gateway
echo "Deploying Edge Gateway..."
kubectl apply -f "${SCRIPT_DIR}/../k8s/edge-gateway/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/edge-gateway/service.yaml"

# Wait for all pods
for shard in a b c; do
  echo "Waiting for ME Shard ${shard}..."
  bash "${SCRIPT_DIR}/helpers/wait-for-pod.sh" matching-engine "app=matching-engine,shard=${shard}"
done

echo "Waiting for Edge Gateway..."
bash "${SCRIPT_DIR}/helpers/wait-for-pod.sh" matching-engine "app=edge-gateway"

echo "All shards and Edge Gateway deployed and ready."
```

### 6.7 `scripts/07-port-forward.sh`

```bash
#!/bin/bash
set -euo pipefail

MODE="${1:-single}"  # 'single' or 'multi'

echo "Killing any existing port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

if [ "$MODE" == "single" ]; then
  echo "Setting up port-forwards for ASR 1 (single shard)..."
  kubectl port-forward svc/me-shard-a 8080:8080 -n matching-engine &
  echo "  ME Shard A: http://localhost:8080"
else
  echo "Setting up port-forwards for ASR 2 (multi shard)..."
  kubectl port-forward svc/edge-gateway 8080:8080 -n matching-engine &
  echo "  Edge Gateway: http://localhost:8080"
fi

# Prometheus remote write endpoint
kubectl port-forward svc/prometheus-server 9090:80 -n monitoring &
echo "  Prometheus: http://localhost:9090"

# Grafana
kubectl port-forward svc/grafana 3000:80 -n monitoring &
echo "  Grafana: http://localhost:3000"

echo ""
echo "Port forwards established. Run tests with k6."
echo "To stop: pkill -f 'kubectl port-forward'"
```

### 6.8 `scripts/helpers/wait-for-pod.sh`

```bash
#!/bin/bash
set -euo pipefail

NAMESPACE="${1}"
LABEL_SELECTOR="${2}"
TIMEOUT="${3:-120s}"

echo "  Waiting for pod with label ${LABEL_SELECTOR} in namespace ${NAMESPACE}..."
kubectl wait --for=condition=Ready pod \
  -l "${LABEL_SELECTOR}" \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT}"
```

### 6.9 `scripts/helpers/pause-redpanda.sh`

```bash
#!/bin/bash
# Used for Test Case A4: Kafka degradation test
# Pauses Redpanda at t=60s, resumes at the end of the test

DELAY_BEFORE_PAUSE="${1:-60}"
PAUSE_DURATION="${2:-120}"

echo "Will pause Redpanda in ${DELAY_BEFORE_PAUSE} seconds..."
sleep "${DELAY_BEFORE_PAUSE}"

echo "Pausing Redpanda (scaling to 0 replicas)..."
kubectl scale statefulset redpanda --replicas=0 -n matching-engine

echo "Redpanda paused. Will resume in ${PAUSE_DURATION} seconds..."
sleep "${PAUSE_DURATION}"

echo "Resuming Redpanda (scaling to 1 replica)..."
kubectl scale statefulset redpanda --replicas=1 -n matching-engine

echo "Waiting for Redpanda to be ready..."
kubectl wait --for=condition=Ready pod/redpanda-0 \
  -n matching-engine --timeout=120s

echo "Redpanda resumed."
```

### 6.10 `scripts/08-run-asr1-tests.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K6_DIR="${SCRIPT_DIR}/../../src/k6"
PROM_URL="http://localhost:9090/api/v1/write"
ME_URL="http://localhost:8080"

echo "========================================="
echo "  ASR 1: LATENCY VALIDATION"
echo "========================================="

echo ""
echo "--- Test A1: Warm-up (2 min) ---"
k6 run -e ME_SHARD_A_URL="${ME_URL}" "${K6_DIR}/test-asr1-a1-warmup.js"

echo ""
echo "--- Test A2: Normal Load Latency (5 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e ME_SHARD_A_URL="${ME_URL}" \
  "${K6_DIR}/test-asr1-a2-normal-load.js"

echo ""
echo "--- Test A4: Kafka Degradation (3 min) ---"
echo "Starting Redpanda pause helper in background..."
bash "${SCRIPT_DIR}/helpers/pause-redpanda.sh" 60 120 &
PAUSE_PID=$!

k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e ME_SHARD_A_URL="${ME_URL}" \
  "${K6_DIR}/test-asr1-a4-kafka-degradation.js"

wait $PAUSE_PID 2>/dev/null || true

echo ""
echo "========================================="
echo "  ASR 1 TEST SUITE COMPLETE"
echo "  Check Grafana at http://localhost:3000"
echo "========================================="
```

### 6.11 `scripts/09-run-asr2-tests.sh`

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K6_DIR="${SCRIPT_DIR}/../../src/k6"
PROM_URL="http://localhost:9090/api/v1/write"
GW_URL="http://localhost:8080"

echo "========================================="
echo "  ASR 2: SCALABILITY VALIDATION"
echo "========================================="

echo ""
echo "--- Test B2: Peak Sustained 3 Shards (5 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e GATEWAY_URL="${GW_URL}" \
  "${K6_DIR}/test-asr2-b2-peak-sustained.js"

echo ""
echo "--- Test B3: Ramp Test (10 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e GATEWAY_URL="${GW_URL}" \
  "${K6_DIR}/test-asr2-b3-ramp.js"

echo ""
echo "--- Test B4: Hot Symbol Test (5 min) ---"
k6 run \
  --out experimental-prometheus-rw="${PROM_URL}" \
  -e GATEWAY_URL="${GW_URL}" \
  "${K6_DIR}/test-asr2-b4-hot-symbol.js"

echo ""
echo "========================================="
echo "  ASR 2 TEST SUITE COMPLETE"
echo "  Check Grafana at http://localhost:3000"
echo "========================================="
```

### 6.12 `scripts/10-teardown.sh`

```bash
#!/bin/bash
set -euo pipefail

CLUSTER_NAME="matching-engine-exp"

echo "Killing port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true

echo "Deleting k3d cluster: ${CLUSTER_NAME}..."
k3d cluster delete ${CLUSTER_NAME}

echo "Cluster deleted. Clean up complete."
```

---

## 7. Resource Allocation Summary

### ASR 1 Scenario (Single Shard)

| Pod | CPU Request | CPU Limit | Mem Request | Mem Limit |
|:---|:---|:---|:---|:---|
| ME Shard A | 1.0 | 2.0 | 512Mi | 1Gi |
| Redpanda | 1.0 | 2.0 | 1Gi | 2Gi |
| Prometheus | 0.25 | 0.5 | 256Mi | 512Mi |
| Grafana | 0.25 | 0.5 | 128Mi | 256Mi |
| **Total** | **2.5** | **5.0** | **1.9Gi** | **3.8Gi** |

### ASR 2 Scenario (3 Shards)

| Pod | CPU Request | CPU Limit | Mem Request | Mem Limit |
|:---|:---|:---|:---|:---|
| ME Shard A | 1.0 | 2.0 | 512Mi | 1Gi |
| ME Shard B | 1.0 | 2.0 | 512Mi | 1Gi |
| ME Shard C | 1.0 | 2.0 | 512Mi | 1Gi |
| Edge Gateway | 0.5 | 1.0 | 256Mi | 512Mi |
| Redpanda | 1.0 | 2.0 | 1Gi | 2Gi |
| Prometheus | 0.25 | 0.5 | 256Mi | 512Mi |
| Grafana | 0.25 | 0.5 | 128Mi | 256Mi |
| **Total** | **5.0** | **10.0** | **3.2Gi** | **6.3Gi** |

Machine has 12 cores, 16GB RAM. Sufficient with headroom.

---

## 8. Environment Variables Reference

| Variable | Set In | Used By |
|:---|:---|:---|
| `SHARD_ID` | K8s Deployment env | ME process |
| `SHARD_SYMBOLS` | K8s Deployment env | ME process |
| `KAFKA_BOOTSTRAP` | K8s Deployment env | ME process |
| `HTTP_PORT` | K8s Deployment env | ME and Gateway |
| `METRICS_PORT` | K8s Deployment env | ME and Gateway |
| `ME_SHARD_MAP` | K8s Deployment env | Gateway process |
| `SHARD_SYMBOLS_MAP` | K8s Deployment env | Gateway process |

---

## 9. Acceptance Criteria

This role is "done" when:

1. **Cluster creates successfully:** `01-create-cluster.sh` produces a k3d cluster with 1 server + 3 agent nodes, all in Ready state.
2. **Observability deploys:** Prometheus and Grafana pods are Running in the `monitoring` namespace.
3. **Redpanda deploys:** `redpanda-0` pod is Running and the `orders` and `matches` topics exist.
4. **ME images build and import:** `matching-engine:experiment-v1` and `edge-gateway:experiment-v1` are available in the k3d cluster.
5. **Single-shard deployment works:** `me-shard-a` pod starts, passes health check, and is scraped by Prometheus.
6. **Multi-shard deployment works:** All 3 ME shards and the Edge Gateway are Running and passing health checks.
7. **Port forwarding works:** `07-port-forward.sh single` makes ME available at `localhost:8080` and Prometheus at `localhost:9090`.
8. **k6 can reach the ME:** `curl http://localhost:8080/health` returns 200 after port-forward.
9. **Prometheus scrapes ME metrics:** `me_matches_total` metric is visible in Prometheus after submitting a test order.
10. **Grafana is accessible:** `http://localhost:3000` loads with admin/admin and Prometheus datasource is configured.
11. **Teardown is clean:** `10-teardown.sh` deletes the cluster completely.
12. **ASR 1 test runner works:** `08-run-asr1-tests.sh` executes the warm-up and normal load tests end-to-end.
13. **ASR 2 test runner works:** `09-run-asr2-tests.sh` executes the peak sustained and ramp tests end-to-end.
14. **Redpanda pause works for A4:** `helpers/pause-redpanda.sh` scales Redpanda to 0 and back to 1 without affecting ME operation.

---

## 10. Full Deployment Sequence (Quick Start)

```bash
# From repo root:
cd infra/scripts

# 1. Check prerequisites
bash 00-prerequisites.sh

# 2. Create cluster
bash 01-create-cluster.sh

# 3. Deploy observability
bash 02-deploy-observability.sh

# 4. Deploy Redpanda
bash 03-deploy-redpanda.sh

# 5. Build and import images
bash 04-build-images.sh

# --- ASR 1 (single shard) ---
bash 05-deploy-me-single.sh
bash 07-port-forward.sh single
bash 08-run-asr1-tests.sh

# --- ASR 2 (multi shard) ---
bash 06-deploy-me-multi.sh
bash 07-port-forward.sh multi
bash 09-run-asr2-tests.sh

# --- Teardown ---
bash 10-teardown.sh
```
