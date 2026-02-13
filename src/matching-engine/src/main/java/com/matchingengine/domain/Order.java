package com.matchingengine.domain;

/**
 * Order entity with fill tracking. Mutable: remainingQuantity, filledQuantity,
 * and status change as the order is matched.
 */
public class Order {

    private final OrderId id;
    private final String symbol;
    private final Side side;
    private final OrderType type;
    private final Price limitPrice;
    private final long originalQuantity;
    private long remainingQuantity;
    private long filledQuantity;
    private final long timestamp;
    private OrderStatus status;

    public Order(OrderId id, String symbol, Side side, OrderType type,
                 Price limitPrice, long quantity, long timestamp) {
        this.id = id;
        this.symbol = symbol;
        this.side = side;
        this.type = type;
        this.limitPrice = limitPrice;
        this.originalQuantity = quantity;
        this.remainingQuantity = quantity;
        this.filledQuantity = 0;
        this.timestamp = timestamp;
        this.status = OrderStatus.NEW;
    }

    /**
     * Fill this order by the given quantity. Reduces remainingQuantity,
     * increases filledQuantity, and updates status accordingly.
     */
    public void fill(long qty) {
        if (qty <= 0) {
            throw new IllegalArgumentException("Fill quantity must be positive: " + qty);
        }
        if (qty > remainingQuantity) {
            throw new IllegalArgumentException(
                "Fill quantity " + qty + " exceeds remaining " + remainingQuantity);
        }
        remainingQuantity -= qty;
        filledQuantity += qty;
        if (remainingQuantity == 0) {
            status = OrderStatus.FILLED;
        } else {
            status = OrderStatus.PARTIALLY_FILLED;
        }
    }

    public boolean isFilled() {
        return remainingQuantity == 0;
    }

    public boolean isActive() {
        return status == OrderStatus.NEW || status == OrderStatus.PARTIALLY_FILLED;
    }

    public OrderId getId() {
        return id;
    }

    public String getSymbol() {
        return symbol;
    }

    public Side getSide() {
        return side;
    }

    public OrderType getType() {
        return type;
    }

    public Price getLimitPrice() {
        return limitPrice;
    }

    public long getOriginalQuantity() {
        return originalQuantity;
    }

    public long getRemainingQuantity() {
        return remainingQuantity;
    }

    public long getFilledQuantity() {
        return filledQuantity;
    }

    public long getTimestamp() {
        return timestamp;
    }

    public OrderStatus getStatus() {
        return status;
    }

    public void setStatus(OrderStatus status) {
        this.status = status;
    }
}
