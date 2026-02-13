package com.matchingengine.http;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * HTTP handler for GET /health.
 * Returns a simple health check response with the shard identifier.
 */
public class HealthHttpHandler implements HttpHandler {

    private final String shardId;

    public HealthHttpHandler(String shardId) {
        this.shardId = shardId;
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
            byte[] response = "{\"error\":\"Method not allowed\"}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(405, response.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(response);
            }
            return;
        }

        String body = "{\"status\":\"UP\",\"shardId\":\"" + shardId + "\"}";
        byte[] responseBytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, responseBytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(responseBytes);
        }
    }
}
