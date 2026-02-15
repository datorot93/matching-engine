package com.matchingengine.logging;

import com.matchingengine.domain.OrderBook;
import com.matchingengine.domain.OrderBookManager;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import static net.logstash.logback.argument.StructuredArguments.keyValue;

/**
 * Logs aggregate matching statistics every N seconds on a separate daemon thread.
 * Never blocks the matching thread. Always enabled regardless of ENABLE_DETAILED_LOGGING.
 */
public class PeriodicStatsLogger {

    private static final Logger logger = LoggerFactory.getLogger(PeriodicStatsLogger.class);

    private final MatchingStats stats;
    private final OrderBookManager bookManager;
    private final String shardId;
    private final int intervalSeconds;
    private final ScheduledExecutorService scheduler;

    private long lastBuyOrders;
    private long lastSellOrders;
    private long lastMatches;
    private long lastRejected;

    public PeriodicStatsLogger(MatchingStats stats, OrderBookManager bookManager,
                               String shardId, int intervalSeconds) {
        this.stats = stats;
        this.bookManager = bookManager;
        this.shardId = shardId;
        this.intervalSeconds = intervalSeconds;
        this.scheduler = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "periodic-stats-logger");
            t.setDaemon(true);
            return t;
        });
    }

    public void start() {
        scheduler.scheduleAtFixedRate(this::logSummary, intervalSeconds, intervalSeconds, TimeUnit.SECONDS);
        logger.info("Periodic stats logger started",
                keyValue("event", "STATS_LOGGER_STARTED"),
                keyValue("shard", shardId),
                keyValue("intervalSeconds", intervalSeconds));
    }

    public void stop() {
        scheduler.shutdown();
        try {
            if (!scheduler.awaitTermination(5, TimeUnit.SECONDS)) {
                scheduler.shutdownNow();
            }
        } catch (InterruptedException e) {
            scheduler.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }

    /**
     * Log a final lifetime summary on shutdown.
     */
    public void logShutdownSummary() {
        long totalBuy = stats.buyOrdersReceived.get();
        long totalSell = stats.sellOrdersReceived.get();
        long totalMatches = stats.matchesExecuted.get();
        long totalRejected = stats.ordersRejected.get();
        long totalOrders = totalBuy + totalSell;
        double matchRate = totalOrders > 0 ? (double) totalMatches / totalOrders : 0.0;

        logger.info("Shutdown summary",
                keyValue("event", "SHUTDOWN_SUMMARY"),
                keyValue("shard", shardId),
                keyValue("totalBuyOrders", totalBuy),
                keyValue("totalSellOrders", totalSell),
                keyValue("totalOrders", totalOrders),
                keyValue("totalMatches", totalMatches),
                keyValue("totalRejected", totalRejected),
                keyValue("overallMatchRate", String.format("%.4f", matchRate)));
    }

    private void logSummary() {
        try {
            long currentBuy = stats.buyOrdersReceived.get();
            long currentSell = stats.sellOrdersReceived.get();
            long currentMatches = stats.matchesExecuted.get();
            long currentRejected = stats.ordersRejected.get();

            long deltaBuy = currentBuy - lastBuyOrders;
            long deltaSell = currentSell - lastSellOrders;
            long deltaMatches = currentMatches - lastMatches;
            long deltaRejected = currentRejected - lastRejected;
            long deltaTotal = deltaBuy + deltaSell;
            double matchRate = deltaTotal > 0 ? (double) deltaMatches / deltaTotal : 0.0;

            lastBuyOrders = currentBuy;
            lastSellOrders = currentSell;
            lastMatches = currentMatches;
            lastRejected = currentRejected;

            // Aggregate order book depth
            int bidDepth = 0, askDepth = 0, bidLevels = 0, askLevels = 0;
            for (OrderBook book : bookManager.getAllBooks()) {
                bidDepth += book.getBidDepth();
                askDepth += book.getAskDepth();
                bidLevels += book.getBidLevelCount();
                askLevels += book.getAskLevelCount();
            }

            logger.info("Periodic summary",
                    keyValue("event", "PERIODIC_SUMMARY"),
                    keyValue("shard", shardId),
                    keyValue("intervalSeconds", intervalSeconds),
                    keyValue("buyOrders", deltaBuy),
                    keyValue("sellOrders", deltaSell),
                    keyValue("totalOrders", deltaTotal),
                    keyValue("matchesExecuted", deltaMatches),
                    keyValue("rejected", deltaRejected),
                    keyValue("matchRate", String.format("%.4f", matchRate)),
                    keyValue("bidDepth", bidDepth),
                    keyValue("askDepth", askDepth),
                    keyValue("bidLevels", bidLevels),
                    keyValue("askLevels", askLevels));
        } catch (Exception e) {
            logger.error("Error in periodic stats logging", e);
        }
    }
}
