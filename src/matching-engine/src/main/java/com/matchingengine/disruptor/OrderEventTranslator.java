package com.matchingengine.disruptor;

import com.matchingengine.domain.OrderType;
import com.matchingengine.domain.Side;

/**
 * Translates HTTP request data into a pre-allocated OrderEvent slot.
 * Zero heap allocation: all data is copied into existing fields.
 *
 * This class holds the data extracted from the HTTP request body
 * that will be translated into the ring buffer event.
 */
public class OrderEventTranslator {

    /**
     * Copy fields from the HTTP request data into the pre-allocated OrderEvent slot.
     * This is called by the Disruptor when a slot is claimed by a producer.
     */
    public static void translate(OrderEvent event, long sequence,
                                 String orderId, String symbol, Side side,
                                 OrderType orderType, long price, long quantity,
                                 long timestamp, long receivedNanos) {
        event.receivedNanos = receivedNanos;
        event.orderId = orderId;
        event.symbol = symbol;
        event.side = side;
        event.orderType = orderType;
        event.price = price;
        event.quantity = quantity;
        event.timestamp = timestamp;
    }
}
