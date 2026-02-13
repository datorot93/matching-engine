package com.matchingengine.domain;

import java.util.List;

/**
 * Collection of fills for one incoming order.
 * Contains the list of individual match results and summary statistics.
 */
public class MatchResultSet {

    private final List<MatchResult> results;
    private final long totalFilledQuantity;
    private final boolean incomingFullyFilled;

    public MatchResultSet(List<MatchResult> results, long totalFilledQuantity,
                          boolean incomingFullyFilled) {
        this.results = results;
        this.totalFilledQuantity = totalFilledQuantity;
        this.incomingFullyFilled = incomingFullyFilled;
    }

    public List<MatchResult> getResults() {
        return results;
    }

    public long getTotalFilledQuantity() {
        return totalFilledQuantity;
    }

    public boolean isIncomingFullyFilled() {
        return incomingFullyFilled;
    }

    public int getMatchCount() {
        return results.size();
    }

    public boolean hasMatches() {
        return !results.isEmpty();
    }
}
