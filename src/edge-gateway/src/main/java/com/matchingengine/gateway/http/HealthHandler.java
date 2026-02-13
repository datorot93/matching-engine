package com.matchingengine.gateway.http;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Health check endpoint handler.
 *
 * <p>Responds to GET /health with a JSON body indicating the gateway is operational.
 */
public class HealthHandler implements HttpHandler {

    private static final Logger logger = LoggerFactory.getLogger(HealthHandler.class);

    private static final byte[] RESPONSE_BODY =
            "{\"status\":\"UP\",\"component\":\"edge-gateway\"}".getBytes(StandardCharsets.UTF_8);

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        try {
            if (!"GET".equalsIgnoreCase(exchange.getRequestMethod())) {
                exchange.sendResponseHeaders(405, -1);
                return;
            }

            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, RESPONSE_BODY.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(RESPONSE_BODY);
            }
        } catch (IOException e) {
            logger.error("Error handling health request", e);
            throw e;
        } finally {
            exchange.close();
        }
    }
}
