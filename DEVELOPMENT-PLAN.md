# Matching Engine: Development Plan

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites and Environment Setup](#2-prerequisites-and-environment-setup)
3. [Agent-to-Phase Mapping](#3-agent-to-phase-mapping)
4. [Development Phases](#4-development-phases)
5. [Phase 0: Environment Setup](#5-phase-0-environment-setup)
6. [Phase 1: Matching Engine Core](#6-phase-1-matching-engine-core)
7. [Phase 2: Edge Gateway](#7-phase-2-edge-gateway)
8. [Phase 3: Infrastructure and Deployment](#8-phase-3-infrastructure-and-deployment)
9. [Phase 4: Load Testing Scripts](#9-phase-4-load-testing-scripts)
10. [Phase 5: Integration Glue](#10-phase-5-integration-glue)
11. [Phase 6: Local Experiment Execution](#11-phase-6-local-experiment-execution)
12. [Phase 7: Cloud Deployment (Optional)](#12-phase-7-cloud-deployment-optional)
13. [How to Run Locally](#13-how-to-run-locally)
14. [ASR Validation Test Plan](#14-asr-validation-test-plan)
15. [Cloud Compatibility Strategy](#15-cloud-compatibility-strategy)
16. [Dependency Graph](#16-dependency-graph)

---

## 1. Overview

This plan outlines the step-by-step implementation of the Matching Engine project, from environment setup through ASR validation. The project validates two Architecturally Significant Requirements:

- **ASR 1 (Latency):** Matching execution < 200ms (p99) at 1,000 matches/min.
- **ASR 2 (Scalability):** Scale from 1,000 to 5,000 matches/min via asset-symbol sharding.

**Design principles:**

- **Local-first, cloud-compatible:** All development and initial testing runs locally on k3d. Docker images and Kubernetes manifests are portable to AWS EKS/EC2 and Oracle Cloud OKE/A1.Flex without code changes.
- **Spec-driven:** Every implementation task traces back to one of the 5 specifications in `spec/`.
- **Agent-assisted:** Each phase maps to a specialized Claude agent that owns the domain expertise.

---

## 2. Prerequisites and Environment Setup

Before any code is written, the development machine must have the following tools installed and verified:

| Tool | Version | Purpose |
|:---|:---|:---|
| Java (JDK) | 21 (LTS) | Matching Engine & Edge Gateway |
| Gradle | 8.x | Build tool |
| Docker | 20.10+ | Container images |
| k3d | latest | Local Kubernetes cluster |
| kubectl | 1.28+ | Kubernetes CLI |
| Helm | 3.x | Prometheus & Grafana deployment |
| k6 | latest | Load testing |
| jq | latest | JSON processing in scripts |
| python3 | 3.x | Results collection scripts |
| curl | any | HTTP testing and smoke tests |
| git | any | Version control |

**Agent:** Use the `environment-setup` agent (Phase 0) to automatically detect the OS, install missing tools, and verify the complete toolchain.

---

## 3. Agent-to-Phase Mapping

| Phase | Agent | Specs Covered | Color |
|:---|:---|:---|:---|
| 0 | `environment-setup` | Prerequisites | yellow |
| 1 | `matching-engine-developer` | Spec 1 | blue |
| 2 | `matching-engine-developer` | Spec 2 | blue |
| 3 | `infrastructure-developer` | Spec 4 | cyan |
| 4 | `load-testing-developer` | Spec 3 | green |
| 5 | `infrastructure-developer` | Spec 5 | cyan |
| 6 | All agents (orchestration) | All specs | -- |
| 7 | `latency-scalability-architect` | Cloud docs | yellow |

---

## 4. Development Phases

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 6 ──► Phase 7
 Setup       ME Core     Gateway     Infra/K8s   k6 Tests    Glue        Run Exp     Cloud
                                                                         (Local)     (Optional)
```

**Critical path:** Phases 0 → 1 → 2 → 3 → 4 → 5 → 6 are sequential. Each depends on the previous phase's outputs. Phase 7 is optional and runs after successful local validation.

**Parallelism opportunity:** Phase 3 (infrastructure scripts and K8s manifests) can begin in parallel with Phase 2 (Edge Gateway) since the manifests reference Docker image names, not the built images. However, the infrastructure scripts cannot be fully tested until Phases 1 and 2 produce working Docker images.

---

## 5. Phase 0: Environment Setup

**Agent:** `environment-setup`
**Duration estimate:** First task
**Spec:** N/A (cross-cutting prerequisite)

### Tasks

| # | Task | Acceptance Criteria |
|:---|:---|:---|
| 0.1 | Detect OS and architecture | Output: OS name, version, CPU arch (x86_64 or arm64) |
| 0.2 | Check/install Java 21 | `java --version` shows 21.x |
| 0.3 | Check/install Gradle 8.x | `gradle --version` shows 8.x |
| 0.4 | Check/install Docker | `docker info` succeeds, daemon running |
| 0.5 | Check/install k3d | `k3d version` succeeds |
| 0.6 | Check/install kubectl | `kubectl version --client` shows 1.28+ |
| 0.7 | Check/install Helm 3 | `helm version` shows 3.x |
| 0.8 | Check/install k6 | `k6 version` succeeds |
| 0.9 | Check/install jq, python3, curl | All three available |
| 0.10 | WSL2 checks (if applicable) | Docker accessible, memory >= 8GB, disk >= 10GB free |
| 0.11 | Summary report | All 11 tools listed with status OK |

### Outputs
- All tools installed and verified
- Development machine ready for Phase 1

---

## 6. Phase 1: Matching Engine Core

**Agent:** `matching-engine-developer`
**Spec:** [spec-1-matching-engine-core.md](spec/spec-1-matching-engine-core.md)

This is the core of the system. Everything else depends on a working Matching Engine.

### Tasks

| # | Task | Acceptance Criteria |
|:---|:---|:---|
| 1.1 | Create project structure | `src/matching-engine/` with Gradle Kotlin DSL, `settings.gradle.kts`, directory layout per Spec 1 Section 3 |
| 1.2 | Implement `build.gradle.kts` | All dependencies (Disruptor 4.0.0, Kafka clients 3.7.x, Prometheus 1.3.x, Gson 2.11.x, SLF4J). Fat JAR task. Java 21 toolchain. |
| 1.3 | Implement domain model | `Side`, `OrderType`, `OrderStatus` enums. `Price` record, `OrderId` record, `Order` class, `PriceLevel` (ArrayDeque), `OrderBook` (TreeMap with `reverseOrder()` for bids), `OrderBookManager`, `MatchResult`, `MatchResultSet` |
| 1.4 | Implement `PriceTimePriorityMatcher` | Price-time priority algorithm. O(log P + F). Handles partial fills, full fills, and resting orders. |
| 1.5 | Implement `ShardConfig` | Environment variable parsing: `SHARD_ID`, `SHARD_SYMBOLS`, `HTTP_PORT`, `METRICS_PORT`, `KAFKA_BOOTSTRAP`, `WAL_PATH`, `WAL_SIZE_MB` |
| 1.6 | Implement `MetricsRegistry` | All 11 Prometheus metrics with exact names and bucket configs from Spec 1 Section 4.9. JVM metrics auto-registration. |
| 1.7 | Implement `WriteAheadLog` | Memory-mapped file via `MappedByteBuffer`. Length-prefixed records. Deferred `force()` on endOfBatch. |
| 1.8 | Implement `EventPublisher` | Kafka producer with `acks=0`, `max.block.ms=1`, `linger.ms=5`. Non-blocking send. Error logging without propagation. |
| 1.9 | Implement Disruptor components | `OrderEvent`, `OrderEventFactory`, `OrderEventTranslator`, `OrderEventHandler`. Ring buffer size 131072, `ProducerType.MULTI`, `YieldingWaitStrategy`. |
| 1.10 | Implement HTTP handlers | `OrderHttpHandler` (POST /orders), `HealthHttpHandler` (GET /health), `SeedHttpHandler` (POST /seed). Fire-and-publish pattern for orders. |
| 1.11 | Implement `MatchingEngineApp` | Main entry point. Startup sequence per Spec 1 Section 4.1. Shutdown hook. |
| 1.12 | Create `Dockerfile` | Based on `eclipse-temurin:21-jre-alpine`. JVM flags: `-XX:+UseZGC -Xms256m -Xmx512m -XX:+AlwaysPreTouch`. |
| 1.13 | Build and test locally | `./gradlew build` succeeds. `java -jar` starts the engine. Health, seed, orders, and matching work via curl. Metrics exposed on port 9091. |

### Verification

```bash
# Build
cd src/matching-engine && ./gradlew build

# Run locally (needs Kafka/Redpanda or it logs warnings but runs)
java -jar build/libs/matching-engine-*.jar

# Test endpoints
curl http://localhost:8080/health
curl -X POST http://localhost:8080/seed -H "Content-Type: application/json" \
  -d '{"orders":[{"orderId":"test-sell-1","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15100,"quantity":50}]}'
curl -X POST http://localhost:8080/orders -H "Content-Type: application/json" \
  -d '{"orderId":"test-buy-1","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":15100,"quantity":50}'
curl http://localhost:9091/metrics | grep me_matches_total

# Docker image
docker build -t matching-engine:experiment-v1 .
```

### Outputs
- Compilable, runnable Matching Engine JAR
- Working Docker image
- All 11 Prometheus metrics exposed

---

## 7. Phase 2: Edge Gateway

**Agent:** `matching-engine-developer`
**Spec:** [spec-2-edge-gateway.md](spec/spec-2-edge-gateway.md)
**Depends on:** Phase 1 (ME must be running for integration testing)

### Tasks

| # | Task | Acceptance Criteria |
|:---|:---|:---|
| 2.1 | Create project structure | `src/edge-gateway/` with Gradle Kotlin DSL, directory layout per Spec 2 Section 3 |
| 2.2 | Implement `build.gradle.kts` | Dependencies: Prometheus 1.3.x, Gson 2.11.x, SLF4J. Fat JAR task. Java 21 toolchain. |
| 2.3 | Implement `GatewayConfig` | Parse `ME_SHARD_MAP` and `SHARD_SYMBOLS_MAP` from environment variables |
| 2.4 | Implement `ConsistentHashRouter` | Explicit symbol-to-shard mapping (no hash function needed for the experiment). `getShardUrl(symbol)` and `getShardId(symbol)`. |
| 2.5 | Implement `OrderProxyHandler` | Parse symbol from JSON body, route to correct shard via `SymbolRouter`, forward request via `HttpClient`, return response pass-through. Error handling for unknown symbols (400), shard unavailable (502), timeout (504). |
| 2.6 | Implement `SeedProxyHandler` | Extract shardId from path (`/seed/{shardId}`), forward to `{shardUrl}/seed`. |
| 2.7 | Implement `HealthHandler` | Returns `{"status":"UP","component":"edge-gateway"}` |
| 2.8 | Implement `GatewayMetrics` | 3 metrics: `gw_requests_total`, `gw_request_duration_seconds`, `gw_routing_errors_total`. Exact names and buckets from Spec 2 Section 4.5. |
| 2.9 | Implement `EdgeGatewayApp` | Main entry point. Startup sequence per Spec 2 Section 4.1. |
| 2.10 | Create `Dockerfile` | `eclipse-temurin:21-jre-alpine`. JVM flags: `-Xms128m -Xmx256m`. |
| 2.11 | Integration test | Gateway routes orders correctly to ME shard. Test with ME running locally on a different port. |

### Verification

```bash
# Build
cd src/edge-gateway && ./gradlew build

# Run (with ME running on port 8081)
ME_SHARD_MAP="a=http://localhost:8081" \
SHARD_SYMBOLS_MAP="a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D" \
java -jar build/libs/edge-gateway-*.jar

# Test routing
curl http://localhost:8080/health
curl -X POST http://localhost:8080/orders -H "Content-Type: application/json" \
  -d '{"orderId":"gw-test-1","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":15000,"quantity":100}'

# Docker image
docker build -t edge-gateway:experiment-v1 .
```

### Outputs
- Compilable, runnable Edge Gateway JAR
- Working Docker image
- Symbol-hash routing verified

---

## 8. Phase 3: Infrastructure and Deployment

**Agent:** `infrastructure-developer`
**Spec:** [spec-4-infrastructure.md](spec/spec-4-infrastructure.md)
**Depends on:** Phase 1 and Phase 2 (Docker images must build)

### Tasks

| # | Task | Acceptance Criteria |
|:---|:---|:---|
| 3.1 | Create `infra/` directory structure | All directories per Spec 4 Section 3 |
| 3.2 | Create Kubernetes namespace YAML | `k8s/namespace.yaml` for `matching-engine` namespace |
| 3.3 | Create Redpanda manifests | `k8s/redpanda/statefulset.yaml` and `service.yaml`. Readiness probe on port 9092. |
| 3.4 | Create ME shard manifests (A, B, C) | 6 files: `shard-{a,b,c}-deployment.yaml`, `shard-{a,b,c}-service.yaml`. Prometheus annotations. `imagePullPolicy: Never`. |
| 3.5 | Create Edge Gateway manifests | `k8s/edge-gateway/deployment.yaml` and `service.yaml`. Prometheus annotations. |
| 3.6 | Create Prometheus Helm values | `k8s/monitoring/prometheus-values.yaml`. 5s scrape interval. Remote write receiver enabled. Pod annotation-based service discovery for `matching-engine` namespace. Disable alertmanager, node-exporter, pushgateway, kube-state-metrics. |
| 3.7 | Create Grafana Helm values | `k8s/monitoring/grafana-values.yaml`. Admin password `admin`. Prometheus datasource auto-configured. Dashboard ConfigMap reference. |
| 3.8 | Create script `00-prerequisites.sh` | Check Docker, k3d, kubectl, Helm, k6, Java 21 |
| 3.9 | Create script `01-create-cluster.sh` | k3d cluster with 1 server + 3 agents, port mappings, Traefik disabled, namespaces created |
| 3.10 | Create script `02-deploy-observability.sh` | Helm install Prometheus + Grafana in `monitoring` namespace |
| 3.11 | Create script `03-deploy-redpanda.sh` | Apply Redpanda manifests, wait for ready, create Kafka topics (`orders`, `matches`) |
| 3.12 | Create script `04-build-images.sh` | Gradle build both projects, Docker build, k3d image import |
| 3.13 | Create script `05-deploy-me-single.sh` | Deploy ME Shard A only (ASR 1 config) |
| 3.14 | Create script `06-deploy-me-multi.sh` | Deploy all 3 ME shards + Edge Gateway (ASR 2 config) |
| 3.15 | Create script `07-port-forward.sh` | Supports `single` and `multi` modes. Kill existing forwards first. |
| 3.16 | Create scripts `08-run-asr1-tests.sh` and `09-run-asr2-tests.sh` | Orchestrate k6 test execution with Prometheus remote write |
| 3.17 | Create script `10-teardown.sh` | Delete k3d cluster, kill port-forwards |
| 3.18 | Create helper scripts | `helpers/wait-for-pod.sh`, `helpers/pause-redpanda.sh` |
| 3.19 | Make all scripts executable | `chmod +x infra/scripts/*.sh infra/scripts/helpers/*.sh` |
| 3.20 | End-to-end infrastructure test | Run scripts 00 through 07. All pods Running. Port-forwards working. Prometheus scraping ME metrics. |

### Verification

```bash
cd infra/scripts
bash 00-prerequisites.sh
bash 01-create-cluster.sh
bash 02-deploy-observability.sh
bash 03-deploy-redpanda.sh
bash 04-build-images.sh
bash 05-deploy-me-single.sh
bash 07-port-forward.sh single

# Verify
kubectl get pods -A
curl http://localhost:8081/health
curl http://localhost:9090/api/v1/targets | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['data']['activeTargets'], indent=2))"
```

### Outputs
- Working k3d cluster with all components deployed
- Port-forwards providing local access
- Prometheus scraping all ME pods

---

## 9. Phase 4: Load Testing Scripts

**Agent:** `load-testing-developer`
**Spec:** [spec-3-load-testing.md](spec/spec-3-load-testing.md)
**Depends on:** Phase 3 (k3d cluster must be running with deployed ME)

### Tasks

| # | Task | Acceptance Criteria |
|:---|:---|:---|
| 4.1 | Create `src/k6/` directory structure | `lib/` directory with shared modules |
| 4.2 | Implement `lib/config.js` | Shared constants: URLs, symbols, price ranges, thresholds |
| 4.3 | Implement `lib/orderGenerator.js` | `generateAggressiveBuyOrder()`, `generatePassiveBuyOrder()`, `generateMixedOrder()` (60/40 split), `generateSeedSellOrder()`, `randomSymbol()` |
| 4.4 | Implement `lib/seedHelper.js` | `seedShard()` (via Gateway), `seedShardDirect()` (direct to ME) |
| 4.5 | Implement ASR 1 test scripts | `test-asr1-a1-warmup.js`, `test-asr1-a2-normal-load.js`, `test-asr1-a3-depth-variation.js`, `test-asr1-a4-kafka-degradation.js` |
| 4.6 | Implement ASR 2 test scripts | `test-asr2-b1-baseline.js`, `test-asr2-b2-peak-sustained.js`, `test-asr2-b3-ramp.js`, `test-asr2-b4-hot-symbol.js` |
| 4.7 | Implement `seed-orderbooks.js` | Standalone seed script with `single`/`multi` modes |
| 4.8 | Validate all scripts | `k6 inspect <script>` parses without errors for all 8 test scripts + seed script |

### Verification

```bash
# Validate all scripts parse
for script in src/k6/test-*.js src/k6/seed-orderbooks.js; do
  echo "Checking: $script"
  k6 inspect "$script"
done

# Run warm-up test against live cluster
k6 run -e ME_SHARD_A_URL=http://localhost:8081 src/k6/test-asr1-a1-warmup.js
```

### Outputs
- 8 test scripts + 1 seed script + 3 shared modules
- All scripts validated and ready to execute

---

## 10. Phase 5: Integration Glue

**Agent:** `infrastructure-developer`
**Spec:** [spec-5-integration-glue.md](spec/spec-5-integration-glue.md)
**Depends on:** Phase 3 (Prometheus and Grafana deployed), Phase 4 (k6 scripts ready)

### Tasks

| # | Task | Acceptance Criteria |
|:---|:---|:---|
| 5.1 | Create Grafana dashboard JSON | `infra/grafana/dashboards/matching-engine-experiment.json`. 6 panels (2x3 grid). UID: `me-experiment`. Refresh: 5s. |
| 5.2 | Create Prometheus recording rules | `infra/prometheus/recording-rules.yaml`. Rules for p99/p95/p50 latency, throughput, latency budget components, GC pause. 5s evaluation interval. |
| 5.3 | Create dashboard ConfigMap | Kubernetes ConfigMap with `grafana_dashboard: "1"` label for Grafana sidecar discovery |
| 5.4 | Integrate recording rules into Prometheus Helm values | Add `serverFiles.recording_rules.yml` to `prometheus-values.yaml` |
| 5.5 | Create `smoke-test.sh` | Tests: ME health, order submission, seed, matching, Prometheus metrics existence, Prometheus scrape targets, Grafana accessibility. Exit 1 on any failure. |
| 5.6 | Create `collect-results.sh` | Queries Prometheus HTTP API for ASR 1 (p99 latency, GC pauses, budget breakdown) and ASR 2 (aggregate throughput, per-shard latency). Pass/fail evaluation. |
| 5.7 | Deploy and verify dashboard | Dashboard appears in Grafana, all 6 panels render data when ME is under load |
| 5.8 | Run smoke test | `smoke-test.sh` passes all checks |

### Verification

```bash
# Deploy dashboard
kubectl create configmap grafana-dashboards \
  --from-file=matching-engine-experiment.json=infra/grafana/dashboards/matching-engine-experiment.json \
  -n monitoring
kubectl label configmap grafana-dashboards grafana_dashboard=1 -n monitoring

# Smoke test
bash infra/scripts/smoke-test.sh

# Open Grafana
# http://localhost:3000 (admin/admin) -> Dashboard: "Matching Engine Experiment"
```

### Outputs
- Grafana dashboard with 6 panels rendering live data
- Prometheus recording rules producing pre-computed metrics
- Passing smoke test
- Working results collection script

---

## 11. Phase 6: Local Experiment Execution

**Agent:** All agents (orchestration)
**Depends on:** All previous phases (0-5)

This is the full experiment run that validates both ASRs.

### Tasks

| # | Task | Test Cases | Duration |
|:---|:---|:---|:---|
| 6.1 | Run ASR 1: Latency validation | A1 (warm-up), A2 (normal load), A3 (depth variation), A4 (Kafka degradation) | ~15 min |
| 6.2 | Collect ASR 1 results | `collect-results.sh asr1` | 1 min |
| 6.3 | Switch to multi-shard deployment | `06-deploy-me-multi.sh`, `07-port-forward.sh multi` | 3 min |
| 6.4 | Run ASR 2: Scalability validation | B1 (baseline), B2 (peak sustained), B3 (ramp), B4 (hot symbol) | ~25 min |
| 6.5 | Collect ASR 2 results | `collect-results.sh asr2` | 1 min |
| 6.6 | Review Grafana dashboards | Visual verification of all 6 panels | 5 min |
| 6.7 | Document results | Pass/fail for both ASRs, screenshots, observations | -- |

### Full Execution Sequence

See [Section 13: How to Run Locally](#13-how-to-run-locally) for the complete command sequence.

---

## 12. Phase 7: Cloud Deployment (Optional)

**Agent:** `latency-scalability-architect`
**Depends on:** Phase 6 (local validation must pass first)

Deploy the same Docker images and experiment to a cloud provider to validate ASRs in a more realistic environment.

### AWS Deployment

Reference: [docs/experiment-cloud-aws.md](docs/experiment-cloud-aws.md)

| Component | AWS Service |
|:---|:---|
| Load Balancer | Network Load Balancer (NLB) |
| Gateway + ME Shards | EC2 Graviton (ARM64) instances |
| Redpanda | EC2 (self-managed) |
| Monitoring | EC2 (self-hosted Prometheus + Grafana) |
| WAL storage | EBS gp3 volumes |

### Oracle Cloud (OCI) Deployment

Reference: [docs/experiment-cloud-oci.md](docs/experiment-cloud-oci.md)

| Component | OCI Service |
|:---|:---|
| Load Balancer | OCI Flexible LB (Always Free) |
| Gateway + ME Shards | A1.Flex Ampere (ARM64, Always Free) |
| Redpanda | A1.Flex (self-managed) |
| Monitoring | A1.Flex (self-hosted) |

**Key advantage:** The OCI Always Free tier can run the entire experiment at $0.00 cost.

### Cloud Compatibility

The project is cloud-compatible by design:

1. **Docker images are multi-arch:** `eclipse-temurin:21-jre-alpine` supports both AMD64 and ARM64 natively.
2. **No k3d dependency in images:** The application code has zero dependency on k3d. k3d is only the local orchestrator.
3. **Environment-variable driven:** All configuration (shard IDs, symbols, Kafka bootstrap, ports) is injected via environment variables. Changing deployment target only requires different env var values.
4. **Standard Kubernetes manifests:** The same K8s manifests work on k3d, EKS, OKE, or any Kubernetes distribution.
5. **Helm charts are portable:** Prometheus and Grafana Helm charts are cloud-agnostic.

---

## 13. How to Run Locally

### Quick Start (Full Experiment)

```bash
# ============================================================
# STEP 0: Verify prerequisites
# ============================================================
cd infra/scripts
bash 00-prerequisites.sh

# ============================================================
# STEP 1: Create local Kubernetes cluster
# ============================================================
bash 01-create-cluster.sh

# ============================================================
# STEP 2: Deploy observability stack (Prometheus + Grafana)
# ============================================================
bash 02-deploy-observability.sh

# ============================================================
# STEP 3: Deploy message broker (Redpanda)
# ============================================================
bash 03-deploy-redpanda.sh

# ============================================================
# STEP 4: Build Docker images and import into k3d
# ============================================================
bash 04-build-images.sh

# ============================================================
# STEP 5: Run ASR 1 (Latency) Experiment
# ============================================================
bash 05-deploy-me-single.sh        # Deploy single ME shard
bash 07-port-forward.sh single     # Set up port-forwards
bash ../scripts/smoke-test.sh      # Verify wiring
bash 08-run-asr1-tests.sh          # Run tests A1-A4
bash ../scripts/collect-results.sh asr1   # Collect results

# ============================================================
# STEP 6: Run ASR 2 (Scalability) Experiment
# ============================================================
bash 06-deploy-me-multi.sh         # Deploy 3 shards + Gateway
bash 07-port-forward.sh multi      # Switch port-forwards
bash 09-run-asr2-tests.sh          # Run tests B1-B4
bash ../scripts/collect-results.sh asr2   # Collect results

# ============================================================
# STEP 7: Review results in Grafana
# ============================================================
# Open http://localhost:3000 (admin/admin)
# Navigate to: Matching Engine Experiment dashboard

# ============================================================
# STEP 8: Teardown
# ============================================================
bash 10-teardown.sh
```

### Running Individual Tests

```bash
# ASR 1: Normal load test only (primary ASR 1 test)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/test-asr1-a2-normal-load.js

# ASR 2: Peak sustained test only (primary ASR 2 test)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8081 \
  src/k6/test-asr2-b2-peak-sustained.js
```

### Accessing Services (After Port-Forward)

| Service | URL | Credentials |
|:---|:---|:---|
| Matching Engine / Edge Gateway | http://localhost:8081 | -- |
| Prometheus | http://localhost:9090 | -- |
| Grafana | http://localhost:3000 | admin / admin |

---

## 14. ASR Validation Test Plan

### ASR 1: Latency Validation

**Hypothesis:** A single-threaded Matching Engine with an in-memory Order Book (TreeMap-based) can execute matches in < 200ms at p99 under normal load (1,000 matches/min).

| Test | Script | Duration | Rate | Purpose |
|:---|:---|:---|:---|:---|
| A1: Warm-up | `test-asr1-a1-warmup.js` | 2 min | 500/min | JVM warm-up, discard results |
| **A2: Normal Load** | `test-asr1-a2-normal-load.js` | 5 min | 1,000/min | **PRIMARY TEST** -- p99 < 200ms |
| A3: Depth Variation | `test-asr1-a3-depth-variation.js` | 3x3 min | 1,000/min | Shallow/medium/deep Order Book |
| A4: Kafka Degradation | `test-asr1-a4-kafka-degradation.js` | 3 min | 1,000/min | Decoupling proof (pause Redpanda at t=60s) |

**Pass criteria (from test A2):**

| Metric | Pass | Fail |
|:---|:---|:---|
| p99 `me_match_duration_seconds` | < 200ms | >= 200ms |
| p99 `http_req_duration` (k6) | < 200ms | >= 200ms |
| Error rate | < 1% | >= 1% |
| Max GC pause | < 5ms | >= 10ms |

### ASR 2: Scalability Validation

**Hypothesis:** The Matching Engine can scale from 1,000 to 5,000 matches/min by adding horizontal shards partitioned by asset symbol.

| Test | Script | Duration | Rate | Shards |
|:---|:---|:---|:---|:---|
| B1: Baseline | `test-asr2-b1-baseline.js` | 3 min | 1,000/min | 1 |
| **B2: Peak Sustained** | `test-asr2-b2-peak-sustained.js` | 5 min | 5,000/min | 3 |
| B3: Ramp | `test-asr2-b3-ramp.js` | 10 min | 1K→2.5K→5K/min | 1→2→3 |
| B4: Hot Symbol | `test-asr2-b4-hot-symbol.js` | 5 min | 5,000/min (80% to 1 symbol) | 3 |

**Pass criteria (from test B2):**

| Metric | Pass | Fail |
|:---|:---|:---|
| Aggregate throughput | >= 4,750 matches/min for >= 4 min | < 4,750 matches/min |
| Per-shard p99 latency | < 200ms per shard | >= 200ms on any shard |
| Linear scaling ratio | throughput(3) >= 0.9 * 3 * throughput(1) | Sub-linear |
| Shard isolation | Shard A p99 unchanged (+/- 5%) when Shard B load increases | > 5% degradation |

---

## 15. Cloud Compatibility Strategy

The local development approach ensures cloud portability through these design decisions:

| Decision | Local (k3d) | AWS | Oracle Cloud (OCI) |
|:---|:---|:---|:---|
| Container runtime | Docker + k3d | EKS / EC2 + Docker | OKE / A1.Flex + Docker |
| Image registry | k3d import (no registry) | Amazon ECR | OCI Container Registry |
| Kubernetes | k3s via k3d | EKS (managed) or k3s on EC2 | OKE (managed) or k3s on A1 |
| Load balancer | kubectl port-forward | NLB | OCI Flexible LB |
| Monitoring | Helm charts (local) | Same Helm charts on EKS | Same Helm charts on OKE |
| Config injection | K8s env vars | K8s env vars (same manifests) | K8s env vars (same manifests) |

**What changes between local and cloud:**
1. Image source: `imagePullPolicy: Never` → `imagePullPolicy: Always` (with registry URL)
2. Service type: `ClusterIP` → `LoadBalancer` or `NodePort`
3. Resource limits: May increase for dedicated VMs
4. Storage: `/tmp/wal` → EBS gp3 volume mounts or block volumes

**What stays the same:**
- Application code (zero changes)
- Docker images (same base, same JVM flags)
- Prometheus metric names
- Grafana dashboards
- k6 test scripts (only URL environment variables change)

---

## 16. Dependency Graph

```
Phase 0: Environment Setup
    │
    ▼
Phase 1: Matching Engine Core (Spec 1)
    │
    ├──────────────────────┐
    ▼                      ▼
Phase 2: Edge Gateway    Phase 3: Infrastructure
  (Spec 2)                (Spec 4) [manifests only,
    │                      can start early]
    │                      │
    └──────┬───────────────┘
           ▼
    Phase 3: Infrastructure (Spec 4)
    [full test requires built images]
           │
           ▼
    Phase 4: Load Testing Scripts (Spec 3)
    [needs running cluster for validation]
           │
           ▼
    Phase 5: Integration Glue (Spec 5)
    [needs Prometheus, Grafana, and k6 scripts]
           │
           ▼
    Phase 6: Local Experiment Execution
    [runs all tests, collects results]
           │
           ▼
    Phase 7: Cloud Deployment (Optional)
    [AWS or OCI, same images and manifests]
```

---

*Related documents:*
- *[Experiment Design](docs/experiment-design.md)*
- *[Initial Architecture](docs/architecture/initial-architecture.md)*
- *[Refined Architecture](docs/architecture/refined-architecture.md)*
- *[AWS Cloud Deployment](docs/experiment-cloud-aws.md)*
- *[OCI Cloud Deployment](docs/experiment-cloud-oci.md)*
- *Specifications: [Spec 1](spec/spec-1-matching-engine-core.md), [Spec 2](spec/spec-2-edge-gateway.md), [Spec 3](spec/spec-3-load-testing.md), [Spec 4](spec/spec-4-infrastructure.md), [Spec 5](spec/spec-5-integration-glue.md)*
