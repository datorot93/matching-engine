package com.matchingengine.matching;

import com.matchingengine.domain.MatchResultSet;
import com.matchingengine.domain.Order;
import com.matchingengine.domain.OrderBook;

/**
 * Interface for order matching algorithms.
 * The matching algorithm takes an order book and an incoming order,
 * and returns the set of fills produced.
 */
public interface MatchingAlgorithm {
    MatchResultSet match(OrderBook book, Order incomingOrder);
}
