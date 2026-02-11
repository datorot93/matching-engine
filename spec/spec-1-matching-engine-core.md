# Spec 1: Matching Engine Core

## 1. Role and Scope

**Role Name:** Matching Engine Core Developer

**Scope:** Implement the single-threaded, in-memory Matching Engine process. This is the innermost critical-path component: it receives orders via HTTP, sequences them through an LMAX Disruptor Ring Buffer, validates them, inserts them into an in-memory Order Book (TreeMap-based), executes price-time priority matching, appends results to a Write-Ahead Log (memory-mapped file), publishes events asynchronously to Redpanda, and exposes Prometheus metrics via an HTTP `/metrics` endpoint.

**Out of Scope:** Edge/Gateway layer (Spec 2), k6 load scripts (Spec 3), Kubernetes manifests and Docker (Spec 4), Grafana dashboards and seed scripts (Spec 5). This spec covers only the ME Java application itself.

---

## 2. Technology Stack

| Component | Technology | Version |
|:---|:---|:---|
| Language | Java | 21 (LTS) |
| Build tool | Gradle (Kotlin DSL) | 8.x |
| Ring Buffer | LMAX Disruptor | 4.0.0 |
| Order Book (bids/asks) | `java.util.TreeMap` | JDK 21 |
| Order index | `java.util.HashMap` | JDK 21 |
| Price-level queue | `java.util.ArrayDeque` | JDK 21 |
| WAL | `java.nio.MappedByteBuffer` | JDK 21 |
| HTTP server | `com.sun.net.httpserver.HttpServer` | JDK 21 |
| Kafka producer | `org.apache.kafka:kafka-clients` | 3.7.x |
| Prometheus metrics | `io.prometheus:prometheus-metrics-core` | 1.3.x |
| Prometheus HTTP | `io.prometheus:prometheus-metrics-exporter-httpserver` | 1.3.x |
| Prometheus JVM | `io.prometheus:prometheus-metrics-instrumentation-jvm` | 1.3.x |
| JSON | `com.google.code.gson:gson` | 2.11.x |
| JVM flags | `-XX:+UseZGC -Xms256m -Xmx512m -XX:+AlwaysPreTouch` | -- |
| Base Docker image | `eclipse-temurin:21-jre-alpine` | ARM64 native |

---

## 3. Project Structure

```
src/matching-engine/
  build.gradle.kts
  settings.gradle.kts
  Dockerfile
  src/
    main/
      java/
        com/
          matchingengine/
            MatchingEngineApp.java          # Main entry point
            config/
              ShardConfig.java              # Shard ID, symbols, ports, Kafka bootstrap
            http/
              OrderHttpHandler.java         # HTTP POST /orders handler
              HealthHttpHandler.java        # HTTP GET /health handler
              SeedHttpHandler.java          # HTTP POST /seed handler (pre-seed order book)
            disruptor/
              OrderEvent.java               # Pre-allocated ring buffer event
              OrderEventFactory.java        # Creates empty OrderEvent instances
              OrderEventTranslator.java     # Translates HTTP request into OrderEvent
              OrderEventHandler.java        # Single-threaded event processor
            domain/
              Side.java                     # Enum: BUY, SELL
              OrderType.java                # Enum: LIMIT, MARKET
              OrderStatus.java              # Enum: NEW, PARTIALLY_FILLED, FILLED, CANCELLED, REJECTED
              Order.java                    # Order entity
              OrderId.java                  # Value object wrapping long
              Price.java                    # Value object wrapping long (cents)
              PriceLevel.java              # FIFO queue at a price point
              OrderBook.java               # TreeMap-based order book for one symbol
              OrderBookManager.java        # Map of symbol -> OrderBook
              MatchResult.java             # Single fill result
              MatchResultSet.java          # Collection of fills for one incoming order
            matching/
              MatchingAlgorithm.java        # Interface
              PriceTimePriorityMatcher.java # Price-time priority implementation
            wal/
              WriteAheadLog.java            # Memory-mapped WAL
            publishing/
              EventPublisher.java           # Async Kafka producer wrapper
            metrics/
              MetricsRegistry.java          # All Prometheus metrics in one place
```

---

## 4. Class Specifications

### 4.1 Entry Point: `MatchingEngineApp.java`

```java
public class MatchingEngineApp {
    public static void main(String[] args);
}
```

**Startup sequence:**
1. Parse `ShardConfig` from environment variables.
2. Initialize `MetricsRegistry` and start Prometheus HTTP server on port 9091.
3. Initialize `WriteAheadLog`.
4. Initialize `EventPublisher` (Kafka producer).
5. Initialize `OrderBookManager`.
6. Initialize `PriceTimePriorityMatcher`.
7. Create LMAX Disruptor with:
   - Ring buffer size: 131072 (2^17)
   - `OrderEventFactory`
   - `ProducerType.MULTI`
   - `YieldingWaitStrategy`
8. Register `OrderEventHandler` as the event handler.
9. Start the Disruptor.
10. Start `HttpServer` on port 8080 with handlers for `/orders`, `/health`, `/seed`.
11. Register JVM shutdown hook to cleanly shut down Disruptor, flush WAL, close Kafka producer.

### 4.2 Configuration: `ShardConfig.java`

```java
public class ShardConfig {
    private final String shardId;          // env: SHARD_ID (e.g., "a")
    private final List<String> symbols;    // env: SHARD_SYMBOLS (e.g., "TEST-ASSET-A,TEST-ASSET-B,...")
    private final int httpPort;            // env: HTTP_PORT, default 8080
    private final int metricsPort;         // env: METRICS_PORT, default 9091
    private final String kafkaBootstrap;   // env: KAFKA_BOOTSTRAP (e.g., "redpanda:9092")
    private final String walPath;          // env: WAL_PATH, default "/tmp/wal"
    private final int walSizeMb;           // env: WAL_SIZE_MB, default 64

    public static ShardConfig fromEnv();
}
```

### 4.3 HTTP Layer

#### `OrderHttpHandler.java`

Handles `POST /orders`. Accepts JSON, translates to ring buffer event.

**Request JSON schema:**
```json
{
  "orderId": "string",
  "symbol": "string",
  "side": "BUY" | "SELL",
  "type": "LIMIT",
  "price": 15000,
  "quantity": 100,
  "timestamp": 1707600000000
}
```

- `price` is in **cents** (integer). Example: 15000 = $150.00.
- `orderId` is a string (UUID or incrementing ID from k6).
- `timestamp` is epoch milliseconds. If omitted, the ME assigns `System.nanoTime()`.

**Response JSON schema (synchronous ACK):**
```json
{
  "status": "ACCEPTED",
  "orderId": "string",
  "shardId": "a",
  "timestamp": 1707600000001
}
```

HTTP status: 200 if accepted (published to ring buffer), 400 if validation fails, 503 if ring buffer is full.

**Implementation:**
1. Read request body, deserialize JSON with Gson.
2. Validate: symbol is in `ShardConfig.symbols`, side is valid, price > 0, quantity > 0.
3. Publish to Disruptor ring buffer via `OrderEventTranslator`.
4. Return 200 with ACK. Do NOT wait for matching to complete -- this is fire-and-publish.
5. Record `me_orders_received_total` counter increment.
6. Start a timer for `me_match_duration_seconds` (store the `System.nanoTime()` in the `OrderEvent.receivedNanos` field).

#### `HealthHttpHandler.java`

Handles `GET /health`. Returns `{"status":"UP","shardId":"a"}` with HTTP 200.

#### `SeedHttpHandler.java`

Handles `POST /seed`. Accepts a JSON array of orders to pre-populate the order book without going through the ring buffer. Used by the test framework to set up initial resting orders.

**Request JSON schema:**
```json
{
  "orders": [
    {
      "orderId": "seed-1",
      "symbol": "TEST-ASSET-A",
      "side": "SELL",
      "type": "LIMIT",
      "price": 15000,
      "quantity": 100
    }
  ]
}
```

**Implementation:**
1. Deserialize the array of orders.
2. For each order, call `orderBookManager.getOrCreateBook(symbol).addOrder(order)` directly.
3. Return `{"seeded": N}` where N is the number of orders inserted.
4. This endpoint is for experiment setup ONLY. It bypasses the ring buffer and matching logic.

### 4.4 Disruptor Components

#### `OrderEvent.java`

Pre-allocated mutable event object in the ring buffer.

```java
public class OrderEvent {
    public long receivedNanos;     // System.nanoTime() when HTTP request was received
    public String orderId;
    public String symbol;
    public Side side;
    public OrderType orderType;
    public long price;             // cents
    public long quantity;
    public long timestamp;         // epoch millis

    public void clear();           // Reset all fields to defaults
}
```

#### `OrderEventFactory.java`

```java
public class OrderEventFactory implements EventFactory<OrderEvent> {
    public OrderEvent newInstance() { return new OrderEvent(); }
}
```

#### `OrderEventTranslator.java`

```java
public class OrderEventTranslator {
    public static void translate(OrderEvent event, long sequence, OrderHttpRequest request, long receivedNanos);
}
```

Copies fields from the HTTP request object into the pre-allocated `OrderEvent` slot. Zero heap allocation.

#### `OrderEventHandler.java`

The single-threaded event processor. Implements `EventHandler<OrderEvent>`.

```java
public class OrderEventHandler implements EventHandler<OrderEvent> {
    private final OrderBookManager bookManager;
    private final PriceTimePriorityMatcher matcher;
    private final WriteAheadLog wal;
    private final EventPublisher publisher;
    private final MetricsRegistry metrics;

    @Override
    public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
        // 1. Start sub-timers for latency budget attribution
        // 2. Validate order (symbol exists in shard)
        //    - Record me_order_validation_duration_seconds
        // 3. Get or create OrderBook for symbol
        // 4. Create Order domain object from event
        // 5. Execute matching:
        //    a. Insert order into book
        //       - Record me_orderbook_insertion_duration_seconds
        //    b. Call matcher.match(orderBook, order)
        //       - Record me_matching_algorithm_duration_seconds
        //    c. Process MatchResultSet:
        //       - For each fill: update resting order, possibly remove from book
        //       - If incoming order has remaining qty, it rests in the book
        // 6. Append to WAL
        //    - Record me_wal_append_duration_seconds
        // 7. Publish events to Kafka (async)
        //    - Record me_event_publish_duration_seconds
        // 8. Record total me_match_duration_seconds (nanoTime - event.receivedNanos)
        // 9. Increment me_matches_total for each fill
        // 10. Update me_orderbook_depth and me_orderbook_price_levels gauges
        // 11. Update me_ringbuffer_utilization_ratio gauge
    }
}
```

**Critical constraint:** This handler runs on a SINGLE thread. All operations inside `onEvent` are sequential. No locks, no synchronization, no blocking I/O.

### 4.5 Domain Model

#### `Side.java`

```java
public enum Side { BUY, SELL }
```

#### `OrderType.java`

```java
public enum OrderType { LIMIT, MARKET }
```

#### `OrderStatus.java`

```java
public enum OrderStatus { NEW, PARTIALLY_FILLED, FILLED, CANCELLED, REJECTED }
```

#### `Price.java`

```java
public record Price(long cents) implements Comparable<Price> {
    public int compareTo(Price other) { return Long.compare(this.cents, other.cents); }
}
```

Prices are stored as long (cents) to avoid floating-point issues. Example: $150.00 = 15000 cents.

#### `OrderId.java`

```java
public record OrderId(String value) {}
```

#### `Order.java`

```java
public class Order {
    private final OrderId id;
    private final String symbol;
    private final Side side;
    private final OrderType type;
    private final Price limitPrice;
    private final long originalQuantity;
    private long remainingQuantity;
    private long filledQuantity;
    private final long timestamp;
    private OrderStatus status;

    public void fill(long qty);     // Reduce remainingQty, increase filledQty, update status
    public boolean isFilled();      // remainingQuantity == 0
    public boolean isActive();      // status is NEW or PARTIALLY_FILLED
}
```

#### `PriceLevel.java`

```java
public class PriceLevel {
    private final Price price;
    private final ArrayDeque<Order> orders;  // FIFO queue
    private long totalQuantity;

    public void addOrder(Order order);
    public Order peekFirst();
    public Order pollFirst();
    public void removeOrder(Order order);  // For cancel by reference
    public boolean isEmpty();
    public long getTotalQuantity();
    public int getOrderCount();
}
```

**Design note:** The refined architecture specifies a DoublyLinkedList for O(1) cancel-by-reference. For this experiment, `ArrayDeque` is acceptable because we do NOT implement cancel operations. The experiment only tests order placement and matching. If cancel is needed later, swap to a custom doubly-linked list with `OrderNode` references.

#### `OrderBook.java`

```java
public class OrderBook {
    private final String symbol;
    private final TreeMap<Price, PriceLevel> bids;  // Descending (highest first)
    private final TreeMap<Price, PriceLevel> asks;  // Ascending (lowest first)
    private final HashMap<String, Order> orderIndex; // orderId -> Order

    public OrderBook(String symbol);

    public void addOrder(Order order);
    // If BUY: bids.computeIfAbsent(price, PriceLevel::new).addOrder(order)
    // If SELL: asks.computeIfAbsent(price, PriceLevel::new).addOrder(order)
    // orderIndex.put(order.id, order)

    public void removeOrder(String orderId);
    // Lookup in orderIndex, remove from PriceLevel, if level empty remove from TreeMap

    public PriceLevel getBestBid();   // bids.firstEntry().getValue() or null
    public PriceLevel getBestAsk();   // asks.firstEntry().getValue() or null

    public int getBidDepth();         // total orders across all bid levels
    public int getAskDepth();         // total orders across all ask levels
    public int getBidLevelCount();    // bids.size()
    public int getAskLevelCount();    // asks.size()
}
```

**TreeMap initialization:**
- `bids = new TreeMap<>(Comparator.reverseOrder())` -- descending, so `firstKey()` = highest bid.
- `asks = new TreeMap<>()` -- natural ascending, so `firstKey()` = lowest ask.

#### `OrderBookManager.java`

```java
public class OrderBookManager {
    private final HashMap<String, OrderBook> books;

    public OrderBook getOrCreateBook(String symbol);
    public OrderBook getBook(String symbol);  // Returns null if not found
}
```

#### `MatchResult.java`

```java
public class MatchResult {
    private final String matchId;        // Generated UUID or sequence
    private final String takerOrderId;   // Incoming order
    private final String makerOrderId;   // Resting order
    private final String symbol;
    private final long executionPrice;   // cents
    private final long executionQuantity;
    private final long timestamp;        // nanoTime or epoch millis
    private final Side takerSide;
}
```

#### `MatchResultSet.java`

```java
public class MatchResultSet {
    private final List<MatchResult> results;
    private final long totalFilledQuantity;
    private final boolean incomingFullyFilled;
}
```

### 4.6 Matching Algorithm

#### `MatchingAlgorithm.java`

```java
public interface MatchingAlgorithm {
    MatchResultSet match(OrderBook book, Order incomingOrder);
}
```

#### `PriceTimePriorityMatcher.java`

Implements the standard price-time priority algorithm as defined in the initial architecture (Section 4.2.5).

```java
public class PriceTimePriorityMatcher implements MatchingAlgorithm {

    @Override
    public MatchResultSet match(OrderBook book, Order incoming) {
        List<MatchResult> results = new ArrayList<>();
        long totalFilled = 0;

        // Determine opposite side
        TreeMap<Price, PriceLevel> oppositeBook;
        if (incoming.getSide() == Side.BUY) {
            oppositeBook = book.getAsks(); // ascending price
        } else {
            oppositeBook = book.getBids(); // descending price
        }

        while (incoming.getRemainingQuantity() > 0) {
            Map.Entry<Price, PriceLevel> bestEntry = oppositeBook.firstEntry();
            if (bestEntry == null) break;

            Price bestPrice = bestEntry.getKey();

            // Check price compatibility
            if (incoming.getSide() == Side.BUY && incoming.getLimitPrice().cents() < bestPrice.cents()) break;
            if (incoming.getSide() == Side.SELL && incoming.getLimitPrice().cents() > bestPrice.cents()) break;

            PriceLevel level = bestEntry.getValue();

            while (incoming.getRemainingQuantity() > 0 && !level.isEmpty()) {
                Order resting = level.peekFirst();
                long fillQty = Math.min(incoming.getRemainingQuantity(), resting.getRemainingQuantity());

                incoming.fill(fillQty);
                resting.fill(fillQty);

                MatchResult result = new MatchResult(
                    generateMatchId(),
                    incoming.getSide() == Side.BUY ? incoming.getId().value() : resting.getId().value(),
                    incoming.getSide() == Side.BUY ? resting.getId().value() : incoming.getId().value(),
                    // ... takerOrderId = incoming, makerOrderId = resting
                    incoming.getSymbol(),
                    bestPrice.cents(),
                    fillQty,
                    System.currentTimeMillis(),
                    incoming.getSide()
                );
                results.add(result);
                totalFilled += fillQty;

                if (resting.isFilled()) {
                    level.pollFirst();
                    book.getOrderIndex().remove(resting.getId().value());
                }
            }

            if (level.isEmpty()) {
                oppositeBook.pollFirstEntry();
            }
        }

        // If incoming order has remaining quantity, add it to the book
        if (incoming.getRemainingQuantity() > 0) {
            book.addOrder(incoming);
        }

        return new MatchResultSet(results, totalFilled, incoming.isFilled());
    }
}
```

**Time complexity:** O(log P + F) where P = number of price levels, F = number of fills.

### 4.7 Write-Ahead Log

#### `WriteAheadLog.java`

```java
public class WriteAheadLog {
    private final MappedByteBuffer buffer;
    private final int capacity;  // WAL_SIZE_MB * 1024 * 1024
    private int position;

    public WriteAheadLog(String path, int sizeMb);
    // Opens/creates file, maps it to memory via FileChannel.map(READ_WRITE)

    public void append(byte[] data);
    // Write length prefix (4 bytes) + data to buffer at current position
    // Advance position
    // Do NOT call force() here -- that is deferred

    public void flush();
    // Call buffer.force() -- this is the expensive disk sync
    // Called on endOfBatch or periodically by background thread

    public void close();
    // Flush and unmap
}
```

**Design note:** For this experiment, the WAL is a simplified append-only memory-mapped file. No rotation, no compaction. The experiment runs for at most 30 minutes; even at 5,000 matches/min, total WAL data is < 50 MB (each event is ~200 bytes, 150,000 events = 30 MB). A 64 MB WAL file is sufficient.

**Flush strategy:** Call `flush()` on `endOfBatch` events from the Disruptor. This batches disk syncs, amortizing the cost across multiple events.

### 4.8 Event Publishing

#### `EventPublisher.java`

```java
public class EventPublisher {
    private final KafkaProducer<String, String> producer;
    private final String matchesTopic;

    public EventPublisher(String kafkaBootstrap);
    // Configure producer:
    //   bootstrap.servers = kafkaBootstrap
    //   key.serializer = StringSerializer
    //   value.serializer = StringSerializer
    //   acks = 0  (fire-and-forget for lowest latency)
    //   linger.ms = 5  (batch for 5ms)
    //   batch.size = 16384
    //   buffer.memory = 33554432 (32MB)
    //   max.block.ms = 1  (never block the matching thread)
    //   Topic: "matches"

    public void publishMatch(MatchResult result);
    // Serialize result to JSON, send to "matches" topic with symbol as key
    // This is non-blocking: KafkaProducer.send() returns immediately

    public void publishOrderPlaced(Order order);
    // Serialize to JSON, send to "orders" topic with symbol as key

    public void close();
}
```

**Critical constraint:** `max.block.ms = 1`. If the Kafka producer buffer is full or the broker is unreachable, `send()` must return immediately (or throw). The matching thread must NEVER block on Kafka. Errors are logged and counted via `me_event_publish_errors_total` counter but do NOT affect matching.

### 4.9 Prometheus Metrics

#### `MetricsRegistry.java`

```java
public class MetricsRegistry {
    // All metrics defined here as final fields, initialized in constructor

    // ---- Primary ASR 1 metric ----
    public final Histogram matchDuration;
    // name: me_match_duration_seconds
    // help: Time from order received to match result generated
    // buckets: 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0
    // labels: shard

    // ---- Latency budget attribution ----
    public final Histogram orderValidationDuration;
    // name: me_order_validation_duration_seconds
    // buckets: 0.0001, 0.0005, 0.001, 0.005, 0.01

    public final Histogram orderbookInsertionDuration;
    // name: me_orderbook_insertion_duration_seconds
    // buckets: 0.0001, 0.0005, 0.001, 0.005, 0.01

    public final Histogram matchingAlgorithmDuration;
    // name: me_matching_algorithm_duration_seconds
    // buckets: 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05

    public final Histogram walAppendDuration;
    // name: me_wal_append_duration_seconds
    // buckets: 0.001, 0.005, 0.01, 0.025, 0.05, 0.1

    public final Histogram eventPublishDuration;
    // name: me_event_publish_duration_seconds
    // buckets: 0.0001, 0.0005, 0.001, 0.005, 0.01

    // ---- Primary ASR 2 metric ----
    public final Counter matchesTotal;
    // name: me_matches_total
    // help: Total matches executed
    // labels: shard

    public final Counter ordersReceivedTotal;
    // name: me_orders_received_total
    // help: Total orders received
    // labels: shard, side (buy/sell)

    // ---- Order Book health ----
    public final Gauge orderbookDepth;
    // name: me_orderbook_depth
    // help: Current resting orders
    // labels: shard, side (bid/ask)

    public final Gauge orderbookPriceLevels;
    // name: me_orderbook_price_levels
    // help: Distinct price levels
    // labels: shard, side (bid/ask)

    // ---- Saturation ----
    public final Gauge ringbufferUtilization;
    // name: me_ringbuffer_utilization_ratio
    // help: Ring buffer fill level 0.0 to 1.0
    // labels: shard

    public MetricsRegistry(String shardId);
    // Initialize all metrics with the shard label
    // Register JVM metrics (GC, memory, threads) via prometheus-metrics-instrumentation-jvm
    // Start HTTPServer on metricsPort exposing /metrics
}
```

**Metric names and buckets MUST match exactly** what is defined in `experiment-design.md` Section 9.2. These are the metrics that Prometheus scrapes and that the pass/fail criteria are evaluated against.

---

## 5. API Contracts

### 5.1 HTTP Endpoints

| Method | Path | Port | Purpose |
|:---|:---|:---|:---|
| POST | `/orders` | 8080 | Submit an order for matching |
| GET | `/health` | 8080 | Health check |
| POST | `/seed` | 8080 | Pre-seed order book with resting orders |
| GET | `/metrics` | 9091 | Prometheus metrics scrape endpoint |

### 5.2 Order Submission: POST /orders

**Request:**
```
POST /orders HTTP/1.1
Content-Type: application/json

{
  "orderId": "k6-buy-00001",
  "symbol": "TEST-ASSET-A",
  "side": "BUY",
  "type": "LIMIT",
  "price": 15000,
  "quantity": 100
}
```

**Response (200):**
```json
{
  "status": "ACCEPTED",
  "orderId": "k6-buy-00001",
  "shardId": "a",
  "timestamp": 1707600000001
}
```

**Error Response (400):**
```json
{
  "status": "REJECTED",
  "orderId": "k6-buy-00001",
  "reason": "Unknown symbol: INVALID-SYMBOL"
}
```

### 5.3 Seed Endpoint: POST /seed

**Request:**
```
POST /seed HTTP/1.1
Content-Type: application/json

{
  "orders": [
    {"orderId": "seed-sell-1", "symbol": "TEST-ASSET-A", "side": "SELL", "type": "LIMIT", "price": 15100, "quantity": 50},
    {"orderId": "seed-sell-2", "symbol": "TEST-ASSET-A", "side": "SELL", "type": "LIMIT", "price": 15200, "quantity": 100}
  ]
}
```

**Response (200):**
```json
{"seeded": 2}
```

### 5.4 Kafka Events Published

Topic: `matches` (key: symbol)

```json
{
  "type": "MATCH_EXECUTED",
  "matchId": "m-00001",
  "takerOrderId": "k6-buy-00001",
  "makerOrderId": "seed-sell-1",
  "symbol": "TEST-ASSET-A",
  "executionPrice": 15100,
  "executionQuantity": 50,
  "takerSide": "BUY",
  "timestamp": 1707600000123
}
```

Topic: `orders` (key: symbol)

```json
{
  "type": "ORDER_PLACED",
  "orderId": "k6-buy-00002",
  "symbol": "TEST-ASSET-A",
  "side": "BUY",
  "price": 14900,
  "quantity": 200,
  "timestamp": 1707600000456
}
```

---

## 6. Environment Variables

| Variable | Default | Description |
|:---|:---|:---|
| `SHARD_ID` | `a` | Shard identifier |
| `SHARD_SYMBOLS` | `TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D` | Comma-separated list of symbols this shard handles |
| `HTTP_PORT` | `8080` | Order submission HTTP port |
| `METRICS_PORT` | `9091` | Prometheus metrics HTTP port |
| `KAFKA_BOOTSTRAP` | `localhost:9092` | Kafka/Redpanda bootstrap servers |
| `WAL_PATH` | `/tmp/wal` | Directory for WAL file |
| `WAL_SIZE_MB` | `64` | WAL file size in megabytes |
| `RING_BUFFER_SIZE` | `131072` | Ring buffer size (must be power of 2) |

---

## 7. Integration Points

### 7.1 What This Component Consumes

| Source | Protocol | Data |
|:---|:---|:---|
| k6 load generator (via Edge Gateway or directly) | HTTP POST `/orders` | Order JSON |
| k6 / test framework | HTTP POST `/seed` | Seed orders JSON |
| Prometheus | HTTP GET `/metrics` | Scrape every 5s |

### 7.2 What This Component Produces

| Destination | Protocol | Data |
|:---|:---|:---|
| Redpanda (topic: `matches`) | Kafka protocol (async) | Match result JSON events |
| Redpanda (topic: `orders`) | Kafka protocol (async) | Order placed/filled events |
| Prometheus `/metrics` endpoint | HTTP | Prometheus exposition format |

---

## 8. Build and Packaging

### 8.1 `build.gradle.kts`

```kotlin
plugins {
    java
    application
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

application {
    mainClass.set("com.matchingengine.MatchingEngineApp")
}

repositories {
    mavenCentral()
}

dependencies {
    // LMAX Disruptor
    implementation("com.lmax:disruptor:4.0.0")

    // Kafka client
    implementation("org.apache.kafka:kafka-clients:3.7.0")

    // Prometheus metrics
    implementation("io.prometheus:prometheus-metrics-core:1.3.1")
    implementation("io.prometheus:prometheus-metrics-exporter-httpserver:1.3.1")
    implementation("io.prometheus:prometheus-metrics-instrumentation-jvm:1.3.1")

    // JSON
    implementation("com.google.code.gson:gson:2.11.0")

    // SLF4J + simple logger
    implementation("org.slf4j:slf4j-api:2.0.12")
    implementation("org.slf4j:slf4j-simple:2.0.12")
}

tasks.jar {
    manifest {
        attributes["Main-Class"] = "com.matchingengine.MatchingEngineApp"
    }
    // Create fat JAR
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}
```

### 8.2 `Dockerfile`

```dockerfile
FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app
COPY build/libs/matching-engine-*.jar matching-engine.jar
RUN mkdir -p /app/wal

ENV SHARD_ID=a
ENV SHARD_SYMBOLS=TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D
ENV HTTP_PORT=8080
ENV METRICS_PORT=9091
ENV KAFKA_BOOTSTRAP=redpanda:9092
ENV WAL_PATH=/app/wal
ENV WAL_SIZE_MB=64

EXPOSE 8080 9091

ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-Xms256m", \
  "-Xmx512m", \
  "-XX:+AlwaysPreTouch", \
  "-jar", "matching-engine.jar"]
```

---

## 9. Acceptance Criteria

This role is "done" when:

1. **Build succeeds:** `./gradlew build` produces a fat JAR with all dependencies.
2. **Docker image builds:** `docker build -t matching-engine:experiment-v1 .` succeeds.
3. **Health check works:** `curl http://localhost:8080/health` returns 200 with valid JSON.
4. **Order submission works:** A POST to `/orders` with a valid order returns 200 with ACCEPTED status.
5. **Seed works:** A POST to `/seed` with an array of orders populates the order book.
6. **Matching works:** Submitting a BUY order at a price >= the best ASK price produces a match. The match is reflected in:
   - The `me_matches_total` counter incrementing.
   - A match event published to the `matches` Kafka topic.
   - The `me_match_duration_seconds` histogram recording the latency.
7. **Order Book works correctly:**
   - Orders that do not match rest in the book (visible via `me_orderbook_depth` gauge).
   - Price-time priority is respected: lowest ask matches first, FIFO within a price level.
8. **Metrics are exposed:** `curl http://localhost:9091/metrics` returns Prometheus exposition format with all 11 metrics from Section 9.2 of `experiment-design.md`.
9. **JVM metrics are exposed:** GC pause, heap usage, and thread count metrics are present on `/metrics`.
10. **WAL append works:** Events are appended to the memory-mapped WAL file. No crash or data corruption during a 5-minute test run.
11. **Kafka publish works:** Match events appear on the `matches` topic in Redpanda. If Redpanda is down, the ME continues operating without blocking.
12. **Single-threaded execution:** The `OrderEventHandler.onEvent()` method is never called concurrently (guaranteed by Disruptor topology). Verify by checking that `me_ringbuffer_utilization_ratio` stays well below 1.0.

---

## 10. Algorithms and Patterns Reference

### 10.1 Price-Time Priority Matching

The canonical matching algorithm for limit order books:

1. An incoming order is compared against the opposite side of the book.
2. **Price priority:** Best price on the opposite side is checked first (lowest ask for a buy, highest bid for a sell).
3. **Time priority:** Within the same price level, the order that arrived earliest is matched first (FIFO).
4. **Partial fills:** If the incoming order's quantity exceeds the resting order's quantity, the resting order is fully filled and removed. The incoming order continues matching against the next resting order.
5. **Resting:** If no more matching prices exist, the remaining quantity of the incoming order rests in the book at its limit price.

### 10.2 LMAX Disruptor Pattern

The ring buffer is pre-allocated at startup. Producers (HTTP threads) claim slots via CAS on the sequence counter, write event data into the pre-allocated slot, and publish the sequence. The single consumer thread (BatchEventProcessor) waits on the SequenceBarrier for new events, then processes them sequentially. The YieldingWaitStrategy spins briefly then yields the CPU.

### 10.3 Memory-Mapped WAL

`FileChannel.map(MapMode.READ_WRITE, 0, capacity)` creates a `MappedByteBuffer`. Writes to this buffer go to the OS page cache (memory speed). `buffer.force()` triggers an actual disk flush. By calling `force()` only on `endOfBatch`, disk I/O is amortized across batches.
