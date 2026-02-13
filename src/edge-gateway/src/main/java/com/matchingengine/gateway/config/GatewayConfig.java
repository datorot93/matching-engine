package com.matchingengine.gateway.config;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Configuration for the Edge Gateway, parsed from environment variables.
 *
 * <p>Environment variables:
 * <ul>
 *   <li>{@code HTTP_PORT} - Gateway listening port (default 8080)</li>
 *   <li>{@code METRICS_PORT} - Prometheus metrics port (default 9091)</li>
 *   <li>{@code ME_SHARD_MAP} - Shard ID to ME URL mapping.
 *       Format: {@code a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080}</li>
 *   <li>{@code SHARD_SYMBOLS_MAP} - Shard ID to symbols mapping.
 *       Format: {@code a=TEST-ASSET-A:TEST-ASSET-B,b=TEST-ASSET-C:TEST-ASSET-D}</li>
 * </ul>
 */
public class GatewayConfig {

    private static final String DEFAULT_ME_SHARD_MAP =
            "a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080";

    private static final String DEFAULT_SHARD_SYMBOLS_MAP =
            "a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D," +
            "b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H," +
            "c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L";

    private final int httpPort;
    private final int metricsPort;
    private final Map<String, String> shardMap;
    private final Map<String, List<String>> shardSymbols;

    public GatewayConfig(int httpPort, int metricsPort,
                         Map<String, String> shardMap,
                         Map<String, List<String>> shardSymbols) {
        this.httpPort = httpPort;
        this.metricsPort = metricsPort;
        this.shardMap = Collections.unmodifiableMap(new HashMap<>(shardMap));
        this.shardSymbols = Collections.unmodifiableMap(new HashMap<>(shardSymbols));
    }

    /**
     * Parse configuration from environment variables.
     */
    public static GatewayConfig fromEnv() {
        int httpPort = getEnvInt("HTTP_PORT", 8080);
        int metricsPort = getEnvInt("METRICS_PORT", 9091);

        String shardMapRaw = getEnvString("ME_SHARD_MAP", DEFAULT_ME_SHARD_MAP);
        Map<String, String> shardMap = parseShardMap(shardMapRaw);

        String symbolsMapRaw = getEnvString("SHARD_SYMBOLS_MAP", DEFAULT_SHARD_SYMBOLS_MAP);
        Map<String, List<String>> shardSymbols = parseShardSymbols(symbolsMapRaw);

        return new GatewayConfig(httpPort, metricsPort, shardMap, shardSymbols);
    }

    /**
     * Parse shard map from format: {@code a=http://host:8080,b=http://host:8081}
     */
    private static Map<String, String> parseShardMap(String raw) {
        Map<String, String> map = new HashMap<>();
        String[] entries = raw.split(",");
        for (String entry : entries) {
            String trimmed = entry.trim();
            if (trimmed.isEmpty()) continue;
            int eqIdx = trimmed.indexOf('=');
            if (eqIdx <= 0) {
                throw new IllegalArgumentException("Invalid ME_SHARD_MAP entry: " + trimmed);
            }
            String shardId = trimmed.substring(0, eqIdx).trim();
            String url = trimmed.substring(eqIdx + 1).trim();
            map.put(shardId, url);
        }
        return map;
    }

    /**
     * Parse shard symbols from format: {@code a=SYM1:SYM2,b=SYM3:SYM4}
     */
    private static Map<String, List<String>> parseShardSymbols(String raw) {
        Map<String, List<String>> map = new HashMap<>();
        String[] entries = raw.split(",");
        for (String entry : entries) {
            String trimmed = entry.trim();
            if (trimmed.isEmpty()) continue;
            int eqIdx = trimmed.indexOf('=');
            if (eqIdx <= 0) {
                throw new IllegalArgumentException("Invalid SHARD_SYMBOLS_MAP entry: " + trimmed);
            }
            String shardId = trimmed.substring(0, eqIdx).trim();
            String symbolsStr = trimmed.substring(eqIdx + 1).trim();
            String[] symbols = symbolsStr.split(":");
            List<String> symbolList = new ArrayList<>();
            for (String symbol : symbols) {
                String sym = symbol.trim();
                if (!sym.isEmpty()) {
                    symbolList.add(sym);
                }
            }
            map.put(shardId, Collections.unmodifiableList(symbolList));
        }
        return map;
    }

    private static int getEnvInt(String name, int defaultValue) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) {
            return defaultValue;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(
                    "Invalid integer for environment variable " + name + ": " + value, e);
        }
    }

    private static String getEnvString(String name, String defaultValue) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) {
            return defaultValue;
        }
        return value;
    }

    public int getHttpPort() {
        return httpPort;
    }

    public int getMetricsPort() {
        return metricsPort;
    }

    public Map<String, String> getShardMap() {
        return shardMap;
    }

    public Map<String, List<String>> getShardSymbols() {
        return shardSymbols;
    }

    @Override
    public String toString() {
        return "GatewayConfig{" +
                "httpPort=" + httpPort +
                ", metricsPort=" + metricsPort +
                ", shardMap=" + shardMap +
                ", shardSymbols=" + shardSymbols +
                '}';
    }
}
