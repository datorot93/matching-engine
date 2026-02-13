package com.matchingengine.disruptor;

import com.lmax.disruptor.EventFactory;

/**
 * Factory for pre-allocating OrderEvent instances in the ring buffer.
 * Called once per slot at Disruptor startup to fill the entire ring buffer.
 */
public class OrderEventFactory implements EventFactory<OrderEvent> {

    @Override
    public OrderEvent newInstance() {
        return new OrderEvent();
    }
}
