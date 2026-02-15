// =============================================================================
// Test: Stochastic Aggressive Load (adapted from BLOQUE 2 -- dual-config)
//
// Purpose:  Stress-test the ME at ultra-high throughput with stochastic order
//           arrival.  ~1,300 orders per SECOND for 10 seconds (~13,000 total).
//
// Stochastic techniques preserved from the original dual-config script:
//   - Poisson process for inter-arrival times (sleepPoisson)
//   - Gaussian Random Walk for price generation (Box-Muller transform)
//   - Controlled BUY/SELL distribution: 38.46% BUY / 61.54% SELL
//
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: ramping-vus  13 VUs x lambda 100 = ~1,300 orders/sec
// Seed:     Heavy seeding on both sides to sustain high match rate under blast.
//
// Pass criteria:
//   - p99 http_req_duration  < 200ms
//   - p99 matching_latency   < 200ms
//   - p95 matching_latency   < 150ms
//   - p50 matching_latency   < 100ms
//   - Error rate             < 1%
//   - Order success rate     > 99%
//
// Calculation:
//   Target: 1,300 orders/sec
//   13 VUs x lambda 100 = 1,300 orders/sec
//   Duration 10s -> expected ~13,000 orders total
//   BUY:  ~5,000 (38.46%)
//   SELL: ~8,000 (61.54%)
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

import {
    ME_SHARD_A_URL,
    SHARD_A_SYMBOLS,
    BASE_PRICE,
    JSON_HEADERS,
} from './lib/config.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { randomShardASymbol } from './lib/orderGenerator.js';
import {
    updateMarketPrice,
    sleepPoisson,
    generateStochasticOrder,
} from './lib/stochasticHelper.js';

// =============================================================================
// Custom metrics
// =============================================================================
const matchingLatency = new Trend('matching_latency', true);
const orderSuccessRate = new Rate('order_success_rate');
const buyOrderRate = new Rate('buy_order_rate');
const sellOrderRate = new Rate('sell_order_rate');

// =============================================================================
// Lambda: 100 orders/sec per VU  (13 VUs x 100 = 1,300 orders/sec)
// =============================================================================
const LAMBDA = 300;

// =============================================================================
// k6 options
// =============================================================================
export const options = {
    stages: [
        // Quick warm-up: ramp to 13 VUs in 2 seconds
        { duration: '5s', target: 50 },

        // AGGRESSIVE BLAST: 10 seconds at full rate
        { duration: '15s', target: 150 },

        // Immediate shutdown
        { duration: '5s', target: 0 },
    ],

    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'http_req_failed':   ['rate<0.01'],
        'matching_latency':  ['p(99)<200', 'p(95)<150', 'p(50)<100'],
        'order_success_rate': ['rate>0.99'],
    },

    batch: 1,
    batchPerHost: 1,
};

// =============================================================================
// Per-VU market state
// =============================================================================
let marketPrices = {};

// =============================================================================
// Setup: heavy seeding for high-throughput blast
// =============================================================================
export function setup() {
    console.log('=== Test: Stochastic Aggressive Load (BLOQUE 2 adaptation) ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Rate: ~1,300 orders/SECOND for 10 seconds');
    console.log('Distribution: 38.46% BUY / 61.54% SELL (stochastic)');
    console.log('Expected total: ~13,000 orders');
    console.log('');

    // Heavy SELL seed: 2,000 per symbol across 100 price levels.
    // With ~5,000 aggressive BUY orders expected, we need deep sell liquidity.
    console.log('Seeding SELL orders: 2,000 per symbol across 100 price levels...');
    seedShardDirect(SHARD_A_SYMBOLS, 2000, 100, ME_SHARD_A_URL);

    // Heavy BUY seed: resting BUY orders below BASE_PRICE so aggressive SELLs match.
    console.log('Seeding resting BUY orders for SELL-side matching...');
    let buySeeded = 0;
    for (const symbol of SHARD_A_SYMBOLS) {
        const orders = [];
        for (let level = 1; level <= 100; level++) {
            for (let i = 0; i < 20; i++) {
                orders.push({
                    orderId:  `seed-buy-${symbol}-${level}-${i}`,
                    symbol:   symbol,
                    side:     'BUY',
                    type:     'LIMIT',
                    price:    BASE_PRICE - level,   // resting below BASE_PRICE
                    quantity: 10 + Math.floor(Math.random() * 190),
                });
            }
        }
        const payload = JSON.stringify({ orders: orders });
        const res = http.post(`${ME_SHARD_A_URL}/seed`, payload, {
            headers: JSON_HEADERS,
            timeout: '60s',
        });
        const ok = check(res, {
            [`seed BUY ${symbol} status 200`]: (r) => r.status === 200,
        });
        if (!ok) {
            console.error(`SEED BUY FAILED for ${symbol}: status=${res.status}, body=${res.body}`);
        }
        buySeeded += orders.length;
    }
    console.log(`Seeded ${buySeeded} resting BUY orders across ${SHARD_A_SYMBOLS.length} symbols.`);

    // Return initial market prices
    const initialPrices = {};
    SHARD_A_SYMBOLS.forEach((sym) => {
        initialPrices[sym] = BASE_PRICE;
    });

    console.log('Seed complete. Starting aggressive stochastic blast...');
    console.log('');

    return { initialPrices };
}

// =============================================================================
// Main VU function
// =============================================================================
export default function (data) {
    // Initialize per-VU market state on first iteration
    if (__ITER === 0) {
        marketPrices = { ...data.initialPrices };
    }

    // Step 1: Pick random symbol from Shard A
    const symbol = randomShardASymbol();

    // Step 2: Advance market price via Gaussian Random Walk
    const marketPrice = updateMarketPrice(symbol, marketPrices);

    // Step 3: Generate stochastic order (38.46% BUY / 61.54% SELL)
    const order = generateStochasticOrder(symbol, marketPrice);

    // Step 4: Send to ME
    const payload = JSON.stringify(order);
    const params = {
        headers: JSON_HEADERS,
        tags: {
            symbol: order.symbol,
            side: order.side,
        },
    };

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, params);

    // Step 5: Record metrics
    matchingLatency.add(res.timings.duration);

    if (order.side === 'BUY') {
        buyOrderRate.add(1);
        sellOrderRate.add(0);
    } else {
        buyOrderRate.add(0);
        sellOrderRate.add(1);
    }

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
        'latency < 200ms': () => res.timings.duration < 200,
    });

    orderSuccessRate.add(success ? 1 : 0);

    // Log occasional failures for debugging
    if (!success && __ITER % 500 === 0) {
        console.error(
            `Order failed: ${order.symbol} ${order.side} @ ${order.price} - ` +
            `Status: ${res.status}, Body: ${res.body}`
        );
    }

    // Step 6: Poisson inter-arrival sleep (high-frequency bounds: 1ms-50ms)
    sleepPoisson(LAMBDA);
}

// =============================================================================
// Teardown
// =============================================================================
export function teardown() {
    console.log('');
    console.log('=== Stochastic Aggressive Load test complete ===');
    console.log('Review custom metrics:');
    console.log('  - matching_latency (p99, p95, p50)');
    console.log('  - order_success_rate');
    console.log('  - buy_order_rate  (expected ~38.46%)');
    console.log('  - sell_order_rate (expected ~61.54%)');
    console.log('  - http_reqs (total orders sent)');
    console.log('');
}
