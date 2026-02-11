# Spec 2: Edge Gateway (Order Gateway with Symbol-Hash Routing)

## 1. Role and Scope

**Role Name:** Edge Gateway Developer

**Scope:** Implement a lightweight HTTP reverse proxy that sits between k6 (load generator) and the Matching Engine shards. It receives order submission requests, determines the target ME shard based on a consistent hash of the order's symbol, and forwards the request to the correct shard. It also exposes a health endpoint and Prometheus metrics.

**Why this component exists:**
- For ASR 1 (single shard): k6 could hit the ME directly. But for ASR 2 (3 shards), k6 needs a single entry point that routes orders to the correct shard by symbol. This component provides that routing.
- It validates the architectural pattern of symbol-hash-based routing from the Order Gateway to ME shards.
- The experiment-design.md Section 4.2 excludes the full Order Gateway (protocol translation, idempotency) but the cloud deployment docs (AWS, OCI) include an edge gateway for routing. This component is a minimal version of that.

**Out of Scope:** Authentication, TLS, rate limiting, protocol translation (FIX), idempotency, Redis. This is purely an HTTP proxy with symbol-based routing.

---

## 2. Technology Stack

| Component | Technology | Version |
|:---|:---|:---|
| Language | Java | 21 (LTS) |
| Build tool | Gradle (Kotlin DSL) | 8.x |
| HTTP server | `com.sun.net.httpserver.HttpServer` | JDK 21 |
| HTTP client | `java.net.http.HttpClient` | JDK 21 |
| JSON parsing | `com.google.code.gson:gson` | 2.11.x |
| Prometheus metrics | `io.prometheus:prometheus-metrics-core` | 1.3.x |
| Prometheus HTTP | `io.prometheus:prometheus-metrics-exporter-httpserver` | 1.3.x |
| Base Docker image | `eclipse-temurin:21-jre-alpine` | ARM64 native |

---

## 3. Project Structure

```
src/edge-gateway/
  build.gradle.kts
  settings.gradle.kts
  Dockerfile
  src/
    main/
      java/
        com/
          matchingengine/
            gateway/
              EdgeGatewayApp.java            # Main entry point
              config/
                GatewayConfig.java           # Shard map, ports
              routing/
                SymbolRouter.java            # Symbol -> shard URL mapping
                ConsistentHashRouter.java    # Hash-based routing implementation
              http/
                OrderProxyHandler.java       # POST /orders: parse symbol, route, proxy
                HealthHandler.java           # GET /health
                SeedProxyHandler.java        # POST /seed/{shardId}: proxy to specific shard
              metrics/
                GatewayMetrics.java          # Prometheus counters/histograms
```

---

## 4. Class Specifications

### 4.1 Entry Point: `EdgeGatewayApp.java`

```java
public class EdgeGatewayApp {
    public static void main(String[] args);
}
```

**Startup sequence:**
1. Parse `GatewayConfig` from environment variables.
2. Initialize `GatewayMetrics` and start Prometheus HTTP on metrics port.
3. Create `ConsistentHashRouter` from the shard map.
4. Create `java.net.http.HttpClient` with connection pool.
5. Start `HttpServer` on port 8080 with handlers:
   - `/orders` -> `OrderProxyHandler`
   - `/health` -> `HealthHandler`
   - `/seed/{shardId}` -> `SeedProxyHandler`
6. Log: "Edge Gateway started. Routing table: {shardMap}".

### 4.2 Configuration: `GatewayConfig.java`

```java
public class GatewayConfig {
    private final int httpPort;            // env: HTTP_PORT, default 8080
    private final int metricsPort;         // env: METRICS_PORT, default 9091
    private final Map<String, String> shardMap;  // env: ME_SHARD_MAP
    // Format: "a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080"
    // Parsed into: {"a" -> "http://me-shard-a:8080", "b" -> "http://me-shard-b:8080", ...}

    private final Map<String, List<String>> shardSymbols;  // env: SHARD_SYMBOLS_MAP
    // Format: "a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L"
    // This is an explicit symbol-to-shard mapping (no hash needed for the experiment)

    public static GatewayConfig fromEnv();
}
```

**Design decision:** For this experiment, the symbol-to-shard mapping is EXPLICIT (configured via environment variable), not computed via consistent hashing. This avoids complexity and ensures deterministic routing. The experiment uses 12 fixed symbols mapped to 3 shards (4 symbols each). A hash-based approach would require both the gateway and k6 to agree on the hash function.

### 4.3 Routing

#### `SymbolRouter.java`

```java
public interface SymbolRouter {
    String getShardUrl(String symbol);  // Returns the base URL of the target ME shard
    String getShardId(String symbol);   // Returns the shard ID (a, b, c)
}
```

#### `ConsistentHashRouter.java`

```java
public class ConsistentHashRouter implements SymbolRouter {
    private final Map<String, String> symbolToShardId;   // "TEST-ASSET-A" -> "a"
    private final Map<String, String> shardIdToUrl;      // "a" -> "http://me-shard-a:8080"

    public ConsistentHashRouter(Map<String, List<String>> shardSymbols, Map<String, String> shardMap) {
        // Build the symbolToShardId map from shardSymbols config
        // Build shardIdToUrl from shardMap config
    }

    @Override
    public String getShardUrl(String symbol) {
        String shardId = symbolToShardId.get(symbol);
        if (shardId == null) throw new IllegalArgumentException("Unknown symbol: " + symbol);
        return shardIdToUrl.get(shardId);
    }

    @Override
    public String getShardId(String symbol) {
        return symbolToShardId.get(symbol);
    }
}
```

### 4.4 HTTP Handlers

#### `OrderProxyHandler.java`

Handles `POST /orders`. Parses the symbol from the JSON body, routes to the correct shard, and proxies the request.

```java
public class OrderProxyHandler implements HttpHandler {
    private final SymbolRouter router;
    private final HttpClient httpClient;
    private final GatewayMetrics metrics;
    private final Gson gson;

    @Override
    public void handle(HttpExchange exchange) {
        // 1. Read request body
        // 2. Parse JSON to extract "symbol" field
        //    - Use a minimal approach: parse just the symbol, not the whole object
        //    - Alternatively, parse into a Map<String, Object> and read "symbol"
        // 3. Look up target shard URL via router.getShardUrl(symbol)
        // 4. Forward the ENTIRE original request body to {shardUrl}/orders
        //    - Use HttpClient.send() with the body
        //    - Set Content-Type: application/json
        //    - Timeout: 5 seconds
        // 5. Return the ME's response directly to the caller (pass-through)
        // 6. Record metrics:
        //    - gw_requests_total (counter, labels: shard, status)
        //    - gw_request_duration_seconds (histogram, labels: shard)
        //
        // Error handling:
        // - Unknown symbol: return 400 {"error": "Unknown symbol: X"}
        // - ME unreachable: return 502 {"error": "Shard unavailable: a"}
        // - Timeout: return 504 {"error": "Shard timeout: a"}
    }
}
```

**Critical performance note:** The gateway must NOT add significant latency. The `HttpClient` should be configured with:
- Connection pool (keep-alive) to avoid TCP handshake per request.
- `HTTP_1_1` protocol version for simplicity.
- Connect timeout: 2 seconds.
- Request timeout: 5 seconds.

#### `HealthHandler.java`

```java
public class HealthHandler implements HttpHandler {
    @Override
    public void handle(HttpExchange exchange) {
        // Return 200 {"status": "UP", "component": "edge-gateway"}
    }
}
```

#### `SeedProxyHandler.java`

Handles `POST /seed/{shardId}`. Routes seed requests to a specific shard.

```java
public class SeedProxyHandler implements HttpHandler {
    private final Map<String, String> shardIdToUrl;
    private final HttpClient httpClient;

    @Override
    public void handle(HttpExchange exchange) {
        // 1. Extract shardId from path: /seed/a -> "a"
        // 2. Look up shard URL
        // 3. Forward body to {shardUrl}/seed
        // 4. Return response pass-through
    }
}
```

### 4.5 Metrics

#### `GatewayMetrics.java`

```java
public class GatewayMetrics {
    public final Counter requestsTotal;
    // name: gw_requests_total
    // labels: shard, status (2xx, 4xx, 5xx)

    public final Histogram requestDuration;
    // name: gw_request_duration_seconds
    // labels: shard
    // buckets: 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0

    public final Counter routingErrors;
    // name: gw_routing_errors_total
    // labels: reason (unknown_symbol, shard_unavailable, timeout)

    public GatewayMetrics(int metricsPort);
    // Start Prometheus HTTP server on metricsPort
}
```

---

## 5. API Contracts

### 5.1 HTTP Endpoints

| Method | Path | Port | Purpose |
|:---|:---|:---|:---|
| POST | `/orders` | 8080 | Proxy order to correct ME shard |
| GET | `/health` | 8080 | Health check |
| POST | `/seed/{shardId}` | 8080 | Proxy seed request to specific ME shard |
| GET | `/metrics` | 9091 | Prometheus metrics |

### 5.2 Order Submission (same as ME contract -- pass-through)

**Request to Gateway:**
```
POST /orders HTTP/1.1
Content-Type: application/json

{
  "orderId": "k6-buy-00001",
  "symbol": "TEST-ASSET-E",
  "side": "BUY",
  "type": "LIMIT",
  "price": 15000,
  "quantity": 100
}
```

**Gateway behavior:** Extracts `symbol=TEST-ASSET-E`, maps to shard `b`, forwards to `http://me-shard-b:8080/orders`.

**Response:** Pass-through from ME shard:
```json
{
  "status": "ACCEPTED",
  "orderId": "k6-buy-00001",
  "shardId": "b",
  "timestamp": 1707600000001
}
```

### 5.3 Seed Endpoint

**Request:**
```
POST /seed/a HTTP/1.1
Content-Type: application/json

{
  "orders": [
    {"orderId": "seed-sell-1", "symbol": "TEST-ASSET-A", "side": "SELL", "type": "LIMIT", "price": 15100, "quantity": 50}
  ]
}
```

**Gateway behavior:** Forwards to `http://me-shard-a:8080/seed`.

---

## 6. Environment Variables

| Variable | Default | Description |
|:---|:---|:---|
| `HTTP_PORT` | `8080` | Gateway listening port |
| `METRICS_PORT` | `9091` | Prometheus metrics port |
| `ME_SHARD_MAP` | `a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080` | Shard ID to ME URL mapping |
| `SHARD_SYMBOLS_MAP` | `a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L` | Shard ID to symbols mapping |

---

## 7. Integration Points

### 7.1 What This Component Consumes

| Source | Protocol | Data |
|:---|:---|:---|
| k6 load generator | HTTP POST `/orders` | Order JSON |
| k6 / test framework | HTTP POST `/seed/{shardId}` | Seed orders JSON |
| Prometheus | HTTP GET `/metrics` | Scrape every 5s |

### 7.2 What This Component Produces

| Destination | Protocol | Data |
|:---|:---|:---|
| ME Shard A | HTTP POST `/orders` and `/seed` | Forwarded order/seed JSON |
| ME Shard B | HTTP POST `/orders` and `/seed` | Forwarded order/seed JSON |
| ME Shard C | HTTP POST `/orders` and `/seed` | Forwarded order/seed JSON |
| Prometheus `/metrics` | HTTP | Prometheus exposition format |

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
    mainClass.set("com.matchingengine.gateway.EdgeGatewayApp")
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("io.prometheus:prometheus-metrics-core:1.3.1")
    implementation("io.prometheus:prometheus-metrics-exporter-httpserver:1.3.1")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.slf4j:slf4j-api:2.0.12")
    implementation("org.slf4j:slf4j-simple:2.0.12")
}

tasks.jar {
    manifest {
        attributes["Main-Class"] = "com.matchingengine.gateway.EdgeGatewayApp"
    }
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}
```

### 8.2 `Dockerfile`

```dockerfile
FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app
COPY build/libs/edge-gateway-*.jar edge-gateway.jar

ENV HTTP_PORT=8080
ENV METRICS_PORT=9091
ENV ME_SHARD_MAP=a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080
ENV SHARD_SYMBOLS_MAP=a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L

EXPOSE 8080 9091

ENTRYPOINT ["java", \
  "-Xms128m", \
  "-Xmx256m", \
  "-jar", "edge-gateway.jar"]
```

---

## 9. Acceptance Criteria

This role is "done" when:

1. **Build succeeds:** `./gradlew build` produces a fat JAR.
2. **Docker image builds:** `docker build -t edge-gateway:experiment-v1 .` succeeds.
3. **Health check works:** `curl http://localhost:8080/health` returns 200.
4. **Routing works for ASR 1 (single shard):** With `ME_SHARD_MAP=a=http://localhost:8081`, a POST to `/orders` with `symbol=TEST-ASSET-A` is forwarded to `http://localhost:8081/orders`.
5. **Routing works for ASR 2 (3 shards):** With all 3 shards configured:
   - `symbol=TEST-ASSET-A` routes to shard `a`
   - `symbol=TEST-ASSET-E` routes to shard `b`
   - `symbol=TEST-ASSET-I` routes to shard `c`
6. **Unknown symbol returns 400:** A POST with `symbol=UNKNOWN` returns HTTP 400.
7. **Shard unavailable returns 502:** If a shard is down, the gateway returns HTTP 502.
8. **Seed routing works:** `POST /seed/a` forwards to shard `a`'s `/seed` endpoint.
9. **Metrics are exposed:** `curl http://localhost:9091/metrics` returns `gw_requests_total`, `gw_request_duration_seconds`, and `gw_routing_errors_total`.
10. **Latency overhead is minimal:** The gateway adds < 5 ms of latency to each request (measurable by comparing k6 end-to-end time with ME-internal `me_match_duration_seconds`).

---

## 10. Operational Notes

### 10.1 ASR 1 Configuration

For ASR 1 tests, the gateway can be configured with a single shard:

```
ME_SHARD_MAP=a=http://me-shard-a:8080
SHARD_SYMBOLS_MAP=a=TEST-ASSET-A
```

k6 sends all orders to the gateway, which forwards everything to shard `a`.

### 10.2 ASR 2 Configuration

For ASR 2 tests, all 3 shards are configured:

```
ME_SHARD_MAP=a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080
SHARD_SYMBOLS_MAP=a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L
```

k6 distributes orders across all 12 symbols. The gateway routes each order to its assigned shard.

### 10.3 Direct ME Access (Bypass Gateway)

For the simplest ASR 1 tests, k6 can bypass the gateway entirely and hit the ME shard directly. The gateway is required for ASR 2 multi-shard tests where k6 sends orders for different symbols and needs routing.
