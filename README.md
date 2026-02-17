# Matching Engine

A high-performance, single-threaded matching engine for a centralized order book exchange. Built with Java 21 and the LMAX Disruptor pattern to achieve sub-200ms p99 matching latency at 1,000+ matches per minute, with horizontal scalability to 5,000 matches/min via asset-symbol sharding.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Architectural Styles, Patterns, and Tactics](#architectural-styles-patterns-and-tactics)
3. [Technology Stack](#technology-stack)
4. [Project Structure](#project-structure)
5. [Key Design Decisions](#key-design-decisions)
6. [Structured Logging and Observability](#structured-logging-and-observability)
7. [Prerequisites](#prerequisites)
8. [How to Build](#how-to-build)
9. [How to Run Locally (Java)](#how-to-run-locally-java)
10. [How to Test Locally](#how-to-test-locally)
11. [Deploy to Kubernetes (k3d)](#deploy-to-kubernetes-k3d)
12. [Edge Gateway](#edge-gateway)
13. [Load Testing (k6)](#load-testing-k6)
14. [API Reference](#api-reference)
15. [Configuration](#configuration)
16. [Prometheus Metrics](#prometheus-metrics)
17. [Docker](#docker)
18. [Cloud Deployment](#cloud-deployment)
19. [Documentation and Diagrams](#documentation-and-diagrams)

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

### Horizontal Scalability (Sharding)

The system scales from 1,000 to 5,000 matches/min via **asset-symbol sharding**. Each shard owns a disjoint set of symbols and operates an independent order book and matching thread:

```
                                    ┌─ ME Shard A ─ symbols A, B, C, D
k6 ──► Edge Gateway (router) ──────┼─ ME Shard B ─ symbols E, F, G, H
                                    └─ ME Shard C ─ symbols I, J, K, L
```

- **Partitioning scheme:** Static symbol-to-shard mapping configured via environment variables. The Edge Gateway uses an O(1) lookup table (`HashMap<symbol, shardUrl>`) to route each order to the correct shard.
- **No cross-shard coordination:** Each shard processes its symbols independently. No distributed locks, no two-phase commit, no inter-shard communication.
- **Linear throughput scaling:** 3 shards = 3x the matching capacity of a single shard. Each shard handles ~1,680 orders/min, collectively reaching 5,040 orders/min.
- **Fault isolation:** A failure in Shard B does not affect Shards A or C. Each shard maintains its own WAL, Kafka producer, and Prometheus metrics.

### Observability Pipeline

```
ME Shard ──metrics──► Prometheus (5s scrape) ──► Grafana (dashboards)
    │                       ▲
    │──structured logs──► stdout ──► Promtail ──► Loki ──► Grafana (log explorer)
    │
    └──events──► Kafka/Redpanda (orders + matches topics)
```

Three independent telemetry channels ensure full visibility without impacting matching latency:
- **Metrics:** 11 Prometheus histograms/counters/gauges scraped every 5 seconds
- **Logs:** Structured JSON via Logback + Logstash Encoder, collected by Promtail into Loki
- **Events:** Order and match events published to Kafka topics for downstream consumers

---

## Architectural Styles, Patterns, and Tactics

### Architectural Styles

| Style | Where Applied | Rationale |
|:---|:---|:---|
| **Event-Driven Architecture (EDA)** | Core matching pipeline | Orders are events that flow through the Disruptor ring buffer. The HTTP handler publishes events; the `OrderEventHandler` consumes them. Decouples ingestion from processing. |
| **Pipe-and-Filter** | `OrderEventHandler.onEvent()` processing chain | Each event passes through a sequential pipeline: validate -> insert -> match -> WAL -> publish -> metrics. Each stage is a "filter" with a single responsibility. |
| **Client-Server** | HTTP API + k6 load generator | Standard request/response pattern for order submission. The "fire-and-publish" variant returns immediately without waiting for matching results. |
| **Shared-Nothing (per shard)** | Multi-shard deployment | Each shard has its own process, memory, order book, WAL, and Kafka producer. No shared state between shards. |

### Design Patterns

| Pattern | Implementation | Purpose |
|:---|:---|:---|
| **Disruptor (LMAX)** | `RingBuffer<OrderEvent>` with `YieldingWaitStrategy` | Lock-free inter-thread communication between HTTP threads (producers) and the matching thread (consumer). Pre-allocated ring buffer eliminates GC pressure from object allocation. |
| **Mechanical Sympathy** | Pre-allocated `OrderEvent` slots, `clear()` after use, `long` prices | Designs data structures for CPU cache friendliness. The ring buffer keeps events in contiguous memory. Value types (`long`, `int`) avoid object indirection. |
| **Fire-and-Forget** | `EventPublisher` with `acks=0`, `max.block.ms=1` | Kafka publishing never blocks the matching thread. If the broker is down, events are dropped but matching continues. Prioritizes latency over delivery guarantees. |
| **Write-Ahead Log** | `WriteAheadLog` with `MappedByteBuffer` | Durability via memory-mapped file. Records are appended sequentially; flush is deferred to `endOfBatch` to amortize disk I/O across batches. |
| **Value Object** | `OrderId`, `Price` | Immutable domain primitives that enforce invariants. `Price` wraps `long` cents and implements `Comparable` for TreeMap ordering. |
| **Strategy** | `MatchingAlgorithm` interface + `PriceTimePriorityMatcher` | Decouples matching logic from the event handler. Alternative algorithms (pro-rata, FIFO-only) can be swapped without changing the processing pipeline. |
| **Reverse Proxy / Router** | `ConsistentHashRouter` + `OrderProxyHandler` | The Edge Gateway routes orders to shards by symbol using a pre-computed lookup table. Transparent HTTP forwarding preserves the ME's API contract. |

### Quality Attribute Tactics

#### Latency Tactics

| Tactic | Implementation | Effect |
|:---|:---|:---|
| **Reduce computational overhead** | Single-threaded processing via Disruptor (no locks, no context switches) | Eliminates synchronization overhead entirely |
| **Manage event rate** | `YieldingWaitStrategy` spin-waits instead of parking threads | Avoids OS scheduler latency on the critical path |
| **In-memory processing** | `TreeMap` + `ArrayDeque` order book (no disk reads during matching) | O(log P + F) matching with no I/O stalls |
| **Batch I/O** | WAL flush deferred to `endOfBatch`; Kafka `linger.ms=5` | Amortizes disk and network I/O across multiple events |
| **Minimize GC pauses** | ZGC garbage collector with `-Xms256m -Xmx512m -XX:+AlwaysPreTouch` | Sub-millisecond GC pauses; heap pre-touched to avoid page faults |
| **Pre-allocate resources** | Ring buffer slots created at startup via `OrderEventFactory` | No object allocation per event; `clear()` resets fields in place |
| **Async non-blocking I/O** | Kafka `max.block.ms=1`, async appender for logging | Side effects (publish, log) never stall the matching thread |

#### Scalability Tactics

| Tactic | Implementation | Effect |
|:---|:---|:---|
| **Horizontal partitioning (sharding)** | Static symbol-to-shard mapping across 3 ME instances | Linear throughput scaling: 1 shard = 1,000 matches/min, 3 shards = 5,000 matches/min |
| **Stateless routing** | Edge Gateway lookup table: `HashMap<symbol, shardUrl>` (O(1)) | Gateway adds < 5ms overhead; no state to replicate |
| **Resource isolation** | Each shard runs in its own container with dedicated CPU/memory limits | Prevents noisy-neighbor effects between shards |

#### Availability / Resilience Tactics

| Tactic | Implementation | Effect |
|:---|:---|:---|
| **Fault isolation (Bulkhead)** | Independent shard processes; Kafka `max.block.ms=1` | Kafka/Redpanda outage does not affect matching; shard failure is contained |
| **Graceful degradation** | EventPublisher silently drops events when broker is unreachable | Matching continues even without downstream consumers |
| **Health monitoring** | `/health` endpoint + Prometheus metrics + structured logging | Enables automated liveness/readiness probes in Kubernetes |

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
| Logging | Logback Classic + Logstash Encoder (JSON) | 1.5.6 / 8.0 |
| JSON | `com.google.code.gson:gson` | 2.11.0 |
| Message Broker | Redpanda (Kafka API-compatible) | latest |
| Load Testing | k6 (Grafana) | latest |
| Container Runtime | Docker + k3d (local K8s) | latest |
| JVM | Eclipse Temurin | 21, ZGC, 256-512MB heap |

---

## Project Structure

### Matching Engine

```
src/matching-engine/
  build.gradle.kts                  # Gradle build with all dependencies and fat JAR task
  settings.gradle.kts               # Project name
  Dockerfile                        # eclipse-temurin:21-jre-alpine with ZGC flags
  src/main/resources/
    logback.xml                      # JSON structured logging config (Logstash encoder + AsyncAppender)
  src/main/java/com/matchingengine/
    MatchingEngineApp.java           # Main entry point and startup sequence
    config/
      ShardConfig.java               # Environment variable parsing
    http/
      OrderHttpHandler.java          # POST /orders (fire-and-publish)
      HealthHttpHandler.java         # GET /health
      SeedHttpHandler.java           # POST /seed (pre-populate order book)
    disruptor/
      OrderEvent.java                # Pre-allocated ring buffer event (mutable, cleared after use)
      OrderEventFactory.java         # Creates empty OrderEvent instances for the ring buffer
      OrderEventTranslator.java      # Copies HTTP request data into ring buffer slot
      OrderEventHandler.java         # Single-threaded event processor (match + WAL + Kafka + metrics)
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
      MatchResult.java               # Single fill result (taker, maker, price, quantity)
      MatchResultSet.java            # Collection of fills for one incoming order
    matching/
      MatchingAlgorithm.java         # Interface (Strategy pattern)
      PriceTimePriorityMatcher.java  # Price-time priority implementation O(log P + F)
    wal/
      WriteAheadLog.java             # Memory-mapped WAL with deferred flush
    publishing/
      EventPublisher.java            # Async Kafka producer wrapper (acks=0, max.block.ms=1)
    metrics/
      MetricsRegistry.java           # All 11 Prometheus metrics (histograms, counters, gauges)
    logging/
      MatchingStats.java             # AtomicLong counters (lock-free, shared between threads)
      PeriodicStatsLogger.java       # 10-second summary logger on a separate daemon thread
```

### Edge Gateway

```
src/edge-gateway/
  build.gradle.kts                  # Gradle build with fat JAR task
  settings.gradle.kts               # Project name
  Dockerfile                        # eclipse-temurin:21-jre-alpine
  src/main/java/com/matchingengine/gateway/
    EdgeGatewayApp.java              # Main entry point
    config/
      GatewayConfig.java             # Environment variable parsing (shard map, symbol map)
    routing/
      SymbolRouter.java              # Interface: getShardUrl(symbol), getShardId(symbol)
      ConsistentHashRouter.java      # O(1) lookup table: HashMap<symbol, shardUrl>
    http/
      OrderProxyHandler.java         # POST /orders → route by symbol → forward to ME shard
      SeedProxyHandler.java          # POST /seed/{shardId} → forward to specific ME shard
      HealthHandler.java             # GET /health
    metrics/
      GatewayMetrics.java            # Prometheus: gw_requests_total, gw_request_duration, gw_routing_errors
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
| **AsyncAppender for logging** | Logback's `AsyncAppender` (queue=8192, `neverBlock=true`) ensures log serialization never stalls the matching thread. If the queue is full, log entries are dropped rather than blocking. |
| **ZGC garbage collector** | Z Garbage Collector provides sub-millisecond pause times. Combined with `-XX:+AlwaysPreTouch`, heap pages are faulted in at startup, avoiding latency spikes during operation. |
| **Structured JSON logging** | All log output is JSON via Logstash Encoder. Enables automated parsing by Promtail/Loki without regex-based extraction. Each event carries structured key-value fields. |

---

## Structured Logging and Observability

The Matching Engine uses **structured JSON logging** via Logback + Logstash Encoder to provide full operational visibility during load tests. Logs are designed to be collected by Promtail and stored in Loki for querying through Grafana.

### Logging Architecture

```
Matching Thread ──► SLF4J Logger ──► AsyncAppender (queue=8192, neverBlock) ──► LogstashEncoder ──► stdout (JSON)
                                                                                                       │
Stats Thread (10s) ──► SLF4J Logger ──────────────────────────────────────────────────────────────────┘
                                                                                                       │
                                                                                         Promtail ──► Loki ──► Grafana
```

The `AsyncAppender` with `neverBlock=true` is critical: it guarantees the matching thread is never blocked by log serialization or I/O. If the log queue fills up, entries are silently discarded rather than stalling the matching pipeline.

### Log Event Types

When `ENABLE_DETAILED_LOGGING=true`, the following structured events are emitted per order:

| Event | Level | Fields | When |
|:---|:---|:---|:---|
| `ORDER_RECEIVED` | INFO | orderId, symbol, side, price, quantity, shard | Every incoming order |
| `MATCH_EXECUTED` | INFO | matchId, takerOrderId, makerOrderId, symbol, executionPrice, quantity, takerSide, shard | Each fill during matching |
| `ORDER_RESTING` | INFO | orderId, symbol, side, remainingQuantity, shard | When remaining quantity rests in the book |
| `ORDER_REJECTED` | WARN | orderId, symbol, reason, shard | Unknown symbol or validation failure |

### Periodic Summary (Always Enabled)

Regardless of `ENABLE_DETAILED_LOGGING`, the `PeriodicStatsLogger` runs on a **separate daemon thread** and emits a `PERIODIC_SUMMARY` every 10 seconds:

```json
{
  "timestamp": "2026-02-16T10:30:00.000Z",
  "level": "INFO",
  "message": "Periodic summary",
  "event": "PERIODIC_SUMMARY",
  "shard": "a",
  "intervalSeconds": 10,
  "buyOrders": 85,
  "sellOrders": 72,
  "totalOrders": 157,
  "matchesExecuted": 64,
  "rejected": 0,
  "matchRate": "0.4076",
  "bidDepth": 1245,
  "askDepth": 1180,
  "bidLevels": 48,
  "askLevels": 45,
  "service": "matching-engine"
}
```

This uses `AtomicLong` counters (`MatchingStats`) that are incremented by the matching thread and read by the stats thread — lock-free with negligible overhead.

### Shutdown Summary

On JVM shutdown, a `SHUTDOWN_SUMMARY` event reports lifetime totals:

| Field | Description |
|:---|:---|
| `totalBuyOrders` | Lifetime buy orders processed |
| `totalSellOrders` | Lifetime sell orders processed |
| `totalMatches` | Lifetime matches executed |
| `totalRejected` | Lifetime rejected orders |
| `overallMatchRate` | matches / total orders |

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
| ME Shard A | http://localhost:8081 | `single` |
| Edge Gateway | http://localhost:8081 | `multi` |
| Prometheus | http://localhost:9090 | both |
| Grafana | http://localhost:3000 | both |

#### Step 8: Verify the deployment

```bash
# Health check (ME or Gateway depending on mode)
curl http://localhost:8081/health

# Submit a test order
curl -X POST http://localhost:8081/orders \
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
curl http://localhost:8081/health   # verify

# --- ASR 2 (multi shard) ---
bash infra/scripts/06-deploy-me-multi.sh
bash infra/scripts/07-port-forward.sh multi
curl http://localhost:8081/health   # verify

# --- Teardown ---
bash infra/scripts/10-teardown.sh
```

### Infrastructure File Structure

```
infra/
  k8s/                                        # Kubernetes manifests (local k3d)
    namespace.yaml                            # matching-engine namespace
    redpanda/
      statefulset.yaml                        # Single-node Redpanda
      service.yaml                            # Headless service
    matching-engine/
      shard-a-deployment.yaml                 # ME Shard A (symbols A-D)
      shard-a-service.yaml
      shard-b-deployment.yaml                 # ME Shard B (symbols E-H)
      shard-b-service.yaml
      shard-c-deployment.yaml                 # ME Shard C (symbols I-L)
      shard-c-service.yaml
    edge-gateway/
      deployment.yaml                         # Symbol-hash routing proxy
      service.yaml
    monitoring/
      prometheus-values.yaml                  # Helm values: 5s scrape, remote write
      grafana-values.yaml                     # Helm values: admin/admin, Prometheus DS
  scripts/                                    # Local k3d deployment scripts
    00-prerequisites.sh                       # Verify tools
    01-create-cluster.sh                      # Create k3d cluster
    02-deploy-observability.sh                # Deploy Prometheus + Grafana
    03-deploy-redpanda.sh                     # Deploy Redpanda + create topics
    04-build-images.sh                        # Build JARs + Docker images + import
    05-deploy-me-single.sh                    # Deploy 1 shard (ASR 1)
    06-deploy-me-multi.sh                     # Deploy 3 shards + gateway (ASR 2)
    07-port-forward.sh                        # Port-forwards (single/multi mode)
    08-run-asr1-tests.sh                      # Orchestrate ASR 1 k6 tests
    09-run-asr2-tests.sh                      # Orchestrate ASR 2 k6 tests
    run-unified-asr-tests.sh                  # Unified orchestrator (ASR 1 + ASR 2)
    10-teardown.sh                            # Delete cluster
    helpers/
      wait-for-pod.sh                         # Wait for pod readiness
      pause-redpanda.sh                       # Pause/resume Redpanda (test A4)
  cloud/                                      # Cloud deployment scripts
    aws/                                      # AWS (EC2 Graviton3 ARM64)
      env.sh                                  # Shared config + persist_var()
      00-prerequisites.sh                     # AWS CLI, AMI lookup, SSH key
      01-create-network.sh                    # VPC, subnets, IGW, route tables
      02-create-security-groups.sh            # 6 security groups
      03-launch-instances.sh                  # 7 EC2 instances + NLB
      04-setup-software.sh                    # NAT GW, Docker, Prometheus, Grafana
      05-deploy-me.sh                         # ME containers (single/multi mode)
      06-run-tests.sh                         # k6 tests + results collection
      99-teardown.sh                          # Full reverse-order cleanup
    oci/                                      # Oracle Cloud (Always Free ARM64)
      env.sh                                  # Shared config + save_state()
      00-prerequisites.sh                     # OCI CLI, image lookup, SSH key
      01-create-network.sh                    # VCN, gateways, security lists, subnets
      02-launch-instances.sh                  # 5 instances (bastion + 4 A1.Flex)
      03-setup-software.sh                    # Docker, Java 21, k6, rpk via bastion
      04-deploy-me.sh                         # Build, transfer, deploy containers
      05-create-load-balancer.sh              # Flexible LB (10 Mbps, Always Free)
      06-run-tests.sh                         # k6 tests + results collection
      99-teardown.sh                          # Full reverse-order cleanup
```

### Troubleshooting

| Problem | Solution |
|:---|:---|
| `k3d cluster create` fails | Make sure Docker is running: `docker info` |
| Pods stuck in `ImagePullBackOff` | Images not imported. Re-run `bash infra/scripts/04-build-images.sh` |
| Port-forward dies | Re-run `bash infra/scripts/07-port-forward.sh single` (or `multi`) |
| Prometheus not scraping ME | Check pod annotations: `kubectl describe pod <me-pod> -n matching-engine` — should have `prometheus.io/scrape: "true"` |
| Redpanda not starting | Check resources: `kubectl describe pod redpanda-0 -n matching-engine` — may need more memory |
| `curl localhost:8081` connection refused | Port-forward not running. Check: `ps aux \| grep port-forward` |

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

## Load Testing (k6)

The project includes a complete set of [k6](https://k6.io/) load test scripts to validate the two Architecturally Significant Requirements (ASRs):

- **ASR 1 (Latency):** p99 matching latency < 200ms at 1,000 matches/min (single shard)
- **ASR 2 (Scalability):** Sustain >= 5,000 matches/min across 3 shards

### File Structure

```
src/k6/
├── lib/
│   ├── config.js                      # Shared constants: URLs, symbols, prices, thresholds
│   ├── orderGenerator.js              # Synthetic order generation (aggressive/passive/mixed)
│   └── seedHelper.js                  # Order Book seeding helpers (direct and via gateway)
├── test-asr1-a1-warmup.js             # A1: JVM warm-up (2 min, 500/min) — discard results
├── test-asr1-a2-normal-load.js        # A2: Normal load (5 min, 1,020/min) — PRIMARY ASR 1
├── test-asr1-a3-depth-variation.js    # A3: Shallow/medium/deep OB (3x3 min)
├── test-asr1-a4-kafka-degradation.js  # A4: Decoupling proof (3 min, pause Redpanda at t=60s)
├── test-asr2-b1-baseline.js           # B1: Single shard via gateway (3 min, baseline)
├── test-asr2-b2-peak-sustained.js     # B2: 3 shards sustained (5 min, 5,040/min) — PRIMARY ASR 2
├── test-asr2-b3-ramp.js              # B3: Ramp 1K→2.5K→5K/min (10 min)
├── test-asr2-b4-hot-symbol.js        # B4: 80% traffic to 1 symbol (5 min)
├── test-stochastic-normal.js          # Stochastic: normal load profile
├── test-stochastic-aggressive.js      # Stochastic: aggressive load profile
├── test-stochastic-normal-2min.js     # Stochastic: 2-min normal (for mixed runs)
├── test-stochastic-aggressive-20s.js  # Stochastic: 20-sec aggressive (for mixed runs)
├── run-mixed-stochastic.sh            # Orchestrator: 20 normal + 20 aggressive randomized
├── seed-orderbooks.js                 # Standalone seeder (single/multi modes)
└── results/                           # Test output directory (gitignored)
```

### Test Summary

| Test | Script | Rate | Duration | Purpose |
|:---|:---|:---|:---|:---|
| A1 | `test-asr1-a1-warmup.js` | 500/min | 2 min | JVM warm-up, no thresholds |
| **A2** | `test-asr1-a2-normal-load.js` | 1,020/min | 5 min | **PRIMARY ASR 1** — p99 < 200ms |
| A3 | `test-asr1-a3-depth-variation.js` | 1,020/min | 3x3 min | Order Book depth impact |
| A4 | `test-asr1-a4-kafka-degradation.js` | 1,020/min | 3 min | Kafka decoupling proof |
| B1 | `test-asr2-b1-baseline.js` | 1,020/min | 3 min | Single shard via gateway |
| **B2** | `test-asr2-b2-peak-sustained.js` | 5,040/min | 5 min | **PRIMARY ASR 2** — 3 shards |
| B3 | `test-asr2-b3-ramp.js` | 1K→5K/min | 10 min | Progressive ramp |
| B4 | `test-asr2-b4-hot-symbol.js` | 5,040/min | 5 min | Hot symbol (80% to 1 symbol) |

### Prerequisites

- **k6** installed (`k6 version` to verify)
- Matching Engine running (either locally via Java or on k3d)
- For ASR 2 tests: All 3 shards + Edge Gateway deployed

### How to Run Individual Tests

**ASR 1 tests** target the ME shard directly (no gateway):

```bash
# A1: Warm-up (always run first to warm the JVM)
k6 run -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/test-asr1-a1-warmup.js

# A2: Normal load — PRIMARY ASR 1 TEST
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/test-asr1-a2-normal-load.js

# A3: Depth variation
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/test-asr1-a3-depth-variation.js

# A4: Kafka degradation (pause Redpanda manually at t=60s)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/test-asr1-a4-kafka-degradation.js
```

**ASR 2 tests** target the Edge Gateway (routes to all 3 shards):

```bash
# B1: Baseline (single shard through gateway)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8081 \
  src/k6/test-asr2-b1-baseline.js

# B2: Peak sustained — PRIMARY ASR 2 TEST
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8081 \
  src/k6/test-asr2-b2-peak-sustained.js

# B3: Ramp (1K → 2.5K → 5K matches/min)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8081 \
  src/k6/test-asr2-b3-ramp.js

# B4: Hot symbol (80% traffic to TEST-ASSET-A)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8081 \
  src/k6/test-asr2-b4-hot-symbol.js
```

### Standalone Seeding

Seed Order Books without running load tests:

```bash
# Single shard (direct to ME)
k6 run -e SEED_MODE=single -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/seed-orderbooks.js

# All 3 shards (via gateway)
k6 run -e SEED_MODE=multi -e GATEWAY_URL=http://localhost:8081 \
  src/k6/seed-orderbooks.js

# Custom depth and levels
k6 run -e SEED_MODE=single -e SEED_DEPTH=1000 -e SEED_LEVELS=100 \
  -e ME_SHARD_A_URL=http://localhost:8081 \
  src/k6/seed-orderbooks.js
```

### Environment Variables

| Variable | Default | Used By | Description |
|:---|:---|:---|:---|
| `ME_SHARD_A_URL` | `http://localhost:8081` | ASR 1 tests | Direct URL to ME Shard A |
| `GATEWAY_URL` | `http://localhost:8081` | ASR 2 tests | Edge Gateway URL |
| `SEED_MODE` | `single` | `seed-orderbooks.js` | `single` or `multi` |
| `SEED_DEPTH` | `500` | `seed-orderbooks.js` | Orders per symbol |
| `SEED_LEVELS` | `50` | `seed-orderbooks.js` | Price levels for seed orders |

### Pass/Fail Criteria

**ASR 1 (from test A2):**

| Metric | Pass | Fail |
|:---|:---|:---|
| p99 `http_req_duration` | < 200ms | >= 200ms |
| p99 `match_latency_ms` | < 200ms | >= 200ms |
| Error rate | < 1% | >= 1% |

**ASR 2 (from test B2):**

| Metric | Pass | Fail |
|:---|:---|:---|
| Aggregate throughput | >= 4,750 matches/min for >= 4 min | < 4,750 |
| Per-shard p99 latency | < 200ms | >= 200ms |
| Error rate | < 1% | >= 1% |

### Prometheus Integration

All tests support writing metrics to Prometheus via `--out experimental-prometheus-rw`. This enables real-time visualization in Grafana during test runs. The `--out` flag is optional — tests work without it, but results won't appear in Grafana.

### How Order Matching Works in Tests

The tests use a **60/40 aggressive/passive split**:
- **60% aggressive orders:** BUY orders priced above the best ask, guaranteeing immediate matches
- **40% passive orders:** BUY orders priced below the best bid, which rest in the Order Book

Each test's `setup()` function seeds the Order Book with resting SELL orders before load begins, ensuring there are always orders to match against. Prices are in **cents** (e.g., `15000` = $150.00).

### Stochastic Tests (Statistical Validation)

Beyond the deterministic ASR tests, the project includes **stochastic tests** that run repeated trials with randomized order distributions to build statistical confidence:

| Script | Duration | Purpose |
|:---|:---|:---|
| `test-stochastic-normal-2min.js` | 2 min | Normal load (1,020/min) with randomized price distribution |
| `test-stochastic-aggressive-20s.js` | 20 sec | Aggressive burst (high match rate) with randomized order mix |
| `run-mixed-stochastic.sh` | ~50 min | Orchestrator: runs 20 normal + 20 aggressive tests in random order |

```bash
# Run mixed stochastic suite (40 tests total)
bash src/k6/run-mixed-stochastic.sh http://localhost:8081

# Custom number of runs
NORMAL_RUNS=10 AGGRESSIVE_RUNS=10 bash src/k6/run-mixed-stochastic.sh
```

Output: `src/k6/results/mixed-stochastic-YYYYMMDD-HHMMSS/` with per-run JSON summaries, consolidated CSV, and a text report.

### Unified ASR Test Suite

The unified test orchestrator (`infra/scripts/run-unified-asr-tests.sh`) runs both ASR 1 and ASR 2 test suites in a single execution, handling deployment switching automatically:

```bash
# Run both ASR 1 (single shard) and ASR 2 (multi-shard)
bash infra/scripts/run-unified-asr-tests.sh --both

# Run only ASR 1 (stochastic latency tests)
bash infra/scripts/run-unified-asr-tests.sh --asr1-only

# Run only ASR 2 (scalability tests)
bash infra/scripts/run-unified-asr-tests.sh --asr2-only

# Skip deployment steps (if already deployed)
SKIP_DEPLOYMENT=true bash infra/scripts/run-unified-asr-tests.sh --both
```

Output: `infra/scripts/results/unified-YYYYMMDD-HHMMSS/` with separate `asr1/` and `asr2/` subdirectories, plus a consolidated pass/fail report.

### Validating Scripts

Verify all scripts parse correctly without running them:

```bash
for script in src/k6/test-*.js src/k6/seed-orderbooks.js; do
  echo "Checking: $script"
  k6 inspect "$script" > /dev/null && echo "  OK" || echo "  FAIL"
done
```

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
| `ENABLE_DETAILED_LOGGING` | `false` | When `true`, emits per-order structured log events (ORDER_RECEIVED, MATCH_EXECUTED, ORDER_RESTING, ORDER_REJECTED). Periodic summaries are always enabled regardless of this setting. |

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

---

## Cloud Deployment

The project includes deployment automation for running the full experiment on cloud infrastructure. Two providers are supported: **AWS** and **Oracle Cloud (OCI)**. Both deploy the same Docker images and run the same k6 test suite.

### Architecture (Both Providers)

```
Internet ──► Load Balancer ──► Edge Gateway ──► ME Shard A ─┐
                                           ├──► ME Shard B  ├──► Redpanda
                                           └──► ME Shard C ─┘
                                                                 │
                                                    Prometheus ──┘
                                                        │
                                                    Grafana
```

All instances run ARM64 (Graviton3 on AWS, Ampere A1 on OCI) with Docker containers. No Kubernetes is used in the cloud deployment — each application runs as a Docker container with `--network host`.

### AWS Deployment

**Instance types:** c7g.medium (Graviton3 ARM64, 1 vCPU, 2 GiB) for ME/Edge/Redpanda, t4g.small for monitoring, c7g.large for the k6 load generator.

**Cost:** ~$0.50-1.00/hour for the full cluster (7 instances + NLB).

**Scripts:** `infra/cloud/aws/`

| Script | Purpose |
|:---|:---|
| `env.sh` | Shared configuration (region, CIDRs, instance types, dynamic resource IDs) |
| `00-prerequisites.sh` | Verify AWS CLI, find ARM64 AMI, create SSH key pair |
| `01-create-network.sh` | VPC, subnets, Internet Gateway, route tables |
| `02-create-security-groups.sh` | 6 security groups (NLB, Edge, ME, Redpanda, Monitoring, Load Generator) |
| `03-launch-instances.sh` | Launch 7 EC2 instances + NLB with target group |
| `04-setup-software.sh` | NAT Gateway, Docker, Redpanda, Prometheus, Grafana, build and transfer images |
| `05-deploy-me.sh` | Start ME containers (`single` for ASR 1, `multi` for ASR 2) |
| `06-run-tests.sh` | Run k6 tests (`smoke`, `asr1`, `asr2`) and collect results |
| `99-teardown.sh` | Delete all AWS resources in reverse dependency order |

**Quick start:**

```bash
cd infra/cloud/aws

# 1. Deploy infrastructure
./00-prerequisites.sh
./01-create-network.sh
./02-create-security-groups.sh
./03-launch-instances.sh --all
./04-setup-software.sh

# 2. Run ASR 1 (single shard latency)
./05-deploy-me.sh single
./06-run-tests.sh smoke
./06-run-tests.sh asr1

# 3. Run ASR 2 (multi shard scalability)
./05-deploy-me.sh multi
./06-run-tests.sh asr2

# 4. Cleanup (deletes everything)
./99-teardown.sh
```

### OCI (Oracle Cloud) Deployment

**Instance types:** VM.Standard.A1.Flex (Ampere ARM64, 1 OCPU, 6 GiB each) for ME shards and Edge, VM.Standard.E2.1.Micro for bastion.

**Cost:** $0.00 — the entire experiment runs within the OCI Always Free tier (4 OCPUs, 24 GiB RAM, 200 GB boot storage).

**Network topology:** Bastion host in public subnet for SSH access; all application instances in private subnet. Load Balancer (Always Free, 10 Mbps flexible) provides public HTTP access to the Edge Gateway.

**Scripts:** `infra/cloud/oci/`

| Script | Purpose |
|:---|:---|
| `env.sh` | Shared configuration (region, shapes, CIDRs, state file management) |
| `00-prerequisites.sh` | Verify OCI CLI, resolve ARM64/x86 images, generate SSH keys |
| `01-create-network.sh` | VCN, gateways, route tables, security lists, subnets |
| `02-launch-instances.sh` | Launch 5 instances (bastion + 4 A1.Flex) |
| `03-setup-software.sh` | Install Docker, Java 21, k6, rpk via SSH through bastion |
| `04-deploy-me.sh` | Build images, transfer via bastion, deploy all containers |
| `05-create-load-balancer.sh` | Flexible LB with backend set and HTTP listener |
| `06-run-tests.sh` | Run k6 tests (`smoke`, `asr1`, `asr2`, `all`) and collect results |
| `99-teardown.sh` | Delete all OCI resources in reverse dependency order |

**Quick start:**

```bash
cd infra/cloud/oci

# Set your compartment ID
export COMPARTMENT_ID="ocid1.compartment.oc1..your-compartment-id"

# 1. Deploy infrastructure
./00-prerequisites.sh
./01-create-network.sh
./02-launch-instances.sh
./03-setup-software.sh
./04-deploy-me.sh

# 2. Create load balancer (optional, for external access)
./05-create-load-balancer.sh

# 3. Run tests
./06-run-tests.sh smoke
./06-run-tests.sh asr1
./06-run-tests.sh asr2

# 4. Cleanup (deletes everything)
./99-teardown.sh
```

### Cloud vs Local Comparison

| Aspect | Local (k3d) | AWS | OCI |
|:---|:---|:---|:---|
| Orchestration | Kubernetes (k3d) | Docker containers | Docker containers |
| Load balancer | kubectl port-forward | Network Load Balancer | Flexible Load Balancer |
| Network | k3d internal | VPC (public + private subnets) | VCN (public + private subnets) |
| Monitoring | Helm (Prometheus + Grafana) | Docker (Prometheus + Grafana) | Docker (Prometheus + Grafana) |
| Architecture | AMD64 or ARM64 | ARM64 (Graviton3) | ARM64 (Ampere A1) |
| Cost | Free (local) | ~$0.50-1.00/hr | $0.00 (Always Free) |
| Setup time | ~5 min | ~15-20 min | ~15-20 min |

### Prerequisites

**AWS:**
- AWS CLI v2 configured with credentials (`aws configure`)
- Sufficient EC2 limits (7 instances, 1 NLB)

**OCI:**
- OCI CLI configured (`oci setup config`)
- Always Free tier eligible tenancy
- Compartment OCID

---

## Documentation and Diagrams

The `docs/` directory contains architectural documentation and UML 2.5 diagrams (draw.io format):

```
docs/
  experiment-design.md              # Full experiment plan: ASR definitions, load profiles,
                                    #   pass/fail criteria, resource allocation, step-by-step guide
  class-diagram-uml25.drawio        # UML 2.5 class diagram (ME + Edge Gateway)
                                    #   All packages, classes, attributes, methods, relationships
                                    #   (composition, aggregation, realization, dependency)
  oci-deployment-uml25.drawio       # UML 2.5 deployment diagram for OCI
                                    #   «device», «executionEnvironment», «artifact» stereotypes
                                    #   Pay-as-you-go cost breakdown ($179.95/month without free tier)
  OCI-DEPLOYMENT-ARCHITECTURE.md    # Detailed OCI architecture: cost table, security model,
                                    #   tech stack per component, deployment sequence
  UNIFIED_ASR_TESTING.md            # Unified ASR test suite documentation
  experiment-cloud-aws.md           # AWS cloud experiment notes
  experiment-cloud-oci.md           # OCI cloud experiment notes
  DIAGRAMS.md                       # Diagram inventory and instructions
```

To open the `.drawio` diagrams, use [draw.io](https://app.diagrams.net/) (File -> Open -> select the `.drawio` file).
