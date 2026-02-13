package com.matchingengine.gateway.http;

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
import java.util.Map;

/**
 * Proxies POST /seed/{shardId} requests to the specified ME shard's /seed endpoint.
 *
 * <p>The shard ID is extracted from the URL path. The request body is forwarded
 * as-is to the target shard.
 */
public class SeedProxyHandler implements HttpHandler {

    private static final Logger logger = LoggerFactory.getLogger(SeedProxyHandler.class);
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);

    private final Map<String, String> shardIdToUrl;
    private final HttpClient httpClient;

    /**
     * @param shardIdToUrl mapping of shard ID to ME base URL
     * @param httpClient   shared HTTP client for proxying
     */
    public SeedProxyHandler(Map<String, String> shardIdToUrl, HttpClient httpClient) {
        this.shardIdToUrl = shardIdToUrl;
        this.httpClient = httpClient;
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        try {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }

            // 1. Extract shardId from path: /seed/a -> "a"
            String path = exchange.getRequestURI().getPath();
            String shardId = extractShardId(path);

            if (shardId == null || shardId.isEmpty()) {
                sendErrorResponse(exchange, 400, "Missing shard ID in path. Expected /seed/{shardId}");
                return;
            }

            // 2. Look up shard URL
            String shardUrl = shardIdToUrl.get(shardId);
            if (shardUrl == null) {
                sendErrorResponse(exchange, 404, "Unknown shard: " + shardId);
                return;
            }

            // 3. Read request body and forward to {shardUrl}/seed
            byte[] requestBody = exchange.getRequestBody().readAllBytes();

            HttpRequest proxyRequest = HttpRequest.newBuilder()
                    .uri(URI.create(shardUrl + "/seed"))
                    .header("Content-Type", "application/json")
                    .timeout(REQUEST_TIMEOUT)
                    .POST(HttpRequest.BodyPublishers.ofByteArray(requestBody))
                    .build();

            HttpResponse<byte[]> proxyResponse;
            try {
                proxyResponse = httpClient.send(proxyRequest, HttpResponse.BodyHandlers.ofByteArray());
            } catch (HttpTimeoutException e) {
                logger.warn("Timeout proxying seed to shard {}: {}", shardId, e.getMessage());
                sendErrorResponse(exchange, 504, "Shard timeout: " + shardId);
                return;
            } catch (ConnectException e) {
                logger.warn("Cannot connect to shard {} for seed: {}", shardId, e.getMessage());
                sendErrorResponse(exchange, 502, "Shard unavailable: " + shardId);
                return;
            } catch (IOException e) {
                logger.warn("IO error proxying seed to shard {}: {}", shardId, e.getMessage());
                sendErrorResponse(exchange, 502, "Shard unavailable: " + shardId);
                return;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                sendErrorResponse(exchange, 502, "Shard unavailable: " + shardId);
                return;
            }

            // 4. Return response pass-through
            byte[] responseBody = proxyResponse.body();
            int statusCode = proxyResponse.statusCode();

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

        } catch (Exception e) {
            logger.error("Unexpected error handling seed proxy request", e);
            try {
                sendErrorResponse(exchange, 500, "Internal gateway error");
            } catch (IOException ignored) {
                // Response may already be committed
            }
        } finally {
            exchange.close();
        }
    }

    /**
     * Extracts the shard ID from a path like "/seed/a" or "/seed/abc".
     * Returns null if the path does not contain a shard ID segment.
     */
    private String extractShardId(String path) {
        // Path format: /seed/{shardId}
        if (path == null) return null;
        String prefix = "/seed/";
        if (!path.startsWith(prefix)) return null;
        String shardId = path.substring(prefix.length());
        // Remove trailing slash if present
        if (shardId.endsWith("/")) {
            shardId = shardId.substring(0, shardId.length() - 1);
        }
        return shardId.isEmpty() ? null : shardId;
    }

    private void sendErrorResponse(HttpExchange exchange, int statusCode, String message) throws IOException {
        byte[] body = ("{\"error\":\"" + message + "\"}").getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, body.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(body);
        }
    }
}
