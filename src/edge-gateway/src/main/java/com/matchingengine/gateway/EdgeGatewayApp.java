package com.matchingengine.gateway;

import com.matchingengine.gateway.config.GatewayConfig;
import com.matchingengine.gateway.http.HealthHandler;
import com.matchingengine.gateway.http.OrderProxyHandler;
import com.matchingengine.gateway.http.SeedProxyHandler;
import com.matchingengine.gateway.metrics.GatewayMetrics;
import com.matchingengine.gateway.routing.ConsistentHashRouter;
import com.matchingengine.gateway.routing.SymbolRouter;
import com.sun.net.httpserver.HttpServer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.http.HttpClient;
import java.time.Duration;
import java.util.concurrent.Executors;

/**
 * Main entry point for the Edge Gateway.
 *
 * <p>Startup sequence:
 * <ol>
 *   <li>Parse {@link GatewayConfig} from environment variables</li>
 *   <li>Initialize {@link GatewayMetrics} and start Prometheus HTTP on metrics port</li>
 *   <li>Create {@link ConsistentHashRouter} from the shard map</li>
 *   <li>Create {@link HttpClient} with connection pool</li>
 *   <li>Start {@link HttpServer} on HTTP port with /orders, /health, /seed/* handlers</li>
 *   <li>Log the routing table</li>
 * </ol>
 */
public class EdgeGatewayApp {

    private static final Logger logger = LoggerFactory.getLogger(EdgeGatewayApp.class);

    public static void main(String[] args) {
        try {
            // 1. Parse GatewayConfig from environment variables
            GatewayConfig config = GatewayConfig.fromEnv();
            logger.info("Configuration loaded: {}", config);

            // 2. Initialize GatewayMetrics and start Prometheus HTTP on metrics port
            GatewayMetrics metrics = new GatewayMetrics(config.getMetricsPort());

            // 3. Create ConsistentHashRouter from the shard map
            SymbolRouter router = new ConsistentHashRouter(
                    config.getShardSymbols(), config.getShardMap());

            // 4. Create java.net.http.HttpClient with connection pool
            HttpClient httpClient = HttpClient.newBuilder()
                    .version(HttpClient.Version.HTTP_1_1)
                    .connectTimeout(Duration.ofSeconds(2))
                    .executor(Executors.newFixedThreadPool(
                            Math.max(4, Runtime.getRuntime().availableProcessors())))
                    .build();

            // 5. Start HttpServer on httpPort with handlers
            HttpServer server = HttpServer.create(
                    new InetSocketAddress(config.getHttpPort()), 0);

            // Use a thread pool for handling requests
            server.setExecutor(Executors.newFixedThreadPool(
                    Math.max(8, Runtime.getRuntime().availableProcessors() * 2)));

            server.createContext("/orders", new OrderProxyHandler(router, httpClient, metrics));
            server.createContext("/health", new HealthHandler());
            server.createContext("/seed/", new SeedProxyHandler(config.getShardMap(), httpClient));

            server.start();

            // 6. Log routing table
            logger.info("Edge Gateway started on port {}. Routing table: {}",
                    config.getHttpPort(), config.getShardMap());
            logger.info("Symbol mapping: {}",
                    ((ConsistentHashRouter) router).getSymbolToShardId());

            // Shutdown hook
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                logger.info("Shutting down Edge Gateway...");
                server.stop(2);
                metrics.close();
                logger.info("Edge Gateway stopped.");
            }));

        } catch (IOException e) {
            logger.error("Failed to start Edge Gateway", e);
            System.exit(1);
        } catch (Exception e) {
            logger.error("Unexpected error during startup", e);
            System.exit(1);
        }
    }
}
