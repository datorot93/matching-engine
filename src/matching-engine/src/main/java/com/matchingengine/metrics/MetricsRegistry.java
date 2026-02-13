package com.matchingengine.metrics;

import io.prometheus.metrics.core.metrics.Counter;
import io.prometheus.metrics.core.metrics.Gauge;
import io.prometheus.metrics.core.metrics.Histogram;
import io.prometheus.metrics.exporter.httpserver.HTTPServer;
import io.prometheus.metrics.instrumentation.jvm.JvmMetrics;

import java.io.IOException;

/**
 * All Prometheus metrics for the Matching Engine, defined in one place.
 * Metric names and bucket configurations match Spec 1 Section 4.9 exactly.
 */
public class MetricsRegistry {

    // ---- Primary ASR 1 metric ----
    public final Histogram matchDuration;
    // name: me_match_duration_seconds

    // ---- Latency budget attribution ----
    public final Histogram orderValidationDuration;
    // name: me_order_validation_duration_seconds

    public final Histogram orderbookInsertionDuration;
    // name: me_orderbook_insertion_duration_seconds

    public final Histogram matchingAlgorithmDuration;
    // name: me_matching_algorithm_duration_seconds

    public final Histogram walAppendDuration;
    // name: me_wal_append_duration_seconds

    public final Histogram eventPublishDuration;
    // name: me_event_publish_duration_seconds

    // ---- Primary ASR 2 metric ----
    public final Counter matchesTotal;
    // name: me_matches_total

    public final Counter ordersReceivedTotal;
    // name: me_orders_received_total

    // ---- Order Book health ----
    public final Gauge orderbookDepth;
    // name: me_orderbook_depth

    public final Gauge orderbookPriceLevels;
    // name: me_orderbook_price_levels

    // ---- Saturation ----
    public final Gauge ringbufferUtilization;
    // name: me_ringbuffer_utilization_ratio

    private HTTPServer httpServer;

    public MetricsRegistry(String shardId) {
        // Primary ASR 1: end-to-end matching latency
        matchDuration = Histogram.builder()
                .name("me_match_duration_seconds")
                .help("Time from order received to match result generated")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0)
                .register();

        // Latency budget: validation
        orderValidationDuration = Histogram.builder()
                .name("me_order_validation_duration_seconds")
                .help("Time spent validating incoming orders")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.0001, 0.0005, 0.001, 0.005, 0.01)
                .register();

        // Latency budget: order book insertion
        orderbookInsertionDuration = Histogram.builder()
                .name("me_orderbook_insertion_duration_seconds")
                .help("Time spent inserting orders into the order book")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.0001, 0.0005, 0.001, 0.005, 0.01)
                .register();

        // Latency budget: matching algorithm
        matchingAlgorithmDuration = Histogram.builder()
                .name("me_matching_algorithm_duration_seconds")
                .help("Time spent in the matching algorithm")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05)
                .register();

        // Latency budget: WAL append
        walAppendDuration = Histogram.builder()
                .name("me_wal_append_duration_seconds")
                .help("Time spent appending to the write-ahead log")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.001, 0.005, 0.01, 0.025, 0.05, 0.1)
                .register();

        // Latency budget: event publishing
        eventPublishDuration = Histogram.builder()
                .name("me_event_publish_duration_seconds")
                .help("Time spent publishing events to Kafka")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.0001, 0.0005, 0.001, 0.005, 0.01)
                .register();

        // Primary ASR 2: throughput counter
        matchesTotal = Counter.builder()
                .name("me_matches_total")
                .help("Total matches executed")
                .labelNames("shard")
                .register();

        ordersReceivedTotal = Counter.builder()
                .name("me_orders_received_total")
                .help("Total orders received")
                .labelNames("shard", "side")
                .register();

        // Order book health gauges
        orderbookDepth = Gauge.builder()
                .name("me_orderbook_depth")
                .help("Current resting orders")
                .labelNames("shard", "side")
                .register();

        orderbookPriceLevels = Gauge.builder()
                .name("me_orderbook_price_levels")
                .help("Distinct price levels")
                .labelNames("shard", "side")
                .register();

        // Saturation gauge
        ringbufferUtilization = Gauge.builder()
                .name("me_ringbuffer_utilization_ratio")
                .help("Ring buffer fill level 0.0 to 1.0")
                .labelNames("shard")
                .register();

        // Register JVM metrics (GC, memory, threads)
        JvmMetrics.builder().register();
    }

    /**
     * Start the Prometheus HTTP server on the given port.
     * Exposes /metrics endpoint for Prometheus scraping.
     */
    public void startHttpServer(int port) throws IOException {
        httpServer = HTTPServer.builder()
                .port(port)
                .buildAndStart();
    }

    /**
     * Stop the Prometheus HTTP server.
     */
    public void close() {
        if (httpServer != null) {
            httpServer.close();
        }
    }
}
