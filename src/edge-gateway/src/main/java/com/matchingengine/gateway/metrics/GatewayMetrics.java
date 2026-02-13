package com.matchingengine.gateway.metrics;

import io.prometheus.metrics.core.metrics.Counter;
import io.prometheus.metrics.core.metrics.Histogram;
import io.prometheus.metrics.exporter.httpserver.HTTPServer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;

/**
 * Prometheus metrics for the Edge Gateway.
 *
 * <p>Exposes three metrics:
 * <ul>
 *   <li>{@code gw_requests_total} - Counter of proxied requests (labels: shard, status)</li>
 *   <li>{@code gw_request_duration_seconds} - Histogram of request latency (labels: shard)</li>
 *   <li>{@code gw_routing_errors_total} - Counter of routing errors (labels: reason)</li>
 * </ul>
 */
public class GatewayMetrics {

    private static final Logger logger = LoggerFactory.getLogger(GatewayMetrics.class);

    public final Counter requestsTotal;
    public final Histogram requestDuration;
    public final Counter routingErrors;

    private final HTTPServer metricsServer;

    /**
     * Initialize all metrics and start the Prometheus HTTP exporter.
     *
     * @param metricsPort the port for the Prometheus scrape endpoint
     */
    public GatewayMetrics(int metricsPort) {
        this.requestsTotal = Counter.builder()
                .name("gw_requests_total")
                .help("Total number of proxied requests")
                .labelNames("shard", "status")
                .register();

        this.requestDuration = Histogram.builder()
                .name("gw_request_duration_seconds")
                .help("Request duration in seconds")
                .labelNames("shard")
                .classicOnly()
                .classicUpperBounds(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0)
                .register();

        this.routingErrors = Counter.builder()
                .name("gw_routing_errors_total")
                .help("Total number of routing errors")
                .labelNames("reason")
                .register();

        try {
            this.metricsServer = HTTPServer.builder()
                    .port(metricsPort)
                    .buildAndStart();
            logger.info("Prometheus metrics server started on port {}", metricsPort);
        } catch (IOException e) {
            throw new RuntimeException("Failed to start Prometheus metrics server on port " + metricsPort, e);
        }
    }

    /**
     * Record a successful or failed request.
     *
     * @param shardId the shard that handled the request
     * @param statusCategory the HTTP status category (e.g. "2xx", "4xx", "5xx")
     * @param durationSeconds the request duration in seconds
     */
    public void recordRequest(String shardId, String statusCategory, double durationSeconds) {
        requestsTotal.labelValues(shardId, statusCategory).inc();
        requestDuration.labelValues(shardId).observe(durationSeconds);
    }

    /**
     * Record a routing error.
     *
     * @param reason the error reason (e.g. "unknown_symbol", "shard_unavailable", "timeout")
     */
    public void recordRoutingError(String reason) {
        routingErrors.labelValues(reason).inc();
    }

    /**
     * Stop the metrics HTTP server.
     */
    public void close() {
        if (metricsServer != null) {
            metricsServer.close();
        }
    }
}
