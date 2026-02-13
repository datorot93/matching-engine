package com.matchingengine.domain;

/**
 * Value object representing a price in cents.
 * Example: 15000 cents = $150.00.
 */
public record Price(long cents) implements Comparable<Price> {

    @Override
    public int compareTo(Price other) {
        return Long.compare(this.cents, other.cents);
    }
}
