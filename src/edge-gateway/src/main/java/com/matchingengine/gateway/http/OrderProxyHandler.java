package com.matchingengine.gateway.http;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.google.gson.JsonSyntaxException;
import com.matchingengine.gateway.metrics.GatewayMetrics;
import com.matchingengine.gateway.routing.SymbolRouter;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

/**
 * Proxies POST /orders requests to the correct ME shard based on the order's symbol.
 *
 * <p>Request flow:
 * <ol>
 *   <li>Read the full request body</li>
 *   <li>Parse JSON minimally to extract the "symbol" field</li>
 *   <li>Look up the target shard URL via {@link SymbolRouter}</li>
 *   <li>Forward the entire original body to {shardUrl}/orders</li>
 *   <li>Return the ME's response as a pass-through</li>
 *   <li>Record metrics</li>
 * </ol>
 *
 * <p>Error responses:
 * <ul>
 *   <li>400 - Unknown symbol or invalid JSON</li>
 *   <li>502 - ME shard unreachable</li>
 *   <li>504 - ME shard timeout</li>
 * </ul>
 */
public class OrderProxyHandler implements HttpHandler {

    private static final Logger logger = LoggerFactory.getLogger(OrderProxyHandler.class);
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);

    private final SymbolRouter router;
    private final HttpClient httpClient;
    private final GatewayMetrics metrics;

    public OrderProxyHandler(SymbolRouter router, HttpClient httpClient, GatewayMetrics metrics) {
        this.router = router;
        this.httpClient = httpClient;
        this.metrics = metrics;
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        long startNanos = System.nanoTime();
        String shardId = "unknown";

        try {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }

            // 1. Read request body
            byte[] requestBody = exchange.getRequestBody().readAllBytes();

            // 2. Parse JSON to extract "symbol" field (minimal parsing)
            String symbol;
            try {
                JsonObject json = JsonParser.parseString(new String(requestBody, StandardCharsets.UTF_8))
                        .getAsJsonObject();
                if (!json.has("symbol") || json.get("symbol").isJsonNull()) {
                    sendErrorResponse(exchange, 400, "Missing 'symbol' field in request body");
                    metrics.recordRoutingError("unknown_symbol");
                    return;
                }
                symbol = json.get("symbol").getAsString();
            } catch (JsonSyntaxException | IllegalStateException e) {
                sendErrorResponse(exchange, 400, "Invalid JSON in request body");
                metrics.recordRoutingError("unknown_symbol");
                return;
            }

            // 3. Look up target shard URL
            String shardUrl;
            try {
                shardId = router.getShardId(symbol);
                shardUrl = router.getShardUrl(symbol);
            } catch (IllegalArgumentException e) {
                sendErrorResponse(exchange, 400, "Unknown symbol: " + symbol);
                metrics.recordRoutingError("unknown_symbol");
                return;
            }

            // 4. Forward the entire original request body to {shardUrl}/orders
            HttpRequest proxyRequest = HttpRequest.newBuilder()
                    .uri(URI.create(shardUrl + "/orders"))
                    .header("Content-Type", "application/json")
                    .timeout(REQUEST_TIMEOUT)
                    .POST(HttpRequest.BodyPublishers.ofByteArray(requestBody))
                    .build();

            HttpResponse<byte[]> proxyResponse;
            try {
                proxyResponse = httpClient.send(proxyRequest, HttpResponse.BodyHandlers.ofByteArray());
            } catch (HttpTimeoutException e) {
                logger.warn("Timeout proxying to shard {}: {}", shardId, e.getMessage());
                sendErrorResponse(exchange, 504, "Shard timeout: " + shardId);
                metrics.recordRoutingError("timeout");
                double durationSeconds = (System.nanoTime() - startNanos) / 1_000_000_000.0;
                metrics.recordRequest(shardId, "5xx", durationSeconds);
                return;
            } catch (ConnectException e) {
                logger.warn("Cannot connect to shard {}: {}", shardId, e.getMessage());
                sendErrorResponse(exchange, 502, "Shard unavailable: " + shardId);
                metrics.recordRoutingError("shard_unavailable");
                double durationSeconds = (System.nanoTime() - startNanos) / 1_000_000_000.0;
                metrics.recordRequest(shardId, "5xx", durationSeconds);
                return;
            } catch (IOException e) {
                logger.warn("IO error proxying to shard {}: {}", shardId, e.getMessage());
                sendErrorResponse(exchange, 502, "Shard unavailable: " + shardId);
                metrics.recordRoutingError("shard_unavailable");
                double durationSeconds = (System.nanoTime() - startNanos) / 1_000_000_000.0;
                metrics.recordRequest(shardId, "5xx", durationSeconds);
                return;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                sendErrorResponse(exchange, 502, "Shard unavailable: " + shardId);
                metrics.recordRoutingError("shard_unavailable");
                return;
            }

            // 5. Return the ME's response directly (pass-through)
            byte[] responseBody = proxyResponse.body();
            int statusCode = proxyResponse.statusCode();

            // Copy content-type from upstream if present
            proxyResponse.headers().firstValue("Content-Type")
                    .ifPresent(ct -> exchange.getResponseHeaders().set("Content-Type", ct));

            if (responseBody != null && responseBody.length > 0) {
                exchange.sendResponseHeaders(statusCode, responseBody.length);
                try (OutputStream os = exchange.getResponseBody()) {
                    os.write(responseBody);
                }
            } else {
                exchange.sendResponseHeaders(statusCode, -1);
            }

            // 6. Record metrics
            double durationSeconds = (System.nanoTime() - startNanos) / 1_000_000_000.0;
            String statusCategory = categorizeStatus(statusCode);
            metrics.recordRequest(shardId, statusCategory, durationSeconds);

        } catch (Exception e) {
            logger.error("Unexpected error handling order proxy request", e);
            try {
                sendErrorResponse(exchange, 500, "Internal gateway error");
            } catch (IOException ignored) {
                // Response may already be committed
            }
            double durationSeconds = (System.nanoTime() - startNanos) / 1_000_000_000.0;
            metrics.recordRequest(shardId, "5xx", durationSeconds);
        } finally {
            exchange.close();
        }
    }

    private void sendErrorResponse(HttpExchange exchange, int statusCode, String message) throws IOException {
        byte[] body = ("{\"error\":\"" + message + "\"}").getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, body.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(body);
        }
    }

    private static String categorizeStatus(int statusCode) {
        if (statusCode >= 200 && statusCode < 300) return "2xx";
        if (statusCode >= 400 && statusCode < 500) return "4xx";
        return "5xx";
    }
}
