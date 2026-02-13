package com.matchingengine.matching;

import com.matchingengine.domain.MatchResult;
import com.matchingengine.domain.MatchResultSet;
import com.matchingengine.domain.Order;
import com.matchingengine.domain.OrderBook;
import com.matchingengine.domain.Price;
import com.matchingengine.domain.PriceLevel;
import com.matchingengine.domain.Side;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Price-time priority matching algorithm.
 *
 * Price priority: best price on the opposite side is matched first
 * (lowest ask for a buy, highest bid for a sell).
 *
 * Time priority: within the same price level, the order that arrived
 * earliest is matched first (FIFO via ArrayDeque).
 *
 * Time complexity: O(log P + F) where P = price levels, F = fills.
 */
public class PriceTimePriorityMatcher implements MatchingAlgorithm {

    private final AtomicLong matchSequence = new AtomicLong(0);

    @Override
    public MatchResultSet match(OrderBook book, Order incoming) {
        List<MatchResult> results = new ArrayList<>();
        long totalFilled = 0;

        // Determine opposite side of the book
        TreeMap<Price, PriceLevel> oppositeBook;
        if (incoming.getSide() == Side.BUY) {
            oppositeBook = book.getAsks();  // ascending price (lowest ask first)
        } else {
            oppositeBook = book.getBids();  // descending price (highest bid first)
        }

        while (incoming.getRemainingQuantity() > 0) {
            Map.Entry<Price, PriceLevel> bestEntry = oppositeBook.firstEntry();
            if (bestEntry == null) {
                break;
            }

            Price bestPrice = bestEntry.getKey();

            // Check price compatibility
            if (incoming.getSide() == Side.BUY
                    && incoming.getLimitPrice().cents() < bestPrice.cents()) {
                break;  // Buy price too low to match lowest ask
            }
            if (incoming.getSide() == Side.SELL
                    && incoming.getLimitPrice().cents() > bestPrice.cents()) {
                break;  // Sell price too high to match highest bid
            }

            PriceLevel level = bestEntry.getValue();

            while (incoming.getRemainingQuantity() > 0 && !level.isEmpty()) {
                Order resting = level.peekFirst();
                long fillQty = Math.min(incoming.getRemainingQuantity(),
                                        resting.getRemainingQuantity());

                incoming.fill(fillQty);
                resting.fill(fillQty);

                MatchResult result = new MatchResult(
                    generateMatchId(),
                    incoming.getId().value(),   // taker = incoming
                    resting.getId().value(),    // maker = resting
                    incoming.getSymbol(),
                    bestPrice.cents(),
                    fillQty,
                    System.currentTimeMillis(),
                    incoming.getSide()
                );
                results.add(result);
                totalFilled += fillQty;

                if (resting.isFilled()) {
                    level.pollFirst();
                    book.getOrderIndex().remove(resting.getId().value());
                }
            }

            // Clean up empty price level
            if (level.isEmpty()) {
                oppositeBook.pollFirstEntry();
            }
        }

        return new MatchResultSet(results, totalFilled, incoming.isFilled());
    }

    private String generateMatchId() {
        return "m-" + String.format("%05d", matchSequence.incrementAndGet());
    }
}
