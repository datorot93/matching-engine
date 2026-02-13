package com.matchingengine.http;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.lmax.disruptor.RingBuffer;
import com.matchingengine.config.ShardConfig;
import com.matchingengine.disruptor.OrderEvent;
import com.matchingengine.disruptor.OrderEventTranslator;
import com.matchingengine.domain.OrderType;
import com.matchingengine.domain.Side;
import com.matchingengine.metrics.MetricsRegistry;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * HTTP handler for POST /orders.
 *
 * Fire-and-publish pattern: parses the order from JSON, validates it,
 * publishes to the Disruptor ring buffer, and returns 200 ACCEPTED immediately.
 * Does NOT wait for matching to complete.
 */
public class OrderHttpHandler implements HttpHandler {

    private static final Logger logger = LoggerFactory.getLogger(OrderHttpHandler.class);

    private final RingBuffer<OrderEvent> ringBuffer;
    private final ShardConfig config;
    private final MetricsRegistry metrics;
    private final Gson gson;

    public OrderHttpHandler(RingBuffer<OrderEvent> ringBuffer, ShardConfig config,
                            MetricsRegistry metrics) {
        this.ringBuffer = ringBuffer;
        this.config = config;
        this.metrics = metrics;
        this.gson = new Gson();
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
            return;
        }

        long receivedNanos = System.nanoTime();

        try {
            // Read request body
            String body;
            try (InputStream is = exchange.getRequestBody()) {
                body = new String(is.readAllBytes(), StandardCharsets.UTF_8);
            }

            // Parse JSON
            JsonObject json = JsonParser.parseString(body).getAsJsonObject();

            String orderId = json.get("orderId").getAsString();
            String symbol = json.get("symbol").getAsString();
            String sideStr = json.get("side").getAsString();
            String typeStr = json.has("type") ? json.get("type").getAsString() : "LIMIT";
            long price = json.get("price").getAsLong();
            long quantity = json.get("quantity").getAsLong();
            long timestamp = json.has("timestamp") && !json.get("timestamp").isJsonNull()
                    ? json.get("timestamp").getAsLong()
                    : System.currentTimeMillis();

            Side side;
            try {
                side = Side.valueOf(sideStr.toUpperCase());
            } catch (IllegalArgumentException e) {
                sendRejectResponse(exchange, orderId, "Invalid side: " + sideStr);
                return;
            }

            OrderType orderType;
            try {
                orderType = OrderType.valueOf(typeStr.toUpperCase());
            } catch (IllegalArgumentException e) {
                sendRejectResponse(exchange, orderId, "Invalid order type: " + typeStr);
                return;
            }

            // Validate symbol is handled by this shard
            if (!config.getSymbols().contains(symbol)) {
                sendRejectResponse(exchange, orderId, "Unknown symbol: " + symbol);
                return;
            }

            // Validate price and quantity
            if (price <= 0) {
                sendRejectResponse(exchange, orderId, "Price must be positive: " + price);
                return;
            }
            if (quantity <= 0) {
                sendRejectResponse(exchange, orderId, "Quantity must be positive: " + quantity);
                return;
            }

            // Publish to ring buffer using the two-phase approach
            long sequence;
            try {
                sequence = ringBuffer.tryNext();
            } catch (Exception e) {
                // Ring buffer is full
                logger.warn("Ring buffer full. Rejecting order {}", orderId);
                sendResponse(exchange, 503,
                        "{\"status\":\"REJECTED\",\"orderId\":\"" + orderId
                                + "\",\"reason\":\"Ring buffer full\"}");
                return;
            }

            try {
                OrderEvent event = ringBuffer.get(sequence);
                OrderEventTranslator.translate(event, sequence, orderId, symbol,
                        side, orderType, price, quantity, timestamp, receivedNanos);
            } finally {
                ringBuffer.publish(sequence);
            }

            // Record that we received an order (HTTP-side counter, complements the
            // event-handler-side counter for orders that actually get processed)
            metrics.ordersReceivedTotal.labelValues(config.getShardId(),
                    side.name().toLowerCase()).inc();

            // Return 200 ACCEPTED immediately -- do NOT wait for matching
            JsonObject response = new JsonObject();
            response.addProperty("status", "ACCEPTED");
            response.addProperty("orderId", orderId);
            response.addProperty("shardId", config.getShardId());
            response.addProperty("timestamp", System.currentTimeMillis());

            sendResponse(exchange, 200, gson.toJson(response));

        } catch (Exception e) {
            logger.error("Error handling order request: {}", e.getMessage(), e);
            sendResponse(exchange, 400,
                    "{\"status\":\"REJECTED\",\"reason\":\"" + e.getMessage() + "\"}");
        }
    }

    private void sendRejectResponse(HttpExchange exchange, String orderId, String reason)
            throws IOException {
        JsonObject response = new JsonObject();
        response.addProperty("status", "REJECTED");
        response.addProperty("orderId", orderId);
        response.addProperty("reason", reason);
        sendResponse(exchange, 400, gson.toJson(response));
    }

    private void sendResponse(HttpExchange exchange, int statusCode, String body)
            throws IOException {
        byte[] responseBytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, responseBytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(responseBytes);
        }
    }
}
