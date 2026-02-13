# Matching Engine

A high-performance, single-threaded matching engine for a centralized order book exchange. Built with Java 21 and the LMAX Disruptor pattern to achieve sub-200ms p99 matching latency at 1,000+ matches per minute, with horizontal scalability to 5,000 matches/min via asset-symbol sharding.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Technology Stack](#technology-stack)
3. [Project Structure](#project-structure)
4. [Key Design Decisions](#key-design-decisions)
5. [Prerequisites](#prerequisites)
6. [How to Build](#how-to-build)
7. [How to Run Locally (Java)](#how-to-run-locally-java)
8. [How to Test Locally](#how-to-test-locally)
9. [Deploy to Kubernetes (k3d)](#deploy-to-kubernetes-k3d)
10. [Edge Gateway](#edge-gateway)
11. [API Reference](#api-reference)
12. [Configuration](#configuration)
13. [Prometheus Metrics](#prometheus-metrics)
14. [Docker](#docker)

---

## Architecture Overview

The Matching Engine implements an **Event-Driven Architecture (EDA)** with a **single-threaded matching core** per shard. The critical path is:

```
HTTP Request → Disruptor Ring Buffer → OrderEventHandler → Order Book → Match → WAL → Kafka → Metrics
     │                                        │ (single thread, no locks)
     └── Returns 200 ACCEPTED immediately     └── All processing is sequential
         (fire-and-publish)
```

### Core Components

| Component | Responsibility |
|:---|:---|
| **OrderHttpHandler** | Accepts `POST /orders`, validates input, publishes to the ring buffer, returns 200 immediately |
| **LMAX Disruptor** | Lock-free ring buffer (131,072 slots) that sequences all incoming orders for single-threaded processing |
| **OrderEventHandler** | The single-threaded event processor: validates, matches, appends to WAL, publishes to Kafka, records metrics |
| **OrderBook** | In-memory `TreeMap`-based order book with price-time priority. Bids descending, asks ascending. |
| **PriceTimePriorityMatcher** | Matches incoming orders against the opposite side. O(log P + F) per order. |
| **WriteAheadLog** | Memory-mapped file (`MappedByteBuffer`) for durability. Flush deferred to `endOfBatch`. |
| **EventPublisher** | Async Kafka producer (`acks=0`, `max.block.ms=1`). Never blocks the matching thread. |
| **MetricsRegistry** | 11 Prometheus metrics covering latency, throughput, order book health, and saturation. |

### Matching Algorithm

The engine uses **price-time priority** matching:

1. An incoming order is compared against the **opposite side** of the order book.
2. **Price priority:** Best price is matched first (lowest ask for a buy, highest bid for a sell).
3. **Time priority:** Within the same price level, the earliest order is matched first (FIFO).
4. **Partial fills:** If the incoming order's quantity exceeds the resting order's, the resting order is fully filled and removed. Matching continues with the next resting order.
5. **Resting:** If no more matching prices exist, the remaining quantity rests in the book at its limit price.

---

## Technology Stack

| Component | Technology | Version |
|:---|:---|:---|
| Language | Java | 21 (LTS) |
| Build tool | Gradle (Kotlin DSL) | 8.x |
| Ring Buffer | LMAX Disruptor | 4.0.0 |
| Order Book | `java.util.TreeMap` + `java.util.ArrayDeque` | JDK 21 |
| WAL | `java.nio.MappedByteBuffer` | JDK 21 |
| HTTP Server | `com.sun.net.httpserver.HttpServer` | JDK 21 |
| Kafka Producer | `org.apache.kafka:kafka-clients` | 3.7.0 |
| Prometheus | `io.prometheus:prometheus-metrics-*` | 1.3.1 |
| JSON | `com.google.code.gson:gson` | 2.11.0 |
| JVM | Eclipse Temurin | 21, ZGC, 256-512MB heap |

---

## Project Structure

```
src/matching-engine/
  build.gradle.kts                  # Gradle build with all dependencies and fat JAR task
  settings.gradle.kts               # Project name
  Dockerfile                        # eclipse-temurin:21-jre-alpine with ZGC flags
  src/main/java/com/matchingengine/
    MatchingEngineApp.java           # Main entry point and startup sequence
    config/
      ShardConfig.java               # Environment variable parsing
    http/
      OrderHttpHandler.java          # POST /orders (fire-and-publish)
      HealthHttpHandler.java         # GET /health
      SeedHttpHandler.java           # POST /seed (pre-populate order book)
    disruptor/
      OrderEvent.java                # Pre-allocated ring buffer event
      OrderEventFactory.java         # Creates empty OrderEvent instances
      OrderEventTranslator.java      # Copies HTTP request data into ring buffer slot
      OrderEventHandler.java         # Single-threaded event processor (match + WAL + Kafka)
    domain/
      Side.java                      # Enum: BUY, SELL
      OrderType.java                 # Enum: LIMIT, MARKET
      OrderStatus.java               # Enum: NEW, PARTIALLY_FILLED, FILLED, CANCELLED, REJECTED
      Order.java                     # Order entity with fill(), isFilled(), isActive()
      OrderId.java                   # Value object wrapping String
      Price.java                     # Value object wrapping long (cents), implements Comparable
      PriceLevel.java                # FIFO queue (ArrayDeque) at a single price point
      OrderBook.java                 # TreeMap-based bids/asks with HashMap order index
      OrderBookManager.java          # Symbol -> OrderBook registry
      MatchResult.java               # Single fill result
      MatchResultSet.java            # Collection of fills for one incoming order
    matching/
      MatchingAlgorithm.java         # Interface
      PriceTimePriorityMatcher.java  # Price-time priority implementation
    wal/
      WriteAheadLog.java             # Memory-mapped WAL with deferred flush
    publishing/
      EventPublisher.java            # Async Kafka producer wrapper
    metrics/
      MetricsRegistry.java           # All 11 Prometheus metrics
```

---

## Key Design Decisions

| Decision | Rationale |
|:---|:---|
| **Single-threaded matching** | No locks, no synchronization, no contention. The LMAX Disruptor serializes all events onto one thread. This is the fastest path for an in-memory order book. |
| **Prices as `long` (cents)** | Avoids floating-point rounding errors. `$150.00` = `15000` cents. |
| **TreeMap for order book** | `O(log P)` access to best bid/ask via `firstEntry()`. Bids use `Comparator.reverseOrder()` so `firstKey()` = highest bid. |
| **ArrayDeque for price levels** | FIFO time priority within a price level. `O(1)` for `peekFirst()`, `pollFirst()`, and `addLast()`. |
| **Fire-and-publish HTTP** | `POST /orders` returns 200 immediately after publishing to the ring buffer. The caller does NOT wait for matching. This keeps HTTP response times minimal. |
| **WAL flush on endOfBatch** | `MappedByteBuffer.force()` is expensive. By deferring it to `endOfBatch`, disk syncs are amortized across multiple events. |
| **Kafka `max.block.ms=1`** | The Kafka producer never blocks the matching thread. If the broker is down, events are silently dropped (logged + counted) but matching continues unaffected. |

---

## Prerequisites

| Tool | Version | Installation |
|:---|:---|:---|
| Java JDK | 21 | `sudo apt install openjdk-21-jdk` (Ubuntu) or `brew install openjdk@21` (macOS) |
| Docker | 20.10+ | [Install Docker](https://docs.docker.com/engine/install/) |

Gradle is bundled via the Gradle Wrapper (`./gradlew`), so no separate installation is needed.

Optional (for the full experiment pipeline):

| Tool | Purpose |
|:---|:---|
| k3d | Local Kubernetes cluster |
| kubectl | Kubernetes CLI |
| Helm | Deploy Prometheus and Grafana |
| k6 | Load testing |

---

## How to Build

### Build the fat JAR

```bash
cd src/matching-engine
./gradlew build
```

This produces a fat JAR with all dependencies bundled at:

```
src/matching-engine/build/libs/matching-engine.jar
```

### Build the Docker image

```bash
cd src/matching-engine
docker build -t matching-engine:experiment-v1 .
```

The Docker image uses `eclipse-temurin:21-jre-alpine` and runs with these JVM flags:

```
-XX:+UseZGC -Xms256m -Xmx512m -XX:+AlwaysPreTouch
```

---

## How to Run Locally (Java)

### Run locally with Java

```bash
cd src/matching-engine
java -jar build/libs/matching-engine.jar
```

The engine starts with default configuration:
- HTTP server on port **8080** (orders, health, seed)
- Prometheus metrics on port **9091**
- Shard ID: `a`
- Symbols: `TEST-ASSET-A`, `TEST-ASSET-B`, `TEST-ASSET-C`, `TEST-ASSET-D`

If Kafka/Redpanda is not running, the engine logs warnings but operates normally — matching is not affected by Kafka availability.

### Run with custom configuration

Override defaults via environment variables:

```bash
SHARD_ID=b \
SHARD_SYMBOLS=TEST-ASSET-E,TEST-ASSET-F,TEST-ASSET-G,TEST-ASSET-H \
HTTP_PORT=8082 \
METRICS_PORT=9092 \
KAFKA_BOOTSTRAP=localhost:9092 \
java -jar build/libs/matching-engine.jar
```

### Run with Docker

```bash
docker run -p 8080:8080 -p 9091:9091 matching-engine:experiment-v1
```

With custom environment:

```bash
docker run -p 8080:8080 -p 9091:9091 \
  -e SHARD_ID=a \
  -e SHARD_SYMBOLS=TEST-ASSET-A,TEST-ASSET-B \
  -e KAFKA_BOOTSTRAP=host.docker.internal:9092 \
  matching-engine:experiment-v1
```

### Verify it's running

```bash
curl http://localhost:8080/health
# Expected: {"status":"UP","shardId":"a"}
```

---

## How to Test Locally

### 1. Health check

```bash
curl http://localhost:8080/health
```

Expected response (HTTP 200):

```json
{"status":"UP","shardId":"a"}
```

### 2. Pre-seed the order book with resting SELL orders

```bash
curl -X POST http://localhost:8080/seed \
  -H "Content-Type: application/json" \
  -d '{
    "orders": [
      {"orderId":"seed-sell-1","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15100,"quantity":50},
      {"orderId":"seed-sell-2","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15200,"quantity":100},
      {"orderId":"seed-sell-3","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15000,"quantity":75}
    ]
  }'
```

Expected response (HTTP 200):

```json
{"seeded":3}
```

### 3. Submit a BUY order that matches

Submit a buy order at price 15100 cents ($151.00). This will match against `seed-sell-3` (price 15000, the lowest ask) and `seed-sell-1` (price 15100):

```bash
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{
    "orderId":"test-buy-1",
    "symbol":"TEST-ASSET-A",
    "side":"BUY",
    "type":"LIMIT",
    "price":15100,
    "quantity":100
  }'
```

Expected response (HTTP 200):

```json
{"status":"ACCEPTED","orderId":"test-buy-1","shardId":"a","timestamp":1707600000001}
```

The order is accepted into the ring buffer and matching happens asynchronously on the Disruptor thread.

### 4. Submit a BUY order that rests (no match)

Submit a buy at price 14000 cents ($140.00), well below the lowest ask:

```bash
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{
    "orderId":"test-buy-2",
    "symbol":"TEST-ASSET-A",
    "side":"BUY",
    "type":"LIMIT",
    "price":14000,
    "quantity":50
  }'
```

This order rests in the book (visible via `me_orderbook_depth` gauge).

### 5. Verify via Prometheus metrics

```bash
# Check that matches were executed
curl -s http://localhost:9091/metrics | grep me_matches_total

# Check matching latency
curl -s http://localhost:9091/metrics | grep me_match_duration_seconds_count

# Check order book depth
curl -s http://localhost:9091/metrics | grep me_orderbook_depth

# Check orders received counter
curl -s http://localhost:9091/metrics | grep me_orders_received_total

# Check ring buffer utilization
curl -s http://localhost:9091/metrics | grep me_ringbuffer_utilization_ratio

# Check JVM metrics
curl -s http://localhost:9091/metrics | grep jvm_gc
```

### 6. Test validation and error cases

```bash
# Unknown symbol → 400 REJECTED
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId":"err-1","symbol":"UNKNOWN","side":"BUY","type":"LIMIT","price":15000,"quantity":100}'

# Invalid side → 400 REJECTED
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId":"err-2","symbol":"TEST-ASSET-A","side":"INVALID","type":"LIMIT","price":15000,"quantity":100}'

# Negative price → 400 REJECTED
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId":"err-3","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":-1,"quantity":100}'

# Wrong HTTP method → 405
curl http://localhost:8080/orders
```

### 7. Full end-to-end matching test script

```bash
#!/bin/bash
set -e

ME_URL="${ME_URL:-http://localhost:8080}"
METRICS_URL="${METRICS_URL:-http://localhost:9091}"

echo "=== Matching Engine End-to-End Test ==="

echo ""
echo "1. Health check..."
HEALTH=$(curl -s "$ME_URL/health")
echo "   Response: $HEALTH"

echo ""
echo "2. Seeding order book with 3 SELL orders..."
SEED=$(curl -s -X POST "$ME_URL/seed" \
  -H "Content-Type: application/json" \
  -d '{"orders":[
    {"orderId":"e2e-sell-1","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15000,"quantity":50},
    {"orderId":"e2e-sell-2","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15100,"quantity":100},
    {"orderId":"e2e-sell-3","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15200,"quantity":75}
  ]}')
echo "   Response: $SEED"

echo ""
echo "3. Submitting aggressive BUY order (should match sell-1 fully)..."
BUY=$(curl -s -X POST "$ME_URL/orders" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"e2e-buy-1","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":15000,"quantity":50}')
echo "   Response: $BUY"

echo ""
echo "4. Waiting 1 second for matching to complete..."
sleep 1

echo ""
echo "5. Checking metrics..."
MATCHES=$(curl -s "$METRICS_URL/metrics" | grep 'me_matches_total{' | head -1)
echo "   $MATCHES"

DEPTH=$(curl -s "$METRICS_URL/metrics" | grep 'me_orderbook_depth{' || echo "   (no depth data)")
echo "   $DEPTH"

LATENCY=$(curl -s "$METRICS_URL/metrics" | grep 'me_match_duration_seconds_count{' | head -1)
echo "   $LATENCY"

echo ""
echo "=== Test Complete ==="
```

---

## Deploy to Kubernetes (k3d)

The project includes a complete local Kubernetes deployment using **k3d** (k3s-in-Docker). This deploys the Matching Engine, Edge Gateway, Redpanda (Kafka), Prometheus, and Grafana — everything needed to run the full experiment.

### Deployment Topology

**ASR 1 — Single Shard (Latency Validation):**

```
k6 ──► ME Shard A ──► Redpanda
            │
            └──► Prometheus ──► Grafana
```

**ASR 2 — Multi Shard (Scalability Validation):**

```
k6 ──► Edge Gateway ──► ME Shard A ─┐
                   ├──► ME Shard B  ├──► Redpanda
                   └──► ME Shard C ─┘
                                        │
                                        └──► Prometheus ──► Grafana
```

### Prerequisites

All of these must be installed (use `infra/scripts/00-prerequisites.sh` to verify):

| Tool | Purpose |
|:---|:---|
| Docker | Container runtime (must be running) |
| k3d | Creates local Kubernetes cluster inside Docker |
| kubectl | Kubernetes CLI |
| Helm | Deploys Prometheus and Grafana via Helm charts |
| k6 | Load testing (for running ASR tests) |

### Resource Requirements

| Scenario | CPU (request) | CPU (limit) | Memory (request) | Memory (limit) |
|:---|:---|:---|:---|:---|
| ASR 1 (single shard) | 2.5 cores | 5.0 cores | 1.9 GiB | 3.8 GiB |
| ASR 2 (3 shards) | 5.0 cores | 10.0 cores | 3.2 GiB | 6.3 GiB |

### Step-by-Step Deployment

All scripts are in `infra/scripts/`. Run them from the repo root:

#### Step 1: Verify prerequisites

```bash
bash infra/scripts/00-prerequisites.sh
```

Checks that Docker, k3d, kubectl, Helm, k6, and Java 21 are installed.

#### Step 2: Create the k3d cluster

```bash
bash infra/scripts/01-create-cluster.sh
```

Creates a k3d cluster named `matching-engine-exp` with:
- 1 server node + 3 agent nodes
- Port mappings: 8080 (HTTP), 9090 (Prometheus), 3000 (Grafana)
- Traefik disabled (not needed)
- Namespaces: `matching-engine` and `monitoring`

**Verify:** `kubectl get nodes` should show 4 nodes in Ready state.

#### Step 3: Deploy observability stack

```bash
bash infra/scripts/02-deploy-observability.sh
```

Installs Prometheus and Grafana via Helm in the `monitoring` namespace.

**Verify:** `kubectl get pods -n monitoring` — all pods should be Running.

#### Step 4: Deploy Redpanda (message broker)

```bash
bash infra/scripts/03-deploy-redpanda.sh
```

Deploys a single-node Redpanda instance and creates the `orders` and `matches` Kafka topics (12 partitions each).

**Verify:** `kubectl get pods -n matching-engine` — `redpanda-0` should be Running.

#### Step 5: Build and import Docker images

```bash
bash infra/scripts/04-build-images.sh
```

Builds both Java applications (`matching-engine` and `edge-gateway`), creates Docker images, and imports them into the k3d cluster.

**Verify:** `docker images | grep experiment-v1` should show both images.

#### Step 6a: Deploy single shard (ASR 1)

```bash
bash infra/scripts/05-deploy-me-single.sh
```

Deploys only ME Shard A. Used for latency validation tests.

**Verify:** `kubectl get pods -n matching-engine -l app=matching-engine`

#### Step 6b: Deploy multi shard (ASR 2)

```bash
bash infra/scripts/06-deploy-me-multi.sh
```

Deploys all 3 ME shards + the Edge Gateway. Used for scalability tests.

**Verify:** `kubectl get pods -n matching-engine` — should show 3 ME pods + 1 gateway pod + Redpanda.

#### Step 7: Set up port-forwards

```bash
# For single shard (ASR 1):
bash infra/scripts/07-port-forward.sh single

# For multi shard (ASR 2):
bash infra/scripts/07-port-forward.sh multi
```

This makes services accessible locally:

| Service | URL | Mode |
|:---|:---|:---|
| ME Shard A | http://localhost:8080 | `single` |
| Edge Gateway | http://localhost:8080 | `multi` |
| Prometheus | http://localhost:9090 | both |
| Grafana | http://localhost:3000 | both |

#### Step 8: Verify the deployment

```bash
# Health check (ME or Gateway depending on mode)
curl http://localhost:8080/health

# Submit a test order
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"orderId":"k8s-test-1","symbol":"TEST-ASSET-A","side":"BUY","type":"LIMIT","price":15000,"quantity":100}'

# Check Prometheus is scraping ME metrics
curl -s http://localhost:9090/api/v1/targets | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    if 'matching-engine' in t.get('labels', {}).get('job', ''):
        print(f\"  {t['labels'].get('app','?')} shard={t['labels'].get('shard','?')} -> {t['health']}\")
"

# Open Grafana
echo "Open http://localhost:3000 (admin/admin)"
```

### Teardown

```bash
bash infra/scripts/10-teardown.sh
```

Deletes the k3d cluster and kills all port-forwards. Clean removal.

### Quick Reference: Full Deployment Sequence

```bash
# From repo root:
bash infra/scripts/00-prerequisites.sh
bash infra/scripts/01-create-cluster.sh
bash infra/scripts/02-deploy-observability.sh
bash infra/scripts/03-deploy-redpanda.sh
bash infra/scripts/04-build-images.sh

# --- ASR 1 (single shard) ---
bash infra/scripts/05-deploy-me-single.sh
bash infra/scripts/07-port-forward.sh single
curl http://localhost:8080/health   # verify

# --- ASR 2 (multi shard) ---
bash infra/scripts/06-deploy-me-multi.sh
bash infra/scripts/07-port-forward.sh multi
curl http://localhost:8080/health   # verify

# --- Teardown ---
bash infra/scripts/10-teardown.sh
```

### Infrastructure File Structure

```
infra/
  k8s/
    namespace.yaml                          # matching-engine namespace
    redpanda/
      statefulset.yaml                      # Single-node Redpanda
      service.yaml                          # Headless service
    matching-engine/
      shard-a-deployment.yaml               # ME Shard A (symbols A-D)
      shard-a-service.yaml
      shard-b-deployment.yaml               # ME Shard B (symbols E-H)
      shard-b-service.yaml
      shard-c-deployment.yaml               # ME Shard C (symbols I-L)
      shard-c-service.yaml
    edge-gateway/
      deployment.yaml                       # Symbol-hash routing proxy
      service.yaml
    monitoring/
      prometheus-values.yaml                # Helm values: 5s scrape, remote write
      grafana-values.yaml                   # Helm values: admin/admin, Prometheus DS
  scripts/
    00-prerequisites.sh                     # Verify tools
    01-create-cluster.sh                    # Create k3d cluster
    02-deploy-observability.sh              # Deploy Prometheus + Grafana
    03-deploy-redpanda.sh                   # Deploy Redpanda + create topics
    04-build-images.sh                      # Build JARs + Docker images + import
    05-deploy-me-single.sh                  # Deploy 1 shard (ASR 1)
    06-deploy-me-multi.sh                   # Deploy 3 shards + gateway (ASR 2)
    07-port-forward.sh                      # Port-forwards (single/multi mode)
    08-run-asr1-tests.sh                    # Orchestrate ASR 1 k6 tests
    09-run-asr2-tests.sh                    # Orchestrate ASR 2 k6 tests
    10-teardown.sh                          # Delete cluster
    helpers/
      wait-for-pod.sh                       # Wait for pod readiness
      pause-redpanda.sh                     # Pause/resume Redpanda (test A4)
```

### Troubleshooting

| Problem | Solution |
|:---|:---|
| `k3d cluster create` fails | Make sure Docker is running: `docker info` |
| Pods stuck in `ImagePullBackOff` | Images not imported. Re-run `bash infra/scripts/04-build-images.sh` |
| Port-forward dies | Re-run `bash infra/scripts/07-port-forward.sh single` (or `multi`) |
| Prometheus not scraping ME | Check pod annotations: `kubectl describe pod <me-pod> -n matching-engine` — should have `prometheus.io/scrape: "true"` |
| Redpanda not starting | Check resources: `kubectl describe pod redpanda-0 -n matching-engine` — may need more memory |
| `curl localhost:8080` connection refused | Port-forward not running. Check: `ps aux \| grep port-forward` |

---

## Edge Gateway

The Edge Gateway is a lightweight HTTP reverse proxy that routes orders to the correct ME shard based on the order's symbol. It is required for multi-shard (ASR 2) tests.

### How it works

```
k6 ──POST /orders {"symbol":"TEST-ASSET-E"}──► Edge Gateway
                                                    │
                                          Looks up symbol → shard "b"
                                                    │
                                          Forwards to http://me-shard-b:8080/orders
                                                    │
                                          Returns ME response pass-through
```

### Symbol-to-Shard Mapping

| Shard | Symbols |
|:---|:---|
| `a` | TEST-ASSET-A, TEST-ASSET-B, TEST-ASSET-C, TEST-ASSET-D |
| `b` | TEST-ASSET-E, TEST-ASSET-F, TEST-ASSET-G, TEST-ASSET-H |
| `c` | TEST-ASSET-I, TEST-ASSET-J, TEST-ASSET-K, TEST-ASSET-L |

### Build and run standalone

```bash
cd src/edge-gateway
./gradlew build
docker build -t edge-gateway:experiment-v1 .

# Run with ME on port 8081
ME_SHARD_MAP="a=http://localhost:8081" \
SHARD_SYMBOLS_MAP="a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D" \
java -jar build/libs/edge-gateway.jar
```

### Gateway API

| Method | Path | Purpose |
|:---|:---|:---|
| POST | `/orders` | Route order to correct shard by symbol |
| POST | `/seed/{shardId}` | Forward seed request to specific shard |
| GET | `/health` | Health check |
| GET | `/metrics` (port 9091) | Prometheus metrics |

### Gateway Configuration

| Variable | Default | Description |
|:---|:---|:---|
| `HTTP_PORT` | `8080` | Gateway listening port |
| `METRICS_PORT` | `9091` | Prometheus metrics port |
| `ME_SHARD_MAP` | `a=http://me-shard-a:8080,...` | Shard ID to ME URL mapping |
| `SHARD_SYMBOLS_MAP` | `a=TEST-ASSET-A:...,b=TEST-ASSET-E:...` | Shard ID to symbols mapping |

### Gateway Metrics

| Metric | Type | Labels |
|:---|:---|:---|
| `gw_requests_total` | Counter | `shard`, `status` |
| `gw_request_duration_seconds` | Histogram | `shard` |
| `gw_routing_errors_total` | Counter | `reason` |

---

## API Reference

### POST /orders

Submit an order for matching.

**Request:**

```json
{
  "orderId": "k6-buy-00001",
  "symbol": "TEST-ASSET-A",
  "side": "BUY",
  "type": "LIMIT",
  "price": 15000,
  "quantity": 100,
  "timestamp": 1707600000000
}
```

| Field | Type | Required | Description |
|:---|:---|:---|:---|
| `orderId` | string | yes | Unique order identifier |
| `symbol` | string | yes | Asset symbol (must be in this shard's symbol list) |
| `side` | string | yes | `"BUY"` or `"SELL"` |
| `type` | string | no | `"LIMIT"` (default) or `"MARKET"` |
| `price` | long | yes | Price in **cents** (e.g., 15000 = $150.00) |
| `quantity` | long | yes | Order quantity (must be > 0) |
| `timestamp` | long | no | Epoch milliseconds (defaults to current time) |

**Responses:**

| Status | Body | Condition |
|:---|:---|:---|
| 200 | `{"status":"ACCEPTED","orderId":"...","shardId":"a","timestamp":...}` | Order published to ring buffer |
| 400 | `{"status":"REJECTED","orderId":"...","reason":"..."}` | Validation failure |
| 503 | `{"status":"REJECTED","orderId":"...","reason":"Ring buffer full"}` | Ring buffer at capacity |

### POST /seed

Pre-populate the order book with resting orders. Bypasses the ring buffer and matching logic. For test setup only.

**Request:**

```json
{
  "orders": [
    {"orderId":"seed-1","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15100,"quantity":50},
    {"orderId":"seed-2","symbol":"TEST-ASSET-A","side":"SELL","type":"LIMIT","price":15200,"quantity":100}
  ]
}
```

**Response (200):**

```json
{"seeded":2}
```

### GET /health

Health check endpoint.

**Response (200):**

```json
{"status":"UP","shardId":"a"}
```

### GET /metrics (port 9091)

Prometheus metrics endpoint. Returns all metrics in Prometheus exposition format.

---

## Configuration

All configuration is via environment variables with sensible defaults:

| Variable | Default | Description |
|:---|:---|:---|
| `SHARD_ID` | `a` | Shard identifier (used in metric labels) |
| `SHARD_SYMBOLS` | `TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D` | Comma-separated list of symbols this shard handles |
| `HTTP_PORT` | `8080` | Port for order submission, health, and seed endpoints |
| `METRICS_PORT` | `9091` | Port for Prometheus `/metrics` endpoint |
| `KAFKA_BOOTSTRAP` | `localhost:9092` | Kafka/Redpanda bootstrap servers |
| `WAL_PATH` | `/tmp/wal` | Directory for the Write-Ahead Log file |
| `WAL_SIZE_MB` | `64` | WAL file size in megabytes |
| `RING_BUFFER_SIZE` | `131072` | Disruptor ring buffer size (must be a power of 2) |

---

## Prometheus Metrics

### Latency metrics (histograms)

| Metric | Description | Buckets (seconds) |
|:---|:---|:---|
| `me_match_duration_seconds` | End-to-end: order received to match result | 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0 |
| `me_order_validation_duration_seconds` | Time spent validating | 0.0001, 0.0005, 0.001, 0.005, 0.01 |
| `me_orderbook_insertion_duration_seconds` | Time spent inserting into order book | 0.0001, 0.0005, 0.001, 0.005, 0.01 |
| `me_matching_algorithm_duration_seconds` | Time spent in the matching algorithm | 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05 |
| `me_wal_append_duration_seconds` | Time spent appending to WAL | 0.001, 0.005, 0.01, 0.025, 0.05, 0.1 |
| `me_event_publish_duration_seconds` | Time spent publishing to Kafka | 0.0001, 0.0005, 0.001, 0.005, 0.01 |

### Throughput metrics (counters)

| Metric | Labels | Description |
|:---|:---|:---|
| `me_matches_total` | `shard` | Total matches executed |
| `me_orders_received_total` | `shard`, `side` | Total orders received |

### Health metrics (gauges)

| Metric | Labels | Description |
|:---|:---|:---|
| `me_orderbook_depth` | `shard`, `side` | Current number of resting orders |
| `me_orderbook_price_levels` | `shard`, `side` | Current distinct price levels |
| `me_ringbuffer_utilization_ratio` | `shard` | Ring buffer fill level (0.0 to 1.0) |

### JVM metrics (auto-registered)

GC pause durations, heap memory usage, thread counts, and other standard JVM metrics are automatically exposed via `prometheus-metrics-instrumentation-jvm`.

---

## Docker

### Dockerfile

The Docker image uses a minimal Alpine-based JRE with the Z Garbage Collector:

```dockerfile
FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app
COPY build/libs/matching-engine.jar matching-engine.jar
RUN mkdir -p /app/wal

EXPOSE 8080 9091

ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-Xms256m", \
  "-Xmx512m", \
  "-XX:+AlwaysPreTouch", \
  "-jar", "matching-engine.jar"]
```

### Build and run

```bash
cd src/matching-engine
./gradlew build
docker build -t matching-engine:experiment-v1 .
docker run -p 8080:8080 -p 9091:9091 matching-engine:experiment-v1
```

### Multi-shard deployment

Run 3 shards on different ports:

```bash
# Shard A
docker run -p 8080:8080 -p 9091:9091 \
  -e SHARD_ID=a -e SHARD_SYMBOLS=TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D \
  matching-engine:experiment-v1

# Shard B
docker run -p 8082:8080 -p 9092:9091 \
  -e SHARD_ID=b -e SHARD_SYMBOLS=TEST-ASSET-E,TEST-ASSET-F,TEST-ASSET-G,TEST-ASSET-H \
  matching-engine:experiment-v1

# Shard C
docker run -p 8084:8080 -p 9093:9091 \
  -e SHARD_ID=c -e SHARD_SYMBOLS=TEST-ASSET-I,TEST-ASSET-J,TEST-ASSET-K,TEST-ASSET-L \
  matching-engine:experiment-v1
```
