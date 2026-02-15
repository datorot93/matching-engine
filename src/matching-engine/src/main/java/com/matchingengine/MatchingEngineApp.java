package com.matchingengine;

import com.lmax.disruptor.RingBuffer;
import com.lmax.disruptor.YieldingWaitStrategy;
import com.lmax.disruptor.dsl.Disruptor;
import com.lmax.disruptor.dsl.ProducerType;
import com.lmax.disruptor.util.DaemonThreadFactory;
import com.matchingengine.config.ShardConfig;
import com.matchingengine.disruptor.OrderEvent;
import com.matchingengine.disruptor.OrderEventFactory;
import com.matchingengine.disruptor.OrderEventHandler;
import com.matchingengine.domain.OrderBookManager;
import com.matchingengine.http.HealthHttpHandler;
import com.matchingengine.http.OrderHttpHandler;
import com.matchingengine.http.SeedHttpHandler;
import com.matchingengine.matching.PriceTimePriorityMatcher;
import com.matchingengine.logging.MatchingStats;
import com.matchingengine.logging.PeriodicStatsLogger;
import com.matchingengine.metrics.MetricsRegistry;
import com.matchingengine.publishing.EventPublisher;
import com.matchingengine.wal.WriteAheadLog;
import com.sun.net.httpserver.HttpServer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;

/**
 * Main entry point for the Matching Engine application.
 *
 * Startup sequence:
 * 1. Parse ShardConfig from environment variables
 * 2. Initialize MetricsRegistry + Prometheus HTTP server
 * 3. Initialize WriteAheadLog (memory-mapped file)
 * 4. Initialize EventPublisher (Kafka producer)
 * 5. Initialize OrderBookManager
 * 6. Initialize PriceTimePriorityMatcher
 * 7. Create LMAX Disruptor (ring buffer, producer type, wait strategy)
 * 8. Register OrderEventHandler
 * 9. Start the Disruptor
 * 10. Start HttpServer with /orders, /health, /seed handlers
 * 11. Register JVM shutdown hook
 */
public class MatchingEngineApp {

    private static final Logger logger = LoggerFactory.getLogger(MatchingEngineApp.class);

    public static void main(String[] args) {
        logger.info("Starting Matching Engine...");

        // 1. Parse configuration from environment variables
        ShardConfig config = ShardConfig.fromEnv();
        logger.info("Configuration: {}", config);

        // 2. Initialize MetricsRegistry and start Prometheus HTTP server
        MetricsRegistry metrics = new MetricsRegistry(config.getShardId());
        try {
            metrics.startHttpServer(config.getMetricsPort());
            logger.info("Prometheus metrics HTTP server started on port {}",
                    config.getMetricsPort());
        } catch (IOException e) {
            logger.error("Failed to start Prometheus HTTP server on port {}: {}",
                    config.getMetricsPort(), e.getMessage());
            System.exit(1);
        }

        // 3. Initialize WriteAheadLog
        WriteAheadLog wal = null;
        try {
            wal = new WriteAheadLog(config.getWalPath(), config.getWalSizeMb());
            logger.info("WAL initialized at {} ({} MB)", config.getWalPath(),
                    config.getWalSizeMb());
        } catch (IOException e) {
            logger.error("Failed to initialize WAL: {}. Continuing without WAL.",
                    e.getMessage());
        }

        // 4. Initialize EventPublisher (Kafka producer)
        EventPublisher publisher = new EventPublisher(config.getKafkaBootstrap());

        // 5. Initialize OrderBookManager
        OrderBookManager bookManager = new OrderBookManager();

        // 6. Initialize PriceTimePriorityMatcher
        PriceTimePriorityMatcher matcher = new PriceTimePriorityMatcher();

        // 7. Create LMAX Disruptor
        int ringBufferSize = config.getRingBufferSize();
        Disruptor<OrderEvent> disruptor = new Disruptor<>(
                new OrderEventFactory(),
                ringBufferSize,
                DaemonThreadFactory.INSTANCE,
                ProducerType.MULTI,
                new YieldingWaitStrategy()
        );

        // 8. Register OrderEventHandler with shared stats
        MatchingStats matchingStats = new MatchingStats();
        OrderEventHandler handler = new OrderEventHandler(
                bookManager, matcher, wal, publisher, metrics, config, ringBufferSize, matchingStats);
        disruptor.handleEventsWith(handler);

        // 9. Start the Disruptor
        disruptor.start();
        RingBuffer<OrderEvent> ringBuffer = disruptor.getRingBuffer();
        logger.info("Disruptor started. Ring buffer size: {}", ringBufferSize);

        // 9b. Start periodic stats logger (every 10 seconds, separate daemon thread)
        PeriodicStatsLogger statsLogger = new PeriodicStatsLogger(
                matchingStats, bookManager, config.getShardId(), 10);
        statsLogger.start();

        // 10. Start HTTP server
        HttpServer httpServer;
        try {
            httpServer = HttpServer.create(
                    new InetSocketAddress(config.getHttpPort()), 0);
            httpServer.createContext("/orders",
                    new OrderHttpHandler(ringBuffer, config, metrics));
            httpServer.createContext("/health",
                    new HealthHttpHandler(config.getShardId()));
            httpServer.createContext("/seed",
                    new SeedHttpHandler(bookManager));
            httpServer.setExecutor(Executors.newFixedThreadPool(
                    Runtime.getRuntime().availableProcessors()));
            httpServer.start();
            logger.info("HTTP server started on port {}", config.getHttpPort());
        } catch (IOException e) {
            logger.error("Failed to start HTTP server on port {}: {}",
                    config.getHttpPort(), e.getMessage());
            System.exit(1);
        }

        // 11. Register shutdown hook
        final WriteAheadLog walRef = wal;
        final Disruptor<OrderEvent> disruptorRef = disruptor;
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            logger.info("Shutting down Matching Engine...");
            try {
                disruptorRef.shutdown();
                logger.info("Disruptor shut down.");
            } catch (Exception e) {
                logger.warn("Error shutting down Disruptor: {}", e.getMessage());
            }
            if (walRef != null) {
                walRef.close();
                logger.info("WAL closed.");
            }
            publisher.close();

            // Log final lifetime summary
            statsLogger.logShutdownSummary();
            statsLogger.stop();

            metrics.close();
            logger.info("Matching Engine shut down complete.");
        }));

        logger.info("Matching Engine is ready. Shard: {}, Symbols: {}, HTTP: {}, Metrics: {}",
                config.getShardId(), config.getSymbols(),
                config.getHttpPort(), config.getMetricsPort());
    }
}
