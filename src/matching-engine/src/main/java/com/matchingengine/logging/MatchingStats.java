package com.matchingengine.logging;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Lock-free counters shared between the matching thread (writer) and the
 * periodic stats logger thread (reader). Uses AtomicLong for thread-safe
 * access without blocking the matching thread.
 */
public class MatchingStats {

    public final AtomicLong buyOrdersReceived = new AtomicLong();
    public final AtomicLong sellOrdersReceived = new AtomicLong();
    public final AtomicLong matchesExecuted = new AtomicLong();
    public final AtomicLong ordersRejected = new AtomicLong();
}
