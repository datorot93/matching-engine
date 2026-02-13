package com.matchingengine.config;

import java.util.Arrays;
import java.util.List;

/**
 * Configuration parsed from environment variables.
 * Each Matching Engine shard has its own identity and symbol assignments.
 */
public class ShardConfig {

    private final String shardId;
    private final List<String> symbols;
    private final int httpPort;
    private final int metricsPort;
    private final String kafkaBootstrap;
    private final String walPath;
    private final int walSizeMb;
    private final int ringBufferSize;

    private ShardConfig(String shardId, List<String> symbols, int httpPort,
                        int metricsPort, String kafkaBootstrap, String walPath,
                        int walSizeMb, int ringBufferSize) {
        this.shardId = shardId;
        this.symbols = symbols;
        this.httpPort = httpPort;
        this.metricsPort = metricsPort;
        this.kafkaBootstrap = kafkaBootstrap;
        this.walPath = walPath;
        this.walSizeMb = walSizeMb;
        this.ringBufferSize = ringBufferSize;
    }

    /**
     * Parse configuration from environment variables with sensible defaults.
     */
    public static ShardConfig fromEnv() {
        String shardId = getEnv("SHARD_ID", "a");
        String symbolsCsv = getEnv("SHARD_SYMBOLS",
                "TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D");
        List<String> symbols = Arrays.asList(symbolsCsv.split(","));
        int httpPort = getEnvInt("HTTP_PORT", 8080);
        int metricsPort = getEnvInt("METRICS_PORT", 9091);
        String kafkaBootstrap = getEnv("KAFKA_BOOTSTRAP", "localhost:9092");
        String walPath = getEnv("WAL_PATH", "/tmp/wal");
        int walSizeMb = getEnvInt("WAL_SIZE_MB", 64);
        int ringBufferSize = getEnvInt("RING_BUFFER_SIZE", 131072);

        return new ShardConfig(shardId, symbols, httpPort, metricsPort,
                kafkaBootstrap, walPath, walSizeMb, ringBufferSize);
    }

    private static String getEnv(String key, String defaultValue) {
        String value = System.getenv(key);
        return (value != null && !value.isEmpty()) ? value : defaultValue;
    }

    private static int getEnvInt(String key, int defaultValue) {
        String value = System.getenv(key);
        if (value != null && !value.isEmpty()) {
            try {
                return Integer.parseInt(value);
            } catch (NumberFormatException e) {
                return defaultValue;
            }
        }
        return defaultValue;
    }

    public String getShardId() {
        return shardId;
    }

    public List<String> getSymbols() {
        return symbols;
    }

    public int getHttpPort() {
        return httpPort;
    }

    public int getMetricsPort() {
        return metricsPort;
    }

    public String getKafkaBootstrap() {
        return kafkaBootstrap;
    }

    public String getWalPath() {
        return walPath;
    }

    public int getWalSizeMb() {
        return walSizeMb;
    }

    public int getRingBufferSize() {
        return ringBufferSize;
    }

    @Override
    public String toString() {
        return "ShardConfig{" +
                "shardId='" + shardId + '\'' +
                ", symbols=" + symbols +
                ", httpPort=" + httpPort +
                ", metricsPort=" + metricsPort +
                ", kafkaBootstrap='" + kafkaBootstrap + '\'' +
                ", walPath='" + walPath + '\'' +
                ", walSizeMb=" + walSizeMb +
                ", ringBufferSize=" + ringBufferSize +
                '}';
    }
}
