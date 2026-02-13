package com.matchingengine.domain;

import java.util.ArrayDeque;

/**
 * FIFO queue of orders at a single price point.
 * Orders are matched in time priority (first-in, first-out).
 */
public class PriceLevel {

    private final Price price;
    private final ArrayDeque<Order> orders;
    private long totalQuantity;

    public PriceLevel(Price price) {
        this.price = price;
        this.orders = new ArrayDeque<>();
        this.totalQuantity = 0;
    }

    public void addOrder(Order order) {
        orders.addLast(order);
        totalQuantity += order.getRemainingQuantity();
    }

    public Order peekFirst() {
        return orders.peekFirst();
    }

    public Order pollFirst() {
        Order order = orders.pollFirst();
        if (order != null) {
            totalQuantity -= order.getRemainingQuantity();
        }
        return order;
    }

    /**
     * Remove a specific order by reference. Used for cancel operations.
     * O(n) scan -- acceptable for this experiment since cancels are not implemented.
     */
    public void removeOrder(Order order) {
        if (orders.remove(order)) {
            totalQuantity -= order.getRemainingQuantity();
        }
    }

    public boolean isEmpty() {
        return orders.isEmpty();
    }

    public long getTotalQuantity() {
        return totalQuantity;
    }

    public int getOrderCount() {
        return orders.size();
    }

    public Price getPrice() {
        return price;
    }

    /**
     * Recalculate total quantity from all orders. Called after fills
     * modify individual order quantities without going through addOrder/pollFirst.
     */
    public void recalculateTotalQuantity() {
        totalQuantity = 0;
        for (Order order : orders) {
            totalQuantity += order.getRemainingQuantity();
        }
    }
}
