// =============================================================================
// Test: Stochastic Normal Load -- SHORT (2 minutes)
//
// Purpose:  Validate ME latency under a realistic stochastic workload at
//           normal throughput (~1,300 orders/min for 2 minutes).
//           Designed to be called repeatedly by the mixed orchestrator.
//
// Stochastic techniques:
//   - Poisson process for inter-arrival times (sleepPoisson)
//   - Gaussian Random Walk for price generation (Box-Muller transform)
//   - Controlled BUY/SELL distribution: 38.46% BUY / 61.54% SELL
//
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: ramping-vus  10 VUs x lambda 2.167 = ~21.67 orders/sec = ~1,300/min
// Duration: 2 minutes (vs 3 minutes in the full test)
// Seed:     Resting SELL and BUY orders so both sides of the book have depth.
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
//   Target: 1,300 orders/min = 21.67 orders/sec
//   10 VUs x lambda 2.167 = 21.67 orders/sec
//   Duration 120s -> expected ~2,600 orders total
//   BUY:  ~1,000 (38.46%)
//   SELL: ~1,600 (61.54%)
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

import {
    ME_SHARD_A_URL,
    SHARD_A_SYMBOLS,
    BASE_PRICE,
    JSON_HEADERS,
} from './lib/config.js';
import { seedShard } from './lib/seedHelper.js';
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
const buyOrderCount = new Counter('buy_order_count');
const sellOrderCount = new Counter('sell_order_count');
const totalOrderCount = new Counter('total_order_count');

// =============================================================================
// Lambda: 2.167 orders/sec per VU  (10 VUs x 2.167 = ~21.67 orders/sec)
// =============================================================================
const LAMBDA = 2.167;

// =============================================================================
// k6 options -- 2 minute duration
// =============================================================================
export const options = {
    stages: [
        // Warm-up: ramp to 10 VUs over 5 seconds
        { duration: '5s', target: 10 },

        // Sustained load: 2 minutes at 10 VUs (~1,300 orders/min)
        { duration: '50s', target: 10 },

        // Cool-down
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
// Setup: seed Order Book with resting orders on both sides
// =============================================================================
export function setup() {
    console.log('=== Test: Stochastic Normal Load -- SHORT (2 min) ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Rate: ~1,300 orders/min (21.67 orders/sec) for 2 minutes');
    console.log('Distribution: 38.46% BUY / 61.54% SELL (stochastic)');
    console.log('Expected total: ~2,600 orders');
    console.log('');

    // Seed resting SELL orders
    console.log('Seeding SELL orders: 500 per symbol across 50 price levels...');
    seedShard('a', SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);

    // Seed resting BUY orders
    console.log('Seeding resting BUY orders for SELL-side matching...');
    let buySeeded = 0;
    for (const symbol of SHARD_A_SYMBOLS) {
        const orders = [];
        for (let level = 1; level <= 50; level++) {
            for (let i = 0; i < 10; i++) {
                orders.push({
                    orderId:  `seed-buy-${symbol}-${level}-${i}`,
                    symbol:   symbol,
                    side:     'BUY',
                    type:     'LIMIT',
                    price:    BASE_PRICE - level,
                    quantity: 10 + Math.floor(Math.random() * 190),
                });
            }
        }
        const payload = JSON.stringify({ orders: orders });
        const res = http.post(`${ME_SHARD_A_URL}/seed/a`, payload, {
            headers: JSON_HEADERS,
            timeout: '30s',
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

    const initialPrices = {};
    SHARD_A_SYMBOLS.forEach((sym) => {
        initialPrices[sym] = BASE_PRICE;
    });

    console.log('Seed complete. Starting stochastic normal load (2 min)...');
    console.log('');

    return { initialPrices };
}

// =============================================================================
// Main VU function
// =============================================================================
export default function (data) {
    if (__ITER === 0) {
        marketPrices = { ...data.initialPrices };
    }

    const symbol = randomShardASymbol();
    const marketPrice = updateMarketPrice(symbol, marketPrices);
    const order = generateStochasticOrder(symbol, marketPrice);

    const payload = JSON.stringify(order);
    const params = {
        headers: JSON_HEADERS,
        tags: {
            symbol: order.symbol,
            side: order.side,
        },
    };

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, params);

    // Record metrics
    matchingLatency.add(res.timings.duration);
    totalOrderCount.add(1);

    if (order.side === 'BUY') {
        buyOrderRate.add(1);
        sellOrderRate.add(0);
        buyOrderCount.add(1);
    } else {
        buyOrderRate.add(0);
        sellOrderRate.add(1);
        sellOrderCount.add(1);
    }

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
        'latency < 200ms': () => res.timings.duration < 200,
    });

    orderSuccessRate.add(success ? 1 : 0);

    if (!success && __ITER % 100 === 0) {
        console.error(
            `Order failed: ${order.symbol} ${order.side} @ ${order.price} - ` +
            `Status: ${res.status}, Body: ${res.body}`
        );
    }

    sleepPoisson(LAMBDA);
}

// =============================================================================
// Teardown
// =============================================================================
export function teardown() {
    console.log('');
    console.log('=== Stochastic Normal Load (2 min) complete ===');
    console.log('Metrics: matching_latency, order_success_rate, buy_order_count, sell_order_count, total_order_count');
    console.log('');
}
