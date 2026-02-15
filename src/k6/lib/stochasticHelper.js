// =============================================================================
// Stochastic helpers for k6 load tests
//
// Provides realistic order arrival and pricing models adapted from the original
// dual-config stochastic load test.  All functions are pure or side-effect-free
// except updateMarketPrice() which mutates the caller-provided price map.
//
// Techniques:
//   - Box-Muller transform   -- Gaussian noise for price random walks
//   - Gaussian Random Walk    -- realistic price movement with bounded drift
//   - Poisson inter-arrival   -- exponentially distributed sleep between orders
//   - Stochastic order gen    -- both BUY and SELL with controlled distribution
// =============================================================================

import { sleep } from 'k6';
import { generateOrderId } from './orderGenerator.js';
import {
    BASE_PRICE,
    TICK_SIZE,
    PRICE_SPREAD,
    MIN_QUANTITY,
    MAX_QUANTITY,
} from './config.js';

// ============================================================================
// BUY / SELL distribution constants
// Matches the original dual-config specification:
//   500 BUY / 800 SELL = 38.46% BUY / 61.54% SELL
// ============================================================================
export const BUY_PROBABILITY = 0.3846;

// ============================================================================
// Asset volatility and price constraints
// ============================================================================
const DEFAULT_VOLATILITY = 0.0005;   // 0.05% per step
const PRICE_BAND_FACTOR  = 0.10;     // +/- 10% from BASE_PRICE

// ============================================================================
// Box-Muller Transform
// ============================================================================
/**
 * Generate a random number from a standard normal distribution (mean=0, std=1)
 * using the Box-Muller transform.
 *
 * @returns {number} Gaussian random number
 */
export function boxMullerRandom() {
    const u1 = Math.random();
    const u2 = Math.random();
    return Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2);
}

// ============================================================================
// Gaussian Random Walk for price generation
// ============================================================================
/**
 * Update the market price for a given symbol using a Gaussian Random Walk.
 *
 * Formula:
 *   newPrice = currentPrice + currentPrice * volatility * gaussianNoise
 *
 * The result is rounded to the nearest TICK_SIZE and clamped within +/- 10%
 * of BASE_PRICE to prevent the random walk from drifting too far.
 *
 * @param {string} symbol         - Asset symbol (e.g. TEST-ASSET-A)
 * @param {Object} currentPrices  - Mutable map of symbol -> current price (cents)
 * @param {number} [volatility]   - Per-step volatility (default 0.0005)
 * @returns {number} The updated price in cents
 */
export function updateMarketPrice(symbol, currentPrices, volatility) {
    const vol = volatility || DEFAULT_VOLATILITY;
    const currentPrice = currentPrices[symbol] || BASE_PRICE;

    const noise       = boxMullerRandom();
    const priceChange = currentPrice * vol * noise;
    let newPrice      = currentPrice + priceChange;

    // Round to nearest tick
    newPrice = Math.round(newPrice / TICK_SIZE) * TICK_SIZE;

    // Clamp within +/- 10% of BASE_PRICE
    const minPrice = Math.round(BASE_PRICE * (1 - PRICE_BAND_FACTOR));
    const maxPrice = Math.round(BASE_PRICE * (1 + PRICE_BAND_FACTOR));
    newPrice = Math.max(minPrice, Math.min(maxPrice, newPrice));

    // Persist updated price
    currentPrices[symbol] = newPrice;

    return newPrice;
}

// ============================================================================
// Poisson-process inter-arrival sleep
// ============================================================================
/**
 * Sleep for an exponentially-distributed duration modelling a Poisson process.
 *
 * The sleep time is -ln(U) / lambda, where U ~ Uniform(0,1).
 * Bounds are applied to keep k6 from sleeping too long (stalling VUs) or
 * too short (busy-looping without k6 yielding).
 *
 * @param {number} lambda - Average order rate per second **per VU**
 */
export function sleepPoisson(lambda) {
    const u         = Math.random();
    const sleepTime = -Math.log(u) / lambda;

    let minSleep, maxSleep;

    if (lambda >= 50) {
        // High-frequency mode (aggressive test)
        minSleep = 0.001;   // 1 ms
        maxSleep = 0.05;    // 50 ms
    } else {
        // Distributed mode (normal test)
        minSleep = 0.01;    // 10 ms
        maxSleep = 1.0;     // 1 s
    }

    sleep(Math.max(minSleep, Math.min(maxSleep, sleepTime)));
}

// ============================================================================
// Stochastic order generation
// ============================================================================
/**
 * Generate an order in the ME's expected JSON format using the stochastic
 * price model.  The order is priced aggressively -- BUY orders bid above the
 * current market price and SELL orders offer below it -- so that both sides
 * have a realistic probability of matching against resting counterparties.
 *
 * Spread-crossing factor: 3.5% of market price, which is large enough to
 * ensure high match probability against resting seed orders that sit near
 * BASE_PRICE.
 *
 * @param {string}  symbol      - Asset symbol (e.g. TEST-ASSET-A)
 * @param {number}  marketPrice - Current market price from the random walk (cents)
 * @param {string}  [side]      - Explicit side; if omitted, chosen stochastically
 *                                (38.46% BUY / 61.54% SELL)
 * @returns {Object} Order payload matching the ME /orders contract
 */
export function generateStochasticOrder(symbol, marketPrice, side) {
    const orderSide = side || (Math.random() < BUY_PROBABILITY ? 'BUY' : 'SELL');

    const spreadCrossing = 0.035;   // 3.5%

    let orderPrice;
    if (orderSide === 'BUY') {
        // Bid above market to cross spread and hit resting SELLs
        orderPrice = marketPrice * (1 + spreadCrossing);
    } else {
        // Offer below market to cross spread and hit resting BUYs
        orderPrice = marketPrice * (1 - spreadCrossing);
    }

    // Round to nearest tick and ensure positive
    orderPrice = Math.max(TICK_SIZE, Math.round(orderPrice / TICK_SIZE) * TICK_SIZE);

    // Random quantity within configured range
    const quantity = MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY));

    return {
        orderId:  generateOrderId(`stoch-${orderSide.toLowerCase()}`),
        symbol:   symbol,
        side:     orderSide,
        type:     'LIMIT',
        price:    orderPrice,
        quantity: quantity,
    };
}
