package com.matchingengine.disruptor;

import com.lmax.disruptor.EventHandler;
import com.matchingengine.config.ShardConfig;
import com.matchingengine.domain.MatchResult;
import com.matchingengine.domain.MatchResultSet;
import com.matchingengine.domain.Order;
import com.matchingengine.domain.OrderBook;
import com.matchingengine.domain.OrderBookManager;
import com.matchingengine.domain.OrderId;
import com.matchingengine.domain.Price;
import com.matchingengine.matching.PriceTimePriorityMatcher;
import com.matchingengine.metrics.MetricsRegistry;
import com.matchingengine.publishing.EventPublisher;
import com.matchingengine.wal.WriteAheadLog;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.charset.StandardCharsets;

/**
 * The single-threaded event processor. Implements EventHandler<OrderEvent>.
 *
 * This handler runs on a SINGLE thread managed by the Disruptor's BatchEventProcessor.
 * All operations inside onEvent() are sequential. No locks, no synchronization,
 * no blocking I/O. The only synchronization point in the entire system is the
 * CAS-based slot claiming on the ring buffer (which happens on the HTTP threads,
 * not here).
 *
 * Processing pipeline per event:
 * 1. Validate order (symbol exists in shard)
 * 2. Create Order domain object
 * 3. Insert into order book
 * 4. Execute matching algorithm
 * 5. Process match results (remove filled resting orders)
 * 6. Append to WAL
 * 7. Publish events to Kafka (async)
 * 8. Record all metrics
 * 9. Flush WAL on endOfBatch
 */
public class OrderEventHandler implements EventHandler<OrderEvent> {

    private static final Logger logger = LoggerFactory.getLogger(OrderEventHandler.class);

    private final OrderBookManager bookManager;
    private final PriceTimePriorityMatcher matcher;
    private final WriteAheadLog wal;
    private final EventPublisher publisher;
    private final MetricsRegistry metrics;
    private final ShardConfig config;
    private final long ringBufferSize;

    public OrderEventHandler(OrderBookManager bookManager,
                             PriceTimePriorityMatcher matcher,
                             WriteAheadLog wal,
                             EventPublisher publisher,
                             MetricsRegistry metrics,
                             ShardConfig config,
                             long ringBufferSize) {
        this.bookManager = bookManager;
        this.matcher = matcher;
        this.wal = wal;
        this.publisher = publisher;
        this.metrics = metrics;
        this.config = config;
        this.ringBufferSize = ringBufferSize;
    }

    @Override
    public void onEvent(OrderEvent event, long sequence, boolean endOfBatch) {
        if (event.orderId == null) {
            // Slot was cleared or never populated -- skip
            return;
        }

        String shardId = config.getShardId();

        try {
            // 1. Validate order
            long validationStart = System.nanoTime();
            boolean valid = config.getSymbols().contains(event.symbol);
            long validationEnd = System.nanoTime();
            metrics.orderValidationDuration.labelValues(shardId)
                    .observe(nanosToSeconds(validationEnd - validationStart));

            if (!valid) {
                logger.warn("Rejected order {}: unknown symbol {} for shard {}",
                        event.orderId, event.symbol, shardId);
                event.clear();
                return;
            }

            // 2. Create Order domain object
            Order order = new Order(
                    new OrderId(event.orderId),
                    event.symbol,
                    event.side,
                    event.orderType,
                    new Price(event.price),
                    event.quantity,
                    event.timestamp
            );

            // 3. Get or create OrderBook
            long insertStart = System.nanoTime();
            OrderBook book = bookManager.getOrCreateBook(event.symbol);
            long insertEnd = System.nanoTime();
            metrics.orderbookInsertionDuration.labelValues(shardId)
                    .observe(nanosToSeconds(insertEnd - insertStart));

            // 4. Execute matching algorithm
            // The matcher handles both matching against the opposite side AND
            // inserting the remaining quantity into the book (resting).
            // We do NOT add the order to the book before matching to avoid
            // double-insertion for partially filled orders.
            long matchStart = System.nanoTime();
            MatchResultSet resultSet = matcher.match(book, order);
            long matchEnd = System.nanoTime();
            metrics.matchingAlgorithmDuration.labelValues(shardId)
                    .observe(nanosToSeconds(matchEnd - matchStart));

            // 5. Append to WAL
            long walStart = System.nanoTime();
            appendToWal(event, resultSet);
            long walEnd = System.nanoTime();
            metrics.walAppendDuration.labelValues(shardId)
                    .observe(nanosToSeconds(walEnd - walStart));

            // 6. Publish events to Kafka (async, non-blocking)
            long publishStart = System.nanoTime();
            publisher.publishOrderPlaced(order);
            for (MatchResult match : resultSet.getResults()) {
                publisher.publishMatch(match);
            }
            long publishEnd = System.nanoTime();
            metrics.eventPublishDuration.labelValues(shardId)
                    .observe(nanosToSeconds(publishEnd - publishStart));

            // 7. Record total match duration (from HTTP receive to processing complete)
            double totalDuration = nanosToSeconds(System.nanoTime() - event.receivedNanos);
            metrics.matchDuration.labelValues(shardId).observe(totalDuration);

            // 8. Increment match counter
            // Note: ordersReceivedTotal is incremented in OrderHttpHandler (HTTP layer)
            // to count all received orders, including those rejected at the ring buffer.
            metrics.matchesTotal.labelValues(shardId).inc(resultSet.getMatchCount());

            // 9. Update order book gauges (aggregate across all books)
            updateOrderBookGauges(shardId);

            // 10. Update ring buffer utilization
            // Approximate utilization: sequence modulo ringBufferSize gives the
            // position within the current ring buffer lap. We compute a rough
            // fill level as the fraction of the buffer that has been claimed but
            // potentially not yet processed.
            double utilization = ((double) (sequence % ringBufferSize)) / ringBufferSize;
            metrics.ringbufferUtilization.labelValues(shardId).set(utilization);

        } catch (Exception e) {
            logger.error("Error processing event sequence {}: {}", sequence, e.getMessage(), e);
        } finally {
            // Clear the event slot to prevent stale data
            event.clear();

            // Flush WAL on endOfBatch to amortize disk I/O
            if (endOfBatch && wal != null) {
                wal.flush();
            }
        }
    }

    private void appendToWal(OrderEvent event, MatchResultSet resultSet) {
        if (wal == null) {
            return;
        }
        try {
            // Serialize the event + results as a simple JSON string
            StringBuilder sb = new StringBuilder(256);
            sb.append("{\"orderId\":\"").append(event.orderId)
              .append("\",\"symbol\":\"").append(event.symbol)
              .append("\",\"side\":\"").append(event.side)
              .append("\",\"price\":").append(event.price)
              .append(",\"quantity\":").append(event.quantity)
              .append(",\"matches\":").append(resultSet.getMatchCount())
              .append(",\"totalFilled\":").append(resultSet.getTotalFilledQuantity())
              .append("}");
            byte[] data = sb.toString().getBytes(StandardCharsets.UTF_8);
            wal.append(data);
        } catch (Exception e) {
            logger.warn("Failed to append to WAL: {}", e.getMessage());
        }
    }

    private void updateOrderBookGauges(String shardId) {
        int totalBidDepth = 0;
        int totalAskDepth = 0;
        int totalBidLevels = 0;
        int totalAskLevels = 0;

        for (OrderBook book : bookManager.getAllBooks()) {
            totalBidDepth += book.getBidDepth();
            totalAskDepth += book.getAskDepth();
            totalBidLevels += book.getBidLevelCount();
            totalAskLevels += book.getAskLevelCount();
        }

        metrics.orderbookDepth.labelValues(shardId, "bid").set(totalBidDepth);
        metrics.orderbookDepth.labelValues(shardId, "ask").set(totalAskDepth);
        metrics.orderbookPriceLevels.labelValues(shardId, "bid").set(totalBidLevels);
        metrics.orderbookPriceLevels.labelValues(shardId, "ask").set(totalAskLevels);
    }

    private static double nanosToSeconds(long nanos) {
        return nanos / 1_000_000_000.0;
    }
}
