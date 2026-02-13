package com.matchingengine.gateway.routing;

import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Explicit symbol-to-shard router using a pre-configured mapping.
 *
 * <p>Despite the name (kept for architectural consistency with the full
 * Order Gateway design), this implementation uses a direct lookup table
 * rather than a hash function. For the experiment, the symbol-to-shard
 * mapping is fully deterministic and configured via environment variables.
 *
 * <p>The mapping is built at construction time from two configuration maps:
 * <ul>
 *   <li>{@code shardSymbols}: shard ID to list of symbols (e.g. "a" -> ["TEST-ASSET-A", "TEST-ASSET-B"])</li>
 *   <li>{@code shardMap}: shard ID to base URL (e.g. "a" -> "http://me-shard-a:8080")</li>
 * </ul>
 */
public class ConsistentHashRouter implements SymbolRouter {

    private final Map<String, String> symbolToShardId;
    private final Map<String, String> shardIdToUrl;

    /**
     * Constructs the router from shard configuration.
     *
     * @param shardSymbols mapping of shard ID to list of symbols assigned to that shard
     * @param shardMap     mapping of shard ID to base URL
     */
    public ConsistentHashRouter(Map<String, List<String>> shardSymbols, Map<String, String> shardMap) {
        Map<String, String> symbolMap = new HashMap<>();
        for (Map.Entry<String, List<String>> entry : shardSymbols.entrySet()) {
            String shardId = entry.getKey();
            for (String symbol : entry.getValue()) {
                symbolMap.put(symbol, shardId);
            }
        }
        this.symbolToShardId = Collections.unmodifiableMap(symbolMap);
        this.shardIdToUrl = Collections.unmodifiableMap(new HashMap<>(shardMap));
    }

    @Override
    public String getShardUrl(String symbol) {
        String shardId = symbolToShardId.get(symbol);
        if (shardId == null) {
            throw new IllegalArgumentException("Unknown symbol: " + symbol);
        }
        String url = shardIdToUrl.get(shardId);
        if (url == null) {
            throw new IllegalArgumentException(
                    "Symbol " + symbol + " maps to shard " + shardId + " but no URL configured for that shard");
        }
        return url;
    }

    @Override
    public String getShardId(String symbol) {
        String shardId = symbolToShardId.get(symbol);
        if (shardId == null) {
            throw new IllegalArgumentException("Unknown symbol: " + symbol);
        }
        return shardId;
    }

    /**
     * Returns the symbol-to-shard mapping for logging and diagnostics.
     */
    public Map<String, String> getSymbolToShardId() {
        return symbolToShardId;
    }

    /**
     * Returns the shard-to-URL mapping for logging and diagnostics.
     */
    public Map<String, String> getShardIdToUrl() {
        return shardIdToUrl;
    }
}
