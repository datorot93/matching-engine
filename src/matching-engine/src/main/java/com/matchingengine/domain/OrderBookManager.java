package com.matchingengine.domain;

import java.util.Collection;
import java.util.HashMap;

/**
 * Manages order books for multiple symbols.
 * Maps symbol name to OrderBook instance.
 */
public class OrderBookManager {

    private final HashMap<String, OrderBook> books;

    public OrderBookManager() {
        this.books = new HashMap<>();
    }

    /**
     * Get or create an OrderBook for the given symbol.
     * Thread-safe note: this is only called from the single Disruptor consumer
     * thread or from the seed endpoint (which runs before load testing).
     */
    public OrderBook getOrCreateBook(String symbol) {
        return books.computeIfAbsent(symbol, OrderBook::new);
    }

    /**
     * Get an existing OrderBook. Returns null if not found.
     */
    public OrderBook getBook(String symbol) {
        return books.get(symbol);
    }

    public Collection<OrderBook> getAllBooks() {
        return books.values();
    }
}
