package com.matchingengine.gateway.routing;

/**
 * Routes symbols to their assigned ME shard.
 *
 * <p>Implementations map a symbol string (e.g. "TEST-ASSET-A") to the
 * shard ID and base URL of the Matching Engine instance responsible
 * for that symbol's order book.
 */
public interface SymbolRouter {

    /**
     * Returns the base URL of the target ME shard for the given symbol.
     *
     * @param symbol the trading symbol (e.g. "TEST-ASSET-A")
     * @return the base URL (e.g. "http://me-shard-a:8080")
     * @throws IllegalArgumentException if the symbol is not mapped to any shard
     */
    String getShardUrl(String symbol);

    /**
     * Returns the shard ID for the given symbol.
     *
     * @param symbol the trading symbol (e.g. "TEST-ASSET-A")
     * @return the shard ID (e.g. "a")
     * @throws IllegalArgumentException if the symbol is not mapped to any shard
     */
    String getShardId(String symbol);
}
