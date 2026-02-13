package com.matchingengine.domain;

/**
 * Value object wrapping a String order identifier.
 * The k6 load generator produces string IDs like "k6-buy-00001".
 */
public record OrderId(String value) {}
