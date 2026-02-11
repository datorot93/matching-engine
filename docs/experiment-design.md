# Local Experiment Design: Validating Latency and Scalability ASRs

## Table of Contents

1. [Overview](#1-overview)
2. [Machine Profile](#2-machine-profile)
3. [Local Kubernetes Tool: k3d](#3-local-kubernetes-tool-k3d)
4. [Minimal Component Set](#4-minimal-component-set)
5. [Resource Allocation](#5-resource-allocation)
6. [Technology Stack](#6-technology-stack)
7. [Experiment Scenarios](#7-experiment-scenarios)
8. [Load Testing Tool: k6](#8-load-testing-tool-k6)
9. [Metrics Collection Strategy](#9-metrics-collection-strategy)
10. [Pass/Fail Criteria](#10-passfail-criteria)
11. [Step-by-Step Setup Guide](#11-step-by-step-setup-guide)
12. [Key Decisions Summary](#12-key-decisions-summary)

---

## 1. Overview

This document defines a local experiment plan to validate two Architecturally Significant Requirements (ASRs) for the Matching Engine described in the [Initial Architecture](./architecture/initial-architecture.md):

- **ASR 1 (Latency):** Matching execution must complete in < 200 ms (p99) under normal load (1,000 matches/min).
- **ASR 2 (Scalability):** The system must scale from 1,000 to 5,000 matches/min for sustained 30-minute bursts, achieved through asset-symbol sharding.

### 1.1 ASR Details (from Quality Attribute Scenarios)

#### ASR 1: Latency

| Field | Value |
|:---|:---|
| **Quality Attribute** | Latency |
| **Unit** | Milliseconds |
| **Target** | < 200 ms per match |
| **Actor** | Matching Engine (Motor de emparejamiento) |
| **Stimulus** | Matching a buy order (Emparejamiento de una orden de compra) |
| **Environment** | Normal operation (500 sell orders/min, 800 buy orders/min, 1,000 matches/min) |
| **Expected Response** | Execute the match and materialize the transaction |
| **Priority** | Very high |
| **Availability Impact** | The engine must NOT block while searching for a match, to ensure transaction integrity |

#### ASR 2: Scalability

| Field | Value |
|:---|:---|
| **Quality Attribute** | Scalability |
| **Unit** | Matches/minute * minutes |
| **Actor** | Matching Engine (Motor de emparejamiento) |
| **Stimulus** | Matching a buy order (Emparejamiento de una orden de compra) |
| **Environment** | Normal operation (500 sell/min, 800 buy/min, 1,000 matches/min with 200 ms response per match) |
| **Expected Response** | Execute the match and materialize the transaction |
| **Priority** | Very high |
| **Availability Impact** | To scale, data must be partitioned, information replicated, and events processed asynchronously, moving from strong consistency to eventual consistency |

The experiment runs entirely on a single developer machine using a local Kubernetes cluster. The goal is **architectural validation** -- proving or disproving design hypotheses -- not production readiness.

---

## 2. Machine Profile

| Resource | Value |
|:---|:---|
| **CPU** | 12 cores (Apple Silicon, arm64) |
| **RAM** | 16 GB |
| **Disk** | ~485 GB free |
| **OS** | macOS Darwin 25.2.0 |
| **Docker** | v20.10.23 (installed) |
| **kubectl** | v1.25.4 (installed) |
| **Tools to install** | k3d, k6, helm |

---

## 3. Local Kubernetes Tool: k3d

### 3.1 Selection: k3d (k3s-in-Docker)

| Criterion | k3d | kind | minikube |
|:---|:---|:---|:---|
| ARM64 (Apple Silicon) support | Native. k3s is built for ARM64. | Good. Requires specific node images. | Acceptable, but heavier (VM-based). |
| Control plane RAM | ~250 MB | ~300-400 MB | ~600-800 MB |
| Startup time | ~10 seconds | ~30 seconds | ~60-90 seconds |
| Multi-node support | Native multi-server and multi-agent nodes. | Multiple worker nodes via containers. | Limited. Multi-node is experimental. |
| RAM per worker node | ~80-100 MB per agent node | ~200-300 MB per node | Single node only in practice |
| Docker dependency | Required (installed) | Required | Can use Docker driver or VMs |
| Port mapping | Built-in ServiceLB. Trivial with `--port` flags. | Requires manual port forwarding. | Built-in tunnel, adds complexity. |

### 3.2 Justification

On a 16 GB machine where every megabyte matters, k3d's minimal footprint (~250 MB control plane vs. ~800 MB for minikube) frees approximately 500-600 MB of additional RAM for the actual experiment workloads. Its sub-10-second startup and native ARM64 support via k3s make it the most efficient choice for iterative experimentation on Apple Silicon.

**Installation:** `brew install k3d` (single command, no VM drivers needed).

---

## 4. Minimal Component Set

The full production architecture includes API Gateway, Order Gateway, Matching Engine, Kafka, Redis, Notification Dispatcher, Analytics Service, Event Store, ClickHouse, Prometheus, and Grafana. For this experiment, we strip down to only what directly participates in or measures the ASRs.

### 4.1 Components Included

| Component | Justification | Validates ASR |
|:---|:---|:---|
| **Matching Engine (ME)** | The core component under test. Contains the Order Book, matching algorithm, and WAL. | Both |
| **Redpanda (single broker)** | Lightweight Kafka-API-compatible broker. Validates that async event publishing does not add latency to the critical path. | ASR 1 (decoupling proof), ASR 2 (event flow under scale) |
| **k6 (load generator)** | Produces synthetic order traffic at controlled rates (1K/min, ramp to 5K/min). Measures end-to-end latency. | Both |
| **Prometheus + Grafana** | Collects ME-internal latency histograms, throughput counters, Order Book depth, and ring buffer utilization. | Both |

### 4.2 Components Excluded

| Component | Why Excluded |
|:---|:---|
| **API Gateway** | Auth, TLS, and rate limiting are not relevant to matching latency. Orders go directly to the ME. The architecture's latency budget shows auth is outside the 200 ms scope. |
| **Order Gateway** | Protocol translation and validation add ~3 ms per the latency budget. The load generator sends pre-validated orders directly, isolating the ME's latency contribution. |
| **Redis** | Used only for session cache and idempotency at the edge layer. Not on the matching critical path (architecture Decision 3 in Section 5.5). |
| **Notification Dispatcher** | Off the critical path (async consumer). Not needed to validate matching latency or throughput. |
| **Analytics Service + ClickHouse** | Off the critical path. Cold path consumer. |
| **Event Store** | Consumes from Kafka asynchronously. Not relevant to matching latency. |

### 4.3 Resulting Minimal Topology

```
                                                    ┌─────────────┐
                    ┌──────────────────────────────▶│ ME Shard 1  │──┐
                    │                               └─────────────┘  │
┌──────────────┐    │  ┌──────────────────────────▶┌─────────────┐  │  ┌──────────┐
│  k6 Load     │────┤  │                           │ ME Shard 2  │──┼─▶│ Redpanda │
│  Generator   │────┤  │                           └─────────────┘  │  └──────────┘
└──────────────┘    │  │  ┌───────────────────────▶┌─────────────┐  │       │
                    └──┘  │                        │ ME Shard 3  │──┘       │
                          │                        └─────────────┘     ┌────▼─────┐
                          │                                            │Prometheus│
                          │                                            └────┬─────┘
                          │                                            ┌────▼─────┐
                          │                                            │ Grafana  │
                          │                                            └──────────┘
```

- **ASR 1 (Latency):** Run a single ME shard at 1,000 matches/min.
- **ASR 2 (Scalability):** Run 1 shard at 1,000/min, then add shards 2 and 3, ramp to 5,000/min.

---

## 5. Resource Allocation

**Total machine:** 12 CPU cores, 16 GB RAM.
**k3d + macOS + Docker overhead:** ~1.5 CPU cores, ~2.5 GB RAM.
**Available for workloads:** ~10 CPU cores, ~13 GB RAM.

### 5.1 ASR 1 Scenario (Single Shard, Normal Load)

| Pod | CPU Request | CPU Limit | Memory Request | Memory Limit | Replicas |
|:---|:---|:---|:---|:---|:---|
| ME Shard 1 | 1.0 | 2.0 | 512 Mi | 1 Gi | 1 |
| Redpanda | 1.0 | 2.0 | 1 Gi | 2 Gi | 1 |
| Prometheus | 0.25 | 0.5 | 256 Mi | 512 Mi | 1 |
| Grafana | 0.25 | 0.5 | 128 Mi | 256 Mi | 1 |
| k6 Load Generator | 1.0 | 2.0 | 256 Mi | 512 Mi | 1 |
| **Total** | **3.5** | **7.0** | **2.15 Gi** | **4.28 Gi** | **5 pods** |

### 5.2 ASR 2 Scenario (3 Shards, Peak Load)

| Pod | CPU Request | CPU Limit | Memory Request | Memory Limit | Replicas |
|:---|:---|:---|:---|:---|:---|
| ME Shard 1 | 1.0 | 2.0 | 512 Mi | 1 Gi | 1 |
| ME Shard 2 | 1.0 | 2.0 | 512 Mi | 1 Gi | 1 |
| ME Shard 3 | 1.0 | 2.0 | 512 Mi | 1 Gi | 1 |
| Redpanda | 1.0 | 2.0 | 1 Gi | 2 Gi | 1 |
| Prometheus | 0.25 | 0.5 | 256 Mi | 512 Mi | 1 |
| Grafana | 0.25 | 0.5 | 128 Mi | 256 Mi | 1 |
| k6 Load Generator | 2.0 | 3.0 | 512 Mi | 1 Gi | 1 |
| **Total** | **6.5** | **12.0** | **3.43 Gi** | **6.77 Gi** | **7 pods** |

### 5.3 Budget Summary

| Resource | Used (Peak) | Available | Headroom |
|:---|:---|:---|:---|
| CPU (request) | 8.0 cores | 12 cores | 33% |
| RAM | 8.75 GB | 16 GB | 45% |
| Disk | ~1.1 GB | ~485 GB | 99.8% |

**Verdict:** 16 GB is sufficient. The peak scenario uses ~55% of available RAM and ~67% of CPU cores. Disk is entirely irrelevant at these volumes.

---

## 6. Technology Stack

### 6.1 Selection: Java 21 + LMAX Disruptor

| Consideration | Java 21 + LMAX Disruptor | Go | Rust |
|:---|:---|:---|:---|
| Architecture alignment | 1:1 mapping. Architecture specifies Disruptor, TreeMap, MappedByteBuffer, JVM GC management. | Acceptable. No direct Disruptor or TreeMap equivalent. | Excellent raw performance, but overkill. |
| TreeMap availability | `java.util.TreeMap` -- exact data structure specified. | Requires external library or custom implementation. | `BTreeMap` in stdlib -- good. |
| LMAX Disruptor library | `com.lmax:disruptor:4.0.0` -- production-grade, ARM64 compatible. | No official port. | No official port. |
| GC risk validation | ZGC (Java 21 default) pauses < 1 ms. **The experiment validates whether GC is a real risk.** | No GC (bypasses the risk). | No GC (bypasses the risk). |
| Prometheus client | `io.prometheus:simpleclient_hotspot` -- mature, includes JVM metrics. | `prometheus/client_golang` -- excellent. | `prometheus` crate -- functional. |
| Academic alignment | Most likely familiar to students. Java is commonly taught. | Possible. | Less likely in a software architecture course. |

**Justification:** Java 21 is selected because the architecture documents are written around JVM concepts. Implementing in Java provides a 1:1 mapping between the architecture specification and the code. Additionally, the experiment intentionally uses the JVM to validate whether GC pauses are truly manageable -- if we used Go or Rust, we would bypass this risk and lose the opportunity to validate or invalidate it.

### 6.2 Key Libraries

| Library | Version | Purpose |
|:---|:---|:---|
| `com.lmax:disruptor` | 4.0.0 | Ring Buffer, single-threaded event processing |
| `io.prometheus:prometheus-metrics-core` | 1.3.x | Histograms, counters, gauges for ME metrics |
| `io.prometheus:prometheus-metrics-exporter-httpserver` | 1.3.x | `/metrics` HTTP endpoint |
| JDK: `java.util.TreeMap` | -- | Bids/asks sorted price levels |
| JDK: `java.util.HashMap` | -- | O(1) order-by-ID index |
| JDK: `java.nio.MappedByteBuffer` | -- | Memory-mapped WAL file |
| JDK: `com.sun.net.httpserver.HttpServer` | -- | Lightweight HTTP endpoint for order submission |

### 6.3 ME Process Thread Model

| Thread | Responsibility |
|:---|:---|
| Event processor (main) | Claims events from Ring Buffer, executes validation, matching, WAL append, event buffering. Single core. |
| WAL Flush thread | Periodic `MappedByteBuffer.force()`. Background. |
| Kafka Producer I/O thread | Non-blocking NIO send to Redpanda. Background. |
| Metrics HTTP thread | Serves `/metrics` for Prometheus. Background. |
| HTTP Listener thread(s) | Accepts incoming order HTTP requests, deserializes, publishes to Ring Buffer. 2 threads. |

Total: ~5-6 threads. Validates the architecture's claim of a low thread count.

---

## 7. Experiment Scenarios

### 7.1 Experiment A: Latency Validation (ASR 1)

**Hypothesis:** A single-threaded Matching Engine with an in-memory Order Book (TreeMap-based) can execute matches in < 200 ms at p99 under normal load (1,000 matches/min).

**Pre-conditions:**
- Single ME shard deployed with a single Order Book for one synthetic asset symbol (`TEST-ASSET-A`).
- Order Book pre-seeded with 500 resting sell orders at various price levels.
- WAL enabled (memory-mapped file, batched fsync).
- Async event publishing to Redpanda enabled (fire-and-forget from ME thread).

#### Test Case A1: Warm-up and Baseline

| Parameter | Value |
|:---|:---|
| Duration | 2 minutes |
| Load | 500 buy orders/min |
| Purpose | Warm up JVM, populate CPU caches, stabilize GC behavior |
| Measurement | Discard results. Calibration only. |

#### Test Case A2: Normal Load Latency

| Parameter | Value |
|:---|:---|
| Duration | 5 minutes |
| Load | Steady-state at ~17 orders/sec (1,000 matches/min) |
| Order profile | 60% aggressive limit orders (match immediately), 40% passive (rest in book) |

**Measurements:**
- **Primary:** p50, p95, p99 latency of match execution (order received to MatchResult generated).
- **Secondary:** p50/p95/p99 of WAL append time, event publish buffer time, ring buffer wait time.
- **Throughput:** Actual matches/sec sustained, orders/sec processed.
- **Resource:** CPU utilization, JVM heap usage, GC pause count and duration.

#### Test Case A3: Latency Under Order Book Depth Variation

| Parameter | Value |
|:---|:---|
| Duration | 3 minutes per depth level |
| Load | 1,000 matches/min constant |
| Variable | Order Book depth (3 sub-tests) |

| Sub-test | Resting Orders | Price Levels | Purpose |
|:---|:---|:---|:---|
| Shallow | 100 | 10 | Baseline |
| Medium | 1,000 | 100 | Realistic production depth |
| Deep | 10,000 | 500 | Stress test O(log P + F) complexity |

Validates that matching complexity does not push p99 above 200 ms even with deep books.

#### Test Case A4: Decoupling Proof (Kafka Degradation)

| Parameter | Value |
|:---|:---|
| Duration | 3 minutes |
| Load | 1,000 matches/min |
| Action | At t=60s, pause the Redpanda broker |
| Pass criterion | p99 matching latency remains < 200 ms even while Kafka is degraded |

Proves the architectural decision that async event publishing decouples downstream services from the critical path.

### 7.2 Experiment B: Scalability Validation (ASR 2)

**Hypothesis:** The Matching Engine can scale from 1,000 to 5,000 matches/min by adding horizontal shards partitioned by asset symbol, with no degradation in per-match latency.

**Pre-conditions:**
- 3 ME shards deployed, each handling a disjoint set of asset symbols.
- Shard A: symbols `TEST-ASSET-A` through `TEST-ASSET-D` (4 symbols).
- Shard B: symbols `TEST-ASSET-E` through `TEST-ASSET-H` (4 symbols).
- Shard C: symbols `TEST-ASSET-I` through `TEST-ASSET-L` (4 symbols).
- Load generator routes orders to the correct shard based on symbol hash.
- Each shard's Order Book pre-seeded with resting sell orders.

#### Test Case B1: Baseline -- Single Shard

| Parameter | Value |
|:---|:---|
| Duration | 3 minutes |
| Load | 1,000 matches/min directed to Shard A only |
| Shards active | 1 |
| Purpose | Establish single-shard baseline |

#### Test Case B2: Peak Sustained -- 3 Shards

| Parameter | Value |
|:---|:---|
| Duration | 5 minutes |
| Load | 5,000 matches/min evenly distributed (~1,667/min per shard) |
| Shards active | 3 |

**Measurements:**
- **Per-shard p99 latency:** Must remain < 200 ms (same as single-shard baseline).
- **Aggregate throughput:** Must sustain 5,000 matches/min for the full 5-minute window.
- **Per-shard CPU utilization:** Should be proportional to per-shard load, not affected by other shards.
- **Cross-shard interference:** Verify that increasing load on Shard B does not affect Shard A latency.

#### Test Case B3: Ramp Test

| Parameter | Value |
|:---|:---|
| Duration | 10 minutes |
| Purpose | Validate linear scaling during progressive shard addition |

| Time Window | Load | Shards Active |
|:---|:---|:---|
| t=0-2min | 1,000 matches/min | 1 |
| t=2-4min | 2,500 matches/min | 2 |
| t=4-6min | 5,000 matches/min | 3 |
| t=6-10min | 5,000 matches/min (sustained) | 3 |

**Measurements:**
- Latency continuity: p99 should not spike during shard additions.
- Throughput inflection points: `throughput(N shards) >= 0.9 * N * throughput(1 shard)`.
- No shared-state bottleneck: shards operate independently.

#### Test Case B4: Hot Symbol Test

| Parameter | Value |
|:---|:---|
| Duration | 5 minutes |
| Load | 5,000 matches/min total, 80% directed to a single symbol on Shard A |
| Purpose | Validate the architecture's hot-symbol risk (Section 7, Risk #1) |
| Expected result | Even 4,000 matches/min on one shard (~67/sec) is within the 6M+ events/sec theoretical capacity |

### 7.3 Note on 30-Minute Burst Duration

The ASR specifies 30-minute peak bursts. The 5-minute sustained test (B2) and 10-minute ramp test (B3) are sufficient for iterative validation. If the system sustains 5,000/min for 5 minutes without latency degradation or memory growth, there is no architectural reason it would fail at 30 minutes (memory is bounded by Order Book depth, not time). A single 30-minute run can be executed as a final validation after iterating on shorter tests.

---

## 8. Load Testing Tool: k6

### 8.1 Selection: k6 (Grafana k6)

| Criterion | k6 | Gatling | Locust | Custom Go Client |
|:---|:---|:---|:---|:---|
| Language | JavaScript (test scripts) | Scala | Python | Go |
| ARM64 binary | Native via Homebrew | JVM-based (Rosetta or native JVM) | Platform-independent | Native if compiled |
| Resource efficiency | Very low. ~50 MB RAM for 1000 VUs. | Heavy. JVM: 500 MB+. | Moderate. Python GIL limits concurrency. | Very low. |
| Precise rate control | Built-in `constant-arrival-rate` executor | Injection profiles (less intuitive) | Manual (greenlet-based) | Hand-coded |
| Prometheus integration | Native `--out experimental-prometheus-rw` | Requires custom reporter | Requires custom exporter | Hand-coded |
| Histogram output | Built-in p50/p90/p95/p99/max | Good summary reports | Basic percentiles | Hand-coded |
| Scenario ramping | Built-in `ramping-arrival-rate` | Supports injection steps | Manual ramp logic | Hand-coded |

### 8.2 Justification

k6's `constant-arrival-rate` executor is the decisive factor. For ASR validation, we must control the exact stimulus rate (e.g., precisely 1,000 matches/min = 16.67/sec) **independent of response latency**. k6's arrival-rate model guarantees this: it opens new virtual users to maintain the target rate even if some requests are slow. Combined with native Prometheus output and sub-50 MB memory footprint, it is the optimal choice for a resource-constrained local experiment.

**Installation:** `brew install k6`.

---

## 9. Metrics Collection Strategy

### 9.1 Collection Stack

```
ME Process --[/metrics endpoint]--> Prometheus --[datasource]--> Grafana
k6         --[prometheus-rw]------> Prometheus --[datasource]--> Grafana
```

Prometheus scrapes the ME's `/metrics` endpoint every **5 seconds** (reduced from default 15s for finer granularity during short experiments). k6 pushes its own metrics to Prometheus via remote write.

### 9.2 ME-Internal Metrics (Instrumented in Application Code)

| Metric Name | Type | Description | ASR Relevance |
|:---|:---|:---|:---|
| `me_match_duration_seconds` | Histogram | Time from order received at ME to MatchResult generated. Buckets: 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0 | **Primary ASR 1 metric** |
| `me_order_validation_duration_seconds` | Histogram | Time spent in Order Validator | Latency budget attribution |
| `me_orderbook_insertion_duration_seconds` | Histogram | Time for TreeMap insertion | Latency budget attribution |
| `me_matching_algorithm_duration_seconds` | Histogram | Time in PriceTimePriorityMatcher | Latency budget attribution |
| `me_wal_append_duration_seconds` | Histogram | Time for WAL memory-mapped write | Latency budget (largest contributor) |
| `me_event_publish_duration_seconds` | Histogram | Time to copy event to local send buffer | Decoupling verification |
| `me_matches_total` | Counter | Total matches executed | **Primary ASR 2 metric** |
| `me_orders_received_total` | Counter | Total orders received (labeled by type: buy/sell) | Throughput tracking |
| `me_orderbook_depth` | Gauge | Current resting orders (labeled by side: bid/ask) | Order Book health |
| `me_orderbook_price_levels` | Gauge | Distinct price levels (labeled by side) | Matching complexity input |
| `me_ringbuffer_utilization_ratio` | Gauge | Ring buffer fill level (0.0 to 1.0) | Saturation indicator |

### 9.3 JVM Metrics (Auto-collected via Prometheus Java Client)

| Metric Name | Type | Description |
|:---|:---|:---|
| `jvm_gc_pause_seconds` | Summary | GC pause duration. Must stay < 5 ms for ZGC. |
| `jvm_memory_used_bytes` | Gauge | Heap and non-heap usage. |
| `jvm_threads_current` | Gauge | Thread count (should be ~5-6). |

### 9.4 k6-Emitted Metrics

| Metric Name | Type | Description |
|:---|:---|:---|
| `k6_http_req_duration` | Trend (histogram) | End-to-end HTTP request duration from k6 to ME. |
| `k6_http_reqs` | Counter | Total requests sent. |
| `k6_iterations` | Counter | Total test iterations. |
| `k6_vus` | Gauge | Current virtual users (adjusts to maintain arrival rate). |

### 9.5 Grafana Dashboard (4 Key Panels)

1. **Matching Latency Heatmap (ASR 1):** Heatmap of `me_match_duration_seconds` over time, with horizontal lines at 200 ms (target) and 30 ms (budget estimate). Shows whether actual latency matches the architecture's prediction.

2. **Throughput Per Shard (ASR 2):** Line chart of `rate(me_matches_total[30s])` per shard. Overlaid with the target rate (16.7/sec normal, 83.3/sec peak). Shows whether throughput scales linearly with shards.

3. **Latency Budget Breakdown:** Stacked bar chart showing average contribution of each sub-component (validation, insertion, matching, WAL, publish) to total match duration. Validates the architecture's latency budget.

4. **Resource Saturation:** Multi-line chart showing ring buffer utilization, Order Book depth, and JVM GC pauses over time. Identifies potential bottlenecks.

---

## 10. Pass/Fail Criteria

### 10.1 ASR 1: Latency

| Criterion | Metric | Pass | Fail |
|:---|:---|:---|:---|
| **Primary: p99 matching latency** | `histogram_quantile(0.99, me_match_duration_seconds)` | < 200 ms for the entire 5-min test at 1,000 matches/min | >= 200 ms at any sustained point (excluding first 30s warm-up) |
| **Secondary: budget validation** | Same metric | < 50 ms (validates the ~30 ms budget estimate with margin) | >= 50 ms (budget needs revision, but ASR may still pass) |
| **Decoupling proof** | `me_match_duration_seconds` during Kafka degradation (Test A4) | p99 does NOT increase by > 10% vs. baseline when Kafka is degraded | p99 increases > 10%, async path not fully decoupled |
| **GC impact** | `jvm_gc_pause_seconds_max` | Max GC pause < 5 ms (ZGC target) | Max GC pause >= 10 ms, GC is material tail latency contributor |
| **Latency budget accuracy** | Sum of sub-component histograms | Each sub-component p99 within 2x of estimate | Any sub-component exceeds 3x its estimated budget |

### 10.2 ASR 2: Scalability

| Criterion | Metric | Pass | Fail |
|:---|:---|:---|:---|
| **Primary: sustained 5K/min** | `sum(rate(me_matches_total[1m]))` across all shards | >= 4,750 matches/min (95% of target) for >= 4 consecutive minutes | < 4,750 matches/min, or drops below target for > 30s |
| **Linear scaling** | Per-shard throughput ratio | `throughput(N shards) >= 0.9 * N * throughput(1 shard)` | Sub-linear (< 0.9 * N), indicating shared bottleneck |
| **Per-match latency under scale** | `histogram_quantile(0.99, me_match_duration_seconds)` per shard | p99 per shard at 5K/min aggregate stays < 200 ms | p99 exceeds 200 ms under scaled load |
| **Shard isolation** | Per-shard latency correlation | Shard A p99 unaffected (< 5% change) when Shard B load increases | > 5% increase, indicating resource contention |
| **No memory leak** | `jvm_memory_used_bytes{area="heap"}` | Heap stable (no monotonic growth) over sustained period | Heap grows monotonically |

### 10.3 Experiment-Level Summary

| ASR | Status | Condition |
|:---|:---|:---|
| **ASR 1: PASS** | All primary and decoupling criteria pass. | The single-threaded matching design with in-memory Order Book and async event publishing achieves < 200 ms p99. |
| **ASR 1: CONDITIONAL PASS** | Primary passes but secondary (budget accuracy) fails. | The 200 ms target is met, but latency budget breakdown needs revision. Acceptable for the hypothesis. |
| **ASR 1: FAIL** | Primary criterion fails. | Design hypothesis invalidated. Investigate which sub-component exceeds its budget. |
| **ASR 2: PASS** | All primary and scaling criteria pass. | Asset-symbol sharding achieves linear horizontal scaling from 1K to 5K matches/min. |
| **ASR 2: CONDITIONAL PASS** | Throughput met but shard isolation fails. | System scales, but there is measurable cross-shard interference. Sharding works but may need CPU affinity tuning. |
| **ASR 2: FAIL** | Throughput or linear scaling criterion fails. | Sharding hypothesis invalidated. Investigate the shared bottleneck. |

---

## 11. Step-by-Step Setup Guide

### Phase 0: Prerequisites (One-Time Setup)

```bash
# Step 0.1: Start Docker Desktop
open -a Docker

# Verify Docker is running
docker info

# Step 0.2: Install k3d
brew install k3d

# Step 0.3: Install k6 (load testing tool)
brew install k6

# Step 0.4: Install Helm (for Prometheus/Grafana)
brew install helm

# Step 0.5: Verify kubectl (already installed)
kubectl version --client
```

### Phase 1: Create k3d Cluster

```bash
# Create cluster with 3 worker nodes (one per ME shard),
# port mappings, and disabled default ingress.
k3d cluster create matching-engine-exp \
  --servers 1 \
  --agents 3 \
  --port "8080:80@loadbalancer" \
  --port "9090:9090@loadbalancer" \
  --port "3000:3000@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

# Verify cluster is running
kubectl get nodes
# Expected: 1 server + 3 agent nodes, all Ready

# Set context
kubectl config use-context k3d-matching-engine-exp
```

### Phase 2: Deploy Observability Stack (Prometheus + Grafana)

```bash
# Step 2.1: Add Helm repos
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Step 2.2: Create namespace
kubectl create namespace monitoring

# Step 2.3: Deploy Prometheus (minimal resources)
helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --set server.resources.requests.cpu=250m \
  --set server.resources.requests.memory=256Mi \
  --set server.resources.limits.cpu=500m \
  --set server.resources.limits.memory=512Mi \
  --set server.global.scrape_interval=5s \
  --set alertmanager.enabled=false \
  --set kube-state-metrics.enabled=false \
  --set prometheus-node-exporter.enabled=false \
  --set prometheus-pushgateway.enabled=false \
  --set server.service.type=NodePort \
  --set server.service.nodePort=30090

# Step 2.4: Deploy Grafana
helm install grafana grafana/grafana \
  --namespace monitoring \
  --set resources.requests.cpu=250m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=256Mi \
  --set service.type=NodePort \
  --set service.nodePort=30000 \
  --set adminPassword=admin \
  --set "datasources.datasources\\.yaml.apiVersion=1" \
  --set "datasources.datasources\\.yaml.datasources[0].name=Prometheus" \
  --set "datasources.datasources\\.yaml.datasources[0].type=prometheus" \
  --set "datasources.datasources\\.yaml.datasources[0].url=http://prometheus-server.monitoring.svc:80" \
  --set "datasources.datasources\\.yaml.datasources[0].access=proxy" \
  --set "datasources.datasources\\.yaml.datasources[0].isDefault=true"

# Step 2.5: Verify
kubectl get pods -n monitoring
# Expected: prometheus-server and grafana pods Running
```

### Phase 3: Deploy Redpanda (Single Broker)

```bash
# Step 3.1: Create namespace
kubectl create namespace matching-engine

# Step 3.2: Deploy Redpanda as a single-node StatefulSet
cat <<'MANIFEST_EOF' | kubectl apply -n matching-engine -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redpanda
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
---
apiVersion: v1
kind: Service
metadata:
  name: redpanda
spec:
  clusterIP: None
  ports:
  - port: 9092
    name: kafka
  - port: 9644
    name: admin
  selector:
    app: redpanda
MANIFEST_EOF

# Step 3.3: Wait for Redpanda to be ready
kubectl wait --for=condition=Ready pod/redpanda-0 \
  -n matching-engine --timeout=120s

# Step 3.4: Create topics
kubectl exec -n matching-engine redpanda-0 -- \
  rpk topic create orders matches \
  --partitions 12 --replicas 1
```

### Phase 4: Build and Deploy Matching Engine

```bash
# Step 4.1: Build ME Docker image
# The Dockerfile should:
#   - Use eclipse-temurin:21-jre-alpine as base (ARM64 native)
#   - Copy the fat JAR
#   - Set JVM flags: -XX:+UseZGC -Xms256m -Xmx512m -XX:+AlwaysPreTouch
#   - Expose ports 8080 (HTTP orders) and 9091 (Prometheus metrics)
docker build -t matching-engine:experiment-v1 ./src/matching-engine/

# Load image into k3d's registry
k3d image import matching-engine:experiment-v1 \
  -c matching-engine-exp

# Step 4.2: Deploy ME Shard A (for ASR 1 experiments)
cat <<'MANIFEST_EOF' | kubectl apply -n matching-engine -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: me-shard-a
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
        env:
        - name: SHARD_ID
          value: "a"
        - name: SHARD_SYMBOLS
          value: "TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D"
        - name: KAFKA_BOOTSTRAP
          value: "redpanda-0.redpanda.matching-engine.svc.cluster.local:9092"
        - name: JAVA_OPTS
          value: "-XX:+UseZGC -Xms256m -Xmx512m -XX:+AlwaysPreTouch"
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
---
apiVersion: v1
kind: Service
metadata:
  name: me-shard-a
spec:
  selector:
    app: matching-engine
    shard: a
  ports:
  - port: 8080
    name: http
  - port: 9091
    name: metrics
MANIFEST_EOF

# Step 4.3: For ASR 2, deploy Shards B and C
# (Same manifests with shard=b/c and different SHARD_SYMBOLS)

# Step 4.4: Verify pods are running
kubectl get pods -n matching-engine
```

### Phase 5: Run Experiments with k6

```bash
# Step 5.1: Port-forward ME service for k6 access
kubectl port-forward svc/me-shard-a 8080:8080 \
  -n matching-engine &

# Step 5.2: Run ASR 1 -- Latency test
# k6 script uses constant-arrival-rate at 17 iterations/sec = 1000/min
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  test-asr1-latency.js

# Step 5.3: Run ASR 2 -- Scalability ramp test
# Port-forward all 3 shards, k6 distributes by symbol hash
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  test-asr2-scalability.js

# Step 5.4: Access Grafana to view results
# Open browser to http://localhost:3000, login admin/admin
# Import the pre-built dashboard JSON
```

### Phase 6: Teardown

```bash
k3d cluster delete matching-engine-exp
```

---

## 12. Key Decisions Summary

| Decision | Choice | Rationale |
|:---|:---|:---|
| K8s tool | k3d | Lightest footprint (250 MB), fastest startup (10s), native ARM64. Maximizes RAM for workloads. |
| Components included | ME, Redpanda, k6, Prometheus, Grafana | Minimum viable set touching the critical path and measuring the ASRs. Everything off the critical path excluded. |
| Load tool | k6 | `constant-arrival-rate` provides precise rate control. Native Prometheus remote-write. Sub-50 MB footprint. |
| ME language | Java 21 + LMAX Disruptor | 1:1 mapping to architecture spec. Validates JVM-specific risks (GC). TreeMap and Disruptor library available. |
| Resource budget | 8.75 GB / 8 cores of 16 GB / 12 cores | 45% RAM headroom, 33% CPU headroom. Sufficient with margin. |
| Test duration | 2-10 min per test case | Architecturally equivalent (memory bounded, not time-dependent). 30-min run reserved for final validation. |

---

*Related documents:*
- *[Initial Architecture](./architecture/initial-architecture.md)*
- *[Matching Engine Component Detail](./architecture/matching-engine-component-detail.md)*
- *[Deployment Detail](./architecture/deployment-detail.md)*
