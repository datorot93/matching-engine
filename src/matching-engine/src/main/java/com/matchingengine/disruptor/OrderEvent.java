package com.matchingengine.disruptor;

import com.matchingengine.domain.OrderType;
import com.matchingengine.domain.Side;

/**
 * Pre-allocated mutable event object in the Disruptor ring buffer.
 *
 * Fields are public for zero-overhead access on the critical path.
 * The clear() method resets all fields to defaults after processing,
 * preventing stale data in the ring buffer slot.
 */
public class OrderEvent {

    public long receivedNanos;     // System.nanoTime() when HTTP request was received
    public String orderId;
    public String symbol;
    public Side side;
    public OrderType orderType;
    public long price;             // cents
    public long quantity;
    public long timestamp;         // epoch millis

    /**
     * Reset all fields to defaults. Called after the event has been processed
     * to prevent stale data from persisting in the ring buffer slot.
     */
    public void clear() {
        receivedNanos = 0;
        orderId = null;
        symbol = null;
        side = null;
        orderType = null;
        price = 0;
        quantity = 0;
        timestamp = 0;
    }
}
