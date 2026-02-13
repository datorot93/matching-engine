package com.matchingengine.domain;

import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.TreeMap;

/**
 * In-memory order book for a single symbol.
 *
 * Bids: TreeMap with Comparator.reverseOrder() so firstKey() = highest bid.
 * Asks: TreeMap with natural ordering so firstKey() = lowest ask.
 * Order index: HashMap for O(1) lookup by orderId (used for cancels).
 */
public class OrderBook {

    private final String symbol;
    private final TreeMap<Price, PriceLevel> bids;
    private final TreeMap<Price, PriceLevel> asks;
    private final HashMap<String, Order> orderIndex;

    public OrderBook(String symbol) {
        this.symbol = symbol;
        this.bids = new TreeMap<>(Comparator.reverseOrder());
        this.asks = new TreeMap<>();
        this.orderIndex = new HashMap<>();
    }

    /**
     * Add an order to the appropriate side of the book.
     * BUY orders go to bids, SELL orders go to asks.
     */
    public void addOrder(Order order) {
        TreeMap<Price, PriceLevel> side;
        if (order.getSide() == Side.BUY) {
            side = bids;
        } else {
            side = asks;
        }
        PriceLevel level = side.computeIfAbsent(order.getLimitPrice(), PriceLevel::new);
        level.addOrder(order);
        orderIndex.put(order.getId().value(), order);
    }

    /**
     * Remove an order by orderId. Looks up in the index, removes from the
     * appropriate price level, and cleans up empty levels.
     */
    public void removeOrder(String orderId) {
        Order order = orderIndex.remove(orderId);
        if (order == null) {
            return;
        }
        TreeMap<Price, PriceLevel> side;
        if (order.getSide() == Side.BUY) {
            side = bids;
        } else {
            side = asks;
        }
        PriceLevel level = side.get(order.getLimitPrice());
        if (level != null) {
            level.removeOrder(order);
            if (level.isEmpty()) {
                side.remove(order.getLimitPrice());
            }
        }
    }

    public PriceLevel getBestBid() {
        Map.Entry<Price, PriceLevel> entry = bids.firstEntry();
        return entry != null ? entry.getValue() : null;
    }

    public PriceLevel getBestAsk() {
        Map.Entry<Price, PriceLevel> entry = asks.firstEntry();
        return entry != null ? entry.getValue() : null;
    }

    /**
     * Total number of resting orders on the bid side across all price levels.
     */
    public int getBidDepth() {
        int depth = 0;
        for (PriceLevel level : bids.values()) {
            depth += level.getOrderCount();
        }
        return depth;
    }

    /**
     * Total number of resting orders on the ask side across all price levels.
     */
    public int getAskDepth() {
        int depth = 0;
        for (PriceLevel level : asks.values()) {
            depth += level.getOrderCount();
        }
        return depth;
    }

    public int getBidLevelCount() {
        return bids.size();
    }

    public int getAskLevelCount() {
        return asks.size();
    }

    public String getSymbol() {
        return symbol;
    }

    public TreeMap<Price, PriceLevel> getBids() {
        return bids;
    }

    public TreeMap<Price, PriceLevel> getAsks() {
        return asks;
    }

    public HashMap<String, Order> getOrderIndex() {
        return orderIndex;
    }
}
