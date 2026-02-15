// =============================================================================
// Synthetic order generation for k6 load tests
// Spec 3, Section 4.2
//
// Order mix:
//   - 60% aggressive BUY orders  (price >= BASE_PRICE, cross spread, match)
//   - 40% passive BUY orders     (price << BASE_PRICE, rest in book)
//
// Seed SELL orders sit at BASE_PRICE + level * TICK_SIZE so that aggressive
// BUY orders always find a counterparty.
// =============================================================================

import {
    SHARD_A_SYMBOLS,
    ALL_SYMBOLS,
    BASE_PRICE,
    PRICE_SPREAD,
    TICK_SIZE,
    MIN_QUANTITY,
    MAX_QUANTITY,
} from './config.js';

// Per-VU counter for unique order IDs
let orderCounter = 0;

/**
 * Generate a unique order ID scoped to the current VU.
 * Format: {prefix}-{vuId}-{counter}
 */
export function generateOrderId(prefix) {
    orderCounter++;
    return `${prefix}-${__VU}-${orderCounter}`;
}

/**
 * Generate an aggressive BUY order that crosses the spread and matches
 * against resting SELL orders.
 *
 * Price range: [BASE_PRICE, BASE_PRICE + PRICE_SPREAD/2)
 * These prices are at or above BASE_PRICE, which is where seed SELL orders
 * start (BASE_PRICE + 1*TICK_SIZE and up), so they will match.
 */
export function generateAggressiveBuyOrder(symbol) {
    const priceOffset = Math.floor(Math.random() * (PRICE_SPREAD / 2));
    const price    = BASE_PRICE + priceOffset;
    const quantity = MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY));

    return {
        orderId:  generateOrderId('buy'),
        symbol:   symbol,
        side:     'BUY',
        type:     'LIMIT',
        price:    price,
        quantity: quantity,
    };
}

/**
 * Generate a passive BUY order that rests in the book (well below best ask).
 *
 * Price range: [BASE_PRICE - PRICE_SPREAD - PRICE_SPREAD/2, BASE_PRICE - PRICE_SPREAD)
 * These prices are too low to match any resting SELL orders.
 */
export function generatePassiveBuyOrder(symbol) {
    const priceOffset = Math.floor(Math.random() * (PRICE_SPREAD / 2));
    const price    = BASE_PRICE - PRICE_SPREAD - priceOffset;
    const quantity = MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY));

    return {
        orderId:  generateOrderId('buy-passive'),
        symbol:   symbol,
        side:     'BUY',
        type:     'LIMIT',
        price:    price,
        quantity: quantity,
    };
}

/**
 * Generate a SELL order for seeding the order book.
 *
 * Price = BASE_PRICE + priceLevel * TICK_SIZE
 * Spread across multiple price levels starting just above BASE_PRICE.
 *
 * @param {string} symbol      - Asset symbol (e.g., TEST-ASSET-A)
 * @param {number} priceLevel  - Price level index (1-based)
 * @param {number} idx         - Order index within this level
 */
export function generateSeedSellOrder(symbol, priceLevel, idx) {
    return {
        orderId:  `seed-sell-${symbol}-${priceLevel}-${idx}`,
        symbol:   symbol,
        side:     'SELL',
        type:     'LIMIT',
        price:    BASE_PRICE + priceLevel * TICK_SIZE,
        quantity: MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY)),
    };
}

/**
 * Generate a mixed order with the 60/40 aggressive/passive split.
 *
 * 60% of calls produce aggressive BUY orders that match immediately.
 * 40% of calls produce passive BUY orders that rest in the book.
 * This creates a realistic mixed workload per experiment-design.md.
 */
export function generateMixedOrder(symbol) {
    if (Math.random() < 0.6) {
        return generateAggressiveBuyOrder(symbol);
    } else {
        return generatePassiveBuyOrder(symbol);
    }
}

/**
 * Pick a random symbol from the given list.
 * Default: all 12 symbols across 3 shards.
 */
export function randomSymbol(symbols) {
    const list = symbols || ALL_SYMBOLS;
    return list[Math.floor(Math.random() * list.length)];
}

/**
 * Pick a random symbol from Shard A (TEST-ASSET-A through TEST-ASSET-D).
 */
export function randomShardASymbol() {
    return randomSymbol(SHARD_A_SYMBOLS);
}
