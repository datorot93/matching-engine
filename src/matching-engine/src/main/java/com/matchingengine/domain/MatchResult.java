package com.matchingengine.domain;

/**
 * Represents a single fill (trade) between a taker (incoming) order
 * and a maker (resting) order.
 */
public class MatchResult {

    private final String matchId;
    private final String takerOrderId;
    private final String makerOrderId;
    private final String symbol;
    private final long executionPrice;     // cents
    private final long executionQuantity;
    private final long timestamp;          // epoch millis
    private final Side takerSide;

    public MatchResult(String matchId, String takerOrderId, String makerOrderId,
                       String symbol, long executionPrice, long executionQuantity,
                       long timestamp, Side takerSide) {
        this.matchId = matchId;
        this.takerOrderId = takerOrderId;
        this.makerOrderId = makerOrderId;
        this.symbol = symbol;
        this.executionPrice = executionPrice;
        this.executionQuantity = executionQuantity;
        this.timestamp = timestamp;
        this.takerSide = takerSide;
    }

    public String getMatchId() {
        return matchId;
    }

    public String getTakerOrderId() {
        return takerOrderId;
    }

    public String getMakerOrderId() {
        return makerOrderId;
    }

    public String getSymbol() {
        return symbol;
    }

    public long getExecutionPrice() {
        return executionPrice;
    }

    public long getExecutionQuantity() {
        return executionQuantity;
    }

    public long getTimestamp() {
        return timestamp;
    }

    public Side getTakerSide() {
        return takerSide;
    }
}
