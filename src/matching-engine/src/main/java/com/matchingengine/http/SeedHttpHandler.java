package com.matchingengine.http;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.matchingengine.domain.Order;
import com.matchingengine.domain.OrderBookManager;
import com.matchingengine.domain.OrderId;
import com.matchingengine.domain.OrderType;
import com.matchingengine.domain.Price;
import com.matchingengine.domain.Side;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * HTTP handler for POST /seed.
 *
 * Accepts a JSON array of orders to pre-populate the order book
 * WITHOUT going through the ring buffer. Used by the test framework
 * to set up initial resting orders before load testing.
 *
 * This endpoint is for experiment setup ONLY. It bypasses the ring buffer
 * and matching logic -- orders are inserted directly into the order book.
 */
public class SeedHttpHandler implements HttpHandler {

    private static final Logger logger = LoggerFactory.getLogger(SeedHttpHandler.class);

    private final OrderBookManager bookManager;

    public SeedHttpHandler(OrderBookManager bookManager) {
        this.bookManager = bookManager;
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            sendResponse(exchange, 405, "{\"error\":\"Method not allowed\"}");
            return;
        }

        try {
            // Read request body
            String body;
            try (InputStream is = exchange.getRequestBody()) {
                body = new String(is.readAllBytes(), StandardCharsets.UTF_8);
            }

            // Parse JSON
            JsonObject json = JsonParser.parseString(body).getAsJsonObject();
            JsonArray ordersArray = json.getAsJsonArray("orders");

            int seededCount = 0;
            for (JsonElement element : ordersArray) {
                JsonObject orderJson = element.getAsJsonObject();

                String orderId = orderJson.get("orderId").getAsString();
                String symbol = orderJson.get("symbol").getAsString();
                Side side = Side.valueOf(orderJson.get("side").getAsString().toUpperCase());
                OrderType type = OrderType.valueOf(
                        orderJson.has("type")
                                ? orderJson.get("type").getAsString().toUpperCase()
                                : "LIMIT");
                long price = orderJson.get("price").getAsLong();
                long quantity = orderJson.get("quantity").getAsLong();
                long timestamp = orderJson.has("timestamp")
                        && !orderJson.get("timestamp").isJsonNull()
                        ? orderJson.get("timestamp").getAsLong()
                        : System.currentTimeMillis();

                Order order = new Order(
                        new OrderId(orderId),
                        symbol,
                        side,
                        type,
                        new Price(price),
                        quantity,
                        timestamp
                );

                // Directly add to order book -- bypass ring buffer and matching
                bookManager.getOrCreateBook(symbol).addOrder(order);
                seededCount++;
            }

            logger.info("Seeded {} orders into the order book", seededCount);

            String response = "{\"seeded\":" + seededCount + "}";
            sendResponse(exchange, 200, response);

        } catch (Exception e) {
            logger.error("Error handling seed request: {}", e.getMessage(), e);
            sendResponse(exchange, 400,
                    "{\"error\":\"" + e.getMessage() + "\"}");
        }
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
